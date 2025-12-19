# Unifra APISIX - Plugin Reference

## Table of Contents

1. [Plugin Overview](#plugin-overview)
2. [unifra-jsonrpc-var](#unifra-jsonrpc-var)
3. [unifra-guard](#unifra-guard)
4. [unifra-ctx-var](#unifra-ctx-var)
5. [unifra-whitelist](#unifra-whitelist)
6. [unifra-calculate-cu](#unifra-calculate-cu)
7. [unifra-limit-monthly-cu](#unifra-limit-monthly-cu)
8. [unifra-limit-cu](#unifra-limit-cu)
9. [unifra-ws-jsonrpc-proxy](#unifra-ws-jsonrpc-proxy)

---

## Plugin Overview

| Plugin | Priority | Phase | Description |
|--------|----------|-------|-------------|
| unifra-jsonrpc-var | 26000 | rewrite | Parse JSON-RPC, inject variables |
| unifra-guard | 25000 | rewrite | Emergency circuit breaker |
| unifra-ctx-var | 24000 | rewrite | Inject consumer variables |
| unifra-whitelist | 1900 | access | Method access control |
| unifra-calculate-cu | 1012 | access | Compute unit calculation |
| unifra-limit-monthly-cu | 1011 | access | Monthly quota enforcement |
| unifra-limit-cu | 1010 | access | Per-second rate limiting |
| unifra-ws-jsonrpc-proxy | 999 | access | WebSocket proxy with per-message limits |

---

## unifra-jsonrpc-var

**Priority**: 26000 (highest - runs first)
**Phase**: rewrite
**Location**: `apisix/plugins/unifra-jsonrpc-var.lua`

### Purpose

Parses incoming JSON-RPC requests and injects parsed data into `ctx.var` for use by subsequent plugins. This is the cornerstone of the zero-intrusion architecture.

### Schema

```json
{
  "type": "object",
  "properties": {
    "network": {
      "type": "string",
      "description": "Override network name (useful for testing or single-network routes)"
    }
  }
}
```

### Injected Variables

| Variable | Type | Description |
|----------|------|-------------|
| `ctx.var.jsonrpc_method` | string | First method name, or "batch" for batch requests |
| `ctx.var.jsonrpc_methods` | table | Array of all method names in request |
| `ctx.var.unifra_network` | string | Network extracted from host (e.g., "eth-mainnet") |
| `ctx.jsonrpc` | table | Full parsed result (methods, ids, is_batch, etc.) |

### Network Extraction

The network is extracted from the `Host` header:

```
eth-mainnet.unifra.io  →  eth-mainnet
polygon-mainnet.api.unifra.io  →  polygon-mainnet
localhost:9080  →  localhost (or use network override)
```

### Example Configuration

**Route config (Admin API):**
```json
{
  "uri": "/*",
  "host": "eth-mainnet.unifra.io",
  "plugins": {
    "unifra-jsonrpc-var": {}
  }
}
```

**For testing (override network):**
```json
{
  "uri": "/eth/*",
  "plugins": {
    "unifra-jsonrpc-var": {
      "network": "eth-mainnet"
    }
  }
}
```

### Batch Request Handling

For batch requests like:
```json
[
  {"jsonrpc": "2.0", "method": "eth_blockNumber", "id": 1},
  {"jsonrpc": "2.0", "method": "eth_chainId", "id": 2}
]
```

The plugin sets:
- `jsonrpc_method` = "batch"
- `jsonrpc_methods` = ["eth_blockNumber", "eth_chainId"]

---

## unifra-guard

**Priority**: 25000
**Phase**: rewrite
**Location**: `apisix/plugins/unifra-guard.lua`

### Purpose

Emergency circuit breaker that can immediately block requests based on consumer, method, or IP. Use this for incident response when you need to quickly block malicious traffic.

### Schema

```json
{
  "type": "object",
  "properties": {
    "blocked_consumers": {
      "type": "array",
      "items": { "type": "string" },
      "default": [],
      "description": "List of consumer names to block"
    },
    "blocked_methods": {
      "type": "array",
      "items": { "type": "string" },
      "default": [],
      "description": "List of methods to block (supports wildcards like debug_*)"
    },
    "blocked_ips": {
      "type": "array",
      "items": { "type": "string" },
      "default": [],
      "description": "List of IP addresses to block"
    }
  }
}
```

### Example Configuration

**Block specific consumer:**
```json
{
  "plugins": {
    "unifra-guard": {
      "blocked_consumers": ["malicious-user-123"]
    }
  }
}
```

**Block debug methods globally:**
```json
{
  "plugins": {
    "unifra-guard": {
      "blocked_methods": ["debug_*", "trace_*"]
    }
  }
}
```

**Block specific IP:**
```json
{
  "plugins": {
    "unifra-guard": {
      "blocked_ips": ["192.168.1.100", "10.0.0.50"]
    }
  }
}
```

### Response

When blocked, returns:
```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32603,
    "message": "blocked by guard"
  },
  "id": null
}
```

---

## unifra-ctx-var

**Priority**: 24000
**Phase**: rewrite
**Location**: `apisix/plugins/unifra-ctx-var.lua`

### Purpose

Injects consumer-specific variables into `ctx.var`. This plugin is typically configured on **Consumers**, not routes, to set per-user quotas.

### Schema

```json
{
  "type": "object",
  "properties": {
    "seconds_quota": {
      "type": "string",
      "description": "Per-second CU limit"
    },
    "monthly_quota": {
      "type": "string",
      "description": "Monthly CU quota"
    },
    "monthly_used": {
      "type": "string",
      "description": "Currently used CU this month"
    }
  },
  "additionalProperties": {
    "type": "string"
  }
}
```

### Example Configuration

**Consumer config (Admin API):**
```json
{
  "username": "user-123",
  "plugins": {
    "key-auth": {
      "key": "api-key-abc123"
    },
    "unifra-ctx-var": {
      "seconds_quota": "100",
      "monthly_quota": "10000000",
      "monthly_used": "500000"
    }
  }
}
```

### Injected Variables

After this plugin runs, subsequent plugins can access:
- `ctx.var.seconds_quota` → "100"
- `ctx.var.monthly_quota` → "10000000"
- `ctx.var.monthly_used` → "500000"

### Dynamic Variables

You can inject any variable, not just quotas:
```json
{
  "plugins": {
    "unifra-ctx-var": {
      "customer_tier": "enterprise",
      "bypass_rate_limit": "true",
      "custom_upstream": "premium-nodes"
    }
  }
}
```

---

## unifra-whitelist

**Priority**: 1900
**Phase**: access
**Location**: `apisix/plugins/unifra-whitelist.lua`

### Purpose

Controls which JSON-RPC methods are allowed for each network and user tier (free vs paid).

### Schema

```json
{
  "type": "object",
  "properties": {
    "config_path": {
      "type": "string",
      "default": "/opt/unifra-apisix/conf/whitelist.yaml",
      "description": "Path to whitelist configuration file"
    },
    "config_ttl": {
      "type": "integer",
      "default": 60,
      "minimum": 0,
      "description": "Config cache TTL in seconds (0 = no caching)"
    },
    "paid_quota_threshold": {
      "type": "integer",
      "default": 1000000,
      "description": "Monthly quota threshold to be considered paid user"
    },
    "bypass_networks": {
      "type": "array",
      "items": { "type": "string" },
      "default": [],
      "description": "Networks that bypass whitelist check"
    }
  }
}
```

### Whitelist Configuration File

**whitelist.json:**
```json
{
  "networks": {
    "eth-mainnet": {
      "free": [
        "eth_blockNumber",
        "eth_chainId",
        "eth_gasPrice",
        "eth_getBalance",
        "eth_getBlockByNumber",
        "eth_getBlockByHash",
        "eth_getTransactionByHash",
        "eth_getTransactionReceipt",
        "eth_call",
        "eth_estimateGas",
        "eth_sendRawTransaction",
        "eth_getLogs",
        "eth_getCode",
        "eth_getStorageAt",
        "eth_getTransactionCount",
        "net_version",
        "web3_clientVersion"
      ],
      "paid": [
        "debug_*",
        "trace_*",
        "eth_createAccessList"
      ]
    },
    "polygon-mainnet": {
      "free": ["eth_*", "net_*", "web3_*"],
      "paid": ["debug_*", "trace_*", "bor_*"]
    }
  }
}
```

### Free vs Paid Tier

A user is considered "paid" if:
```
monthly_quota > paid_quota_threshold
```

Default threshold: 1,000,000 CU

- **Free users**: Can only access methods in `free` list
- **Paid users**: Can access both `free` and `paid` lists

### Wildcard Patterns

Supports `*` suffix wildcards:
- `eth_*` matches `eth_blockNumber`, `eth_call`, etc.
- `debug_*` matches `debug_traceTransaction`, etc.

### Error Responses

**Method not in whitelist:**
```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32601,
    "message": "unsupported method: eth_mining"
  },
  "id": 1
}
```

**Paid method for free user:**
```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32603,
    "message": "method debug_traceTransaction requires paid tier"
  },
  "id": 1
}
```

---

## unifra-calculate-cu

**Priority**: 1012
**Phase**: access
**Location**: `apisix/plugins/unifra-calculate-cu.lua`

### Purpose

Calculates the total Compute Unit (CU) cost for a request based on the methods called.

### Schema

```json
{
  "type": "object",
  "properties": {
    "config_path": {
      "type": "string",
      "default": "/opt/unifra-apisix/conf/cu-pricing.yaml",
      "description": "Path to CU pricing configuration file"
    },
    "config_ttl": {
      "type": "integer",
      "default": 60,
      "minimum": 0,
      "description": "Config cache TTL in seconds"
    }
  }
}
```

### CU Pricing Configuration

**cu-pricing.json:**
```json
{
  "default": 1,
  "methods": {
    "eth_blockNumber": 1,
    "eth_chainId": 1,
    "eth_gasPrice": 1,
    "eth_getBalance": 5,
    "eth_getBlockByNumber": 10,
    "eth_getBlockByHash": 10,
    "eth_getTransactionByHash": 5,
    "eth_getTransactionReceipt": 5,
    "eth_call": 15,
    "eth_estimateGas": 20,
    "eth_sendRawTransaction": 10,
    "eth_getLogs": 20,
    "eth_getCode": 5,
    "eth_getStorageAt": 5,
    "eth_getTransactionCount": 5,
    "debug_traceTransaction": 100,
    "debug_*": 50,
    "trace_*": 50
  }
}
```

### Output

Sets `ctx.var.cu` with the total CU cost:

| Request | CU Calculation |
|---------|---------------|
| Single `eth_blockNumber` | 1 |
| Single `eth_call` | 15 |
| Batch: `eth_blockNumber` + `eth_call` | 1 + 15 = 16 |
| Single `debug_traceTransaction` | 100 |

---

## unifra-limit-monthly-cu

**Priority**: 1011
**Phase**: access
**Location**: `apisix/plugins/unifra-limit-monthly-cu.lua`

### Purpose

Enforces monthly CU quotas per consumer.

### Schema

```json
{
  "type": "object",
  "properties": {
    "redis_host": { "type": "string", "default": "127.0.0.1" },
    "redis_port": { "type": "integer", "default": 6379 },
    "redis_password": { "type": "string", "default": "" },
    "redis_database": { "type": "integer", "default": 0 },
    "redis_timeout": { "type": "integer", "default": 1000 },
    "allow_degradation": {
      "type": "boolean",
      "default": true,
      "description": "Allow requests when Redis is unavailable"
    }
  }
}
```

### How It Works

1. Reads `monthly_quota` and `monthly_used` from `ctx.var`
2. Adds current request's CU (`ctx.var.cu`)
3. If `monthly_used + cu > monthly_quota`, rejects request
4. Otherwise, increments usage in Redis

### Error Response

```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32005,
    "message": "monthly quota exceeded"
  },
  "id": 1
}
```

---

## unifra-limit-cu

**Priority**: 1010
**Phase**: access
**Location**: `apisix/plugins/unifra-limit-cu.lua`

### Purpose

Per-second rate limiting using Redis sliding window algorithm.

### Schema

```json
{
  "type": "object",
  "properties": {
    "redis_host": { "type": "string", "default": "127.0.0.1" },
    "redis_port": { "type": "integer", "default": 6379 },
    "redis_password": { "type": "string", "default": "" },
    "redis_database": { "type": "integer", "default": 0 },
    "redis_timeout": { "type": "integer", "default": 1000 },
    "limit_var": {
      "type": "string",
      "default": "seconds_quota",
      "description": "ctx.var name containing the rate limit"
    },
    "time_window": {
      "type": "integer",
      "default": 1,
      "description": "Time window in seconds"
    },
    "allow_degradation": {
      "type": "boolean",
      "default": true,
      "description": "Allow requests when Redis is unavailable"
    }
  }
}
```

### Example

If `seconds_quota = 100` and `time_window = 1`:
- User can consume up to 100 CU per second
- A batch request with 50 CU counts as 50 toward the limit
- Excess requests get rate limited

### Error Response

```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32005,
    "message": "rate limit exceeded"
  },
  "id": 1
}
```

### Response Headers

When rate limited (HTTP 429):
```
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 1
```

---

## unifra-ws-jsonrpc-proxy

**Priority**: 999
**Phase**: access
**Location**: `apisix/plugins/unifra-ws-jsonrpc-proxy.lua`

### Purpose

Proxies WebSocket connections with per-message JSON-RPC processing. Unlike HTTP where each request is independent, WebSocket maintains a persistent connection and this plugin intercepts each message for rate limiting and access control.

### Schema

```json
{
  "type": "object",
  "properties": {
    "whitelist_config_path": {
      "type": "string",
      "default": "/opt/unifra-apisix/conf/whitelist.yaml"
    },
    "cu_config_path": {
      "type": "string",
      "default": "/opt/unifra-apisix/conf/cu-pricing.yaml"
    },
    "enable_rate_limit": {
      "type": "boolean",
      "default": true
    },
    "redis_host": { "type": "string", "default": "127.0.0.1" },
    "redis_port": { "type": "integer", "default": 6379 },
    "redis_password": { "type": "string", "default": "" },
    "redis_database": { "type": "integer", "default": 0 },
    "redis_timeout": { "type": "integer", "default": 1000 },
    "ws_timeout": {
      "type": "integer",
      "default": 60000,
      "description": "WebSocket timeout in milliseconds"
    },
    "paid_quota_threshold": {
      "type": "integer",
      "default": 1000000
    },
    "bypass_networks": {
      "type": "array",
      "items": { "type": "string" },
      "default": []
    },
    "network": {
      "type": "string",
      "description": "Override network name"
    }
  }
}
```

### Architecture

```
Client                    Plugin                     Upstream
  │                         │                           │
  │  WebSocket Handshake    │                           │
  │ ───────────────────────>│                           │
  │                         │  WebSocket Handshake      │
  │                         │ ─────────────────────────>│
  │                         │                           │
  │  101 Switching          │  101 Switching            │
  │ <───────────────────────│ <─────────────────────────│
  │                         │                           │
  │                    ┌────┴────────────────────┐      │
  │                    │ Plugin becomes MITM     │      │
  │                    │ - 2 WebSocket conns     │      │
  │                    │ - Message inspection    │      │
  │                    └────┬────────────────────┘      │
  │                         │                           │
  │  {"method":"eth_sub.."}│                           │
  │ ───────────────────────>│                           │
  │                         │ Check whitelist           │
  │                         │ Check rate limit          │
  │                         │                           │
  │                         │  Forward if allowed       │
  │                         │ ─────────────────────────>│
```

### Route Configuration

WebSocket routes require special configuration:

```json
{
  "uri": "/ws/*",
  "methods": ["GET"],
  "enable_websocket": true,
  "plugins": {
    "key-auth": {},
    "unifra-ws-jsonrpc-proxy": {
      "network": "eth-mainnet",
      "redis_host": "redis"
    }
  },
  "upstream_id": "1"
}
```

**Important:**
- `methods` must include "GET" (WebSocket handshake is GET)
- `enable_websocket: true` is required
- This plugin takes over the connection after handshake

### Per-Message Processing

For each message from client:
1. Parse as JSON-RPC
2. Check whitelist (same logic as HTTP)
3. Check rate limit (same logic as HTTP)
4. If blocked, send error response back to client
5. If allowed, forward to upstream

### Error Message (WebSocket)

When rate limited, sends JSON-RPC error through WebSocket:
```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32005,
    "message": "rate limit exceeded"
  },
  "id": 1
}
```
