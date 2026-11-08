"""Goal 61's proof: fresh videos for the omxplorer page, in the tiled shell (GOAL.md). Prints "Mn: PASS|FAIL  why".

    pixi run python docs/goals/61-check.py [M0 M1 ...]      (default: every milestone)

Reads the takes the clips were made from (build/g47/story, build/clips/<name>: timeline.json, raw.log, screens.txt) and
the clips themselves (ffprobe, Chromium). It doesn't re-shoot: `scripts/clips.py robots` and `scripts/clipshots.py all`
do (their contact sheets are looked at by a person: build/g47/clipcheck, build/clips/<name>/check).
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IMG = ROOT / "docs/img"
STORY = ROOT / "build/g47/story"
CLIPS = ROOT / "build/clips"
WIN = (3840, 2160)


def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,r_frame_rate:format=duration",
                        "-of", "json", str(path)], capture_output=True, text=True)
    j = json.loads(r.stdout or "{}")
    s = (j.get("streams") or [{}])[0]
    num, den = (s.get("r_frame_rate") or "0/1").split("/")
    return s.get("width"), s.get("height"), round(int(num) / max(int(den), 1)), float(j.get("format", {}).get("duration", 0))


def clip_ok(name, probs, at_least=10.0, poster=True):
    p = IMG / f"{name}.mp4"
    if not p.exists():
        probs.append(f"no {p.name}")
        return None
    w, h, fps, d = probe(p)
    if (w, h, fps) != (1920, 1080, 30) or d < at_least:
        probs.append(f"{p.name}: {w}×{h} {fps} fps {d:.1f} s")
    if poster and not (IMG / f"{name}.jpg").exists():
        probs.append(f"no {name}.jpg poster")
    return d


def inside(r, outer, slack=4):
    return r[0] >= outer[0] - slack and r[1] >= outer[1] - slack and r[0] + r[2] <= outer[0] + outer[2] + slack and r[1] + r[3] <= outer[1] + outer[3] + slack


def m0():
    probs = []
    d = (ROOT / "scripts/director.py").read_text()
    for name in ("Canvas", "caption", "card", "write", "lerp_stage", "fit169", "grown"):
        if not re.search(rf"^(def|class) {name}\b", d, re.M):
            probs.append(f"director has no {name}")
    rc, cs = (ROOT / "scripts/robotclip.py").read_text(), (ROOT / "scripts/clipshots.py").read_text()
    for f, text in (("robotclip.py", rc), ("clipshots.py", cs)):
        if "from director import" not in text:
            probs.append(f"{f} doesn't use the director")
        if re.search(r"^(class Canvas|def caption|def card)\b", text, re.M):
            probs.append(f"{f} has its own copy of the director")
    # no fixed screen coordinates or card sizes: clicks by position, the old floating cards' 1300×700 / 1290
    for f, text in (("robotclip.py", rc), ("clipshots.py", cs)):
        for pat in (r"click:\d", r"drag:\d", r"\b1300, 700\b", r"\b1290\b", r"- 330\b"):
            if re.search(pat, text):
                probs.append(f"{f}: a fixed coordinate ({pat})")
    return (not probs), ("; ".join(probs) if probs else "scripts/director.py: cards, captions, cameras (any card shape lifted), encoding; robotclip and clipshots use it; no clicks by position or fixed card sizes")


def m1():
    probs = []
    d = clip_ok("clip-robots", probs, 40)
    clip_ok("clip-robots-15s", probs, 12, poster=False)
    t = json.loads((STORY / "timeline.json").read_text())
    if tuple(t["win"]) != WIN:
        probs.append(f"the take is {t['win']}, not a 2× 3840×2160 one")
    for s in t["scenes"]:
        for k, v in s.items():
            if isinstance(v, list) and len(v) == 4 and all(isinstance(x, (int, float)) for x in v):
                if not inside(v, [0, 0, *WIN]):
                    probs.append(f"{s['name']}.{k} {v} leaves the window")
        cards = s.get("cards") or {}
        if s.get("video") and cards.get("episode") and not inside(s["video"], cards["episode"]):
            probs.append(f"{s['name']}: the video isn't on the episode card")
        if s.get("chart") and cards.get("telemetry") and not inside(s["chart"], cards["telemetry"]):
            probs.append(f"{s['name']}: the chart isn't on the telemetry card")
    log = (STORY / "raw.log").read_text(errors="replace")
    seeks = [float(x) for x in re.findall(r"→ seek \{'value': ([\d.]+)\}", (STORY / "raw.log").read_text(errors="replace"))] or \
        [float(x) for x in re.findall(r"seek .*?([\d.]+)", log)[:0]]
    freeze = next((s for s in t["scenes"] if s["name"] == "freeze"), None)
    if not freeze:
        probs.append("no freeze scene")
    q = re.search(r"JOB: query landed in ([\d.,]+) ms \(([\d,]+) rows\)", log)
    if not q or q.group(0) != t["query_ms"]:
        probs.append(f"the answer's numbers aren't the take's: {t['query_ms']!r}")
    check = ROOT / "build/g47/clipcheck"
    for f in ("08-moment-2.png", "contact-sheet.png", "11-answer.png"):
        if not (check / f).exists():
            probs.append(f"no {f}")
    rc = (ROOT / "scripts/robotclip.py").read_text()
    if "DROP_T = 12.7" not in rc or "value=DROP_T" not in rc:
        probs.append("the freeze isn't at DROP_T 12.7 s")
    return (not probs), ("; ".join(probs)[:1200] if probs else
                         f"{d:.1f} s at 1920×1080/30 from a 2× take; every scene's rectangles in the window, video and chart on their cards; "
                         f"the freeze at 12.7 s; captions from the take ({q.group(2)} rows in {q.group(1)} ms, {t['fleet_rows']:,} runs, {t['tele_rows']:,} rows)")


def takes(name):
    d = CLIPS / name
    return json.loads((d / "timeline.json").read_text()), (d / "raw.log").read_text(errors="replace"), d


def m2():
    probs = []
    d = clip_ok("clip-island-100m", probs, 12)
    t, log, folder = takes("island")
    landed = re.findall(r"^JOB: landed (chart\d+) ([\d.,]+) ms", log, re.M)
    started = re.findall(r"^JOB: start (chart\d+) (.*)$", log, re.M)
    asked = [f"{ms} ms" for (c, ms), (_, what) in zip(landed, started) if "median" in what]
    if t["answers"] != asked:
        probs.append(f"captions {t['answers']} vs the jobs' {asked}")
    import pyarrow.parquet as pq
    n = pq.ParquetFile(ROOT / "build/g20/big.parquet").metadata.num_rows  # (the title card's "100 million rows": the file's own count)
    if n != 100_000_000:
        probs.append(f"the file has {n:,} rows, not 100 million")
    op = next((s for s in t["scenes"] if s["name"] == "opening"), None)
    if not op or op["t1"] - op["t0"] < 1.0:
        probs.append("no opening scene")
    if not any(s.get("island") for s in t["scenes"]):
        probs.append("no island bounds in the take")
    for f in ("02-opening.png", "04-ask.png", "05-ask.png", "contact-sheet.png"):
        if not (folder / "check" / f).exists():
            probs.append(f"no check/{f}")
    return (not probs), ("; ".join(probs)[:1200] if probs else f"{d:.1f} s; opening filmed from the call to the landing; captions = the jobs' own times {asked}")


def m3():
    probs = []
    d = clip_ok("clip-sentence-gtk", probs, 12)
    t, log, folder = takes("sentence")
    screens = (folder / "screens.txt").read_text() if (folder / "screens.txt").exists() else ""
    shown = re.findall(r'^\s+"([\d.,]+ ms)"\s*$', screens, re.M)
    if len(t["answers"]) != 3 or any(a not in shown for a in t["answers"]):
        probs.append(f"captions {t['answers']} vs the card's own times {shown}")
    for f in ("03-ask.png", "04-ask.png", "05-ask.png"):
        if not (folder / "check" / f).exists():
            probs.append(f"no check/{f}")
    return (not probs), ("; ".join(probs)[:1200] if probs else f"{d:.1f} s; three asks, each caption the time under the chart's sentence {t['answers']}")


def m4():
    probs = []
    d = clip_ok("clip-models", probs, 12)
    t, log, folder = takes("models")
    line = t.get("applied", "")
    if not line or line not in log:
        probs.append(f"the applied line isn't the take's: {line!r}")
    if "scene(" not in line:
        probs.append("not a scene() call")
    labels = next((x for x in t["scenes"] if x["name"] == "labels"), {})
    if not labels.get("card"):
        probs.append("the labels card never landed in the take")
    if "apply-scene" not in (ROOT / "scripts/clipshots.py").read_text().split("def compose_models")[1].split("def contact")[0]:
        probs.append("no caption names the agent's tool")
    if "clip-models.mp4" not in (ROOT / "docs/models.html").read_text():
        probs.append("docs/models.html doesn't show it")
    return (not probs), ("; ".join(probs)[:1200] if probs else f"{d:.1f} s; {line.split(': ', 1)[-1][:90]}; the labels card landed; the agent's tool named (apply-scene); on models.html")


def m5():
    from playwright.sync_api import sync_playwright
    probs, played = [], []
    pages = {"docs/omxplorer.html": ["clip-island-100m", "clip-robots", "clip-sentence-gtk"], "docs/models.html": ["clip-models"],
             "docs/index.html": ["clip-island-100m"], "docs/gallery/index.html": ["clip-robots"]}
    for page, clips in pages.items():
        text = (ROOT / page).read_text()
        for c in clips:
            tag = re.search(rf'<video[^>]*src="[^"]*{c}\.mp4"[^>]*>', text)
            if not tag:
                probs.append(f"{page} doesn't use {c}")
                continue
            poster = re.search(r'poster="([^"]+)"', tag.group(0))
            if not poster or not (ROOT / page).parent.joinpath(poster.group(1)).resolve().exists():
                probs.append(f"{page}: {c}'s poster missing")
            if 'aria-label="' not in tag.group(0):
                probs.append(f"{page}: {c} has no description")
    for c in ("clip-robots", "clip-island-100m", "clip-sentence-gtk", "clip-models"):
        size = (IMG / f"{c}.mp4").stat().st_size
        if size > 12_000_000:
            probs.append(f"{c}.mp4 is {size / 1e6:.1f} MB")
    with sync_playwright() as pw:
        b = pw.chromium.launch(executable_path="/usr/bin/chromium", headless=True)
        pg = b.new_page()
        for page in pages:
            pg.goto((ROOT / page).as_uri())
            pg.wait_for_timeout(500)
            states = pg.evaluate("""async () => { const vs = [...document.querySelectorAll('video')];
                return await Promise.all(vs.map(v => new Promise(res => { v.muted = true; v.preload = 'auto'; v.load();
                  const done = () => res([v.currentSrc.split('/').pop(), v.readyState, v.error ? v.error.code : 0]);
                  v.addEventListener('loadeddata', done, {once: true}); v.addEventListener('error', done, {once: true}); setTimeout(done, 8000); }))); }""")
            for src, ready, err in states:
                if src.startswith("clip-") and (ready < 2 or err):
                    probs.append(f"{page}: {src} readyState {ready}, error {err}")
                elif src.startswith("clip-"):
                    played.append(src)
        b.close()
    return (not probs), ("; ".join(probs)[:1200] if probs else f"the pages use the four clips with posters and descriptions; {len(played)} videos load in Chromium; all under 12 MB")


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5}

if __name__ == "__main__":
    bad = 0
    for k in sys.argv[1:] or list(MILESTONES):
        try:
            ok, why = MILESTONES[k]()
        except Exception as e:
            ok, why = False, f"crashed: {e!r}"
        print(f"{k}: {'PASS' if ok else 'FAIL'}  {why}", flush=True)
        bad += not ok
    sys.exit(1 if bad else 0)
