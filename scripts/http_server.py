"""A small HTTP/1.1 test server for mojoui.http (goal 33 M1): the replies tests/test_http.mojo and examples/httpcheck ask for.

    pixi run python scripts/http_server.py [port]      # serves until Ctrl+C; prints its URL
    with TestServer() as srv: srv.url ...              # (scripts/check.py M1)

Routes: GET /json, POST /echo (the JSON body back, with the method and content type), GET /header?name=N (that request
header's value), GET /chunked (Transfer-Encoding: chunked, four chunks), GET /big (1 MiB, Content-Length), GET
/slow?ms=N (answers after N ms), GET /fail (a 500). Every request is kept in `seen` (method, path, headers, body).
"""

import json
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

JSON_REPLY = {"hello": "world", "n": 42, "pi": 3.25, "list": [1, -2, None, True]}
CHUNKS = [b"alpha-", b"beta-", b"gam", b"ma \xc3\xa9"]  # (the last one splits nothing, but carries UTF-8)
BIG_SIZE = 1 << 20


def big_body():
    """1 MiB of printable text, the same every time (the test reports its FNV-1a hash)."""
    line = bytes(range(33, 127))  # 94 printable bytes
    out = bytearray()
    k = 0
    while len(out) < BIG_SIZE:
        out += line[k % 94:] + line[:k % 94] + b"\n"
        k += 7
    return bytes(out[:BIG_SIZE])


def fnv1a(data):
    h = 0xcbf29ce484222325
    for b in data:
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"


BIG = big_body()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def keep(self, body=b""):
        self.server.seen.append({"method": self.command, "path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()},
                                 "body": body, "at": time.monotonic()})

    def reply(self, status, body, ctype="text/plain; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.keep()
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if url.path == "/json":
            self.reply(200, json.dumps(JSON_REPLY).encode(), "application/json")
        elif url.path == "/header":
            self.reply(200, self.headers.get(q.get("name", [""])[0], "(none)").encode())
        elif url.path == "/chunked":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i, c in enumerate(CHUNKS):
                ext = ";note=x" if i == 1 else ""  # (a chunk extension, which a reader skips)
                self.wfile.write(f"{len(c):X}{ext}\r\n".encode() + c + b"\r\n")
                self.wfile.flush()
                time.sleep(0.02)
            self.wfile.write(b"0\r\n\r\n")
        elif url.path == "/big":
            self.reply(200, BIG, "application/octet-stream")
        elif url.path == "/slow":
            ms = int(q.get("ms", ["2000"])[0])
            time.sleep(ms / 1000)
            try:
                self.reply(200, f"slept {ms} ms".encode())
            except OSError:
                pass  # (the client gave up first: a timeout test)
        elif url.path == "/fail":
            self.reply(500, b"boom")
        else:
            self.reply(404, b"no such route")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        self.keep(body)
        try:
            value = json.loads(body)
        except ValueError:
            self.reply(400, b"not JSON")
            return
        out = {"method": "POST", "type": self.headers.get("Content-Type", ""), "body": value}
        self.reply(200, json.dumps(out).encode(), "application/json")


class TestServer:
    """Starts the server on a free port in a thread; `url` ends with '/'; `dead` is a URL nothing listens on."""

    def __init__(self, port=0):
        self.httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.httpd.daemon_threads = True
        self.httpd.seen = []
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}/"
        with socket.socket() as s:  # a port that was free a moment ago: connecting is refused
            s.bind(("127.0.0.1", 0))
            self.dead = f"http://127.0.0.1:{s.getsockname()[1]}/"
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    @property
    def seen(self):
        return self.httpd.seen

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()


if __name__ == "__main__":
    srv = TestServer(int(sys.argv[1]) if len(sys.argv) > 1 else 0)
    with srv:
        print(f"HTTP_TEST_URL={srv.url} HTTP_TEST_DEAD={srv.dead}", flush=True)
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            pass
