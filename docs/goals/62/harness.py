"""Goal 62's harness: omxplorer's web host on a free port (optionally public, held to a plan's memory and CPU, behind a
delaying proxy), headless Chromium pages on it, and what the server and the page used. Adapted from the browser check's
build/webcheck/harness/webstory.py (another session's, 2026-11-06), for this worktree and for visitors who only click.

Imported by docs/goals/62-check.py and the other helpers here; run with this checkout's pixi Python."""

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build/g62"
CHROMIUM = "/usr/bin/chromium"
MODULE = ROOT / "build/omxplorer/web"
G47 = Path("/home/abhisheksreesaila/.abode/home/worktrees/mojo-ui/t3-32644b84/build/g47/full")  # (read-only: another session's)
STARTER = ROOT / "build/starter/robot"  # scripts/starter.py makes it from G47


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Server:
    """mojoui/hosts/web.py on a free port, CPU only, its log in a file and in memory.

    public: MOJOUI_PUBLIC=1 (the hosted copy's switch). limits: {"MemoryMax": "4G", "CPUQuota": "200%"} runs it in a
    transient systemd scope held to them (systemd-run --user --scope). env: more environment. start: the command that
    starts it instead of web.py (the image's own, scripts/web-start: it reads PORT and MOJOUI_MODULE)."""

    def __init__(self, out, public=True, env=None, limits=None, module=MODULE, starter=STARTER, port=None, start=None):
        self.out = Path(out)
        if self.out.exists():
            shutil.rmtree(self.out)  # (this check's own scratch folder, made by its last run)
        self.out.mkdir(parents=True)
        self.port = port or free_port()
        self.uploads = self.out / "uploads"
        self.home = self.out / "home"
        self.home.mkdir()
        e = dict(os.environ, CUDA_VISIBLE_DEVICES="", PYTHONUNBUFFERED="1", MOJOUI_TRACE="1", HOME=str(self.home),
                 OMXCODE_UPLOADS=str(self.uploads), OMX_DOCUMENTS=str(self.out / "documents"), OMX_CONFIG=str(self.out / "config"),
                 PORT=str(self.port))
        e.pop("MOJOUI_AGENT_SOCKET", None)
        if public:
            e["MOJOUI_PUBLIC"] = "1"
        if starter:
            e["OMX_STARTER"] = str(starter)
        e.update(env or {})
        self.env = e
        cmd = [sys.executable, os.environ.get("G62_WEB", str(ROOT / "mojoui/hosts/web.py")), str(module), str(self.port)]
        if start:
            e["MOJOUI_MODULE"] = str(module)
            e["MOJOUI_PYTHON"] = sys.executable
            cmd = list(start)
        self.unit = None
        if limits:
            self.unit = f"g62-web-{self.port}"
            props = sum((["-p", f"{k}={v}"] for k, v in limits.items()), [])
            cmd = ["systemd-run", "--user", "--scope", "--quiet", f"--unit={self.unit}", *props, "--", *cmd]
        self.log, self.stamps = [], []
        self.logfile = open(self.out / "server.log", "w")
        t0 = time.perf_counter()
        self.p = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=e)
        self.reader = threading.Thread(target=self._drain, daemon=True)
        self.reader.start()
        self.url = f"http://127.0.0.1:{self.port}/"
        for _ in range(1800):
            try:
                urllib.request.urlopen(self.url + "health", timeout=1)
                break
            except urllib.error.HTTPError:
                break  # (an old host without /health answered: it's up)
            except OSError:
                if self.p.poll() is not None:
                    raise RuntimeError("server died:\n" + "\n".join(self.log[-40:]))
                time.sleep(0.1)
        self.start_s = time.perf_counter() - t0

    def _drain(self):
        for line in self.p.stdout:
            line = line.rstrip("\n")
            self.stamps.append(time.perf_counter())
            self.log.append(line)
            self.logfile.write(line + "\n")
            self.logfile.flush()

    def mark(self):
        return len(self.log)

    def traced(self, prefix, mark=0, timeout=10.0):
        """The newest log line from `mark` on that starts with prefix, waiting up to timeout."""
        t0 = time.time()
        while True:
            got = [l for l in self.log[mark:] if l.startswith(prefix)]
            if got or time.time() - t0 >= timeout:
                return got[-1] if got else ""
            time.sleep(0.05)

    def pid(self):
        """The web server's own pid (under systemd-run --scope the command keeps systemd-run's pid: it execs)."""
        return self.p.pid

    def memory(self):
        """The server's memory in MB: RSS, peak RSS, PSS (smaps_rollup); with limits, the scope's cgroup memory too."""
        pid = self.pid()
        st = Path(f"/proc/{pid}/status").read_text()
        rss = int(re.search(r"VmRSS:\s+(\d+)", st).group(1)) / 1024
        hwm = int(re.search(r"VmHWM:\s+(\d+)", st).group(1)) / 1024
        roll = Path(f"/proc/{pid}/smaps_rollup").read_text()
        pss = int(re.search(r"^Pss:\s+(\d+)", roll, re.M).group(1)) / 1024
        swap = int(re.search(r"VmSwap:\s+(\d+)", st).group(1)) / 1024
        # (mem_mb: RSS + swap: this machine is shared, and under pressure the kernel swaps the idle starter out)
        out = {"mem_mb": round(rss + swap), "rss_mb": round(rss), "swap_mb": round(swap), "peak_rss_mb": round(hwm), "pss_mb": round(pss)}
        cg = cgroup_of(pid)
        if self.unit and cg:
            for k, f in (("cgroup_mb", "memory.current"), ("cgroup_peak_mb", "memory.peak")):
                try:
                    out[k] = round(int((cg / f).read_text()) / 2**20)
                except (OSError, ValueError):
                    pass
        return out

    def stop(self):
        self.p.terminate()
        try:
            self.p.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait(timeout=10)
        self.reader.join(timeout=5)
        self.logfile.close()


def cgroup_of(pid):
    try:
        rel = Path(f"/proc/{pid}/cgroup").read_text().strip().split("::", 1)[1]
        return Path("/sys/fs/cgroup") / rel.lstrip("/")
    except (OSError, IndexError):
        return None


def get(url, data=None, headers=None, timeout=30):
    """(status, headers, body bytes) of one plain request (no browser: urllib's own headers only)."""
    req = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


CANVASES_DRAWN = """() => [...document.querySelectorAll('[data-kind=canvas]')].every(div => {
  const st = div.mojoui, m = document.getElementById('n' + div.dataset.node + '-meta');
  if (!st || !m) return false;
  if (m.dataset.frames !== '0') return st.count > 0;
  const ev = window.mojouiEvents;
  return !st.busy && !(ev && (ev.sending || ev.queue.length)) && !st.updating && !st.again && !st.timer && !(window.mojouiPendingBusy && window.mojouiPendingBusy()) && String(st.drawn) === m.dataset.version;
})"""

# In-page probes: htmx swaps settled, clicks and changes (performance.now()).
PROBE = """
window.__probe = { settles: [], clicks: [], changes: [] };
document.addEventListener('htmx:afterSettle', () => window.__probe.settles.push(performance.now()));
document.addEventListener('click', () => window.__probe.clicks.push(performance.now()), true);
document.addEventListener('change', () => window.__probe.changes.push(performance.now()), true);
"""

OBJECTS = "() => [...document.querySelectorAll('[data-kind=object]')].map(o => (o.dataset.tag || '') + ': ' + (o.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 160))"


def settle(page, timeout=30000):
    """The page has no request out and every canvas shows its newest picture (or is playing)."""
    page.wait_for_timeout(250)
    page.wait_for_function("() => document.getElementById('mojoui-root') && document.getElementById('mojoui-root').dataset.sid && !document.querySelector('.htmx-request')", timeout=timeout)
    page.wait_for_function(CANVASES_DRAWN, timeout=timeout)
    page.wait_for_function("() => !document.querySelector('.htmx-request')", timeout=timeout)
    page.wait_for_timeout(50)


def try_settle(page, timeout=30000):
    try:
        settle(page, timeout)
        return True
    except Exception as e:
        print(f"   (not settled: {str(e)[:160]})", flush=True)
        return False


class Net:
    """Every response a page got (url, status, bytes, time) and every WebSocket frame, through the DevTools protocol
    (Network.loadingFinished's encodedDataLength: bytes on the wire for that request)."""

    def __init__(self, page):
        self.events = []  # (perf time, kind, url, bytes, status)
        self.urls = {}
        self.status = {}
        self.cdp = page.context.new_cdp_session(page)
        self.cdp.send("Network.enable")
        self.cdp.on("Network.requestWillBeSent", self._req)
        self.cdp.on("Network.loadingFinished", self._done)
        self.cdp.on("Network.responseReceived", lambda e: self.status.__setitem__(e["requestId"], e["response"]["status"]))
        self.cdp.on("Network.webSocketFrameReceived", lambda e: self.events.append((time.perf_counter(), "ws", "", len(e["response"]["payloadData"]), 101)))
        self.cdp.on("Network.webSocketCreated", lambda e: self.events.append((time.perf_counter(), "ws-open", e.get("url", ""), 0, 101)))

    def _req(self, e):
        self.urls[e["requestId"]] = e["request"]["url"]
        self.events.append((time.perf_counter(), "request", e["request"]["url"], 0, 0))

    def _done(self, e):
        self.events.append((time.perf_counter(), "response", self.urls.get(e["requestId"], ""), int(e.get("encodedDataLength", 0)), self.status.get(e["requestId"], 0)))

    def since(self, t0, kinds=("response", "ws")):
        return [ev for ev in self.events if ev[0] >= t0 and ev[1] in kinds]


def chromium(p, **kw):
    return p.chromium.launch(executable_path=CHROMIUM, headless=True, **kw)
