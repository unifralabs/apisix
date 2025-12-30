#!/bin/bash
#
# Sync APISIX plugin schema to Dashboard
#
# This script exports the plugin schema from APISIX and saves it for Dashboard.
# Run this after adding/modifying Unifra plugins.
#
# Usage: ./sync-schema.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_FILE="${SCRIPT_DIR}/schema.json"

echo "Syncing APISIX plugin schema to Dashboard..."

# Check if APISIX is running
if ! docker-compose ps apisix | grep -q "Up"; then
    echo "Error: APISIX container is not running."
    echo "Start it with: docker-compose up -d apisix"
    exit 1
fi

# Export schema from APISIX control API (port 9090, localhost only)
echo "Exporting schema from APISIX..."
docker run --rm --network container:unifra-apisix curlimages/curl -s \
    http://127.0.0.1:9090/v1/schema > "${SCHEMA_FILE}.tmp"

# Validate JSON
if ! jq empty "${SCHEMA_FILE}.tmp" 2>/dev/null; then
    echo "Error: Invalid JSON received from APISIX"
    rm -f "${SCHEMA_FILE}.tmp"
    exit 1
fi

# Check if Unifra plugins are present
UNIFRA_PLUGINS=$(jq -r '.plugins | keys[] | select(startswith("unifra-"))' "${SCHEMA_FILE}.tmp" | wc -l)
if [ "$UNIFRA_PLUGINS" -eq 0 ]; then
    echo "Warning: No Unifra plugins found in schema!"
fi

mv "${SCHEMA_FILE}.tmp" "${SCHEMA_FILE}"

echo "Schema saved to ${SCHEMA_FILE}"
echo "Found ${UNIFRA_PLUGINS} Unifra plugins:"
jq -r '.plugins | keys[] | select(startswith("unifra-"))' "${SCHEMA_FILE}" | sed 's/^/  - /'

# Restart Dashboard to pick up new schema
echo ""
echo "Restarting Dashboard..."
docker-compose restart dashboard

echo ""
echo "Done! Dashboard now has Unifra plugin schema."
echo "Access Dashboard at: http://localhost:9000"
