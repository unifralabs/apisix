package.path = "/opt/unifra-apisix/?.lua;" .. package.path
local telemetry = require("unifra.jsonrpc.telemetry")
local ctx = {var = {route_name = "arc-testnet-public", host = "spoof.invalid",
                    request_method = "POST", unifra_network = "unchanged"}}
telemetry.http(ctx, "arc-testnet")
assert(ctx.var.unifra_log_network == "arc-testnet")
assert(ctx.var.unifra_log_route_name == "arc-testnet-public")
assert(ctx.var.unifra_log_transport == "http")
assert(ctx.var.unifra_log_event_kind == "rpc_request")
assert(ctx.var.unifra_log_schema_version == 2)
assert(ctx.var.unifra_network == "unchanged")
ctx.var.request_method = "GET"
ctx.var.http_upgrade = "websocket"
telemetry.http(ctx, nil)
assert(ctx.var.unifra_log_network == "") -- never guess from Host
assert(ctx.var.unifra_log_transport == "http") -- handshake is not a message
assert(ctx.var.unifra_log_event_kind == "diagnostic")
ctx.var.route_name = "support-options"
ctx.var.request_method = "OPTIONS"
telemetry.http(ctx, "")
assert(ctx.var.unifra_log_network == "") -- preflight has no blockchain network
assert(ctx.var.unifra_log_route_name == "support-options")
assert(ctx.var.unifra_log_transport == "http")
assert(ctx.var.unifra_log_event_kind == "diagnostic")
assert(ctx.var.unifra_log_schema_version == 2)
local snapshot = telemetry.snapshot(ctx, "arc-testnet", "ws", "rpc_request")
local entry = telemetry.apply({cu_cost = 5, user_id = "owner"}, snapshot, "subscription_push")
assert(entry.transport == "ws" and entry.event_kind == "subscription_push")
assert(entry.cu_cost == 5 and entry.user_id == "owner")
assert(snapshot.event_kind == "rpc_request") -- per-message classification cannot leak
assert(telemetry.apply({}, snapshot).event_kind == "rpc_request")
assert(telemetry.apply({}, snapshot, "diagnostic").event_kind == "diagnostic")
print("PASS telemetry dimensions, no host inference, handshake, ownership and immutable WS snapshot")
