#!/bin/bash
#
# P1 Integration Test: Failure Scenarios
# Verifies system behavior under error conditions
#
# Prerequisites:
#   - APISIX running with Unifra plugins
#   - Redis running
#   - Anvil (or other RPC backend) running
#
# Usage: ./test-failures.sh
#

set -uo pipefail

# Configuration - matches test-all.sh setup
APISIX_URL="${APISIX_URL:-http://localhost:9080}"
API_KEY="${1:-test-api-key-123}"
REDIS_DOCKER="${REDIS_DOCKER:-test-env-redis-1}"

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

# Make JSON-RPC request
jsonrpc_call() {
    local body="$1"
    curl -s -X POST "$APISIX_URL/eth/" \
        -H "Content-Type: application/json" \
        -H "apikey: $API_KEY" \
        -d "$body"
}

# Test: Invalid JSON handling
test_invalid_json() {
    ((TESTS_RUN++))
    log_info "Test: Invalid JSON handling"

    local response=$(curl -s -X POST "$APISIX_URL/eth/" \
        -H "Content-Type: application/json" \
        -H "apikey: $API_KEY" \
        -d '{invalid json}')

    if echo "$response" | grep -qi 'parse\|invalid\|error'; then
        log_pass "Invalid JSON returns error response"
    else
        log_fail "Invalid JSON should return error, got: $response"
    fi
}

# Test: Empty body handling
test_empty_body() {
    ((TESTS_RUN++))
    log_info "Test: Empty body handling"

    local response=$(curl -s -X POST "$APISIX_URL/eth/" \
        -H "Content-Type: application/json" \
        -H "apikey: $API_KEY" \
        -d '')

    if echo "$response" | grep -qi 'error\|empty\|body'; then
        log_pass "Empty body returns error response"
    else
        log_fail "Empty body should return error, got: $response"
    fi
}

# Test: Missing method field
test_missing_method() {
    ((TESTS_RUN++))
    log_info "Test: Missing method field"

    local response=$(jsonrpc_call '{"jsonrpc":"2.0","id":1}')

    if echo "$response" | grep -qi 'method\|missing\|error'; then
        log_pass "Missing method returns error"
    else
        log_fail "Missing method should return error, got: $response"
    fi
}

# Test: Invalid method type
test_invalid_method_type() {
    ((TESTS_RUN++))
    log_info "Test: Invalid method type (number instead of string)"

    local response=$(jsonrpc_call '{"jsonrpc":"2.0","method":123,"id":1}')

    if echo "$response" | grep -qi 'invalid\|method\|error'; then
        log_pass "Invalid method type returns error"
    else
        log_fail "Invalid method type should return error, got: $response"
    fi
}

# Test: Empty batch handling
test_empty_batch() {
    ((TESTS_RUN++))
    log_info "Test: Empty batch handling"

    local response=$(jsonrpc_call '[]')

    if echo "$response" | grep -qi 'empty\|batch\|error'; then
        log_pass "Empty batch returns error"
    else
        log_fail "Empty batch should return error, got: $response"
    fi
}

# Test: Large batch handling
test_large_batch() {
    ((TESTS_RUN++))
    log_info "Test: Large batch handling (exceeds limit)"

    # Create batch with 150 requests (should exceed 100 limit)
    local batch="["
    for i in $(seq 1 150); do
        batch="${batch}{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"id\":$i}"
        if [ $i -lt 150 ]; then
            batch="${batch},"
        fi
    done
    batch="${batch}]"

    local response=$(jsonrpc_call "$batch")

    if echo "$response" | grep -qi 'too large\|batch\|limit\|error'; then
        log_pass "Large batch returns error"
    else
        # Check if it was truncated or returned error
        local count=$(echo "$response" | grep -o '"id"' | wc -l | tr -d ' ')
        if [ "$count" -lt 150 ]; then
            log_pass "Large batch handled (truncated or limited)"
        else
            log_fail "Large batch should be rejected, got $count responses"
        fi
    fi
}

# Test: Unknown method handling
test_unknown_method() {
    ((TESTS_RUN++))
    log_info "Test: Unknown/unsupported method"

    local response=$(jsonrpc_call '{"jsonrpc":"2.0","method":"eth_mining","id":1}')

    if echo "$response" | grep -qi 'unsupported\|method\|error'; then
        log_pass "Unknown method returns appropriate error"
    else
        log_fail "Unknown method should return error, got: $response"
    fi
}

# Test: Blocked method for free tier
test_blocked_method() {
    ((TESTS_RUN++))
    log_info "Test: Blocked method for free tier"

    local response=$(jsonrpc_call '{"jsonrpc":"2.0","method":"debug_traceTransaction","params":["0x0"],"id":1}')

    if echo "$response" | grep -qi 'paid\|tier\|blocked\|forbidden\|error'; then
        log_pass "Paid method blocked for free tier"
    else
        log_fail "Paid method should be blocked, got: $response"
    fi
}

# Test: Invalid API key format
test_invalid_api_key_format() {
    ((TESTS_RUN++))
    log_info "Test: Invalid API key format"

    local status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$APISIX_URL/eth/" \
        -H "Content-Type: application/json" \
        -H "apikey: " \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}')

    if [ "$status" == "401" ] || [ "$status" == "403" ]; then
        log_pass "Empty API key rejected with $status"
    else
        log_fail "Empty API key should return 401/403, got $status"
    fi
}

# Test: Very long method name
test_long_method_name() {
    ((TESTS_RUN++))
    log_info "Test: Very long method name"

    local long_method=$(printf 'x%.0s' {1..1000})
    local response=$(jsonrpc_call "{\"jsonrpc\":\"2.0\",\"method\":\"$long_method\",\"id\":1}")

    # Should either reject or return method not found
    if echo "$response" | grep -qi 'error\|unsupported\|method'; then
        log_pass "Long method name handled correctly"
    else
        log_fail "Long method name should return error, got: ${response:0:100}..."
    fi
}

# Test: Request timeout simulation
test_slow_request_handling() {
    ((TESTS_RUN++))
    log_info "Test: Request handling (normal case)"

    # Just verify normal request works
    local start=$(date +%s%N)
    local response=$(jsonrpc_call '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}')
    local end=$(date +%s%N)
    local duration_ms=$(( (end - start) / 1000000 ))

    if echo "$response" | grep -q '"result"' && [ "$duration_ms" -lt 5000 ]; then
        log_pass "Request completed in ${duration_ms}ms"
    else
        log_fail "Request should complete within 5s, took ${duration_ms}ms"
    fi
}

# Test: Graceful error responses
test_error_response_format() {
    ((TESTS_RUN++))
    log_info "Test: Error response is valid JSON-RPC format"

    local response=$(jsonrpc_call '{"jsonrpc":"2.0","method":"invalid_method_xyz","id":1}')

    # Check for JSON-RPC error structure
    if echo "$response" | grep -q '"error"' && echo "$response" | grep -q '"code"'; then
        log_pass "Error response has valid JSON-RPC structure"
    else
        log_fail "Error response should have JSON-RPC structure, got: $response"
    fi
}

# Main test execution
main() {
    echo "================================================"
    echo "P1 Integration Test: Failure Scenarios"
    echo "================================================"
    echo ""
    log_info "APISIX URL: $APISIX_URL"
    log_info "API Key: $API_KEY"
    echo ""

    # Check prerequisites
    if ! curl -s "$APISIX_URL" >/dev/null 2>&1; then
        log_fail "APISIX is not reachable at $APISIX_URL"
        exit 1
    fi

    log_info "Prerequisites OK, starting tests..."
    echo ""

    # Run tests
    test_invalid_json
    test_empty_body
    test_missing_method
    test_invalid_method_type
    test_empty_batch
    test_large_batch
    test_unknown_method
    test_blocked_method
    test_invalid_api_key_format
    test_long_method_name
    test_slow_request_handling
    test_error_response_format

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
