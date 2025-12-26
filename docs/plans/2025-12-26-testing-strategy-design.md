# Unifra APISIX Comprehensive Testing Strategy

**Date**: 2025-12-26
**Status**: Approved
**Goal**: Build production-ready confidence through comprehensive automated testing

## Overview

This document outlines a risk-prioritized testing strategy for the Unifra APISIX JSON-RPC gateway. The strategy covers:
- Local development testing workflow
- CI/CD pipeline automation
- Staging environment validation
- Production deployment checklist

## Risk Assessment & Priority Matrix

### P0 - Critical Path (Must be 100% correct)

1. **Billing Accuracy**
   - CU calculation correctness (unifra-calculate-cu)
   - Monthly quota deduction accuracy (unifra-limit-monthly-cu)
   - Redis script atomicity
   - **Risk**: Errors directly affect revenue

2. **Rate Limiting Accuracy**
   - Per-second CU rate limiting (unifra-limit-cu)
   - Sliding window algorithm correctness
   - **Risk**: Failures may cause resource abuse

3. **Authentication & Access Control**
   - API Key verification (key-auth)
   - Method whitelist enforcement (unifra-whitelist)
   - **Risk**: Security vulnerabilities

### P1 - High Risk Areas (Require thorough testing)

4. **Concurrency & Race Conditions**
   - High-concurrency Redis operations
   - Concurrent quota deductions

5. **Failure Recovery**
   - Redis connection failure/recovery (circuit breaker)
   - Upstream RPC node failures

6. **Edge Cases**
   - Batch request handling
   - Oversized request bodies
   - Month boundary quota reset

### P2 - Secondary Features (Basic validation)

7. **Configuration hot reload**
8. **WebSocket proxy**
9. **Monitoring metrics**

## Test Architecture

```
                    ┌─────────────────┐
                    │  E2E Tests      │  Few, critical scenarios
                    │  (Staging)      │
                    └─────────────────┘
                ┌───────────────────────┐
                │  Integration Tests    │  Medium count, core flows
                │  (Docker + Real Deps) │
                └───────────────────────┘
            ┌─────────────────────────────┐
            │    Component Tests          │  More, module-level
            │    (Mocked Dependencies)    │
            └─────────────────────────────┘
        ┌─────────────────────────────────────┐
        │       Unit Tests (Busted)           │  Many, logic verification
        │       (Pure Lua Logic)              │
        └─────────────────────────────────────┘
```

### Layer Details

| Layer | Tool | Coverage | Speed | Trigger |
|-------|------|----------|-------|---------|
| L1: Unit | Busted | Pure logic functions | <10s | On save |
| L2: Component | Busted + Redis | Single plugin + Redis | ~30s | On commit |
| L3: Integration | Docker Compose | Full request chain | ~2min | PR/CI |
| L4: Load | k6 | Performance & concurrency | ~5min | Master merge |
| L5: Staging | Shell scripts | Pre-production validation | ~3min | Pre-deploy |

## Test Directory Structure

```
tests/
├── README.md
├── conftest.lua                        # Shared test config
│
├── unit/                               # Layer 1: Unit tests
│   ├── test_cu_calculation.lua
│   ├── test_config.lua
│   ├── test_errors.lua
│   ├── test_whitelist.lua
│   ├── test_feature_flags.lua
│   └── test_billing_logic.lua
│
├── component/                          # Layer 2: Component tests
│   ├── test_redis_scripts.lua
│   ├── test_redis_circuit_breaker.lua
│   ├── test_rate_limiting.lua
│   └── test_monthly_quota.lua
│
├── integration/                        # Layer 3: Integration tests
│   ├── test_billing_accuracy.sh
│   ├── test_rate_limiting.sh
│   ├── test_authentication.sh
│   ├── test_batch_requests.sh
│   ├── test_failure_scenarios.sh
│   └── test_concurrent_requests.sh
│
├── load/                               # Layer 4: Load tests
│   ├── billing_accuracy_load.js
│   ├── rate_limit_load.js
│   └── concurrent_quota_load.js
│
├── staging/                            # Staging tests
│   ├── run-staging-tests.sh
│   ├── pre-deploy-checklist.sh
│   └── compare-environments.sh
│
├── fixtures/                           # Test data
│   ├── consumers/
│   ├── routes/
│   ├── requests/
│   └── responses/
│
└── helpers/                            # Test utilities
    ├── mock_ngx.lua
    ├── mock_redis.lua
    ├── assertions.lua
    └── test_utils.lua
```

## P0 Test Cases

### Billing Accuracy Tests

```lua
describe("CU Calculation Accuracy", function()
  it("should calculate correct CU for single request")
  it("should calculate correct CU for batch requests")
  it("should handle unknown methods with default_cu")
  it("should not charge CU for malformed requests")
end)

describe("Monthly Quota Deduction", function()
  it("should deduct exact CU amount")
  it("should accumulate CU across multiple requests")
  it("should reject when quota exhausted")
  it("should handle month boundary correctly")
end)

describe("Redis Script Atomicity", function()
  it("should handle concurrent quota deductions correctly")
  it("should never allow negative quota")
end)
```

### Rate Limiting Tests

```lua
describe("Rate Limiting Accuracy", function()
  it("should enforce per-second CU limit")
  it("should use sliding window correctly")
  it("should handle burst traffic correctly")
end)
```

## P1 Test Cases

### Concurrency Tests

```lua
describe("Concurrent Quota Deduction", function()
  it("should handle race conditions correctly")
  it("should handle concurrent batch requests")
end)
```

### Failure Recovery Tests

```lua
describe("Redis Failure Handling", function()
  it("should open circuit breaker after consecutive failures")
  it("should recover when Redis comes back")
  it("should handle Redis timeout")
end)

describe("Upstream RPC Failure", function()
  it("should handle upstream timeout")
  it("should handle upstream 5xx errors")
end)
```

### Edge Case Tests

```lua
describe("Batch Request Edge Cases", function()
  it("should handle empty batch")
  it("should handle oversized batch")
  it("should handle mixed valid/invalid methods")
  it("should handle partial quota in batch")
end)

describe("Time Boundary Edge Cases", function()
  it("should handle month rollover correctly")
  it("should handle leap year correctly")
  it("should use UTC for all quota calculations")
end)
```

## Local Development Setup

### One-Command Setup

```bash
./scripts/dev-setup.sh
```

### Makefile Commands

```makefile
make test-unit          # Run unit tests
make test-component     # Run component tests (with Redis)
make test-integration   # Run integration tests (full stack)
make test-load          # Run load tests
make test-all           # Run all tests
make test-coverage      # Run with coverage
make test-watch         # Watch mode
```

## CI/CD Pipeline

### GitHub Actions Workflow

```yaml
jobs:
  unit-tests:        # Stage 1: Fast feedback
  component-tests:   # Stage 2: With Redis
  integration-tests: # Stage 3: Full stack
  load-tests:        # Stage 4: On master only
```

### Required Checks for PR

- Unit Tests (must pass)
- Component Tests (must pass)
- Integration Tests (must pass)

## Staging Environment Testing

### Pre-Deploy Validation

```bash
./tests/staging/run-staging-tests.sh
```

Tests:
- Authentication flow
- Billing accuracy verification
- Rate limiting validation
- Whitelist enforcement

### Deployment Checklist

```bash
./tests/staging/pre-deploy-checklist.sh
```

Checks:
- All tests pass
- No uncommitted changes
- Branch up to date
- Staging validation passed

## Implementation Roadmap

### Phase 1: Infrastructure (Day 1-2)
- Create directory structure
- Set up Makefile
- Configure CI/CD pipeline
- Verify local environment

### Phase 2: P0 Critical Tests (Day 3-5)
- CU calculation accuracy tests
- Monthly quota deduction tests
- Redis script atomicity tests
- Rate limiting accuracy tests

### Phase 3: P1 High-Risk Tests (Day 6-8)
- Concurrency tests
- Failure recovery tests
- Edge case tests
- Load tests

### Phase 4: Integration & Acceptance (Day 9-10)
- Staging test scripts
- Pre-deploy checklist
- Documentation
- Team training

## Success Criteria

Before production deployment:

- [ ] All P0 tests pass
- [ ] All P1 tests pass
- [ ] Billing accuracy: 100% accurate (zero tolerance)
- [ ] Rate limiting accuracy: <5% variance
- [ ] Concurrency tests: No data races
- [ ] CI pipeline green
- [ ] Staging validation passed

## Files to Create

```
New/Modified files:
├── Makefile
├── scripts/dev-setup.sh
├── tests/conftest.lua
├── tests/unit/*.lua (6 files)
├── tests/component/*.lua (4 files)
├── tests/integration/*.sh (6 files)
├── tests/load/*.js (3 files)
├── tests/staging/*.sh (3 files)
├── tests/fixtures/**/*.json
├── tests/helpers/*.lua (4 files)
├── test-env/docker-compose-minimal.yml
├── test-env/scripts/*.sh (2 files)
└── .github/workflows/*.yml (2 files)
```

## Appendix: Key Decisions

1. **Risk-based prioritization**: Focus testing effort on revenue-critical paths
2. **Four-layer test pyramid**: Balance speed and coverage
3. **Billing accuracy zero tolerance**: Any billing error is unacceptable
4. **CI/CD gating**: PRs cannot merge without passing tests
5. **Staging validation**: Manual pre-deploy checks automated
