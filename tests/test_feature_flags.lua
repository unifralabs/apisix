--
-- Unit tests for unifra/feature_flags.lua
--
-- Run with: busted tests/test_feature_flags.lua
--

describe("feature_flags module", function()
    local feature_flags

    setup(function()
        -- Mock ngx and other dependencies
        _G.ngx = {
            log = function() end,
            INFO = 1,
            WARN = 2,
            ERR = 3,
            var = {},
        }

        feature_flags = require("unifra.feature_flags")
    end)

    teardown(function()
        package.loaded["unifra.feature_flags"] = nil
    end)

    describe("is_enabled", function()
        it("should return false when flag not configured", function()
            local ctx = { var = {} }
            assert.is_false(feature_flags.is_enabled(ctx, "nonexistent_flag"))
        end)

        it("should read from global config", function()
            feature_flags.set("test_flag", true)
            local ctx = { var = {} }
            assert.is_true(feature_flags.is_enabled(ctx, "test_flag"))
        end)

        it("should read from route config", function()
            feature_flags.set("test_flag", false)
            local ctx = {
                var = {},
                matched_route = {
                    value = {
                        feature_flags = {
                            test_flag = true
                        }
                    }
                }
            }
            assert.is_true(feature_flags.is_enabled(ctx, "test_flag"))
        end)

        it("should read from consumer config", function()
            feature_flags.set("test_flag", false)
            local ctx = {
                var = {
                    feature_flags = {
                        test_flag = true
                    }
                }
            }
            assert.is_true(feature_flags.is_enabled(ctx, "test_flag"))
        end)

        it("should prioritize consumer > route > global", function()
            feature_flags.set("test_flag", false)
            local ctx = {
                var = {
                    feature_flags = {
                        test_flag = true  -- Consumer: true
                    }
                },
                matched_route = {
                    value = {
                        feature_flags = {
                            test_flag = false  -- Route: false
                        }
                    }
                }
            }
            -- Consumer config should win
            assert.is_true(feature_flags.is_enabled(ctx, "test_flag"))
        end)
    end)

    describe("is_enabled_for_percentage", function()
        it("should return true for 100% rollout", function()
            feature_flags.set_percentage("test_flag", 100)
            local ctx = { var = {} }
            assert.is_true(feature_flags.is_enabled_for_percentage(ctx, "test_flag", 100))
        end)

        it("should return false for 0% rollout", function()
            feature_flags.set_percentage("test_flag", 0)
            local ctx = { var = {} }
            assert.is_false(feature_flags.is_enabled_for_percentage(ctx, "test_flag", 0))
        end)

        it("should use consistent hashing for same key", function()
            local ctx = { var = { consumer_name = "user123" } }
            local result1 = feature_flags.is_enabled_for_percentage(ctx, "test_flag", 50, "consumer_name")
            local result2 = feature_flags.is_enabled_for_percentage(ctx, "test_flag", 50, "consumer_name")
            assert.equals(result1, result2)
        end)
    end)

    describe("set and clear", function()
        it("should set global flag", function()
            feature_flags.set("new_flag", true)
            local ctx = { var = {} }
            assert.is_true(feature_flags.is_enabled(ctx, "new_flag"))
        end)

        it("should clear global flag", function()
            feature_flags.set("temp_flag", true)
            feature_flags.clear("temp_flag")
            local ctx = { var = {} }
            assert.is_false(feature_flags.is_enabled(ctx, "temp_flag"))
        end)

        it("should clear all flags", function()
            feature_flags.set("flag1", true)
            feature_flags.set("flag2", true)
            feature_flags.clear_all()
            local ctx = { var = {} }
            assert.is_false(feature_flags.is_enabled(ctx, "flag1"))
            assert.is_false(feature_flags.is_enabled(ctx, "flag2"))
        end)
    end)
end)
