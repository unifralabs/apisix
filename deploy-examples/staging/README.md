# Staging Environment Deployment

Staging environment for Unifra APISIX JSON-RPC gateway.

## Domain Pattern

```
staging-{network}.unifra.io
```

Examples:
- `staging-eth-mainnet.unifra.io`
- `staging-polygon.unifra.io`
- `staging-arbitrum.unifra.io`

## Quick Start

```bash
# 1. Start services
docker-compose up -d

# 2. Wait for healthy status
docker-compose ps

# 3. Configure routes (see examples below)
./setup-routes.sh
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `APISIX_ADMIN_KEY` | Admin API key | `staging-admin-key-change-me` |
| `DASHBOARD_SECRET` | Dashboard JWT secret | `staging-dashboard-secret-change-me` |
| `DASHBOARD_PASSWORD` | Dashboard admin password | `staging-admin-change-me` |

## Example Route Setup

```bash
# Create upstream for eth-mainnet
curl -X PUT "http://localhost:9180/apisix/admin/upstreams/eth-mainnet" \
  -H "X-API-KEY: staging-admin-key-change-me" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "eth-mainnet-upstream",
    "type": "roundrobin",
    "nodes": {
      "your-eth-node:8545": 1
    }
  }'

# Create route for staging-eth-mainnet.unifra.io
curl -X PUT "http://localhost:9180/apisix/admin/routes/eth-mainnet" \
  -H "X-API-KEY: staging-admin-key-change-me" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "staging-eth-mainnet",
    "host": "staging-eth-mainnet.unifra.io",
    "uri": "/v1/*",
    "upstream_id": "eth-mainnet",
    "plugins": {
      "proxy-rewrite": {"uri": "/"},
      "unifra-jsonrpc-var": {"network": "eth-mainnet"},
      "unifra-whitelist": {},
      "unifra-calculate-cu": {},
      "key-auth": {}
    }
  }'
```

## Differences from Production

| Aspect | Staging | Production |
|--------|---------|------------|
| Domain | `staging-*.unifra.io` | `*.unifra.io` |
| Log level | `info` | `warn` |
| Admin access | Internal IPs only | Restricted + VPN |
| Rate limits | Lower | Production values |

## Access

- **Proxy**: http://localhost:9080
- **Dashboard**: http://localhost:9000
- **Admin API**: http://localhost:9180
- **Prometheus**: http://localhost:9091
