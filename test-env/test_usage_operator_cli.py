"""Exercise the opt-in operator CLI with real, isolated local ClickHouse/Kafka."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from test_usage_topology import Local, QUEUES
sys.path.insert(0, '/dashboard/clickhouse')
from usage_telemetry_v2 import Migration, PREFIX
from usage_telemetry_release import exclusive_json


def main():
    c = Local()
    print(json.dumps({'database': c.db, 'suite': 'operator CLI exact production DDL'}), flush=True)
    class Adapter:
        url = 'http://usage-clickhouse:8123'
        database = c.db
        execute = staticmethod(c.sql)
    m = Migration(Adapter())
    try:
        c.bootstrap()
        common = {'user_id': 'operator-local-owner', 'app_id': 'operator-local-app', 'client_ip': '127.0.0.1',
                  'network': 'arc-testnet', 'duration': 0, 'response_status_code': 200, 'time': str(time.time())}
        request = {**common, 'request': '{"method":"eth_chainId"}', 'response': '{}', 'total_cu_cost': 1, 'cu_costs': '[1]'}
        push = {**common, 'time': time.time(), 'jsonrpc_method': 'eth_subscription', 'cu_cost': 5,
                'node_id': '', 'service_id': '', 'route_id': '', 'request_id': '', 'subscription_type': 'newHeads'}
        c.produce([request])
        c.produce([push], push=True)
        c.wait(1, 1, 1)
        plan = m.plan()
        with tempfile.TemporaryDirectory(prefix='operator-cli-') as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            path = root / 'plan.json'
            exclusive_json(path, plan)
            exclusive_json(root / 'backup.json', {'original': plan['original']})
            exclusive_json(root / 'manifest.json', {name: {'bytes': (root / name).stat().st_size,
                'sha256': hashlib.sha256((root / name).read_bytes()).hexdigest()} for name in ('plan.json', 'backup.json')})
            env = {**os.environ, 'CLICKHOUSE_DATABASE': c.db}
            sequence = 0
            def run(command, *args, ok=True):
                start = time.monotonic()
                result = subprocess.run([sys.executable, '-B', '/dashboard/clickhouse/usage_telemetry_release.py',
                    command, '--rehearsal', '--plan-file', str(path), *args], env=env,
                    capture_output=True, text=True, timeout=180)
                if not ok:
                    assert result.returncode != 0, 'Expected refusal'
                    return result.stderr
                assert result.returncode == 0, (command, result.stderr)
                print(json.dumps({'operator_command': command, 'seconds': round(time.monotonic()-start, 3)}), flush=True)
                return json.loads(result.stdout)

            def approve(action):
                nonlocal sequence
                sequence += 1
                file = root / f'{action}-{sequence}.json'
                result = run('preflight', '--for-action', action, '--approval-file', str(file))
                assert result['execution_approved'] is False
                template = json.loads(file.read_text())
                assert template['mode'] == 'rehearsal' and template['action'] == action
                assert template['execution_approved'] is False
                assert 'Named operator' in run(action, '--approve-plan', plan['id'], '--approval-file', str(file), ok=False)
                template['operator'] = 'local-rehearsal-only'
                for key in ('execution_approved', 'backup_verified', 'permissions_verified', 'recovery_reviewed', 'errors_reviewed',
                            'retention_headroom', 'maintenance_window_confirmed', 'pre_pause_lag_zero'):
                    template[key] = True
                approved = root / f'{action}-{sequence}-approved.json'
                exclusive_json(approved, template)
                return ['--approve-plan', plan['id'], '--approval-file', str(approved)]

            assert 'Exact plan approval' in run('prepare', ok=False)
            assert not c.exists(PREFIX + '_control')
            preparation = approve('prepare')
            assert not c.exists(PREFIX + '_control'), 'Preflight/template rejection must not write'
            assert run('prepare', *preparation)['phase'] == 'prepared'
            assert run('prepare', *preparation)['phase'] == 'prepared'
            assert c.sql(f'SELECT count() n FROM {PREFIX}', True) == [{'n': '0'}]
            assert run('resume', *approve('resume'))['phase'] == 'streaming'
            dimensions = {'schema_version': 2, 'event_kind': 'rpc_request'}
            c.produce([{**request, **dimensions, 'route_name': 'arc-testnet', 'transport': 'http'},
                       {**request, **dimensions, 'route_name': 'arc-testnet-ws', 'transport': 'ws'}], new=True)
            c.produce([{**push, 'schema_version': 2, 'event_kind': 'subscription_push',
                        'route_name': 'arc-testnet-ws', 'transport': 'ws'}], push=True, new=True)
            c.wait(3, 3, 2)
            assert run('pause', *approve('pause'))['phase'] == 'paused'
            before = c.snapshot()
            c.produce([request])
            time.sleep(1)
            assert c.snapshot() == before
            assert run('resume', *approve('resume'))['phase'] == 'streaming'
            c.wait(4, 4, 2)
            assert run('pause', *approve('pause'))['phase'] == 'paused'
            evidence = {'plan_id': plan['id'], 'checked_at': dt.datetime.now(dt.timezone.utc).isoformat(),
                'producer_inventory': ['local-fixture-http', 'local-fixture-ws'], 'lag': {'request': 0, 'push': 0},
                **{k: True for k in ('all_producers_v2', 'http_smoke', 'ws_request_smoke',
                    'ws_push_smoke', 'bad_message_review', 'retention_headroom')}}
            proof = root / 'local-evidence.json'
            exclusive_json(proof, evidence)
            publish = approve('publish')
            assert 'separate evidence' in run('publish', *publish, ok=False)
            state = run('publish', *publish, '--evidence-file', str(proof))
            assert state['phase'] == 'ready'
            assert run('publish', *publish, '--evidence-file', str(proof)) == state
            assert c.sql(f'SELECT sum(cu) cu FROM {PREFIX}', True) == [{'cu': '8'}]
            assert run('withdraw', *approve('withdraw'))['phase'] == 'withdrawn'
            assert run('resume', *approve('resume'))['phase'] == 'withdrawn'
            assert run('status')['phase'] == 'withdrawn'
            assert c.snapshot() == dict(zip(('t_request_metrics', 't_request_metrics_expanded', 't_ws_event_metrics'), ('4', '4', '2')))
            print(json.dumps({'result': 'PASS', 'suite': 'operator CLI', 'generation_cu': 8,
                              'historical_cu_excluded': 6, 'mode': 'rehearsal', 'production_writes': False}), flush=True)
    finally:
        for name in QUEUES:
            if c.exists(name):
                c.sql('DETACH TABLE ' + name)


if __name__ == '__main__':
    main()
