# Unifra APISIX Fork 改动文档

## 概述

本文档记录了 Unifra 对 Apache APISIX 的所有自定义改动。该 fork 主要用于支持区块链 JSON-RPC 代理服务。

### Fork 信息

| 项目 | 值 |
|------|-----|
| Fork 时间 | 2023-01-11 |
| 基础版本 | Apache APISIX master (commit `cbf2297c`) |
| 合并提交 | `59388135` |
| 自定义提交数 | 107 个 |
| 仓库地址 | git@github.com:unifralabs/apisix.git |

---

## 一、核心文件修改

### 1.1 apisix/core/ctx.lua - JSON-RPC 请求解析

**改动目的**: 添加 JSON-RPC 协议支持，解析请求中的方法名。

**主要改动**:

```lua
-- 新增常量
local JSONRPC_DEFAULT_MAX_SIZE     = 1048576 -- 1MiB
local JSONRPC_REQ_METHOD_KEY       = "method"
local JSONRPC_REQ_PARAMS           = "params"
local JSONRPC_REQ_METHOD_HTTP_POST = "POST"
local JSONRPC_REQ_MIME_JSON        = "application/json"
```

**新增功能**:

1. **单请求解析**: 解析 `{"method": "eth_blockNumber", ...}` 格式
2. **批量请求解析**: 解析 `[{"method": "eth_blockNumber"}, {"method": "eth_getBalance"}]` 格式
3. **注册变量**:
   - `jsonrpc_method`: 单个方法名，批量请求时为 `"batch"`
   - `jsonrpc_methods`: 批量请求时的方法数组

**新增函数**:

```lua
-- 判断是否为数组
local function isArray(t)
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then return false end
    end
    return true
end

-- JSON-RPC 数据获取
local fetch_jsonrpc_data = {
    [JSONRPC_REQ_METHOD_HTTP_POST] = function(request_context, max_request_size)
        -- 解析单个请求或批量请求
        -- 返回 { method = "xxx", methods = {...} }
    end
}
```

### 1.2 apisix/utils/log-util.lua - 日志工具

**改动目的**: 支持自定义日志格式和响应体记录。

**主要改动**:
- 代码格式化调整
- 支持 `resp_body` 变量注册
- 添加 `ngx.re` 模块引用

### 1.3 apisix/cli/ngx_tpl.lua - Nginx 模板

**改动目的**: 配置调整以支持自定义功能。

---

## 二、自定义插件

### 2.1 calculate-cu - 计算单元计算器

**文件**: `apisix/plugins/calculate-cu.lua`

**优先级**: 1012

**功能**: 根据 JSON-RPC 方法计算请求的 Compute Unit (CU)。

**Schema**:
```lua
{
    type = "object",
    properties = {
        methods = {
            type = "object",
            patternProperties = {
                ["^[a-zA-Z_][a-zA-Z0-9_]*$"] = { type = "integer", minimum = 1 }
            }
        }
    }
}
```

**配置示例**:
```yaml
plugins:
  - name: calculate-cu
    config:
      methods:
        eth_call: 2
        eth_getLogs: 5
        debug_traceTransaction: 10
```

**工作原理**:
1. 从 `ctx.var["jsonrpc_method"]` 获取方法名
2. 如果是批量请求 (`method == "batch"`)，遍历 `ctx.var["jsonrpc_methods"]` 累加 CU
3. 将结果存入 `ctx.var["cu"]`

---

### 2.2 limit-cu - CU 速率限制

**文件**:
- `apisix/plugins/limit-cu.lua` (入口)
- `apisix/plugins/limit-cu/init.lua` (核心逻辑)
- `apisix/plugins/limit-cu/limit-cu-redis.lua` (Redis 实现)
- `apisix/plugins/limit-cu/limit-cu-redis-cluster.lua` (Redis Cluster 实现)

**优先级**: 1010

**功能**: 基于 CU 的速率限制，支持本地、Redis、Redis Cluster 三种策略。

**Schema**:
```lua
{
    type = "object",
    properties = {
        count = { type = "string", default = "$seconds_quota" },  -- 支持变量
        time_window = { type = "integer", exclusiveMinimum = 0 },
        group = { type = "string" },
        key = { type = "string", default = "remote_addr" },
        key_type = {
            type = "string",
            enum = { "var", "var_combination", "constant" },
            default = "var"
        },
        rejected_code = { type = "integer", default = 503 },
        rejected_msg = { type = "string" },
        policy = {
            type = "string",
            enum = { "local", "redis", "redis-cluster" },
            default = "local"
        },
        allow_degradation = { type = "boolean", default = false },
        show_limit_quota_header = { type = "boolean", default = true },
        -- Redis 配置
        redis_host = { type = "string" },
        redis_port = { type = "integer", default = 6379 },
        redis_password = { type = "string" },
        redis_database = { type = "integer", default = 0 },
        redis_timeout = { type = "integer", default = 1000 },
        -- Redis Cluster 配置
        redis_cluster_nodes = { type = "array" },
        redis_cluster_name = { type = "string" }
    },
    required = { "count", "time_window" }
}
```

**配置示例**:
```yaml
plugins:
  - name: limit-cu
    config:
      count: "$seconds_quota"  # 从 consumer 变量获取
      time_window: 1
      key: "consumer_name"
      policy: "redis"
      redis_host: "127.0.0.1"
      redis_port: 6379
```

**工作原理**:
1. 从 `ctx.var["cu"]` 获取当前请求的 CU 值
2. 根据配置的 key 生成限流键
3. 循环调用 `lim:incoming()` 消耗 CU
4. 超限返回配置的错误码

---

### 2.3 limit-monthly-cu - 月度配额限制

**文件**: `apisix/plugins/limit-monthly-cu.lua`

**优先级**: 1011

**功能**: 限制用户月度 CU 使用量。

**Schema**:
```lua
{
    type = "object",
    properties = {
        monthly_quota = { type = "string", default = "$monthly_quota" },
        monthly_used = { type = "string", default = "$monthly_used" }
    },
    required = { "monthly_quota", "monthly_used" }
}
```

**配置示例**:
```yaml
plugins:
  - name: limit-monthly-cu
    config:
      monthly_quota: "$monthly_quota"
      monthly_used: "$monthly_used"
```

**工作原理**:
1. 从上下文变量获取月度配额和已用量
2. 如果 `monthly_used >= monthly_quota`，返回 429 错误

---

### 2.4 whitelist - JSON-RPC 方法白名单

**文件**: `apisix/plugins/whitelist.lua`

**优先级**: 1900

**功能**: 控制 JSON-RPC 方法的访问权限，区分免费用户和付费用户。

**Schema**:
```lua
{
    type = "object",
    properties = {
        default_paid_quota = {
            description = "default paid quota",
            type = "integer",
            default = 1000000
        }
    },
    required = { "default_paid_quota" }
}
```

**支持的区块链网络**:

| 网络类型 | 网络名称 |
|---------|---------|
| 以太坊 | eth-mainnet, eth-sepolia |
| Polygon | polygon-mainnet |
| Conflux | cfx-core, cfx-core-testnet, cfx-espace, cfx-espace-testnet |
| Arbitrum | arb-mainnet |
| Optimism | opt-mainnet, op-testnet, op-mainnet |
| Scroll | scroll-alpha, scroll-testnet, scroll-mainnet |
| Merlin | merlin-testnet, merlin-mainnet |
| Nervos CKB | ckb-mirana |
| Starknet | starknet-mainnet, starknet-testnet |
| Base | base-mainnet, base-testnet |
| zkSync Era | zksync-era-mainnet, zksync-era-testnet |
| Linea | linea-mainnet, linea-testnet |
| ZetaChain | zetachain-evm-athens-testnet, 等 |
| Sophon | sophon-mainnet, sophon-testnet |
| XLayer | xlayer-mainnet |
| DogeOS | dogeos-mainnet, dogeos-testnet |

**方法分类**:

**免费方法 (所有用户可用)**:
```lua
-- web3 方法
"web3_clientVersion", "web3_sha3"

-- net 方法
"net_version", "net_listening"

-- eth 方法 (约 40 个)
"eth_blockNumber", "eth_getBlockByHash", "eth_getBlockByNumber",
"eth_getTransactionByHash", "eth_getTransactionReceipt",
"eth_getBalance", "eth_getCode", "eth_call", "eth_getLogs",
"eth_gasPrice", "eth_estimateGas", "eth_chainId", ...
```

**付费方法 (仅付费用户可用)**:
```lua
-- trace 方法
"trace_call", "trace_callMany", "trace_block", "trace_transaction",
"trace_filter", "trace_get", "trace_rawTransaction", ...

-- debug 方法
"debug_traceBlockByHash", "debug_traceBlockByNumber",
"debug_traceTransaction", "debug_traceCall", "debug_traceCallMany",
"debug_getRawReceipts"
```

**工作原理**:
1. 从请求 host 提取网络名称 (例如 `eth-mainnet.unifra.io` -> `eth-mainnet`)
2. 检查方法是否在该网络的白名单中
3. 如果是付费方法，检查用户的 `monthly_quota` 是否超过 `default_paid_quota`
4. 不满足条件返回 405 错误

---

### 2.5 custom-ctx-var - 自定义上下文变量

**文件**: `apisix/plugins/custom-ctx-var.lua`

**优先级**: 24000 (最高优先级之一)

**功能**: 注册全局自定义变量到请求上下文。

**Schema**:
```lua
{
    type = "object",
    description = "Key-value pairs for the variables to register",
    additionalProperties = true
}
```

**配置示例**:
```yaml
plugins:
  - name: custom-ctx-var
    config:
      network: "eth-mainnet"
      tier: "free"
```

**工作原理**:
```lua
function _M.access(conf, ctx)
    for k, v in pairs(conf) do
        ctx.var[k] = v
    end
end
```

---

### 2.6 env-to-ctx - 环境变量注入

**文件**: `apisix/plugins/env-to-ctx.lua`

**优先级**: 1001

**功能**: 将系统环境变量注入到请求上下文。

**Schema**:
```lua
{
    type = "object",
    args = {
        type = "object",
        description = "specify args need to parse"
    }
}
```

**配置示例**:
```yaml
plugins:
  - name: env-to-ctx
    config:
      args:
        redis_host: "REDIS_HOST"
        redis_port: "REDIS_PORT"
```

**工作原理**:
```lua
function _M.access(conf, ctx)
    for arg_name, arg_value in pairs(conf.args) do
        ctx.var[arg_name] = os.getenv(arg_value)
    end
end
```

---

### 2.7 guard - 紧急阻断插件

**文件**: `apisix/plugins/guard.lua`

**优先级**: 50

**功能**: 紧急情况下阻断所有请求。

**Schema**:
```lua
{
    type = "object",
    properties = {
        error_code = {
            type = "integer",
            minimum = 100, maximum = 599,
            default = 403
        },
        error_message = {
            type = "object",
            properties = {
                jsonrpc = { type = "string", default = "2.0" },
                error = {
                    type = "object",
                    properties = {
                        code = { type = "integer", default = -32603 },
                        message = { type = "string", default = "Invalid Request" }
                    }
                }
            }
        }
    }
}
```

**配置示例**:
```yaml
plugins:
  - name: guard
    config:
      error_code: 503
      error_message:
        jsonrpc: "2.0"
        error:
          code: -32603
          message: "Service temporarily unavailable"
```

---

### 2.8 path-key-extractor - 路径 Key 提取

**文件**: `apisix/plugins/path-key-extractor.lua`

**功能**: 从 URL 路径中提取 API Key。

---

### 2.9 ws-jsonrpc-proxy - WebSocket JSON-RPC 代理

**文件**: `apisix/plugins/ws-jsonrpc-proxy.lua`

**优先级**: 999

**功能**: 代理 WebSocket 连接，对每条消息应用速率限制和访问控制。

**开发时间**: 2024 年 11 月 (最新开发)

**架构**:
1. WebSocket 握手阶段：正常 APISIX 插件运行 (key-auth, custom-ctx-var 等)
2. 握手后：该插件成为中间人代理
3. 对每条 JSON-RPC 消息：手动注入变量并调用其他插件

**主要功能**:
- 解析 WebSocket 消息中的 JSON-RPC 请求
- 支持单个请求和批量请求
- 调用 calculate-cu 计算 CU
- 调用 limit-cu 进行速率限制
- 转发请求到上游并返回响应

---

## 三、配置文件修改

### 3.1 conf/config-default.yaml

**改动**: 添加自定义插件到插件列表

```yaml
plugins:
  - calculate-cu
  - limit-cu
  - limit-monthly-cu
  - whitelist
  - custom-ctx-var
  - env-to-ctx
  - guard
  - path-key-extractor
  - ws-jsonrpc-proxy
```

### 3.2 conf/config.yaml

**主要改动**:
- 修改默认端口为 80, 443
- 配置 etcd 连接信息
- 配置 Dashboard
- 启用自定义插件

---

## 四、请求处理流程

```
┌─────────────────────────────────────────────────────────────────┐
│                        HTTP/WebSocket 请求                        │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  1. custom-ctx-var (优先级: 24000)                               │
│     - 注册全局变量到 ctx.var                                      │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  2. whitelist (优先级: 1900)                                     │
│     - 检查方法是否在白名单                                         │
│     - 检查用户是否为付费用户                                       │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  3. calculate-cu (优先级: 1012)                                  │
│     - 根据方法计算 CU                                             │
│     - 批量请求累加所有方法的 CU                                    │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  4. limit-monthly-cu (优先级: 1011)                              │
│     - 检查月度配额                                                │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  5. limit-cu (优先级: 1010)                                      │
│     - 基于 CU 的速率限制                                          │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  6. env-to-ctx (优先级: 1001)                                    │
│     - 注入环境变量                                                │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  7. ws-jsonrpc-proxy (优先级: 999) [仅 WebSocket]                │
│     - WebSocket 消息级别的处理                                    │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│                          上游节点                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 五、Git 提交历史分类

### 5.1 核心功能开发

| 提交 | 日期 | 描述 |
|------|------|------|
| `3ce33947` | 2022-12-23 | add jsonrpc support (首个自定义提交) |
| `470cc83d` | 2023-01 | feat(jsonrpc router): decode single/batch json rpc requests |
| `9659578c` | 2023-01 | feat(limit-cu): rate limiter by cu, support batch requests |
| `993f25f4` | 2023-01 | feat(calculate-cu): cu calculator based on jsonrpc method |
| `73f239f6` | 2023-01 | feat(limit-monthly-cu): limit consumer monthly cu |
| `635118c1` | 2023-01 | feat(custom-ctx-var): add custom-ctx-var plugin |
| `f78647c9` | 2023-01 | feat: add whitelist plugin |
| `94ddb94e` | 2024-11 | feat(ws-jsonrpc-proxy): add WebSocket JSON-RPC proxy plugin |

### 5.2 网络支持扩展

| 提交 | 日期 | 网络 |
|------|------|------|
| `8fcdf71f` | 2023-02 | starknet |
| `0ea46975` | 2023-03 | scroll-alpha |
| `8fe26857` | 2023-05 | cfx-testnet, zksync-era, linea |
| `aa8b3ba3` | 2023-08 | base mainnet |
| `f8325cfb` | 2023-09 | scroll testnet |
| `878f7f36` | 2023-10 | zetachain |
| `f5b94c1c` | 2023-11 | scroll mainnet |
| `f62a59ba` | 2024-01 | merlin |
| `0e6b5f53` | 2024-02 | optimism |
| `97b4c9e5` | 2024-06 | sophon |
| `e0b7d1b1` | 2024-07 | xlayer |
| `84b5fcab` | 2024-11 | dogeos |

### 5.3 Bug 修复

| 提交 | 描述 |
|------|------|
| `b900021a` | fix: jsonrpc empty batch & parse error |
| `5080e6af` | fix whitelist panic |
| `bd8d378c` | Fix (whitelist): Lua's string.find special characters |
| `c90e7676` | fix: panic in calculate-cu, incorrect whitelist check |
| `7e7bd7c2` | fix error message in ctx.lua |

### 5.4 WebSocket 代理开发 (2024-11)

| 提交 | 描述 |
|------|------|
| `94ddb94e` | feat(ws-jsonrpc-proxy): add WebSocket JSON-RPC proxy plugin |
| `4396e8ff` | refactor(ws-jsonrpc-proxy): update version and priority settings |
| `1fbf9477` | feat(ws-jsonrpc-proxy): skip JSON-RPC parsing for WebSocket handshake |
| `8e8220c5` | feat(ws-jsonrpc-proxy): initialize upstream configuration |
| `91fb58fc` | feat(ws-jsonrpc-proxy): enhance upstream selection logic |
| `6ed8a586` | refactor(ws-jsonrpc-proxy): streamline WebSocket connection logic |
| `1a7d4d51` | refactor(ws-jsonrpc-proxy): adjust WebSocket timeout handling |

---

## 六、与上游 APISIX 的差异

### 6.1 新增文件

```
apisix/plugins/calculate-cu.lua
apisix/plugins/custom-ctx-var.lua
apisix/plugins/env-to-ctx.lua
apisix/plugins/guard.lua
apisix/plugins/limit-cu.lua
apisix/plugins/limit-cu/init.lua
apisix/plugins/limit-cu/limit-cu-redis.lua
apisix/plugins/limit-cu/limit-cu-redis-cluster.lua
apisix/plugins/limit-monthly-cu.lua
apisix/plugins/path-key-extractor.lua
apisix/plugins/whitelist.lua
apisix/plugins/ws-jsonrpc-proxy.lua
```

### 6.2 修改文件

```
apisix/core/ctx.lua          # JSON-RPC 解析
apisix/utils/log-util.lua    # 日志工具
apisix/cli/ngx_tpl.lua       # Nginx 模板
conf/config-default.yaml     # 默认配置
conf/config.yaml             # 主配置
```

---

## 七、升级注意事项

如果需要合并上游 APISIX 的更新，需要注意以下冲突风险点：

1. **`apisix/core/ctx.lua`**: 核心修改，可能与上游变更冲突
2. **`apisix/utils/log-util.lua`**: 日志格式修改
3. **`conf/config-default.yaml`**: 插件列表配置
4. **插件优先级**: 确保自定义插件优先级不与新插件冲突

---

## 八、附录

### A. 完整提交列表

```bash
# 查看所有自定义提交
git log --oneline --no-merges 59388135..HEAD
```

### B. 文件差异

```bash
# 查看与 fork 点的所有差异
git diff 59388135..HEAD --stat

# 查看特定文件差异
git diff 59388135..HEAD -- apisix/core/ctx.lua
```

### C. 相关文档

- [Apache APISIX 官方文档](https://apisix.apache.org/docs/)
- [Unifra API 文档](https://docs.unifra.io)
