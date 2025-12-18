# Unifra JSON-RPC Gateway 重构实施指南

## 一、背景

### 1.1 当前问题

Unifra 基于 Apache APISIX 构建了区块链 JSON-RPC 网关，但当前实现存在严重的可维护性问题：

| 问题 | 影响 |
|------|------|
| `ctx.lua` 修改 174 行 | 无法升级 APISIX，每次合并都有冲突 |
| 插件混在 `apisix/plugins/` 目录 | 代码混乱，难以区分自定义和原生 |
| 插件之间硬编码调用 | ws-jsonrpc-proxy 直接 require 其他插件 |
| 配置硬编码 | 白名单、CU 定价写死在代码里 |

### 1.2 重构目标

1. **零侵入** - 不修改 APISIX 任何源文件
2. **可升级** - 随时可以升级 APISIX 版本
3. **可维护** - 代码结构清晰，逻辑集中
4. **生态兼容** - 无缝使用 APISIX 原生插件

---

## 二、设计原则

### 2.1 第一性原理

```
核心需求：区块链 JSON-RPC 网关

功能分解：
1. JSON-RPC 解析（单个 + 批量）
2. 方法级访问控制（白名单、免费/付费）
3. 计量（Compute Unit）
4. 限流（秒级 + 月度配额）
5. 多协议支持（HTTP + WebSocket）
```

### 2.2 设计决策

| 决策点 | 选择 | 理由 |
|--------|------|------|
| 代码位置 | 外部目录 `/opt/unifra-apisix/` | 零侵入，独立版本控制 |
| 插件机制 | 融入 APISIX 插件体系 | 复用生态，保持兼容 |
| 逻辑复用 | 核心逻辑独立模块，插件为薄壳 | HTTP/WS 复用同一套逻辑 |
| 配置管理 | 外部 YAML 文件 | 代码与配置分离 |
| 变量传递 | 写入 ctx.var 缓存 | 利用 APISIX 原生机制 |

---

## 三、架构设计

### 3.1 整体架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              客户端请求                                      │
│                         (HTTP / WebSocket)                                  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           APISIX (原版，零修改)                              │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                        插件执行流 (按优先级)                           │  │
│  │                                                                       │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │  APISIX 原生插件                                                 │  │  │
│  │  │  key-auth (2500) → limit-conn (1003) → limit-count (1002) → ... │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  │                              ↓                                        │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │  Unifra 自定义插件 (通过 extra_lua_path 加载)                    │  │  │
│  │  │                                                                 │  │  │
│  │  │  unifra-jsonrpc-var (26000)  ← 最高优先级，解析 JSON-RPC        │  │  │
│  │  │          ↓                                                      │  │  │
│  │  │  unifra-whitelist (1900)     ← 方法白名单检查                   │  │  │
│  │  │          ↓                                                      │  │  │
│  │  │  unifra-calculate-cu (1012)  ← 计算 Compute Unit                │  │  │
│  │  │          ↓                                                      │  │  │
│  │  │  unifra-limit-monthly-cu (1011) ← 月度配额检查                  │  │  │
│  │  │          ↓                                                      │  │  │
│  │  │  unifra-limit-cu (1010)      ← 秒级速率限制                     │  │  │
│  │  │          ↓                                                      │  │  │
│  │  │  unifra-ws-jsonrpc-proxy (999) ← WebSocket 代理 (仅 WS 生效)    │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  │                              ↓                                        │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │  APISIX 原生插件 (继续)                                          │  │  │
│  │  │  proxy-rewrite → response-rewrite → prometheus → ...            │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  APISIX 核心能力 (100% 复用)                                          │  │
│  │  • 动态配置 (etcd)    • Admin API        • Dashboard                 │  │
│  │  • 负载均衡           • 健康检查          • 服务发现                  │  │
│  │  • SSL/TLS            • 监控指标          • 日志                      │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  配置: extra_lua_path = "/opt/unifra-apisix/?.lua"                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            区块链节点集群                                    │
│  eth-mainnet: [node1, node2, node3]                                         │
│  polygon: [node1, node2]                                                    │
│  scroll: [node1]                                                            │
│  ...                                                                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 代码复用架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         /opt/unifra-apisix/                                 │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  unifra/jsonrpc/ (核心业务逻辑，纯函数，可独立测试)                    │  │
│  │                                                                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │  core.lua   │  │whitelist.lua│  │   cu.lua    │  │ratelimit.lua│  │  │
│  │  │  • parse()  │  │  • check()  │  │• calculate()│  │  • check()  │  │  │
│  │  │  • error()  │  │  • load()   │  │             │  │  • incr()   │  │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                          ↑                  ↑                               │
│                          │   被调用         │                               │
│  ┌───────────────────────┴──────────────────┴────────────────────────────┐  │
│  │  apisix/plugins/ (APISIX 插件壳，薄层封装)                             │  │
│  │                                                                       │  │
│  │  ┌───────────────────┐  ┌───────────────────┐  ┌──────────────────┐  │  │
│  │  │unifra-jsonrpc-var │  │ unifra-whitelist  │  │unifra-calculate- │  │  │
│  │  │    .lua           │  │     .lua          │  │     cu.lua       │  │  │
│  │  └───────────────────┘  └───────────────────┘  └──────────────────┘  │  │
│  │                                                                       │  │
│  │  ┌───────────────────┐  ┌───────────────────┐  ┌──────────────────┐  │  │
│  │  │ unifra-limit-cu   │  │unifra-limit-      │  │unifra-ws-jsonrpc-│  │  │
│  │  │     .lua          │  │  monthly-cu.lua   │  │    proxy.lua     │  │  │
│  │  └───────────────────┘  └───────────────────┘  └──────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  conf/ (外部配置文件)                                                  │  │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐   │  │
│  │  │ whitelist.yaml  │  │ cu-pricing.yaml │  │ networks.yaml       │   │  │
│  │  └─────────────────┘  └─────────────────┘  └─────────────────────┘   │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 HTTP vs WebSocket 处理

```
HTTP 请求:
┌──────────────┐     ┌──────────────────────────────────────────────────┐
│   Request    │ ──→ │  APISIX 插件链自动执行                           │
│   (单次)     │     │  jsonrpc-var → whitelist → cu → limit → proxy   │
└──────────────┘     └──────────────────────────────────────────────────┘

WebSocket 请求:
┌──────────────┐     ┌──────────────────────────────────────────────────┐
│  Handshake   │ ──→ │  APISIX 插件链执行 (握手阶段)                    │
│   (GET)      │     │  key-auth → jsonrpc-var(skip) → ws-proxy(接管)  │
└──────────────┘     └──────────────────────────────────────────────────┘
       │
       ▼
┌──────────────┐     ┌──────────────────────────────────────────────────┐
│   Message    │ ──→ │  ws-proxy 内部处理 (复用核心逻辑)                │
│   (多次)     │     │  core.parse() → whitelist.check() → cu → limit  │
└──────────────┘     └──────────────────────────────────────────────────┘
```

---

## 四、目录结构

```
/opt/unifra-apisix/
├── unifra/
│   └── jsonrpc/
│       ├── core.lua              # JSON-RPC 解析、错误响应
│       ├── whitelist.lua         # 白名单检查逻辑
│       ├── cu.lua                # CU 计算逻辑
│       ├── ratelimit.lua         # 限流逻辑 (Redis 操作)
│       └── config.lua            # 配置加载器
│
├── apisix/
│   └── plugins/
│       ├── unifra-jsonrpc-var.lua        # 解析 JSON-RPC，注入变量
│       ├── unifra-whitelist.lua          # 方法白名单插件
│       ├── unifra-calculate-cu.lua       # CU 计算插件
│       ├── unifra-limit-cu.lua           # 秒级限流插件
│       ├── unifra-limit-monthly-cu.lua   # 月度配额插件
│       ├── unifra-guard.lua              # 紧急阻断插件
│       └── unifra-ws-jsonrpc-proxy.lua   # WebSocket 代理插件
│
├── conf/
│   ├── whitelist.yaml            # 方法白名单配置
│   ├── cu-pricing.yaml           # CU 定价配置
│   └── networks.yaml             # 网络配置
│
└── tests/
    ├── test_core.lua             # 核心逻辑测试
    ├── test_whitelist.lua        # 白名单测试
    └── test_cu.lua               # CU 计算测试
```

---

## 五、核心模块设计

### 5.1 core.lua - JSON-RPC 解析

```lua
-- /opt/unifra-apisix/unifra/jsonrpc/core.lua

local json = require("cjson.safe")

local _M = {}

-- 常量
_M.ERROR_PARSE = -32700
_M.ERROR_INVALID_REQUEST = -32600
_M.ERROR_METHOD_NOT_FOUND = -32601
_M.ERROR_RATE_LIMITED = -32000
_M.ERROR_QUOTA_EXCEEDED = -32001

-- 判断是否为数组
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

--- 解析 JSON-RPC 请求
-- @param body string 请求体
-- @return table|nil 解析结果 { method, methods, is_batch, raw }
-- @return string|nil 错误信息
function _M.parse(body)
    if not body or body == "" then
        return nil, "empty body"
    end

    local decoded, err = json.decode(body)
    if not decoded then
        return nil, "parse error: " .. (err or "invalid json")
    end

    -- 批量请求
    if is_array(decoded) then
        if #decoded == 0 then
            return nil, "empty batch"
        end

        local methods = {}
        for i, req in ipairs(decoded) do
            if type(req) ~= "table" then
                return nil, "invalid request at index " .. i
            end
            if not req.method or type(req.method) ~= "string" then
                return nil, "missing method at index " .. i
            end
            methods[#methods + 1] = req.method
        end

        return {
            method = "batch",
            methods = methods,
            is_batch = true,
            count = #decoded,
            raw = decoded
        }, nil
    end

    -- 单个请求
    if type(decoded) ~= "table" then
        return nil, "invalid request: not an object"
    end

    if not decoded.method or type(decoded.method) ~= "string" then
        return nil, "missing method"
    end

    return {
        method = decoded.method,
        methods = { decoded.method },
        is_batch = false,
        count = 1,
        raw = decoded
    }, nil
end

--- 生成 JSON-RPC 错误响应
-- @param code number 错误码
-- @param message string 错误信息
-- @param id any 请求 ID (可选)
-- @return string JSON 字符串
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

--- 生成 JSON-RPC 错误响应 (table 格式)
-- @param code number 错误码
-- @param message string 错误信息
-- @param id any 请求 ID (可选)
-- @return table
function _M.error_table(code, message, id)
    return {
        jsonrpc = "2.0",
        id = id,
        error = {
            code = code,
            message = message
        }
    }
end

--- 从 host 提取网络名称
-- @param host string 例如 "eth-mainnet.unifra.io"
-- @return string 例如 "eth-mainnet"
function _M.extract_network(host)
    if not host then
        return nil
    end
    return host:match("^([^.]+)%.unifra%.io$") or host:match("^([^.]+)%.")
end

return _M
```

### 5.2 whitelist.lua - 白名单检查

```lua
-- /opt/unifra-apisix/unifra/jsonrpc/whitelist.lua

local yaml = require("tinyyaml")
local log = require("apisix.core.log")

local _M = {}

local config_cache = nil
local config_mtime = 0

--- 加载白名单配置
-- @param path string 配置文件路径
-- @return table 配置
function _M.load_config(path)
    local file = io.open(path, "r")
    if not file then
        log.error("failed to open whitelist config: ", path)
        return nil
    end

    local content = file:read("*a")
    file:close()

    local config, err = yaml.parse(content)
    if not config then
        log.error("failed to parse whitelist config: ", err)
        return nil
    end

    return config
end

--- 检查方法是否匹配模式
-- @param method string 方法名
-- @param pattern string 模式 (支持 * 通配符，如 "eth_*")
-- @return boolean
local function match_pattern(method, pattern)
    if pattern == method then
        return true
    end

    -- 处理通配符
    if pattern:sub(-1) == "*" then
        local prefix = pattern:sub(1, -2)
        return method:sub(1, #prefix) == prefix
    end

    return false
end

--- 检查方法是否在列表中
-- @param method string 方法名
-- @param list table 方法列表
-- @return boolean
local function in_list(method, list)
    if not list then
        return false
    end

    for _, pattern in ipairs(list) do
        if match_pattern(method, pattern) then
            return true
        end
    end

    return false
end

--- 检查方法是否允许访问
-- @param network string 网络名称
-- @param methods table 方法列表
-- @param is_paid boolean 是否付费用户
-- @param config table 配置
-- @return boolean 是否允许
-- @return string|nil 错误信息
function _M.check(network, methods, is_paid, config)
    if not config or not config.networks then
        return false, "whitelist config not loaded"
    end

    local network_config = config.networks[network]
    if not network_config then
        return false, "unsupported network: " .. network
    end

    for _, method in ipairs(methods) do
        local is_free = in_list(method, network_config.free)
        local is_paid_method = in_list(method, network_config.paid)

        if is_free then
            -- 免费方法，所有人可用
        elseif is_paid_method then
            -- 付费方法，需要付费用户
            if not is_paid then
                return false, "method " .. method .. " requires paid tier"
            end
        else
            -- 不在任何列表中
            return false, "unsupported method: " .. method
        end
    end

    return true, nil
end

return _M
```

### 5.3 cu.lua - CU 计算

```lua
-- /opt/unifra-apisix/unifra/jsonrpc/cu.lua

local yaml = require("tinyyaml")
local log = require("apisix.core.log")

local _M = {}

--- 加载 CU 定价配置
-- @param path string 配置文件路径
-- @return table 配置
function _M.load_config(path)
    local file = io.open(path, "r")
    if not file then
        log.error("failed to open cu pricing config: ", path)
        return { default = 1, methods = {} }
    end

    local content = file:read("*a")
    file:close()

    local config = yaml.parse(content)
    return config or { default = 1, methods = {} }
end

--- 计算单个方法的 CU
-- @param method string 方法名
-- @param config table 配置
-- @return number CU 值
function _M.get_method_cu(method, config)
    if config.methods and config.methods[method] then
        return config.methods[method]
    end
    return config.default or 1
end

--- 计算总 CU
-- @param methods table 方法列表
-- @param config table 配置
-- @return number 总 CU
function _M.calculate(methods, config)
    local total = 0
    for _, method in ipairs(methods) do
        total = total + _M.get_method_cu(method, config)
    end
    return total
end

return _M
```

### 5.4 ratelimit.lua - 限流逻辑

```lua
-- /opt/unifra-apisix/unifra/jsonrpc/ratelimit.lua

local redis = require("resty.redis")

local _M = {}

--- 检查并增加速率限制计数
-- @param redis_conf table Redis 配置
-- @param key string 限流 key
-- @param cu number 本次消耗的 CU
-- @param limit number 限制值
-- @param window number 时间窗口 (秒)
-- @return boolean 是否允许
-- @return number 剩余配额
-- @return string|nil 错误信息
function _M.check_and_incr(redis_conf, key, cu, limit, window)
    local red = redis:new()
    red:set_timeout(redis_conf.timeout or 1000)

    local ok, err = red:connect(redis_conf.host, redis_conf.port or 6379)
    if not ok then
        return nil, nil, "redis connect failed: " .. err
    end

    if redis_conf.password and redis_conf.password ~= "" then
        local ok, err = red:auth(redis_conf.password)
        if not ok then
            return nil, nil, "redis auth failed: " .. err
        end
    end

    if redis_conf.database and redis_conf.database > 0 then
        red:select(redis_conf.database)
    end

    -- 使用 INCRBY 原子操作
    local current, err = red:incrby(key, cu)
    if not current then
        return nil, nil, "redis incrby failed: " .. err
    end

    -- 设置过期时间 (仅在 key 首次创建时)
    if current == cu then
        red:expire(key, window)
    end

    -- 放回连接池
    red:set_keepalive(10000, 100)

    local remaining = limit - current
    if remaining < 0 then
        remaining = 0
    end

    return current <= limit, remaining, nil
end

--- 生成限流 key
-- @param consumer_id string 用户 ID
-- @param window number 时间窗口 (秒)
-- @return string
function _M.make_key(consumer_id, window)
    local ts = math.floor(ngx.now() / window) * window
    return string.format("ratelimit:%s:%d", consumer_id, ts)
end

return _M
```

---

## 六、插件设计

### 6.1 unifra-jsonrpc-var.lua

```lua
-- /opt/unifra-apisix/apisix/plugins/unifra-jsonrpc-var.lua

local core = require("apisix.core")
local jsonrpc = require("unifra.jsonrpc.core")

local plugin_name = "unifra-jsonrpc-var"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 26000,  -- 最高优先级
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    -- 跳过 WebSocket 握手 (GET 请求)
    if ctx.var.request_method == "GET" then
        return
    end

    -- 跳过非 JSON 请求
    local content_type = core.request.header(ctx, "Content-Type") or ""
    if not content_type:find("application/json", 1, true) then
        return
    end

    -- 读取并解析 body
    local body, err = core.request.get_body()
    if not body then
        core.log.warn("failed to get request body: ", err)
        return
    end

    local result, err = jsonrpc.parse(body)
    if err then
        core.response.set_header("Content-Type", "application/json")
        return 200, jsonrpc.error_response(jsonrpc.ERROR_PARSE, err)
    end

    -- 写入 ctx.var 缓存 (关键!)
    ctx.var.jsonrpc_method = result.method
    ctx.var.jsonrpc_methods = result.methods

    -- 存入 ctx 供其他插件使用
    ctx.jsonrpc = result

    -- 提取网络名称
    ctx.var.unifra_network = jsonrpc.extract_network(ctx.var.host)
end

return _M
```

### 6.2 unifra-whitelist.lua

```lua
-- /opt/unifra-apisix/apisix/plugins/unifra-whitelist.lua

local core = require("apisix.core")
local jsonrpc = require("unifra.jsonrpc.core")
local whitelist = require("unifra.jsonrpc.whitelist")

local plugin_name = "unifra-whitelist"

local schema = {
    type = "object",
    properties = {
        config_path = {
            type = "string",
            default = "/opt/unifra-apisix/conf/whitelist.yaml"
        },
        paid_quota_threshold = {
            type = "integer",
            default = 1000000
        }
    },
}

local _M = {
    version = 0.1,
    priority = 1900,
    name = plugin_name,
    schema = schema,
}

local config_cache = nil

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    -- 跳过非 JSON-RPC 请求
    if not ctx.jsonrpc then
        return
    end

    -- 加载配置 (带缓存)
    if not config_cache then
        config_cache = whitelist.load_config(conf.config_path)
    end

    local network = ctx.var.unifra_network
    local methods = ctx.var.jsonrpc_methods
    local monthly_quota = tonumber(ctx.var.monthly_quota) or 0
    local is_paid = monthly_quota > conf.paid_quota_threshold

    local ok, err = whitelist.check(network, methods, is_paid, config_cache)
    if not ok then
        core.response.set_header("Content-Type", "application/json")
        return 405, jsonrpc.error_response(jsonrpc.ERROR_METHOD_NOT_FOUND, err)
    end
end

return _M
```

### 6.3 unifra-calculate-cu.lua

```lua
-- /opt/unifra-apisix/apisix/plugins/unifra-calculate-cu.lua

local core = require("apisix.core")
local cu = require("unifra.jsonrpc.cu")

local plugin_name = "unifra-calculate-cu"

local schema = {
    type = "object",
    properties = {
        config_path = {
            type = "string",
            default = "/opt/unifra-apisix/conf/cu-pricing.yaml"
        }
    },
}

local _M = {
    version = 0.1,
    priority = 1012,
    name = plugin_name,
    schema = schema,
}

local config_cache = nil

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    if not ctx.jsonrpc then
        return
    end

    -- 加载配置 (带缓存)
    if not config_cache then
        config_cache = cu.load_config(conf.config_path)
    end

    local methods = ctx.var.jsonrpc_methods
    local total_cu = cu.calculate(methods, config_cache)

    -- 写入 ctx.var
    ctx.var.cu = total_cu
end

return _M
```

### 6.4 unifra-limit-cu.lua

```lua
-- /opt/unifra-apisix/apisix/plugins/unifra-limit-cu.lua

local core = require("apisix.core")
local jsonrpc = require("unifra.jsonrpc.core")
local ratelimit = require("unifra.jsonrpc.ratelimit")

local plugin_name = "unifra-limit-cu"

local schema = {
    type = "object",
    properties = {
        limit_var = {
            type = "string",
            default = "seconds_quota"
        },
        time_window = {
            type = "integer",
            default = 1
        },
        key_var = {
            type = "string",
            default = "consumer_name"
        },
        redis_host = { type = "string", default = "127.0.0.1" },
        redis_port = { type = "integer", default = 6379 },
        redis_password = { type = "string", default = "" },
        redis_database = { type = "integer", default = 0 },
        redis_timeout = { type = "integer", default = 1000 },
        rejected_code = { type = "integer", default = 429 },
    },
    required = { "redis_host" }
}

local _M = {
    version = 0.1,
    priority = 1010,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    if not ctx.var.cu then
        return
    end

    local cu = tonumber(ctx.var.cu) or 1
    local limit = tonumber(ctx.var[conf.limit_var]) or 100
    local key_value = ctx.var[conf.key_var] or ctx.var.remote_addr

    local redis_conf = {
        host = conf.redis_host,
        port = conf.redis_port,
        password = conf.redis_password,
        database = conf.redis_database,
        timeout = conf.redis_timeout,
    }

    local key = ratelimit.make_key(key_value, conf.time_window)
    local ok, remaining, err = ratelimit.check_and_incr(redis_conf, key, cu, limit, conf.time_window)

    if err then
        core.log.error("rate limit error: ", err)
        -- 降级处理：允许通过
        return
    end

    if not ok then
        core.response.set_header("Content-Type", "application/json")
        core.response.set_header("X-RateLimit-Limit", limit)
        core.response.set_header("X-RateLimit-Remaining", 0)
        return conf.rejected_code, jsonrpc.error_response(
            jsonrpc.ERROR_RATE_LIMITED,
            "rate limit exceeded"
        )
    end

    core.response.set_header("X-RateLimit-Limit", limit)
    core.response.set_header("X-RateLimit-Remaining", remaining)
end

return _M
```

### 6.5 unifra-limit-monthly-cu.lua

```lua
-- /opt/unifra-apisix/apisix/plugins/unifra-limit-monthly-cu.lua

local core = require("apisix.core")
local jsonrpc = require("unifra.jsonrpc.core")

local plugin_name = "unifra-limit-monthly-cu"

local schema = {
    type = "object",
    properties = {
        quota_var = {
            type = "string",
            default = "monthly_quota"
        },
        used_var = {
            type = "string",
            default = "monthly_used"
        },
    },
}

local _M = {
    version = 0.1,
    priority = 1011,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    local quota = tonumber(ctx.var[conf.quota_var])
    local used = tonumber(ctx.var[conf.used_var])

    if not quota or not used then
        return
    end

    if used >= quota then
        core.response.set_header("Content-Type", "application/json")
        return 429, jsonrpc.error_response(
            jsonrpc.ERROR_QUOTA_EXCEEDED,
            "monthly quota exceeded"
        )
    end
end

return _M
```

---

## 七、配置文件

### 7.1 whitelist.yaml

```yaml
# /opt/unifra-apisix/conf/whitelist.yaml

networks:
  eth-mainnet:
    free:
      - web3_clientVersion
      - web3_sha3
      - net_version
      - net_listening
      - eth_blockNumber
      - eth_getBlockByHash
      - eth_getBlockByNumber
      - eth_getTransactionByHash
      - eth_getTransactionReceipt
      - eth_getBalance
      - eth_getCode
      - eth_call
      - eth_estimateGas
      - eth_gasPrice
      - eth_getLogs
      - eth_chainId
      - eth_getTransactionCount
      - eth_sendRawTransaction
      # ... 更多方法
    paid:
      - debug_*
      - trace_*

  polygon-mainnet:
    free:
      - web3_*
      - net_*
      - eth_*
      - bor_*
    paid:
      - debug_*
      - trace_*

  scroll-mainnet:
    free:
      - web3_*
      - net_*
      - eth_*
    paid:
      - debug_*

  # ... 更多网络
```

### 7.2 cu-pricing.yaml

```yaml
# /opt/unifra-apisix/conf/cu-pricing.yaml

default: 1

methods:
  # 基础方法
  eth_blockNumber: 1
  eth_chainId: 1
  eth_gasPrice: 1

  # 中等复杂度
  eth_getBalance: 2
  eth_call: 2
  eth_estimateGas: 3

  # 高复杂度
  eth_getLogs: 5
  eth_getBlockReceipts: 10

  # 调试方法
  debug_traceTransaction: 20
  debug_traceBlockByHash: 50
  debug_traceBlockByNumber: 50
  trace_block: 50
  trace_transaction: 20
```

### 7.3 APISIX 配置

```yaml
# conf/config.yaml

apisix:
  extra_lua_path: "/opt/unifra-apisix/?.lua"

plugins:
  # Unifra 自定义插件
  - unifra-jsonrpc-var
  - unifra-whitelist
  - unifra-calculate-cu
  - unifra-limit-monthly-cu
  - unifra-limit-cu
  - unifra-guard
  - unifra-ws-jsonrpc-proxy

  # APISIX 原生插件 (按需启用)
  - key-auth
  - jwt-auth
  - limit-conn
  - limit-count
  - limit-req
  - proxy-rewrite
  - response-rewrite
  - prometheus
  - http-logger
  # ... 更多
```

---

## 八、迁移步骤

### 8.1 Phase 1: 准备 (1-2 天)

```bash
# 1. 创建目录结构
mkdir -p /opt/unifra-apisix/{unifra/jsonrpc,apisix/plugins,conf,tests}

# 2. 编写核心模块
# - unifra/jsonrpc/core.lua
# - unifra/jsonrpc/whitelist.lua
# - unifra/jsonrpc/cu.lua
# - unifra/jsonrpc/ratelimit.lua

# 3. 编写配置文件
# - conf/whitelist.yaml (从 whitelist.lua 提取)
# - conf/cu-pricing.yaml (从 calculate-cu.lua 提取)

# 4. 编写单元测试
# - tests/test_core.lua
# - tests/test_whitelist.lua
```

### 8.2 Phase 2: 迁移插件 (2-3 天)

```bash
# 1. 编写新插件
# - apisix/plugins/unifra-jsonrpc-var.lua
# - apisix/plugins/unifra-whitelist.lua
# - apisix/plugins/unifra-calculate-cu.lua
# - apisix/plugins/unifra-limit-cu.lua
# - apisix/plugins/unifra-limit-monthly-cu.lua

# 2. 迁移 ws-jsonrpc-proxy
# - 复用核心模块
# - 简化代码

# 3. 更新 APISIX 配置
# - 添加 extra_lua_path
# - 添加新插件到 plugins 列表
```

### 8.3 Phase 3: 恢复原版 APISIX (1 天)

```bash
# 1. 恢复 ctx.lua 到原版
git checkout upstream/master -- apisix/core/ctx.lua

# 2. 删除旧插件
rm apisix/plugins/calculate-cu.lua
rm apisix/plugins/whitelist.lua
rm apisix/plugins/limit-cu.lua
rm -rf apisix/plugins/limit-cu/
rm apisix/plugins/limit-monthly-cu.lua
rm apisix/plugins/custom-ctx-var.lua
rm apisix/plugins/env-to-ctx.lua
rm apisix/plugins/guard.lua
rm apisix/plugins/ws-jsonrpc-proxy.lua

# 3. 更新 config-default.yaml (移除旧插件)
```

### 8.4 Phase 4: 测试 (2-3 天)

```bash
# 1. 单元测试
cd /opt/unifra-apisix
resty tests/test_core.lua
resty tests/test_whitelist.lua
resty tests/test_cu.lua

# 2. 集成测试
# - 测试 HTTP JSON-RPC
# - 测试 WebSocket JSON-RPC
# - 测试批量请求
# - 测试限流
# - 测试白名单

# 3. 压力测试
wrk -t4 -c100 -d60s http://localhost:9080/
```

### 8.5 Phase 5: 上线 (1-2 天)

```bash
# 1. 灰度发布
# - 10% 流量切换到新版本
# - 监控错误率、延迟

# 2. 逐步扩大
# - 30% → 50% → 80% → 100%

# 3. 下线旧版本
```

---

## 九、测试清单

### 9.1 功能测试

| 测试项 | 描述 | 状态 |
|--------|------|------|
| JSON-RPC 单请求解析 | `{"method": "eth_blockNumber"}` | [ ] |
| JSON-RPC 批量请求解析 | `[{"method": "eth_blockNumber"}, ...]` | [ ] |
| 空 batch 错误 | `[]` 返回错误 | [ ] |
| 无效 JSON 错误 | 格式错误返回 -32700 | [ ] |
| 白名单 - 免费方法 | 免费用户访问 eth_blockNumber | [ ] |
| 白名单 - 付费方法 | 免费用户访问 debug_* 被拒 | [ ] |
| 白名单 - 付费用户 | 付费用户访问 debug_* 成功 | [ ] |
| CU 计算 - 单请求 | eth_call = 2 CU | [ ] |
| CU 计算 - 批量请求 | 累加所有方法 CU | [ ] |
| 速率限制 - 正常 | 未超限正常通过 | [ ] |
| 速率限制 - 超限 | 返回 429 | [ ] |
| 月度配额 - 正常 | 未超限正常通过 | [ ] |
| 月度配额 - 超限 | 返回 429 | [ ] |
| WebSocket 握手 | 正常建立连接 | [ ] |
| WebSocket 消息 | 每条消息应用限流 | [ ] |

### 9.2 兼容性测试

| 测试项 | 描述 | 状态 |
|--------|------|------|
| key-auth | API Key 认证正常 | [ ] |
| limit-conn | 连接数限制正常 | [ ] |
| prometheus | 指标采集正常 | [ ] |
| http-logger | 日志记录正常 | [ ] |
| Admin API | 动态配置正常 | [ ] |

### 9.3 升级测试

| 测试项 | 描述 | 状态 |
|--------|------|------|
| APISIX 升级 | git merge 无冲突 | [ ] |
| API 兼容 | 核心 API 调用正常 | [ ] |

---

## 十、回滚方案

如果新版本出现问题，可以快速回滚：

```bash
# 1. 恢复旧插件
git checkout HEAD~1 -- apisix/plugins/

# 2. 恢复旧 ctx.lua
git checkout HEAD~1 -- apisix/core/ctx.lua

# 3. 恢复旧配置
git checkout HEAD~1 -- conf/config-default.yaml

# 4. 重启 APISIX
apisix reload
```

---

## 十一、总结

### 改动对比

| 项目 | 改动前 | 改动后 |
|------|--------|--------|
| ctx.lua | 174 行修改 | 零修改 |
| 插件位置 | apisix/plugins/ | /opt/unifra-apisix/ |
| 配置 | 硬编码 | 外部 YAML |
| APISIX 升级 | 几乎不可能 | 直接 merge |
| 代码结构 | 分散 | 集中 |
| 可测试性 | 差 | 好 |

### 风险评估

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| 功能遗漏 | 中 | 高 | 完整的测试清单 |
| 性能下降 | 低 | 中 | 压力测试验证 |
| APISIX API 变化 | 低 | 低 | 跑测试，按需修复 |

### 实施时间

| 阶段 | 时间 |
|------|------|
| Phase 1: 准备 | 1-2 天 |
| Phase 2: 迁移插件 | 2-3 天 |
| Phase 3: 恢复原版 | 1 天 |
| Phase 4: 测试 | 2-3 天 |
| Phase 5: 上线 | 1-2 天 |
| **总计** | **7-11 天** |
