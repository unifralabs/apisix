package.path = "?.lua;../?.lua;" .. package.path
local ws = require("unifra.jsonrpc.ws_upstream")

describe("WebSocket upstream Host and handshake", function()
    local ctx, server
    before_each(function()
        ctx = {upstream_scheme = "https", upstream_conf = {pass_host = "node"},
               var = {upstream_host = "arc-mainnet.unifra.io"}}
        server = {host = "192.0.2.1", port = 443, domain = "lb.drpc.live",
                  upstream_host = "lb.drpc.live"}
    end)

    it("uses domain Host and SNI while leaving selected IP unchanged", function()
        local opts = assert(ws.options(ctx, server, 70000))
        assert.equals("lb.drpc.live", opts.host)
        assert.equals("lb.drpc.live", opts.server_name)
        assert.is_true(opts.ssl_verify)
        assert.equals("192.0.2.1", server.host)
    end)

    it("keeps nonstandard port in Host but not SNI", function()
        server.port, server.upstream_host = 8443, "lb.drpc.live:8443"
        local opts = assert(ws.options(ctx, server, 70000))
        assert.equals("lb.drpc.live:8443", opts.host)
        assert.equals("lb.drpc.live", opts.server_name)
    end)

    it("supports rewrite Host", function()
        ctx.upstream_conf = {pass_host = "rewrite", upstream_host = "provider.example:443"}
        local opts = assert(ws.options(ctx, server, 70000))
        assert.equals("provider.example:443", opts.host)
        assert.equals("provider.example", opts.server_name)
    end)

    it("supports pass including a proxy-rewrite host", function()
        ctx.upstream_conf.pass_host = "pass"
        assert.equals("arc-mainnet.unifra.io", ws.options(ctx, server, 1).host)
        ctx.var.upstream_host = "rewritten.example"
        assert.equals("rewritten.example", ws.options(ctx, server, 1).host)
    end)

    it("keeps local plaintext WS working", function()
        ctx.upstream_scheme = "http"
        server = {host = "10.148.0.8", port = 8545}
        local opts = assert(ws.options(ctx, server, 70000))
        assert.equals("10.148.0.8:8545", opts.host)
        assert.is_nil(opts.ssl_verify)
        assert.is_nil(opts.server_name)
    end)

    it("handles bracketed IPv6 Host without putting its port in SNI", function()
        server = {host = "[2001:db8::1]", port = 8443}
        local opts = assert(ws.options(ctx, server, 1))
        assert.equals("[2001:db8::1]:8443", opts.host)
        assert.equals("2001:db8::1", opts.server_name)
    end)

    local accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    local valid = "HTTP/1.1 101 Switching Protocols\r\n"
        .. "Upgrade: WebSocket\r\nConnection: keep-alive, Upgrade\r\n"
        .. "Sec-WebSocket-Accept: " .. accept .. "\r\n\r\n"

    it("accepts a valid upgrade and challenge", function()
        assert.is_true(ws.validate_handshake(valid, accept))
    end)

    for _, status in ipairs({200, 301, 401, 403, 404, 500}) do
        it("rejects HTTP " .. status .. " before accepting the client", function()
            local ok, err = ws.validate_handshake("HTTP/1.1 " .. status .. " Error\r\n\r\n", accept)
            assert.is_nil(ok)
            assert.equals("upstream handshake returned HTTP " .. status, err)
        end)
    end

    it("rejects missing or malformed response", function()
        assert.is_nil(ws.validate_handshake(nil, accept))
        assert.is_nil(ws.validate_handshake("connection reused", accept))
    end)

    it("rejects invalid upgrade headers and challenge", function()
        assert.is_nil(ws.validate_handshake(valid:gsub("WebSocket\r", "http\r"), accept))
        assert.is_nil(ws.validate_handshake(valid:gsub("keep%-alive, Upgrade", "keep-alive"), accept))
        assert.is_nil(ws.validate_handshake(valid, "wrong"))
    end)
end)
