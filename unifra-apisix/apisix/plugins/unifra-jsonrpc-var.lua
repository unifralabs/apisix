--
-- Unifra JSON-RPC Variable Injection Plugin
--
-- This is the CORE plugin that must run first (highest priority).
-- It parses JSON-RPC requests and injects variables into ctx.var cache.
--
-- Key insight: By writing to ctx.var cache with high priority,
-- subsequent plugins access our parsed values directly without
-- triggering any fallback parsing mechanisms.
--
-- Priority: 26000 (must be highest to run before all other plugins)
--

local core = require("apisix.core")
local jsonrpc = require("unifra.jsonrpc.core")

local plugin_name = "unifra-jsonrpc-var"

local schema = {
    type = "object",
    properties = {
        network = {
            type = "string",
            description = "Override network name (useful for testing or single-network routes)"
        },
    },
}

local _M = {
    version = 0.1,
    priority = 26000,  -- Highest priority - must run first!
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.rewrite(conf, ctx)
    -- Skip non-POST requests (GET for WebSocket handshake, etc.)
    if ctx.var.request_method ~= "POST" then
        return
    end

    -- Skip WebSocket upgrade requests
    local upgrade = ctx.var.http_upgrade
    if upgrade and upgrade:lower() == "websocket" then
        return
    end

    -- Check Content-Type (must be JSON)
    local content_type = core.request.header(ctx, "Content-Type") or ""
    if not content_type:find("application/json", 1, true) then
        return
    end

    -- Read request body
    local body, err = core.request.get_body()
    if not body then
        core.log.warn("failed to read request body: ", err)
        return
    end

    -- Parse JSON-RPC request
    local result, err = jsonrpc.parse(body)
    if err then
        -- Return JSON-RPC error response
        local code = jsonrpc.ERROR_PARSE
        if err:find("empty batch") or err:find("missing method") then
            code = jsonrpc.ERROR_INVALID_REQUEST
        end

        core.response.set_header("Content-Type", "application/json")
        return 200, jsonrpc.error_response(code, err, nil)
    end

    -- === KEY MECHANISM ===
    -- Write parsed values directly to ctx.var cache
    -- This "hijacks" the variable access - subsequent plugins will
    -- get these cached values without triggering any fallback parsing

    ctx.var.jsonrpc_method = result.method
    ctx.var.jsonrpc_methods = result.methods
    ctx.var.jsonrpc_is_batch = result.is_batch
    ctx.var.jsonrpc_count = result.count

    -- Also store full result in ctx for plugins that need more data
    ctx.jsonrpc = result

    -- Extract network from config or host header
    local network = conf.network or jsonrpc.extract_network(ctx.var.host)
    if network then
        ctx.var.unifra_network = network
    end

    core.log.info("jsonrpc parsed: method=", result.method,
                  ", count=", result.count,
                  ", network=", network or "unknown")
end


return _M
