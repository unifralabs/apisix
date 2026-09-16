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
        local raw = {
            schema_version = 1,
            revision = "test-revision",
            method_profiles = {
                evm = {"eth_blockNumber", "eth_chainId", "eth_gasPrice", "eth_call", "eth_getBalance"},
                debug = {"debug_traceTransaction", "debug_traceCall"},
                trace = {"trace_block", "trace_transaction"},
            },
            networks = {
                ["eth-mainnet"] = {
                    display_name = "Ethereum Mainnet",
                    published = true,
                    free_profiles = {"evm"},
                    paid_profiles = {"debug", "trace"},
                },
                ["polygon"] = {
                    published = true,
                    free_profiles = {"evm"},
                    paid_profiles = {"debug"},
                },
                ["staging-internal"] = {
                    published = false,
                    free = {"eth_blockNumber"},
                }
            }
        }
        config = assert(whitelist.process_config(raw))
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
            local ok, err = whitelist.check("eth-mainnet", {"eth_blockNumber", "debug_traceCall"}, false, config)
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
            local ok, err = whitelist.check("eth-mainnet", {"eth_blockNumber", "debug_traceCall"}, true, config)
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

    describe("explicit method profiles", function()
        it("should expand a reusable profile to exact names", function()
            local ok = whitelist.check("polygon", {"eth_call"}, false, config)
            assert.is_true(ok)
        end)

        it("should reject unknown names even when their prefix is familiar", function()
            local ok, err = whitelist.check("polygon", {"eth_anyMethod"}, false, config)
            assert.is_false(ok)
            assert.is_truthy(err:match("unsupported method"))
        end)

        it("should reject wildcard entries while loading configuration", function()
            local parsed, err = whitelist.process_config({
                networks = {bad = {free = {"eth_*"}, paid = {}}},
            })
            assert.is_nil(parsed)
            assert.is_truthy(err:match("wildcard methods are not allowed"))
        end)

        it("should reject unknown profiles", function()
            local parsed, err = whitelist.process_config({
                networks = {bad = {free_profiles = {"missing"}}},
            })
            assert.is_nil(parsed)
            assert.is_truthy(err:match("unknown method profile"))
        end)
    end)

    describe("public capabilities", function()
        it("should expose sorted sanitized published networks", function()
            local capabilities = whitelist.get_capabilities(config)
            assert.equals(1, capabilities.schema_version)
            assert.equals("test-revision", capabilities.revision)
            assert.equals(2, #capabilities.networks)
            assert.equals("eth-mainnet", capabilities.networks[1].id)
            assert.equals("Ethereum Mainnet", capabilities.networks[1].display_name)
            assert.is_nil(capabilities.networks[1].free_lookup)
            assert.equals("polygon", capabilities.networks[2].id)
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
            assert.equals(3, #networks)
            -- Should be sorted
            assert.equals("eth-mainnet", networks[1])
            assert.equals("polygon", networks[2])
            assert.equals("staging-internal", networks[3])
        end)
    end)
end)
