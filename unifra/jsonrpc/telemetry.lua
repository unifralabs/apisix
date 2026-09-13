-- Log dimensions only. Never infer permissions, prices or billing ownership.
local _M = {}

function _M.snapshot(ctx, network, transport, event_kind)
    local var = ctx.var or {}
    return {
        schema_version = 2,
        -- Use the configured parser/proxy network, not an entry name or a
        -- client-supplied Host/header. Missing configuration stays visible.
        network = network or "",
        route_name = var.route_name or "",
        transport = transport,
        event_kind = event_kind,
    }
end

function _M.http(ctx, network)
    local dimensions = _M.snapshot(ctx, network, "http",
        ctx.var.request_method == "POST" and "rpc_request" or "diagnostic")
    -- Namespaced variables for kafka-logger metadata. Do not change the
    -- existing unifra_network used by pricing/access control.
    for name, value in pairs(dimensions) do
        ctx.var["unifra_log_" .. name] = value
    end
end

function _M.apply(entry, snapshot, event_kind)
    for name, value in pairs(snapshot) do
        entry[name] = value
    end
    entry.event_kind = event_kind or snapshot.event_kind
    return entry
end

return _M
