--
-- Unifra JSON-RPC Whitelist Module
-- Manages method access control per network and user tier
--
-- This module loads whitelist configuration from YAML files
-- and provides methods to check access permissions.
--

local config_mod = require("unifra.jsonrpc.config")
local cjson = require("cjson.safe")

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
local function contains_wildcard(method)
    return type(method) == "string" and method:find("*", 1, true) ~= nil
end


local function append_methods(target, seen, methods, source)
    for _, method in ipairs(methods or {}) do
        if type(method) ~= "string" or method == "" then
            return nil, "invalid method in " .. source
        end
        if contains_wildcard(method) then
            return nil, "wildcard methods are not allowed in " .. source .. ": " .. method
        end
        if not seen[method] then
            target[#target + 1] = method
            seen[method] = true
        end
    end
    return true
end


local function expand_tier(parsed, network, methods, profile_names, tier)
    local expanded, seen = {}, {}
    local profiles = parsed.method_profiles or {}
    for _, profile_name in ipairs(profile_names or {}) do
        local profile = profiles[profile_name]
        if type(profile) ~= "table" then
            return nil, "unknown method profile " .. tostring(profile_name) ..
                " for network " .. network
        end
        local ok, err = append_methods(expanded, seen, profile,
            "profile " .. profile_name)
        if not ok then return nil, err end
    end
    local ok, err = append_methods(expanded, seen, methods,
        network .. "." .. tier)
    if not ok then return nil, err end
    table.sort(expanded)
    return expanded
end


local function default_display_name(network)
    local words = {}
    for word in network:gmatch("[^-]+") do
        words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2)
    end
    return table.concat(words, " ")
end


local function process_whitelist_config(parsed)
    local config = {
        schema_version = parsed.schema_version or 1,
        revision = parsed.revision or "unversioned",
        networks = {},
    }
    if parsed.networks then
        for network, methods in pairs(parsed.networks) do
            local free, free_err = expand_tier(parsed, network, methods.free,
                methods.free_profiles, "free")
            if not free then return nil, free_err end
            local paid, paid_err = expand_tier(parsed, network, methods.paid,
                methods.paid_profiles, "paid")
            if not paid then return nil, paid_err end

            config.networks[network] = {
                free = free,
                paid = paid,
                rpc_policy = methods.rpc_policy,
                display_name = methods.display_name or default_display_name(network),
                published = methods.published == true,
                environment = methods.environment,
                sort_order = methods.sort_order,
                -- Build lookup tables
                free_lookup = {},
                paid_lookup = {}
            }
            -- Convert arrays to lookup tables
            for _, m in ipairs(free) do
                config.networks[network].free_lookup[m] = true
            end
            for _, m in ipairs(paid) do
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
    local config, process_err = process_whitelist_config(raw_config)
    if not config then
        ngx.log(ngx.ERR, "whitelist config validation failed: ", process_err)
        return DEFAULT_CONFIG, process_err
    end

    return config, nil
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

    -- Check paid methods (only for paid users)
    if net_config.paid_lookup[method] then
        if is_paid then
            return true, nil
        else
            return false, "method " .. method .. " requires paid tier"
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


--- Build the public, read-only capability document.
-- Lookup tables and unpublished/internal networks are deliberately omitted.
function _M.get_capabilities(config)
    if not config or not config.networks then return nil end
    local networks = {}
    for id, network in pairs(config.networks) do
        if network.published then
            networks[#networks + 1] = {
                id = id,
                display_name = network.display_name,
                environment = network.environment,
                sort_order = network.sort_order,
                rpc_policy = network.rpc_policy,
                free = #network.free > 0 and network.free or cjson.empty_array,
                paid = #network.paid > 0 and network.paid or cjson.empty_array,
            }
        end
    end
    table.sort(networks, function(a, b)
        local ao, bo = a.sort_order or 1000, b.sort_order or 1000
        if ao ~= bo then return ao < bo end
        return a.id < b.id
    end)
    return {
        schema_version = config.schema_version,
        revision = config.revision,
        networks = networks,
    }
end


-- Exported for deterministic unit tests and configuration tooling.
_M.process_config = process_whitelist_config


return _M
