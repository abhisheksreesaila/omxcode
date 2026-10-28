"""A small MCP client for the checks (and for trying the agent host by hand): spawns the server over stdio,
speaks JSON-RPC, keeps the notifications it gets.

  pixi run python scripts/agent_client.py build/kit/web screen
  pixi run python scripts/agent_client.py build/kit/web file-save
  pixi run python scripts/agent_client.py build/kit/web act name=open-dialog
  pixi run python scripts/agent_client.py --attach /tmp/widgets.sock editor-read     (a running host's agent link)
"""

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class Client:
    def __init__(self, module_dir=None, env=None, attach=None):
        """module_dir: the agent host runs its own session of that web build; attach: it attaches to a running host's
        agent link instead (MOJOUI_AGENT_SOCKET; the widgets run there)."""
        import os
        target = ["--attach", str(attach)] if attach else [str(module_dir)]
        self.p = subprocess.Popen([sys.executable, str(ROOT / "mojoui/hosts/agent.py"), *target], cwd=ROOT, env=dict(os.environ, **(env or {})),
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
        self.next_id = 1
        self.notifications = []
        self.init = self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "omxcode-check", "version": "0"}})
        self.notify("notifications/initialized")

    def send(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    def notify(self, method, params=None):
        self.send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def request(self, method, params=None):
        rid = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}})
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("the agent host closed: " + self.p.stderr.read()[-2000:])
            msg = json.loads(line)
            if "method" in msg and "id" not in msg:
                self.notifications.append(msg["method"])
                continue
            if msg.get("id") != rid:
                raise RuntimeError(f"out of order: {line[:200]}")
            if "error" in msg:
                raise RuntimeError(f"{method}: {msg['error']}")
            return msg["result"]

    def tools(self):
        return self.request("tools/list")["tools"]

    def names(self):
        return [t["name"] for t in self.tools()]

    def call(self, tool, **args):
        """Calls a tool; returns (text, images, is_error)."""
        r = self.request("tools/call", {"name": tool, "arguments": args})
        texts = [c["text"] for c in r["content"] if c["type"] == "text"]
        images = [c for c in r["content"] if c["type"] == "image"]
        return "\n".join(texts), images, bool(r.get("isError"))

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()
        return self.p.stderr.read()


if __name__ == "__main__":
    argv = sys.argv[1:]
    c = Client(attach=argv[1]) if argv[0] == "--attach" else Client(argv[0])
    rest = argv[2:] if argv[0] == "--attach" else argv[1:]
    name = rest[0] if rest else "screen"
    args = {}
    for kv in rest[1:]:
        k, _, v = kv.partition("=")
        args[k] = json.loads(v) if v[:1] in "{[0123456789tf" else v
    text, images, err = c.call(name, **args)
    print(("ERROR: " if err else "") + text + (f"\n[{len(images)} image(s)]" if images else ""))
    c.close()
