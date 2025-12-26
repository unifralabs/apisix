--
-- Unifra Control Plane Client Module
--
-- Mock implementation for control plane integration.
-- In production, this would communicate with the control plane API
-- to fetch dynamic quota updates, billing cycle information, etc.
--
-- For now, this serves as a placeholder that reads from consumer config.
--

local core = require("apisix.core")
local http = require("resty.http")

local _M = {
    version = "1.0.0"
}

-- Mock control plane configuration
local CP_CONFIG = {
    enabled = false,  -- Set to true when control plane is available
    base_url = os.getenv("CP_BASE_URL") or "http://control-plane:8080",
    api_key = os.getenv("CP_API_KEY") or "",
    timeout = 5000,  -- 5 seconds
}


--- Get billing cycle information from control plane
-- @param consumer_name string Consumer name
-- @return string|nil cycle_id Cycle ID
-- @return number|nil cycle_end_at Cycle end timestamp
-- @return string|nil error Error message
function _M.get_billing_cycle(consumer_name)
    if not CP_CONFIG.enabled then
        -- Mock response: return nil to fall back to consumer config
        return nil, nil, "control plane not enabled"
    end

    -- In production, this would make an HTTP request like:
    -- GET /api/v1/consumers/{consumer_name}/billing-cycle

    local httpc = http.new()
    httpc:set_timeout(CP_CONFIG.timeout)

    local url = CP_CONFIG.base_url .. "/api/v1/consumers/" .. consumer_name .. "/billing-cycle"
    local res, err = httpc:request_uri(url, {
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. CP_CONFIG.api_key,
            ["Content-Type"] = "application/json",
        },
    })

    if err then
        return nil, nil, "control plane request failed: " .. err
    end

    if res.status ~= 200 then
        return nil, nil, "control plane returned status " .. res.status
    end

    -- Parse response
    local data = core.json.decode(res.body)
    if not data then
        return nil, nil, "failed to parse control plane response"
    end

    return data.cycle_id, data.cycle_end_at, nil
end


--- Get consumer quota limits from control plane
-- @param consumer_name string Consumer name
-- @return number|nil seconds_quota Per-second quota
-- @return number|nil monthly_quota Monthly quota
-- @return string|nil error Error message
function _M.get_consumer_quota(consumer_name)
    if not CP_CONFIG.enabled then
        return nil, nil, "control plane not enabled"
    end

    -- Mock implementation
    -- In production: GET /api/v1/consumers/{consumer_name}/quota

    return nil, nil, "not implemented"
end


--- Report usage to control plane
-- @param consumer_name string Consumer name
-- @param cu number CU consumed
-- @param timestamp number Timestamp
-- @return boolean|nil success
-- @return string|nil error Error message
function _M.report_usage(consumer_name, cu, timestamp)
    if not CP_CONFIG.enabled then
        return true, nil  -- No-op if disabled
    end

    -- In production: POST /api/v1/usage
    -- Body: {consumer: "...", cu: 123, timestamp: 1234567890}

    return true, nil
end


--- Configure control plane client
-- @param config table Configuration overrides
function _M.configure(config)
    for k, v in pairs(config) do
        if CP_CONFIG[k] ~= nil then
            CP_CONFIG[k] = v
        end
    end
end


--- Get current configuration
-- @return table Current configuration
function _M.get_config()
    return core.table.clone(CP_CONFIG)
end


return _M
