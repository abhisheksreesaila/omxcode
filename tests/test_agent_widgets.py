"""The agent host's side of JS widgets (goal 34b M0): a WebComponent becomes <name>-read (what its describe() says, as
JSON) and <name>-set (the fields it declares, each a typed argument); a set that names an undeclared field or a value of
the wrong JSON type never reaches the host; a widget without describe reads "no description"; in the agent's own session
(no web view) a widget says how to attach. Driven against a fake host link (the same JSON-lines protocol as web.py's and
the GTK host's MOJOUI_AGENT_SOCKET), so it runs without a browser.

    pixi run python tests/test_agent_widgets.py      # prints "agent_widgets: ok"
"""

import json
import socket
import socketserver
import sys
import tempfile
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "mojoui" / "hosts"))
import agent  # noqa: E402


def node(kind, name="", hint="", value=0, msg=0, text="", children=(), tip=""):
    return {"kind": kind, "name": name, "hint": hint, "value": value, "msg": msg, "msg2": 0, "text": text, "tip": tip, "style": 0,
            "options": [], "children": list(children), "w": 0, "h": 0, "size": 0, "spacing": 0, "x": 0, "y": 0}


class FakeHost:
    """A host with an editor (describe + a text field), a counter (describe + a count field) and a plain widget."""

    def __init__(self):
        self.text, self.count, self.sets, self.words = "", 0, [], 0

    def view(self):
        nodes = [node(agent.VSTACK, children=[1, 2, 3, 4]),
                 node(agent.WEBCOMP, name="editor", hint="mx-editor", value=1, msg=7),
                 node(agent.WEBCOMP, name="counter", hint="mx-counter", value=1, msg=2),
                 node(agent.WEBCOMP, hint="mx-plain", value=3, msg=0),
                 node(agent.TEXT, text=f"Words: {self.words}")]
        widgets = [
            {"tag": "mx-editor", "id": 1, "description": "The note, in a CodeMirror 6 text editor",
             "said": {"text": f"{len(self.text)} characters", "value": self.text, "lines": self.text.count("\n") + 1}, "fields": {"text": "string"}},
            {"tag": "mx-counter", "id": 1, "description": "A counter", "said": {"text": f"count {self.count}", "count": self.count}, "fields": {"count": "integer"}},
            {"tag": "mx-plain", "id": 3, "description": "", "said": None, "fields": {}},
        ]
        return {"ok": True, "title": "fake", "design": "omxqua", "nodes": nodes, "widgets": widgets, "busy": False}

    def handle(self, op):
        if op["op"] == "view":
            return self.view()
        if op["op"] == "set":
            self.sets.append(op)
            value = json.loads(op["value"])  # (the link carries JSON text)
            if op["tag"] == "mx-editor":
                self.text = value
                self.words = len(value.split())
            else:
                self.count = value
            return {"ok": True}
        return {"ok": False, "error": "no op"}


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
    fake = FakeHost()
    path = Path(tempfile.mkdtemp()) / "link.sock"
    srv = serve(fake, path)
    host = agent.Host(attach=path)
    tools = {t["name"]: t for t in host.tools()}
    for need in ("editor-read", "editor-set", "counter-read", "counter-set", "mx-plain-read"):
        assert need in tools, sorted(tools)
    assert "mx-plain-set" not in tools  # (no fields: nothing to set)
    assert tools["editor-set"]["inputSchema"]["properties"] == {"text": {"type": "string", "description": "its new text"}}, tools["editor-set"]
    assert tools["counter-set"]["inputSchema"]["properties"]["count"]["type"] == "integer"
    assert "CodeMirror" in tools["editor-read"]["description"]
    assert "no description" in tools["mx-plain-read"]["description"], tools["mx-plain-read"]
    assert host.call("mx-plain-read", {}) == "mx-plain#3: no description"

    out = host.call("editor-set", {"text": "one two\nthree"})
    assert "Did editor-set." in out and "Now: mx-editor#1" in out, out
    said = json.loads(host.call("editor-read", {}).split(": ", 1)[1])
    assert said["value"] == "one two\nthree" and said["lines"] == 2, said
    assert host.call("read", {"name": "editor"}).startswith("mx-editor#1: {")
    assert "Words: 3" in host.call("read", {})
    host.call("counter-set", {"count": 42})
    assert json.loads(host.call("counter-read", {}).split(": ", 1)[1])["count"] == 42
    assert fake.sets[-1] == {"op": "set", "tag": "mx-counter", "id": 1, "field": "count", "value": "42"}, fake.sets[-1]

    n = len(fake.sets)
    for tool, args, why in [("counter-set", {"label": "<img src=x onerror=alert(1)>"}, "no settable field"),
                            ("counter-set", {"count": "7"}, "takes integer"), ("counter-set", {"count": True}, "takes integer"),
                            ("counter-set", {"count": 1.5}, "takes integer"), ("editor-set", {"text": 12}, "takes string"),
                            ("editor-set", {}, "give one of its fields")]:
        try:
            host.call(tool, args)
        except ValueError as e:
            assert why in str(e), (tool, args, str(e))
        else:
            raise AssertionError(f"{tool} {args} was accepted")
    assert len(fake.sets) == n, fake.sets[n:]  # (refused before anything crossed)
    screen = host.call("screen", {})
    assert "Widget mx-editor: The note, in a CodeMirror 6 text editor #1: 13 characters → editor-read, editor-set" in screen, screen
    assert "Widget mx-plain (no description) #3" in screen, screen
    try:
        host.call("render", {})
    except ValueError as e:
        assert "own session" in str(e)
    srv.shutdown()

    # the agent's own session: no web view, so a widget says how to attach
    local = agent.Host.__new__(agent.Host)
    local.link, local.widgets, local.nodes = None, {}, fake.view()["nodes"]
    assert "MOJOUI_AGENT_SOCKET" in local.widget_read(1)
    assert "not running here" in local.widget_what(1)
    assert agent.fits("number", 3) and agent.fits("integer", 3.0) and not agent.fits("integer", True) and not agent.fits("string", None)
    print("agent_widgets: ok")


if __name__ == "__main__":
    main()
