"""Exercise the shipped candidate CLI, not only its imported Python class."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

from test_usage_topology import Local, QUEUES


def main():
    c = Local()
    print(json.dumps({'database': c.db, 'suite': 'migration CLI'}), flush=True)
    try:
        c.bootstrap()
        with tempfile.TemporaryDirectory(prefix='usage-migration-cli-') as directory:
            path = Path(directory) / 'plan.json'
            env = {**os.environ, 'CLICKHOUSE_DATABASE': c.db}
            def run(command, *args, ok=True):
                result = subprocess.run([sys.executable, '-B', '/dashboard/clickhouse/usage_telemetry_v2.py',
                    command, '--plan-file', str(path), *args], env=env, capture_output=True, text=True, timeout=180)
                if ok:
                    assert result.returncode == 0, (command, result.stderr)
                    return json.loads(result.stdout)
                assert result.returncode != 0, ('expected rejection', command)
                return result.stderr
            output = run('plan')
            plan = json.loads(path.read_text())
            assert output['plan_id'] == plan['id']
            assert stat.S_IMODE(path.stat().st_mode) == 0o600
            assert not c.exists('usage_telemetry_v2_control'), 'plan must not create migration objects'
            assert 'approve' in run('prepare', '--approve-plan', 'wrong', ok=False).lower()
            assert not c.exists('usage_telemetry_v2_control')
            approve = ('--approve-plan', plan['id'])
            assert run('prepare', *approve)['phase'] == 'prepared'
            assert run('prepare', *approve)['phase'] == 'prepared'
            assert run('resume', *approve)['phase'] == 'streaming'
            assert run('resume', *approve)['phase'] == 'streaming'
            assert run('status')['generation'] == plan['id']
            assert run('pause', *approve)['phase'] == 'paused'
            assert run('pause', *approve)['phase'] == 'paused'
            assert 'evidence file' in run('publish', *approve, ok=False)
            assert run('resume', *approve)['phase'] == 'streaming'
            assert run('withdraw', *approve)['phase'] == 'withdrawn'
            assert run('resume', *approve)['phase'] == 'withdrawn'
            assert not c.exists('usage_telemetry_v2_lock')
            # Explicitly simulate another migration process holding the lock.
            c.sql('CREATE TABLE usage_telemetry_v2_lock (owner String) ENGINE=Memory')
            try:
                assert 'TABLE_ALREADY_EXISTS' in run('resume', *approve, ok=False)
                assert c.exists('usage_telemetry_v2_lock'), 'failed contender must not release another owner lock'
            finally:
                c.sql('DROP TABLE usage_telemetry_v2_lock')
            assert run('status')['phase'] == 'withdrawn'
            c.check('CLI protects plan, approval, permissions, repeat operations and exclusive lock', True, True)
            print('PASS migration CLI', flush=True)
    finally:
        for name in QUEUES:
            if c.exists(name): c.sql('DETACH TABLE ' + name)


if __name__ == '__main__': main()
