"""Opt-in bounded real Arc/DogeOS upstreams, local gateway/ledger/Kafka/CH only.

Reads only node addresses from the mounted nomad upstream files. No production
Admin API, database, Kafka, API keys, broadcasts or management RPC calls.
"""
import json
import time
from pathlib import Path

from test_usage_gateway import Local, Migration, PREFIX, QUEUES, configure, account, eventually
from test_access import rpc, request, PROXY
from test_billing_e2e import subscribe, recv_push, success
from access_mock import frame, read_frame


def main():
    c = Local()
    print(json.dumps({'database': c.db, 'real_upstreams': True}), flush=True)
    try:
        c.bootstrap()
        common = {'user_id': 'readiness', 'app_id': 'probe', 'client_ip': '127.0.0.1',
                  'network': 'arc-testnet', 'duration': 0, 'response_status_code': 200, 'time': str(time.time())}
        c.produce([{**common, 'request': json.dumps(rpc()), 'response': '{}', 'total_cu_cost': 0, 'cu_costs': '[0]'}])
        c.produce([{**common, 'time': time.time(), 'jsonrpc_method': 'eth_subscription', 'cu_cost': 0,
                    'node_id': 'probe', 'service_id': '', 'route_id': '', 'request_id': ''}], push=True)
        c.wait(1, 1, 1)
        class Adapter:
            database = c.db
            url = 'http://usage-clickhouse:8123'
            execute = staticmethod(c.sql)
        migration = Migration(Adapter())
        plan = migration.plan()
        migration.prepare(plan)
        migration.resume(plan)
        accounts = []
        for network, upstream_id, chain_id in [('arc-testnet', 650, 5042002), ('dogeos-testnet', 600, 6281971)]:
            upstreams = []
            for ws in (False, True):
                source = json.loads((Path('/configs/upstream') / f'{upstream_id+int(ws)}-{network}{"-ws" if ws else ""}.json').read_text())
                assert all(node['host'].startswith('10.142.0.') and node['port'] in (8545, 8546) for node in source['nodes'])
                # No imported active probes or unlimited upstream timeouts.
                upstreams.append({'type': source['type'], 'nodes': source['nodes'], 'scheme': source['scheme'],
                                  'timeout': {'connect': 6, 'send': 6, 'read': 20}})
            configure(c, network, *upstreams)
            for tier in ('free', 'paid'):
                a = account(tier)
                accounts.append((network, tier, a))
                identity = a.http(rpc('eth_chainId'))
                success(identity)
                assert int(identity['result'], 16) == chain_id
                success(a.http(rpc()))
                ws = a.ws()
                pushes = 0
                try:
                    identity = ws.call(rpc('eth_chainId'))
                    success(identity)
                    assert int(identity['result'], 16) == chain_id
                    success(ws.call(rpc()))
                    sub = subscribe(ws, 'newHeads')
                    ws.sock.settimeout(20)
                    message = recv_push(ws)
                    assert message['params']['subscription'] == sub
                    assert int(message['params']['result']['number'], 16) > 0
                    pushes += 1
                    unsub = rpc('eth_unsubscribe', 999)
                    unsub['params'] = [sub]
                    ws.sock.sendall(frame(json.dumps(unsub).encode(), masked=True))
                    for _ in range(5):
                        op, data = read_frame(ws.stream)
                        assert op == 1
                        message = json.loads(data)
                        if message.get('id') == 999:
                            assert message.get('result') is True
                            break
                        assert message.get('method') == 'eth_subscription'
                        pushes += 1
                    else: raise AssertionError('Unsubscribe did not complete within the bounded response budget')
                finally: ws.close()
                expected = 6 + 5 * pushes
                assert a.used() == expected, (network, tier, pushes, expected, a.used())
                def verify():
                    row = c.sql(f"SELECT sum(cu) cu FROM {PREFIX} WHERE user_id='{a.user}'", True)[0]
                    assert int(row['cu']) == expected, (network, tier, row, expected)
                eventually(verify)
                c.check(network + '/' + tier + '/real-node ledger and daily CU', a.used(), expected)
            public = request(PROXY + '/usage-public', 'POST', rpc('eth_chainId'),
                             {'Host': 'access.test', 'Content-Type': 'application/json'})[1]
            success(public)
            assert int(public['result'], 16) == chain_id
        def verify_public():
            assert c.sql(f"SELECT sum(cu) cu FROM {PREFIX} WHERE user_id='usage-public-{c.run}'", True) == [{'cu': '2'}]
        eventually(verify_public)
        for network, tier, a in accounts:
            c.check(network + '/' + tier + '/actual dimensions', c.sql(f'''SELECT DISTINCT network,route_name,transport,event_kind
                FROM {PREFIX} WHERE user_id='{a.user}' ORDER BY transport,event_kind''', True), [
                    {'network': network, 'route_name': network, 'transport': 'http', 'event_kind': 'rpc_request'},
                    {'network': network, 'route_name': network + '-ws', 'transport': 'ws', 'event_kind': 'rpc_request'},
                    {'network': network, 'route_name': network + '-ws', 'transport': 'ws', 'event_kind': 'subscription_push'}])
        for name in QUEUES: c.sql('DETACH TABLE ' + name)
        c.check('real-node generation raw/daily audit', migration.audit_local(plan)['equal'], True)
        print('PASS real Arc/DogeOS HTTP/WS/newHeads/private/public -> local native Kafka/ClickHouse', flush=True)
    finally:
        for name in QUEUES:
            if c.exists(name): c.sql('DETACH TABLE ' + name)
        # Restore mock-only local gateway configuration; no lingering node probes.
        configure(c)


if __name__ == '__main__': main()
