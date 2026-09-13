# Production DDL snapshot → isolated local migration rehearsal

Date: 2026-09-13. Result: **PASS for the local checks below; no production migration executed.**

## Source and isolation

- Authorized production snapshot plan ID:
  `ef427aab9b8614c47621716226401f2c8caacecd2ecb62dd1b5b1521e1993f0e`.
- Migration module SHA-256:
  `3fc280327a079b89676052e2abdbf81aa7c7415e292a07671fb037fd576a3fd1`.
- Backup contains 19 objects. Restore scope is the **12 objects touched/referenced by this migration**:
  three raw tables, two Kafka queue tables, two old aggregate tables and five materialized views.
  Seven unrelated/internal/external objects and account grants are not executed.
- Host-side exporter verifies backup hashes and plan fingerprint, replaces the database qualifier,
  Kafka broker/topic/group, rejects unexpected Kafka settings and external connection expressions.
  Columns, partitioning, primary/sort keys, TTL, views, parser and skip-broken settings remain from
  the actual snapshot. In particular, restored queue skip policy remains production's `1`, not
  the handcrafted fixture's `0`.
- Docker receives only the sanitized fixture; full backup, grants and production environment files
  are not mounted. The existing `unifra-dashboard-dev_backend` network is `Internal=true`.
  ClickHouse 22.10.7.13, native Kafka 3.2 and APISIX 3.14 run locally; RPC upstream is the local mock.
  No production business rows are copied, no production RPC or Kafka connections are made.
- All 12 restored definitions match the source after approved substitutions and whitespace
  normalization of server SHOW CREATE, in each of the three fresh databases below.
- Offline safety tests reject a production broker, non-test consumer group and external table engine.

## Results

| Suite | Local database | Result |
|---|---|---|
| Restore + release lifecycle | `usage_topology_test_f6d8cf7ad12e` | PASS |
| Restore + APISIX/Kafka/ClickHouse/ledger E2E | `usage_topology_test_d003cb96300a` | PASS |
| Restore + real migration CLI | `usage_topology_test_8d142c229b39` | PASS |
| Dashboard usage service/API on E2E database | `usage_topology_test_d003cb96300a` | PASS |
| Existing Dashboard usage-performance / usage-telemetry unit suites | No production access | PASS |

### Release lifecycle and CLI

- Preparation acknowledgement loss, DROP acknowledgement loss, partial ingress creation,
  ready acknowledgement loss, repeated operations and withdrawal/resume all recover as asserted.
- Stored row counts and CU remain consistent after recovery. Existing pre-migration nonzero
  fixture usage is not backfilled into the new generation.
- Invalid approval, stale evidence, wrong plan, nonzero lag evidence, missing WS evidence,
  occupied lock and production-target writes are rejected.
- Old raw engines/TTL and daily/minute definitions are checked by the actual migration code.
- Local 12-object restore took 6.67–6.71 seconds. Release preparation with injected lost ACK
  took 13.124 seconds; repeated prepare took 0.006 seconds. Individual tested pause/publish
  operations were below 0.1 seconds. These tiny-fixture measurements are **not production
  pause-time guarantees**, do not include a large generation audit and are not a load benchmark.

### Gateway and usage semantics

- Real local APISIX HTTP, WS request and subscription push travel through native Kafka and the
  restored/migrated ClickHouse graph. Free, paid, public and exhausted-quota cases are exercised.
- Free total **23 CU**, paid total **83 CU**, exhausted account **1 CU**, public owner **1 CU**;
  private totals match the isolated Redis ledgers. No existing ledger is reset.
- Two 429 events remain visible and contribute no billed CU.
- Network, route, transport and event kind match actual ingress; spoofed request headers do not
  change those dimensions. Legacy aliases/defaults still work.
- Four invalid-dimension records and one diagnostic record stay in raw/excluded data, not usage.
- Final raw/expanded/push counts: **27 / 31 / 3**, including explicit contract fixtures.
- Gateway suite uses a test-only ready marker for preview; it does not claim its intentionally
  invalid fixtures satisfy production publication evidence. The separate release suite tests
  the actual pause/audit/publish path with a valid generation.

### Dashboard

- Existing `tests/usage-telemetry-service.ts` invokes the real service and API handler with a test
  session, querying the real migrated local ClickHouse and local Postgres. This is not a browser
  login test or an externally served HTTP response-time measurement.
- Owner **23 CU**, paid **83 CU**, owner WS subtotal **15 CU**; private/public owner isolation,
  forged query user IDs, private/no-store response, invalid ranges and contract failure pass.
- First uncached service call: **48 ms**, **2 ClickHouse queries**. Twenty subsequent cache calls:
  **0 additional queries** (elapsed rounded to 0 ms). No fallback scan of raw tables.
- The intentional wrong-contract test prints `[Usage] Analytics query unavailable` and returns
  the expected 503; it is not an unexplained ingestion failure.
- Separate unit suites pass unknown-history versus zero, partial first day, UTC ranges,
  HTTP/WS dimensions, cache isolation/TTL/coalescing and ledger fallback behavior.

## Reproduce

The reusable runner is `test-env/test_usage_production_ddl.py`; it reuses existing lifecycle,
gateway and CLI suites instead of creating a parallel migration implementation.

1. On the host, export the authorized private backup into a sanitized local fixture:

   ```sh
   python3 -B test-env/test_usage_production_ddl.py --export /AUTHORIZED_PRIVATE_BACKUP_DIR
   ```

2. Confirm the Docker network is internal and run each suite separately:

   ```sh
   docker run --rm --network unifra-dashboard-dev_backend \
     --volume /Users/qiaoxiaorui/github/unifra/apisix/test-env:/tests:ro \
     --volume /Users/qiaoxiaorui/github/unifra/unifra_dashboard/clickhouse:/dashboard/clickhouse:ro \
     --volume /SANITIZED_FIXTURE_FILE:/fixture.json:ro \
     --env CLICKHOUSE_URL=http://usage-clickhouse:8123 \
     --env CLICKHOUSE_USERNAME=usage_test \
     --env CLICKHOUSE_PASSWORD=usage-local-only \
     --env USAGE_TEST_BROKER=usage-kafka32:9092 \
     python:3.12-alpine python -B /tests/test_usage_production_ddl.py \
       --fixture /fixture.json --suite release
   ```

   Repeat with `--suite gateway` and `--suite cli`. Gateway changes shared **local test** route
   fixtures; do not run another gateway suite concurrently. All databases/topics use random IDs.
   Kafka queue readers are detached by suite cleanup; local test databases/topics are retained
   for inspection. Existing Dashboard server configuration is not switched to this test database.

3. Run Dashboard `usage-telemetry-service.ts` using the gateway output's database/free/paid IDs,
   with process-scoped local ClickHouse environment and the existing local Postgres connection.
   Use the installed ts-node and CommonJS compiler override. The running server is not restarted.

## Remaining publication boundaries

- No production SQL writes, Kafka retention changes, deployment, offset reset or history backfill.
- User elected to retain the Kafka 10GiB cap. Recheck actual window, offsets, disk and errors just
  before each production maintenance window; an earlier 17.4h sample is not a guarantee.
- The candidate CLI still intentionally rejects production writes. Production execution entry,
  target/hash authorization and operator recovery commands require separate review/testing;
  do not remove guards just because this rehearsal passed.
- These tests do not certify full production-data restoration, every account/role's effective
  permissions, large-generation audit duration, power-loss behavior or exactly-once delivery.
- Sensitive backup remains at its explicitly authorized temporary destination. Persistent backup
  archival to a different path has not been performed without a user-specified destination.
- Before executing a real migration, review the precise plan again for source/version drift,
  agree on the two short pauses and monitoring owner, then obtain production execution approval.
