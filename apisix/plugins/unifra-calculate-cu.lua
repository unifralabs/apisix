--
-- Unifra Calculate CU Plugin
--
-- Calculates Compute Unit (CU) consumption for JSON-RPC requests.
-- The calculated CU is stored in ctx.var.cu for use by rate limiting plugins.
--
-- Priority: 1012 (runs after whitelist check, before rate limiting)
--

local core = require("apisix.core")
local cu = require("unifra.jsonrpc.cu")

local plugin_name = "unifra-calculate-cu"

local schema = {
    type = "object",
    properties = {
        config_path = {
            type = "string",
            default = "/opt/unifra-apisix/conf/cu-pricing.yaml",
            description = "Path to CU pricing configuration file"
        },
        config_ttl = {
            type = "integer",
            default = 60,
            minimum = 0,
            description = "Config cache TTL in seconds (0 = no caching)"
        },
    },
}

local _M = {
    version = 0.1,
    priority = 1012,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.access(conf, ctx)
    -- Skip if not a JSON-RPC request
    if not ctx.jsonrpc then
        ctx.var.cu = 1  -- Default CU for non-JSONRPC requests
        return
    end

    -- Load CU pricing configuration using unified config module
    -- Pass TTL directly (not via set_ttl) to avoid cross-route interference
    local config_cache, err = cu.load_config(ctx, conf.config_path, conf.config_ttl)
    if not config_cache then
        core.log.error("failed to load CU config: ", err, ", using default CU=1")
        ctx.var.cu = 1
        return
    end

    -- Calculate total CU for all methods
    local methods = ctx.var.jsonrpc_methods
    local total_cu = cu.calculate(methods, config_cache)

    -- Store in ctx.var for rate limiting plugins
    ctx.var.cu = total_cu

    core.log.info("calculated cu: ", total_cu, " for ", #methods, " methods")
end


return _M
