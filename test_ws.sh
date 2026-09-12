#!/usr/bin/env bash
# WS_URL must include the API key when required. Do not enable shell tracing.
set -euo pipefail
: "${WS_URL:?Set WS_URL to the WebSocket endpoint to test}"
command -v wscat >/dev/null || { echo 'Install wscat before running this script.' >&2; exit 1; }

test_run=$(date +%s)
single_id="test-single-$test_run"
batch_id_1="test-batch1-$test_run"
batch_id_2="test-batch2-$test_run"
subscription_id="test-sub-$test_run"

printf 'Single request: %s\n' "$single_id"
wscat -c "$WS_URL" -x "{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":\"$single_id\"}"

printf 'Batch request: %s, %s\n' "$batch_id_1" "$batch_id_2"
wscat -c "$WS_URL" -x "[{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":\"$batch_id_1\"},{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":\"$batch_id_2\"}]"

printf 'Subscription (6 seconds): %s\n' "$subscription_id"
wscat -c "$WS_URL" -x "{\"jsonrpc\":\"2.0\",\"method\":\"eth_subscribe\",\"params\":[\"newHeads\"],\"id\":\"$subscription_id\"}" -w 6

# Optional Kafka UI lookup; complete messages API URL without a query.
if [[ -n "${KAFKA_MESSAGES_URL:-}" ]]; then
  command -v jq >/dev/null || { echo 'Install jq for Kafka lookups.' >&2; exit 1; }
  sleep 3
  curl --fail --silent --show-error --get "$KAFKA_MESSAGES_URL" \
    --data-urlencode 'keySerde=String' --data-urlencode 'valueSerde=String' \
    --data-urlencode 'limit=200' --data-urlencode "q=$test_run" |
    sed -n 's/^data://p' | jq -r 'select(.type == "MESSAGE") | .message.content'
fi
