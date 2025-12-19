--
-- Unifra JSON-RPC Compute Unit (CU) Module
-- Calculates compute unit consumption for JSON-RPC methods
--
-- Each method has a CU cost based on its computational complexity.
-- This is used for rate limiting and billing purposes.
--

local _M = {
    version = "1.0.0"
}

-- Configuration cache with TTL support
local config_cache = nil
local config_path = nil
local config_loaded_at = 0
local CONFIG_TTL = 60  -- Reload config every 60 seconds


--- Default CU pricing configuration
local DEFAULT_CONFIG = {
    default = 1,
    methods = {}
}


--- Load CU pricing configuration from file (YAML or JSON)
-- @param path string Path to the cu-pricing config file
-- @return table Configuration table with 'default' and 'methods' fields
function _M.load_config(path, force_reload)
    -- Return cached config if path matches and TTL not expired
    local now = ngx.now()
    if not force_reload and config_cache and config_path == path then
        if (now - config_loaded_at) < CONFIG_TTL then
            return config_cache
        end
        ngx.log(ngx.INFO, "CU pricing config TTL expired, reloading...")
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
        ngx.log(ngx.INFO, "loading CU pricing from JSON: ", json_path)
    else
        -- Fall back to YAML
        file = io.open(path, "r")
        if not file then
            ngx.log(ngx.WARN, "cu pricing config not found: ", path, ", using defaults")
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
        ngx.log(ngx.ERR, "failed to parse cu pricing config: ", err)
        return DEFAULT_CONFIG
    end

    local config = {
        default = parsed.default or 1,
        methods = parsed.methods or {}
    }

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
function _M.clear_cache()
    config_cache = nil
    config_path = nil
    config_loaded_at = 0
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
