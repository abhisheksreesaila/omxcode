"""Stand-in for the Hugging Face Hub (MOJOUI_HF_BASE), for goal 64's fake-port harness: one unsupported model,
acme/weird (the WeirdForCausalLM fixture the Python version's tests used), with a tiny config and weights.
  python fake_hub.py <port> <dir-with-config.json>"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

port, folder = int(sys.argv[1]), Path(sys.argv[2])
CONFIG = (folder / "config.json").read_bytes()
WEIGHTS = b"safetensors-stand-in\n" * 64
SHA = "0123456789abcdef0123456789abcdef01234567"
FILES = {"config.json": CONFIG, "model.safetensors": WEIGHTS}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, status, body=b"", kind="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if self.path.startswith("/api/models/acme/weird"):
            siblings = [{"rfilename": n, "size": len(b)} for n, b in FILES.items()]
            body = {"id": "acme/weird", "sha": SHA, "siblings": siblings,
                    "files": siblings, "pipeline_tag": "text-generation", "downloads": 1, "likes": 0,
                    "lastModified": "2026-11-01T00:00:00.000Z"}
            return self._send(200, json.dumps(body).encode())
        for name, body in FILES.items():
            if self.path.endswith("/" + name):
                return self._send(200, body, "application/octet-stream")
        self._send(404, b'{"error": "not found"}')


ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
