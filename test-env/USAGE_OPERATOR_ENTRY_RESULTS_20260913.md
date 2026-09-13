# Operator-entry preparation and local acceptance

2026-09-13. **PASS; production execution has not been approved or performed.**

## Change scope

- Dashboard: new `clickhouse/usage_telemetry_release.py` operator-only entry,
  offline `tests/usage-operator-safety.py`, and `dev/USAGE_PRODUCTION_RUNBOOK.md`.
- Shared `usage_telemetry_v2.py` only extracts existing write/audit guards into overridable methods.
  Its original class and CLI retain the same local-only defaults. Migration SQL, accounting,
  field definitions and lifecycle are reused, not duplicated or changed by this extraction.
- APISIX repository: add `test-env/test_usage_operator_cli.py` and extend the production-DDL
  fixture runner to dispatch it. This turn does not modify APISIX runtime plugin code.
- No Dashboard UI/API/query changes this turn, no Nomad edits this turn, no image build,
  git commit/push, deployment, production read/write request or Kafka retention change.

## Reviewed inputs and code fingerprints

- Production DDL snapshot plan:
  `ef427aab9b8614c47621716226401f2c8caacecd2ecb62dd1b5b1521e1993f0e`.
- Shared migration module after guard extraction:
  `2fa32b17ffe6b06e7723e42468c9f647a7267c38a82f67234f46721e8abb8888`.
- Final operator bundle hash (legacy client + shared migration + operator entry):
  `ca54084172e604361c14be892fa3dc86c8265b04f0cac7fcedf803f1dadad3a6`.
- Original private production backup is unchanged. The local fixture exporter requires an explicit
  reviewed new source hash when source differs from the backup-time implementation. Only the
  sanitized local fixture is mounted; no production credentials, grants or business rows are used.
- Local internal network, native Kafka3.2 and ClickHouse22.10.7.13 as in the preceding rehearsal.
  Twelve relevant source definitions again match normalized SHOW CREATE in each test database.

## Final acceptance

| Check | Result / evidence |
|---|---|
| New operator CLI with real local Kafka/ClickHouse | PASS: `usage_topology_test_01f6e81519bc` |
| Original migration CLI after shared guard extraction | PASS: `usage_topology_test_b92a238608d7` |
| Existing lost-ACK / partial recovery release suite after guard extraction | PASS: `usage_topology_test_a949e0b0ba05` |
| New offline operator safety checks | PASS, zero network |
| Existing offline legacy/base-CLI production rejection checks | PASS, zero network |
| Python AST syntax / git whitespace checks | PASS |

Earlier operator-entry iteration also passed in `usage_topology_test_fc0f65eace90`;
the final run above includes added permission attestation and unstarted-plan age protection.

### Operator CLI flow exercised

Read-only preflight → unapproved template rejection → prepare → repeat prepare → resume →
HTTP/WS/push fixtures → pause → write Kafka backlog while paused → resume and drain → pause →
publish with separate evidence → repeat publish → withdraw → resume remains withdrawn → status.

- Source historical test data: 1 request CU + 5 push CU. All **6 historical CU are excluded**
  from the new generation; new generation final **8 CU** is correct.
- Final raw counts **4 request / 4 expanded / 2 push**; backlog survives the pause and is consumed
  after resume. No reset/replay or backfill is used.
- Local prepare **13.223 seconds**, repeated prepare 0.186s; resume 0.225–0.238s;
  pause 0.230–0.234s; publish 0.225–0.275s. These are tiny-fixture command wall times,
  not production downtime or large-generation audit estimates.
- The generated authorization template is checked to contain `execution_approved:false`;
  trying it before approval fails without creating the control table.
- Publication cannot use only execution approval: separate fresh rollout evidence is required.
- Tests set attestations only for their own local simulation. They are not production evidence.

### Offline refusal coverage

- No production execution flag, wrong plan/target/action/mode/source hash.
- Blank operator, false/missing checks, numeric `1` instead of literal boolean `true`.
- Expired/future/naive-time approvals; expired/future unstarted plan (24h rule).
- Wrong private permissions, symlink input, output overwrite, altered backup checksum,
  supplied plan differing from the private saved plan.
- Base migration and old backfill CLI still refuse production before SQL.

## Remaining steps, not silently included in this work

1. User-select persistent protected backup archive location; temporary backup must still exist
   and verify before execution. Full instance/business-data disaster recovery is not certified.
2. Review and commit the migration/operator tools, APISIX telemetry and Nomad metadata changes;
   bind exact release commits and check the selected Dashboard image build. No commits made here.
3. Just before the approved window, refresh production state, execution privileges, disk,
   Kafka earliest/current/end offsets and errors. Kafka's accepted10GiB cap remains unchanged.
4. Explicit production rollout approval, named operator/monitoring, then follow the runbook.
   Preflight templates deliberately cannot serve as automatic approval.

No runtime credentials or full production DDL are stored in this report.
