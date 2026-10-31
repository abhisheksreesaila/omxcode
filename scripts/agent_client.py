"""A small MCP client for the checks (and for trying the agent host by hand): spawns the server over stdio,
speaks JSON-RPC, keeps the notifications it gets.

  pixi run python scripts/agent_client.py build/kit/web screen
  pixi run python scripts/agent_client.py build/kit/web file-save
  pixi run python scripts/agent_client.py build/kit/web act name=open-dialog
  pixi run python scripts/agent_client.py --attach /tmp/widgets.sock editor-read     (a running host's agent link)
  pixi run python scripts/agent_client.py omxplorer --tools --media clip.mp4         (an app by name: its web build, made or
        remade when its sources are newer; --media opens the file through the screen's file picker first, as a person
        would; --tools prints the tools then on screen, one per line: name — description)
"""

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class Client:
    def __init__(self, module_dir=None, env=None, attach=None, python=None):
        """module_dir: the agent host runs its own session of that web build; attach: it attaches to a running host's
        agent link instead (MOJOUI_AGENT_SOCKET; the widgets run there); python: the interpreter it runs in (default this
        one; the models environment's when the app runs a model in process, e.g. OCR)."""
        import os
        target = ["--attach", str(attach)] if attach else [str(module_dir)]
        self.p = subprocess.Popen([str(python or sys.executable), str(ROOT / "mojoui/hosts/agent.py"), *target], cwd=ROOT, env=dict(os.environ, **(env or {})),
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


def app_build(name):
    """build/<name>/web for an app name (examples/<name>), built when missing or older than the sources it compiles."""
    import subprocess
    if Path(name).is_dir():
        return Path(name)
    out = ROOT / "build" / name / "web"
    so = out / "mojoui_app.so"
    sources = [*(ROOT / "examples" / name).glob("*.mojo"), *(ROOT / "mojoui").rglob("*.mojo"), *(ROOT / "themes").glob("*.mojo"),
               *(ROOT / "mojoui/hosts").glob("*.py")]
    if not so.exists() or max((p.stat().st_mtime for p in sources), default=0) > so.stat().st_mtime:
        r = subprocess.run([str(ROOT / "scripts/build.sh"), name, "web"], cwd=ROOT, capture_output=True, text=True)
        if r.returncode:
            raise SystemExit(f"build {name} web failed: {(r.stdout + r.stderr)[-1500:]}")
    return out


def open_through_picker(c, path):
    """Opens a file the way a person would: the first file picker on screen that accepts its extension gets its path."""
    ext = Path(path).suffix.lower()
    for t in c.tools():
        if "path" not in t["inputSchema"].get("properties", {}):
            continue
        accepts = t["description"].rsplit("(accepts ", 1)[-1].rstrip(")").lower()
        if accepts == "any file" or ext in [a.strip() for a in accepts.split(",")]:
            text, _, err = c.call(t["name"], path=str(Path(path).resolve()))
            if err:
                raise SystemExit(f"{t['name']}: {text}")
            return t["name"], text
    raise SystemExit(f"no file picker on screen takes {ext} files")


def tools_main(argv):
    """<app> --tools [--media FILE]: the tools an agent has (after opening FILE), one per line."""
    app = argv[0]
    media = argv[argv.index("--media") + 1] if "--media" in argv else None
    c = Client(app_build(app))
    try:
        if media:
            picker, said = open_through_picker(c, media)
            print(f"# opened {Path(media).name} with {picker}: {said.splitlines()[-1] if said else ''}")
        if "--tools" in argv:
            for t in c.tools():
                print(f"{t['name']} — {t['description']}")
    finally:
        c.close()


if __name__ == "__main__":
    argv = sys.argv[1:]
    if "--tools" in argv or "--media" in argv:
        tools_main(argv)
        sys.exit(0)
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
