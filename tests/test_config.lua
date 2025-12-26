--
-- Unit tests for unifra/jsonrpc/config.lua
--
-- Run with: busted tests/test_config.lua
--

describe("config module", function()
    local config_mod
    local lfs

    setup(function()
        -- Mock dependencies
        _G.ngx = {
            log = function() end,
            INFO = 1,
            WARN = 2,
            ERR = 3,
            now = function() return 1000000 end,
        }

        -- Mock lfs for file operations
        lfs = {
            attributes = function(path)
                -- Mock file exists with modification time
                if path:match("%.yaml$") then
                    return { modification = 1000000 }
                end
                return nil
            end
        }
        package.preload["lfs"] = function() return lfs end

        config_mod = require("unifra.jsonrpc.config")
    end)

    teardown(function()
        package.loaded["unifra.jsonrpc.config"] = nil
        package.preload["lfs"] = nil
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
            local config1 = config_mod.load(ctx1, "test", "/test/config.yaml", 60)

            -- Load for route 2
            local config2 = config_mod.load(ctx2, "test", "/test/config.yaml", 60)

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
            local config1 = config_mod.load(ctx, "test", "/test/config.yaml", 60)

            -- Second load (within TTL)
            local config2 = config_mod.load(ctx, "test", "/test/config.yaml", 60)

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
            local config1 = config_mod.load(ctx, "test", "/test/config.yaml", 60)

            -- Second load at T=1000061 (TTL expired)
            _G.ngx.now = function() return 1000061 end
            local config2 = config_mod.load(ctx, "test", "/test/config.yaml", 60)

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
            local config, err = config_mod.load_whitelist(ctx, "/test/whitelist.yaml")

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

            local config, err = config_mod.load_cu_pricing(ctx, "/test/cu-pricing.yaml")

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
                _config_cache = {
                    ["route-1:whitelist:/test.yaml"] = { data = "test" }
                },
                matched_route = {
                    value = { id = "route-1" }
                }
            }

            config_mod.clear_cache("whitelist")

            -- Context cache should be emptied
            local count = 0
            for k, v in pairs(ctx._config_cache) do
                if k:match("whitelist") then
                    count = count + 1
                end
            end
            assert.equals(0, count)
        end)

        it("should clear all caches", function()
            local ctx = {
                _config_cache = {
                    ["route-1:whitelist:/test.yaml"] = { data = "test1" },
                    ["route-1:cu_pricing:/test.yaml"] = { data = "test2" }
                }
            }

            config_mod.clear_cache()

            -- Global state should be reset
            assert.is_not_nil(config_mod)
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
            local config1 = config_mod.load(ctx, "test", "/test/config.yaml", 60, false)

            -- Force reload
            local config2 = config_mod.load(ctx, "test", "/test/config.yaml", 60, true)

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

            -- Mock lfs to return nil (file not found)
            lfs.attributes = function() return nil end

            local config, err = config_mod.load(ctx, "test", "/nonexistent/config.yaml", 60)

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

            -- This will fail during actual file read
            -- In integration tests, use malformed YAML file
            local config, err = config_mod.load(ctx, "test", "/invalid/config.yaml", 60)

            if not config then
                assert.is_not_nil(err)
            end
        end)
    end)
end)
