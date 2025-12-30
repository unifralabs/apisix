# Unifra APISIX Test Suite

This directory contains tests for the Unifra APISIX plugins and modules, organized by dependency layer.

## Test Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                       Test Pyramid                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│                          ┌─────┐                                │
│                         /  E2E  \        ~3 min                 │
│                        /─────────\       Full stack             │
│                       /           \      test-env/              │
│                      /─────────────\                            │
│                     /  Integration  \    ~1 min                 │
│                    /─────────────────\   OpenResty (resty)      │
│                   /                   \  tests/integration/     │
│                  /─────────────────────\                        │
│                 /         Unit          \  ~10 sec              │
│                /─────────────────────────\ busted + mocks       │
│               /                           \ tests/unit/         │
│              /─────────────────────────────\                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
tests/
├── unit/                           # Layer 0: busted + mocks (no external deps)
│   ├── test_core_parsing.lua       # JSON-RPC parsing
│   ├── test_whitelist.lua          # Whitelist access control
│   ├── test_cu_calculation.lua     # CU calculation
│   ├── test_config.lua             # Config management
│   ├── test_circuit_breaker.lua    # Redis circuit breaker
│   └── test_key_extraction.lua     # API key URL extraction
│
├── integration/                    # Layer 1: OpenResty runtime (resty)
│   ├── test_jsonrpc_core.lua       # JSON-RPC core with cjson
│   ├── test_cu.lua                 # CU module
│   └── test_compression.lua        # gzip compression
│
├── e2e/                            # Layer 2: placeholder
│   └── (e2e tests are in test-env/)
│
├── conftest.lua                    # Shared test configuration
├── fixtures/                       # Test data
└── helpers/                        # Test utilities

test-env/                           # E2E: Full stack tests
├── docker-compose.yml              # APISIX + etcd + Redis
├── test-all.sh                     # Main E2E test script
├── test-billing.sh
├── test-rate-limiting.sh
└── ...
```

## Running Tests

### Layer 0: Unit Tests (busted)

```bash
# Install dependencies
luarocks install busted luafilesystem lua-cjson

# Run all unit tests
cd tests && busted unit/ --verbose

# Run specific test
busted unit/test_config.lua
```

### Layer 1: Integration Tests (OpenResty)

```bash
# Using APISIX container
docker run --rm \
  -v $(pwd):/opt/unifra-apisix \
  -w /opt/unifra-apisix \
  apache/apisix:3.14.0-debian \
  bash -c 'cd tests/integration && for f in test_*.lua; do resty "$f"; done'

# Or locally with OpenResty
cd tests/integration
resty test_jsonrpc_core.lua
resty test_compression.lua
```

### Layer 2: E2E Tests (Full Stack)

```bash
# Start test environment
cd test-env
docker-compose up -d

# Start Anvil (blockchain mock)
anvil --host 0.0.0.0 --port 8545 &

# Run E2E tests
./test-all.sh
```

## CI Pipeline

The GitHub Actions workflow runs tests in stages:

| Stage | Name | Dependencies | Duration |
|-------|------|--------------|----------|
| 1 | Unit Tests | busted + mocks | ~10s |
| 2 | Integration Tests | OpenResty (Docker) | ~1m |
| 3 | E2E Tests | Full stack | ~3m |

Each stage depends on the previous one passing.

## Writing Tests

### Unit Test (busted + mocks)

```lua
-- tests/unit/test_my_module.lua

describe("my_module", function()
    local my_module

    setup(function()
        -- Mock ngx
        _G.ngx = {
            log = function() end,
            INFO = 1, WARN = 2, ERR = 3,
        }
        my_module = require("unifra.jsonrpc.my_module")
    end)

    teardown(function()
        package.loaded["unifra.jsonrpc.my_module"] = nil
    end)

    it("should calculate correctly", function()
        local result = my_module.calculate(10)
        assert.equals(100, result)
    end)
end)
```

### Integration Test (resty)

```lua
#!/usr/bin/env resty
-- tests/integration/test_my_feature.lua

local install_path = os.getenv("UNIFRA_PATH") or "/opt/unifra-apisix"
package.path = install_path .. "/?.lua;" .. package.path

local my_module = require("unifra.jsonrpc.my_module")

local function test(name, fn)
    local ok, err = pcall(fn)
    print(ok and "[PASS] " or "[FAIL] ", name, err or "")
end

test("real cjson encoding", function()
    local result = my_module.encode({foo = "bar"})
    assert(result == '{"foo":"bar"}')
end)

print("All tests completed")
```

## Test Coverage by Module

| Module | Unit | Integration | E2E |
|--------|------|-------------|-----|
| unifra/jsonrpc/core.lua | ✅ | ✅ | ✅ |
| unifra/jsonrpc/whitelist.lua | ✅ | - | ✅ |
| unifra/jsonrpc/cu.lua | ✅ | ✅ | ✅ |
| unifra/jsonrpc/config.lua | ✅ | - | - |
| unifra/compression.lua | - | ✅ | - |
| unifra/jsonrpc/redis_circuit_breaker.lua | ✅ | - | - |
| apisix/plugins/* | - | - | ✅ |

## Best Practices

1. **Write unit tests for pure logic** - JSON parsing, calculations, validation
2. **Use integration tests for runtime deps** - ffi-zlib, cjson encoding
3. **Use E2E for plugin chain** - Full request flow through APISIX
4. **Mock only what's necessary** - Prefer real implementations when possible
5. **Test edge cases** - Empty inputs, invalid data, boundary conditions
