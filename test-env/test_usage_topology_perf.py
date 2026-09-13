"""Bounded, local-only storage benchmark for the new analytics dimensions.

Synthetic direct inserts benchmark ClickHouse reads, not Kafka, Redis billing,
Dashboard latency, or production traffic. All objects live in a fresh test DB.
"""
import json
import time
from test_usage_topology import Local, KEYS


def main():
    c = Local()
    c.sql('''CREATE TABLE request_fixture (
      user_id String,time DateTime,app_id String,network String,route_name String,
      transport String,event_kind String,cu_cost UInt32,response_status_code Int32)
      ENGINE=MergeTree PARTITION BY toYYYYMMDD(time) ORDER BY (app_id,time)''')
    c.sql(f'''CREATE TABLE daily_fixture (
      user_id String,day Date,app_id String,network String,route_name String,
      transport String,event_kind String,cu UInt64,events UInt64)
      ENGINE=SummingMergeTree((cu,events)) PARTITION BY toYYYYMM(day) ORDER BY ({KEYS})''')
    c.sql(f'''CREATE MATERIALIZED VIEW fixture_mv TO daily_fixture AS
      SELECT user_id,toDate(time,'UTC') day,app_id,network,route_name,transport,event_kind,
      sumIf(toUInt64(cu_cost),response_status_code!=429) cu,count() events
      FROM request_fixture GROUP BY {KEYS}''')
    c.sql('''INSERT INTO request_fixture SELECT
      concat('user-',toString(number%1000)),now(),concat('app-',toString(number%2000)),
      if(intDiv(number,2000)%2=0,'dogeos-testnet','arc-testnet') network,
      concat(network,if(intDiv(number,4000)%2=0,'','-ws')),
      if(intDiv(number,4000)%2=0,'http','ws') transport,
      if(transport='ws' AND intDiv(number,8000)%2=0,'subscription_push','rpc_request'),
      toUInt32(1+number%5),toInt32(200) FROM numbers(1000000)''')
    raw = '''SELECT network,route_name,transport,event_kind,
      sumIf(toUInt64(cu_cost),response_status_code!=429) cu,count() events
      FROM request_fixture WHERE user_id='user-417'
      GROUP BY network,route_name,transport,event_kind ORDER BY network,route_name,transport,event_kind'''
    daily = '''SELECT network,route_name,transport,event_kind,sum(cu) cu,sum(events) events
      FROM daily_fixture WHERE user_id='user-417'
      GROUP BY network,route_name,transport,event_kind ORDER BY network,route_name,transport,event_kind'''
    # Compare an explicitly labelled local index-granularity candidate. This
    # copies only this benchmark's tiny aggregate, never historical raw logs.
    c.sql(f'''CREATE TABLE daily_fine AS daily_fixture
      ENGINE=SummingMergeTree((cu,events)) PARTITION BY toYYYYMM(day) ORDER BY ({KEYS})
      SETTINGS index_granularity=1024''')
    c.sql('INSERT INTO daily_fine SELECT * FROM daily_fixture')
    report = {'database': c.db, 'input_rows': 1000000,
              'scope': 'local synthetic direct-insert storage benchmark; not API P95'}
    for label, query in [('raw', raw), ('daily', daily),
                         ('daily_granularity_1024', daily.replace('daily_fixture', 'daily_fine'))]:
        start = time.monotonic()
        rows = c.sql(query, True)
        report[label] = {'statistics': c.last_statistics, 'wall_seconds': time.monotonic()-start,
                         'groups': len(rows), 'cu': sum(int(r['cu']) for r in rows),
                         'events': sum(int(r['events']) for r in rows)}
        if label == 'raw':
            expected = rows
        else:
            assert rows == expected, (rows, expected)
    report['read_row_reduction'] = 1-report['daily']['statistics']['rows_read']/report['raw']['statistics']['rows_read']
    report['fine_index_read_row_reduction'] = 1-report['daily_granularity_1024']['statistics']['rows_read']/report['raw']['statistics']['rows_read']
    report['default_index_99_percent_target_met'] = report['read_row_reduction'] >= .99
    report['fine_index_99_percent_target_met'] = report['fine_index_read_row_reduction'] >= .99
    assert report['daily']['events'] == 1000
    assert report['daily']['statistics']['rows_read'] < report['raw']['statistics']['rows_read']
    report['result'] = 'PASS'
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
