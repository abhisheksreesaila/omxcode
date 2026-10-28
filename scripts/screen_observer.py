"""Goal 38 M5: the external screen observer, its Hyprland helpers and its self-test.

    pixi run python scripts/screen_observer.py build        # build/observer/screen_observer (wayland-scanner + cc)
    pixi run python scripts/screen_observer.py selftest     # on the live desktop (D-765): writes docs/goals/38/observer.json

The method (docs/goals/38/README.md "The observer"): a small wlr-screencopy v3 client (scripts/screen_observer.c)
captures only a region of the compositor's output (the KPI row of the measured window) with capture_output_region +
copy_with_damage, so it is handed one copy per composited frame that has damage, at display rate, with no polling
timer; each frame carries the compositor's presentation timestamp. The harness matches frames to injected changes by
the region's pixel hash. grim (one process and a full-output PNG per shot) and video recorders (encode + portal) are
slower and coarser; the self-test measures this one's own latency and resolution against the probe window's
wp_presentation feedback (the compositor's own word on when a commit reached the screen).

Only processes this module starts are ever stopped (Popen handles; never by name).
"""
import json
import os
import random
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "scripts/screen_observer.c"
XML_SCREENCOPY = ROOT / "scripts/screen_observer.wlr-screencopy-unstable-v1.xml"
XML_XDG = Path("/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml")
XML_PRES = Path("/usr/share/wayland-protocols/stable/presentation-time/presentation-time.xml")
OUT = ROOT / "build/observer"
BIN = OUT / "screen_observer"
RESULT = ROOT / "docs/goals/38/observer.json"
SYSTEM_CC = "/usr/bin/cc"  # the system compiler and libwayland-client (pixi's env has no Wayland)


def mono_ns():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC)


def build():
    """Compile the observer if its source or protocols changed. Returns the binary's path."""
    srcs = [SRC, XML_SCREENCOPY, XML_XDG, XML_PRES]
    if BIN.exists() and all(BIN.stat().st_mtime > s.stat().st_mtime for s in srcs):
        return BIN
    OUT.mkdir(parents=True, exist_ok=True)
    gen = []
    for xml, name in ((XML_SCREENCOPY, "wlr-screencopy-unstable-v1"), (XML_XDG, "xdg-shell"), (XML_PRES, "presentation-time")):
        subprocess.run(["wayland-scanner", "client-header", str(xml), str(OUT / f"{name}-client-protocol.h")], check=True)
        subprocess.run(["wayland-scanner", "private-code", str(xml), str(OUT / f"{name}-protocol.c")], check=True)
        gen.append(str(OUT / f"{name}-protocol.c"))
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CONDA", "PIXI")) and k not in ("CFLAGS", "LDFLAGS", "CPPFLAGS")}
    env["PATH"] = "/usr/bin:/bin"
    r = subprocess.run([SYSTEM_CC, "-O2", "-Wall", "-Wno-unused-parameter", "-I", str(OUT), str(SRC), *gen,
                        "-o", str(BIN), "-lwayland-client"], capture_output=True, text=True, env=env)
    if r.returncode:
        raise SystemExit(f"screen_observer: build failed\n{r.stderr[-3000:]}")
    return BIN


def desktop_env():
    """The owner's live Hyprland session (D-765), never the headless display."""
    env = dict(os.environ)
    env.setdefault("WAYLAND_DISPLAY", "wayland-1")
    env.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    if not (Path(env["XDG_RUNTIME_DIR"]) / env["WAYLAND_DISPLAY"]).exists():
        raise SystemExit(f"screen_observer: no Wayland desktop at {env['WAYLAND_DISPLAY']}")
    env.pop("MOJOUI_PRIVATE_DISPLAY", None)
    return env


# ---------------------------------------------------------------------------------------------------------------------
# Hyprland
# ---------------------------------------------------------------------------------------------------------------------

def hyprctl(*args, env=None):
    r = subprocess.run(["hyprctl", *args], capture_output=True, text=True, timeout=10, env=env or desktop_env())
    return r.stdout


def clients():
    try:
        return json.loads(hyprctl("clients", "-j"))
    except json.JSONDecodeError:
        return []


def monitor():
    m = json.loads(hyprctl("monitors", "-j"))
    return next((x for x in m if x.get("focused")), m[0])


def window_of(pids, title=None, cls=None, timeout=60):
    """The Hyprland client owned by one of `pids` (a set; a browser's window belongs to one of its processes), or
    matching title/class, once it is mapped."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        for c in clients():
            if c.get("pid") in pids or (title and title in c.get("title", "")) or (cls and c.get("class") == cls):
                if c.get("mapped", True) and c["size"][0] > 0:
                    return c
        time.sleep(0.05)
    return None


def place(win, w, h, x=None, y=None):
    """Float the window, give it exactly w×h logical pixels, move it to (x, y) on the focused monitor (default: centred),
    and focus it. Returns the client record after the move."""
    m = monitor()
    lw, lh = round(m["width"] / m["scale"]), round(m["height"] / m["scale"])
    x = m["x"] + (lw - w) // 2 if x is None else x
    y = m["y"] + (lh - h) // 2 if y is None else y
    # Hyprland 0.56 dispatches through Lua (hl.dsp.*). Every call names the window explicitly: a dispatcher without
    # `window` acts on the focused window, which is the owner's (it toggled their window once, 2026-10-28).
    addr = win["address"]
    w_ = f'window = "address:{addr}"'
    for cmd in (f'hl.dsp.window.float({{ action = "enable", {w_} }})', f"hl.dsp.window.resize({{ x = {w}, y = {h}, {w_} }})",
                f"hl.dsp.window.move({{ x = {x}, y = {y}, {w_} }})", f"hl.dsp.focus({{ {w_} }})"):
        out = hyprctl("dispatch", cmd).strip()
        if out != "ok":
            raise RuntimeError(f"hyprctl dispatch {cmd}: {out}")
    t0 = time.time()
    while time.time() - t0 < 5:
        c = next((c for c in clients() if c["address"] == addr), None)
        if c and c["size"] == [w, h] and c["at"] == [x, y]:
            return c
        time.sleep(0.05)
    return next((c for c in clients() if c["address"] == addr), win)


def visible(win):
    """The window is on the monitor's active workspace (else the compositor draws none of its frames)."""
    m = monitor()
    c = next((c for c in clients() if c["address"] == win["address"]), None)
    return bool(c) and c["workspace"]["id"] == m["activeWorkspace"]["id"]


# ---------------------------------------------------------------------------------------------------------------------
# The observer process
# ---------------------------------------------------------------------------------------------------------------------

class Observer:
    """Runs screen_observer on a region (logical output coordinates) and keeps every frame it reports:
    self.frames = [(seq, t_present_ns, t_recv_ns, hash), …]."""

    def __init__(self, x, y, w, h, output=None):
        args = [str(build())] + (["--output", output] if output else []) + [str(int(v)) for v in (x, y, w, h)]
        self.region = (x, y, w, h)
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                  bufsize=1, env=desktop_env())
        self.frames, self.info, self.dumps, self._cv = [], None, [], threading.Condition()
        self._t = threading.Thread(target=self._read, daemon=True)
        self._t.start()
        with self._cv:
            if not self._cv.wait_for(lambda: self.info is not None and self.frames or self.p.poll() is not None, 10):
                raise RuntimeError("screen_observer: no first frame in 10 s")
        if self.p.poll() is not None:
            raise RuntimeError(f"screen_observer exited: {self.p.stderr.read()[-1000:]}")

    def _read(self):
        for line in self.p.stdout:
            f = line.split()
            with self._cv:
                if f[0] == "F":
                    self.frames.append((int(f[1]), int(f[2]), int(f[3]), f[4]))
                elif f[0] == "R":
                    self.info = {"width_px": int(f[1]), "height_px": int(f[2]), "stride": int(f[3]), "format": int(f[4])}
                elif f[0] == "D":
                    self.dumps.append(f[1])
                self._cv.notify_all()

    def last(self):
        with self._cv:
            return self.frames[-1]

    def since(self, t_ns):
        """Frames presented at or after t_ns."""
        with self._cv:
            return [f for f in self.frames if f[1] >= t_ns]

    def wait(self, pred, timeout):
        with self._cv:
            return self._cv.wait_for(lambda: pred(self.frames), timeout)

    def wait_stable(self, quiet_ms, timeout, after_ns=0):
        """Wait until no frame with a new hash for quiet_ms (the region settled). Returns the settled hash, or None."""
        t_end = time.time() + timeout
        while time.time() < t_end:
            with self._cv:
                fr = self.frames
                h = fr[-1][3]
                # the time the region last changed (the first frame with the current hash, in the current run of it)
                k = len(fr) - 1
                while k > 0 and fr[k - 1][3] == h:
                    k -= 1
                changed_at = fr[k][2]
            if changed_at >= after_ns and (mono_ns() - changed_at) / 1e6 >= quiet_ms:
                return h
            if changed_at < after_ns and (mono_ns() - after_ns) / 1e6 >= quiet_ms:
                return h
            time.sleep(0.005)
        return None

    def dump(self, path, timeout=5):
        """The next frame of the region as a PPM (needs one more composited frame with damage: callers trigger one)."""
        n = len(self.dumps)
        self.p.stdin.write(f"dump {path}\n")
        self.p.stdin.flush()
        with self._cv:
            return self._cv.wait_for(lambda: len(self.dumps) > n, timeout)

    def close(self):
        if self.p.poll() is None:
            try:
                self.p.stdin.write("quit\n")
                self.p.stdin.flush()
                self.p.wait(2)
            except (BrokenPipeError, subprocess.TimeoutExpired, OSError):
                self.p.terminate()
                try:
                    self.p.wait(2)
                except subprocess.TimeoutExpired:
                    self.p.kill()


def first_match(frames, t0_ns, final_hash):
    """The first frame presented after t0 whose region shows the final content: (t_present, t_recv), or None."""
    for _seq, tp, tr, h in frames:
        if tp >= t0_ns and h == final_hash:
            return tp, tr
    return None


# ---------------------------------------------------------------------------------------------------------------------
# Self-test: the observer against the compositor's own presentation feedback
# ---------------------------------------------------------------------------------------------------------------------

class ScreenNotLive(RuntimeError):
    pass


def screen_live():
    """None when a fresh window's commit reaches the screen (the session is unlocked and the output on), else why not.
    Opens the probe window for about a second and closes it."""
    try:
        probe = Probe()
    except Exception as e:
        return f"probe failed: {e}"
    try:
        win = window_of({probe.p.pid}, cls="observer-probe", timeout=10)
        if not win:
            return "probe window never mapped"
        place(win, 320, 200)
        time.sleep(0.2)
        try:
            _tc, tp, _r = probe.flip()
        except ScreenNotLive as e:
            return str(e)
        return None if tp else "the probe's commit was discarded (not shown)"
    finally:
        probe.close()


def stream_stats(x, y, w, h, seconds=3.0):
    """Without a probe (works on any repainting region, e.g. a lock screen): frame interval and receipt − timestamp."""
    obs = Observer(x, y, w, h)
    try:
        time.sleep(seconds)
        fr = list(obs.frames)
    finally:
        obs.close()
    return {"frames": len(fr), "region_px": obs.info,
            "interval_ms": _summary([(b[1] - a[1]) / 1e6 for a, b in zip(fr, fr[1:])]),
            "receipt_minus_timestamp_ms": _summary([(f[2] - f[1]) / 1e6 for f in fr[1:]]),
            "timestamp_vs_our_clock_ms": round((fr[-1][2] - fr[-1][1]) / 1e6, 3) if fr else None}


class Probe:
    def __init__(self):
        self.p = subprocess.Popen([str(build()), "probe"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                                  bufsize=1, env=desktop_env())
        self.lines, self._cv = [], threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()
        self.clock = int(self.expect("K")[1])
        self.size = tuple(int(v) for v in self.expect("S")[1:3])

    def _read(self):
        for line in self.p.stdout:
            with self._cv:
                self.lines.append(line.split())
                self._cv.notify_all()

    def expect(self, kind, timeout=10, start=0):
        with self._cv:
            ok = self._cv.wait_for(lambda: any(l[0] == kind for l in self.lines[start:]), timeout)
            if not ok:
                raise RuntimeError(f"probe: no {kind} line")
            i = next(i for i in range(start, len(self.lines)) if self.lines[i][0] == kind)
            line = self.lines.pop(i)
            return line

    def flip(self):
        """Paint a new colour; (t_commit_ns, t_presented_ns or None) from the probe's own clock and feedback."""
        self.p.stdin.write("flip\n")
        self.p.stdin.flush()
        c = self.expect("C")
        try:
            p = self.expect("P", timeout=2)
        except RuntimeError:
            raise ScreenNotLive("the probe's commit was never presented: is the session locked or the output off?")
        return int(c[1]), (int(p[1]) if p[1] != "0" else None), int(p[2])

    def close(self):
        if self.p.poll() is None:
            try:
                self.p.stdin.write("quit\n")
                self.p.stdin.flush()
                self.p.wait(2)
            except (BrokenPipeError, subprocess.TimeoutExpired, OSError):
                self.p.terminate()
                self.p.wait(2)


def _pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, max(0, int(round(q * (len(xs) - 1)))))] if xs else None


def _summary(xs):
    xs = [x for x in xs if x is not None]
    if not xs:
        return None
    return {"n": len(xs), "median": round(statistics.median(xs), 3), "p95": round(_pct(xs, 0.95), 3),
            "min": round(min(xs), 3), "max": round(max(xs), 3)}


def selftest(flips=120, write=True):
    """Probe window on the desktop; flip its colour at random phases; per flip: commit → compositor-presented
    (wp_presentation, the truth), observer's frame timestamp − truth (its timestamp error), observer receipt − truth
    (its delivery delay), and the same probe latency with the observer off (its cost to the compositor)."""
    env = desktop_env()
    probe = Probe()
    try:
        win = window_of({probe.p.pid}, cls="observer-probe")
        if not win:
            raise RuntimeError("probe window never mapped")
        win = place(win, 320, 200)
        x, y = win["at"]
        time.sleep(0.5)
        _tc, tp, _r = probe.flip()  # raises ScreenNotLive on a locked session
        if not tp:
            raise ScreenNotLive("the probe's first commit was discarded")
        # 1. observer off: the probe's commit → presented latency (the compositor's own floor)
        off = []
        for _ in range(flips // 2):
            time.sleep(0.05 + random.random() * 0.1)
            tc, tp, refresh = probe.flip()
            if tp:
                off.append((tp - tc) / 1e6)
        # 2. observer on, a 120×40 region inside the probe (a KPI-row-sized copy is ~1/10 of the window's)
        obs = Observer(x + 100, y + 80, 120, 40)
        rows = []
        try:
            time.sleep(0.3)
            for _ in range(flips):
                time.sleep(0.05 + random.random() * 0.1)
                tc, tp, refresh = probe.flip()
                ok = obs.wait(lambda fr: fr[-1][1] >= (tp or tc), 1.0)
                fr = obs.since(tc)
                hit = next((f for f in fr), None) if ok else None
                rows.append({"commit": tc, "presented": tp, "obs_present": hit[1] if hit else None,
                             "obs_recv": hit[2] if hit else None})
            info, nframes = obs.info, len(obs.frames)
            # observer frame rate under continuous change: flip every 4 ms for 1 s
            t0 = mono_ns()
            n0 = len(obs.frames)
            end = time.time() + 1.0
            while time.time() < end:
                probe.p.stdin.write("flip\n")
                probe.p.stdin.flush()
                time.sleep(0.004)
            time.sleep(0.1)
            burst = [f for f in obs.frames[n0:] if f[1] >= t0]
            intervals = [(b[1] - a[1]) / 1e6 for a, b in zip(burst, burst[1:])]
        finally:
            obs.close()
    finally:
        probe.close()
    lat_on = [(r["presented"] - r["commit"]) / 1e6 for r in rows if r["presented"]]
    err = [(r["obs_present"] - r["presented"]) / 1e6 for r in rows if r["presented"] and r["obs_present"]]
    recv = [(r["obs_recv"] - r["presented"]) / 1e6 for r in rows if r["presented"] and r["obs_recv"]]
    seen = sum(1 for r in rows if r["obs_present"])
    m = monitor()
    res = {
        "method": "wlr-screencopy v3 capture_output_region + copy_with_damage (scripts/screen_observer.c), shm, region only",
        "compositor": hyprctl("version", env=env).splitlines()[0],
        "monitor": {k: m.get(k) for k in ("name", "width", "height", "refreshRate", "scale")},
        "probe_clock_id": probe.clock,
        "flips": flips, "seen": seen, "missed": flips - seen,
        "region_px": info,
        "probe_commit_to_present_ms_observer_off": _summary(off),
        "probe_commit_to_present_ms_observer_on": _summary(lat_on),
        "observer_timestamp_minus_presented_ms": _summary(err),
        "observer_receipt_minus_presented_ms": _summary(recv),
        "observer_frame_interval_ms_under_continuous_change": _summary(intervals),
        "refresh_ms": round(1000 / m["refreshRate"], 3),
        "when": time.strftime("%Y-%m-%d %H:%M:%S"),
        "load1": round(os.getloadavg()[0], 2),
    }
    exact = sum(1 for e in err if abs(e) < 0.5)
    res["observer_timestamp_equals_presented"] = f"{exact} of {len(err)} within 0.5 ms"
    if write:
        RESULT.parent.mkdir(parents=True, exist_ok=True)
        RESULT.write_text(json.dumps(res, indent=1) + "\n")
    return res


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "build"
    if cmd == "build":
        print(build())
    elif cmd == "stream":
        print(json.dumps(stream_stats(*[int(v) for v in sys.argv[2:6]] if len(sys.argv) >= 6 else (0, 0, 400, 100)), indent=1))
    elif cmd == "live":
        print(screen_live() or "live")
    elif cmd == "selftest":
        print(json.dumps(selftest(), indent=1))
    else:
        raise SystemExit(__doc__)
