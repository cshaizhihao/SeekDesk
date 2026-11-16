"""Loopback-only integration checks; never contact a real proxy node or forum."""
import base64
import pathlib
import socketserver
import subprocess
import tempfile
import threading


def headers(stream):
    first = stream.readline(65536)
    values = {}
    while True:
        line = stream.readline(65536)
        if line in (b"\r\n", b"\n", b""):
            break
        key, _, value = line.partition(b":")
        values[key.strip().lower()] = value.strip()
    return first, values


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(8)
        first, values = headers(self.rfile)
        if not first:
            return
        marker = b"direct-origin"
        if self.server.is_proxy:
            auth = b"Basic " + base64.b64encode(b"fixture-user:fixture-password")
            if values.get(b"proxy-authorization") != auth:
                self.wfile.write(b'HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="fixture"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                return
            if first.startswith(b"CONNECT "):
                self.wfile.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                self.wfile.flush()
                first, values = headers(self.rfile)
            marker = b"via-proxy"
        length = int(values.get(b"content-length", b"0"))
        if length:
            self.rfile.read(length)
        body = b"<html><body>" + marker + b"</body></html>"
        self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)


root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="seekdesk-proxy-tests-") as output:
    binary = str(pathlib.Path(output) / "ProxyNetworkChecks")
    subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(root / ".build/module-cache"),
                    str(root / "Sources/SeekDesk/DeskProxyNetwork.swift"),
                    str(root / "Tests/Regression/ProxyNetworkChecks.swift"), "-o", binary], check=True)
    servers = []
    try:
        for proxy in (True, False):
            server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
            server.daemon_threads = True
            server.is_proxy = proxy
            threading.Thread(target=server.serve_forever, daemon=True).start()
            servers.append(server)
        subprocess.run([binary] + [str(s.server_address[1]) for s in servers], check=True, timeout=45)
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()
