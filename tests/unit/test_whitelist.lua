--
-- Unit tests for whitelist access control
-- Tests method access validation for free and paid tiers
--

package.path = "?.lua;../?.lua;../?/init.lua;" .. package.path

local conftest = require("tests.conftest")
conftest.setup()

local whitelist = require("unifra.jsonrpc.whitelist")

describe("Whitelist Access Control", function()
    local config

    setup(function()
        conftest.setup()
        -- Build a proper whitelist config
        config = {
            networks = {
                ["eth-mainnet"] = {
                    free = {"eth_blockNumber", "eth_chainId", "eth_gasPrice", "eth_call", "eth_getBalance"},
                    paid = {"debug_*", "trace_*"},
                    free_lookup = {},
                    paid_lookup = {}
                },
                ["polygon"] = {
                    free = {"eth_*"},
                    paid = {"debug_*"},
                    free_lookup = {},
                    paid_lookup = {}
                }
            }
        }
        -- Build lookup tables
        for network, nc in pairs(config.networks) do
            for _, m in ipairs(nc.free) do nc.free_lookup[m] = true end
            for _, m in ipairs(nc.paid) do nc.paid_lookup[m] = true end
        end
    end)

    teardown(function()
        conftest.teardown()
    end)

    describe("check (free tier)", function()
        it("should allow free methods for free tier", function()
            local ok, err = whitelist.check("eth-mainnet", {"eth_blockNumber"}, false, config)
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should allow multiple free methods", function()
            local ok, err = whitelist.check("eth-mainnet", {"eth_blockNumber", "eth_chainId"}, false, config)
            assert.is_true(ok)
        end)

        it("should reject paid methods for free tier", function()
            local ok, err = whitelist.check("eth-mainnet", {"debug_traceTransaction"}, false, config)
            assert.is_false(ok)
            assert.is_truthy(err:match("requires paid tier"))
        end)

        it("should reject if any method in batch requires paid", function()
            local ok, err = whitelist.check("eth-mainnet", {"eth_blockNumber", "debug_trace"}, false, config)
            assert.is_false(ok)
            assert.is_truthy(err:match("requires paid tier"))
        end)
    end)

    describe("check (paid tier)", function()
        it("should allow free methods for paid tier", function()
            local ok, err = whitelist.check("eth-mainnet", {"eth_blockNumber"}, true, config)
            assert.is_true(ok)
        end)

        it("should allow paid methods for paid tier", function()
            local ok, err = whitelist.check("eth-mainnet", {"debug_traceTransaction"}, true, config)
            assert.is_true(ok)
        end)

        it("should allow mixed methods for paid tier", function()
            local ok, err = whitelist.check("eth-mainnet", {"eth_blockNumber", "debug_trace"}, true, config)
            assert.is_true(ok)
        end)
    end)

    describe("check (unsupported)", function()
        it("should reject unsupported network", function()
            local ok, err = whitelist.check("unsupported-network", {"eth_blockNumber"}, false, config)
            assert.is_false(ok)
            assert.is_truthy(err:match("unsupported network"))
        end)

        it("should reject unsupported method", function()
            local ok, err = whitelist.check("eth-mainnet", {"completely_unknown_method"}, false, config)
            assert.is_false(ok)
            assert.is_truthy(err:match("unsupported method"))
        end)
    end)

    describe("check (edge cases)", function()
        it("should reject nil methods", function()
            local ok, err = whitelist.check("eth-mainnet", nil, false, config)
            assert.is_false(ok)
        end)

        it("should reject empty methods", function()
            local ok, err = whitelist.check("eth-mainnet", {}, false, config)
            assert.is_false(ok)
        end)

        it("should reject nil network", function()
            local ok, err = whitelist.check(nil, {"eth_blockNumber"}, false, config)
            assert.is_false(ok)
        end)

        it("should reject nil config", function()
            local ok, err = whitelist.check("eth-mainnet", {"eth_blockNumber"}, false, nil)
            assert.is_false(ok)
        end)
    end)

    describe("wildcard matching", function()
        it("should match eth_* pattern for polygon", function()
            local ok, err = whitelist.check("polygon", {"eth_anyMethod"}, false, config)
            assert.is_true(ok)
        end)

        it("should match debug_* for paid polygon user", function()
            local ok, err = whitelist.check("polygon", {"debug_trace"}, true, config)
            assert.is_true(ok)
        end)
    end)

    describe("is_network_supported", function()
        it("should return true for supported network", function()
            assert.is_true(whitelist.is_network_supported("eth-mainnet", config))
            assert.is_true(whitelist.is_network_supported("polygon", config))
        end)

        it("should return false for unsupported network", function()
            assert.is_false(whitelist.is_network_supported("unknown", config))
        end)
    end)

    describe("get_networks", function()
        it("should return all networks", function()
            local networks = whitelist.get_networks(config)
            assert.equals(2, #networks)
            -- Should be sorted
            assert.equals("eth-mainnet", networks[1])
            assert.equals("polygon", networks[2])
        end)
    end)
end)
