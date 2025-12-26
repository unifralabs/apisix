# Unifra APISIX Test Suite

This directory contains unit and integration tests for the Unifra APISIX plugins and modules.

## Test Structure

```
tests/
├── README.md                          # This file
├── test_feature_flags.lua             # Feature flag system tests
├── test_redis_circuit_breaker.lua     # Circuit breaker pattern tests
├── test_config.lua                    # Config management tests
└── integration/                       # (Future) Integration tests
    ├── test_rate_limiting.lua
    ├── test_monthly_quota.lua
    └── test_websocket_proxy.lua
```

## Prerequisites

### Install Busted (Lua Testing Framework)

```bash
# Using LuaRocks
luarocks install busted

# Or via system package manager
# Ubuntu/Debian
apt-get install lua-busted

# macOS
brew install lua
luarocks install busted
```

### Install Dependencies

```bash
# Install required Lua modules
luarocks install luafilesystem
luarocks install lua-cjson
luarocks install tinyyaml  # For YAML parsing
```

## Running Tests

### Run All Tests

```bash
# From project root
busted tests/

# With verbose output
busted --verbose tests/

# With coverage
busted --coverage tests/
```

### Run Specific Test File

```bash
busted tests/test_feature_flags.lua
busted tests/test_redis_circuit_breaker.lua
busted tests/test_config.lua
```

### Run with Pattern Matching

```bash
# Run only tests matching "circuit breaker"
busted --filter="circuit breaker" tests/

# Run only tests matching "cache"
busted --filter="cache" tests/
```

## Test Coverage

### Core Modules Tested

1. **Feature Flags** (`unifra/feature_flags.lua`)
   - Global/route/consumer level configuration
   - Percentage-based rollout
   - Priority resolution

2. **Redis Circuit Breaker** (`unifra/jsonrpc/redis_circuit_breaker.lua`)
   - State transitions (CLOSED → OPEN → HALF_OPEN)
   - Failure threshold detection
   - Fail-open/fail-closed strategies
   - Health check recovery

3. **Config Management** (`unifra/jsonrpc/config.lua`)
   - Per-route caching
   - TTL-based refresh
   - YAML file loading
   - Error handling

### Modules Requiring Integration Tests

The following modules require real dependencies and should be tested with integration tests:

1. **Redis Scripts** (`unifra/jsonrpc/redis_scripts.lua`)
   - Requires real Redis instance
   - Test sliding window algorithm
   - Test monthly quota script
   - Test atomic operations

2. **Billing Module** (`unifra/jsonrpc/billing.lua`)
   - Requires Redis + control plane mock
   - Test cycle management
   - Test quota enforcement

3. **Rate Limiting Plugin** (`apisix/plugins/unifra-limit-cu.lua`)
   - Requires Redis instance
   - Test sliding window vs fixed window
   - Test concurrent requests
   - Test circuit breaker integration

4. **WebSocket Proxy** (`apisix/plugins/unifra-ws-jsonrpc-proxy.lua`)
   - Requires real WebSocket server
   - Test case-insensitive upgrade
   - Test SSL verification
   - Test config hot reload

## Writing New Tests

### Unit Test Template

```lua
--
-- Unit tests for my_module.lua
--

describe("my_module", function()
    local my_module

    setup(function()
        -- Mock dependencies
        _G.ngx = {
            log = function() end,
            INFO = 1,
            WARN = 2,
            ERR = 3,
        }

        my_module = require("path.to.my_module")
    end)

    teardown(function()
        package.loaded["path.to.my_module"] = nil
    end)

    before_each(function()
        -- Reset state before each test
    end)

    describe("feature name", function()
        it("should do something", function()
            local result = my_module.do_something()
            assert.is_true(result)
        end)

        it("should handle errors", function()
            local result, err = my_module.do_something_risky()
            assert.is_nil(result)
            assert.is_not_nil(err)
        end)
    end)
end)
```

### Integration Test Template

```lua
--
-- Integration tests for my_feature
--

describe("my_feature integration", function()
    local redis
    local apisix_client

    setup(function()
        -- Connect to real services
        redis = connect_to_test_redis()
        apisix_client = create_apisix_client()
    end)

    teardown(function()
        -- Cleanup
        redis:close()
    end)

    before_each(function()
        -- Clear test data
        redis:flushdb()
    end)

    it("should process request end-to-end", function()
        local response = apisix_client:post("/v1/test", {
            jsonrpc = "2.0",
            method = "eth_blockNumber",
            id = 1
        })

        assert.equals(200, response.status)
        assert.is_not_nil(response.body)
    end)
end)
```

## Integration Test Setup

### 1. Start Test Redis

```bash
# Using Docker
docker run -d --name test-redis -p 6380:6379 redis:7

# Configure plugins to use test Redis
export REDIS_HOST=127.0.0.1
export REDIS_PORT=6380
```

### 2. Start Test APISIX Instance

```bash
# Copy test configuration
cp conf/config-test.yaml conf/config.yaml

# Start APISIX in test mode
make run
```

### 3. Run Integration Tests

```bash
# Set test environment
export TEST_MODE=integration
export APISIX_URL=http://127.0.0.1:9080

# Run tests
busted tests/integration/
```

## Continuous Integration

### GitHub Actions Example

```yaml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      redis:
        image: redis:7
        ports:
          - 6379:6379

    steps:
      - uses: actions/checkout@v3

      - name: Install Lua
        run: |
          sudo apt-get update
          sudo apt-get install -y lua5.1 luarocks

      - name: Install dependencies
        run: |
          sudo luarocks install busted
          sudo luarocks install luafilesystem
          sudo luarocks install lua-cjson

      - name: Run unit tests
        run: busted tests/

      - name: Run integration tests
        run: |
          export REDIS_HOST=127.0.0.1
          busted tests/integration/
```

## Test Best Practices

1. **Isolate Tests**: Each test should be independent
2. **Mock External Dependencies**: Use mocks for Redis, HTTP clients, etc. in unit tests
3. **Clean Up**: Always clean up test data in `teardown()` or `after_each()`
4. **Use Descriptive Names**: Test names should clearly describe what is being tested
5. **Test Edge Cases**: Include tests for error conditions, boundary values, etc.
6. **Avoid Timing Dependencies**: Don't rely on `sleep()` or real time passing

## Debugging Tests

### Enable Verbose Logging

```bash
# Show all output including print statements
busted --verbose tests/

# Show only failed tests
busted --output=junit tests/ > test-results.xml
```

### Run Single Test

```bash
# Run only one specific test
busted tests/test_feature_flags.lua --filter="should return false when flag not configured"
```

### Interactive Debugging

```lua
-- Add breakpoint in test
it("should debug", function()
    local value = my_module.calculate()
    print("DEBUG: value=" .. tostring(value))  -- Will show in verbose mode
    assert.is_not_nil(value)
end)
```

## Known Issues

1. **Module Caching**: Lua caches modules, so you may need to use `package.loaded[module] = nil` to reload
2. **Global State**: Some APISIX modules use global state, which can interfere between tests
3. **Async Operations**: ngx.timer and ngx.thread operations are hard to test without real OpenResty

## Future Work

- [ ] Add integration tests for all plugins
- [ ] Set up CI/CD pipeline
- [ ] Add load tests for rate limiting
- [ ] Add chaos tests for circuit breaker
- [ ] Implement test coverage reporting
- [ ] Create performance benchmarks

## Contributing

When adding new features:

1. Write unit tests first (TDD approach recommended)
2. Ensure all tests pass before submitting PR
3. Add integration tests for features requiring external services
4. Update this README with any new test requirements

## Resources

- [Busted Documentation](https://olivinelabs.com/busted/)
- [Lua Testing Best Practices](http://lua-users.org/wiki/UnitTesting)
- [APISIX Testing Guide](https://apisix.apache.org/docs/apisix/how-to-guide/test)
