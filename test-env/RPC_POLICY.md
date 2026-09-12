# Configuration-selected RPC access policy

This policy uses RPC method semantics, caller entitlement and configured limits.
It never detects a node client/version and contains no production chain-name
checks. The earlier [node capability audit](RETH_RPC_AUDIT.md) is evidence used
to choose method lists, not a runtime backend dependency.

## Activation

In `conf/whitelist.yaml`, a network opts into the policy explicitly:

```yaml
networks:
  any-evm-network:
    rpc_policy: bounded_evm
    free: [eth_blockNumber, eth_call]
    paid: [trace_call]
```

The profile describes bounded EVM JSON-RPC access, irrespective of which
compatible implementation serves it. Omitting the field preserves the legacy
behavior; unknown profile names fail closed. It does not grant methods: the
explicit free/paid whitelist is still checked first.

Currently only Arc and DogeOS testnet opt in, through configuration. HTTP and
every WS message call `unifra/jsonrpc/rpc_policy.lua`; worker-shared leases and
HTTP filter ownership are implemented in `rpc_resources.lua`.

The normalized request marker is `ctx.jsonrpc.rpc_policy` (HTTP) or
`parsed.rpc_policy` (WS), meaning a configured policy was applied, not a client
type. `policy_methods` in `conf/cu-pricing.yaml` supplies price overrides for
policy-controlled requests. Other networks retain their existing prices.
Unavailable policy pricing rejects requests with a generic 503 rather than
charging an accidental default 1 CU. Logs distinguish this rejection from the
unchanged legacy pricing fallback.

## Implemented behavior

- Arc/DogeOS: explicit method names, including the same nine trace methods;
  no `eth_*`, `debug_*`, `trace_*` permission wildcard. Arc alone lists
  `eth_blobBaseFee`, based on the earlier capability audit.
- `eth_callMany`, `eth_simulateV1`, `eth_getStorageValues`, `eth_getProof` and
  tracing are paid. `eth_createAccessList` remains free with explicit pricing.
- Internal call count, simulated transaction count, storage slots and trace
  block span affect CU. Outer JSON-RPC batch admission remains atomic.
- Calls receive an explicit gas cap (free 1M, paid 5M). No state/block overrides.
- Debug tracing defaults to built-in `callTracer`, maximum 3-second requested
  timeout. Arbitrary JS/opcode tracers are rejected. Trace types are limited to
  `trace`; vmTrace/stateDiff are not enabled by this profile.
- Logs: at most 100 blocks free, 2,000 paid. Public and subscription logs need
  an address/topic filter. A moving tag mixed with a fixed number is rejected;
  use an explicit bounded range or the same tag at both ends.
- trace_filter: maximum 10 blocks and count 100. Omitted range is explicitly
  forwarded as latest/latest, preventing differing backend defaults from
  turning a validated one-block request into an unbounded scan.
- callMany: maximum 10 internal calls; simulateV1: one block, ten transactions;
  storage values: at most ten addresses/32 slots; getProof: at most 32 slots.
- Heavy execution: 2 concurrent operations per account, 8 per network and 16
  total per gateway instance, shared by HTTP/WS and workers. Heavy notifications
  without IDs are rejected. Incomplete/disconnected execution keeps a safety
  lease for up to 120 seconds; disconnect does not prove backend cancellation.
- HTTP filters: authenticated users only, opaque IDs bound to the shared user
  quota key, at most 16 free / 64 paid handles, 1,024 gateway-wide, five-minute
  handle lifetime. Raw upstream IDs and other users' IDs are rejected. Filters
  are HTTP-only; WS clients use subscriptions. Existing raw IDs must be recreated.
- WS subscriptions: 4 free, 16 paid, 2 public per connection. newHeads and
  narrowly filtered logs are free; pending transaction hashes are paid-only.
  Full pending transaction payloads and unknown subscription types are denied.
- WS connections: 4 free, 16 paid, 2 public per identity/IP, 512 gateway-wide;
  reconnect after one hour. Read timeout is capped at 60 seconds.
- Policy-controlled responses are bounded to 2 MiB; WS fragmented request
  accumulation is capped at 1 MiB. Rejected execution is not forwarded/billed;
  admitted execution is not refunded merely because its response is oversized.

## Deployment boundaries

No production deployment was performed. Kafka log/schema changes are parked on
`codex/parked-rpc-telemetry` in APISIX, nomad-config and Dashboard and are not
dependencies of this change. No Consumer resend or plugin metadata rewrite is
needed when existing config paths remain unchanged.

Deploy plugin code, shared modules, whitelist and CU pricing together. APISIX
`limit-conn` must be enabled because its existing shared dictionary stores the
resource leases; the repository's production configuration already enables it.
Restart/drain old workers and WS connections, rather than relying on git pull
to replace loaded Lua. Recreate old filter IDs after the upgrade/restart.

The leases are **per gateway instance, not Redis-cluster-wide**. Multiple
independent gateways require distributed coordination (or appropriate affinity
for filters) and node-global execution limits. Restarting the gateway loses
filter mappings; upstream filters expire according to the node's own lifecycle.
The gateway cannot guarantee CPU cancellation or stop a backend computing a
large response. Verify node-global tracing concurrency, gas/response/log limits,
pruning and execution-time controls separately before production rollout.

Free-to-paid changes (notably getProof, batch simulations and pending streams),
explicit method lists, tracer restrictions, range bounds and filter lifecycle
are compatibility changes. This is broader than the original WS handshake-only
security patch `d3751986` and should be released with client-facing notice.

## Local regression

Use the existing internal Docker mock stack; do not run these against production:

```sh
docker compose -p unifra-rpc-policy -f test-env/docker-compose.access.yml up -d
docker compose -p unifra-rpc-policy -f test-env/docker-compose.access.yml run --rm tests python -B /tests/test_rpc_policy.py --config-dir /configs
docker compose -p unifra-rpc-policy -f test-env/docker-compose.access.yml exec -T apisix resty /opt/unifra-apisix/tests/integration/test_rpc_policy.lua
```

Run the access, WS security and billing suites sequentially on the same test
gateway. Policy tests also use unrelated network names to prove configuration,
not backend or production chain-name detection, selects behavior and pricing.

Verified locally on 2026-09-12 after removing client-type coupling:

| Suite | Passed |
| --- | ---: |
| Pure RPC policy checks | 586 |
| RPC policy HTTP/WS integration | 177 |
| WS security regression | 290 |
| CU/billing regression | 49 |
| Access integration | 42 |
| Access resolver / JSON-RPC core / compression | 50 |
| Total | 1,194 |

All checks passed against the isolated local mock stack. This is not a
production load test or a guarantee of backend execution cancellation.

The subsequent [real-node acceptance](REAL_NODE_E2E.md) added 156 successful
HTTP/WS checks through local APISIX to actual Arc/DogeOS upstreams, including
real subscription pushes and Redis billing. Multi-instance and large-scale
load tests remain outside the requested scope.
