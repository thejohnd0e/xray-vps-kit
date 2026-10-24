#!/usr/bin/env python3
# Run inside the test namespace: python3 tests/helpers/e2e-fixtures.py CERT KEY TOKEN READY_FILE
"""Test-only network fixtures for the e2e suite.

* a TLS1.3 + h2 REALITY target (self-signed; the production installer never
  disables target verification, this certificate only exists in the fixture),
* deterministic HTTP origins: one reachable at 198.51.100.3 and several on
  addresses the server must refuse to proxy to (RFC1918, loopback, metadata).
"""
import http.server
import socket
import ssl
import sys
import threading

TARGET = ("198.18.0.2", 8444)
ORIGINS = {
    ("198.51.100.3", 8080): "origin",
    ("10.77.0.1", 8080): "private",
    ("127.0.0.1", 8081): "loopback",
    ("169.254.169.254", 8080): "metadata",
}


def serve_target(cert: str, key: str, ready: threading.Barrier) -> None:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.set_alpn_protocols(["h2"])
    context.load_cert_chain(cert, key)
    listener = socket.create_server(TARGET)
    ready.wait()
    while True:
        connection, _ = listener.accept()
        threading.Thread(target=handshake, args=(context, connection), daemon=True).start()


def handshake(context: ssl.SSLContext, connection: socket.socket) -> None:
    connection.settimeout(5)
    try:
        with context.wrap_socket(connection, server_side=True) as tls:
            tls.recv(1)
    except (OSError, ssl.SSLError):
        connection.close()


def serve_origin(address: tuple[str, int], label: str, token: str, ready: threading.Barrier) -> None:
    body = f"{label}-{token}\n".encode()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 - stdlib naming
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_: object) -> None:
            return

    server = http.server.ThreadingHTTPServer(address, Handler)
    ready.wait()
    server.serve_forever()


def main(cert: str, key: str, token: str, ready_file: str) -> int:
    ready = threading.Barrier(len(ORIGINS) + 2)
    threading.Thread(target=serve_target, args=(cert, key, ready), daemon=True).start()
    for address, label in ORIGINS.items():
        threading.Thread(target=serve_origin, args=(address, label, token, ready), daemon=True).start()
    ready.wait(timeout=10)
    with open(ready_file, "w", encoding="utf-8") as handle:
        handle.write("ready\n")
    threading.Event().wait()
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:5]))
