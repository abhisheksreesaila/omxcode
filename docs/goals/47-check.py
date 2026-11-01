#!/usr/bin/env python3
"""Goal 47's proof: "Why did the robot drop it?" Each milestone is proven by running something (docs/goals/47-GOAL.md).

    pixi run python docs/goals/47-check.py [M0 M1 ...]          (default: every milestone; prints "Mn: PASS|FAIL  why")

Reads the full fleet from build/g47/full (scripts/robot_data.py makes it when missing, from ~/data/robot-scout/droid720*),
runs scripts/scenario.py robots (agent tools only) once into build/g47/robots and scripts/clips.py robots (the GTK clip and
the shots) once, and reads what they left. Truth comes from scripts/robot_data.py's truth.json and from the telemetry
parquet itself (pyarrow), never from the app.
"""
import csv
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
G47 = ROOT / "build/g47"
FULL = G47 / "full"
ROBOTS = G47 / "robots"
PY = [sys.executable, "-I"]
sys.path.insert(0, str(ROOT / "scripts"))


def run(cmd, timeout=3600, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))


def oks(cmd, labels, timeout=1800):
    r = run(cmd, timeout)
    out = r.stdout + r.stderr
    missing = [l for l in labels if not re.search(rf"^{re.escape(l)}: ok", out, re.M)]
    return (r.returncode == 0 and not missing), out, missing


def data():
    if not (FULL / "truth.json").exists():
        r = run(PY + ["scripts/robot_data.py", str(FULL)], 7200)
        if r.returncode:
            raise SystemExit("robot_data.py failed: " + (r.stdout + r.stderr)[-800:])
    return json.loads((FULL / "truth.json").read_text())


_robots = None


def robots():
    """scripts/scenario.py robots, once per check run: its summary (robots.json)."""
    global _robots
    if _robots is None:
        data()
        r = run(["pixi", "run", "python", "scripts/scenario.py", "robots", "--media", str(FULL), "--out", str(ROBOTS)], 3600)
        (G47 / "check-scenario.txt").write_text(r.stdout + r.stderr)
        if r.returncode or not (ROBOTS / "robots.json").exists():
            raise SystemExit("scenario robots failed: " + (r.stdout + r.stderr)[-1200:])
        _robots = json.loads((ROBOTS / "robots.json").read_text())
    return _robots


_clip = None


def clip():
    global _clip
    if _clip is None:
        data()
        r = run(["pixi", "run", "python", "scripts/clips.py", "robots"], 3600)
        (G47 / "check-clip.txt").write_text(r.stdout + r.stderr)
        if r.returncode:
            raise SystemExit("clips.py robots failed: " + (r.stdout + r.stderr)[-1200:])
        _clip = (G47 / "clip-robots.log").read_text()
    return _clip


def m0():
    t = data()
    bad = []
    ok, out, missing = oks(PY + ["tests/test_lerobot.py"], ["lerobot", "droid"])
    if not ok:
        bad.append(f"test_lerobot: no ok for {missing}: {out[-300:]}")
    rows = list(csv.DictReader(open(FULL / "fleet.csv")))
    want = {"episode", "lab", "robot", "date", "task", "verb", "success", "duration_s", "frames", "grasps", "clip", "source"}
    if not want <= set(rows[0]):
        bad.append(f"fleet.csv lacks {sorted(want - set(rows[0]))}")
    if len(t["labs"]) < 13 or t["episodes"] != len(rows):
        bad.append(f"{len(t['labs'])} labs, truth {t['episodes']} vs {len(rows)} rows")
    hero = [r for r in rows if r["episode"] == t["hero"]]
    if not hero or not (FULL / hero[0]["clip"]).exists():
        bad.append(f"the featured failure {t['hero']} has no clip")
    else:
        n = run(["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0",
                 str(FULL / hero[0]["clip"])]).stdout.strip()
        if n != hero[0]["frames"]:
            bad.append(f"{t['hero']}.mp4 has {n} frames, fleet says {hero[0]['frames']}")
    if not (FULL / "paper" / "droid-paper.pdf").exists() or not (FULL / "telemetry.parquet").exists():
        bad.append("paper or telemetry missing")
    small = ["~/data/robot-scout/droid720", "~/data/robot-scout/droid720_failure"]
    outs = []
    for k in (1, 2):
        o = G47 / f"determinism-{k}"
        r = run(PY + ["scripts/robot_data.py", str(o)] + [os.path.expanduser(s) for s in small], 3600, env={"ROBOT_CLIPS": "0"})
        if r.returncode:
            bad.append(f"run {k}: {(r.stdout + r.stderr)[-300:]}")
        outs.append(o)
    for f in ("fleet.csv", "limits.csv", "truth.json"):
        if (outs[0] / f).read_bytes() != (outs[1] / f).read_bytes():
            bad.append(f"two runs differ: {f}")
    return not bad, "; ".join(bad) or (f"{t['episodes']:,} episodes, {len(t['labs'])} labs, {t['failures']:,} failures; hero {t['hero']} "
                                       f"({hero[0]['frames']} frames, clip ok); two runs byte-equal; lerobot + droid ok")


def m1():
    ok, out, missing = oks(["pixi", "run", "mojo", "run", "-I", ".", "tests/test_telemetry.mojo"], ["signal", "lanes", "draw", "seek"])
    if not ok:
        return False, f"test_telemetry: no ok for {missing}: {out[-400:]}"
    r = run(["scripts/mxbuild.sh", "tests/test_robot_follow.mojo", "-o", "build/test_robot_follow"], 1800)
    if r.returncode:
        return False, "build test_robot_follow: " + (r.stdout + r.stderr)[-400:]
    labels = ["follow", "index", "slice", "moment", "card", "named", "page"]
    ok, out, missing = oks(["pixi", "run", "build/test_robot_follow", str(FULL / "clips/F00118.mp4"), str(FULL / "clips/F00119.mp4"), str(FULL / "paper/droid-paper.pdf")], labels)
    return ok, "signal; lanes; draw; seek; " + "; ".join(labels) if ok else f"test_robot_follow: no ok for {missing}: {out[-400:]}"


def m2():
    s = robots()
    t = data()
    log = s["log"]
    bad = []
    if not any(l.startswith(f"OPEN: episode {t['hero']}.mp4") for l in log):
        bad.append("no OPEN line for the featured failure")
    sl = [l for l in log if l.startswith(f"SLICE: telemetry episode={t['hero']}")]
    frames = next(r["frames"] for r in csv.DictReader(open(FULL / "fleet.csv")) if r["episode"] == t["hero"])
    if not sl:
        bad.append("no SLICE line")
    elif f" {frames} rows" not in sl[0]:
        bad.append(f"the slice isn't the whole episode: {sl[0]} vs {frames} frames in fleet.csv")
    if not any(l.startswith("JOB: index landed telemetry.episode") and "(grouped)" in l for l in log):
        bad.append("no grouped index landed for the telemetry")
    for want, p, c in s["seeks"]:
        mp = re.search(r"t=([0-9.]+)", p)
        mc = re.search(r"t=([0-9.]+)", c)
        if not mp or not mc or abs(float(mp.group(1)) - float(mc.group(1))) > 1 / 15 + 1e-6:
            bad.append(f"seek {want}: {p} vs {c}")
    if s["slow"]:
        bad.append(f"{len(s['slow'])} SLOW lines: {s['slow'][:2]}")
    return not bad, "; ".join(bad) or f"{sl[0][len('SLICE: '):]}; cursor = player at 3 seeks; 0 SLOW at 50 ms"


def m3():
    s = robots()
    t = data()
    bad = []
    chart = dict(re.findall(r"^(\w+)\t([0-9.]+)$", s["said"]["chart"], re.M))
    bad += [f"lab {lab}" for lab, v in t["success_rate_by_lab"].items() if lab not in chart or abs(float(chart[lab]) - 100 * v) > 0.6]
    verbs = dict(re.findall(r"^(\S+)\t([0-9.]+)$", s["said"].get("verbs", ""), re.M))
    if len(verbs) < 5:
        bad.append(f"verb chart: {s['said'].get('verbs', '')[:200]!r}")
    bad += [f"verb {v}" for v, x in verbs.items() if v not in t["success_rate_by_verb"] or abs(float(x) - 100 * t["success_rate_by_verb"][v]) > 0.6]
    rows = list(csv.DictReader(open(FULL / "fleet.csv")))
    want = {}
    for r in rows:
        f, ok, n = want.get(r["lab"], (0, 0, 0))
        want[r["lab"]] = (f + (r["outcome"] == "failure"), ok + (r["outcome"] == "success"), n + 1)
    block = s["said"].get("pivot", "")
    block = block[block.find("[pivot]"):] if "[pivot]" in block else ""
    cells = re.findall(r'^\s*"([^"]*)"$', block, re.M)
    got = {}
    for i, c in enumerate(cells):
        if c in want and i + 3 < len(cells):
            try:
                got[c] = tuple(int(x.replace(",", "")) for x in cells[i + 1:i + 4])
            except ValueError:
                pass
    bad += [f"pivot {lab}: {got.get(lab)} vs {w}" for lab, w in want.items() if got.get(lab) != w]
    return not bad, ("; ".join(bad) if bad else f"chart: success by {len(chart)} labs = truth (PennPAL {chart.get('PennPAL')} … RAD {chart.get('RAD')}); "
                     f"by verb, {len(verbs)} verbs = truth; pivot: failure/success/total for all {len(got)} labs = fleet.csv")


def m4():
    import pyarrow.compute as pc
    import pyarrow.parquet as pq
    s = robots()
    t = data()
    bad = []
    asks = [l for l in s["log"] if l.startswith("ASK: ")]
    for q in ("failures where the gripper closed, let go and closed again", "episodes within 30% of the arm's joint speed limit"):
        if not any(q in l and "JOIN \"telemetry\"" in l for l in asks):
            bad.append(f"no ASK line for {q!r} with the implied join")
    m = re.search(r"\(([0-9,]+) rows", s["said"]["regrasped"])
    if not m or int(m.group(1).replace(",", "")) != len(t["regrasped_failures"]):
        bad.append(f"regrasped: {m.group(1) if m else '?'} rows, truth {len(t['regrasped_failures'])}")
    tele = pq.read_table(FULL / "telemetry.parquet", columns=["episode", "speed"])
    fast = sorted(set(tele.filter(pc.greater(tele["speed"], 1.5225))["episode"].to_pylist()))
    got = sorted(re.findall(r"^([SF]\d{5})\t", s["said"]["fastest"], re.M))
    if got != fast:
        bad.append(f"fastest {got} vs parquet {fast}")
    return not bad, "; ".join(bad) or f"regrasped {len(t['regrasped_failures']):,} = truth; within 30% of the limit {got} = parquet; both asked in words, JOIN LINKED written out"


def m5():
    import pymupdf
    s = robots()
    d = [l for l in s["log"] if l.startswith("DOCUMENT: paper droid-paper.pdf field=recorded_at")]
    if not d:
        return False, "no DOCUMENT line with the field"
    v = dict(re.findall(r"(page|x|y|w|h)=([0-9.]+)", d[-1]))
    doc = pymupdf.open(FULL / "paper" / "droid-paper.pdf")
    page = int(v["page"])
    x, y, w, h = (float(v[k]) for k in "xywh")
    text = doc[page].get_text("text", clip=pymupdf.Rect(x - 1, y - 1, x + w + 1, y + h + 1))
    return "15Hz" in text, f"page {page + 1}: the marked box reads {text.strip()!r}"


def m6():
    import pymupdf
    import pyarrow.parquet as pq
    robots()
    pack = ROBOTS / "pack"
    picked = ("F00118", "F00119", "F00124")
    tele = pq.read_table(FULL / "telemetry.parquet", columns=["episode", "t", "gripper_event"], filters=[("episode", "in", list(picked))]).to_pylist()
    bad = []
    for ep in picked:
        f = pack / f"{ep}.pdf"
        if not f.exists() or not (pack / f"{ep}.mp4").exists():
            bad.append(f"{ep}: pdf {f.exists()}, mp4 {(pack / f'{ep}.mp4').exists()}")
            continue
        d = pymupdf.open(f)
        txt = "".join(p.get_text() for p in d)
        offs = [r["t"] for r in tele if r["episode"] == ep and r["gripper_event"] == "open"]
        at = f"at {int(offs[-1]) // 60}:{int(offs[-1]) % 60:02d}" if offs else None
        if d.page_count < 2 or ep not in txt or not d[0].get_images():
            bad.append(f"{ep}.pdf: {d.page_count} pages, id {ep in txt}, frame {bool(d[0].get_images())}")
        if at and at not in txt:
            bad.append(f"{ep}.pdf doesn't show the release ({at}, the parquet's last open)")
        if "15Hz" not in txt:
            bad.append(f"{ep}.pdf lacks the paper's field")
    return not bad, "; ".join(bad) or "3 picked failures: a PDF each (its id; the frame at its last gripper release, its time = the parquet's; the paper's field and page) and a clip"


def m7():
    s = robots()
    t = data()
    land = [l for l in s["log"] if l.startswith("JOB: table landed telemetry.parquet")]
    q = [l for l in s["log"] if l.startswith("JOB: query landed")]
    bad = []
    if not land or f"{t['frames']:,} rows" not in land[0]:
        bad.append(f"telemetry landing: {land}")
    if t["episodes"] < 60000:
        bad.append(f"{t['episodes']} episodes")
    if s["slow"]:
        bad.append("SLOW lines")
    rep = (ROOT / "docs/goals/47-report.md")
    if not rep.exists() or "grow" not in rep.read_text().lower():
        bad.append("the report doesn't say how to grow")
    return not bad, "; ".join(bad) or f"{t['episodes']:,} episodes, {land[0][len('JOB: '):]}; queries {[x.split(' in ')[1] for x in q]}; 0 SLOW"


def m8():
    import numpy as np
    from PIL import Image
    log = clip()
    bad = []
    if "SLOW:" in log:
        bad.append("SLOW lines in the GTK run")
    if f"SLICE: telemetry episode={data()['hero']}" not in log:
        bad.append("no SLICE in the GTK run")
    c = ROOT / "docs/img/clip-robots.mp4"
    dur = float(run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(c)]).stdout.strip() or 0)
    if not 30 <= dur <= 45:
        bad.append(f"clip {dur:.1f} s")
    shots = sorted((G47 / "shots").glob("*.png"))
    lum = []
    for p in shots:
        im = Image.open(p)
        if im.size != (1440, 900):
            bad.append(f"{p.name} {im.size}")
        a = np.asarray(im.convert("RGB"), dtype=np.float64) / 255
        lum.append(float((0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]).mean()))
    if len(shots) < 11 or not all(0.10 <= v <= 0.30 for v in lum):
        bad.append(f"{len(shots)} shots, luminance {[round(v, 2) for v in lum]}")
    rep = ROOT / "docs/goals/47-report.md"
    if not rep.exists() or "## Record it yourself" not in rep.read_text():
        bad.append("no 'Record it yourself' section")
    return not bad, "; ".join(bad) or f"clip {dur:.1f} s; {len(shots)} shots at 1440×900, luminance {min(lum):.2f}–{max(lum):.2f}; 0 SLOW on GTK"


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5, "M6": m6, "M7": m7, "M8": m8}


def main():
    import headless
    headless.ensure()
    want = sys.argv[1:] or list(MILESTONES)
    failed = 0
    for k in want:
        try:
            ok, msg = MILESTONES[k]()
        except SystemExit as e:
            ok, msg = False, str(e)
        except Exception as e:  # (a crash is a FAIL with its reason, never a silent pass)
            import traceback
            ok, msg = False, "".join(traceback.format_exception(e))[-800:]
        print(f"{k}: {'PASS' if ok else 'FAIL'}  {msg}", flush=True)
        failed += not ok
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
