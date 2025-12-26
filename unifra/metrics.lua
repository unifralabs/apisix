--
-- Unifra Metrics Module
--
-- Provides Prometheus metrics for monitoring and observability.
-- Tracks requests, CU consumption, rate limiting, errors, and performance.
--

local core = require("apisix.core")
local feature_flags = require("unifra.feature_flags")

-- Optional dependency: resty.prometheus
local prometheus
local prometheus_available = pcall(function()
    prometheus = require("resty.prometheus")
end)

local _M = {
    version = "1.0.0"
}

-- Prometheus instance (shared across workers)
local prom

-- Metric definitions
local metrics = {}

-- Flag to track if metrics are enabled
local metrics_enabled = false


--- Initialize Prometheus metrics
-- Should be called once during worker initialization
-- Gracefully degrades if resty.prometheus is not available
function _M.init()
    if not prometheus_available or not prometheus then
        core.log.warn("resty.prometheus not available, metrics disabled")
        core.log.warn("Install: luarocks install lua-resty-prometheus")
        metrics_enabled = false
        return false, "prometheus module not available"
    end

    local ok, err = pcall(function()
        prom = prometheus.new()
    end)

    if not ok then
        core.log.error("Failed to initialize Prometheus: ", err)
        metrics_enabled = false
        return false, err
    end

    metrics_enabled = true

    -- Request counters
    metrics.request_total = prom:counter(
        "unifra_requests_total",
        "Total number of requests",
        {"network", "method", "consumer", "status"}
    )

    metrics.cu_consumed_total = prom:counter(
        "unifra_cu_consumed_total",
        "Total CU consumed",
        {"network", "method", "consumer"}
    )

    -- Rate limiting metrics
    metrics.rate_limit_exceeded_total = prom:counter(
        "unifra_rate_limit_exceeded_total",
        "Number of rate limit rejections",
        {"consumer", "limit_type"}  -- limit_type: second, monthly
    )

    metrics.quota_exceeded_total = prom:counter(
        "unifra_quota_exceeded_total",
        "Number of quota exceeded rejections",
        {"consumer"}
    )

    -- Request duration histogram
    metrics.request_duration_seconds = prom:histogram(
        "unifra_request_duration_seconds",
        "Request duration in seconds",
        {"network", "method"},
        {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5}  -- Buckets
    )

    -- Redis operation metrics
    metrics.redis_operations_total = prom:counter(
        "unifra_redis_operations_total",
        "Total Redis operations",
        {"operation", "status"}  -- status: success, error
    )

    metrics.redis_circuit_breaker_state = prom:gauge(
        "unifra_redis_circuit_breaker_state",
        "Circuit breaker state (0=closed, 1=open, 2=half_open)",
        {"redis_host"}
    )

    -- Config cache metrics
    metrics.config_cache_hits_total = prom:counter(
        "unifra_config_cache_hits_total",
        "Config cache hits",
        {"config_type"}
    )

    metrics.config_cache_misses_total = prom:counter(
        "unifra_config_cache_misses_total",
        "Config cache misses",
        {"config_type"}
    )

    -- Whitelist/Guard metrics
    metrics.whitelist_rejections_total = prom:counter(
        "unifra_whitelist_rejections_total",
        "Whitelist rejections",
        {"network", "method"}
    )

    metrics.guard_blocks_total = prom:counter(
        "unifra_guard_blocks_total",
        "Guard blocks",
        {"block_type"}  -- block_type: ip, consumer, method
    )

    -- WebSocket metrics
    metrics.websocket_connections_total = prom:counter(
        "unifra_websocket_connections_total",
        "WebSocket connections",
        {"network"}
    )

    metrics.websocket_messages_total = prom:counter(
        "unifra_websocket_messages_total",
        "WebSocket messages",
        {"network", "direction"}  -- direction: upstream, downstream
    )

    -- Consumer quota gauges (current usage)
    metrics.consumer_monthly_quota = prom:gauge(
        "unifra_consumer_monthly_quota",
        "Consumer monthly quota limit",
        {"consumer"}
    )

    metrics.consumer_monthly_used = prom:gauge(
        "unifra_consumer_monthly_used",
        "Consumer monthly quota used",
        {"consumer"}
    )

    core.log.info("Prometheus metrics initialized")
end


--- Check if metrics are enabled
-- @param ctx table Request context (optional)
-- @return boolean true if enabled
local function is_enabled(ctx)
    -- First check if prometheus module is available
    if not metrics_enabled or not prom then
        return false
    end

    -- Then check feature flag
    return feature_flags.is_enabled(ctx, "prometheus_metrics")
end


--- Increment request counter
-- @param ctx table Request context
-- @param status string Status (success, error, rate_limited, etc.)
function _M.inc_request(ctx, status)
    if not is_enabled(ctx) or not prom then
        return
    end

    local network = ctx.var.unifra_network or "unknown"
    local method = ctx.var.jsonrpc_method or "unknown"
    local consumer = ctx.var.consumer_name or "anonymous"

    metrics.request_total:inc(1, {network, method, consumer, status})
end


--- Record CU consumption
-- @param ctx table Request context
-- @param cu number CU consumed
function _M.record_cu(ctx, cu)
    if not is_enabled(ctx) or not prom then
        return
    end

    local network = ctx.var.unifra_network or "unknown"
    local method = ctx.var.jsonrpc_method or "unknown"
    local consumer = ctx.var.consumer_name or "anonymous"

    metrics.cu_consumed_total:inc(cu, {network, method, consumer})
end


--- Record rate limit rejection
-- @param ctx table Request context
-- @param limit_type string Type of limit (second, monthly)
function _M.inc_rate_limit(ctx, limit_type)
    if not is_enabled(ctx) or not prom then
        return
    end

    local consumer = ctx.var.consumer_name or "anonymous"
    metrics.rate_limit_exceeded_total:inc(1, {consumer, limit_type})
end


--- Record quota exceeded
-- @param ctx table Request context
function _M.inc_quota_exceeded(ctx)
    if not is_enabled(ctx) or not prom then
        return
    end

    local consumer = ctx.var.consumer_name or "anonymous"
    metrics.quota_exceeded_total:inc(1, {consumer})
end


--- Record request duration
-- @param ctx table Request context
-- @param duration number Duration in seconds
function _M.record_duration(ctx, duration)
    if not is_enabled(ctx) or not prom then
        return
    end

    local network = ctx.var.unifra_network or "unknown"
    local method = ctx.var.jsonrpc_method or "unknown"

    metrics.request_duration_seconds:observe(duration, {network, method})
end


--- Record Redis operation
-- @param operation string Operation name (get, set, incrby, etc.)
-- @param success boolean Whether operation succeeded
function _M.record_redis_op(operation, success)
    if not prom then
        return
    end

    local status = success and "success" or "error"
    metrics.redis_operations_total:inc(1, {operation, status})
end


--- Update circuit breaker state
-- @param redis_host string Redis host
-- @param state string State (closed, open, half_open)
function _M.set_circuit_breaker_state(redis_host, state)
    if not prom then
        return
    end

    local state_value = 0
    if state == "open" then
        state_value = 1
    elseif state == "half_open" then
        state_value = 2
    end

    metrics.redis_circuit_breaker_state:set(state_value, {redis_host})
end


--- Record config cache hit/miss
-- @param config_type string Type of config
-- @param hit boolean Whether it was a hit
function _M.record_config_cache(config_type, hit)
    if not prom then
        return
    end

    if hit then
        metrics.config_cache_hits_total:inc(1, {config_type})
    else
        metrics.config_cache_misses_total:inc(1, {config_type})
    end
end


--- Record whitelist rejection
-- @param network string Network name
-- @param method string Method name
function _M.inc_whitelist_rejection(network, method)
    if not prom then
        return
    end

    metrics.whitelist_rejections_total:inc(1, {network, method})
end


--- Record guard block
-- @param block_type string Type of block (ip, consumer, method)
function _M.inc_guard_block(block_type)
    if not prom then
        return
    end

    metrics.guard_blocks_total:inc(1, {block_type})
end


--- Record WebSocket connection
-- @param network string Network name
function _M.inc_websocket_connection(network)
    if not prom then
        return
    end

    metrics.websocket_connections_total:inc(1, {network})
end


--- Record WebSocket message
-- @param network string Network name
-- @param direction string Direction (upstream or downstream)
function _M.inc_websocket_message(network, direction)
    if not prom then
        return
    end

    metrics.websocket_messages_total:inc(1, {network, direction})
end


--- Update consumer quota metrics
-- @param consumer string Consumer name
-- @param quota number Monthly quota limit
-- @param used number Current usage
function _M.set_consumer_quota(consumer, quota, used)
    if not prom then
        return
    end

    metrics.consumer_monthly_quota:set(quota, {consumer})
    metrics.consumer_monthly_used:set(used, {consumer})
end


--- Get metrics in Prometheus format
-- @return string Metrics in Prometheus text format
function _M.collect()
    if not prom then
        return "# Metrics not initialized\n"
    end

    return prom:collect()
end


--- Start request timer
-- Call this at the beginning of request processing
-- @param ctx table Request context
function _M.start_timer(ctx)
    if is_enabled(ctx) then
        ctx._unifra_start_time = ngx.now()
    end
end


--- End request timer and record metrics
-- Call this at the end of request processing
-- @param ctx table Request context
-- @param status string Request status (success, error, etc.)
function _M.end_timer(ctx, status)
    if not is_enabled(ctx) or not ctx._unifra_start_time then
        return
    end

    local duration = ngx.now() - ctx._unifra_start_time
    _M.record_duration(ctx, duration)
    _M.inc_request(ctx, status)

    -- Record CU if available
    local cu = tonumber(ctx.var.cu)
    if cu then
        _M.record_cu(ctx, cu)
    end
end


return _M
