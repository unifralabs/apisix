#!/bin/bash
#
# Setup staging routes for Unifra APISIX
#
# Usage: ./setup-routes.sh [ADMIN_KEY]
#

set -e

ADMIN_KEY="${1:-staging-admin-key-change-me}"
ADMIN_URL="http://localhost:9180/apisix/admin"

echo "Setting up staging routes..."

# Helper function
api() {
    local method=$1
    local path=$2
    local data=$3
    curl -s -X "$method" "${ADMIN_URL}${path}" \
        -H "X-API-KEY: ${ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "$data"
}

# Create upstreams
echo "Creating upstreams..."

api PUT "/upstreams/eth-mainnet" '{
    "name": "eth-mainnet-staging",
    "type": "roundrobin",
    "scheme": "http",
    "nodes": {
        "your-eth-node:8545": 1
    }
}'

api PUT "/upstreams/polygon" '{
    "name": "polygon-staging",
    "type": "roundrobin",
    "scheme": "http",
    "nodes": {
        "your-polygon-node:8545": 1
    }
}'

# Create routes
echo ""
echo "Creating routes..."

api PUT "/routes/eth-mainnet" '{
    "name": "staging-eth-mainnet",
    "host": "staging-eth-mainnet.unifra.io",
    "uri": "/v1/*",
    "methods": ["POST", "GET"],
    "upstream_id": "eth-mainnet",
    "plugins": {
        "proxy-rewrite": {"regex_uri": ["^/v1/[^/]+/(.*)", "/$1"]},
        "unifra-jsonrpc-var": {"network": "eth-mainnet"},
        "unifra-whitelist": {},
        "unifra-calculate-cu": {},
        "key-auth": {"header": "X-API-KEY", "hide_credentials": true}
    }
}'

api PUT "/routes/polygon" '{
    "name": "staging-polygon",
    "host": "staging-polygon.unifra.io",
    "uri": "/v1/*",
    "methods": ["POST", "GET"],
    "upstream_id": "polygon",
    "plugins": {
        "proxy-rewrite": {"regex_uri": ["^/v1/[^/]+/(.*)", "/$1"]},
        "unifra-jsonrpc-var": {"network": "polygon"},
        "unifra-whitelist": {},
        "unifra-calculate-cu": {},
        "key-auth": {"header": "X-API-KEY", "hide_credentials": true}
    }
}'

echo ""
echo "Done! Routes configured:"
echo "  - staging-eth-mainnet.unifra.io/v1/{api-key}"
echo "  - staging-polygon.unifra.io/v1/{api-key}"
echo ""
echo "Create a test consumer:"
echo "  curl -X PUT '${ADMIN_URL}/consumers/test-user' \\"
echo "    -H 'X-API-KEY: ${ADMIN_KEY}' \\"
echo "    -d '{\"username\":\"test-user\",\"plugins\":{\"key-auth\":{\"key\":\"test-api-key\"}}}'"
