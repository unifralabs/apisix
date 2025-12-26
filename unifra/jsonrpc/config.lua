--
-- Unifra Unified Config Management Module
--
-- Provides per-route configuration caching to eliminate global state issues.
-- Supports YAML-only configuration loading with TTL-based refresh.
--
-- This module solves the "global TTL interference" problem by scoping
-- configuration cache to route_id instead of module-level globals.
--

local core = require("apisix.core")
local feature_flags = require("unifra.feature_flags")

-- Optional dependency: lyaml (APISIX standard YAML library)
local yaml
local yaml_available = pcall(function()
    yaml = require("lyaml")
end)

local _M = {
    version = "1.0.0"
}

-- Configuration types
_M.TYPE_WHITELIST = "whitelist"
_M.TYPE_CU_PRICING = "cu_pricing"

-- Default TTL for cached configs (seconds)
local DEFAULT_TTL = 60

-- Module-level config cache (not per-request, for better performance)
local module_cache = {}

--- Get cache key for configuration
-- @param route_id string Route ID
-- @param config_type string Configuration type
-- @param config_path string Path to config file
-- @return string Cache key
local function get_cache_key(route_id, config_type, config_path)
    return string.format("%s:%s:%s", route_id or "global", config_type, config_path)
end


--- Load configuration from YAML file
-- @param path string File path
-- @return table|nil Parsed configuration
-- @return string|nil Error message
local function load_yaml_file(path)
    local file, err = io.open(path, "r")
    if not file then
        return nil, "failed to open file: " .. (err or "unknown")
    end

    local content = file:read("*a")
    file:close()

    if not content or content == "" then
        return nil, "empty configuration file"
    end

    -- Parse YAML (using lyaml - APISIX standard library)
    if not yaml_available or not yaml then
        core.log.error("lyaml not available, cannot parse YAML config")
        return nil, "lyaml module not available (should be included in APISIX)"
    end

    -- lyaml.load may throw exception on malformed YAML, use pcall for safety
    local ok, config = pcall(yaml.load, content)
    if not ok then
        -- config contains error message when ok is false
        return nil, "failed to parse YAML: " .. tostring(config)
    end

    if not config then
        return nil, "failed to parse YAML: empty result"
    end

    return config, nil
end


--- Get route ID from context
-- @param ctx table Request context
-- @return string Route ID (or "global" if not available)
local function get_route_id(ctx)
    if ctx and ctx.matched_route and ctx.matched_route.value then
        return ctx.matched_route.value.id or "global"
    end
    return "global"
end


--- Load configuration with per-route caching
-- @param ctx table Request context
-- @param config_type string Configuration type (TYPE_WHITELIST or TYPE_CU_PRICING)
-- @param config_path string Path to configuration file
-- @param ttl number Cache TTL in seconds (optional, default: 60)
-- @param force_reload boolean Force reload from disk (optional)
-- @return table|nil Configuration
-- @return string|nil Error message
function _M.load(ctx, config_type, config_path, ttl, force_reload)
    -- Check if per-route caching is enabled
    local use_per_route_cache = feature_flags.is_enabled(ctx, "per_route_config_cache")

    if not use_per_route_cache then
        -- Fallback to direct file loading (backward compatible)
        return load_yaml_file(config_path)
    end

    -- Get cache key
    local route_id = get_route_id(ctx)
    local cache_key = get_cache_key(route_id, config_type, config_path)

    -- Use provided TTL or default (no global override to avoid cross-route interference)
    ttl = ttl or DEFAULT_TTL

    -- Check module-level cache (shared across workers)
    local cached = module_cache[cache_key]
    if cached and not force_reload then
        local now = ngx.now()
        local age = now - cached.loaded_at

        if age < ttl then
            -- Cache hit
            core.log.debug("Config cache hit: ", cache_key, ", age: ", age, "s")
            return cached.config, nil
        end

        core.log.info("Config cache expired: ", cache_key, ", age: ", age, "s, ttl: ", ttl, "s")
    end

    -- Load from file
    local config, err = load_yaml_file(config_path)
    if err then
        core.log.error("Failed to load config: ", config_path, ", error: ", err)

        -- Return stale cache if available (graceful degradation)
        if cached then
            core.log.warn("Using stale config cache: ", cache_key)
            return cached.config, nil
        end

        return nil, err
    end

    -- Update module-level cache
    module_cache[cache_key] = {
        config = config,
        loaded_at = ngx.now(),
    }

    core.log.info("Config loaded and cached: ", cache_key)
    return config, nil
end


--- Load whitelist configuration
-- Convenience wrapper for whitelist config
-- @param ctx table Request context
-- @param config_path string Path to whitelist YAML file
-- @param ttl number Cache TTL in seconds (optional, default: 60)
-- @param force_reload boolean Force reload from disk (optional, default: false)
-- @return table|nil Whitelist configuration
-- @return string|nil Error message
function _M.load_whitelist(ctx, config_path, ttl, force_reload)
    return _M.load(ctx, _M.TYPE_WHITELIST, config_path, ttl, force_reload)
end


--- Load CU pricing configuration
-- Convenience wrapper for CU pricing config
-- @param ctx table Request context
-- @param config_path string Path to CU pricing YAML file
-- @param ttl number Cache TTL in seconds (optional, default: 60)
-- @param force_reload boolean Force reload from disk (optional, default: false)
-- @return table|nil CU pricing configuration
-- @return string|nil Error message
function _M.load_cu_pricing(ctx, config_path, ttl, force_reload)
    return _M.load(ctx, _M.TYPE_CU_PRICING, config_path, ttl, force_reload)
end


--- Validate whitelist configuration structure
-- @param config table Whitelist configuration
-- @return boolean true if valid
-- @return string|nil Error message
function _M.validate_whitelist(config)
    if type(config) ~= "table" then
        return false, "config must be a table"
    end

    if not config.networks or type(config.networks) ~= "table" then
        return false, "config.networks must be a table"
    end

    for network, rules in pairs(config.networks) do
        if type(rules) ~= "table" then
            return false, "network rules must be a table: " .. network
        end

        -- Check for free and paid arrays
        if rules.free and type(rules.free) ~= "table" then
            return false, "free methods must be an array: " .. network
        end

        if rules.paid and type(rules.paid) ~= "table" then
            return false, "paid methods must be an array: " .. network
        end
    end

    return true, nil
end


--- Validate CU pricing configuration structure
-- @param config table CU pricing configuration
-- @return boolean true if valid
-- @return string|nil Error message
function _M.validate_cu_pricing(config)
    if type(config) ~= "table" then
        return false, "config must be a table"
    end

    if config.default and type(config.default) ~= "number" then
        return false, "default CU must be a number"
    end

    if config.methods and type(config.methods) ~= "table" then
        return false, "methods must be a table"
    end

    return true, nil
end


--- Hot reload configuration from disk
-- Forces reload and updates cache
-- @param ctx table Request context
-- @param config_type string Configuration type
-- @param config_path string Path to configuration file
-- @return table|nil Reloaded configuration
-- @return string|nil Error message
function _M.reload(ctx, config_type, config_path)
    core.log.info("Hot reloading config: ", config_type, ", path: ", config_path)
    return _M.load(ctx, config_type, config_path, DEFAULT_TTL, true)
end


--- Clear cache by config type (compatibility API)
-- Provides compatibility with whitelist.lua/cu.lua API
-- @param config_type string Configuration type (optional, clears all if not provided)
function _M.clear_cache(config_type)
    if not config_type then
        -- Clear all module-level cache
        local count = 0
        for _ in pairs(module_cache) do
            count = count + 1
        end
        module_cache = {}
        core.log.info("Cleared all ", count, " config cache entries")
        return
    end

    -- Clear specific config type
    local cleared = 0
    for key, _ in pairs(module_cache) do
        if key:find(":" .. config_type .. ":") then
            module_cache[key] = nil
            cleared = cleared + 1
        end
    end
    core.log.info("Cleared ", cleared, " config cache entries for type: ", config_type)
end


return _M
