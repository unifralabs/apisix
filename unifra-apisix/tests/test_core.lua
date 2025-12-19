#!/usr/bin/env resty
--
-- Unit tests for unifra/jsonrpc/core.lua
--
-- Run with: resty tests/test_core.lua
-- Requires OpenResty environment (cjson, etc.)
--

-- Adjust path based on installation location
local install_path = os.getenv("UNIFRA_PATH") or "/opt/unifra-apisix"
package.path = install_path .. "/?.lua;" .. package.path

local core = require("unifra.jsonrpc.core")

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

local function assert_nil(val, msg)
    if val ~= nil then
        error((msg or "") .. " expected nil, got: " .. tostring(val))
    end
end

local function assert_not_nil(val, msg)
    if val == nil then
        error((msg or "") .. " expected non-nil value")
    end
end

print("\n=== Testing unifra/jsonrpc/core.lua ===\n")

-- Test parse: single request
test("parse: single request", function()
    local body = '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
    local result, err = core.parse(body)

    assert_nil(err, "parse error: ")
    assert_eq(result.method, "eth_blockNumber")
    assert_eq(result.is_batch, false)
    assert_eq(result.count, 1)
    assert_eq(#result.methods, 1)
    assert_eq(result.methods[1], "eth_blockNumber")
end)

-- Test parse: batch request
test("parse: batch request", function()
    local body = '[{"jsonrpc":"2.0","method":"eth_blockNumber","id":1},{"jsonrpc":"2.0","method":"eth_getBalance","params":["0x123"],"id":2}]'
    local result, err = core.parse(body)

    assert_nil(err, "parse error: ")
    assert_eq(result.method, "batch")
    assert_eq(result.is_batch, true)
    assert_eq(result.count, 2)
    assert_eq(#result.methods, 2)
    assert_eq(result.methods[1], "eth_blockNumber")
    assert_eq(result.methods[2], "eth_getBalance")
end)

-- Test parse: empty body
test("parse: empty body", function()
    local result, err = core.parse("")
    assert_nil(result)
    assert_not_nil(err)
    assert_eq(err, "empty body")
end)

-- Test parse: invalid JSON
test("parse: invalid JSON", function()
    local result, err = core.parse("{invalid json}")
    assert_nil(result)
    assert_not_nil(err)
    assert(err:find("parse error"), "expected parse error")
end)

-- Test parse: empty batch
test("parse: empty batch", function()
    local result, err = core.parse("[]")
    assert_nil(result)
    assert_not_nil(err)
    assert_eq(err, "empty batch")
end)

-- Test parse: missing method
test("parse: missing method", function()
    local result, err = core.parse('{"jsonrpc":"2.0","id":1}')
    assert_nil(result)
    assert_not_nil(err)
    assert(err:find("missing method"), "expected missing method error")
end)

-- Test parse: empty method name
test("parse: empty method name", function()
    local result, err = core.parse('{"jsonrpc":"2.0","method":"","id":1}')
    assert_nil(result)
    assert_not_nil(err)
    assert(err:find("empty method"), "expected empty method error")
end)

-- Test error_response
test("error_response: generates valid JSON", function()
    local resp = core.error_response(-32700, "Parse error", 123)
    assert_not_nil(resp)
    -- Parse it back to verify it's valid JSON
    local cjson = require("cjson.safe")
    local decoded = cjson.decode(resp)
    assert_eq(decoded.jsonrpc, "2.0")
    assert_eq(decoded.id, 123)
    assert_eq(decoded.error.code, -32700)
    assert_eq(decoded.error.message, "Parse error")
end)

-- Test error_response: nil id
test("error_response: nil id", function()
    local resp = core.error_response(-32700, "Parse error", nil)
    local cjson = require("cjson.safe")
    local decoded = cjson.decode(resp)
    assert_eq(decoded.id, nil)
end)

-- Test error_table
test("error_table: returns table", function()
    local t = core.error_table(-32600, "Invalid request", 1)
    assert_eq(type(t), "table")
    assert_eq(t.jsonrpc, "2.0")
    assert_eq(t.error.code, -32600)
    assert_eq(t.error.message, "Invalid request")
end)

-- Test extract_network: unifra.io format
test("extract_network: unifra.io format", function()
    assert_eq(core.extract_network("eth-mainnet.unifra.io"), "eth-mainnet")
    assert_eq(core.extract_network("polygon-mainnet.unifra.io"), "polygon-mainnet")
    assert_eq(core.extract_network("staging-eth-mainnet.unifra.io"), "staging-eth-mainnet")
end)

-- Test extract_network: generic format
test("extract_network: generic format", function()
    assert_eq(core.extract_network("eth-mainnet.example.com"), "eth-mainnet")
end)

-- Test extract_network: nil input
test("extract_network: nil input", function()
    assert_nil(core.extract_network(nil))
end)

-- Test match_method: exact match
test("match_method: exact match", function()
    assert_eq(core.match_method("eth_blockNumber", "eth_blockNumber"), true)
    assert_eq(core.match_method("eth_blockNumber", "eth_call"), false)
end)

-- Test match_method: wildcard
test("match_method: wildcard", function()
    assert_eq(core.match_method("eth_blockNumber", "eth_*"), true)
    assert_eq(core.match_method("eth_getBalance", "eth_*"), true)
    assert_eq(core.match_method("debug_traceTransaction", "debug_*"), true)
    assert_eq(core.match_method("net_version", "eth_*"), false)
end)

-- Test method_in_list
test("method_in_list: mixed patterns", function()
    local patterns = {"eth_blockNumber", "web3_*", "net_version"}

    assert_eq(core.method_in_list("eth_blockNumber", patterns), true)
    assert_eq(core.method_in_list("web3_clientVersion", patterns), true)
    assert_eq(core.method_in_list("web3_sha3", patterns), true)
    assert_eq(core.method_in_list("net_version", patterns), true)
    assert_eq(core.method_in_list("eth_call", patterns), false)
    assert_eq(core.method_in_list("debug_traceTransaction", patterns), false)
end)

-- Test method_in_list: nil list
test("method_in_list: nil list", function()
    assert_eq(core.method_in_list("eth_blockNumber", nil), false)
end)

-- Test method_in_list: empty list
test("method_in_list: empty list", function()
    assert_eq(core.method_in_list("eth_blockNumber", {}), false)
end)

-- Test constants
test("error constants defined", function()
    assert_eq(core.ERROR_PARSE, -32700)
    assert_eq(core.ERROR_INVALID_REQUEST, -32600)
    assert_eq(core.ERROR_METHOD_NOT_FOUND, -32601)
    assert_eq(core.ERROR_RATE_LIMITED, -32000)
    assert_eq(core.ERROR_QUOTA_EXCEEDED, -32001)
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
