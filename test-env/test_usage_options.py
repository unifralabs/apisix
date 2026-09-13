"""Local-only regression for the production OPTIONS route and shared metadata.

Uses the existing isolated gateway/billing fixtures and native Kafka/CH stack.
No production endpoints, identities, offsets or Redis ledgers are accessed.
"""
import copy
import json
import time
from pathlib import Path
from urllib.request import Request, urlopen

from test_access import admin, request, ADMIN, ADMIN_KEY, PROXY, UPSTREAM, rpc, count
from test_usage_gateway import Local, Migration, PREFIX, QUEUES, configure, account, eventually
from test_billing_e2e import success


def preflight():
    req = Request(PROXY + '/options-probe', method='OPTIONS', headers={
        'Host': 'spoof-network.invalid', 'Origin': 'https://example.invalid',
        'Access-Control-Request-Method': 'POST',
        'Access-Control-Request-Headers': 'content-type,x-api-key',
        'X-Network': 'spoof', 'X-Transport': 'ws'})
    with urlopen(req, timeout=10) as response:
        return response.status, response.read(), {
            k.lower(): v for k, v in response.headers.items()
            if k.lower().startswith('access-control-')}


def main():
    c = Local()
    print(json.dumps({'database': c.db, 'local_only': True}), flush=True)
    try:
        c.bootstrap()
        probe = {'user_id': 'readiness', 'app_id': 'probe', 'client_ip': '127.0.0.1',
                 'network': 'arc-testnet', 'duration': 0, 'response_status_code': 200,
                 'time': str(time.time())}
        c.produce([{**probe, 'request': json.dumps(rpc()), 'response': '{}',
                    'total_cu_cost': 0, 'cu_costs': '[0]'}])
        c.produce([{**probe, 'time': time.time(), 'jsonrpc_method': 'eth_subscription',
                    'cu_cost': 0, 'node_id': 'probe', 'service_id': '', 'route_id': '',
                    'request_id': ''}], push=True)
        c.wait(1, 1, 1)
        class Adapter:
            database = c.db
            url = 'http://usage-clickhouse:8123'
            execute = staticmethod(c.sql)
        migration = Migration(Adapter())
        plan = migration.plan()
        migration.prepare(plan)
        migration.resume(plan)
        configure(c)
        route = json.loads(Path('/configs/route/60-support-options.json').read_text())
        assert route['name'] == 'support-options' and route['methods'] == ['OPTIONS']
        assert route['plugins']['unifra-jsonrpc-var'] == {'network': ''}
        route['service_id'] = 'usage-options-local'
        # Existing suites retain a wildcard OPTIONS route at priority 1.
        # Give this local copy deterministic precedence; production priority
        # and all production matching/CORS settings remain unchanged.
        route['priority'] = 1000
        logger = {'broker_list': {c.broker.split(':')[0]: int(c.broker.split(':')[1])},
                  'kafka_topic': c.topic(), 'batch_max_size': 1, 'inactive_timeout': 1,
                  'include_req_body': True, 'include_resp_body': True,
                  'producer_type': 'async', 'cluster_name': 914, 'max_retry_count': 0}
        admin('services/usage-options-local', {'plugins': {'kafka-logger': logger},
                                              'upstream': UPSTREAM})
        old = copy.deepcopy(route)
        del old['plugins']['unifra-jsonrpc-var']
        admin('routes/usage-options-local', old)
        time.sleep(1)
        before_calls = count()
        baseline = preflight()
        assert baseline[0] == 200 and baseline[1] == b''
        assert baseline[2]['access-control-allow-origin'] == '*'
        admin('routes/usage-options-local', route)
        time.sleep(1)
        for _ in range(2):
            assert preflight() == baseline, 'CORS response changed'
        assert count() == before_calls, 'OPTIONS reached RPC upstream'

        def diagnostics():
            rows = c.sql('''SELECT network,route_name,transport,event_kind,schema_version,
                                  sum(total_cu_cost) cu,count() n
                           FROM t_request_metrics WHERE route_name='support-options'
                           GROUP BY network,route_name,transport,event_kind,schema_version''', True)
            assert rows == [{'network': '', 'route_name': 'support-options', 'transport': 'http',
                             'event_kind': 'diagnostic', 'schema_version': 2, 'cu': '0', 'n': '2'}], rows
            assert c.sql(f"SELECT count() n FROM {PREFIX} WHERE route_name='support-options'", True) == [{'n': '0'}]
            assert c.sql(f"SELECT reason,count() n FROM {PREFIX}_excluded WHERE route_name='support-options' GROUP BY reason", True) == [{'reason': 'diagnostic', 'n': '2'}]
        eventually(diagnostics)
        a = account('free')
        success(a.http(rpc()))
        assert a.used() == 1
        def normal_rpc():
            assert c.sql(f"SELECT sum(cu) cu FROM {PREFIX} WHERE user_id='{a.user}'", True) == [{'cu': '1'}]
        eventually(normal_rpc)
        print('PASS CORS unchanged; no upstream calls; two v2 HTTP diagnostics through Kafka/raw/expanded; zero RPC usage; ordinary RPC still 1 CU', flush=True)
    finally:
        request(ADMIN + 'routes/usage-options-local', 'DELETE',
                headers={'X-API-KEY': ADMIN_KEY})
        for name in QUEUES:
            if c.exists(name):
                c.sql('DETACH TABLE ' + name)


if __name__ == '__main__':
    main()
