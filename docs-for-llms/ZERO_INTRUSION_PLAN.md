# 完全零侵入方案

## 核心发现

APISIX 原版已经有 JSON-RPC 支持，但**只支持单请求**。我们的修改主要是添加了 **batch 请求**支持。

`ctx.var` 的变量访问顺序：
```lua
1. 先查缓存      → t._cache[key]           ← 我们写入这里！
2. 再匹配前缀    → jsonrpc_, graphql_, http_
3. 最后 register_var
```

**关键洞察**：如果我们在最高优先级插件中**先写入缓存**，后续访问就不会触发原版解析！

---

## 方案设计

### 架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         APISIX (100% 原版，零修改)                       │
│                                                                         │
│  ctx.lua 原版:                                                          │
│  - jsonrpc_ 前缀处理 (原生功能)                                         │
│  - 只支持单请求 (我们通过缓存覆盖它)                                     │
│                                                                         │
│  extra_lua_path: /opt/unifra-apisix/                                   │
└─────────────────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    /opt/unifra-apisix/ (零侵入扩展)                      │
│                                                                         │
│  unifra-jsonrpc-var 插件 (priority: 26000)                             │
│  ├── 在 rewrite 阶段解析 JSON-RPC (支持 batch)                          │
│  ├── 写入 ctx.var.jsonrpc_method = "batch" 或 "eth_call"               │
│  └── 写入 ctx.var.jsonrpc_methods = {"eth_call", "eth_getBalance"}     │
│                                                                         │
│  后续插件访问 ctx.var.jsonrpc_method 时：                               │
│  → 直接从缓存返回，不触发原版解析！                                      │
└─────────────────────────────────────────────────────────────────────────┘
```

### 工作原理

```
请求进入
    │
    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  unifra-jsonrpc-var.rewrite() [priority: 26000, 最先执行]               │
│                                                                         │
│  1. 解析 JSON-RPC body (支持 batch)                                     │
│  2. ctx.var.jsonrpc_method = "batch"        ← 写入缓存                  │
│  3. ctx.var.jsonrpc_methods = ["eth_call", "eth_getBalance"]            │
└─────────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  unifra-whitelist.access() [priority: 1900]                             │
│                                                                         │
│  method = ctx.var.jsonrpc_method                                        │
│  → 访问缓存，返回 "batch"，不触发原版解析！                              │
└─────────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  其他插件...                                                            │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 实现代码

### 1. JSON-RPC 解析模块

```lua
-- /opt/unifra-apisix/apisix/core/jsonrpc.lua

local json = require("apisix.core.json")
local request = require("apisix.core.request")
local log = require("apisix.core.log")

local _M = {}

local MAX_SIZE = 1048576  -- 1MiB

local function is_array(t)
    if type(t) ~= "table" then
        return false
    end
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then
            return false
        end
    end
    return true
end

function _M.parse(ctx)
    -- 跳过非 POST 请求
    if ctx.var.request_method ~= "POST" then
        return nil, nil  -- 不是 JSON-RPC 请求，让原版处理
    end

    -- 跳过 WebSocket 握手
    if ctx.var.http_upgrade == "websocket" then
        return { method = nil, methods = {} }, nil
    end

    -- 检查 Content-Type
    local content_type = request.header(ctx, "Content-Type") or ""
    if not string.find(content_type, "application/json", 1, true) then
        return nil, nil  -- 不是 JSON，让原版处理
    end

    -- 读取 body
    local body, err = request.get_body(MAX_SIZE, ctx)
    if not body then
        return nil, "failed to read body: " .. (err or "empty")
    end

    -- 解析 JSON
    local decoded, err = json.decode(body)
    if not decoded then
        return nil, "parse error"
    end

    -- 批量请求
    if is_array(decoded) then
        if #decoded == 0 then
            return nil, "empty batch"
        end

        local methods = {}
        for _, req in ipairs(decoded) do
            if type(req) == "table" and req.method then
                methods[#methods + 1] = req.method
            else
                return nil, "invalid request in batch"
            end
        end

        return {
            method = "batch",
            methods = methods,
            is_batch = true
        }, nil
    end

    -- 单个请求
    if type(decoded) == "table" and decoded.method then
        return {
            method = decoded.method,
            methods = { decoded.method },
            is_batch = false
        }, nil
    end

    return nil, "invalid request"
end

function _M.error_response(code, message, id)
    return json.encode({
        jsonrpc = "2.0",
        id = id,
        error = {
            code = code,
            message = message
        }
    })
end

return _M
```

### 2. 变量注入插件 (核心！)

```lua
-- /opt/unifra-apisix/apisix/plugins/unifra-jsonrpc-var.lua

local core = require("apisix.core")
local jsonrpc = require("apisix.core.jsonrpc")

local plugin_name = "unifra-jsonrpc-var"

local _M = {
    version = 0.1,
    priority = 26000,  -- 最高优先级！确保在所有其他插件之前执行
    name = plugin_name,
    schema = { type = "object" },
}

function _M.rewrite(conf, ctx)
    -- 解析 JSON-RPC
    local result, err = jsonrpc.parse(ctx)

    if err then
        -- 解析出错，返回 JSON-RPC 错误响应
        local code = -32700  -- Parse error
        if err == "empty batch" then
            code = -32600  -- Invalid Request
        end

        core.response.set_header("Content-Type", "application/json")
        return 200, jsonrpc.error_response(code, err, nil)
    end

    if result then
        -- 关键！直接写入 ctx.var 缓存，覆盖原版行为
        ctx.var.jsonrpc_method = result.method
        ctx.var.jsonrpc_methods = result.methods

        -- 同时存到 ctx，方便其他插件使用
        ctx.jsonrpc = result
    end
    -- 如果 result 为 nil，说明不是 JSON-RPC 请求，让原版处理
end

return _M
```

### 3. 其他插件 (无需修改变量名！)

```lua
-- /opt/unifra-apisix/apisix/plugins/unifra-whitelist.lua

local core = require("apisix.core")

local _M = {
    version = 0.1,
    priority = 1900,
    name = "unifra-whitelist",
    schema = { type = "object" },
}

function _M.access(conf, ctx)
    -- 直接使用原来的变量名，完全兼容！
    local method = ctx.var.jsonrpc_method
    local methods = ctx.var.jsonrpc_methods

    -- 业务逻辑...
end

return _M
```

---

## 配置

```yaml
# conf/config.yaml

apisix:
  extra_lua_path: "/opt/unifra-apisix/?.lua"

plugins:
  # Unifra 插件
  - unifra-jsonrpc-var      # 必须第一个！
  - unifra-whitelist
  - unifra-calculate-cu
  - unifra-limit-cu
  - unifra-limit-monthly-cu
  - unifra-guard
  - unifra-ws-jsonrpc-proxy

  # APISIX 原生插件 (正常使用)
  - key-auth
  - limit-count
  - limit-req
  - proxy-rewrite
  # ...
```

---

## 目录结构

```
/opt/unifra-apisix/
├── apisix/
│   ├── core/
│   │   └── jsonrpc.lua                 # JSON-RPC 解析 (支持 batch)
│   └── plugins/
│       ├── unifra-jsonrpc-var.lua      # 变量注入 (核心!)
│       ├── unifra-whitelist.lua
│       ├── unifra-calculate-cu.lua
│       ├── unifra-limit-cu/
│       │   ├── init.lua
│       │   ├── redis.lua
│       │   └── redis-cluster.lua
│       ├── unifra-limit-monthly-cu.lua
│       ├── unifra-guard.lua
│       └── unifra-ws-jsonrpc-proxy.lua
└── conf/
    ├── whitelist.yaml
    └── cu-pricing.yaml

apisix/                                  # APISIX 源码
└── (完全不修改！使用原版)
```

---

## 对比

| 项目 | 之前 | 零侵入方案 |
|------|------|-----------|
| ctx.lua 修改 | 174 行 | **0 行** |
| 变量名 | jsonrpc_method | jsonrpc_method (不变!) |
| 插件位置 | apisix/plugins/ | /opt/unifra-apisix/ |
| APISIX 升级 | 几乎不可能 | **直接升级** |
| 兼容性 | - | 100% 兼容现有配置 |

---

## 升级流程

```bash
# 1. 恢复 ctx.lua 到原版
git checkout upstream/master -- apisix/core/ctx.lua

# 2. 移动插件到外部目录
mkdir -p /opt/unifra-apisix/apisix/plugins
mv apisix/plugins/calculate-cu.lua /opt/unifra-apisix/apisix/plugins/unifra-calculate-cu.lua
# ... 其他插件

# 3. 创建 jsonrpc.lua 和 unifra-jsonrpc-var.lua

# 4. 更新配置
# extra_lua_path: "/opt/unifra-apisix/?.lua"

# 5. 测试
make test

# 之后升级 APISIX
git fetch upstream
git merge upstream/master  # 无冲突！
```

---

## 关键点

1. **利用缓存机制** - `ctx.var.xxx = value` 写入缓存，后续访问直接返回
2. **优先级保证** - `unifra-jsonrpc-var` 必须是 26000（最高），确保第一个执行
3. **变量名不变** - 保持 `jsonrpc_method`，100% 兼容现有代码
4. **原版 ctx.lua** - 完全不修改，直接升级

---

## WebSocket 处理

WebSocket 仍然需要特殊处理，因为它是消息级别的。但 `unifra-ws-jsonrpc-proxy` 可以：

1. 复用 `apisix/core/jsonrpc.lua` 解析模块
2. 在每条消息上手动设置 `ctx.var.jsonrpc_method`
3. 调用其他插件

这部分逻辑保持独立，不影响零侵入的目标。

---

## 总结

**完全零侵入是可行的！**

核心原理：
- APISIX 原版已有 JSON-RPC 支持（只支持单请求）
- 我们通过高优先级插件**先写入缓存**
- 后续访问直接返回缓存，**覆盖**原版行为
- ctx.lua 完全不需要修改
