# Unifra APISIX 重构方案：最大化利用 APISIX 能力

## 一、设计原则

1. **最小化核心修改** - ctx.lua 修改控制在 20 行以内
2. **最大化复用** - 充分利用 APISIX 原生能力
3. **业务外置** - 所有业务逻辑放在外部目录
4. **可升级** - 升级 APISIX 时冲突最小化

---

## 二、当前问题分析

### 2.1 ctx.lua 修改 (174 行新增)

| 代码块 | 行数 | 说明 |
|--------|------|------|
| JSONRPC 常量 | 6 | 可移到外部模块 |
| `isArray()` | 8 | 可移到外部模块 |
| `fetch_jsonrpc_data` | 60 | 可移到外部模块 |
| `parse_jsonrpc()` | 20 | 可移到外部模块 |
| `get_parsed_jsonrpc()` | 50 | 可移到外部模块 |
| `jsonrpc_` 前缀处理 | 4 | **必须保留** |

**结论**: 只有 `jsonrpc_` 前缀处理（4行）是必须在 ctx.lua 中的。

### 2.2 当前目录结构问题

```
apisix/
├── core/
│   └── ctx.lua              ← 大量修改
├── plugins/
│   ├── calculate-cu.lua     ← 混在官方插件中
│   ├── whitelist.lua        ← 混在官方插件中
│   ├── limit-cu.lua         ← 混在官方插件中
│   └── ...
```

---

## 三、重构后架构

### 3.1 目录结构

```
/opt/unifra-apisix/                    # 外部业务代码目录
├── apisix/
│   ├── core/
│   │   └── jsonrpc.lua                # JSON-RPC 解析模块
│   └── plugins/
│       ├── unifra-jsonrpc-var.lua     # 变量注册插件 (最高优先级)
│       ├── unifra-whitelist.lua
│       ├── unifra-calculate-cu.lua
│       ├── unifra-limit-cu/
│       │   ├── init.lua
│       │   ├── redis.lua
│       │   └── redis-cluster.lua
│       ├── unifra-limit-monthly-cu.lua
│       ├── unifra-guard.lua
│       └── unifra-ws-jsonrpc-proxy.lua
├── conf/
│   ├── whitelist.yaml                 # 方法白名单配置
│   └── cu-pricing.yaml                # CU 定价配置
└── README.md

apisix/                                 # APISIX 源码 (最小修改)
├── core/
│   └── ctx.lua                        # 只保留 ~15 行钩子代码
└── ...
```

### 3.2 配置方式

```yaml
# conf/config.yaml
apisix:
  extra_lua_path: "/opt/unifra-apisix/?.lua"

plugins:
  # Unifra 自定义插件 (使用前缀避免冲突)
  - unifra-jsonrpc-var      # 优先级 26000，最先执行
  - unifra-whitelist        # 优先级 1900
  - unifra-calculate-cu     # 优先级 1012
  - unifra-limit-monthly-cu # 优先级 1011
  - unifra-limit-cu         # 优先级 1010
  - unifra-guard            # 优先级 50
  - unifra-ws-jsonrpc-proxy # 优先级 999

  # APISIX 原生插件 (正常使用)
  - key-auth
  - limit-count
  - limit-req
  - proxy-rewrite
  - ...
```

---

## 四、核心模块设计

### 4.1 JSON-RPC 解析模块

```lua
-- /opt/unifra-apisix/apisix/core/jsonrpc.lua

local json = require("apisix.core.json")
local request = require("apisix.core.request")
local log = require("apisix.core.log")

local _M = {}

local JSONRPC_MAX_SIZE = 1048576  -- 1MiB
local JSONRPC_MIME = "application/json"

local function is_array(t)
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then return false end
    end
    return true
end

-- 解析 JSON-RPC 请求
-- 返回: { method = "xxx", methods = {"xxx", "yyy"}, is_batch = bool }
function _M.parse(ctx)
    -- 跳过 WebSocket 握手
    if ctx.var.request_method == "GET" and ctx.var.http_upgrade == "websocket" then
        return { method = nil, methods = {}, is_batch = false }
    end

    -- 只处理 POST + JSON
    if ctx.var.request_method ~= "POST" then
        return nil, "only POST method supported"
    end

    local content_type = request.header(ctx, "Content-Type") or ""
    if not string.match(content_type, JSONRPC_MIME) then
        return nil, "content-type must be application/json"
    end

    -- 读取并解析 body
    local body, err = request.get_body(JSONRPC_MAX_SIZE, ctx)
    if not body then
        return nil, "failed to read body: " .. (err or "empty")
    end

    local decoded, err = json.decode(body)
    if not decoded then
        return nil, "invalid json: " .. err
    end

    -- 批量请求
    if is_array(decoded) then
        if #decoded == 0 then
            return nil, "empty batch"
        end

        local methods = {}
        for _, req in ipairs(decoded) do
            if not req.method then
                return nil, "missing method in batch request"
            end
            methods[#methods + 1] = req.method
        end

        return {
            method = "batch",
            methods = methods,
            is_batch = true
        }
    end

    -- 单个请求
    if not decoded.method then
        return nil, "missing method"
    end

    return {
        method = decoded.method,
        methods = { decoded.method },
        is_batch = false
    }
end

-- 返回 JSON-RPC 错误响应
function _M.error_response(code, message, id)
    return {
        jsonrpc = "2.0",
        id = id,
        error = {
            code = code,
            message = message
        }
    }
end

return _M
```

### 4.2 变量注册插件 (关键!)

```lua
-- /opt/unifra-apisix/apisix/plugins/unifra-jsonrpc-var.lua
--
-- 这个插件的作用:
-- 1. 在最高优先级执行，解析 JSON-RPC 请求
-- 2. 将解析结果存入 ctx，供后续插件使用
-- 3. 注册 ctx.var 变量，兼容原有代码

local core = require("apisix.core")
local jsonrpc = require("apisix.core.jsonrpc")  -- 我们的外部模块

local plugin_name = "unifra-jsonrpc-var"

local _M = {
    version = 0.1,
    priority = 26000,  -- 最高优先级，在所有其他插件之前
    name = plugin_name,
    schema = { type = "object" },
}

function _M.rewrite(conf, ctx)
    -- 解析 JSON-RPC
    local result, err = jsonrpc.parse(ctx)

    if not result then
        -- 解析失败，返回 JSON-RPC 错误
        local code = -32700  -- Parse error
        if err == "empty batch" then
            code = -32600  -- Invalid Request
        end

        core.response.set_header("Content-Type", "application/json")
        return 200, jsonrpc.error_response(code, err, nil)
    end

    -- 存储到 ctx，供后续插件使用
    ctx.jsonrpc = result

    -- 设置变量 (直接写入 ctx.var 的缓存)
    ctx.var.jsonrpc_method = result.method
    ctx.var.jsonrpc_methods = result.methods
end

return _M
```

### 4.3 ctx.lua 最小修改 (方案 A: 约 15 行)

```lua
-- 在 ctx.lua 的 __index 元方法中，找到变量获取逻辑
-- 只需要添加以下代码 (约 15 行)

-- 添加在 graphql_ 处理之后
elseif core_str.has_prefix(key, "jsonrpc_") then
    -- JSON-RPC 变量由 unifra-jsonrpc-var 插件设置
    -- 这里只是一个 fallback，正常情况下变量已在缓存中
    local jsonrpc_data = t._ctx and t._ctx.jsonrpc
    if jsonrpc_data then
        key = sub_str(key, 9)  -- 去掉 "jsonrpc_" 前缀
        val = jsonrpc_data[key]
    end
```

### 4.4 ctx.lua 最小修改 (方案 B: 零修改!)

**如果愿意改变变量名**，可以完全不修改 ctx.lua：

```lua
-- 使用 rpc_method 代替 jsonrpc_method
-- 通过 register_var 注册

-- /opt/unifra-apisix/apisix/plugins/unifra-jsonrpc-var.lua
local core = require("apisix.core")

-- 在模块加载时注册变量
core.ctx.register_var("rpc_method", function(ctx)
    return ctx.jsonrpc and ctx.jsonrpc.method
end)

core.ctx.register_var("rpc_methods", function(ctx)
    return ctx.jsonrpc and ctx.jsonrpc.methods
end)

core.ctx.register_var("rpc_is_batch", function(ctx)
    return ctx.jsonrpc and ctx.jsonrpc.is_batch
end)
```

然后修改所有引用：
- `ctx.var.jsonrpc_method` → `ctx.var.rpc_method`
- `ctx.var.jsonrpc_methods` → `ctx.var.rpc_methods`

---

## 五、业务插件重构

### 5.1 whitelist 插件

```lua
-- /opt/unifra-apisix/apisix/plugins/unifra-whitelist.lua

local core = require("apisix.core")
local jsonrpc = require("apisix.core.jsonrpc")

local plugin_name = "unifra-whitelist"

-- 从外部配置文件加载白名单
local whitelist_config = nil

local schema = {
    type = "object",
    properties = {
        config_path = {
            type = "string",
            default = "/opt/unifra-apisix/conf/whitelist.yaml"
        }
    }
}

local _M = {
    version = 0.1,
    priority = 1900,
    name = plugin_name,
    schema = schema,
}

function _M.init()
    -- 加载白名单配置
    whitelist_config = load_yaml_config(schema.properties.config_path.default)
end

function _M.access(conf, ctx)
    local network = extract_network(ctx.var.host)  -- eth-mainnet.unifra.io -> eth-mainnet
    local methods = ctx.var.rpc_methods or ctx.var.jsonrpc_methods or {}
    local is_paid = ctx.var.monthly_quota > (conf.paid_threshold or 1000000)

    for _, method in ipairs(methods) do
        local allowed, err = check_method_access(whitelist_config, network, method, is_paid)
        if not allowed then
            return 405, jsonrpc.error_response(-32601, err, nil)
        end
    end
end

return _M
```

### 5.2 配置外置

```yaml
# /opt/unifra-apisix/conf/whitelist.yaml
networks:
  eth-mainnet:
    free:
      - eth_blockNumber
      - eth_getBalance
      - eth_call
      - eth_getLogs
      # ... 更多
    paid:
      - debug_traceTransaction
      - debug_traceBlockByHash
      - trace_*  # 支持通配符

  polygon-mainnet:
    free:
      - eth_*
      - bor_*
    paid:
      - trace_*
      - debug_*

# /opt/unifra-apisix/conf/cu-pricing.yaml
default: 1
methods:
  eth_call: 2
  eth_getLogs: 5
  debug_traceTransaction: 20
  trace_block: 50
```

---

## 六、WebSocket 处理方案

### 6.1 问题分析

WebSocket 的特殊性：
1. APISIX 插件是基于 HTTP 请求周期设计的
2. WebSocket 需要在**消息级别**应用业务逻辑
3. 当前 `ws-jsonrpc-proxy` 是完全独立的实现

### 6.2 方案选择

| 方案 | 描述 | 优点 | 缺点 |
|------|------|------|------|
| A. 保持现状 | ws-jsonrpc-proxy 独立实现 | 功能完整 | 与其他插件耦合 |
| B. 外部服务 | Go 写 WS 代理 | 解耦彻底 | 架构变复杂 |
| C. 优化现有 | 重构 ws-jsonrpc-proxy | 复用 APISIX | 仍有一定耦合 |

**推荐方案 C**: 重构 `ws-jsonrpc-proxy`，使其：
1. 复用 `apisix/core/jsonrpc.lua` 解析逻辑
2. 通过配置引用其他插件，而不是硬编码
3. 保持在 APISIX 插件体系内

### 6.3 ws-jsonrpc-proxy 重构

```lua
-- /opt/unifra-apisix/apisix/plugins/unifra-ws-jsonrpc-proxy.lua

local core = require("apisix.core")
local jsonrpc = require("apisix.core.jsonrpc")
local ws_server = require("resty.websocket.server")
local ws_client = require("resty.websocket.client")

local plugin_name = "unifra-ws-jsonrpc-proxy"

local schema = {
    type = "object",
    properties = {
        -- 配置化引用其他插件
        plugins = {
            type = "array",
            items = { type = "string" },
            default = {
                "unifra-whitelist",
                "unifra-calculate-cu",
                "unifra-limit-cu",
                "unifra-limit-monthly-cu"
            }
        }
    }
}

local _M = {
    version = 0.2,
    priority = 999,
    name = plugin_name,
    schema = schema,
}

-- 动态加载并执行插件
local function run_plugins_on_message(conf, ctx, parsed)
    -- 设置解析结果
    ctx.jsonrpc = parsed
    ctx.var.rpc_method = parsed.method
    ctx.var.rpc_methods = parsed.methods

    -- 按配置顺序执行插件
    for _, plugin_name in ipairs(conf.plugins or {}) do
        local plugin = require("apisix.plugins." .. plugin_name)
        if plugin and plugin.access then
            local code, body = plugin.access(plugin.default_conf or {}, ctx)
            if code then
                return code, body
            end
        end
    end

    return nil, nil
end

function _M.access(conf, ctx)
    if ctx.var.http_upgrade ~= "websocket" then
        return
    end

    -- ... WebSocket 代理逻辑 ...
    -- 在消息处理中调用 run_plugins_on_message
end

return _M
```

---

## 七、升级流程

### 7.1 升级 APISIX

```bash
# 1. 备份当前 ctx.lua
cp apisix/core/ctx.lua apisix/core/ctx.lua.backup

# 2. 拉取上游更新
git fetch upstream
git merge upstream/master

# 3. 如果 ctx.lua 有冲突，只需要重新添加 ~15 行钩子代码
# 冲突概率: 低
# 解决难度: 简单

# 4. 测试
make test
```

### 7.2 对比：修改前后

| 指标 | 重构前 | 重构后 |
|------|--------|--------|
| ctx.lua 修改行数 | 174 行 | 15 行 (或 0 行) |
| 插件位置 | 混在官方目录 | 外部独立目录 |
| 升级难度 | 几乎不可能 | 正常 git merge |
| 配置方式 | 硬编码 | 外部 YAML |

---

## 八、实施步骤

### Phase 1: 准备 (1 天)

1. 创建 `/opt/unifra-apisix/` 目录结构
2. 编写 `apisix/core/jsonrpc.lua` 模块
3. 编写 `unifra-jsonrpc-var` 插件

### Phase 2: 迁移插件 (2-3 天)

1. 迁移 `whitelist` → `unifra-whitelist`
2. 迁移 `calculate-cu` → `unifra-calculate-cu`
3. 迁移 `limit-cu` → `unifra-limit-cu`
4. 迁移其他插件
5. 将配置外置到 YAML

### Phase 3: 精简 ctx.lua (1 天)

1. 恢复 ctx.lua 到原版
2. 添加最小钩子代码 (15 行)
3. 或者改用 `rpc_*` 变量名 (0 行修改)

### Phase 4: 重构 ws-jsonrpc-proxy (2-3 天)

1. 重构为配置化插件引用
2. 复用 jsonrpc.lua 模块
3. 测试 WebSocket 功能

### Phase 5: 测试 & 上线 (2-3 天)

1. 单元测试
2. 集成测试
3. 灰度发布
4. 全量上线

**总计: 约 1.5-2 周**

---

## 九、最终架构图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              APISIX (原版)                               │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  ctx.lua (最小修改: 15 行)                                         │  │
│  │  - jsonrpc_ 前缀处理 (可选，或用 register_var 实现零修改)            │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  原生能力 (100% 复用)                                              │  │
│  │  - 动态配置 (etcd)                                                │  │
│  │  - 负载均衡 & 健康检查                                            │  │
│  │  - key-auth, jwt-auth                                            │  │
│  │  - limit-count, limit-req                                        │  │
│  │  - proxy-rewrite                                                 │  │
│  │  - 日志 & 监控                                                   │  │
│  │  - Admin API & Dashboard                                         │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  extra_lua_path: /opt/unifra-apisix/                                   │
│         │                                                               │
└─────────┼───────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     /opt/unifra-apisix/ (业务代码)                       │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  apisix/core/jsonrpc.lua                                          │  │
│  │  - JSON-RPC 解析                                                  │  │
│  │  - 错误响应生成                                                   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  apisix/plugins/                                                  │  │
│  │  ├── unifra-jsonrpc-var.lua     (解析 & 变量注册)                 │  │
│  │  ├── unifra-whitelist.lua       (方法白名单)                      │  │
│  │  ├── unifra-calculate-cu.lua    (CU 计算)                         │  │
│  │  ├── unifra-limit-cu/           (CU 限流)                         │  │
│  │  ├── unifra-limit-monthly-cu.lua (月度配额)                       │  │
│  │  ├── unifra-guard.lua           (紧急阻断)                        │  │
│  │  └── unifra-ws-jsonrpc-proxy.lua (WebSocket 代理)                 │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  conf/                                                            │  │
│  │  ├── whitelist.yaml             (方法白名单配置)                   │  │
│  │  └── cu-pricing.yaml            (CU 定价配置)                     │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 十、总结

### 核心改进

1. **ctx.lua 修改从 174 行降到 15 行** (或零修改)
2. **业务插件完全外置**，不污染 APISIX 源码
3. **配置外置到 YAML**，易于管理
4. **保留 APISIX 所有原生能力**

### 升级能力

- 升级前: ❌ 几乎不可能
- 升级后: ✅ 正常 git merge，最多手动处理 15 行代码

### 开发体验

- 业务逻辑集中在 `/opt/unifra-apisix/`
- 与 APISIX 源码完全分离
- 可独立版本控制和部署
