"""Local-only production-shape request/WS ingestion upgrade and recovery.

Production business DDL was inspected read-only on 2026-09-13. Preserve the
relevant types, expressions, TTL, ordering and active five-view dependency graph.
Unused old tables, PostgreSQL engines and credentials are deliberately excluded.
The candidate changes request expansion from a parallel Kafka MV to a cascade
from the persisted request envelope. This is a local experiment, not a deploy CLI.
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

REQUEST_QUEUE = '''user_id String,app_id String,client_ip String,network String,
 duration Float32,total_cu_cost UInt32,cu_costs String,request String,response String,
 response_status_code Int32,time String'''
PUSH_QUEUE = '''user_id String,app_id String,client_ip String,network String,
 duration Float32,response_status_code Int32,time Float64,jsonrpc_method String,
 cu_cost UInt32,node_id String,service_id String,route_id String,request_id String,
 subscription_type Nullable(String)'''
RAW_COMMON = '''user_id String,app_id String,client_ip IPv6,network String,method String,
 duration Int64,request String,response String,response_status_code Int32,
 response_error_code Int32,time DateTime'''
PUSH_RAW = '''user_id String,app_id String,client_ip IPv6,network String,method String,
 duration Int64,response_status_code Int32,cu_cost UInt32,time DateTime,
 node_id String,service_id String,route_id String,request_id String,
 subscription_type LowCardinality(Nullable(String)) DEFAULT NULL'''
DIMENSIONS = "route_name String DEFAULT '',transport String DEFAULT '',event_kind String DEFAULT '',schema_version UInt8 DEFAULT 0"
RAW_TABLES = ('t_request_metrics', 't_request_metrics_expanded', 't_ws_event_metrics')
QUEUES = ('t_request_queue', 't_ws_event_queue')
INGEST_VIEWS = ('mv_request_queue', 'mv_request_queue_expanded', 'mv_ws_event_queue')
KEYS = 'user_id,day,app_id,network,route_name,transport,event_kind'


class Local:
    def __init__(self):
        assert os.environ['CLICKHOUSE_URL'] == 'http://usage-clickhouse:8123'
        assert os.environ['CLICKHOUSE_USERNAME'] == 'usage_test'
        assert os.environ['CLICKHOUSE_PASSWORD'] == 'usage-local-only'
        self.broker = os.environ['USAGE_TEST_BROKER']
        assert self.broker in ('usage-kafka32:9092', 'kafka:9092')
        self.run = uuid.uuid4().hex[:12]
        self.db = 'usage_topology_test_' + self.run
        self.phase = 'old'
        self.checks = 0
        self.sql('CREATE DATABASE ' + self.db, db='usage_test')
        assert self.sql('SELECT version() v', True)[0]['v'] == '22.10.7.13'

    def sql(self, query, rows=False, db=None):
        params = urllib.parse.urlencode({'database': db or self.db, 'max_threads': 1,
                                        'max_execution_time': 20})
        request = urllib.request.Request('http://usage-clickhouse:8123/?' + params,
            (query + (' FORMAT JSON' if rows else '')).encode(),
            {'Authorization': 'Basic ' + base64.b64encode(b'usage_test:usage-local-only').decode()})
        try:
            with urllib.request.urlopen(request, timeout=25) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            raise RuntimeError(error.read(5000).decode()) from None
        if rows:
            result = json.loads(body)
            self.last_statistics = result.get('statistics', {})
            return result['data']
        return None

    def check(self, label, actual, expected):
        self.checks += 1
        print(json.dumps({'check': label, 'pass': actual == expected,
                          'actual': actual, 'expected': expected}), flush=True)
        assert actual == expected, label

    def exists(self, name):
        return bool(self.sql(f"SELECT name FROM system.tables WHERE database=currentDatabase() AND name='{name}'", True))

    def topic(self, push=False):
        return 'usage-topology-local-' + self.run + ('-push' if push else '-request')

    def queue(self, push=False, new=False, writer=None):
        name = writer or QUEUES[int(push)]
        fields = PUSH_QUEUE if push else REQUEST_QUEUE
        if new:
            fields += ',' + DIMENSIONS
        # Same group before/after replacement. Test differs from prod only in
        # local addresses/names and broken-message policy (0 so failures surface).
        group = 'usage-topology-local-' + self.run + ('-push' if push else '-request')
        if writer:
            group += '-' + writer
        self.sql(f'''CREATE TABLE {name} ({fields}) ENGINE=Kafka SETTINGS
          kafka_broker_list='{self.broker}',kafka_topic_list='{self.topic(push)}',
          kafka_group_name='{group}',kafka_format='JSONEachRow',
          kafka_skip_broken_messages=0,input_format_defaults_for_omitted_fields=1
          {',kafka_max_block_size=65536' if not push else ''}''')

    def dimensions(self, push=False):
        transport, kind = ('ws', 'subscription_push') if push else ('http', 'rpc_request')
        return f''',q.route_name,
          if(q.schema_version<2 AND q.transport='', '{transport}', q.transport) transport,
          if(q.schema_version<2 AND q.event_kind='', '{kind}', q.event_kind) event_kind,
          if(q.schema_version=0,toUInt8(1),q.schema_version) schema_version'''

    def request_ingest(self, new=False):
        self.sql('''CREATE MATERIALIZED VIEW mv_request_queue TO t_request_metrics AS SELECT
          user_id,app_id,toIPv6OrDefault(client_ip) client_ip,network,
          if(isValidJSON(request) AND JSONType(request)='Object',JSONExtractString(request,'method'),
            if(isValidJSON(request) AND JSONType(request)='Array','batch','')) method,
          toInt64(duration*1000000000) duration,total_cu_cost,cu_costs,request,response,response_status_code,
          if(isValidJSON(response) AND JSONType(response)='Object',
            JSONExtract(response,'error','Tuple(code Int32,message String)').1,0) response_error_code,
          toDateTime(toInt32(toFloat32(time))) time'''
          + (self.dimensions() if new else '') + ' FROM t_request_queue q')

    def expanded(self, new=False):
        source = 't_request_metrics' if new else 't_request_queue'
        self.sql(f'''CREATE MATERIALIZED VIEW mv_request_queue_expanded TO t_request_metrics_expanded AS SELECT
          user_id,app_id,{'client_ip' if new else 'toIPv6OrDefault(client_ip)'} client_ip,network,
          if(isValidJSON(req_arr) AND JSONType(req_arr)='Object',JSONExtractString(req_arr,'method'),'') method,
          {'duration' if new else 'toInt64(duration*1000000000)'} duration,cost_arr cu_cost,
          req_arr request,resp_arr response,response_status_code,
          if(isValidJSON(resp_arr) AND JSONType(resp_arr)='Object',
            JSONExtract(resp_arr,'error','Tuple(code Int32,message String)').1,0) response_error_code,
          {'time' if new else 'toDateTime(toInt32(toFloat32(time)))'} time
          {',route_name,transport,event_kind,schema_version' if new else ''}
          FROM (SELECT q.*,
            if(isValidJSON(q.request) AND JSONType(q.request)='Array',JSONExtractArrayRaw(q.request),[q.request]) req_arr,
            length(req_arr) req_len,
            if(isValidJSON(q.response) AND JSONType(q.response)='Array',arrayResize(JSONExtractArrayRaw(q.response),req_len,''),
              if(req_len=1,[q.response],arrayResize([''],req_len,''))) resp_arr,
            if(isValidJSON(q.cu_costs) AND JSONType(q.cu_costs)='Array' AND length(JSONExtractArrayRaw(q.cu_costs))=req_len,
              arrayMap(x->toUInt32OrZero(x),JSONExtractArrayRaw(q.cu_costs)),arrayResize([toUInt32(0)],req_len,toUInt32(0))) cost_arr
            FROM {source} q) src
          ARRAY JOIN src.req_arr AS req_arr,src.resp_arr AS resp_arr,src.cost_arr AS cost_arr''')

    def push_ingest(self, new=False):
        self.sql('''CREATE MATERIALIZED VIEW mv_ws_event_queue TO t_ws_event_metrics AS SELECT
          user_id,app_id,toIPv6OrDefault(client_ip) client_ip,network,jsonrpc_method method,
          toInt64(duration*1000000000) duration,response_status_code,cu_cost,toDateTime(time) time,
          node_id,service_id,route_id,request_id,subscription_type'''
          + (self.dimensions(True) if new else '') + ' FROM t_ws_event_queue q')

    def bootstrap(self):
        for name, extra in [('t_request_metrics', ',total_cu_cost UInt32 DEFAULT 0,cu_costs String'),
                            ('t_request_metrics_expanded', ',cu_cost UInt32 DEFAULT 0')]:
            self.sql(f'''CREATE TABLE {name} ({RAW_COMMON}{extra}) ENGINE=MergeTree
              PARTITION BY toYYYYMMDD(time) ORDER BY (app_id,time) TTL time+INTERVAL 1 WEEK
              SETTINGS index_granularity=8192,ttl_only_drop_parts=1''')
        self.sql(f'''CREATE TABLE t_ws_event_metrics ({PUSH_RAW}) ENGINE=MergeTree
          ORDER BY (app_id,time) TTL time+INTERVAL 1 WEEK SETTINGS index_granularity=8192''')
        for period, bucket in [('daily', 'toStartOfDay'), ('minutes', 'toStartOfMinute')]:
            self.sql(f'''CREATE TABLE storage_mv_request_metrics_{period} (
              bucket DateTime,user_id String,app_id String,method String,network String,
              avg_duration Float64,cnt UInt64,batch_cnt UInt64,failed_cnt UInt64,rate_limited_cnt UInt64)
              ENGINE=SummingMergeTree PARTITION BY toYYYYMM(bucket)
              ORDER BY (bucket,user_id,app_id,method,network) SETTINGS index_granularity=8192''')
            self.sql(f'''CREATE MATERIALIZED VIEW mv_request_metrics_{period}
              TO storage_mv_request_metrics_{period} AS SELECT {bucket}(time) bucket,user_id,app_id,method,network,
              avg(duration) avg_duration,countIf(response_status_code!=429) cnt,
              countIf(response_error_code!=0 OR response_status_code!=200) failed_cnt,
              countIf(response_status_code=429) rate_limited_cnt FROM t_request_metrics_expanded
              GROUP BY bucket,user_id,app_id,method,network,request''')
        self.queue(); self.queue(push=True)
        self.expanded(); self.request_ingest(); self.push_ingest()
        # Establish a stable old graph like long-running production before tests.
        for name in QUEUES:
            self.sql('DETACH TABLE ' + name); self.sql('ATTACH TABLE ' + name)
        for push, prefix in [(False, 'request'), (True, 'push')]:
            self.queue(push=push, writer='legacy_' + prefix)
            self.queue(push=push, new=True, writer='new_' + prefix)
        self.sql('CREATE TABLE upgrade_state (version UInt64,phase String) ENGINE=MergeTree ORDER BY version')

    def state(self):
        rows = self.sql('SELECT phase FROM upgrade_state ORDER BY version DESC LIMIT 1', True)
        return rows[0]['phase'] if rows else 'old'

    def mark(self, phase):
        self.sql(f"INSERT INTO upgrade_state VALUES ({time.time_ns()},'{phase}')")

    def snapshot(self):
        return {name: self.sql('SELECT count() n FROM ' + name, True)[0]['n'] for name in RAW_TABLES}

    def wait(self, requests, expanded, pushes):
        expected = dict(zip(RAW_TABLES, map(str, (requests, expanded, pushes))))
        end = time.monotonic() + 45
        while time.monotonic() < end:
            actual = self.snapshot()
            if actual == expected:
                return
            time.sleep(.3)
        raise AssertionError(('ingestion did not settle', actual, expected))

    def produce(self, payloads, push=False, new=False):
        table = ('new_' if new else 'legacy_') + ('push' if push else 'request')
        self.sql('INSERT INTO ' + table + ' FORMAT JSONEachRow\n' + '\n'.join(json.dumps(x) for x in payloads))

    def prepare(self, fail_at=None):
        if self.state() in ('prepared', 'streaming'):
            return

        def checkpoint(phase):
            self.mark('preparing_' + phase)
            if fail_at == phase:
                raise InterruptedError(phase)

        for name in QUEUES:
            if self.exists(name):
                self.sql('DETACH TABLE ' + name)
        checkpoint('paused')
        # Only Kafka ingress and the expansion view are replaced. Legacy daily
        # and minute views and all raw/summary data stay in place.
        for name in INGEST_VIEWS:
            self.sql('DROP VIEW IF EXISTS ' + name)
        for name in RAW_TABLES:
            for definition in DIMENSIONS.split(','):
                self.sql('ALTER TABLE ' + name + ' ADD COLUMN IF NOT EXISTS ' + definition)
        for push, name in enumerate(QUEUES):
            if not self.exists(name):
                try:
                    self.sql('ATTACH TABLE ' + name)
                except RuntimeError as error:
                    if 'UNKNOWN_TABLE' not in str(error) and 'FILE_DOESNT_EXIST' not in str(error):
                        raise
            self.sql('DROP TABLE IF EXISTS ' + name)
            self.queue(push=bool(push), new=True)
        checkpoint('queues_replaced')
        self.expanded(new=True)
        checkpoint('expanded_ready')
        self.sql(f'''CREATE TABLE IF NOT EXISTS usage_daily_v2 (
          user_id String,day Date,app_id String,network String,route_name String,transport String,event_kind String,
          cu UInt64,events UInt64,rate_limited UInt64)
          ENGINE=SummingMergeTree((cu,events,rate_limited)) PARTITION BY toYYYYMM(day)
          ORDER BY ({KEYS}) TTL day+INTERVAL 13 MONTH''')
        for name, source, condition in [('request', RAW_TABLES[1], 'response_status_code!=429'),
                                        ('push', RAW_TABLES[2], '1')]:
            self.sql(f'''CREATE MATERIALIZED VIEW IF NOT EXISTS usage_daily_{name} TO usage_daily_v2 AS
              SELECT user_id,toDate(time,'UTC') day,app_id,network,route_name,transport,event_kind,
              sumIf(toUInt64(cu_cost),{condition}) cu,count() events,countIf(response_status_code=429) rate_limited
              FROM {source} GROUP BY {KEYS}''')
        checkpoint('summaries_ready')
        self.mark('prepared')

    def resume(self, fail_after_http=False):
        if self.state() == 'streaming':
            return
        assert self.state() == 'prepared', 'Preparation is not complete'
        for name in (*RAW_TABLES, *QUEUES, 'mv_request_queue_expanded', 'mv_request_metrics_daily',
                     'mv_request_metrics_minutes', 'usage_daily_request', 'usage_daily_push', 'usage_daily_v2'):
            assert self.exists(name), 'Missing downstream: ' + name
        if not self.exists('mv_request_queue'):
            self.request_ingest(new=True)
        if fail_after_http:
            raise InterruptedError('http started; push still paused')
        if not self.exists('mv_ws_event_queue'):
            self.push_ingest(new=True)
        self.mark('streaming')


def main():
    c = Local()
    print(json.dumps({'database': c.db, 'broker': c.broker, 'request_topic': c.topic(),
                      'push_topic': c.topic(True)}), flush=True)

    def request(label, costs, status=200, **dimensions):
        requests = [{'jsonrpc': '2.0', 'id': f'{label}-{i}', 'method': 'eth_blockNumber', 'params': []}
                    for i, _ in enumerate(costs)]
        responses = [{'jsonrpc': '2.0', 'id': x['id'], **({'result': '0x1'} if status == 200 else
                     {'error': {'code': 429, 'message': 'limited'}})} for x in requests]
        return {'user_id': 'local-user', 'app_id': 'local-app', 'client_ip': '127.0.0.1',
                'network': 'dogeos-testnet', 'duration': .01, 'total_cu_cost': sum(costs),
                'cu_costs': json.dumps(costs), 'request': json.dumps(requests[0] if len(costs) == 1 else requests),
                'response': json.dumps(responses[0] if len(costs) == 1 else responses),
                'response_status_code': status, 'time': str(time.time()), **dimensions}

    def push(label, **dimensions):
        return {'user_id': 'local-user', 'app_id': 'local-app', 'client_ip': '127.0.0.1',
                'network': 'dogeos-testnet', 'duration': 0, 'response_status_code': 200,
                'time': time.time(), 'jsonrpc_method': 'eth_subscription', 'cu_cost': 5,
                'node_id': 'local-node', 'service_id': '3', 'route_id': '6002',
                'request_id': label, 'subscription_type': 'newHeads', **dimensions}

    try:
        c.bootstrap()
        c.produce([request('baseline-single', [3]), request('baseline-batch', [2, 4])])
        c.produce([push('baseline-push')], push=True)
        c.wait(2, 3, 1)
        baseline = c.snapshot()
        for period in ('daily', 'minutes'):
            c.check('old ' + period + ' graph', c.sql(f'SELECT sum(cnt) cnt FROM storage_mv_request_metrics_{period}', True), [{'cnt': '3'}])

        for phase in ('paused', 'queues_replaced', 'expanded_ready', 'summaries_ready'):
            try:
                c.prepare(fail_at=phase)
            except InterruptedError as error:
                c.check('injected failure ' + phase, str(error), phase)
            else:
                raise AssertionError('Failure was not injected')
            c.check('original data preserved after ' + phase, c.snapshot(), baseline)
        c.prepare()
        c.prepare()  # idempotent acknowledgement-loss retry
        c.check('prepared state persisted', c.state(), 'prepared')
        c.check('no historical backfill', c.sql('SELECT count() n FROM usage_daily_v2', True), [{'n': '0'}])

        # Deliberately break a downstream precondition: neither ingress may start.
        c.sql('RENAME TABLE usage_daily_push TO usage_daily_push_held')
        try:
            try:
                c.resume()
            except AssertionError as error:
                c.check('missing downstream blocks resume', str(error), 'Missing downstream: usage_daily_push')
            else:
                raise AssertionError('Unsafe resume accepted')
            c.check('guard starts no Kafka ingress', [c.exists(x) for x in ('mv_request_queue', 'mv_ws_event_queue')], [False, False])
        finally:
            c.sql('RENAME TABLE usage_daily_push_held TO usage_daily_push')

        c.produce([request('legacy-backlog', [1])])
        c.produce([request('ws-batch', [2, 4], route_name='dogeos-testnet-ws', transport='ws', event_kind='rpc_request', schema_version=2),
                   request('public', [2], route_name='dogeos-testnet-public', transport='http', event_kind='rpc_request', schema_version=2),
                   request('limited', [19], status=429, route_name='dogeos-testnet', transport='http', event_kind='rpc_request', schema_version=2)], new=True)
        c.produce([push('legacy-push-backlog')], push=True)
        c.produce([push('new-push-backlog', route_name='dogeos-testnet-ws', transport='ws', event_kind='subscription_push', schema_version=2)], push=True, new=True)
        c.check('Kafka backlog leaves raw untouched', c.snapshot(), baseline)
        try:
            c.resume(fail_after_http=True)
        except InterruptedError:
            c.check('partial resume retained prepared state', c.state(), 'prepared')
        c.resume()
        c.wait(6, 8, 3)
        c.check('resume completes', c.state(), 'streaming')
        c.check('batch per-method CU preserved', c.sql("SELECT cu_cost FROM t_request_metrics_expanded WHERE transport='ws' ORDER BY cu_cost", True), [{'cu_cost': 2}, {'cu_cost': 4}])
        expected = [{'cu': '19', 'events': '7', 'limited': '1'}]
        end = time.monotonic() + 15
        while time.monotonic() < end:
            actual = c.sql('SELECT sum(cu) cu,sum(events) events,sum(rate_limited) limited FROM usage_daily_v2', True)
            if actual == expected:
                break
            time.sleep(.3)
        c.check('new summary excludes history and 429 CU', actual, expected)
        for period in ('daily', 'minutes'):
            c.check('old ' + period + ' remains correct', c.sql(f'SELECT sum(cnt) cnt,sum(rate_limited_cnt) limited FROM storage_mv_request_metrics_{period}', True), [{'cnt': '7', 'limited': '1'}])
        c.check('Kafka request has exactly one consuming view',
                c.sql("SELECT name FROM system.tables WHERE database=currentDatabase() AND engine='MaterializedView' AND position(create_table_query,concat('FROM ',currentDatabase(),'.t_request_queue'))>0 ORDER BY name", True),
                [{'name': 'mv_request_queue'}])
        c.check('raw request and expanded CU agree including rejected computed cost',
                c.sql('SELECT (SELECT sum(total_cu_cost) FROM t_request_metrics) raw,(SELECT sum(cu_cost) FROM t_request_metrics_expanded) expanded', True), [{'raw': '37', 'expanded': '37'}])
        c.prepare(); c.resume()  # must be no-ops after a completed resume
        for name in QUEUES:
            c.sql('DETACH TABLE ' + name); c.sql('ATTACH TABLE ' + name)
        time.sleep(3)
        c.check('reader restart and completed retries do not replay', c.snapshot(), dict(zip(RAW_TABLES, ('6', '8', '3'))))
        c.check('reader restart preserves new summary', c.sql('SELECT sum(cu) cu,sum(events) events,sum(rate_limited) limited FROM usage_daily_v2', True), expected)
        print(json.dumps({'result': 'PASS', 'checks': c.checks, 'database': c.db,
                          'broker': c.broker, 'raw_requests': 6, 'expanded_requests': 8,
                          'pushes': 3, 'new_summary_cu': 19,
                          'scope': 'production-shape DDL/local synthetic Kafka messages; not APISIX or Dashboard acceptance'}), flush=True)
    finally:
        for name in QUEUES:
            if c.exists(name):
                c.sql('DETACH TABLE ' + name)


if __name__ == '__main__':
    main()
