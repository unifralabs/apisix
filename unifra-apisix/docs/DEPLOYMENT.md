# Unifra APISIX - Deployment Guide

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Docker Deployment](#docker-deployment)
3. [Kubernetes Deployment](#kubernetes-deployment)
4. [Manual Deployment](#manual-deployment)
5. [Configuration Management](#configuration-management)
6. [Health Checks](#health-checks)
7. [Scaling](#scaling)

---

## Prerequisites

### Required Components

| Component | Version | Purpose |
|-----------|---------|---------|
| Apache APISIX | 3.x | API Gateway |
| etcd | 3.5+ | Configuration storage |
| Redis | 6+ | Rate limiting storage |

### System Requirements

**Minimum (Development):**
- 2 CPU cores
- 2 GB RAM
- 10 GB disk

**Recommended (Production):**
- 4+ CPU cores
- 8+ GB RAM
- 50+ GB SSD

---

## Docker Deployment

### Quick Start

Create `docker-compose.yml`:

```yaml
version: '3.8'

services:
  etcd:
    image: quay.io/coreos/etcd:v3.5.11
    command:
      - /usr/local/bin/etcd
      - --advertise-client-urls=http://etcd:2379
      - --listen-client-urls=http://0.0.0.0:2379
      - --data-dir=/etcd-data
    volumes:
      - etcd-data:/etcd-data
    healthcheck:
      test: ["CMD", "etcdctl", "endpoint", "health"]
      interval: 10s
      timeout: 5s
      retries: 3

  redis:
    image: redis:7-alpine
    command: redis-server --appendonly yes
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3

  apisix:
    image: apache/apisix:3.14.0-debian
    depends_on:
      etcd:
        condition: service_healthy
      redis:
        condition: service_healthy
    ports:
      - "9080:9080"   # HTTP
      - "9443:9443"   # HTTPS
      - "9180:9180"   # Admin API
    volumes:
      # Mount Unifra extensions
      - ./unifra-apisix:/opt/unifra-apisix:ro
      # Mount APISIX config
      - ./apisix-config.yaml:/usr/local/apisix/conf/config.yaml:ro
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9080/apisix/status"]
      interval: 10s
      timeout: 5s
      retries: 3

volumes:
  etcd-data:
  redis-data:
```

### APISIX Configuration

Create `apisix-config.yaml`:

```yaml
apisix:
  node_listen: 9080
  enable_ipv6: false
  enable_admin: true

  # CRITICAL: Load Unifra plugins
  extra_lua_path: "/opt/unifra-apisix/?.lua"

# Enable plugins
plugins:
  # Unifra plugins (in priority order)
  - unifra-jsonrpc-var
  - unifra-guard
  - unifra-ctx-var
  - unifra-whitelist
  - unifra-calculate-cu
  - unifra-limit-monthly-cu
  - unifra-limit-cu
  - unifra-ws-jsonrpc-proxy

  # APISIX built-in plugins
  - proxy-rewrite
  - key-auth
  - limit-conn
  - limit-count
  - prometheus
  - http-logger

# etcd configuration
deployment:
  role: traditional
  role_traditional:
    config_provider: etcd
  etcd:
    host:
      - "http://etcd:2379"
    prefix: "/apisix"
    timeout: 30
  admin:
    admin_key:
      - name: admin
        key: YOUR_ADMIN_KEY_HERE
        role: admin
    # In production, restrict to internal network
    allow_admin:
      - 10.0.0.0/8
      - 172.16.0.0/12
      - 192.168.0.0/16

# Logging
nginx_config:
  error_log_level: warn
  http:
    access_log: "/dev/stdout"
```

### Start the Stack

```bash
# Start all services
docker-compose up -d

# Check logs
docker-compose logs -f apisix

# Verify plugins loaded
curl http://localhost:9180/apisix/admin/plugins/list \
  -H "X-API-KEY: YOUR_ADMIN_KEY_HERE" | grep unifra
```

---

## Kubernetes Deployment

### Using Helm

```bash
# Add APISIX Helm repo
helm repo add apisix https://charts.apiseven.com
helm repo update

# Create namespace
kubectl create namespace apisix

# Create ConfigMap for Unifra extensions
kubectl create configmap unifra-apisix \
  --from-file=unifra-apisix/ \
  -n apisix

# Install APISIX with custom values
helm install apisix apisix/apisix \
  -n apisix \
  -f values.yaml
```

### values.yaml

```yaml
apisix:
  image:
    repository: apache/apisix
    tag: 3.14.0-debian

  # Enable WebSocket support
  enableWebsocket: true

  extraVolumeMounts:
    - name: unifra-plugins
      mountPath: /opt/unifra-apisix
      readOnly: true

  extraVolumes:
    - name: unifra-plugins
      configMap:
        name: unifra-apisix

  config:
    apisix:
      extra_lua_path: "/opt/unifra-apisix/?.lua"

    plugins:
      - unifra-jsonrpc-var
      - unifra-guard
      - unifra-ctx-var
      - unifra-whitelist
      - unifra-calculate-cu
      - unifra-limit-monthly-cu
      - unifra-limit-cu
      - unifra-ws-jsonrpc-proxy
      - proxy-rewrite
      - key-auth
      - prometheus

etcd:
  enabled: true
  replicaCount: 3

redis:
  enabled: false  # Use external Redis

externalRedis:
  host: redis.redis.svc.cluster.local
  port: 6379
```

### Kustomize Example

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: apisix

resources:
  - namespace.yaml
  - etcd.yaml
  - apisix-deployment.yaml
  - apisix-service.yaml

configMapGenerator:
  - name: unifra-apisix
    files:
      - unifra-apisix/apisix/plugins/unifra-jsonrpc-var.lua
      - unifra-apisix/apisix/plugins/unifra-guard.lua
      - unifra-apisix/apisix/plugins/unifra-ctx-var.lua
      - unifra-apisix/apisix/plugins/unifra-whitelist.lua
      - unifra-apisix/apisix/plugins/unifra-calculate-cu.lua
      - unifra-apisix/apisix/plugins/unifra-limit-monthly-cu.lua
      - unifra-apisix/apisix/plugins/unifra-limit-cu.lua
      - unifra-apisix/apisix/plugins/unifra-ws-jsonrpc-proxy.lua
      - unifra-apisix/unifra/jsonrpc/core.lua
      - unifra-apisix/unifra/jsonrpc/whitelist.lua
      - unifra-apisix/unifra/jsonrpc/cu.lua
      - unifra-apisix/unifra/jsonrpc/ratelimit.lua
      - unifra-apisix/conf/whitelist.json
      - unifra-apisix/conf/cu-pricing.json
```

---

## Manual Deployment

### 1. Install APISIX

```bash
# Install dependencies
sudo apt-get update
sudo apt-get install -y curl git

# Install OpenResty
wget -O - https://openresty.org/package/pubkey.gpg | sudo apt-key add -
echo "deb http://openresty.org/package/ubuntu $(lsb_release -sc) main" \
  | sudo tee /etc/apt/sources.list.d/openresty.list
sudo apt-get update
sudo apt-get install -y openresty

# Install APISIX
curl -sSL https://github.com/apache/apisix/releases/download/3.14.0/apisix_3.14.0-0_amd64.deb -o apisix.deb
sudo dpkg -i apisix.deb
```

### 2. Install Unifra Extensions

```bash
# Clone or copy unifra-apisix directory
sudo mkdir -p /opt/unifra-apisix
sudo cp -r unifra-apisix/* /opt/unifra-apisix/

# Set permissions
sudo chown -R apisix:apisix /opt/unifra-apisix
sudo chmod -R 755 /opt/unifra-apisix
```

### 3. Configure APISIX

```bash
# Edit config
sudo vim /usr/local/apisix/conf/config.yaml

# Add extra_lua_path and plugins (see apisix-config.yaml above)
```

### 4. Start Services

```bash
# Start etcd
sudo systemctl start etcd

# Start Redis
sudo systemctl start redis

# Test APISIX config
apisix test

# Start APISIX
sudo systemctl start apisix

# Enable auto-start
sudo systemctl enable apisix
```

---

## Configuration Management

### Updating Whitelist/CU Config

The plugins support **hot reloading** with TTL-based cache:

```bash
# Edit whitelist
vim /opt/unifra-apisix/conf/whitelist.json

# Changes take effect within 60 seconds (default TTL)
# Or force immediate reload:
docker exec apisix apisix reload
```

### Adjusting TTL

In route configuration:
```json
{
  "plugins": {
    "unifra-whitelist": {
      "config_ttl": 30
    },
    "unifra-calculate-cu": {
      "config_ttl": 30
    }
  }
}
```

### Using Admin API

Create upstream:
```bash
curl -X PUT http://localhost:9180/apisix/admin/upstreams/1 \
  -H "X-API-KEY: $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "eth-mainnet-nodes",
    "type": "roundrobin",
    "nodes": {
      "eth-node-1.internal:8545": 1,
      "eth-node-2.internal:8545": 1
    },
    "timeout": {
      "connect": 5,
      "send": 60,
      "read": 60
    }
  }'
```

Create consumer:
```bash
curl -X PUT http://localhost:9180/apisix/admin/consumers/user-123 \
  -H "X-API-KEY: $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "user-123",
    "plugins": {
      "key-auth": {
        "key": "api-key-abc123"
      },
      "unifra-ctx-var": {
        "seconds_quota": "100",
        "monthly_quota": "10000000"
      }
    }
  }'
```

Create route:
```bash
curl -X PUT http://localhost:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "eth-mainnet-http",
    "uri": "/*",
    "host": "eth-mainnet.unifra.io",
    "upstream_id": "1",
    "plugins": {
      "key-auth": {},
      "unifra-jsonrpc-var": {},
      "unifra-whitelist": {},
      "unifra-calculate-cu": {},
      "unifra-limit-cu": {
        "redis_host": "redis"
      }
    }
  }'
```

---

## Health Checks

### APISIX Status

```bash
# Built-in status endpoint
curl http://localhost:9080/apisix/status

# Check plugin list
curl http://localhost:9180/apisix/admin/plugins/list \
  -H "X-API-KEY: $ADMIN_KEY"
```

### Redis Health

```bash
# Check connection
redis-cli -h redis ping

# Check rate limit keys
redis-cli -h redis keys "unifra:ratelimit:*"
```

### etcd Health

```bash
# Check cluster health
etcdctl --endpoints=http://etcd:2379 endpoint health

# List APISIX routes
etcdctl --endpoints=http://etcd:2379 get /apisix/routes --prefix
```

---

## Scaling

### Horizontal Scaling

APISIX is stateless (configuration in etcd, rate limits in Redis):

```yaml
# Kubernetes HPA
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: apisix-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: apisix
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

### Redis Cluster

For high-volume rate limiting:

```yaml
# Redis Cluster config
redis:
  cluster:
    enabled: true
    nodes:
      - redis-0.redis:6379
      - redis-1.redis:6379
      - redis-2.redis:6379
```

### etcd Cluster

For high availability:

```yaml
etcd:
  replicaCount: 3
  persistentVolume:
    enabled: true
    size: 10Gi
```

### Performance Tuning

APISIX nginx config:
```yaml
nginx_config:
  worker_processes: auto
  worker_connections: 65535
  http:
    keepalive_timeout: 60s
    client_max_body_size: 10m
```

Redis connection pool:
```json
{
  "plugins": {
    "unifra-limit-cu": {
      "redis_host": "redis",
      "redis_timeout": 100,
      "pool_size": 100
    }
  }
}
```
