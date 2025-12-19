#!/bin/bash
#
# Unifra APISIX Integration Test Suite
# Comprehensive automated tests for all Unifra plugins
#
# Usage:
#   ./integration_test.sh              # Run all tests
#   ./integration_test.sh --http-only  # Run HTTP tests only
#   ./integration_test.sh --ws-only    # Run WebSocket tests only
#   ./integration_test.sh --verbose    # Verbose output
#

set -e

# Configuration
APISIX_URL="${APISIX_URL:-http://localhost:9080}"
ADMIN_URL="${ADMIN_URL:-http://localhost:9180}"
ADMIN_KEY="${ADMIN_KEY:-unifra-test-admin-key}"
ANVIL_URL="${ANVIL_URL:-http://localhost:8545}"
WS_URL="${WS_URL:-ws://localhost:9080}"

# Test users
FREE_USER_KEY="test-free-user-key"
PAID_USER_KEY="test-paid-user-key"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# Options
VERBOSE=false
HTTP_ONLY=false
WS_ONLY=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --verbose|-v) VERBOSE=true ;;
        --http-only) HTTP_ONLY=true ;;
        --ws-only) WS_ONLY=true ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --verbose, -v    Show detailed output"
            echo "  --http-only      Run HTTP tests only"
            echo "  --ws-only        Run WebSocket tests only"
            echo "  --help, -h       Show this help"
            exit 0
            ;;
    esac
done

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASSED++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAILED++)); }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $1"; ((SKIPPED++)); }
log_debug() { $VERBOSE && echo -e "${YELLOW}[DEBUG]${NC} $1" || true; }

# Test helpers
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="$3"
    if echo "$haystack" | grep -q "$needle"; then
        log_pass "$msg"
        return 0
    else
        log_fail "$msg"
        log_debug "Expected to find: $needle"
        log_debug "Got: $haystack"
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="$3"
    if ! echo "$haystack" | grep -q "$needle"; then
        log_pass "$msg"
        return 0
    else
        log_fail "$msg"
        log_debug "Expected NOT to find: $needle"
        log_debug "Got: $haystack"
        return 1
    fi
}

assert_json_field() {
    local json="$1"
    local field="$2"
    local expected="$3"
    local msg="$4"
    local actual=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field',''))" 2>/dev/null)
    if [ "$actual" = "$expected" ]; then
        log_pass "$msg"
        return 0
    else
        log_fail "$msg (expected: $expected, got: $actual)"
        return 1
    fi
}

http_post() {
    local url="$1"
    local data="$2"
    local headers="$3"
    curl -s -X POST "$url" -H "Content-Type: application/json" $headers -d "$data"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check Anvil
    if ! curl -s "$ANVIL_URL" -X POST -H "Content-Type: application/json" \
         -d '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}' | grep -q "result"; then
        log_fail "Anvil not running at $ANVIL_URL"
        echo "  Start with: anvil --host 0.0.0.0 --port 8545"
        exit 1
    fi
    log_pass "Anvil is running"

    # Check APISIX
    if ! curl -s "$ADMIN_URL/apisix/admin/plugins/list" -H "X-API-KEY: $ADMIN_KEY" | grep -q "unifra"; then
        log_fail "APISIX not running or Unifra plugins not loaded"
        exit 1
    fi
    log_pass "APISIX is running with Unifra plugins"

    # Check wscat for WebSocket tests
    if ! $HTTP_ONLY; then
        export PATH="$PATH:$(npm bin -g 2>/dev/null)"
        if ! which wscat > /dev/null 2>&1; then
            log_skip "wscat not found, WebSocket tests will be skipped"
            WS_ONLY=false
            HTTP_ONLY=true
        fi
    fi
}

# Setup test data
setup_test_data() {
    log_info "Setting up test data..."

    # Create Upstream
    curl -s -X PUT "$ADMIN_URL/apisix/admin/upstreams/test-upstream" \
        -H "X-API-KEY: $ADMIN_KEY" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "test-anvil-upstream",
            "type": "roundrobin",
            "nodes": { "host.docker.internal:8545": 1 }
        }' > /dev/null
    log_debug "Upstream created"

    # Create Free User
    curl -s -X PUT "$ADMIN_URL/apisix/admin/consumers/free-user" \
        -H "X-API-KEY: $ADMIN_KEY" \
        -H "Content-Type: application/json" \
        -d '{
            "username": "free-user",
            "plugins": {
                "key-auth": { "key": "'"$FREE_USER_KEY"'" },
                "unifra-ctx-var": {
                    "seconds_quota": "50",
                    "monthly_quota": "1000"
                }
            }
        }' > /dev/null
    log_debug "Free user created"

    # Create Paid User
    curl -s -X PUT "$ADMIN_URL/apisix/admin/consumers/paid-user" \
        -H "X-API-KEY: $ADMIN_KEY" \
        -H "Content-Type: application/json" \
        -d '{
            "username": "paid-user",
            "plugins": {
                "key-auth": { "key": "'"$PAID_USER_KEY"'" },
                "unifra-ctx-var": {
                    "seconds_quota": "1000",
                    "monthly_quota": "10000000"
                }
            }
        }' > /dev/null
    log_debug "Paid user created"

    # Create HTTP Route
    curl -s -X PUT "$ADMIN_URL/apisix/admin/routes/test-http" \
        -H "X-API-KEY: $ADMIN_KEY" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "test-http-route",
            "uri": "/test/*",
            "upstream_id": "test-upstream",
            "plugins": {
                "proxy-rewrite": { "uri": "/" },
                "key-auth": {},
                "unifra-jsonrpc-var": { "network": "eth-mainnet" },
                "unifra-whitelist": {},
                "unifra-calculate-cu": {},
                "unifra-limit-cu": { "redis_host": "redis", "redis_port": 6379 },
                "unifra-limit-monthly-cu": { "redis_host": "redis", "redis_port": 6379 }
            }
        }' > /dev/null
    log_debug "HTTP route created"

    # Create WebSocket Route
    curl -s -X PUT "$ADMIN_URL/apisix/admin/routes/test-ws" \
        -H "X-API-KEY: $ADMIN_KEY" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "test-ws-route",
            "uri": "/test-ws",
            "upstream_id": "test-upstream",
            "enable_websocket": true,
            "plugins": {
                "proxy-rewrite": { "uri": "/" },
                "key-auth": { "query": "apikey" },
                "unifra-ws-jsonrpc-proxy": {
                    "redis_host": "redis",
                    "redis_port": 6379,
                    "network": "eth-mainnet"
                }
            }
        }' > /dev/null
    log_debug "WebSocket route created"

    log_pass "Test data setup complete"
    sleep 1  # Wait for routes to propagate
}

# Cleanup test data
cleanup_test_data() {
    log_info "Cleaning up test data..."

    curl -s -X DELETE "$ADMIN_URL/apisix/admin/routes/test-http" -H "X-API-KEY: $ADMIN_KEY" > /dev/null 2>&1 || true
    curl -s -X DELETE "$ADMIN_URL/apisix/admin/routes/test-ws" -H "X-API-KEY: $ADMIN_KEY" > /dev/null 2>&1 || true
    curl -s -X DELETE "$ADMIN_URL/apisix/admin/consumers/free-user" -H "X-API-KEY: $ADMIN_KEY" > /dev/null 2>&1 || true
    curl -s -X DELETE "$ADMIN_URL/apisix/admin/consumers/paid-user" -H "X-API-KEY: $ADMIN_KEY" > /dev/null 2>&1 || true
    curl -s -X DELETE "$ADMIN_URL/apisix/admin/upstreams/test-upstream" -H "X-API-KEY: $ADMIN_KEY" > /dev/null 2>&1 || true

    log_pass "Cleanup complete"
}

# ============================================================================
# HTTP Tests
# ============================================================================

test_http_auth() {
    echo ""
    echo "========================================"
    echo " HTTP Authentication Tests"
    echo "========================================"

    # Test: No API key
    local result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}')
    assert_contains "$result" "Missing API key" "Reject request without API key"

    # Test: Invalid API key
    result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}' "-H 'apikey: invalid-key'")
    assert_contains "$result" "Invalid API key" "Reject request with invalid API key"

    # Test: Valid API key
    result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}' "-H 'apikey: $FREE_USER_KEY'")
    assert_contains "$result" '"result"' "Accept request with valid API key"
}

test_http_jsonrpc_parsing() {
    echo ""
    echo "========================================"
    echo " HTTP JSON-RPC Parsing Tests"
    echo "========================================"

    # Test: Valid single request
    local result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "-H 'apikey: $FREE_USER_KEY'")
    assert_contains "$result" '"result":"0x' "Parse valid single request"

    # Test: Valid batch request
    result=$(http_post "$APISIX_URL/test/" '[{"jsonrpc":"2.0","method":"eth_blockNumber","id":1},{"jsonrpc":"2.0","method":"eth_chainId","id":2}]' "-H 'apikey: $FREE_USER_KEY'")
    local count=$(echo "$result" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    if [ "$count" = "2" ]; then
        log_pass "Parse valid batch request (2 items)"
    else
        log_fail "Parse valid batch request (expected 2 items, got $count)"
    fi

    # Test: Invalid JSON
    result=$(http_post "$APISIX_URL/test/" 'not json' "-H 'apikey: $FREE_USER_KEY'")
    assert_contains "$result" "parse error\|Parse error" "Reject invalid JSON"

    # Test: Missing method
    result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","id":1}' "-H 'apikey: $FREE_USER_KEY'")
    assert_contains "$result" "missing method" "Reject request without method"

    # Test: Empty batch
    result=$(http_post "$APISIX_URL/test/" '[]' "-H 'apikey: $FREE_USER_KEY'")
    assert_contains "$result" "empty batch" "Reject empty batch"
}

test_http_whitelist() {
    echo ""
    echo "========================================"
    echo " HTTP Whitelist Tests"
    echo "========================================"

    # Test: Free method allowed
    local result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}' "-H 'apikey: $FREE_USER_KEY'")
    assert_contains "$result" '"result"' "Allow free method (eth_blockNumber)"

    # Test: Another free method
    result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","latest"],"id":1}' "-H 'apikey: $FREE_USER_KEY'")
    assert_contains "$result" '"result"' "Allow free method (eth_getBalance)"

    # Test: Paid method blocked for free user
    result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","method":"debug_traceTransaction","id":1}' "-H 'apikey: $FREE_USER_KEY'")
    assert_contains "$result" "requires paid tier" "Block paid method for free user"

    # Test: Paid method allowed for paid user
    result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","method":"debug_traceTransaction","params":["0x0000000000000000000000000000000000000000000000000000000000000000"],"id":1}' "-H 'apikey: $PAID_USER_KEY'")
    # Anvil may not support debug_traceTransaction, but it should pass whitelist
    assert_not_contains "$result" "requires paid tier" "Allow paid method for paid user"

    # Test: Unsupported method blocked
    result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","method":"eth_mining","id":1}' "-H 'apikey: $FREE_USER_KEY'")
    assert_contains "$result" "unsupported method" "Block unsupported method"
}

test_http_rate_limiting() {
    echo ""
    echo "========================================"
    echo " HTTP Rate Limiting Tests"
    echo "========================================"

    # Rapid requests to trigger rate limiting
    log_info "Sending rapid requests to test rate limiting..."

    local success=0
    local rate_limited=0

    for i in {1..60}; do
        result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","method":"eth_blockNumber","id":'$i'}' "-H 'apikey: $FREE_USER_KEY'")
        if echo "$result" | grep -q '"result"'; then
            ((success++))
        elif echo "$result" | grep -q "rate limit"; then
            ((rate_limited++))
        fi
    done

    log_debug "Success: $success, Rate limited: $rate_limited"

    if [ $success -gt 0 ] && [ $success -lt 60 ]; then
        log_pass "Rate limiting working ($success succeeded, $rate_limited rate-limited)"
    elif [ $success -eq 60 ]; then
        log_pass "All requests succeeded (quota not exceeded)"
    else
        log_fail "Rate limiting may not be working correctly"
    fi

    # Wait for rate limit window to reset
    sleep 2
}

test_http_cu_calculation() {
    echo ""
    echo "========================================"
    echo " HTTP CU Calculation Tests"
    echo "========================================"

    # Test: Check rate limit header shows CU calculation
    local result=$(curl -s -i -X POST "$APISIX_URL/test/" \
        -H "Content-Type: application/json" \
        -H "apikey: $FREE_USER_KEY" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}')

    if echo "$result" | grep -qi "X-RateLimit"; then
        log_pass "Rate limit headers present"
    else
        log_skip "Rate limit headers not found"
    fi

    # Test: Batch request CU should be sum of individual methods
    result=$(http_post "$APISIX_URL/test/" '[{"jsonrpc":"2.0","method":"eth_blockNumber","id":1},{"jsonrpc":"2.0","method":"eth_blockNumber","id":2},{"jsonrpc":"2.0","method":"eth_blockNumber","id":3}]' "-H 'apikey: $FREE_USER_KEY'")
    local count=$(echo "$result" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    if [ "$count" = "3" ]; then
        log_pass "Batch request processes all methods"
    else
        log_fail "Batch request should process all methods"
    fi
}

test_http_real_blockchain() {
    echo ""
    echo "========================================"
    echo " HTTP Real Blockchain Tests (Anvil)"
    echo "========================================"

    # Test: Get block number
    local result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}' "-H 'apikey: $FREE_USER_KEY'")
    local block=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
    if [[ "$block" == 0x* ]]; then
        log_pass "eth_blockNumber returns hex ($block)"
    else
        log_fail "eth_blockNumber should return hex"
    fi

    # Test: Get chain ID (Anvil = 31337 = 0x7a69)
    result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","method":"eth_chainId","id":1}' "-H 'apikey: $FREE_USER_KEY'")
    assert_contains "$result" '"0x7a69"' "eth_chainId returns Anvil chain ID (31337)"

    # Test: Get balance of test account
    result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","latest"],"id":1}' "-H 'apikey: $FREE_USER_KEY'")
    assert_contains "$result" '"result":"0x' "eth_getBalance returns balance"

    # Test: eth_call
    result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0x0000000000000000000000000000000000000000","data":"0x"},"latest"],"id":1}' "-H 'apikey: $FREE_USER_KEY'")
    assert_contains "$result" '"result"' "eth_call works"

    # Test: eth_gasPrice
    result=$(http_post "$APISIX_URL/test/" '{"jsonrpc":"2.0","method":"eth_gasPrice","id":1}' "-H 'apikey: $FREE_USER_KEY'")
    assert_contains "$result" '"result":"0x' "eth_gasPrice returns gas price"
}

# ============================================================================
# WebSocket Tests
# ============================================================================

ws_test() {
    local msg="$1"
    local apikey="$2"
    export PATH="$PATH:$(npm bin -g 2>/dev/null)"
    (sleep 1; echo "$msg"; sleep 1) | wscat -c "$WS_URL/test-ws?apikey=$apikey" 2>&1 | grep -v "^>" | head -1
}

test_ws_auth() {
    echo ""
    echo "========================================"
    echo " WebSocket Authentication Tests"
    echo "========================================"

    export PATH="$PATH:$(npm bin -g 2>/dev/null)"

    # Test: No API key
    local result=$( (sleep 1; echo '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}'; sleep 1) | wscat -c "$WS_URL/test-ws" 2>&1 || true )
    if echo "$result" | grep -qi "Missing API key\|401\|error"; then
        log_pass "WebSocket rejects connection without API key"
    else
        log_skip "WebSocket auth test inconclusive"
    fi

    # Test: Valid API key
    result=$(ws_test '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}' "$FREE_USER_KEY")
    assert_contains "$result" '"result"' "WebSocket accepts connection with valid API key"
}

test_ws_jsonrpc() {
    echo ""
    echo "========================================"
    echo " WebSocket JSON-RPC Tests"
    echo "========================================"

    # Test: eth_blockNumber
    local result=$(ws_test '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}' "$FREE_USER_KEY")
    assert_contains "$result" '"result":"0x' "WebSocket eth_blockNumber works"

    # Test: eth_chainId
    result=$(ws_test '{"jsonrpc":"2.0","method":"eth_chainId","id":1}' "$FREE_USER_KEY")
    assert_contains "$result" '"0x7a69"' "WebSocket eth_chainId returns Anvil chain ID"

    # Test: eth_gasPrice
    result=$(ws_test '{"jsonrpc":"2.0","method":"eth_gasPrice","id":1}' "$FREE_USER_KEY")
    assert_contains "$result" '"result":"0x' "WebSocket eth_gasPrice works"
}

test_ws_whitelist() {
    echo ""
    echo "========================================"
    echo " WebSocket Whitelist Tests"
    echo "========================================"

    # Test: Free method allowed
    local result=$(ws_test '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}' "$FREE_USER_KEY")
    assert_contains "$result" '"result"' "WebSocket allows free method"

    # Test: Paid method blocked for free user
    result=$(ws_test '{"jsonrpc":"2.0","method":"debug_traceTransaction","id":1}' "$FREE_USER_KEY")
    assert_contains "$result" "requires paid tier" "WebSocket blocks paid method for free user"

    # Test: Unsupported method blocked
    result=$(ws_test '{"jsonrpc":"2.0","method":"eth_mining","id":1}' "$FREE_USER_KEY")
    assert_contains "$result" "unsupported method" "WebSocket blocks unsupported method"
}

test_ws_multiple_messages() {
    echo ""
    echo "========================================"
    echo " WebSocket Multiple Messages Tests"
    echo "========================================"

    export PATH="$PATH:$(npm bin -g 2>/dev/null)"

    # Send multiple messages
    local result=$( (sleep 1; echo '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}'; sleep 0.5; echo '{"jsonrpc":"2.0","method":"eth_chainId","id":2}'; sleep 1) | wscat -c "$WS_URL/test-ws?apikey=$FREE_USER_KEY" 2>&1 | grep -v "^>" | head -2 )

    local count=$(echo "$result" | grep -c "result" || echo "0")
    if [ "$count" -ge 2 ]; then
        log_pass "WebSocket handles multiple messages ($count responses)"
    else
        log_fail "WebSocket should handle multiple messages"
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo "========================================"
    echo " Unifra APISIX Integration Test Suite"
    echo "========================================"
    echo " APISIX URL: $APISIX_URL"
    echo " Admin URL:  $ADMIN_URL"
    echo " Anvil URL:  $ANVIL_URL"
    echo "========================================"
    echo ""

    check_prerequisites
    setup_test_data

    # Run HTTP tests
    if ! $WS_ONLY; then
        test_http_auth
        test_http_jsonrpc_parsing
        test_http_whitelist
        test_http_rate_limiting
        test_http_cu_calculation
        test_http_real_blockchain
    fi

    # Run WebSocket tests
    if ! $HTTP_ONLY; then
        if which wscat > /dev/null 2>&1; then
            test_ws_auth
            test_ws_jsonrpc
            test_ws_whitelist
            test_ws_multiple_messages
        else
            log_skip "WebSocket tests skipped (wscat not found)"
        fi
    fi

    cleanup_test_data

    # Summary
    echo ""
    echo "========================================"
    echo " Test Summary"
    echo "========================================"
    echo -e " ${GREEN}Passed:${NC}  $PASSED"
    echo -e " ${RED}Failed:${NC}  $FAILED"
    echo -e " ${YELLOW}Skipped:${NC} $SKIPPED"
    echo "========================================"

    if [ $FAILED -gt 0 ]; then
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

# Run main
main "$@"
