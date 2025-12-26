--
-- Unifra Redis Lua Scripts Module
--
-- Provides atomic Redis operations using Lua scripts to prevent race conditions.
-- All scripts implement check-before-increment patterns for quota and rate limiting.
--

local _M = {
    version = "1.0.0"
}

--- Sliding window rate limit script (ZSET + Hash for CU tracking)
-- Uses sorted set with timestamps for sliding window + hash for CU values
-- KEYS[1] = ZSET key for timestamps (e.g., "ratelimit:cu:sliding:consumer")
-- KEYS[2] = HASH key for CU values (e.g., "ratelimit:cu:sliding:consumer:values")
-- ARGV[1] = current timestamp (milliseconds)
-- ARGV[2] = window size (milliseconds)
-- ARGV[3] = max CU limit
-- ARGV[4] = increment amount (CU for this request)
-- ARGV[5] = unique request ID
-- Returns: {allowed (1/0), current_cu_sum, remaining}
_M.SLIDING_WINDOW_SCRIPT = [[
local key = KEYS[1]
local hash_key = KEYS[2]
local now = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local limit = tonumber(ARGV[3])
local increment = tonumber(ARGV[4])
local request_id = ARGV[5]

-- Remove old entries outside the window
local window_start = now - window
local removed_members = redis.call('ZRANGEBYSCORE', key, 0, window_start)
if #removed_members > 0 then
    redis.call('ZREMRANGEBYSCORE', key, 0, window_start)
    -- Remove corresponding CU values from hash
    for i, member in ipairs(removed_members) do
        redis.call('HDEL', hash_key, member)
    end
end

-- Calculate current CU sum in window by summing all hash values
local members_in_window = redis.call('ZRANGEBYSCORE', key, window_start, now)
local current_cu = 0
for i, member in ipairs(members_in_window) do
    local cu_value = tonumber(redis.call('HGET', hash_key, member)) or 0
    current_cu = current_cu + cu_value
end

-- Check if adding this request would exceed limit
if current_cu + increment > limit then
    -- Would exceed, reject
    local remaining = limit - current_cu
    if remaining < 0 then remaining = 0 end
    return {0, current_cu, remaining}
end

-- Add this request to the window (timestamp in ZSET, CU in hash)
redis.call('ZADD', key, now, request_id)
redis.call('HSET', hash_key, request_id, increment)

-- Set expiration (window + buffer)
local expire_seconds = math.ceil(window / 1000) + 10
redis.call('EXPIRE', key, expire_seconds)
redis.call('EXPIRE', hash_key, expire_seconds)

-- Calculate new CU sum and remaining
local new_cu = current_cu + increment
local remaining = limit - new_cu
if remaining < 0 then remaining = 0 end

return {1, new_cu, remaining}
]]

--- Monthly quota check-before-increment script
-- Atomically checks quota and increments usage
-- KEYS[1] = monthly quota key (e.g., "quota:monthly:consumer:cycle_id")
-- ARGV[1] = limit (monthly quota)
-- ARGV[2] = increment (CU to consume)
-- ARGV[3] = cycle_end_at (unix timestamp for expiration)
-- Returns: {allowed (1/0), used_after, remaining}
_M.MONTHLY_QUOTA_SCRIPT = [[
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local increment = tonumber(ARGV[2])
local expire_at = tonumber(ARGV[3])

-- Get current usage
local current = tonumber(redis.call('GET', key)) or 0

-- Check if adding this request would exceed limit
if current + increment > limit then
    -- Would exceed, reject
    local remaining = limit - current
    if remaining < 0 then remaining = 0 end
    return {0, current, remaining}
end

-- Increment usage
local new_value = redis.call('INCRBY', key, increment)

-- Set expiration using EXPIREAT (absolute timestamp)
-- This handles cycle boundaries correctly
if expire_at > 0 then
    redis.call('EXPIREAT', key, expire_at)
end

-- Calculate remaining
local remaining = limit - new_value
if remaining < 0 then remaining = 0 end

return {1, new_value, remaining}
]]

--- Token bucket rate limit script
-- Alternative to sliding window, uses token bucket algorithm
-- KEYS[1] = bucket key
-- ARGV[1] = max capacity
-- ARGV[2] = refill rate (tokens per second)
-- ARGV[3] = current timestamp (seconds)
-- ARGV[4] = requested tokens
-- Returns: {allowed (1/0), current_tokens, wait_time_ms}
_M.TOKEN_BUCKET_SCRIPT = [[
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill_rate = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local requested = tonumber(ARGV[4])

-- Get current bucket state
local bucket = redis.call('HMGET', key, 'tokens', 'last_refill')
local tokens = tonumber(bucket[1]) or capacity
local last_refill = tonumber(bucket[2]) or now

-- Calculate tokens to add based on time elapsed
local elapsed = now - last_refill
local tokens_to_add = elapsed * refill_rate
tokens = math.min(capacity, tokens + tokens_to_add)

-- Check if we have enough tokens
if tokens >= requested then
    -- Consume tokens
    tokens = tokens - requested
    redis.call('HMSET', key, 'tokens', tokens, 'last_refill', now)
    redis.call('EXPIRE', key, math.ceil(capacity / refill_rate) + 60)
    return {1, tokens, 0}
else
    -- Not enough tokens, calculate wait time
    local tokens_needed = requested - tokens
    local wait_seconds = tokens_needed / refill_rate
    local wait_ms = math.ceil(wait_seconds * 1000)
    return {0, tokens, wait_ms}
end
]]

--- Fixed window rate limit with check-before-increment
-- Simple fixed window but atomic check
-- KEYS[1] = rate limit key
-- ARGV[1] = limit
-- ARGV[2] = window (seconds)
-- ARGV[3] = increment
-- Returns: {allowed (1/0), current, remaining}
_M.FIXED_WINDOW_SCRIPT = [[
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local increment = tonumber(ARGV[3])

-- Get current count
local current = tonumber(redis.call('GET', key)) or 0

-- Check before increment
if current + increment > limit then
    local remaining = limit - current
    if remaining < 0 then remaining = 0 end
    return {0, current, remaining}
end

-- Increment
local new_value = redis.call('INCRBY', key, increment)

-- Set expiration on first increment
if new_value == increment then
    redis.call('EXPIRE', key, window)
end

local remaining = limit - new_value
if remaining < 0 then remaining = 0 end

return {1, new_value, remaining}
]]

--- Get or initialize monthly quota
-- Used to fetch current usage for a billing cycle
-- KEYS[1] = quota key
-- ARGV[1] = cycle_end_at (unix timestamp)
-- Returns: current usage
_M.GET_QUOTA_SCRIPT = [[
local key = KEYS[1]
local expire_at = tonumber(ARGV[1])

local current = tonumber(redis.call('GET', key)) or 0

-- Ensure expiration is set
if expire_at > 0 and current > 0 then
    redis.call('EXPIREAT', key, expire_at)
end

return current
]]

--- Decrement quota (for rollback/refund scenarios)
-- KEYS[1] = quota key
-- ARGV[1] = amount to decrement
-- ARGV[2] = cycle_end_at
-- Returns: new usage value
_M.DECREMENT_QUOTA_SCRIPT = [[
local key = KEYS[1]
local amount = tonumber(ARGV[1])
local expire_at = tonumber(ARGV[2])

local current = tonumber(redis.call('GET', key)) or 0
local new_value = math.max(0, current - amount)

if new_value == 0 then
    redis.call('DEL', key)
else
    redis.call('SET', key, new_value)
    if expire_at > 0 then
        redis.call('EXPIREAT', key, expire_at)
    end
end

return new_value
]]

-- SHA1 cache for script performance optimization
-- Redis can execute by SHA1 to avoid sending full script every time
local script_shas = {}

--- Load a script into Redis and cache its SHA1
-- @param redis Redis client instance
-- @param script string Lua script
-- @return string|nil SHA1 hash
-- @return string|nil Error message
local function load_script(redis, script)
    local sha, err = redis:script("load", script)
    if not sha then
        return nil, "failed to load script: " .. (err or "unknown")
    end
    return sha, nil
end

--- Execute a Redis Lua script with automatic fallback
-- @param redis Redis client instance
-- @param script string Lua script
-- @param keys table Array of keys
-- @param args table Array of arguments
-- @return any Script result
-- @return string|nil Error message
function _M.execute(redis, script, keys, args)
    -- Try to get cached SHA1
    local script_key = ngx.md5(script)
    local sha = script_shas[script_key]

    local result, err

    if sha then
        -- Try EVALSHA first (faster)
        result, err = redis:evalsha(sha, #keys, unpack(keys), unpack(args))

        if err and err:find("NOSCRIPT") then
            -- Script not loaded, load and retry
            sha = nil
            script_shas[script_key] = nil
        end
    end

    if not sha then
        -- Load script and execute
        sha, err = load_script(redis, script)
        if not sha then
            return nil, err
        end
        script_shas[script_key] = sha

        -- Execute by SHA1
        result, err = redis:evalsha(sha, #keys, unpack(keys), unpack(args))
    end

    if err then
        return nil, "script execution failed: " .. err
    end

    return result, nil
end

--- Clear script cache (for testing)
function _M.clear_cache()
    script_shas = {}
end

return _M
