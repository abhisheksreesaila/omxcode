"""Milestone checker for docs/goals/45-GOAL.md (goal 45: Keeper, still working when the window is closed). PASS/FAIL per milestone.

Run: pixi run python docs/goals/45-check.py        (a subset: … 45-check.py M0 M2)
Written before the work (2026-10-30), from the goal's words; never edited to make a milestone pass (add, don't weaken).

Ground rules this checker keeps:
- Every folder it writes is a fresh temp dir (removed at exit); the owner's files are never touched.
- Every D-Bus step runs inside `dbus-run-session` (this script re-runs itself there with --inner), on a private session
  bus; it refuses to run if that bus is the owner's. The owner's tray and notifications are never reached.
- GTK runs are headless (scripts/headless.py).
- Lags are computed here, on one clock (CLOCK_MONOTONIC: Python's time.monotonic_ns is the same clock as Mojo's
  clock_gettime(CLOCK_MONOTONIC)): the time this script closed (renamed, deleted) a file → the `at=<ns>` the Mojo code
  printed when its event arrived. The `ms=` the code prints must agree, but is never what's judged.

Names this checker fixes where the goal leaves them open (the goal's words, made exact):
- M0: `tests/test_watch.mojo` prints `WATCH READY` once watching, `WATCH THREAD: reader=<tid> main=<tid>` (different:
  inotify read on its own thread), and per change `WATCH EVENT: <kind> <path> ms=<lag> at=<monotonic ns>`, kind one of
  create / modify / rename / delete; a rename's path is the new name; paths absolute or relative to $MOJOUI_WATCH_DIR.
- M1: a small framework check app, `examples/traycheck` (scripts/build.sh traycheck linux): it asks for background mode
  unless TRAYCHECK_BACKGROUND=0, and when its window closes it sends a notification whose text includes $TRAYCHECK_TEXT.
  The host prints `WINDOW: open` when the window opens again; a new generic step `waitopen:N` waits up to N ms for that.
- M2: Keeper's index is an FTS5 table `files_fts` with a `path` column (paths absolute or relative to $KEEPER_DIR).
  Keeper prints `KEEPER SCAN: start`, `KEEPER SCAN: done <n> files in <ms> ms`, `KEEPER INDEXED: <path> ms=<lag>
  at=<monotonic ns>`, and `KEEPER SEARCH: q=<q> results=<n>`.
- M3: web.json's shape is in m3()'s docstring.
"""

import atexit
import json
import os
import random
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())
sys.path.insert(0, str(ROOT / "scripts"))
DATA = ROOT / "docs" / "goals" / "45"
TMP = Path(tempfile.mkdtemp(prefix="g45-"))
atexit.register(shutil.rmtree, TMP, True)
NATIVE = {}  # what M0–M2 measured in this process (M3 races the web against these, never against printed numbers)


def run(cmd, timeout=3600, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=env)


def p95(xs):
    xs = sorted(xs)
    return xs[int(0.95 * (len(xs) - 1))] if xs else float("inf")


_BUILT = {}


def build(app, target):
    if (app, target) not in _BUILT:
        r = run(["scripts/build.sh", app, target], 3600)
        _BUILT[(app, target)] = (r.returncode == 0, (r.stdout + r.stderr)[-400:])
    return _BUILT[(app, target)]


class Proc:
    """A process whose output lines are collected as they arrive (in its own session, so it can be stopped whole)."""

    def __init__(self, cmd, env):
        self.p = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
                                  start_new_session=True, bufsize=1)
        self.lines = []
        self.t = threading.Thread(target=self._read, daemon=True)
        self.t.start()

    def _read(self):
        for line in self.p.stdout:
            self.lines.append(line.rstrip("\n"))

    def text(self):
        return "\n".join(self.lines)

    def wait_for(self, pattern, timeout, start=0):
        """Index of the first line from `start` on matching pattern, or -1 after timeout (or if the process ended)."""
        rx = re.compile(pattern)
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            for i in range(start, len(self.lines)):
                if rx.search(self.lines[i]):
                    return i
            if self.p.poll() is not None:
                time.sleep(0.2)
                for i in range(start, len(self.lines)):
                    if rx.search(self.lines[i]):
                        return i
                return -1
            time.sleep(0.02)
        return -1

    def alive(self):
        return self.p.poll() is None

    def stop(self):
        if self.p.poll() is None:
            try:
                os.killpg(self.p.pid, signal.SIGTERM)
                self.p.wait(timeout=10)
            except (subprocess.TimeoutExpired, ProcessLookupError):
                with_kill = getattr(os, "killpg")
                try:
                    with_kill(self.p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.t.join(timeout=5)


def rel(path, base):
    path, base = str(path), str(base).rstrip("/")
    return path[len(base) + 1:] if path.startswith(base + "/") else path


# --------------------------------------------------------------------------------------------------------------- M0

EVENT = re.compile(r"^WATCH EVENT: (\w+) (\S+) ms=([\d.]+) at=(\d+)(?: got=(\d+))?\s*$")  # (got=: addition, D-1625)


def m0():
    if not (ROOT / "tests/test_watch.mojo").exists() or not (ROOT / "mojoui/watch.mojo").exists():
        return False, "mojoui/watch.mojo or tests/test_watch.mojo missing"
    d = TMP / "m0"
    d.mkdir()
    p = Proc(["pixi", "run", "mojo", "run", "-I", ".", "tests/test_watch.mojo"], dict(os.environ, MOJOUI_WATCH_DIR=str(d)))
    try:
        if p.wait_for(r"^WATCH READY", 900) < 0:
            return False, f"no WATCH READY: {p.text()[-400:]}"
        time.sleep(0.3)
        done = {}  # (kind, rel path) -> (op start ns, close ns)
        last_call = {}  # (addition, D-1623) (kind, rel path) -> when the close()/rename()/remove() that makes the event began
        rng = random.Random(45)

        def op(kind, path, fn):
            t0 = time.monotonic_ns()
            last_call[(kind, path)] = t0
            fn((kind, path))
            done[(kind, path)] = (t0, time.monotonic_ns())
            time.sleep(0.002)

        def write(path, text, mode="w"):
            def f(key):
                fh = open(d / path, mode)
                fh.write(text)
                fh.flush()
                last_call[key] = time.monotonic_ns()
                fh.close()
            return f

        folders = [f"d{i}/n{i}" for i in range(10)]
        for f in folders:  # 400 creates, in brand-new nested subfolders made while it runs
            (d / f).mkdir(parents=True)
            for j in range(40):
                op("create", f"{f}/f{j}.txt", write(f"{f}/f{j}.txt", f"file {j} in {f} {rng.random()}\n"))
        for f in folders:  # 200 modifies
            for j in range(20):
                op("modify", f"{f}/f{j}.txt", write(f"{f}/f{j}.txt", "one more line\n", "a"))
        for f in folders:  # 200 renames
            for j in range(20, 40):
                op("rename", f"{f}/g{j}.txt", lambda key, f=f, j=j: os.rename(d / f"{f}/f{j}.txt", d / f"{f}/g{j}.txt"))
        for f in folders:  # 200 deletes
            for j in range(20):
                op("delete", f"{f}/f{j}.txt", lambda key, f=f, j=j: os.remove(d / f"{f}/f{j}.txt"))
        time.sleep(3)
    finally:
        p.stop()
    out = p.text()
    if len(done) != 1000:
        return False, f"the checker made {len(done)} changes, not 1000"
    th = re.search(r"^WATCH THREAD: reader=(\d+) main=(\d+)", out, re.M)
    if not th or th.group(1) == th.group(2):
        return False, f"no WATCH THREAD line with the reader on its own thread ({th.group(0) if th else 'none'})"
    dirs = {"d%d" % i for i in range(10)} | set(folders)
    events = []
    for line in out.splitlines():
        m = EVENT.match(line)
        if m and rel(m.group(2), d) not in dirs:
            events.append((m.group(1), rel(m.group(2), d), float(m.group(3)), int(m.group(4)), int(m.group(5) or 0)))
    seen = {}
    for kind, path, ms, at, got in events:
        seen.setdefault((kind, path), []).append((ms, at, got))
    missing = [k for k in done if k not in seen]
    twice = [k for k, v in seen.items() if k in done and len(v) > 1]
    extra = [k for k in seen if k not in done]
    if missing or twice or extra:
        return False, (f"{len(events)} events for 1000 changes: {len(missing)} missing (e.g. {missing[:3]}), "
                       f"{len(twice)} reported twice (e.g. {twice[:3]}), {len(extra)} unexpected (e.g. {extra[:3]})")
    lags, disagree, early = [], 0, 0
    during, before_call, bounds, worst = [], 0, [], 0.0  # (addition, D-1623)
    delivered = []  # (addition, D-1625) close → the consumer's thread has the event (after the pipe), what the web race uses
    for k, (t0, closed) in done.items():
        ms, at, got = seen[k][0]
        if got < at:
            return False, f"{k}: got= missing or before at= (the consumer's stamp must follow the reader's)"
        delivered.append(max(0, got - closed) / 1e6)
        if at < t0:
            early += 1
        if at < last_call[k]:
            before_call += 1
        if at < closed:
            during.append((closed - at) / 1e6)  # stamped inside the close()/rename()/remove() call: flagged, not hidden
        bounds.append((at - last_call[k]) / 1e6)  # the lag measured from the call's start: never below the real one
        lag = max(0, at - closed) / 1e6
        lags.append(lag)
        worst = max(worst, abs(ms - lag))
        if abs(ms - lag) > 2:
            disagree += 1
    if early:
        return False, f"{early} events stamped before their change began: the at= clock isn't CLOCK_MONOTONIC"
    if before_call:
        return False, f"{before_call} events stamped before the close()/rename()/remove() that makes them began"
    if disagree > 3:  # (tightened from 10, D-1623: the final runs had 0; 2 ms stays, the test's ctime clock is coarse)
        return False, f"{disagree} events print an ms= that disagrees with the measured lag by > 2 ms (3 allowed)"
    if p95(bounds) > 50:
        return False, f"p95 lag measured from the start of each change's last call {p95(bounds):.1f} ms (≤ 50)"
    q = p95(lags)
    NATIVE["watch_p95_ms"] = max(q, p95(delivered))  # (D-1625: the race takes the later of the two stamps)
    if q > 50:
        return False, f"p95 lag {q:.1f} ms (≤ 50)"
    return True, (f"1000 changes (400 creates in 10 new nested folders, 200 modifies, 200 renames, 200 deletes): each reported once, p95 lag "
                  f"{q:.2f} ms (max {max(lags):.1f}); {len(during)} stamped during their own close/rename/remove call (up to "
                  f"{max(during, default=0):.2f} ms before it returned; none before it began); from each call's start p95 {p95(bounds):.2f} ms; "
                  f"ms= within 2 ms on {1000 - disagree}/1000 (worst {worst:.2f}); delivered to the consumer's thread p95 {p95(delivered):.3f} ms; reader thread {th.group(1)} ≠ main {th.group(2)}")


# ------------------------------------------------------------------------------------------------ private bus helpers

# (addition, D-1606: the system's session config lets the private bus start the desktop's services on demand: GTK asks
# for the portal, xdg-desktop-portal started and reached the owner's Wayland display. The private bus now has no
# service directories at all, and runs without the owner's display variables, so nothing on it can start or reach
# anything of the owner's)
BUS_CONFIG = """<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><auth>EXTERNAL</auth>
<policy context="default"><allow send_destination="*" eavesdrop="true"/><allow eavesdrop="true"/><allow own="*"/></policy>
</busconfig>"""


def bus_run(name):
    """Runs milestone `name`'s bus part inside a fresh `dbus-run-session`, returning (ok, msg)."""
    conf = TMP / "bus.conf"
    conf.write_text(BUS_CONFIG)
    env = {k: v for k, v in os.environ.items() if k not in ("WAYLAND_DISPLAY", "DISPLAY", "XDG_SESSION_TYPE")}
    r = run(["dbus-run-session", f"--config-file={conf}", "--", sys.executable, str(Path(__file__).resolve()), "--inner", name,
             "--owner-bus", os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")], 3600, env=env)
    if "Activating service" in r.stdout + r.stderr:
        return False, "a service was started on the private bus (it must have none)"
    m = re.search(r"INNER RESULT (\{.*\})$", r.stdout, re.M)
    if not m:
        return False, f"the private-bus run gave no result (exit {r.returncode}): {(r.stdout + r.stderr)[-500:]}"
    res = json.loads(m.group(1))
    NATIVE.update(res.get("native", {}))
    return res["ok"], res["msg"]


def private_bus_or_die(owner):
    mine = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
    if not mine or mine == owner:
        raise RuntimeError("not on a private session bus: refusing to touch the owner's")


class Monitor:
    """dbus-monitor on the private bus, watching Notify calls."""

    def __init__(self):
        self.p = Proc(["dbus-monitor", "--session", "interface='org.freedesktop.Notifications'"], dict(os.environ))
        time.sleep(0.5)

    def notify_calls(self):
        """Each Notify method call's string arguments, joined."""
        calls, cur = [], None
        for line in self.p.lines:
            if line.startswith("method call") and "member=Notify" in line:
                cur = []
                calls.append(cur)
            elif line.startswith(("method call", "signal", "method return", "error")):
                cur = None
            elif cur is not None:
                m = re.match(r'\s*string "(.*)"$', line)
                if m:
                    cur.append(m.group(1))
        return [" ".join(c) for c in calls]

    def stop(self):
        self.p.stop()


# (addition, D-1618: background mode now hides the window only while a panel's StatusNotifierWatcher has taken the tray
# item, so a closed window can't strand the app. The private bus has no panel; this plays one: it owns
# org.kde.StatusNotifierWatcher and prints each RegisterStatusNotifierItem. System Python's GObject bindings, run as a
# separate process on the private bus only)
FAKE_WATCHER = r"""
import sys
from gi.repository import Gio, GLib
XML = '<node><interface name="org.kde.StatusNotifierWatcher"><method name="RegisterStatusNotifierItem"><arg name="service" type="s" direction="in"/></method></interface></node>'
def call(conn, sender, path, iface, method, params, inv):
    print('REGISTERED ' + params.unpack()[0], flush=True)
    inv.return_value(None)
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
bus.register_object('/StatusNotifierWatcher', Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], call, None, None)
Gio.bus_own_name_on_connection(bus, 'org.kde.StatusNotifierWatcher', 0, lambda *a: print('WATCHER UP', flush=True), lambda *a: print('WATCHER LOST', flush=True))
GLib.MainLoop().run()
"""


class FakeWatcher:
    def __init__(self):
        self.p = Proc(["/usr/bin/python3", "-I", "-c", FAKE_WATCHER], dict(os.environ))
        if self.p.wait_for(r"^WATCHER UP", 20) < 0:
            raise RuntimeError(f"the pretend panel didn't start: {self.p.text()[-300:]}")

    def registered(self, name, timeout=10):
        return self.p.wait_for(r"^REGISTERED " + re.escape(name) + r"$", timeout) >= 0

    def stop(self):
        self.p.stop()


def menu_click(name, item):
    """(addition, D-1618) the tray menu's item clicked as a panel does (com.canonical.dbusmenu Event)."""
    return gdbus("--dest", name, "--object-path", "/MenuBar", "--method", "com.canonical.dbusmenu.Event", str(item), "clicked", "<0>", "0")


def gdbus(*args):
    return run(["gdbus", "call", "--session", *args], 30)


def sni_name(pid):
    names = gdbus("--dest", "org.freedesktop.DBus", "--object-path", "/org/freedesktop/DBus", "--method", "org.freedesktop.DBus.ListNames").stdout
    want = f"org.kde.StatusNotifierItem-{pid}-1"
    return want if f"'{want}'" in names else None


def activate(name):
    return gdbus("--dest", name, "--object-path", "/StatusNotifierItem", "--method", "org.kde.StatusNotifierItem.Activate", "0", "0")


# --------------------------------------------------------------------------------------------------------------- M1

def m1_inner():
    import headless
    headless.ensure()
    exe = ROOT / "build" / "traycheck" / "linux" / "traycheck"
    token = "keepme%06d" % random.Random().randrange(10**6)
    mon = Monitor()
    try:
        # without background mode, closing the window still ends the app (nothing changed for apps that don't ask)
        p = Proc([str(exe)], dict(os.environ, MOJOUI_TEST="pause:300;quit", TRAYCHECK_BACKGROUND="0", TRAYCHECK_TEXT=token))
        try:
            p.p.wait(timeout=60)
        except subprocess.TimeoutExpired:
            p.stop()
            return False, "with TRAYCHECK_BACKGROUND=0 the app didn't exit after its window closed"
        # (addition, D-1618) background mode with no panel on the bus: closing must end the app, not strand it hidden
        p = Proc([str(exe)], dict(os.environ, MOJOUI_TEST="pause:300;quit;waitopen:5000", TRAYCHECK_TEXT=token))
        try:
            p.p.wait(timeout=60)
        except subprocess.TimeoutExpired:
            p.stop()
            return False, "background mode with no panel (no StatusNotifierWatcher): closing the window left the app running hidden"
        if "no tray to come back from" not in p.text():
            return False, f"background mode with no panel: the app ended without saying why: {p.text()[-300:]}"
        panel = FakeWatcher()
        p = Proc([str(exe)], dict(os.environ, MOJOUI_TEST="pause:300;quit;waitopen:30000;pause:300;quit;waitopen:30000;pause:30000", TRAYCHECK_TEXT=token))
        try:
            if not panel.registered(f"org.kde.StatusNotifierItem-{p.p.pid}-1", 60):
                return False, f"the tray item never registered with the panel's watcher: {panel.p.text()[-300:]}"
            if p.wait_for(r"^QUIT: window closed", 60) < 0:
                return False, f"the quit step didn't close the window: {p.text()[-300:]}"
            time.sleep(1.5)
            if not p.alive():
                return False, f"the process ended when its window closed (background mode): {p.text()[-300:]}"
            name = sni_name(p.p.pid)
            if not name:
                return False, f"no org.kde.StatusNotifierItem-{p.p.pid}-1 on the bus"
            intro = run(["gdbus", "introspect", "--session", "--dest", name, "--object-path", "/StatusNotifierItem"], 30).stdout
            if "org.kde.StatusNotifierItem" not in intro or "Activate" not in intro:
                return False, f"{name} has no org.kde.StatusNotifierItem.Activate at /StatusNotifierItem"
            mark = len(p.lines)
            r = activate(name)
            if r.returncode != 0:
                return False, f"Activate failed: {r.stderr.strip()}"
            if p.wait_for(r"^WINDOW: open", 20, mark) < 0:
                return False, f"Activate didn't open the window again: {p.text()[-300:]}"
            time.sleep(0.5)
            calls = [c for c in mon.notify_calls() if token in c]
            if not calls:
                return False, f"no Notify call with the app's text ({token}) on the bus; calls seen: {mon.notify_calls()[:3]}"
            # (addition, D-1618) closed again, then launched a second time: the running one opens, no second instance
            if p.wait_for(r"^QUIT: window closed", 30, mark) < 0:
                return False, f"the second quit step didn't hide the window: {p.text()[-300:]}"
            time.sleep(0.5)
            mark = len(p.lines)
            again = Proc([str(exe)], dict(os.environ, TRAYCHECK_TEXT=token))
            try:
                again.p.wait(timeout=60)
            except subprocess.TimeoutExpired:
                again.stop()
                return False, "a second launch kept running beside the first (background apps are one instance)"
            if p.wait_for(r"^WINDOW: open", 20, mark) < 0:
                return False, f"a second launch didn't open the running app's window: {again.text()[-300:]}"
            # (addition, D-1618) the tray menu's Quit ends it, no kill needed
            r = menu_click(name, 3)
            if r.returncode != 0:
                return False, f"the tray menu's Quit failed: {r.stderr.strip()}"
            try:
                p.p.wait(timeout=20)
            except subprocess.TimeoutExpired:
                return False, "the tray menu's Quit didn't end the app"
            if p.wait_for(r"^WINDOW: quit from the tray", 5) < 0:
                return False, f"the app ended, but not through the menu's Quit: {p.text()[-300:]}"
        finally:
            p.stop()
            panel.stop()
    finally:
        mon.stop()
    return True, (f"window closed, process kept running; {name} on a private bus, registered with a pretend panel; Activate reopened the "
                  f"window; Notify carried {calls[0][:80]!r}; a second launch opened the running one; the tray menu's Quit ended it; "
                  f"with no panel, or without background mode, closing ends the app")


def m1():
    ok, why = build("traycheck", "linux")
    if not ok:
        return False, "traycheck linux build failed: " + why
    return bus_run("m1")


# --------------------------------------------------------------------------------------------------------------- M2

VOCAB = ("river stone maple lantern orbit copper meadow signal harbor velvet quartz ember willow cobalt summit "
         "pepper canyon falcon juniper marble nectar osprey pixel quiver saffron tundra umber vortex walnut yonder").split()


def make_corpus(root, n=100_000, per=100):
    """n text/Markdown files (each with its own word tok<i>), per folder; and 1,000 binary files Keeper must skip."""
    rng = random.Random(4500)
    for i in range(n):
        folder = root / f"s{i // per:04d}"
        if i % per == 0:
            folder.mkdir(parents=True)
        ext = ".md" if i % 2 else ".txt"
        words = " ".join(rng.choice(VOCAB) for _ in range(12))
        (folder / f"n{i}{ext}").write_text(f"# note {i}\n{words} tok{i}\n")
    for i in range(1000):
        (root / f"s{i:04d}" / f"blob{i}.bin").write_bytes(b"\x00\x01binskip" + bytes([i % 256]) * 64)


def fts_paths(db, query, base):
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=10)
    try:
        return {rel(r[0], base) for r in con.execute("SELECT path FROM files_fts WHERE files_fts MATCH ?", (query,))}
    finally:
        con.close()


def m2_inner():
    import headless
    headless.ensure()
    exe = ROOT / "build" / "keeper" / "linux" / "keeper"
    kdir, db = TMP / "keeper", TMP / "keeper.db"
    t = time.monotonic()
    make_corpus(kdir)
    made_s = time.monotonic() - t
    native = {}
    # (a) the first scan of 100,000 files, as a job, with the window painting
    p = Proc([str(exe)], dict(os.environ, KEEPER_DIR=str(kdir), KEEPER_DB=str(db), MOJOUI_TEST="gaps:start;gaps:40000"))
    try:
        p.p.wait(timeout=600)
    except subprocess.TimeoutExpired:
        p.stop()
        return False, "(a) the scan run didn't end", native
    p.t.join(5)
    out = p.text()
    gap = re.search(r"GAPS: (\d+) frames, longest ([\d.]+) ms", out)
    done = re.search(r"KEEPER SCAN: done (\d+) files in (\d+) ms", out)
    starts = [out.find("GAPS: start"), out.find("KEEPER SCAN: start")]
    if p.p.returncode != 0 or not gap or not done or min(starts) < 0:
        return False, f"(a) exit {p.p.returncode}; GAPS {bool(gap)}; scan done {bool(done)}; starts {starts}: {out[-400:]}", native
    if not (starts[0] < starts[1] and done.start() < gap.start()):
        return False, "(a) the scan wasn't inside the measured window (GAPS: start → scan start → scan done → GAPS line)", native
    frames, longest, n, scan_ms = int(gap.group(1)), float(gap.group(2)), int(done.group(1)), int(done.group(2))
    if n != 100_000:
        return False, f"(a) the scan reports {n} files, want 100000 (the 1,000 .bin files skipped)", native
    if scan_ms < 200:
        return False, f"(a) the scan took {scan_ms} ms (< 200: too short to show a freeze)", native
    if frames < 20 or longest > 100:
        return False, f"(a) while scanning: {frames} frames, longest gap {longest} ms (≥ 20 frames, ≤ 100 ms)", native
    con = sqlite3.connect(db)
    total = con.execute("SELECT count(*) FROM files_fts").fetchone()[0]
    con.close()
    if total != 100_000:
        return False, f"(a) files_fts holds {total} rows, want 100000", native
    rng = random.Random(7)
    sample = rng.sample(range(100_000), 300)
    wrong = [i for i in sample if fts_paths(db, f"tok{i}", kdir) != {f"s{i // 100:04d}/n{i}{'.md' if i % 2 else '.txt'}"}]
    if wrong or fts_paths(db, "binskip", kdir):
        return False, f"(a) FTS5 doesn't find files by their word (e.g. tok{wrong[:3]}) or indexed a .bin file", native
    native["scan_ms"] = scan_ms
    native["scan_files"] = n
    scanned = n  # (n is reused for the search below: the summary names the scan's count, D-1610)
    # (b) window closed, background mode: 200 new files, indexed and searchable; alerts on the bus
    alert = "zebra%04d" % random.Random().randrange(10**4)
    shot = DATA / "keeper-gtk.png"
    shot.parent.mkdir(parents=True, exist_ok=True)
    if shot.exists():
        shot.unlink()
    mon = Monitor()
    panel = FakeWatcher()  # (addition, D-1618: a panel to come back from, or closing the window ends Keeper)
    p = Proc([str(exe)], dict(os.environ, KEEPER_DIR=str(kdir), KEEPER_DB=str(db), KEEPER_ALERT=alert, MOJOUI_SHOT=str(shot),
                              MOJOUI_TEST="pause:500;quit;waitopen:120000;type:Search=nightjar;pause:800"))
    try:
        if p.wait_for(r"^QUIT: window closed", 120) < 0:
            return False, f"(b) the window didn't close: {p.text()[-300:]}", native
        if p.wait_for(r"^KEEPER SCAN: done", 300) < 0:
            return False, f"(b) the relaunch's scan never finished: {p.text()[-300:]}", native
        time.sleep(1.0)
        if not p.alive():
            return False, f"(b) the process ended with its window closed: {p.text()[-300:]}", native
        (kdir / "fresh").mkdir()  # a new subfolder, made while closed
        # (addition, D-1621) searchable, seen from outside: Python's sqlite3 polls the index while the files are written
        # and stamps when each first matches; that lag is judged too, not only the at= Keeper prints
        outside, polling = {}, [True]

        def poll_index():
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=10)
            try:
                while polling[0]:
                    for (path,) in con.execute("SELECT path FROM files_fts WHERE files_fts MATCH 'nightjar'"):
                        outside.setdefault(rel(path, kdir), time.monotonic_ns())
                    time.sleep(0.002)
            finally:
                con.close()
        poller = threading.Thread(target=poll_index, daemon=True)
        poller.start()
        new, closed_at = {}, {}
        for i in range(200):
            path = f"fresh/new{i}.md" if i % 2 else f"s0000/new{i}.txt"
            words = " ".join(VOCAB[(i + k) % len(VOCAB)] for k in range(6))
            body = f"kept while closed nightjar fresh{i} {words}" + (f" {alert}" if i % 10 == 0 else "") + "\n"
            with open(kdir / path, "w") as fh:
                fh.write(body)
            closed_at[path] = time.monotonic_ns()
            new[path] = i
            time.sleep(0.02)
        mark_paths = set(new)
        end = time.monotonic() + 30
        got = {}
        while time.monotonic() < end and len(got) < 200:
            for line in p.lines:
                m = re.match(r"^KEEPER INDEXED: (\S+) ms=([\d.]+) at=(\d+)", line)
                if m and rel(m.group(1), kdir) in mark_paths:
                    got.setdefault(rel(m.group(1), kdir), []).append((float(m.group(2)), int(m.group(3))))
            time.sleep(0.2)
        time.sleep(0.5)
        polling[0] = False
        poller.join(5)
        if len(got) < 200:
            return False, f"(b) {len(got)}/200 files printed KEEPER INDEXED (missing e.g. {sorted(mark_paths - set(got))[:3]})", native
        # (addition, D-1621) each file indexed exactly once (the loop above re-reads every line on each pass: count afresh)
        once = {}
        for line in list(p.lines):
            m = re.match(r"^KEEPER INDEXED: (\S+) ms=", line)
            if m and rel(m.group(1), kdir) in mark_paths:
                once[rel(m.group(1), kdir)] = once.get(rel(m.group(1), kdir), 0) + 1
        twice = [k for k, c in once.items() if c != 1]
        if twice:
            return False, f"(b) {len(twice)} files printed KEEPER INDEXED more than once (e.g. {twice[:3]})", native
        if len(outside) < 200:
            return False, f"(b) Python's sqlite3, polling, saw {len(outside)}/200 new files become searchable", native
        out_lags = [max(0, outside[k] - closed_at[k]) / 1e6 for k in new]
        out_q = p95(out_lags)
        if out_q > 100:
            return False, f"(b) file closed → searchable as Python's sqlite3 sees it, p95 {out_q:.1f} ms (≤ 100)", native
        if not p.alive():
            return False, "(b) the process ended while indexing in the background", native
        lags = [max(0, got[k][0][1] - closed_at[k]) / 1e6 for k in new]
        q = p95(lags)
        if q > 100:
            return False, f"(b) file closed → searchable p95 {q:.1f} ms (≤ 100)", native
        unfound = [k for k, i in new.items() if fts_paths(db, f"fresh{i}", kdir) != {k}]
        if unfound:
            return False, f"(b) Python's sqlite3 doesn't find {len(unfound)} of the new files by their word (e.g. {unfound[:3]})", native
        native["index_p95_ms"] = q
        calls = mon.notify_calls()
        alerts = [k for k, i in new.items() if i % 10 == 0]
        unalerted = [k for k in alerts if not any(Path(k).name in c for c in calls)]
        false = [k for k, i in new.items() if i % 10 and any(re.search(re.escape(Path(k).name) + r"\b", c) for c in calls)]
        if unalerted or false:
            return False, f"(b) notifications: {len(unalerted)} alert files not named (e.g. {unalerted[:2]}), {len(false)} quiet files named; calls {calls[:2]}", native
        # (addition, D-1621) each alert file named in exactly one notification (a burst may share one)
        named = {k: sum(1 for c in calls if re.search(r"(?<![\w])" + re.escape(Path(k).name) + r"\b", c)) for k in alerts}
        repeated = [k for k, c in named.items() if c != 1]
        if repeated:
            return False, f"(b) alert files named in more than one notification: {[(k, named[k]) for k in repeated[:3]]}", native
        # (addition, D-1621) a reindex that fails keeps its changes: the index is locked past Keeper's 5 s busy wait while a
        # file is written; Keeper must say it's retrying, then index the file once the lock goes
        (kdir / "held").mkdir()
        mark = len(p.lines)
        lock = sqlite3.connect(db, timeout=10, isolation_level=None)
        lock.execute("BEGIN EXCLUSIVE")
        try:
            with open(kdir / "held" / "held0.md", "w") as fh:
                fh.write("written while the index was locked heldword\n")
            retried = p.wait_for(r"^KEEPER RETRY: \d+ changes", 15, mark) >= 0
        finally:
            lock.execute("ROLLBACK")
            lock.close()
        if not retried:
            return False, f"(b) with the index locked, Keeper didn't report a failed reindex (KEEPER RETRY): {p.text()[-300:]}", native
        if p.wait_for(r"^KEEPER INDEXED: \S*held/held0\.md ", 30, mark) < 0 or fts_paths(db, "heldword", kdir) != {"held/held0.md"}:
            return False, f"(b) after the lock went, the file written meanwhile wasn't indexed (its change was lost): {p.text()[-300:]}", native
        # (c) Activate reopens the window; the typed search shows the new files
        name = sni_name(p.p.pid)
        if not name:
            return False, f"(c) no org.kde.StatusNotifierItem-{p.p.pid}-1 on the bus", native
        mark = len(p.lines)
        r = activate(name)
        if r.returncode != 0 or p.wait_for(r"^WINDOW: open", 30, mark) < 0:
            return False, f"(c) Activate didn't reopen the window ({r.stderr.strip()}): {p.text()[-300:]}", native
        i = p.wait_for(r"^KEEPER SEARCH: q=nightjar results=\d+", 30, mark)
        if i < 0:
            return False, f"(c) no KEEPER SEARCH line for the typed query: {p.text()[-300:]}", native
        n = int(re.search(r"results=(\d+)", p.lines[i]).group(1))
        found = fts_paths(db, "nightjar", kdir)
        want = len(found)
        if n != want or want != 200:
            return False, f"(c) the search shows {n} results; Python's FTS5 finds {want} (want 200)", native
        # (addition, D-1621) the results list itself drew them: its first row asked for, and as many rows as sqlite finds
        j = p.wait_for(r"^KEEPER RESULTS: q=nightjar shown=\d+ first=\S+", 30, i)
        if j < 0:
            return False, f"(c) the results list never drew a row for the typed search: {p.text()[-300:]}", native
        rm = re.search(r"shown=(\d+) first=(\S+)", p.lines[j])
        if int(rm.group(1)) != want or rel(rm.group(2), kdir) not in found:
            return False, f"(c) the list shows {rm.group(1)} rows starting {rm.group(2)}; sqlite finds {want}", native
        end = time.monotonic() + 60
        while time.monotonic() < end and p.alive() and not shot.exists():
            time.sleep(0.2)
        time.sleep(1.0)
    finally:
        p.stop()
        mon.stop()
        panel.stop()
    from PIL import Image
    import numpy as np
    if not shot.exists() or np.asarray(Image.open(shot).convert("L"), dtype=float).std() < 2:
        return False, "(c) docs/goals/45/keeper-gtk.png missing or blank", native
    return True, (f"(a) {scanned:,} files scanned in {scan_ms} ms as a job: {frames} frames, longest gap {longest} ms (corpus made in "
                  f"{made_s:.0f} s); (b) window closed: 200 files indexed once each, p95 {q:.1f} ms (Python's sqlite3 polling: p95 {out_q:.1f} ms), "
                  f"all found by sqlite3, {len(alerts)} alert files each named in exactly one notification ({len(calls)} sent); a reindex "
                  f"failed on a locked index, retried and indexed the file; (c) Activate reopened it, the search and its list show {n}"), native


def m2():
    mojo = sorted(p.name for p in (ROOT / "examples" / "keeper").glob("*.mojo")) if (ROOT / "examples/keeper").exists() else []
    if mojo != ["app.mojo"]:
        return False, f"examples/keeper should be one Mojo file (app.mojo), found {mojo}"
    ok, why = build("keeper", "linux")
    if not ok:
        return False, "keeper linux build failed: " + why
    return bus_run("m2")


# --------------------------------------------------------------------------------------------------------------- M3

THINGS = {  # entry → the tries each must report
    "read_folder": ("no_gesture", "cdp_granted"),
    "notice_change": ("FileSystemObserver", "polling"),
    "run_closed": ("background_sync", "periodic_sync", "web_push"),  # (web_push: addition, D-1624)
    "notify_closed": ("web_push",),
    "tray": (),
}
NATIVE_MEASURES = ("watch_p95_ms", "index_p95_ms", "scan_ms")


def has_evidence(e):
    return isinstance(e, (str, dict, list)) and len(e) > 0 and str(e).strip() not in ("", "{}", "[]")


def recomputed(ents):
    """(addition, D-1624) The race numbers worked out again here from web.json's raw stamps, never taken as written:
    each folder read's page-clock t0/t1, each change's [closed, seen] with the clock offset. Returns (problems, notes)."""
    problems, notes = [], []
    rf = ents.get("read_folder", {})
    if rf.get("can"):
        ev = rf.get("tries", {}).get("cdp_granted", {}).get("evidence", {})
        reads = list(ev.get("drop_folder", {}).get("reads", []))
        inp = ev.get("input_webkitdirectory", {}).get("read")
        if inp:
            reads.append(inp)
        full = [r for r in reads if isinstance(r, dict) and r.get("files") == 100_000 and isinstance(r.get("t1"), (int, float))]
        if not any("inflight" in r for r in full):
            problems.append("read_folder: no parallel read among the tries (the web's best way wasn't tried)")
        if full:
            best = min(r["t1"] - r["t0"] for r in full)
            if abs(best - rf.get("race", {}).get("web_ms", -1)) > 0.06:
                problems.append(f"read_folder: race web_ms {rf.get('race', {}).get('web_ms')} isn't the fastest read in the raw stamps ({best:.1f})")
            notes.append(f"read_folder fastest of {len(full)} reads {best:.1f} ms (recomputed)")
        else:
            problems.append("read_folder: the web can, but no read carries raw t0/t1 stamps")
    nc = ents.get("notice_change", {})
    if nc.get("can"):
        tries = nc.get("tries", {})
        runs = []
        fso = tries.get("FileSystemObserver", {})
        fso_rounds = []
        if fso.get("can"):  # (D-1626: three rounds; the race's number is the median of their recomputed p95s)
            for k, r in enumerate(fso["evidence"].get("rounds", [])):
                runs.append((f"FileSystemObserver round {k + 1}", r))
            if not fso["evidence"].get("rounds"):
                problems.append("notice_change: FileSystemObserver has no rounds of raw stamps")
        if tries.get("polling", {}).get("can"):
            runs += [(f"polling every {r.get('every_ms')} ms", r) for r in tries["polling"]["evidence"].get("every_try", [])]
        best = None
        for name, r in runs:
            raw, off = r.get("raw"), r.get("offset_ms")
            if not isinstance(raw, dict) or not isinstance(off, (int, float)):
                problems.append(f"notice_change {name}: no raw stamps")
                continue
            lags = [max(0.0, seen + off - closed) for closed, seen in raw.values() if seen is not None]
            q = round(p95(lags), 3) if lags else None
            if q is None or r.get("p95_ms") is None or abs(q - r["p95_ms"]) > 0.002:
                problems.append(f"notice_change {name}: p95 {r.get('p95_ms')} disagrees with its raw stamps ({q})")
                continue
            if name.startswith("FileSystemObserver"):
                fso_rounds.append(q)
            elif len(lags) == len(raw):
                best = q if best is None else min(best, q)
        if fso_rounds:
            med = sorted(fso_rounds)[len(fso_rounds) // 2]
            if abs(med - fso["evidence"].get("p95_ms", -1)) > 0.002:
                problems.append(f"notice_change: FileSystemObserver p95 {fso['evidence'].get('p95_ms')} isn't the median of its rounds ({med})")
            best = med if best is None else min(best, med)
        if best is not None and abs(best - nc.get("race", {}).get("web_ms", -1)) > 0.002:
            problems.append(f"notice_change: race web_ms {nc.get('race', {}).get('web_ms')} isn't the best recomputed p95 ({best})")
        notes.append(f"notice_change best p95 {best} ms (recomputed)")
    return problems, notes


def m3():
    """web.json: {"commit", "chromium", "entries": {<thing>: {"can", "evidence", "label", "summary", "tries": {<try>: {"can",
    "evidence"}}, "race" (when can): {"native": one of NATIVE_MEASURES, "web_ms": the web's number for the same thing,
    "files" (for scan_ms: how many files the web read)}}}}"""
    for name, fn in (("M0", m0), ("M1", m1), ("M2", m2)):
        if name not in RESULTS:
            RESULTS[name] = fn()
        if not RESULTS[name][0]:
            return False, f"native must do all five first: {name} failed"
    path = DATA / "web.json"
    if not path.exists():
        return False, "docs/goals/45/web.json missing (scripts/keeper_web.py)"
    w = json.loads(path.read_text())
    srcs = ["mojoui/watch.mojo", "scripts/keeper_web.py"]
    stale = run(["git", "diff", "--quiet", w.get("commit", "none"), "HEAD", "--", *srcs]).returncode != 0
    dirty = run(["git", "diff", "--quiet", "HEAD", "--", *srcs]).returncode != 0
    if stale or dirty:
        return False, f"web.json is stale for {srcs}"
    if not w.get("chromium"):
        return False, "web.json doesn't say which Chromium ran"
    ents = w.get("entries", {})
    problems, verdicts = [], []
    for thing, tries in THINGS.items():
        e = ents.get(thing)
        if not isinstance(e, dict) or not isinstance(e.get("can"), bool) or not has_evidence(e.get("evidence")):
            problems.append(f"{thing}: no can/evidence")
            continue
        for t in tries:
            tr = e.get("tries", {}).get(t)
            if not isinstance(tr, dict) or not isinstance(tr.get("can"), bool) or not has_evidence(tr.get("evidence")):
                problems.append(f"{thing}.{t}: not tried with evidence")
        if tries and e["can"] != any(e["tries"].get(t, {}).get("can") is True for t in tries):
            problems.append(f"{thing}: can={e['can']} disagrees with its tries")
        if e["can"]:
            race = e.get("race", {})
            measure, web = race.get("native"), race.get("web_ms")
            if measure not in NATIVE_MEASURES or not isinstance(web, (int, float)) or web <= 0:
                problems.append(f"{thing}: the web can, but there's no race against a native measure")
                continue
            if measure == "scan_ms" and race.get("files") != NATIVE.get("scan_files"):
                problems.append(f"{thing}: the web read {race.get('files')} files, native scanned {NATIVE.get('scan_files')}")
                continue
            mine = NATIVE[measure]
            verdicts.append(f"{thing}: native {mine:.1f} vs web {web:.1f} ms")
            if mine > web / 2:
                problems.append(f"{thing}: native {measure} {mine:.1f} ms isn't ≤ half the web's {web:.1f} ms (a loss)")
        else:
            verdicts.append(f"{thing}: the web can't")
    more, notes = recomputed(ents)
    problems += more
    if problems:
        return False, "; ".join(problems)
    return True, "native does all five; " + "; ".join(verdicts) + "; " + "; ".join(notes)


# --------------------------------------------------------------------------------------------------------------- M4

def shown(page, v):
    return any(re.search(r"(?<![\d.])" + re.escape(s) + r"(?![\d])", page) for s in {f"{v}", f"{v:.1f}", f"{v:,.0f}", f"{v:.0f}"})


def m4():
    problems = []
    page = (ROOT / "docs" / "gallery" / "index.html").read_text()
    if "Works when closed" not in page:
        problems.append("no 'Works when closed' section in the gallery")
    import numpy as np
    from PIL import Image
    img = ROOT / "docs" / "gallery" / "img" / "keeper-gtk.png"
    if "img/keeper-gtk.png" not in page:
        problems.append("the gallery doesn't show img/keeper-gtk.png")
    if not img.exists() or np.asarray(Image.open(img).convert("L"), dtype=float).std() < 2:
        problems.append("img/keeper-gtk.png missing or blank")
    wj = DATA / "web.json"
    if wj.exists():
        for thing, e in json.loads(wj.read_text()).get("entries", {}).items():
            for key in ("label", "summary"):
                if not e.get(key) or e[key] not in page:
                    problems.append(f"the gallery lacks web.json's {thing} {key}")
    else:
        problems.append("docs/goals/45/web.json missing")
    if "Why not just WebGPU?" not in page:
        problems.append("no 'Why not just WebGPU?' note")
    r42 = json.loads((ROOT / "docs/goals/42/race.json").read_text())
    r43 = json.loads((ROOT / "docs/goals/43/race.json").read_text())
    nums = [r42["a"]["search_p95_ms"], r42["b"]["search_p95_ms"], r43["a"]["p95_ms"], r43["b"]["p95_ms"]]
    if (ROOT / "docs/goals/44/race.json").exists():
        if "Recall" not in page:
            problems.append("Recall's race.json is merged but the note doesn't draw on it")
    for v in nums:
        if not shown(page, v):
            problems.append(f"the WebGPU note doesn't show the race number {v}")
    if run(["pixi", "run", "python", "scripts/components.py", "--check"]).returncode != 0:
        problems.append("docs/components.md is stale")
    comps = (ROOT / "docs" / "components.md").read_text()
    for word in ("folder watcher", "background mode", "tray", "notification"):
        if word not in comps.lower():
            problems.append(f"docs/components.md doesn't list {word}")
    for word in ("FSEvents", "NSStatusItem", "UNUserNotificationCenter"):
        if word not in comps:
            problems.append(f"docs/components.md doesn't note the Mac's {word}")
    if "mojoui.watch" not in (ROOT / "docs" / "llms.txt").read_text():
        problems.append("docs/llms.txt doesn't name mojoui.watch")
    top = (ROOT / "EXPERIMENTS.md").read_text().split("\n## ", 2)
    if len(top) < 2 or "45" not in top[1].splitlines()[0]:
        problems.append("EXPERIMENTS.md's newest entry isn't goal 45")
    ok, why = build("keeper", "mac")
    if not ok:
        problems.append(f"mac build failed: {why[-150:]}")
    if problems:
        return False, "; ".join(problems)
    return True, "gallery 'Works when closed' + 'Why not just WebGPU?', matrix, llms.txt, EXPERIMENTS; keeper mac built"


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4}
INNER = {"m1": lambda: (*m1_inner(), {}), "m2": m2_inner}
RESULTS = {}

if __name__ == "__main__":
    if "--inner" in sys.argv:
        name = sys.argv[sys.argv.index("--inner") + 1]
        owner = sys.argv[sys.argv.index("--owner-bus") + 1] if "--owner-bus" in sys.argv else ""
        try:
            private_bus_or_die(owner)
            ok, msg, native = INNER[name]()
        except Exception as e:
            ok, msg, native = False, f"{type(e).__name__}: {e}", {}
        print("INNER RESULT " + json.dumps({"ok": ok, "msg": msg, "native": native}), flush=True)
        sys.exit(0)
    pick = [a for a in sys.argv[1:] if a in MILESTONES] or list(MILESTONES)
    failed = 0
    for name in pick:
        try:
            ok, msg = RESULTS[name] if name in RESULTS else MILESTONES[name]()
        except Exception as e:  # a crash in a proof is a FAIL, not a pass
            ok, msg = False, f"{type(e).__name__}: {e}"
        RESULTS[name] = (ok, msg)
        failed += not ok
        print(f"{name} {'PASS' if ok else 'FAIL'}: {msg}", flush=True)
    sys.exit(1 if failed else 0)
