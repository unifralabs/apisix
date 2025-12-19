# Unifra APISIX Extensions

Zero-intrusion extensions for Apache APISIX to support JSON-RPC gateway functionality.

## Overview

This package provides custom plugins and modules for running a blockchain JSON-RPC gateway on Apache APISIX **without modifying any APISIX source code**.

### Key Features

- **JSON-RPC Parsing**: Full support for single and batch JSON-RPC 2.0 requests
- **Method Whitelist**: Per-network method access control with free/paid tiers
- **Compute Unit (CU) Based Rate Limiting**: Configurable CU costs per method
- **Monthly Quota Management**: Track and enforce monthly usage limits
- **WebSocket Support**: Per-message rate limiting for WebSocket connections
- **Emergency Circuit Breaker**: Block specific consumers, methods, or IPs
- **Hot Reload Config**: Whitelist and CU configs auto-reload (configurable TTL)

## Documentation

| Document | Description |
|----------|-------------|
| [**Architecture**](./docs/ARCHITECTURE.md) | Deep dive into zero-intrusion design, ctx.var caching, plugin priorities |
| [**Plugin Reference**](./docs/PLUGINS.md) | Complete reference for all 8 plugins with schemas and examples |
| [**Deployment Guide**](./docs/DEPLOYMENT.md) | Docker, Kubernetes, and manual deployment instructions |
| [**Operations Guide**](./docs/OPERATIONS.md) | Monitoring, logging, troubleshooting, maintenance |
| [**Development Guide**](./docs/DEVELOPMENT.md) | Creating new plugins, testing, best practices |

## Quick Start

### 1. Deploy Extension Files

```bash
# Clone this repo and mount it
git clone https://github.com/unifra/unifra-apisix.git
cd unifra-apisix

# Or copy to /opt (for production)
sudo cp -r . /opt/unifra-apisix

# Or use Docker volume mount
docker run -v $(pwd):/opt/unifra-apisix:ro apache/apisix:3.14.0-debian
```

### 2. Configure APISIX

Add to your `config.yaml`:

```yaml
apisix:
  extra_lua_path: "/opt/unifra-apisix/?.lua"

plugins:
  # Unifra plugins (by priority, highest first)
  - unifra-jsonrpc-var      # 26000 - Parse JSON-RPC
  - unifra-guard            # 25000 - Emergency blocker
  - unifra-ctx-var          # 24000 - Consumer variables
  - unifra-whitelist        # 1900  - Access control
  - unifra-calculate-cu     # 1012  - CU calculation
  - unifra-limit-monthly-cu # 1011  - Monthly quota
  - unifra-limit-cu         # 1010  - Rate limiting
  - unifra-ws-jsonrpc-proxy # 999   - WebSocket proxy
  # ... APISIX built-in plugins
  - proxy-rewrite
  - key-auth
```

### 3. Create Route

```bash
curl -X PUT http://localhost:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "uri": "/*",
    "host": "eth-mainnet.unifra.io",
    "plugins": {
      "key-auth": {},
      "unifra-jsonrpc-var": {},
      "unifra-whitelist": {},
      "unifra-calculate-cu": {},
      "unifra-limit-cu": {"redis_host": "redis"}
    },
    "upstream_id": "1"
  }'
```

### 4. Make Request

```bash
curl -X POST https://eth-mainnet.unifra.io/v1/your-api-key \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

## Directory Structure

```
.
├── apisix/plugins/           # APISIX plugin wrappers (8 plugins)
├── unifra/jsonrpc/           # Core business logic (4 modules)
├── conf/                     # Configuration files
├── docs/                     # Documentation
├── test-env/                 # Docker Compose test environment
└── tests/                    # Unit tests
```

## Plugin Overview

| Plugin | Priority | Description |
|--------|----------|-------------|
| `unifra-jsonrpc-var` | 26000 | Parse JSON-RPC, inject `ctx.var.jsonrpc_method`, etc. |
| `unifra-guard` | 25000 | Emergency block by consumer/method/IP |
| `unifra-ctx-var` | 24000 | Inject consumer quotas into ctx.var |
| `unifra-whitelist` | 1900 | Check method access (free vs paid tier) |
| `unifra-calculate-cu` | 1012 | Calculate CU cost for request |
| `unifra-limit-monthly-cu` | 1011 | Enforce monthly quota |
| `unifra-limit-cu` | 1010 | Per-second rate limiting |
| `unifra-ws-jsonrpc-proxy` | 999 | WebSocket proxy with per-message limits |

## Zero Intrusion Architecture

The key innovation is using APISIX's `ctx.var` caching mechanism:

```
┌─────────────────────────────────────────────────────────────────────┐
│                     APISIX Core (Unmodified)                         │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                      ctx.var Cache                           │    │
│  │  ┌────────────────┐  ┌────────────────┐  ┌───────────────┐  │    │
│  │  │jsonrpc_method  │  │jsonrpc_methods │  │unifra_network │  │    │
│  │  │ = "eth_call"   │  │ = ["eth_call"] │  │ ="eth-mainnet"│  │    │
│  │  └────────────────┘  └────────────────┘  └───────────────┘  │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                              ▲                                       │
│                              │ Write to cache                        │
└──────────────────────────────┼───────────────────────────────────────┘
                               │
┌──────────────────────────────┴───────────────────────────────────────┐
│                 External Plugin (unifra-jsonrpc-var)                  │
│  ctx.var.jsonrpc_method = parsed.method  -- Goes to cache!           │
└───────────────────────────────────────────────────────────────────────┘
```

1. `unifra-jsonrpc-var` runs first (priority 26000)
2. It parses JSON-RPC body and writes to `ctx.var` cache
3. Subsequent plugins read from cache
4. **APISIX source code remains completely unmodified**

## Upgrading APISIX

Since we don't modify APISIX source code:

```bash
# Simply update the image version
docker pull apache/apisix:3.15.0-debian
docker-compose up -d

# Plugins continue to work!
```

## Configuration Hot Reload

Whitelist and CU configs support automatic reloading:

```json
{
  "plugins": {
    "unifra-whitelist": {
      "config_ttl": 60
    }
  }
}
```

After editing `conf/whitelist.json`:
- Wait up to 60 seconds for auto-reload, OR
- Run `apisix reload` for immediate effect

**No APISIX restart or redeployment required.**

## Testing

```bash
# Start test environment
cd test-env
docker-compose up -d
anvil --host 0.0.0.0 --port 8545 &

# Run quick tests
./test-all.sh

# Run full integration tests
./tests/integration_test.sh
```

## License

Apache License 2.0
