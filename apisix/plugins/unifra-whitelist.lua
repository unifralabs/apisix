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
local access = require("unifra.jsonrpc.access")

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
        bypass_networks = {
            type = "array",
            items = { type = "string" },
            default = {},
            description = "Networks that bypass whitelist check (e.g., zetachain)"
        },
    },
}

for name, field in pairs(access.schema_properties) do
    schema.properties[name] = field
end

local _M = {
    version = 0.1,
    priority = 1900,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.access(conf, ctx)
    -- Skip if not a JSON-RPC request (no parsed data)
    if not ctx.jsonrpc then
        if conf.method_policy == "free_only" and ctx.var.request_method == "POST" then
            core.response.set_header("Content-Type", "application/json")
            return 400, jsonrpc.error_response(jsonrpc.ERROR_INVALID_REQUEST,
                "JSON-RPC request was not parsed", nil)
        end
        return
    end

    -- Load whitelist configuration using unified config module
    -- Pass TTL directly (not via set_ttl) to avoid cross-route interference
    local config_cache, err = whitelist.load_config(ctx, conf.config_path, conf.config_ttl)
    if err or not config_cache then
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
    if access.should_bypass(conf, network) then
        core.log.info("whitelist bypass for network: ", network)
        return
    end

    -- Determine if user is paid tier
    local is_paid, entitlement_source = access.is_paid(conf, ctx)
    ctx.var.rpc_entitlement_source = entitlement_source

    -- Check whitelist
    local ok, err = whitelist.check(network, methods, is_paid, config_cache)
    if not ok then
        core.log.warn("whitelist denied: ", err,
                      ", network=", network,
                      ", is_paid=", is_paid,
                      ", entitlement_source=", entitlement_source)

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
