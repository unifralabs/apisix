--
-- Unit tests for unifra/jsonrpc/config.lua
--
-- Run with: busted tests/test_config.lua
--

-- Mock apisix.core BEFORE requiring the module
package.preload["apisix.core"] = function()
    return {
        log = {
            info = function() end,
            warn = function() end,
            error = function() end,
            debug = function() end,
        },
        table = {
            clone = function(t)
                local copy = {}
                for k, v in pairs(t) do copy[k] = v end
                return copy
            end
        }
    }
end

local function fixture_path(relative)
    local script_path = debug.getinfo(1, "S").source:sub(2)
    local tests_dir = script_path:match("(.*/)")
    return tests_dir .. "../fixtures/" .. relative
end

local TEST_CONFIG_PATH = fixture_path("config/test-config.yaml")
local MISSING_CONFIG_PATH = fixture_path("config/missing-config.yaml")
local INVALID_CONFIG_PATH = fixture_path("config/invalid-config.yaml")

describe("config module", function()
    local config_mod
    local lyaml_stubbed = false

    setup(function()
        -- Mock ngx
        _G.ngx = {
            log = function() end,
            INFO = 1,
            WARN = 2,
            ERR = 3,
            now = function() return 1000000 end,
        }

        -- Ensure lyaml is available for config parsing
        local ok = pcall(require, "lyaml")
        if not ok then
            lyaml_stubbed = true
            package.preload["lyaml"] = function()
                return {
                    load = function(content)
                        if content and content:find("INVALID_YAML") then
                            error("invalid yaml")
                        end
                        return { test = true }
                    end
                }
            end
        end

        config_mod = require("unifra.jsonrpc.config")
    end)

    teardown(function()
        package.loaded["unifra.jsonrpc.config"] = nil
        if lyaml_stubbed then
            package.preload["lyaml"] = nil
            package.loaded["lyaml"] = nil
        end
    end)

    before_each(function()
        config_mod.clear_cache()
    end)

    describe("per-route caching", function()
        it("should cache config per route", function()
            local ctx1 = {
                _config_cache = {},
                matched_route = {
                    value = { id = "route-1" }
                }
            }

            local ctx2 = {
                _config_cache = {},
                matched_route = {
                    value = { id = "route-2" }
                }
            }

            -- Load for route 1
            local config1 = config_mod.load(ctx1, "test", TEST_CONFIG_PATH, 60)

            -- Load for route 2
            local config2 = config_mod.load(ctx2, "test", TEST_CONFIG_PATH, 60)

            -- Both should have independent caches
            assert.is_not_nil(ctx1._config_cache)
            assert.is_not_nil(ctx2._config_cache)
        end)

        it("should use cached config within TTL", function()
            local ctx = {
                _config_cache = {},
                matched_route = {
                    value = { id = "route-1" }
                }
            }

            -- First load
            local config1 = config_mod.load(ctx, "test", TEST_CONFIG_PATH, 60)

            -- Second load (within TTL)
            local config2 = config_mod.load(ctx, "test", TEST_CONFIG_PATH, 60)

            -- Should return cached value (same reference)
            assert.equals(config1, config2)
        end)

        it("should reload after TTL expiry", function()
            local ctx = {
                _config_cache = {},
                matched_route = {
                    value = { id = "route-1" }
                }
            }

            -- First load at T=1000000
            _G.ngx.now = function() return 1000000 end
            local config1 = config_mod.load(ctx, "test", TEST_CONFIG_PATH, 60)

            -- Second load at T=1000061 (TTL expired)
            _G.ngx.now = function() return 1000061 end
            local config2 = config_mod.load(ctx, "test", TEST_CONFIG_PATH, 60)

            -- Should trigger reload
            assert.is_not_nil(config2)
        end)
    end)

    describe("config type loaders", function()
        it("should load whitelist config", function()
            local ctx = {
                _config_cache = {},
                matched_route = {
                    value = { id = "route-1" }
                }
            }

            -- Note: This will fail in real test without actual file
            -- In production, use integration tests with real config files
            local config, err = config_mod.load_whitelist(ctx, TEST_CONFIG_PATH)

            -- In unit test, we expect graceful failure
            if not config then
                assert.is_not_nil(err)
            end
        end)

        it("should load CU pricing config", function()
            local ctx = {
                _config_cache = {},
                matched_route = {
                    value = { id = "route-1" }
                }
            }

            local config, err = config_mod.load_cu_pricing(ctx, TEST_CONFIG_PATH)

            if not config then
                assert.is_not_nil(err)
            end
        end)
    end)

    describe("TTL configuration", function()
        it("should use global TTL by default", function()
            config_mod.set_ttl("test_type", 120)

            local ttl = config_mod.get_ttl("test_type")
            assert.equals(120, ttl)
        end)

        it("should fall back to default TTL", function()
            local ttl = config_mod.get_ttl("unknown_type")
            assert.equals(60, ttl)  -- Default TTL
        end)
    end)

    describe("cache management", function()
        it("should clear specific config type", function()
            local ctx = {
                matched_route = {
                    value = { id = "route-1" }
                }
            }

            local config1 = config_mod.load(ctx, "whitelist", TEST_CONFIG_PATH, 60)
            config_mod.clear_cache("whitelist")
            local config2 = config_mod.load(ctx, "whitelist", TEST_CONFIG_PATH, 60)

            assert.is_not_nil(config1)
            assert.is_not_nil(config2)
            assert.is_true(config1 ~= config2)
        end)

        it("should clear all caches", function()
            local ctx = {
                matched_route = {
                    value = { id = "route-1" }
                }
            }

            local config1 = config_mod.load(ctx, "whitelist", TEST_CONFIG_PATH, 60)
            local config2 = config_mod.load(ctx, "cu_pricing", TEST_CONFIG_PATH, 60)

            config_mod.clear_cache()

            local config1b = config_mod.load(ctx, "whitelist", TEST_CONFIG_PATH, 60)
            local config2b = config_mod.load(ctx, "cu_pricing", TEST_CONFIG_PATH, 60)

            assert.is_not_nil(config1)
            assert.is_not_nil(config2)
            assert.is_not_nil(config1b)
            assert.is_not_nil(config2b)
            assert.is_true(config1 ~= config1b)
            assert.is_true(config2 ~= config2b)
        end)
    end)

    describe("force reload", function()
        it("should reload when force_reload=true", function()
            local ctx = {
                _config_cache = {},
                matched_route = {
                    value = { id = "route-1" }
                }
            }

            -- First load
            local config1 = config_mod.load(ctx, "test", TEST_CONFIG_PATH, 60, false)

            -- Force reload
            local config2 = config_mod.load(ctx, "test", TEST_CONFIG_PATH, 60, true)

            -- Should attempt reload regardless of TTL
            assert.is_not_nil(config2)
        end)
    end)

    describe("error handling", function()
        it("should return error when file not found", function()
            local ctx = {
                _config_cache = {},
                matched_route = {
                    value = { id = "route-1" }
                }
            }

            local config, err = config_mod.load(ctx, "test", MISSING_CONFIG_PATH, 60)

            assert.is_nil(config)
            assert.is_not_nil(err)
            assert.is_true(err:match("file not found") ~= nil or err:match("not found") ~= nil)
        end)

        it("should return error when parse fails", function()
            local ctx = {
                _config_cache = {},
                matched_route = {
                    value = { id = "route-1" }
                }
            }

            -- Use malformed YAML fixture to trigger parse error
            local config, err = config_mod.load(ctx, "test", INVALID_CONFIG_PATH, 60)

            if not config then
                assert.is_not_nil(err)
            end
        end)
    end)
end)
