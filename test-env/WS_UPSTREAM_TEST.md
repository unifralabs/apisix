# WS upstream Host / handshake regression

Run from the repository root. This starts a separate APISIX 3.14 + etcd + Redis
environment and a Host-sensitive WS/WSS mock. No host ports are exposed.
The existing local gateway and production configuration are not modified.

## Start and run

Requires Docker Compose and OpenSSL with `-addext` support. Generate temporary
test certificates (the private key is never checked into Git):

```bash
export WS_TEST_CERT_DIR=$(mktemp -d /tmp/arc-ws-e2e.XXXXXX)
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WS_TEST_CERT_DIR/server.key" \
  -out "$WS_TEST_CERT_DIR/server.crt" -days 2 \
  -subj /CN=provider.test \
  -addext 'subjectAltName=DNS:provider.test,DNS:rewrite.test'

# macOS system CA bundle; use your system's PEM bundle path on other platforms.
openssl crl2pkcs7 -nocrl -certfile "$WS_TEST_CERT_DIR/server.crt" \
  -certfile /etc/ssl/cert.pem |
  openssl pkcs7 -print_certs -out "$WS_TEST_CERT_DIR/ca-bundle.crt"

docker compose -p unifra-ws-upstream-test \
  -f test-env/docker-compose.access.yml \
  -f test-env/docker-compose.ws-upstream.yml up -d

docker compose -p unifra-ws-upstream-test \
  -f test-env/docker-compose.access.yml \
  -f test-env/docker-compose.ws-upstream.yml run --rm tests

# Existing WS authentication, authorization, quota, fragmentation and subscription suite
docker compose -p unifra-ws-upstream-test \
  -f test-env/docker-compose.access.yml \
  -f test-env/docker-compose.ws-upstream.yml run --rm tests \
  python -B /tests/test_ws_security.py --config-dir /configs
```

The focused suite imports the real Arc Mainnet WS Route and Service from the
sibling `nomad-config` checkout, substitutes test credentials and upstreams, and
checks the Host, SNI, URI and absence of the client's `apikey` header at the mock.
It tests `node`, `rewrite`, `pass`, WS/WSS switching, single/batch ID restoration,
404/bad-accept rejection before client upgrade, and invalid client credentials.
Kafka is not part of this focused environment; delivery of telemetry is not tested.

## Optional real dRPC smoke test

Only this step enables gateway egress. It reads the current provider path from
`nomad-config/apisix-config/arc-switch.json` and sends `eth_chainId` and
`eth_blockNumber` through the local authenticated WS route. It does not connect to
the production APISIX Admin API. The temporary test gateway contains this key
until the environment is removed, so avoid sharing its configuration/logs.

```bash
docker compose -p unifra-ws-upstream-test \
  -f test-env/docker-compose.access.yml \
  -f test-env/docker-compose.ws-upstream.yml \
  -f test-env/docker-compose.real-nodes.yml up -d apisix

docker compose -p unifra-ws-upstream-test \
  -f test-env/docker-compose.access.yml \
  -f test-env/docker-compose.ws-upstream.yml \
  -f test-env/docker-compose.real-nodes.yml run --rm tests \
  python -B /tests/test_ws_upstream_e2e.py --config-dir /configs --real-drpc
```

## Cleanup

```bash
docker compose -p unifra-ws-upstream-test \
  -f test-env/docker-compose.access.yml \
  -f test-env/docker-compose.ws-upstream.yml \
  -f test-env/docker-compose.real-nodes.yml down
```

Only this dedicated project's containers and networks are removed. Temporary
certificate files remain at `$WS_TEST_CERT_DIR` and can be discarded afterward.

## Verified 2026-09-16

- Focused full-gateway suite: **7 passed, 0 failed**.
- Existing WS security regression: **290 passed, 0 failed**.
- Real dRPC through local APISIX: **101 handshake**, `eth_chainId = 0x13b2`
  (5042), `eth_blockNumber = 0x1415c5d`; original string IDs restored.
- Existing unit and OpenResty client/plugin regression tests are documented by
  `tests/unit/test_ws_upstream.lua` and `tests/integration/test_ws_upstream.lua`.
