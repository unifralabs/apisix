# OPTIONS telemetry release gate — 2026-09-13

Production preflight found route 60 (`support-options`) inherits Service 4's
Kafka logger, but did not enable the parser that supplies the v2 log variables.
The shared metadata must not be released with that route left behind.

## Fix

In nomad-config `apisix-config/route/60-support-options.json`, add only:

```json
"unifra-jsonrpc-var": {"network": ""}
```

The existing plugin runs before CORS, skips body parsing for non-POST requests,
and supplies `route_name=support-options`, `transport=http`,
`event_kind=diagnostic`, `schema_version=2`. An explicitly empty network means
this preflight request does not belong to a blockchain; it is not derived from
Host. Raw diagnostics remain available, but the new RPC usage aggregate excludes
them. No new plugin runtime logic, CORS rules, route priority, CU prices,
authorization rules, Redis ledger changes or ClickHouse DDL changes are needed.

## Local verification

- OpenResty `tests/integration/test_telemetry.lua`: PASS, including OPTIONS.
- `test_usage_options.py`: PASS, database `usage_topology_test_389b35dd219b`.
- Real local APISIX 3.14 -> Kafka 3.2 -> ClickHouse 22.10.7.13.
- Before/after CORS status, body and allow headers equal; no OPTIONS reaches mock RPC upstream.
- Two real OPTIONS requests arrive as v2 HTTP diagnostic records with blank network.
- Both are retained in raw/expanded and classified as diagnostic in the excluded view;
  neither produces a new usage aggregate row. Normal private RPC remains 1 CU.
- `test_usage_gateway.py`: database `usage_topology_test_d30fdad7e984`, full existing
  HTTP/WS/public/free/paid/429/legacy contract regression and generation audit.
- The first OPTIONS run hit a retained local wildcard route with equal priority,
  not the new fixture. The test copy now has isolated precedence and is deleted
  after the run; production priority remains 1.
- The old local ClickHouse was slow to reopen historical fault-test queues after
  Docker restart. Its volume was preserved; this run uses a fresh same-version
  internal-network instance, `usage-options-clickhouse-20260913`.

## Deployment ordering

Deploy the already reviewed APISIX telemetry runtime (two plugin files plus
`unifra/jsonrpc/telemetry.lua`) and reload; ensure old workers retire. Then add
the OPTIONS parser configuration, then publish the reviewed Kafka log metadata.
Do not deploy the global metadata first. Verify real OPTIONS, RPC and WS logs.
ClickHouse remains streaming; publishing ready and changing Dashboard query
source are separate stages. Local PASS is not production acceptance.
