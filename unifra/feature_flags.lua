--
-- Unifra Feature Flags Module
--
-- Provides feature flag management for gradual rollout and A/B testing.
-- Flags can be configured globally, per-route, or per-consumer.
--
-- Usage:
--   local feature_flags = require("unifra.feature_flags")
--   if feature_flags.is_enabled(ctx, "sliding_window_rate_limit") then
--       -- use new algorithm
--   end
--

local core = require("apisix.core")

local _M = {
    version = "1.0.0"
}

-- Test override flags (for testing only, highest priority)
local test_override_flags = {}

-- Default feature flags (can be overridden in config)
local DEFAULT_FLAGS = {
    -- P0 Fixes
    force_json_parsing = true,              -- Remove Content-Type check
    sliding_window_rate_limit = true,       -- Use sliding window instead of fixed
    atomic_monthly_quota = true,            -- Use Redis atomic operations for monthly quota
    per_route_config_cache = true,          -- Per-route config caching instead of global
    fix_jsonrpc_batch_partial = true,       -- Allow partial batch failures
    fix_jsonrpc_id_null = true,             -- Properly handle id:null in errors
    ws_case_insensitive_upgrade = true,     -- Case-insensitive WebSocket upgrade check
    ws_ssl_verify = true,                   -- Enable SSL verification for upstream WebSocket

    -- Infrastructure
    redis_circuit_breaker = true,           -- Use circuit breaker for Redis
    fail_open_on_redis_error = true,        -- Fail-open when Redis is unavailable
    unified_error_handling = true,          -- Use unified error module
    prometheus_metrics = true,              -- Enable Prometheus metrics
    structured_logging = true,              -- Enable structured logging with request IDs

    -- Control Plane Integration
    control_plane_billing = false,          -- Use control plane for billing cycles (needs CP)
    dynamic_quota_updates = false,          -- Allow dynamic quota updates from CP

    -- URL Format
    url_key_extraction = true,              -- Extract API key from /v1/<key> URL format
}

--- Load feature flags from configuration
-- Priority: test_override > consumer > route > env > defaults
-- @param ctx table Request context
-- @return table Feature flags
local function load_flags(ctx)
    local flags = core.table.clone(DEFAULT_FLAGS)

    -- Global overrides from environment variables
    -- These are cached at module load time for performance
    local env_prefix = "UNIFRA_FF_"
    for flag_name, _ in pairs(DEFAULT_FLAGS) do
        local env_var = env_prefix .. flag_name:upper()
        local env_val = os.getenv(env_var)
        if env_val ~= nil then
            flags[flag_name] = (env_val == "true" or env_val == "1")
        end
    end

    -- Route-level overrides
    if ctx and ctx.matched_route then
        local route_flags = ctx.matched_route.value and
                           ctx.matched_route.value.feature_flags
        if route_flags then
            for k, v in pairs(route_flags) do
                flags[k] = v
            end
        end
    end

    -- Consumer-level overrides
    if ctx and ctx.consumer then
        local consumer_flags = ctx.consumer.feature_flags
        if consumer_flags then
            for k, v in pairs(consumer_flags) do
                flags[k] = v
            end
        end
    end

    -- Test overrides (highest priority, for testing only)
    for k, v in pairs(test_override_flags) do
        flags[k] = v
    end

    return flags
end


--- Check if a feature flag is enabled
-- No caching - each request gets its own flags based on consumer/route context
-- This prevents cache pollution where one consumer's flags affect another
-- @param ctx table Request context (required for consumer/route-specific flags)
-- @param flag_name string Feature flag name
-- @return boolean true if enabled
function _M.is_enabled(ctx, flag_name)
    -- Load flags for this specific request context
    -- No global cache to prevent cross-request pollution
    local flags = load_flags(ctx)

    -- Get flag value (default to false if not found)
    local enabled = flags[flag_name]
    if enabled == nil then
        return false
    end

    return enabled == true
end


--- Get all feature flags for context
-- @param ctx table Request context
-- @return table All feature flags
function _M.get_all(ctx)
    -- Load flags fresh for this request
    return load_flags(ctx)
end


--- Set a feature flag (for testing only)
-- This sets a test override that takes highest priority
-- @param flag_name string Feature flag name
-- @param enabled boolean Enable or disable
function _M.set(flag_name, enabled)
    test_override_flags[flag_name] = enabled
    core.log.warn("Test override set: ", flag_name, " = ", enabled)
end


--- Clear test overrides (for testing only)
-- Removes all test overrides, restoring normal flag behavior
function _M.clear_cache()
    test_override_flags = {}
    core.log.warn("All test overrides cleared")
end


--- Get flag value with percentage-based rollout
-- Useful for canary deployments (e.g., enable for 10% of users)
-- @param ctx table Request context
-- @param flag_name string Feature flag name
-- @param percentage number Percentage of users to enable (0-100)
-- @param key_field string Field to use for consistent hashing (default: consumer_name)
-- @return boolean true if enabled for this request
function _M.is_enabled_for_percentage(ctx, flag_name, percentage, key_field)
    -- First check if flag is enabled at all
    if not _M.is_enabled(ctx, flag_name) then
        return false
    end

    -- If percentage is 100, enable for everyone
    if percentage >= 100 then
        return true
    end

    -- If percentage is 0, disable for everyone
    if percentage <= 0 then
        return false
    end

    -- Get key for consistent hashing
    key_field = key_field or "consumer_name"
    local key = ctx.var[key_field]
    if not key then
        -- Fallback to remote_addr if consumer not available
        key = ctx.var.remote_addr or "unknown"
    end

    -- Simple hash-based percentage
    local hash_input = flag_name .. ":" .. key
    local hash_val = ngx.crc32_short(hash_input)
    local bucket = (hash_val % 100) + 1  -- 1-100

    return bucket <= percentage
end


return _M
