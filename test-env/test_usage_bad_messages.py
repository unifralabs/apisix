"""Local Kafka/ClickHouse 22.10 malformed-payload behavior, no offset reset.

Two independent groups consume the same three records with skip=0 vs skip=1.
This is a parser/retention-risk probe, not a promise of lossless ingestion.
"""
import json
import time
from test_usage_topology import Local


def main():
    c = Local()
    topic = c.topic() + '-malformed'
    print(json.dumps({'database': c.db, 'topic': topic}), flush=True)
    queues = []
    try:
        settings = f"kafka_broker_list='{c.broker}',kafka_topic_list='{topic}'"
        c.sql(f"CREATE TABLE writer (message String) ENGINE=Kafka SETTINGS {settings},kafka_group_name='{topic}-writer',kafka_format='RawBLOB'")
        for skip in (0, 1):
            queue = f'queue_skip_{skip}'
            queues.append(queue)
            c.sql(f'CREATE TABLE raw_skip_{skip} (value String) ENGINE=MergeTree ORDER BY value')
            c.sql(f"CREATE TABLE {queue} (value String) ENGINE=Kafka SETTINGS {settings},kafka_group_name='{topic}-skip-{skip}',kafka_format='JSONEachRow',kafka_skip_broken_messages={skip}")
            c.sql(f'CREATE MATERIALIZED VIEW ingest_skip_{skip} TO raw_skip_{skip} AS SELECT value FROM {queue}')
        def send(value):
            safe = value.replace('\\', '\\\\').replace("'", "\\'")
            c.sql("INSERT INTO writer VALUES ('" + safe + "')")
        def values(skip):
            return [r['value'] for r in c.sql(f'SELECT value FROM raw_skip_{skip} ORDER BY value', True)]
        def wait(skip, expected):
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                actual = values(skip)
                if actual == expected: return
                time.sleep(.3)
            raise AssertionError((skip, actual, expected))
        send('{"value":"one"}')
        for skip in (0, 1): wait(skip, ['one'])
        send('{"value":')
        send('{"value":"two"}')
        wait(1, ['one', 'two'])
        # Let the strict consumer encounter the same known partition records.
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            assert values(0) == ['one'], 'Strict reader unexpectedly passed malformed input'
            time.sleep(.3)
        c.check('existing skip=1 passes valid successor but stores no malformed record', values(1), ['one', 'two'])
        c.check('skip=0 stops before successor; no silent skip', values(0), ['one'])
        print('PASS observed policies; malformed JSON is NOT captured by typed-dimension exclusion view', flush=True)
    finally:
        for name in queues:
            if c.exists(name): c.sql('DETACH TABLE ' + name)


if __name__ == '__main__': main()
