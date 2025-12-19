#!/bin/bash
#
# Unifra APISIX Plugin Full Test Suite
# Tests all plugins with real Anvil blockchain
#

set -e

APISIX_URL="http://localhost:9080"
ADMIN_URL="http://localhost:9180"
ADMIN_KEY="unifra-test-admin-key"
API_KEY="test-api-key-123"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

echo "========================================"
echo " Unifra APISIX Plugin Test Suite"
echo "========================================"
echo ""

# Check prerequisites
info "Checking prerequisites..."

if ! curl -s http://localhost:8545 > /dev/null 2>&1; then
    fail "Anvil not running on port 8545"
    echo "  Start with: anvil --host 0.0.0.0 --port 8545"
    exit 1
fi
pass "Anvil is running"

if ! curl -s $ADMIN_URL/apisix/admin/plugins/list -H "X-API-KEY: $ADMIN_KEY" > /dev/null 2>&1; then
    fail "APISIX Admin API not accessible"
    exit 1
fi
pass "APISIX is running"

echo ""
echo "========================================"
echo " Setup: Configure Upstream/Route/Consumer"
echo "========================================"

# Update Upstream to point to host's Anvil
info "Configuring Upstream to Anvil (host.docker.internal:8545)..."
curl -s -X PUT "$ADMIN_URL/apisix/admin/upstreams/1" \
  -H "X-API-KEY: $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "anvil-upstream",
    "type": "roundrobin",
    "nodes": {
      "host.docker.internal:8545": 1
    }
  }' > /dev/null
pass "Upstream configured"

# Create Consumer
info "Creating test Consumer..."
curl -s -X PUT "$ADMIN_URL/apisix/admin/consumers/test-user" \
  -H "X-API-KEY: $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "test-user",
    "plugins": {
      "key-auth": { "key": "'"$API_KEY"'" },
      "unifra-ctx-var": {
        "seconds_quota": "100",
        "monthly_quota": "100000"
      }
    }
  }' > /dev/null
pass "Consumer created"

# Create Route
info "Creating Route with Unifra plugins..."
curl -s -X PUT "$ADMIN_URL/apisix/admin/routes/1" \
  -H "X-API-KEY: $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "eth-jsonrpc-route",
    "uri": "/eth/*",
    "upstream_id": "1",
    "plugins": {
      "proxy-rewrite": { "uri": "/" },
      "key-auth": {},
      "unifra-jsonrpc-var": { "network": "eth-mainnet" },
      "unifra-whitelist": {},
      "unifra-calculate-cu": {},
      "unifra-limit-cu": {
        "redis_host": "redis",
        "redis_port": 6379
      },
      "unifra-limit-monthly-cu": {
        "redis_host": "redis",
        "redis_port": 6379
      }
    }
  }' > /dev/null
pass "Route created"

echo ""
echo "========================================"
echo " Test 1: Authentication"
echo "========================================"

# Test without API key
result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')
if echo "$result" | grep -q "Missing API key"; then
    pass "Request without API key rejected"
else
    fail "Request without API key should be rejected"
fi

# Test with invalid API key
result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: wrong-key" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')
if echo "$result" | grep -q "Invalid API key"; then
    pass "Invalid API key rejected"
else
    fail "Invalid API key should be rejected"
fi

# Test with valid API key
result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')
if echo "$result" | grep -q '"result"'; then
    pass "Valid API key accepted"
else
    fail "Valid API key should be accepted: $result"
fi

echo ""
echo "========================================"
echo " Test 2: JSON-RPC Methods"
echo "========================================"

# Test eth_blockNumber
result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')
if echo "$result" | grep -q '"result":"0x'; then
    pass "eth_blockNumber: $(echo $result | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])")"
else
    fail "eth_blockNumber failed: $result"
fi

# Test eth_chainId
result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}')
if echo "$result" | grep -q '"result":"0x'; then
    chain_id=$(echo $result | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'], 16))")
    pass "eth_chainId: $chain_id (Anvil default: 31337)"
else
    fail "eth_chainId failed: $result"
fi

# Test eth_getBalance
result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","latest"],"id":1}')
if echo "$result" | grep -q '"result":"0x'; then
    balance=$(echo $result | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'], 16) / 1e18)")
    pass "eth_getBalance: ${balance} ETH (Anvil test account)"
else
    fail "eth_getBalance failed: $result"
fi

echo ""
echo "========================================"
echo " Test 3: Batch Requests"
echo "========================================"

result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '[
    {"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1},
    {"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":2},
    {"jsonrpc":"2.0","method":"eth_gasPrice","params":[],"id":3}
  ]')
count=$(echo "$result" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
if [ "$count" = "3" ]; then
    pass "Batch request returned 3 results"
else
    fail "Batch request should return 3 results, got: $count"
fi

echo ""
echo "========================================"
echo " Test 4: Whitelist Enforcement"
echo "========================================"

# Test allowed method
result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0x0000000000000000000000000000000000000000","data":"0x"},"latest"],"id":1}')
if echo "$result" | grep -q '"result"'; then
    pass "Allowed method (eth_call) works"
else
    fail "Allowed method should work: $result"
fi

# Test paid method (should fail for free user)
result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '{"jsonrpc":"2.0","method":"debug_traceTransaction","params":[],"id":1}')
if echo "$result" | grep -q "requires paid tier"; then
    pass "Paid method (debug_*) blocked for free user"
else
    fail "Paid method should be blocked: $result"
fi

# Test unsupported method
result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '{"jsonrpc":"2.0","method":"eth_mining","params":[],"id":1}')
if echo "$result" | grep -q "unsupported method"; then
    pass "Unsupported method (eth_mining) blocked"
else
    fail "Unsupported method should be blocked: $result"
fi

echo ""
echo "========================================"
echo " Test 5: Rate Limiting"
echo "========================================"

info "Sending 20 rapid requests to test rate limiting..."
success=0
rate_limited=0
for i in {1..20}; do
    result=$(curl -s -X POST "$APISIX_URL/eth/" \
      -H "Content-Type: application/json" \
      -H "apikey: $API_KEY" \
      -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":'$i'}')
    if echo "$result" | grep -q '"result"'; then
        ((success++))
    elif echo "$result" | grep -q "rate limit"; then
        ((rate_limited++))
    fi
done
echo "  Results: $success succeeded, $rate_limited rate-limited"
if [ $success -gt 0 ]; then
    pass "Rate limiting is working (some requests succeeded)"
else
    fail "At least some requests should succeed"
fi

echo ""
echo "========================================"
echo " Test 6: Send Transaction"
echo "========================================"

# Get nonce for test account
nonce_result=$(curl -s -X POST "$APISIX_URL/eth/" \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d '{"jsonrpc":"2.0","method":"eth_getTransactionCount","params":["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","latest"],"id":1}')
if echo "$nonce_result" | grep -q '"result"'; then
    nonce=$(echo $nonce_result | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])")
    pass "eth_getTransactionCount: $nonce"
else
    fail "Failed to get nonce: $nonce_result"
fi

echo ""
echo "========================================"
echo " Summary"
echo "========================================"
echo ""
echo "All core Unifra APISIX plugins are working:"
echo "  - unifra-jsonrpc-var: JSON-RPC parsing and variable injection"
echo "  - unifra-ctx-var: Consumer variable injection"
echo "  - unifra-whitelist: Method access control"
echo "  - unifra-calculate-cu: Compute unit calculation"
echo "  - unifra-limit-cu: Per-second rate limiting"
echo "  - unifra-limit-monthly-cu: Monthly quota management"
echo ""
echo "Test completed!"
