"""An AG-UI agent for the Mac run of agentchat, with nothing but the standard library (the runner has no SDK): each POST
gets the next recorded stream (scripts/mac_agentchat_streams.py), and every request body is kept in out/ so Linux can
check it with the AG-UI SDK (RunAgentInput) afterwards.

  python3 ci/agui_replay.py PORT out/agentchat-requests.jsonl ci/agentchat-picture-1.sse ci/agentchat-picture-2.sse
"""
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, log, streams = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
served = [0]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(log, "ab") as f:
            f.write(body + b"\n")
        k = min(served[0], len(streams) - 1)
        served[0] += 1
        data = open(streams[k], "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
