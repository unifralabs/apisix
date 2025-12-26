--
-- Unifra Limit CU Plugin
--
-- Enforces CU-based rate limiting per time window (default: per second).
-- Uses Redis for distributed rate limiting across multiple APISIX instances.
--
-- Priority: 1010 (runs after CU calculation)
--

local core = require("apisix.core")
local jsonrpc = require("unifra.jsonrpc.core")
local ratelimit = require("unifra.jsonrpc.ratelimit")
local redis_scripts = require("unifra.jsonrpc.redis_scripts")
local redis_circuit_breaker = require("unifra.jsonrpc.redis_circuit_breaker")
local feature_flags = require("unifra.feature_flags")
local errors = require("unifra.jsonrpc.errors")
local metrics = require("unifra.metrics")

local plugin_name = "unifra-limit-cu"

local schema = {
    type = "object",
    properties = {
        -- Rate limit configuration
        limit_var = {
            type = "string",
            default = "seconds_quota",
            description = "Variable name containing the CU limit"
        },
        time_window = {
            type = "integer",
            default = 1,
            minimum = 1,
            description = "Time window in seconds"
        },
        key_var = {
            type = "string",
            default = "consumer_name",
            description = "Variable name for rate limit key"
        },

        -- Redis configuration
        redis_host = {
            type = "string",
            default = "127.0.0.1"
        },
        redis_port = {
            type = "integer",
            default = 6379
        },
        redis_password = {
            type = "string",
            default = ""
        },
        redis_database = {
            type = "integer",
            default = 0
        },
        redis_timeout = {
            type = "integer",
            default = 1000,
            description = "Redis timeout in milliseconds"
        },

        -- Response configuration
        rejected_code = {
            type = "integer",
            default = 429
        },
        rejected_msg = {
            type = "string",
            default = "rate limit exceeded"
        },

        -- Degradation
        allow_degradation = {
            type = "boolean",
            default = true,
            description = "Allow requests when Redis is unavailable"
        },
        show_limit_header = {
            type = "boolean",
            default = true,
            description = "Show X-RateLimit-* headers"
        },
    },
    required = { "redis_host" },
}

local _M = {
    version = 0.1,
    priority = 1010,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.access(conf, ctx)
    -- Get CU for this request (calculated by unifra-calculate-cu)
    local cu = tonumber(ctx.var.cu) or 1

    -- Get rate limit from variable (set by key-auth or other plugins)
    local limit = tonumber(ctx.var[conf.limit_var])
    if not limit or limit <= 0 then
        -- No limit configured, skip rate limiting
        return
    end

    -- Get key for rate limiting
    local key_value = ctx.var[conf.key_var]
    if not key_value or key_value == "" then
        -- Fallback to remote address
        key_value = ctx.var.remote_addr
    end

    -- Check if sliding window is enabled
    local use_sliding_window = feature_flags.is_enabled(ctx, "sliding_window_rate_limit")

    if use_sliding_window then
        -- Use new sliding window algorithm
        return _M.sliding_window_check(conf, ctx, cu, limit, key_value)
    else
        -- Use legacy fixed window algorithm
        return _M.fixed_window_check(conf, ctx, cu, limit, key_value)
    end
end


--- Sliding window rate limiting (new, recommended)
function _M.sliding_window_check(conf, ctx, cu, limit, key_value)
    local redis_conf = {
        host = conf.redis_host,
        port = conf.redis_port,
        password = conf.redis_password,
        database = conf.redis_database,
        timeout = conf.redis_timeout,
    }

    -- Generate unique request ID for ZSET
    local request_id = ngx.var.request_id or (key_value .. ":" .. ngx.now() .. ":" .. math.random(1000000))

    -- Keys for sliding window (ZSET for timestamps + Hash for CU values)
    local key = "ratelimit:cu:sliding:" .. key_value
    local hash_key = "ratelimit:cu:sliding:" .. key_value .. ":values"

    -- Current timestamp in milliseconds
    local now_ms = ngx.now() * 1000
    local window_ms = conf.time_window * 1000

    -- Execute sliding window script via circuit breaker
    local result, script_err, blocked = redis_circuit_breaker.execute(
        redis_conf,
        ctx,
        function()
            local redis = require("resty.redis")
            local red = redis:new()
            red:set_timeout(redis_conf.timeout or 1000)

            local ok, conn_err = red:connect(redis_conf.host, redis_conf.port or 6379)
            if not ok then
                metrics.record_redis_op("connect", false)
                return nil, "redis connect failed: " .. (conn_err or "unknown")
            end

            if redis_conf.password and redis_conf.password ~= "" then
                local ok, auth_err = red:auth(redis_conf.password)
                if not ok then
                    metrics.record_redis_op("auth", false)
                    return nil, "redis auth failed: " .. (auth_err or "unknown")
                end
            end

            if redis_conf.database and redis_conf.database > 0 then
                red:select(redis_conf.database)
            end

            -- Execute sliding window script (needs 2 keys: ZSET + Hash)
            local script_result, exec_err = redis_scripts.execute(
                red,
                redis_scripts.SLIDING_WINDOW_SCRIPT,
                {key, hash_key},
                {now_ms, window_ms, limit, cu, request_id}
            )

            red:set_keepalive(10000, 100)

            if exec_err then
                metrics.record_redis_op("eval", false)
                return nil, exec_err
            end

            metrics.record_redis_op("eval", true)
            return script_result, nil
        end,
        conf.allow_degradation  -- fail-open if configured
    )

    -- Handle circuit breaker block or error
    if blocked or script_err then
        if conf.allow_degradation then
            core.log.warn("rate limit degradation (sliding window): allowing request")
            return
        else
            return errors.response(
                ctx,
                errors.ERR_INTERNAL,
                "rate limiting service unavailable",
                ctx.jsonrpc and ctx.jsonrpc.ids and ctx.jsonrpc.ids[1]
            )
        end
    end

    -- Parse result: {allowed (1/0), current_count, remaining}
    local allowed = (result[1] == 1)
    local current = tonumber(result[2]) or 0
    local remaining = tonumber(result[3]) or 0

    -- Set rate limit headers
    if conf.show_limit_header then
        core.response.set_header("X-RateLimit-Limit", limit)
        core.response.set_header("X-RateLimit-Remaining", remaining)
        core.response.set_header("X-RateLimit-Window", conf.time_window)
        core.response.set_header("X-RateLimit-Type", "sliding")
    end

    -- Record metrics
    if not allowed then
        metrics.inc_rate_limit(ctx, "second")
    end

    if not allowed then
        core.log.warn("rate limit exceeded (sliding): key=", key_value,
                      ", current=", current, ", limit=", limit, ", cu=", cu)

        return errors.response(
            ctx,
            errors.ERR_RATE_LIMITED,
            conf.rejected_msg,
            ctx.jsonrpc and ctx.jsonrpc.ids and ctx.jsonrpc.ids[1],
            {
                ["Retry-After"] = conf.time_window,
                ["X-RateLimit-Limit"] = limit,
                ["X-RateLimit-Remaining"] = 0,
            }
        )
    end

    core.log.debug("rate limit passed (sliding): key=", key_value,
                   ", remaining=", remaining, "/", limit)
end


--- Fixed window rate limiting (legacy, deprecated)
function _M.fixed_window_check(conf, ctx, cu, limit, key_value)
    local redis_conf = {
        host = conf.redis_host,
        port = conf.redis_port,
        password = conf.redis_password,
        database = conf.redis_database,
        timeout = conf.redis_timeout,
    }

    -- Generate rate limit key (includes time bucket)
    local key = ratelimit.make_key(key_value, conf.time_window)

    -- Check rate limit (legacy implementation)
    local allowed, remaining, err = ratelimit.check_and_incr(
        redis_conf, key, cu, limit, conf.time_window
    )

    if err then
        core.log.error("rate limit redis error (fixed): ", err)

        if conf.allow_degradation then
            core.log.warn("rate limit degradation (fixed): allowing request")
            return
        else
            return errors.response(
                ctx,
                errors.ERR_INTERNAL,
                "rate limiting service unavailable",
                ctx.jsonrpc and ctx.jsonrpc.ids and ctx.jsonrpc.ids[1]
            )
        end
    end

    -- Set rate limit headers
    if conf.show_limit_header then
        core.response.set_header("X-RateLimit-Limit", limit)
        core.response.set_header("X-RateLimit-Remaining", remaining or 0)
        core.response.set_header("X-RateLimit-Reset", conf.time_window)
        core.response.set_header("X-RateLimit-Type", "fixed")
    end

    if not allowed then
        metrics.inc_rate_limit(ctx, "second")

        core.log.warn("rate limit exceeded (fixed): key=", key_value,
                      ", limit=", limit, ", cu=", cu)

        return errors.response(
            ctx,
            errors.ERR_RATE_LIMITED,
            conf.rejected_msg,
            ctx.jsonrpc and ctx.jsonrpc.ids and ctx.jsonrpc.ids[1],
            {
                ["Retry-After"] = conf.time_window,
            }
        )
    end

    core.log.debug("rate limit passed (fixed): key=", key_value,
                   ", remaining=", remaining, "/", limit)
end


return _M
