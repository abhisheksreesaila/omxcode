"""examples/console on a live mxconsole daemon (goal 33 M7): load a model, its numbers update, create a key and call
/v1 with it, revoke it, stop the model, all through the console's own buttons, each step read back from the daemon.

    pixi run python scripts/console_live.py            # GTK; prints one LIVE-FACT line per step and a JSON summary

The daemon is the one scripts/console_record.py starts (`console_record.py --daemon PORT`: mxconsole's create_app and
Supervisor under mxstudio's own Python, tests/mxconsole/fake_max.py as `max serve`), with no seeding: three registered
models, all cold, no keys. Every state dir (HOME, MXC_HOME, HF_HOME, TMPDIR, XDG_*) is a fresh temp folder, removed at
the end: ~/.mxc and the real home are never touched (daemon_main asserts it), nothing is written in ~/Projects/mxstudio.

The console runs on GTK with MOJOUI_TEST steps (taps by text, as M5 and M6 drive it) and MOJOUI_LIVE_REPORT, so this
script reads the screen mid-run (SIGUSR1: the host prints its LABEL:/BUTTON:/BOX: lines and "LIVE: reported"). The
steps keep their own time; the script follows them by watching the daemon's admin API, and every fact is a reading of
the daemon (/admin/models, /admin/metrics, /admin/keys, /v1's status code) next to what the screen said:

  load      the model is cold, the console's Start makes the daemon report it ready, the screen shows Stop
  numbers   six chats (an extra key the script makes itself, zz-traffic) raise the daemon's request count for the model;
            within one poll the overview shows that count, which it didn't before
  key       New key, live-bot, Create key: the daemon lists live-bot active; the screen shows its secret once, whose
            prefix is the daemon's
  v1        that secret on GET /v1/models and POST /v1/chat/completions: 200
  revoke    Revoke, Click again to revoke: the daemon lists live-bot revoked (zz-traffic still active), /v1 refuses the
            secret with 401
  stop      back to the model, Stop: the daemon reports the model cold, the screen shows Start

The web isn't driven: drive.web_run reads the page only at the end of its steps, and the key's secret has to be read
mid-run (D-403).
"""

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import console_record  # noqa: E402  (the daemon, its fakes, call() and chat())

MODEL = "qwen2.5-0.5b"
KEY_APP = "live-bot"
TRAFFIC_APP = "zz-traffic"  # (sorts after live-bot: the Keys table's first Revoke is live-bot's)
CHATS = 6
EXE = ROOT / "build" / "console" / "linux" / "console"
# The console's own taps, by the words on its buttons. Each pause is the time this script needs for that step.
STEPS = ";".join([
    "pause:2500", f"tap:{MODEL}", "pause:1200", "tap:Start", "pause:30000",  # load, then the numbers (one poll after the chats)
    "tap:Keys", "pause:1500", "tap:New key", "pause:500", f"type:App name, e.g. my-app={KEY_APP}", "tap:Create key", "pause:12000",
    "tap:Revoke@0", "pause:400", "tap:Click again to revoke", "pause:10000",
    "tap:omxconsole", "pause:1500", f"tap:{MODEL}", "pause:1500", "tap:Stop", "pause:12000",
])


def daemon_env(tmp, port):
    env = {"PATH": os.environ["PATH"], "LANG": "C.UTF-8", "REAL_HOME": str(Path.home()), "MXSTUDIO_DIR": str(console_record.MXSTUDIO),
           "HOME": str(tmp / "home"), "MXC_HOME": str(tmp / "mxc"), "HF_HOME": str(tmp / "hf"), "TMPDIR": str(tmp / "tmp"),
           "XDG_DATA_HOME": str(tmp / "xdg-data"), "XDG_CONFIG_HOME": str(tmp / "xdg-config"), "XDG_CACHE_HOME": str(tmp / "xdg-cache"),
           "PYTHONDONTWRITEBYTECODE": "1", "MXC_PORT": str(port), "MXC_FAKE_HUB": str(console_record.FAKES / "fake_hub.py"),
           "FAKE_MAX_TOKENS_OUT": "48", "FAKE_MAX_CHUNK_DELAY": "0.006", "FAKE_MAX_TTFT_DELAY": "0.04", "FAKE_MAX_USAGE": "1",
           "FAKE_MAX_DELAY": "1.5"}
    for d in ("home", "mxc", "hf", "tmp", "xdg-data", "xdg-config", "xdg-cache"):
        (tmp / d).mkdir()
    return env


def status_of(base, method, path, key, body=None):
    req = urllib.request.Request(base + path, method=method, headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            r.read()
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def admin(base, path):
    return console_record.call(base, "GET", path)


def model_state(base):
    return next((m["state"] for m in admin(base, "/admin/models") if m["name"] == MODEL), None)


def key_status(base, app):
    return next((k["status"] for k in admin(base, "/admin/keys") if k["app"] == app), None)


def key_prefix(base, app):
    return next((k["prefix"] for k in admin(base, "/admin/keys") if k["app"] == app), None)


def requests_for(base):
    return admin(base, "/admin/metrics").get("by_model", {}).get(MODEL, {}).get("requests", 0)


def wait_for(fn, want, deadline_s):
    end = time.monotonic() + deadline_s
    got = fn()
    while got != want and time.monotonic() < end:
        time.sleep(0.25)
        got = fn()
    return got


class Screen:
    """The GTK console's own report, asked for mid-run (SIGUSR1) and read from its log."""

    def __init__(self, app, log_path):
        self.app, self.log_path = app, log_path

    def report(self):
        before = self.log_path.read_text(errors="replace")
        self.app.send_signal(signal.SIGUSR1)
        end = time.monotonic() + 10
        while time.monotonic() < end:
            now = self.log_path.read_text(errors="replace")
            if now.count("LIVE: reported") > before.count("LIVE: reported"):
                return now[len(before):]
            time.sleep(0.1)
        return ""


def texts(out):
    got = set()
    for l in out.splitlines():
        for head in ("LABEL: ", "BUTTON: "):
            if l.startswith(head):
                got.add(l[len(head):].replace(" ", " ").strip())
    return got


def run():
    """[(fact, ok, detail)], the daemon's and the app's logs' tails."""
    facts = []

    def fact(name, ok, detail):
        facts.append((name, bool(ok), detail))
        print(f"LIVE-FACT: {name} {'ok' if ok else 'FAIL'} {detail}", flush=True)

    if not EXE.exists():
        return [("build", False, f"no {EXE.relative_to(ROOT)} (scripts/build.sh console linux)")], ""
    if not console_record.PY.exists():
        return [("daemon", False, f"no mxstudio Python at {console_record.PY} (MXSTUDIO_PYTHON)")], ""
    tmp = Path(tempfile.mkdtemp(prefix="mxc-console-live-"))
    port = console_record.free_port()
    base = f"http://127.0.0.1:{port}"
    daemon = subprocess.Popen([str(console_record.PY), str(ROOT / "scripts" / "console_record.py"), "--daemon", str(port)], cwd=tmp,
                              env=daemon_env(tmp, port), stdout=open(tmp / "daemon.log", "w"), stderr=subprocess.STDOUT)
    app = None
    app_log = tmp / "app.log"
    try:
        for _ in range(300):
            try:
                urllib.request.urlopen(base + "/health", timeout=1)
                break
            except OSError:
                if daemon.poll() is not None:
                    return [("daemon", False, "the daemon died: " + (tmp / "daemon.log").read_text()[-1500:])], ""
                time.sleep(0.1)
        traffic_key = console_record.call(base, "POST", "/admin/keys", {"app": TRAFFIC_APP})["key"]
        cold = model_state(base)
        import headless
        headless.ensure()
        env = dict(os.environ, MXC_URL=base, MXC_ADMIN_KEY="1", MOJOUI_TEST=STEPS, MOJOUI_LIVE_REPORT="1", MOJOUI_WINDOW="1440x900")
        app = subprocess.Popen([str(EXE)], env=env, stdout=open(app_log, "w"), stderr=subprocess.STDOUT)
        screen = Screen(app, app_log)

        # load: the console's Start (at ~4 s) makes the daemon start it
        ready = wait_for(lambda: model_state(base), "ready", 25)
        time.sleep(1.0)
        a = screen.report()
        fact("load", cold == "cold" and ready == "ready" and "Stop" in texts(a),
             f"daemon: {cold} before, {ready} after Start; the screen offers {'Stop' if 'Stop' in texts(a) else 'no Stop'}")
        # numbers: the daemon's request count rises, the overview follows within one poll (3 s)
        n0 = requests_for(base)
        for _ in range(CHATS):
            console_record.chat(base, traffic_key, model=MODEL)
        n1 = requests_for(base)
        time.sleep(4.0)
        b = screen.report()
        fact("numbers", n1 >= n0 + CHATS and str(n1) in texts(b) and str(n1) not in texts(a),
             f"daemon: {n0} -> {n1} requests for {MODEL}; the screen shows {n1}: {str(n1) in texts(b)} (before: {str(n1) in texts(a)})")
        # key: created through the console, shown once
        live = wait_for(lambda: key_status(base, KEY_APP), "active", 30)
        time.sleep(1.0)
        c = screen.report()
        prefix = key_prefix(base, KEY_APP) or "?"
        shown = [t for t in texts(c) if t.startswith("mst-") and len(t) > 20]
        secret = next((t for t in shown if t.startswith(prefix.rstrip("…."))), None) if prefix != "?" else None
        fact("key", live == "active" and secret is not None,
             f"daemon: {KEY_APP} {live}, prefix {prefix}; the screen shows {len(shown)} full key(s), {'one' if secret else 'none'} with that prefix")
        # v1: the shown secret works
        s_models = status_of(base, "GET", "/v1/models", secret) if secret else None
        s_chat = status_of(base, "POST", "/v1/chat/completions", secret,
                           {"model": MODEL, "max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]}) if secret else None
        fact("v1", s_models == 200 and s_chat == 200, f"/v1/models {s_models}, /v1/chat/completions {s_chat} with {KEY_APP}'s key")
        # revoke: through the console's two taps
        gone = wait_for(lambda: key_status(base, KEY_APP), "revoked", 25)
        other = key_status(base, TRAFFIC_APP)
        s_after = status_of(base, "GET", "/v1/models", secret) if secret else None
        fact("revoke", gone == "revoked" and other == "active" and s_after == 401,
             f"daemon: {KEY_APP} {gone}, {TRAFFIC_APP} {other}; /v1/models with the revoked key {s_after}")
        # stop: back to the model, Stop
        stopped = wait_for(lambda: model_state(base), "cold", 30)
        time.sleep(1.5)
        d = screen.report()
        fact("stop", stopped == "cold" and "Start" in texts(d),
             f"daemon: {MODEL} {stopped} after Stop; the screen offers {'Start' if 'Start' in texts(d) else 'no Start'}")
        try:
            app.wait(timeout=60)
        except subprocess.TimeoutExpired:
            pass
        out = app_log.read_text(errors="replace")
        if "TEST: " in out:  # a step the host couldn't do (a button not on screen)
            fact("steps", False, "; ".join(l for l in out.splitlines() if l.startswith("TEST: "))[:400])
        return facts, out[-1500:]
    finally:
        if app and app.poll() is None:
            app.kill()
        daemon.terminate()
        try:
            daemon.wait(timeout=15)
        except subprocess.TimeoutExpired:
            daemon.kill()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    facts, tail = run()
    print("LIVE-SUMMARY: " + json.dumps([{"fact": f, "ok": ok, "detail": d} for f, ok, d in facts]))
    if not all(ok for _, ok, _ in facts):
        print(tail)
    sys.exit(0 if facts and all(ok for _, ok, _ in facts) else 1)
