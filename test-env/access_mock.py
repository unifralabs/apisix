"""Dependency-free HTTP/WS mock with a counter proving blocked RPCs never arrive."""
import base64
import gzip
import hashlib
import json
import struct
import threading
import uuid
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def read_exact(stream, size):
    result = b""
    while len(result) < size:
        chunk = stream.read(size - len(result))
        if not chunk:
            raise EOFError("WebSocket closed")
        result += chunk
    return result


def read_frame(stream):
    first, second = read_exact(stream, 2)
    size = second & 127
    if size == 126:
        size = struct.unpack("!H", read_exact(stream, 2))[0]
    elif size == 127:
        size = struct.unpack("!Q", read_exact(stream, 8))[0]
    mask = read_exact(stream, 4) if second & 128 else None
    payload = read_exact(stream, size)
    if mask:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return first & 15, payload


def frame(payload, opcode=1, masked=False, final=True):
    size = len(payload)
    header = bytes([(128 if final else 0) | opcode])
    flag = 128 if masked else 0
    if size < 126:
        header += bytes([flag | size])
    elif size < 65536:
        header += bytes([flag | 126]) + struct.pack("!H", size)
    else:
        header += bytes([flag | 127]) + struct.pack("!Q", size)
    if masked:
        mask = b"test"
        header += mask
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return header + payload


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    calls = []
    lock = threading.Lock()
    subscriptions = {}
    filters = {}
    requests = []

    def setup(self):
        super().setup()
        self.send_lock = threading.Lock()

    def send_frame(self, payload, opcode=1):
        with self.send_lock:
            self.wfile.write(frame(payload, opcode))

    def rpc(self, body):
        request = json.loads(body)
        batch = isinstance(request, list)
        requests = request if batch else [request]
        with self.lock:
            self.calls.extend(r.get("method") for r in requests if isinstance(r, dict))
            self.requests.extend(requests)
        replies = []
        for r in requests:
            if not isinstance(r, dict) or "id" not in r:
                continue
            response = {"jsonrpc": "2.0", "id": r["id"], "result": "mock:" + r["method"]}
            first = r.get("params", [None])[0] if r.get("params") else None
            if isinstance(first, dict):
                time.sleep(min(3, first.get("mock_delay", 0)))
                if first.get("mock_size"):
                    response["result"] = "x" * min(2200000, first["mock_size"])
            if r["method"] in ("eth_newFilter", "eth_newBlockFilter", "eth_newPendingTransactionFilter"):
                filter_id = "0x" + uuid.uuid4().hex
                self.filters[filter_id] = True
                response["result"] = filter_id
            elif r["method"] in ("eth_getFilterChanges", "eth_getFilterLogs", "eth_uninstallFilter"):
                if first not in self.filters:
                    response.pop("result")
                    response["error"] = {"code": -32602, "message": "filter not found"}
                elif r["method"] == "eth_uninstallFilter":
                    response["result"] = self.filters.pop(first)
                else:
                    response["result"] = []
            if r["method"].endswith("_subscribe"):
                subscription = "0x" + uuid.uuid4().hex
                with self.lock:
                    self.subscriptions[subscription] = self
                response["result"] = subscription
            elif r["method"].endswith("_unsubscribe"):
                with self.lock:
                    response["result"] = self.subscriptions.pop(r["params"][0], None) is not None
            elif r.get("params") and isinstance(r["params"][0], dict) and r["params"][0].get("mock_error"):
                response.pop("result")
                response["error"] = {"code": -32010, "message": "mock upstream execution error"}
            replies.append(response)
        return json.dumps(replies if batch else replies[0]).encode() if replies else b""

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.headers.get("Content-Encoding") in ("gzip", "x-gzip"):
            body = gzip.decompress(body)
        if self.path == "/push":
            push = json.loads(body)
            with self.lock:
                owner = self.subscriptions.get(push["subscription"])
            if owner:
                message = {"jsonrpc": "2.0", "method": "eth_subscription", "params": {
                    "subscription": push["subscription"], "result": push.get("result", {})}}
                owner.send_frame(json.dumps(message).encode(), 2 if push.get("binary") else 1)
            self.reply(json.dumps({"sent": owner is not None}).encode())
            return
        self.reply(self.rpc(body))

    def reply(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/requests":
            with self.lock:
                self.reply(json.dumps(self.requests).encode())
            return
        if self.path == "/calls":
            with self.lock:
                self.reply(json.dumps(self.calls).encode())
            return
        if self.headers.get("Upgrade", "").lower() != "websocket":
            self.send_error(404)
            return
        key = self.headers["Sec-WebSocket-Key"]
        accept = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        try:
            while True:
                opcode, payload = read_frame(self.rfile)
                if opcode == 8:
                    self.send_frame(b"", 8)
                    break
                if opcode == 9:
                    self.send_frame(payload, 10)
                elif opcode == 1:
                    response = self.rpc(payload)
                    if response:
                        self.send_frame(response)
        except (EOFError, ConnectionError):
            pass
        with self.lock:
            for subscription, owner in list(self.subscriptions.items()):
                if owner is self:
                    del self.subscriptions[subscription]
        self.close_connection = True

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8545), Handler).serve_forever()
