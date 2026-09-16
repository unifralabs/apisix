#!/usr/bin/env bash

set -euo pipefail

: "${APISIX_ADMIN_URL:?Set APISIX_ADMIN_URL, for example http://apisix3:9180}"
: "${APISIX_ADMIN_KEY:?Set APISIX_ADMIN_KEY}"

curl --fail --silent --show-error \
  --request PUT \
  "${APISIX_ADMIN_URL%/}/apisix/admin/routes/rpc-capabilities" \
  --header "X-API-KEY: ${APISIX_ADMIN_KEY}" \
  --header "Content-Type: application/json" \
  --data '{
    "name": "rpc-capabilities",
    "uri": "/apisix/plugin/unifra-whitelist/capabilities",
    "methods": ["GET"],
    "plugins": {
      "public-api": {}
    }
  }'

printf '\nRPC capabilities route configured.\n'
