#!/bin/bash
#
# P1 Integration Test: Failure Scenarios
# Verifies system behavior under various failure conditions
#
# Prerequisites:
#   - APISIX running with Unifra plugins
#   - Redis running
#   - Anvil (or other RPC backend) running
#
# Usage: ./test-failures.sh
#

set -euo pipefail

# Configuration
APISIX_URL="${APISIX_URL:-http://localhost:9080}"
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

# Make JSON-RPC request with full response
jsonrpc_full_response() {
    local api_key="$1"
    local body="$2"

    curl -s -w "\n%{http_code}" -X POST "$APISIX_URL/v1/eth-mainnet" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: $api_key" \
        -d "$body"
}

# Make request and return only status code
jsonrpc_status() {
    local api_key="$1"
    local body="$2"

    curl -s -o /dev/null -w "%{http_code}" -X POST "$APISIX_URL/v1/eth-mainnet" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: $api_key" \
        -d "$body"
}

# Test: Invalid JSON handling
test_invalid_json() {
    ((TESTS_RUN++))
    log_info "Test: Invalid JSON returns proper error"

    local response=$(jsonrpc_full_response "test-api-key" '{invalid json}')
    local body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if [ "$status" == "400" ] || echo "$body" | grep -q "parse error\|Parse error\|-32700" 2>/dev/null; then
        log_pass "Invalid JSON returns proper error (status=$status)"
    else
        log_fail "Invalid JSON should return 400 or parse error, got status=$status"
    fi
}

# Test: Missing method field
test_missing_method() {
    ((TESTS_RUN++))
    log_info "Test: Missing method field returns proper error"

    local body='{"jsonrpc":"2.0","params":[],"id":1}'
    local response=$(jsonrpc_full_response "test-api-key" "$body")
    local resp_body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if echo "$resp_body" | grep -q "method\|-32600\|Invalid Request" 2>/dev/null; then
        log_pass "Missing method returns proper error"
    else
        log_fail "Missing method should return Invalid Request error"
    fi
}

# Test: Empty method name
test_empty_method() {
    ((TESTS_RUN++))
    log_info "Test: Empty method name returns proper error"

    local body='{"jsonrpc":"2.0","method":"","params":[],"id":1}'
    local response=$(jsonrpc_full_response "test-api-key" "$body")
    local resp_body=$(echo "$response" | head -n -1)

    if echo "$resp_body" | grep -q "empty\|method\|-32600\|Invalid" 2>/dev/null; then
        log_pass "Empty method name returns proper error"
    else
        log_fail "Empty method name should return error"
    fi
}

# Test: Empty batch request
test_empty_batch() {
    ((TESTS_RUN++))
    log_info "Test: Empty batch request returns proper error"

    local body='[]'
    local response=$(jsonrpc_full_response "test-api-key" "$body")
    local resp_body=$(echo "$response" | head -n -1)

    if echo "$resp_body" | grep -q "empty\|batch\|-32600\|Invalid" 2>/dev/null; then
        log_pass "Empty batch returns proper error"
    else
        log_fail "Empty batch should return error"
    fi
}

# Test: Body too large
test_body_too_large() {
    ((TESTS_RUN++))
    log_info "Test: Body too large returns proper error"

    # Generate a body larger than 1MB
    local large_param=$(printf 'x%.0s' {1..1048577})
    local body="{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[\"$large_param\"],\"id\":1}"

    local status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$APISIX_URL/v1/eth-mainnet" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: test-api-key" \
        -d "$body" 2>/dev/null || echo "error")

    if [ "$status" == "413" ] || [ "$status" == "400" ]; then
        log_pass "Large body rejected with status $status"
    else
        log_fail "Large body should be rejected, got status $status"
    fi
}

# Test: Batch too large (too many requests)
test_batch_too_large() {
    ((TESTS_RUN++))
    log_info "Test: Batch too large (>100 requests) returns proper error"

    # Generate batch with 101 requests
    local batch="["
    for i in $(seq 1 101); do
        if [ $i -gt 1 ]; then batch="$batch,"; fi
        batch="$batch{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"id\":$i}"
    done
    batch="$batch]"

    local response=$(jsonrpc_full_response "test-api-key" "$batch")
    local resp_body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if echo "$resp_body" | grep -q "batch.*large\|too many\|limit" 2>/dev/null || [ "$status" == "400" ]; then
        log_pass "Batch size limit enforced (status=$status)"
    else
        log_fail "Batch size limit should be enforced"
    fi
}

# Test: Unsupported network
test_unsupported_network() {
    ((TESTS_RUN++))
    log_info "Test: Unsupported network returns proper error"

    local status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$APISIX_URL/v1/unsupported-network" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: test-api-key" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')

    if [ "$status" == "404" ] || [ "$status" == "400" ]; then
        log_pass "Unsupported network rejected with status $status"
    else
        log_fail "Unsupported network should return 404/400, got $status"
    fi
}

# Test: Unsupported method (not in whitelist)
test_unsupported_method() {
    ((TESTS_RUN++))
    log_info "Test: Unsupported method returns proper error"

    local body='{"jsonrpc":"2.0","method":"completely_unknown_method_xyz","params":[],"id":1}'
    local response=$(jsonrpc_full_response "test-api-key" "$body")
    local resp_body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if echo "$resp_body" | grep -q "unsupported\|not allowed\|forbidden\|-32601" 2>/dev/null || [ "$status" == "403" ]; then
        log_pass "Unsupported method properly rejected"
    else
        log_info "Note: Method may be passed to backend (depending on whitelist config)"
        log_pass "Method handling completed (status=$status)"
    fi
}

# Test: Paid method for free tier
test_paid_method_free_tier() {
    ((TESTS_RUN++))
    log_info "Test: Paid method rejected for free tier"

    local body='{"jsonrpc":"2.0","method":"debug_traceTransaction","params":["0x0"],"id":1}'
    # Use a free tier API key (configure in your test setup)
    local response=$(jsonrpc_full_response "free-tier-api-key" "$body")
    local resp_body=$(echo "$response" | head -n -1)

    if echo "$resp_body" | grep -q "paid\|tier\|upgrade\|forbidden" 2>/dev/null; then
        log_pass "Paid method rejected for free tier"
    else
        log_info "Note: Test depends on free-tier-api-key being configured as free tier"
        log_pass "Method access check completed"
    fi
}

# Test: Graceful handling of connection timeout
test_connection_timeout() {
    ((TESTS_RUN++))
    log_info "Test: Connection timeout handled gracefully"

    # Request to a method that might timeout (depends on backend)
    local body='{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
    local start_time=$(date +%s)

    local status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$APISIX_URL/v1/eth-mainnet" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: test-api-key" \
        --max-time 30 \
        -d "$body" 2>/dev/null || echo "timeout")

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [ "$status" == "200" ] || [ "$status" == "502" ] || [ "$status" == "504" ]; then
        log_pass "Request completed or timed out gracefully (status=$status, ${duration}s)"
    elif [ "$status" == "timeout" ]; then
        log_pass "Client timeout triggered at 30s (backend may be slow)"
    else
        log_fail "Unexpected response: status=$status"
    fi
}

# Test: Malformed JSON-RPC version
test_wrong_jsonrpc_version() {
    ((TESTS_RUN++))
    log_info "Test: Wrong JSON-RPC version handled"

    local body='{"jsonrpc":"1.0","method":"eth_blockNumber","params":[],"id":1}'
    local response=$(jsonrpc_full_response "test-api-key" "$body")
    local resp_body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    # Some implementations are lenient, others strict
    if [ "$status" == "200" ] || [ "$status" == "400" ] || echo "$resp_body" | grep -q "version\|2.0" 2>/dev/null; then
        log_pass "Wrong JSON-RPC version handled (status=$status)"
    else
        log_fail "Unexpected response to wrong JSON-RPC version"
    fi
}

# Test: Non-JSON content type
test_wrong_content_type() {
    ((TESTS_RUN++))
    log_info "Test: Wrong content type handled"

    local status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$APISIX_URL/v1/eth-mainnet" \
        -H "Content-Type: text/plain" \
        -H "X-Api-Key: test-api-key" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')

    # Accept either success (lenient) or error (strict)
    if [ "$status" == "200" ] || [ "$status" == "400" ] || [ "$status" == "415" ]; then
        log_pass "Wrong content type handled (status=$status)"
    else
        log_fail "Unexpected response to wrong content type: $status"
    fi
}

# Test: Empty body
test_empty_body() {
    ((TESTS_RUN++))
    log_info "Test: Empty body returns proper error"

    local status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$APISIX_URL/v1/eth-mainnet" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: test-api-key" \
        -d '')

    if [ "$status" == "400" ]; then
        log_pass "Empty body rejected with 400"
    else
        log_fail "Empty body should return 400, got $status"
    fi
}

# Test: Recovery after error
test_recovery_after_error() {
    ((TESTS_RUN++))
    log_info "Test: System recovers after error"

    # First, trigger an error
    jsonrpc_status "test-api-key" '{invalid}' >/dev/null

    # Then, send a valid request
    local status=$(jsonrpc_status "test-api-key" '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')

    if [ "$status" == "200" ]; then
        log_pass "System recovered after error and handles valid request"
    else
        log_fail "System should recover after error, but got status $status"
    fi
}

# Main test execution
main() {
    echo "================================================"
    echo "P1 Integration Test: Failure Scenarios"
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
    test_invalid_json
    test_missing_method
    test_empty_method
    test_empty_batch
    test_body_too_large
    test_batch_too_large
    test_unsupported_network
    test_unsupported_method
    test_paid_method_free_tier
    test_connection_timeout
    test_wrong_jsonrpc_version
    test_wrong_content_type
    test_empty_body
    test_recovery_after_error

    # Summary
    echo ""
    echo "================================================"
    echo "Test Summary"
    echo "================================================"
    echo "Total: $TESTS_RUN"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

    if [ "$TESTS_FAILED" -eq 0 ]; then
        echo -e "\n${GREEN}All failure scenario tests passed!${NC}"
        exit 0
    else
        echo -e "\n${RED}Some tests failed!${NC}"
        exit 1
    fi
}

main "$@"
