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
local errors = require("unifra.jsonrpc.errors")
local whitelist = require("unifra.jsonrpc.whitelist")
local access = require("unifra.jsonrpc.access")
local rpc_policy = require("unifra.jsonrpc.rpc_policy")
local resources = require("unifra.jsonrpc.rpc_resources")
local cjson = require("cjson.safe")

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
        return errors.response(
            ctx,
            errors.ERR_SERVICE_UNAVAILABLE,
            nil,
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
    local profile, profile_err = rpc_policy.resolve(config_cache, network)
    if profile_err then
        core.log.error("invalid RPC policy configuration: ", profile_err)
        return errors.response(ctx, errors.ERR_SERVICE_UNAVAILABLE)
    end
    local valid, policy_err, policy_code = rpc_policy.validate(ctx.jsonrpc, network, is_paid,
        conf.method_policy == "free_only" or not ctx.consumer, "http", ctx, profile)
    if valid then valid, policy_err, policy_code = resources.acquire(ctx.jsonrpc, ctx) end
    if not valid then
        core.response.set_header("Content-Type", "application/json")
        return policy_code == -32000 and 429 or policy_code == -32603 and 503 or 400,
            jsonrpc.error_response(policy_code, policy_err, ctx.jsonrpc.ids and ctx.jsonrpc.ids[1])
    end
    if ctx.jsonrpc.rpc_policy then
        -- Forward the checked/capped parameters, including decoded gzip bodies.
        ngx.req.set_body_data(cjson.encode(ctx.jsonrpc.raw))
        ngx.req.clear_header("Content-Encoding")
        ngx.req.set_header("Accept-Encoding", "identity")
    end
end

function _M.header_filter(conf, ctx)
    if ctx.jsonrpc and ctx.jsonrpc.rpc_policy then
        ngx.header.content_length = nil
    end
end

function _M.body_filter(conf, ctx)
    if not (ctx.jsonrpc and ctx.jsonrpc.rpc_policy) then return end
    if ctx.rpc_response_done then ngx.arg[1] = nil; return end
    local chunk = ngx.arg[1] or ""
    ctx.rpc_response_size = (ctx.rpc_response_size or 0) + #chunk
    if ctx.rpc_response_size > resources.response_limit then
        ctx.rpc_response_done = true
        ctx.rpc_chunks = nil
        ngx.arg[1] = jsonrpc.error_response(-32603, "response exceeds policy limit", nil)
        ngx.arg[2] = true
        return
    end
    ctx.rpc_chunks = ctx.rpc_chunks or {}
    ctx.rpc_chunks[#ctx.rpc_chunks+1] = chunk
    ngx.arg[1] = nil
    if ngx.arg[2] then
        local body = table.concat(ctx.rpc_chunks)
        if #ctx.jsonrpc.rpc_policy.filters > 0 then
            local response = cjson.decode(body)
            response = response and resources.filter_response(ctx.jsonrpc,response)
            body = response and cjson.encode(response) or jsonrpc.error_response(-32603,
                "Service temporarily unavailable", nil)
        end
        ngx.arg[1] = body
        ctx.rpc_response_done = true
        ctx.rpc_chunks = nil
    end
end

function _M.log(conf, ctx)
    if ctx.jsonrpc and ctx.jsonrpc.rpc_policy then
        local p = ctx.jsonrpc.rpc_policy
        local status = tonumber(ctx.var.upstream_status)
        p.sent = status ~= nil
        p.completed = ctx.rpc_response_done and status ~= nil and status < 500
    end
    resources.finish(ctx.jsonrpc, ctx)
end

return _M
