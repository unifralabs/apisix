--
-- Unifra Limit Monthly CU Plugin
--
-- Enforces monthly CU quota limits.
-- Checks if the user has exceeded their monthly allocation.
--
-- Priority: 1010 (runs after CU calculation, before per-second limit)
--

local core = require("apisix.core")
local jsonrpc = require("unifra.jsonrpc.core")
local billing = require("unifra.jsonrpc.billing")
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
        quota_key_var = {
            type = "string",
            default = "quota_key",
            description = "Variable name for quota key (user_id for shared quotas). Falls back to consumer_name if not set."
        },
        -- Redis configuration (Optional override)
        redis_host = { type = "string" },
        redis_port = { type = "integer" },
        redis_password = { type = "string" },
        redis_database = { type = "integer" },
        redis_timeout = { type = "integer" },
        
        rejected_code = {
            type = "integer",
            default = 429,
        },
        rejected_msg = {
            type = "string",
            default = "monthly quota exceeded",
        },
    },
}

local metadata_schema = {
    type = "object",
    properties = {
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
    }
}

local _M = {
    version = 0.1,
    priority = 1010,
    name = plugin_name,
    schema = schema,
    metadata_schema = metadata_schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.access(conf, ctx)
    -- Get monthly quota from consumer configuration
    local quota = tonumber(ctx.var[conf.quota_var])
    if not quota or quota <= 0 then
        core.log.debug("No monthly quota configured, skipping check")
        return
    end

    -- Get consumer name (required for fallback)
    local consumer_name = ctx.var.consumer_name
    if not consumer_name then
        core.log.warn("No consumer name available for monthly quota check")
        return
    end

    -- Get quota_key: use configured variable, fallback to consumer_name
    -- This allows multiple API keys (consumers) to share a single user's quota
    local quota_key = ctx.var[conf.quota_key_var]
    if not quota_key or quota_key == "" then
        quota_key = consumer_name
        core.log.debug("quota_key not set, using consumer_name: ", consumer_name)
    else
        core.log.debug("Using quota_key for shared quota: ", quota_key)
    end

    -- Get CU for this request
    local cu = tonumber(ctx.var.cu) or 1

    -- Load Metadata
    local plugin_mod = require("apisix.plugin")
    local metadata = plugin_mod.plugin_metadata(plugin_name)
    local meta_conf = metadata and metadata.value or {}
    
    -- Ensure defaults are populated from metadata_schema
    local valid, err = core.schema.check(metadata_schema, meta_conf)
    if not valid then
        core.log.error("limit-monthly-cu: failed to validate metadata: ", err)
    end

    -- Build Redis configuration (Route > Metadata > Default)
    local redis_conf = {
        host = conf.redis_host or meta_conf.redis_host,
        port = conf.redis_port or meta_conf.redis_port,
        password = conf.redis_password or meta_conf.redis_password,
        database = conf.redis_database or meta_conf.redis_database,
        timeout = conf.redis_timeout or meta_conf.redis_timeout,
    }

    -- Atomic check-and-increment via billing module
    local allowed, used, remaining, err = billing.check_and_increment(
        redis_conf,
        ctx,
        quota_key,
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


return _M
