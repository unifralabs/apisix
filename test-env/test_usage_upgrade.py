"""Local-only ClickHouse/Kafka upgrade feasibility and compatibility tests.

Uses an existing isolated ClickHouse 22.10 and local Kafka-compatible broker.
Never connects to production, resets offsets, or modifies an existing database.
Leaves its uniquely named database/topic for inspection; detaches its reader.
"""
import base64
import datetime as dt
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


def main():
    url = os.environ['CLICKHOUSE_URL']
    assert url == 'http://usage-clickhouse:8123', 'Only isolated local ClickHouse is allowed'
    assert os.environ['CLICKHOUSE_USERNAME'] == 'usage_test'
    assert os.environ['CLICKHOUSE_PASSWORD'] == 'usage-local-only'
    broker = os.environ.get('USAGE_TEST_BROKER', 'kafka:9092')
    assert broker in ('kafka:9092', 'usage-kafka32:9092'), 'Only isolated local brokers are allowed'
    run = uuid.uuid4().hex[:12]
    database = 'usage_contract_test_' + run
    topic = 'usage-contract-local-' + run
    group = 'usage-contract-local-' + run
    failures, results = [], []

    def sql(query, rows=False, db=None):
        params = urllib.parse.urlencode({'database': db or database, 'max_threads': 1,
                                        'max_execution_time': 15})
        auth = base64.b64encode(b'usage_test:usage-local-only').decode()
        request = urllib.request.Request(url + '/?' + params,
            (query + (' FORMAT JSON' if rows else '')).encode(),
            {'Authorization': 'Basic ' + auth})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            raise RuntimeError(error.read(4000).decode()) from None
        return json.loads(body)['data'] if rows else None

    def check(name, actual, expected):
        ok = actual == expected
        results.append({'check': name, 'pass': ok, 'actual': actual, 'expected': expected})
        print(json.dumps(results[-1]), flush=True)
        if not ok:
            failures.append(name)

    def wait_count(expected):
        end = time.monotonic() + 25
        while time.monotonic() < end:
            count = int(sql('SELECT count() n FROM raw', True)[0]['n'])
            if count == expected:
                return
            time.sleep(.3)
        raise AssertionError(('Kafka did not settle', count, expected))

    def queue_ddl(fields):
        return f'''CREATE TABLE queue ({fields}) ENGINE=Kafka SETTINGS
          kafka_broker_list='{broker}', kafka_topic_list='{topic}',
          kafka_group_name='{group}', kafka_format='JSONEachRow',
          kafka_flush_interval_ms=100, kafka_skip_broken_messages=0,
          input_format_defaults_for_omitted_fields=1'''

    def produce(rows):
        payload = '\n'.join(json.dumps(row) for row in rows)
        sql('INSERT INTO producer FORMAT JSONEachRow\n' + payload)

    def event(i, **extra):
        return {'user_id': 'local-owner', 'app_id': 'local-app', 'network': 'dogeos-testnet',
                'time': dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d %H:%M:%S'),
                'cu_cost': i, 'response_status_code': 200, **extra}

    version = sql('SELECT version() version', True, 'usage_test')[0]['version']
    assert version == '22.10.7.13', version
    sql('CREATE DATABASE ' + database, db='usage_test')
    print(json.dumps({'database': database, 'topic': topic, 'version': version}), flush=True)
    fields = "user_id String,app_id String,network String,time DateTime('UTC'),cu_cost UInt32,response_status_code Int32"
    extra = ",route_name String DEFAULT '',transport String DEFAULT 'http',event_kind String DEFAULT 'rpc_request',schema_version UInt8 DEFAULT 1"
    try:
        sql(f'CREATE TABLE raw ({fields}) ENGINE=MergeTree ORDER BY (app_id,time)')
        sql(queue_ddl(fields))
        sql('CREATE MATERIALIZED VIEW ingest TO raw AS SELECT * FROM queue')
        # Kafka producer table is local test tooling, not a consumer of the topic.
        sql(f'''CREATE TABLE producer ({fields}{extra}) ENGINE=Kafka SETTINGS
          kafka_broker_list='{broker}',kafka_topic_list='{topic}',
          kafka_group_name='{group}-writer',kafka_format='JSONEachRow' ''')
        # A separate legacy writer genuinely omits new fields on the wire.
        sql(f'''CREATE TABLE legacy_producer ({fields}) ENGINE=Kafka SETTINGS
          kafka_broker_list='{broker}',kafka_topic_list='{topic}',
          kafka_group_name='{group}-legacy-writer',kafka_format='JSONEachRow' ''')
        sql('INSERT INTO legacy_producer FORMAT JSONEachRow\n' + json.dumps(event(1)))
        wait_count(1)
        check('baseline old Kafka message', int(sql('SELECT sum(cu_cost) n FROM raw', True)[0]['n']), 1)

        try:
            sql("ALTER TABLE queue ADD COLUMN transport String DEFAULT 'http'")
            kafka_alter = 'supported'
        except RuntimeError as error:
            kafka_alter = str(error).split('\n')[0]
        print(json.dumps({'probe': 'Kafka ADD COLUMN', 'result': kafka_alter}), flush=True)
        check('22.10 Kafka ADD COLUMN feasibility', 'NOT_IMPLEMENTED' in kafka_alter, True)

        for definition in ["route_name String DEFAULT ''", "transport String DEFAULT 'http'",
                           "event_kind String DEFAULT 'rpc_request'", 'schema_version UInt8 DEFAULT 1']:
            sql('ALTER TABLE raw ADD COLUMN IF NOT EXISTS ' + definition)
        check('old stored row reads compatible defaults',
              sql('SELECT transport,event_kind,schema_version FROM raw', True),
              [{'transport': 'http', 'event_kind': 'rpc_request', 'schema_version': 1}])
        before = sql('SELECT count() n,sum(cu_cost) cu FROM raw', True)

        # The tested fallback pauses only this isolated reader. It is not an
        # automatically authorized production procedure.
        sql('DETACH TABLE queue')
        # Queue changes while detached are unsupported too; retain topic/group.
        sql('DROP VIEW ingest')
        # A detached Atomic table is absent from the SQL catalog. Reattach only
        # after removing its sole consumer MV, then replace its metadata.
        sql('ATTACH TABLE queue')
        sql('DROP TABLE queue')
        sql(queue_ddl(fields + extra))
        check('raw survives queue metadata recreation', sql('SELECT count() n,sum(cu_cost) cu FROM raw', True), before)
        # No MV yet: produce old/new backlog before starting the sole reader.
        sql('INSERT INTO legacy_producer FORMAT JSONEachRow\n' + json.dumps(event(2)))
        produce([event(3, route_name='dogeos-testnet-ws', transport='ws', schema_version=2),
                 event(4, route_name='dogeos-testnet-public', transport='http', schema_version=2)])
        check('backlog does not mutate raw while reader is paused', sql('SELECT count() n,sum(cu_cost) cu FROM raw', True), before)
        # Kafka JSONEachRow gives type defaults for omitted fields on this
        # version even when queue DEFAULT expressions are declared. Apply the
        # topic-specific compatibility mapping explicitly in the consumer MV.
        sql('''CREATE MATERIALIZED VIEW ingest TO raw AS SELECT
          user_id,app_id,network,time,cu_cost,response_status_code,route_name,
          if(q.schema_version<2 AND q.transport='', 'http', q.transport) transport,
          if(q.schema_version<2 AND q.event_kind='', 'rpc_request', q.event_kind) event_kind,
          if(q.schema_version=0, toUInt8(1), q.schema_version) schema_version FROM queue AS q''')
        wait_count(4)
        check('old offset resumes without replay in graceful test',
              sql('SELECT cu_cost,transport,event_kind,schema_version FROM raw ORDER BY cu_cost', True),
              [{'cu_cost': i, 'transport': 'ws' if i == 3 else 'http', 'event_kind': 'rpc_request',
                'schema_version': 2 if i >= 3 else 1} for i in range(1, 5)])

        sql('''CREATE TABLE daily (user_id String, day Date,app_id String,network String,
          route_name String,transport String,event_kind String,cu UInt64,events UInt64)
          ENGINE=SummingMergeTree((cu,events)) PARTITION BY toYYYYMM(day)
          ORDER BY (user_id,day,app_id,network,route_name,transport,event_kind)
          TTL day + INTERVAL 13 MONTH''')
        sql('''CREATE MATERIALIZED VIEW daily_ingest TO daily AS
          SELECT user_id,toDate(time,'UTC') day,app_id,network,route_name,transport,event_kind,
          sum(toUInt64(cu_cost)) cu,count() events FROM raw
          GROUP BY user_id,day,app_id,network,route_name,transport,event_kind''')
        check('no POPULATE or history backfill', int(sql('SELECT count() n FROM daily', True)[0]['n']), 0)
        produce([event(5, route_name='dogeos-testnet-ws', transport='ws', event_kind='subscription_push', schema_version=2),
                 event(6, route_name='dogeos-testnet', transport='http', schema_version=2)])
        wait_count(6)
        time.sleep(2)
        before_restart = sql('SELECT sum(cu) cu,sum(events) events FROM daily', True)
        print(json.dumps({'probe': 'new downstream MV while existing Kafka reader runs',
                          'raw_new_rows': 2, 'daily': before_restart}), flush=True)
        # Direct INSERT tests alone can pass while an existing Kafka read loop
        # still uses a cached downstream graph. Exercise a reader refresh too.
        sql('DETACH TABLE queue')
        sql('ATTACH TABLE queue')
        time.sleep(2)
        check('graceful reader restart keeps totals', sql('SELECT count() n,sum(cu_cost) cu FROM raw', True), [{'n': '6', 'cu': '21'}])
        check('restart does not backfill missed history', sql('SELECT sum(cu) cu,sum(events) events FROM daily', True), before_restart)
        produce([event(7, route_name='dogeos-testnet-ws', transport='ws', event_kind='subscription_push', schema_version=2),
                 event(8, route_name='dogeos-testnet', transport='http', schema_version=2)])
        wait_count(8)
        end = time.monotonic() + 10
        while time.monotonic() < end:
            current = sql('SELECT sum(cu) cu,sum(events) events FROM daily', True)
            if int(current[0]['events']) == int(before_restart[0]['events']) + 2:
                break
            time.sleep(.2)
        check('new fields reach cascade after reader refresh', current,
              [{'cu': str(int(before_restart[0]['cu']) + 15), 'events': str(int(before_restart[0]['events']) + 2)}])
        print(json.dumps({'probe': 'new typed dimensions', 'rows': sql('SELECT transport,event_kind,sum(cu) cu,sum(events) events FROM daily GROUP BY transport,event_kind ORDER BY transport', True)}), flush=True)

        # Production has a second topic dedicated to subscription pushes. It
        # requires WS defaults, not the request topic's HTTP compatibility rule.
        ws_topic = topic + '-push'
        sql(f'CREATE TABLE raw_ws ({fields}{extra}) ENGINE=MergeTree ORDER BY (app_id,time)')
        sql(f'''CREATE TABLE queue_ws ({fields}{extra}) ENGINE=Kafka SETTINGS
          kafka_broker_list='{broker}',kafka_topic_list='{ws_topic}',
          kafka_group_name='{group}-push',kafka_format='JSONEachRow',
          kafka_flush_interval_ms=100,kafka_skip_broken_messages=0,
          input_format_defaults_for_omitted_fields=1''')
        sql(f'''CREATE TABLE legacy_producer_ws ({fields}) ENGINE=Kafka SETTINGS
          kafka_broker_list='{broker}',kafka_topic_list='{ws_topic}',
          kafka_group_name='{group}-push-writer',kafka_format='JSONEachRow' ''')
        # Install downstream BEFORE starting the Kafka MV: first event must
        # reach both raw and daily without a second pause or missing window.
        sql('''CREATE MATERIALIZED VIEW daily_ws TO daily AS
          SELECT user_id,toDate(time,'UTC') day,app_id,network,route_name,transport,event_kind,
          sum(toUInt64(cu_cost)) cu,count() events FROM raw_ws
          GROUP BY user_id,day,app_id,network,route_name,transport,event_kind''')
        sql('''CREATE MATERIALIZED VIEW ingest_ws TO raw_ws AS SELECT
          user_id,app_id,network,time,cu_cost,response_status_code,route_name,
          if(q.schema_version<2 AND q.transport='', 'ws', q.transport) transport,
          if(q.schema_version<2 AND q.event_kind='', 'subscription_push', q.event_kind) event_kind,
          if(q.schema_version=0, toUInt8(1), q.schema_version) schema_version FROM queue_ws q''')
        sql('INSERT INTO legacy_producer_ws FORMAT JSONEachRow\n' + json.dumps(event(9)))
        end = time.monotonic() + 25
        while time.monotonic() < end:
            raw_ws = sql('SELECT cu_cost,transport,event_kind,schema_version FROM raw_ws', True)
            if raw_ws:
                break
            time.sleep(.3)
        check('legacy push topic has independent WS defaults', raw_ws,
              [{'cu_cost': 9, 'transport': 'ws', 'event_kind': 'subscription_push', 'schema_version': 1}])
        end = time.monotonic() + 10
        expected = [{'cu': str(int(before_restart[0]['cu']) + 24),
                     'events': str(int(before_restart[0]['events']) + 3)}]
        while time.monotonic() < end:
            total = sql('SELECT sum(cu) cu,sum(events) events FROM daily', True)
            if total == expected:
                break
            time.sleep(.2)
        check('downstream prepared before reader includes first push', total, expected)
        print(json.dumps({'result': 'FAIL' if failures else 'PASS', 'database': database,
            'version': version, 'broker': 'local Kafka 3.2.0' if broker == 'usage-kafka32:9092' else 'local Redpanda v24.3.18 (not Kafka 3.2)',
            'checks': len(results), 'failures': failures,
            'production_gate': 'Kafka input schema needs a separately approved reader metadata replacement; ADD COLUMN is unsupported'}), flush=True)
        if failures:
            raise AssertionError(failures)
    finally:
        for name in ('queue', 'queue_ws'):
            try:
                sql('DETACH TABLE IF EXISTS ' + name)
            except RuntimeError:
                pass


if __name__ == '__main__':
    main()
