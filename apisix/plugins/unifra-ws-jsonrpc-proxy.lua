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
local redis_scripts = require("unifra.jsonrpc.redis_scripts")
local redis_circuit_breaker = require("unifra.jsonrpc.redis_circuit_breaker")
local config_mod = require("unifra.jsonrpc.config")
local feature_flags = require("unifra.feature_flags")
local billing = require("unifra.jsonrpc.billing")
local errors = require("unifra.jsonrpc.errors")
local metrics = require("unifra.metrics")

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
        -- Rate limit degradation (for per-second rate limit only)
        allow_degradation = {
            type = "boolean",
            default = true,
            description = "Allow requests when per-second rate limit service is unavailable (fail-open)"
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

-- Use unified config module with per-route caching and hot reload support
-- (Removed global module-level caches that were never refreshed)


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

    -- Load configs using unified config module (supports hot reload)
    -- Uses per-route caching with TTL-based refresh
    local whitelist_config, wl_load_err = config_mod.load_whitelist(ctx, conf.whitelist_config_path)
    if not whitelist_config then
        core.log.error("ws: failed to load whitelist: ", wl_load_err)
        return 500, jsonrpc.error_response(jsonrpc.ERROR_INTERNAL, "config load failed", nil)
    end

    local cu_config, cu_load_err = config_mod.load_cu_pricing(ctx, conf.cu_config_path)
    if not cu_config then
        core.log.error("ws: failed to load CU pricing: ", cu_load_err)
        return 500, jsonrpc.error_response(jsonrpc.ERROR_INTERNAL, "config load failed", nil)
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

    -- Monthly quota check (same as HTTP path)
    local use_monthly_quota = feature_flags.is_enabled(ctx, "atomic_monthly_quota")
    if use_monthly_quota then
        local quota = tonumber(ctx.var.monthly_quota)
        if quota and quota > 0 then
            local consumer_name = ctx.var.consumer_name
            if consumer_name then
                local redis_conf = {
                    host = conf.redis_host,
                    port = conf.redis_port,
                    password = conf.redis_password,
                    database = conf.redis_database,
                    timeout = conf.redis_timeout,
                }

                local allowed, used, remaining, quota_err = billing.check_and_increment(
                    redis_conf, ctx, consumer_name, total_cu, quota
                )

                if quota_err then
                    core.log.error("ws monthly quota check error: ", quota_err)
                    return 500, jsonrpc.error_response(
                        jsonrpc.ERROR_INTERNAL,
                        "monthly quota service unavailable",
                        result.ids and result.ids[1]
                    )
                end

                if not allowed then
                    core.log.warn("ws monthly quota exceeded: consumer=", consumer_name,
                                  ", used=", used, ", quota=", quota)
                    return 429, jsonrpc.error_response(
                        jsonrpc.ERROR_QUOTA_EXCEEDED,
                        "monthly quota exceeded",
                        result.ids and result.ids[1]
                    )
                end
            end
        end
    end

    -- Rate limit check (per-second sliding window, same as HTTP path)
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

            -- Generate unique request ID for ZSET
            local request_id = (key_value .. ":" .. ngx.now() .. ":" .. math.random(1000000))

            -- Keys for sliding window (ZSET + Hash)
            local key = "ratelimit:cu:sliding:" .. key_value
            local hash_key = "ratelimit:cu:sliding:" .. key_value .. ":values"

            -- Current timestamp in milliseconds (1 second window)
            local now_ms = ngx.now() * 1000
            local window_ms = 1000  -- 1 second

            -- Execute sliding window script via circuit breaker
            local script_result, script_err, blocked = redis_circuit_breaker.execute(
                redis_conf,
                ctx,
                function()
                    local redis = require("resty.redis")
                    local red = redis:new()
                    red:set_timeout(redis_conf.timeout or 1000)

                    local ok, conn_err = red:connect(redis_conf.host, redis_conf.port or 6379)
                    if not ok then
                        metrics.record_redis_op("connect", false)
                        return nil, "redis connect failed: " .. (conn_err or "unknown")
                    end

                    if redis_conf.password and redis_conf.password ~= "" then
                        local ok, auth_err = red:auth(redis_conf.password)
                        if not ok then
                            metrics.record_redis_op("auth", false)
                            return nil, "redis auth failed: " .. (auth_err or "unknown")
                        end
                    end

                    if redis_conf.database and redis_conf.database > 0 then
                        red:select(redis_conf.database)
                    end

                    -- Execute sliding window script
                    local res, exec_err = redis_scripts.execute(
                        red,
                        redis_scripts.SLIDING_WINDOW_SCRIPT,
                        {key, hash_key},
                        {now_ms, window_ms, limit, total_cu, request_id}
                    )

                    red:set_keepalive(10000, 100)

                    if exec_err then
                        metrics.record_redis_op("eval", false)
                        return nil, exec_err
                    end

                    metrics.record_redis_op("eval", true)
                    return res, nil
                end,
                conf.allow_degradation  -- Use config parameter (same as HTTP path)
            )

            -- Handle circuit breaker block or error (respect allow_degradation config)
            if blocked or script_err then
                if conf.allow_degradation then
                    core.log.warn("ws rate limit degradation (sliding window): allowing request, error: ",
                                 script_err or "circuit breaker open")
                    -- Allow request (fail-open)
                else
                    core.log.error("ws rate limit unavailable (sliding window): rejecting request, error: ",
                                  script_err or "circuit breaker open")
                    return 500, jsonrpc.error_response(
                        jsonrpc.ERROR_INTERNAL,
                        "rate limiting service unavailable",
                        result.ids and result.ids[1]
                    )
                end
            else
                -- Parse result: {allowed (1/0), current_cu, remaining}
                local allowed = (script_result[1] == 1)

                if not allowed then
                    return 429, jsonrpc.error_response(
                        jsonrpc.ERROR_RATE_LIMITED,
                        "rate limit exceeded",
                        result.ids and result.ids[1]
                    )
                end
            end
        end
    end

    return 200, nil
end


function _M.access(conf, ctx)
    -- Case-insensitive WebSocket upgrade check
    -- Handles "Websocket", "WebSocket", "WEBSOCKET", etc. properly
    local upgrade = ctx.var.http_upgrade
    if not upgrade or upgrade:lower() ~= "websocket" then
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

    -- Connection options with SSL verification
    local conn_opts = { timeout = ws_timeout }

    if use_ssl then
        -- Enable SSL verification for security (was disabled before)
        local ws_ssl_verify = feature_flags.is_enabled(ctx, "ws_ssl_verify")
        conn_opts.ssl_verify = ws_ssl_verify

        -- Set SNI for proper SSL handshake
        local sni = server.domain or server.host
        if sni then
            conn_opts.server_name = sni:match("^([^:]+)")
        end

        if not ws_ssl_verify then
            core.log.warn("ws: SSL verification disabled (not recommended for production)")
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
