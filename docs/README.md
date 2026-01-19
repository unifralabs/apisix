# Unifra APISIX Documentation

Welcome to the Unifra APISIX documentation. This documentation covers everything you need to know about deploying, operating, and extending the Unifra APISIX plugins.

## Quick Navigation

| Document | Description |
|----------|-------------|
| [Architecture](./ARCHITECTURE.md) | Deep dive into zero-intrusion design |
| [Plugins](./PLUGINS.md) | Complete plugin reference |
| [Deployment](./DEPLOYMENT.md) | Docker, Kubernetes, manual deployment |
| [Operations](./OPERATIONS.md) | Monitoring, logging, troubleshooting |
| [Development](./DEVELOPMENT.md) | Creating new plugins, testing |

## What is Unifra APISIX?

Unifra APISIX is a set of **external plugins** for Apache APISIX that enable:

- JSON-RPC request parsing and routing
- Method-level access control (whitelist)
- Compute Unit (CU) based rate limiting
- Monthly quota management
- WebSocket JSON-RPC proxy with per-message limits

### Key Innovation: Zero Intrusion

Unlike traditional APISIX customizations that require modifying source code, Unifra plugins load **externally** via `extra_lua_path`. This means:

- **No merge conflicts** when upgrading APISIX
- **Clean separation** between APISIX core and business logic
- **Easy deployment** via volume mounts

## Quick Start

### 1. Add plugins to APISIX config

```yaml
apisix:
  extra_lua_path: "/opt/unifra-apisix/?.lua"

plugins:
  - unifra-key-auth         # Extract API key from URL path
  - unifra-jsonrpc-var      # Parse JSON-RPC + gzip decompression
  - unifra-ctx-var
  - unifra-whitelist
  - unifra-calculate-cu
  - unifra-limit-monthly-cu
  - unifra-limit-cu
  - unifra-ws-jsonrpc-proxy
```

### 2. Create a route

```bash
curl -X PUT http://localhost:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $ADMIN_KEY" \
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

### 3. Make a request

```bash
curl -X POST https://eth-mainnet.unifra.io/v1/your-api-key \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                       Apache APISIX (Unmodified)                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                        Plugin Chain                            │  │
│  │                                                                │  │
│  │  ┌─────────────────┐                                          │  │
│  │  │ unifra-key-auth │ ─────► Extract API key from URL path     │  │
│  │  │   (27000)       │        /v1/{key}/... → header injection  │  │
│  │  └────────┬────────┘                                          │  │
│  │           │                                                     │  │
│  │  ┌────────▼─────────┐                                          │  │
│  │  │unifra-jsonrpc-var│ ─────► Parse JSON-RPC + gzip decompress │  │
│  │  │   (26000)        │        inject ctx.var.*                  │  │
│  │  └────────┬─────────┘                                          │  │
│  │           │                                                     │  │
│  │  ┌────────▼─────────┐                                          │  │
│  │  │ unifra-ctx-var   │ ─────► Inject consumer quotas            │  │
│  │  │   (2400)        │                                          │  │
│  │  └────────┬─────────┘                                          │  │
│  │           │                                                     │  │
│  │  ┌────────▼─────────┐                                          │  │
│  │  │  key-auth        │ ─────► Authenticate API key              │  │
│  │  │   (2500)         │                                          │  │
│  │  └────────┬─────────┘                                          │  │
│  │           │                                                     │  │
│  │  ┌────────▼─────────┐                                          │  │
│  │  │unifra-whitelist  │ ─────► Check method access               │  │
│  │  │   (1900)         │                                          │  │
│  │  └────────┬─────────┘                                          │  │
│  │           │                                                     │  │
│  │  ┌────────▼─────────┐                                          │  │
│  │  │unifra-calculate-cu│─────► Calculate request CU cost         │  │
│  │  │   (1012)         │                                          │  │
│  │  └────────┬─────────┘                                          │  │
│  │           │                                                     │  │
│  │  ┌────────▼─────────┐                                          │  │
│  │  │unifra-limit-*-cu │ ─────► Rate limiting (per-sec, monthly)  │  │
│  │  │  (1011, 1010)    │                                          │  │
│  │  └────────┬─────────┘                                          │  │
│  │           │                                                     │  │
│  └───────────┼────────────────────────────────────────────────────┘  │
│              │                                                        │
│              ▼                                                        │
│         [Upstream]                                                    │
└───────────────────────────────────────────────────────────────────────┘
```

## FAQ

### Q: Do I need to fork APISIX?

**No.** Unifra plugins load externally. Use the official APISIX Docker image.

### Q: How do I update whitelist/CU config?

Edit the YAML files in `conf/`:
- `whitelist.yaml` - Method access control per network
- `cu-pricing.yaml` - Compute unit costs per method

Changes auto-reload within 60 seconds (configurable via `config_ttl`).

### Q: Does this work with WebSocket?

Yes. `unifra-ws-jsonrpc-proxy` handles WebSocket with per-message rate limiting.

### Q: What happens if Redis is down?

By default, plugins have `allow_degradation: true`, so requests continue without rate limiting.

### Q: How do I add a new JSON-RPC method?

Add it to `conf/whitelist.yaml` under the appropriate network and tier (free/paid).

## Getting Help

- Check [Troubleshooting](./OPERATIONS.md#troubleshooting) for common issues
- Review [APISIX documentation](https://apisix.apache.org/docs/)
- Open an issue on GitHub
