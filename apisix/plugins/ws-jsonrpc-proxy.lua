--
-- WebSocket JSON-RPC Proxy Plugin
-- This plugin intercepts WebSocket connections and applies rate limiting and access control
-- on a per-message basis for JSON-RPC requests.
--
-- Architecture:
-- 1. During WebSocket handshake, normal APISIX plugins (key-auth, custom-ctx-var) run
-- 2. After handshake, this plugin becomes a man-in-the-middle proxy
-- 3. For each JSON-RPC message, it manually injects variables and calls other plugins
--

local core = require("apisix.core")
local balancer = require("apisix.balancer")
local upstream_mod = require("apisix.upstream")
local ngx = ngx
local ipairs = ipairs
local type = type

local plugin_name = "ws-jsonrpc-proxy"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 1004,  -- Run after proxy-rewrite (1008), before limit-conn (1003)
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- Helper function to calculate CU for a JSON-RPC method
-- This mimics the calculate-cu plugin logic
local function calculate_cu_for_method(method, calculate_cu_conf)
    if not calculate_cu_conf or not calculate_cu_conf.methods then
        return 1
    end
    return calculate_cu_conf.methods[method] or 1
end

-- Helper function to run plugins on a WebSocket message
-- ctx.plugins structure: {plugin_obj1, plugin_conf1, plugin_obj2, plugin_conf2, ...}
-- We iterate with step 2: plugins[i] is plugin_obj, plugins[i+1] is plugin_conf
local function run_plugins_on_message(ctx, req_or_batch)
    local api_ctx = ctx

    -- Use the already-merged plugin configuration from ctx.plugins
    -- This includes service + route + consumer plugins
    if not api_ctx.plugins or #api_ctx.plugins == 0 then
        return 200, nil
    end

    -- Handle both single requests and batch requests
    local requests = {}
    local is_batch = false

    if type(req_or_batch) == "table" then
        if req_or_batch.method then
            -- Single request
            requests = {req_or_batch}
        elseif type(req_or_batch[1]) == "table" then
            -- Batch request (array of requests)
            is_batch = true
            requests = req_or_batch
        else
            return 400, { error_msg = "Invalid JSON-RPC request format" }
        end
    else
        return 400, { error_msg = "Invalid JSON-RPC request format" }
    end

    -- Collect all methods for batch processing
    local methods = {}
    for _, req in ipairs(requests) do
        if req.method then
            core.table.insert(methods, req.method)
        end
    end

    if #methods == 0 then
        return 400, { error_msg = "No valid methods in request" }
    end

    -- Set variables for plugin checks
    if is_batch then
        api_ctx.var.jsonrpc_method = "batch"
        api_ctx.var.jsonrpc_methods = methods
    else
        api_ctx.var.jsonrpc_method = requests[1].method
    end

    -- Iterate plugins with step 2: plugins[i] is plugin_obj, plugins[i+1] is plugin_conf
    local plugins = api_ctx.plugins

    -- Find and run calculate-cu plugin if enabled
    local total_cu = 0
    for i = 1, #plugins, 2 do
        local plugin_obj = plugins[i]
        local plugin_conf = plugins[i + 1]
        if plugin_obj.name == "calculate-cu" then
            local disabled = plugin_conf._meta and plugin_conf._meta.disable
            if not disabled then
                for _, method in ipairs(methods) do
                    total_cu = total_cu + calculate_cu_for_method(method, plugin_conf)
                end
            end
            break
        end
    end
    api_ctx.var.cu = total_cu > 0 and total_cu or #methods

    -- Run whitelist plugin if enabled
    for i = 1, #plugins, 2 do
        local plugin_obj = plugins[i]
        local plugin_conf = plugins[i + 1]
        if plugin_obj.name == "whitelist" then
            local disabled = plugin_conf._meta and plugin_conf._meta.disable
            if not disabled then
                local whitelist = require("apisix.plugins.whitelist")
                local status_code, body = whitelist.access(plugin_conf, api_ctx)
                if status_code then
                    return status_code, body
                end
            end
            break
        end
    end

    -- Run limit-cu plugin if enabled (rate limiting per second/minute)
    for i = 1, #plugins, 2 do
        local plugin_obj = plugins[i]
        local plugin_conf = plugins[i + 1]
        if plugin_obj.name == "limit-cu" then
            local disabled = plugin_conf._meta and plugin_conf._meta.disable
            if not disabled then
                local limit_cu = require("apisix.plugins.limit-cu.init")
                local status_code, body = limit_cu.rate_limit(plugin_conf, api_ctx)
                if status_code then
                    return status_code, body
                end
            end
            break
        end
    end

    -- Run limit-monthly-cu plugin if enabled (monthly quota)
    for i = 1, #plugins, 2 do
        local plugin_obj = plugins[i]
        local plugin_conf = plugins[i + 1]
        if plugin_obj.name == "limit-monthly-cu" then
            local disabled = plugin_conf._meta and plugin_conf._meta.disable
            if not disabled then
                local limit_monthly_cu = require("apisix.plugins.limit-monthly-cu")
                local status_code, body = limit_monthly_cu.access(plugin_conf, api_ctx)
                if status_code then
                    return status_code, body
                end
            end
            break
        end
    end

    return 200, nil
end

function _M.access(conf, ctx)
    -- Only intercept WebSocket upgrade requests
    if ctx.var.http_upgrade ~= "websocket" then
        return
    end

    core.log.info("ws-jsonrpc-proxy: intercepting WebSocket connection for ", ctx.var.host)

    -- Initialize upstream configuration (normally done in handle_upstream after access phase)
    -- This is needed because we're picking the server during access phase
    local route = ctx.matched_route
    local route_val = route.value

    -- Load upstream by upstream_id if specified
    local up_id = route_val.upstream_id
    if up_id then
        local upstream = upstream_mod.get_by_id(up_id)
        if not upstream then
            core.log.error("ws-jsonrpc-proxy: upstream not found: ", up_id)
            return 502
        end
        ctx.matched_upstream = upstream
    else
        -- Use upstream from route directly
        ctx.matched_upstream = route_val.upstream
    end

    if not ctx.matched_upstream then
        core.log.error("ws-jsonrpc-proxy: no upstream configured")
        return 502
    end

    local code, err = upstream_mod.set_by_route(route, ctx)
    if code then
        core.log.error("ws-jsonrpc-proxy: failed to set upstream: ", err)
        return code
    end

    -- Pick upstream server using APISIX's balancer
    -- This ensures we use the same load balancing, health checks, and retry logic as HTTP
    local server, err = balancer.pick_server(route, ctx)
    if not server then
        core.log.error("ws-jsonrpc-proxy: failed to pick server: ", err)
        return 502
    end

    core.log.info("ws-jsonrpc-proxy: picked server ", server.host, ":", server.port)

    -- Load required modules here to avoid loading them on every HTTP request
    local ws_server = require("resty.websocket.server")
    local ws_client = require("resty.websocket.client")
    local cjson = require("cjson.safe")

    -- Establish server-side WebSocket connection (accept client connection)
    local wb, err = ws_server:new({
        timeout = 60000,  -- 60 seconds
        max_payload_len = 65535,
    })

    if not wb then
        core.log.error("ws-jsonrpc-proxy: failed to create WebSocket server: ", err)
        return 500
    end

    -- Build upstream WebSocket URI with proper path and query string
    local upstream_scheme = ctx.upstream_scheme
    local ws_scheme = "ws"
    local use_ssl = false
    if upstream_scheme == "https" or upstream_scheme == "grpcs" then
        ws_scheme = "wss"
        use_ssl = true
    end

    -- Use the rewritten URI from proxy-rewrite plugin if available
    -- IMPORTANT: ctx.var.upstream_uri may already contain query string when ctx.var.is_args == "?"
    -- (see apisix/plugins/proxy-rewrite.lua:291-296), so we should NOT blindly append args again
    local upstream_uri = ctx.var.upstream_uri or ctx.var.uri

    -- Build full upstream WebSocket URL
    local upstream_url = ws_scheme .. "://" .. server.host .. ":" .. server.port .. upstream_uri
    core.log.info("ws-jsonrpc-proxy: connecting to upstream ", upstream_url)

    -- Connect to upstream WebSocket server
    local wc = ws_client:new()

    -- Prepare connection options
    local conn_opts = {
        timeout = 10000,
    }

    -- Forward all client request headers to upstream
    -- Skip WebSocket handshake headers that will be handled by lua-resty-websocket
    local skip_headers = {
        ["connection"] = true,
        ["upgrade"] = true,
        ["sec-websocket-key"] = true,
        ["sec-websocket-version"] = true,
        ["sec-websocket-extensions"] = true,
    }

    local headers = {}
    local req_headers = ngx.req.get_headers(0)  -- 0 = no limit
    for k, v in pairs(req_headers) do
        local lower_k = k:lower()
        if not skip_headers[lower_k] then
            headers[k] = v
        end
    end

    -- Override Host header if upstream_host is set (by proxy-rewrite or upstream config)
    local upstream_host = ctx.var.upstream_host
    if upstream_host then
        headers["Host"] = upstream_host
    end

    -- Forward any custom headers set by proxy-rewrite plugin
    if ctx.upstream_headers then
        for k, v in pairs(ctx.upstream_headers) do
            headers[k] = v
        end
    end

    conn_opts.headers = headers

    -- Apply TLS/mTLS settings from upstream configuration
    -- This ensures WSS connections respect the same TLS settings as HTTPS
    if use_ssl then
        local up_conf = ctx.upstream_conf

        -- SSL verification setting
        -- IMPORTANT: Match APISIX's default behavior - Nginx's proxy_ssl_verify defaults to OFF
        -- We only enable verification when explicitly configured in upstream.tls.verify
        if up_conf and up_conf.tls and up_conf.tls.verify ~= nil then
            conn_opts.ssl_verify = up_conf.tls.verify
        else
            -- Default to false to match Nginx/APISIX default behavior
            -- This ensures existing HTTPS upstreams with self-signed or private CA certs keep working
            conn_opts.ssl_verify = false
        end

        -- Client certificate for mTLS
        if up_conf and up_conf.tls then
            if up_conf.tls.client_cert and up_conf.tls.client_key then
                conn_opts.client_cert = up_conf.tls.client_cert
                conn_opts.client_priv_key = up_conf.tls.client_key
            end
        end

        -- Check for client_cert_id (SSL reference)
        if ctx.upstream_ssl then
            local ssl = ctx.upstream_ssl
            if ssl.value then
                if ssl.value.cert then
                    conn_opts.client_cert = ssl.value.cert
                end
                if ssl.value.key then
                    conn_opts.client_priv_key = ssl.value.key
                end
            end
        end

        -- Set SNI (Server Name Indication) for TLS handshake
        -- Use upstream_host if available, otherwise use the server domain/host
        local sni = upstream_host or server.domain or server.host
        if sni then
            -- Remove port from SNI if present
            sni = sni:match("^([^:]+)")
            conn_opts.server_name = sni
        end

        core.log.info("ws-jsonrpc-proxy: TLS settings - ssl_verify: ", conn_opts.ssl_verify,
                      ", sni: ", conn_opts.server_name or "nil",
                      ", has_client_cert: ", conn_opts.client_cert ~= nil)
    end

    local ok, err = wc:connect(upstream_url, conn_opts)

    if not ok then
        core.log.error("ws-jsonrpc-proxy: failed to connect to upstream WebSocket: ", err)
        wb:send_close()
        return 502
    end

    core.log.info("ws-jsonrpc-proxy: connected to upstream")

    -- Spawn a thread to forward downstream messages (upstream -> client)
    local downstream_thread = ngx.thread.spawn(function()
        while true do
            local data, typ, err = wc:recv_frame()
            if not data then
                if err ~= "timeout" then
                    core.log.info("ws-jsonrpc-proxy: upstream WebSocket closed: ", err or "unknown")
                end
                break
            end

            local bytes, send_err = wb:send_frame(true, typ, data)
            if not bytes then
                core.log.error("ws-jsonrpc-proxy: failed to send frame to client: ", send_err)
                break
            end
        end
        -- Close client connection when upstream closes
        wb:send_close()
    end)

    -- Main thread handles upstream messages (client -> upstream)
    while true do
        local data, typ, err = wb:recv_frame()

        if not data then
            if err ~= "timeout" then
                core.log.info("ws-jsonrpc-proxy: client WebSocket closed: ", err or "unknown")
            end
            break
        end

        -- Handle different frame types
        if typ == "close" then
            core.log.info("ws-jsonrpc-proxy: client sent close frame")
            wc:send_close()
            break
        elseif typ == "ping" then
            wb:send_pong()
        elseif typ == "pong" then
            -- Forward pong to upstream
            wc:send_pong()
        elseif typ == "text" then
            -- Parse JSON-RPC request (single or batch)
            local req_or_batch, decode_err = cjson.decode(data)

            if req_or_batch then
                -- Run plugins on this message (handles both single and batch)
                local status_code, error_body = run_plugins_on_message(ctx, req_or_batch)

                if status_code ~= 200 then
                    -- Plugin rejected the request
                    local error_msg = "Request rejected"
                    local error_code = status_code

                    if error_body and type(error_body) == "table" then
                        if error_body.error_msg then
                            error_msg = error_body.error_msg
                        elseif error_body.error and error_body.error.message then
                            error_msg = error_body.error.message
                            error_code = error_body.error.code or status_code
                        end
                    end

                    -- Determine the ID to use in error response
                    local response_id = nil
                    if type(req_or_batch) == "table" then
                        if req_or_batch.id then
                            response_id = req_or_batch.id
                        elseif type(req_or_batch[1]) == "table" and req_or_batch[1].id then
                            -- For batch, use first request's ID (or could return array of errors)
                            response_id = req_or_batch[1].id
                        end
                    end

                    local error_response = cjson.encode({
                        jsonrpc = "2.0",
                        error = { code = error_code, message = error_msg },
                        id = response_id
                    })
                    wb:send_text(error_response)
                    goto continue_loop
                end
            end

            -- Forward to upstream
            local bytes, send_err = wc:send_text(data)
            if not bytes then
                core.log.error("ws-jsonrpc-proxy: failed to send text to upstream: ", send_err)
                break
            end
        elseif typ == "binary" then
            -- Forward binary frames directly (no inspection)
            local bytes, send_err = wc:send_binary(data)
            if not bytes then
                core.log.error("ws-jsonrpc-proxy: failed to send binary to upstream: ", send_err)
                break
            end
        else
            -- Forward other frame types directly
            core.log.warn("ws-jsonrpc-proxy: unknown frame type: ", typ)
        end

        ::continue_loop::
    end

    -- Cleanup
    core.log.info("ws-jsonrpc-proxy: cleaning up connection")
    ngx.thread.wait(downstream_thread)
    wc:send_close()

    -- Return 200 to signal successful handling
    return 200
end

return _M
