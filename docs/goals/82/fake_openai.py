"""An OpenAI-compatible chat endpoint on loopback for goal 82 M6's check (no network, no key of anyone's): POST
/v1/chat/completions answers with the recorded reply (argv[2]) as the message's content; each request's Authorization (or
api-key) header and its body are appended as one JSON line to argv[3]. Prints its port, then serves until killed.
    python3 -I docs/goals/82/fake_openai.py <port or 0> <reply file> <seen.jsonl>"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPLY = open(sys.argv[2]).read()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with open(sys.argv[3], "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization", ""), "api_key": self.headers.get("api-key", ""),
                                "body": json.loads(body or b"{}")}) + "\n")
        out = json.dumps({"id": "c1", "object": "chat.completion", "choices": [{"index": 0, "message": {"role": "assistant", "content": REPLY}, "finish_reason": "stop"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
