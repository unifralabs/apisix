-- Run with resty -I <repo> tests/integration/test_ws_upstream.lua.
-- Exercises the installed lua-resty-websocket without external services.
local upstream = require("unifra.jsonrpc.ws_upstream")
local original_tcp = ngx.socket.tcp
local sockets = {}
local response_mode = "valid"
local function check(value, message) assert(value, message) end

ngx.socket.tcp = function()
    local sock = {}
    sockets[#sockets + 1] = sock
    function sock:settimeout(timeout) self.timeout = timeout end
    function sock:connect(host, port) self.host, self.port = host, port; return true end
    function sock:getreusedtimes() return 0 end
    function sock:sslhandshake(_, sni, verify)
        self.sni, self.verify = sni, verify
        return true
    end
    function sock:send(data) self.request = data; return #data end
    function sock:close() self.closed = true; return true end
    function sock:receiveuntil()
        return function()
            local host = self.request:match("\r\nHost: ([^\r]+)")
            if host ~= "lb.drpc.live" or response_mode == "404" then
                return "HTTP/1.1 404 Not Found\r\nContent-Length: 0"
            end
            local key = self.request:match("Sec%-WebSocket%-Key: ([^\r]+)")
            local accept = ngx.encode_base64(ngx.sha1_bin(
                key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
            if response_mode == "bad-accept" then accept = "wrong" end
            return "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                .. "Connection: Upgrade\r\nSec-WebSocket-Accept: " .. accept
        end
    end
    return sock
end

local client = require("resty.websocket.client")
local ctx = {upstream_scheme = "https", upstream_conf = {pass_host = "node"},
             var = {upstream_host = "arc-mainnet.unifra.io"}}
local server = {host = "192.0.2.1", domain = "lb.drpc.live", port = 443,
                upstream_host = "lb.drpc.live"}
local url = "wss://192.0.2.1:443/arc/fake-test-key"

-- Prove the original bug with the actual installed WebSocket library.
local old = assert(client:new())
local old_ok, _, old_response = old:connect(url, {server_name = server.domain, ssl_verify = true})
check(old_ok and old_response:find("404", 1, true), "old client must accept the HTTP 404")
check(sockets[#sockets].request:find("Host: 192.0.2.1:443", 1, true), "old Host must be IP")
old.sock:close()

for _, mode in ipairs({"valid", "404", "bad-accept"}) do
    response_mode = mode
    local wc = assert(client:new())
    local opts = assert(upstream.options(ctx, server, 1000))
    local ok, err = upstream.connect(wc, url, opts)
    local sock = sockets[#sockets]
    check(sock.host == "192.0.2.1", "must preserve the selected IP")
    check(sock.sni == "lb.drpc.live" and sock.verify, "must retain verified TLS with domain SNI")
    check(sock.request:find("Host: lb.drpc.live\r\n", 1, true), "must use domain Host")
    check(sock.request:find("GET /arc/fake-test-key HTTP/1.1", 1, true), "must preserve URI")
    if mode == "valid" then
        check(ok and not sock.closed, err or "valid handshake failed")
        wc.sock:close()
    else
        check(not ok and sock.closed, "failed handshake must close raw socket")
    end
end

print("PASS: real lua-resty-websocket ", client._VERSION,
      " reproduces old IP Host/404 bug; fixed Host/SNI/path succeed; 404 and bad accept rejected.")

-- Drive the actual plugin access handler up to client acceptance. Unrelated
-- billing/metadata dependencies are stubbed; the WS client and new helper are real.
local noop = function() end
for _, name in ipairs({"unifra.jsonrpc.whitelist", "unifra.jsonrpc.access",
    "unifra.jsonrpc.rpc_policy", "unifra.jsonrpc.rpc_resources", "unifra.jsonrpc.cu",
    "unifra.jsonrpc.redis_scripts", "unifra.jsonrpc.redis_circuit_breaker",
    "unifra.jsonrpc.billing", "unifra.jsonrpc.errors", "unifra.metrics",
    "apisix.utils.batch-processor", "resty.kafka.producer"}) do
    package.loaded[name] = {}
end
package.loaded["apisix.core"] = {schema = {check = function() return true end},
    log = {info = noop, error = noop, warn = noop, debug = noop}}
package.loaded["apisix.balancer"] = {pick_server = function() return server end}
package.loaded["apisix.plugin"] = {plugin_metadata = function() return {value = {}} end}
package.loaded["apisix.upstream"] = {
    get_by_id = function() return ctx.upstream_conf end,
    set_by_route = function() end,
}
package.loaded["unifra.jsonrpc.core"] = {extract_network = function() return "arc-mainnet" end}
package.loaded["unifra.jsonrpc.access"] = {schema_properties = {}, is_paid = function() return true end}
package.loaded["unifra.jsonrpc.whitelist"].load_config = function() return {} end
package.loaded["unifra.jsonrpc.rpc_policy"].resolve = function() return {} end
package.loaded["unifra.jsonrpc.rpc_resources"].ws_open = function() return true end
package.loaded["unifra.jsonrpc.telemetry"] = {snapshot = function() return {} end}
local accepted = false
package.loaded["resty.websocket.server"] = {new = function()
    accepted = true
    error("TEST_CLIENT_ACCEPTED", 0) -- Stop before the bidirectional proxy loop.
end}
ctx.matched_route = {value = {upstream_id = "663"}}
ctx.var.request_method = "GET"
ctx.var.http_upgrade = "websocket"
ctx.var.http_connection = "Upgrade"
ctx.var.http_sec_websocket_version = "13"
ctx.var.http_sec_websocket_key = "dGhlIHNhbXBsZSBub25jZQ=="
ctx.var.upstream_uri = "/arc/fake-test-key"
local plugin = require("apisix.plugins.unifra-ws-jsonrpc-proxy")
for _, mode in ipairs({"404", "bad-accept", "valid"}) do
    response_mode, accepted = mode, false
    local ok, result = pcall(plugin.access, {ws_timeout = 1000}, ctx)
    if mode == "valid" then
        check(not ok and result == "TEST_CLIENT_ACCEPTED" and accepted,
              "plugin must accept client after verified upgrade: " .. tostring(result))
        sockets[#sockets]:close()
    else
        check(ok and result == 502 and not accepted and sockets[#sockets].closed,
              "plugin must reject invalid upstream before accepting client: " .. tostring(result))
    end
end
ngx.socket.tcp = original_tcp
print("PASS: actual plugin access handler returns 502 before client upgrade on rejection; accepts valid upgrade.")
