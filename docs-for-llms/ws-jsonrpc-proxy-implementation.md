# WebSocket JSON-RPC 代理插件实施文档

## 概述

本文档描述了 `ws-jsonrpc-proxy` 插件的实现细节和使用方法。该插件为 APISIX 添加了 WebSocket JSON-RPC 请求的精细化限流和访问控制功能。

## 架构设计

### 工作流程

1. **握手阶段 (Handshake Phase)**
   - 客户端发起 WebSocket 握手请求
   - APISIX 正常执行 HTTP Access 阶段的所有插件：
     - `key-auth`: 识别 API Key，加载 Consumer 配置
     - `custom-ctx-var`: 注入 Consumer 的配额变量（`seconds_quota`, `monthly_quota` 等）
     - `limit-conn`: 检查连接数限制
   - 握手成功后，WebSocket 连接建立

2. **消息代理阶段 (Message Proxy Phase)**
   - `ws-jsonrpc-proxy` 插件接管 WebSocket 连接
   - 作为中间人（MITM），建立双向代理：
     - 客户端 ↔ APISIX ↔ 上游节点
   - 对每条 JSON-RPC 消息：
     - 解析 JSON-RPC 请求，提取 `method`
     - 注入变量：`ctx.var.jsonrpc_method`, `ctx.var.cu`
     - 手动调用 `whitelist` 插件检查访问权限
     - 手动调用 `limit-cu` 插件进行速率限制
     - 检查通过：转发给上游
     - 检查失败：返回 JSON-RPC 错误响应

### 关键特性

- **不修改现有插件**：完全复用现有的 `limit-cu`、`whitelist`、`custom-ctx-var` 插件
- **零影响 HTTP 流量**：仅当 `ctx.var.http_upgrade == "websocket"` 时才激活
- **自动配置读取**：从 Service/Route 配置中读取插件配置，无需重复配置

## 文件清单

### 新增文件

1. **插件实现**: `apisix/plugins/ws-jsonrpc-proxy.lua`
   - 主要功能：WebSocket 消息级别的拦截和检查
   - 优先级：999（确保在 limit-conn(1003)/limit-count(1002) 之后，gzip(995) 之前）
   - 超时策略：从 upstream 配置读取 `timeout.read`（秒）作为 WS connect/read 超时；未配置则默认 60s；`recv_frame` 的 timeout 不会断开连接。

### 修改文件

1. **配置文件**: `nomad-config/staging-rpc/apisix/config.yaml`
   - 在 `plugins` 列表中添加 `ws-jsonrpc-proxy`

## 配置示例

### 1. 启用插件

在 `config.yaml` 的 `plugins` 部分添加：

```yaml
plugins:
  - workflow                       # priority: 1006
  - ws-jsonrpc-proxy               # priority: 999   <-- 新优先级
  - calculate-cu                   # priority: 1012
  - limit-cu                       # priority: 1010
  - limit-conn                     # priority: 1003
```

### 2. Service 配置（无需修改）

现有的 Service 配置（如 `3-ws-plugins.json`）无需修改。插件会自动读取：

```json
{
  "name": "ws-plugins",
  "plugins": {
    "key-auth": { ... },
    "custom-ctx-var": {},
    "limit-conn": {
      "conn": 500,
      "key": "remote_addr",
      "rejected_code": 429
    },
    "whitelist": {
      "default_paid_quota": 100000
    },
    "limit-cu": {
      "count": "$seconds_quota",
      "time_window": 1,
      "policy": "redis",
      ...
    }
  }
}
```

**重要**：虽然 Service 配置中包含 `limit-cu` 和 `whitelist`，但这些插件在 WebSocket 握手后**不会自动执行**。`ws-jsonrpc-proxy` 会**手动调用**它们的逻辑。

### 3. Route 配置（确保启用 WebSocket）

```json
{
  "uri": "/ws/*",
  "name": "dogeos-testnet-ws",
  "methods": ["GET"],
  "host": "*dogeos-testnet.unifra.io",
  "service_id": "3",
  "upstream_id": "601",
  "enable_websocket": true,  // 必须设置为 true
  "status": 1
}
```

### 4. Consumer 配置（差异化限流）

#### 免费用户
```json
{
  "username": "free_user",
  "plugins": {
    "key-auth": { "key": "user-api-key" },
    "custom-ctx-var": {
      "seconds_quota": "100",
      "monthly_quota": "100000"
    }
  }
}
```

#### VIP 用户（更高配额 + 更多连接数）
```json
{
  "username": "vip_user",
  "plugins": {
    "key-auth": { "key": "vip-api-key" },
    "custom-ctx-var": {
      "seconds_quota": "2000",
      "monthly_quota": "10000000"
    },
    "limit-conn": {
      "conn": 1000,  // 覆盖 Service 的 500 连接限制
      "key": "remote_addr",
      "rejected_code": 503
    }
  }
}
```

## 实现细节

### 变量注入机制

每条 WebSocket 消息处理时，插件会注入以下变量：

```lua
ctx.var.jsonrpc_method = req.method  -- 如 "eth_blockNumber"
ctx.var.cu = calculate_cu(req.method) -- 从 calculate-cu 配置中获取或默认为 1
```

这些变量随后会被 `whitelist` 和 `limit-cu` 插件使用。

### 错误响应格式

当请求被拒绝时，返回标准 JSON-RPC 错误：

```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": 429,
    "message": "Your app has reached maximum qps limit"
  },
  "id": null
}
```

错误码：
- `405`: 方法不在白名单或非付费用户
- `429`: 超过速率限制
- `500`: 内部错误

### 连接生命周期

```
客户端                 APISIX               上游节点
   |                      |                     |
   |-- WebSocket 握手 --->|                     |
   |    (key-auth,        |                     |
   |     custom-ctx-var,  |                     |
   |     limit-conn 运行) |                     |
   |<---- 101 切换协议 ---|                     |
   |                      |--- 连接上游 WS ---->|
   |                      |<----- 连接成功 -----|
   |                      |                     |
   |-- JSON-RPC 消息 ---->|                     |
   |    (ws-jsonrpc-proxy |                     |
   |     检查 whitelist   |                     |
   |     和 limit-cu)     |                     |
   |                      |--- 转发消息 ------->|
   |                      |<---- 响应 ----------|
   |<---- 响应 -----------|                     |
   |                      |                     |
```

## 测试方法

### 1. 基本连接测试

```bash
# 使用 websocat 工具测试
websocat -H="apikey: YOUR_API_KEY" \
  wss://dogeos-testnet.unifra.io/ws/dogeos-testnet
```

### 2. JSON-RPC 请求测试

```bash
# 连接后发送
{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}
```

### 3. 限流测试

使用脚本快速发送多个请求，验证是否正确限流：

```javascript
const WebSocket = require('ws');

const ws = new WebSocket('wss://dogeos-testnet.unifra.io/ws/dogeos-testnet', {
  headers: { 'apikey': 'YOUR_API_KEY' }
});

ws.on('open', () => {
  // 快速发送 200 个请求
  for (let i = 0; i < 200; i++) {
    ws.send(JSON.stringify({
      jsonrpc: '2.0',
      method: 'eth_blockNumber',
      params: [],
      id: i
    }));
  }
});

ws.on('message', (data) => {
  const resp = JSON.parse(data);
  if (resp.error && resp.error.code === 429) {
    console.log('Rate limit triggered at request', resp.id);
  }
});
```

## 性能考虑

### Redis 压力

每条 WebSocket 消息都会调用一次 Redis INCR 操作（通过 `limit-cu` 插件）。对于高频 WebSocket 消息（如订阅场景），需要：

1. 确保 Redis 使用了 Pipeline 或 Lua Script 优化
2. 监控 Redis 负载，必要时使用 Redis Cluster
3. 考虑使用 `limit-cu` 的 `allow_degradation` 选项在 Redis 故障时放行

### 连接数限制

`limit-conn` 在握手阶段执行，建议：

1. Service 级别设置较大的默认值（如 500）
2. 针对 VIP 用户在 Consumer 配置中覆盖为更大的值（如 1000）

## 与旧配置的兼容性

### 现有 HTTP RPC 流量

完全不受影响。`ws-jsonrpc-proxy` 仅在检测到 WebSocket 升级时激活。

### 现有 WebSocket 配置

如果之前已有 WebSocket 路由（如 `6002-dogeos-testnet-ws.json`），但未启用精细化限流，现在会自动生效。

**迁移步骤**：

1. 确保 Route 的 `enable_websocket: true`
2. 确保 Service 中配置了 `limit-cu` 和 `whitelist`
3. 在 `config.yaml` 中启用 `ws-jsonrpc-proxy` 插件
4. 重启 APISIX

## 故障排查

### 连接失败

**症状**：WebSocket 握手失败，返回 401 或 429

**检查项**：
- API Key 是否正确（`key-auth` 插件）
- Consumer 配置是否存在
- `limit-conn` 连接数是否已满

### 消息被拒绝

**症状**：连接成功，但消息返回 405 或 429 错误

**检查项**：
- `whitelist` 配置中是否支持该方法
- `monthly_quota` 是否足够（付费用户检查）
- `limit-cu` 的 `seconds_quota` 是否已耗尽
- Redis 是否正常工作

### 日志查看

```bash
# APISIX 错误日志
tail -f /usr/local/apisix/logs/error.log | grep ws-jsonrpc-proxy

# 查看连接和消息处理信息
grep "ws-jsonrpc-proxy: intercepting" /usr/local/apisix/logs/error.log
grep "ws-jsonrpc-proxy: connected to upstream" /usr/local/apisix/logs/error.log
```

## 未来优化方向

1. **批量请求支持**：如果客户端发送 JSON-RPC batch 请求，需要解析数组并分别检查
2. **订阅过滤**：对于 `eth_subscribe` 等订阅方法，可能需要特殊处理
3. **性能优化**：考虑使用共享内存缓存插件配置，减少重复读取
4. **监控指标**：添加 Prometheus 指标，统计 WebSocket 连接数、消息速率等

## 参考资料

- [APISIX WebSocket 代理文档](https://apisix.apache.org/docs/apisix/plugins/proxy-rewrite/#enable-websocket)
- [lua-resty-websocket](https://github.com/openresty/lua-resty-websocket)
- [原始需求文档](./ws-jsonrpc-proxy.md)
