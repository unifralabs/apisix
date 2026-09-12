"""Real APISIX + Redis + HTTP/WS mock; isolated Compose network only.

No production URL overrides, FLUSHDB, or external node dependencies. Every test
gets a new account quota key; inspect the actual Redis ledger AND upstream calls.
"""
import concurrent.futures
import gzip
import json
import socket
import struct
import time
import traceback
import uuid
from datetime import datetime, timezone

from access_mock import frame, read_frame
from test_access import admin, request, rpc, WebSocket, UPSTREAM, PROXY, count

RUN = "billing-" + uuid.uuid4().hex[:10]
PASSED = 0
FAILED = []
REDIS_TIMEOUT_MS = 1000
REDIS_FAILURE_PAUSE_MS = 1500


def redis(*args):
    def read(stream):
        line = stream.readline()
        prefix, value = line[:1], line[1:-2]
        if prefix == b"+": return value.decode()
        if prefix == b"-": raise RuntimeError(value.decode())
        if prefix == b":": return int(value)
        if prefix == b"$":
            length = int(value)
            if length < 0: return None
            result = stream.read(length)
            assert stream.read(2) == b"\r\n"
            return result.decode()
        if prefix == b"*": return [read(stream) for _ in range(int(value))]
        raise RuntimeError(repr(line))
    values = [str(x).encode() for x in args]
    data = (f"*{len(values)}\r\n".encode() + b"".join(
        f"${len(v)}\r\n".encode() + v + b"\r\n" for v in values))
    with socket.create_connection(("redis", 6379), timeout=5) as sock:
        sock.sendall(data)
        with sock.makefile("rb") as stream:
            return read(stream)


class Account:
    def __init__(self, tier="free", seconds=100000, monthly=100000, quota_key=None):
        self.key = RUN + "-" + uuid.uuid4().hex[:10]
        self.quota_key = quota_key or self.key
        self.month_key = f"quota:monthly:{self.quota_key}:" + datetime.now(timezone.utc).strftime("%Y%m")
        self.rate_key = f"ratelimit:cu:sliding:{self.quota_key}:values"
        admin("consumers/" + self.key, {"username": self.key, "plugins": {
            "key-auth": {"key": self.key}, "unifra-ctx-var": {
                "rpc_tier": tier, "seconds_quota": str(seconds),
                "monthly_quota": str(monthly), "quota_key": self.quota_key}}})
        time.sleep(0.08)

    def used(self): return int(redis("GET", self.month_key) or 0)
    def rate(self): return sum(float(v) for v in redis("HVALS", self.rate_key))
    def ws(self): return WebSocket("/billing-ws", self.key)
    def http(self, payload, headers=None, raw=None):
        return request(PROXY + "/billing-http", "POST", raw if raw is not None else payload,
                       {"Host": "access.test", "Content-Type": "application/json",
                        "apikey": self.key, **(headers or {})})[1]


def code(response):
    return response.get("error", {}).get("code") if isinstance(response, dict) else None


def success(response):
    replies = response if isinstance(response, list) else [response]
    assert all(isinstance(r, dict) and "result" in r for r in replies), response


def checked(account, call, payload, cost, forwarded, error=None):
    before, previous = count(), account.used()
    response = call(payload)
    if error is None: success(response)
    else: assert code(response) == error, response
    assert account.used() == previous + cost, ("monthly CU", previous, account.used(), cost)
    assert count() - before == forwarded, ("upstream calls", count() - before, forwarded)
    return response


def run(name, fn):
    global PASSED
    try:
        fn()
        PASSED += 1
        print("PASS", name, flush=True)
    except Exception:
        FAILED.append(name)
        print("FAIL", name, flush=True)
        traceback.print_exc()


def setup():
    for plugin in ("unifra-limit-cu", "unifra-limit-monthly-cu", "unifra-ws-jsonrpc-proxy"):
        admin("plugin_metadata/" + plugin, {"redis_host": "redis", "redis_port": 6379,
                                           "redis_timeout": REDIS_TIMEOUT_MS})
    admin("routes/billing-http", {"uri": "/billing-http", "host": "access.test",
        "methods": ["POST"], "upstream": UPSTREAM, "plugins": {
            "key-auth": {}, "unifra-jsonrpc-var": {"network": "arc-testnet"},
            "unifra-whitelist": {},
            "unifra-calculate-cu": {}, "unifra-limit-cu": {"allow_degradation": False},
            "unifra-limit-monthly-cu": {}}})
    admin("routes/billing-ws", {"uri": "/billing-ws", "host": "access.test",
        "methods": ["GET"], "enable_websocket": True, "upstream": UPSTREAM,
        "plugins": {"key-auth": {}, "unifra-ws-jsonrpc-proxy": {
            "network": "arc-testnet",
            "enable_rate_limit": True, "allow_degradation": False}}})
    time.sleep(1)


def limit_case(tier, transport, batch, limit):
    method, unit = ("eth_call", 5) if tier == "free" else ("debug_traceTransaction", 30)
    payload = [rpc(), rpc(method, 2)] if batch else rpc(method)
    cost = unit + int(batch)
    account = Account(tier, seconds=2*cost if limit == "seconds" else 100000,
                      monthly=2*cost if limit == "monthly" else 100000)
    ws = account.ws() if transport == "ws" else None
    call = ws.call if ws else account.http
    try:
        for _ in range(2): checked(account, call, payload, cost, 2 if batch else 1)
        checked(account, call, payload, 0, 0, -32000 if limit == "seconds" else -32001)
        if limit == "seconds":
            assert account.rate() == 2*cost, account.rate()
            time.sleep(1.1)
            checked(account, call, payload, cost, 2 if batch else 1)
        else:
            # Rate admission precedes the monthly check; this is NOT monthly billing.
            assert account.rate() == 3*cost, account.rate()
    finally:
        if ws: ws.close()


def permission_case(tier, transport, batch):
    account = Account(tier, monthly=10**9 if tier == "free" else 1000)
    ws = account.ws() if transport == "ws" else None
    call = ws.call if ws else account.http
    payload = [rpc(), rpc("debug_traceTransaction", 2)] if batch else rpc("debug_traceTransaction")
    try:
        checked(account, call, payload, 30 + int(batch) if tier == "paid" else 0,
                (2 if batch else 1) if tier == "paid" else 0, None if tier == "paid" else -32003)
        if tier == "free": assert account.rate() == 0
    finally:
        if ws: ws.close()


def pricing_case(transport):
    account = Account("paid")
    ws = account.ws() if transport == "ws" else None
    try:
        for method, cost in [("eth_blockNumber", 1), ("eth_getBalance", 2),
             ("eth_getBlockByNumber", 3), ("eth_call", 5), ("eth_getLogs", 10),
             ("debug_traceTransaction", 30), ("debug_traceBlockByNumber", 50),
             ("debug_traceCall", 30), ("trace_block", 50), ("trace_transaction", 25),
             ("trace_get", 25), ("eth_chainId", 1)]:
            checked(account, ws.call if ws else account.http, rpc(method), cost, 1)
    finally:
        if ws: ws.close()


def batch_atomic(transport):
    account = Account(monthly=6)
    ws = account.ws() if transport == "ws" else None
    try:
        call = ws.call if ws else account.http
        checked(account, call, rpc("eth_call"), 5, 1)
        checked(account, call, [rpc(), rpc("eth_call", 2)], 0, 0, -32001)
        checked(account, call, rpc(), 1, 1)
    finally:
        if ws: ws.close()


def encoding_case():
    account = Account()
    checked(account, lambda p: account.http(p, {"Content-Encoding": "gzip"},
            gzip.compress(json.dumps(p).encode())), rpc("eth_call"), 5, 1)
    checked(account, lambda p: account.http(p, {"Content-Type": "text/plain"}), rpc(), 1, 1)
    before = account.used()
    notification = rpc("eth_call")
    notification.pop("id")
    result = account.http(notification)
    assert result is None and account.used() == before + 5, (result, account.used())
    checked(account, account.http, [rpc(), {"jsonrpc": "2.0", "method": "eth_getBalance"}], 3, 2)
    before = account.used()
    account.http([notification, notification])
    assert account.used() == before + 10


def ws_encoding_case():
    account = Account()
    ws = account.ws()
    try:
        checked(account, lambda p: ws.call(p, binary=True), rpc("eth_call"), 5, 1)
        checked(account, lambda p: ws.call(p, fragmented=True), rpc("eth_getBalance"), 2, 1)
        checked(account, lambda p: ws.call(p, binary=True), rpc("debug_traceTransaction"), 0, 0, -32003)
        notification = rpc("eth_call")
        notification.pop("id")
        ws.sock.sendall(frame(json.dumps(notification).encode(), masked=True))
        success(ws.call(rpc()))
        assert account.used() == 13, account.used()
        result = checked(account, ws.call, [rpc(rpc_id="original"),
            {"jsonrpc": "2.0", "method": "eth_getBalance"}], 3, 2)
        assert result[0]["id"] == "original", result
        previous = account.used()
        ws.sock.sendall(frame(b"ping", 9, masked=True))
        op, data = read_frame(ws.stream)
        assert op == 10 and data == b"ping" and account.used() == previous
    finally: ws.close()


def rejection_case(transport):
    account = Account()
    ws = account.ws() if transport == "ws" else None
    try:
        call = ws.call if ws else account.http
        checked(account, call, rpc("admin_peers"), 0, 0, -32601)
        checked(account, call, [], 0, 0, -32600)
        assert account.rate() == 0
        error_payload = rpc("eth_call")
        error_payload["params"] = [{"mock_error": True}]
        checked(account, call, error_payload, 5, 1, -32010)
    finally:
        if ws: ws.close()


def sharing_case(limit):
    values = {"seconds": 3 if limit == "seconds" else 100000,
              "monthly": 3 if limit == "monthly" else 100000}
    a = Account(**values)
    b = Account(quota_key=a.quota_key, **values)
    ws = b.ws()
    try:
        checked(a, a.http, rpc(), 1, 1)
        checked(a, ws.call, rpc(), 1, 1)
        checked(a, b.http, rpc(), 1, 1)
        checked(a, ws.call, rpc(), 0, 0, -32000 if limit == "seconds" else -32001)
        assert b.used() == 3
    finally: ws.close()


def concurrency_case(transport):
    account = Account("paid", monthly=3)
    before = count()
    def invoke(_):
        if transport == "http": return account.http(rpc())
        ws = account.ws()
        try: return ws.call(rpc())
        finally: ws.close()
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        results = list(pool.map(invoke, range(20)))
    assert sum(code(r) is None for r in results) == 3, results
    assert all(code(r) in (None, -32001) for r in results), results
    assert account.used() == 3 and count() - before == 3, (account.used(), count() - before)


def subscribe(ws, event, rpc_id=1):
    payload = rpc("eth_subscribe", rpc_id)
    payload["params"] = [event]
    if event == "logs": payload["params"].append({"address": "0x" + "00" * 19 + "01"})
    result = ws.call(payload)
    success(result)
    return result["result"]


def push(subscription, result=None, binary=False):
    status, response = request("http://mock-rpc:8545/push", "POST", {
        "subscription": subscription, "result": {"opaque": True} if result is None else result,
        "binary": binary})
    assert status == 200, response
    return response["sent"]


def recv_push(ws, binary=False):
    opcode, data = read_frame(ws.stream)
    assert opcode == (2 if binary else 1), (opcode, data)
    payload = json.loads(data)
    assert payload["method"] == "eth_subscription", payload
    return payload


def pushes_case(tier, event, cost, binary=False):
    account = Account(tier, seconds=1)
    ws = account.ws()
    try:
        sub = subscribe(ws, event)
        assert account.used() == 1
        rate_before = account.rate()
        for i in range(3):
            assert push(sub, binary=binary)
            recv_push(ws, binary=binary)
            assert account.used() == 1 + (i+1)*cost, (event, account.used())
        assert account.rate() == rate_before == 1, account.rate()
        # The request budget is still exhausted by subscribe, not by pushes.
        checked(account, ws.call, rpc(), 0, 0, -32000)
    finally: ws.close()


def batch_subscriptions():
    account = Account("paid")
    ws = account.ws()
    try:
        payload = [rpc("eth_subscribe", "logs-id"), rpc("eth_subscribe", "pending-id")]
        payload[0]["params"] = ["logs", {"address": "0x" + "00" * 19 + "01"}]
        payload[1]["params"] = ["newPendingTransactions"]
        result = checked(account, ws.call, payload, 2, 2)
        assert [r["id"] for r in result] == ["logs-id", "pending-id"], result
        for response, expected in zip(result, (12, 32)):
            assert push(response["result"])
            recv_push(ws)
            assert account.used() == expected, (expected, account.used())
        unsubscribe = rpc("eth_unsubscribe")
        unsubscribe["params"] = [result[0]["result"]]
        checked(account, ws.call, unsubscribe, 1, 1)
        assert not push(result[0]["result"])
        assert account.used() == 33
    finally: ws.close()


def push_monthly_case(tier):
    account = Account(tier, monthly=21)
    ws = account.ws()
    try:
        sub = subscribe(ws, "logs")
        for _ in range(2):
            assert push(sub)
            recv_push(ws)
        assert account.used() == 21
        assert push(sub)
        op, data = read_frame(ws.stream)
        assert op == 8 and struct.unpack("!H", data[:2])[0] == 1008, (op, data)
        assert account.used() == 21
    finally: ws.close()


def push_sharing_case():
    account = Account(monthly=13)
    second = Account(quota_key=account.quota_key, monthly=13)
    a, b = account.ws(), second.ws()
    try:
        sa, sb = subscribe(a, "newHeads"), subscribe(b, "newHeads")
        assert push(sa)
        recv_push(a)
        checked(account, account.http, rpc(), 1, 1)
        assert push(sb)
        recv_push(b)
        assert account.used() == second.used() == 13
        checked(account, b.call, rpc(), 0, 0, -32001)
    finally:
        a.close()
        b.close()


def calendar_case():
    account = Account()
    previous = datetime.now(timezone.utc).replace(day=1)
    from datetime import timedelta
    old_key = f"quota:monthly:{account.quota_key}:" + (previous-timedelta(days=1)).strftime("%Y%m")
    redis("SET", old_key, 999)
    checked(account, account.http, rpc(), 1, 1)
    assert redis("GET", old_key) == "999"
    ttl = redis("TTL", account.month_key)
    assert 0 < ttl <= 31*86400, ttl
    redis("DEL", old_key)  # Only this test's explicitly constructed prior-month fixture.


def push_redis_failure():
    account = Account()
    ws = account.ws()
    try:
        sub = subscribe(ws, "logs")
        assert account.used() == 1
        redis("CLIENT", "PAUSE", REDIS_FAILURE_PAUSE_MS, "ALL")
        assert push(sub)
        op, data = read_frame(ws.stream)
        assert op == 8 and struct.unpack("!H", data[:2])[0] == 1011, (op, data)
        assert data[2:].decode() == "Service temporarily unavailable", data
        time.sleep((REDIS_FAILURE_PAUSE_MS + 100) / 1000)
        assert account.used() == 1
    finally: ws.close()


def main():
    setup()
    for tier in ("free", "paid"):
        for transport in ("http", "ws"):
            for batch in (False, True):
                for limit in ("seconds", "monthly"):
                    run(f"{tier}/{transport}/{'batch' if batch else 'single'}/{limit}",
                        lambda t=tier, p=transport, b=batch, l=limit: limit_case(t,p,b,l))
                run(f"{tier}/{transport}/batch={batch}/permission", lambda t=tier,p=transport,b=batch: permission_case(t,p,b))
    for transport in ("http", "ws"):
        run(transport + "/exact pricing and wildcard costs", lambda p=transport: pricing_case(p))
        run(transport + "/batch monthly all-or-nothing", lambda p=transport: batch_atomic(p))
        run(transport + "/rejection and upstream error billing", lambda p=transport: rejection_case(p))
        run(transport + "/concurrent monthly atomicity", lambda p=transport: concurrency_case(p))
    run("HTTP gzip/content-type/client notifications", encoding_case)
    run("WS binary/fragment/client notification/ping", ws_encoding_case)
    for limit in ("seconds", "monthly"):
        run("shared HTTP/WS/two API keys/" + limit, lambda l=limit: sharing_case(l))
    for tier in ("free", "paid"):
        for event,cost in (("newHeads",5),("logs",10)) + ((("newPendingTransactions",20),) if tier == "paid" else ()):
            run(f"{tier}/push/{event}/monthly only", lambda t=tier,e=event,c=cost: pushes_case(t,e,c))
        run(tier + "/push/monthly exhaustion closes", lambda t=tier: push_monthly_case(t))
        run(tier + "/binary push/monthly only", lambda t=tier: pushes_case(t, "logs", 10, True))
    run("batch subscriptions preserve event pricing and unsubscribe", batch_subscriptions)
    run("two subscriptions plus HTTP share monthly CU", push_sharing_case)
    run("UTC calendar monthly key and expiration", calendar_case)
    # Fault injection is last and limited to the isolated Redis for one second.
    run("push Redis outage fails closed without unbilled delivery", push_redis_failure)
    print(f"\n{PASSED} passed; {len(FAILED)} failed", flush=True)
    if FAILED: raise SystemExit(1)


if __name__ == "__main__": main()
