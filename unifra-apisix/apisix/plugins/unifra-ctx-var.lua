--
-- Unifra Context Variable Injection Plugin
--
-- This plugin injects custom variables into ctx.var from plugin configuration.
-- Used primarily in Consumer configs to set quota variables like:
-- - seconds_quota: CU limit per second
-- - monthly_quota: Monthly CU limit
-- - monthly_used: Current monthly usage
--
-- Example Consumer config:
-- {
--   "plugins": {
--     "unifra-ctx-var": {
--       "seconds_quota": "100",
--       "monthly_quota": "1000000"
--     }
--   }
-- }
--
-- Priority: 24000 (runs after key-auth (2500), before jsonrpc-var (26000))
-- Note: Priority is high but lower than jsonrpc-var to ensure variables
-- are set before other Unifra plugins run.
--

local core = require("apisix.core")

local plugin_name = "unifra-ctx-var"

-- Schema allows any string key-value pairs
local schema = {
    type = "object",
    description = "Key-value pairs for variables to inject into ctx.var",
    additionalProperties = {
        type = "string"
    }
}

local _M = {
    version = 0.1,
    priority = 24000,  -- High priority, runs early but after auth
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.access(conf, ctx)
    if not conf then
        return
    end

    -- Inject all configured variables into ctx.var
    for key, value in pairs(conf) do
        -- Skip meta keys
        if key ~= "_meta" and key ~= "disable" then
            ctx.var[key] = value
            core.log.debug("unifra-ctx-var: set ", key, " = ", value)
        end
    end
end


return _M
