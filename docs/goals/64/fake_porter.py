"""Stand-in for a frontier model's endpoint, so goal 64's checks never need a real API key: a one-token Anthropic
Messages call (POST /v1/messages, the API the porting agent speaks) with the good key in `x-api-key` or
`Authorization: Bearer` is 200, anything else 401.
  python fake_porter.py <port> <good key>"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, good = int(sys.argv[1]), sys.argv[2]
seen = []


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0)
        self.do_GET()

    def do_GET(self):
        auth = self.headers.get("authorization", "")
        key = self.headers.get("x-api-key", "")
        seen.append({"path": self.path, "auth": auth})
        ok = auth == "Bearer " + good or key == good
        body = json.dumps({"content": [{"type": "text", "text": "hi"}], "model": "a-frontier-model"}
                          if ok else {"error": "bad key"}).encode()
        self.send_response(200 if ok else 401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
