--
-- Unifra Redis Circuit Breaker Module
--
-- Implements circuit breaker pattern for Redis connections to prevent
-- cascading failures. Supports fail-open strategy for graceful degradation.
--
-- States:
--   CLOSED: Normal operation, requests go through
--   OPEN: Circuit tripped, requests fail fast without hitting Redis
--   HALF_OPEN: Testing if Redis recovered, limited requests allowed
--

local core = require("apisix.core")
local feature_flags = require("unifra.feature_flags")

local _M = {
    version = "1.0.0"
}

-- Circuit breaker states
local STATE_CLOSED = "closed"
local STATE_OPEN = "open"
local STATE_HALF_OPEN = "half_open"

-- Circuit breakers (one per Redis host:port)
-- Format: { [host:port] = { state, failure_count, last_failure_time, success_count } }
local circuit_breakers = {}

-- Configuration (can be overridden)
local config = {
    failure_threshold = 5,           -- Failures to trip circuit
    success_threshold = 2,           -- Successes in half-open to close circuit
    timeout = 30,                    -- Seconds to wait before half-open
    half_open_max_calls = 3,         -- Max concurrent calls in half-open state
    failure_window = 60,             -- Time window for counting failures (seconds)
}


--- Get circuit breaker key for Redis connection
-- @param redis_conf table Redis configuration
-- @return string Circuit breaker key
local function get_breaker_key(redis_conf)
    return string.format("%s:%d", redis_conf.host, redis_conf.port or 6379)
end


--- Initialize circuit breaker for Redis connection
-- @param key string Circuit breaker key
local function init_breaker(key)
    if not circuit_breakers[key] then
        circuit_breakers[key] = {
            state = STATE_CLOSED,
            failure_count = 0,
            success_count = 0,
            last_failure_time = 0,
            half_open_calls = 0,
        }
    end
    return circuit_breakers[key]
end


--- Check if circuit breaker allows request
-- @param redis_conf table Redis configuration
-- @return boolean true if allowed
-- @return string state Current circuit state
function _M.allow_request(redis_conf)
    local key = get_breaker_key(redis_conf)
    local breaker = init_breaker(key)
    local now = ngx.now()

    if breaker.state == STATE_CLOSED then
        -- Normal operation
        return true, STATE_CLOSED

    elseif breaker.state == STATE_OPEN then
        -- Check if timeout expired, transition to half-open
        if (now - breaker.last_failure_time) >= config.timeout then
            breaker.state = STATE_HALF_OPEN
            breaker.half_open_calls = 0
            breaker.success_count = 0
            core.log.info("Circuit breaker transitioning to HALF_OPEN: ", key)
            return true, STATE_HALF_OPEN
        end

        -- Circuit still open, reject
        return false, STATE_OPEN

    elseif breaker.state == STATE_HALF_OPEN then
        -- Limit concurrent calls in half-open state
        if breaker.half_open_calls >= config.half_open_max_calls then
            return false, STATE_HALF_OPEN
        end

        breaker.half_open_calls = breaker.half_open_calls + 1
        return true, STATE_HALF_OPEN
    end

    return true, STATE_CLOSED
end


--- Record successful Redis operation
-- @param redis_conf table Redis configuration
function _M.record_success(redis_conf)
    local key = get_breaker_key(redis_conf)
    local breaker = init_breaker(key)

    if breaker.state == STATE_HALF_OPEN then
        breaker.success_count = breaker.success_count + 1
        breaker.half_open_calls = breaker.half_open_calls - 1

        -- Enough successes, close circuit
        if breaker.success_count >= config.success_threshold then
            breaker.state = STATE_CLOSED
            breaker.failure_count = 0
            breaker.success_count = 0
            core.log.info("Circuit breaker CLOSED (recovered): ", key)
        end

    elseif breaker.state == STATE_CLOSED then
        -- Reset failure count on success in closed state
        local now = ngx.now()
        if (now - breaker.last_failure_time) > config.failure_window then
            breaker.failure_count = 0
        end
    end
end


--- Record failed Redis operation
-- @param redis_conf table Redis configuration
-- @param err string Error message
function _M.record_failure(redis_conf, err)
    local key = get_breaker_key(redis_conf)
    local breaker = init_breaker(key)
    local now = ngx.now()

    breaker.last_failure_time = now

    if breaker.state == STATE_HALF_OPEN then
        -- Any failure in half-open goes back to open
        breaker.state = STATE_OPEN
        breaker.half_open_calls = 0
        core.log.warn("Circuit breaker OPEN (failure in half-open): ", key, ", error: ", err)

    elseif breaker.state == STATE_CLOSED then
        -- Count failures in time window
        if (now - breaker.last_failure_time) < config.failure_window then
            breaker.failure_count = breaker.failure_count + 1
        else
            breaker.failure_count = 1
        end

        -- Trip circuit if threshold exceeded
        if breaker.failure_count >= config.failure_threshold then
            breaker.state = STATE_OPEN
            core.log.error("Circuit breaker OPEN (threshold exceeded): ", key,
                          ", failures: ", breaker.failure_count,
                          ", error: ", err)
        end
    end
end


--- Execute Redis operation with circuit breaker
-- @param redis_conf table Redis configuration
-- @param ctx table Request context
-- @param operation function Redis operation to execute
-- @param fail_open boolean Whether to fail-open (default: true)
-- @return any Result from operation (or nil on failure)
-- @return string|nil Error message
-- @return boolean Whether circuit breaker blocked the request
function _M.execute(redis_conf, ctx, operation, fail_open)
    -- Check if circuit breaker is enabled
    if not feature_flags.is_enabled(ctx, "redis_circuit_breaker") then
        -- Circuit breaker disabled, execute directly
        local result, err = operation()
        return result, err, false
    end

    -- Default to fail-open if not specified
    if fail_open == nil then
        fail_open = feature_flags.is_enabled(ctx, "fail_open_on_redis_error")
    end

    -- Check if request is allowed
    local allowed, state = _M.allow_request(redis_conf)
    if not allowed then
        core.log.warn("Circuit breaker blocking request: ",
                     get_breaker_key(redis_conf), ", state: ", state)

        if fail_open then
            -- Fail-open: allow request to proceed without Redis
            return nil, "circuit breaker open (fail-open)", true
        else
            -- Fail-closed: reject request
            return nil, "circuit breaker open (fail-closed)", true
        end
    end

    -- Execute operation
    local result, err = operation()

    -- Record result
    if err then
        _M.record_failure(redis_conf, err)

        if fail_open then
            -- Fail-open: return success with nil result
            return nil, err, false
        else
            -- Fail-closed: propagate error
            return nil, err, false
        end
    else
        _M.record_success(redis_conf)
        return result, nil, false
    end
end


--- Get circuit breaker status
-- @param redis_conf table Redis configuration
-- @return table Status information
function _M.get_status(redis_conf)
    local key = get_breaker_key(redis_conf)
    local breaker = circuit_breakers[key]

    if not breaker then
        return {
            state = STATE_CLOSED,
            failure_count = 0,
            success_count = 0,
        }
    end

    return {
        state = breaker.state,
        failure_count = breaker.failure_count,
        success_count = breaker.success_count,
        last_failure_time = breaker.last_failure_time,
        half_open_calls = breaker.half_open_calls,
    }
end


--- Reset circuit breaker (for testing or manual recovery)
-- @param redis_conf table Redis configuration
function _M.reset(redis_conf)
    local key = get_breaker_key(redis_conf)
    circuit_breakers[key] = nil
    core.log.info("Circuit breaker reset: ", key)
end


--- Configure circuit breaker
-- @param new_config table Configuration overrides
function _M.configure(new_config)
    for k, v in pairs(new_config) do
        if config[k] ~= nil then
            config[k] = v
        end
    end
end


--- Get current configuration
-- @return table Current configuration
function _M.get_config()
    return core.table.clone(config)
end


return _M
