"""Static server for the browser row: cross-origin isolated (COOP/COEP, so wasm threads work) and a sink for
scripted results. python serve.py [--port P] [--out DIR]; POST /result/<name>[?offset=B] writes DIR/<name> (at B)."""
import argparse
import http.server
import sys
from functools import partial
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

HERE = Path(__file__).resolve().parent


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".wasm": "application/wasm", ".js": "text/javascript"}
    out = Path(".")

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_POST(self):
        url = urlsplit(self.path)
        name = url.path.removeprefix("/result/")
        if not url.path.startswith("/result/") or not name or "/" in name or name.startswith("."):
            self.send_error(404)
            return
        offset = int(parse_qs(url.query).get("offset", ["0"])[0])  # big results arrive in chunks
        size = int(self.headers.get("Content-Length", 0))
        path = self.out / name
        with open(path, "r+b" if offset and path.exists() else "wb") as f:
            f.seek(offset)
            f.write(self.rfile.read(size))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *a):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8036)
    ap.add_argument("--out", default=str(HERE / "out"))
    ap.add_argument("--root", default=str(HERE / "build/web"))
    a = ap.parse_args()
    Handler.out = Path(a.out)
    Handler.out.mkdir(parents=True, exist_ok=True)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", a.port), partial(Handler, directory=a.root))
    print(f"http://127.0.0.1:{srv.server_address[1]}/", flush=True)
    sys.stdout.flush()
    srv.serve_forever()


if __name__ == "__main__":
    main()
