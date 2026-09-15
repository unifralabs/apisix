"""Real gateway E2E: real Arc route/service, test credentials, local WS/WSS only."""
import argparse
import base64
import copy
import json
import socket
import time
from pathlib import Path
from urllib.error import URLError

import test_access as t

HOST = "arc-mainnet.unifra.io"
KEY = "ws-upstream-local-test-key"


def records():
    return t.request("http://mock-rpc:8545/handshakes")[1]


def setup(config_dir):
    for _ in range(60):
        try:
            if t.request(t.ADMIN + "routes", headers={"X-API-KEY": t.ADMIN_KEY})[0] == 200:
                break
        except (URLError, ConnectionError):
            pass
        time.sleep(0.5)
    else:
        raise RuntimeError("Local gateway not ready")
    service = json.loads((config_dir / "service/3-ws-plugins-prod.json").read_text())
    t.admin("services/3", service)
    t.admin("plugin_metadata/unifra-ws-jsonrpc-proxy", {
        "redis_host": "redis", "redis_port": 6379,
        "kafka_brokers": [{"host": "127.0.0.1", "port": 9092}]})
    t.admin("consumers/" + KEY, {"username": KEY, "plugins": {
        "key-auth": {"key": KEY},
        "unifra-ctx-var": {"rpc_tier": "paid", "seconds_quota": "100000",
                           "monthly_quota": "1000000", "quota_key": KEY}}})
    # Keep the production shape, never the production node or provider key.
    upstream = json.loads((config_dir / "upstream/663-arc-mainnet-drpc-ws.json").read_text())
    upstream["nodes"] = [{"host": "provider.test", "port": 8546, "weight": 1}]
    t.admin("upstreams/663", upstream)
    local_upstream = copy.deepcopy(upstream)
    local_upstream.update(scheme="http", pass_host="pass",
                          nodes=[{"host": "mock-rpc", "port": 8545, "weight": 1}])
    t.admin("upstreams/661", local_upstream)
    rewrite = copy.deepcopy(upstream)
    rewrite.update(pass_host="rewrite", upstream_host="rewrite.test:8546")
    t.admin("upstreams/ws-rewrite", rewrite)
    route = json.loads((config_dir / "route/6602-arc-mainnet-ws.json").read_text())
    route.update(upstream_id="663", service_id="3")
    route["plugins"]["proxy-rewrite"] = {"uri": "/arc/test-provider-key"}
    t.admin("routes/6602", route)
    time.sleep(1)
    return route


def configure(route, upstream="663", path="/arc/test-provider-key"):
    route["upstream_id"] = upstream
    if path is None:
        route["plugins"].pop("proxy-rewrite", None)
    else:
        route["plugins"]["proxy-rewrite"] = {"uri": path}
    t.admin("routes/6602", route)
    time.sleep(0.4)


def exchange(route, upstream="663", path="/arc/test-provider-key", host="provider.test:8546", sni="provider.test"):
    configure(route, upstream, path)
    ws = t.WebSocket("/ws/" + KEY, host=HOST)
    try:
        for method, ident in (("eth_chainId", "client-chain-id"), ("eth_blockNumber", 9876)):
            response = ws.call(t.rpc(method, ident))
            assert response == {"jsonrpc": "2.0", "id": ident, "result": "mock:" + method}, response
        batch = ws.call([t.rpc("eth_chainId", "batch-a"), t.rpc("eth_blockNumber", 100)])
        assert [r["id"] for r in batch] == ["batch-a", 100], batch
        last = records()[-1]
        assert last == {"path": path or "/", "host": host, "sni": sni, "apikey": None}, last
    finally:
        ws.close()


def handshake_status(key=KEY):
    with socket.create_connection(("apisix", 9080), timeout=10) as sock:
        nonce = base64.b64encode(b"local-ws-test-16").decode()
        sock.sendall((f"GET /ws/{key} HTTP/1.1\r\nHost: {HOST}\r\nUpgrade: websocket\r\n"
                      f"Connection: Upgrade\r\nSec-WebSocket-Key: {nonce}\r\n"
                      "Sec-WebSocket-Version: 13\r\n\r\n").encode())
        with sock.makefile("rb") as stream:
            return int(stream.readline().split()[1])


def rejected(route, path):
    configure(route, path=path)
    status = handshake_status()
    assert status == 502, status
    assert records()[-1]["path"] == path


def auth_rejected(route):
    configure(route)
    before = len(records())
    status = handshake_status("invalid-local-key")
    assert status in (401, 403), status
    assert len(records()) == before, "Unauthorized request reached the provider"


def real_drpc(route, config_dir):
    # Explicit opt-in only. Read the provider key at runtime; never print it.
    upstream = json.loads((config_dir / "upstream/663-arc-mainnet-drpc-ws.json").read_text())
    assert upstream["nodes"][0]["host"] == "lb.drpc.live"
    assert upstream["scheme"] == "https" and upstream["pass_host"] == "node"
    path = json.loads((config_dir / "arc-switch.json").read_text())["drpc_path"]
    assert path.startswith("/arc/") and len(path) > 10
    t.admin("upstreams/663", upstream)
    configure(route, path=path)
    ws = t.WebSocket("/ws/" + KEY, host=HOST)
    try:
        print("Local APISIX -> real dRPC: WebSocket 101", flush=True)
        for method, ident in (("eth_chainId", "live-chain"), ("eth_blockNumber", "live-block")):
            response = ws.call(t.rpc(method, ident))
            assert response.get("id") == ident and "result" in response, response
            print(method, json.dumps(response), flush=True)
    finally:
        ws.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-dir", type=Path, required=True)
    parser.add_argument("--real-drpc", action="store_true", help="opt into two read-only real provider calls")
    args = parser.parse_args()
    route = setup(args.config_dir)
    if args.real_drpc:
        real_drpc(route, args.config_dir)
        return
    t.test("WSS node Host + verified TLS SNI + path + RPC and batch ID restoration", lambda: exchange(route))
    t.test("upstream HTTP 404 returns 502 before client upgrade", lambda: rejected(route, "/reject-404"))
    t.test("invalid Sec-WebSocket-Accept returns 502 before client upgrade", lambda: rejected(route, "/bad-accept"))
    t.test("WSS rewrite Host and SNI", lambda: exchange(route, "ws-rewrite", "/rewrite", "rewrite.test:8546", "rewrite.test"))
    t.test("switch back to plaintext WS and inherited / path", lambda: exchange(route, "661", None, HOST, None))
    t.test("switch again to WSS", lambda: exchange(route))
    t.test("invalid client key rejected before upstream connection", lambda: auth_rejected(route))
    print(f"{t.passed} passed; {len(t.failed)} failed", flush=True)
    if t.failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
