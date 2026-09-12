-- Run with luajit or resty; the entitlement resolver has no APISIX dependencies.
local root = os.getenv("UNIFRA_PATH") or "/opt/unifra-apisix"
package.path = root .. "/?.lua;" .. package.path
local access = require("unifra.jsonrpc.access")
local passed = 0

local function check(name, conf, tier, quota, expected, source, authenticated)
    local ctx = {
        var = { monthly_quota = quota, rpc_tier = "paid" },
        consumer = authenticated ~= false and {
            plugins = { ["unifra-ctx-var"] = { rpc_tier = tier } }
        } or nil,
    }
    local paid, actual_source = access.is_paid(conf, ctx)
    assert(paid == expected, name .. ": unexpected entitlement")
    assert(actual_source == source, name .. ": unexpected source " .. actual_source)
    passed = passed + 1
end

check("public paid consumer", { method_policy = "free_only" }, "paid", 1e9, false, "free_only")
check("free with high quota", {}, "free", 1e9, false, "rpc_tier_free")
check("paid with no quota", {}, "paid", nil, true, "rpc_tier_paid")
check("legacy high", {}, nil, 1e9, true, "legacy_quota")
check("legacy boundary", {}, nil, 1e6, false, "legacy_quota")
check("legacy custom threshold", { paid_quota_threshold = 2e6 }, nil, 1500000, false, "legacy_quota")
check("strict missing", { legacy_quota_fallback = false }, nil, 1e9, false, "missing_rpc_tier")
check("invalid explicit value", {}, "invalid", 1e9, false, "rpc_tier_free")
check("empty explicit value", {}, "", 1e9, false, "rpc_tier_free")
check("boolean explicit value", {}, true, 1e9, false, "rpc_tier_free")
check("anonymous variables", {}, "paid", 1e9, false, "unauthenticated", false)
check("invalid policy", { method_policy = "invalid" }, "paid", 1e9, false, "invalid_policy")
assert(not access.should_bypass({ method_policy = "free_only", bypass_networks = { "arc" } }, "arc-testnet"))
assert(access.should_bypass({ bypass_networks = { "arc" } }, "arc-testnet"))
assert(not access.should_bypass({ bypass_networks = { "arc" } }, nil))
print(string.format("%d access resolver checks passed", passed + 3))
