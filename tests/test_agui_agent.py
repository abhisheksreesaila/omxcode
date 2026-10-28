"""scripts/agui_agent.py's HTTP edge (goal 35 reviewer item 4, D-722): only a local app may start a run. A web page can't
(a JSON content type is required, so no simple cross-site POST; a foreign Origin or a Host that isn't localhost is
refused, so no DNS rebinding); bodies are bounded; RunAgentInputs are kept only when a test asks; nothing refused ever
reaches the model; a request carrying the key never follows a redirect.

  pixi run python tests/test_agui_agent.py        (prints "agui_agent: ok")
"""

import http.client
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import agui_agent  # noqa: E402
import fake_llm  # noqa: E402

GOOD = json.dumps({"threadId": "t", "runId": "r", "messages": [{"id": "u1", "role": "user", "content": "Hello there"}],
                   "state": {}, "tools": [], "context": [], "forwardedProps": {}}).encode()


def post(port, body=GOOD, headers=None, length=True):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    h = {"Content-Type": "application/json", "Host": f"127.0.0.1:{port}"}
    h.update(headers or {})
    c.putrequest("POST", "/", skip_host=True, skip_accept_encoding=True)
    for k, v in h.items():
        if v is not None:
            c.putheader(k, v)
    if length is True:
        c.putheader("Content-Length", str(len(body)))
    elif length is not None:
        c.putheader("Content-Length", length)
    c.endheaders()
    if body and length is not None:
        try:
            c.send(body)
        except OSError:
            pass
    r = c.getresponse()
    data = r.read()
    c.close()
    return r.status, data


def main():
    problems = []
    with fake_llm.Server() as llm:
        os.environ.update(AGUI_LLM_BASE_URL=llm.url, AGUI_LLM_KEY_VAR="AGUI_TEST_KEY", AGUI_TEST_KEY="sk-edge-1")
        with agui_agent.Server("live") as srv:  # (live: a refused request must never reach the model)
            port = int(srv.url.rsplit(":", 1)[1].strip("/"))
            cases = [
                ("text/plain (a cross-site form or simple fetch)", dict(headers={"Content-Type": "text/plain"}), 415),
                ("no content type", dict(headers={"Content-Type": None}), 415),
                ("a foreign Origin", dict(headers={"Origin": "https://evil.example"}), 403),
                ("the null Origin", dict(headers={"Origin": "null"}), 403),
                ("a rebinding Host", dict(headers={"Host": f"evil.example:{port}"}), 403),
                ("a Host on another port", dict(headers={"Host": "127.0.0.1:1"}), 403),
                ("no Content-Length", dict(length=None, body=b""), 411),
                ("a negative Content-Length", dict(length="-5", body=b""), 400),
                ("a Content-Length that isn't a number", dict(length="12x", body=b""), 400),
                ("a body over 1 MB", dict(length=str(2 * 1024 * 1024), body=b"{}"), 413),
                ("not a RunAgentInput", dict(body=b'{"hello": 1}'), 422),
            ]
            for why, kw, want in cases:
                status, _ = post(port, **kw)
                if status != want:
                    problems.append(f"{why}: {status} (want {want})")
            if llm.seen:
                problems.append(f"a refused request reached the model ({len(llm.seen)} calls)")
            status, body = post(port, headers={"Origin": f"http://localhost:{port}"})
            if status != 200 or b"RUN_FINISHED" not in body:
                problems.append(f"a local request was refused: {status} {body[:200]!r}")
            if len(llm.seen) != 1:
                problems.append(f"the local request made {len(llm.seen)} model calls (want 1)")
            if srv.inputs:
                problems.append("a server outside test mode kept the RunAgentInputs")
    with agui_agent.Server("chat", record=True) as srv:
        port = int(srv.url.rsplit(":", 1)[1].strip("/"))
        status, _ = post(port)
        if status != 200 or len(srv.inputs) != 1:
            problems.append(f"a test-mode server didn't keep the input ({status}, {len(srv.inputs)})")
    # a request carrying the key never follows a redirect (the key would go wherever it points)
    hits = []

    class Target(BaseHTTPRequestHandler):
        def do_POST(self):
            hits.append(self.headers.get("Authorization"))
            self.send_response(500)
            self.end_headers()

        def log_message(self, *a):
            pass

    target = ThreadingHTTPServer(("127.0.0.1", 0), Target)
    threading.Thread(target=target.serve_forever, daemon=True).start()

    class Redirect(BaseHTTPRequestHandler):
        def do_POST(self):
            self.send_response(307)
            self.send_header("Location", f"http://127.0.0.1:{target.server_address[1]}/v1/chat/completions")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *a):
            pass

    redirect = ThreadingHTTPServer(("127.0.0.1", 0), Redirect)
    threading.Thread(target=redirect.serve_forever, daemon=True).start()
    env = dict(os.environ, AGUI_LLM_BASE_URL=f"http://127.0.0.1:{redirect.server_address[1]}/v1", AGUI_LLM_KEY_VAR="AGUI_TEST_KEY", AGUI_TEST_KEY="sk-edge-2")
    r = subprocess.run([sys.executable, str(ROOT / "scripts/agui_agent.py"), "--live", "--once", "hi"], env=env, capture_output=True, text=True, timeout=60)
    if hits:
        problems.append(f"the key followed a redirect to another server ({len(hits)} hits)")
    if "RUN_ERROR" not in r.stdout or "sk-edge-2" in r.stdout + r.stderr:
        problems.append(f"a redirect should end the run with an error and print no key: {r.stdout[-300:]!r}")
    target.shutdown()
    redirect.shutdown()
    if problems:
        print("agui_agent: FAIL: " + "; ".join(problems))
        sys.exit(1)
    print("agui_agent: ok")


if __name__ == "__main__":
    main()
