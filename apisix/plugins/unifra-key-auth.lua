--
-- Unifra Key Authentication Plugin (URL-based)
--
-- Extracts API key from URL patterns like /v1/<key> and /ws/<key>
-- and makes it available to the standard key-auth plugin.
--
-- Priority: 27000 (highest - must run before standard key-auth at 2500)
--
-- URL Patterns:
--   HTTP: /v1/{apikey}/*  -> rewrites to /* with X-API-Key header
--   WS:   /ws/{apikey}/*  -> rewrites to /ws/* with X-API-Key header
--

local core = require("apisix.core")
local feature_flags = require("unifra.feature_flags")

local plugin_name = "unifra-key-auth"

local schema = {
    type = "object",
    properties = {
        http_pattern = {
            type = "string",
            default = "^/v1/([^/]+)(.*)",
            description = "Regex pattern to extract key from HTTP URLs"
        },
        ws_pattern = {
            type = "string",
            default = "^/ws/([^/]+)(.*)",
            description = "Regex pattern to extract key from WebSocket URLs"
        },
        header_name = {
            type = "string",
            default = "apikey",
            description = "Header name to inject extracted key (must match key-auth plugin config)"
        },
        query_name = {
            type = "string",
            default = "apikey",
            description = "Query parameter name (alternative to header)"
        },
        use_header = {
            type = "boolean",
            default = true,
            description = "Inject key as header"
        },
        use_query = {
            type = "boolean",
            default = false,
            description = "Inject key as query parameter"
        },
        rewrite_upstream_uri = {
            type = "boolean",
            default = true,
            description = "Rewrite upstream URI to remove key segment"
        },
    },
}

local _M = {
    version = 0.1,
    priority = 27000,  -- MUST be higher than key-auth (2500)
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.rewrite(conf, ctx)
    -- Check if URL key extraction is enabled
    if not feature_flags.is_enabled(ctx, "url_key_extraction") then
        return
    end

    local uri = ctx.var.uri
    local key, remaining_path

    -- Try HTTP pattern first
    key, remaining_path = uri:match(conf.http_pattern)

    -- If no match, try WebSocket pattern
    if not key then
        key, remaining_path = uri:match(conf.ws_pattern)
    end

    -- If still no match, skip
    if not key or key == "" then
        return
    end

    core.log.info("Extracted API key from URL: key=", key:sub(1, 8), "..., remaining=", remaining_path or "/")

    -- Store key in context for downstream plugins
    ctx.var.unifra_extracted_apikey = key

    -- Inject key as header (for key-auth plugin)
    if conf.use_header then
        core.request.set_header(ctx, conf.header_name, key)
    end

    -- Inject key as query parameter (alternative method)
    if conf.use_query then
        local args = core.request.get_uri_args(ctx)
        args[conf.query_name] = key
        ctx.var.args = ngx.encode_args(args)
    end

    -- Rewrite upstream URI to remove key segment
    if conf.rewrite_upstream_uri and remaining_path then
        -- Ensure remaining_path starts with /
        if remaining_path == "" then
            remaining_path = "/"
        elseif not remaining_path:find("^/") then
            remaining_path = "/" .. remaining_path
        end

        -- Store original URI for logging
        ctx.var.unifra_original_uri = uri

        -- Set new URI (this affects upstream proxying)
        ngx.var.uri = remaining_path

        -- Sync ctx.var.uri to maintain cache consistency
        -- (later plugins may read ctx.var.uri and expect the rewritten value)
        ctx.var.uri = remaining_path

        -- Also set ctx.var.upstream_uri for APISIX proxy
        ctx.var.upstream_uri = remaining_path

        core.log.info("Rewrote URI: ", uri, " -> ", remaining_path)
    end
end


return _M
