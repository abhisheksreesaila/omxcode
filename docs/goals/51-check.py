#!/usr/bin/env python3
"""Goal 51's proof: models as functions in the script, in the app's own process (GOAL.md). "Mn: PASS|FAIL  why".

    pixi run python docs/goals/51-check.py [M0 M1 ...]          (default: every milestone)

Packs are built by scripts/packs/*.py into build/packs/ when missing (build side: Python is allowed there). The app is
driven by `scripts/scenario.py models --media build/g47/full --out build/g51` (agent tools only), which leaves
build/g51/models.json (cards, trace, tools_called, export: the recipe folder it exported). Truth comes from fleet.csv,
the packs' Python references and ffprobe, never from the app.
"""
import csv
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FULL = ROOT / "build/g47/full"
OUT = ROOT / "build/g51"
PACKS = ROOT / "build/packs"
FPS = 15


def run(cmd, timeout=3600, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))


def mojo_test(src, labels, timeout=1800, env=None):
    """Build a test with the vendored engine and libmax (scripts/mxbuild.sh) and run it; (ok, output, missing labels)."""
    exe = ROOT / "build" / Path(src).stem
    b = run(["scripts/mxbuild.sh", src, "-o", str(exe)], timeout)
    if b.returncode:
        return False, b.stdout + b.stderr, labels
    r = subprocess.run([str(exe)], cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))
    out = r.stdout + r.stderr
    missing = [l for l in labels if not re.search(rf"^{re.escape(l)}: ok", out, re.M)]
    return (r.returncode == 0 and not missing), out, missing


def pack(name, marker):
    """build/packs/<name>, made by scripts/packs/<name>.py when `marker` isn't there yet."""
    if not (PACKS / name / marker).exists():
        r = run(["pixi", "run", "python", f"scripts/packs/{name}.py", str(PACKS / name)], 7200)
        if r.returncode:
            raise SystemExit(f"scripts/packs/{name}.py failed: " + (r.stdout + r.stderr)[-1200:])
    return PACKS / name


_s = None


def scenario():
    global _s
    if _s is None:
        r = run(["pixi", "run", "python", "scripts/scenario.py", "models", "--media", str(FULL), "--out", str(OUT)], 3600)
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / "check-scenario.txt").write_text(r.stdout + r.stderr)
        if r.returncode or not (OUT / "models.json").exists():
            raise SystemExit("scenario models failed: " + (r.stdout + r.stderr)[-1500:])
        _s = json.loads((OUT / "models.json").read_text())
    return _s


def m0():
    pack("tiny", "tiny_gpu.mef")
    ok, out, missing = mojo_test("tests/test_maxrt.mojo", ["cpu", "gpu", "nopython"])  # (nopython: libmax loaded, no libpython, read from /proc/self/maps)
    if not ok:
        return False, f"test_maxrt: no ok for {missing}: {out[-600:]}"
    ldd = run(["ldd", str(ROOT / "build/test_maxrt")]).stdout
    if "libpython" in ldd:
        return False, "test_maxrt links libpython: " + ldd[-400:]
    gpu = re.findall(r"^gpu: ok.*$", out, re.M)
    return True, "cpu; " + (gpu[0][len("gpu: ok "):] if gpu else "gpu") + "; libmax loaded at run time, no libpython"


def m1():
    p = pack("minilm", "ref_vectors.f32")
    ok, out, missing = mojo_test("tests/test_textembed.mojo", ["wordpiece", "embed"], env={"MINILM_PACK": str(p)})
    speed = re.findall(r"^rows/s.*$", out, re.M)
    if not ok:
        return False, f"test_textembed: no ok for {missing}: {out[-600:]}"
    return True, "wordpiece ids = Python's; cosine ≥ 0.999 with the Python pack; " + (speed[0] if speed else "no rows/s line")


def m2():
    s = scenario()
    exp = Path(s["export"])
    f = exp / "classified.csv"
    if not f.exists():
        return False, f"no classified.csv in {exp}"
    label_of = {r["value"]: r["label"] for r in csv.DictReader(open(f))}
    fleet = list(csv.DictReader(open(FULL / "fleet.csv")))
    verbs = Counter(r["verb"] for r in fleet)
    base = verbs.most_common(1)[0][1] / len(fleet)
    agree = sum(1 for r in fleet if label_of.get(r["task"]) == r["verb"]) / len(fleet)
    missing = sum(1 for r in fleet if r["task"] not in label_of)
    timed = [l for l in s["trace"] if l.startswith("SCRIPT: classified")]
    bad = []
    if missing:
        bad.append(f"{missing} fleet rows' task has no label")
    if agree < base + 0.20:
        bad.append(f"agrees on {agree:.1%}, needs ≥ {base + 0.20:.1%} (always '{verbs.most_common(1)[0][0]}': {base:.1%})")
    if "run-script" not in s["tools_called"]:
        bad.append("not run through the Script window")
    return not bad, "; ".join(bad) or f"agrees with fleet.verb on {agree:.1%} of {len(fleet):,} rows (always the commonest: {base:.1%}); {len(label_of):,} unique tasks; {timed[0] if timed else ''}"


def iou(a, b):
    ax2, ay2, bx2, by2 = a[0] + a[2], a[1] + a[3], b[0] + b[2], b[1] + b[3]
    iw, ih = max(0.0, min(ax2, bx2) - max(a[0], b[0])), max(0.0, min(ay2, by2) - max(a[1], b[1]))
    inter = iw * ih
    u = a[2] * a[3] + b[2] * b[3] - inter
    return inter / u if u > 0 else 0.0


def m3():
    p = pack("yolox", "reference.json")
    ok, out, missing = mojo_test("tests/test_yolox.mojo", ["yolox"], env={"YOLOX_PACK": str(p), "YOLOX_OUT": str(OUT / "yolox.json")})
    if not ok:
        return False, f"test_yolox: no ok for {missing}: {out[-600:]}"
    ref = json.loads((p / "reference.json").read_text())
    got = json.loads((OUT / "yolox.json").read_text())
    bad = []
    for img, boxes in ref.items():
        mine = got.get(img, [])
        for b in boxes:
            if b["score"] >= 0.3 and not any(m["cls"] == b["cls"] and iou(m["box"], b["box"]) >= 0.9 for m in mine):
                bad.append(f"{img}: reference {b['cls']} {b['score']:.2f} unmatched")
        for m in mine:
            if m["score"] >= 0.5 and not any(m["cls"] == b["cls"] and iou(m["box"], b["box"]) >= 0.5 for b in boxes):
                bad.append(f"{img}: extra {m['cls']} {m['score']:.2f}")
    ms = re.findall(r"^ms/frame.*$", out, re.M)
    n = sum(len([b for b in v if b["score"] >= 0.3]) for v in ref.values())
    return not bad, "; ".join(bad[:6]) or f"{n} reference boxes on {len(ref)} images matched (IoU ≥ 0.9, same class), no extras; {ms[0] if ms else ''}"


def m4():
    s = scenario()
    a, b = s["range"]
    lo, hi = round(a * FPS), round(b * FPS)
    exp = Path(s["export"])
    f = exp / "detected.csv"
    bad = []
    if not f.exists():
        return False, f"no detected.csv in {exp}"
    rows = list(csv.DictReader(open(f)))
    frames = [int(r["frame"]) for r in rows]
    outside = [x for x in frames if not lo <= x < hi]
    covered = len(set(frames)) / (hi - lo)
    if not rows or outside:
        bad.append(f"{len(rows)} rows, {len(outside)} outside [{lo}, {hi})")
    if covered < 0.5:
        bad.append(f"boxes on {covered:.0%} of the section's frames, needs ≥ 50%")
    for need in ("kind", "score", "x", "y", "w", "h"):
        if rows and need not in rows[0]:
            bad.append(f"no column {need}")
    slow = [l for l in s["trace"] if l.startswith("SLOW:")]
    if slow:
        bad.append(f"{len(slow)} SLOW: {slow[:2]}")
    if not any(l.startswith("MARKS:") for l in s["trace"]):
        bad.append("the boxes never reached the player (no MARKS: line)")
    shots = list((OUT / "shots").glob("*.png")) if (OUT / "shots").exists() else []
    if not shots:
        bad.append("no shots in build/g51/shots")
    kinds = Counter(r["kind"] for r in rows).most_common(3)
    return not bad, "; ".join(bad) or f"{len(rows)} boxes on {covered:.0%} of frames [{lo}, {hi}); kinds {kinds}; on the player; 0 SLOW"


def m5():
    r = run(["pixi", "run", "python", "docs/goals/49-check.py", "M1", "M2", "M3", "M4"], 7200)
    ok = r.returncode == 0 and "FAIL" not in r.stdout
    return ok, "goal 49 M1–M4 PASS" if ok else "goal 49: " + r.stdout[-800:]


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5}


def main():
    want = sys.argv[1:] or list(MILESTONES)
    failed = 0
    for k in want:
        try:
            ok, msg = MILESTONES[k]()
        except SystemExit as e:
            ok, msg = False, str(e)
        except Exception as e:
            ok, msg = False, f"{type(e).__name__}: {e}"
        failed += not ok
        print(f"{k}: {'PASS' if ok else 'FAIL'}  {msg}", flush=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
