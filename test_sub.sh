#!/usr/bin/env bash
# WS_URL must include the API key when required. Do not enable shell tracing.
set -euo pipefail
: "${WS_URL:?Set WS_URL to the WebSocket endpoint to test}"
command -v wscat >/dev/null || { echo 'Install wscat before running this script.' >&2; exit 1; }

test_run="test-sub-$(date +%s)"
printf 'Starting subscription test: %s\n' "$test_run"
wscat -c "$WS_URL" -x "{\"jsonrpc\":\"2.0\",\"method\":\"eth_subscribe\",\"params\":[\"newHeads\"],\"id\":\"$test_run\"}" -w 6

# Optional Kafka UI lookup; complete messages API URL without a query.
if [[ -n "${KAFKA_MESSAGES_URL:-}" ]]; then
  command -v jq >/dev/null || { echo 'Install jq for Kafka lookups.' >&2; exit 1; }
  sleep 3
  curl --fail --silent --show-error --get "$KAFKA_MESSAGES_URL" \
    --data-urlencode 'keySerde=String' --data-urlencode 'valueSerde=String' \
    --data-urlencode 'limit=200' --data-urlencode "q=$test_run" |
    sed -n 's/^data://p' | jq -r 'select(.type == "MESSAGE") | .message.content'
fi
