"""The probes' open items, fixed one at a time (docs/probes.md, owner 2026-10-30). Each fix has a step here that runs its
test (written failing first) and records what it measured in docs/goals/probe-fixes/results.json, which the gallery's
"Hardened since" notes read (scripts/probe_fixes_gallery.py). A step may gain checks, never lose them.

Run: pixi run python scripts/probe_fixes.py            (every step)
     pixi run python scripts/probe_fixes.py dictate    (one or more steps by name)
"""

import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
RESULTS = ROOT / "docs" / "goals" / "probe-fixes" / "results.json"


def mojo(path, ok_line, timeout=900, env=None):
    """Runs a Mojo test; (ok, its output). ok needs exit 0 and the ok line."""
    try:
        r = subprocess.run(["pixi", "run", "mojo", "run", "-I", ".", path], cwd=ROOT, capture_output=True, text=True,
                           timeout=timeout, env=env)
    except subprocess.TimeoutExpired as e:
        return False, f"{path}: no answer in {timeout} s (hung): {(e.stdout or b'')[-300:]!r}"
    out = r.stdout + r.stderr
    return r.returncode == 0 and ok_line in out, out


def dictate():
    """captured_ns gives up on a sequence word that stays odd (bounded), and still reads an even one exactly."""
    ok, out = mojo("tests/test_audio_stamp.mojo", "audio stamp: ok", timeout=300)
    m = re.search(r"returned in ([\d.]+) ms", out)
    if not ok or not m:
        return False, f"tests/test_audio_stamp.mojo: {out[-400:]}", {}
    ok2, out2 = mojo("tests/test_audio_fail.mojo", "audio lost: ok", timeout=300)
    if not ok2:
        return False, f"tests/test_audio_fail.mojo (captured_ns under a live capture): {out2[-400:]}", {}
    ms = float(m.group(1))
    return True, f"a stuck word returns in {ms:.2f} ms (before: never); live capture still consistent", {
        "item": "captured_ns retried without a bound", "before": "hung forever on a word that stayed odd",
        "after_ms": round(ms, 2), "test": "tests/test_audio_stamp.mojo",
        "note": "after_ms is how long the stuck read took to return, which is the 2 ms bound; the fallback's time being off by at most one 20 ms chunk is reasoned from the writer's code, not tested"}


def load_check(n):
    import importlib.util
    spec = importlib.util.spec_from_file_location(f"goal{n}", ROOT / "docs" / "goals" / f"{n}-check.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def jot_flake():
    """Goal 30 M1 (100M rows, frame gaps ≤ 50 ms, the cancel) passes RUNS times in a row (before: 1 of 5 failed, and its
    steps failed every time with half the CPU busy). Causes: a fixed 3.5 s pause raced the open job (now waitfor:,
    D-1701) and the pause: step slept 10 ms after every main-loop turn, skipping frames (now pump(), D-1702)."""
    import headless
    headless.ensure()  # (archived checkers don't start the display: lessons)
    g30 = load_check(30)
    if not g30.big().exists():
        return False, f"no 100M-row file at {g30.big()} (goal 20's big.parquet)", {}
    runs, gaps = 3, []
    for i in range(runs):
        ok, msg = g30.m1()
        if not ok:
            return False, f"goal 30 M1 run {i + 1} of {runs}: {msg}", {}
        gaps.append(msg.split("longest frame gaps ", 1)[1].split(")", 1)[0])
    return True, f"goal 30 M1 passed {runs} of {runs} (longest frame gaps per run: {'; '.join(gaps)})", {
        "item": "goal 30 M1 failed now and then", "runs": runs, "gaps": gaps,
        "causes": ["a fixed 3.5 s pause raced the 100M-row open job (1.8-2.3 s idle, 4.3-6 s with half the CPU busy): "
                   "the test host's waitfor: step waits for the import sheet's button instead",
                   "the test host's pause: step slept 10 ms after every main-loop turn and skipped frames: the cancel's "
                   "gaps were 50-67 ms in 6 of 6 runs, 16.7-50 ms after"]}


def jot_queue():
    """A held field change never overwrites a newer one that reached the app directly (tests/test_field_queue.py)."""
    v = subprocess.run([sys.executable, "tests/test_step_verbs.py"], cwd=ROOT, capture_output=True, text=True, timeout=60)
    if v.returncode != 0:  # (the queue's holdtext: step once shadowed goal 41's hold: after a merge)
        return False, (v.stdout + v.stderr)[-300:], {}
    r = subprocess.run([sys.executable, "tests/test_field_queue.py"], cwd=ROOT, capture_output=True, text=True, timeout=900)
    out = r.stdout + r.stderr
    if r.returncode != 0 or "field queue stale: ok" not in out or "field queue: ok" not in out:
        return False, f"tests/test_field_queue.py: {out[-400:]}", {}
    return True, "a held change, then a newer one reaching the app, then a rebuild: the app keeps the newer (before: the held one came back)", {
        "item": "the field queue's stale-write window", "before": "the app's texts newer, newer, old, old",
        "after": "newer kept through two rebuilds", "test": "tests/test_field_queue.py"}


def jot_drop():
    """The web host's files: tests/test_web_files.py (eviction mid-write, the start's sweep, oversize), then a real page:
    an oversize file picked in headless Chromium shows the host's notice, which leaves by itself (the notice once passed
    the server-side test and never showed: htmx's beforeend inserts an out-of-band element's children)."""
    import tempfile
    if not (ROOT / "build/jot/web/mojoui_app.so").exists():
        b = subprocess.run(["scripts/build.sh", "jot", "web"], cwd=ROOT, capture_output=True, text=True, timeout=1800)
        if b.returncode != 0:
            return False, "jot web build: " + (b.stdout + b.stderr)[-300:], {}
    r = subprocess.run([sys.executable, "tests/test_web_files.py"], cwd=ROOT, capture_output=True, text=True, timeout=900)
    out = r.stdout + r.stderr
    want = ["sweep: ok", "oversize: ok", "evicted drop: ok", "evicted upload: ok", "web files: ok"]
    if r.returncode != 0 or any(w not in out for w in want):
        return False, f"tests/test_web_files.py: {out[-500:]}", {}
    import drive
    d = tempfile.mkdtemp()
    (Path(d) / "big.md").write_text("x" * 1000)
    shot = ROOT / "docs/goals/probe-fixes/web-notice.png"

    def during(page):
        page.set_input_files("input.picker-input", str(Path(d) / "big.md"))
        page.wait_for_selector(".mojoui-notice", timeout=10000)
        page.wait_for_timeout(400)
        page.screenshot(path=str(shot))
        text = page.inner_text(".mojoui-notice")
        page.wait_for_timeout(8500)
        return f"NOTICE: {text}\nNOTICE GONE: {page.query_selector('.mojoui-notice') is None}"

    res, log = drive.web_run(ROOT / "build/jot/web", "pause:300", viewport=(1100, 700), during=during,
                             env={"OMXCODE_UPLOAD_MAX": "64", "OMXCODE_UPLOADS": d + "/u", "JOT_DB": d + "/j.db"})
    if res.returncode != 0 or "NOTICE GONE: True" not in log or "wasn't uploaded" not in log:
        return False, f"the page's notice: {log[-400:]}", {}
    return True, "evicted drops and uploads leave nothing, a start sweeps a gone server's folders, an oversize file shows a notice (Chromium)", {
        "item": "web drop leaks", "test": "tests/test_web_files.py", "shot": "docs/goals/probe-fixes/web-notice.png",
        "before": "an evicted drop left its files (the folder recreated), an evicted upload reached its closed app, "
                  "crash leftovers stayed forever, an oversize file vanished in silence"}


def keeper_stamp():
    """file_stamp agrees with os.stat (ns time, 5 GiB, empty, missing), reads statx on Linux, compiles for aarch64."""
    r = subprocess.run([sys.executable, "tests/test_file_stamp.py"], cwd=ROOT, capture_output=True, text=True, timeout=1800)
    out = r.stdout + r.stderr
    if r.returncode != 0 or "file stamp: ok" not in out:
        return False, f"tests/test_file_stamp.py: {out[-500:]}", {}
    return True, "file_stamp agrees with the system on 4 cases, reads statx (one layout on every architecture), compiles for aarch64", {
        "item": "file_stamp was x86-64 only", "test": "tests/test_file_stamp.py",
        "before": "short paths read as unreadable (the path was freed before stat read it); offsets of x86-64's struct stat",
        "unverified": "run on aarch64 Linux (no machine here: compiled only); the Mac's branch is unchanged (built, not run)"}


def keeper_handover():
    """Goal 45 M1 on its private bus, with its addition: a second launch opens the running app and never builds its App
    (traycheck prints TRAYCHECK: built from __init__)."""
    g45 = load_check(45)
    ok, why = g45.build("traycheck", "linux")
    if not ok:
        return False, "traycheck build: " + why, {}
    import headless
    headless.ensure()
    ok, msg = g45.m1()
    if not ok:
        return False, f"goal 45 M1: {msg}", {}
    return True, "a second launch hands over to the running app before building anything (goal 45 M1 PASS)", {
        "item": "a second launch built its App before handing over", "api": "App.one_instance()",
        "before": "goal 45 M1's addition failed: the second launch printed TRAYCHECK: built"}


def sketch_erase():
    """Goal 40 M3 (the mended picture equals the CPU render, pixel for pixel, with an erase across a crossing stroke)
    and M4 on docs/goals/40/bench.json (with its addition: erase p95 ≤ 16.7 ms, the ink layer never built again while
    erasing). The bench itself: pixi run python scripts/sketch_bench.py (several minutes)."""
    import headless
    headless.ensure()
    g40 = load_check(40)
    for name in ("m3", "m4"):
        ok, msg = getattr(g40, name)()
        if not ok:
            return False, f"goal 40 {name.upper()}: {msg}", {}
    b = json.loads((ROOT / "docs/goals/40/bench.json").read_text())["erase"]
    return True, f"erase p95 {b['p95_ms']} ms, the ink layer trimmed {b['trimmed_by_layer'].get('ink', 0)} times and built 0; pixels equal the CPU's", {
        "item": "erasing took 14-23 ms p95", "after_p95_ms": b["p95_ms"], "after_draw_p95_ms": b["draw_p95_ms"],
        "before_p95_ms": 21.4, "before_note": "21.4 ms on this machine at the start (draw 20.2: node build 6.1, mend 11.1, finding the removal 1.2); 13.7 in goal 40's run",
        "runs_p95_ms": [5.8, 6.7, 15.4, 8.2, 8.0, 8.5], "runs_note": "six runs on a shared machine (load average 4-16); the 15.4 run was slower in every part of the frame"}


STEPS = {"dictate": dictate, "jot_flake": jot_flake, "jot_queue": jot_queue, "jot_drop": jot_drop, "keeper_stamp": keeper_stamp,
         "keeper_handover": keeper_handover, "sketch_erase": sketch_erase}


def main():
    names = sys.argv[1:] or list(STEPS)
    results = json.loads(RESULTS.read_text()) if RESULTS.exists() else {}
    bad = 0
    for name in names:
        t = time.time()
        try:
            ok, msg, data = STEPS[name]()
        except Exception as e:  # (a crash prints its traceback: lessons, 2026-10-21)
            import traceback
            traceback.print_exc()
            ok, msg, data = False, f"crashed: {e!r}", {}
        print(f"{'PASS' if ok else 'FAIL'} {name} ({time.time() - t:.0f} s): {msg}")
        if ok:
            results[name] = dict(data, checked=time.strftime("%Y-%m-%d"))
        bad += not ok
    RESULTS.write_text(json.dumps(results, indent=1, sort_keys=True) + "\n")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
