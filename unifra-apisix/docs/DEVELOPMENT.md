# Unifra APISIX - Development Guide

## Table of Contents

1. [Development Setup](#development-setup)
2. [Plugin Structure](#plugin-structure)
3. [Creating a New Plugin](#creating-a-new-plugin)
4. [Testing](#testing)
5. [Best Practices](#best-practices)
6. [API Reference](#api-reference)

---

## Development Setup

### Prerequisites

```bash
# Install OpenResty (for local testing)
brew install openresty  # macOS
# or
apt-get install openresty  # Ubuntu

# Install luarocks for dependency management
brew install luarocks  # macOS
# or
apt-get install luarocks  # Ubuntu

# Install test dependencies
luarocks install busted
luarocks install luacheck
```

### Local Development Environment

```bash
# Clone the repo
git clone https://github.com/unifra/apisix.git
cd apisix

# Start test environment
cd test-env
docker-compose up -d

# Start Anvil (local Ethereum node)
anvil --host 0.0.0.0 --port 8545 &

# Run tests
./test-all.sh
```

### IDE Setup

**VS Code with Lua extension:**

`.vscode/settings.json`:
```json
{
  "Lua.runtime.version": "LuaJIT",
  "Lua.diagnostics.globals": [
    "ngx",
    "rawget",
    "rawset",
    "setmetatable",
    "getmetatable"
  ],
  "Lua.workspace.library": [
    "/usr/local/openresty/lualib"
  ]
}
```

---

## Plugin Structure

### File Organization

```
unifra-apisix/
├── apisix/plugins/           # Plugin entry points
│   └── unifra-example.lua    # APISIX plugin format
├── unifra/                   # Business logic modules
│   └── example/
│       └── logic.lua         # Reusable logic
└── conf/                     # Configuration files
    └── example.json
```

### Plugin Anatomy

```lua
-- apisix/plugins/unifra-example.lua

local core = require("apisix.core")
local example_logic = require("unifra.example.logic")

local plugin_name = "unifra-example"

-- JSON Schema for plugin configuration
local schema = {
    type = "object",
    properties = {
        config_path = {
            type = "string",
            default = "/opt/unifra-apisix/conf/example.json"
        },
        enabled = {
            type = "boolean",
            default = true
        }
    },
}

local _M = {
    version = 0.1,
    priority = 1000,        -- Execution order (higher = earlier)
    name = plugin_name,
    schema = schema,
}

-- Validate configuration
function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- Rewrite phase (runs before access)
function _M.rewrite(conf, ctx)
    -- Modify request before processing
end

-- Access phase (main processing)
function _M.access(conf, ctx)
    -- Main plugin logic
    -- Return HTTP status to abort, or nil to continue
end

-- Header filter phase (modify response headers)
function _M.header_filter(conf, ctx)
    -- Modify response headers
end

-- Body filter phase (modify response body)
function _M.body_filter(conf, ctx)
    -- Modify response body
end

-- Log phase (after response sent)
function _M.log(conf, ctx)
    -- Logging, metrics, etc.
end

return _M
```

### Plugin Phases

```
Request arrives
      │
      ▼
┌─────────────┐
│   rewrite   │  ← Modify URI, headers before routing
└──────┬──────┘
       │
       ▼
┌─────────────┐
│   access    │  ← Main logic (auth, rate limit, etc.)
└──────┬──────┘
       │
       ▼
   [Upstream]
       │
       ▼
┌─────────────┐
│header_filter│  ← Modify response headers
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ body_filter │  ← Modify response body
└──────┬──────┘
       │
       ▼
┌─────────────┐
│     log     │  ← After response sent
└─────────────┘
```

---

## Creating a New Plugin

### Example: IP Geolocation Plugin

**Step 1: Create business logic module**

`unifra/geo/lookup.lua`:
```lua
local _M = {
    version = "1.0.0"
}

local http = require("resty.http")

-- Cache for geo lookups
local geo_cache = {}
local CACHE_TTL = 3600  -- 1 hour

function _M.lookup(ip)
    -- Check cache
    local cached = geo_cache[ip]
    if cached and (ngx.now() - cached.time) < CACHE_TTL then
        return cached.data
    end

    -- Call external geo API
    local httpc = http.new()
    local res, err = httpc:request_uri("http://ip-api.com/json/" .. ip)

    if not res then
        ngx.log(ngx.WARN, "geo lookup failed: ", err)
        return nil
    end

    local cjson = require("cjson.safe")
    local data = cjson.decode(res.body)

    -- Cache result
    geo_cache[ip] = {
        data = data,
        time = ngx.now()
    }

    return data
end

function _M.get_country(ip)
    local geo = _M.lookup(ip)
    return geo and geo.countryCode or "UNKNOWN"
end

return _M
```

**Step 2: Create plugin wrapper**

`apisix/plugins/unifra-geo.lua`:
```lua
local core = require("apisix.core")
local geo = require("unifra.geo.lookup")

local plugin_name = "unifra-geo"

local schema = {
    type = "object",
    properties = {
        blocked_countries = {
            type = "array",
            items = { type = "string" },
            default = {},
            description = "ISO country codes to block"
        },
        inject_header = {
            type = "boolean",
            default = true,
            description = "Add X-Geo-Country header"
        }
    },
}

local _M = {
    version = 0.1,
    priority = 2000,  -- Run early
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    local client_ip = ctx.var.remote_addr
    local country = geo.get_country(client_ip)

    -- Store in ctx.var for other plugins
    ctx.var.geo_country = country

    -- Block if country is in blocked list
    for _, blocked in ipairs(conf.blocked_countries) do
        if country == blocked then
            core.log.warn("blocked country: ", country, " ip: ", client_ip)
            return 403, {
                jsonrpc = "2.0",
                error = {
                    code = -32603,
                    message = "access denied from your region"
                },
                id = ctx.jsonrpc and ctx.jsonrpc.ids and ctx.jsonrpc.ids[1]
            }
        end
    end
end

function _M.header_filter(conf, ctx)
    if conf.inject_header and ctx.var.geo_country then
        core.response.set_header("X-Geo-Country", ctx.var.geo_country)
    end
end

return _M
```

**Step 3: Add to APISIX config**

```yaml
plugins:
  - unifra-geo  # Add new plugin
  - unifra-jsonrpc-var
  # ... other plugins
```

**Step 4: Configure route**

```json
{
  "plugins": {
    "unifra-geo": {
      "blocked_countries": ["CN", "RU"],
      "inject_header": true
    }
  }
}
```

---

## Testing

### Unit Tests

`tests/test_geo.lua`:
```lua
local geo = require("unifra.geo.lookup")

describe("geo lookup module", function()
    it("should return country code", function()
        -- Mock ngx
        _G.ngx = {
            now = function() return 0 end,
            log = function() end,
            INFO = 6,
            WARN = 5
        }

        -- Test with known IP
        local country = geo.get_country("8.8.8.8")
        assert.equals("US", country)
    end)

    it("should cache results", function()
        local first = geo.lookup("8.8.8.8")
        local second = geo.lookup("8.8.8.8")
        assert.same(first, second)
    end)
end)
```

Run tests:
```bash
busted tests/test_geo.lua
```

### Integration Tests

`tests/integration/test_geo.sh`:
```bash
#!/bin/bash

# Test geo blocking
echo "Testing geo blocking..."

# This should fail (if your IP is in blocked list)
result=$(curl -s http://localhost:9080/eth/ \
  -H "apikey: test-key" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')

if echo "$result" | grep -q "access denied"; then
    echo "[PASS] Geo blocking works"
else
    echo "[FAIL] Geo blocking not working"
fi

# Test header injection
echo "Testing header injection..."

headers=$(curl -si http://localhost:9080/eth/ \
  -H "apikey: test-key" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')

if echo "$headers" | grep -q "X-Geo-Country"; then
    echo "[PASS] Header injection works"
else
    echo "[FAIL] Header not injected"
fi
```

### Load Testing

```bash
# Using wrk
wrk -t4 -c100 -d30s \
  -s post.lua \
  http://localhost:9080/eth/

# post.lua
wrk.method = "POST"
wrk.body = '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
wrk.headers["Content-Type"] = "application/json"
wrk.headers["apikey"] = "test-key"
```

---

## Best Practices

### 1. Use Business Logic Modules

Separate reusable logic from APISIX plugin boilerplate:

```
✅ Good:
  unifra/geo/lookup.lua     # Reusable logic
  apisix/plugins/unifra-geo.lua  # Thin wrapper

❌ Bad:
  apisix/plugins/unifra-geo.lua  # Everything in one file
```

### 2. Handle Errors Gracefully

```lua
function _M.access(conf, ctx)
    local ok, result = pcall(function()
        return do_something_risky()
    end)

    if not ok then
        core.log.error("plugin error: ", result)
        if conf.allow_degradation then
            return  -- Continue without blocking
        end
        return 500  -- Block request
    end
end
```

### 3. Use Configuration TTL

For external config files, implement TTL-based caching:

```lua
local config_cache = nil
local config_loaded_at = 0
local CONFIG_TTL = 60

function load_config(path)
    local now = ngx.now()
    if config_cache and (now - config_loaded_at) < CONFIG_TTL then
        return config_cache
    end

    -- Load from file
    config_cache = do_load(path)
    config_loaded_at = now
    return config_cache
end
```

### 4. Minimize Redis Calls

Batch operations when possible:

```lua
-- ❌ Bad: Multiple round trips
local val1 = redis:get("key1")
local val2 = redis:get("key2")

-- ✅ Good: Single round trip
local results = redis:pipeline(function(p)
    p:get("key1")
    p:get("key2")
end)
```

### 5. Log Appropriately

```lua
-- Use appropriate log levels
core.log.debug("detailed debug info")   -- Development only
core.log.info("normal operation")        -- Operational info
core.log.warn("potential issue")         -- Warnings
core.log.error("error occurred")         -- Errors
```

### 6. Validate Input

Always validate user input:

```lua
function _M.access(conf, ctx)
    local body = core.request.get_body()
    if not body or #body == 0 then
        return 400, {error = "empty body"}
    end

    local json, err = cjson.decode(body)
    if not json then
        return 400, {error = "invalid JSON: " .. err}
    end
end
```

---

## API Reference

### core.request

```lua
-- Get request body
local body = core.request.get_body()

-- Get header
local auth = core.request.header(ctx, "Authorization")

-- Get URI args
local args = core.request.get_uri_args(ctx)
```

### core.response

```lua
-- Set response header
core.response.set_header("X-Custom", "value")

-- Set multiple headers
core.response.set_headers({
    ["X-One"] = "1",
    ["X-Two"] = "2"
})
```

### core.log

```lua
core.log.debug("message")
core.log.info("message")
core.log.warn("message")
core.log.error("message")

-- With variables
core.log.info("user: ", username, " method: ", method)
```

### ctx.var

```lua
-- Read nginx variable
local ip = ctx.var.remote_addr
local host = ctx.var.host

-- Write custom variable (for other plugins)
ctx.var.my_custom_var = "value"

-- Read custom variable
local val = ctx.var.my_custom_var
```

### ctx Object

```lua
-- Store complex data
ctx.my_data = {
    parsed = true,
    items = {1, 2, 3}
}

-- Read in later plugin
if ctx.my_data and ctx.my_data.parsed then
    -- ...
end
```

### JSON-RPC Helpers

```lua
local jsonrpc = require("unifra.jsonrpc.core")

-- Parse request
local result, err = jsonrpc.parse(body)
-- result.method, result.methods, result.ids, result.is_batch

-- Create error response
local resp = jsonrpc.error_response(
    jsonrpc.ERROR_RATE_LIMITED,  -- -32005
    "rate limit exceeded",
    request_id
)

-- Extract network from host
local network = jsonrpc.extract_network("eth-mainnet.unifra.io")
-- Returns: "eth-mainnet"
```

### Redis Operations

```lua
local ratelimit = require("unifra.jsonrpc.ratelimit")

local redis_conf = {
    host = "127.0.0.1",
    port = 6379,
    password = "",
    database = 0,
    timeout = 1000
}

-- Check and increment rate limit
local allowed, remaining, err = ratelimit.check_and_incr(
    redis_conf,
    "key",
    cost,      -- CU to consume
    limit,     -- Max CU per window
    window     -- Window in seconds
)
```
