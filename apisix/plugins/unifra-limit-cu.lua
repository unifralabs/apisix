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

    -- Build Redis configuration
    local redis_conf = {
        host = conf.redis_host,
        port = conf.redis_port,
        password = conf.redis_password,
        database = conf.redis_database,
        timeout = conf.redis_timeout,
    }

    -- Generate rate limit key
    local key = ratelimit.make_key(key_value, conf.time_window)

    -- Check rate limit
    local allowed, remaining, err = ratelimit.check_and_incr(
        redis_conf, key, cu, limit, conf.time_window
    )

    if err then
        core.log.error("rate limit redis error: ", err)

        if conf.allow_degradation then
            -- Allow request when Redis fails
            core.log.warn("rate limit degradation: allowing request")
            return
        else
            -- Reject request when Redis fails
            core.response.set_header("Content-Type", "application/json")
            return 503, jsonrpc.error_response(
                jsonrpc.ERROR_INTERNAL,
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
    end

    if not allowed then
        core.log.warn("rate limit exceeded: key=", key_value,
                      ", limit=", limit, ", cu=", cu)

        core.response.set_header("Content-Type", "application/json")
        core.response.set_header("Retry-After", conf.time_window)

        return conf.rejected_code, jsonrpc.error_response(
            jsonrpc.ERROR_RATE_LIMITED,
            conf.rejected_msg,
            ctx.jsonrpc and ctx.jsonrpc.ids and ctx.jsonrpc.ids[1]
        )
    end

    core.log.info("rate limit passed: key=", key_value,
                  ", remaining=", remaining, "/", limit)
end


return _M
