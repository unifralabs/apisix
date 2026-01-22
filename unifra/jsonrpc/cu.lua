--
-- Unifra JSON-RPC Compute Unit (CU) Module
-- Calculates compute unit consumption for JSON-RPC methods
--
-- Each method has a CU cost based on its computational complexity.
-- This is used for rate limiting and billing purposes.
--

local config_mod = require("unifra.jsonrpc.config")

local _M = {
    version = "1.0.0"
}

-- Default CU pricing configuration
local DEFAULT_CONFIG = {
    default = 1,
    push_notification = {
        default = 10,
        newHeads = 10,
        logs = 20,
        newPendingTransactions = 50
    },
    methods = {}
}

local function value_or_default(value, default)
    if value == nil then
        return default
    end
    return value
end

local function clone_push_notification(config)
    return {
        default = config.default,
        newHeads = config.newHeads,
        logs = config.logs,
        newPendingTransactions = config.newPendingTransactions
    }
end

local function clone_default_config()
    return {
        default = DEFAULT_CONFIG.default,
        push_notification = clone_push_notification(DEFAULT_CONFIG.push_notification),
        methods = {}
    }
end


--- Process raw CU pricing config into normalized structure
-- @param parsed table Raw parsed config
-- @return table Processed configuration
local function process_cu_config(parsed)
    -- Handle push_notification: can be a number (simple) or a table (event-specific)
    local push_notif = parsed.push_notification
    local push_notif_result
    if type(push_notif) == "table" then
        push_notif_result = {
            default = value_or_default(push_notif.default, 10),
            newHeads = value_or_default(push_notif.newHeads, 10),
            logs = value_or_default(push_notif.logs, 20),
            newPendingTransactions = value_or_default(push_notif.newPendingTransactions, 50)
        }
    elseif push_notif == nil then
        -- Missing: use DEFAULT_CONFIG defaults (different per event type)
        push_notif_result = clone_push_notification(DEFAULT_CONFIG.push_notification)
    else
        -- Legacy: single number applies to all events
        local cost = tonumber(push_notif) or 10
        push_notif_result = {
            default = cost,
            newHeads = cost,
            logs = cost,
            newPendingTransactions = cost
        }
    end

    return {
        default = value_or_default(parsed.default, 1),
        push_notification = push_notif_result,
        methods = parsed.methods or {}
    }
end


--- Load CU pricing configuration using unified config module
-- Uses per-route caching with TTL-based refresh to avoid cross-route interference
-- @param ctx table APISIX context (optional, for per-route caching)
-- @param path string Path to the cu-pricing config file
-- @param ttl number Cache TTL in seconds (optional)
-- @param force_reload boolean Force reload ignoring cache
-- @return table Configuration table with 'default' and 'methods' fields
-- @return string|nil Error message if load failed
function _M.load_config(ctx, path, ttl, force_reload)
    -- Use unified config module for per-route caching
    -- Pass ttl directly to avoid cross-route interference from global set_ttl
    local raw_config, err = config_mod.load_cu_pricing(ctx, path, ttl, force_reload)

    if not raw_config then
        ngx.log(ngx.WARN, "CU pricing config load failed: ", err or "unknown", ", using defaults")
        return clone_default_config(), err
    end

    -- Process raw config into normalized structure
    return process_cu_config(raw_config), nil
end


--- Legacy compatibility: Clear cache via unified config module
function _M.clear_cache()
    config_mod.clear_cache("cu_pricing")
end


--- Get CU cost for a single method
-- @param method string Method name
-- @param config table Configuration from load_config()
-- @return number CU cost (defaults to config.default if method not found)
function _M.get_method_cu(method, config)
    if not config then
        return 1
    end

    -- Check exact match first
    if config.methods and config.methods[method] then
        return config.methods[method]
    end

    -- Check prefix patterns (e.g., "debug_*" -> all debug methods)
    if config.methods then
        for pattern, cu in pairs(config.methods) do
            if pattern:sub(-1) == "*" then
                local prefix = pattern:sub(1, -2)
                if method:sub(1, #prefix) == prefix then
                    return cu
                end
            end
        end
    end

    return config.default or 1
end


--- Calculate total CU for multiple methods
-- @param methods table Array of method names
-- @param config table Configuration from load_config()
-- @return number Total CU cost
function _M.calculate(methods, config)
    if not methods or #methods == 0 then
        return 0
    end

    local total = 0
    for _, method in ipairs(methods) do
        total = total + _M.get_method_cu(method, config)
    end
    return total
end


--- Calculate CU breakdown for multiple methods
-- Useful for debugging and logging
-- @param methods table Array of method names
-- @param config table Configuration from load_config()
-- @return table Map of method -> CU cost
-- @return number Total CU cost
function _M.calculate_breakdown(methods, config)
    if not methods or #methods == 0 then
        return {}, 0
    end

    local breakdown = {}
    local total = 0
    for _, method in ipairs(methods) do
        local cu = _M.get_method_cu(method, config)
        breakdown[method] = (breakdown[method] or 0) + cu
        total = total + cu
    end
    return breakdown, total
end


return _M
