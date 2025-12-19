#!/usr/bin/env resty
--
-- Unit tests for unifra/jsonrpc/cu.lua
--
-- Run with: resty tests/test_cu.lua
-- Requires OpenResty environment
--

-- Adjust path based on installation location
local install_path = os.getenv("UNIFRA_PATH") or "/opt/unifra-apisix"
package.path = install_path .. "/?.lua;" .. package.path

local cu = require("unifra.jsonrpc.cu")

local tests_passed = 0
local tests_failed = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        tests_passed = tests_passed + 1
        print("[PASS] " .. name)
    else
        tests_failed = tests_failed + 1
        print("[FAIL] " .. name .. ": " .. tostring(err))
    end
end

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "") .. " expected: " .. tostring(expected) .. ", got: " .. tostring(actual))
    end
end

print("\n=== Testing unifra/jsonrpc/cu.lua ===\n")

-- Mock config for testing
local mock_config = {
    default = 1,
    methods = {
        ["eth_blockNumber"] = 1,
        ["eth_call"] = 5,
        ["eth_getLogs"] = 10,
        ["debug_*"] = 20,
        ["trace_block"] = 50,
    }
}

-- Test get_method_cu: exact match
test("get_method_cu: exact match", function()
    assert_eq(cu.get_method_cu("eth_blockNumber", mock_config), 1)
    assert_eq(cu.get_method_cu("eth_call", mock_config), 5)
    assert_eq(cu.get_method_cu("eth_getLogs", mock_config), 10)
    assert_eq(cu.get_method_cu("trace_block", mock_config), 50)
end)

-- Test get_method_cu: wildcard match
test("get_method_cu: wildcard match", function()
    assert_eq(cu.get_method_cu("debug_traceTransaction", mock_config), 20)
    assert_eq(cu.get_method_cu("debug_traceCall", mock_config), 20)
end)

-- Test get_method_cu: default fallback
test("get_method_cu: default fallback", function()
    assert_eq(cu.get_method_cu("eth_getBalance", mock_config), 1)
    assert_eq(cu.get_method_cu("net_version", mock_config), 1)
end)

-- Test get_method_cu: nil config
test("get_method_cu: nil config", function()
    assert_eq(cu.get_method_cu("eth_call", nil), 1)
end)

-- Test calculate: single method
test("calculate: single method", function()
    assert_eq(cu.calculate({"eth_blockNumber"}, mock_config), 1)
    assert_eq(cu.calculate({"eth_call"}, mock_config), 5)
end)

-- Test calculate: multiple methods
test("calculate: multiple methods", function()
    local methods = {"eth_blockNumber", "eth_call", "eth_getLogs"}
    assert_eq(cu.calculate(methods, mock_config), 16) -- 1 + 5 + 10
end)

-- Test calculate: batch with duplicates
test("calculate: batch with duplicates", function()
    local methods = {"eth_blockNumber", "eth_blockNumber", "eth_call"}
    assert_eq(cu.calculate(methods, mock_config), 7) -- 1 + 1 + 5
end)

-- Test calculate: empty list
test("calculate: empty list", function()
    assert_eq(cu.calculate({}, mock_config), 0)
end)

-- Test calculate: nil list
test("calculate: nil list", function()
    assert_eq(cu.calculate(nil, mock_config), 0)
end)

-- Test calculate_breakdown
test("calculate_breakdown: returns breakdown and total", function()
    local methods = {"eth_blockNumber", "eth_call", "eth_blockNumber"}
    local breakdown, total = cu.calculate_breakdown(methods, mock_config)

    assert_eq(total, 7) -- 1 + 5 + 1
    assert_eq(breakdown["eth_blockNumber"], 2) -- 1 + 1
    assert_eq(breakdown["eth_call"], 5)
end)

-- Test with config that has no methods
test("calculate: config with no methods field", function()
    local config = { default = 2 }
    assert_eq(cu.calculate({"any_method"}, config), 2)
end)

-- Summary
print("\n=== Test Summary ===")
print(string.format("Passed: %d, Failed: %d", tests_passed, tests_failed))

if tests_failed > 0 then
    os.exit(1)
else
    print("All tests passed!")
    os.exit(0)
end
