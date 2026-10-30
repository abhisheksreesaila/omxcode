"""Milestone checker for GOAL.md (goal 41: the claim, answered in two minutes, and nothing freezes). PASS/FAIL per milestone.

Run: scripts/check   (a subset: scripts/check M0 M4)
Each proof was written from GOAL.md's words before its work started (never weaker). Goal 39's checker is archived as
docs/goals/39-check.py and is re-run for the milestones that must keep passing. Truth comes from scripts/claims_data.py's
own model (and goal 39's scene model), never from the code under test.
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
OUT = ROOT / "build" / "g41"
DATA = OUT / "data"
SITE = Path.home() / "Projects" / "omxlabs"
BUDGET = "50"  # ms: the watchdog's budget on headless Xvfb (CPU drawing); GOAL.md's assumption
WINDOW = "1742x876"


def run(cmd, timeout=3600, **kw):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, **kw)


def data():
    """M0's data, made once per checkout."""
    if not (DATA / "truth.json").exists():
        r = run([sys.executable, "scripts/claims_data.py", str(DATA)])
        if r.returncode:
            raise RuntimeError(f"claims_data.py failed: {r.stderr[-500:]}")
    return json.loads((DATA / "truth.json").read_text())


def oks(test, labels, timeout=3600, env_name=None):
    """Runs a Mojo test; every label must print '<label>: ok'. Returns (ok, message, output)."""
    env = dict(os.environ, G41_DATA=str(DATA), G41_OUT=str(OUT))
    cmd = ["pixi", "run"] + (["-e", env_name] if env_name else []) + ["mojo", "run", "-I", ".", test]
    r = run(cmd, timeout, env=env)
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


def csv_rows(path):
    import csv
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def slow_lines(out):
    return re.findall(r"^SLOW: .*$", out, re.M)


def gaps(out):
    return [float(x) for x in re.findall(r"GAPS: \d+ frames, longest ([0-9.]+) ms", out)]


def old_check(*names):
    """Goal 39's archived checker for milestones that must keep passing (its own data under build/g39)."""
    r = run([sys.executable, "docs/goals/39-check.py", *names], 7200)
    out = r.stdout + r.stderr
    bad = [l for l in out.splitlines() if re.match(r"M\d+: FAIL", l)]
    if r.returncode or bad:
        return False, f"goal 39 {names}: {' | '.join(bad) or out[-300:]}"
    return True, f"goal 39 {'/'.join(names)} still PASS"


def build(app, target="linux"):
    r = run(["scripts/build.sh", app, target])
    if r.returncode:
        raise RuntimeError(f"build {app} {target}: {(r.stdout + r.stderr)[-500:]}")


def omx(name, steps, budget=BUDGET, extra=None, timeout=1200):
    """A headless omxplorer session (GTK) over M0's data; returns its output (also written to OUT/<name>.txt)."""
    import headless
    headless.ensure()
    home = OUT / name
    (home / "config").mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, OMX_DOCUMENTS=str(DATA), OMX_CONFIG=str(home / "config"), MOJOUI_TRACE="1",
               MOJOUI_BUDGET_MS=budget, MOJOUI_TEST=steps, MOJOUI_SHOT=str(OUT / f"{name}-gtk.png"), MOJOUI_WINDOW=WINDOW)
    env.update(extra or {})
    r = run([str(ROOT / "build/omxplorer/linux/omxplorer")], timeout, env=env)
    out = r.stdout + r.stderr
    (OUT / f"{name}.txt").write_text(out)
    if r.returncode or "TEST: " in out:
        raise RuntimeError(f"{name}: exit {r.returncode}: {[l for l in out.splitlines() if 'TEST: ' in l][:3] or out[-400:]}")
    return out


def web(app, steps, shot=None, extra=None, timeout=1800):
    """The same steps on the app's web build in headless Chromium (scripts/drive.py; the host's log lines join its output)."""
    env = dict(os.environ, VIEWPORT=WINDOW, MOJOUI_BUDGET_MS=BUDGET, OMX_DOCUMENTS=str(DATA))
    env.update(extra or {})
    return run([sys.executable, "scripts/drive.py", f"build/{app}/web", steps] + ([str(shot)] if shot else []), timeout, env=env)


def lum(img):
    import numpy as np
    a = np.asarray(img.convert("RGB"), float) / 255.0
    return a @ np.array([0.2126, 0.7152, 0.0722])


# ---------------------------------------------------------------------------------------------------------------------

def m0():
    with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
        for d in (a, b):
            r = run([sys.executable, "scripts/claims_data.py", d], 1800)
            if r.returncode:
                return False, f"claims_data.py failed: {r.stderr[-500:]}"
        need = ["dock.mp4", "shipments.csv", "forklift_log.csv", "truth.json"]
        miss = [f for f in need if not (Path(a) / f).exists()]
        pdfs = sorted((Path(a) / "bol").glob("BOL-*.pdf"))
        if miss or not pdfs:
            return False, f"missing {miss}, {len(pdfs)} BOL PDFs"
        for f in need[1:]:
            if (Path(a) / f).read_bytes() != (Path(b) / f).read_bytes():
                return False, f"{f} differs between two runs"
        import fitz  # PyMuPDF
        for p in pdfs:
            q = Path(b) / "bol" / p.name
            ta = "".join(pg.get_text() for pg in fitz.open(p))
            tb = "".join(pg.get_text() for pg in fitz.open(q)) if q.exists() else None
            if not ta.strip() or ta != tb:
                return False, f"{p.name}: text {'empty' if not ta.strip() else 'differs between runs'}"
        t = json.loads((Path(a) / "truth.json").read_text())
        for k in ("bols", "disputed", "damage_frame", "log_offset_s"):
            if k not in t:
                return False, f"truth.json has no {k}"
        if not t["disputed"] or len(t["bols"]) != len(pdfs):
            return False, f"{len(t['disputed'])} disputed, {len(t['bols'])} BOLs in truth vs {len(pdfs)} PDFs"
        w, h, fps, dur = probe(Path(a) / "dock.mp4")
        if (w, h) != (1280, 720) or dur < 20:
            return False, f"dock.mp4: {w}x{h} {dur:.1f} s"
    data()
    return True, f"{len(pdfs)} BOLs, {len(t['disputed'])} disputed; two runs byte-equal (PDF text too)"


def m1():
    build("slowcheck")
    build("slowcheck", "web")
    import headless
    headless.ensure()
    env = dict(os.environ, MOJOUI_BUDGET_MS=BUDGET, MOJOUI_TRACE="1",
               MOJOUI_TEST="wait:1500;tap:fast;wait:300;tap:slow;wait:300;tap:fast;wait:300")
    r = run([str(ROOT / "build/slowcheck/linux/slowcheck")], 300, env=env)
    out = r.stdout + r.stderr
    (OUT / "m1-gtk.txt").write_text(out)
    lines = out.splitlines()
    s = [i for i, l in enumerate(lines) if l.startswith("SLOW: update")]
    if r.returncode or not s:
        return False, f"GTK: exit {r.returncode}, no SLOW: update line: {out[-300:]}"
    if not re.search(r"^SLOW: update \S.* ([0-9.]+) ms$", lines[s[0]]) or float(re.search(r"([0-9.]+) ms$", lines[s[0]]).group(1)) < 70:
        return False, f"GTK SLOW line malformed or too short: {lines[s[0]]}"
    if len(s) != 1:
        return False, f"GTK: {len(s)} SLOW: update lines (want 1, after the slow tap only): {[lines[i] for i in s]}"
    # the web host: the same app served, the same steps through the web driver
    r = web("slowcheck", "wait:1500;tap:fast;wait:300;tap:slow;wait:300;tap:fast;wait:300")
    w = r.stdout + r.stderr
    (OUT / "m1-web.txt").write_text(w)
    ws = re.findall(r"^SLOW: update .*$", w, re.M)
    if r.returncode or len(ws) != 1:
        return False, f"web: exit {r.returncode}, {len(ws)} SLOW: update lines: {w[-300:]}"
    build("jobwake")
    r = run([str(ROOT / "build/jobwake/linux/jobwake")], 300, env=dict(os.environ))
    jw = r.stdout + r.stderr
    if r.returncode or not re.search(r"JOBWAKE FREEZE: .*: PASS", jw):
        return False, f"jobwake: exit {r.returncode}: {jw[-300:]}"
    return True, f"{lines[s[0]]}; web too; jobwake PASS"


def m2():
    t = data()
    ok, msg, _ = oks("tests/test_player.mojo", ["player", "cursor", "player async"])
    if not ok:
        return False, msg
    build("omxplorer")
    still = DATA / "still.png"
    if not still.exists():
        run(["ffmpeg", "-v", "error", "-y", "-ss", "5", "-i", str(DATA / "dock.mp4"), "-frames:v", "1", str(still)])
    scrubs = ";".join(f"dragat:seek={x},500,{(-1) ** k * 60},0" for k, x in enumerate(range(50, 1000, 47)))[:4000]
    steps = (f"wait:1500;open:dock.mp4;wait:1200;gaps:start;{scrubs};gaps:600;tap:play;wait:2000;tap:pause;"
             f"tap:edit;wait:1200;tap:chip-blur;wait:800;tap:done;wait:400;open:still.png;wait:1200")
    out = omx("m2", steps)
    s, g = slow_lines(out), gaps(out)
    if s or not g or g[0] >= 120:
        return False, f"{len(s)} SLOW lines {s[:3]}, GAPS {g}"
    ok2, m = old_check("M6", "M7", "M11")
    if not ok2:
        return False, m
    return True, f"player async; session 0 SLOW at {BUDGET} ms, scrub gaps {g[0]:.0f} ms; {m}"


def m3():
    data()
    src = (ROOT / "examples/omxplorer/app.mojo").read_text()
    if re.search(r"\bstart_job\(", src):
        return False, "examples/omxplorer/app.mojo still calls start_job("
    for f in ("mojoui/videojobs.mojo", "mojoui/mediatimeline_jobs.mojo"):
        if re.search(r"\bstart_job\(", (ROOT / f).read_text()):
            return False, f"{f} calls start_job( (not start_ui_job)"
    big = OUT / "big.csv"
    if not big.exists():
        import random
        rnd = random.Random(41)
        with open(big, "w") as f:
            f.write("id,carrier,usd\n")
            for i in range(1_000_000):
                f.write(f"{i},{rnd.choice(['Ridge', 'Polar', 'Atlas', 'Kite'])},{rnd.randint(1, 9999)}\n")
    build("omxplorer")
    steps = (f"wait:1500;pick:Table=" + str(big) + ";wait:4000;"
             "type:query=SELECT carrier, SUM(usd) AS usd FROM big GROUP BY carrier;submit:query;wait:3000;"
             "tap:Export CSV;wait:3000;open:dock.mp4;wait:1500;tap:analyze;wait:15000")
    out = omx("m3", steps, extra={"OMX_EXPORTS": str(OUT / "m3-exports")})
    s = slow_lines(out)
    if s or not re.search(r"^JOB: .*quer", out, re.M | re.I):
        return False, f"{len(s)} SLOW lines {s[:3]}; JOB line for the query: {bool(re.search(r'^JOB: .*quer', out, re.M | re.I))}"
    ok2, m = old_check("M7")
    return (ok2, m) if not ok2 else (True, f"no start_job; 1M-row insert, query, export, analyze: 0 SLOW; {m}")


def m4():
    for app in ("examples/media/app.mojo", "examples/omxplorer/app.mojo"):
        if "open_with(" not in (ROOT / app).read_text():
            return False, f"{app} doesn't use MediaTimeline.open_with"
    if not list((ROOT / "mojoui").glob("videocard*.mojo")):
        return False, "no mojoui/videocard*.mojo"
    if "def video_for_log" not in (ROOT / "mojoui/trackcard.mojo").read_text():
        return False, "video_for_log isn't in mojoui/trackcard.mojo"
    if "def video_for_log" in (ROOT / "examples/omxplorer/app.mojo").read_text():
        return False, "omxplorer still defines video_for_log"
    data()
    build("omxplorer")
    steps = ("wait:1500;open:dock.mp4;wait:1500;a11y;tap:edit;wait:1200;a11y;tap:done;wait:300;"
             "pick:Table=" + str(DATA / "shipments.csv") + ";wait:1500;a11y")
    out = omx("m4", steps, budget="100000")
    counts = [int(x) for x in re.findall(r"^A11Y: (\d+) unnamed", out, re.M)]
    if len(counts) != 3 or any(counts):
        return False, f"A11Y counts {counts}: {re.findall(r'^A11Y UNNAMED: .*$', out, re.M)[:5]}"
    r = run([sys.executable, "scripts/components.py"])
    st = run(["git", "status", "--porcelain", "docs/components.md"]).stdout.strip()
    if r.returncode or st:
        return False, f"components matrix stale ({st or r.stderr[-200:]})"
    return True, "open_with in both apps; videocard + video_for_log in mojoui; A11Y 0/0/0 unnamed; matrix fresh"


def m5():
    from PIL import Image
    data()
    build("omxplorer")
    build("omxplorer", "web")
    steps = "wait:1500;open:dock.mp4;wait:1200;pick:Table=" + str(DATA / "shipments.csv") + ";wait:1500;regions:" + str(OUT / "m5-regions.json")
    omx("m5", steps, budget="100000")
    shots = {"gtk": OUT / "m5-gtk.png"}
    r = web("omxplorer", steps.replace(str(OUT / "m5-regions.json"), str(OUT / "m5-regions-web.json")), OUT / "m5-web.png")
    if r.returncode or not (OUT / "m5-web.png").exists():
        return False, f"web run: exit {r.returncode}: {(r.stdout + r.stderr)[-300:]}"
    shots["web"] = OUT / "m5-web.png"
    res = []
    for host, shot in shots.items():
        rj = OUT / ("m5-regions.json" if host == "gtk" else "m5-regions-web.json")
        if not shot.exists() or not rj.exists():
            return False, f"{host}: shot {shot.exists()}, regions {rj.exists()}"
        L = lum(Image.open(shot))
        mean = float(L.mean())
        if not 0.10 <= mean <= 0.30:
            return False, f"{host}: mean luminance {mean:.3f} (want 0.10–0.30)"
        regions = json.loads(rj.read_text())  # [{"name", "x", "y", "w", "h"}] in the shot's pixels
        names = {r_["name"] for r_ in regions}
        need = {"sidebar", "toolbar", "sheet", "inspector", "status", "card"}
        if not need <= {n.split(":")[0] for n in names}:
            return False, f"{host}: regions {sorted(names)} lack {sorted(need - {n.split(':')[0] for n in names})}"
        import numpy as np
        weak = []
        H, W = L.shape
        for g in regions:
            x, y, w, h = int(g["x"]), int(g["y"]), int(g["w"]), int(g["h"])
            # each side the shot contains: the boundary line (best of ±1 px) against 3 px inside and 3 px outside
            sides = []
            if 3 <= y and y + 3 < H:
                sides.append((lambda o: L[y + o, x:x + w], L[y + 3, x:x + w], L[y - 3, x:x + w]))
            if 3 <= y + h - 1 < H - 3:
                sides.append((lambda o: L[y + h - 1 + o, x:x + w], L[y + h - 4, x:x + w], L[y + h + 2, x:x + w]))
            if 3 <= x and x + 3 < W:
                sides.append((lambda o: L[y:y + h, x + o], L[y:y + h, x + 3], L[y:y + h, x - 3]))
            if 3 <= x + w - 1 < W - 3:
                sides.append((lambda o: L[y:y + h, x + w - 1 + o], L[y:y + h, x + w - 4], L[y:y + h, x + w + 2]))
            for k, (line, ins, outs) in enumerate(sides):
                best = max(float((np.maximum.reduce([np.abs(line(o) - ins), np.abs(line(o) - outs), np.abs(ins - outs)]) >= 0.04).mean())
                           for o in (-1, 0, 1))
                if best < 0.8:
                    weak.append(f"{g['name']}#{k} {best:.2f}")
        if weak:
            return False, f"{host}: weak borders {weak[:6]}"
        res.append(f"{host} mean {mean:.2f}")
    build("gallery")
    return True, "graphite; " + ", ".join(res) + "; every region bordered"


def m6():
    ok, msg, _ = oks("tests/test_links.mojo", ["link", "match", "join", "follow", "time", "tools"])
    return ok, msg


def iou(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    ix, iy = max(0, min(ax + aw, bx + bw) - max(ax, bx)), max(0, min(ay + ah, by + bh) - max(ay, by))
    u = aw * ah + bw * bh - ix * iy
    return ix * iy / u if u else 0.0


def m7():
    t = data()
    ok, msg, out = oks("tests/test_documents.mojo", ["documents"], env_name="models")
    if not ok:
        return False, msg
    fields = OUT / "bol_fields.csv"  # file, field, value, page, x, y, w, h (page points)
    if not fields.exists():
        return False, "tests/test_documents.mojo wrote no build/g41/bol_fields.csv"
    got = {(r["file"], r["field"]): r for r in csv_rows(fields)}
    total = exact = boxed = 0
    wrong = []
    for b in t["bols"]:  # {"file", "fields": {name: {"value", "page", "box"}}}
        for name, f in b["fields"].items():
            total += 1
            g = got.get((b["file"], name))
            if g and g["value"].strip() == str(f["value"]).strip():
                exact += 1
            elif len(wrong) < 5:
                wrong.append((b["file"], name, g["value"] if g else None, f["value"]))
            if g and iou([float(g[k]) for k in "xywh"], f["box"]) >= 0.5:
                boxed += 1
    rec = number(out, "funsd recall")
    if not total or exact < 0.98 * total or boxed < 0.98 * total or rec is None or rec < 0.70:
        return False, f"fields exact {exact}/{total}, boxes {boxed}/{total}, funsd recall {rec}; wrong {wrong}"
    return True, f"fields exact {exact}/{total}, boxes IoU≥0.5 {boxed}/{total}; FUNSD word recall {rec:.2f}"


def link_steps():
    return ("wait:1500;open:dock.mp4;wait:1200;tap:analyze;wait:15000;pick:Table=" + str(DATA / "shipments.csv") + ";wait:1500;"
            "linkdrag:shipments.shipment_id=dock.mp4;wait:600;tap:Link;wait:400;"
            "tap:Links;wait:600;hold:shipments=500;wait:200;release:;wait:400")


def m8():
    data()
    build("omxplorer")
    out = omx("m8", link_steps(), extra={"MOJOUI_SHOTS_EACH": str(OUT / "m8-step")})
    s = slow_lines(out)
    links = re.findall(r"^LINK: (\S+) = (.+?) \((\d+) of (\d+)\)$", out, re.M)
    peeks = re.findall(r"^PEEK: lit=\[(.*?)\] dim=\[(.*?)\] lines=(\d+)$", out, re.M)
    if s or not links or not peeks:
        return False, f"{len(s)} SLOW {s[:2]}, LINK {links}, PEEK {peeks}"
    lit = [x.strip() for x in peeks[0][0].split(",") if x.strip()]
    if not any("dock" in x for x in lit) or int(peeks[0][2]) < len(links):
        return False, f"peek doesn't light the linked video: {peeks[0]}"
    if not re.search(r"^PEEK: done", out, re.M):
        return False, "the peek didn't settle back after release (no PEEK: done)"
    shots = sorted(OUT.glob("m8-step*.png"))
    if len(shots) < 3:
        return False, f"{len(shots)} step shots (want the drag, the panel, the peek)"
    r = web("omxplorer", link_steps())
    w = r.stdout + r.stderr
    (OUT / "m8-web.txt").write_text(w)
    if r.returncode or not re.search(r"^LINK: ", w, re.M) or not re.search(r"^PEEK: lit=", w, re.M):
        return False, f"web: exit {r.returncode}: {w[-300:]}"
    return True, f"{len(links)} link(s) {links[0][0]} ({links[0][2]} of {links[0][3]}); peek lit {lit}; web too; 0 SLOW"


def m9():
    t = data()
    build("omxplorer")
    steps = ("wait:1500;open:dock.mp4;wait:1200;pick:Table=" + str(DATA / "forklift_log.csv") + ";wait:1500;"
             f"timelink:forklift_log.t=dock.mp4@{t['log_offset_s']};wait:600;"
             "dragat:seek=200,500,0,0;wait:500;dragat:seek=520,500,0,0;wait:500;dragat:seek=880,500,0,0;wait:500")
    out = omx("m9", steps)
    pairs = re.findall(r"PLAYER: t=([0-9.]+).*?CURSOR: t=([0-9.]+)", out, re.S)
    if len(pairs) < 3:
        return False, f"{len(pairs)} PLAYER/CURSOR pairs: {out[-300:]}"
    off = [abs(float(a) - float(b)) for a, b in pairs[-3:]]
    if any(o > 1 / 30 + 1e-6 for o in off) or not re.search(r"^LANE: forklift_log", out, re.M):
        return False, f"cursor offsets {off}, lane line {bool(re.search(r'^LANE: forklift_log', out, re.M))}"
    return True, f"time link paints; cursor within one frame at 3 seeks ({max(off) * 1000:.0f} ms worst)"


def m10():
    t = data()
    build("omxplorer")
    d = OUT / "claims"
    r = run([sys.executable, "scripts/scenario.py", "claims", "--media", str(DATA), "--out", str(d)], 3600)
    out = r.stdout + r.stderr
    (OUT / "m10.txt").write_text(out)
    if r.returncode:
        return False, f"scenario claims: exit {r.returncode}: {out[-500:]}"
    got = sorted(r_["shipment"] for r_ in csv_rows(d / "answer.csv"))
    want = sorted(t["disputed"])
    if got != want:
        return False, f"answer {got}, want {want}"
    sel = {r_["shipment"]: r_ for r_ in csv_rows(d / "selections.csv")}  # shipment, frame, page, x, y, w, h
    bad = []
    for s in want:
        g = sel.get(s)
        ex = next(f for b in t["bols"] if b["shipment"] == s for n, f in b["fields"].items() if n == "exceptions")
        if not g or abs(int(g["frame"]) - t["damage_frame"][s]) > 15 or iou([float(g[k]) for k in "xywh"], ex["box"]) < 0.5:
            bad.append((s, g and g["frame"], t["damage_frame"][s]))
    if bad:
        return False, f"selections off: {bad[:4]}"
    import fitz
    for s in want:
        pdf, reel = d / "pack" / f"{s}.pdf", d / "pack" / f"{s}.mp4"
        if not pdf.exists() or not reel.exists():
            return False, f"claim pack for {s}: pdf {pdf.exists()}, reel {reel.exists()}"
        doc = fitz.open(pdf)
        text = "".join(p.get_text() for p in doc)
        imgs = sum(len(p.get_images()) for p in doc)
        if len(doc) < 2 or s not in text or imgs < 2:
            return False, f"{pdf.name}: {len(doc)} pages, id {'in' if s in text else 'missing'}, {imgs} images"
        w, h, fps, dur = probe(reel)
        if not w or dur < 2:
            return False, f"{reel.name}: {w}x{h} {dur:.1f} s"
    return True, f"answer = truth ({len(want)} disputed); seeks ±15 frames and Exceptions boxes; claim packs (PDF + reel) each"


def m11():
    clip = SITE / "assets" / "img" / "clip-claims.mp4"
    if not clip.exists() or probe(clip)[3] < 8:
        return False, f"clip-claims.mp4: {'missing' if not clip.exists() else f'{probe(clip)[3]:.1f} s'}"
    cover, deck = (SITE / "omxplorer" / "index.html").read_text(), (SITE / "omxplorer" / "deck.html").read_text()
    if "clip-claims.mp4" not in cover or "clip-claims.mp4" not in deck:
        return False, "clip-claims.mp4 not on the cover and in the deck"
    readme = ROOT / "examples" / "claims-data" / "README.md"
    if not readme.exists() or "claims_data.py" not in readme.read_text():
        return False, "examples/claims-data/README.md missing or doesn't say how to regenerate"
    with tempfile.TemporaryDirectory() as a:
        r = run([sys.executable, "scripts/claims_data.py", a], 1800)
        if r.returncode or (Path(a) / "truth.json").read_bytes() != (data() and (DATA / "truth.json").read_bytes()):
            return False, "regenerating doesn't give truth byte-equal"
    srv = subprocess.Popen([sys.executable, "-m", "http.server", "8741", "-d", str(SITE)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        import time
        time.sleep(1.0)
        bad = []
        for page in ("index.html", "omxplorer/index.html", "omxcore/index.html", "omxcode/index.html", "omxconsole/index.html", "omxqua/index.html"):
            r = run([sys.executable, "scripts/covershot.py", page, str(OUT / ("m11-" + page.replace("/", "-")))], 600,
                    env=dict(os.environ, COVER_BASE="http://127.0.0.1:8741/"))
            o = r.stdout + r.stderr
            if r.returncode or re.search(r"overflow[^\n]*[1-9]", o, re.I) or re.search(r"errors \[(?!\])", o):
                bad.append(f"{page}: {o.strip()[-200:]}")
    finally:
        srv.terminate()
    return (not bad), ("; ".join(bad) if bad else "claim clip on cover + deck; bundle regenerates; 6 covers clean at 1440/390")


MILESTONES = {f"M{i}": globals()[f"m{i}"] for i in range(12)}

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
