--
-- Unifra Whitelist Plugin
--
-- Checks if JSON-RPC methods are allowed for the current network and user tier.
-- Free users can only access methods in the free list.
-- Paid users can access both free and paid methods.
--
-- Priority: 1900 (runs after jsonrpc-var parsing)
--

local core = require("apisix.core")
local jsonrpc = require("unifra.jsonrpc.core")
local whitelist = require("unifra.jsonrpc.whitelist")

local plugin_name = "unifra-whitelist"

local schema = {
    type = "object",
    properties = {
        config_path = {
            type = "string",
            default = "/opt/unifra-apisix/conf/whitelist.yaml",
            description = "Path to whitelist configuration file"
        },
        config_ttl = {
            type = "integer",
            default = 60,
            minimum = 0,
            description = "Config cache TTL in seconds (0 = no caching)"
        },
        paid_quota_threshold = {
            type = "integer",
            default = 1000000,
            description = "Monthly quota threshold to be considered paid user"
        },
        bypass_networks = {
            type = "array",
            items = { type = "string" },
            default = {},
            description = "Networks that bypass whitelist check (e.g., zetachain)"
        },
    },
}

local _M = {
    version = 0.1,
    priority = 1900,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


--- Check if network should bypass whitelist
local function should_bypass(network, bypass_list)
    if not network or not bypass_list then
        return false
    end

    for _, pattern in ipairs(bypass_list) do
        if network:find(pattern, 1, true) then
            return true
        end
    end

    return false
end


function _M.access(conf, ctx)
    -- Skip if not a JSON-RPC request (no parsed data)
    if not ctx.jsonrpc then
        return
    end

    -- Load whitelist configuration using unified config module
    -- Pass TTL directly (not via set_ttl) to avoid cross-route interference
    local config_cache, err = whitelist.load_config(ctx, conf.config_path, conf.config_ttl)
    if not config_cache then
        core.log.error("failed to load whitelist config: ", err, ", denying request")
        core.response.set_header("Content-Type", "application/json")
        return 500, jsonrpc.error_response(
            jsonrpc.ERROR_INTERNAL,
            "whitelist config unavailable",
            ctx.jsonrpc.ids and ctx.jsonrpc.ids[1]
        )
    end

    local network = ctx.var.unifra_network
    local methods = ctx.var.jsonrpc_methods

    -- Check bypass networks
    if should_bypass(network, conf.bypass_networks) then
        core.log.info("whitelist bypass for network: ", network)
        return
    end

    -- Determine if user is paid tier
    local monthly_quota = tonumber(ctx.var.monthly_quota) or 0
    local is_paid = monthly_quota > conf.paid_quota_threshold

    -- Check whitelist
    local ok, err = whitelist.check(network, methods, is_paid, config_cache)
    if not ok then
        core.log.warn("whitelist denied: ", err,
                      ", network=", network,
                      ", is_paid=", is_paid)

        core.response.set_header("Content-Type", "application/json")

        -- Determine appropriate error code
        local code = jsonrpc.ERROR_METHOD_NOT_FOUND
        if err:find("requires paid") then
            code = jsonrpc.ERROR_FORBIDDEN
        elseif err:find("unsupported network") then
            code = jsonrpc.ERROR_INVALID_REQUEST
        end

        return 405, jsonrpc.error_response(code, err, ctx.jsonrpc.ids and ctx.jsonrpc.ids[1])
    end
end


return _M
