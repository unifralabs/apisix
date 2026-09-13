"""Host-side bounded local Kafka forensic export and offset-monitor acceptance.

Uses only fixed local container names and a freshly generated malformed test
topic. Exported records stay in a private temporary directory; no production
groups, offset resets, topic changes or raw-file replay.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DASHBOARD = ROOT.parent / 'unifra_dashboard'
BROKER = 'unifra-usage-native-usage-kafka32-1'
sys.path.insert(0, str(DASHBOARD / 'clickhouse'))
from usage_ingestion_check import snapshot, compare


class ErrorClient:
    url = 'http://usage-clickhouse:8123'
    database = 'usage_test'
    def execute(self, sql, rows=False):
        result = run(['docker', 'exec', 'usage-clickhouse', 'clickhouse-client', '--user', 'usage_test',
            '--password', 'usage-local-only', '--database', self.database, '--query', sql + ' FORMAT JSON'])
        return json.loads(result.stdout)['data']


def run(args, codes=(0,)):
    result = subprocess.run(args, capture_output=True, text=True, timeout=180)
    assert result.returncode in codes, (args[0:3], result.returncode, result.stderr[-3000:])
    return result


def main():
    before_errors = snapshot(ErrorClient())
    probe = run(['docker', 'run', '--rm', '--network', 'unifra-dashboard-dev_backend',
        '--volume', str(ROOT / 'test-env') + ':/tests:ro',
        '--env', 'CLICKHOUSE_URL=http://usage-clickhouse:8123', '--env', 'CLICKHOUSE_USERNAME=usage_test',
        '--env', 'CLICKHOUSE_PASSWORD=usage-local-only', '--env', 'USAGE_TEST_BROKER=usage-kafka32:9092',
        'python:3.12-alpine', 'python', '-B', '/tests/test_usage_bad_messages.py'])
    print(probe.stdout, end='', flush=True)
    after_errors = snapshot(ErrorClient())
    errors = compare(before_errors, after_errors)
    assert not errors['healthy'] and errors['reason'] == 'new_server_errors', errors
    assert any('PARSE' in r['name'] for r in errors['errors']), errors
    assert compare(after_errors, after_errors)['healthy']
    reset = {**after_errors, 'uptime': 0}
    assert compare(before_errors, reset)['reason'] == 'server_restart_or_clock_change'
    topic = json.loads(probe.stdout.splitlines()[0])['topic']
    for name in ('KafkaRecordExport', 'KafkaLagCheck'):
        run(['docker', 'cp', str(DASHBOARD / 'clickhouse' / (name + '.java')), BROKER + ':/tmp/' + name + '.java'])
    def java(name, *args, codes=(0,)):
        return run(['docker', 'exec', BROKER, 'java', '--class-path', '/opt/bitnami/kafka/libs/*',
                    '/tmp/' + name + '.java', 'usage-kafka32:9092', *args], codes)
    def lag(skip, codes):
        return json.loads(java('KafkaLagCheck', topic + '-skip-' + str(skip), topic, '0', codes=codes).stdout)
    before = [lag(0, (2,)), lag(1, (0,))]
    assert before[0]['status'] == 'lagging' and before[0]['lag'] == 2, before
    assert before[1]['status'] == 'ok' and before[1]['lag'] == 0, before
    exported = java('KafkaRecordExport', topic, '0', '0', '3')
    assert 'COMPLETE ' in exported.stderr
    records = [json.loads(line) for line in exported.stdout.splitlines()]
    original = [b'{"value":"one"}', b'{"value":', b'{"value":"two"}']
    assert len(records) == 3
    for index, row in enumerate(records):
        assert row['offset'] == index and row['partition'] == 0 and row['topic'] == topic
        assert base64.b64decode(row['value_base64']) == original[index]
        assert row['value_sha256'] == hashlib.sha256(original[index]).hexdigest()
    with tempfile.TemporaryDirectory(prefix='usage-forensic-') as directory:
        path = Path(directory) / 'records.jsonl'
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as output: output.write(exported.stdout)
        assert path.stat().st_mode & 0o777 == 0o600
        assert len(path.read_text().splitlines()) == 3
    # Unavailable and unbounded requests must fail, not report complete.
    assert 'not yet present' in java('KafkaRecordExport', topic, '0', '0', '4', codes=(1,)).stderr
    assert '1..1000' in java('KafkaRecordExport', topic, '0', '0', '1001', codes=(1,)).stderr
    after = [lag(0, (2,)), lag(1, (0,))]
    assert after == before, 'Read-only forensic export must not change billing consumer offsets'
    missing = json.loads(java('KafkaLagCheck', topic + '-nonexistent', topic, '0', codes=(2,)).stdout)
    assert missing['status'] == 'uninitialized' and missing['committed'] is None
    with tempfile.TemporaryDirectory(prefix='usage-monitor-') as directory:
        def monitor(command, codes=(0,)):
            return run(['docker', 'run', '--rm', '--network', 'unifra-dashboard-dev_backend',
                '--volume', str(DASHBOARD / 'clickhouse') + ':/checks:ro', '--volume', directory + ':/evidence',
                '--env', 'CLICKHOUSE_URL=http://usage-clickhouse:8123', '--env', 'CLICKHOUSE_DATABASE=usage_test',
                '--env', 'CLICKHOUSE_USERNAME=usage_test', '--env', 'CLICKHOUSE_PASSWORD=usage-local-only',
                'python:3.12-alpine', 'python', '-B', '/checks/usage_ingestion_check.py', command,
                '--baseline', '/evidence/baseline.json'], codes)
        monitor('snapshot')
        assert (Path(directory) / 'baseline.json').stat().st_mode & 0o777 == 0o600
        assert json.loads(monitor('check').stdout)['healthy']
        assert 'FileExistsError' in monitor('snapshot', (1,)).stderr, 'Existing baseline must never be overwritten'
    print('PASS exact raw bytes/hash/offsets, private export, bounds, lag/parser alerts and unchanged consumer offsets', flush=True)


if __name__ == '__main__': main()
