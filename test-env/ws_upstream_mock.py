"""Host-sensitive WS/WSS upstream, restricted to the internal test network."""
import ssl
import threading
from http.server import ThreadingHTTPServer
from access_mock import Handler
import json


class Upstream(Handler):
    handshakes = []

    def do_GET(self):
        if self.path == "/handshakes":
            with self.lock:
                self.reply(json.dumps(self.handshakes).encode())
            return
        if self.headers.get("Upgrade", "").lower() == "websocket":
            record = {"path": self.path, "host": self.headers.get("Host"),
                      "sni": getattr(self.connection, "test_sni", None),
                      "apikey": self.headers.get("apikey")}
            with self.lock:
                self.handshakes.append(record)
            if self.path == "/reject-404":
                self.send_error(404)
                return
            if self.path == "/bad-accept":
                self.send_response(101)
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", "incorrect")
                self.end_headers()
                self.close_connection = True
                return
            if self.path == "/arc/test-provider-key":
                if record["host"] != "provider.test:8546" or record["sni"] != "provider.test":
                    self.send_error(404)
                    return
            elif self.path == "/rewrite":
                if record["host"] != "rewrite.test:8546" or record["sni"] != "rewrite.test":
                    self.send_error(404)
                    return
        super().do_GET()


if __name__ == "__main__":
    plain = ThreadingHTTPServer(("0.0.0.0", 8545), Upstream)
    tls = ThreadingHTTPServer(("0.0.0.0", 8546), Upstream)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain("/certs/server.crt", "/certs/server.key")
    context.set_servername_callback(lambda sock, name, _: setattr(sock, "test_sni", name))
    tls.socket = context.wrap_socket(tls.socket, server_side=True)
    threading.Thread(target=plain.serve_forever, daemon=True).start()
    tls.serve_forever()
