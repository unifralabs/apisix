# Manual WebSocket diagnostics

Install `wscat` before running the scripts. Set `WS_URL` in your local shell to
the complete endpoint (including an API key if required), then run from the
repository root:

```bash
bash test_ws.sh
bash test_sub.sh
```

The scripts send read-only JSON-RPC calls and a six-second `newHeads`
subscription to the endpoint you select. They consume its normal RPC quota.
They do not print the endpoint or save a response file.

For an optional Kafka UI lookup, set `KAFKA_MESSAGES_URL` to the complete
messages API URL without query parameters. Install `jq` for this option.
Queries use the generated request ID. Without this variable, Kafka is skipped.

Keep credentials outside version control. Do not run these scripts with shell
tracing (`bash -x`), which prints arguments including the endpoint's API key.
For repeatable isolated tests, use `test-env/ACCESS_TESTS.md` and
`test-env/BILLING_E2E.md`.
