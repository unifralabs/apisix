--
-- Unit tests for CU calculation accuracy
-- These tests verify that compute unit costs are calculated correctly
--

-- Setup path
package.path = "?.lua;../?.lua;../?/init.lua;" .. package.path

-- Load test helpers
local conftest = require("tests.conftest")
conftest.setup()

-- Now load the module under test
local cu = require("unifra.jsonrpc.cu")

describe("CU Calculation Accuracy", function()
    local config

    setup(function()
        conftest.setup()
        config = conftest.fixtures.cu_config
    end)

    teardown(function()
        conftest.teardown()
    end)

    before_each(function()
        conftest.reset()
    end)

    describe("get_method_cu", function()
        it("should return exact CU for known methods", function()
            assert.equals(1, cu.get_method_cu("eth_blockNumber", config))
            assert.equals(5, cu.get_method_cu("eth_call", config))
            assert.equals(10, cu.get_method_cu("eth_getLogs", config))
        end)

        it("should match wildcard patterns", function()
            assert.equals(20, cu.get_method_cu("debug_traceTransaction", config))
            assert.equals(20, cu.get_method_cu("debug_traceCall", config))
            assert.equals(50, cu.get_method_cu("trace_block", config))
            assert.equals(50, cu.get_method_cu("trace_call", config))
        end)

        it("should return default CU for unknown methods", function()
            assert.equals(1, cu.get_method_cu("unknown_method", config))
            assert.equals(1, cu.get_method_cu("net_version", config))
        end)

        it("should return 1 when config is nil", function()
            assert.equals(1, cu.get_method_cu("eth_call", nil))
        end)

        it("should return default when methods table is empty", function()
            local empty_config = { default = 5, methods = {} }
            assert.equals(5, cu.get_method_cu("any_method", empty_config))
        end)
    end)

    describe("calculate (single method)", function()
        it("should calculate CU for single method", function()
            assert.equals(1, cu.calculate({"eth_blockNumber"}, config))
            assert.equals(5, cu.calculate({"eth_call"}, config))
            assert.equals(10, cu.calculate({"eth_getLogs"}, config))
        end)
    end)

    describe("calculate (batch methods)", function()
        it("should sum CU for multiple methods", function()
            local methods = {"eth_blockNumber", "eth_call", "eth_getLogs"}
            assert.equals(16, cu.calculate(methods, config)) -- 1 + 5 + 10
        end)

        it("should handle duplicate methods", function()
            local methods = {"eth_blockNumber", "eth_blockNumber", "eth_call"}
            assert.equals(7, cu.calculate(methods, config)) -- 1 + 1 + 5
        end)

        it("should handle mixed known and unknown methods", function()
            local methods = {"eth_blockNumber", "unknown_method", "eth_call"}
            assert.equals(7, cu.calculate(methods, config)) -- 1 + 1 + 5
        end)

        it("should handle wildcard methods in batch", function()
            local methods = {"eth_blockNumber", "debug_trace", "trace_block"}
            assert.equals(71, cu.calculate(methods, config)) -- 1 + 20 + 50
        end)
    end)

    describe("calculate (edge cases)", function()
        it("should return 0 for empty list", function()
            assert.equals(0, cu.calculate({}, config))
        end)

        it("should return 0 for nil list", function()
            assert.equals(0, cu.calculate(nil, config))
        end)

        it("should handle large batch correctly", function()
            local methods = {}
            for i = 1, 100 do
                table.insert(methods, "eth_blockNumber")
            end
            assert.equals(100, cu.calculate(methods, config))
        end)
    end)

    describe("calculate_breakdown", function()
        it("should return breakdown and total", function()
            local methods = {"eth_blockNumber", "eth_call", "eth_blockNumber"}
            local breakdown, total = cu.calculate_breakdown(methods, config)

            assert.equals(7, total) -- 1 + 5 + 1
            assert.equals(2, breakdown["eth_blockNumber"]) -- 1 + 1
            assert.equals(5, breakdown["eth_call"])
        end)

        it("should return empty breakdown for empty list", function()
            local breakdown, total = cu.calculate_breakdown({}, config)
            assert.equals(0, total)
            assert.same({}, breakdown)
        end)
    end)
end)
