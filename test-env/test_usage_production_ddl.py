"""Rehearse against an authorized production DDL snapshot, on local services only.

Host export removes all production destinations before Docker sees the fixture.
Only the migration's twelve objects are restored; unrelated external engines and
account grants are never mounted or executed. No business rows are copied.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time

RAW = ('t_request_metrics', 't_request_metrics_expanded', 't_ws_event_metrics')
STORAGE = ('storage_mv_request_metrics_daily', 'storage_mv_request_metrics_minutes')
QUEUES = ('t_request_queue', 't_ws_event_queue')
VIEWS = ('mv_request_metrics_daily', 'mv_request_metrics_minutes',
         'mv_request_queue', 'mv_request_queue_expanded', 'mv_ws_event_queue')
ORDER = (*RAW, *STORAGE, *QUEUES, *VIEWS)
LOCAL_DB = '__LOCAL_DATABASE__'


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def validate(fixture):
    assert set(fixture['ddl']) == set(ORDER)
    for name, ddl in fixture['ddl'].items():
        assert ddl.startswith(('CREATE TABLE ' + LOCAL_DB + '.' + name + '\n',
                               'CREATE MATERIALIZED VIEW ' + LOCAL_DB + '.' + name + ' '))
        assert not re.search(r'metrics_prod|10\.142\.|https?://|\b(remote|url|s3|mysql|postgresql|jdbc|odbc|file)\s*\(', ddl, re.I)
        assert not re.search(r'\b(password|sasl|security_protocol|ssl|named_collection)\b', ddl, re.I)
        assert not re.search(r';|--|/\*', ddl), 'Unexpected SQL statement/comment'
        if name in QUEUES:
            assert "kafka_broker_list = 'usage-kafka32:9092'" in ddl
            for setting in ('kafka_topic_list', 'kafka_group_name'):
                suffix = 'push' if name == QUEUES[1] else 'request'
                assert f"{setting} = '@LOCAL_{suffix}@'" in ddl
        elif name in RAW:
            assert 'ENGINE = MergeTree\n' in ddl
        elif name in STORAGE:
            assert 'ENGINE = SummingMergeTree\n' in ddl
        else:
            assert ' ENGINE ' not in ddl and '\nENGINE ' not in ddl


def export(source, reviewed_source_sha256=None):
    plan = json.loads((source / 'plan.json').read_text())
    backup = json.loads((source / 'backup.json').read_text())
    manifest = json.loads((source / 'manifest.json').read_text())
    for name in ('backup.json', 'plan.json'):
        data = (source / name).read_bytes()
        assert hashlib.sha256(data).hexdigest() == manifest[name]['sha256']
        assert stat.S_IMODE((source / name).stat().st_mode) == 0o600
    assert digest({k: v for k, v in plan.items() if k != 'id'}) == plan['id']
    assert plan['database'] == 'metrics_prod' and plan['no_backfill'] is True
    assert set(plan['original']) == set(ORDER)
    current_source = Path(__file__).resolve().parents[2] / 'unifra_dashboard/clickhouse/usage_telemetry_v2.py'
    current_sha = hashlib.sha256(current_source.read_bytes()).hexdigest()
    if current_sha != manifest['migration_source_sha256']:
        assert reviewed_source_sha256 == current_sha, 'Source changed; explicitly review and supply --reviewed-source-sha256'
    fixture = {'production_plan_id': plan['id'], 'ddl': {},
               'source_sha256': current_sha, 'snapshot_source_sha256': manifest['migration_source_sha256']}
    for name in ORDER:
        ddl = plan['original'][name]
        assert backup['original'][name] == ddl
        ddl = ddl.replace('metrics_prod.', LOCAL_DB + '.')
        if name in QUEUES:
            allowed = {'kafka_broker_list', 'kafka_topic_list', 'kafka_group_name',
                       'kafka_format', 'kafka_skip_broken_messages', 'kafka_max_block_size',
                       'input_format_defaults_for_omitted_fields'}
            assert set(re.findall(r'(\w+)\s*=', ddl.split('SETTINGS', 1)[1])) <= allowed
            suffix = 'push' if name == QUEUES[1] else 'request'
            for setting, replacement in (
                ('kafka_broker_list', 'usage-kafka32:9092'),
                ('kafka_topic_list', '@LOCAL_' + suffix + '@'),
                ('kafka_group_name', '@LOCAL_' + suffix + '@')):
                ddl, count = re.subn(setting + r" = '(?:\\.|[^'\\])*'",
                                     setting + " = '" + replacement + "'", ddl)
                assert count == 1
        fixture['ddl'][name] = ddl
    validate(fixture)
    os.umask(0o077)
    directory = Path(tempfile.mkdtemp(prefix='unifra-ddl-rehearsal-', dir='/private/tmp'))
    path = directory / 'local-fixture.json'
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as output:
        json.dump(fixture, output, indent=2)
    print(json.dumps({'sanitized_fixture': str(path), 'objects': len(ORDER),
                      'production_plan_id': plan['id'], 'business_rows_exported': 0}), flush=True)


def run(suite, path):
    fixture = json.loads(path.read_text())
    validate(fixture)  # Must pass before creating a local database or any query.
    sys.path.insert(0, '/dashboard/clickhouse')
    import test_usage_topology as topology
    from usage_telemetry_v2 import Migration
    source = Path('/dashboard/clickhouse/usage_telemetry_v2.py').read_bytes()
    assert hashlib.sha256(source).hexdigest() == fixture['source_sha256'], 'Migration source drift'

    class ExactDDL(topology.Local):
        def bootstrap(self):
            assert self.broker == 'usage-kafka32:9092'
            expected = {}
            started = time.monotonic()
            for name in ORDER:
                ddl = fixture['ddl'][name].replace(LOCAL_DB, self.db)
                for push, suffix in ((False, 'request'), (True, 'push')):
                    ddl = ddl.replace('@LOCAL_' + suffix + '@', self.topic(push))
                expected[name] = ddl
                self.sql(ddl)
            # Compare normalized server SHOW CREATE for every restored object.
            for name, ddl in expected.items():
                actual = self.sql('SHOW CREATE TABLE ' + name, True)[0]['statement']
                assert re.sub(r'\s+', ' ', actual) == re.sub(r'\s+', ' ', ddl), 'Restored DDL mismatch: ' + name
            for name in QUEUES:
                self.sql('DETACH TABLE ' + name)
                self.sql('ATTACH TABLE ' + name)
            for push, suffix in ((False, 'request'), (True, 'push')):
                self.queue(push=push, writer='legacy_' + suffix)
                self.queue(push=push, new=True, writer='new_' + suffix)
            self.sql('CREATE TABLE upgrade_state (version UInt64,phase String) ENGINE=MergeTree ORDER BY version')
            print(json.dumps({'restored_objects': 12, 'exact_normalized_ddl_match': True,
                              'production_plan_id': fixture['production_plan_id'],
                              'database': self.db, 'restore_seconds': round(time.monotonic()-started, 3)}), flush=True)

    topology.Local = ExactDDL
    for name in ('prepare', 'resume', 'pause', 'publish', 'withdraw'):
        original = getattr(Migration, name)
        def timed(self, *args, _original=original, _name=name, **kwargs):
            start = time.monotonic()
            try:
                return _original(self, *args, **kwargs)
            finally:
                print(json.dumps({'operation': _name, 'seconds': round(time.monotonic()-start, 3)}), flush=True)
        setattr(Migration, name, timed)
    import importlib
    module = importlib.import_module('test_usage_' + {'release': 'release', 'gateway': 'gateway', 'cli': 'migration_cli', 'operator': 'operator_cli'}[suite])
    module.main()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--export', type=Path)
    parser.add_argument('--fixture', type=Path)
    parser.add_argument('--suite', choices=('release', 'gateway', 'cli', 'operator'))
    parser.add_argument('--reviewed-source-sha256')
    args = parser.parse_args()
    if args.export:
        export(args.export, args.reviewed_source_sha256)
    else:
        assert args.fixture and args.suite
        run(args.suite, args.fixture)
