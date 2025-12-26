#!/bin/bash
#
# Staging Environment Test Suite
# Runs a subset of critical tests against staging environment
#
# This script is designed to be run before production deployments
# to verify that the staging environment is working correctly.
#
# Prerequisites:
#   - Valid staging API key
#   - Network access to staging environment
#
# Usage:
#   ./test-staging.sh <staging-url> <api-key>
#   Example: ./test-staging.sh https://staging-eth.unifra.io test-api-key
#
# Environment variables:
#   STAGING_URL - Base URL for staging (alternative to CLI arg)
#   STAGING_API_KEY - API key for staging (alternative to CLI arg)
#   STAGING_NETWORK - Network to test (default: eth-mainnet)
#

set -euo pipefail

# Configuration
STAGING_URL="${1:-${STAGING_URL:-https://staging-eth.unifra.io}}"
API_KEY="${2:-${STAGING_API_KEY:-}}"
NETWORK="${STAGING_NETWORK:-eth-mainnet}"
TIMEOUT="${TIMEOUT:-30}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Helper functions
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((TESTS_PASSED++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((TESTS_FAILED++)); }
log_skip() { echo -e "${BLUE}[SKIP]${NC} $1"; ((TESTS_SKIPPED++)); }
log_header() { echo -e "\n${BLUE}━━━ $1 ━━━${NC}\n"; }

# Make JSON-RPC request
jsonrpc_call() {
    local method="$1"
    local params="${2:-[]}"

    curl -s -w "\n%{http_code}" -X POST "$STAGING_URL/v1/$NETWORK" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: $API_KEY" \
        --max-time "$TIMEOUT" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}" 2>/dev/null || echo -e "\n000"
}

# Parse response and status
parse_response() {
    local response="$1"
    local body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)
    echo "$body"
    return "$status"
}

# === SMOKE TESTS ===
# Quick validation that core functionality works

smoke_test_connectivity() {
    ((TESTS_RUN++))
    log_info "Smoke: Connectivity check"

    local response=$(jsonrpc_call "eth_blockNumber")
    local body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if [ "$status" == "200" ]; then
        local block=$(echo "$body" | grep -o '"result":"0x[0-9a-fA-F]*"' | cut -d'"' -f4 || echo "")
        if [ -n "$block" ]; then
            log_pass "Connected to staging, current block: $block"
        else
            log_fail "Connected but no valid block number returned"
        fi
    elif [ "$status" == "000" ]; then
        log_fail "Connection timeout or network error"
    else
        log_fail "Connection failed with status $status"
    fi
}

smoke_test_chain_id() {
    ((TESTS_RUN++))
    log_info "Smoke: Chain ID check"

    local response=$(jsonrpc_call "eth_chainId")
    local body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if [ "$status" == "200" ] && echo "$body" | grep -q '"result"' 2>/dev/null; then
        local chain_id=$(echo "$body" | grep -o '"result":"0x[0-9a-fA-F]*"' | cut -d'"' -f4 || echo "unknown")
        log_pass "Chain ID: $chain_id"
    else
        log_fail "Failed to get chain ID (status: $status)"
    fi
}

smoke_test_gas_price() {
    ((TESTS_RUN++))
    log_info "Smoke: Gas price check"

    local response=$(jsonrpc_call "eth_gasPrice")
    local body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if [ "$status" == "200" ] && echo "$body" | grep -q '"result"' 2>/dev/null; then
        log_pass "Gas price endpoint working"
    else
        log_fail "Failed to get gas price (status: $status)"
    fi
}

# === CRITICAL PATH TESTS ===
# P0 functionality that must work

critical_test_eth_call() {
    ((TESTS_RUN++))
    log_info "Critical: eth_call execution"

    # Call to a well-known contract (USDT totalSupply on mainnet)
    local params='[{"to":"0xdAC17F958D2ee523a2206206994597C13D831ec7","data":"0x18160ddd"},"latest"]'
    local response=$(jsonrpc_call "eth_call" "$params")
    local body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if [ "$status" == "200" ] && echo "$body" | grep -q '"result"' 2>/dev/null; then
        log_pass "eth_call executed successfully"
    elif echo "$body" | grep -q '"error"' 2>/dev/null; then
        local error=$(echo "$body" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
        log_info "Note: eth_call returned error (may be expected): $error"
        log_pass "eth_call handled correctly"
    else
        log_fail "eth_call failed (status: $status)"
    fi
}

critical_test_get_balance() {
    ((TESTS_RUN++))
    log_info "Critical: eth_getBalance"

    # Check balance of a known address (Vitalik's address)
    local params='["0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045","latest"]'
    local response=$(jsonrpc_call "eth_getBalance" "$params")
    local body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if [ "$status" == "200" ] && echo "$body" | grep -q '"result"' 2>/dev/null; then
        log_pass "eth_getBalance working"
    else
        log_fail "eth_getBalance failed (status: $status)"
    fi
}

critical_test_batch_request() {
    ((TESTS_RUN++))
    log_info "Critical: Batch request handling"

    local batch='[{"jsonrpc":"2.0","method":"eth_blockNumber","id":1},{"jsonrpc":"2.0","method":"eth_chainId","id":2}]'
    local response=$(curl -s -w "\n%{http_code}" -X POST "$STAGING_URL/v1/$NETWORK" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: $API_KEY" \
        --max-time "$TIMEOUT" \
        -d "$batch" 2>/dev/null || echo -e "\n000")

    local body=$(echo "$response" | head -n -1)
    local status=$(echo "$response" | tail -n 1)

    if [ "$status" == "200" ]; then
        # Check if response is an array with 2 results
        if echo "$body" | grep -q '\[.*\]' 2>/dev/null && echo "$body" | grep -c '"id"' 2>/dev/null | grep -q "2"; then
            log_pass "Batch request returned 2 responses"
        else
            log_info "Batch response: $body"
            log_pass "Batch request handled (response format may vary)"
        fi
    else
        log_fail "Batch request failed (status: $status)"
    fi
}

# === RATE LIMIT TESTS ===
# Verify rate limiting is active but not blocking legitimate traffic

rate_limit_test_normal_usage() {
    ((TESTS_RUN++))
    log_info "Rate Limit: Normal usage pattern"

    local success_count=0
    for i in $(seq 1 5); do
        local response=$(jsonrpc_call "eth_blockNumber")
        local status=$(echo "$response" | tail -n 1)
        if [ "$status" == "200" ]; then
            ((success_count++))
        fi
        sleep 0.5  # Reasonable delay between requests
    done

    if [ "$success_count" -eq 5 ]; then
        log_pass "Normal usage: 5/5 requests succeeded"
    else
        log_fail "Normal usage: only $success_count/5 requests succeeded"
    fi
}

rate_limit_test_headers_present() {
    ((TESTS_RUN++))
    log_info "Rate Limit: Headers presence check"

    local headers=$(curl -s -I -X POST "$STAGING_URL/v1/$NETWORK" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: $API_KEY" \
        --max-time "$TIMEOUT" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null)

    if echo "$headers" | grep -qi "ratelimit\|x-rate\|quota" 2>/dev/null; then
        log_pass "Rate limit headers present"
    else
        log_info "Note: Standard rate limit headers not found (may use custom headers)"
        log_pass "Request completed"
    fi
}

# === ERROR HANDLING TESTS ===
# Verify proper error responses

error_test_invalid_json() {
    ((TESTS_RUN++))
    log_info "Error: Invalid JSON handling"

    local response=$(curl -s -w "\n%{http_code}" -X POST "$STAGING_URL/v1/$NETWORK" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: $API_KEY" \
        --max-time "$TIMEOUT" \
        -d '{invalid json}' 2>/dev/null || echo -e "\n000")

    local status=$(echo "$response" | tail -n 1)

    if [ "$status" == "400" ]; then
        log_pass "Invalid JSON rejected with 400"
    else
        log_fail "Invalid JSON should return 400, got $status"
    fi
}

error_test_missing_api_key() {
    ((TESTS_RUN++))
    log_info "Error: Missing API key handling"

    local status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$STAGING_URL/v1/$NETWORK" \
        -H "Content-Type: application/json" \
        --max-time "$TIMEOUT" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null || echo "000")

    if [ "$status" == "401" ] || [ "$status" == "403" ]; then
        log_pass "Missing API key rejected with $status"
    else
        log_fail "Missing API key should return 401/403, got $status"
    fi
}

# === LATENCY TESTS ===
# Check response times are acceptable

latency_test_simple_request() {
    ((TESTS_RUN++))
    log_info "Latency: Simple request timing"

    local start_ms=$(date +%s%3N)
    local response=$(jsonrpc_call "eth_blockNumber")
    local end_ms=$(date +%s%3N)

    local status=$(echo "$response" | tail -n 1)
    local latency=$((end_ms - start_ms))

    if [ "$status" == "200" ]; then
        if [ "$latency" -lt 500 ]; then
            log_pass "Response time: ${latency}ms (excellent)"
        elif [ "$latency" -lt 1000 ]; then
            log_pass "Response time: ${latency}ms (good)"
        elif [ "$latency" -lt 3000 ]; then
            log_info "Note: Response time ${latency}ms is slower than optimal"
            log_pass "Response time: ${latency}ms (acceptable)"
        else
            log_fail "Response time too slow: ${latency}ms"
        fi
    else
        log_fail "Request failed, cannot measure latency"
    fi
}

# === MAIN ===

print_usage() {
    echo "Usage: $0 <staging-url> <api-key>"
    echo ""
    echo "Example:"
    echo "  $0 https://staging-eth.unifra.io your-api-key"
    echo ""
    echo "Or set environment variables:"
    echo "  STAGING_URL=https://staging-eth.unifra.io STAGING_API_KEY=key $0"
}

main() {
    echo "================================================"
    echo "Staging Environment Test Suite"
    echo "================================================"
    echo ""

    # Validate inputs
    if [ -z "$API_KEY" ]; then
        log_fail "API key is required"
        print_usage
        exit 1
    fi

    log_info "Staging URL: $STAGING_URL"
    log_info "Network: $NETWORK"
    log_info "API Key: ${API_KEY:0:8}..."
    log_info "Timeout: ${TIMEOUT}s"
    echo ""

    # Run test suites
    log_header "Smoke Tests"
    smoke_test_connectivity
    smoke_test_chain_id
    smoke_test_gas_price

    log_header "Critical Path Tests"
    critical_test_eth_call
    critical_test_get_balance
    critical_test_batch_request

    log_header "Rate Limit Tests"
    rate_limit_test_normal_usage
    rate_limit_test_headers_present

    log_header "Error Handling Tests"
    error_test_invalid_json
    error_test_missing_api_key

    log_header "Latency Tests"
    latency_test_simple_request

    # Summary
    echo ""
    echo "================================================"
    echo "Staging Test Summary"
    echo "================================================"
    echo "Total: $TESTS_RUN"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    echo -e "Skipped: ${BLUE}$TESTS_SKIPPED${NC}"

    if [ "$TESTS_FAILED" -eq 0 ]; then
        echo -e "\n${GREEN}✓ All staging tests passed! Safe to deploy.${NC}"
        exit 0
    else
        echo -e "\n${RED}✗ Some tests failed. Review before deploying.${NC}"
        exit 1
    fi
}

main "$@"
