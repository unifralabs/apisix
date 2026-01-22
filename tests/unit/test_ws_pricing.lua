--
-- Unit tests for WebSocket Pricing features
-- Tests: Push Notification Cost parsing
--
-- NOTE: This test requires the 'busted' testing framework.
-- Run via: make test-unit
--

package.path = "?.lua;../?.lua;../?/init.lua;" .. package.path

local conftest = require("tests.conftest")
conftest.setup()

local cu = require("unifra.jsonrpc.cu")

-- Busted globals are injected by busted runner, ignore lint warnings
-- luacheck: globals describe it assert setup teardown before_each

describe("WebSocket Pricing Logic", function()
    
    describe("Push Notification CU Cost", function()
        it("should load push_notification cost table from config", function()
            local config_mod = require("unifra.jsonrpc.config")
            local old_load = config_mod.load_cu_pricing
            
            config_mod.load_cu_pricing = function()
                return {
                    default = 1,
                    push_notification = {
                        default = 15,
                        newHeads = 10,
                        logs = 25,
                        newPendingTransactions = 60
                    },
                    methods = {}
                }
            end
            
            local loaded_conf = cu.load_config(nil, "path", 10)
            assert.equals(15, loaded_conf.push_notification.default)
            assert.equals(10, loaded_conf.push_notification.newHeads)
            assert.equals(25, loaded_conf.push_notification.logs)
            assert.equals(60, loaded_conf.push_notification.newPendingTransactions)
            
            config_mod.load_cu_pricing = old_load
        end)

        it("should return default push costs if missing in config", function()
            local config_mod = require("unifra.jsonrpc.config")
            local old_load = config_mod.load_cu_pricing
            
            config_mod.load_cu_pricing = function()
                return {
                    default = 1,
                    -- missing push_notification
                }
            end
            
            local loaded_conf = cu.load_config(nil, "path", 10)
            -- Should use defaults from DEFAULT_CONFIG
            assert.equals(10, loaded_conf.push_notification.default)
            assert.equals(10, loaded_conf.push_notification.newHeads)
            assert.equals(20, loaded_conf.push_notification.logs)
            assert.equals(50, loaded_conf.push_notification.newPendingTransactions)
            
            config_mod.load_cu_pricing = old_load
        end)
        
        it("should handle legacy single-number push_notification config", function()
            local config_mod = require("unifra.jsonrpc.config")
            local old_load = config_mod.load_cu_pricing
            
            config_mod.load_cu_pricing = function()
                return {
                    default = 1,
                    push_notification = 30 -- Legacy: single number
                }
            end
            
            local loaded_conf = cu.load_config(nil, "path", 10)
            -- All event types should have the same cost
            assert.equals(30, loaded_conf.push_notification.default)
            assert.equals(30, loaded_conf.push_notification.newHeads)
            assert.equals(30, loaded_conf.push_notification.logs)
            assert.equals(30, loaded_conf.push_notification.newPendingTransactions)
            
            config_mod.load_cu_pricing = old_load
        end)
    end)
end)
