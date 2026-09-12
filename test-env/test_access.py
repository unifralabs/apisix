"""Run only inside docker-compose.access.yml's internal network.

All Admin API writes target the isolated `apisix` service with a test-only key.
The mock counter is checked for every request, including rejected batches.
"""
import argparse
import base64
import gzip
import json
import socket
import time
import uuid
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from access_mock import frame, read_frame

ADMIN = "http://apisix:9180/apisix/admin/"
PROXY = "http://apisix:9080"
MOCK = "http://mock-rpc:8545/calls"
ADMIN_KEY = "unifra-access-test-only"
UPSTREAM = {"type": "roundrobin", "nodes": {"mock-rpc:8545": 1}}
passed = 0
failed = []


def request(url, method="GET", body=None, headers=None):
    if body is not None and not isinstance(body, bytes):
        body = json.dumps(body).encode()
    try:
        response = urlopen(Request(url, body, headers or {}, method=method), timeout=10)
    except HTTPError as error:
        response = error
    with response:
        data = response.read()
        return response.status, json.loads(data) if data else None


def admin(resource, value):
    status, response = request(ADMIN + resource, "PUT", value,
                               {"X-API-KEY": ADMIN_KEY, "Content-Type": "application/json"})
    assert status in (200, 201), (resource, status, response)


def test(name, fn):
    global passed
    try:
        fn()
        passed += 1
        print("PASS", name, flush=True)
    except Exception as error:
        failed.append(name)
        print("FAIL", name, repr(error), flush=True)


def rpc(method="eth_blockNumber", rpc_id=1):
    return {"jsonrpc": "2.0", "method": method, "params": [], "id": rpc_id}


def count():
    return len(request(MOCK)[1])


def check_response(status, response, before, forwarded, error_code=None, http_status=None,
                   error_message=None):
    if http_status is not None:
        assert status == http_status, (status, response)
    if error_code is not None:
        assert response["error"]["code"] == error_code, response
        if error_message is not None:
            assert response["error"]["message"] == error_message, response
    else:
        replies = response if isinstance(response, list) else [response]
        assert all(r and r.get("result", "").startswith("mock:") for r in replies), response
    assert count() - before == forwarded, ("upstream received unexpected calls", before, count())


def http_case(path="/", host="arc-testnet-public.unifra.io", payload=None,
              key=None, error_code=None, status=200, forwarded=1, headers=None, compressed=False,
              error_message=None):
    payload = rpc() if payload is None else payload
    body = json.dumps(payload).encode()
    hdrs = {"Content-Type": "application/json", "Host": host}
    if key:
        hdrs["apikey"] = key
    hdrs.update(headers or {})
    if compressed:
        body = gzip.compress(body)
        hdrs["Content-Encoding"] = "gzip"
    before = count()
    actual_status, response = request(PROXY + path, "POST", body, hdrs)
    check_response(actual_status, response, before, forwarded, error_code, status, error_message)


class WebSocket:
    def __init__(self, path, key=None):
        self.sock = socket.create_connection(("apisix", 9080), timeout=10)
        self.stream = self.sock.makefile("rb")
        ws_key = base64.b64encode(b"access-test-12345").decode()
        headers = (f"GET {path} HTTP/1.1\r\nHost: access.test\r\n"
                   "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                   f"Sec-WebSocket-Key: {ws_key}\r\nSec-WebSocket-Version: 13\r\n")
        if key:
            headers += f"apikey: {key}\r\n"
        self.sock.sendall((headers + "\r\n").encode())
        status = self.stream.readline()
        assert b" 101 " in status, status
        while self.stream.readline() not in (b"\r\n", b""):
            pass

    def call(self, payload, binary=False, fragmented=False):
        data = json.dumps(payload).encode()
        opcode = 2 if binary else 1
        if fragmented:
            middle = len(data) // 2
            self.sock.sendall(frame(data[:middle], opcode, masked=True, final=False)
                              + frame(data[middle:], 0, masked=True))
        else:
            self.sock.sendall(frame(data, opcode, masked=True))
        opcode, data = read_frame(self.stream)
        assert opcode == 1, (opcode, data)
        return json.loads(data)

    def close(self):
        try:
            self.sock.sendall(frame(b"", 8, masked=True))
        finally:
            self.stream.close()
            self.sock.close()


def ws_case(path="/ws-public", key=None, payload=None, error_code=None,
            forwarded=1, binary=False, fragmented=False, error_message=None):
    ws = WebSocket(path, key)
    try:
        before = count()
        response = ws.call(rpc() if payload is None else payload, binary, fragmented)
        check_response(None, response, before, forwarded, error_code,
                       error_message=error_message)
    finally:
        ws.close()


def setup(config_dir):
    for attempt in range(60):
        try:
            status, _ = request(ADMIN + "routes", headers={"X-API-KEY": ADMIN_KEY})
            if status == 200:
                break
        except (URLError, ConnectionError):
            pass
        time.sleep(0.5)
    else:
        raise RuntimeError("Isolated APISIX Admin API did not become ready")

    # Real public service/routes, with logging removed and upstreams replaced.
    # No production upstream or metadata is ever submitted to this gateway.
    for env in ("prod", "staging"):
        service = json.loads((config_dir / f"service/4-jsonrpc-plugins-public-{env}.json").read_text())
        assert service["plugins"]["unifra-whitelist"]["method_policy"] == "free_only"
    daily = json.loads((config_dir / "service/6-jsonrpc-plugins-public-staging-daily.json").read_text())
    assert daily["plugins"]["unifra-whitelist"]["method_policy"] == "free_only"
    service = json.loads((config_dir / "service/4-jsonrpc-plugins-public-prod.json").read_text())
    service["plugins"].pop("kafka-logger", None)
    admin("services/4", service)
    for route_file in sorted((config_dir / "route").glob("*-public.json")):
        route = json.loads(route_file.read_text())
        route.pop("upstream_id", None)
        route["upstream"] = UPSTREAM
        admin("routes/" + route_file.name.split("-")[0], route)
    options = json.loads((config_dir / "route/60-support-options.json").read_text())
    admin("routes/60", options)

    for plugin in ("unifra-limit-cu", "unifra-limit-monthly-cu", "unifra-ws-jsonrpc-proxy"):
        admin("plugin_metadata/" + plugin, {"redis_host": "redis", "redis_port": 6379})

    cases = {"free-high": ("free", 10**9), "paid-low": ("paid", 1000),
             "legacy-high": (None, 10**9), "legacy-boundary": (None, 10**6),
             "paid-exhausted": ("paid", 1)}
    keys = {}
    run_id = uuid.uuid4().hex[:8]
    for name, (tier, quota) in cases.items():
        key = f"access-{run_id}-{name}"
        keys[name] = key
        variables = {"monthly_quota": str(quota), "seconds_quota": "0"}
        if tier is not None:
            variables["rpc_tier"] = tier
        admin("consumers/" + key, {"username": key, "plugins": {
            "key-auth": {"key": key}, "unifra-ctx-var": variables}})

    for name, policy, auth, legacy, network, config_path in [
        ("private", "consumer", True, True, "arc-testnet", None),
        ("strict", "consumer", True, False, "arc-testnet", None),
        ("public-auth", "free_only", True, True, "arc-testnet", None),
        ("public-high", "free_only", False, True, "arc-testnet", None),
        ("anonymous", "consumer", False, True, "arc-testnet", None),
        ("unknown", "free_only", False, True, "unknown", None),
        ("missing-config", "free_only", False, True, "arc-testnet", "/missing-whitelist.yaml"),
    ]:
        whitelist = {"method_policy": policy, "legacy_quota_fallback": legacy}
        if policy == "free_only":
            whitelist["bypass_networks"] = [network]
        if config_path:
            whitelist["config_path"] = config_path
        plugins = {"unifra-jsonrpc-var": {"network": network},
                   "unifra-whitelist": whitelist,
                   "unifra-ctx-var": {"monthly_quota": str(10**9), "rpc_tier": "paid"}}
        if auth:
            plugins.update({"key-auth": {}, "unifra-calculate-cu": {},
                            "unifra-limit-monthly-cu": {}})
        admin("routes/access-" + name, {"uri": "/" + name, "host": "access.test",
                                       "methods": ["POST"], "plugins": plugins, "upstream": UPSTREAM})
    for name, policy, auth, legacy in [
        ("public", "free_only", False, True),
        ("public-auth", "free_only", True, True),
        ("private", "consumer", True, True),
        ("strict", "consumer", True, False),
    ]:
        config = {"network": "arc-testnet", "method_policy": policy,
                  "legacy_quota_fallback": legacy, "enable_rate_limit": False}
        if policy == "free_only":
            config["bypass_networks"] = ["arc"]
        plugins = {"unifra-ws-jsonrpc-proxy": config,
                   "unifra-ctx-var": {"monthly_quota": str(10**9), "rpc_tier": "paid"}}
        if auth:
            plugins["key-auth"] = {}
        admin("routes/access-ws-" + name, {"uri": "/ws-" + name, "host": "access.test",
                "methods": ["GET"], "enable_websocket": True, "plugins": plugins, "upstream": UPSTREAM})
    # Allow etcd watches in the proxy workers to apply this setup.
    time.sleep(2)
    return keys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-dir", type=Path, required=True)
    args = parser.parse_args()
    keys = setup(args.config_dir)
    debug = rpc("debug_traceTransaction")
    mixed = [rpc(), rpc("debug_traceTransaction", 2)]
    denied = {"payload": debug, "error_code": -32003, "status": 405, "forwarded": 0}

    for host in ("dogeos-testnet-public.unifra.io", "arc-testnet-public.unifra.io",
                 "conflux-espace-public.unifra.io", "conflux-core-public.unifra.io"):
        method = "cfx_epochNumber" if "conflux-core" in host else "eth_blockNumber"
        forbidden = "trace_block" if "conflux" in host else "debug_traceTransaction"
        test(host + " basic", lambda: http_case(host=host, payload=rpc(method)))
        test(host + " restricted", lambda: http_case(host=host, payload=rpc(forbidden),
             error_code=-32003, status=405, forwarded=0))
    test("public trace", lambda: http_case(payload=rpc("trace_block"),
         error_code=-32003, status=405, forwarded=0))
    test("public unknown method", lambda: http_case(payload=rpc("admin_peers"),
         error_code=-32601, status=405, forwarded=0))
    test("public allowed batch", lambda: http_case(payload=[rpc(), rpc("eth_chainId", 2)], forwarded=2))
    test("public mixed batch", lambda: http_case(**(denied | {"payload": mixed})))
    test("public notification", lambda: http_case(**(denied | {"payload": {
         "jsonrpc": "2.0", "method": "debug_traceTransaction", "params": []}})))
    test("public wrong Content-Type", lambda: http_case(**denied, headers={"Content-Type": "text/plain"}))
    test("public gzip", lambda: http_case(**denied, compressed=True))
    test("public POST Upgrade cannot skip parsing", lambda: http_case(payload=debug,
         error_code=-32600, status=400, forwarded=0,
         headers={"Upgrade": "websocket", "Connection": "Upgrade"}))
    test("public ignores paid key", lambda: http_case(**denied, key=keys["paid-low"]))
    test("public header spoof", lambda: http_case(**denied, headers={"rpc_tier": "paid", "monthly_quota": "999999999"}))
    for path in ("public-high", "public-auth"):
        test(path + " cannot upgrade or bypass", lambda: http_case(path="/" + path,
             host="access.test", key=keys["paid-low"] if path == "public-auth" else None, **denied))
    test("anonymous route variables cannot grant paid", lambda: http_case(path="/anonymous", host="access.test", **denied))
    test("unknown network cannot bypass", lambda: http_case(path="/unknown", host="access.test",
         error_code=-32600, status=405, forwarded=0))
    test("missing whitelist fails closed", lambda: http_case(path="/missing-config", host="access.test",
         error_code=-32603, status=503, forwarded=0,
         error_message="Service temporarily unavailable"))
    for name in ("free-high", "legacy-boundary"):
        test(name + " denies paid HTTP", lambda: http_case(path="/private", host="access.test", key=keys[name], **denied))
    for name in ("paid-low", "legacy-high"):
        test(name + " allows paid HTTP", lambda: http_case(path="/private", host="access.test", key=keys[name], payload=debug))
    test("strict missing tier", lambda: http_case(path="/strict", host="access.test", key=keys["legacy-high"], **denied))
    test("strict explicit paid", lambda: http_case(path="/strict", host="access.test", key=keys["paid-low"], payload=debug))
    test("quota still independently enforced HTTP", lambda: http_case(path="/private", host="access.test",
         key=keys["paid-exhausted"], payload=debug, status=429, error_code=-32001, forwarded=0))

    def options():
        before = count()
        status, _ = request(PROXY + "/", "OPTIONS", headers={"Host": "arc-testnet-public.unifra.io",
                            "Origin": "https://example.test", "Access-Control-Request-Method": "POST"})
        assert status in (200, 204), status
        assert count() == before
    test("CORS preflight", options)

    def invalid_schema():
        status, _ = request(ADMIN + "consumers/access-invalid", "PUT", {"username": "access-invalid",
            "plugins": {"unifra-ctx-var": {"rpc_tier": "invalid"}}}, {"X-API-KEY": ADMIN_KEY})
        assert status == 400, status
        for plugin in ("unifra-whitelist", "unifra-ws-jsonrpc-proxy"):
            status, _ = request(ADMIN + "routes/access-invalid", "PUT", {"uri": "/invalid",
                "plugins": {plugin: {"method_policy": "invalid"}}}, {"X-API-KEY": ADMIN_KEY})
            assert status == 400, (plugin, status)
    test("invalid entitlement/policy rejected by schemas", invalid_schema)

    ws_denied = {"payload": debug, "error_code": -32003, "forwarded": 0}
    test("WS public basic", lambda: ws_case())
    test("WS public debug and bypass", lambda: ws_case(**ws_denied))
    test("WS public batch", lambda: ws_case(**(ws_denied | {"payload": mixed})))
    test("WS public binary debug", lambda: ws_case(**ws_denied, binary=True))
    test("WS public binary basic", lambda: ws_case(binary=True))
    test("WS public fragmented debug", lambda: ws_case(**ws_denied, fragmented=True))
    test("WS public authenticated paid", lambda: ws_case(path="/ws-public-auth", key=keys["paid-low"], **ws_denied))
    for name in ("free-high", "legacy-boundary"):
        test(name + " denies paid WS", lambda: ws_case(path="/ws-private", key=keys[name], **ws_denied))
    for name in ("paid-low", "legacy-high"):
        test(name + " allows paid WS", lambda: ws_case(path="/ws-private", key=keys[name], payload=debug))
    test("WS strict missing tier", lambda: ws_case(path="/ws-strict", key=keys["legacy-high"], **ws_denied))
    test("WS strict explicit paid", lambda: ws_case(path="/ws-strict", key=keys["paid-low"], payload=debug))
    test("quota still independently enforced WS", lambda: ws_case(path="/ws-private", key=keys["paid-exhausted"],
         payload=debug, error_code=-32001, forwarded=0))

    def persistent_ws():
        ws = WebSocket("/ws-public")
        try:
            for payload, code, forwarded in ((rpc(), None, 1), (debug, -32003, 0), (rpc(), None, 1)):
                before = count()
                check_response(None, ws.call(payload), before, forwarded, code)
        finally:
            ws.close()
    test("WS checks every message and survives denial", persistent_ws)

    def missing_ws_config():
        admin("plugin_metadata/unifra-ws-jsonrpc-proxy", {
            "redis_host": "redis", "whitelist_config_path": "/missing-whitelist.yaml"})
        time.sleep(1)
        try:
            ws_case(error_code=-32603, forwarded=0,
                    error_message="Service temporarily unavailable")
        finally:
            admin("plugin_metadata/unifra-ws-jsonrpc-proxy", {"redis_host": "redis"})
    test("WS missing whitelist fails closed", missing_ws_config)

    print(f"\n{passed} passed, {len(failed)} failed", flush=True)
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
