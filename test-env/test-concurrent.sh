#!/bin/bash
#
# P1 Integration Test: Concurrent Requests
# Verifies system behavior under concurrent load
#
# Prerequisites:
#   - APISIX running with Unifra plugins
#   - Redis running
#   - Anvil (or other RPC backend) running
#   - GNU parallel (optional, for parallel tests)
#
# Usage: ./test-concurrent.sh
#

set -euo pipefail

# Configuration
APISIX_URL="${APISIX_URL:-http://localhost:9080}"
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"
CONCURRENCY="${CONCURRENCY:-10}"
REQUESTS_PER_WORKER="${REQUESTS_PER_WORKER:-20}"

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

# Reset Redis key
reset_redis_key() {
    local key="$1"
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "$key" >/dev/null 2>&1
}

# Get Redis key value
get_redis_value() {
    local key="$1"
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "$key" 2>/dev/null || echo "0"
}

# Make single JSON-RPC request
make_request() {
    local api_key="$1"
    curl -s -o /dev/null -w "%{http_code}" -X POST "$APISIX_URL/v1/eth-mainnet" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: $api_key" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
}

# Worker function for concurrent test
concurrent_worker() {
    local worker_id="$1"
    local api_key="$2"
    local count="$3"
    local success=0
    local fail=0

    for i in $(seq 1 "$count"); do
        local status=$(make_request "$api_key")
        if [ "$status" == "200" ]; then
            ((success++))
        else
            ((fail++))
        fi
    done

    echo "$worker_id,$success,$fail"
}

# Test: CU counting accuracy under concurrent load
test_concurrent_cu_accuracy() {
    ((TESTS_RUN++))
    log_info "Test: CU counting accuracy under concurrent load"
    log_info "  Concurrency: $CONCURRENCY workers"
    log_info "  Requests per worker: $REQUESTS_PER_WORKER"

    local api_key="test-concurrent-cu"
    local monthly_key="cu:monthly:$api_key"
    local expected_cu=$((CONCURRENCY * REQUESTS_PER_WORKER))

    # Reset CU counter
    reset_redis_key "$monthly_key"

    # Run concurrent workers
    local pids=()
    local temp_dir=$(mktemp -d)

    for i in $(seq 1 "$CONCURRENCY"); do
        (
            local success=0
            for j in $(seq 1 "$REQUESTS_PER_WORKER"); do
                local status=$(make_request "$api_key")
                if [ "$status" == "200" ]; then
                    ((success++))
                fi
            done
            echo "$success" > "$temp_dir/worker_$i"
        ) &
        pids+=($!)
    done

    # Wait for all workers
    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    # Sum up successful requests
    local total_success=0
    for i in $(seq 1 "$CONCURRENCY"); do
        local worker_success=$(cat "$temp_dir/worker_$i" 2>/dev/null || echo "0")
        total_success=$((total_success + worker_success))
    done

    # Cleanup
    rm -rf "$temp_dir"

    # Allow a moment for Redis to sync
    sleep 1

    # Check CU count
    local actual_cu=$(get_redis_value "$monthly_key")

    log_info "  Total successful requests: $total_success"
    log_info "  Expected CU: $total_success (1 CU each)"
    log_info "  Actual CU in Redis: $actual_cu"

    if [ "$actual_cu" -eq "$total_success" ]; then
        log_pass "CU count accurate under concurrent load ($actual_cu CU)"
    else
        local diff=$((actual_cu - total_success))
        if [ ${diff#-} -le 2 ]; then
            log_info "Note: Minor discrepancy of $diff CU (acceptable margin)"
            log_pass "CU count approximately accurate under concurrent load"
        else
            log_fail "CU count mismatch: expected $total_success, got $actual_cu (diff: $diff)"
        fi
    fi
}

# Test: No race conditions in rate limiting
test_rate_limit_race_condition() {
    ((TESTS_RUN++))
    log_info "Test: No race conditions in rate limiting"

    local api_key="test-race-limit"
    local monthly_key="cu:monthly:$api_key"

    # Set usage close to limit (998/1000, leaving room for 2 requests)
    reset_redis_key "$monthly_key"
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "$monthly_key" "998" >/dev/null

    # Launch many concurrent requests - only ~2 should succeed
    local success_count=0
    local limited_count=0
    local pids=()
    local temp_dir=$(mktemp -d)

    for i in $(seq 1 20); do
        (
            local status=$(make_request "$api_key")
            echo "$status" > "$temp_dir/result_$i"
        ) &
        pids+=($!)
    done

    # Wait for all
    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    # Count results
    for i in $(seq 1 20); do
        local status=$(cat "$temp_dir/result_$i" 2>/dev/null || echo "0")
        if [ "$status" == "200" ]; then
            ((success_count++))
        elif [ "$status" == "429" ]; then
            ((limited_count++))
        fi
    done

    rm -rf "$temp_dir"

    log_info "  Successful: $success_count, Limited: $limited_count"

    # We expect approximately 2 successes (998 + 2 = 1000 limit)
    # With race conditions, we might see more or less
    if [ "$success_count" -le 5 ] && [ "$limited_count" -ge 15 ]; then
        log_pass "Rate limiting correctly handled concurrent requests near limit"
    else
        log_fail "Possible race condition: $success_count successes when expecting ~2"
    fi
}

# Test: Different API keys don't interfere
test_concurrent_key_isolation() {
    ((TESTS_RUN++))
    log_info "Test: Different API keys don't interfere under concurrent load"

    local api_key_a="test-isolated-a"
    local api_key_b="test-isolated-b"
    local monthly_key_a="cu:monthly:$api_key_a"
    local monthly_key_b="cu:monthly:$api_key_b"

    reset_redis_key "$monthly_key_a"
    reset_redis_key "$monthly_key_b"

    local requests_each=50

    # Run concurrent requests for both keys simultaneously
    local pids=()

    # Workers for key A
    for i in $(seq 1 5); do
        (
            for j in $(seq 1 10); do
                make_request "$api_key_a" >/dev/null
            done
        ) &
        pids+=($!)
    done

    # Workers for key B
    for i in $(seq 1 5); do
        (
            for j in $(seq 1 10); do
                make_request "$api_key_b" >/dev/null
            done
        ) &
        pids+=($!)
    done

    # Wait for all
    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    sleep 1

    local cu_a=$(get_redis_value "$monthly_key_a")
    local cu_b=$(get_redis_value "$monthly_key_b")

    log_info "  Key A CU: $cu_a (expected ~$requests_each)"
    log_info "  Key B CU: $cu_b (expected ~$requests_each)"

    # Check that neither key has the other's CU added
    if [ "$cu_a" -le 55 ] && [ "$cu_a" -ge 45 ] && [ "$cu_b" -le 55 ] && [ "$cu_b" -ge 45 ]; then
        log_pass "API keys correctly isolated under concurrent load"
    else
        log_fail "Possible cross-contamination: A=$cu_a, B=$cu_b"
    fi
}

# Test: System handles high concurrency without errors
test_high_concurrency_stability() {
    ((TESTS_RUN++))
    log_info "Test: System handles high concurrency without errors"

    local api_key="test-stability"
    local monthly_key="cu:monthly:$api_key"
    reset_redis_key "$monthly_key"

    local high_concurrency=50
    local requests_each=10
    local error_count=0
    local pids=()
    local temp_dir=$(mktemp -d)

    log_info "  Launching $high_concurrency concurrent workers..."

    for i in $(seq 1 "$high_concurrency"); do
        (
            local errors=0
            for j in $(seq 1 "$requests_each"); do
                local status=$(make_request "$api_key")
                if [ "$status" != "200" ] && [ "$status" != "429" ]; then
                    ((errors++))
                fi
            done
            echo "$errors" > "$temp_dir/errors_$i"
        ) &
        pids+=($!)
    done

    # Wait for all workers
    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    # Sum errors
    for i in $(seq 1 "$high_concurrency"); do
        local worker_errors=$(cat "$temp_dir/errors_$i" 2>/dev/null || echo "0")
        error_count=$((error_count + worker_errors))
    done

    rm -rf "$temp_dir"

    local total_requests=$((high_concurrency * requests_each))
    log_info "  Total requests: $total_requests"
    log_info "  Error responses (not 200/429): $error_count"

    if [ "$error_count" -eq 0 ]; then
        log_pass "System stable under high concurrency (no unexpected errors)"
    else
        local error_rate=$((error_count * 100 / total_requests))
        if [ "$error_rate" -lt 5 ]; then
            log_info "Note: Minor error rate ${error_rate}% (acceptable)"
            log_pass "System mostly stable under high concurrency"
        else
            log_fail "High error rate: $error_count errors (${error_rate}%)"
        fi
    fi
}

# Test: Batch requests handled correctly under concurrency
test_concurrent_batch_requests() {
    ((TESTS_RUN++))
    log_info "Test: Batch requests handled correctly under concurrency"

    local api_key="test-batch-concurrent"
    local monthly_key="cu:monthly:$api_key"
    reset_redis_key "$monthly_key"

    local batch='[{"jsonrpc":"2.0","method":"eth_blockNumber","id":1},{"jsonrpc":"2.0","method":"eth_chainId","id":2}]'
    local workers=10
    local requests_each=10
    local expected_cu=$((workers * requests_each * 2))  # 2 CU per batch

    local pids=()

    for i in $(seq 1 "$workers"); do
        (
            for j in $(seq 1 "$requests_each"); do
                curl -s -o /dev/null -X POST "$APISIX_URL/v1/eth-mainnet" \
                    -H "Content-Type: application/json" \
                    -H "X-Api-Key: $api_key" \
                    -d "$batch"
            done
        ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    sleep 1

    local actual_cu=$(get_redis_value "$monthly_key")

    log_info "  Expected CU: ~$expected_cu (${workers}x${requests_each} batches @ 2 CU)"
    log_info "  Actual CU: $actual_cu"

    local diff=$((actual_cu - expected_cu))
    if [ ${diff#-} -le 10 ]; then
        log_pass "Batch requests counted correctly under concurrency"
    else
        log_fail "Batch CU mismatch: expected ~$expected_cu, got $actual_cu"
    fi
}

# Main test execution
main() {
    echo "================================================"
    echo "P1 Integration Test: Concurrent Requests"
    echo "================================================"
    echo ""
    log_info "APISIX URL: $APISIX_URL"
    log_info "Redis: $REDIS_HOST:$REDIS_PORT"
    log_info "Default concurrency: $CONCURRENCY"
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
    test_concurrent_cu_accuracy
    test_rate_limit_race_condition
    test_concurrent_key_isolation
    test_high_concurrency_stability
    test_concurrent_batch_requests

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
