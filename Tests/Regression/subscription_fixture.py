"""Loopback-only HTTP subscription integration fixtures; no external destinations."""
import base64
import http.server
import json
import subprocess
import sys
import threading
import urllib.parse


LIMIT = 2 * 1024 * 1024
PLAIN = ("trojan://fixture-password@example.invalid:443?security=tls#Fixture\n"
         "socks5://fixture:password@other.example.invalid:1080#Fixture-SOCKS\n").encode()
YAML = b"""proxies:
  - {name: Fixture, type: trojan, server: example.invalid, port: 443, password: fixture-password}
  - {name: Fixture-SOCKS, type: socks5, server: other.example.invalid, port: 1080, username: fixture, password: password}
"""
SECRET = b"fixture-sensitive-response-never-display"


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.records = []
        self.records_lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):
        pass

    def reply(self, body, status=200, headers=None, length=True):
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        if length:
            self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/stats":
            with self.server.records_lock:
                data = json.dumps(self.server.records).encode()
            self.reply(data)
            return
        with self.server.records_lock:
            self.server.records.append({
                "path": path,
                "cookie": self.headers.get("Cookie", ""),
                "authorization": self.headers.get("Authorization", ""),
                "agent": self.headers.get("User-Agent", ""),
            })
        try:
            if path in ("/plain", "/cookie-check"):
                self.reply(PLAIN)
            elif path == "/base64":
                self.reply(base64.b64encode(PLAIN))
            elif path == "/yaml":
                self.reply(YAML)
            elif path == "/cookie-set":
                self.reply(PLAIN, headers={"Set-Cookie": "fixture-session=must-not-be-sent; Path=/"})
            elif path == "/cookie-redirect":
                self.reply(b"", 302, {"Location": "/cookie-check", "Set-Cookie": "fixture-session=must-not-be-sent; Path=/"})
            elif path == "/redirect":
                self.reply(b"", 302, {"Location": "/plain"})
            elif path == "/redirect-credentials":
                self.reply(b"", 302, {"Location": "http://fixture-user:fixture-password@127.0.0.1:%d/plain" % self.server.server_port})
            elif path == "/http-error":
                self.reply(SECRET, 403)
            elif path == "/html-error":
                self.reply(b"<html><body>" + SECRET + b"</body></html>")
            elif path == "/oversize-length":
                self.reply(b"A" * (LIMIT + 1))
            elif path == "/oversize-stream":
                self.reply(b"", length=False)
                block = b"A" * 65536
                for _ in range(LIMIT // len(block)):
                    self.wfile.write(block)
                self.wfile.write(b"A")
            elif path == "/slow":
                self.send_response(200)
                self.send_header("Content-Length", str(len(PLAIN)))
                self.end_headers()
                self.wfile.write(PLAIN[:1])
                self.wfile.flush()
                threading.Event().wait(3)
                self.wfile.write(PLAIN[1:])
            else:
                self.reply(b"missing fixture", 404)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            # Expected when the client cancels or rejects an oversized response.
            pass


def main():
    server = Server()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        result = subprocess.run([sys.argv[1], str(server.server_port)], timeout=60)
        if result.returncode:
            raise SystemExit(result.returncode)
        with server.records_lock:
            assert all(not item["cookie"] and not item["authorization"] for item in server.records)
        print("Passed loopback server verification: no Cookie or Authorization header received.", flush=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


if __name__ == "__main__":
    main()
