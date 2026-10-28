"""A stand-in for an OpenAI-compatible chat API (the OMX Console's shape: POST /v1/chat/completions, streamed), for goal
35 M3's check of the live agent path. It answers like a small local model does: some words, then a render_ui tool call
whose JSON is broken (code fences, single quotes, trailing commas, lower-case and synonym names), which the agent
backend must repair. `seen` keeps each request's Authorization header and body.
"""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BROKEN = ("```json\n{'ui': {'component': 'card', 'title': 'Sales', 'children': [{'component': 'chart', "
          "'data': [12, 15, 14, 18, 21,], 'title': 'Sales, in thousands',},]}}\n```")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        self.server.seen.append({"path": self.path, "auth": self.headers.get("Authorization", ""), "body": body})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def chunk(delta):
            data = "data: " + json.dumps({"id": "c1", "object": "chat.completion.chunk", "model": body.get("model"),
                                          "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}) + "\n\n"
            b = data.encode()
            self.wfile.write(f"{len(b):X}\r\n".encode() + b + b"\r\n")
            self.wfile.flush()

        chunk({"role": "assistant", "content": "Here are "})
        chunk({"content": "your sales."})
        half = len(BROKEN) // 2
        chunk({"tool_calls": [{"index": 0, "id": "call_1", "type": "function", "function": {"name": "render_ui", "arguments": BROKEN[:half]}}]})
        chunk({"tool_calls": [{"index": 0, "function": {"arguments": BROKEN[half:]}}]})
        done = b"data: [DONE]\n\n"
        self.wfile.write(f"{len(done):X}\r\n".encode() + done + b"\r\n0\r\n\r\n")
        self.wfile.flush()


class Server:
    def __init__(self):
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        self.httpd.seen = []
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}/v1"
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
