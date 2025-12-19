--
-- Unifra WebSocket JSON-RPC Proxy Plugin
--
-- This plugin intercepts WebSocket connections and applies rate limiting
-- and access control on a per-message basis for JSON-RPC requests.
--
-- Architecture:
-- 1. During WebSocket handshake, normal APISIX plugins (key-auth, etc.) run
-- 2. After handshake, this plugin becomes a man-in-the-middle proxy
-- 3. For each JSON-RPC message, it applies whitelist and rate limiting
--
-- Priority: 999 (runs after other plugins, before response phase)
--

local core = require("apisix.core")
local balancer = require("apisix.balancer")
local upstream_mod = require("apisix.upstream")
local jsonrpc = require("unifra.jsonrpc.core")
local whitelist_mod = require("unifra.jsonrpc.whitelist")
local cu_mod = require("unifra.jsonrpc.cu")
local ratelimit_mod = require("unifra.jsonrpc.ratelimit")

local ngx = ngx
local ipairs = ipairs
local type = type

local plugin_name = "unifra-ws-jsonrpc-proxy"

local schema = {
    type = "object",
    properties = {
        -- Whitelist configuration
        whitelist_config_path = {
            type = "string",
            default = "/opt/unifra-apisix/conf/whitelist.yaml"
        },
        -- CU configuration
        cu_config_path = {
            type = "string",
            default = "/opt/unifra-apisix/conf/cu-pricing.yaml"
        },
        -- Rate limit configuration
        enable_rate_limit = {
            type = "boolean",
            default = true
        },
        redis_host = {
            type = "string",
            default = "127.0.0.1"
        },
        redis_port = {
            type = "integer",
            default = 6379
        },
        redis_password = {
            type = "string",
            default = ""
        },
        redis_database = {
            type = "integer",
            default = 0
        },
        redis_timeout = {
            type = "integer",
            default = 1000
        },
        -- Timeout
        ws_timeout = {
            type = "integer",
            default = 60000,
            description = "WebSocket timeout in milliseconds"
        },
        -- Paid tier threshold
        paid_quota_threshold = {
            type = "integer",
            default = 1000000
        },
        -- Bypass networks
        bypass_networks = {
            type = "array",
            items = { type = "string" },
            default = {}
        },
        -- Network override (for testing or single-network routes)
        network = {
            type = "string",
            description = "Override network name instead of extracting from host"
        },
    },
}

local _M = {
    version = 0.1,
    priority = 999,
    name = plugin_name,
    schema = schema,
}

-- Config caches
local whitelist_config = nil
local cu_config = nil


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


--- Check if network should bypass checks
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


--- Run checks on a JSON-RPC message
-- @return number status code (200 = ok, other = error)
-- @return string|nil error response JSON
local function check_message(conf, ctx, data)
    local cjson = require("cjson.safe")

    -- Parse JSON-RPC
    local result, err = jsonrpc.parse(data)
    if err then
        return 400, jsonrpc.error_response(jsonrpc.ERROR_PARSE, err, nil)
    end

    local network = conf.network or jsonrpc.extract_network(ctx.var.host)
    local methods = result.methods

    -- Bypass check
    if should_bypass(network, conf.bypass_networks) then
        return 200, nil
    end

    -- Load configs
    if not whitelist_config then
        whitelist_config = whitelist_mod.load_config(conf.whitelist_config_path)
    end
    if not cu_config then
        cu_config = cu_mod.load_config(conf.cu_config_path)
    end

    -- Whitelist check
    local monthly_quota = tonumber(ctx.var.monthly_quota) or 0
    local is_paid = monthly_quota > conf.paid_quota_threshold

    local ok, wl_err = whitelist_mod.check(network, methods, is_paid, whitelist_config)
    if not ok then
        local code = jsonrpc.ERROR_METHOD_NOT_FOUND
        if wl_err:find("requires paid") then
            code = jsonrpc.ERROR_FORBIDDEN
        end
        return 405, jsonrpc.error_response(code, wl_err, result.ids and result.ids[1])
    end

    -- Calculate CU
    local total_cu = cu_mod.calculate(methods, cu_config)

    -- Rate limit check
    if conf.enable_rate_limit then
        local limit = tonumber(ctx.var.seconds_quota)
        if limit and limit > 0 then
            local key_value = ctx.var.consumer_name or ctx.var.remote_addr

            local redis_conf = {
                host = conf.redis_host,
                port = conf.redis_port,
                password = conf.redis_password,
                database = conf.redis_database,
                timeout = conf.redis_timeout,
            }

            local key = ratelimit_mod.make_key(key_value, 1)
            local allowed, _, rl_err = ratelimit_mod.check_and_incr(
                redis_conf, key, total_cu, limit, 1
            )

            if rl_err then
                core.log.warn("ws rate limit error: ", rl_err)
                -- Allow on Redis error
            elseif not allowed then
                return 429, jsonrpc.error_response(
                    jsonrpc.ERROR_RATE_LIMITED,
                    "rate limit exceeded",
                    result.ids and result.ids[1]
                )
            end
        end
    end

    return 200, nil
end


function _M.access(conf, ctx)
    -- Only intercept WebSocket upgrade requests
    if ctx.var.http_upgrade ~= "websocket" then
        return
    end

    core.log.info("ws-jsonrpc-proxy: intercepting WebSocket for ", ctx.var.host)

    -- Initialize upstream
    local route = ctx.matched_route
    local route_val = route.value

    local up_id = route_val.upstream_id
    if up_id then
        local upstream = upstream_mod.get_by_id(up_id)
        if not upstream then
            core.log.error("ws-jsonrpc-proxy: upstream not found: ", up_id)
            return 502
        end
        ctx.matched_upstream = upstream
    else
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

    -- Pick upstream server
    local server, err = balancer.pick_server(route, ctx)
    if not server then
        core.log.error("ws-jsonrpc-proxy: failed to pick server: ", err)
        return 502
    end

    core.log.info("ws-jsonrpc-proxy: picked server ", server.host, ":", server.port)

    -- Load WebSocket modules
    local ws_server = require("resty.websocket.server")
    local ws_client = require("resty.websocket.client")

    -- Determine timeout
    local ws_timeout = conf.ws_timeout
    local up_conf = ctx.upstream_conf
    if up_conf and up_conf.timeout and up_conf.timeout.read then
        ws_timeout = up_conf.timeout.read * 1000
    end

    -- Build upstream URL
    local upstream_scheme = ctx.upstream_scheme
    local ws_scheme = "ws"
    local use_ssl = false
    if upstream_scheme == "https" or upstream_scheme == "grpcs" then
        ws_scheme = "wss"
        use_ssl = true
    end

    local upstream_uri = ctx.var.upstream_uri or ctx.var.uri
    local upstream_url = ws_scheme .. "://" .. server.host .. ":" .. server.port .. upstream_uri

    core.log.info("ws-jsonrpc-proxy: connecting to ", upstream_url)

    -- Create upstream client
    local wc, wc_err = ws_client:new({
        timeout = ws_timeout,
        max_payload_len = 65535
    })

    if not wc then
        core.log.error("ws-jsonrpc-proxy: failed to create client: ", wc_err)
        return 502
    end

    -- Connection options
    local conn_opts = { timeout = ws_timeout }

    if use_ssl then
        conn_opts.ssl_verify = false
        local sni = server.domain or server.host
        if sni then
            conn_opts.server_name = sni:match("^([^:]+)")
        end
    end

    -- Connect to upstream first
    local ok, err = wc:connect(upstream_url, conn_opts)
    if not ok then
        core.log.error("ws-jsonrpc-proxy: failed to connect: ", err)
        return 502
    end

    core.log.info("ws-jsonrpc-proxy: connected to upstream")

    -- Accept client connection
    local wb, wb_err = ws_server:new({
        timeout = ws_timeout,
        max_payload_len = 65535
    })

    if not wb then
        core.log.error("ws-jsonrpc-proxy: failed to accept: ", wb_err)
        wc:send_close()
        return 500
    end

    core.log.info("ws-jsonrpc-proxy: client connected")

    -- Spawn downstream thread (upstream -> client)
    local downstream_thread = ngx.thread.spawn(function()
        while true do
            local data, typ, err = wc:recv_frame()
            if not data then
                if err ~= "timeout" then
                    core.log.info("ws-jsonrpc-proxy: upstream closed: ", err or "unknown")
                    break
                end
                goto continue
            end

            local bytes, send_err
            if typ == "text" then
                bytes, send_err = wb:send_text(data)
            elseif typ == "binary" then
                bytes, send_err = wb:send_binary(data)
            elseif typ == "close" then
                wb:send_close()
                break
            elseif typ == "ping" then
                bytes, send_err = wb:send_pong(data)
            end

            if send_err then
                core.log.error("ws-jsonrpc-proxy: send to client failed: ", send_err)
                break
            end

            ::continue::
        end
        wb:send_close()
    end)

    -- Main thread: client -> upstream
    while true do
        local data, typ, err = wb:recv_frame()

        if not data then
            if err ~= "timeout" then
                core.log.info("ws-jsonrpc-proxy: client closed: ", err or "unknown")
                break
            end
            goto continue_loop
        end

        if typ == "close" then
            core.log.info("ws-jsonrpc-proxy: client sent close")
            wc:send_close()
            break
        elseif typ == "ping" then
            wb:send_pong()
        elseif typ == "pong" then
            wc:send_pong()
        elseif typ == "text" then
            -- Check JSON-RPC message
            local status, error_resp = check_message(conf, ctx, data)

            if status ~= 200 then
                wb:send_text(error_resp)
                goto continue_loop
            end

            -- Forward to upstream
            local bytes, send_err = wc:send_text(data)
            if not bytes then
                core.log.error("ws-jsonrpc-proxy: send to upstream failed: ", send_err)
                break
            end
        elseif typ == "binary" then
            local bytes, send_err = wc:send_binary(data)
            if not bytes then
                core.log.error("ws-jsonrpc-proxy: send binary failed: ", send_err)
                break
            end
        end

        ::continue_loop::
    end

    -- Cleanup
    core.log.info("ws-jsonrpc-proxy: cleaning up")
    ngx.thread.wait(downstream_thread)
    wc:send_close()

    return 200
end


return _M
