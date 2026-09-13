"""Local real APISIX -> Kafka 3.2 -> ClickHouse contract acceptance.

Reuses existing isolated billing fixtures and production-shaped ingestion.
No production credentials/endpoints, no ledger reset, no historical backfill.
This does NOT certify the deployment CLI (the topology is still a fixture).
"""
import json
import os
import sys
import time
from pathlib import Path

from test_access import admin, request, rpc, UPSTREAM, PROXY
from test_billing_e2e import Account, setup, subscribe, push, recv_push, success, code
from test_usage_topology import Local, QUEUES
sys.path.insert(0, '/dashboard/clickhouse')
from usage_telemetry_v2 import Migration, PREFIX


def configure(c, network='arc-testnet', http_upstream=UPSTREAM, ws_upstream=UPSTREAM):
    setup()
    admin('plugin_metadata/kafka-logger', json.loads(
        Path(__file__).with_name('usage-kafka-log-format.json').read_text()))
    host, port = c.broker.split(':')
    admin('plugin_metadata/unifra-ws-jsonrpc-proxy', {
        'redis_host': 'redis', 'redis_port': 6379,
        'kafka_brokers': [{'host': host, 'port': int(port)}],
        'kafka_producer_config': {'producer_type': 'async', 'required_acks': 1}})
    logger = {'broker_list': {host: int(port)}, 'kafka_topic': c.topic(),
              'batch_max_size': 1, 'inactive_timeout': 1,
              'include_req_body': True, 'include_resp_body': True, 'producer_type': 'async',
              'cluster_name': 913, 'max_retry_count': 0}
    http = {'key-auth': {}, 'unifra-jsonrpc-var': {'network': network},
            'unifra-whitelist': {}, 'unifra-calculate-cu': {},
            'unifra-limit-cu': {'allow_degradation': False}, 'unifra-limit-monthly-cu': {},
            'kafka-logger': logger}
    admin('services/usage-private', {'plugins': http})
    admin('routes/billing-http', {'name': network, 'service_id': 'usage-private',
          'uri': '/billing-http', 'host': 'access.test', 'methods': ['POST'], 'upstream': http_upstream})
    admin('routes/billing-ws', {'name': network + '-ws', 'uri': '/billing-ws', 'host': 'access.test',
          'methods': ['GET'], 'enable_websocket': True, 'upstream': ws_upstream, 'plugins': {
              'key-auth': {}, 'unifra-ws-jsonrpc-proxy': {'network': network,
              'enable_rate_limit': True, 'allow_degradation': False,
              'kafka_topic': c.topic(), 'kafka_event_topic': c.topic(True)}}})
    admin('routes/usage-public', {'name': network + '-public', 'uri': '/usage-public',
          'host': 'access.test', 'methods': ['POST'], 'upstream': http_upstream, 'plugins': {
              'unifra-jsonrpc-var': {'network': network},
              'unifra-ctx-var': {'user_id': 'usage-public-' + c.run, 'app_id': 'public', 'rpc_tier': 'free'},
              'unifra-whitelist': {'method_policy': 'free_only'}, 'unifra-calculate-cu': {},
              'kafka-logger': logger}})
    time.sleep(1)


def account(tier, monthly=100000):
    a = Account(tier, monthly=monthly)
    a.user = (os.environ.get('USAGE_PREVIEW_USER') if tier == 'free' and monthly == 100000 else None) or a.key
    admin('consumers/' + a.key, {'username': a.key, 'plugins': {
        'key-auth': {'key': a.key}, 'unifra-ctx-var': {
            'rpc_tier': tier, 'user_id': a.user, 'app_id': 'usage-local-app',
            'quota_key': a.quota_key, 'monthly_quota': str(monthly), 'seconds_quota': '100000'}}})
    time.sleep(.15)
    return a


def eventually(fn):
    deadline = time.monotonic() + 45
    while True:
        try:
            return fn()
        except AssertionError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(.3)


def main():
    c = Local()
    print(json.dumps({'database': c.db, 'request_topic': c.topic(), 'push_topic': c.topic(True)}), flush=True)
    try:
        c.bootstrap()
        # Create/settle both random topics before exercising the gateway. The
        # legacy Lua producer otherwise loses initial sends during topic auto-
        # creation. These zero-CU historical probes must NOT enter the summary.
        common = {'user_id': 'local-readiness-probe', 'app_id': 'probe',
                  'client_ip': '127.0.0.1', 'network': 'arc-testnet', 'duration': 0,
                  'response_status_code': 200, 'time': str(time.time())}
        c.produce([{**common, 'request': json.dumps(rpc()), 'response': '{}',
                    'total_cu_cost': 0, 'cu_costs': '[0]'}])
        c.produce([{**common, 'time': time.time(), 'jsonrpc_method': 'eth_subscription',
                    'cu_cost': 0, 'node_id': 'probe', 'service_id': '', 'route_id': '',
                    'request_id': '', 'subscription_type': 'newHeads'}], push=True)
        c.wait(1, 1, 1)
        class Adapter:
            database = c.db
            url = 'http://usage-clickhouse:8123'
            execute = staticmethod(c.sql)
        migration = Migration(Adapter())
        plan = migration.plan()
        original_counts = c.snapshot()
        for checkpoint in ('paused', 'queues', 'expanded', 'summaries'):
            try: migration.prepare(plan, fail_at=checkpoint)
            except InterruptedError: pass
            else: raise AssertionError('Fault injection was not reached')
            assert c.snapshot() == original_counts
        migration.prepare(plan)
        migration.prepare(plan)
        assert c.sql(f'SELECT count() n FROM {PREFIX}', True) == [{'n': '0'}]
        # A replacement table with the same name must not pass the resume gate.
        c.sql(f'RENAME TABLE {PREFIX}_push TO {PREFIX}_push_saved')
        c.sql(f'CREATE VIEW {PREFIX}_push AS SELECT 1')
        try:
            try: migration.resume(plan)
            except RuntimeError as error: assert 'fingerprint' in str(error), str(error)
            else: raise AssertionError('Schema drift was accepted')
            assert not c.exists('mv_request_queue')
        finally:
            c.sql(f'DROP VIEW {PREFIX}_push')
            c.sql(f'RENAME TABLE {PREFIX}_push_saved TO {PREFIX}_push')
        try: migration.resume(plan, fail_after_http=True)
        except InterruptedError: pass
        migration.resume(plan)
        migration.resume(plan)
        configure(c)
        accounts = []
        for tier in ('free', 'paid'):
            a = account(tier)
            accounts.append(a)
            success(a.http(rpc('eth_call'), headers={
                'X-Network': 'spoof', 'X-Route-Name': 'spoof', 'X-Transport': 'ws'}))
            success(a.http([rpc(), rpc('eth_getBalance', 2)]))
            denied = a.http(rpc('debug_traceTransaction'))
            if tier == 'free': assert code(denied) == -32003, denied
            else: success(denied)
            ws = a.ws()
            try:
                success(ws.call(rpc('eth_call')))
                success(ws.call([rpc(), rpc('eth_getBalance', 2)]))
                denied = ws.call(rpc('debug_traceTransaction'))
                if tier == 'free': assert code(denied) == -32003, denied
                else: success(denied)
                sub = subscribe(ws, 'newHeads')
                assert push(sub)
                recv_push(ws)
                unsubscribe = rpc('eth_unsubscribe')
                unsubscribe['params'] = [sub]
                success(ws.call(unsubscribe))
            finally:
                ws.close()
            expected = 23 + (60 if tier == 'paid' else 0)
            assert a.used() == expected, (tier, a.used(), expected)

        limited = account('free', monthly=1)
        success(limited.http(rpc()))
        assert code(limited.http(rpc('eth_call'))) == -32001
        ws = limited.ws()
        try:
            assert code(ws.call(rpc('eth_call'))) == -32001
        finally:
            ws.close()
        assert limited.used() == 1
        success(request(PROXY + '/usage-public', 'POST', rpc(),
                        {'Host': 'access.test', 'Content-Type': 'application/json'})[1])
        c.wait(21, 25, 3)
        all_dimensions = c.sql('''SELECT DISTINCT network,route_name,transport,event_kind,schema_version
            FROM t_request_metrics WHERE user_id != 'local-readiness-probe' ORDER BY route_name''', True)
        c.check('actual HTTP/WS/private/public log dimensions', all_dimensions, [
            {'network': 'arc-testnet', 'route_name': 'arc-testnet', 'transport': 'http', 'event_kind': 'rpc_request', 'schema_version': 2},
            {'network': 'arc-testnet', 'route_name': 'arc-testnet-public', 'transport': 'http', 'event_kind': 'rpc_request', 'schema_version': 2},
            {'network': 'arc-testnet', 'route_name': 'arc-testnet-ws', 'transport': 'ws', 'event_kind': 'rpc_request', 'schema_version': 2}])
        c.check('actual subscription push log dimensions', c.sql('''SELECT DISTINCT network,route_name,transport,event_kind,schema_version
            FROM t_ws_event_metrics WHERE user_id != 'local-readiness-probe' ''', True), [{'network': 'arc-testnet', 'route_name': 'arc-testnet-ws',
                'transport': 'ws', 'event_kind': 'subscription_push', 'schema_version': 2}])
        for a, expected in zip(accounts + [limited], (23, 83, 1)):
            def verify():
                row = c.sql(f"SELECT sum(cu) cu FROM {PREFIX} WHERE user_id='{a.user}'", True)[0]
                assert int(row['cu']) == expected == a.used(), (row, expected, a.used())
            eventually(verify)
            c.check('daily CU agrees with isolated ledger ' + a.key, True, True)
        c.check('public ownership remains separate', c.sql(
            f"SELECT sum(cu) cu FROM {PREFIX} WHERE user_id='usage-public-{c.run}'", True), [{'cu': '1'}])
        c.check('429 remains visible but zero billed CU', c.sql(f'SELECT sum(rate_limited) limited FROM {PREFIX}', True), [{'limited': '2'}])
        # These are direct Kafka contract fixtures, distinct from gateway E2E.
        wire = {**common, 'user_id': 'contract-fixtures', 'network': 'arc-testnet',
                'request': json.dumps(rpc()), 'response': '{}', 'total_cu_cost': 7, 'cu_costs': '[7]',
                'route_name': 'arc-testnet', 'schema_version': 2, 'transport': 'http', 'event_kind': 'rpc_request'}
        c.produce([{**wire, **bad} for bad in ({'transport': 'banana'}, {'network': ''},
            {'route_name': ''}, {'event_kind': 'diagnostic'}, {'schema_version': 3})], new=True)
        legacy = {k: v for k, v in wire.items() if k not in ('route_name', 'schema_version', 'transport', 'event_kind')}
        c.produce([{**legacy, 'network': 'arc-testnet-public'}])
        c.wait(27, 31, 3)
        c.check('invalid dimensions retained outside usage', c.sql(f'''SELECT reason,count() n FROM {PREFIX}_excluded
            WHERE usage_generation!='' GROUP BY reason ORDER BY reason''', True),
            [{'reason': 'diagnostic', 'n': '1'}, {'reason': 'invalid_dimensions', 'n': '4'}])
        c.check('legacy source defaults and canonical alias', c.sql(f'''SELECT network,route_name,transport,event_kind,sum(cu) cu
            FROM {PREFIX} WHERE user_id='contract-fixtures' GROUP BY network,route_name,transport,event_kind''', True),
            [{'network': 'arc-testnet', 'route_name': '', 'transport': 'http', 'event_kind': 'rpc_request', 'cu': '7'}])
        for name in QUEUES: c.sql('DETACH TABLE ' + name)
        c.check('candidate migration generation audit', migration.audit_local(plan)['equal'], True)
        # Local preview fixture only; the CLI deliberately has no production
        # publish command. The real rollout requires producer/lag verification.
        migration.mark('ready', plan)
        print(json.dumps({'preview_database': c.db, 'free_user': accounts[0].user,
                          'paid_user': accounts[1].user, 'public_user': 'usage-public-' + c.run}), flush=True)
        print('PASS local gateway -> native Kafka -> production-shape raw/expanded/daily, ledger and ownership', flush=True)
    finally:
        for name in QUEUES:
            if c.exists(name): c.sql('DETACH TABLE ' + name)


if __name__ == '__main__':
    main()
