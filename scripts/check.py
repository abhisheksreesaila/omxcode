"""Milestone checker for GOAL.md (goal 39: omxplorer goes multimodal). Prints PASS/FAIL per milestone.

Run: scripts/check   (a subset: scripts/check M0 M4)
Each proof was written from GOAL.md's words before its work started (never weaker). Goal 36's checker is archived as
docs/goals/36-check.py. Truth comes from scripts/media_data.py's own scene model, never from the analysis under test.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
OUT = ROOT / "build" / "g39"
MEDIA = OUT / "media"
SITE = Path.home() / "Projects" / "omxlabs"


def run(cmd, timeout=3600, **kw):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, **kw)


def media():
    """The generated media (M0's script), made once per checkout."""
    if not (MEDIA / "truth.json").exists():
        r = run([sys.executable, "scripts/media_data.py", str(MEDIA)])
        if r.returncode:
            raise RuntimeError(f"media_data.py failed: {r.stderr[-500:]}")
    return json.loads((MEDIA / "truth.json").read_text())


def oks(test, labels, timeout=3600):
    """Runs a Mojo test; every label must print '<label>: ok'. Returns (ok, message, output)."""
    env = dict(os.environ, G39_MEDIA=str(MEDIA), G39_OUT=str(OUT))
    r = run(["pixi", "run", "mojo", "run", "-I", ".", test], timeout, env=env)
    out = r.stdout + r.stderr
    lines = [l.strip() for l in out.splitlines()]
    missing = [l for l in labels if not any(x.startswith(f"{l}: ok") for x in lines)]
    if r.returncode or missing:
        return False, f"{test}: exit {r.returncode}, no ok for {missing}: {' | '.join(lines)[-700:]}", out
    return True, "; ".join(labels), out


def number(out, label):
    m = re.search(rf"{re.escape(label)}:\s*([0-9.]+)", out)
    return float(m.group(1)) if m else None


def probe(path):
    r = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
             "stream=width,height,r_frame_rate:format=duration", "-of", "json", str(path)])
    j = json.loads(r.stdout or "{}")
    s, f = j.get("streams", [{}])[0], j.get("format", {})
    num, den = (s.get("r_frame_rate") or "0/1").split("/")
    return s.get("width"), s.get("height"), float(num) / float(den or 1), float(f.get("duration", 0))


def frame(path, n, w=1280, h=720):
    """Frame n as a numpy array (ffmpeg's own decode), for the reel's checks."""
    import numpy as np
    r = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-vf", f"select=eq(n\\,{n})", "-vframes", "1",
                        "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True)
    return np.frombuffer(r.stdout, np.uint8).reshape(h, w, 3)


def sharpness(img, box):
    import numpy as np
    x, y, w, h = box
    g = img[y:y + h, x:x + w].astype(float).mean(axis=2)
    lap = g[1:-1, 1:-1] * 4 - g[:-2, 1:-1] - g[2:, 1:-1] - g[1:-1, :-2] - g[1:-1, 2:]
    return float(np.var(lap))


def csv_rows(path):
    import csv
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def players(out):
    """PLAYER: t=.. and CURSOR: t=.. trace lines, in order."""
    p = [float(x) for x in re.findall(r"PLAYER: t=([0-9.]+)", out)]
    c = [float(x) for x in re.findall(r"CURSOR: t=([0-9.]+)", out)]
    return p, c


# ---------------------------------------------------------------------------------------------------------------------

def m0():
    with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
        for d in (a, b):
            r = run([sys.executable, "scripts/media_data.py", d])
            if r.returncode:
                return False, f"media_data.py failed: {r.stderr[-500:]}"
        need = ["warehouse.mp4", "drone_a.mp4", "drone_b.mp4", "shipments.csv", "telemetry_a.csv", "telemetry_b.csv", "truth.json"]
        miss = [f for f in need if not (Path(a) / f).exists()]
        if miss:
            return False, f"missing {miss}"
        for f in need:
            if f.endswith((".csv", ".json")) and (Path(a) / f).read_bytes() != (Path(b) / f).read_bytes():
                return False, f"{f} differs between two runs"
        for v in need[:3]:
            w, h, fps, dur = probe(Path(a) / v)
            if (w, h) != (1280, 720) or abs(fps - 30) > 0.01 or dur < 20:
                return False, f"{v}: {w}x{h} {fps} fps {dur:.1f} s"
    media()
    return True, "media + truth, two runs byte-equal"


def m1():
    media()
    ok, msg, _ = oks("tests/test_video.mojo", ["video open", "video frame", "video seek", "video speed"])
    return ok, msg


def m2():
    media()
    ok, msg, _ = oks("tests/test_player.mojo", ["player", "cursor"])
    if not ok:
        return False, msg
    for target in ("linux", "web"):
        r = run(["scripts/build.sh", "media", target])
        if r.returncode:
            return False, f"build media {target}: {(r.stdout + r.stderr)[-500:]}"
    import headless
    headless.ensure()
    shot = OUT / "m2-media-gtk.png"
    env = dict(os.environ, G39_MEDIA=str(MEDIA),
               MOJOUI_TEST="wait:500;tap:play;wait:2000;tap:pause;wait:300", MOJOUI_SHOT=str(shot), MOJOUI_WINDOW="1440x900")
    r = run([str(ROOT / "build/media/linux/media")], 600, env=env)
    out = r.stdout + r.stderr
    (OUT / "m2-media.txt").write_text(out)
    p, c = players(out)
    if r.returncode or not p or not c or not shot.exists():
        return False, f"GTK run: exit {r.returncode}, {len(p)} PLAYER, {len(c)} CURSOR lines, shot {shot.exists()}: {out[-400:]}"
    if p[-1] - p[0] < 1.0 or abs(p[-1] - c[-1]) > 1 / 30 + 1e-6:
        return False, f"t {p[0]:.3f}→{p[-1]:.3f}, cursor {c[-1]:.3f}"
    return True, f"{msg}; linux+web build; t {p[0]:.2f}→{p[-1]:.2f} s, cursor {c[-1]:.2f}"


def m3():
    ok, msg, out = oks("tests/test_imageops.mojo", ["blur", "crop", "text", "gpu equals cpu"])
    ms = number(out, "blur 720p ms")
    if ok and (ms is None or ms >= 2):
        return False, f"blur 720p ms: {ms}"
    return ok, f"{msg}; blur 720p {ms} ms" if ok else msg


def m4():
    t = media()
    ok, msg, out = oks("tests/test_videotable.mojo", ["videotable"])
    if not ok:
        return False, msg
    rows = csv_rows(OUT / "warehouse_regions.csv")
    pallets = t["warehouse"]["pallets"]
    found = codes = 0
    damaged_wrong = []
    for p in pallets:
        mine = [r for r in rows if r.get("code") == str(p["code"])]
        if mine:
            fs = [int(r["frame"]) for r in mine]
            if abs(min(fs) - p["first"]) <= 2 and abs(max(fs) - p["last"]) <= 2:
                found += 1
            codes += 1
            if not p["damaged"] and any(r.get("damaged") in ("1", "true", "True") for r in mine):
                damaged_wrong.append(p["code"])
    visible = [p for p in pallets if p.get("code_visible", True)]
    fps = number(out, "frames per s")
    if found < 0.95 * len(pallets) or codes < 0.95 * len(visible) or damaged_wrong or not fps or fps < 240:
        return False, f"found {found}/{len(pallets)}, codes {codes}/{len(visible)}, wrong damaged {damaged_wrong}, {fps} frames/s"
    return True, f"pallets {found}/{len(pallets)}, codes {codes}/{len(visible)}, {fps:.0f} frames/s"


def reel_ok(reel, t):
    w, h, fps, dur = probe(reel)
    want = sum(b - a for a, b in t["warehouse"]["damaged_intervals"])
    if abs(dur - want) > 0.2:
        return False, f"reel {dur:.2f} s, want {want:.2f}"
    src = MEDIA / "warehouse.mp4"
    checks = t["warehouse"]["face_checks"]  # [{"src_frame", "reel_frame", "box"}]
    worse = []
    for c in checks:
        a, b = sharpness(frame(src, c["src_frame"]), c["box"]), sharpness(frame(reel, c["reel_frame"]), c["box"])
        if b >= 0.2 * a:
            worse.append((c["reel_frame"], round(b / max(a, 1e-9), 2)))
    if not checks or worse:
        return False, f"faces not blurred: {worse or 'no face checks in truth'}"
    import numpy as np
    band = t["warehouse"]["id_band"]  # {"src_frame", "reel_frame", "box"}
    x, y, bw, bh = band["box"]
    d = np.abs(frame(src, band["src_frame"])[y:y + bh, x:x + bw].astype(int) - frame(reel, band["reel_frame"])[y:y + bh, x:x + bw].astype(int)).mean()
    if d < 8:
        return False, f"ID band barely differs ({d:.1f})"
    return True, f"reel {dur:.2f} s (want {want:.2f}), {len(checks)} faces blurred, ID band differs {d:.0f}"


def m5():
    t = media()
    ok, msg, _ = oks("tests/test_export.mojo", ["export"])
    return reel_ok(OUT / "reel.mp4", t) if ok else (False, msg)


def omx_build():
    r = run(["scripts/build.sh", "omxplorer", "linux"])
    if r.returncode:
        raise RuntimeError(f"build omxplorer: {(r.stdout + r.stderr)[-500:]}")


def m6():
    media()
    omx_build()
    home = OUT / "m6"
    (home / "docs").mkdir(parents=True, exist_ok=True)
    (home / "config").mkdir(parents=True, exist_ok=True)
    shot = OUT / "m6-omxplorer-gtk.png"
    import headless
    headless.ensure()
    env = dict(os.environ, OMX_DOCUMENTS=str(MEDIA), OMX_CONFIG=str(home / "config"), MOJOUI_TRACE="1",
               MOJOUI_TEST=os.environ.get("G39_M6_STEPS", "wait:800;open:warehouse.mp4;wait:1500;tap:play;wait:2000;tap:pause;wait:300"),
               MOJOUI_SHOT=str(shot), MOJOUI_WINDOW="1742x876")
    r = run([str(ROOT / "build/omxplorer/linux/omxplorer")], 900, env=env)
    out = r.stdout + r.stderr
    (OUT / "m6.txt").write_text(out)
    p, _ = players(out)
    if r.returncode or "TEST: " in out or len(p) < 2 or p[-1] - p[0] < 1.0 or not shot.exists():
        return False, f"exit {r.returncode}, PLAYER {p[:1]}..{p[-1:]}, shot {shot.exists()}: {out[-400:]}"
    r = run([sys.executable, "scripts/agent_client.py", "omxplorer", "--tools", "--media", str(MEDIA / "warehouse.mp4")], 600)
    tools = r.stdout + r.stderr
    miss = [n for n in ("play", "pause", "seek") if not re.search(rf"\b{n}\b", tools)]
    if miss:
        return False, f"agent tools lack {miss}: {tools[-400:]}"
    return True, f"video card plays {p[0]:.2f}→{p[-1]:.2f} s; tools play/pause/seek"


def scenario(name):
    media()
    omx_build()
    r = run([sys.executable, "scripts/scenario.py", name, "--media", str(MEDIA), "--out", str(OUT / name)], 1800)
    out = r.stdout + r.stderr
    (OUT / f"{name}.txt").write_text(out)
    if r.returncode:
        raise RuntimeError(f"scenario {name}: exit {r.returncode}: {out[-600:]}")
    return out


def m7():
    t = media()
    scenario("warehouse")
    d = OUT / "warehouse"
    ok, msg = reel_ok(d / "reel.mp4", t)
    if not ok:
        return False, msg
    got = sorted(r["shipment"] for r in csv_rows(d / "missing.csv"))
    want = sorted(t["warehouse"]["missing_shipments"])
    if got != want:
        return False, f"missing.csv {got[:8]}… ({len(got)}), want {want[:8]}… ({len(want)})"
    return True, f"{msg}; missing.csv = truth ({len(want)} shipments)"


def m8():
    import math
    t = media()
    out = scenario("drone")
    p, c = players(out)
    pairs = list(zip(p, c))[-3:]
    if len(pairs) < 3 or any(abs(a - b) > 1 / 30 + 1e-6 for a, b in pairs):
        return False, f"cursor vs video at seeks: {pairs}"
    d = OUT / "drone"

    def metres(a, b):
        return math.hypot((a[0] - b[0]) * 111320, (a[1] - b[1]) * 111320 * math.cos(math.radians(a[0])))

    for k in ("a", "b"):
        mine = [(float(r["lat"]), float(r["lon"])) for r in csv_rows(d / f"defects_{k}.csv")]
        truth = [(x["lat"], x["lon"]) for x in t["drone"][f"defects_{k}"]]
        hit = sum(1 for x in truth if any(metres(x, m) <= 5 for m in mine))
        if hit < 0.9 * len(truth):
            return False, f"defects_{k}: {hit}/{len(truth)} within 5 m"
    worse = sorted(r["asset"] for r in csv_rows(d / "worse.csv"))
    if worse != sorted(t["drone"]["worse"]):
        return False, f"worse.csv {worse}, want {sorted(t['drone']['worse'])}"
    wp = csv_rows(d / "waypoints.csv")
    want = {a["asset"]: a for a in t["drone"]["assets"] if a["asset"] in worse}
    if sorted(r["asset"] for r in wp) != sorted(want) or any(
            abs(float(r["lat"]) - want[r["asset"]]["lat"]) > 1e-4 or abs(float(r["lon"]) - want[r["asset"]]["lon"]) > 1e-4 for r in wp):
        return False, f"waypoints {[(r['asset'], r['lat'], r['lon']) for r in wp]}"
    return True, f"cursor synced at 3 seeks; defects ≥ 90 % within 5 m; worse = truth ({len(worse)}); waypoints exact"


def m9():
    for clip in ("clip-warehouse.mp4", "clip-drone.mp4"):
        f = SITE / "assets" / "img" / clip
        if not f.exists() or probe(f)[3] < 8:
            return False, f"{clip}: {'missing' if not f.exists() else f'{probe(f)[3]:.1f} s'}"
    cover, deck = (SITE / "omxplorer" / "index.html").read_text(), (SITE / "omxplorer" / "deck.html").read_text()
    for clip in ("clip-warehouse.mp4", "clip-drone.mp4"):
        if clip not in cover or clip not in deck:
            return False, f"{clip} not on the cover and in the deck"
    home = (SITE / "index.html").read_text().lower()
    if "four breakthrough technologies" not in home or home.find("omxplorer") > home.find("omxcore"):
        return False, "omxlabs page doesn't lead with omxplorer and 'four breakthrough technologies'"
    shot = Path("/tmp/oxshot/shot.py")
    bad = []
    for page in ("index.html", "omxplorer/index.html", "omxcore/index.html", "omxcode/index.html", "omxconsole/index.html", "omxqua/index.html"):
        r = run([sys.executable, str(shot), str(SITE / page), "g39-" + page.replace("/", "-")], 600)
        o = r.stdout + r.stderr
        if r.returncode or re.search(r"overflow[^\n]*[1-9]", o, re.I) or re.search(r"console error(?!s?: 0)", o, re.I):
            bad.append(f"{page}: {o.strip()[-200:]}")
    return (not bad), ("; ".join(bad) if bad else "clips on cover + deck; leads with omxplorer; 6 covers clean at 1440/390")


def m10():
    f = ROOT / "docs" / "research" / "inprocess-ai.md"
    if not f.exists():
        return False, "docs/research/inprocess-ai.md missing"
    t = f.read_text()
    opts = len(re.findall(r"^#+\s*Option", t, re.M | re.I))
    if opts < 3 or not re.search(r"recommend", t, re.I):
        return False, f"{opts} options, recommendation {'yes' if re.search('recommend', t, re.I) else 'no'}"
    return True, f"{opts} options and a recommendation"


def m11():
    media()
    ok, msg, _ = oks("tests/test_mediatimeline.mojo", ["timeline", "edit"])
    if not ok:
        return False, msg
    r = run(["scripts/build.sh", "media", "linux"])
    if r.returncode:
        return False, f"build media: {(r.stdout + r.stderr)[-400:]}"
    import headless
    headless.ensure()
    shot = OUT / "m11-editor-gtk.png"
    env = dict(os.environ, G39_MEDIA=str(MEDIA), MOJOUI_TRACE="1", MOJOUI_SHOT=str(shot), MOJOUI_WINDOW="1440x900",
               MOJOUI_TEST=os.environ.get("G39_M11_STEPS", "wait:600;tap:edit;wait:400;tap:split;wait:300;tap:trim-end;wait:300;tap:play;wait:1000;tap:pause;wait:300"))
    r = run([str(ROOT / "build/media/linux/media")], 600, env=env)
    out = r.stdout + r.stderr
    (OUT / "m11.txt").write_text(out)
    lines = re.findall(r"TIMELINE: .*", out)
    if r.returncode or "TEST: " in out or not lines or not shot.exists() or not any("split" in l for l in lines) or not any("trim" in l for l in lines):
        return False, f"exit {r.returncode}, {len(lines)} TIMELINE lines, shot {shot.exists()}: {out[-400:]}"
    src = (ROOT / "examples/omxplorer/app.mojo").read_text() + (ROOT / "mojoui/mediacard.mojo").read_text()
    if "MediaTimeline" not in src:
        return False, "omxplorer's video card doesn't open the editor (no MediaTimeline in mediacard/app)"
    return True, f"{msg}; {len(lines)} TIMELINE lines; editor in omxplorer"


def m12():
    import math
    t = media()
    env = dict(os.environ, G39_MEDIA=str(MEDIA), G39_OUT=str(OUT))
    out = ""
    for test, label in (("tests/test_visionmodel.mojo", "visionmodel"), ("tests/test_findlike.mojo", "findlike")):
        r = run(["pixi", "run", "-e", "models", "mojo", "run", "-I", ".", test], 3600, env=env)
        o = r.stdout + r.stderr
        out += o
        if r.returncode or not re.search(rf"^{label}: ok", o, re.M):
            return False, f"{test}: exit {r.returncode}: {o[-500:]}"
    want = set()
    for a, b in t["warehouse"]["damaged_frames"]:
        want.update(range(a, b + 1))
    got = {int(r["frame"]) for r in csv_rows(OUT / "findlike_damaged.csv")}
    rec, prec = len(got & want) / max(len(want), 1), len(got & want) / max(len(got), 1)
    marks = [(float(r["lat"]), float(r["lon"])) for r in csv_rows(OUT / "findlike_drone_a.csv")]

    def metres(a, b):
        return math.hypot((a[0] - b[0]) * 111320, (a[1] - b[1]) * 111320 * math.cos(math.radians(a[0])))

    hit = sum(1 for d in t["drone"]["defects_a"] if any(metres((d["lat"], d["lon"]), m) <= 5 for m in marks))
    secs = number(out, "scan s")
    if rec < 0.95 or prec < 0.85 or hit < 4 or secs is None or secs > 15:
        return False, f"recall {rec:.3f}, precision {prec:.3f}, drone {hit}/5, scan {secs} s"
    return True, f"damaged frames recall {rec:.3f} precision {prec:.3f}; drone {hit}/5 marks; scan {secs:.1f} s"


MILESTONES = {f"M{i}": globals()[f"m{i}"] for i in range(13)}

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    pick = sys.argv[1:] or list(MILESTONES)
    fails = 0
    for k in pick:
        try:
            ok, msg = MILESTONES[k]()
        except Exception as e:  # a crash is a FAIL with its reason
            ok, msg = False, f"{type(e).__name__}: {e}"
        fails += not ok
        print(f"{k}: {'PASS' if ok else 'FAIL'}  {msg}", flush=True)
    sys.exit(1 if fails else 0)
