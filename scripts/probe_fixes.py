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
        "after_ms": round(ms, 2), "test": "tests/test_audio_stamp.mojo"}


STEPS = {"dictate": dictate}


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
