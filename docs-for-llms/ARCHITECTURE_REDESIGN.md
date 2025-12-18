# Unifra JSON-RPC Gateway 架构重设计方案

## 一、第一性原理分析

### 1.1 核心业务需求

从业务本质出发，Unifra 需要的是一个 **区块链 JSON-RPC 网关**，核心功能是：

| 需求 | 描述 | 优先级 |
|------|------|--------|
| JSON-RPC 代理 | HTTP 和 WebSocket 协议支持 | P0 |
| 多链支持 | 30+ 区块链网络，统一入口 | P0 |
| 方法级访问控制 | 白名单、免费/付费区分 | P0 |
| 速率限制 | 基于 Compute Unit (CU) 的限流 | P0 |
| 月度配额 | 用户级别使用量限制 | P0 |
| 负载均衡 | 多节点负载均衡、健康检查 | P1 |
| 认证 | API Key 认证 | P1 |
| 监控 | 请求日志、指标采集 | P2 |

### 1.2 技术约束

- **高性能**: 区块链 RPC 请求量大，延迟敏感
- **可维护**: 能够独立升级网关和业务逻辑
- **可扩展**: 易于添加新链、新方法

### 1.3 当前架构问题

```
问题根源: 将 "业务逻辑" 和 "基础设施" 强耦合

当前:
┌─────────────────────────────────────────────────────────┐
│                    APISIX (修改版)                       │
│  ┌─────────────────────────────────────────────────┐   │
│  │  ctx.lua (核心修改)                              │   │
│  │  - JSON-RPC 解析逻辑                            │   │
│  │  - 变量注册                                     │   │
│  └─────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────┐   │
│  │  自定义插件 (混在官方插件中)                      │   │
│  │  - whitelist, calculate-cu, limit-cu, etc.      │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘

问题:
1. ctx.lua 修改导致无法升级 APISIX
2. 插件之间强耦合 (ws-jsonrpc-proxy 手动调用其他插件)
3. 业务逻辑分散在多个插件中
4. Lua 不是团队熟悉的语言 (假设)
```

---

## 二、技术方案评估

### 方案 A: 继续使用 APISIX，更好解耦

**思路**: 利用 APISIX 原生扩展机制

```
┌─────────────────────────────────────────────────────────┐
│                    APISIX (原版)                         │
│  extra_lua_path → /opt/unifra-plugins/                  │
└─────────────────────────────────────────────────────────┘
```

**优点**:
- 改动最小
- 复用现有代码

**缺点**:
- WebSocket 消息级处理仍需深度集成
- Lua 开发体验差
- 本质问题未解决

**评分**: ⭐⭐ (2/5)

---

### 方案 B: APISIX + 外部服务 (Sidecar)

**思路**: JSON-RPC 业务逻辑放到独立服务

```
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│     Client      │ ──→  │  Unifra Service │ ──→  │     APISIX      │
│                 │      │  (Go/Rust)      │      │   (原版)        │
│                 │      │  - 解析 JSONRPC │      │   - 负载均衡    │
│                 │      │  - 限流/白名单  │      │   - 健康检查    │
└─────────────────┘      └─────────────────┘      └─────────────────┘
                                                           │
                                                           ▼
                                                  ┌─────────────────┐
                                                  │ Blockchain Node │
                                                  └─────────────────┘
```

**优点**:
- APISIX 保持原版，可升级
- 业务逻辑用熟悉的语言

**缺点**:
- 两跳延迟
- 架构变复杂
- 需要维护两套系统

**评分**: ⭐⭐⭐ (3/5)

---

### 方案 C: 专用 JSON-RPC Gateway (Go)

**思路**: 用 Go 重写一个专门的 JSON-RPC 网关

**参考项目**:
- [scroll-tech/rpc-gateway](https://github.com/scroll-tech/rpc-gateway) (Confura fork)
- [gochain/rpc-proxy](https://github.com/gochain/rpc-proxy)

```
┌─────────────────────────────────────────────────────────┐
│              Unifra RPC Gateway (Go)                    │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Core                                            │   │
│  │  - HTTP/WebSocket Server                         │   │
│  │  - JSON-RPC Parser                               │   │
│  │  - Request Router                                │   │
│  └─────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Middleware Pipeline                             │   │
│  │  - Auth (API Key)                                │   │
│  │  - Whitelist                                     │   │
│  │  - CU Calculator                                 │   │
│  │  - Rate Limiter                                  │   │
│  │  - Monthly Quota                                 │   │
│  └─────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Upstream Manager                                │   │
│  │  - 节点池管理                                    │   │
│  │  - 健康检查                                      │   │
│  │  - 负载均衡                                      │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

**优点**:
- 完全控制，针对 JSON-RPC 优化
- Go 生态成熟，团队可能更熟悉
- 单一服务，架构简单
- 有成熟参考实现

**缺点**:
- 需要重新实现负载均衡、健康检查等
- 开发工作量较大

**评分**: ⭐⭐⭐⭐ (4/5)

---

### 方案 D: Envoy + WASM Filter

**思路**: 用 Envoy 作为基础，Go/Rust 写 WASM 插件

```
┌─────────────────────────────────────────────────────────┐
│                      Envoy Proxy                        │
│  ┌─────────────────────────────────────────────────┐   │
│  │  WASM Filter (Go/Rust)                           │   │
│  │  - JSON-RPC 解析                                 │   │
│  │  - 业务逻辑                                      │   │
│  └─────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────┐   │
│  │  原生功能                                        │   │
│  │  - 负载均衡、健康检查、熔断                      │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

**优点**:
- Envoy 功能强大，生态好
- WASM 插件可独立开发部署
- 高性能

**缺点**:
- WASM 开发体验一般
- WebSocket + WASM 支持有限
- 学习曲线陡峭

**评分**: ⭐⭐⭐ (3/5)

---

### 方案 E: 混合架构 (推荐)

**思路**: Go 处理 JSON-RPC 业务逻辑，反向代理处理基础设施

```
┌─────────────────────────────────────────────────────────────────┐
│                    Unifra RPC Gateway (Go)                      │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │  HTTP/WebSocket Handler                                    │ │
│  │  - 接收请求                                                │ │
│  │  - 解析 JSON-RPC                                           │ │
│  │  - 执行中间件链                                            │ │
│  └───────────────────────────────────────────────────────────┘ │
│                              │                                  │
│  ┌───────────────────────────▼───────────────────────────────┐ │
│  │  Middleware Chain                                          │ │
│  │  ┌─────────┐ ┌───────────┐ ┌────────┐ ┌─────────────────┐ │ │
│  │  │  Auth   │→│ Whitelist │→│  CU    │→│   Rate Limit    │ │ │
│  │  └─────────┘ └───────────┘ └────────┘ └─────────────────┘ │ │
│  └───────────────────────────────────────────────────────────┘ │
│                              │                                  │
│  ┌───────────────────────────▼───────────────────────────────┐ │
│  │  Upstream Manager                                          │ │
│  │  - 连接池管理 (HTTP + WebSocket)                           │ │
│  │  - 健康检查                                                │ │
│  │  - 负载均衡 (一致性哈希 / Round Robin)                     │ │
│  │  - 自动重试                                                │ │
│  └───────────────────────────────────────────────────────────┘ │
│                              │                                  │
└──────────────────────────────┼──────────────────────────────────┘
                               │
            ┌──────────────────┼──────────────────┐
            │                  │                  │
            ▼                  ▼                  ▼
    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
    │  Node Pool  │    │  Node Pool  │    │  Node Pool  │
    │ eth-mainnet │    │  polygon    │    │   scroll    │
    └─────────────┘    └─────────────┘    └─────────────┘
```

**评分**: ⭐⭐⭐⭐⭐ (5/5)

---

## 三、推荐方案详细设计

### 3.1 架构总览

```
                              ┌─────────────────────────────────────┐
                              │           Control Plane             │
                              │  - 配置管理 (etcd/consul/file)       │
                              │  - 网络/方法白名单配置               │
                              │  - CU 定价配置                       │
                              │  - 节点池配置                        │
                              └──────────────────┬──────────────────┘
                                                 │ watch/pull
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│                         Unifra RPC Gateway (Go)                             │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                        Request Handler                               │  │
│   │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐  │  │
│   │  │  HTTP Handler   │  │   WS Handler    │  │   gRPC Handler      │  │  │
│   │  │  (net/http)     │  │ (gorilla/ws)    │  │   (future)          │  │  │
│   │  └────────┬────────┘  └────────┬────────┘  └──────────┬──────────┘  │  │
│   └───────────┼─────────────────────┼─────────────────────┼─────────────┘  │
│               │                     │                     │                │
│               └─────────────────────┼─────────────────────┘                │
│                                     ▼                                      │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                       JSON-RPC Parser                                │  │
│   │  - 解析单请求 / 批量请求                                             │  │
│   │  - 提取 method, params, id                                           │  │
│   │  - 验证 JSON-RPC 2.0 格式                                            │  │
│   └─────────────────────────────────┬───────────────────────────────────┘  │
│                                     ▼                                      │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                       Middleware Chain                               │  │
│   │                                                                      │  │
│   │  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────────────┐  │  │
│   │  │  Auth    │ → │ Network  │ → │ Method   │ → │  CU Calculator   │  │  │
│   │  │          │   │ Resolver │   │ Whitelist│   │                  │  │  │
│   │  └──────────┘   └──────────┘   └──────────┘   └──────────────────┘  │  │
│   │       │                                              │              │  │
│   │       ▼                                              ▼              │  │
│   │  ┌──────────┐                                 ┌──────────────────┐  │  │
│   │  │ Consumer │                                 │   Rate Limiter   │  │  │
│   │  │  Loader  │                                 │  (per-second)    │  │  │
│   │  └──────────┘                                 └──────────────────┘  │  │
│   │                                                      │              │  │
│   │                                                      ▼              │  │
│   │                                               ┌──────────────────┐  │  │
│   │                                               │  Monthly Quota   │  │  │
│   │                                               │   Checker        │  │  │
│   │                                               └──────────────────┘  │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                     │                                      │
│                                     ▼                                      │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                       Upstream Manager                               │  │
│   │                                                                      │  │
│   │  ┌───────────────────────────────────────────────────────────────┐  │  │
│   │  │  Node Pool Manager                                             │  │  │
│   │  │  - eth-mainnet: [node1, node2, node3]                         │  │  │
│   │  │  - polygon: [node1, node2]                                    │  │  │
│   │  │  - scroll: [node1]                                            │  │  │
│   │  └───────────────────────────────────────────────────────────────┘  │  │
│   │                                                                      │  │
│   │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐  │  │
│   │  │  Health Check   │  │  Load Balancer  │  │   Connection Pool   │  │  │
│   │  │  - 周期性检查    │  │  - 一致性哈希    │  │   - HTTP Keep-Alive │  │  │
│   │  │  - 自动摘除      │  │  - Round Robin  │  │   - WS 连接复用     │  │  │
│   │  └─────────────────┘  └─────────────────┘  └─────────────────────┘  │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                     │                                      │
└─────────────────────────────────────┼──────────────────────────────────────┘
                                      │
                                      ▼
                    ┌─────────────────────────────────────┐
                    │         Blockchain Nodes            │
                    └─────────────────────────────────────┘
```

### 3.2 核心模块设计

#### 3.2.1 JSON-RPC Parser

```go
// pkg/jsonrpc/parser.go

type Request struct {
    JSONRPC string          `json:"jsonrpc"`
    Method  string          `json:"method"`
    Params  json.RawMessage `json:"params,omitempty"`
    ID      interface{}     `json:"id,omitempty"`
}

type BatchRequest []Request

type ParseResult struct {
    IsBatch  bool
    Requests []Request
    Methods  []string  // 快速访问所有方法名
    RawBody  []byte    // 原始请求体，用于转发
}

func Parse(body []byte) (*ParseResult, error) {
    // 1. 尝试解析为数组 (batch)
    // 2. 尝试解析为对象 (single)
    // 3. 验证 JSON-RPC 2.0 格式
}
```

#### 3.2.2 Middleware Interface

```go
// pkg/middleware/middleware.go

type Context struct {
    // 请求信息
    Network     string        // eth-mainnet, polygon, etc.
    ParseResult *ParseResult  // JSON-RPC 解析结果

    // 用户信息 (Auth 后填充)
    Consumer    *Consumer
    APIKey      string

    // 计算结果 (CU Calculator 后填充)
    TotalCU     int

    // 控制流
    Abort       bool
    AbortCode   int
    AbortBody   interface{}
}

type Middleware interface {
    Name() string
    Process(ctx *Context) error
}

type Chain struct {
    middlewares []Middleware
}

func (c *Chain) Execute(ctx *Context) error {
    for _, m := range c.middlewares {
        if err := m.Process(ctx); err != nil {
            return err
        }
        if ctx.Abort {
            return nil
        }
    }
    return nil
}
```

#### 3.2.3 Whitelist Middleware

```go
// pkg/middleware/whitelist.go

type WhitelistConfig struct {
    Networks map[string]NetworkConfig `yaml:"networks"`
}

type NetworkConfig struct {
    FreeMethods []string `yaml:"free_methods"`
    PaidMethods []string `yaml:"paid_methods"`
}

type WhitelistMiddleware struct {
    config *WhitelistConfig
}

func (w *WhitelistMiddleware) Process(ctx *Context) error {
    networkCfg, ok := w.config.Networks[ctx.Network]
    if !ok {
        ctx.Abort = true
        ctx.AbortCode = 400
        ctx.AbortBody = jsonrpcError(-32600, "Unsupported network")
        return nil
    }

    for _, method := range ctx.ParseResult.Methods {
        if !w.isAllowed(networkCfg, method, ctx.Consumer.IsPaid) {
            ctx.Abort = true
            ctx.AbortCode = 405
            ctx.AbortBody = jsonrpcError(-32601,
                fmt.Sprintf("Method %s not allowed", method))
            return nil
        }
    }
    return nil
}
```

#### 3.2.4 CU Calculator

```go
// pkg/middleware/cu_calculator.go

type CUConfig struct {
    DefaultCU int            `yaml:"default_cu"`
    Methods   map[string]int `yaml:"methods"`
}

type CUCalculatorMiddleware struct {
    config *CUConfig
}

func (c *CUCalculatorMiddleware) Process(ctx *Context) error {
    totalCU := 0
    for _, method := range ctx.ParseResult.Methods {
        cu, ok := c.config.Methods[method]
        if !ok {
            cu = c.config.DefaultCU
        }
        totalCU += cu
    }
    ctx.TotalCU = totalCU
    return nil
}
```

#### 3.2.5 Rate Limiter

```go
// pkg/middleware/rate_limiter.go

type RateLimiterMiddleware struct {
    redis  *redis.Client
    config *RateLimitConfig
}

func (r *RateLimiterMiddleware) Process(ctx *Context) error {
    key := fmt.Sprintf("ratelimit:%s:%d",
        ctx.Consumer.ID,
        time.Now().Unix())

    // 使用 Redis INCRBY 原子操作
    newCount, err := r.redis.IncrBy(ctx, key, int64(ctx.TotalCU)).Result()
    if err != nil {
        // 降级处理
        if r.config.AllowOnError {
            return nil
        }
        return err
    }

    // 设置过期时间
    r.redis.Expire(ctx, key, time.Second)

    if newCount > int64(ctx.Consumer.SecondsQuota) {
        ctx.Abort = true
        ctx.AbortCode = 429
        ctx.AbortBody = jsonrpcError(-32000, "Rate limit exceeded")
    }
    return nil
}
```

#### 3.2.6 Upstream Manager

```go
// pkg/upstream/manager.go

type Node struct {
    Host     string
    Port     int
    Healthy  bool
    Weight   int
    LastCheck time.Time
}

type NodePool struct {
    Network string
    Nodes   []*Node
    mu      sync.RWMutex
}

type Manager struct {
    pools    map[string]*NodePool
    balancer Balancer
    checker  *HealthChecker
}

func (m *Manager) GetNode(network string) (*Node, error) {
    pool, ok := m.pools[network]
    if !ok {
        return nil, fmt.Errorf("unknown network: %s", network)
    }

    pool.mu.RLock()
    defer pool.mu.RUnlock()

    healthyNodes := filterHealthy(pool.Nodes)
    if len(healthyNodes) == 0 {
        return nil, fmt.Errorf("no healthy nodes for %s", network)
    }

    return m.balancer.Pick(healthyNodes), nil
}
```

#### 3.2.7 WebSocket Handler

```go
// pkg/handler/websocket.go

type WSHandler struct {
    chain    *middleware.Chain
    upstream *upstream.Manager
}

func (h *WSHandler) Handle(w http.ResponseWriter, r *http.Request) {
    // 1. 升级连接
    clientConn, err := upgrader.Upgrade(w, r, nil)
    if err != nil {
        return
    }
    defer clientConn.Close()

    // 2. 建立上游连接
    network := extractNetwork(r.Host)
    node, err := h.upstream.GetNode(network)
    if err != nil {
        return
    }

    upstreamConn, _, err := websocket.DefaultDialer.Dial(
        fmt.Sprintf("ws://%s:%d", node.Host, node.Port), nil)
    if err != nil {
        return
    }
    defer upstreamConn.Close()

    // 3. 双向代理，每条消息执行中间件
    go h.proxyUpstreamToClient(upstreamConn, clientConn)
    h.proxyClientToUpstream(clientConn, upstreamConn, network)
}

func (h *WSHandler) proxyClientToUpstream(client, upstream *websocket.Conn, network string) {
    for {
        _, message, err := client.ReadMessage()
        if err != nil {
            return
        }

        // 解析并执行中间件
        parsed, err := jsonrpc.Parse(message)
        if err != nil {
            // 直接转发无效消息或返回错误
            continue
        }

        ctx := &middleware.Context{
            Network:     network,
            ParseResult: parsed,
        }

        if err := h.chain.Execute(ctx); err != nil || ctx.Abort {
            // 返回错误响应
            resp, _ := json.Marshal(ctx.AbortBody)
            client.WriteMessage(websocket.TextMessage, resp)
            continue
        }

        // 转发到上游
        upstream.WriteMessage(websocket.TextMessage, message)
    }
}
```

### 3.3 配置设计

```yaml
# config.yaml

server:
  http_port: 8080
  https_port: 8443
  metrics_port: 9090

auth:
  type: api_key  # api_key, jwt
  header: X-API-Key

networks:
  eth-mainnet:
    nodes:
      - host: eth-node-1.internal
        port: 8545
        weight: 100
      - host: eth-node-2.internal
        port: 8545
        weight: 100
    health_check:
      interval: 10s
      timeout: 5s
      method: eth_blockNumber
    whitelist:
      free:
        - eth_blockNumber
        - eth_getBalance
        - eth_call
        # ... 更多方法
      paid:
        - debug_traceTransaction
        - trace_block
        # ... 更多方法

  polygon-mainnet:
    nodes:
      - host: polygon-node-1.internal
        port: 8545
    whitelist:
      free:
        - eth_*
        - bor_*
      paid:
        - trace_*

cu_pricing:
  default: 1
  methods:
    eth_getLogs: 5
    debug_traceTransaction: 20
    trace_block: 50

rate_limit:
  storage: redis  # redis, memory
  redis:
    addr: localhost:6379
    password: ""
    db: 0

monthly_quota:
  storage: postgres
  table: consumer_quotas
```

### 3.4 数据流

```
HTTP Request
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  1. Network Resolution                                  │
│     eth-mainnet.unifra.io → network = "eth-mainnet"     │
└─────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  2. JSON-RPC Parsing                                    │
│     {"method": "eth_call", ...}                         │
│     → ParseResult{Methods: ["eth_call"], IsBatch: false}│
└─────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  3. Auth Middleware                                     │
│     X-API-Key: xxx → Consumer{ID: "user1", Tier: "paid"}│
└─────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  4. Whitelist Middleware                                │
│     eth_call ∈ FreeMethods → PASS                       │
└─────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  5. CU Calculator                                       │
│     eth_call → CU = 2                                   │
└─────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  6. Rate Limiter                                        │
│     INCRBY ratelimit:user1:1702000000 2                 │
│     current = 50, limit = 100 → PASS                    │
└─────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  7. Monthly Quota                                       │
│     used = 500000, quota = 1000000 → PASS               │
└─────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  8. Upstream Forward                                    │
│     Pick node: eth-node-1:8545                          │
│     Forward request, return response                    │
└─────────────────────────────────────────────────────────┘
```

---

## 四、迁移计划

### Phase 1: 并行运行 (2-4 周)

```
                    ┌─────────────────┐
                    │  Load Balancer  │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │ 90%          │              │ 10%
              ▼              │              ▼
    ┌─────────────────┐      │    ┌─────────────────┐
    │  APISIX (现有)   │      │    │  New Gateway    │
    │                 │      │    │  (Go)           │
    └─────────────────┘      │    └─────────────────┘
                             │
```

1. 开发新网关核心功能
2. 10% 流量灰度
3. 对比监控指标

### Phase 2: 逐步切换 (2-4 周)

```
流量比例: 10% → 30% → 50% → 80% → 100%

监控指标:
- 延迟 P50/P99
- 错误率
- CU 计算准确性
```

### Phase 3: 下线旧系统

```
1. 100% 切换到新网关
2. 观察 1-2 周
3. 下线 APISIX
```

---

## 五、技术选型建议

### 5.1 核心依赖

| 组件 | 推荐 | 备选 |
|------|------|------|
| HTTP Server | net/http + chi | gin, echo |
| WebSocket | gorilla/websocket | nhooyr/websocket |
| JSON | encoding/json | json-iterator |
| Redis | go-redis/redis | redigo |
| Config | viper | koanf |
| Logging | zap | zerolog |
| Metrics | prometheus | - |

### 5.2 可参考的开源项目

1. **[scroll-tech/rpc-gateway](https://github.com/scroll-tech/rpc-gateway)** - Scroll 的 RPC 网关
   - 健康检查
   - 负载均衡
   - 速率限制
   - 缓存

2. **[gochain/rpc-proxy](https://github.com/gochain/rpc-proxy)** - 简单的 RPC 代理
   - 速率限制
   - 路径白名单

3. **[AxLabs/go-jsonrpc-proxy](https://github.com/AxLabs/go-jsonrpc-proxy)** - 基于方法的路由

---

## 六、风险与应对

| 风险 | 影响 | 应对措施 |
|------|------|----------|
| 新系统 bug | 服务中断 | 灰度发布，快速回滚 |
| 性能不达标 | 延迟增加 | 压测验证，性能优化 |
| 功能遗漏 | 兼容性问题 | 完整的测试用例迁移 |
| 配置迁移错误 | 访问控制失效 | 配置验证工具，对比测试 |

---

## 七、总结

### 推荐方案: 专用 Go JSON-RPC Gateway

**理由**:

1. **根本解决耦合问题** - 不再依赖 APISIX，完全自主可控
2. **针对性优化** - 专门为 JSON-RPC 设计，性能更好
3. **开发效率** - Go 生态成熟，团队更容易维护
4. **参考实现** - Scroll 等项目已验证可行性
5. **长期收益** - 减少技术债，降低维护成本

**与 APISIX 对比**:

| 维度 | APISIX | 新方案 |
|------|--------|--------|
| 升级能力 | ❌ 几乎不可能 | ✅ 自主可控 |
| 开发效率 | ❌ Lua 不熟悉 | ✅ Go 生态好 |
| JSON-RPC 支持 | ❌ 需要 hack | ✅ 原生设计 |
| WebSocket | ❌ 复杂实现 | ✅ 简单直接 |
| 运维复杂度 | ⚠️ 中等 | ✅ 单一服务 |
