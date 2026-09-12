-- Unit tests for sanitized public gateway errors.

package.path = "?.lua;../?.lua;../?/init.lua;" .. package.path

local conftest = require("tests.conftest")
conftest.setup()

local cjson = require("cjson.safe")
local errors = require("unifra.jsonrpc.errors")

describe("JSON-RPC gateway errors", function()
    before_each(function()
        conftest.reset()
    end)

    teardown(function()
        conftest.teardown()
    end)

    it("returns a generic 503 for infrastructure failures", function()
        local status, body = errors.response(
            { var = {} },
            errors.ERR_SERVICE_UNAVAILABLE,
            nil,
            42
        )
        local decoded = assert(cjson.decode(body))

        assert.equals(503, status)
        assert.equals(-32603, decoded.error.code)
        assert.equals("Service temporarily unavailable", decoded.error.message)
        assert.equals(42, decoded.id)
    end)

    it("maps HTTP 503 to the sanitized error type", function()
        assert.equals(errors.ERR_SERVICE_UNAVAILABLE, errors.from_http_status(503))
    end)
end)
