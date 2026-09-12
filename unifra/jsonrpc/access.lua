-- Shared method entitlement resolution for HTTP and WebSocket requests.
local _M = {}

-- These fields are shared by both plugin schemas. Legacy fallback is enabled
-- during Consumer migration only; public endpoints always use free_only.
_M.schema_properties = {
    method_policy = {
        type = "string",
        enum = { "free_only", "consumer" },
        default = "consumer",
        description = "free_only caps endpoint permissions; consumer uses rpc_tier"
    },
    legacy_quota_fallback = {
        type = "boolean",
        default = true,
        description = "Use monthly quota only when an authenticated Consumer has no rpc_tier"
    },
    paid_quota_threshold = {
        type = "integer",
        default = 1000000,
        description = "Legacy monthly quota threshold; ignored with explicit rpc_tier or free_only"
    },
}

function _M.is_paid(conf, ctx)
    local policy = conf.method_policy or "consumer"
    if policy ~= "consumer" then
        return false, policy == "free_only" and "free_only" or "invalid_policy"
    end

    -- Read entitlements from the authenticated Consumer itself, never request
    -- headers, query parameters or route-injected context variables.
    local consumer = ctx.consumer
    if not consumer then
        return false, "unauthenticated"
    end
    local vars = consumer.plugins and consumer.plugins["unifra-ctx-var"] or {}
    local tier = vars.rpc_tier
    if tier ~= nil then
        -- Invalid/empty explicit values must not fall back to a high quota.
        return tier == "paid", tier == "paid" and "rpc_tier_paid" or "rpc_tier_free"
    end

    if conf.legacy_quota_fallback == false then
        return false, "missing_rpc_tier"
    end

    local quota = tonumber(ctx.var.monthly_quota) or 0
    return quota > (conf.paid_quota_threshold or 1000000), "legacy_quota"
end

function _M.should_bypass(conf, network)
    -- A public endpoint's permission cap takes precedence over every bypass.
    if (conf.method_policy or "consumer") ~= "consumer" or not network then
        return false
    end
    for _, pattern in ipairs(conf.bypass_networks or {}) do
        if network:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

return _M
