"""Arc/DogeOS security regression; ONLY the internal access-test Docker stack.

Imports real WS routes + Service 3, replaces upstreams with the HTTP/WS mock,
and installs local Redis metadata/Consumers. Never loads production credentials.
--baseline proves the old bypass against the mock before applying the fix.
"""
import argparse
import base64
import http.client
import json
import time
from pathlib import Path

import test_access as t
from test_billing_e2e import Account

DEBUG = ["debug_traceTransaction", "debug_traceCall", "debug_traceBlockByHash",
         "debug_traceBlockByNumber"]
TRACE = ["trace_block", "trace_transaction", "trace_call", "trace_callMany",
         "trace_rawTransaction", "trace_replayBlockTransactions",
         "trace_replayTransaction", "trace_filter", "trace_get"]
DENIED = ["debug_setHead", "debug_chaindbCompact", "debug_startCPUProfile",
          "debug_stopCPUProfile", "debug_writeMemProfile", "debug_traceBlockFromFile",
          "debug_verbosity", "debug_foo", "trace_foo", "admin_addPeer",
          "personal_unlockAccount", "miner_start"]


def setup(config_dir):
    keys = t.setup(config_dir)
    service = json.loads((config_dir / "service/3-ws-plugins-prod.json").read_text())
    # Transport/auth/limit-conn/policies are the real service configuration.
    t.admin("services/security-ws", service)
    for network, route_id in (("arc-testnet", "6502"), ("dogeos-testnet", "6002")):
        files = list((config_dir / "route").glob(route_id + "-*.json"))
        assert len(files) == 1, files
        route = json.loads(files[0].read_text())
        assert "POST" in route["methods"], "Keep legacy permissive route for regression"
        route.pop("upstream_id")
        route["upstream"] = t.UPSTREAM
        route["service_id"] = "security-ws"
        t.admin("routes/security-" + route_id, route)
        # Normal authenticated HTTP uses the same network whitelist.
        t.admin("routes/security-http-" + network, {
            "uri": "/security-http", "host": network + ".unifra.io",
            "methods": ["POST"], "upstream": t.UPSTREAM,
            "plugins": {"key-auth": {}, "unifra-jsonrpc-var": {"network": network},
                        "unifra-whitelist": {}, "unifra-calculate-cu": {},
                        "unifra-limit-monthly-cu": {}}})
    # Give the permission matrix ample quota; keep the exhausted Consumer at 1 CU.
    for tier in ("free", "paid"):
        key = keys["free-high" if tier == "free" else "paid-low"]
        t.admin("consumers/" + key, {"username": key, "plugins": {
            "key-auth": {"key": key}, "unifra-ctx-var": {
                "rpc_tier": tier, "monthly_quota": "1000000000", "seconds_quota": "0"}}})
    time.sleep(2)
    return keys


def http_on_ws(network, key, method="POST", headers=None, expected=400, forwarded=0):
    before = t.count()
    conn = http.client.HTTPConnection("apisix", 9080, timeout=10)
    hdrs = {"Host": network + ".unifra.io", "Content-Type": "application/json"}
    hdrs.update(headers or {})
    try:
        conn.request(method, "/ws/" + key, json.dumps(t.rpc("debug_traceTransaction")), hdrs)
        response = conn.getresponse()
        body = response.read()
        assert response.status == expected, (response.status, body)
        assert t.count() - before == forwarded, (before, t.count(), body)
    finally:
        conn.close()


def ws_rpc(network, key, method, code=None):
    ws = t.WebSocket("/ws/" + key, host=network + ".unifra.io")
    try:
        before = t.count()
        response = ws.call(t.rpc(method))
        t.check_response(None, response, before, 0 if code else 1, code)
    finally:
        ws.close()


def ws_shapes(network, key):
    ws = t.WebSocket("/ws/" + key, host=network + ".unifra.io",
                     upgrade="WebSocket", connection="keep-alive, UpGrAdE")
    try:
        for payload, code, forwarded in [
            ([t.rpc(), t.rpc("debug_setHead", 2)], -32601, 0),
            ({"jsonrpc": "2.0", "method": "debug_setHead", "params": []}, -32601, 0),
            (t.rpc(), None, 1),
        ]:
            before = t.count()
            response = ws.call(payload, binary=True, fragmented=True)
            t.check_response(None, response, before, forwarded, code)
        before = t.count()
        payload = t.rpc("eth_subscribe")
        payload["params"] = ["newHeads"]
        subscription = ws.call(payload)["result"]
        payload = t.rpc("eth_unsubscribe")
        payload["params"] = [subscription]
        assert ws.call(payload)["result"] is True
        assert t.count() - before == 2
    finally:
        ws.close()


def ws_rate_limit(network):
    account = Account("paid", seconds=29, monthly=1000000)
    before = account.used()
    ws_rpc(network, account.key, "debug_traceTransaction", -32000)
    assert account.used() == before


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-dir", type=Path, required=True)
    parser.add_argument("--baseline", action="store_true")
    args = parser.parse_args()
    keys = setup(args.config_dir)
    for network in ("arc-testnet", "dogeos-testnet"):
        if args.baseline:
            for name in ("free-high", "paid-exhausted"):
                t.test(network + " OLD POST bypass " + name, lambda: http_on_ws(
                    network, keys[name], expected=200, forwarded=1))
            t.test(network + " OLD paid debug_setHead admitted to mock", lambda: ws_rpc(
                network, keys["paid-low"], "debug_setHead"))
            continue
        for name in ("free-high", "paid-low", "paid-exhausted"):
            for method in ("POST", "GET", "PUT", "PATCH", "DELETE", "HEAD"):
                t.test(f"{network} rejects non-WS {method} {name}", lambda: http_on_ws(
                    network, keys[name], method=method))
        # Spoofed Upgrade is not a valid WebSocket handshake.
        valid_headers = {"Upgrade": "websocket", "Connection": "Upgrade",
                         "Sec-WebSocket-Key": base64.b64encode(b"security-test-12!").decode(),
                         "Sec-WebSocket-Version": "13"}
        for method, headers in [
            ("POST", valid_headers),
            ("GET", {"Upgrade": "websocket"}),
            ("GET", {"Upgrade": "websocket", "Connection": "Upgrade"}),
            ("GET", valid_headers | {"Connection": "notupgrade"}),
            ("GET", valid_headers | {"Sec-WebSocket-Version": "12"}),
            ("GET", valid_headers | {"Sec-WebSocket-Key": "invalid"}),
            ("GET", valid_headers | {"Sec-WebSocket-Key": base64.b64encode(b"x" * 17).decode()}),
        ]:
            t.test(network + " invalid handshake " + method + str(headers), lambda: http_on_ws(
                network, keys["free-high"], method=method, headers=headers))
        paid_methods = DEBUG + (TRACE if network == "arc-testnet" else [])
        for method in DEBUG + TRACE + DENIED:
            for name in ("free-high", "paid-low"):
                allowed = name == "paid-low" and method in paid_methods
                code = None if allowed else (-32003 if method in paid_methods else -32601)
                t.test(f"{network} HTTP {name} {method}", lambda: t.http_case(
                    path="/security-http", host=network + ".unifra.io", key=keys[name],
                    payload=t.rpc(method), error_code=code, status=200 if allowed else 405,
                    forwarded=1 if allowed else 0))
                t.test(f"{network} WS {name} {method}", lambda: ws_rpc(
                    network, keys[name], method, code))
        for method in DEBUG + DENIED:
            t.test(f"{network} public denies {method}", lambda: t.http_case(
                host=network + "-public.unifra.io", payload=t.rpc(method),
                error_code=-32003 if method in DEBUG else -32601, status=405, forwarded=0))
        t.test(network + " free WS basic", lambda: ws_rpc(network, keys["free-high"], "eth_blockNumber"))
        t.test(network + " paid WS exhausted quota", lambda: ws_rpc(
            network, keys["paid-exhausted"], "debug_traceTransaction", -32001))
        t.test(network + " WS rate limit", lambda: ws_rate_limit(network))
        t.test(network + " WS mixed-case handshake, batch, notification, binary, fragmentation, subscription",
               lambda: ws_shapes(network, keys["paid-low"]))
    print(f"\n{t.passed} passed, {len(t.failed)} failed", flush=True)
    if t.failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
