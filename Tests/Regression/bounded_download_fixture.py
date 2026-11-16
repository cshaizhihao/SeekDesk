"""Loopback-only oversized image transport; never contacts an external service."""
import http.server
import json
import subprocess
import sys
import threading
import urllib.parse

LIMIT = 256 * 1024
BLOCK = b"i" * (16 * 1024)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.lock = threading.Lock()
        self.records = {}

    def handle_error(self, request, client_address):
        # Overflow/cancellation closes a keep-alive connection while the
        # handler waits for its next request. This is an expected outcome.
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError, ConnectionAbortedError)):
            return
        super().handle_error(request, client_address)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/stats":
            with self.server.lock:
                data = json.dumps(self.server.records).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        with self.server.lock:
            previous = self.server.records.get(path, {}).get("requests", 0)
            self.server.records[path] = {
                "requests": previous + 1,
                "sent": 0,
                "cookie": int(bool(self.headers.get("Cookie"))),
                "authorization": int(bool(self.headers.get("Authorization"))),
            }
        try:
            if path.startswith("/redirect") or path == "/cookie-redirect":
                target = "/small"
                if path == "/redirect-credentials":
                    target = f"http://fixture:password@127.0.0.1:{self.server.server_port}/credential-target"
                if path == "/redirect-file":
                    target = "file:///tmp/must-not-be-opened"
                self.send_response(302)
                self.send_header("Location", target)
                self.send_header("Content-Length", "0")
                if path == "/cookie-redirect":
                    self.send_header("Set-Cookie", "fixture-session=must-not-send; Path=/")
                self.end_headers()
                return

            large = path.startswith("/oversize") or path == "/parallel-large"
            slow = path.startswith("/slow")
            length = LIMIT * 32 if large else LIMIT if path == "/exact" else 128
            chunked = path == "/oversize-chunked"
            unknown = path == "/oversize-stream"
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Cache-Control", "no-store")
            if chunked:
                self.send_header("Transfer-Encoding", "chunked")
            elif not unknown:
                self.send_header("Content-Length", str(length))
            else:
                self.send_header("Connection", "close")
                self.close_connection = True
            if path == "/cookie-set":
                self.send_header("Set-Cookie", "fixture-session=must-not-send; Path=/")
            self.end_headers()
            sent = 0
            while sent < length:
                block = BLOCK[: min(len(BLOCK), length - sent)]
                if slow and sent == 0:
                    block = block[:1]
                self.wfile.write((f"{len(block):x}\r\n".encode() + block + b"\r\n") if chunked else block)
                self.wfile.flush()
                sent += len(block)
                with self.server.lock:
                    self.server.records[path]["sent"] = sent
                if large:
                    threading.Event().wait(0.01)
                if slow and sent == 1:
                    threading.Event().wait(3)
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


if __name__ == "__main__":
    server = Server()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run([sys.argv[1], str(server.server_port)], check=True, timeout=45)
    finally:
        server.shutdown()
        server.server_close()
