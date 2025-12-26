--
-- Unit tests for JSON-RPC core parsing
-- Tests the parse() function for single and batch requests
--

package.path = "?.lua;../?.lua;../?/init.lua;" .. package.path

local conftest = require("tests.conftest")
conftest.setup()

-- Mock cjson
local cjson = require("cjson.safe")

local core = require("unifra.jsonrpc.core")

describe("JSON-RPC Core Parsing", function()

    setup(function()
        conftest.setup()
    end)

    teardown(function()
        conftest.teardown()
    end)

    describe("parse single request", function()
        it("should parse valid single request", function()
            local body = '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
            local result, err = core.parse(body)

            assert.is_nil(err)
            assert.is_not_nil(result)
            assert.equals("eth_blockNumber", result.method)
            assert.equals(false, result.is_batch)
            assert.equals(1, result.count)
            assert.same({"eth_blockNumber"}, result.methods)
        end)

        it("should extract method with params", function()
            local body = '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0x0"},"latest"],"id":1}'
            local result, err = core.parse(body)

            assert.is_nil(err)
            assert.equals("eth_call", result.method)
        end)

        it("should handle notification (no id)", function()
            local body = '{"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"]}'
            local result, err = core.parse(body)

            assert.is_nil(err)
            assert.equals("eth_subscribe", result.method)
        end)
    end)

    describe("parse batch request", function()
        it("should parse valid batch request", function()
            local body = '[{"jsonrpc":"2.0","method":"eth_blockNumber","id":1},{"jsonrpc":"2.0","method":"eth_chainId","id":2}]'
            local result, err = core.parse(body)

            assert.is_nil(err)
            assert.equals(true, result.is_batch)
            assert.equals(2, result.count)
            assert.same({"eth_blockNumber", "eth_chainId"}, result.methods)
        end)

        it("should extract all IDs from batch", function()
            local body = '[{"jsonrpc":"2.0","method":"m1","id":1},{"jsonrpc":"2.0","method":"m2","id":"str-id"}]'
            local result, err = core.parse(body)

            assert.is_nil(err)
            assert.equals(1, result.ids[1])
            assert.equals("str-id", result.ids[2])
        end)
    end)

    describe("parse errors", function()
        it("should reject empty body", function()
            local result, err = core.parse("")
            assert.is_nil(result)
            assert.equals("empty body", err)
        end)

        it("should reject nil body", function()
            local result, err = core.parse(nil)
            assert.is_nil(result)
            assert.equals("empty body", err)
        end)

        it("should reject invalid JSON", function()
            local result, err = core.parse("{invalid json")
            assert.is_nil(result)
            assert.is_truthy(err:match("parse error"))
        end)

        it("should reject missing method", function()
            local result, err = core.parse('{"jsonrpc":"2.0","params":[],"id":1}')
            assert.is_nil(result)
            assert.equals("missing method field", err)
        end)

        it("should reject empty method", function()
            local result, err = core.parse('{"jsonrpc":"2.0","method":"","id":1}')
            assert.is_nil(result)
            assert.equals("empty method name", err)
        end)

        it("should reject empty batch", function()
            local result, err = core.parse('[]')
            assert.is_nil(result)
            assert.equals("empty batch", err)
        end)

        it("should reject body exceeding max size", function()
            local large_body = string.rep("x", 1048577) -- > 1 MiB
            local result, err = core.parse(large_body)
            assert.is_nil(result)
            assert.equals("body too large", err)
        end)

        it("should reject batch exceeding max size", function()
            local batch = {}
            for i = 1, 101 do
                table.insert(batch, {jsonrpc = "2.0", method = "m" .. i, id = i})
            end
            local body = cjson.encode(batch)
            local result, err = core.parse(body)
            assert.is_nil(result)
            assert.is_truthy(err:match("batch too large"))
        end)
    end)

    describe("error_response", function()
        it("should generate valid error response", function()
            local resp = core.error_response(-32600, "Invalid Request", 1)
            local decoded = cjson.decode(resp)

            assert.equals("2.0", decoded.jsonrpc)
            assert.equals(1, decoded.id)
            assert.equals(-32600, decoded.error.code)
            assert.equals("Invalid Request", decoded.error.message)
        end)

        it("should handle nil id", function()
            local resp = core.error_response(-32700, "Parse error", nil)
            local decoded = cjson.decode(resp)

            -- nil id should become null in JSON
            assert.equals(cjson.null, decoded.id)
        end)
    end)

    describe("extract_network", function()
        it("should extract network from unifra.io domain", function()
            assert.equals("eth-mainnet", core.extract_network("eth-mainnet.unifra.io"))
            assert.equals("polygon", core.extract_network("polygon.unifra.io"))
        end)

        it("should extract network from generic domain", function()
            assert.equals("eth", core.extract_network("eth.example.com"))
        end)

        it("should return nil for nil host", function()
            assert.is_nil(core.extract_network(nil))
        end)
    end)

    describe("match_method", function()
        it("should match exact method", function()
            assert.is_true(core.match_method("eth_call", "eth_call"))
        end)

        it("should not match different method", function()
            assert.is_false(core.match_method("eth_call", "eth_send"))
        end)

        it("should match wildcard pattern", function()
            assert.is_true(core.match_method("debug_traceTransaction", "debug_*"))
            assert.is_true(core.match_method("debug_anything", "debug_*"))
        end)

        it("should not match partial wildcard", function()
            assert.is_false(core.match_method("eth_debug_trace", "debug_*"))
        end)
    end)
end)
