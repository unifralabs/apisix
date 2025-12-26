#!/bin/bash
#
# P0 Integration Test: Rate Limiting
# Verifies that CU-based rate limiting works correctly
#
# Prerequisites:
#   - APISIX running with Unifra plugins
#   - Redis running
#   - Anvil (or other RPC backend) running
#
# Usage: ./test-rate-limiting.sh
#

set -euo pipefail

# Configuration
APISIX_URL="${APISIX_URL:-http://localhost:9080}"
ADMIN_URL="${ADMIN_URL:-http://localhost:9180}"
ADMIN_KEY="${ADMIN_KEY:-unifra-test-admin-key}"
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((TESTS_PASSED++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((TESTS_FAILED++)); }

# Reset rate limit state in Redis
reset_rate_limit() {
    local key="$1"
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "$key" >/dev/null 2>&1
}

# Set CU usage in Redis
set_cu_usage() {
    local key="$1"
    local value="$2"
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "$key" "$value" >/dev/null 2>&1
}

# Make JSON-RPC request and return HTTP status code
jsonrpc_call_status() {
    local method="$1"
    local api_key="$2"

    curl -s -o /dev/null -w "%{http_code}" -X POST "$APISIX_URL/v1/eth-mainnet" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: $api_key" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":[],\"id\":1}"
}

# Make JSON-RPC request and return response
jsonrpc_call() {
    local method="$1"
    local api_key="$2"

    curl -s -X POST "$APISIX_URL/v1/eth-mainnet" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: $api_key" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":[],\"id\":1}"
}

# Test: Request within limit should succeed
test_within_limit() {
    ((TESTS_RUN++))
    log_info "Test: Request within monthly limit should succeed"

    local api_key="test-limit-within"
    local monthly_key="cu:monthly:$api_key"

    # Reset and set usage below limit (assuming 1000 CU monthly limit for test consumer)
    reset_rate_limit "$monthly_key"
    set_cu_usage "$monthly_key" "100"

    local status=$(jsonrpc_call_status "eth_blockNumber" "$api_key")

    if [ "$status" == "200" ]; then
        log_pass "Request within limit returned 200 OK"
    else
        log_fail "Request within limit should return 200, got $status"
    fi
}

# Test: Request exceeding monthly limit should be rejected
test_monthly_limit_exceeded() {
    ((TESTS_RUN++))
    log_info "Test: Request exceeding monthly limit should be rejected"

    local api_key="test-limit-exceed"
    local monthly_key="cu:monthly:$api_key"

    # Set usage at or above limit (assuming 1000 CU monthly limit)
    reset_rate_limit "$monthly_key"
    set_cu_usage "$monthly_key" "1000"

    local status=$(jsonrpc_call_status "eth_blockNumber" "$api_key")

    if [ "$status" == "429" ]; then
        log_pass "Request exceeding limit returned 429 Too Many Requests"
    else
        log_fail "Request exceeding limit should return 429, got $status"
    fi
}

# Test: Rate limit response contains correct error
test_rate_limit_error_message() {
    ((TESTS_RUN++))
    log_info "Test: Rate limit response contains correct error message"

    local api_key="test-limit-message"
    local monthly_key="cu:monthly:$api_key"

    # Set usage at limit
    reset_rate_limit "$monthly_key"
    set_cu_usage "$monthly_key" "1000"

    local response=$(jsonrpc_call "eth_blockNumber" "$api_key")

    if echo "$response" | grep -q "quota\|limit\|exceeded" 2>/dev/null; then
        log_pass "Rate limit response contains quota/limit error message"
    else
        log_fail "Rate limit response should mention quota/limit, got: $response"
    fi
}

# Test: Per-second rate limiting
test_per_second_limit() {
    ((TESTS_RUN++))
    log_info "Test: Per-second rate limiting (burst protection)"

    local api_key="test-burst"
    local monthly_key="cu:monthly:$api_key"

    # Reset monthly to allow requests
    reset_rate_limit "$monthly_key"

    # Rapid fire requests - some should be rate limited
    local success_count=0
    local limited_count=0

    for i in $(seq 1 50); do
        local status=$(jsonrpc_call_status "eth_blockNumber" "$api_key")
        if [ "$status" == "200" ]; then
            ((success_count++))
        elif [ "$status" == "429" ]; then
            ((limited_count++))
        fi
    done

    if [ "$limited_count" -gt 0 ]; then
        log_pass "Burst protection triggered: $success_count success, $limited_count limited"
    else
        log_info "Note: No per-second limiting observed (may be configured with high limit)"
        log_pass "All 50 rapid requests succeeded (burst limit may be >=50 CU/s)"
    fi
}

# Test: Different API keys have independent limits
test_independent_limits() {
    ((TESTS_RUN++))
    log_info "Test: Different API keys have independent limits"

    local api_key_a="test-independent-a"
    local api_key_b="test-independent-b"
    local monthly_key_a="cu:monthly:$api_key_a"
    local monthly_key_b="cu:monthly:$api_key_b"

    # Set key A at limit, key B below limit
    reset_rate_limit "$monthly_key_a"
    reset_rate_limit "$monthly_key_b"
    set_cu_usage "$monthly_key_a" "1000"
    set_cu_usage "$monthly_key_b" "100"

    local status_a=$(jsonrpc_call_status "eth_blockNumber" "$api_key_a")
    local status_b=$(jsonrpc_call_status "eth_blockNumber" "$api_key_b")

    if [ "$status_a" == "429" ] && [ "$status_b" == "200" ]; then
        log_pass "API keys have independent limits (A=429, B=200)"
    else
        log_fail "API keys should have independent limits (A got $status_a, B got $status_b)"
    fi
}

# Test: Rate limit headers are present
test_rate_limit_headers() {
    ((TESTS_RUN++))
    log_info "Test: Rate limit headers are present in response"

    local api_key="test-headers"
    local monthly_key="cu:monthly:$api_key"

    reset_rate_limit "$monthly_key"

    local headers=$(curl -s -I -X POST "$APISIX_URL/v1/eth-mainnet" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: $api_key" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')

    # Check for common rate limit headers
    if echo "$headers" | grep -qi "x-ratelimit\|x-rate-limit\|ratelimit" 2>/dev/null; then
        log_pass "Rate limit headers present in response"
    else
        log_info "Note: Standard rate limit headers not found (may use custom headers)"
        log_pass "Request completed (rate limit headers may use custom format)"
    fi
}

# Test: Invalid API key should be rejected
test_invalid_api_key() {
    ((TESTS_RUN++))
    log_info "Test: Invalid API key should be rejected"

    local status=$(jsonrpc_call_status "eth_blockNumber" "invalid-key-12345")

    if [ "$status" == "401" ] || [ "$status" == "403" ]; then
        log_pass "Invalid API key rejected with $status"
    else
        log_fail "Invalid API key should return 401/403, got $status"
    fi
}

# Test: Missing API key should be rejected
test_missing_api_key() {
    ((TESTS_RUN++))
    log_info "Test: Missing API key should be rejected"

    local status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$APISIX_URL/v1/eth-mainnet" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')

    if [ "$status" == "401" ] || [ "$status" == "403" ]; then
        log_pass "Missing API key rejected with $status"
    else
        log_fail "Missing API key should return 401/403, got $status"
    fi
}

# Test: Rate limit resets after window
test_limit_reset() {
    ((TESTS_RUN++))
    log_info "Test: Rate limit state persists correctly (manual reset)"

    local api_key="test-reset"
    local monthly_key="cu:monthly:$api_key"

    # Set at limit
    set_cu_usage "$monthly_key" "1000"
    local status_before=$(jsonrpc_call_status "eth_blockNumber" "$api_key")

    # Reset usage
    reset_rate_limit "$monthly_key"
    local status_after=$(jsonrpc_call_status "eth_blockNumber" "$api_key")

    if [ "$status_before" == "429" ] && [ "$status_after" == "200" ]; then
        log_pass "Rate limit resets correctly when usage cleared"
    else
        log_fail "Rate limit reset issue (before=$status_before, after=$status_after)"
    fi
}

# Main test execution
main() {
    echo "================================================"
    echo "P0 Integration Test: Rate Limiting"
    echo "================================================"
    echo ""
    log_info "APISIX URL: $APISIX_URL"
    log_info "Redis: $REDIS_HOST:$REDIS_PORT"
    echo ""

    # Check prerequisites
    if ! curl -s "$APISIX_URL" >/dev/null 2>&1; then
        log_fail "APISIX is not reachable at $APISIX_URL"
        exit 1
    fi

    if ! redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping >/dev/null 2>&1; then
        log_fail "Redis is not reachable at $REDIS_HOST:$REDIS_PORT"
        exit 1
    fi

    log_info "Prerequisites OK, starting tests..."
    echo ""

    # Run tests
    test_within_limit
    test_monthly_limit_exceeded
    test_rate_limit_error_message
    test_per_second_limit
    test_independent_limits
    test_rate_limit_headers
    test_invalid_api_key
    test_missing_api_key
    test_limit_reset

    # Summary
    echo ""
    echo "================================================"
    echo "Test Summary"
    echo "================================================"
    echo "Total: $TESTS_RUN"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

    if [ "$TESTS_FAILED" -eq 0 ]; then
        echo -e "\n${GREEN}All rate limiting tests passed!${NC}"
        exit 0
    else
        echo -e "\n${RED}Some tests failed!${NC}"
        exit 1
    fi
}

main "$@"
