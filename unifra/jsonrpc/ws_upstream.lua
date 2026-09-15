-- The Lua WS client bypasses APISIX's normal proxy header/handshake handling.
local _M = {}

function _M.options(ctx, server, timeout)
    local upstream = ctx.upstream_conf or {}
    local scheme = ctx.upstream_scheme or upstream.scheme or "http"
    local secure = scheme == "https" or scheme == "grpcs"
    local mode = upstream.pass_host or ctx.pass_host or "pass"
    local host
    if mode == "node" then
        host = server.upstream_host
        if not host then
            host = server.domain or server.host
            if host:find(":", 1, true) and host:sub(1, 1) ~= "[" then
                host = "[" .. host .. "]"
            end
            if tonumber(server.port) ~= (secure and 443 or 80) then
                host = host .. ":" .. server.port
            end
        end
    elseif mode == "rewrite" then
        host = upstream.upstream_host or ctx.upstream_host
    else
        -- Includes proxy-rewrite.host if that plugin already set the variable.
        host = ctx.var.upstream_host or ctx.var.http_host or ctx.var.host
    end
    if not host or host == "" or host:find("[\r\n]") then
        return nil, "invalid upstream Host"
    end

    local opts = {timeout = timeout, host = host}
    if secure then
        opts.ssl_verify = true
        -- SNI contains only the hostname, without brackets or port.
        opts.server_name = host:match("^%[([^%]]+)%]") or host:match("^([^:]+)")
    end
    return opts
end

local function has_token(value, expected)
    for token in (value or ""):lower():gmatch("[^,]+") do
        if token:match("^%s*(.-)%s*$") == expected then return true end
    end
    return false
end

function _M.validate_handshake(response, expected_accept)
    if type(response) ~= "string" then return nil, "missing upstream handshake" end
    local status = response:match("^HTTP/1%.1%s+(%d%d%d)%s")
    if status ~= "101" then
        return nil, "upstream handshake returned HTTP " .. (status or "invalid status")
    end
    local headers = {}
    for line in response:gmatch("[^\r\n]+") do
        local name, value = line:match("^([^:%s]+):%s*(.-)%s*$")
        if name then
            name = name:lower()
            headers[name] = headers[name] and (headers[name] .. "," .. value) or value
        end
    end
    if not has_token(headers.upgrade, "websocket")
        or not has_token(headers.connection, "upgrade") then
        return nil, "invalid upstream Upgrade/Connection headers"
    end
    if not expected_accept or headers["sec-websocket-accept"] ~= expected_accept then
        return nil, "invalid upstream Sec-WebSocket-Accept"
    end
    return true
end

function _M.connect(client, url, opts)
    local random = require("resty.random")
    local nonce, err = random.bytes(16, true)
    if not nonce then return nil, "failed to generate WebSocket key: " .. (err or "unknown") end
    opts.key = ngx.encode_base64(nonce)
    local expected_accept = ngx.encode_base64(ngx.sha1_bin(
        opts.key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    local ok, connect_err, response = client:connect(url, opts)
    if ok then
        ok, connect_err = _M.validate_handshake(response, expected_accept)
    end
    if not ok then
        -- No WS close frame may be sent to an HTTP rejection response.
        if client.sock then client.sock:close() end
        return nil, connect_err
    end
    return true
end

return _M
