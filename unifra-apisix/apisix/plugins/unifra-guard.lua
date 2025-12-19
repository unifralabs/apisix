--
-- Unifra Guard Plugin
--
-- Emergency circuit breaker for blocking specific consumers or methods.
-- Useful for emergency situations like detecting abuse or attacks.
--
-- Priority: 25000 (high priority, runs right after jsonrpc-var)
--

local core = require("apisix.core")
local jsonrpc = require("unifra.jsonrpc.core")

local plugin_name = "unifra-guard"

local schema = {
    type = "object",
    properties = {
        blocked_consumers = {
            type = "array",
            items = { type = "string" },
            default = {},
            description = "List of blocked consumer names"
        },
        blocked_methods = {
            type = "array",
            items = { type = "string" },
            default = {},
            description = "List of blocked method names (supports wildcards)"
        },
        blocked_ips = {
            type = "array",
            items = { type = "string" },
            default = {},
            description = "List of blocked IP addresses"
        },
        block_message = {
            type = "string",
            default = "service temporarily unavailable"
        },
        enabled = {
            type = "boolean",
            default = true
        },
    },
}

local _M = {
    version = 0.1,
    priority = 25000,  -- High priority, right after jsonrpc-var
    name = plugin_name,
    schema = schema,
}

-- Local caches for fast lookup
local blocked_consumers_cache = {}
local blocked_methods_cache = {}
local blocked_ips_cache = {}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


--- Build lookup cache from array
local function build_cache(array)
    local cache = {}
    for _, item in ipairs(array or {}) do
        cache[item] = true
    end
    return cache
end


function _M.access(conf, ctx)
    if not conf.enabled then
        return
    end

    -- Build caches (on first access or config change)
    -- Note: In production, you'd want a more sophisticated cache invalidation
    blocked_consumers_cache = build_cache(conf.blocked_consumers)
    blocked_methods_cache = build_cache(conf.blocked_methods)
    blocked_ips_cache = build_cache(conf.blocked_ips)

    -- Check blocked IPs
    local remote_addr = ctx.var.remote_addr
    if blocked_ips_cache[remote_addr] then
        core.log.warn("guard: blocked IP ", remote_addr)
        core.response.set_header("Content-Type", "application/json")
        return 403, jsonrpc.error_response(
            jsonrpc.ERROR_FORBIDDEN,
            conf.block_message,
            nil
        )
    end

    -- Check blocked consumers
    local consumer_name = ctx.var.consumer_name
    if consumer_name and blocked_consumers_cache[consumer_name] then
        core.log.warn("guard: blocked consumer ", consumer_name)
        core.response.set_header("Content-Type", "application/json")
        return 403, jsonrpc.error_response(
            jsonrpc.ERROR_FORBIDDEN,
            conf.block_message,
            nil
        )
    end

    -- Check blocked methods (if we have parsed JSON-RPC)
    if ctx.jsonrpc and ctx.jsonrpc.methods then
        for _, method in ipairs(ctx.jsonrpc.methods) do
            -- Exact match
            if blocked_methods_cache[method] then
                core.log.warn("guard: blocked method ", method)
                core.response.set_header("Content-Type", "application/json")
                return 403, jsonrpc.error_response(
                    jsonrpc.ERROR_FORBIDDEN,
                    conf.block_message,
                    ctx.jsonrpc.ids and ctx.jsonrpc.ids[1]
                )
            end

            -- Wildcard match
            for pattern in pairs(blocked_methods_cache) do
                if pattern:sub(-1) == "*" then
                    local prefix = pattern:sub(1, -2)
                    if method:sub(1, #prefix) == prefix then
                        core.log.warn("guard: blocked method ", method, " (pattern: ", pattern, ")")
                        core.response.set_header("Content-Type", "application/json")
                        return 403, jsonrpc.error_response(
                            jsonrpc.ERROR_FORBIDDEN,
                            conf.block_message,
                            ctx.jsonrpc.ids and ctx.jsonrpc.ids[1]
                        )
                    end
                end
            end
        end
    end
end


return _M
