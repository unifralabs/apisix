--
-- Unifra JSON-RPC Rate Limiting Module
-- Provides CU-based rate limiting using Redis
--
-- This module handles rate limiting based on Compute Units (CU).
-- It supports both single Redis and Redis Cluster modes.
--

local _M = {
    version = "1.0.0"
}


--- Generate rate limit key
-- @param consumer_id string User/consumer identifier
-- @param window number Time window in seconds
-- @return string Redis key for rate limiting
function _M.make_key(consumer_id, window)
    local now = ngx.now()
    local ts = math.floor(now / window) * window
    return string.format("ratelimit:cu:%s:%d", consumer_id, ts)
end


--- Generate monthly quota key
-- @param consumer_id string User/consumer identifier
-- @return string Redis key for monthly quota
function _M.make_monthly_key(consumer_id)
    local date = os.date("*t")
    return string.format("quota:monthly:%s:%d:%02d", consumer_id, date.year, date.month)
end


--- Check and increment rate limit counter (single Redis)
-- @param redis_conf table Redis configuration {host, port, password, database, timeout}
-- @param key string Rate limit key
-- @param cu number CU to consume
-- @param limit number Maximum CU allowed
-- @param window number Time window in seconds
-- @return boolean|nil true if allowed, false if rate limited, nil on error
-- @return number Remaining quota (0 if exceeded)
-- @return string|nil Error message on failure
function _M.check_and_incr(redis_conf, key, cu, limit, window)
    local redis = require("resty.redis")
    local red = redis:new()
    red:set_timeout(redis_conf.timeout or 1000)

    local ok, err = red:connect(redis_conf.host, redis_conf.port or 6379)
    if not ok then
        return nil, nil, "redis connect failed: " .. (err or "unknown")
    end

    -- Authenticate if password is provided
    if redis_conf.password and redis_conf.password ~= "" then
        local ok, err = red:auth(redis_conf.password)
        if not ok then
            return nil, nil, "redis auth failed: " .. (err or "unknown")
        end
    end

    -- Select database if specified
    if redis_conf.database and redis_conf.database > 0 then
        local ok, err = red:select(redis_conf.database)
        if not ok then
            return nil, nil, "redis select failed: " .. (err or "unknown")
        end
    end

    -- Atomic increment with INCRBY
    local current, err = red:incrby(key, cu)
    if not current then
        return nil, nil, "redis incrby failed: " .. (err or "unknown")
    end

    -- Set expiration only for new keys (when current equals cu)
    if tonumber(current) == cu then
        red:expire(key, window + 1) -- Add 1 second buffer
    end

    -- Return connection to pool
    local ok, err = red:set_keepalive(10000, 100)
    if not ok then
        ngx.log(ngx.WARN, "failed to set redis keepalive: ", err)
    end

    local remaining = limit - tonumber(current)
    if remaining < 0 then
        remaining = 0
    end

    return tonumber(current) <= limit, remaining, nil
end


--- Check and increment monthly quota
-- @param redis_conf table Redis configuration
-- @param key string Monthly quota key
-- @param cu number CU to consume
-- @param limit number Monthly CU limit
-- @return boolean|nil true if allowed, false if exceeded, nil on error
-- @return number Used quota
-- @return string|nil Error message on failure
function _M.check_monthly_quota(redis_conf, key, cu, limit)
    local redis = require("resty.redis")
    local red = redis:new()
    red:set_timeout(redis_conf.timeout or 1000)

    local ok, err = red:connect(redis_conf.host, redis_conf.port or 6379)
    if not ok then
        return nil, nil, "redis connect failed: " .. (err or "unknown")
    end

    if redis_conf.password and redis_conf.password ~= "" then
        local ok, err = red:auth(redis_conf.password)
        if not ok then
            return nil, nil, "redis auth failed: " .. (err or "unknown")
        end
    end

    if redis_conf.database and redis_conf.database > 0 then
        red:select(redis_conf.database)
    end

    -- Get current usage first
    local current, err = red:get(key)
    if err then
        return nil, nil, "redis get failed: " .. (err or "unknown")
    end

    current = tonumber(current) or 0

    -- Check if adding this request would exceed limit
    if current + cu > limit then
        red:set_keepalive(10000, 100)
        return false, current, nil
    end

    -- Increment usage
    local new_val, err = red:incrby(key, cu)
    if not new_val then
        return nil, nil, "redis incrby failed: " .. (err or "unknown")
    end

    -- Set expiration to end of month if new key
    if tonumber(new_val) == cu then
        -- Calculate seconds until end of month
        local date = os.date("*t")
        local days_in_month = os.date("*t", os.time{year=date.year, month=date.month+1, day=0}).day
        local seconds_left = (days_in_month - date.day + 1) * 86400
        red:expire(key, seconds_left)
    end

    red:set_keepalive(10000, 100)
    return true, tonumber(new_val), nil
end


--- Get current rate limit status
-- @param redis_conf table Redis configuration
-- @param key string Rate limit key
-- @return number|nil Current usage, nil on error
-- @return string|nil Error message on failure
function _M.get_current(redis_conf, key)
    local redis = require("resty.redis")
    local red = redis:new()
    red:set_timeout(redis_conf.timeout or 1000)

    local ok, err = red:connect(redis_conf.host, redis_conf.port or 6379)
    if not ok then
        return nil, "redis connect failed: " .. (err or "unknown")
    end

    if redis_conf.password and redis_conf.password ~= "" then
        local ok, err = red:auth(redis_conf.password)
        if not ok then
            return nil, "redis auth failed: " .. (err or "unknown")
        end
    end

    if redis_conf.database and redis_conf.database > 0 then
        red:select(redis_conf.database)
    end

    local val, err = red:get(key)
    if err then
        return nil, "redis get failed: " .. (err or "unknown")
    end

    red:set_keepalive(10000, 100)
    return tonumber(val) or 0, nil
end


return _M
