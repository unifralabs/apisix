--
-- Unifra JSON-RPC Whitelist Module
-- Manages method access control per network and user tier
--
-- This module loads whitelist configuration from YAML files
-- and provides methods to check access permissions.
--

local core_module = require("unifra.jsonrpc.core")

local _M = {
    version = "1.0.0"
}

-- Configuration cache with TTL support
local config_cache = nil
local config_path = nil
local config_loaded_at = 0
local CONFIG_TTL = 60  -- Reload config every 60 seconds


--- Default whitelist configuration
-- This is used as fallback when config file is not available
local DEFAULT_CONFIG = {
    networks = {}
}


--- Load whitelist configuration from file (YAML or JSON)
-- Supports both YAML (via tinyyaml) and JSON (via cjson) formats
-- @param path string Path to the whitelist config file
-- @return table Configuration table
function _M.load_config(path, force_reload)
    -- Return cached config if path matches and TTL not expired
    local now = ngx.now()
    if not force_reload and config_cache and config_path == path then
        if (now - config_loaded_at) < CONFIG_TTL then
            return config_cache
        end
        ngx.log(ngx.INFO, "whitelist config TTL expired, reloading...")
    end

    -- Try JSON file first (more reliable across environments)
    local json_path = path:gsub("%.yaml$", ".json")
    local file = io.open(json_path, "r")
    local content = nil
    local is_json = false

    if file then
        content = file:read("*a")
        file:close()
        is_json = true
        ngx.log(ngx.INFO, "loading whitelist from JSON: ", json_path)
    else
        -- Fall back to YAML
        file = io.open(path, "r")
        if not file then
            ngx.log(ngx.WARN, "whitelist config not found: ", path, ", using defaults")
            return DEFAULT_CONFIG
        end
        content = file:read("*a")
        file:close()
    end

    local parsed = nil
    local err = nil

    if is_json then
        -- Parse JSON
        local cjson = require("cjson.safe")
        parsed, err = cjson.decode(content)
    else
        -- Try to use tinyyaml if available
        local ok, yaml = pcall(require, "tinyyaml")
        if not ok then
            ngx.log(ngx.ERR, "tinyyaml not available, using default config")
            return DEFAULT_CONFIG
        end
        parsed, err = yaml.parse(content)
    end

    if not parsed then
        ngx.log(ngx.ERR, "failed to parse whitelist config: ", err)
        return DEFAULT_CONFIG
    end

    -- Build lookup tables for fast access
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

    config_cache = config
    config_path = path
    config_loaded_at = ngx.now()
    return config
end


--- Set the TTL for configuration cache
-- @param ttl number TTL in seconds (0 = no caching, nil = use default)
function _M.set_ttl(ttl)
    if ttl then
        CONFIG_TTL = ttl
    end
end


--- Clear configuration cache
-- Call this when config file changes
function _M.clear_cache()
    config_cache = nil
    config_path = nil
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
