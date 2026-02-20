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
local plugin_mod = require("apisix.plugin")
local upstream_mod = require("apisix.upstream")
local jsonrpc = require("unifra.jsonrpc.core")
local whitelist_mod = require("unifra.jsonrpc.whitelist")
local cu_mod = require("unifra.jsonrpc.cu")
local redis_scripts = require("unifra.jsonrpc.redis_scripts")
local redis_circuit_breaker = require("unifra.jsonrpc.redis_circuit_breaker")
local billing = require("unifra.jsonrpc.billing")
local errors = require("unifra.jsonrpc.errors")
local metrics = require("unifra.metrics")
local batch_processor = require("apisix.utils.batch-processor")
local producer = require("resty.kafka.producer")

local ngx = ngx
local ipairs = ipairs
local type = type

local plugin_name = "unifra-ws-jsonrpc-proxy"

local schema = {
    type = "object",
    properties = {
        -- Rate limit configuration
        enable_rate_limit = {
            type = "boolean",
            default = true
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
        kafka_topic = {
            type = "string",
            default = "request_metrics_prod" -- request_metrics_staging
        },
        kafka_event_topic = {
            type = "string",
            default = "request_metrics_event_prod", -- request_metrics_event_staging
            description = "Kafka topic for subscription push event logs"
        },
    },
}

local metadata_schema = {
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
        -- Kafka configuration
        kafka_brokers = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    host = { type = "string" },
                    port = { type = "integer" },
                },
                required = { "host", "port" }
            },
            default = {
                { host = "kafka", port = 9092 }
            }
        },
        kafka_producer_config = {
            type = "object",
            properties = {
                producer_type = { type = "string", enum = {"async", "sync"}, default = "async" },
                refresh_interval = { type = "integer", default = 1000 },
                required_acks = { type = "integer", default = 1 },
            },
            default = {
                producer_type = "async",
                refresh_interval = 1000,
                required_acks = 1
            }
        }
    }
}

local _M = {
    version = 0.1,
    priority = 999,
    name = plugin_name,
    schema = schema,
    metadata_schema = metadata_schema,
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
-- @return table|nil parsed JSON-RPC result
-- @return number|nil total CU cost (if calculated)
local function check_message(conf, ctx, data, meta_conf)
    -- Parse JSON-RPC
    local result, err = jsonrpc.parse(data)
    if err then
        return 400, jsonrpc.error_response(jsonrpc.ERROR_PARSE, err, nil), nil, nil
    end

    local network = ctx.var.unifra_network or conf.network or jsonrpc.extract_network(ctx.var.host)
    local methods = result.methods

    -- Bypass check
    if should_bypass(network, conf.bypass_networks) then
        return 200, nil, result, nil
    end

    -- Load configs using unified config module (supports hot reload)
    -- Uses per-route caching with TTL-based refresh
    
    meta_conf = meta_conf or {}

    -- Configuration Source: Plugin Metadata (with defaults)
    local whitelist_path = meta_conf.whitelist_config_path
    local cu_path = meta_conf.cu_config_path
    
    local redis_host = meta_conf.redis_host
    local redis_port = meta_conf.redis_port
    local redis_password = meta_conf.redis_password
    local redis_database = meta_conf.redis_database
    local redis_timeout = meta_conf.redis_timeout

    local whitelist_config, wl_load_err = whitelist_mod.load_config(ctx, whitelist_path)
    if not whitelist_config then
        core.log.error("ws: failed to load whitelist: ", wl_load_err)
        return 500, jsonrpc.error_response(jsonrpc.ERROR_INTERNAL, "config load failed", nil), result, nil
    end

    local cu_config, cu_load_err = cu_mod.load_config(ctx, cu_path)
    if cu_load_err then
        core.log.error("ws: failed to load CU pricing: ", cu_load_err)
        return 500, jsonrpc.error_response(jsonrpc.ERROR_INTERNAL, "config load failed", nil), result, nil
    end
    if not cu_config then
        core.log.error("ws: failed to load CU pricing: empty config")
        return 500, jsonrpc.error_response(jsonrpc.ERROR_INTERNAL, "config load failed", nil), result, nil
    end

    -- Calculate CU early so logs can include it even on errors
    local total_cu = cu_mod.calculate(methods, cu_config)

    -- Whitelist check
    local monthly_quota = tonumber(ctx.var.monthly_quota) or 0
    local is_paid = monthly_quota > conf.paid_quota_threshold

    local ok, wl_err = whitelist_mod.check(network, methods, is_paid, whitelist_config)
    if not ok then
        local code = jsonrpc.ERROR_METHOD_NOT_FOUND
        if wl_err:find("requires paid") then
            code = jsonrpc.ERROR_FORBIDDEN
        end
        return 405, jsonrpc.error_response(code, wl_err, result.ids and result.ids[1]), result, total_cu
    end

    -- Rate limit check (per-second sliding window, same as HTTP path)
    if conf.enable_rate_limit then
        local limit = tonumber(ctx.var.seconds_quota)
        if limit and limit > 0 then
            -- Use shared quota key (user_id) if available, consistent with monthly quota
            local key_value = ctx.var.quota_key
            if not key_value or key_value == "" then
                key_value = ctx.var.consumer_name or ctx.var.remote_addr
            end

            local redis_conf = {
                host = redis_host,
                port = redis_port,
                password = redis_password,
                database = redis_database,
                timeout = redis_timeout,
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
                        local ok, select_err = red:select(redis_conf.database)
                        if not ok then
                            metrics.record_redis_op("select", false)
                            return nil, "redis select failed: " .. (select_err or "unknown")
                        end
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
                    ), result, total_cu
                end
            else
                -- Parse result: {allowed (1/0), current_cu, remaining}
                local allowed = (script_result[1] == 1)

                if not allowed then
                    return 429, jsonrpc.error_response(
                        jsonrpc.ERROR_RATE_LIMITED,
                        "rate limit exceeded",
                        result.ids and result.ids[1]
                    ), result, total_cu
                end
            end
        end
    end

    -- Monthly quota check (atomic via billing module)
    local quota = tonumber(ctx.var.monthly_quota)
    if quota and quota > 0 then
        -- Use shared quota key (user_id) if available, fallback to consumer_name (api_key)
        -- This ensures consistency with HTTP monthly limit plugin
        local quota_key = ctx.var.quota_key
        if not quota_key or quota_key == "" then
            quota_key = ctx.var.consumer_name
        end

        if quota_key then
            local redis_conf = {
                host = redis_host,
                port = redis_port,
                password = redis_password,
                database = redis_database,
                timeout = redis_timeout,
            }

            local allowed, used, remaining, quota_err = billing.check_and_increment(
                redis_conf, ctx, quota_key, total_cu, quota
            )

            if quota_err then
                core.log.error("ws monthly quota check error: ", quota_err)
                return 500, jsonrpc.error_response(
                    jsonrpc.ERROR_INTERNAL,
                    "monthly quota service unavailable",
                    result.ids and result.ids[1]
                ), result, total_cu
            end

            if not allowed then
                core.log.warn("ws monthly quota exceeded: key=", quota_key,
                              ", used=", used, ", quota=", quota)
                return 429, jsonrpc.error_response(
                    jsonrpc.ERROR_QUOTA_EXCEEDED,
                    "monthly quota exceeded",
                    result.ids and result.ids[1]
                ), result, total_cu
            end
        end
    end

    return 200, nil, result, total_cu
end


-- Batch processor for Kafka logging
local buffers = {}

local function is_subscription_method(method)
    if not method then return false end
    -- Match any chain's subscribe/unsubscribe methods
    -- e.g., eth_subscribe, cfx_subscribe, eth_unsubscribe, cfx_unsubscribe
    return method:sub(-10) == "_subscribe" or method:sub(-12) == "_unsubscribe"
end

local function is_subscription_request(parsed)
    if not parsed or not parsed.methods then
        return false
    end
    for _, method in ipairs(parsed.methods) do
        if is_subscription_method(method) then
            return true
        end
    end
    return false
end

local function get_batch_processor(meta_conf, conf, topic_override)
    if not meta_conf then
        return nil
    end
    -- Configuration Source: Plugin Metadata (with defaults)
    local brokers = meta_conf.kafka_brokers
    local prod_conf = meta_conf.kafka_producer_config
    local topic = topic_override or (conf and conf.kafka_topic)
    if not topic then
        core.log.error("ws: kafka topic not configured")
        return nil
    end

    -- Cache key must include broker hash to prevent collision if different routes
    -- use different brokers/producer configs for the same topic (edge case)
    -- Simplified key: plugin_name # topic # broker_list_hash
    
    local broker_list = {}
    for _, b in ipairs(brokers) do
        table.insert(broker_list, { host = b.host, port = b.port })
    end
    
    local key = "ws_logger:" .. (topic or "default") .. ":" .. core.json.encode(broker_list)
    
    if buffers[key] then
        return buffers[key]
    end

    local buffer_config = {
        name = "unifra-ws-logger",
        retry_delay = 1,
        batch_max_size = 500,
        max_retry_count = 3,
        buffer_duration = 1,
        inactive_timeout = 2,
    }

    local function flush_to_kafka(entries)
        local broker_list = {}
        for _, b in ipairs(brokers) do
            table.insert(broker_list, { host = b.host, port = b.port })
        end

        core.log.debug("ws: flushing ", #entries, " logs to kafka topic: ", topic)

        local p = producer:new(broker_list, prod_conf)
        
        for _, entry in ipairs(entries) do
            local json_str = core.json.encode(entry)
            local ok, err = p:send(topic, nil, json_str)
            if not ok then
                core.log.error("ws: failed to send log to kafka: ", err)
            end
        end
        return true
    end

    local bp, err = batch_processor:new(flush_to_kafka, buffer_config)
    if not bp then
        core.log.error("ws: failed to create batch processor: ", err)
        return nil
    end

    buffers[key] = bp
    return bp
end


local function log_jsonrpc(ctx, conf, base_info, log_details, bp)
    if not bp then
        return
    end

    local request_data = log_details.request_data or ""
    local response_data = log_details.response_data or ""
    local duration = log_details.duration or 0
    local status = log_details.status or 200
    local extra_info = log_details.extra_info or {}
    local metadata_only = log_details.metadata_only or false
    
    -- Use captured base info
    local user_id = base_info.user_id or ""
    local app_id = base_info.app_id or ""
    local network = base_info.network or (extra_info and extra_info.network) or ""
    local method = extra_info.method
    
    local log_entry = {
        user_id = user_id,
        app_id = app_id,
        network = network,
        duration = duration,
        client_ip = ctx.var.remote_addr,
        response_status_code = status,
        time = ngx.now(),
        jsonrpc_method = method,
        
        -- Extra fields for detailed debugging/metrics
        cu_cost = extra_info.cu_cost,
        node_id = core.utils.gethostname(),
        service_id = ctx.var.service_id,
        route_id = ctx.var.route_id,
        request_id = extra_info.request_id,
        subscription_type = extra_info.subscription_type,
    }

    if not metadata_only then
        log_entry.request = request_data
        log_entry.response = response_data
    end

    core.log.debug("ws: queuing jsonrpc log, user_id=", user_id)
    bp:push(log_entry)
end


function _M.access(conf, ctx)
    -- Case-insensitive WebSocket upgrade check
    -- Handles "Websocket", "WebSocket", "WEBSOCKET", etc. properly
    local upgrade = ctx.var.http_upgrade
    if not upgrade or upgrade:lower() ~= "websocket" then
        return
    end

    core.log.info("ws-jsonrpc-proxy: intercepting WebSocket for ", ctx.var.host)

    -- Capture Context Variables Early
    -- This avoids thread scope issues and repeated lookups
    -- Prefer unifra_network set by unifra-jsonrpc-var plugin (single source of truth)
    local network = ctx.var.unifra_network or conf.network or jsonrpc.extract_network(ctx.var.host)



    local base_info = {
        user_id = ctx.user_id or ctx.var.user_id or ctx.quota_key or ctx.var.quota_key or ctx.consumer_name or ctx.var.consumer_name,
        app_id = ctx.app_id or ctx.var.app_id or ctx.consumer_name or ctx.var.consumer_name,
        network = network
    }

    -- Load plugin metadata once per connection (defaults are populated in-place)
    local metadata = plugin_mod.plugin_metadata(plugin_name)
    local meta_conf = metadata and metadata.value or {}
    local valid, err = core.schema.check(metadata_schema, meta_conf)
    if not valid then
        core.log.error("ws: failed to validate metadata: ", err)
    end
    local bp = get_batch_processor(meta_conf, conf)
    local event_topic = conf.kafka_event_topic
    local event_bp = get_batch_processor(meta_conf, conf, event_topic)

    -- Redis configuration for billing/concurrency
    local redis_host = meta_conf.redis_host
    local redis_port = meta_conf.redis_port
    local redis_password = meta_conf.redis_password
    local redis_database = meta_conf.redis_database
    local redis_timeout = meta_conf.redis_timeout

    local redis_conf = {
        host = redis_host,
        port = redis_port,
        password = redis_password,
        database = redis_database,
        timeout = redis_timeout,
    }

    -- Concurrency Control
    local conn_limit = 0
    -- Try to get limit from Consumer config
    if ctx.consumer and ctx.consumer.concurrency_limit then
        conn_limit = tonumber(ctx.consumer.concurrency_limit) or 0
    elseif ctx.var.consumer_name then
         -- Fallback or other logic if needed, but per user request "read from consumer"
    end

    local conn_key = nil
    
    if conn_limit > 0 then
        -- Use user_id for key consistency with monthly quota
        -- Prioritize quota_key as requested
        local key_suffix = ctx.var.quota_key
        if not key_suffix or key_suffix == "" then
            -- Fallback to user_id or consumer_name
             key_suffix = base_info.user_id or ctx.var.consumer_name or ctx.var.remote_addr
        end
        conn_key = "ws_connections:" .. key_suffix

        -- Increment connection count
        local redis = require("resty.redis")
        local red = redis:new()
        red:set_timeout(redis_conf.timeout or 1000)
        
        local ok, conn_err = red:connect(redis_conf.host, redis_conf.port or 6379)
        if ok then
            if redis_conf.password and redis_conf.password ~= "" then
                red:auth(redis_conf.password)
            end
            if redis_conf.database and redis_conf.database > 0 then
                red:select(redis_conf.database)
            end
            
            local current, err = red:incr(conn_key)
            if current then
                 -- Set expiry for safety
                 red:expire(conn_key, 86400) 
                 
                 if current > conn_limit then
                     core.log.warn("ws: concurrency limit exceeded for ", conn_key, ": ", current, " > ", conn_limit)
                     red:decr(conn_key) -- Rollback
                     red:set_keepalive(10000, 100)
                     return 429
                 end
            else
                 core.log.error("ws: failed to incr concurrency: ", err)
            end
            red:set_keepalive(10000, 100)
        else
            core.log.error("ws: failed to connect to redis for concurrency check: ", conn_err)
        end
    end

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
        -- Enable SSL verification for security
        conn_opts.ssl_verify = true

        -- Set SNI for proper SSL handshake
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
        -- Concurrency cleanup handled in finally block if we structure it well,
        -- but here simpler to just decr if we incremented.
        if conn_key then
            local redis = require("resty.redis")
            local red = redis:new()
            red:set_timeout(redis_conf.timeout or 1000)
            if red:connect(redis_conf.host, redis_conf.port or 6379) then
                if redis_conf.password and redis_conf.password ~= "" then red:auth(redis_conf.password) end
                if redis_conf.database and redis_conf.database > 0 then red:select(redis_conf.database) end
                red:decr(conn_key)
                red:set_keepalive(10000, 100)
            end
        end
        return 500
    end

    core.log.info("ws-jsonrpc-proxy: client connected")

    -- Shared state for correlating requests and responses
    local inflight_requests = {}
    local expired_request_ids = {}
    local request_counter = 0
    local cjson = require("cjson.safe")
    local inflight_ttl = math.max(1, (ws_timeout or 60000) / 1000)
    local cleanup_interval = math.max(1, inflight_ttl / 2)
    local last_cleanup = ngx.now()

    -- Subscription ID Mapping for push notification billing
    -- Maps subscription_id -> event_type (e.g., "0xsub_id" -> "newHeads")
    local subscription_map = {}
    -- Pending subscriptions: Maps internal_request_id -> event_type
    -- Used to correlate eth_subscribe response with the subscription type
    local pending_subscriptions = {}

    local function cleanup_inflight(now, wb)
        if (now - last_cleanup) < cleanup_interval then
            return
        end
        last_cleanup = now

        local expired_requests = {}
        for internal_id, req_ctx in pairs(inflight_requests) do
            if now - req_ctx.start_time > inflight_ttl then
                inflight_requests[internal_id] = nil
                expired_request_ids[internal_id] = now
                expired_requests[#expired_requests + 1] = req_ctx
            end
        end

        if wb then
            for _, req_ctx in ipairs(expired_requests) do
                local timeout_resp = jsonrpc.error_response(
                    jsonrpc.ERROR_INTERNAL,
                    "request timeout",
                    req_ctx.orig_id
                )
                local _, send_err = wb:send_text(timeout_resp)
                if send_err then
                    core.log.warn("ws-jsonrpc-proxy: failed to send timeout response: ", send_err)
                end
            end
        end

        for internal_id, ts in pairs(expired_request_ids) do
            if now - ts > inflight_ttl then
                expired_request_ids[internal_id] = nil
            end
        end
    end

    -- Spawn downstream thread (upstream -> client)
    local downstream_thread = ngx.thread.spawn(function()
        while true do
            local data, typ, err = wc:recv_frame()
            if not data then
                if err ~= "timeout" then
                    core.log.info("ws-jsonrpc-proxy: upstream closed: ", err or "unknown")
                    break
                end;
                goto continue
            end

            if typ == "text" then
                -- Intercept response to rewrite ID and log
                core.log.debug("ws: upstream response received, size=", #data)
                local json_resp = cjson.decode(data)
                local req_ctx = nil
                local rewritten = false
                
                -- Try to find matching request using Internal ID
                if json_resp and json_resp.id then
                    local internal_id_key = tostring(json_resp.id)
                    req_ctx = inflight_requests[internal_id_key]
                    local pending_sub_type = pending_subscriptions[internal_id_key]
                    
                    if req_ctx then
                        local end_time = ngx.now()
                        local duration = end_time - req_ctx.start_time
                        
                        -- RESTORE Original ID in the response before sending to client
                        json_resp.id = req_ctx.orig_id
                        data = cjson.encode(json_resp) -- Re-encode with original ID
                        rewritten = true
                        
                        -- Map subscription ID if this was a subscribe response (eth_subscribe, cfx_subscribe, etc.)
                        if pending_sub_type and json_resp.result then
                            -- json_resp.result is the subscription_id (e.g., "0x12345...")
                            local subscription_id = tostring(json_resp.result)
                            subscription_map[subscription_id] = pending_sub_type
                            core.log.info("ws: subscription created, user=", base_info.user_id, ", subscription_id=", subscription_id, ", type=", pending_sub_type)
                            pending_subscriptions[internal_id_key] = nil -- Cleanup
                        end
                        
                        -- Log unsubscribe success (eth_unsubscribe, cfx_unsubscribe, etc.)
                        local req_method = req_ctx.extra_info and req_ctx.extra_info.method
                        if req_method and req_method:sub(-12) == "_unsubscribe" then
                            core.log.info("ws: unsubscribed (", req_method, "), user=", base_info.user_id, ", result=", tostring(json_resp.result))
                        end

                        log_jsonrpc(ctx, conf, base_info, {
                            request_data = req_ctx.data,
                            response_data = data,
                            duration = duration,
                            status = 200,
                            metadata_only = req_ctx.metadata_only,
                            extra_info = req_ctx.extra_info
                        }, bp)
                        
                        -- Cleanup
                        inflight_requests[internal_id_key] = nil
                    elseif expired_request_ids[internal_id_key] then
                        expired_request_ids[internal_id_key] = nil
                        core.log.warn("ws-jsonrpc-proxy: dropping late response for expired request id: ", internal_id_key)
                        goto continue
                    else
                        if pending_sub_type and json_resp.result then
                            local subscription_id = tostring(json_resp.result)
                            subscription_map[subscription_id] = pending_sub_type
                            core.log.info("ws: subscription created, user=", base_info.user_id, ", subscription_id=", subscription_id, ", type=", pending_sub_type)
                            pending_subscriptions[internal_id_key] = nil -- Cleanup
                        end

                        -- Unmatched response (timeout? or unsolicited? or batch?)
                        -- If we didn't rewrite it (not found), pass through as is.
                        log_jsonrpc(ctx, conf, base_info, {
                            request_data = "",
                            response_data = data,
                            duration = 0,
                            status = 200,
                            metadata_only = pending_sub_type ~= nil,
                            extra_info = {
                                network = network,
                                method = pending_sub_type and (req_ctx and req_ctx.extra_info and req_ctx.extra_info.method or "subscribe") or nil,
                                cu_cost = 0,
                            }
                        }, bp)
                    end
                elseif json_resp then
                     -- Notification from upstream (eth_subscription, cfx_subscription, etc.)
                     local is_notification = (json_resp.id == nil
                         and json_resp.method and type(json_resp.method) == "string"
                         and json_resp.method:sub(-13) == "_subscription")
                     if is_notification then
                         core.log.debug("ws: upstream push notification received, method=", json_resp.method)
                     end
                     local push_cost
                     local event_type
                     
                     if is_notification then
                         -- Push Notification Billing with event-specific costs
                         -- Load CU config to get push costs
                         local push_cost_config = nil
                         local cu_config_loaded, cu_load_err = cu_mod.load_config(ctx, meta_conf.cu_config_path)
                         if not cu_load_err and cu_config_loaded and cu_config_loaded.push_notification then
                             push_cost_config = cu_config_loaded.push_notification
                         end
                         
                         -- Determine subscription event type using subscription_map (Option B: Context Mapping)
                         -- This avoids parsing the result structure every time
                         event_type = "default"
                         if json_resp.params and json_resp.params.subscription then
                             local subscription_id = tostring(json_resp.params.subscription)
                             event_type = subscription_map[subscription_id] or "default"
                             core.log.debug("ws: push notification for subscription_id=", subscription_id, ", type=", event_type)
                         end
                         
                         -- Fallback: If event_type is still default, try to infer from result structure
                         -- (This handles cases where subscription wasn't properly tracked)
                         if event_type == "default" and json_resp.params and json_resp.params.result then
                             local result = json_resp.params.result
                             if type(result) == "table" then
                                 if result.parentHash and (result.number or result.height) then
                                     event_type = "newHeads"
                                 elseif result.topics or result.logIndex then
                                     event_type = "logs"
                                 elseif result.hash and not result.parentHash then
                                     event_type = "newPendingTransactions"
                                 end
                             elseif type(result) == "string" then
                                 event_type = "newPendingTransactions" -- tx hash
                             end
                         end
                         
                         -- Get cost from config
                         push_cost = 10 -- Default fallback
                         if push_cost_config then
                             if type(push_cost_config) == "table" then
                                 push_cost = push_cost_config[event_type] or push_cost_config.default or 10
                             else
                                 push_cost = tonumber(push_cost_config) or 10
                             end
                         end

                         local quota = tonumber(ctx.var.monthly_quota)

                         if quota and quota > 0 then
                             local quota_key = ctx.var.quota_key or ctx.var.consumer_name
                             if quota_key then
                                 -- Async billing: check and increment
                                 local allowed, used, remaining, quota_err = billing.check_and_increment(
                                     redis_conf, ctx, quota_key, push_cost, quota
                                 )
                                 
                                 if not allowed and not quota_err then
                                     core.log.warn("ws: push quota exceeded for ", quota_key, ", closing connection")
                                     -- Send close frame
                                     wb:send_close(1008, "Quota Exceeded")
                                     break -- Exit loop to close connection
                                 end
                             end
                         end
                     end

                     log_jsonrpc(ctx, conf, base_info, {
                        request_data = "",
                        response_data = data,
                        duration = 0,
                        status = 200,
                        metadata_only = is_notification,
                        extra_info = {
                            network = network,
                            method = is_notification and json_resp.method or nil,
                            cu_cost = is_notification and push_cost or 0,
                            is_notification = is_notification,
                            subscription_type = is_notification and event_type or nil
                        }
                    }, is_notification and (event_bp or bp) or bp)
                end
            end

            do
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
            end

            ::continue::
        end
        wb:send_close()
    end)

    -- Main thread: client -> upstream
    while true do
        local data, typ, err = wb:recv_frame()
        cleanup_inflight(ngx.now(), wb)

        if not data then
            if err ~= "timeout" then
                core.log.info("ws-jsonrpc-proxy: client closed: ", err or "unknown")
                break
            end;
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
            core.log.debug("ws: client request received, size=", #data)
            -- Check JSON-RPC message
            local status, error_resp, parsed, total_cu = check_message(conf, ctx, data, meta_conf)
            local network = ctx.var.unifra_network or conf.network or jsonrpc.extract_network(ctx.var.host)
            local subscription_request = is_subscription_request(parsed)

            if status ~= 200 then
                -- Log rejected request immediately
                local method_name = nil
                local req_id = nil

                if parsed then
                    if parsed.is_batch then
                        method_name = "BATCH"
                    elseif parsed.raw then
                        method_name = parsed.raw.method
                        req_id = parsed.raw.id
                    end
                end

                log_jsonrpc(ctx, conf, base_info, {
                    request_data = data,
                    response_data = error_resp,
                    duration = 0,
                    status = status,
                    metadata_only = subscription_request,
                    extra_info = {
                        network = network,
                        method = method_name,
                        request_id = req_id,
                        cu_cost = total_cu or 0,
                        error = error_resp
                    }
                }, bp)

                wb:send_text(error_resp)
                goto continue_loop
            end

            -- If successful (status == 200)
            -- 1. Decode
            -- 2. Rewrite ID (if applicable)
            -- 3. Store Mapping
            -- 4. Re-encode and Forward
            
            local json_ops = parsed and parsed.raw or nil
            local method_name = "unknown"
            local req_id = nil
            local is_batch = false
            
            if parsed then
                if parsed.is_batch then
                    method_name = "BATCH"
                    is_batch = true
                elseif json_ops and json_ops.method then
                    method_name = json_ops.method
                    req_id = json_ops.id
                end
            end
            
            -- Prepare data to send (default to original)
            local data_to_send = data

            if req_id and not is_batch then
                -- Generate Internal ID
                request_counter = request_counter + 1
                -- Use simple monotonic ID for this connection to save bytes
                local internal_id = request_counter
                local internal_id_str = tostring(internal_id)

                -- Store mapping
                inflight_requests[internal_id_str] = {
                    start_time = ngx.now(),
                    orig_id = req_id,       -- Keep original ID to restore later
                    data = data,            -- Keep original Request Data for logging
                    metadata_only = is_subscription_method(method_name),
                    extra_info = {
                        network = network,
                        method = method_name,
                        request_id = req_id,
                        cu_cost = total_cu or 0,
                    }
                }
                
                -- Track subscribe requests for subscription ID mapping (eth_subscribe, cfx_subscribe, etc.)
                -- When response comes back, we'll map subscription_id -> event_type
                if method_name and method_name:sub(-10) == "_subscribe" and json_ops.params and #json_ops.params > 0 then
                    local sub_type = json_ops.params[1] -- e.g., "newHeads", "logs", "newPendingTransactions"
                    pending_subscriptions[internal_id_str] = sub_type
                    core.log.info("ws: subscribe request (", method_name, "), user=", base_info.user_id, ", type=", sub_type, ", internal_id=", internal_id_str)
                elseif method_name and method_name:sub(-12) == "_unsubscribe" and json_ops.params and #json_ops.params > 0 then
                    core.log.info("ws: unsubscribe request (", method_name, "), user=", base_info.user_id, ", subscription_id=", json_ops.params[1])
                end
                
                -- Rewrite ID in JSON
                json_ops.id = internal_id
                data_to_send = cjson.encode(json_ops)
            else
                -- Notification or Batch
                -- Log immediately as we don't track them with ID rewriting yet
                log_jsonrpc(ctx, conf, base_info, {
                    request_data = data,
                    response_data = "",
                    duration = 0,
                    status = 200,
                    metadata_only = subscription_request,
                    extra_info = {
                        network = network,
                        method = method_name,
                        request_id = req_id,
                        cu_cost = total_cu or 0,
                    }
                }, bp)
            end

            -- Forward (rewritten or original) to upstream
            local bytes, send_err = wc:send_text(data_to_send)
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

    -- Concurrency Cleanup (DECR)
    if conn_key then
        local redis = require("resty.redis")
        local red = redis:new()
        red:set_timeout(redis_conf.timeout or 1000)
        local ok, err = red:connect(redis_conf.host, redis_conf.port or 6379)
        if ok then
            if redis_conf.password and redis_conf.password ~= "" then red:auth(redis_conf.password) end
            if redis_conf.database and redis_conf.database > 0 then red:select(redis_conf.database) end
            red:decr(conn_key)
            red:set_keepalive(10000, 100)
        else
             core.log.error("ws: failed to cleanup concurrency key: ", err)
        end
    end

    -- Do not return a status code here: the HTTP 101 upgrade response
    -- has already been sent, so setting ngx.status would trigger:
    -- "attempt to set ngx.status after sending out response headers"
    return
end


return _M
