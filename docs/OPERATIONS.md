# Unifra APISIX - Operations Guide

## Table of Contents

1. [Monitoring](#monitoring)
2. [Logging](#logging)
3. [Troubleshooting](#troubleshooting)
4. [Common Issues](#common-issues)
5. [Maintenance](#maintenance)
6. [Security](#security)

---

## Monitoring

### Prometheus Metrics

Enable Prometheus plugin in APISIX:

```yaml
plugins:
  - prometheus

plugin_attr:
  prometheus:
    export_uri: /apisix/prometheus/metrics
    export_addr:
      ip: 0.0.0.0
      port: 9091
```

### Key Metrics

| Metric | Description |
|--------|-------------|
| `apisix_http_requests_total` | Total requests by route, status |
| `apisix_http_latency_bucket` | Request latency histogram |
| `apisix_bandwidth` | Bandwidth usage |
| `apisix_upstream_status` | Upstream health status |

### Custom Dashboard (Grafana)

```json
{
  "panels": [
    {
      "title": "Requests per Second",
      "targets": [{
        "expr": "rate(apisix_http_requests_total[1m])"
      }]
    },
    {
      "title": "Error Rate",
      "targets": [{
        "expr": "rate(apisix_http_requests_total{code=~\"4..|5..\"}[1m])"
      }]
    },
    {
      "title": "P99 Latency",
      "targets": [{
        "expr": "histogram_quantile(0.99, rate(apisix_http_latency_bucket[1m]))"
      }]
    },
    {
      "title": "Rate Limited Requests",
      "targets": [{
        "expr": "rate(apisix_http_requests_total{code=\"429\"}[1m])"
      }]
    }
  ]
}
```

### Alerting Rules

```yaml
groups:
  - name: apisix
    rules:
      - alert: HighErrorRate
        expr: |
          rate(apisix_http_requests_total{code=~"5.."}[5m])
          / rate(apisix_http_requests_total[5m]) > 0.05
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "High error rate on APISIX"

      - alert: HighLatency
        expr: |
          histogram_quantile(0.99, rate(apisix_http_latency_bucket[5m])) > 1000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "P99 latency > 1s"

      - alert: RateLimitSpike
        expr: |
          rate(apisix_http_requests_total{code="429"}[5m]) > 100
        for: 5m
        labels:
          severity: info
        annotations:
          summary: "Many requests being rate limited"
```

---

## Logging

### Log Configuration

```yaml
nginx_config:
  error_log_level: warn  # error, warn, info, debug

  http:
    access_log: /var/log/apisix/access.log
    access_log_format: |
      {"time":"$time_iso8601","remote_addr":"$remote_addr",
       "method":"$request_method","uri":"$uri","status":"$status",
       "latency":"$request_time","upstream_time":"$upstream_response_time",
       "consumer":"$http_x_consumer_username",
       "jsonrpc_method":"$jsonrpc_method"}
```

### Plugin Logging

Each plugin logs important events:

```lua
-- unifra-whitelist.lua
core.log.warn("whitelist denied: ", err,
              ", network=", network,
              ", is_paid=", is_paid)

-- unifra-limit-cu.lua
core.log.info("rate limit check: key=", key,
              ", cu=", cu, ", limit=", limit)
```

### Structured Logging

Enable HTTP logger plugin for external log aggregation:

```json
{
  "plugins": {
    "http-logger": {
      "uri": "http://logstash:8080/logs",
      "batch_max_size": 1000,
      "inactive_timeout": 5,
      "include_req_body": false,
      "include_resp_body": false
    }
  }
}
```

### Log Analysis Queries (Elasticsearch)

```json
// Rate limited requests
{
  "query": {
    "bool": {
      "must": [
        { "term": { "status": 429 } },
        { "range": { "@timestamp": { "gte": "now-1h" } } }
      ]
    }
  },
  "aggs": {
    "by_consumer": {
      "terms": { "field": "consumer.keyword" }
    }
  }
}

// Slow requests
{
  "query": {
    "bool": {
      "must": [
        { "range": { "latency": { "gte": 1 } } }
      ]
    }
  }
}
```

---

## Troubleshooting

### Debug Mode

Enable debug logging temporarily:

```bash
# Edit config
vim /usr/local/apisix/conf/config.yaml
# Set: error_log_level: debug

# Reload
apisix reload

# Watch logs
tail -f /usr/local/apisix/logs/error.log | grep unifra
```

### Common Debug Commands

```bash
# Check if plugins are loaded
curl http://localhost:9180/apisix/admin/plugins/list \
  -H "X-API-KEY: $ADMIN_KEY" | jq '.[] | select(startswith("unifra"))'

# Check route configuration
curl http://localhost:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $ADMIN_KEY" | jq '.value.plugins'

# Check consumer configuration
curl http://localhost:9180/apisix/admin/consumers/user-123 \
  -H "X-API-KEY: $ADMIN_KEY" | jq '.value.plugins'

# Test request with verbose output
curl -v -X POST http://localhost:9080/v1/abc123 \
  -H "Content-Type: application/json" \
  -H "apikey: test-key" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Check Redis rate limit keys
redis-cli -h redis keys "unifra:ratelimit:*"
redis-cli -h redis get "unifra:ratelimit:user-123:1"
```

### Request Tracing

Add request ID for tracing:

```json
{
  "plugins": {
    "request-id": {
      "include_in_response": true,
      "algorithm": "uuid"
    }
  }
}
```

Then trace a specific request:
```bash
# Get request ID from response header
curl -i http://localhost:9080/...
# X-Request-Id: abc123

# Search logs for this ID
grep "abc123" /var/log/apisix/access.log
```

---

## Common Issues

### 1. Plugin Not Found

**Symptom:**
```
failed to check the configuration of plugin unifra-jsonrpc-var: not found
```

**Solution:**
```bash
# Check extra_lua_path in config
grep extra_lua_path /usr/local/apisix/conf/config.yaml

# Verify files exist
ls -la /opt/unifra-apisix/apisix/plugins/

# Check file permissions
sudo chown -R apisix:apisix /opt/unifra-apisix
```

### 2. Whitelist Config Not Loading

**Symptom:**
```json
{"error": {"code": -32600, "message": "whitelist config not loaded"}}
```

**Solution:**
```bash
# Check config path
ls -la /opt/unifra-apisix/conf/whitelist.json

# Verify JSON is valid
cat /opt/unifra-apisix/conf/whitelist.json | jq .

# Check APISIX error log
grep "whitelist" /usr/local/apisix/logs/error.log
```

### 3. Rate Limit Not Working

**Symptom:** Requests not being rate limited despite quota being set.

**Checklist:**
```bash
# 1. Check consumer has seconds_quota set
curl http://localhost:9180/apisix/admin/consumers/user-123 \
  -H "X-API-KEY: $ADMIN_KEY" | jq '.value.plugins["unifra-ctx-var"]'

# 2. Check Redis is reachable
docker exec apisix redis-cli -h redis ping

# 3. Check rate limit plugin is enabled on route
curl http://localhost:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $ADMIN_KEY" | jq '.value.plugins["unifra-limit-cu"]'

# 4. Check Redis for keys
redis-cli -h redis keys "*"
```

### 4. WebSocket Connection Fails

**Symptom:** WebSocket handshake fails or times out.

**Solution:**
```bash
# Check route has enable_websocket
curl http://localhost:9180/apisix/admin/routes/2 \
  -H "X-API-KEY: $ADMIN_KEY" | jq '.value.enable_websocket'

# Check route accepts GET method
curl http://localhost:9180/apisix/admin/routes/2 \
  -H "X-API-KEY: $ADMIN_KEY" | jq '.value.methods'

# Test WebSocket manually
wscat -c ws://localhost:9080/ws/v1/key123
```

### 5. Network Extraction Fails

**Symptom:**
```json
{"error": {"code": -32600, "message": "unsupported network: localhost"}}
```

**Solution:**
Add `network` override to plugin config:
```json
{
  "plugins": {
    "unifra-jsonrpc-var": {
      "network": "eth-mainnet"
    }
  }
}
```

### 6. Method Blocked Unexpectedly

**Symptom:**
```json
{"error": {"code": -32601, "message": "unsupported method: eth_newMethod"}}
```

**Solution:**
```bash
# Check whitelist config
cat /opt/unifra-apisix/conf/whitelist.json | jq '.networks["eth-mainnet"]'

# Add method to free list
vim /opt/unifra-apisix/conf/whitelist.json

# Wait for TTL or force reload
apisix reload
```

---

## Maintenance

### Upgrading APISIX

Since we use zero-intrusion architecture, APISIX upgrades are straightforward:

```bash
# 1. Pull new image
docker pull apache/apisix:3.15.0-debian

# 2. Update docker-compose.yml version
vim docker-compose.yml

# 3. Rolling restart
docker-compose up -d --no-deps apisix

# 4. Verify plugins still work
curl http://localhost:9180/apisix/admin/plugins/list \
  -H "X-API-KEY: $ADMIN_KEY" | grep unifra
```

### Updating Unifra Plugins

```bash
# 1. Copy new plugin files
cp -r new-unifra-apisix/* /opt/unifra-apisix/

# 2. Reload APISIX (no restart needed)
apisix reload

# 3. Verify
curl http://localhost:9080/apisix/status
```

### Backup and Restore

```bash
# Backup etcd data
etcdctl snapshot save /backup/etcd-snapshot.db

# Backup Redis data
redis-cli -h redis BGSAVE
cp /data/dump.rdb /backup/

# Backup configs
cp -r /opt/unifra-apisix/conf /backup/unifra-conf/

# Restore etcd
etcdctl snapshot restore /backup/etcd-snapshot.db

# Restore Redis
cp /backup/dump.rdb /data/
redis-cli -h redis DEBUG RELOAD
```

### Rotating Admin Keys

```bash
# 1. Add new key
curl -X PATCH http://localhost:9180/apisix/admin/consumers/admin \
  -H "X-API-KEY: $OLD_KEY" \
  -d '{"plugins": {"key-auth": {"key": "new-key-123"}}}'

# 2. Update config.yaml with new admin key
vim /usr/local/apisix/conf/config.yaml

# 3. Reload
apisix reload

# 4. Verify new key works
curl http://localhost:9180/apisix/admin/routes \
  -H "X-API-KEY: new-key-123"
```

---

## Security

### Admin API Protection

```yaml
deployment:
  admin:
    admin_key:
      - name: admin
        key: LONG_RANDOM_KEY_HERE
        role: admin
    # Only allow internal network
    allow_admin:
      - 10.0.0.0/8
      - 127.0.0.1/32
```

### TLS Configuration

```yaml
apisix:
  ssl:
    enable: true
    listen:
      - port: 9443
        enable_http2: true

  # Force HTTPS
  enable_http2: true
```

### Rate Limit Redis

Use password authentication:
```json
{
  "plugins": {
    "unifra-limit-cu": {
      "redis_host": "redis",
      "redis_password": "your-redis-password"
    }
  }
}
```

### API Key Best Practices

1. Use long, random keys (32+ characters)
2. Rotate keys periodically
3. Use different keys per environment
4. Never commit keys to version control

### Audit Logging

Enable access logging with consumer info:
```yaml
nginx_config:
  http:
    access_log_format: |
      {"consumer":"$http_apikey","ip":"$remote_addr",
       "method":"$jsonrpc_method","status":"$status"}
```

### Vulnerability Scanning

Regularly scan container images:
```bash
# Using Trivy
trivy image apache/apisix:3.14.0-debian

# Check for outdated dependencies
docker exec apisix luarocks list
```
