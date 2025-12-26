--
-- Unifra JSON-RPC Core Module
-- Provides JSON-RPC parsing, validation, and error response generation
--
-- This module is the foundation for all JSON-RPC processing in Unifra gateway.
-- It supports both single requests and batch requests per JSON-RPC 2.0 spec.
--

local cjson = require("cjson.safe")
local feature_flags = require("unifra.feature_flags")

local _M = {
    version = "1.0.0"
}

-- cjson.null for proper null handling in JSON
local cjson_null = cjson.null

-- JSON-RPC 2.0 Standard Error Codes
_M.ERROR_PARSE = -32700           -- Invalid JSON was received
_M.ERROR_INVALID_REQUEST = -32600 -- The JSON sent is not a valid Request
_M.ERROR_METHOD_NOT_FOUND = -32601 -- The method does not exist
_M.ERROR_INVALID_PARAMS = -32602  -- Invalid method parameters
_M.ERROR_INTERNAL = -32603        -- Internal JSON-RPC error

-- Custom Error Codes (Application-specific)
_M.ERROR_RATE_LIMITED = -32000    -- Rate limit exceeded
_M.ERROR_QUOTA_EXCEEDED = -32001  -- Monthly quota exceeded
_M.ERROR_UNAUTHORIZED = -32002    -- Authentication required
_M.ERROR_FORBIDDEN = -32003       -- Method not allowed for user tier

-- Maximum request body size (1 MiB)
local MAX_BODY_SIZE = 1048576

-- Maximum batch size
local MAX_BATCH_SIZE = 100


--- Check if a table is an array (JSON array)
-- For JSON-RPC, we treat empty tables as arrays (batch with zero requests)
-- since [] is the more common error case than {}
-- @param t table to check
-- @return boolean true if array, false otherwise
local function is_array(t)
    if type(t) ~= "table" then
        return false
    end
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then
            return false
        end
    end
    -- Empty table is treated as empty array for JSON-RPC
    -- This ensures "[]" returns "empty batch" error
    return true
end


--- Parse JSON-RPC request body
-- Supports both single requests and batch requests per JSON-RPC 2.0 spec.
-- @param body string The raw request body
-- @param allow_partial boolean Allow partial batch parsing (optional, default: false)
-- @return table|nil Parsed result with fields: method, methods, is_batch, count, raw, errors
-- @return string|nil Error message if parsing failed
function _M.parse(body, allow_partial)
    if not body or body == "" then
        return nil, "empty body"
    end

    if #body > MAX_BODY_SIZE then
        return nil, "body too large"
    end

    local decoded, err = cjson.decode(body)
    if not decoded then
        return nil, "parse error: " .. (err or "invalid json")
    end

    -- Handle batch request (JSON array)
    if is_array(decoded) then
        if #decoded == 0 then
            return nil, "empty batch"
        end

        if #decoded > MAX_BATCH_SIZE then
            return nil, "batch too large, max " .. MAX_BATCH_SIZE .. " requests"
        end

        local methods = {}
        local ids = {}
        local errors = {}  -- Track errors for each index

        for i, req in ipairs(decoded) do
            local req_err = nil

            -- Validate request structure
            if type(req) ~= "table" then
                req_err = "not an object"
            elseif not req.method or type(req.method) ~= "string" then
                req_err = "missing or invalid method"
            elseif req.method == "" then
                req_err = "empty method name"
            end

            if req_err then
                if allow_partial then
                    -- In partial mode, record error and continue
                    methods[#methods + 1] = nil
                    -- Safe ID extraction (req may not be a table)
                    local safe_id = cjson_null
                    if type(req) == "table" and req.id ~= nil then
                        safe_id = req.id
                    end
                    ids[#ids + 1] = safe_id
                    errors[i] = req_err
                else
                    -- Strict mode: fail entire batch
                    return nil, "invalid request at index " .. i .. ": " .. req_err
                end
            else
                -- Valid request
                methods[#methods + 1] = req.method
                ids[#ids + 1] = req.id
                errors[i] = nil
            end
        end

        return {
            method = "batch",
            methods = methods,
            ids = ids,
            is_batch = true,
            count = #decoded,
            raw = decoded,
            errors = errors,  -- May contain per-request errors in partial mode
        }, nil
    end

    -- Handle single request (JSON object)
    if type(decoded) ~= "table" then
        return nil, "invalid request: expected object or array"
    end

    if not decoded.method then
        return nil, "missing method field"
    end

    if type(decoded.method) ~= "string" then
        return nil, "invalid method: expected string"
    end

    if decoded.method == "" then
        return nil, "empty method name"
    end

    return {
        method = decoded.method,
        methods = { decoded.method },
        ids = { decoded.id },
        is_batch = false,
        count = 1,
        raw = decoded
    }, nil
end


--- Generate JSON-RPC error response string
-- @param code number Error code (use _M.ERROR_* constants)
-- @param message string Error message
-- @param id any Request ID (optional, can be nil for parse errors)
-- @return string JSON-encoded error response
function _M.error_response(code, message, id)
    -- Properly handle nil id: JSON-RPC spec requires id:null not id omitted
    -- Use cjson.null when id is nil to encode as "id":null instead of omitting field
    if id == nil then
        id = cjson_null
    end

    return cjson.encode({
        jsonrpc = "2.0",
        id = id,
        error = {
            code = code,
            message = message
        }
    })
end


--- Generate JSON-RPC error response as table
-- Useful when you need to include the error in a batch response
-- @param code number Error code
-- @param message string Error message
-- @param id any Request ID (optional)
-- @return table Error response table
function _M.error_table(code, message, id)
    -- Properly handle nil id
    if id == nil then
        id = cjson_null
    end

    return {
        jsonrpc = "2.0",
        id = id,
        error = {
            code = code,
            message = message
        }
    }
end


--- Generate batch error response for all requests
-- @param code number Error code
-- @param message string Error message
-- @param ids table Array of request IDs
-- @return string JSON-encoded array of error responses
function _M.batch_error_response(code, message, ids)
    local responses = {}
    for _, id in ipairs(ids or {}) do
        responses[#responses + 1] = _M.error_table(code, message, id)
    end
    return cjson.encode(responses)
end


--- Extract network name from host header
-- Supports format: {network}.unifra.io or {network}.{domain}
-- @param host string The Host header value
-- @return string|nil Network name or nil if not matched
function _M.extract_network(host)
    if not host then
        return nil
    end

    -- Try unifra.io format first
    local network = host:match("^([^.]+)%.unifra%.io$")
    if network then
        return network
    end

    -- Try generic format (first segment before first dot)
    network = host:match("^([^.]+)%.")
    return network
end


--- Check if a method name matches a pattern
-- Supports exact match and wildcard suffix (e.g., "eth_*")
-- @param method string Method name to check
-- @param pattern string Pattern to match against
-- @return boolean true if matches
function _M.match_method(method, pattern)
    if pattern == method then
        return true
    end

    -- Handle wildcard suffix pattern like "eth_*"
    if pattern:sub(-1) == "*" then
        local prefix = pattern:sub(1, -2)
        return method:sub(1, #prefix) == prefix
    end

    return false
end


--- Check if a method is in a list of patterns
-- @param method string Method name to check
-- @param patterns table Array of patterns
-- @return boolean true if method matches any pattern
function _M.method_in_list(method, patterns)
    if not patterns then
        return false
    end

    for _, pattern in ipairs(patterns) do
        if _M.match_method(method, pattern) then
            return true
        end
    end

    return false
end


return _M
