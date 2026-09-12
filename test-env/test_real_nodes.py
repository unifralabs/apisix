"""Opt-in low-volume local-gateway / real-node acceptance, no node writes.

Run with docker-compose.real-nodes.yml, NEVER with production Admin/Redis.
Uses actual nomad-config upstream IPs; config/Consumers/ledger are local only.
No broadcasts, admin calls, load tests, or unbounded historical scans.
"""
import argparse
import json
import time
from pathlib import Path

import test_access as t
import test_billing_e2e as b

A = "0x" + "00" * 18 + "dead"
TX = {"to": A, "gas": "0x186a0"}
CHAINS = {"dogeos-testnet": (600, 6281971), "arc-testnet": (650, 5042002)}


def rpc(method, params=None, rid=1):
    return {"jsonrpc": "2.0", "id": rid, "method": method, "params": params or []}


def setup(config_dir, network, upstream_id):
    b.setup()
    # No telemetry is sent to a production broker from this egress-enabled stack.
    t.admin("plugin_metadata/unifra-ws-jsonrpc-proxy", {"redis_host": "redis",
        "kafka_brokers": [{"host": "127.0.0.1", "port": 9092}]})
    for transport, offset in (("http", 0), ("ws", 1)):
        filename = f"{upstream_id + offset}-{network}" + ("-ws" if offset else "") + ".json"
        source = json.loads((config_dir / "upstream" / filename).read_text())
        # Do not import production health probes: this test sends bounded traffic only.
        upstream = {"type": source["type"], "nodes": source["nodes"],
                    "scheme": source["scheme"], "timeout": source["timeout"]}
        print("UPSTREAM", network, transport, source["nodes"], flush=True)
        for public in (False, True):
            route_id = "real-" + transport + ("-public" if public else "")
            plugins = {} if public else {"key-auth": {}}
            policy = {"method_policy": "free_only"} if public else {}
            if transport == "http":
                plugins.update({"unifra-jsonrpc-var": {"network": network},
                                "unifra-whitelist": policy, "unifra-calculate-cu": {}})
                if not public:
                    plugins.update({"unifra-limit-cu": {"allow_degradation": False},
                                    "unifra-limit-monthly-cu": {}})
            else:
                plugins["unifra-ws-jsonrpc-proxy"] = {"network": network, **policy,
                    "enable_rate_limit": not public, "allow_degradation": False}
            t.admin("routes/" + route_id, {"uri": "/" + route_id, "host": "access.test",
                    "enable_websocket": transport == "ws", "upstream": upstream, "plugins": plugins})
    time.sleep(1)


class Client:
    def __init__(self, transport, tier="paid", public=False, **quota):
        self.account = None if public else b.Account(tier, **quota)
        self.path = "/real-" + transport + ("-public" if public else "")
        self.key = self.account.key if self.account else None
        self.ws = t.WebSocket(self.path, self.key) if transport == "ws" else None

    def call(self, payload, cost=None, error=None):
        time.sleep(.15)  # sequential low-volume testing, not a load test
        before = self.account.used() if self.account else None
        if self.ws:
            result = self.ws.call(payload)
        else:
            result = t.request(t.PROXY + self.path, "POST", payload,
                {"Host": "access.test", "Content-Type": "application/json",
                 **({"apikey": self.key} if self.key else {})})[1]
        if error is None:
            b.success(result)
        else:
            assert b.code(result) == error, result
        if before is not None and cost is not None:
            assert self.account.used() - before == cost, ("CU", self.account.used() - before, cost)
        return result

    def close(self):
        if self.ws:
            self.ws.close()


def check(client, name, payload, cost, error=None):
    b.run(name, lambda: client.call(payload, cost, error))


def smoke(network, transport, chain_id):
    paid, free, public = Client(transport), Client(transport, "free"), Client(transport, public=True)
    prefix = network + "/" + transport
    try:
        def identity():
            for client in (paid, free, public):
                result = client.call(rpc("eth_chainId"), 1)
                assert int(result["result"], 16) == chain_id, result
        b.run(prefix + "/real chain identity all tiers", identity)
        number = paid.call(rpc("eth_blockNumber"), 1)["result"]
        print("SNAPSHOT", network, transport, number, flush=True)
        for method, params, cost in [
            ("eth_call", [TX, number], 5),
            ("eth_createAccessList", [TX, number], 10),
            ("eth_getLogs", [{"fromBlock": number, "toBlock": number, "address": A}], 10),
            ("eth_feeHistory", ["0x1", number, []], 3),
        ]:
            check(free, prefix + "/free " + method, rpc(method, params), cost)
        for method, params, cost in [
            ("trace_call", [TX, ["trace"], number], 25),
            ("trace_callMany", [[[TX, ["trace"]], [TX, ["trace"]]], number], 60),
            ("debug_traceCall", [TX, number], 30),
            ("debug_traceCallMany", [[{"transactions": [TX]}], {"blockNumber": number}], 30),
            ("eth_callMany", [[{"transactions": [TX, TX]}], {"blockNumber": number}], 20),
            ("eth_simulateV1", [{"blockStateCalls": [{"calls": [TX]}]}, number], 50),
            ("eth_getStorageValues", [{A: ["0x0", "0x1"]}, number], 4),
            # Proof retention is node-dependent; avoid aging the snapshot during the suite.
            ("eth_getProof", [A, ["0x0"], "latest"], 20),
        ]:
            check(paid, prefix + "/paid " + method, rpc(method, params), cost)
            check(free, prefix + "/free denies " + method, rpc(method, params), 0, -32003)
        for method in ("debug_foo", "eth_sendTransaction", "admin_addPeer"):
            # Deliberately no executable payload; these must be rejected by gateway.
            check(paid, prefix + "/unknown or management " + method, rpc(method), 0, -32601)
        check(public, prefix + "/public denies trace", rpc("trace_call", [TX, ["trace"], number]), 0, -32003)
        check(paid, prefix + "/reject excessive range", rpc("eth_getLogs", [{"fromBlock": "0x1", "toBlock": "0x1000"}]), 0, -32602)
        check(paid, prefix + "/reject JS tracer", rpc("debug_traceCall", [TX, number, {"tracer": "javascript"}]), 0, -32602)
        check(free, prefix + "/atomic denied mixed batch", [rpc("eth_chainId"), rpc("trace_call", [TX, ["trace"], number], 2)], 0, -32003)
        check(paid, prefix + "/successful mixed batch", [rpc("eth_chainId"), rpc("eth_call", [TX, number], 2)], 6)

        if transport == "http":
            def filters():
                fid = free.call(rpc("eth_newBlockFilter"), 2)["result"]
                try:
                    paid.call(rpc("eth_getFilterChanges", [fid]), 0, -32602)
                    free.call(rpc("eth_getFilterChanges", [fid]), 2)
                finally:
                    removed = free.call(rpc("eth_uninstallFilter", [fid]), 1)
                    assert removed["result"] is True, removed
            b.run(prefix + "/real filter ownership and cleanup", filters)
        else:
            def subscription():
                # Real nodes push independently of replies; do not mistake a push
                # for the unsubscribe response (the basic mock helper is single-frame).
                client = Client("ws", "free")
                pushes = []
                def receive_reply(rid):
                    while True:
                        opcode, data = t.read_frame(client.ws.stream)
                        if opcode == 9:
                            client.ws.sock.sendall(t.frame(data, 10, masked=True))
                            continue
                        assert opcode == 1, (opcode, data)
                        response = json.loads(data)
                        if response.get("method") == "eth_subscription":
                            pushes.append(response)
                            continue
                        assert response.get("id") == rid, response
                        b.success(response)
                        return response["result"]
                def send(method, params, rid):
                    client.ws.sock.sendall(t.frame(json.dumps(rpc(method, params, rid)).encode(), masked=True))
                try:
                    send("eth_subscribe", ["newHeads"], 1001)
                    sid = receive_reply(1001)
                    # Allow a few heads, but never a high-frequency pending stream.
                    time.sleep(3)
                    send("eth_unsubscribe", [sid], 1002)
                    assert receive_reply(1002) is True
                    assert all(p["params"]["subscription"] == sid for p in pushes)
                    assert pushes, "no real newHeads event in the observation window"
                    assert client.account.used() == 2 + 5 * len(pushes), (client.account.used(), len(pushes))
                    print("PUSHES", network, len(pushes), "monthly CU", client.account.used(), flush=True)
                finally:
                    client.close()  # also removes subscriptions if an assertion failed
            b.run(prefix + "/real subscribe and unsubscribe", subscription)

        # Block tracing is only attempted after checking the actual block is tiny.
        small = None
        for height in range(int(number, 16), max(0, int(number, 16) - 8), -1):
            block = paid.call(rpc("eth_getBlockByNumber", [hex(height), False]), 3)["result"]
            if block and int(block["gasUsed"], 16) <= 500000 and len(block["transactions"]) <= 4:
                small = block
                break
        if small:
            print("SAFE_BLOCK", network, small["number"], small["gasUsed"], len(small["transactions"]), flush=True)
            for method, params, cost in [
                ("trace_block", [small["number"]], 50),
                ("trace_replayBlockTransactions", [small["number"], ["trace"]], 50),
                ("debug_traceBlockByNumber", [small["number"]], 50),
                ("debug_traceBlockByHash", [small["hash"]], 50),
                ("trace_filter", [{"fromBlock": small["number"], "toBlock": small["number"], "count": 1}], 50),
            ]:
                check(paid, prefix + "/small block " + method, rpc(method, params), cost)
        else:
            print("SKIP", prefix, "block tracing: no small block in 8-block window", flush=True)
        if network == "arc-testnet":
            # Previously audited transaction; recheck its gas before any tracing.
            tx_hash = "0x88d29c81da005acbbcff3f8b3dcf5d1c1d1ff286ecbd6dc1beaa5e765fe7ed67"
            tx = paid.call(rpc("eth_getTransactionByHash", [tx_hash]), 3)["result"]
            if tx and int(tx["gas"], 16) <= 100000:
                for method, params, cost in [
                    ("trace_transaction", [tx_hash], 25),
                    ("trace_get", [tx_hash, []], 25),
                    ("trace_replayTransaction", [tx_hash, ["trace"]], 25),
                    ("debug_traceTransaction", [tx_hash], 30),
                ]:
                    check(paid, prefix + "/bounded real transaction " + method, rpc(method, params), cost)
            else:
                print("SKIP", prefix, "transaction tracing: audited low-gas transaction unavailable", flush=True)
        # Zero means unlimited in the existing quota contract. Exceed a positive cap.
        for limit, expected in (({"monthly": 1}, -32001), ({"seconds": 1}, -32000)):
            limited = Client(transport, **limit)
            try:
                check(limited, prefix + "/local ledger limit " + str(limit),
                      [rpc("eth_chainId"), rpc("eth_chainId", rid=2)], 0, expected)
            finally:
                limited.close()
    finally:
        for client in (paid, free, public):
            client.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-dir", type=Path, required=True)
    parser.add_argument("--allow-real-nodes", action="store_true", required=True)
    args = parser.parse_args()
    for network, (upstream_id, chain_id) in CHAINS.items():
        setup(args.config_dir, network, upstream_id)
        for transport in ("http", "ws"):
            smoke(network, transport, chain_id)
    print(f"\n{b.PASSED} passed; {len(b.FAILED)} failed", flush=True)
    raise SystemExit(bool(b.FAILED))
