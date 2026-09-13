"""Local lifecycle and acknowledgement-loss acceptance of the real migration."""
import datetime as dt
import json
import sys
import time
from test_usage_topology import Local, QUEUES
sys.path.insert(0, '/dashboard/clickhouse')
from usage_telemetry_v2 import Migration, PREFIX, digest


def main():
    c = Local()
    print(json.dumps({'database': c.db, 'suite': 'release lifecycle'}), flush=True)
    class Adapter:
        database = c.db
        url = 'http://usage-clickhouse:8123'
        fault = None
        def execute(self, sql, rows=False):
            result = c.sql(sql, rows)
            if self.fault and self.fault(sql):
                self.fault = None
                raise ConnectionError('Injected acknowledgement loss after successful statement')
            return result
    adapter = Adapter()
    m = Migration(adapter)
    def fail(fn, match):
        try: fn()
        except Exception as error:
            assert match in str(error), str(error)
        else: raise AssertionError('Expected rejection: ' + match)
    try:
        c.bootstrap()
        common = {'user_id': 'release-test', 'app_id': 'release-test', 'client_ip': '127.0.0.1',
                  'network': 'arc-testnet', 'duration': 0, 'response_status_code': 200, 'time': str(time.time())}
        request = {**common, 'request': '{"method":"eth_chainId"}', 'response': '{}', 'total_cu_cost': 1, 'cu_costs': '[1]'}
        push = {**common, 'time': time.time(), 'jsonrpc_method': 'eth_subscription', 'cu_cost': 5,
                'node_id': '', 'service_id': '', 'route_id': '', 'request_id': '', 'subscription_type': 'newHeads'}
        c.produce([request])
        c.produce([push], push=True)
        c.wait(1, 1, 1)
        plan = m.plan()
        class NoSQL:
            database = 'metrics_prod'
            url = 'http://usage-clickhouse:8123'
            def execute(self, *args): raise AssertionError('Target guard must reject before any SQL')
        blocked = {**plan, 'database': NoSQL.database}
        blocked['id'] = digest({k: v for k, v in blocked.items() if k != 'id'})
        fail(lambda: Migration(NoSQL()).prepare(blocked), 'Production writes disabled')
        adapter.fault = lambda sql: sql.startswith('INSERT INTO ' + PREFIX + '_control') and "'prepared'" in sql
        fail(lambda: m.prepare(plan), 'acknowledgement loss')
        m.prepare(plan)
        m.resume(plan)
        c.produce([{**request, 'schema_version': 2, 'route_name': 'arc-testnet', 'transport': 'http', 'event_kind': 'rpc_request'}], new=True)
        c.produce([{**push, 'schema_version': 2, 'route_name': 'arc-testnet-ws', 'transport': 'ws', 'event_kind': 'subscription_push'}], push=True, new=True)
        c.wait(2, 2, 2)
        # DROP completed but client lost its acknowledgement. Repetition must
        # finish stopping the other reader and never delete persisted data.
        adapter.fault = lambda sql: sql == 'DROP VIEW IF EXISTS mv_request_queue'
        fail(lambda: m.pause(plan), 'acknowledgement loss')
        assert m.state()['phase'] == 'paused'
        m.pause(plan)
        before = c.snapshot()
        assert m.audit_local(plan)['groups'] == 2
        evidence = {'plan_id': plan['id'], 'checked_at': dt.datetime.now(dt.timezone.utc).isoformat(),
            'producer_inventory': ['local HTTP logger', 'local WS logger'], 'lag': {'request': 0, 'push': 0},
            **{key: True for key in ('all_producers_v2', 'http_smoke', 'ws_request_smoke', 'ws_push_smoke', 'bad_message_review', 'retention_headroom')}}
        fail(lambda: m.publish(plan, {**evidence, 'plan_id': 'wrong'}), 'another plan')
        fail(lambda: m.publish(plan, {**evidence, 'checked_at': '2000-01-01T00:00:00Z'}), 'fresh')
        fail(lambda: m.publish(plan, {**evidence, 'lag': {'request': 1, 'push': 0}}), 'caught up')
        fail(lambda: m.publish(plan, {**evidence, 'ws_push_smoke': False}), 'release checks')
        adapter.fault = lambda sql: sql.startswith('CREATE MATERIALIZED VIEW mv_request_queue TO')
        fail(lambda: m.publish(plan, evidence), 'acknowledgement loss')
        assert m.state()['phase'] == 'paused'
        fail(lambda: m.publish(plan, evidence), 'Pause both')
        m.pause(plan)
        adapter.fault = lambda sql: sql.startswith('INSERT INTO ' + PREFIX + '_control') and "'ready'" in sql
        fail(lambda: m.publish(plan, evidence), 'acknowledgement loss')
        assert m.state()['phase'] == 'ready'
        ready = m.state()
        m.publish(plan, evidence)
        assert m.state() == ready, 'ready retry must not move the coverage boundary'
        m.withdraw(plan)
        assert m.state()['phase'] == 'withdrawn'
        m.resume(plan)
        assert m.state()['phase'] == 'withdrawn', 'reader resume must not silently republish charts'
        assert c.snapshot() == before
        # Traffic keeps flowing during application rollback.
        c.produce([request])
        c.wait(3, 3, 2)
        m.pause(plan)
        assert m.audit_local(plan)['equal']
        assert c.sql(f'SELECT sum(cu) n FROM {PREFIX}', True) == [{'n': '7'}]
        m.publish(plan, evidence)
        assert m.state()['phase'] == 'ready'
        c.check('publish, withdraw, pause, resume and ACK-loss retries preserve counts/CU', True, True)
        print('PASS release lifecycle; production writes remain disabled', flush=True)
    finally:
        for name in QUEUES:
            if c.exists(name): c.sql('DETACH TABLE ' + name)


if __name__ == '__main__': main()
