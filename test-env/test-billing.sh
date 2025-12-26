#!/bin/bash
#
# P0 Integration Test: Billing Accuracy
# Verifies that CU calculations are accurate end-to-end
#
# Prerequisites:
#   - APISIX running with Unifra plugins
#   - Redis running
#   - Anvil (or other RPC backend) running
#
# Usage: ./test-billing.sh [API_KEY]
#

set -uo pipefail  # Don't exit immediately on error (-e removed)

# Configuration - matches test-all.sh setup
APISIX_URL="${APISIX_URL:-http://localhost:9080}"
ADMIN_URL="${ADMIN_URL:-http://localhost:9180}"
ADMIN_KEY="${ADMIN_KEY:-unifra-test-admin-key}"
API_KEY="${1:-test-api-key-123}"
CONSUMER_NAME="${CONSUMER_NAME:-test-user}"
# Redis access via docker exec (Redis not exposed to host by default)
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

# Get current billing cycle ID (YYYYMM format)
get_cycle_id() {
    date -u +"%Y%m"
}

# Get current CU usage from Redis (via docker exec)
get_cu_usage() {
    local key="$1"
    local result=$(docker exec "$REDIS_DOCKER" redis-cli GET "$key" 2>/dev/null)
    echo "${result:-0}"
}

# Reset CU usage in Redis for testing (via docker exec)
reset_cu_usage() {
    local key="$1"
    docker exec "$REDIS_DOCKER" redis-cli DEL "$key" >/dev/null 2>&1 || true
}

# Make JSON-RPC request - uses /eth/ route with apikey header
jsonrpc_call() {
    local method="$1"
    local params="${2:-[]}"
    local api_key="${3:-$API_KEY}"

    curl -s -X POST "$APISIX_URL/eth/" \
        -H "Content-Type: application/json" \
        -H "apikey: $api_key" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}"
}

# Make batch JSON-RPC request
jsonrpc_batch() {
    local body="$1"
    local api_key="${2:-$API_KEY}"

    curl -s -X POST "$APISIX_URL/eth/" \
        -H "Content-Type: application/json" \
        -H "apikey: $api_key" \
        -d "$body"
}

# Test: Single method CU calculation
test_single_method_cu() {
    ((TESTS_RUN++))
    log_info "Test: Single method CU calculation (eth_blockNumber = 1 CU)"

    local key="quota:monthly:$CONSUMER_NAME:$(get_cycle_id)"
    local before=$(get_cu_usage "$key")

    # eth_blockNumber should cost 1 CU
    jsonrpc_call "eth_blockNumber" >/dev/null

    sleep 0.5  # Allow Redis write to complete
    local after=$(get_cu_usage "$key")

    local diff=$((after - before))
    if [ "$diff" -eq 1 ]; then
        log_pass "eth_blockNumber consumed exactly 1 CU (before=$before, after=$after)"
    else
        log_fail "eth_blockNumber should consume 1 CU, but consumed $diff CU"
    fi
}

# Test: Known method with higher CU
test_higher_cu_method() {
    ((TESTS_RUN++))
    log_info "Test: Higher CU method (eth_call = 5 CU)"

    local key="quota:monthly:$CONSUMER_NAME:$(get_cycle_id)"
    local before=$(get_cu_usage "$key")

    # eth_call should cost 5 CU
    jsonrpc_call "eth_call" '[{"to":"0x0000000000000000000000000000000000000000"},"latest"]' >/dev/null

    sleep 0.5
    local after=$(get_cu_usage "$key")

    local diff=$((after - before))
    if [ "$diff" -eq 5 ]; then
        log_pass "eth_call consumed exactly 5 CU (before=$before, after=$after)"
    else
        log_fail "eth_call should consume 5 CU, but consumed $diff CU"
    fi
}

# Test: Batch request CU accumulation
test_batch_cu_accumulation() {
    ((TESTS_RUN++))
    log_info "Test: Batch request CU accumulation"

    local key="quota:monthly:$CONSUMER_NAME:$(get_cycle_id)"
    local before=$(get_cu_usage "$key")

    # Batch: eth_blockNumber (1) + eth_chainId (1) = 2 CU
    local batch='[{"jsonrpc":"2.0","method":"eth_blockNumber","id":1},{"jsonrpc":"2.0","method":"eth_chainId","id":2}]'
    jsonrpc_batch "$batch" >/dev/null

    sleep 0.5
    local after=$(get_cu_usage "$key")

    local diff=$((after - before))
    if [ "$diff" -eq 2 ]; then
        log_pass "Batch consumed exactly 2 CU (before=$before, after=$after)"
    else
        log_fail "Batch should consume 2 CU, but consumed $diff CU"
    fi
}

# Test: Mixed batch with different CU costs
test_mixed_batch_cu() {
    ((TESTS_RUN++))
    log_info "Test: Mixed batch CU calculation"

    local key="quota:monthly:$CONSUMER_NAME:$(get_cycle_id)"
    local before=$(get_cu_usage "$key")

    # Batch: eth_blockNumber (1) + eth_call (5) + eth_getLogs (10) = 16 CU
    local batch='[
        {"jsonrpc":"2.0","method":"eth_blockNumber","id":1},
        {"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0x0"},"latest"],"id":2},
        {"jsonrpc":"2.0","method":"eth_getLogs","params":[{"fromBlock":"latest"}],"id":3}
    ]'
    jsonrpc_batch "$batch" >/dev/null

    sleep 0.5
    local after=$(get_cu_usage "$key")

    local diff=$((after - before))
    if [ "$diff" -eq 16 ]; then
        log_pass "Mixed batch consumed exactly 16 CU (before=$before, after=$after)"
    else
        log_fail "Mixed batch should consume 16 CU, but consumed $diff CU"
    fi
}

# Test: Blocked method should not charge CU
test_blocked_method_no_cu() {
    ((TESTS_RUN++))
    log_info "Test: Blocked method should not charge CU (debug_* requires paid tier)"

    local key="quota:monthly:$CONSUMER_NAME:$(get_cycle_id)"
    local before=$(get_cu_usage "$key")

    # debug_traceTransaction requires paid tier and should be blocked
    # Blocked requests should NOT charge CU
    jsonrpc_call "debug_traceTransaction" '["0x0"]' >/dev/null 2>&1 || true

    sleep 0.5
    local after=$(get_cu_usage "$key")

    local diff=$((after - before))
    if [ "$diff" -eq 0 ]; then
        log_pass "Blocked method (debug_*) did not charge CU (before=$before, after=$after)"
    else
        log_fail "Blocked method should not charge CU, but charged $diff CU"
    fi
}

# Test: Unknown method uses default CU
test_unknown_method_cu() {
    ((TESTS_RUN++))
    log_info "Test: Unknown method uses default CU (1 CU)"

    local key="quota:monthly:$CONSUMER_NAME:$(get_cycle_id)"
    local before=$(get_cu_usage "$key")

    # Unknown method should use default (1 CU)
    jsonrpc_call "net_version" >/dev/null 2>&1 || true

    sleep 0.5
    local after=$(get_cu_usage "$key")

    local diff=$((after - before))
    if [ "$diff" -eq 1 ]; then
        log_pass "net_version consumed exactly 1 CU (default) (before=$before, after=$after)"
    else
        log_fail "net_version should consume 1 CU (default), but consumed $diff CU"
    fi
}

# Test: CU not charged for invalid requests
test_invalid_request_no_cu() {
    ((TESTS_RUN++))
    log_info "Test: Invalid request should not charge CU"

    local key="quota:monthly:$CONSUMER_NAME:$(get_cycle_id)"
    local before=$(get_cu_usage "$key")

    # Invalid JSON should not charge CU
    curl -s -X POST "$APISIX_URL/eth/" \
        -H "Content-Type: application/json" \
        -H "apikey: $API_KEY" \
        -d '{invalid json}' >/dev/null 2>&1 || true

    sleep 0.5
    local after=$(get_cu_usage "$key")

    local diff=$((after - before))
    if [ "$diff" -eq 0 ]; then
        log_pass "Invalid request did not charge CU (before=$before, after=$after)"
    else
        log_fail "Invalid request should not charge CU, but charged $diff CU"
    fi
}

# Test: CU accumulation across multiple requests
test_cu_accumulation() {
    ((TESTS_RUN++))
    log_info "Test: CU accumulation across multiple requests"

    local key="quota:monthly:$CONSUMER_NAME:$(get_cycle_id)"
    reset_cu_usage "$key"

    # Make 5 requests of 1 CU each
    for i in 1 2 3 4 5; do
        jsonrpc_call "eth_blockNumber" >/dev/null
    done

    sleep 0.5
    local total=$(get_cu_usage "$key")

    if [ "$total" -eq 5 ]; then
        log_pass "5 requests accumulated to exactly 5 CU (total=$total)"
    else
        log_fail "5 requests should accumulate to 5 CU, but got $total CU"
    fi
}

# Main test execution
main() {
    echo "================================================"
    echo "P0 Integration Test: Billing Accuracy"
    echo "================================================"
    echo ""
    log_info "APISIX URL: $APISIX_URL"
    log_info "API Key: $API_KEY"
    log_info "Consumer: $CONSUMER_NAME"
    log_info "Redis: via docker exec $REDIS_DOCKER"
    log_info "Cycle ID: $(get_cycle_id)"
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
    test_single_method_cu
    test_higher_cu_method
    test_batch_cu_accumulation
    test_mixed_batch_cu
    test_blocked_method_no_cu
    test_unknown_method_cu
    test_invalid_request_no_cu
    test_cu_accumulation

    # Summary
    echo ""
    echo "================================================"
    echo "Test Summary"
    echo "================================================"
    echo "Total: $TESTS_RUN"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

    if [ "$TESTS_FAILED" -eq 0 ]; then
        echo -e "\n${GREEN}All billing accuracy tests passed!${NC}"
        exit 0
    else
        echo -e "\n${RED}Some tests failed!${NC}"
        exit 1
    fi
}

main "$@"
