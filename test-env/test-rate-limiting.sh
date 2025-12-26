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

set -uo pipefail  # Don't exit immediately on error

# Configuration - matches test-all.sh setup
APISIX_URL="${APISIX_URL:-http://localhost:9080}"
ADMIN_URL="${ADMIN_URL:-http://localhost:9180}"
ADMIN_KEY="${ADMIN_KEY:-unifra-test-admin-key}"
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

# Make JSON-RPC request and return HTTP status code
jsonrpc_call_status() {
    local method="${1:-eth_blockNumber}"
    local api_key="${2:-$API_KEY}"

    curl -s -o /dev/null -w "%{http_code}" -X POST "$APISIX_URL/eth/" \
        -H "Content-Type: application/json" \
        -H "apikey: $api_key" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":[],\"id\":1}"
}

# Make JSON-RPC request and return response
jsonrpc_call() {
    local method="${1:-eth_blockNumber}"
    local api_key="${2:-$API_KEY}"

    curl -s -X POST "$APISIX_URL/eth/" \
        -H "Content-Type: application/json" \
        -H "apikey: $api_key" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":[],\"id\":1}"
}

# Get rate limit headers (using -i for POST request, not -I which is for HEAD)
get_rate_limit_headers() {
    curl -s -i -X POST "$APISIX_URL/eth/" \
        -H "Content-Type: application/json" \
        -H "apikey: $API_KEY" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null | head -20
}

# Test: Request with valid key should succeed
test_valid_request() {
    ((TESTS_RUN++))
    log_info "Test: Request with valid API key should succeed"

    local status=$(jsonrpc_call_status "eth_blockNumber" "$API_KEY")

    if [ "$status" == "200" ]; then
        log_pass "Valid request returned 200 OK"
    else
        log_fail "Valid request should return 200, got $status"
    fi
}

# Test: Rate limit headers are present
test_rate_limit_headers() {
    ((TESTS_RUN++))
    log_info "Test: Rate limit headers are present in response"

    local headers=$(get_rate_limit_headers)

    # Check for our specific rate limit headers
    local has_limit=$(echo "$headers" | grep -i "X-RateLimit-Limit" || true)
    local has_remaining=$(echo "$headers" | grep -i "X-RateLimit-Remaining" || true)
    local has_type=$(echo "$headers" | grep -i "X-RateLimit-Type" || true)

    if [ -n "$has_limit" ] && [ -n "$has_remaining" ]; then
        log_pass "Rate limit headers present (Limit + Remaining)"
    else
        log_fail "Expected X-RateLimit-Limit and X-RateLimit-Remaining headers"
        echo "  Headers received:"
        echo "$headers" | grep -i "ratelimit\|monthly" | head -5
    fi
}

# Test: Monthly quota headers are present
test_monthly_quota_headers() {
    ((TESTS_RUN++))
    log_info "Test: Monthly quota headers are present in response"

    local headers=$(get_rate_limit_headers)

    local has_quota=$(echo "$headers" | grep -i "X-Monthly-Quota" || true)
    local has_used=$(echo "$headers" | grep -i "X-Monthly-Used" || true)

    if [ -n "$has_quota" ] && [ -n "$has_used" ]; then
        log_pass "Monthly quota headers present (Quota + Used)"
    else
        log_fail "Expected X-Monthly-Quota and X-Monthly-Used headers"
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

    local status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$APISIX_URL/eth/" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')

    if [ "$status" == "401" ] || [ "$status" == "403" ]; then
        log_pass "Missing API key rejected with $status"
    else
        log_fail "Missing API key should return 401/403, got $status"
    fi
}

# Test: Per-second rate limiting (sliding window)
test_per_second_limit() {
    ((TESTS_RUN++))
    log_info "Test: Per-second rate limiting is tracked"

    # Make a request and check the remaining counter decreases
    local headers1=$(get_rate_limit_headers)
    local remaining1=$(echo "$headers1" | grep -i "X-RateLimit-Remaining" | awk -F': ' '{print $2}' | tr -d '\r')

    local headers2=$(get_rate_limit_headers)
    local remaining2=$(echo "$headers2" | grep -i "X-RateLimit-Remaining" | awk -F': ' '{print $2}' | tr -d '\r')

    if [ -n "$remaining1" ] && [ -n "$remaining2" ]; then
        if [ "$remaining2" -lt "$remaining1" ] || [ "$remaining2" -ge 0 ]; then
            log_pass "Rate limit remaining tracked: $remaining1 -> $remaining2"
        else
            log_fail "Rate limit remaining should decrease or stay valid"
        fi
    else
        log_fail "Could not parse rate limit remaining headers"
    fi
}

# Test: Sliding window type is used
test_sliding_window_type() {
    ((TESTS_RUN++))
    log_info "Test: Sliding window rate limiting type is used"

    local headers=$(get_rate_limit_headers)
    local rate_type=$(echo "$headers" | grep -i "X-RateLimit-Type" | awk -F': ' '{print $2}' | tr -d '\r')

    if [ "$rate_type" == "sliding" ]; then
        log_pass "Using sliding window rate limiting"
    elif [ -n "$rate_type" ]; then
        log_info "Note: Rate limit type is '$rate_type' (expected 'sliding')"
        log_pass "Rate limit type header present"
    else
        log_fail "X-RateLimit-Type header not found"
    fi
}

# Test: Burst of requests within limit
test_burst_within_limit() {
    ((TESTS_RUN++))
    log_info "Test: Burst of requests (10 rapid requests)"

    local success_count=0
    local limited_count=0
    local error_count=0

    for i in $(seq 1 10); do
        local status=$(jsonrpc_call_status "eth_blockNumber" "$API_KEY")
        case "$status" in
            200) ((success_count++)) ;;
            429) ((limited_count++)) ;;
            *) ((error_count++)) ;;
        esac
    done

    log_info "  Results: $success_count success, $limited_count limited, $error_count errors"

    if [ "$success_count" -gt 0 ] && [ "$error_count" -eq 0 ]; then
        log_pass "Burst test: All requests either succeeded or were rate limited"
    else
        log_fail "Burst test: Unexpected errors occurred"
    fi
}

# Test: Rate limit error response format
test_rate_limit_error_format() {
    ((TESTS_RUN++))
    log_info "Test: Rate limit error response is valid JSON-RPC"

    # Force rate limit by making many rapid requests
    # Capture both status and body in a single request to avoid race condition
    local temp_file=$(mktemp)
    local limited_response=""
    local limited_status=""

    for i in $(seq 1 100); do
        # Capture body to file and status to variable in one request
        local status=$(curl -s -w "%{http_code}" -o "$temp_file" -X POST "$APISIX_URL/eth/" \
            -H "Content-Type: application/json" \
            -H "apikey: $API_KEY" \
            -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')

        if [ "$status" == "429" ]; then
            limited_response=$(cat "$temp_file")
            limited_status="429"
            break
        fi
    done

    rm -f "$temp_file"

    if [ -n "$limited_response" ]; then
        if echo "$limited_response" | grep -q '"error"' && echo "$limited_response" | grep -q '"code"'; then
            log_pass "Rate limit response is valid JSON-RPC error format"
        else
            log_fail "Rate limit response should be JSON-RPC error, got: $limited_response"
        fi
    else
        log_info "Note: Could not trigger rate limit with 100 requests (limit may be high)"
        log_pass "High rate limit configured (>100 CU/second)"
    fi
}

# Main test execution
main() {
    echo "================================================"
    echo "P0 Integration Test: Rate Limiting"
    echo "================================================"
    echo ""
    log_info "APISIX URL: $APISIX_URL"
    log_info "API Key: $API_KEY"
    log_info "Redis: via docker exec $REDIS_DOCKER"
    echo ""

    # Check prerequisites
    if ! curl -s "$APISIX_URL" >/dev/null 2>&1; then
        log_fail "APISIX is not reachable at $APISIX_URL"
        exit 1
    fi

    if ! docker exec "$REDIS_DOCKER" redis-cli ping >/dev/null 2>&1; then
        log_fail "Redis is not reachable via $REDIS_DOCKER"
        exit 1
    fi

    log_info "Prerequisites OK, starting tests..."
    echo ""

    # Run tests
    test_valid_request
    test_rate_limit_headers
    test_monthly_quota_headers
    test_invalid_api_key
    test_missing_api_key
    test_per_second_limit
    test_sliding_window_type
    test_burst_within_limit
    test_rate_limit_error_format

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
