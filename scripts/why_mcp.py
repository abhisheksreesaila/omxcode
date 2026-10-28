"""Records the MCP session docs/why-details.html shows (goal 36 M5, reviewer item 2): an agent drives the native particle app.

    pixi run python scripts/why_mcp.py      # writes docs/goals/36/mcp-transcript.json

The GTK build (build/particles/linux/particles) runs on the headless display with GDK_DEBUG=no-vsync, the context
M4 measured it in, and opens its agent link (MOJOUI_AGENT_SOCKET); the agent host attaches to it
(mojoui/hosts/agent.py --attach) and speaks MCP over stdio. Every JSON-RPC line both ways is kept, unedited.
Steps: screen; the slider to 50 (the third stop: 5M); three seconds; read.
"""

import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import headless  # noqa: E402
from agent_client import Client  # noqa: E402

OUT = ROOT / "docs/goals/36/mcp-transcript.json"
APP = ROOT / "build/particles/linux/particles"


class Tap:
    """Keeps every line the agent host sends back."""

    def __init__(self, f, log):
        self.f, self.log = f, log

    def readline(self):
        line = self.f.readline()
        if line:
            self.log.append({"from": "agent host", "t": round(time.time(), 3), "msg": json.loads(line)})
        return line

    def read(self):
        return self.f.read()


def main():
    if not APP.exists():
        raise SystemExit(f"{APP} missing: scripts/build.sh particles linux")
    headless.ensure()
    log = []
    with tempfile.TemporaryDirectory() as d:
        sock = Path(d) / "particles.sock"
        env = dict(os.environ, MOJOUI_AGENT_SOCKET=str(sock), GDK_DEBUG="no-vsync")
        app = subprocess.Popen([str(APP)], cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                               start_new_session=True)
        try:
            for _ in range(300):
                if sock.exists():
                    break
                if app.poll() is not None:
                    raise SystemExit("the app exited: " + app.stderr.read().decode()[-1500:])
                time.sleep(0.1)
            else:
                raise SystemExit("the app never opened its agent link")
            time.sleep(3)  # its frames running, so the readout has an fps
            c = Client(attach=sock)
            c.p.stdout = Tap(c.p.stdout, log)
            send = c.send

            def tapped(obj):
                log.append({"from": "agent", "t": round(time.time(), 3), "msg": obj})
                send(obj)
            c.send = tapped
            c.call("screen")
            c.call("slider", value=50)
            time.sleep(3)
            c.call("read")
            c.close()
        finally:
            os.killpg(app.pid, signal.SIGTERM)  # (only the app this script started, in its own session)
            try:
                app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(app.pid, signal.SIGKILL)
    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    OUT.write_text(json.dumps({
        "date": time.strftime("%Y-%m-%d %H:%M"), "commit": commit,
        "app": "build/particles/linux/particles: the native GTK build, on the headless display (Xvfb), GDK_DEBUG=no-vsync",
        "agent": "mojoui/hosts/agent.py --attach <MOJOUI_AGENT_SOCKET>, driven by scripts/agent_client.py's Client",
        "load1": round(os.getloadavg()[0], 2), "messages": log}, indent=1, ensure_ascii=False) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)} ({len(log)} messages)")


if __name__ == "__main__":
    main()
