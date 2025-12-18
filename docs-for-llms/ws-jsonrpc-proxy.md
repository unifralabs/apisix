# 技术实施方案：以太坊 RPC 网关 WebSocket 支持与精细化限流

## 1. 方案概述

本方案旨在现有 APISIX 架构基础上，新增对 **WebSocket (JSON-RPC)** 的完整支持。
目标是实现类似 Alchemy 的 **"长连接鉴权 + 消息级计费"** 模式：
1.  **连接数限制**：基于 Consumer 或 IP 限制并发 WebSocket 连接数。
2.  **精细化限流**：在 WebSocket 长连接内部，针对每一条 JSON-RPC 消息计算 CU (Compute Units) 并扣除用户配额。
3.  **架构复用**：完全复用现有的 `custom-ctx-var` 变量注入机制、`limit-cu` 计费算法以及 `whitelist` 鉴权逻辑。

## 2. 核心架构设计

> 插件优先级：`ws-jsonrpc-proxy` 设为 **999**，确保执行顺序为 `limit-conn`(1003) / `limit-count`(1002) 之后、`gzip`(995) 之前，避免与现有核心限流插件冲突，同时不占用已存在的优先级值。

由于 WebSocket 握手后不再触发 Nginx 的 Access 阶段，我们需要引入一个中间人（MITM）插件来接管流量。

### 流量处理流程

1.  **握手阶段 (Handshake)** - *复用现有机制*
    *   **Key Auth**: 识别 API Key，加载 Consumer 配置。
    *   **Custom Ctx Var**: 将 Consumer 的配额（`seconds_quota` 等）注入到 `ctx.var`。
    *   **Limit Conn**: 检查当前 IP/Consumer 的连接数是否超标，超标直接拒绝 (503)。
2.  **代理阶段 (Proxy Loop)** - *新增逻辑*
    *   **WS Proxy**: 拦截升级后的 TCP 流，建立双向管道。
    *   **消息循环**:
        *   解析客户端发送的 JSON-RPC（支持单条与 batch）。
        *   **手动注入变量**: 模拟 Core 行为，设置 `ctx.var.jsonrpc_method` / `ctx.var.jsonrpc_methods` 和 `ctx.var.cu`。
        *   **手动调用插件**: 在 Lua 代码中显式调用 `whitelist`、`limit-cu`（秒级限流）和 `limit-monthly-cu`（月度配额）进行检查。
        *   **转发/拦截**: 检查通过则转发给节点；失败则返回 JSON Error (不强制断开连接)。

---

## 3. 开发任务清单

### 任务一：现有插件微调 (Refactoring)

**目标**：确保 `limit-cu` 和 `whitelist` 的核心逻辑可以被 Lua 代码直接调用，且**不执行** `ngx.exit`（因为这会中断 WS 连接）。

1.  **`apisix/plugins/limit-cu.lua`**:
    *   检查 `rate_limit` 函数。确保它**只返回状态码**（如 `200` 或 `429`），而不是直接调用 `core.response.exit(429)`。
    *   如果现有逻辑包含 `exit`，请拆分为 `_M.check_limit(conf, ctx)` (纯判断) 和 `_M.access` (HTTP 阶段调用)。

2.  **`apisix/plugins/whitelist.lua`**:
    *   同理，暴露一个 `check_access(conf, ctx)` 函数，返回 `true/false` 或错误信息，供 WS 代理插件调用。

### 任务二：开发新插件 `ws-jsonrpc-proxy`

**目标**：实现 WebSocket 中间人代理。

**核心代码逻辑 (伪代码/参考)**：

```lua
local ws_server = require("resty.websocket.server")
local ws_client = require("resty.websocket.client")
local cjson = require("cjson.safe")
-- 引入现有插件
local limit_cu = require("apisix.plugins.limit-cu")
local whitelist = require("apisix.plugins.whitelist")

function _M.access(conf, ctx)
    -- 1. 仅拦截 WebSocket
    if ctx.var.http_upgrade ~= "websocket" then return end

    -- 2. 建立服务端连接 (Handshake)
    local wb, err = ws_server:new()
    if not wb then return 500 end

    -- 3. 选路与连接上游 (复用 Upstream 配置)
    -- 开发注：需使用 apisix.balancer 选择节点
    local wc = ws_client:new()
    local ok = wc:connect("ws://" .. upstream_ip .. ":" .. upstream_port)
    if not ok then return 500 end

    -- 4. 开启下行转发线程 (Node -> Client)
    local co = ngx.thread.spawn(function()
        while true do
            local data, typ = wc:recv_frame()
            if not data then break end
            wb:send_frame(data, typ)
        end
    end)

    -- 5. 主线程处理上行消息 (Client -> Node)
    while true do
        local data, typ = wb:recv_frame()
        if not data then break end

        if typ == "text" then
            local req = cjson.decode(data)
            if req then
                -- A. 变量注入 (复用 Core/Whitelist 逻辑)
                ctx.var.jsonrpc_method = req.method
                -- B. 计算 CU (复用 Limit-CU 逻辑或在此处计算)
                -- 假设 limit-cu 内部会读 ctx.var.jsonrpc_method 来计算，或者在这里算好写入 ctx.var.cu
                
                -- C. 手动鉴权
                local wl_pass, wl_err = whitelist.check_access(whitelist_conf, ctx)
                if not wl_pass then
                    wb:send_text(cjson.encode({jsonrpc="2.0", error={code=403, message=wl_err}}))
                    goto continue_loop
                end

                -- D. 手动限流
                -- 注意：limit-cu 内部会自动读取 ctx.var.seconds_quota
                local limit_code = limit_cu.check_limit(limit_cu_conf, ctx)
                if limit_code ~= 200 then
                    wb:send_text(cjson.encode({jsonrpc="2.0", error={code=429, message="Rate limit exceeded"}}))
                    goto continue_loop
                end
            end
            -- E. 检查通过，转发
            wc:send_text(data)
        else
            -- Ping/Pong/Close 处理
            if typ == "close" then break end
            wc:send_frame(data, typ)
        end
        ::continue_loop::
    end
    
    wc:close()
    return 200
end
```

---

## 4. 配置变更计划

**重要提示**：在发布以下配置前，建议先在测试环境验证旧 Consumer 的行为。

### Service 配置更新 (`ws-plugins`)

我们需要修改现有的 Service，加入 WebSocket 相关的插件栈。

**变更点说明**：
1.  **`limit-conn`**: 加入连接数限制。**初始值建议设大 (如 500)**，以防误杀现有的旧 VIP 用户。后续可通过 Consumer 配置单独收紧。
2.  **`custom-ctx-var`**: 必须启用，用于握手阶段将 Consumer 变量注入内存。
3.  **`limit-cu`**: 必须配置 `count: "$seconds_quota"`，作为变量绑定的依据。
4.  **`ws-jsonrpc-proxy`**: 启用新插件。

```json
{
  "name": "ws-plugins",
  "plugins": {
    "cors": { "allow_origins": "*", "disable": false },
    "key-auth": { "header": "apikey", "query": "apikey" },
    "path-key-extractor": { "regex": "ws/(%w+)" },
    "proxy-rewrite": { "uri": "/" },
    "real-ip": { "source": "http_x_forwarded_for" },
    
    // --- 新增/修改部分 ---
    
    "custom-ctx-var": {}, // 1. 握手时注入 seconds_quota 等变量

    "whitelist": {
       "default_paid_quota": 100000
    },

    "limit-conn": {
       "conn": 500,       // 2. 默认并发连接数 (设大一点作为安全兜底)
       "burst": 0,
       "default_conn_delay": 0.1,
       "key": "remote_addr",
       "rejected_code": 429
    },

    "limit-cu": {
       "count": "$seconds_quota", // 3. 绑定变量，WS 代理插件调用时会自动读取
       "time_window": 1,
       "policy": "redis",
       "redis_host": "YOUR_REDIS_IP", 
       "redis_key_prefix": "rl:cu:",
       "rejected_code": 429
    },

    "ws-jsonrpc-proxy": {} // 4. 启用 WS 代理
  }
}
```

### Route 配置更新

确保 Route 指向上述 Service，并允许 WebSocket 升级。

```json
{
  "uri": "/*",  // 建议覆盖根路径，适配标准 Eth 客户端
  "name": "dogeos-testnet-ws",
  "methods": ["GET"],
  "host": "*dogeos-testnet.unifra.io",
  "service_id": "SERVICE_ID_OF_WS_PLUGINS",
  "upstream_id": "YOUR_UPSTREAM_ID",
  "enable_websocket": true,
  "vars": [
     ["http_upgrade", "==", "websocket"] // 仅匹配 WS 流量
  ]
}
```

---

## 5. 兼容性与 Consumer 管理

### 旧 Consumer 的兼容性
*   **功能**: 旧 Consumer 无需修改 JSON，其配置的 `custom-ctx-var` 变量（如 `seconds_quota`）会自动被 WS 方案识别并生效。
*   **兜底**: 如果 Consumer 没有特定变量，将回退使用 Service 中的默认行为或报错（取决于 Lua 代码里的 nil 处理）。

### 实现 VIP 用户差异化限制

#### 1. 差异化 CU 限流 (已自动支持)
修改 Consumer 的 `custom-ctx-var` 里的 `seconds_quota` 值即可。WS 代理里的 `limit-cu` 会自动读取该值。

#### 2. 差异化连接数限制 (需覆盖配置)
`limit-conn` 不支持变量。如需给 VIP 用户开通 1000 连接并发，需在 **Consumer JSON** 中覆盖插件配置：

```json
{
  "username": "vip_user",
  "plugins": {
    "custom-ctx-var": { "seconds_quota": "2000" }, // CU 限流变量
    "limit-conn": {
        "conn": 1000, // VIP 专属连接数配置，覆盖 Service 的 500
        "key": "remote_addr",
        "rejected_code": 503
    }
  }
}
```

---

## 6. 风险提示

1.  **`limit-conn` 初始值**：请务必确认 Service 中的 `limit-conn` 默认值（推荐 500+）不会低于现有大客户的并发数，否则上线瞬间会导致客户重连失败。
2.  **Redis 压力**：Alchemy 模式下，每条 WS 消息都会访问一次 Redis 进行 INCR。如果 WS 消息频率极高（如 10k TPS），请确保 `limit-cu` 使用了 Redis Pipeline 或 Lua Script 优化，并关注 Redis 负载。
