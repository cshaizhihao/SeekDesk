"""Local Xray VLESS/Hysteria2 + HTTP fixtures. No external network requests."""
import http.server
import json
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time

UUID = "00000000-0000-4000-8000-000000000001"
AUTH = "fixture-hysteria-auth"


class Origin(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.requests = []
        self.lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/stats":
            with self.server.lock:
                body = json.dumps(self.server.requests).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        with self.server.lock:
            self.server.requests.append({"path": self.path, "cookie": self.headers.get("Cookie", ""),
                                         "auth": self.headers.get("Authorization", ""),
                                         "proxy_auth": self.headers.get("Proxy-Authorization", "")})
        try:
            if self.path == "/slow":
                threading.Event().wait(6)
            if self.path == "/redirect":
                self.send_response(302)
                self.send_header("Location", "http://seekdesk-node-probe.invalid/redirect-target")
            elif self.path == "/wrong":
                self.send_response(200)
            else:
                self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
        except (BrokenPipeError, ConnectionResetError):
            pass


def random_port(udp=False):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start_core(core, config, tcp_port=None):
    child = subprocess.Popen([str(core), "run", "-format", "json", "-c", "stdin:"], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    child.stdin.write(json.dumps(config).encode())
    child.stdin.close()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise RuntimeError("Fixture Xray failed: " + child.stdout.read().decode())
        if tcp_port:
            try:
                with socket.create_connection(("127.0.0.1", tcp_port), timeout=.1):
                    return child
            except OSError:
                pass
        elif time.monotonic() > deadline - 2.7:
            return child
        time.sleep(.025)
    child.kill()
    child.wait()
    raise RuntimeError("Fixture Xray startup timeout")


def main():
    binary = pathlib.Path(sys.argv[1])
    core = pathlib.Path(sys.argv[2])
    origin = Origin()
    thread = threading.Thread(target=origin.serve_forever, daemon=True)
    thread.start()
    children = []
    try:
        with tempfile.TemporaryDirectory(prefix="seekdesk-node-probe-fixtures-") as temporary:
            folder = pathlib.Path(temporary)
            cert = folder / "fixture.pem"
            key = folder / "fixture.key"
            openssl_config = folder / "openssl.cnf"
            openssl_config.write_text("""[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=localhost
[extensions]
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
""")
            subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                            "-keyout", str(key), "-out", str(cert), "-config", str(openssl_config)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            vless_port = random_port()
            hy2_port = random_port(udp=True)
            # Xray's server-side freedom blocks private targets by default; permit only this fixture's origin.
            outbound = {"protocol": "freedom", "settings": {"redirect": "127.0.0.1:%d" % origin.server_port,
                        "finalRules": [{"action": "allow", "ip": ["127.0.0.1"], "port": origin.server_port}]}}
            config = {"log": {"loglevel": "none"}, "inbounds": [{"listen": "127.0.0.1", "port": vless_port,
                       "protocol": "vless", "settings": {"clients": [{"id": UUID}], "decryption": "none"}}], "outbounds": [outbound]}
            children.append(start_core(core, config, vless_port))
            hy2 = {"log": {"loglevel": "none"}, "inbounds": [{"listen": "127.0.0.1", "port": hy2_port,
                   "protocol": "hysteria", "settings": {"version": 2, "users": [{"auth": AUTH}]},
                   "streamSettings": {"network": "hysteria", "security": "tls", "hysteriaSettings": {"version": 2},
                    "tlsSettings": {"alpn": ["h3"], "certificates": [{"certificateFile": str(cert), "keyFile": str(key)}]}}}],
                   "outbounds": [outbound]}
            children.append(start_core(core, hy2))
            # Keep an unused TCP port bound so a closed-node fixture cannot be claimed by another listener.
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as closed:
                closed.bind(("127.0.0.1", 0))
                result = subprocess.run([str(binary), str(core), str(vless_port), str(hy2_port), str(origin.server_port),
                                         str(cert), str(closed.getsockname()[1])], timeout=65)
                if result.returncode:
                    raise SystemExit(result.returncode)
            with origin.lock:
                assert not any(r["cookie"] or r["auth"] or r["proxy_auth"] for r in origin.requests)
                assert not any(r["path"] == "/redirect-target" for r in origin.requests)
            print("Passed origin verification: no cookies or credentials and no followed redirects.", flush=True)
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            if sys.exc_info()[0]:
                print(child.stdout.read().decode(), flush=True)
        origin.shutdown()
        origin.server_close()
        thread.join(timeout=2)


if __name__ == "__main__":
    main()
