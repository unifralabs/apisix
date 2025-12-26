--
-- Unifra JSON-RPC Whitelist Module
-- Manages method access control per network and user tier
--
-- This module loads whitelist configuration from YAML files
-- and provides methods to check access permissions.
--

local core_module = require("unifra.jsonrpc.core")
local config_mod = require("unifra.jsonrpc.config")

local _M = {
    version = "1.0.0"
}

-- Default whitelist configuration
-- This is used as fallback when config file is not available
local DEFAULT_CONFIG = {
    networks = {}
}


--- Process raw whitelist config into optimized structure
-- Builds lookup tables for fast access
-- @param parsed table Raw parsed config
-- @return table Processed configuration with lookup tables
local function process_whitelist_config(parsed)
    local config = { networks = {} }
    if parsed.networks then
        for network, methods in pairs(parsed.networks) do
            config.networks[network] = {
                free = methods.free or {},
                paid = methods.paid or {},
                -- Build lookup tables
                free_lookup = {},
                paid_lookup = {}
            }
            -- Convert arrays to lookup tables
            for _, m in ipairs(methods.free or {}) do
                config.networks[network].free_lookup[m] = true
            end
            for _, m in ipairs(methods.paid or {}) do
                config.networks[network].paid_lookup[m] = true
            end
        end
    end
    return config
end


--- Load whitelist configuration using unified config module
-- Uses per-route caching with TTL-based refresh to avoid cross-route interference
-- @param ctx table APISIX context (optional, for per-route caching)
-- @param path string Path to the whitelist config file
-- @param ttl number Cache TTL in seconds (optional)
-- @param force_reload boolean Force reload ignoring cache
-- @return table Configuration table
-- @return string|nil Error message if load failed
function _M.load_config(ctx, path, ttl, force_reload)
    -- Use unified config module for per-route caching
    -- Pass ttl directly to avoid cross-route interference from global set_ttl
    local raw_config, err = config_mod.load_whitelist(ctx, path, ttl, force_reload)

    if not raw_config then
        ngx.log(ngx.WARN, "whitelist config load failed: ", err or "unknown", ", using defaults")
        return DEFAULT_CONFIG, err
    end

    -- Process raw config into optimized structure with lookup tables
    return process_whitelist_config(raw_config), nil
end


--- Legacy compatibility: Clear cache via unified config module
function _M.clear_cache()
    config_mod.clear_cache("whitelist")
end


--- Check if a method is allowed for the given network and user tier
-- @param network string Network name (e.g., "eth-mainnet")
-- @param method string Method name to check
-- @param is_paid boolean Whether the user has paid tier
-- @param config table Configuration from load_config()
-- @return boolean true if allowed
-- @return string|nil Error message if not allowed
local function check_method_access(network, method, is_paid, config)
    local net_config = config.networks[network]
    if not net_config then
        return false, "unsupported network: " .. network
    end

    -- Check free methods first (available to everyone)
    if net_config.free_lookup[method] then
        return true, nil
    end

    -- Check wildcard patterns in free list
    for _, pattern in ipairs(net_config.free) do
        if core_module.match_method(method, pattern) then
            return true, nil
        end
    end

    -- Check paid methods (only for paid users)
    if net_config.paid_lookup[method] then
        if is_paid then
            return true, nil
        else
            return false, "method " .. method .. " requires paid tier"
        end
    end

    -- Check wildcard patterns in paid list
    for _, pattern in ipairs(net_config.paid) do
        if core_module.match_method(method, pattern) then
            if is_paid then
                return true, nil
            else
                return false, "method " .. method .. " requires paid tier"
            end
        end
    end

    return false, "unsupported method: " .. method
end


--- Check if all methods are allowed
-- @param network string Network name
-- @param methods table Array of method names
-- @param is_paid boolean Whether the user has paid tier
-- @param config table Configuration from load_config()
-- @return boolean true if all methods allowed
-- @return string|nil Error message for first disallowed method
function _M.check(network, methods, is_paid, config)
    if not config or not config.networks then
        return false, "whitelist config not loaded"
    end

    if not network then
        return false, "network not specified"
    end

    if not methods or #methods == 0 then
        return false, "no methods to check"
    end

    for _, method in ipairs(methods) do
        local ok, err = check_method_access(network, method, is_paid, config)
        if not ok then
            return false, err
        end
    end

    return true, nil
end


--- Check if a network is supported
-- @param network string Network name
-- @param config table Configuration from load_config()
-- @return boolean true if network is supported
function _M.is_network_supported(network, config)
    if not config or not config.networks then
        return false
    end
    return config.networks[network] ~= nil
end


--- Get list of supported networks
-- @param config table Configuration from load_config()
-- @return table Array of network names
function _M.get_networks(config)
    if not config or not config.networks then
        return {}
    end

    local networks = {}
    for network in pairs(config.networks) do
        networks[#networks + 1] = network
    end
    table.sort(networks)
    return networks
end


return _M
