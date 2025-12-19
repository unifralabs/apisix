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
│   ├── unifra-guard.lua          # Priority 25000
│   ├── unifra-ctx-var.lua        # Priority 24000
│   ├── unifra-whitelist.lua      # Priority 1900
│   ├── unifra-calculate-cu.lua   # Priority 1012
│   ├── unifra-limit-monthly-cu.lua # Priority 1011
│   ├── unifra-limit-cu.lua       # Priority 1010
│   └── unifra-ws-jsonrpc-proxy.lua # Priority 999
├── unifra/jsonrpc/               # Core business logic (reusable modules)
│   ├── core.lua                  # JSON-RPC parsing
│   ├── whitelist.lua             # Access control logic
│   ├── cu.lua                    # CU calculation logic
│   └── ratelimit.lua             # Redis rate limiting
└── conf/                         # Configuration files
    ├── whitelist.json
    └── cu-pricing.json
```

### Loading External Plugins

APISIX config (`config.yaml`):

```yaml
apisix:
  # This line loads our external plugins!
  extra_lua_path: "/opt/unifra-apisix/?.lua"

plugins:
  - unifra-jsonrpc-var      # Now APISIX can find these
  - unifra-guard
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
│  unifra-guard (25000)                                           │
│  - Emergency circuit breaker                                    │
│  - Block specific consumers/methods/IPs                         │
│  - Can reject request immediately                               │
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
│  unifra-ctx-var (24000)                                         │
│  - Inject consumer-specific variables                           │
│  - Set seconds_quota, monthly_quota, monthly_used               │
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
│  unifra-limit-monthly-cu (1011)                                 │
│  - Check if monthly quota exceeded                              │
│  - Reject if over limit                                         │
└─────────────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────────────┐
│  unifra-limit-cu (1010)                                         │
│  - Per-second rate limiting via Redis                           │
│  - Uses sliding window algorithm                                │
│  - Reject if rate exceeded                                      │
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
| unifra-guard | 25000 | Emergency block before any processing |
| unifra-ctx-var | 24000 | Consumer vars needed for quota checks |
| unifra-whitelist | 1900 | Reject invalid methods early |
| unifra-calculate-cu | 1012 | CU needed for rate limiting |
| unifra-limit-monthly-cu | 1011 | Monthly check before per-second |
| unifra-limit-cu | 1010 | Final rate limit check |
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
