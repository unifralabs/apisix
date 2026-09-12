# Method access regression tests

For the complete Dashboard + HTTP/WS quota and CU billing matrix, see
[BILLING_E2E.md](BILLING_E2E.md).

This focused Compose stack uses the same APISIX 3.14 image and plugin mount as
the existing test stack, with etcd, Redis and a dependency-free HTTP/WS mock.
The network is Docker `internal`, there are no published ports, no host gateway,
no external upstreams and no persistent volumes. The test runner writes only to
the isolated APISIX service with a test-only Admin API key.

Run from the APISIX repository root. The neighboring `../nomad-config` checkout
is required so the tests can read the actual public Route/Service JSON files:

```bash
docker compose -p unifra-access-test -f test-env/docker-compose.access.yml up -d
docker compose -p unifra-access-test -f test-env/docker-compose.access.yml run --rm tests
docker compose -p unifra-access-test -f test-env/docker-compose.access.yml exec -T apisix \
  resty /opt/unifra-apisix/tests/integration/test_access.lua
docker compose -p unifra-access-test -f test-env/docker-compose.access.yml down
```

After editing Lua code, restart the local APISIX container before rerunning:

```bash
docker compose -p unifra-access-test -f test-env/docker-compose.access.yml restart apisix
```

The tests import production public Service 4 and all four public RPC routes,
remove Kafka logging, and replace upstream references with the local mock. Both
production and staging public service policies are checked. Redis metadata is
created locally; production metadata and credentials are never imported.

Additional local fixtures cover authenticated Consumers, high public/free quotas,
low paid quotas, missing explicit tiers, bypass attempts, spoofed
headers/route variables, unknown networks/methods, missing whitelist files, CORS,
HTTP gzip/batches/notifications, POST Upgrade bypass, WS text/binary/fragmented
messages and repeated messages over one WS connection. Each RPC assertion checks
the mock's call counter as well as the response, proving rejected calls were not
forwarded. Monthly quota rejection is checked independently on HTTP and WS.

The mock and runner use only Python's standard library. WS logging may report an
unavailable Kafka broker because this focused stack intentionally has no Kafka;
this does not change authorization or upstream-call assertions.
