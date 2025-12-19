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

local plugin_name = "unifra-limit-monthly-cu"

local schema = {
    type = "object",
    properties = {
        quota_var = {
            type = "string",
            default = "monthly_quota",
            description = "Variable name containing monthly quota"
        },
        used_var = {
            type = "string",
            default = "monthly_used",
            description = "Variable name containing current usage"
        },
        rejected_code = {
            type = "integer",
            default = 429
        },
        rejected_msg = {
            type = "string",
            default = "monthly quota exceeded"
        },
    },
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
    -- Get monthly quota and current usage from context variables
    -- These are typically set by key-auth plugin from consumer configuration
    local quota = tonumber(ctx.var[conf.quota_var])
    local used = tonumber(ctx.var[conf.used_var])

    -- If no quota configured, skip check
    if not quota then
        return
    end

    -- If no usage data, skip check (first request or data not available)
    if not used then
        return
    end

    -- Get CU for this request
    local cu = tonumber(ctx.var.cu) or 1

    -- Check if this request would exceed quota
    if used + cu > quota then
        core.log.warn("monthly quota exceeded: used=", used,
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

    -- Set informational headers
    core.response.set_header("X-Monthly-Quota", quota)
    core.response.set_header("X-Monthly-Remaining", quota - used - cu)
end


return _M
