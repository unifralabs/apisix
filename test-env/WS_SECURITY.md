# Arc / DogeOS WS security regression

The findings and 434-test table below describe the original isolated security
patch d3751986. Subsequent configuration-selected RPC policy adds DogeOS trace
permissions and explicit free-method/parameter limits; see [RPC_POLICY.md](RPC_POLICY.md).

## Scope and findings (2026-09-12, local only)

No production requests, Admin API writes, node management calls, or deployment.
The test uses the existing isolated `docker-compose.access.yml` stack: real
APISIX 3.14, etcd and Redis; the upstream is a dependency-free HTTP/WS mock.
The Docker network is internal and exposes no host ports.

The test imports the local Nomad repository's actual Service 3 and routes 6002
(DogeOS testnet) / 6502 (Arc testnet). Service authentication, URI rewriting,
connection limits and permissive HTTP method lists are retained. Upstream IDs
are replaced with the mock, and plugin metadata/Consumers use local test values.
No production credentials or upstream configuration is imported.

Before the fix, six baseline checks reproduced the problem:

- On both networks, a free Consumer's ordinary POST to `/ws/<key>` containing
  `debug_traceTransaction` reached the mock, bypassing paid-method authorization.
- On both networks, the same POST from a paid Consumer with only 1 monthly CU
  reached the mock, bypassing the WS monthly admission check.
- On both networks, paid `debug_setHead` over WS reached the mock.

These results prove the gateway path under a dual-protocol upstream, not that
the live production upstream accepts HTTP on its WS port. Actual production
exploitability was deliberately not probed.

Final local run on an exported security-only Git index snapshot (no telemetry
module, logger changes, or schema-v2 fields included):

| Suite | Passed | Failed |
| --- | ---: | ---: |
| Arc/DogeOS security regression | 290 | 0 |
| Existing public/HTTP/WS access regression | 42 | 0 |
| Existing CU billing/quota matrix | 52 | 0 |
| Lua entitlement/core/compression checks | 50 | 0 |
| Total | 434 | 0 |

`git diff --check` passed. The six pre-fix reproduction checks are evidence of
the old vulnerability and are not counted as post-fix regression passes.

## Changes

- The common WS plugin rejects invalid handshakes before connecting upstream.
  In particular, a non-Upgrade request no longer falls through to HTTP proxying.
  It checks GET, Upgrade/Connection headers, version 13 and a 16-byte nonce.
  This protects every route using this plugin, even with old permissive methods.
- Only `dogeos-testnet` and `arc-testnet` permission lists are narrowed.
  Four explicitly priced debug tracing methods remain paid. Arc also keeps nine
  explicitly enumerated trace methods; DogeOS does not acquire trace access.
- Management/unknown methods such as `debug_setHead`, `debug_chaindbCompact`,
  `debug_startCPUProfile`, `debug_writeMemProfile`, `debug_traceBlockFromFile`,
  `debug_foo` and `trace_foo` now fail whitelist matching even for paid users.
  Their error is unsupported method (-32601), not an invitation to upgrade.
- No pricing changes, Consumer migrations, PostgreSQL changes, Dashboard
  changes or Nomad route changes are needed for this fix. The security release
  excludes the separate telemetry work.

The remaining free `eth_*`, `net_*`, `web3_*` patterns are unchanged. This is
not an exhaustive allowlist/parameter-cost audit: for example node-held-account
signing APIs under `eth_*`, newly added expensive methods, custom tracer
parameters and resource caps still need separate review. Upstream support for
each retained tracing method has not been verified against the live nodes.

## Run

From the APISIX repository with adjacent `../nomad-config`:

```sh
docker compose -p unifra-access-test -f test-env/docker-compose.access.yml up -d
docker compose -p unifra-access-test -f test-env/docker-compose.access.yml restart apisix
docker compose -p unifra-access-test -f test-env/docker-compose.access.yml run --rm tests \
  python -B /tests/test_ws_security.py --config-dir /configs
docker compose -p unifra-access-test -f test-env/docker-compose.access.yml run --rm tests
docker compose -p unifra-access-test -f test-env/docker-compose.access.yml run --rm tests \
  python -B /tests/test_billing_e2e.py
```

Run these suites sequentially: they share only this disposable test gateway and
mock counter. Do not run them concurrently with other tests of that gateway.
The optional `--baseline` switch asserts the old vulnerabilities and therefore
must **fail on fixed code**; never restore vulnerable code on production to use it.

Coverage includes free/paid/public HTTP and actual WS routes, exhausted monthly
quota, CU/s rejection, allowed trace methods, denied administration/unknown
methods, malformed handshakes, mixed-case valid handshakes, mixed batches,
notifications, binary fragmented frames, connection reuse and subscriptions.
Every RPC allow/deny assertion checks the mock call counter. The billing suite
also checks the actual Redis ledger; its old fictional debug/trace success
fixtures were replaced with explicitly allowed methods. The shared WS client
now sends an RFC 6455-compliant 16-byte nonce (the old fixture used 17 bytes).

## Release boundary

Deploy this security change independently of telemetry. The effective change
requires both the new plugin code and updated whitelist file. Existing WS
connections can retain old worker code after a graceful reload, so the security
rollout must explicitly drain/terminate old connections as appropriate.
No plugin metadata update or Consumer resend is required by this security fix.
