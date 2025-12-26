--
-- Unifra Limit Monthly CU Plugin
--
-- Enforces monthly CU quota limits.
-- Checks if the user has exceeded their monthly allocation.
--
-- Priority: 1011 (runs after CU calculation, before per-second limit)
--

local core = require("apisix.core")
local jsonrpc = require("unifra.jsonrpc.core")
local billing = require("unifra.jsonrpc.billing")
local feature_flags = require("unifra.feature_flags")
local errors = require("unifra.jsonrpc.errors")

local plugin_name = "unifra-limit-monthly-cu"

local schema = {
    type = "object",
    properties = {
        quota_var = {
            type = "string",
            default = "monthly_quota",
            description = "Variable name containing monthly quota"
        },
        -- Redis configuration for atomic quota tracking
        redis_host = {
            type = "string",
            default = "127.0.0.1",
        },
        redis_port = {
            type = "integer",
            default = 6379,
        },
        redis_password = {
            type = "string",
            default = "",
        },
        redis_database = {
            type = "integer",
            default = 0,
        },
        redis_timeout = {
            type = "integer",
            default = 1000,
        },
        rejected_code = {
            type = "integer",
            default = 429,
        },
        rejected_msg = {
            type = "string",
            default = "monthly quota exceeded",
        },
    },
    required = {"redis_host"},
}

local _M = {
    version = 0.1,
    priority = 1011,  -- Between calculate-cu (1012) and limit-cu (1010)
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.access(conf, ctx)
    -- Check if atomic monthly quota tracking is enabled
    local use_atomic = feature_flags.is_enabled(ctx, "atomic_monthly_quota")

    if not use_atomic then
        -- Fallback to legacy behavior (non-atomic, not recommended)
        return _M.legacy_access(conf, ctx)
    end

    -- Get monthly quota from consumer configuration
    local quota = tonumber(ctx.var[conf.quota_var])
    if not quota or quota <= 0 then
        core.log.debug("No monthly quota configured, skipping check")
        return
    end

    -- Get consumer name
    local consumer_name = ctx.var.consumer_name
    if not consumer_name then
        core.log.warn("No consumer name available for monthly quota check")
        return
    end

    -- Get CU for this request
    local cu = tonumber(ctx.var.cu) or 1

    -- Build Redis configuration
    local redis_conf = {
        host = conf.redis_host,
        port = conf.redis_port,
        password = conf.redis_password,
        database = conf.redis_database,
        timeout = conf.redis_timeout,
    }

    -- Atomic check-and-increment via billing module
    local allowed, used, remaining, err = billing.check_and_increment(
        redis_conf,
        ctx,
        consumer_name,
        cu,
        quota
    )

    -- Handle error (fail-closed strategy for strong consistency)
    if err then
        core.log.error("Monthly quota check error: ", err, " (rejecting request)")
        return errors.response(
            ctx,
            errors.ERR_INTERNAL,
            "monthly quota service unavailable",
            ctx.jsonrpc and ctx.jsonrpc.ids and ctx.jsonrpc.ids[1]
        )
    end

    -- Set informational headers
    core.response.set_header("X-Monthly-Quota", quota)
    core.response.set_header("X-Monthly-Used", used)
    core.response.set_header("X-Monthly-Remaining", remaining)

    -- If not allowed, reject request
    if not allowed then
        return errors.response(
            ctx,
            errors.ERR_QUOTA_EXCEEDED,
            conf.rejected_msg,
            ctx.jsonrpc and ctx.jsonrpc.ids and ctx.jsonrpc.ids[1],
            {
                ["X-Monthly-Quota"] = quota,
                ["X-Monthly-Used"] = used,
            }
        )
    end
end


-- Legacy non-atomic implementation (deprecated, kept for compatibility)
function _M.legacy_access(conf, ctx)
    local quota = tonumber(ctx.var[conf.quota_var])
    local used = tonumber(ctx.var.monthly_used)  -- This is never set!

    if not quota then
        return
    end

    if not used then
        -- This always happens, so check is always skipped
        return
    end

    local cu = tonumber(ctx.var.cu) or 1

    if used + cu > quota then
        core.log.warn("monthly quota exceeded (legacy): used=", used,
                      ", quota=", quota, ", cu=", cu)

        core.response.set_header("Content-Type", "application/json")
        core.response.set_header("X-Monthly-Quota", quota)
        core.response.set_header("X-Monthly-Used", used)

        return conf.rejected_code, jsonrpc.error_response(
            jsonrpc.ERROR_QUOTA_EXCEEDED,
            conf.rejected_msg,
            ctx.jsonrpc and ctx.jsonrpc.ids and ctx.jsonrpc.ids[1]
        )
    end

    core.response.set_header("X-Monthly-Quota", quota)
    core.response.set_header("X-Monthly-Remaining", quota - used - cu)
end


return _M
