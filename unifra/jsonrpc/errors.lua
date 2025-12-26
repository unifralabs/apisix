--
-- Unifra Unified Error Handling Module
--
-- Provides consistent error handling and HTTP status code mapping.
-- Distinguishes between gateway-level errors (HTTP status codes) and
-- JSON-RPC business logic errors (always HTTP 200).
--
-- Design principle:
-- - Gateway errors (auth, rate limit, quota): Use proper HTTP status codes
-- - JSON-RPC errors (method not found, invalid params): HTTP 200 + JSON-RPC error
--

local core = require("apisix.core")
local jsonrpc_core = require("unifra.jsonrpc.core")
local feature_flags = require("unifra.feature_flags")

local _M = {
    version = "1.0.0"
}

-- Error categories
_M.CATEGORY_GATEWAY = "gateway"       -- Infrastructure/gateway errors
_M.CATEGORY_BUSINESS = "business"     -- JSON-RPC business logic errors

-- Gateway error types (use HTTP status codes)
_M.ERR_UNAUTHORIZED = {
    code = jsonrpc_core.ERROR_UNAUTHORIZED,
    http_status = 401,
    message = "Unauthorized",
    category = _M.CATEGORY_GATEWAY,
}

_M.ERR_FORBIDDEN = {
    code = jsonrpc_core.ERROR_FORBIDDEN,
    http_status = 403,
    message = "Forbidden",
    category = _M.CATEGORY_GATEWAY,
}

_M.ERR_METHOD_NOT_ALLOWED = {
    code = jsonrpc_core.ERROR_FORBIDDEN,
    http_status = 405,
    message = "Method not allowed",
    category = _M.CATEGORY_GATEWAY,
}

_M.ERR_RATE_LIMITED = {
    code = jsonrpc_core.ERROR_RATE_LIMITED,
    http_status = 429,
    message = "Rate limit exceeded",
    category = _M.CATEGORY_GATEWAY,
}

_M.ERR_QUOTA_EXCEEDED = {
    code = jsonrpc_core.ERROR_QUOTA_EXCEEDED,
    http_status = 429,
    message = "Monthly quota exceeded",
    category = _M.CATEGORY_GATEWAY,
}

_M.ERR_BAD_REQUEST = {
    code = jsonrpc_core.ERROR_INVALID_REQUEST,
    http_status = 400,
    message = "Bad request",
    category = _M.CATEGORY_GATEWAY,
}

_M.ERR_INTERNAL = {
    code = jsonrpc_core.ERROR_INTERNAL,
    http_status = 500,
    message = "Internal server error",
    category = _M.CATEGORY_GATEWAY,
}

-- JSON-RPC error types (always HTTP 200)
_M.ERR_PARSE_ERROR = {
    code = jsonrpc_core.ERROR_PARSE,
    http_status = 200,
    message = "Parse error",
    category = _M.CATEGORY_BUSINESS,
}

_M.ERR_INVALID_REQUEST = {
    code = jsonrpc_core.ERROR_INVALID_REQUEST,
    http_status = 200,
    message = "Invalid request",
    category = _M.CATEGORY_BUSINESS,
}

_M.ERR_METHOD_NOT_FOUND = {
    code = jsonrpc_core.ERROR_METHOD_NOT_FOUND,
    http_status = 200,
    message = "Method not found",
    category = _M.CATEGORY_BUSINESS,
}

_M.ERR_INVALID_PARAMS = {
    code = jsonrpc_core.ERROR_INVALID_PARAMS,
    http_status = 200,
    message = "Invalid params",
    category = _M.CATEGORY_BUSINESS,
}


--- Create error response with proper HTTP status
-- @param ctx table Request context
-- @param error_type table Error type definition
-- @param custom_message string Custom error message (optional)
-- @param request_id any JSON-RPC request ID (optional)
-- @param headers table Additional headers (optional)
-- @return number HTTP status code
-- @return string Response body
function _M.response(ctx, error_type, custom_message, request_id, headers)
    local use_unified = feature_flags.is_enabled(ctx, "unified_error_handling")

    if not use_unified then
        -- Fallback to legacy behavior
        local message = custom_message or error_type.message
        return error_type.http_status, jsonrpc_core.error_response(
            error_type.code, message, request_id
        )
    end

    -- Unified error handling
    local message = custom_message or error_type.message
    local http_status = error_type.http_status
    local response_body

    -- Set Content-Type header
    core.response.set_header("Content-Type", "application/json")

    -- Set additional headers
    if headers then
        for k, v in pairs(headers) do
            core.response.set_header(k, v)
        end
    end

    -- Set X-Error-Code for debugging
    core.response.set_header("X-Error-Code", error_type.code)
    core.response.set_header("X-Error-Category", error_type.category)

    -- Generate response body
    if error_type.category == _M.CATEGORY_GATEWAY then
        -- Gateway error: HTTP status + JSON-RPC error
        response_body = jsonrpc_core.error_response(error_type.code, message, request_id)

    elseif error_type.category == _M.CATEGORY_BUSINESS then
        -- Business error: Always HTTP 200 + JSON-RPC error
        http_status = 200
        response_body = jsonrpc_core.error_response(error_type.code, message, request_id)
    end

    return http_status, response_body
end


--- Create batch error response
-- @param ctx table Request context
-- @param error_type table Error type definition
-- @param custom_message string Custom error message (optional)
-- @param request_ids table Array of JSON-RPC request IDs
-- @return number HTTP status code
-- @return string Response body (JSON array)
function _M.batch_response(ctx, error_type, custom_message, request_ids)
    local message = custom_message or error_type.message
    local http_status = error_type.http_status

    -- Set headers
    core.response.set_header("Content-Type", "application/json")
    core.response.set_header("X-Error-Code", error_type.code)
    core.response.set_header("X-Error-Category", error_type.category)

    -- Generate batch response
    local response_body = jsonrpc_core.batch_error_response(
        error_type.code, message, request_ids
    )

    -- Business errors always use HTTP 200
    if error_type.category == _M.CATEGORY_BUSINESS then
        http_status = 200
    end

    return http_status, response_body
end


--- Log error with context
-- @param ctx table Request context
-- @param error_type table Error type definition
-- @param custom_message string Custom error message (optional)
-- @param details table Additional details (optional)
function _M.log(ctx, error_type, custom_message, details)
    local message = custom_message or error_type.message
    local log_level = ngx.ERR

    -- Adjust log level based on error type
    if error_type.http_status == 429 then
        log_level = ngx.WARN  -- Rate limiting is expected
    elseif error_type.http_status >= 500 then
        log_level = ngx.ERR   -- Server errors are serious
    elseif error_type.http_status >= 400 then
        log_level = ngx.WARN  -- Client errors
    else
        log_level = ngx.INFO  -- Business logic errors
    end

    -- Build log message
    local log_msg = string.format(
        "[%s] code=%d, http=%d, message=%s",
        error_type.category,
        error_type.code,
        error_type.http_status,
        message
    )

    -- Add context
    if ctx then
        if ctx.var.consumer_name then
            log_msg = log_msg .. ", consumer=" .. ctx.var.consumer_name
        end
        if ctx.var.unifra_network then
            log_msg = log_msg .. ", network=" .. ctx.var.unifra_network
        end
        if ctx.var.remote_addr then
            log_msg = log_msg .. ", ip=" .. ctx.var.remote_addr
        end
    end

    -- Add details
    if details then
        local details_str = core.json.encode(details)
        log_msg = log_msg .. ", details=" .. details_str
    end

    -- Map log_level to core.log method (cannot use numeric index)
    if log_level == ngx.ERR then
        core.log.error(log_msg)
    elseif log_level == ngx.WARN then
        core.log.warn(log_msg)
    elseif log_level == ngx.INFO then
        core.log.info(log_msg)
    elseif log_level == ngx.DEBUG then
        core.log.debug(log_msg)
    else
        core.log.notice(log_msg)
    end
end


--- Check if error should fail-closed (reject request)
-- @param error_type table Error type definition
-- @return boolean true if should fail-closed
function _M.should_fail_closed(error_type)
    -- Gateway errors always fail-closed
    if error_type.category == _M.CATEGORY_GATEWAY then
        return true
    end

    -- Business errors depend on severity
    if error_type.code == jsonrpc_core.ERROR_INTERNAL then
        return true  -- Internal errors fail-closed
    end

    return false
end


--- Convert HTTP status to error type
-- For backward compatibility
-- @param http_status number HTTP status code
-- @return table Error type definition
function _M.from_http_status(http_status)
    if http_status == 401 then
        return _M.ERR_UNAUTHORIZED
    elseif http_status == 403 then
        return _M.ERR_FORBIDDEN
    elseif http_status == 405 then
        return _M.ERR_METHOD_NOT_ALLOWED
    elseif http_status == 429 then
        return _M.ERR_RATE_LIMITED
    elseif http_status == 400 then
        return _M.ERR_BAD_REQUEST
    elseif http_status >= 500 then
        return _M.ERR_INTERNAL
    else
        return _M.ERR_INTERNAL
    end
end


--- Convert JSON-RPC error code to error type
-- @param rpc_code number JSON-RPC error code
-- @return table Error type definition
function _M.from_rpc_code(rpc_code)
    if rpc_code == jsonrpc_core.ERROR_PARSE then
        return _M.ERR_PARSE_ERROR
    elseif rpc_code == jsonrpc_core.ERROR_INVALID_REQUEST then
        return _M.ERR_INVALID_REQUEST
    elseif rpc_code == jsonrpc_core.ERROR_METHOD_NOT_FOUND then
        return _M.ERR_METHOD_NOT_FOUND
    elseif rpc_code == jsonrpc_core.ERROR_INVALID_PARAMS then
        return _M.ERR_INVALID_PARAMS
    elseif rpc_code == jsonrpc_core.ERROR_RATE_LIMITED then
        return _M.ERR_RATE_LIMITED
    elseif rpc_code == jsonrpc_core.ERROR_QUOTA_EXCEEDED then
        return _M.ERR_QUOTA_EXCEEDED
    elseif rpc_code == jsonrpc_core.ERROR_UNAUTHORIZED then
        return _M.ERR_UNAUTHORIZED
    elseif rpc_code == jsonrpc_core.ERROR_FORBIDDEN then
        return _M.ERR_FORBIDDEN
    else
        return _M.ERR_INTERNAL
    end
end


return _M
