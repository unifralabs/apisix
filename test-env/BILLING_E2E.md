# End-to-End Tests for RPC Permissions, Quotas, and CU Billing

## Latest complete test run

On 2026-09-12, the local `bash dev/test-e2e.sh` run finished with exit code **0**:

| Suite | Passed | Failed |
| --- | ---: | ---: |
| Dashboard login, payments, Consumer synchronization, and scheduled expiration | 18 | 0 |
| Public endpoint and HTTP/WS permission regressions | 48 | 0 |
| HTTP/WS/batch/push CU billing and quota matrix | 52 | 0 |
| Actual incremental SQL migration regression | 1 | 0 |
| Lua entitlement resolver, JSON-RPC, and compression checks | 53 | 0 |
| Total | 172 | 0 |

The full Dashboard `tsc --noEmit --incremental false` check also passed, as did
HTTP checks for the login page and Mailpit. The development containers were left
running. The test runner does not commit or push code and performs no production operations.

## Confirmed billing rules

**Client RPC calls consume both the per-second request budget and the monthly
quota. Server subscription notifications consume only the monthly quota.**

The per-second limit is measured in CU/s, not HTTP request count or WebSocket
frame count.

| Scenario | Per-second request budget | Monthly CU | Permission / outcome |
| --- | --- | --- | --- |
| Single HTTP / WS RPC | Method CU cost | Method CU cost | Uses the Consumer's explicit `rpc_tier` |
| HTTP / WS batch | Sum of valid method CU costs | Sum of valid method CU costs | A forbidden method rejects the entire batch; no partial upstream execution |
| Client notification without an id | Method CU cost | Method CU cost | Omitting the id cannot bypass permissions or billing |
| Subscribe / unsubscribe request | Method CU cost; currently defaults to 1 | Method CU cost | Same rules as other client RPC calls |
| Server `newHeads` notification | None | 5 per event | Reserves monthly CU before forwarding |
| Server `logs` notification | None | 10 per event | Includes subscriptions created in a batch |
| Server `newPendingTransactions` notification | None | 20 per event | Includes events containing only a transaction hash |
| Other subscription event | None | Currently defaults to 5 per event | Uses the configured default event cost |
| WS Ping/Pong/Close | None | None | Pong must preserve the original Ping payload |
| Permission / parsing / per-second rejection | No additional admitted request CU | None | Does not reach the upstream |
| Monthly quota rejection | The earlier per-second check may already have consumed request capacity | None | Does not reach the upstream; no partial batch charge |
| Upstream RPC execution error | Already consumed | Already charged | Preserves admission-based billing; no refund based on the execution result |
| Insufficient monthly quota for a notification | None | No additional charge | Does not forward the event; Close 1008 |
| Notification dependency unavailable | None | No billing bypass allowed | Does not forward the event; Close 1011 with the generic `Service temporarily unavailable` reason |

Prices come from `conf/cu-pricing.yaml`. A large quota is not evidence of a paid
RPC entitlement. Monthly ledgers use UTC calendar-month buckets. HTTP, WS, and
multiple API keys belonging to the same user share per-second and monthly quotas
through `quota_key`. Payment renewal neither changes the Redis calendar-month
bucket nor clears the Redis ledger.

## Run the complete suite, including Dashboard

Place the three repositories side by side: `apisix`, `unifra_dashboard`, and
`nomad-config`.

```bash
cd /path/to/unifra_dashboard
bash dev/test-e2e.sh
```

The entry point uses the fixed `docker-compose.dev.yml` file, the fixed
`unifra-dashboard-dev` project, and `--env-file /dev/null`. It does not load the
production Compose file or production `.env`. The backend network has
`internal: true`, and test upstreams point only to the local mock. PostgreSQL,
Redis, etcd, and the APISIX Admin API have no published host ports. Only Dashboard
and the test mailbox are published on loopback addresses.

Execution order: build and start the development environment; test the actual
incremental migration; test Dashboard login, payments, Consumer synchronization,
and scheduled expiration; run 48 public-configuration and permission regressions;
run 52 billing matrix cases; run 53 Lua core, compression, and entitlement checks;
run the full Dashboard TypeScript check; check the login page.

Any failed step returns a nonzero exit status and prevents the final success
message. A successful run leaves the development environment running.

To rerun only the billing matrix from the Dashboard repository:

```bash
docker compose --env-file /dev/null -p unifra-dashboard-dev -f docker-compose.dev.yml \
  run --rm gateway-tests
```

Alternatively, run it in the standalone APISIX test stack after starting
`docker-compose.access.yml`:

```bash
docker compose -p unifra-access-test -f test-env/docker-compose.access.yml \
  run --rm tests python -B /tests/test_billing_e2e.py
```

After changing Lua code, restart the corresponding local APISIX container first.
Rerunning Python alone does not refresh Lua already loaded by the workers.

## Coverage and assertions

`test_billing_e2e.py` contains 52 cases, each with multiple actual RPC calls and
ledger assertions:

- Free / paid × HTTP / WS × single / batch × per-second / monthly limits:
  exact boundaries, rejection above the limit, and recovery after the per-second
  window. A high free monthly quota does not grant debug access; a low paid
  monthly quota does not remove debug access.
- Permission checks across tiers, transports, and request shapes; exact,
  default, and debug/trace wildcard CU prices over both HTTP and WS.
- All-or-nothing batch rejection and billing when the remaining monthly quota
  covers only part of the batch. When 20 concurrent requests compete for 3 CU,
  exactly 3 reach the upstream, verifying Redis Lua atomicity.
- gzip, incorrect Content-Type, client notifications without ids,
  notification-only batches, and mixed notification batches; WS binary frames,
  fragmentation, restoration of original request ids, and Ping/Pong.
- Shared user quotas across HTTP, WS, and multiple API keys; shared monthly
  quotas across multiple subscription connections and HTTP.
- Four notification types for both free and paid users; notifications leave the
  per-second request ledger unchanged and stop when the monthly quota is exhausted.
- JSON subscription events sent by the upstream in binary frames are also
  charged; frame type cannot bypass the monthly quota.
- Event-type correlation for batch subscriptions, stopping notifications after
  unsubscribe, and fail-closed behavior during a Redis outage.
- UTC monthly-key isolation, month-end TTL, and admission-based billing for
  upstream business errors.

Each normal allow/reject case checks the response, the actual Redis monthly CU
delta, and the number of RPC calls received by the mock. Dedicated rate-limit and
notification cases also inspect the Redis per-second window. All test accounts
have randomized prefixes; the suite never executes `FLUSHDB`. Fault injection
runs last and briefly pauses only the isolated Redis. It does not stop
production Redis or a Redis instance on the host.

## Verification boundaries

These local end-to-end tests use real Dashboard, NextAuth, PostgreSQL, APISIX,
and Redis services. External chain nodes, payment services, and email delivery
are replaced with a controllable RPC mock, signed callbacks, and Mailpit,
respectively. The tests do not connect to real chain nodes or payment accounts,
and they do not send external email.

The gateway's Redis ledger is the source of truth for CU deduction assertions.
This stack does not deploy Kafka or ClickHouse, so it does not verify
asynchronous log delivery, ClickHouse ingestion latency, or production data
consistency in Dashboard historical charts. Kafka-unavailable warnings in WS
logs are expected in this reduced stack.

CU is reserved before sending to the upstream or client; there is no
delivery-acknowledgment transaction. If the network fails after a charge, or the
result of a Redis command is uncertain, the system does not promise cross-network
exactly-once billing or automatic refunds. Billing failures must not allow
notifications to continue for free. These tests do not imply a guarantee against
every possible overcharge.
