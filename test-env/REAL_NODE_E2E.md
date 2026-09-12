# Local APISIX → real Arc / DogeOS acceptance

Verified 2026-09-12. This supplements the 1,194 local mock/pure regression
checks in [RPC_POLICY.md](RPC_POLICY.md); it does not replace those fault tests.

## Environment and safety

- Local APISIX 3.14 runs the working checkout's plugins and configuration.
- Admin API, etcd, test Consumers and Redis quota ledgers are local only.
- Actual upstream addresses come from the sibling nomad-config checkout:
  `600/601`: DogeOS `10.142.0.16:8545/8546`; `650/651`: Arc
  `10.142.0.28:8545/8546`. The returned chain IDs were verified as 6281971
  and 5042002 respectively.
- The opt-in Compose overlay gives only APISIX an egress network. No host
  ports are published. Kafka is explicitly directed to local loopback, not a
  production broker. Production health-check configuration is not imported.
- Sequential requests, 150 ms pacing, simulated gas ≤100,000, no broadcasts,
  management calls, load testing or production gateway/config/DB changes.
- HTTP filters are uninstalled; WS subscriptions are unsubscribed and sockets
  closed (including failure cleanup). No multi-instance test was requested.

## Final acceptance results

| Actual backend | HTTP checks | WS checks |
| --- | ---: | ---: |
| DogeOS testnet | 37 | 37 |
| Arc testnet | 41 | 41 |
| Total | 78 | 78 |

**156 passed, 0 failed**: the final main suite passed 151 checks; five Arc WS
block-tracing checks initially skipped for safe-load selection then passed in
a supplemental run using the same small block verified in the HTTP run.

Coverage includes free/paid/public identity, permissions, real call simulation,
callMany/simulate internal CU, latest proofs, storage-slot pricing, denied
ranges/tracers, mixed-batch permission rejection and successful batch billing,
positive monthly/per-second limits, filter ownership and cleanup, subscriptions,
real newHeads delivery and actual local Redis deductions.

- DogeOS real push: 1 event, total 7 CU (subscribe 1 + push 5 + unsubscribe 1).
- Arc real push: 8 events, total 42 CU (subscribe 1 + pushes 40 + unsubscribe 1).
- DogeOS blocks `0x74d20c` / `0x74d212`: zero gas, empty blocks. Five block
  trace methods were verified over HTTP and WS, but these are not evidence of
  non-empty DogeOS transaction tracing.
- Arc block `0x3ae1802`: gasUsed `0x13704` (79,620), two transactions. Five
  block trace methods passed over HTTP and WS. The WS supplemental run
  rechecked size/gas before forwarding any trace request.
- Arc transaction `0x88d29c81da005acbbcff3f8b3dcf5d1c1d1ff286ecbd6dc1beaa5e765fe7ed67`:
  gas limit rechecked ≤100,000. `trace_transaction`, `trace_get`,
  `trace_replayTransaction` and `debug_traceTransaction` passed on both transports.

## Issues found while building real-node tests

1. Both nodes rejected the earlier saved block for eth_getProof with
   `distance to target block exceeds maximum proof window`. `latest` succeeded
   over HTTP/WS. The exact retention window was not measured; Dashboard now
   documents node-dependent historical availability. This is not a gateway
   permission failure, and admitted backend errors still consume CU.
2. Existing zero-valued CU quotas mean unlimited. Tests were corrected to
   exceed a positive cap with a two-member batch, not change quota semantics.
3. The first test incorrectly used the HTTP six-second timeout for WS too.
   Tests now use the actual upstream timeouts from nomad-config (WS 70 seconds,
   capped by the new gateway policy to 60 seconds).
4. Real subscription pushes interleave with RPC replies. The test receiver now
   separates notifications and matches response IDs, then checks push billing.

These findings required test corrections and documentation, not plugin runtime
changes. Early failed runs are not counted as passing acceptance results.

## Reproduce

Requires access from Docker to the configured private IPs. No production Admin
API credentials or production database credentials are needed.

```sh
docker compose -p unifra-real-nodes -f test-env/docker-compose.access.yml -f test-env/docker-compose.real-nodes.yml up -d
docker compose -p unifra-real-nodes -f test-env/docker-compose.access.yml -f test-env/docker-compose.real-nodes.yml run --rm tests python -B /tests/test_real_nodes.py --config-dir /configs --allow-real-nodes
docker compose -p unifra-real-nodes -f test-env/docker-compose.access.yml -f test-env/docker-compose.real-nodes.yml down
```

Tests deliberately skip block tracing when no block with ≤500,000 gas and
≤4 transactions appears in an eight-block window; they do not silently raise
load thresholds to achieve a green result. Counts can therefore vary by run.
Data-dependent skips must be recorded or supplemented with a verified small
block before claiming that particular case passed. No real signed transaction
was submitted; broadcast/raw-transaction behavior is not covered here.
