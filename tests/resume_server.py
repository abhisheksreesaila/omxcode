"""A file server whose connections drop mid-body, for tests/test_resume.mojo (goal 55: Hugging Face's CDN resets long
downloads). Serves FILE_SIZE bytes (byte i is i % 251) and honours `Range: bytes=K-` with a 206.
  /drop         the first request sends 40% of the body and closes the socket; every later one is whole
  /always-drop  every request sends 40% of what it owes and closes
  /whole        never drops
Prints "PORT <n>" once listening on 127.0.0.1 (port 0: any free one).
  python tests/resume_server.py [port]"""
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FILE_SIZE = 3_000_000
DATA = bytes(i % 251 for i in range(FILE_SIZE))
seen = {}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        path = self.path.split("?")[0]
        with lock:
            n = seen.get(path, 0)
            seen[path] = n + 1
        start = 0
        rng = self.headers.get("Range", "")
        if rng.startswith("bytes=") and rng.endswith("-"):
            start = int(rng[6:-1])
        body = DATA[start:]
        self.send_response(206 if start else 200)
        if start:
            self.send_header("Content-Range", f"bytes {start}-{FILE_SIZE - 1}/{FILE_SIZE}")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()
        drop = (path == "/drop" and n == 0) or path == "/always-drop"
        if drop:
            self.wfile.write(body[: int(len(body) * 0.4)])
            self.wfile.flush()
            self.close_connection = True
            self.connection.shutdown(2)
            return
        self.wfile.write(body)


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 0), Handler)
    print("PORT", srv.server_address[1], flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
