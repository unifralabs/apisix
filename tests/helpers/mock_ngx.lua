--
-- Mock ngx object for unit testing outside OpenResty
-- Provides essential ngx.* functions used by Unifra modules
--

local cjson = require("cjson.safe")

local _M = {}

-- Mock apisix.core module
local mock_core = {
    version = "mock",

    log = {
        error = function(...) _M.log(_M.ERR, ...) end,
        warn = function(...) _M.log(_M.WARN, ...) end,
        info = function(...) _M.log(_M.INFO, ...) end,
        debug = function(...) _M.log(_M.DEBUG, ...) end,
        notice = function(...) _M.log(_M.NOTICE, ...) end,
    },

    response = {
        _headers = {},
        set_header = function(name, value)
            mock_core.response._headers[name] = value
        end,
        get_headers = function()
            return mock_core.response._headers
        end,
        reset = function()
            mock_core.response._headers = {}
        end
    },

    json = {
        encode = function(data)
            return cjson.encode(data)
        end,
        decode = function(str)
            return cjson.decode(str)
        end
    },

    table = {
        new = function(narr, nrec)
            return {}
        end,
        clear = function(t)
            for k in pairs(t) do
                t[k] = nil
            end
        end
    },

    string = {
        has_prefix = function(s, prefix)
            return s:sub(1, #prefix) == prefix
        end,
        has_suffix = function(s, suffix)
            return suffix == "" or s:sub(-#suffix) == suffix
        end
    },

    config = {
        local_conf = function()
            return {}
        end
    }
}

-- Install apisix.core mock
function _M.install_apisix_core()
    package.loaded["apisix.core"] = mock_core
end

-- Log levels
_M.DEBUG = 8
_M.INFO = 7
_M.NOTICE = 6
_M.WARN = 5
_M.ERR = 4
_M.CRIT = 3
_M.ALERT = 2
_M.EMERG = 1

-- HTTP status codes
_M.HTTP_OK = 200
_M.HTTP_BAD_REQUEST = 400
_M.HTTP_UNAUTHORIZED = 401
_M.HTTP_FORBIDDEN = 403
_M.HTTP_NOT_FOUND = 404
_M.HTTP_TOO_MANY_REQUESTS = 429
_M.HTTP_INTERNAL_SERVER_ERROR = 500
_M.HTTP_BAD_GATEWAY = 502
_M.HTTP_SERVICE_UNAVAILABLE = 503

-- Captured logs for assertions
_M._logs = {}

-- Mock log function
function _M.log(level, ...)
    local args = {...}
    local msg = table.concat(args, "")
    table.insert(_M._logs, {level = level, message = msg})
end

-- Mock time functions
local mock_time = os.time()
function _M.now()
    return mock_time + (os.clock() % 1)
end

function _M.time()
    return mock_time
end

function _M.set_mock_time(t)
    mock_time = t
end

-- Mock request/response
_M.var = {}
_M.ctx = {}

_M.req = {
    _body = nil,
    _headers = {},

    get_body_data = function()
        return _M.req._body
    end,

    get_headers = function()
        return _M.req._headers
    end,

    set_body = function(body)
        _M.req._body = body
    end,

    set_headers = function(headers)
        _M.req._headers = headers
    end
}

_M._response_body = nil
_M._exit_status = nil

function _M.say(body)
    _M._response_body = body
end

function _M.exit(status)
    _M._exit_status = status
end

-- MD5 function
function _M.md5(str)
    -- Simple mock - in real tests use a proper md5 library
    local hash = 0
    for i = 1, #str do
        hash = (hash * 31 + string.byte(str, i)) % 2^32
    end
    return string.format("%08x%08x%08x%08x", hash, hash, hash, hash)
end

-- Reset all mocks
function _M.reset()
    _M._logs = {}
    _M.var = {}
    _M.ctx = {}
    _M.req._body = nil
    _M.req._headers = {}
    _M._response_body = nil
    _M._exit_status = nil
    mock_core.response._headers = {}
end

-- Get logs at specific level
function _M.get_logs(level)
    local result = {}
    for _, log in ipairs(_M._logs) do
        if not level or log.level == level then
            table.insert(result, log.message)
        end
    end
    return result
end

-- Install as global ngx
function _M.install()
    _G.ngx = _M
    _M.install_apisix_core()
end

-- Uninstall global ngx
function _M.uninstall()
    _G.ngx = nil
    package.loaded["apisix.core"] = nil
end

-- Reset apisix.core mock state
function _M.reset_core()
    mock_core.response._headers = {}
end

return _M
