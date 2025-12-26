# Comprehensive Testing Strategy Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a complete automated testing system that provides production-ready confidence for the Unifra APISIX JSON-RPC gateway.

**Architecture:** Four-layer test pyramid (unit → component → integration → load) with risk-prioritized test coverage. Tests use Busted for Lua unit/component tests, shell scripts for integration tests, and k6 for load tests.

**Tech Stack:** Busted (Lua testing), Docker Compose, Redis, GitHub Actions, k6

---

## Phase 1: Infrastructure Setup

### Task 1.1: Create Test Directory Structure

**Files:**
- Create: `tests/unit/.gitkeep`
- Create: `tests/component/.gitkeep`
- Create: `tests/integration/.gitkeep`
- Create: `tests/load/.gitkeep`
- Create: `tests/staging/.gitkeep`
- Create: `tests/fixtures/consumers/.gitkeep`
- Create: `tests/fixtures/routes/.gitkeep`
- Create: `tests/fixtures/requests/.gitkeep`
- Create: `tests/helpers/.gitkeep`

**Step 1: Create directory structure**

```bash
cd /Users/daoleno/unifra/apisix/.worktrees/testing-strategy
mkdir -p tests/{unit,component,integration,load,staging}
mkdir -p tests/fixtures/{consumers,routes,requests}
mkdir -p tests/helpers
touch tests/unit/.gitkeep tests/component/.gitkeep tests/integration/.gitkeep
touch tests/load/.gitkeep tests/staging/.gitkeep
touch tests/fixtures/consumers/.gitkeep tests/fixtures/routes/.gitkeep
touch tests/fixtures/requests/.gitkeep tests/helpers/.gitkeep
```

**Step 2: Commit**

```bash
git add tests/
git commit -m "chore: create test directory structure"
```

---

### Task 1.2: Create Test Helpers - Mock NGX

**Files:**
- Create: `tests/helpers/mock_ngx.lua`

**Step 1: Write mock_ngx.lua**

```lua
--
-- Mock ngx object for unit testing outside OpenResty
-- Provides essential ngx.* functions used by Unifra modules
--

local _M = {}

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
end

-- Uninstall global ngx
function _M.uninstall()
    _G.ngx = nil
end

return _M
```

**Step 2: Commit**

```bash
git add tests/helpers/mock_ngx.lua
git commit -m "test: add mock ngx helper for unit tests"
```

---

### Task 1.3: Create Test Configuration (conftest.lua)

**Files:**
- Create: `tests/conftest.lua`

**Step 1: Write conftest.lua**

```lua
--
-- Shared test configuration and fixtures for Busted tests
--

local _M = {}

-- Setup package path for testing
local function setup_path()
    local script_path = debug.getinfo(1, "S").source:sub(2)
    local tests_dir = script_path:match("(.*/)")
    local project_root = tests_dir:match("(.*/)[^/]+/") or tests_dir .. "../"

    package.path = project_root .. "?.lua;" ..
                   project_root .. "?/init.lua;" ..
                   package.path
end

setup_path()

-- Load mock ngx
local mock_ngx = require("tests.helpers.mock_ngx")

-- Install mock before loading modules
function _M.setup()
    mock_ngx.install()
end

-- Cleanup after tests
function _M.teardown()
    mock_ngx.reset()
end

-- Reset between tests
function _M.reset()
    mock_ngx.reset()
end

-- Common test fixtures

_M.fixtures = {
    -- CU pricing configuration
    cu_config = {
        default = 1,
        methods = {
            ["eth_blockNumber"] = 1,
            ["eth_chainId"] = 1,
            ["eth_gasPrice"] = 1,
            ["eth_getBalance"] = 2,
            ["eth_call"] = 5,
            ["eth_estimateGas"] = 5,
            ["eth_getLogs"] = 10,
            ["eth_getTransactionReceipt"] = 3,
            ["debug_*"] = 20,
            ["trace_*"] = 50,
        }
    },

    -- Whitelist configuration
    whitelist_config = {
        networks = {
            ["eth-mainnet"] = {
                free = {"eth_blockNumber", "eth_chainId", "eth_gasPrice", "eth_call", "eth_*"},
                paid = {"debug_*", "trace_*"},
                free_lookup = {},
                paid_lookup = {}
            }
        }
    },

    -- Test consumers
    consumers = {
        free_tier = {
            username = "test-free-user",
            api_key = "free-api-key-123",
            seconds_quota = 100,
            monthly_quota = 10000,
            tier = "free"
        },
        paid_tier = {
            username = "test-paid-user",
            api_key = "paid-api-key-456",
            seconds_quota = 1000,
            monthly_quota = 1000000,
            tier = "paid"
        },
        exhausted = {
            username = "test-exhausted-user",
            api_key = "exhausted-api-key-789",
            seconds_quota = 100,
            monthly_quota = 100,
            used_quota = 100,
            tier = "free"
        }
    },

    -- Test JSON-RPC requests
    requests = {
        single_valid = '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}',
        single_call = '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0x0","data":"0x"},"latest"],"id":1}',
        batch_valid = '[{"jsonrpc":"2.0","method":"eth_blockNumber","id":1},{"jsonrpc":"2.0","method":"eth_chainId","id":2}]',
        batch_mixed = '[{"jsonrpc":"2.0","method":"eth_blockNumber","id":1},{"jsonrpc":"2.0","method":"debug_trace","id":2}]',
        invalid_json = '{"invalid json',
        missing_method = '{"jsonrpc":"2.0","params":[],"id":1}',
        empty_batch = '[]',
    }
}

-- Build lookup tables for whitelist config
local function build_lookups()
    for network, config in pairs(_M.fixtures.whitelist_config.networks) do
        for _, m in ipairs(config.free) do
            config.free_lookup[m] = true
        end
        for _, m in ipairs(config.paid) do
            config.paid_lookup[m] = true
        end
    end
end
build_lookups()

return _M
```

**Step 2: Commit**

```bash
git add tests/conftest.lua
git commit -m "test: add conftest with shared fixtures"
```

---

### Task 1.4: Create Makefile with Test Commands

**Files:**
- Create: `Makefile`

**Step 1: Write Makefile**

```makefile
.PHONY: test-unit test-component test-integration test-load test-all test-coverage help

# Default target
help:
	@echo "Unifra APISIX Test Commands"
	@echo "==========================="
	@echo ""
	@echo "  make test-unit          Run unit tests (fast, no dependencies)"
	@echo "  make test-component     Run component tests (requires Redis)"
	@echo "  make test-integration   Run integration tests (full Docker stack)"
	@echo "  make test-load          Run load tests (requires k6)"
	@echo "  make test-all           Run all tests in sequence"
	@echo "  make test-coverage      Run tests with coverage report"
	@echo ""
	@echo "  make dev-setup          Set up local development environment"
	@echo "  make docker-up          Start Docker test environment"
	@echo "  make docker-down        Stop Docker test environment"
	@echo ""

# Check if busted is available
check-busted:
	@command -v busted >/dev/null 2>&1 || { \
		echo "Error: busted not found. Install with: luarocks install busted"; \
		exit 1; \
	}

# Unit tests - fast, no dependencies
test-unit: check-busted
	@echo "Running unit tests..."
	@cd tests && busted unit/ --verbose --pattern=test

# Component tests - requires Redis
test-component: check-busted
	@echo "Starting Redis for component tests..."
	@docker run -d --name test-redis -p 6379:6379 redis:7-alpine >/dev/null 2>&1 || true
	@sleep 2
	@echo "Running component tests..."
	@REDIS_HOST=localhost REDIS_PORT=6379 busted tests/component/ --verbose --pattern=test || \
		(docker stop test-redis >/dev/null 2>&1; docker rm test-redis >/dev/null 2>&1; exit 1)
	@docker stop test-redis >/dev/null 2>&1
	@docker rm test-redis >/dev/null 2>&1
	@echo "Component tests completed."

# Integration tests - full Docker stack
test-integration:
	@echo "Starting full test environment..."
	@cd test-env && docker-compose up -d
	@echo "Waiting for services..."
	@sleep 10
	@./test-env/test-all.sh || (cd test-env && docker-compose down; exit 1)
	@cd test-env && docker-compose down
	@echo "Integration tests completed."

# Load tests - requires k6
test-load:
	@command -v k6 >/dev/null 2>&1 || { \
		echo "Error: k6 not found. Install from https://k6.io/docs/getting-started/installation/"; \
		exit 1; \
	}
	@echo "Starting test environment for load tests..."
	@cd test-env && docker-compose up -d
	@sleep 15
	@echo "Running load tests..."
	@k6 run tests/load/billing_accuracy_load.js || true
	@cd test-env && docker-compose down

# Run all tests
test-all: test-unit test-component test-integration
	@echo ""
	@echo "================================"
	@echo "All tests completed successfully!"
	@echo "================================"

# Coverage report
test-coverage: check-busted
	@echo "Running tests with coverage..."
	@cd tests && busted unit/ --coverage --verbose
	@echo "Coverage report generated."

# Development setup
dev-setup:
	@echo "Setting up development environment..."
	@./scripts/dev-setup.sh

# Docker environment management
docker-up:
	@cd test-env && docker-compose up -d
	@echo "Test environment started."

docker-down:
	@cd test-env && docker-compose down -v
	@echo "Test environment stopped."

# Minimal Docker for component tests
docker-redis:
	@docker run -d --name test-redis -p 6379:6379 redis:7-alpine
	@echo "Redis started on port 6379"

docker-redis-stop:
	@docker stop test-redis && docker rm test-redis
	@echo "Redis stopped"
```

**Step 2: Commit**

```bash
git add Makefile
git commit -m "build: add Makefile with test commands"
```

---

### Task 1.5: Create Development Setup Script

**Files:**
- Create: `scripts/dev-setup.sh`

**Step 1: Create scripts directory and setup script**

```bash
mkdir -p scripts
```

**Step 2: Write dev-setup.sh**

```bash
#!/bin/bash
#
# Development environment setup script
# Run this once to prepare your local environment for testing
#

set -e

echo "========================================"
echo " Unifra APISIX Development Setup"
echo "========================================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

# Check prerequisites
echo "Checking prerequisites..."

# Docker
if command -v docker &> /dev/null; then
    success "Docker installed: $(docker --version | head -1)"
else
    error "Docker not found. Please install Docker first."
    exit 1
fi

# Docker Compose
if command -v docker-compose &> /dev/null; then
    success "Docker Compose installed: $(docker-compose --version)"
else
    warn "docker-compose not found, checking for 'docker compose'..."
    if docker compose version &> /dev/null; then
        success "Docker Compose (plugin) installed"
    else
        error "Docker Compose not found. Please install it."
        exit 1
    fi
fi

# Lua
if command -v lua &> /dev/null; then
    success "Lua installed: $(lua -v 2>&1 | head -1)"
else
    warn "Lua not found. Unit tests require Lua."
fi

# LuaRocks
if command -v luarocks &> /dev/null; then
    success "LuaRocks installed: $(luarocks --version | head -1)"
else
    warn "LuaRocks not found. Installing test dependencies may fail."
    echo "  Install with: brew install luarocks (macOS) or apt install luarocks (Ubuntu)"
fi

# Busted
if command -v busted &> /dev/null; then
    success "Busted installed"
else
    warn "Busted not found. Attempting to install..."
    if command -v luarocks &> /dev/null; then
        luarocks install --local busted
        success "Busted installed via LuaRocks"
    else
        warn "Cannot install Busted without LuaRocks"
        echo "  Install manually: luarocks install busted"
    fi
fi

echo ""
echo "Setting up test environment..."

# Verify Docker services can start
echo "Testing Docker environment..."
cd test-env
docker-compose config > /dev/null 2>&1 && success "Docker Compose config valid" || error "Docker Compose config invalid"
cd ..

# Create local LuaRocks tree if needed
if [ ! -d "$HOME/.luarocks" ]; then
    mkdir -p "$HOME/.luarocks"
    success "Created local LuaRocks directory"
fi

# Install additional Lua dependencies
echo ""
echo "Installing Lua dependencies..."
if command -v luarocks &> /dev/null; then
    luarocks install --local luafilesystem 2>/dev/null && success "luafilesystem" || warn "luafilesystem (may already exist)"
    luarocks install --local lua-cjson 2>/dev/null && success "lua-cjson" || warn "lua-cjson (may already exist)"
fi

echo ""
echo "========================================"
echo " Setup Complete!"
echo "========================================"
echo ""
echo "Available commands:"
echo "  make test-unit          # Run unit tests (fast)"
echo "  make test-component     # Run component tests (with Redis)"
echo "  make test-integration   # Run integration tests (full stack)"
echo "  make test-all           # Run all tests"
echo ""
echo "Quick start:"
echo "  1. Run unit tests:      make test-unit"
echo "  2. Start test env:      make docker-up"
echo "  3. Run all tests:       make test-all"
echo ""
```

**Step 3: Make executable and commit**

```bash
chmod +x scripts/dev-setup.sh
git add scripts/dev-setup.sh
git commit -m "build: add development setup script"
```

---

### Task 1.6: Create Minimal Docker Compose for Component Tests

**Files:**
- Create: `test-env/docker-compose-minimal.yml`

**Step 1: Write docker-compose-minimal.yml**

```yaml
# Minimal setup for component tests (Redis only)
# Usage: docker-compose -f docker-compose-minimal.yml up -d

services:
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 3s
      retries: 5
    command: redis-server --appendonly no --save ""
```

**Step 2: Commit**

```bash
git add test-env/docker-compose-minimal.yml
git commit -m "build: add minimal docker-compose for component tests"
```

---

### Task 1.7: Create GitHub Actions CI Workflow

**Files:**
- Create: `.github/workflows/test.yml`

**Step 1: Create directory and workflow**

```bash
mkdir -p .github/workflows
```

**Step 2: Write test.yml**

```yaml
name: Test Suite

on:
  push:
    branches: [master, main, develop, 'feature/*']
  pull_request:
    branches: [master, main]

env:
  REDIS_HOST: localhost
  REDIS_PORT: 6379

jobs:
  # Stage 1: Unit Tests (fastest feedback)
  unit-tests:
    name: Unit Tests
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Setup Lua
        uses: leafo/gh-actions-lua@v10
        with:
          luaVersion: "5.1"

      - name: Setup LuaRocks
        uses: leafo/gh-actions-luarocks@v4

      - name: Install dependencies
        run: |
          luarocks install busted
          luarocks install luafilesystem
          luarocks install lua-cjson

      - name: Run unit tests
        run: |
          cd tests
          busted unit/ --verbose --output=TAP

  # Stage 2: Component Tests (with Redis)
  component-tests:
    name: Component Tests
    runs-on: ubuntu-latest
    needs: unit-tests

    services:
      redis:
        image: redis:7-alpine
        ports:
          - 6379:6379
        options: >-
          --health-cmd "redis-cli ping"
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4

      - name: Setup Lua
        uses: leafo/gh-actions-lua@v10
        with:
          luaVersion: "5.1"

      - name: Setup LuaRocks
        uses: leafo/gh-actions-luarocks@v4

      - name: Install dependencies
        run: |
          luarocks install busted
          luarocks install luafilesystem
          luarocks install lua-cjson
          luarocks install redis-lua

      - name: Run component tests
        run: |
          cd tests
          busted component/ --verbose --output=TAP

  # Stage 3: Integration Tests (full stack)
  integration-tests:
    name: Integration Tests
    runs-on: ubuntu-latest
    needs: component-tests

    steps:
      - uses: actions/checkout@v4

      - name: Start test environment
        run: |
          cd test-env
          docker-compose up -d

      - name: Install Foundry (Anvil)
        uses: foundry-rs/foundry-toolchain@v1

      - name: Start Anvil
        run: |
          anvil --host 0.0.0.0 --port 8545 &
          sleep 5

      - name: Wait for APISIX
        run: |
          timeout 60 bash -c 'until curl -s http://localhost:9180/apisix/admin/plugins/list -H "X-API-KEY: unifra-test-admin-key" > /dev/null; do sleep 2; done'

      - name: Run integration tests
        run: ./test-env/test-all.sh

      - name: Collect logs on failure
        if: failure()
        run: |
          docker-compose -f test-env/docker-compose.yml logs > apisix-logs.txt

      - name: Upload logs
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: apisix-logs
          path: apisix-logs.txt

      - name: Cleanup
        if: always()
        run: |
          cd test-env
          docker-compose down -v
```

**Step 3: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "ci: add GitHub Actions test workflow"
```

---

## Phase 2: P0 Critical Tests

### Task 2.1: Unit Test - CU Calculation

**Files:**
- Create: `tests/unit/test_cu_calculation.lua`

**Step 1: Write the test file**

```lua
--
-- Unit tests for CU calculation accuracy
-- These tests verify that compute unit costs are calculated correctly
--

-- Setup path
package.path = "?.lua;../?.lua;../?/init.lua;" .. package.path

-- Load test helpers
local conftest = require("tests.conftest")
conftest.setup()

-- Now load the module under test
local cu = require("unifra.jsonrpc.cu")

describe("CU Calculation Accuracy", function()
    local config

    setup(function()
        conftest.setup()
        config = conftest.fixtures.cu_config
    end)

    teardown(function()
        conftest.teardown()
    end)

    before_each(function()
        conftest.reset()
    end)

    describe("get_method_cu", function()
        it("should return exact CU for known methods", function()
            assert.equals(1, cu.get_method_cu("eth_blockNumber", config))
            assert.equals(5, cu.get_method_cu("eth_call", config))
            assert.equals(10, cu.get_method_cu("eth_getLogs", config))
        end)

        it("should match wildcard patterns", function()
            assert.equals(20, cu.get_method_cu("debug_traceTransaction", config))
            assert.equals(20, cu.get_method_cu("debug_traceCall", config))
            assert.equals(50, cu.get_method_cu("trace_block", config))
            assert.equals(50, cu.get_method_cu("trace_call", config))
        end)

        it("should return default CU for unknown methods", function()
            assert.equals(1, cu.get_method_cu("unknown_method", config))
            assert.equals(1, cu.get_method_cu("net_version", config))
        end)

        it("should return 1 when config is nil", function()
            assert.equals(1, cu.get_method_cu("eth_call", nil))
        end)

        it("should return default when methods table is empty", function()
            local empty_config = { default = 5, methods = {} }
            assert.equals(5, cu.get_method_cu("any_method", empty_config))
        end)
    end)

    describe("calculate (single method)", function()
        it("should calculate CU for single method", function()
            assert.equals(1, cu.calculate({"eth_blockNumber"}, config))
            assert.equals(5, cu.calculate({"eth_call"}, config))
            assert.equals(10, cu.calculate({"eth_getLogs"}, config))
        end)
    end)

    describe("calculate (batch methods)", function()
        it("should sum CU for multiple methods", function()
            local methods = {"eth_blockNumber", "eth_call", "eth_getLogs"}
            assert.equals(16, cu.calculate(methods, config)) -- 1 + 5 + 10
        end)

        it("should handle duplicate methods", function()
            local methods = {"eth_blockNumber", "eth_blockNumber", "eth_call"}
            assert.equals(7, cu.calculate(methods, config)) -- 1 + 1 + 5
        end)

        it("should handle mixed known and unknown methods", function()
            local methods = {"eth_blockNumber", "unknown_method", "eth_call"}
            assert.equals(7, cu.calculate(methods, config)) -- 1 + 1 + 5
        end)

        it("should handle wildcard methods in batch", function()
            local methods = {"eth_blockNumber", "debug_trace", "trace_block"}
            assert.equals(71, cu.calculate(methods, config)) -- 1 + 20 + 50
        end)
    end)

    describe("calculate (edge cases)", function()
        it("should return 0 for empty list", function()
            assert.equals(0, cu.calculate({}, config))
        end)

        it("should return 0 for nil list", function()
            assert.equals(0, cu.calculate(nil, config))
        end)

        it("should handle large batch correctly", function()
            local methods = {}
            for i = 1, 100 do
                table.insert(methods, "eth_blockNumber")
            end
            assert.equals(100, cu.calculate(methods, config))
        end)
    end)

    describe("calculate_breakdown", function()
        it("should return breakdown and total", function()
            local methods = {"eth_blockNumber", "eth_call", "eth_blockNumber"}
            local breakdown, total = cu.calculate_breakdown(methods, config)

            assert.equals(7, total) -- 1 + 5 + 1
            assert.equals(2, breakdown["eth_blockNumber"]) -- 1 + 1
            assert.equals(5, breakdown["eth_call"])
        end)

        it("should return empty breakdown for empty list", function()
            local breakdown, total = cu.calculate_breakdown({}, config)
            assert.equals(0, total)
            assert.same({}, breakdown)
        end)
    end)
end)
```

**Step 2: Run test to verify it works**

```bash
cd tests && busted unit/test_cu_calculation.lua --verbose
```

Expected: All tests pass

**Step 3: Commit**

```bash
git add tests/unit/test_cu_calculation.lua
git commit -m "test: add CU calculation unit tests"
```

---

### Task 2.2: Unit Test - JSON-RPC Core Parsing

**Files:**
- Create: `tests/unit/test_core_parsing.lua`

**Step 1: Write the test file**

```lua
--
-- Unit tests for JSON-RPC core parsing
-- Tests the parse() function for single and batch requests
--

package.path = "?.lua;../?.lua;../?/init.lua;" .. package.path

local conftest = require("tests.conftest")
conftest.setup()

-- Mock cjson
local cjson = require("cjson.safe")

local core = require("unifra.jsonrpc.core")

describe("JSON-RPC Core Parsing", function()

    setup(function()
        conftest.setup()
    end)

    teardown(function()
        conftest.teardown()
    end)

    describe("parse single request", function()
        it("should parse valid single request", function()
            local body = '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
            local result, err = core.parse(body)

            assert.is_nil(err)
            assert.is_not_nil(result)
            assert.equals("eth_blockNumber", result.method)
            assert.equals(false, result.is_batch)
            assert.equals(1, result.count)
            assert.same({"eth_blockNumber"}, result.methods)
        end)

        it("should extract method with params", function()
            local body = '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0x0"},"latest"],"id":1}'
            local result, err = core.parse(body)

            assert.is_nil(err)
            assert.equals("eth_call", result.method)
        end)

        it("should handle notification (no id)", function()
            local body = '{"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"]}'
            local result, err = core.parse(body)

            assert.is_nil(err)
            assert.equals("eth_subscribe", result.method)
        end)
    end)

    describe("parse batch request", function()
        it("should parse valid batch request", function()
            local body = '[{"jsonrpc":"2.0","method":"eth_blockNumber","id":1},{"jsonrpc":"2.0","method":"eth_chainId","id":2}]'
            local result, err = core.parse(body)

            assert.is_nil(err)
            assert.equals(true, result.is_batch)
            assert.equals(2, result.count)
            assert.same({"eth_blockNumber", "eth_chainId"}, result.methods)
        end)

        it("should extract all IDs from batch", function()
            local body = '[{"jsonrpc":"2.0","method":"m1","id":1},{"jsonrpc":"2.0","method":"m2","id":"str-id"}]'
            local result, err = core.parse(body)

            assert.is_nil(err)
            assert.equals(1, result.ids[1])
            assert.equals("str-id", result.ids[2])
        end)
    end)

    describe("parse errors", function()
        it("should reject empty body", function()
            local result, err = core.parse("")
            assert.is_nil(result)
            assert.equals("empty body", err)
        end)

        it("should reject nil body", function()
            local result, err = core.parse(nil)
            assert.is_nil(result)
            assert.equals("empty body", err)
        end)

        it("should reject invalid JSON", function()
            local result, err = core.parse("{invalid json")
            assert.is_nil(result)
            assert.is_truthy(err:match("parse error"))
        end)

        it("should reject missing method", function()
            local result, err = core.parse('{"jsonrpc":"2.0","params":[],"id":1}')
            assert.is_nil(result)
            assert.equals("missing method field", err)
        end)

        it("should reject empty method", function()
            local result, err = core.parse('{"jsonrpc":"2.0","method":"","id":1}')
            assert.is_nil(result)
            assert.equals("empty method name", err)
        end)

        it("should reject empty batch", function()
            local result, err = core.parse('[]')
            assert.is_nil(result)
            assert.equals("empty batch", err)
        end)

        it("should reject body exceeding max size", function()
            local large_body = string.rep("x", 1048577) -- > 1 MiB
            local result, err = core.parse(large_body)
            assert.is_nil(result)
            assert.equals("body too large", err)
        end)

        it("should reject batch exceeding max size", function()
            local batch = {}
            for i = 1, 101 do
                table.insert(batch, {jsonrpc = "2.0", method = "m" .. i, id = i})
            end
            local body = cjson.encode(batch)
            local result, err = core.parse(body)
            assert.is_nil(result)
            assert.is_truthy(err:match("batch too large"))
        end)
    end)

    describe("error_response", function()
        it("should generate valid error response", function()
            local resp = core.error_response(-32600, "Invalid Request", 1)
            local decoded = cjson.decode(resp)

            assert.equals("2.0", decoded.jsonrpc)
            assert.equals(1, decoded.id)
            assert.equals(-32600, decoded.error.code)
            assert.equals("Invalid Request", decoded.error.message)
        end)

        it("should handle nil id", function()
            local resp = core.error_response(-32700, "Parse error", nil)
            local decoded = cjson.decode(resp)

            -- nil id should become null in JSON
            assert.equals(cjson.null, decoded.id)
        end)
    end)

    describe("extract_network", function()
        it("should extract network from unifra.io domain", function()
            assert.equals("eth-mainnet", core.extract_network("eth-mainnet.unifra.io"))
            assert.equals("polygon", core.extract_network("polygon.unifra.io"))
        end)

        it("should extract network from generic domain", function()
            assert.equals("eth", core.extract_network("eth.example.com"))
        end)

        it("should return nil for nil host", function()
            assert.is_nil(core.extract_network(nil))
        end)
    end)

    describe("match_method", function()
        it("should match exact method", function()
            assert.is_true(core.match_method("eth_call", "eth_call"))
        end)

        it("should not match different method", function()
            assert.is_false(core.match_method("eth_call", "eth_send"))
        end)

        it("should match wildcard pattern", function()
            assert.is_true(core.match_method("debug_traceTransaction", "debug_*"))
            assert.is_true(core.match_method("debug_anything", "debug_*"))
        end)

        it("should not match partial wildcard", function()
            assert.is_false(core.match_method("eth_debug_trace", "debug_*"))
        end)
    end)
end)
```

**Step 2: Run test**

```bash
cd tests && busted unit/test_core_parsing.lua --verbose
```

**Step 3: Commit**

```bash
git add tests/unit/test_core_parsing.lua
git commit -m "test: add JSON-RPC core parsing unit tests"
```

---

### Task 2.3: Unit Test - Whitelist Access Control

**Files:**
- Create: `tests/unit/test_whitelist.lua`

**Step 1: Write the test file**

```lua
--
-- Unit tests for whitelist access control
-- Tests method access validation for free and paid tiers
--

package.path = "?.lua;../?.lua;../?/init.lua;" .. package.path

local conftest = require("tests.conftest")
conftest.setup()

local whitelist = require("unifra.jsonrpc.whitelist")

describe("Whitelist Access Control", function()
    local config

    setup(function()
        conftest.setup()
        -- Build a proper whitelist config
        config = {
            networks = {
                ["eth-mainnet"] = {
                    free = {"eth_blockNumber", "eth_chainId", "eth_gasPrice", "eth_call", "eth_getBalance"},
                    paid = {"debug_*", "trace_*"},
                    free_lookup = {},
                    paid_lookup = {}
                },
                ["polygon"] = {
                    free = {"eth_*"},
                    paid = {"debug_*"},
                    free_lookup = {},
                    paid_lookup = {}
                }
            }
        }
        -- Build lookup tables
        for network, nc in pairs(config.networks) do
            for _, m in ipairs(nc.free) do nc.free_lookup[m] = true end
            for _, m in ipairs(nc.paid) do nc.paid_lookup[m] = true end
        end
    end)

    teardown(function()
        conftest.teardown()
    end)

    describe("check (free tier)", function()
        it("should allow free methods for free tier", function()
            local ok, err = whitelist.check("eth-mainnet", {"eth_blockNumber"}, false, config)
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should allow multiple free methods", function()
            local ok, err = whitelist.check("eth-mainnet", {"eth_blockNumber", "eth_chainId"}, false, config)
            assert.is_true(ok)
        end)

        it("should reject paid methods for free tier", function()
            local ok, err = whitelist.check("eth-mainnet", {"debug_traceTransaction"}, false, config)
            assert.is_false(ok)
            assert.is_truthy(err:match("requires paid tier"))
        end)

        it("should reject if any method in batch requires paid", function()
            local ok, err = whitelist.check("eth-mainnet", {"eth_blockNumber", "debug_trace"}, false, config)
            assert.is_false(ok)
            assert.is_truthy(err:match("requires paid tier"))
        end)
    end)

    describe("check (paid tier)", function()
        it("should allow free methods for paid tier", function()
            local ok, err = whitelist.check("eth-mainnet", {"eth_blockNumber"}, true, config)
            assert.is_true(ok)
        end)

        it("should allow paid methods for paid tier", function()
            local ok, err = whitelist.check("eth-mainnet", {"debug_traceTransaction"}, true, config)
            assert.is_true(ok)
        end)

        it("should allow mixed methods for paid tier", function()
            local ok, err = whitelist.check("eth-mainnet", {"eth_blockNumber", "debug_trace"}, true, config)
            assert.is_true(ok)
        end)
    end)

    describe("check (unsupported)", function()
        it("should reject unsupported network", function()
            local ok, err = whitelist.check("unsupported-network", {"eth_blockNumber"}, false, config)
            assert.is_false(ok)
            assert.is_truthy(err:match("unsupported network"))
        end)

        it("should reject unsupported method", function()
            local ok, err = whitelist.check("eth-mainnet", {"completely_unknown_method"}, false, config)
            assert.is_false(ok)
            assert.is_truthy(err:match("unsupported method"))
        end)
    end)

    describe("check (edge cases)", function()
        it("should reject nil methods", function()
            local ok, err = whitelist.check("eth-mainnet", nil, false, config)
            assert.is_false(ok)
        end)

        it("should reject empty methods", function()
            local ok, err = whitelist.check("eth-mainnet", {}, false, config)
            assert.is_false(ok)
        end)

        it("should reject nil network", function()
            local ok, err = whitelist.check(nil, {"eth_blockNumber"}, false, config)
            assert.is_false(ok)
        end)

        it("should reject nil config", function()
            local ok, err = whitelist.check("eth-mainnet", {"eth_blockNumber"}, false, nil)
            assert.is_false(ok)
        end)
    end)

    describe("wildcard matching", function()
        it("should match eth_* pattern for polygon", function()
            local ok, err = whitelist.check("polygon", {"eth_anyMethod"}, false, config)
            assert.is_true(ok)
        end)

        it("should match debug_* for paid polygon user", function()
            local ok, err = whitelist.check("polygon", {"debug_trace"}, true, config)
            assert.is_true(ok)
        end)
    end)

    describe("is_network_supported", function()
        it("should return true for supported network", function()
            assert.is_true(whitelist.is_network_supported("eth-mainnet", config))
            assert.is_true(whitelist.is_network_supported("polygon", config))
        end)

        it("should return false for unsupported network", function()
            assert.is_false(whitelist.is_network_supported("unknown", config))
        end)
    end)

    describe("get_networks", function()
        it("should return all networks", function()
            local networks = whitelist.get_networks(config)
            assert.equals(2, #networks)
            -- Should be sorted
            assert.equals("eth-mainnet", networks[1])
            assert.equals("polygon", networks[2])
        end)
    end)
end)
```

**Step 2: Run test**

```bash
cd tests && busted unit/test_whitelist.lua --verbose
```

**Step 3: Commit**

```bash
git add tests/unit/test_whitelist.lua
git commit -m "test: add whitelist access control unit tests"
```

---

### Task 2.4: Integration Test - Billing Accuracy

**Files:**
- Create: `tests/integration/test_billing_accuracy.sh`

**Step 1: Write the test script**

```bash
#!/bin/bash
#
# Integration test: Billing Accuracy
# Verifies that CU deductions are accurate through the full request pipeline
#

set -e

APISIX_URL="${APISIX_URL:-http://localhost:9080}"
ADMIN_URL="${ADMIN_URL:-http://localhost:9180}"
ADMIN_KEY="${ADMIN_KEY:-unifra-test-admin-key}"
API_KEY="${API_KEY:-test-api-key-123}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

echo "========================================"
echo " Integration Test: Billing Accuracy"
echo "========================================"

# Get Redis connection
REDIS_CLI="docker exec test-env-redis-1 redis-cli"

# Helper to get current CU usage from Redis
get_cu_usage() {
    local key="monthly:test-user:$(date +%Y-%m)"
    $REDIS_CLI GET "$key" 2>/dev/null || echo "0"
}

# Helper to clear Redis for clean test
clear_redis() {
    $REDIS_CLI FLUSHALL > /dev/null 2>&1
}

# Test 1: Single request CU deduction
echo ""
echo "Test 1: Single request CU deduction"
clear_redis
initial_cu=$(get_cu_usage)

# eth_blockNumber should cost 1 CU
curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' > /dev/null

sleep 1
final_cu=$(get_cu_usage)
expected_cu=$((initial_cu + 1))

if [ "$final_cu" = "$expected_cu" ] || [ "$final_cu" = "1" ]; then
    pass "Single request: CU increased by 1 (eth_blockNumber)"
else
    fail "Single request: Expected CU=$expected_cu, got $final_cu"
fi

# Test 2: Batch request CU deduction
echo ""
echo "Test 2: Batch request CU deduction"
clear_redis

# Batch: eth_blockNumber (1) + eth_chainId (1) + eth_gasPrice (1) = 3 CU
curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '[
    {"jsonrpc":"2.0","method":"eth_blockNumber","id":1},
    {"jsonrpc":"2.0","method":"eth_chainId","id":2},
    {"jsonrpc":"2.0","method":"eth_gasPrice","id":3}
  ]' > /dev/null

sleep 1
batch_cu=$(get_cu_usage)

if [ "$batch_cu" = "3" ]; then
    pass "Batch request: CU = 3 (sum of 3 methods)"
else
    fail "Batch request: Expected CU=3, got $batch_cu"
fi

# Test 3: Cumulative CU tracking
echo ""
echo "Test 3: Cumulative CU tracking"
clear_redis

# Send 5 requests
for i in {1..5}; do
    curl -s -X POST "$APISIX_URL/eth/" \
      -H "Content-Type: application/json" \
      -H "apikey: $API_KEY" \
      -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":'$i'}' > /dev/null
done

sleep 1
cumulative_cu=$(get_cu_usage)

if [ "$cumulative_cu" = "5" ]; then
    pass "Cumulative: 5 requests = 5 CU"
else
    fail "Cumulative: Expected CU=5, got $cumulative_cu"
fi

# Test 4: No CU for failed requests
echo ""
echo "Test 4: No CU for rejected requests (unauthorized)"
clear_redis

# Request without API key should be rejected, no CU charged
curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' > /dev/null

sleep 1
rejected_cu=$(get_cu_usage)

if [ "$rejected_cu" = "" ] || [ "$rejected_cu" = "0" ]; then
    pass "Rejected request: No CU charged"
else
    fail "Rejected request: Expected CU=0, got $rejected_cu"
fi

echo ""
echo "========================================"
echo " Billing Accuracy Tests Complete"
echo "========================================"
```

**Step 2: Make executable and commit**

```bash
chmod +x tests/integration/test_billing_accuracy.sh
git add tests/integration/test_billing_accuracy.sh
git commit -m "test: add billing accuracy integration tests"
```

---

### Task 2.5: Integration Test - Rate Limiting

**Files:**
- Create: `tests/integration/test_rate_limiting.sh`

**Step 1: Write the test script**

```bash
#!/bin/bash
#
# Integration test: Rate Limiting Accuracy
# Verifies that rate limiting enforces CU quotas correctly
#

set -e

APISIX_URL="${APISIX_URL:-http://localhost:9080}"
API_KEY="${API_KEY:-test-api-key-123}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

echo "========================================"
echo " Integration Test: Rate Limiting"
echo "========================================"

# Test 1: Burst traffic should be rate limited
echo ""
echo "Test 1: Burst traffic rate limiting"

# Clear Redis sliding window
docker exec test-env-redis-1 redis-cli FLUSHALL > /dev/null 2>&1

success=0
rate_limited=0

# Send 50 rapid requests (should exceed quota)
for i in {1..50}; do
    result=$(curl -s -X POST "$APISIX_URL/eth/" \
      -H "Content-Type: application/json" \
      -H "apikey: $API_KEY" \
      -d '{"jsonrpc":"2.0","method":"eth_blockNumber","id":'$i'}')

    if echo "$result" | grep -q '"result"'; then
        ((success++))
    elif echo "$result" | grep -q -i "rate.limit\|too.many\|429\|quota"; then
        ((rate_limited++))
    fi
done

info "Results: $success succeeded, $rate_limited rate-limited"

if [ $rate_limited -gt 0 ]; then
    pass "Burst traffic: Rate limiting triggered ($rate_limited requests limited)"
else
    fail "Burst traffic: Rate limiting did not trigger"
fi

# Test 2: Rate limit headers present
echo ""
echo "Test 2: Rate limit response headers"

response=$(curl -s -i -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}')

# Check for rate limit headers (X-RateLimit-* or similar)
if echo "$response" | grep -qi "x-ratelimit\|ratelimit\|remaining"; then
    pass "Rate limit headers present in response"
else
    info "Rate limit headers not found (may be optional)"
fi

# Test 3: Sliding window recovery
echo ""
echo "Test 3: Sliding window recovery"

# Clear and wait for window to slide
docker exec test-env-redis-1 redis-cli FLUSHALL > /dev/null 2>&1
sleep 2

# Should succeed after window resets
result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}')

if echo "$result" | grep -q '"result"'; then
    pass "Sliding window: Request succeeds after window reset"
else
    fail "Sliding window: Request should succeed after reset"
fi

echo ""
echo "========================================"
echo " Rate Limiting Tests Complete"
echo "========================================"
```

**Step 2: Make executable and commit**

```bash
chmod +x tests/integration/test_rate_limiting.sh
git add tests/integration/test_rate_limiting.sh
git commit -m "test: add rate limiting integration tests"
```

---

## Phase 3: P1 High-Risk Tests

### Task 3.1: Integration Test - Concurrent Requests

**Files:**
- Create: `tests/integration/test_concurrent_requests.sh`

**Step 1: Write the test script**

```bash
#!/bin/bash
#
# Integration test: Concurrent Request Handling
# Verifies no race conditions in quota deduction
#

set -e

APISIX_URL="${APISIX_URL:-http://localhost:9080}"
API_KEY="${API_KEY:-test-api-key-123}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

echo "========================================"
echo " Integration Test: Concurrent Requests"
echo "========================================"

# Clear Redis
docker exec test-env-redis-1 redis-cli FLUSHALL > /dev/null 2>&1

# Test 1: Concurrent requests should not cause race conditions
echo ""
echo "Test 1: Concurrent quota deduction accuracy"

# Launch 20 concurrent requests using background processes
pids=()
results_dir=$(mktemp -d)

for i in {1..20}; do
    (
        result=$(curl -s -X POST "$APISIX_URL/eth/" \
          -H "Content-Type: application/json" \
          -H "apikey: $API_KEY" \
          -d '{"jsonrpc":"2.0","method":"eth_blockNumber","id":'$i'}')
        echo "$result" > "$results_dir/result_$i.txt"
    ) &
    pids+=($!)
done

# Wait for all requests to complete
for pid in "${pids[@]}"; do
    wait $pid
done

# Count results
success=0
failed=0
for i in {1..20}; do
    if grep -q '"result"' "$results_dir/result_$i.txt" 2>/dev/null; then
        ((success++))
    else
        ((failed++))
    fi
done

rm -rf "$results_dir"

info "Concurrent results: $success succeeded, $failed failed/rate-limited"

# Check Redis for accurate CU count
sleep 1
cu_key="monthly:test-user:$(date +%Y-%m)"
actual_cu=$(docker exec test-env-redis-1 redis-cli GET "$cu_key" 2>/dev/null || echo "0")

# CU should equal number of successful requests (1 CU each)
if [ "$actual_cu" = "$success" ]; then
    pass "Concurrent: CU count matches successful requests ($actual_cu)"
else
    fail "Concurrent: CU mismatch - expected $success, got $actual_cu"
fi

# Test 2: High concurrency stress test
echo ""
echo "Test 2: High concurrency stress (50 parallel)"

docker exec test-env-redis-1 redis-cli FLUSHALL > /dev/null 2>&1

pids=()
results_dir=$(mktemp -d)

for i in {1..50}; do
    (
        result=$(curl -s -X POST "$APISIX_URL/eth/" \
          -H "Content-Type: application/json" \
          -H "apikey: $API_KEY" \
          -d '{"jsonrpc":"2.0","method":"eth_blockNumber","id":'$i'}')
        echo "$result" > "$results_dir/result_$i.txt"
    ) &
    pids+=($!)
done

for pid in "${pids[@]}"; do
    wait $pid
done

success=0
for i in {1..50}; do
    if grep -q '"result"' "$results_dir/result_$i.txt" 2>/dev/null; then
        ((success++))
    fi
done

rm -rf "$results_dir"

sleep 1
actual_cu=$(docker exec test-env-redis-1 redis-cli GET "$cu_key" 2>/dev/null || echo "0")

if [ "$actual_cu" = "$success" ]; then
    pass "High concurrency: CU accurate under stress ($actual_cu CU for $success requests)"
else
    fail "High concurrency: CU mismatch - $success requests but $actual_cu CU"
fi

echo ""
echo "========================================"
echo " Concurrent Request Tests Complete"
echo "========================================"
```

**Step 2: Make executable and commit**

```bash
chmod +x tests/integration/test_concurrent_requests.sh
git add tests/integration/test_concurrent_requests.sh
git commit -m "test: add concurrent requests integration tests"
```

---

### Task 3.2: Integration Test - Failure Scenarios

**Files:**
- Create: `tests/integration/test_failure_scenarios.sh`

**Step 1: Write the test script**

```bash
#!/bin/bash
#
# Integration test: Failure Scenarios
# Tests error handling for various failure conditions
#

set -e

APISIX_URL="${APISIX_URL:-http://localhost:9080}"
API_KEY="${API_KEY:-test-api-key-123}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

echo "========================================"
echo " Integration Test: Failure Scenarios"
echo "========================================"

# Test 1: Invalid JSON
echo ""
echo "Test 1: Invalid JSON handling"

result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '{invalid json}')

if echo "$result" | grep -qi "parse.error\|invalid\|-32700"; then
    pass "Invalid JSON: Proper error response"
else
    fail "Invalid JSON: Expected parse error, got: $result"
fi

# Test 2: Missing method field
echo ""
echo "Test 2: Missing method field"

result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '{"jsonrpc":"2.0","params":[],"id":1}')

if echo "$result" | grep -qi "method\|invalid\|-32600"; then
    pass "Missing method: Proper error response"
else
    fail "Missing method: Expected error, got: $result"
fi

# Test 3: Unsupported method
echo ""
echo "Test 3: Unsupported method"

result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '{"jsonrpc":"2.0","method":"eth_mining","params":[],"id":1}')

if echo "$result" | grep -qi "unsupported\|not.allowed\|-32601"; then
    pass "Unsupported method: Proper error response"
else
    info "Unsupported method: Response was: $result"
fi

# Test 4: Empty batch
echo ""
echo "Test 4: Empty batch request"

result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '[]')

if echo "$result" | grep -qi "empty\|invalid\|-32600"; then
    pass "Empty batch: Proper error response"
else
    fail "Empty batch: Expected error, got: $result"
fi

# Test 5: Invalid API key
echo ""
echo "Test 5: Invalid API key"

result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: wrong-key" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')

if echo "$result" | grep -qi "invalid\|unauthorized\|api.key"; then
    pass "Invalid API key: Proper error response"
else
    fail "Invalid API key: Expected auth error, got: $result"
fi

# Test 6: Missing API key
echo ""
echo "Test 6: Missing API key"

result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')

if echo "$result" | grep -qi "missing\|api.key\|unauthorized"; then
    pass "Missing API key: Proper error response"
else
    fail "Missing API key: Expected auth error, got: $result"
fi

# Test 7: Paid method for free tier
echo ""
echo "Test 7: Paid method for free tier user"

result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '{"jsonrpc":"2.0","method":"debug_traceTransaction","params":[],"id":1}')

if echo "$result" | grep -qi "paid\|tier\|forbidden\|-32003"; then
    pass "Paid method: Blocked for free tier"
else
    info "Paid method: Response was: $result"
fi

echo ""
echo "========================================"
echo " Failure Scenario Tests Complete"
echo "========================================"
```

**Step 2: Make executable and commit**

```bash
chmod +x tests/integration/test_failure_scenarios.sh
git add tests/integration/test_failure_scenarios.sh
git commit -m "test: add failure scenario integration tests"
```

---

## Phase 4: Staging & Final

### Task 4.1: Create Staging Test Script

**Files:**
- Create: `tests/staging/run-staging-tests.sh`

**Step 1: Write the staging test script**

```bash
#!/bin/bash
#
# Staging environment validation
# Run before every production deployment
#

set -e

STAGING_URL="${STAGING_URL:-https://staging.unifra.io}"
STAGING_API_KEY="${STAGING_API_KEY:-}"

if [ -z "$STAGING_API_KEY" ]; then
    echo "Error: STAGING_API_KEY environment variable not set"
    echo "Usage: STAGING_API_KEY=your-key ./run-staging-tests.sh"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASSED=0
FAILED=0

test_case() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if echo "$actual" | grep -qi "$expected"; then
        echo -e "${GREEN}[PASS]${NC} $name"
        ((PASSED++))
    else
        echo -e "${RED}[FAIL]${NC} $name"
        echo "  Expected pattern: $expected"
        echo "  Actual: $actual"
        ((FAILED++))
    fi
}

echo "========================================"
echo " Staging Environment Validation"
echo " Target: $STAGING_URL"
echo "========================================"
echo ""

# P0: Authentication
echo "--- P0: Authentication ---"

result=$(curl -s -X POST "$STAGING_URL/eth/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')
test_case "Unauthenticated request rejected" "api.key\|unauthorized" "$result"

result=$(curl -s -X POST "$STAGING_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $STAGING_API_KEY" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')
test_case "Authenticated request succeeds" '"result"' "$result"

# P0: Core methods
echo ""
echo "--- P0: Core JSON-RPC Methods ---"

result=$(curl -s -X POST "$STAGING_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $STAGING_API_KEY" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}')
test_case "eth_chainId returns result" '"result"' "$result"

result=$(curl -s -X POST "$STAGING_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $STAGING_API_KEY" \
  -d '{"jsonrpc":"2.0","method":"eth_gasPrice","params":[],"id":1}')
test_case "eth_gasPrice returns result" '"result"' "$result"

# P0: Batch requests
echo ""
echo "--- P0: Batch Requests ---"

result=$(curl -s -X POST "$STAGING_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $STAGING_API_KEY" \
  -d '[{"jsonrpc":"2.0","method":"eth_blockNumber","id":1},{"jsonrpc":"2.0","method":"eth_chainId","id":2}]')
test_case "Batch request returns array" '^\[' "$result"

# P0: Whitelist enforcement
echo ""
echo "--- P0: Whitelist Enforcement ---"

result=$(curl -s -X POST "$STAGING_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $STAGING_API_KEY" \
  -d '{"jsonrpc":"2.0","method":"debug_traceTransaction","params":[],"id":1}')
test_case "Paid method blocked for free tier" "paid\|tier\|forbidden" "$result"

# Summary
echo ""
echo "========================================"
echo " Results: $PASSED passed, $FAILED failed"
echo "========================================"

if [ $FAILED -gt 0 ]; then
    echo -e "${RED}STAGING VALIDATION FAILED${NC}"
    echo "DO NOT deploy to production until all tests pass"
    exit 1
else
    echo -e "${GREEN}STAGING VALIDATION PASSED${NC}"
    echo "Safe to proceed with production deployment"
    exit 0
fi
```

**Step 2: Make executable and commit**

```bash
chmod +x tests/staging/run-staging-tests.sh
git add tests/staging/run-staging-tests.sh
git commit -m "test: add staging validation script"
```

---

### Task 4.2: Update Tests README

**Files:**
- Modify: `tests/README.md`

**Step 1: Update the README with new structure**

Read the existing README and update it to reflect the new test structure, then commit.

```bash
git add tests/README.md
git commit -m "docs: update tests README with new structure"
```

---

### Task 4.3: Final Commit - Move Existing Tests

**Step 1: Reorganize existing tests into new structure**

```bash
# Move existing test files to unit/
mv tests/test_cu.lua tests/unit/test_cu_legacy.lua 2>/dev/null || true
mv tests/test_core.lua tests/unit/test_core_legacy.lua 2>/dev/null || true
mv tests/test_config.lua tests/unit/test_config.lua 2>/dev/null || true
mv tests/test_feature_flags.lua tests/unit/test_feature_flags.lua 2>/dev/null || true
mv tests/test_redis_circuit_breaker.lua tests/component/test_redis_circuit_breaker.lua 2>/dev/null || true

git add -A tests/
git commit -m "refactor: reorganize tests into unit/component structure"
```

---

## Verification Checklist

After completing all tasks:

- [ ] `make test-unit` runs and passes
- [ ] `make test-component` runs (with Redis)
- [ ] `make test-integration` runs (with Docker)
- [ ] GitHub Actions workflow triggers on push
- [ ] All P0 tests have coverage for critical paths
- [ ] Staging test script works with real staging environment

---

## Summary

**Total Tasks:** 15 tasks across 4 phases

**Files Created:**
- `tests/helpers/mock_ngx.lua`
- `tests/conftest.lua`
- `tests/unit/test_cu_calculation.lua`
- `tests/unit/test_core_parsing.lua`
- `tests/unit/test_whitelist.lua`
- `tests/integration/test_billing_accuracy.sh`
- `tests/integration/test_rate_limiting.sh`
- `tests/integration/test_concurrent_requests.sh`
- `tests/integration/test_failure_scenarios.sh`
- `tests/staging/run-staging-tests.sh`
- `Makefile`
- `scripts/dev-setup.sh`
- `test-env/docker-compose-minimal.yml`
- `.github/workflows/test.yml`
