"""The agent host never hands a secret field's contents to an agent (goal 64 review round 2, D-6509): a FIELD with
style FIELD_SECRET (TextField.secret()) is read by its tool name, by its tag and by its placeholder's slug, listed on
the screen, offered as a tool and read with the whole screen, and the key is in none of them; only its length is. A
plain field beside it still reads back, so the masking is the secret's own. Driven against a fake host link (the same
JSON-lines protocol as web.py's and the GTK host's MOJOUI_AGENT_SOCKET).

    pixi run python tests/test_agent_secret.py      # prints "agent_secret: ok"
"""

import json
import socketserver
import sys
import tempfile
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "mojoui" / "hosts"))
import agent  # noqa: E402

KEY = "sk-agent-secret-0123456789abcdef"
NAME = "ada-lovelace-plain"


def node(kind, name="", hint="", msg=0, text="", style=0, children=()):
    return {"kind": kind, "name": name, "hint": hint, "value": 0, "msg": msg, "msg2": 0, "text": text, "tip": "", "style": style,
            "options": [], "children": list(children), "w": 0, "h": 0, "size": 0, "spacing": 0, "x": 0, "y": 0}


class FakeHost:
    def handle(self, op):
        if op["op"] == "view":
            nodes = [node(agent.VSTACK, children=[1, 2, 4]),
                     node(agent.HSTACK, name="outlined-field", children=[3]),
                     node(agent.TEXT, text="API key"),
                     node(agent.FIELD, hint="API key Claude Code signs in with", msg=7, text=KEY, style=agent.FIELD_SECRET),
                     node(agent.FIELD, name="who", hint="", msg=8, text=NAME)]
            nodes[0]["children"] = [1, 2, 4]
            nodes[1]["children"] = [3]
            return {"ok": True, "title": "fake", "design": "omxqua", "nodes": nodes, "widgets": [], "busy": False}
        return {"ok": True}


def serve(fake, path):
    class H(socketserver.StreamRequestHandler):
        def handle(self):
            for raw in self.rfile:
                self.wfile.write((json.dumps(fake.handle(json.loads(raw))) + "\n").encode())
                self.wfile.flush()
    srv = socketserver.ThreadingUnixStreamServer(str(path), H)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def main():
    path = Path(tempfile.mkdtemp()) / "link.sock"
    srv = serve(FakeHost(), path)
    host = agent.Host(attach=path)
    tools = {t["name"]: t for t in host.tools()}
    secret_tool = "api-key-claude-code-signs-in-with"
    assert secret_tool in tools, sorted(tools)
    seen = [json.dumps(tools)]
    # read it every way an agent can name it: its tool, its placeholder's slug, and the stack it sits in
    for name in (secret_tool, "outlined-field"):
        seen.append(host.call("read", {"name": name}))
    assert host.call("read", {"name": secret_tool}) == f"(secret, {len(KEY)} characters)", host.call("read", {"name": secret_tool})
    seen.append(host.call("read", {}))
    seen.append(host.call("screen", {}))
    assert f"Secret field ({len(KEY)} characters)" in seen[-1], seen[-1]
    for text in seen:
        assert KEY not in text, text
        assert KEY[:12] not in text, text
    # a plain field is not masked: the masking belongs to .secret()
    assert NAME in host.call("read", {"name": "who"}), host.call("read", {"name": "who"})
    assert NAME in host.call("screen", {})
    srv.shutdown()
    print("agent_secret: ok")


if __name__ == "__main__":
    main()
