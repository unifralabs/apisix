--
-- Shared test configuration and fixtures for Busted tests
--

local _M = {}

-- Setup package path for testing
local function setup_path()
    local script_path = debug.getinfo(1, "S").source:sub(2)
    local tests_dir = script_path:match("(.*/)")
    local project_root = tests_dir:match("(.*/)[^/]+/") or tests_dir .. "../"

    package.path = project_root .. "?.lua;" ..
                   project_root .. "?/init.lua;" ..
                   package.path
end

setup_path()

-- Load mock ngx
local mock_ngx = require("tests.helpers.mock_ngx")

-- Install mock before loading modules
function _M.setup()
    mock_ngx.install()
end

-- Cleanup after tests
function _M.teardown()
    mock_ngx.reset()
end

-- Reset between tests
function _M.reset()
    mock_ngx.reset()
end

-- Common test fixtures

_M.fixtures = {
    -- CU pricing configuration
    cu_config = {
        default = 1,
        methods = {
            ["eth_blockNumber"] = 1,
            ["eth_chainId"] = 1,
            ["eth_gasPrice"] = 1,
            ["eth_getBalance"] = 2,
            ["eth_call"] = 5,
            ["eth_estimateGas"] = 5,
            ["eth_getLogs"] = 10,
            ["eth_getTransactionReceipt"] = 3,
            ["debug_*"] = 20,
            ["trace_*"] = 50,
        }
    },

    -- Whitelist configuration
    whitelist_config = {
        networks = {
            ["eth-mainnet"] = {
                free = {"eth_blockNumber", "eth_chainId", "eth_gasPrice", "eth_call", "eth_*"},
                paid = {"debug_*", "trace_*"},
                free_lookup = {},
                paid_lookup = {}
            }
        }
    },

    -- Test consumers
    consumers = {
        free_tier = {
            username = "test-free-user",
            api_key = "free-api-key-123",
            seconds_quota = 100,
            monthly_quota = 10000,
            tier = "free"
        },
        paid_tier = {
            username = "test-paid-user",
            api_key = "paid-api-key-456",
            seconds_quota = 1000,
            monthly_quota = 1000000,
            tier = "paid"
        },
        exhausted = {
            username = "test-exhausted-user",
            api_key = "exhausted-api-key-789",
            seconds_quota = 100,
            monthly_quota = 100,
            used_quota = 100,
            tier = "free"
        }
    },

    -- Test JSON-RPC requests
    requests = {
        single_valid = '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}',
        single_call = '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0x0","data":"0x"},"latest"],"id":1}',
        batch_valid = '[{"jsonrpc":"2.0","method":"eth_blockNumber","id":1},{"jsonrpc":"2.0","method":"eth_chainId","id":2}]',
        batch_mixed = '[{"jsonrpc":"2.0","method":"eth_blockNumber","id":1},{"jsonrpc":"2.0","method":"debug_trace","id":2}]',
        invalid_json = '{"invalid json',
        missing_method = '{"jsonrpc":"2.0","params":[],"id":1}',
        empty_batch = '[]',
    }
}

-- Build lookup tables for whitelist config
local function build_lookups()
    for network, config in pairs(_M.fixtures.whitelist_config.networks) do
        for _, m in ipairs(config.free) do
            config.free_lookup[m] = true
        end
        for _, m in ipairs(config.paid) do
            config.paid_lookup[m] = true
        end
    end
end
build_lookups()

return _M
