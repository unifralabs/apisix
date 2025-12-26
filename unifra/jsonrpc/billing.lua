--
-- Unifra Billing Cycles Module
--
-- Manages billing cycles with control plane integration.
-- Supports cycle_id and cycle_end_at from control plane for strong consistency.
--
-- Design:
-- - Control plane provides: cycle_id (e.g., "20251215T000000Z") and cycle_end_at (unix timestamp)
-- - Gateway performs atomic check-and-increment in Redis
-- - Redis key includes cycle_id for proper cycle isolation
-- - EXPIREAT ensures automatic cleanup at cycle end
--

local core = require("apisix.core")
local redis_scripts = require("unifra.jsonrpc.redis_scripts")
local redis_circuit_breaker = require("unifra.jsonrpc.redis_circuit_breaker")
local feature_flags = require("unifra.feature_flags")
local metrics = require("unifra.metrics")

local _M = {
    version = "1.0.0"
}


--- Generate Redis key for billing cycle
-- @param consumer_name string Consumer name
-- @param cycle_id string Cycle ID from control plane
-- @return string Redis key
function _M.make_key(consumer_name, cycle_id)
    return string.format("quota:monthly:%s:%s", consumer_name, cycle_id or "default")
end


--- Parse cycle information from consumer configuration
-- @param ctx table Request context
-- @return string|nil cycle_id Cycle ID
-- @return number|nil cycle_end_at Cycle end timestamp (unix seconds)
-- @return string|nil error Error message
function _M.get_cycle_info(ctx)
    -- Check if control plane billing is enabled
    local use_cp_billing = feature_flags.is_enabled(ctx, "control_plane_billing")

    if use_cp_billing then
        -- Get from consumer configuration (provided by control plane)
        local cycle_id = ctx.var.billing_cycle_id
        local cycle_end_at = tonumber(ctx.var.billing_cycle_end_at)

        if not cycle_id or not cycle_end_at then
            return nil, nil, "missing billing cycle information from control plane"
        end

        return cycle_id, cycle_end_at, nil
    else
        -- Fallback: Generate cycle_id from current date (UTC natural month)
        local date = os.date("!*t")  -- UTC
        local cycle_id = string.format("%04d%02d", date.year, date.month)

        -- Calculate end of current month (last second: 23:59:59 UTC)
        -- CRITICAL: Must use UTC epoch, not local timezone interpretation

        -- Calculate next month's first day
        local next_month = date.month + 1
        local next_year = date.year
        if next_month > 12 then
            next_month = 1
            next_year = next_year + 1
        end

        -- Get epoch for next month's first day 00:00:00 in LOCAL timezone
        local next_month_local = os.time({
            year = next_year,
            month = next_month,
            day = 1,
            hour = 0,
            min = 0,
            sec = 0
        })

        -- Calculate timezone offset to convert local epoch to UTC epoch
        -- In UTC+8: local time "2026-01-01 00:00:00 +08:00" = "2025-12-31 16:00:00 UTC"
        -- We want "2026-01-01 00:00:00 UTC", so need to ADD 8 hours
        local utc_date = os.date("!*t", next_month_local)
        local utc_as_local = os.time(utc_date)
        local tz_offset = next_month_local - utc_as_local

        -- CRITICAL: Add offset (not subtract) to get UTC epoch
        -- next_month_local represents the date in local timezone
        -- We need to shift forward by tz_offset to get the same date in UTC
        local next_month_utc = next_month_local + tz_offset

        -- Current month's last second: next month start - 1 second
        local cycle_end_at = next_month_utc - 1

        return cycle_id, cycle_end_at, nil
    end
end


--- Check and increment monthly quota atomically
-- @param redis_conf table Redis configuration
-- @param ctx table Request context
-- @param consumer_name string Consumer name
-- @param cu number CU to consume
-- @param limit number Monthly quota limit
-- @return boolean|nil allowed true if allowed, false if exceeded, nil on error
-- @return number|nil used Current usage after increment (if allowed) or before (if rejected)
-- @return number|nil remaining Remaining quota
-- @return string|nil error Error message
function _M.check_and_increment(redis_conf, ctx, consumer_name, cu, limit)
    -- Get cycle information
    local cycle_id, cycle_end_at, err = _M.get_cycle_info(ctx)
    if err then
        core.log.error("Failed to get cycle info: ", err)
        return nil, nil, nil, err
    end

    -- Generate Redis key
    local key = _M.make_key(consumer_name, cycle_id)

    -- Execute atomic script via circuit breaker
    local redis = require("resty.redis")
    local result, script_err, blocked

    result, script_err, blocked = redis_circuit_breaker.execute(
        redis_conf,
        ctx,
        function()
            local red = redis:new()
            red:set_timeout(redis_conf.timeout or 1000)

            -- Connect
            local ok, conn_err = red:connect(redis_conf.host, redis_conf.port or 6379)
            if not ok then
                metrics.record_redis_op("connect", false)
                return nil, "redis connect failed: " .. (conn_err or "unknown")
            end

            -- Auth
            if redis_conf.password and redis_conf.password ~= "" then
                local ok, auth_err = red:auth(redis_conf.password)
                if not ok then
                    metrics.record_redis_op("auth", false)
                    return nil, "redis auth failed: " .. (auth_err or "unknown")
                end
            end

            -- Select database
            if redis_conf.database and redis_conf.database > 0 then
                red:select(redis_conf.database)
            end

            -- Execute atomic script
            local script_result, exec_err = redis_scripts.execute(
                red,
                redis_scripts.MONTHLY_QUOTA_SCRIPT,
                {key},
                {limit, cu, cycle_end_at}
            )

            -- Return connection to pool
            red:set_keepalive(10000, 100)

            if exec_err then
                metrics.record_redis_op("eval", false)
                return nil, exec_err
            end

            metrics.record_redis_op("eval", true)
            return script_result, nil
        end,
        false  -- MUST fail-closed for strong consistency (prevent overselling)
    )

    -- Handle circuit breaker block
    if blocked then
        core.log.error("Circuit breaker blocked monthly quota check for ", consumer_name)
        -- Fail-closed: reject request to prevent overselling
        return nil, nil, nil, "monthly quota service unavailable (circuit breaker open)"
    end

    -- Handle script error
    if script_err then
        core.log.error("Monthly quota script error: ", script_err)
        -- Fail-closed: reject request to prevent overselling
        return nil, nil, nil, script_err
    end

    -- Parse result
    -- result = {allowed (1/0), used_after, remaining}
    if not result or type(result) ~= "table" then
        core.log.error("Invalid script result: ", core.json.encode(result))
        -- Fail-closed: reject request on invalid response
        return nil, nil, nil, "invalid quota script response"
    end

    local allowed = (result[1] == 1)
    local used = tonumber(result[2]) or 0
    local remaining = tonumber(result[3]) or 0

    -- Update metrics
    if ctx.var.consumer_name then
        metrics.set_consumer_quota(ctx.var.consumer_name, limit, used)
    end

    if not allowed then
        metrics.inc_quota_exceeded(ctx)
        core.log.warn("Monthly quota exceeded: consumer=", consumer_name,
                     ", used=", used, ", limit=", limit, ", cycle=", cycle_id)
    end

    return allowed, used, remaining, nil
end


--- Get current monthly usage
-- @param redis_conf table Redis configuration
-- @param ctx table Request context
-- @param consumer_name string Consumer name
-- @return number|nil used Current usage (0 if not found)
-- @return string|nil error Error message
function _M.get_current_usage(redis_conf, ctx, consumer_name)
    local cycle_id, cycle_end_at, err = _M.get_cycle_info(ctx)
    if err then
        return nil, err
    end

    local key = _M.make_key(consumer_name, cycle_id)

    -- Execute via circuit breaker
    local result, script_err, blocked = redis_circuit_breaker.execute(
        redis_conf,
        ctx,
        function()
            local redis = require("resty.redis")
            local red = redis:new()
            red:set_timeout(redis_conf.timeout or 1000)

            local ok, conn_err = red:connect(redis_conf.host, redis_conf.port or 6379)
            if not ok then
                return nil, "redis connect failed: " .. (conn_err or "unknown")
            end

            if redis_conf.password and redis_conf.password ~= "" then
                red:auth(redis_conf.password)
            end

            if redis_conf.database and redis_conf.database > 0 then
                red:select(redis_conf.database)
            end

            -- Execute GET script
            local script_result, exec_err = redis_scripts.execute(
                red,
                redis_scripts.GET_QUOTA_SCRIPT,
                {key},
                {cycle_end_at}
            )

            red:set_keepalive(10000, 100)

            if exec_err then
                return nil, exec_err
            end

            return script_result, nil
        end,
        true  -- fail-open
    )

    if blocked or script_err then
        -- Fail-open: return 0 usage
        return 0, nil
    end

    local used = tonumber(result) or 0
    return used, nil
end


--- Reset quota for a consumer (for testing or refunds)
-- @param redis_conf table Redis configuration
-- @param ctx table Request context
-- @param consumer_name string Consumer name
-- @return boolean|nil success
-- @return string|nil error Error message
function _M.reset_quota(redis_conf, ctx, consumer_name)
    local cycle_id, _, err = _M.get_cycle_info(ctx)
    if err then
        return nil, err
    end

    local key = _M.make_key(consumer_name, cycle_id)

    local redis = require("resty.redis")
    local red = redis:new()
    red:set_timeout(redis_conf.timeout or 1000)

    local ok, conn_err = red:connect(redis_conf.host, redis_conf.port or 6379)
    if not ok then
        return nil, "redis connect failed: " .. (conn_err or "unknown")
    end

    if redis_conf.password and redis_conf.password ~= "" then
        red:auth(redis_conf.password)
    end

    if redis_conf.database and redis_conf.database > 0 then
        red:select(redis_conf.database)
    end

    local del_result, del_err = red:del(key)
    red:set_keepalive(10000, 100)

    if del_err then
        return nil, "redis del failed: " .. del_err
    end

    core.log.info("Reset quota for consumer: ", consumer_name, ", cycle: ", cycle_id)
    return true, nil
end


return _M
