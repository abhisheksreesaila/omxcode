#!/usr/bin/env python3
"""Goal 49's proof: one script over everything on the board (GOAL.md). Prints "Mn: PASS|FAIL  why" per milestone.

    pixi run python docs/goals/49-check.py [M0 M1 ...]          (default: every milestone)

Data: goal 47's fleet in build/g47/full (fleet.csv, telemetry.parquet, clips/). The app is driven once by
`scripts/scenario.py script --media build/g47/full --out build/g49` (agent tools only), which leaves build/g49/script.json:
  cards:        {card name: {"rows": n, "cells": {column: first value}}}   every result card the scenario read
  trace:        the app's SCRIPT:/QUERY:/JOB:/SLOW: lines
  tools_called: every tool the scenario called, in order;  tools_available: the agent host's tool names at the end
  export:       the folder Export recipe wrote;  range: [from_s, to_s] applied;  other: the episode the recipe was reopened on
Truth comes from pyarrow / ffprobe / fleet.csv, never from the app.
"""
import csv
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FULL = ROOT / "build/g47/full"
OUT = ROOT / "build/g49"
HERO = "F00118"
FPS = 15


def run(cmd, timeout=3600):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=dict(os.environ))


def oks(cmd, labels, timeout=1800):
    r = run(cmd, timeout)
    out = r.stdout + r.stderr
    missing = [l for l in labels if not re.search(rf"^{re.escape(l)}: ok", out, re.M)]
    return (r.returncode == 0 and not missing), out, missing


def mojo_test(src, labels, timeout=1800, env=None):
    """Build a test with the vendored engine (scripts/mxbuild.sh: -I vendor) and run it; (ok, output, missing labels)."""
    exe = ROOT / "build" / Path(src).stem
    b = run(["scripts/mxbuild.sh", src, "-o", str(exe)], timeout)
    if b.returncode:
        return False, b.stdout + b.stderr, labels
    r = subprocess.run([str(exe)], cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))
    out = r.stdout + r.stderr
    missing = [l for l in labels if not re.search(rf"^{re.escape(l)}: ok", out, re.M)]
    return (r.returncode == 0 and not missing), out, missing


def frames_of(path):
    r = run(["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries", "stream=nb_read_frames",
             "-of", "csv=p=0", str(path)], 600)
    return int(r.stdout.strip().split(",")[0])


def telemetry_matches(episode, nframes):
    """Telemetry rows of the episode whose frame (round(t * 15)) is one of the video's frames."""
    import pyarrow.compute as pc
    import pyarrow.parquet as pq
    t = pq.read_table(FULL / "telemetry.parquet", columns=["episode", "t"])
    t = t.filter(pc.equal(t["episode"], episode))
    return sum(1 for x in t["t"].to_pylist() if 0 <= round(x * FPS) < nframes)


def fleet_row(episode):
    return next(r for r in csv.DictReader(open(FULL / "fleet.csv")) if r["episode"] == episode)


_s = None


def scenario():
    global _s
    if _s is None:
        r = run(["pixi", "run", "python", "scripts/scenario.py", "script", "--media", str(FULL), "--out", str(OUT)], 3600)
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / "check-scenario.txt").write_text(r.stdout + r.stderr)
        if r.returncode or not (OUT / "script.json").exists():
            raise SystemExit("scenario script failed: " + (r.stdout + r.stderr)[-1500:])
        _s = json.loads((OUT / "script.json").read_text())
    return _s


def m0():
    p = ROOT / "docs/goals/49/story.md"
    if not p.exists():
        return False, "docs/goals/49/story.md is missing"
    text = p.read_text()
    beats = re.findall(r"^## (\d+)\.", text, re.M)
    bad = []
    if beats != [str(i) for i in range(1, 16)]:
        bad.append(f"beats {beats}, want 1..15")
    for part in re.split(r"^## \d+\.", text, flags=re.M)[1:]:
        for need in ("caption:", "zoom:", "payoff:", "tool:"):
            if need not in part:
                bad.append(f"a beat lacks {need!r}: {part.strip().splitlines()[0][:60]}")
    named = set(re.findall(r"^tool: `([^`]+)`", text, re.M))
    have = set(scenario()["tools_available"]) | set(scenario()["tools_called"])
    missing = sorted(t for t in named if t not in have and not any(re.fullmatch(t.replace("*", ".*"), h) for h in have))
    if missing:
        bad.append(f"tools not in the app: {missing}")
    return not bad, "; ".join(bad) or f"15 beats, {len(named)} tools, all in the app"


def m1():
    ok, out, missing = mojo_test("tests/test_script.mojo", ["parse", "run", "chain", "error", "fn"])
    return ok, "parse; run; chain; error; fn" if ok else f"test_script: no ok for {missing}: {out[-500:]}"


def m2():
    s = scenario()
    c = s["cards"]
    n = frames_of(FULL / "clips" / f"{HERO}.mp4")
    want = telemetry_matches(HERO, n)
    lab = fleet_row(HERO)["lab"]
    bad = []
    for k in ("frames", "joined", "with_fleet"):
        if f"table-{k}" not in c:
            bad.append(f"no card table-{k}")
    if bad:
        return False, "; ".join(bad)
    if c["table-frames"]["rows"] != n:
        bad.append(f"frames {c['table-frames']['rows']} != video {n}")
    if c["table-joined"]["rows"] != want:
        bad.append(f"joined {c['table-joined']['rows']} != pyarrow {want}")
    if c["table-with_fleet"]["rows"] != want or c["table-with_fleet"]["cells"].get("lab") != lab:
        bad.append(f"with_fleet {c['table-with_fleet']} != {want} rows of lab {lab}")
    if len([l for l in s["trace"] if l.startswith("SCRIPT:")]) < 3:
        bad.append("fewer than 3 SCRIPT: lines")
    return not bad, "; ".join(bad) or f"video {n} frames; video ⨝ telemetry {want} rows = pyarrow; ⨝ fleet: lab {lab}"


def m3():
    s = scenario()
    a, b = s["range"]
    lo, hi = round(a * FPS), round(b * FPS)
    bad = []
    if not any(l.startswith("SCRIPT:") and "regions(" in l for l in s["trace"]):
        bad.append("Apply did not write a regions(…) statement")
    card = next((v for k, v in s["cards"].items() if k.startswith("table-apply")), None)
    if not card or card["rows"] <= 0:
        bad.append(f"no applied result with rows: {card}")
    elif not (lo <= int(card["cells"].get("frame", -1)) < hi):
        bad.append(f"applied first frame {card['cells'].get('frame')} outside [{lo}, {hi})")
    exp = Path(s["export"])
    clips = list(exp.glob("*.mp4"))
    if not clips:
        bad.append(f"no clip in {exp}")
    elif abs(frames_of(clips[0]) - (hi - lo)) > 1:
        bad.append(f"clip {frames_of(clips[0])} frames != range {hi - lo}")
    if not (exp / "script.sql").exists() or "regions(" not in (exp / "script.sql").read_text():
        bad.append("script.sql missing or without regions(")
    if len(list(exp.glob("*.csv"))) < 2:
        bad.append("fewer than 2 CSVs")
    slow = [l for l in s["trace"] if l.startswith("SLOW:")]
    if slow:
        bad.append(f"{len(slow)} SLOW: {slow[:2]}")
    return not bad, "; ".join(bad) or f"range {a}–{b} s: applied on frames [{lo}, {hi}), clip {hi - lo} frames, script + CSVs; 0 SLOW at 50 ms"


def m4():
    s = scenario()
    other = s["other"]
    bad = []
    if other == HERO:
        bad.append("reopened on the same episode")
    n = frames_of(FULL / "clips" / f"{other}.mp4")
    want = telemetry_matches(other, n)
    r = s.get("reopened", {})
    if r.get("table-frames", {}).get("rows") != n:
        bad.append(f"reopened frames {r.get('table-frames')} != {n}")
    if r.get("table-joined", {}).get("rows") != want:
        bad.append(f"reopened joined {r.get('table-joined')} != pyarrow {want}")
    for t in ("open-recipe", "run-script", "export-recipe"):
        if t not in s["tools_called"]:
            bad.append(f"never called {t}")
    return not bad, "; ".join(bad) or f"recipe reopened on {other}: {n} frames, joined {want} = pyarrow; {len(s['tools_called'])} tool calls, agent tools only"


def m5():
    bad = []
    media, g39 = ROOT / "build/g39/media", ROOT / "build/g39"  # (goal 39's generated warehouse: the tests' media)
    if not (media / "truth.json").exists():
        r = run([sys.executable, "scripts/media_data.py", str(media)], 3600)
        if r.returncode:
            return False, "media_data.py: " + (r.stdout + r.stderr)[-400:]
    env = {"G39_MEDIA": str(media), "G39_OUT": str(g39)}
    for t, labels in (("tests/test_asksql.mojo", ["implied", "lineage", "book", "chain"]), ("tests/test_tablejobs.mojo", ["tablejobs"]),
                      ("tests/test_videotable.mojo", ["videotable"])):
        ok, out, _ = mojo_test(t, labels, env=env)
        if not ok:
            bad.append(f"{t}: {out[-300:]}")
    r = run(["pixi", "run", "python", "docs/goals/47-check.py", "M2", "M4"], 7200)
    if r.returncode or "FAIL" in r.stdout:
        bad.append("goal 47: " + r.stdout[-600:])
    return not bad, "; ".join(bad) or "asksql, tablejobs, videotable tests; goal 47 M2 + M4 PASS"


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5}


def main():
    want = sys.argv[1:] or list(MILESTONES)
    failed = 0
    for k in want:
        try:
            ok, msg = MILESTONES[k]()
        except SystemExit as e:
            ok, msg = False, str(e)
        except Exception as e:  # a crash in a proof is a FAIL, with its reason
            ok, msg = False, f"{type(e).__name__}: {e}"
        failed += not ok
        print(f"{k}: {'PASS' if ok else 'FAIL'}  {msg}", flush=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
