-- Run with luajit or resty; the entitlement resolver has no APISIX dependencies.
local root = os.getenv("UNIFRA_PATH") or "/opt/unifra-apisix"
package.path = root .. "/?.lua;" .. package.path
local access = require("unifra.jsonrpc.access")
local passed = 0

local function check(name, conf, tier, expected, source, authenticated)
    local ctx = {
        -- Spoofed request/route variables must never grant method access.
        var = { monthly_quota = 1e9, rpc_tier = "paid" },
        consumer = authenticated ~= false and {
            plugins = { ["unifra-ctx-var"] = { rpc_tier = tier } }
        } or nil,
    }
    local paid, actual_source = access.is_paid(conf, ctx)
    assert(paid == expected, name .. ": unexpected entitlement")
    assert(actual_source == source, name .. ": unexpected source " .. actual_source)
    passed = passed + 1
end

check("public paid consumer", { method_policy = "free_only" }, "paid", false, "free_only")
check("free ignores high quota", {}, "free", false, "rpc_tier_free")
check("paid ignores quota", {}, "paid", true, "rpc_tier_paid")
check("missing tier ignores high quota", {}, nil, false, "missing_rpc_tier")
check("invalid explicit value", {}, "invalid", false, "rpc_tier_free")
check("empty explicit value", {}, "", false, "rpc_tier_free")
check("boolean explicit value", {}, true, false, "rpc_tier_free")
check("anonymous variables", {}, "paid", false, "unauthenticated", false)
check("invalid policy", { method_policy = "invalid" }, "paid", false, "invalid_policy")
assert(not access.should_bypass({ method_policy = "free_only", bypass_networks = { "arc" } }, "arc-testnet"))
assert(access.should_bypass({ bypass_networks = { "arc" } }, "arc-testnet"))
assert(not access.should_bypass({ bypass_networks = { "arc" } }, nil))
print(string.format("%d access resolver checks passed", passed + 3))
