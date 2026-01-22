# Unifra APISIX - Architecture Deep Dive

## Table of Contents

1. [Background and Motivation](#background-and-motivation)
2. [The Problem We Solved](#the-problem-we-solved)
3. [Zero Intrusion Architecture](#zero-intrusion-architecture)
4. [Plugin Priority System](#plugin-priority-system)
5. [Request Processing Flow](#request-processing-flow)
6. [ctx.var Caching Mechanism](#ctxvar-caching-mechanism)

---

## Background and Motivation

### What is Unifra?

Unifra is a blockchain infrastructure provider that offers JSON-RPC endpoints for various blockchain networks (Ethereum, Polygon, Arbitrum, etc.). Users access blockchain data through our API gateway, which needs to:

1. **Authenticate** requests (API key validation)
2. **Parse** JSON-RPC requests (extract method names, parameters)
3. **Control access** (whitelist allowed methods, distinguish free/paid tiers)
4. **Rate limit** (per-second limits, monthly quotas based on Compute Units)
5. **Route** to appropriate blockchain nodes

### Why Apache APISIX?

Apache APISIX is a high-performance, cloud-native API gateway built on Nginx/OpenResty. We chose it for:

- **Performance**: Handles millions of requests per second
- **Plugin architecture**: Extensible via Lua plugins
- **Cloud-native**: Works well with Kubernetes, etcd
- **Active community**: Frequent updates, good documentation

### The Original Problem

Initially, we modified APISIX source code directly to add JSON-RPC parsing capabilities. This worked, but created **174 lines of changes** to `apisix/core/ctx.lua`:

```lua
-- Original invasive modification
local _jsonrpc_cache = {}

function _M.set_vars_meta(ctx)
    -- ... 174 lines of modifications ...
    -- Custom logic to parse JSON-RPC and cache results
end
```

**Problems with this approach:**

| Issue | Impact |
|-------|--------|
| Upgrade conflicts | Every APISIX upgrade required manual merge |
| Maintenance burden | Had to track upstream changes |
| Testing complexity | Custom build needed for testing |
| Deployment risk | Modified core could introduce bugs |

---

## The Problem We Solved

We needed to:

1. **Parse JSON-RPC** requests before other plugins run
2. **Store parsed data** in a way accessible to subsequent plugins
3. **Do all this without modifying APISIX source code**

The challenge: APISIX's `ctx.var` uses a metatable with `__index` to lazily fetch nginx variables. We needed to inject our own variables without changing this mechanism.

---

## Zero Intrusion Architecture

### The Key Insight

APISIX's `ctx.var` metatable has a **cache layer**:

```lua
-- Simplified APISIX ctx.var implementation
local var_mt = {
    __index = function(t, key)
        -- First: check cache
        local val = t._cache[key]
        if val ~= nil then
            return val
        end

        -- Second: try nginx variable
        local val = ngx.var[key]
        if val ~= nil then
            t._cache[key] = val
            return val
        end

        -- Third: call registered getter
        -- ...
    end,

    __newindex = function(t, key, val)
        -- Writes go directly to cache!
        t._cache[key] = val
    end
}
```

**The breakthrough**: Writing to `ctx.var.foo = "bar"` puts data in the cache, and subsequent reads return cached values without triggering nginx variable lookup!

### Our Solution

```
┌─────────────────────────────────────────────────────────────────────┐
│                        APISIX Core (Unmodified)                      │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │                         ctx.var Cache                            ││
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌───────────────┐  ││
│  │  │ jsonrpc_method   │  │ jsonrpc_methods  │  │ unifra_network│  ││
│  │  │ = "eth_call"     │  │ = ["eth_call"]   │  │ = "eth-mainnet││  ││
│  │  └──────────────────┘  └──────────────────┘  └───────────────┘  ││
│  └─────────────────────────────────────────────────────────────────┘│
│                              ▲                                       │
│                              │ Write to cache                        │
│                              │                                       │
└──────────────────────────────┼───────────────────────────────────────┘
                               │
┌──────────────────────────────┴───────────────────────────────────────┐
│                    External Plugin (unifra-jsonrpc-var)              │
│                                                                       │
│  function rewrite(conf, ctx)                                         │
│      local body = core.request.get_body()                            │
│      local parsed = jsonrpc.parse(body)                              │
│                                                                       │
│      -- Write to ctx.var cache (no APISIX modification needed!)      │
│      ctx.var.jsonrpc_method = parsed.method                          │
│      ctx.var.jsonrpc_methods = parsed.methods                        │
│      ctx.var.unifra_network = extract_network(ctx.var.host)          │
│  end                                                                  │
└───────────────────────────────────────────────────────────────────────┘
```

### File Organization

```
unifra-apisix/                    # External directory (not in APISIX repo)
├── apisix/plugins/               # Plugin wrappers (APISIX plugin format)
│   ├── unifra-jsonrpc-var.lua    # Priority 26000 - runs first
│   ├── unifra-ctx-var.lua        # Priority 2400
│   ├── unifra-whitelist.lua      # Priority 1900
│   ├── unifra-calculate-cu.lua   # Priority 1012
│   ├── unifra-limit-cu.lua       # Priority 1011
│   ├── unifra-limit-monthly-cu.lua # Priority 1010
│   └── unifra-ws-jsonrpc-proxy.lua # Priority 999
├── unifra/jsonrpc/               # Core business logic (reusable modules)
│   ├── core.lua                  # JSON-RPC parsing
│   ├── whitelist.lua             # Access control logic
│   ├── cu.lua                    # CU calculation logic
│   └── ratelimit.lua             # Redis rate limiting
└── conf/                         # Configuration files
    ├── whitelist.yaml
    └── cu-pricing.yaml
```

### Loading External Plugins

APISIX config (`config.yaml`):

```yaml
apisix:
  # This line loads our external plugins!
  extra_lua_path: "/opt/unifra-apisix/?.lua"

plugins:
  - unifra-jsonrpc-var      # Now APISIX can find these
  - unifra-ctx-var
  # ... etc
```

---

## Plugin Priority System

APISIX runs plugins in **descending priority order** (higher number = runs earlier).

```
Request arrives
      │
      ▼
┌─────────────────────────────────────────────────────────────────┐
│  unifra-jsonrpc-var (26000)                                     │
│  - Parse JSON-RPC body                                          │
│  - Write jsonrpc_method, jsonrpc_methods, unifra_network        │
│  - Store ctx.jsonrpc for later plugins                          │
└─────────────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────────────┐
│  key-auth (2500) [APISIX built-in]                              │
│  - Validate API key                                             │
│  - Load consumer and set ctx.var.consumer_name                  │
└─────────────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────────────┐
│  unifra-ctx-var (2400)                                         │
│  - Inject consumer-specific variables                           │
│  - Set seconds_quota, monthly_quota, quota_key                  │
└─────────────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────────────┐
│  unifra-whitelist (1900)                                        │
│  - Check if method is allowed for network                       │
│  - Check free vs paid tier based on monthly_quota               │
│  - Reject if method not in whitelist                            │
└─────────────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────────────┐
│  unifra-calculate-cu (1012)                                     │
│  - Calculate total CU for all methods in request                │
│  - Store in ctx.var.cu for rate limiting                        │
└─────────────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────────────┐
│  unifra-limit-cu (1011)                                         │
│  - Per-second rate limiting via Redis                           │
│  - Uses sliding window algorithm                                │
│  - Reject if rate exceeded                                      │
└─────────────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────────────┐
│  unifra-limit-monthly-cu (1010)                                 │
│  - Check if monthly quota exceeded                              │
│  - Reject if over limit                                         │
└─────────────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────────────┐
│  proxy-rewrite, upstream selection, etc.                        │
│  - Rewrite URI if needed                                        │
│  - Select upstream node                                         │
└─────────────────────────────────────────────────────────────────┘
      │
      ▼
   Upstream
```

### Why These Priorities?

| Plugin | Priority | Reason |
|--------|----------|--------|
| unifra-jsonrpc-var | 26000 | Must parse body before anything else reads it |
| unifra-ctx-var | 2400 | Consumer vars needed for quota checks |
| unifra-whitelist | 1900 | Reject invalid methods early |
| unifra-calculate-cu | 1012 | CU needed for rate limiting |
| unifra-limit-cu | 1011 | Final rate limit check |
| unifra-limit-monthly-cu | 1010 | Monthly check after per-second |
| unifra-ws-jsonrpc-proxy | 999 | WebSocket runs in access phase, must be last |

---

## Request Processing Flow

### HTTP JSON-RPC Request

```
Client                    APISIX                         Upstream
  │                         │                               │
  │  POST /v1/abc123        │                               │
  │  {"jsonrpc":"2.0",      │                               │
  │   "method":"eth_call",  │                               │
  │   "params":[...],       │                               │
  │   "id":1}               │                               │
  │ ───────────────────────>│                               │
  │                         │                               │
  │                    ┌────┴────┐                          │
  │                    │ REWRITE │                          │
  │                    │  PHASE  │                          │
  │                    └────┬────┘                          │
  │                         │                               │
  │              unifra-jsonrpc-var                         │
  │              - Parse body                               │
  │              - ctx.var.jsonrpc_method = "eth_call"      │
  │              - ctx.var.unifra_network = "eth-mainnet"   │
  │                         │                               │
  │                    ┌────┴────┐                          │
  │                    │ ACCESS  │                          │
  │                    │  PHASE  │                          │
  │                    └────┬────┘                          │
  │                         │                               │
  │              key-auth: validate API key                 │
  │              unifra-ctx-var: set quotas                 │
  │              unifra-whitelist: check allowed            │
  │              unifra-calculate-cu: cu = 15               │
  │              unifra-limit-monthly-cu: check quota       │
  │              unifra-limit-cu: check rate                │
  │                         │                               │
  │                         │  Forward to upstream          │
  │                         │ ─────────────────────────────>│
  │                         │                               │
  │                         │  {"jsonrpc":"2.0",            │
  │                         │   "result":"0x...",           │
  │                         │   "id":1}                     │
  │                         │ <─────────────────────────────│
  │                         │                               │
  │  {"jsonrpc":"2.0",      │                               │
  │   "result":"0x...",     │                               │
  │   "id":1}               │                               │
  │ <───────────────────────│                               │
```

### WebSocket JSON-RPC

```
Client                    APISIX (WS Proxy)               Upstream
  │                         │                               │
  │  GET /v1/abc123         │                               │
  │  Upgrade: websocket     │                               │
  │ ───────────────────────>│                               │
  │                         │                               │
  │              key-auth: validate                         │
  │              unifra-ws-jsonrpc-proxy: starts            │
  │                         │                               │
  │                         │  Connect WebSocket            │
  │                         │ ─────────────────────────────>│
  │                         │                               │
  │  101 Switching          │  101 Switching                │
  │ <───────────────────────│ <─────────────────────────────│
  │                         │                               │
  │  {"method":"eth_sub.."} │                               │
  │ ───────────────────────>│                               │
  │                         │                               │
  │              Per-message checks:                        │
  │              - Parse JSON-RPC                           │
  │              - Whitelist check                          │
  │              - Rate limit check                         │
  │                         │                               │
  │                         │  Forward message              │
  │                         │ ─────────────────────────────>│
  │                         │                               │
  │                         │  {"result":"0x..."}           │
  │                         │ <─────────────────────────────│
  │                         │                               │
  │  {"result":"0x..."}     │                               │
  │ <───────────────────────│                               │
```

---

## ctx.var Caching Mechanism

### How It Works

```lua
-- APISIX creates ctx.var with this metatable
setmetatable(ctx.var, {
    __index = function(t, key)
        -- 1. Check rawget (direct table access)
        local v = rawget(t, key)
        if v ~= nil then return v end

        -- 2. Check cache
        local cache = rawget(t, "_cache")
        if cache and cache[key] ~= nil then
            return cache[key]
        end

        -- 3. Check nginx variables
        local ngx_var = ngx.var[key]
        if ngx_var then
            cache[key] = ngx_var
            return ngx_var
        end

        -- 4. Call custom getter (if registered)
        -- ...
    end,

    __newindex = function(t, key, val)
        -- Writes go to cache, NOT to nginx var
        local cache = rawget(t, "_cache") or {}
        cache[key] = val
        rawset(t, "_cache", cache)
    end
})
```

### Our Usage Pattern

```lua
-- In unifra-jsonrpc-var (runs first, priority 26000)
function _M.rewrite(conf, ctx)
    local body = core.request.get_body()
    local result = jsonrpc.parse(body)

    -- Write to cache via __newindex
    ctx.var.jsonrpc_method = result.method
    ctx.var.jsonrpc_methods = result.methods  -- Tables work too!
    ctx.var.unifra_network = extract_network(ctx.var.host)

    -- Also store in ctx for complex data
    ctx.jsonrpc = result
end

-- In unifra-whitelist (runs later, priority 1900)
function _M.access(conf, ctx)
    -- Read from cache via __index (no nginx lookup!)
    local method = ctx.var.jsonrpc_method
    local methods = ctx.var.jsonrpc_methods
    local network = ctx.var.unifra_network

    -- These were set by unifra-jsonrpc-var
    -- No body parsing needed here!
end
```

### Why This Works

1. **Plugin execution order is guaranteed** by priority
2. **ctx.var persists** throughout the request lifecycle
3. **Cache is per-request** (not shared between requests)
4. **No race conditions** (single-threaded per request)

### Limitations

- Cache is **not persistent** across requests
- **Tables in cache** work but should be read-only
- **nginx variables** (`$remote_addr`, etc.) still accessible

---

## Quota Architecture

### Shared Quota Model

Multiple API keys (apps) belonging to the same user can share a single monthly quota using `quota_key`:

```
┌─────────────────────────────────────────────────────────────────┐
│                   User Quota Sharing Architecture               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  User A (quota_key = "user-a-uuid")                             │
│  ├── App 1: apikey-1 ─┐                                         │
│  ├── App 2: apikey-2 ─┼──→ Redis: quota:monthly:user-a-uuid:*   │
│  └── App 3: apikey-3 ─┘         └── Shared 10,000,000 CU        │
│                                                                 │
│  User B (quota_key = "user-b-uuid")                             │
│  └── App 1: apikey-4 ────→ Redis: quota:monthly:user-b-uuid:*   │
│                                   └── Own 5,000,000 CU          │
│                                                                 │
│  Legacy User (no quota_key)                                     │
│  └── apikey-5 ───────────→ Redis: quota:monthly:apikey-5:*      │
│                                   └── Uses consumer_name        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Redis Key Structure

| Purpose | Key Format | Type | Expiry |
|---------|-----------|------|--------|
| Monthly quota | `quota:monthly:{quota_key}:{YYYYMM}` | String | EXPIREAT end of month |
| Per-second rate | `ratelimit:cu:sliding:{consumer}` | ZSet | Sliding window |
| Per-second CU values | `ratelimit:cu:sliding:{consumer}:values` | Hash | Sliding window |

**Note**: Monthly quota uses `quota_key` (shared), while per-second rate limiting uses `consumer_name` (per API key).

### Consumer Configuration

```json
{
  "username": "apikey-1",
  "plugins": {
    "key-auth": { "key": "apikey-1" },
    "unifra-ctx-var": {
      "quota_key": "user-a-uuid",
      "monthly_quota": "10000000",
      "seconds_quota": "100"
    }
  }
}
```

### Dashboard Integration

External dashboards can query user usage directly from Redis:

```python
def get_user_usage(user_id: str) -> dict:
    cycle_id = datetime.now().strftime("%Y%m")  # e.g., "202512"
    key = f"quota:monthly:{user_id}:{cycle_id}"
    used = int(redis.get(key) or 0)
    return {"user_id": user_id, "cycle": cycle_id, "used": used}
```

Or via Prometheus metrics:
```
unifra_consumer_monthly_used{consumer="user-a-uuid"} 850000
unifra_consumer_monthly_quota{consumer="user-a-uuid"} 10000000
```

---

## 7. WebSocket Proxy Design

### Man-in-the-Middle (MITM) Architecture

Unlike standard HTTP proxying where APISIX simply forwards bytes, our WebSocket implementation acts as an intelligent Man-in-the-Middle to enable JSON-RPC inspection and rate limiting on a per-message basis.

```
┌──────────┐      WebSocket       ┌─────────────────────────┐      WebSocket       ┌──────────┐
│          │  Upgrade (HTTP)      │  unifra-ws-jsonrpc-proxy│      (Client)        │          │
│  Client  │ ───────────────────> │ (Server)       (Client) │ ───────────────────> │ Upstream │
│          │ <─────────────────── │   │                ▲    │ <─────────────────── │  Node    │
└──────────┘  101 Switching Prot  │   │                │    │                      └──────────┘
                                  │   │                │    │
                                  │   ▼                │    │
                                  │  Thread 1     Thread 2  │
                                  └─────────────────────────┘
```

### Dual-Thread Model

The plugin spawns a lightweight thread (Lua coroutine) to handle full-duplex communication:

1.  **Main Thread (Client -> Upstream)**:
    *   Reads frames from the Client.
    *   Parses JSON-RPC messages.
    *   Applies **Rate Limits** (sliding window) and **Whitelist** checks.
    *   Forwards valid messages to Upstream.
    *   Stores request metadata (start time, CU cost) in an `inflight_requests` table using the JSON-RPC ID.

2.  **Downstream Thread (Upstream -> Client)**:
    *   Reads frames from Upstream.
    *   Parses JSON-RPC responses.
    *   **Correlates** responses with requests using the JSON-RPC ID.
    *   Calculates latency (`now - start_time`).
    *   Logs Kafka events according to the policy below.
    *   Forwards responses back to the Client.

### Kafka Logging Policy

- Non-subscription JSON-RPC request/response pairs are emitted to Kafka in the same schema as the Kafka Logger configuration (full payload).
- Subscription lifecycle and push traffic (eth_subscribe request, subscription success response, eth_subscription events) emits metadata only: method, network, latency, status, CU, user identifier. No request/response payloads.
- Subscription push events are routed to a dedicated Kafka topic via `kafka_event_topic` (default: `unifra-ws-events`).

### ID Correlation & Context Capture

To accurately bill and log WebSocket traffic, we must link responses to their original requests.

*   **Problem**: WebSocket is asynchronous; responses can come in any order.
*   **Solution**: We use the `id` field in JSON-RPC.
    *   When sending a request, we store context in a Lua table: `inflight[id] = { start=..., cu=..., app_id=... }`.
    *   When receiving a response, we look up `inflight[id]`.
    *   This allows us to log "Request A took 50ms and cost 10 CU".

### High-Performance Optimizations

1.  **Context Pre-Capture**:
    *   Instead of looking up `ctx.var.consumer_name` or `ctx.var.quota_key` for every single WebSocket message (which is expensive), we capture these values **once** during the WebSocket handshake phase.
    *   These values are passed into the tight loops of the read/write threads.

2.  **Circuit Breaker for Redis**:
    *   Rate limiting relies on Redis. To prevent WebSocket latency spikes if Redis is slow, we wrap Redis calls in a circuit breaker.
    *   If Redis fails, we fail-open (allow traffic) to preserve user experience, while logging the error.

3.  **Kafka Batching**:
    *   High-frequency WebSocket traffic generates massive logs.
    *   We use a **Batch Processor** to buffer logs in memory and flush them to Kafka in chunks (e.g., every 500 entries or 1 second).
    *   This drastically reduces I/O overhead compared to sending one Kafka message per WebSocket frame.

### Plugin Execution Flow

The WebSocket flow differs significantly from standard HTTP because continuous message processing happens *inside* the proxy loop, after the initial handshake.

#### 1. Handshake Phase (Standard APISIX Chain)
Client initiates `GET / HTTP/1.1 Upgrade: websocket`.

```
┌────────────────────────────────┐
│ 1. unifra-jsonrpc-var (26000)  │  ◄ Context extraction (Network, Helper vars)
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│ 2. key-auth (2500)             │  ◄ API Key Validation
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│ 3. unifra-ctx-var (2400)       │  ◄ Load Quota & Limits for User
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│ 4. unifra-ws-jsonrpc-proxy (999)│ ◄ INTERCEPT HANDSHAKE
└──────────────┬─────────────────┘
               │  (Plugin takes over connection)
               ▼
        Connected to Upstream
```

#### 2. Message Phase (Inside Proxy Loop)
For **EACH** WebSocket message frame:

```
┌────────────────────────────────┐
│      Incoming Message          │
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│      JSON-RPC Parsing          │
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│      Whitelist Check           │  (Library Call: unifra.jsonrpc.whitelist)
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│      CU Calculation            │  (Library Call: unifra.jsonrpc.cu)
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│      Rate Limiting Check       │  (Library Call -> Redis Script)
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│      Forward to Upstream       │
└────────────────────────────────┘
```

