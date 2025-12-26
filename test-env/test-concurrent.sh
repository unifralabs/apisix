#!/bin/bash
#
# P1 Integration Test: Concurrent Requests
# Verifies system behavior under concurrent load
#
# Prerequisites:
#   - APISIX running with Unifra plugins
#   - Redis running
#   - Anvil (or other RPC backend) running
#
# Usage: ./test-concurrent.sh
#

set -uo pipefail

# Configuration - matches test-all.sh setup
APISIX_URL="${APISIX_URL:-http://localhost:9080}"
API_KEY="${1:-test-api-key-123}"
CONCURRENCY="${CONCURRENCY:-10}"
REQUESTS_PER_WORKER="${REQUESTS_PER_WORKER:-5}"

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

# Make single JSON-RPC request
make_request() {
    curl -s -o /dev/null -w "%{http_code}" -X POST "$APISIX_URL/eth/" \
        -H "Content-Type: application/json" \
        -H "apikey: $API_KEY" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
}

# Test: Basic concurrent requests
test_concurrent_basic() {
    ((TESTS_RUN++))
    log_info "Test: Basic concurrent requests"
    log_info "  Sending $CONCURRENCY parallel requests"

    local temp_dir=$(mktemp -d)
    local pids=()

    # Launch concurrent requests
    for i in $(seq 1 "$CONCURRENCY"); do
        (
            local status=$(make_request)
            echo "$status" > "$temp_dir/result_$i"
        ) &
        pids+=($!)
    done

    # Wait for all
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Count results
    local success=0
    local limited=0
    local other=0

    for i in $(seq 1 "$CONCURRENCY"); do
        local status=$(cat "$temp_dir/result_$i" 2>/dev/null || echo "000")
        case "$status" in
            200) ((success++)) ;;
            429) ((limited++)) ;;
            *) ((other++)) ;;
        esac
    done

    rm -rf "$temp_dir"

    log_info "  Results: $success success, $limited rate-limited, $other other"

    if [ "$success" -gt 0 ] && [ "$other" -eq 0 ]; then
        log_pass "Concurrent requests handled correctly"
    else
        log_fail "Unexpected errors in concurrent requests"
    fi
}

# Test: Sequential burst
test_sequential_burst() {
    ((TESTS_RUN++))
    log_info "Test: Sequential burst (50 rapid requests)"

    local success=0
    local limited=0
    local other=0

    for i in $(seq 1 50); do
        local status=$(make_request)
        case "$status" in
            200) ((success++)) ;;
            429) ((limited++)) ;;
            *) ((other++)) ;;
        esac
    done

    log_info "  Results: $success success, $limited rate-limited, $other other"

    if [ "$success" -gt 0 ] && [ "$other" -eq 0 ]; then
        log_pass "Sequential burst handled correctly"
    else
        log_fail "Unexpected errors in sequential burst"
    fi
}

# Test: Mixed operations
test_mixed_operations() {
    ((TESTS_RUN++))
    log_info "Test: Mixed operations (different methods)"

    local methods=("eth_blockNumber" "eth_chainId" "eth_gasPrice")
    local success=0
    local fail=0

    for method in "${methods[@]}"; do
        local response=$(curl -s -X POST "$APISIX_URL/eth/" \
            -H "Content-Type: application/json" \
            -H "apikey: $API_KEY" \
            -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":[],\"id\":1}")

        if echo "$response" | grep -q '"result"'; then
            ((success++))
        else
            ((fail++))
        fi
    done

    if [ "$fail" -eq 0 ]; then
        log_pass "All 3 different methods succeeded"
    else
        log_fail "Some methods failed: $fail failures"
    fi
}

# Test: Batch under load
test_batch_under_load() {
    ((TESTS_RUN++))
    log_info "Test: Batch requests under concurrent load"

    local temp_dir=$(mktemp -d)
    local batch_size=3
    local concurrent_batches=5

    # Create batch request
    local batch='[{"jsonrpc":"2.0","method":"eth_blockNumber","id":1},{"jsonrpc":"2.0","method":"eth_chainId","id":2},{"jsonrpc":"2.0","method":"eth_gasPrice","id":3}]'

    # Launch concurrent batch requests
    local pids=()
    for i in $(seq 1 "$concurrent_batches"); do
        (
            local response=$(curl -s -X POST "$APISIX_URL/eth/" \
                -H "Content-Type: application/json" \
                -H "apikey: $API_KEY" \
                -d "$batch")
            # Count results in batch response
            local count=$(echo "$response" | grep -o '"id"' | wc -l | tr -d ' ')
            echo "$count" > "$temp_dir/batch_$i"
        ) &
        pids+=($!)
    done

    # Wait for all
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Verify all batches returned 3 results
    local correct=0
    for i in $(seq 1 "$concurrent_batches"); do
        local count=$(cat "$temp_dir/batch_$i" 2>/dev/null || echo "0")
        if [ "$count" -eq 3 ]; then
            ((correct++))
        fi
    done

    rm -rf "$temp_dir"

    if [ "$correct" -eq "$concurrent_batches" ]; then
        log_pass "All $concurrent_batches concurrent batches returned correct results"
    else
        log_fail "Only $correct/$concurrent_batches batches returned correct results"
    fi
}

# Test: No request loss under load
test_no_request_loss() {
    ((TESTS_RUN++))
    log_info "Test: No request loss under moderate load"

    local total_requests=20
    local success=0

    for i in $(seq 1 "$total_requests"); do
        local status=$(make_request)
        if [ "$status" == "200" ] || [ "$status" == "429" ]; then
            ((success++))
        fi
    done

    if [ "$success" -eq "$total_requests" ]; then
        log_pass "All $total_requests requests completed (200 or 429)"
    else
        log_fail "Some requests lost: $success/$total_requests completed"
    fi
}

# Main test execution
main() {
    echo "================================================"
    echo "P1 Integration Test: Concurrent Requests"
    echo "================================================"
    echo ""
    log_info "APISIX URL: $APISIX_URL"
    log_info "API Key: $API_KEY"
    log_info "Default concurrency: $CONCURRENCY"
    echo ""

    # Check prerequisites
    if ! curl -s "$APISIX_URL" >/dev/null 2>&1; then
        log_fail "APISIX is not reachable at $APISIX_URL"
        exit 1
    fi

    log_info "Prerequisites OK, starting tests..."
    echo ""

    # Run tests
    test_concurrent_basic
    test_sequential_burst
    test_mixed_operations
    test_batch_under_load
    test_no_request_loss

    # Summary
    echo ""
    echo "================================================"
    echo "Test Summary"
    echo "================================================"
    echo "Total: $TESTS_RUN"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

    if [ "$TESTS_FAILED" -eq 0 ]; then
        echo -e "\n${GREEN}All concurrent request tests passed!${NC}"
        exit 0
    else
        echo -e "\n${RED}Some tests failed!${NC}"
        exit 1
    fi
}

main "$@"
