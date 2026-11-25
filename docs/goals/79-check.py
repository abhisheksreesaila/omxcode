"""Milestone checker for GOAL.md (goal 79: Personal Note, native, the exact look of the web app, faster).
Prints "Mn: PASS|FAIL|BLOCKED  why" per milestone.

    pixi run python docs/goals/79-check.py [M0 M1 ...]          (default: every milestone; scripts/check runs this)

Written before the feature work (2026-11-19) from GOAL.md's words; never edited to make a milestone pass (add, don't
weaken; checker bugs are logged in docs/decisions.md with why the fix is not a weakening).

The yardstick is the web Personal Note in ~/Projects/personalnotev2 (PN): its own dist/ build and API, on scratch
databases only. docs/goals/79/ref.mjs shoots it (M0); every comparison below regenerates the reference first (once per
run of this checker).

The native app's contract (examples/pnote, built by `scripts/build.sh pnote linux`):
  PNOTE_DB=<file>          a Personal Note database (PN's own SQLite schema: notes, notebooks, revisions, FTS5); the app
                           reads and writes it. The checker gives it a copy of the reference's seeded pn.db.
  PNOTE_FIXTURE=<json>     seeds an empty PNOTE_DB from docs/goals/79/fixture.json, as ref.mjs seeds the web app
  PNOTE_SKIN=paper|night|crayon   the skin at start (the web keeps it in localStorage; the native app in its config)
  PNOTE_BOXES=<file>       after every frame, the frame's named elements {name: [x, y, w, h]} (logical px, the same
                           names as ref.mjs's) as JSON
  PNOTE_FONTCHECK=1        (the Mac's M1) the app prints test_fonttext's lines at start: WIDTH/NOTDEF/CRISP
  The window is one Canvas tagged "desk", 1440×900 logical; `render:desk=<png>` (the host's step) writes its picture
  at device pixels. Screens are reached by real test-mode steps (taps at the web's boxes, keys), listed in SCREEN_STEPS.
  Linux GUI runs only through scripts/testscreen (the hidden 1.6× output); the Mac through scripts/mac-ssh.
"""
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())
OUT = ROOT / "build" / "g79"
REF = OUT / "ref"
REF_MAC = OUT / "ref-mac"
PN = Path(os.path.expanduser("~/Projects/personalnotev2"))
APP = ROOT / "build" / "pnote" / "linux" / "pnote"
FIXTURE = ROOT / "docs" / "goals" / "79" / "fixture.json"
MAC_SSH = os.environ.get("MAC_SSH", "bhoomijaprasad@100.76.9.101")
MAC_KEY = os.path.expanduser(os.environ.get("MAC_SSH_KEY", "~/.ssh/edx_mac"))

# ---- the bars, from GOAL.md ----
NAMES_MIN = 40        # M0: named elements over all screens
WIDTH_TOL = 1.0       # M1: a line's advance width vs Chromium's, device px
CRISP_MIN = 0.9       # M1: edge sharpness of a 4× zoomed raster vs a direct 4× raster
BOX_TOL = 2.0         # M2/M3: every named element's box, logical px
FILL_TOL = 4          # M2/M3: each element's sampled fill, levels per channel
SSIM_MIN = 0.95       # M2/M3/M4: the whole frame's SSIM, grey, device px
# (D-7931, then D-7942 set by the main session as contract author) M4 per step: where the web step changed the picture
# (grey moved > 24 levels, grown 6 device px; at least REGION_MIN_AREA px), native's shot after the step must look more
# like the web's shot after the step than like the web's shot before it: SSIM(native, web after) − SSIM(native, web
# before), over the region, ≥ REGION_MARGIN. (Replaces D-7931's absolute region bar of 0.80, which small text regions
# missed on antialiasing alone; the margin was chosen from the data, D-7942: done steps read +0.16…+0.86, the
# skipped-step self-test −0.32.) The whole frame keeps GOAL.md's bar (SSIM_MIN) and the saved notes must be equal.
REGION_MIN_AREA = 150
REGION_MARGIN = 0.10
STEPS_MIN = 25        # M4
P95 = 8.3             # M6: silky
OPEN_TEST_OK = [False]
SNAPINFO = {}  # (D-7958) per race note: the first opens A (no kept view) and B, the cold opens' restores, the run without  # (D-7946 (d)) tests/test_canvasload passed in this M6 run
MAX = 16.7
LINUX_DPR = 1.6
MAC_DPR = 2.0

SCREENS = ["page-sidebar", "page", "canvas", "mindmap", "search", "island-card", "settings", "page-sidebar-night", "page-sidebar-crayon"]
M2_SCREENS = ["page-sidebar", "page", "page-sidebar-night", "page-sidebar-crayon"]
M3_SCREENS = ["canvas", "mindmap", "search", "island-card", "settings"]
FACES = {  # M1: the web app's own faces, OFL files in fonts/<dir>/ with OFL.txt
    "Bricolage Grotesque": "bricolagegrotesque", "Geist": "geist", "Geist Mono": "geistmono", "IBM Plex Sans": "ibmplexsans",
    "IBM Plex Mono": "ibmplexmono", "Source Serif 4": "sourceserif4", "Instrument Serif": "instrumentserif"}
SCRIPTS = ["hindi", "tamil", "arabic", "japanese", "chinese", "korean", "emoji"]  # M1: lines that must be in the fixture
# M4: what the step script must cover (each step in docs/goals/79/steps.json names what it covers)
M4_COVERS = ["open-page", "open-canvas", "open-map", "fold-shelf", "toggle-panel", "rename", "type-paragraph", "type-heading",
             "tick-task", "write-draw", "draw-mark", "canvas-text", "canvas-sticky", "connect", "canvas-stroke", "move-object",
             "delete-object", "undo", "redo", "zoom-island", "map-child", "map-sibling", "map-rename", "search-open-keyboard",
             "skin-settings", "quit-reopen"]
# M6: the steps of PN's own benchmark, and the native app's extra ones
# (11-20, D-7929) one row per web row, raced like with like: pan at 30 % and at 100 %, undo and redo apart
RACE_STEPS = ["open", "pan 30%", "zoom from 30%", "pan 100%", "drag one", "drag 40", "undo", "redo", "pen", "typing"]
RACE_NOTES = ["600", "stress"]

_ref_done = {}


LINUX_LOAD = []  # what each measured run on this machine saw before it started (linux_quiet)
QUIET_CORES = 3.0  # busy cores above which no measured run starts, web or native (the Mac's rule is its load under 3)


def linux_quiet(what, wait=300):
    """(review 4, S12) The CPU's share of the quiet rule on this machine, the same for both sides of the race: the run waits (up
    to `wait` s) until fewer than QUIET_CORES cores' worth of work runs (/proc/stat over 2 s); what it saw is kept for race.md.
    False: it never was quiet."""
    end = time.time() + wait
    while True:
        a = [int(x) for x in open("/proc/stat").readline().split()[1:9]]
        time.sleep(2)
        b = [int(x) for x in open("/proc/stat").readline().split()[1:9]]
        total = sum(b) - sum(a)
        idle = (b[3] + b[4]) - (a[3] + a[4])
        cores = os.cpu_count() * (total - idle) / max(total, 1)
        if cores < QUIET_CORES or time.time() > end:
            LINUX_LOAD.append((what, round(cores, 2), cores < QUIET_CORES))
            return cores < QUIET_CORES


def run(cmd, timeout=3600, env=None, cwd=ROOT):
    said = " ".join(str(c) for c in cmd)
    if M6_RUNNING[0] and ("scripts/testscreen" in said or "benchmark-" in said or re.search(r"docs/goals/79/web\w+\.mjs", said)):
        linux_quiet(said.rsplit("/", 1)[-1][:60])
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)


def tail(s, n=500):
    return s[-n:].replace("\n", " | ")


# ---------------------------------------------------------------- the reference (M0)

def make_ref(out=REF, dpr=LINUX_DPR):
    """Runs ref.mjs once per checker run (per device scale): the reference is regenerated by the check."""
    key = str(out)
    if key in _ref_done:
        return _ref_done[key]
    if not PN.exists() or not (PN / "node_modules" / "playwright").exists():
        _ref_done[key] = f"{PN} (with node_modules/playwright) isn't there"
        return _ref_done[key]
    if out == REF_MAC:
        # (D-7983, ruling A) the Mac's reference: the web app in the Mac's own Chrome at 2.0 (ruling B's setup there),
        # made into a fresh folder first. (D-7997) The Mac drops off the network for minutes: it is tried 3×, and a
        # Mac-made reference already there is kept rather than replaced by Linux Chromium's (which made a whole M7 run
        # judge the Mac against Linux's labels); Linux Chromium at 2.0 only when there is no Mac-made one at all
        new = out.with_name(out.name + "-new")
        for attempt in range(3):
            if mac_reachable():
                for _ in range(40):
                    time.sleep(15)
                    if not mac_reachable():
                        break
            if new.exists():
                shutil.rmtree(new)
            print("(shooting the web app on the Mac in its own Chrome at 2.0: about two minutes)", flush=True)
            with MacLock():
                r = run(["python3", str(ROOT / "docs/goals/79/macref.py"), str(new)], 1500)
            if r.returncode == 0 and (new / "made-by.json").exists():
                if out.exists():
                    shutil.rmtree(out)
                new.rename(out)
                _ref_done[key] = ""
                return ""
        made = json.loads((out / "made-by.json").read_text()) if (out / "made-by.json").exists() else {}
        if made.get("platform") == "darwin":
            print("(the Mac couldn't make a new reference: " + tail(r.stdout + r.stderr, 200) + "; the last Mac-made one kept)", flush=True)
            _ref_done[key] = ""
            return ""
        print("(no Mac reference: " + tail(r.stdout + r.stderr, 200) + "; Linux Chromium at 2.0 instead, said so)", flush=True)
    if out.exists():
        shutil.rmtree(out)
    print(f"(shooting the web app at {dpr}×: about a minute)", flush=True)
    r = run(["node", str(ROOT / "docs/goals/79/ref.mjs"), str(out), f"--dpr={dpr}"], 900, cwd=PN)
    _ref_done[key] = "" if r.returncode == 0 else f"ref.mjs exit {r.returncode}: {tail(r.stdout + r.stderr)}"
    return _ref_done[key]


def m0():
    src = (ROOT / "docs/goals/79/ref.mjs")
    if not src.exists() or not FIXTURE.exists():
        return "FAIL", "docs/goals/79/ref.mjs or fixture.json missing"
    code = src.read_text()
    probs = []
    if "fixture.json" not in code or "/api" not in code or "getBoundingClientRect" not in code:
        probs.append("ref.mjs must load fixture.json, seed through the web API and read boxes from the DOM")
    err = make_ref()
    if err:
        return "FAIL", err
    meta = json.loads((REF / "meta.json").read_text())
    if meta.get("fonts") != "live" or not any("gstatic" in u for u in meta.get("faces", {})):
        probs.append("the reference isn't drawn with the fonts the live page loads (D-8053)")
    fix = json.loads(FIXTURE.read_text())
    kinds = [n["noteType"] for n in fix["notes"]]
    if kinds.count("page") < 4 or "canvas" not in kinds or "mindmap" not in kinds or not fix.get("notebooks"):
        probs.append("fixture lacks a page note + 3 more notes, a canvas, a mind map or a notebook")
    page = next((n for n in fix["notes"] if n["noteType"] == "page" and n.get("content")), None)
    md = page["content"]["markdown"] if page else ""
    for what, pat in [("headings", r"^#{1,2} "), ("bold", r"\*\*\w"), ("italic", r"(?<!\*)\*\w[^*]*\*(?!\*)"), ("tasks", r"- \[[ x]\]"),
                      ("numbered list", r"^\d+\. "), ("quote", r"^> "), ("inline code", r"`[^`]+`")]:
        if not re.search(pat, md, re.M):
            probs.append(f"the page note has no {what}")
    canvas = next((n for n in fix["notes"] if n["noteType"] == "canvas"), {}).get("content", {})
    stickies = [o for o in canvas.get("nodes", []) if o.get("color")]
    if len(stickies) < 2 or not canvas.get("edges") or not [o for o in canvas.get("nodes", []) if not o.get("color")]:
        probs.append("the canvas note needs text, two stickies and a connector")
    mm = next((n for n in fix["notes"] if n["noteType"] == "mindmap"), {}).get("content", {})
    root_id = mm.get("rootId")
    branches = [n for n in mm.get("nodes", []) if n.get("parentId") == root_id]
    leaves = [n for n in mm.get("nodes", []) if n.get("parentId") in {b["id"] for b in branches}]
    if len(branches) != 4 or len(leaves) != 10:
        probs.append(f"the mind map has {len(branches)} branches and {len(leaves)} leaves (wants 4 and 10)")
    names = set()
    for s in SCREENS:
        png, bx = REF / f"{s}.png", REF / f"{s}.boxes.json"
        if not png.exists() or not bx.exists():
            probs.append(f"{s}: no png or boxes")
            continue
        w, h = Image.open(png).size
        if (w, h) != (round(1440 * LINUX_DPR), round(900 * LINUX_DPR)):
            probs.append(f"{s}.png is {w}×{h}")
        names |= {f"{s}/{k}" for k in json.loads(bx.read_text())}
    if len({n.split("/", 1)[1] for n in names}) < NAMES_MIN:
        probs.append(f"only {len({n.split('/', 1)[1] for n in names})} distinct names over all screens")
    tw = REF / "textwidths.json"
    if not tw.exists() or set(json.loads(tw.read_text())["widths"]) != {l["id"] for l in fix["textlines"]}:
        probs.append("textwidths.json doesn't measure every fixture line")
    db = REF / "pn.db"
    if db.exists():
        titles = {r[0] for r in sqlite3.connect(db).execute("SELECT title FROM notes")}
        missing = [n["title"] for n in fix["notes"] if n["title"] not in titles]
        if missing:
            probs.append(f"pn.db lacks {missing}")
    else:
        probs.append("no pn.db")
    if probs:
        return "FAIL", "; ".join(probs)
    return "PASS", (f"9 screens at {LINUX_DPR}× ({round(1440 * LINUX_DPR)}×{round(900 * LINUX_DPR)}), "
                    f"{len({n.split('/', 1)[1] for n in names})} distinct names ({len(names)} boxes), {len(fix['textlines'])} text widths, pn.db seeded")


# ---------------------------------------------------------------- M1: text

def fonttext_lines(out):
    widths = {m[0]: float(m[1]) for m in re.findall(r"^WIDTH (\S+) ([\d.]+)", out, re.M)}
    notdef = {m[0]: int(m[1]) for m in re.findall(r"^NOTDEF (\S+) (\d+)", out, re.M)}
    crisp = [float(x) for x in re.findall(r"^CRISP ([\d.]+)", out, re.M)]
    return widths, notdef, crisp


def judge_fonttext(out, ref_widths, where):
    widths, notdef, crisp = fonttext_lines(out)
    probs = []
    if "fonttext: ok" not in out:
        probs.append(f"{where}: no 'fonttext: ok'")
    worst = 0.0
    for k, cw in ref_widths.items():
        if k not in widths:
            probs.append(f"{where}: no width for {k}")
            continue
        d = abs(widths[k] - cw)
        worst = max(worst, d)
        if d > WIDTH_TOL:
            probs.append(f"{where}: {k} {widths[k]:.1f} vs Chromium {cw:.1f} device px")
        if notdef.get(k, 1) != 0:
            probs.append(f"{where}: {k} draws {notdef.get(k, 'unknown')} missing glyphs")
    if not crisp or min(crisp) < CRISP_MIN:
        probs.append(f"{where}: crispness {crisp} (needs ≥ {CRISP_MIN})")
    return probs, worst, crisp


def m1():
    probs = []
    for fam, d in FACES.items():
        if not list((ROOT / "fonts" / d).glob("*.ttf")) or not (ROOT / "fonts" / d / "OFL.txt").exists():
            probs.append(f"fonts/{d}: no TTF or OFL.txt ({fam})")
    src = ROOT / "mojoui" / "fonttext.mojo"
    if not src.exists():
        return "FAIL", "mojoui/fonttext.mojo missing; " + "; ".join(probs)
    code = src.read_text() + "".join(p.read_text() for p in (ROOT / "mojoui").glob("fonttext_*.mojo"))
    for sym in ["FT_Load_Glyph", "hb_shape", "FcFontMatch", "CTFont"]:
        if sym not in code:
            probs.append(f"fonttext doesn't call {sym}")
    fix = json.loads(FIXTURE.read_text())
    ids = {l["id"] for l in fix["textlines"]}
    fams = {l["family"] for l in fix["textlines"]}
    if not set(FACES) <= fams or not set(SCRIPTS) <= ids:
        probs.append(f"the fixture's lines lack faces {set(FACES) - fams} or scripts {set(SCRIPTS) - ids}")
    err = make_ref()
    if err:
        return "FAIL", err
    ref_widths = json.loads((REF / "textwidths.json").read_text())["widths"]
    env = dict(os.environ, FONTTEXT_REF=str(REF / "textwidths.json"), FONTTEXT_FIXTURE=str(FIXTURE), FONTTEXT_DPR=str(LINUX_DPR))
    r = run(["pixi", "run", "mojo", "run", "-I", ".", "tests/test_fonttext.mojo"], 1800, env=env)
    out = r.stdout + r.stderr
    (OUT / "m1-linux.log").parent.mkdir(parents=True, exist_ok=True)
    (OUT / "m1-linux.log").write_text(out)
    if r.returncode != 0:
        probs.append(f"tests/test_fonttext.mojo exit {r.returncode}: {tail(out, 300)}")
    p, worst, crisp = judge_fonttext(out, ref_widths, "Linux")
    probs += p
    # the Mac: CoreText, the same lines against Chromium at 2×
    mac_note = ""
    m = mac_reachable()
    if m:
        mac_note = f"; Mac BLOCKED ({m})"
        blocked_mac = True
    else:
        blocked_mac = False
        err = make_ref(REF_MAC, MAC_DPR)
        if err:
            probs.append("ref at 2×: " + err)
        else:
            # (D-7976, ruling A) the Mac's lines against Chrome on the Mac with the Mac's fonts (web faces and fallback
            # scripts alike). (D-7991, ruling C) measured on the live page by M0's tool: ref.mjs in the Mac's own Chrome
            # through Playwright (macref.py), its textwidths.json; made-by.json must name the Mac. macwidths.py's
            # --dump-dom (a headless layout mode) is no longer used for references
            mw = REF_MAC / "textwidths.json"
            made = json.loads((REF_MAC / "made-by.json").read_text()) if (REF_MAC / "made-by.json").exists() else {}
            if not mw.exists() or made.get("platform") != "darwin":
                probs.append(f"Mac: no page measurement from Chrome on the Mac (REF_MAC made by {made or 'nothing'})")
                return "FAIL", "; ".join(probs[:12])
            out_mac, e = mac_run("fontcheck", [], {"PNOTE_FONTCHECK": "1", "FONTTEXT_REF": "{data}/textwidths.json",
                                                    "FONTTEXT_FIXTURE": "{data}/fixture.json", "FONTTEXT_DPR": str(MAC_DPR)},
                                 [mw, FIXTURE])
            if e:
                probs.append("Mac: " + e)
            else:
                pm, worst_m, crisp_m = judge_fonttext(out_mac, json.loads(mw.read_text())["widths"], "Mac")
                probs += pm
                mac_note = f"; Mac worst {worst_m:.2f} px, crisp {min(crisp_m) if crisp_m else 0:.2f}"
    if probs:
        return "FAIL", "; ".join(probs[:12])
    if blocked_mac:
        return "BLOCKED", f"Linux: {len(ref_widths)} lines, worst {worst:.2f} device px, no .notdef, crisp {min(crisp):.2f}{mac_note}"
    return "PASS", f"Linux: {len(ref_widths)} lines, worst {worst:.2f} device px, no .notdef, crisp {min(crisp):.2f}{mac_note}"


# ---------------------------------------------------------------- comparing pictures (M2–M4, M7)

def grey(path):
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
    return a[..., 0] * 0.299 + a[..., 1] * 0.587 + a[..., 2] * 0.114


def _blur(a, sigma=1.5, radius=5):
    x = np.arange(-radius, radius + 1)
    k = np.exp(-(x * x) / (2 * sigma * sigma))
    k /= k.sum()
    return _conv1(_conv1(a, k, 1), k, 0)


def _conv1(a, k, axis):
    r = len(k) // 2
    pad = [(0, 0), (0, 0)]
    pad[axis] = (r, r)
    p = np.pad(a, pad, mode="reflect")
    out = np.zeros_like(a)
    for i, w in enumerate(k):
        sl = [slice(None), slice(None)]
        sl[axis] = slice(i, i + a.shape[axis])
        out += w * p[tuple(sl)]
    return out


def ssim(a, b):
    """Mean SSIM of two grey images (Wang et al. 2004: Gaussian window σ 1.5, K1 0.01, K2 0.03, L 255)."""
    if a.shape != b.shape:
        return 0.0
    return float(ssim_map(a, b).mean())


def ssim_map(a, b):
    """SSIM per pixel (the map ssim() averages)."""
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    mu_a, mu_b = _blur(a), _blur(b)
    saa = _blur(a * a) - mu_a ** 2
    sbb = _blur(b * b) - mu_b ** 2
    sab = _blur(a * b) - mu_a * mu_b
    return ((2 * mu_a * mu_b + c1) * (2 * sab + c2)) / ((mu_a ** 2 + mu_b ** 2 + c1) * (saa + sbb + c2))


def changed_region(before, after, level=24, grow=6):
    """Where a step changed a picture: pixels whose grey moved by more than `level`, grown by `grow` device px."""
    m = np.abs(before - after) > level
    for axis in (0, 1):
        g = m.copy()
        for d in range(1, grow + 1):
            g |= np.roll(m, d, axis=axis) | np.roll(m, -d, axis=axis)
        m = g
    return m


def step_region(web_prev, web_cur, nat_prev, nat_cur):
    """(D-7931, D-7942) The region the web step changed and how native's shot after the step reads there: (area px,
    SSIM(native after, web after), SSIM(native after, web before)), or None when the web step changed nothing visible."""
    wp, wc, npv, nc = grey(web_prev), grey(web_cur), grey(nat_prev), grey(nat_cur)
    if not (wp.shape == wc.shape == npv.shape == nc.shape):
        return (0, 0.0, 0.0)
    m = changed_region(wp, wc)
    area = int(m.sum())
    if area < REGION_MIN_AREA:
        return None
    return (area, float(ssim_map(nc, wc)[m].mean()), float(ssim_map(nc, wp)[m].mean()))


def region_verdicts(steps, web_dir, nat_dir):
    """[(i, problem or "", detail)] for every step: a step whose web change has native not matching it there, or
    native's shot no nearer the web's than before the step (a step native didn't do), is a problem."""
    out = []
    for i, st in enumerate(steps):
        wp = web_dir / ("start.png" if i == 0 else f"{i - 1:02d}.png")
        npv = nat_dir / ("start.png" if i == 0 else f"{i - 1:02d}.png")
        wc, nc = web_dir / f"{i:02d}.png", nat_dir / f"{i:02d}.png"
        if not all(x.exists() for x in (wp, npv, wc, nc)):
            out.append((i, f"step {i} ({st['name']}): a shot for the region check is missing", ""))
            continue
        r = step_region(wp, wc, npv, nc)
        if r is None:
            out.append((i, "", "no visible change"))
            continue
        area, after, before = r
        bad = after - before < REGION_MARGIN
        out.append((i, f"step {i} ({st['name']}): where the web changed ({area} px) native reads {after:.3f} against the web after the step and {before:.3f} against the web before it (gain {after - before:+.3f} < {REGION_MARGIN})" if bad else "",
                    f"{area} px after {after:.3f} before {before:.3f} gain {after - before:+.3f}"))
    return out


def sampled_fill(img, box, dpr):
    """An element's fill: the most common colour inside its box, inset by up to 3 logical px (text and edges vote less
    than the fill they sit on)."""
    x, y, w, h = box
    if min(w, h) * dpr < 2:
        return hairline_color(img, box, dpr)
    inset = min(3.0, w / 4, h / 4)
    x0, y0 = int(round((x + inset) * dpr)), int(round((y + inset) * dpr))
    x1, y1 = int(round((x + w - inset) * dpr)), int(round((y + h - inset) * dpr))
    H, W = img.shape[:2]
    x0, y0, x1, y1 = max(0, x0), max(0, y0), min(W, max(x1, x0 + 1)), min(H, max(y1, y0 + 1))
    region = img[y0:y1, x0:x1].reshape(-1, 3)
    if len(region) == 0:
        return None
    keys = (region[:, 0].astype(np.int64) << 16) | (region[:, 1].astype(np.int64) << 8) | region[:, 2].astype(np.int64)
    vals, counts = np.unique(keys, return_counts=True)
    k = int(vals[counts.argmax()])
    return (k >> 16) & 255, (k >> 8) & 255, k & 255


def hairline_color(img, box, dpr):
    """(D-7920) A line thinner than 2 device px has no pixel of its own colour at a fractional device scale: its colour is
    recovered from the ink it lays down across the rows (or columns) it touches, ink / (thickness in device px), measured
    against the background on both sides. The same rule reads the web and the native picture; a missing line reads as
    the background, a wrong colour or a line of the wrong thickness reads as a different colour."""
    x, y, w, h = box
    H, W = img.shape[:2]
    horizontal = h <= w
    if horizontal:
        a0, a1 = int(round((x + min(3.0, w / 4)) * dpr)), int(round((x + w - min(3.0, w / 4)) * dpr))
        b0, b1 = int(np.floor(y * dpr)) - 2, int(np.ceil((y + h) * dpr)) + 2
        if b0 < 0 or b1 > H or a1 <= a0:
            return None
        reg = img[b0:b1, a0:a1].astype(float)
        thick = h * dpr
    else:
        a0, a1 = int(round((y + min(3.0, h / 4)) * dpr)), int(round((y + h - min(3.0, h / 4)) * dpr))
        b0, b1 = int(np.floor(x * dpr)) - 2, int(np.ceil((x + w) * dpr)) + 2
        if b0 < 0 or b1 > W or a1 <= a0:
            return None
        reg = img[a0:a1, b0:b1].astype(float).transpose(1, 0, 2)
        thick = w * dpr
    bg = (reg[0] + reg[-1]) / 2
    col = bg - (bg[None] - reg).sum(axis=0) / thick
    m = np.clip(np.median(col, axis=0), 0, 255)
    return tuple(int(round(v)) for v in m)


INK_BOX, INK_MID = 2, 1.7  # (device px) a small mark's ink: its edges, its middle


def ink_marks(boxes):
    """(D-8053, a sharpening) The small marks of a screen: each row's and title's emoji on its tile, the page's, every icon
    button. Name → its rect and how far in its ink is looked for. (M2 passed emoji 8–16 px too high: boxes, fills and SSIM don't
    see a glyph that small.)"""
    for k, b in boxes.items():
        if k.startswith("row:"):
            yield "emoji of " + k, [b[0] + 8, b[1] + 5, 24, 24], 1.0
        elif k == "[Change icon]":
            yield "emoji of the page", b, 1.0
        elif 8 <= max(b[2], b[3]) <= 66 and "Add branch" not in k:  # (those overlap the map's branches: no ground of their own)
            yield k, b, 1.0 if max(b[2], b[3]) < 24 else 0.18 * min(b[2], b[3])


def ink_of(img, rect, inset, dpr):
    """Where a mark's ink is in its rect (pixels 48 levels off the ground's colour): its box and its middle; None: no ink."""
    x, y, w, h = rect
    x0, y0, x1, y1 = [max(0, int(round(v * dpr))) for v in (x + inset, y + inset, x + w - inset, y + h - inset)]
    r = img[y0:y1, x0:x1].astype(np.int64)
    if r.size == 0:
        return None
    v, n = np.unique((r[..., 0] << 16) | (r[..., 1] << 8) | r[..., 2], return_counts=True)
    g = int(v[n.argmax()])
    d = np.abs(r - np.array([g >> 16, (g >> 8) & 255, g & 255])).max(axis=2) > 48
    if d.sum() < 6:
        return None
    ys, xs = np.nonzero(d)
    return [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max()), float(xs.mean()), float(ys.mean())]


def ink_wrong(wa, web_boxes, na, nat_boxes, dpr):
    """(how many marks were compared, the ones whose ink isn't where the web's is)."""
    nat = {k: r for k, r, _ in ink_marks(nat_boxes)}
    out, n = [], 0
    k_dpr = dpr / LINUX_DPR
    for k, r, inset in ink_marks(web_boxes):
        a = ink_of(wa, r, inset, dpr)
        if a is None:
            continue
        n += 1
        b = ink_of(na, nat[k], inset, dpr) if k in nat else None
        if b is None:
            out.append(f"{k} has no ink")
            continue
        edge, mid = max(abs(a[i] - b[i]) for i in range(4)), max(abs(a[4] - b[4]), abs(a[5] - b[5]))
        if edge > INK_BOX * k_dpr or mid > INK_MID * k_dpr:
            out.append(f"{k} off {edge} px (middle {mid:.1f})")
    return n, out


def compare_screen(name, web_png, web_boxes, nat_png, nat_boxes, dpr, out_png):
    """(problems, ssim). Writes web │ native │ diff to out_png."""
    probs = []
    wa = np.asarray(Image.open(web_png).convert("RGB"))
    na = np.asarray(Image.open(nat_png).convert("RGB")) if nat_png.exists() else None
    if na is None:
        return [f"{name}: no native picture"], 0.0
    if wa.shape != na.shape:
        probs.append(f"{name}: native picture {na.shape[1]}×{na.shape[0]} vs web {wa.shape[1]}×{wa.shape[0]}")
    s = ssim(grey(web_png), grey(nat_png)) if wa.shape == na.shape else 0.0
    if s < SSIM_MIN:
        probs.append(f"{name}: SSIM {s:.4f} < {SSIM_MIN}")
    bad_box, bad_fill = [], []
    for k, b in web_boxes.items():
        nb = nat_boxes.get(k)
        if nb is None:
            bad_box.append(f"{k} missing")
            continue
        d = max(abs(b[i] - nb[i]) for i in range(4))
        if d > BOX_TOL:
            bad_box.append(f"{k} off {d:.1f}px")
        if wa.shape == na.shape:
            fw, fn = sampled_fill(wa, b, dpr), sampled_fill(na, b, dpr)
            if fw and fn and max(abs(fw[i] - fn[i]) for i in range(3)) > FILL_TOL:
                bad_fill.append(f"{k} {'#%02x%02x%02x' % fw}→{'#%02x%02x%02x' % fn}")
    if bad_box:
        probs.append(f"{name}: {len(bad_box)}/{len(web_boxes)} boxes ({', '.join(bad_box[:6])})")
    if bad_fill:
        probs.append(f"{name}: {len(bad_fill)} fills ({', '.join(bad_fill[:4])})")
    if wa.shape == na.shape:
        n_ink, bad_ink = ink_wrong(wa, web_boxes, na, nat_boxes, dpr)
        if bad_ink:
            probs.append(f"{name}: ink of {len(bad_ink)}/{n_ink} marks ({'; '.join(bad_ink[:5])})")
    # web │ native │ diff
    if wa.shape == na.shape:
        diff = np.abs(wa.astype(np.int16) - na.astype(np.int16)).max(axis=2)
        dimg = np.stack([np.clip(diff * 4, 0, 255)] * 3, axis=2).astype(np.uint8)
        strip = np.concatenate([wa, np.full((wa.shape[0], 8, 3), 255, np.uint8), na, np.full((wa.shape[0], 8, 3), 255, np.uint8), dimg], axis=1)
        Image.fromarray(strip).resize((strip.shape[1] // 2, strip.shape[0] // 2)).save(out_png)
    return probs, s


# ---------------------------------------------------------------- the native app on the test screen

def build_linux():
    r = run(["bash", "scripts/build.sh", "pnote", "linux"], 3600)
    if r.returncode or not APP.exists():
        return f"build failed: {tail(r.stdout + r.stderr, 800)}"
    return ""


def box_center(boxes, name, cw=1440.0, ch=900.0):
    x, y, w, h = boxes[name]
    return f"{round((x + w / 2) / cw * 1000)},{round((y + h / 2) / ch * 1000)}"


def screen_steps(screen, ref):
    """The test-mode steps that reach a screen in the native app, from a fresh start on the seeded database (the web's
    path in ref.mjs, tapped at the web's own boxes)."""
    sb = json.loads((ref / "page-sidebar.boxes.json").read_text())
    pg = json.loads((ref / "page.boxes.json").read_text())
    mm = json.loads((ref / "mindmap.boxes.json").read_text())
    ic = json.loads((ref / "island-card.boxes.json").read_text())
    row = lambda t: next(k for k in sb if k.startswith("row:") and k.endswith(t))
    # (D-7921) both apps start with the notes panel closed; ref.mjs's openNote opens it first (sidebar(true) clicks the toggle)
    open_page = [f"tapat:desk={box_center(sb, '#toggle-sidebar')}", "wait:600", f"tapat:desk={box_center(sb, row('Lighthouse trip'))}", "wait:600"]
    close_panel = [f"tapat:desk={box_center(sb, '#toggle-sidebar')}", "wait:600"]
    open_panel = [f"tapat:desk={box_center(pg, '#toggle-sidebar')}", "wait:600"]
    open_note = lambda t: open_panel + [f"tapat:desk={box_center(sb, row(t))}", "wait:600"] + close_panel
    steps = {
        "page-sidebar": open_page,
        "page": open_page + close_panel,
        "page-sidebar-night": open_page,
        "page-sidebar-crayon": open_page,
        "canvas": open_page + close_panel + open_note("Garden plan"),
        "mindmap": open_page + close_panel + open_note("Book mind map"),
        "search": open_page + close_panel + open_note("Book mind map") + [f"tapat:desk={box_center(mm, '#search-button')}", "wait:400", "typekeys:desk=li", "wait:600"],
        "island-card": open_page + close_panel + open_note("Book mind map") + [f"tapat:desk={box_center(mm, '#island-title')}", "wait:600"],
        "settings": open_page + close_panel + open_note("Book mind map") + [f"tapat:desk={box_center(mm, '#island-title')}", "wait:600",
                                                                              f"tapat:desk={box_center(ic, '#top-properties')}", "wait:800"],
    }
    return steps[screen]


def native_shot(screen, ref, outdir, skin=None):
    """Runs pnote on the hidden test screen to a screen; (png, boxes, log) or an error string."""
    outdir.mkdir(parents=True, exist_ok=True)
    db = outdir / f"{screen}.db"
    for f in [db, Path(str(db) + "-wal"), Path(str(db) + "-shm")]:
        f.unlink(missing_ok=True)
    shutil.copy(ref / "pn.db", db)
    png, boxes = outdir / f"{screen}.png", outdir / f"{screen}.boxes.json"
    png.unlink(missing_ok=True)
    boxes.unlink(missing_ok=True)
    skin = skin or ("night" if screen.endswith("night") else "crayon" if screen.endswith("crayon") else "paper")
    # (added 11-19, D-7911, a strengthening) the picture compared is the GPU frame the window shows (gpushot: what GTK
    # holds from the GPU 2D renderer, rendered as GTK composites it), with every picture of the canvas drawn by the GPU;
    # the app's own CPU picture (render:) is kept beside it as <screen>.cpu.png, a second report that can't pass
    cpu_png = outdir / f"{screen}.cpu.png"
    cpu_png.unlink(missing_ok=True)
    steps = ["wait:800"] + screen_steps(screen, ref) + ["wait:400", f"gpushot:desk={png}", f"render:desk={cpu_png}"]
    cfg = outdir / f"cfg-{screen}"
    shutil.rmtree(cfg, ignore_errors=True)
    cfg.mkdir()
    env = dict(os.environ, PNOTE_DB=str(db), PNOTE_SKIN=skin, PNOTE_BOXES=str(boxes), OMX_CONFIG=str(cfg), PNOTE_DIR=str(cfg),
               MOJOUI_TEST=";".join(steps), MOJOUI_SHOT="")
    # (added 11-19, D-7913) the app's clock is the web shot's: "Edited now" means the same moment in both
    meta = json.loads((ref / "meta.json").read_text()) if (ref / "meta.json").exists() else {}
    if meta.get("shots", {}).get(screen):
        env["PNOTE_NOW"] = meta["shots"][screen]
    r = run(["scripts/testscreen", str(APP)], 600, env=env)
    log = r.stdout + r.stderr
    (outdir / f"{screen}.log").write_text(log)
    if not png.exists():
        return f"{screen}: no GPU picture (exit {r.returncode}): {tail(log, 400)}"
    gs = re.search(r"^GPUSHOT: \S+ (\d+)x(\d+) texture=(\S+) gpu_frames=(\d+) cpu_frames=(\d+)", log, re.M)
    if not gs or int(gs.group(4)) == 0 or int(gs.group(5)) != 0 or not re.search(r"^PNOTE GPU: gpu2d", log, re.M):
        return f"{screen}: the picture isn't all the GPU renderer's ({gs.group(0) if gs else 'no GPUSHOT line'}; {re.search(r'^PNOTE GPU: .*', log, re.M).group(0)[:60] if re.search(r'^PNOTE GPU: .*', log, re.M) else 'no PNOTE GPU line'})"
    if not boxes.exists():
        return f"{screen}: no boxes file"
    return png, json.loads(boxes.read_text()), log


def look_milestone(screens):
    err = make_ref() or build_linux()
    if err:
        return "FAIL", err
    probs, scores = [], {}
    for s in screens:
        r = native_shot(s, REF, OUT / "native")
        if isinstance(r, str):
            probs.append(r)
            continue
        png, boxes, _ = r
        p, sc = compare_screen(s, REF / f"{s}.png", json.loads((REF / f"{s}.boxes.json").read_text()), png, boxes, LINUX_DPR,
                               OUT / f"{s}-compare.png")
        probs += p
        scores[s] = sc
    said = ", ".join(f"{k} {v:.3f}" for k, v in scores.items())
    if probs:
        return "FAIL", "; ".join(probs)[:1500] + f" (SSIM: {said})"
    return "PASS", f"boxes ≤ {BOX_TOL}px, fills ≤ {FILL_TOL} levels, SSIM {said}; build/g79/<screen>-compare.png"


def m2():
    return look_milestone(M2_SCREENS)


def m3():
    return look_milestone(M3_SCREENS)


# ---------------------------------------------------------------- M4: it works the same

def normalized_notes(db_or_api):
    """[(title, noteType, normalized content)] read back through the web app's own API, on a copy of a database."""
    scratch = OUT / "m4" / "api"
    shutil.rmtree(scratch, ignore_errors=True)
    scratch.mkdir(parents=True)
    db = scratch / "v.db"
    src = sqlite3.connect(db_or_api)
    dst = sqlite3.connect(db)
    src.backup(dst)
    dst.close()
    src.close()
    port = 4993
    env = dict(os.environ, PERSONAL_NOTE_DB=str(db), PERSONAL_NOTE_PLUGINS_DIR=str(scratch / "plugins"))
    p = subprocess.Popen([str(PN / ".venv/bin/python"), "-m", "uvicorn", "main:app", "--host", "127.0.0.1", "--port", str(port)],
                         cwd=PN, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    import urllib.request
    try:
        for _ in range(200):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/api/notebooks", timeout=1)
                break
            except Exception:
                time.sleep(0.15)
        get = lambda u: json.loads(urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/api{u}", headers={"x-personal-note": "1"}), timeout=10).read())
        notes = get("/notes")
        notes = notes if isinstance(notes, list) else notes.get("notes", [])
        out = []
        for n in sorted(notes, key=lambda n: n["title"]):
            full = get(f"/notes/{n['id']}")
            out.append((n["title"], n.get("noteType"), normalize(full.get("content"), n.get("noteType"))))
        return out
    finally:
        p.terminate()
        p.wait(10)


def normalize(content, kind):
    """What a person made, without what only one app records (ids, timestamps, float noise, key order)."""
    if content is None:
        return None
    if kind == "page":
        md = content.get("markdown", "") if isinstance(content, dict) else str(content)
        ink = (content.get("ink") or {}) if isinstance(content, dict) else {}
        # (D-7931) page marks too: how many, and the words each is anchored to
        marks = sorted(((m.get("anchor") or {}).get("text", ""), (m.get("anchor") or {}).get("from", (m.get("anchor") or {}).get("start"))) for m in ink.get("marks", []))
        return {"markdown": md.strip(), "ink": len(ink.get("drawings", [])), "marks": marks}
    if kind == "mindmap":
        nodes = content.get("nodes", [])
        byid = {n["id"]: n for n in nodes}
        path = lambda n: (path(byid[n["parentId"]]) + "/" if n.get("parentId") in byid else "") + n.get("text", "")
        return sorted((path(n), round(float(n.get("x", 0))), round(float(n.get("y", 0)))) for n in nodes)  # (positions to 1 px, D-7931)
    if kind == "canvas":
        objs = content.get("nodes") or content.get("objects") or []
        kinds = sorted((o.get("type", ""), (o.get("text") or "").strip(), str(o.get("color", "")), round(float(o.get("x", 0))), round(float(o.get("y", 0))),
                        round(float(o.get("width", 0))), round(float(o.get("height", 0)))) for o in objs)  # (positions to 1 px, D-7931)
        return {"objects": kinds, "edges": len(content.get("edges", []))}
    return content


def m4():
    steps_file = ROOT / "docs/goals/79/steps.json"
    if not steps_file.exists():
        return "FAIL", "docs/goals/79/steps.json (the one step script) missing"
    steps = json.loads(steps_file.read_text())["steps"]
    covered = {c for s in steps for c in s.get("covers", [])}
    probs = []
    if len(steps) < STEPS_MIN:
        probs.append(f"{len(steps)} steps (needs ≥ {STEPS_MIN})")
    if set(M4_COVERS) - covered:
        probs.append(f"steps don't cover {sorted(set(M4_COVERS) - covered)}")
    if not all("web" in s and "native" in s for s in steps):
        probs.append("every step needs a web and a native action")
    if probs:
        return "FAIL", "; ".join(probs)
    err = make_ref() or build_linux()
    if err:
        return "FAIL", err
    out = OUT / "m4"
    shutil.rmtree(out / "web", ignore_errors=True)
    shutil.rmtree(out / "native", ignore_errors=True)
    (out / "web").mkdir(parents=True)
    (out / "native").mkdir(parents=True)
    # the web: docs/goals/79/steps.mjs plays steps.json in Chromium on a copy of pn.db, a shot after each step
    shutil.copy(REF / "pn.db", out / "web.db")
    r = run(["node", str(ROOT / "docs/goals/79/steps.mjs"), str(out / "web.db"), str(out / "web"), f"--dpr={LINUX_DPR}"], 1800, cwd=PN)
    if r.returncode:
        return "FAIL", f"steps.mjs exit {r.returncode}: {tail(r.stdout + r.stderr)}"
    # the native app: the same steps through test mode, a render after each; quit-reopen runs the app again
    shutil.copy(REF / "pn.db", out / "native.db")
    runs, cur = [[f"gpushot:desk={out / 'native' / 'start.png'}"]], 0
    for i, s in enumerate(steps):
        acts = s["native"] if isinstance(s["native"], list) else [s["native"]]
        for a in acts:
            if a == "relaunch":
                runs.append([])
            else:
                runs[-1].append(a)
        # (D-7931) the GPU frame the window shows, not the app's CPU picture
        runs[-1].append(f"gpushot:desk={out / 'native' / f'{i:02d}.png'}")
    cfg = out / "cfg"
    shutil.rmtree(cfg, ignore_errors=True)
    cfg.mkdir()
    for k, rs in enumerate(runs):
        env = dict(os.environ, PNOTE_DB=str(out / "native.db"), PNOTE_SKIN="paper", OMX_CONFIG=str(cfg), PNOTE_DIR=str(cfg),
                   PNOTE_BOXES=str(out / "native" / f"run{k}.boxes.json"), MOJOUI_TEST=";".join(["wait:800"] + rs), MOJOUI_SHOT="")
        r = run(["scripts/testscreen", str(APP)], 1200, env=env)
        (out / f"native-run{k}.log").write_text(r.stdout + r.stderr)
    worst = []
    for i, s in enumerate(steps):
        w, n = out / "web" / f"{i:02d}.png", out / "native" / f"{i:02d}.png"
        if not w.exists() or not n.exists():
            probs.append(f"step {i} ({s['name']}): no {'web' if not w.exists() else 'native'} shot")
            continue
        sc = ssim(grey(w), grey(n)) if Image.open(w).size == Image.open(n).size else 0.0
        worst.append((sc, i))
        if sc < SSIM_MIN:
            probs.append(f"step {i} ({s['name']}): SSIM {sc:.3f}")
    verdicts = region_verdicts(steps, out / "web", out / "native")
    for i, prob, detail in verdicts:
        if prob:
            probs.append(prob)
    regions = [d for _, _, d in verdicts]
    (out / "regions.txt").write_text("\n".join(f"{i:02d} {steps[i]['name']}: {d}" for i, d in enumerate(regions)) + "\n")
    # (D-7931) the self-test: native played again with one step left out must be caught by the region check
    skip = next((i for i, st in enumerate(steps) if st["name"] == "tick a task"), None)
    if skip is not None:  # (run whatever the other steps found: it proves the check, not the app)
        sk = out / "skipped"
        shutil.rmtree(sk, ignore_errors=True)
        sk.mkdir()
        shutil.copy(REF / "pn.db", sk / "native.db")
        acts = [f"gpushot:desk={sk / 'start.png'}"]
        for i, st in enumerate(steps[:skip + 2]):
            if i != skip:
                acts += [a for a in (st["native"] if isinstance(st["native"], list) else [st["native"]]) if a != "relaunch"]
            acts.append(f"gpushot:desk={sk / f'{i:02d}.png'}")
        env = dict(os.environ, PNOTE_DB=str(sk / "native.db"), PNOTE_SKIN="paper", OMX_CONFIG=str(cfg), PNOTE_DIR=str(cfg),
                   MOJOUI_TEST=";".join(["wait:800"] + acts), MOJOUI_SHOT="")
        run(["scripts/testscreen", str(APP)], 1200, env=env)
        caught = [p_ for i, p_, _ in region_verdicts(steps[:skip + 1], out / "web", sk) if i == skip and p_]
        old = ssim(grey(out / "web" / f"{skip:02d}.png"), grey(sk / f"{skip:02d}.png")) if (sk / f"{skip:02d}.png").exists() else 0.0
        if not caught:
            probs.append(f"self-test: native without step {skip} ({steps[skip]['name']}) wasn't caught by the region check (whole-frame SSIM {old:.3f})")
        else:
            (out / "selftest.txt").write_text(f"skipped step {skip}: whole-frame SSIM {old:.3f} (the old check: {'pass' if old >= SSIM_MIN else 'fail'}); region check: {caught[0]}\n")
    web_notes = normalized_notes(out / "web.db")
    nat_notes = normalized_notes(out / "native.db")
    if web_notes != nat_notes:
        diff = [f"{a[0]}" for a, b in zip(web_notes, nat_notes) if a != b] or [f"{len(web_notes)} vs {len(nat_notes)} notes"]
        probs.append(f"saved notes differ: {diff[:5]}")
        (out / "notes-web.json").write_text(json.dumps(web_notes, indent=1, ensure_ascii=False))
        (out / "notes-native.json").write_text(json.dumps(nat_notes, indent=1, ensure_ascii=False))
    if probs:
        return "FAIL", "; ".join(probs)[:1500]
    return "PASS", f"{len(steps)} steps, worst SSIM {min(worst)[0]:.3f} (step {min(worst)[1]}), saved notes equal through the web API"


# ---------------------------------------------------------------- M5: typing in other languages

IME_WORDS = {"japanese": "漢字", "hindi": "नमस्ते", "korean": "한국어"}


def m5():
    err = make_ref() or build_linux()
    if err:
        return "FAIL", err
    out = OUT / "m5"
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    shutil.copy(REF / "pn.db", out / "ime.db")
    sb = json.loads((REF / "page-sidebar.boxes.json").read_text())
    row = next(k for k in sb if k.startswith("row:") and k.endswith("Weekly review"))
    # Japanese: kana preedit, then the converted kanji committed; Hindi and Korean composed and committed; then the
    # same text pasted from the system clipboard
    steps = ["wait:800", f"tapat:desk={box_center(sb, row)}", "wait:600", "key:desk=ctrl+End",
             "imepreedit:desk=かんじ", "wait:200", "render:desk=" + str(out / "preedit.png"), "imecommit:desk=漢字", "key:desk=Return",
             "imepreedit:desk=नमस्", "imecommit:desk=नमस्ते", "key:desk=Return",
             "imepreedit:desk=한", "imecommit:desk=한국어", "key:desk=Return",
             "clipboard:漢字 नमस्ते 한국어", "key:desk=ctrl+v", "wait:800"]
    cfg = out / "cfg"
    cfg.mkdir()
    env = dict(os.environ, PNOTE_DB=str(out / "ime.db"), PNOTE_SKIN="paper", OMX_CONFIG=str(cfg), PNOTE_DIR=str(cfg),
               MOJOUI_TEST=";".join(steps), MOJOUI_SHOT="")
    r = run(["scripts/testscreen", str(APP)], 600, env=env)
    log = r.stdout + r.stderr
    (out / "linux.log").write_text(log)
    probs = []
    # the app's real GtkIMContext: preedit drawn underlined at the caret, the candidate window placed there
    pre = re.search(r"^PNOTE IME: preedit=\"かんじ\" underline=1 caret=([\d.]+),([\d.]+) cursor_location=([\d.]+),([\d.]+),([\d.]+),([\d.]+)", log, re.M)
    if not pre:
        probs.append("Linux: no 'PNOTE IME: preedit=\"かんじ\" underline=1 caret=… cursor_location=…' from the app's GtkIMContext")
    elif abs(float(pre.group(1)) - float(pre.group(3))) > 2 or abs(float(pre.group(2)) - float(pre.group(4))) > 24:
        probs.append(f"Linux: the candidate window ({pre.group(3)},{pre.group(4)}) isn't at the caret ({pre.group(1)},{pre.group(2)})")
    # (fixed 11-19, D-7918) the IM context is the framework's, made by the GTK host for the app's canvas: "IME: context=…"
    if not re.search(r"^(PNOTE )?IME: context=Gtk\w*IM\w*", log, re.M):
        probs.append("Linux: the app didn't report the IM context it created")
    md = page_markdown(out / "ime.db", "Weekly review")
    want = "漢字\nनमस्ते\n한국어\n漢字 नमस्ते 한국어"
    if md is None or want not in md:
        probs.append(f"Linux: saved Markdown {md!r} lacks {want!r}")
    if "かんじ" in (md or ""):
        probs.append("Linux: the preedit text was saved")
    mac_said = ""
    m = mac_reachable()
    if m:
        mac_said = f"Mac BLOCKED ({m})"
    else:
        # (D-7979, fixed 11-22: the Mac half had never run: no PNOTE_OPEN exists; the same path as Linux's: the note's row,
        # the caret to the end; the saved note read back from the app's own database, fetched from the Mac)
        os.environ["MAC_FETCH"] = "pn.db pn.db-wal pn.db-shm"
        out_mac, e = mac_run("ime", ["wait:800", f"tapat:desk={box_center(sb, row)}", "wait:600", "key:desk=ctrl+End",
                                     "imemarked:desk=かんじ", "imefirstrect:desk", "imeinsert:desk=漢字", "key:desk=Return",
                                     "imemarked:desk=नमस्", "imeinsert:desk=नमस्ते", "key:desk=Return", "imemarked:desk=한", "imeinsert:desk=한국어",
                                     "key:desk=Return", "clipboard:漢字 नमस्ते 한국어", "key:desk=ctrl+v", "wait:800"],
                             {"PNOTE_DB": "{data}/pn.db", "PNOTE_SKIN": "paper"}, [REF / "pn.db"])
        os.environ.pop("MAC_FETCH", None)
        if e:
            probs.append("Mac: " + e)
        else:
            # (D-7979) the host's own line when setMarkedText:… ran on the real view, the app's line when the composition
            # reached it drawn underlined (both: the method and its effect), and firstRectForCharacterRange:'s answer
            if (not re.search(r"^IME: marked=\"かんじ\"", out_mac, re.M) or not re.search(r"^PNOTE IME: preedit=\"かんじ\" underline=1", out_mac, re.M)
                    or not re.search(r"^IME: firstRect=[\d.-]+,[\d.-]+,[\d.]+,[\d.]+ markedRange=0,3 ", out_mac, re.M)):
                probs.append("Mac: setMarkedText/firstRectForCharacterRange not seen on the real view")
            rep = next(iter(sorted((ROOT / "build/mac-ssh").glob("pnote-*"))[-1:]), None)
            dbm = next(iter(rep.rglob("pn.db")), None) if rep else None
            md_mac = page_markdown(dbm, "Weekly review") if dbm else None
            if md_mac is None or want not in md_mac:
                probs.append(f"Mac: saved Markdown {md_mac!r} lacks {want!r}")
            if "かんじ" in (md_mac or ""):
                probs.append("Mac: the marked text was saved")
            mac_said = "Mac: NSTextInputClient on the real view"
    if probs:
        return "FAIL", "; ".join(probs)
    if mac_said.startswith("Mac BLOCKED"):
        return "BLOCKED", f"Linux PASS (GtkIMContext preedit/commit, paste); {mac_said}"
    return "PASS", f"Linux: GtkIMContext preedit underlined at the caret, commits and paste saved exactly; {mac_said}"


def page_markdown(db, title):
    try:
        c = sqlite3.connect(db)
        for (content,) in c.execute("SELECT content FROM notes WHERE title = ?", (title,)):
            try:
                return json.loads(content).get("markdown")
            except Exception:
                return content
    except Exception:
        return None
    return None


# ---------------------------------------------------------------- M6: faster than the web

def m6():
    M6_RUNNING[0] = True
    LINUX_LOAD.clear()
    try:
        return m6_both()
    finally:
        M6_RUNNING[0] = False


def m6_both():
    if os.environ.get("M6_ONLY") == "mac":  # (D-7988) the Mac's half alone, while iterating there: never a PASS by itself
        race = OUT / "race"
        rt = run(["pixi", "run", "mojo", "build", "-I", ".", "-I", "vendor", "-o", str(race / "test_canvasload"), "tests/test_canvasload.mojo"], 900)
        rt2 = run([str(race / "test_canvasload")], 300) if rt.returncode == 0 else rt
        OPEN_TEST_OK[0] = rt2.returncode == 0 and "canvasload: ok" in rt2.stdout  # (the open's contract is the framework's: same test)
        st, msg = m6_mac(race)
        return ("FAIL" if st == "PASS" else st), f"Linux half not run (M6_ONLY=mac); Mac {st}: {msg}"
    err = build_linux()
    if err:
        return "FAIL", err
    race = OUT / "race"
    race.mkdir(parents=True, exist_ok=True)
    stale = list(race.glob("*.log")) + list(race.glob("*.json"))  # (an earlier race's and diagnoses': put aside, so that what is kept with the table is this race's)
    if stale:
        aside = OUT / "race-old" / time.strftime("%Y%m%d-%H%M%S")
        aside.mkdir(parents=True)
        for f in stale:
            f.rename(aside / f.name)
    # (D-7946 (d)) the progressive open's contract: a pan and an edit during the open end as the whole import does
    rt = run(["pixi", "run", "mojo", "build", "-I", ".", "-I", "vendor", "-o", str(race / "test_canvasload"), "tests/test_canvasload.mojo"], 900)
    rt2 = run([str(race / "test_canvasload")], 300) if rt.returncode == 0 else rt
    OPEN_TEST_OK[0] = rt2.returncode == 0 and "canvasload: ok" in rt2.stdout
    (race / "test_canvasload.log").write_text(rt.stdout + rt.stderr + rt2.stdout + rt2.stderr)
    probs = []
    # the web at its best: PN's own benchmarks, Chromium with the GPU, at the native run's device scale
    print("(running Personal Note's own benchmarks: several minutes)", flush=True)
    if why := not_free():
        return "BLOCKED", why
    STATES["web"].clear()
    STATES["native"].clear()
    r = web_headed("scripts/benchmark-f034.mjs", "--gpu", f"--dpr={LINUX_DPR}", "--note=both", f"--out={race / 'web-f034.json'}", timeout=3600)
    (race / "web-f034.log").write_text(r.stdout + r.stderr)
    if r.returncode or not (race / "web-f034.json").exists():
        return "FAIL", f"benchmark-f034 exit {r.returncode}: {tail(r.stdout + r.stderr)}"
    r2 = run(["node", "scripts/benchmark-first-screen.mjs"], 1800, cwd=PN)
    (race / "web-first-screen.log").write_text(r2.stdout + r2.stderr)
    web = web_race(json.loads((race / "web-f034.json").read_text()), r2.stdout)
    # (added 11-19, D-7917) the web's memory: PN's scripts measure none, so docs/goals/79/webmem.mjs opens a note of each
    # kind in Chromium (with the GPU, as the race) on the reference's database and sums Chromium's processes and the API
    err = make_ref()
    if err:
        return "FAIL", err
    if why := not_free():
        return "BLOCKED", why
    r3 = web_headed(ROOT / "docs/goals/79/webmem.mjs", str(REF / "pn.db"), "--gpu", f"--dpr={LINUX_DPR}", timeout=600)
    (race / "web-mem.log").write_text(r3.stdout + r3.stderr)
    mm = re.search(r"WEB RSS MB: ([\d.]+)", r3.stdout)
    web["rss_mb"] = float(mm.group(1)) if mm else None
    if why := not_free():
        return "BLOCKED", why
    rs = web_headed(ROOT / "docs/goals/79/webswitch.mjs", str(REF / "pn.db"), "--gpu", f"--dpr={LINUX_DPR}")  # (D-8001)
    (race / "web-switch.log").write_text(rs.stdout + rs.stderr)
    web.update(web_switch(rs.stdout))
    # the web's first screen: the "after" build of PN's benchmark (both are this checkout)
    mf = re.search(r"after\s+first screen (\d+)", r2.stdout)
    if mf:
        web["first_screen_ms"] = float(mf.group(1))
    # the native app: the same notes in Personal Note's own schema (D-7929: seedrace.mjs writes PN's generators' notes into
    # scratch copies of the reference database through the web app's own API), on pnote's web look (PNOTE_DB), the
    # same steps. Each note is raced twice: as it runs (the canvas offloaded to the compositor: the frame's work) and with
    # GTK compositing the canvas (MOJOUI_OFFLOAD=0), whose frames report when they reached the screen.
    r = run(["node", str(ROOT / "docs/goals/79/seedrace.mjs"), str(REF / "pn.db"), str(race)], 900, cwd=PN)
    (race / "seedrace.log").write_text(r.stdout + r.stderr)
    if r.returncode or "SEEDED stress" not in r.stdout:
        return "FAIL", f"seeding the race notes through the web API: {tail(r.stdout + r.stderr)}"
    for note in RACE_NOTES:  # (D-8026: the web's opening of the same note inside the running app, the native open row's span)
        if why := not_free():
            return "BLOCKED", why
        rw = web_headed(ROOT / "docs/goals/79/webopen.mjs", str(race / f"race-{note}.db"), "--gpu", f"--dpr={LINUX_DPR}")
        (race / f"web-open-{note}.log").write_text(rw.stdout + rw.stderr)
        web.setdefault(note, {}).update(web_open(rw.stdout))
    # (review 4, MUST 5) typing in the middle of a page's 20,000-character paragraph: the web, then native on the note it made
    if why := not_free():
        return "BLOCKED", why
    rt_ = web_headed(ROOT / "docs/goals/79/webtype.mjs", str(REF / "pn.db"), str(race / "race-page.db"), "--gpu", f"--dpr={LINUX_DPR}")
    (race / "web-type.log").write_text(rt_.stdout + rt_.stderr)
    web["type page"] = web_type(rt_.stdout)
    cfg = race / "cfg-type"
    shutil.rmtree(cfg, ignore_errors=True)
    cfg.mkdir()
    if (race / "race-page.db").exists():
        shutil.copy(race / "race-page.db", cfg / "pn.db")
    env = dict(os.environ, PNOTE_DIR=str(cfg), OMX_CONFIG=str(cfg), PNOTE_DB=str(cfg / "pn.db"), MOJOUI_BENCH_PACED="1", MOJOUI_TEST=";".join(TYPE_STEPS), MOJOUI_SHOT="")
    r = run(["scripts/testscreen", str(APP)], 600, env=env)
    (race / "native-type.log").write_text(r.stdout + r.stderr)
    native_states("typing", r.stdout + r.stderr)
    typed = native_race(r.stdout + r.stderr).get("typing")
    nat, shown, paced, unwarm, opens = {}, {}, {}, {}, {}
    # (D-7951, review 2) the process's very first open of each race note: pnote starts on another note (PNOTE_FIRST), so
    # nothing of the canvas (tiles, parses, its glyphs at that zoom) exists in the process. (D-7956/D-7958) Twice: A, the
    # first open ever (no kept view on disk: parsed; printed, not judged), which keeps the settled view (it waits 4 s);
    # B, a new process opening it again from that kept view (judged with the cold opens, labelled). The race below
    # starts from B's folder, so its cold opens can use the kept view; how many did is counted and printed.
    snapinfo = {}
    for note in RACE_NOTES:
        cfg = race / f"cfg-first-{note}"
        shutil.rmtree(cfg, ignore_errors=True)
        cfg.mkdir()
        shutil.copy(race / f"race-{note}.db", cfg / "pn.db")
        other = subprocess.run(["sqlite3", str(cfg / "pn.db"), "SELECT id FROM notes WHERE note_type = 'page' AND secure = 0 ORDER BY id LIMIT 1"],
                               capture_output=True, text=True).stdout.strip()
        for run_ in ("A", "B"):
            steps = ["wait:800", "window:1440x900", "appbench:desk=coldopens", "framebench:desk=open,1"] + (["wait:4000"] if run_ == "A" else [])
            env = dict(os.environ, PNOTE_DIR=str(cfg), OMX_CONFIG=str(cfg), PNOTE_DB=str(cfg / "pn.db"), PNOTE_FIRST=other,
                       MOJOUI_SNAP_LOG="1", MOJOUI_TEST=";".join(steps), MOJOUI_SHOT="")
            r = run(["scripts/testscreen", str(APP)], 600, env=env)
            log = r.stdout + r.stderr
            (race / f"native-first-{note}{'-nosnap' if run_ == 'A' else ''}.log").write_text(log)
            fo = native_race(log).get("open")
            used = "SNAP: restored" in log
            snapinfo.setdefault(note, {})[run_] = {"open": fo, "snap": used, "saved": "SNAP: saved" in log}
            if run_ == "B" and fo:
                nat.setdefault(note, {})["first open"] = dict(fo, snap=used)
    # (D-8026) frames shown: the process's first open ever (nothing kept) and the next process's, from its kept view, with
    # nothing of the measurement in the frames (MOJOUI_BENCH_PACED)
    for note in RACE_NOTES:
        cfg = race / f"cfg-firstpaced-{note}"
        shutil.rmtree(cfg, ignore_errors=True)
        cfg.mkdir()
        shutil.copy(race / f"race-{note}.db", cfg / "pn.db")
        for run_ in ("A", "B"):
            steps = ["wait:800", "window:1440x900", "appbench:desk=coldopens", "framebench:desk=open,1"] + (["wait:4000"] if run_ == "A" else [])
            env = dict(os.environ, PNOTE_DIR=str(cfg), OMX_CONFIG=str(cfg), PNOTE_DB=str(cfg / "pn.db"), PNOTE_FIRST=other,
                       MOJOUI_SNAP_LOG="1", MOJOUI_BENCH_PACED="1", MOJOUI_TEST=";".join(steps), MOJOUI_SHOT="")
            r = run(["scripts/testscreen", str(APP)], 600, env=env)
            log = r.stdout + r.stderr
            (race / f"native-firstpaced-{note}-{run_}.log").write_text(log)
            opens.setdefault(note, {})[run_] = dict(native_race(log).get("open") or {}, snap="SNAP: restored" in log)
    # (D-8026) the whole race once more as frames are shown: the app as it runs, and once with its idle warming off
    for note in RACE_NOTES:
        for warm in (True, False):
            cfg = race / f"cfg-paced-{note}"
            shutil.rmtree(cfg, ignore_errors=True)
            cfg.mkdir()
            shutil.copy(race / f"race-{note}.db", cfg / "pn.db")
            if (race / f"cfg-first-{note}" / "snaps").exists():
                shutil.copytree(race / f"cfg-first-{note}" / "snaps", cfg / "snaps")
            env = dict(os.environ, PNOTE_DIR=str(cfg), OMX_CONFIG=str(cfg), PNOTE_DB=str(cfg / "pn.db"), MOJOUI_SNAP_LOG="1", MOJOUI_BENCH_PACED="1",
                       MOJOUI_TEST=";".join(["wait:800", "window:1440x900"] + PACED_RACE), MOJOUI_SHOT="")
            if not warm:
                env.update(MOJOUI_SCENEWARM="0", MOJOUI_GLYPHWARM="0")
            r = run(["scripts/testscreen", str(APP)], 1800, env=env)
            (race / f"native-paced-{note}{'' if warm else '-notwarm'}.log").write_text(r.stdout + r.stderr)
            native_states(f"paced {note}", r.stdout + r.stderr)
            (paced if warm else unwarm)[note] = native_race(r.stdout + r.stderr)
    for note in RACE_NOTES:
        for visible in (False, True):
            cfg = race / f"cfg-{note}"
            shutil.rmtree(cfg, ignore_errors=True)
            cfg.mkdir()
            shutil.copy(race / f"race-{note}.db", cfg / "pn.db")
            if (race / f"cfg-first-{note}" / "snaps").exists():  # (the kept view B opened from)
                shutil.copytree(race / f"cfg-first-{note}" / "snaps", cfg / "snaps")
            env = dict(os.environ, PNOTE_DIR=str(cfg), OMX_CONFIG=str(cfg), PNOTE_DB=str(cfg / "pn.db"), MOJOUI_SNAP_LOG="1",
                       MOJOUI_TEST=";".join(["wait:800", "window:1440x900"] + NATIVE_RACE), MOJOUI_SHOT="")
            if visible:
                env["MOJOUI_OFFLOAD"] = "0"
            r = run(["scripts/testscreen", str(APP)], 1800, env=env)
            log = r.stdout + r.stderr
            (race / f"native-{note}{'-composited' if visible else ''}.log").write_text(log)
            # (a strengthening, D-7929) the race must time the rebuilt app: the web look on the seeded note
            if not re.search(r"^PNOTE WEB: \d+ notes from ", log, re.M):
                return "FAIL", f"native race on {note}{' (composited)' if visible else ''} didn't run pnote's web look (no 'PNOTE WEB:' line): {tail(log)}"
            if visible:
                shown[note] = native_race(log)
            else:
                first_ = nat.get(note, {}).get("first open")
                nat[note] = native_race(log)
                if first_:
                    nat[note]["first open"] = first_
                cold = log.split("APPBENCH: coldopens", 1)[-1].split("APPBENCH: keptopens", 1)[0]
                snapinfo.setdefault(note, {})["cold"] = (cold.count("SNAP: restored"), cold.count("SNAP: restored") + cold.count("SNAP: none") + cold.count("SNAP: refused"))
        # (D-7958) the same cold opens with the kept view turned off (MOJOUI_SNAP=0): printed beside, not judged
        cfg = race / f"cfg-nosnap-{note}"
        shutil.rmtree(cfg, ignore_errors=True)
        cfg.mkdir()
        shutil.copy(race / f"race-{note}.db", cfg / "pn.db")
        env = dict(os.environ, PNOTE_DIR=str(cfg), OMX_CONFIG=str(cfg), PNOTE_DB=str(cfg / "pn.db"), MOJOUI_SNAP="0",
                   MOJOUI_TEST=";".join(["wait:800", "window:1440x900", "appbench:desk=coldopens", "framebench:desk=open,20", "framebench:desk=openpress,10"]), MOJOUI_SHOT="")
        r = run(["scripts/testscreen", str(APP)], 900, env=env)
        (race / f"native-nosnap-{note}.log").write_text(r.stdout + r.stderr)
        snapinfo.setdefault(note, {})["off"] = native_race(r.stdout + r.stderr).get("open")
    SNAPINFO.clear()
    SNAPINFO.update(snapinfo)
    starts = []
    for _ in range(5):
        cfg = race / "cfg-start"
        shutil.rmtree(cfg, ignore_errors=True)
        cfg.mkdir()
        shutil.copy(REF / "pn.db", cfg / "pn.db") if (REF / "pn.db").exists() else None
        env = dict(os.environ, PNOTE_DIR=str(cfg), OMX_CONFIG=str(cfg), PNOTE_DB=str(cfg / "pn.db"),
                   MOJOUI_TEST=";".join(["firstscreen:", "noteswitch:5", "omnibar:5", "openall:", "rss:"]), MOJOUI_SHOT="")
        r = run(["scripts/testscreen", str(APP)], 600, env=env)
        (race / "native-start.log").write_text(r.stdout + r.stderr)
        if not re.search(r"^PNOTE WEB: \d+ notes from ", r.stdout + r.stderr, re.M):  # (review 2: the start runs time the web look too)
            return "FAIL", f"native start-up run didn't run pnote's web look (no 'PNOTE WEB:' line): {tail(r.stdout + r.stderr)}"
        starts.append(r.stdout + r.stderr)
    nstart = native_start(starts)
    # (D-8002) a second start in the same folder (the glyphs of the first one readied while nothing happens): printed, not judged
    r = run(["scripts/testscreen", str(APP)], 600, env=env)
    nstart["second"] = native_start([r.stdout + r.stderr])
    # (D-7950, set by the main session) cold start, like with like: Personal Note's own desktop launcher cold, and a
    # fresh Chromium process on the built app, each from its process's start to the title island painted
    for mode in ("desktop", "chromium"):
        r = run([str(ROOT / "scripts/testscreen"), "node", str(ROOT / "docs/goals/79/webcold.mjs"), str(REF / "pn.db"), mode, "5"], 900, env=dict(os.environ, **COLD_ENV), cwd=PN)
        (race / f"web-cold-{mode}.log").write_text(r.stdout + r.stderr)
        m = re.search(rf"WEBCOLD {mode} median: ([\d.]+)", r.stdout)
        web[f"cold_{mode}_ms"] = float(m.group(1)) if m else None
    noisy = [f"{w} ({c} cores)" for w, c, q in LINUX_LOAD if not q]
    if noisy:  # (a measured run that started on a busy machine says nothing, web or native)
        return "BLOCKED", "void: the CPU wasn't quiet before " + "; ".join(noisy)[:500]
    fair = fair_rounds(race) if FAIR_RULE else None
    probs = unlike(STATES)
    rows, ok = race_table(web, nat, nstart, shown, paced=paced, unwarm=unwarm, opens=opens, typed=typed, states=STATES, fair=fair)
    keep_logs(race, "linux", rows)
    if probs:
        (race / "race-unlike.md").write_text(rows)
        return "BLOCKED", "not like-for-like, not judged: " + "; ".join(probs)[:700]
    (ROOT / "docs/goals/79").mkdir(parents=True, exist_ok=True)
    (ROOT / "docs/goals/79/race.md").write_text(rows)
    linux = "PASS (docs/goals/79/race.md)" if ok else "FAIL: " + "; ".join(l for l in rows.splitlines() if "✗" in l)[:700]
    # (D-7988) the Mac's half runs whatever Linux's said, and both are reported
    mst, mmsg = m6_mac(race)
    if ok and mst == "PASS":
        return "PASS", "native better than the web, or within 3 % of it, on every row, on both machines (the owner's ruling, GOAL.md M6); docs/goals/79/race.md, race-mac.md"
    status = "FAIL" if (not ok or mst == "FAIL") else "BLOCKED"
    return status, f"Linux {linux}; Mac {mst}: {mmsg}"


def mac_sh(cmd, timeout=3600):
    """A shell command on the Mac (its login shell, zsh); the CompletedProcess."""
    return run(["ssh", "-i", MAC_KEY, "-o", "ConnectTimeout=15", "-o", "BatchMode=yes", MAC_SSH, cmd], timeout)


def mac_put(local, remote):
    r = run(["scp", "-q", "-i", MAC_KEY, str(local), f"{MAC_SSH}:{remote}"], 600)
    return r.returncode == 0


def mac_get(remote, local):
    """A file from the Mac by ssh cat (scp from the Mac closes the connection on some runs)."""
    r = subprocess.run(["ssh", "-i", MAC_KEY, "-o", "ConnectTimeout=15", "-o", "BatchMode=yes", MAC_SSH, f"cat {remote}"], capture_output=True, timeout=600)
    if r.returncode == 0:
        Path(local).write_bytes(r.stdout)
    return r.returncode == 0


MAC_WEB = "omxcode-g79-web"  # (ruling B, D-7977: everything the web side needs on the Mac, listed in docs/goals/79/mac-setup.md)


def keep_logs(race, what, rows):
    """The logs behind a table, under a folder of their own (review 5: later runs had written over them)."""
    d = OUT / "race-logs" / f"{what}-{time.strftime('%Y%m%d-%H%M%S')}"
    d.mkdir(parents=True, exist_ok=True)
    for f in list(race.glob("*.log")) + list(race.glob("*.json")):
        shutil.copy(f, d / f.name)
    (d / "table.md").write_text(rows)
    (d / "states.json").write_text(json.dumps(STATES, indent=1))


def mac_screens():
    """The Mac's screens as the app sees them, and whether a window of it comes to the front there with the screen unlocked:
    ([(number, name, at, scale, refresh)], '') or ([], why not)."""
    out, e = mac_run("screens", ["wait:800", "window:1440x900", "framebench:desk=open,1"], {"PNOTE_DB": "{data}/pn.db", "OMX_CONFIG": "{data}/cfg-screens", "MOJOUI_SCREENS": "1",
                     "MOJOUI_BENCH_PACED": "1", "MOJOUI_BENCHSTATE": "1"}, [REF_MAC / "pn.db"])
    if e:
        return [], f"the Mac's screens: {e}"
    if not mac_live(out):
        return [], "the Mac's screen is locked, or the app doesn't come to the front: nothing is raced (scripts/mac-unlocked says when it is)"
    return [(int(m.group(1)), m.group(5).strip(), m.group(2), float(m.group(3)), float(m.group(4)))
            for m in re.finditer(r"^SCREEN: (\d+) at=(\S+) size=\S+ scale=([\d.]+) refresh=([\d.]+) name=(.*)$", out, re.M)], ""


def m6_mac(race):
    """The Mac's half, on every screen it has that shows windows of its own (mirrored ones are one screen): one table each, the
    web and native both in visible windows there, or refused."""
    m = mac_reachable()
    if m:
        return "BLOCKED", m
    screens, why = mac_screens()
    if why:
        return "BLOCKED", why
    tables, said, worst = [], [], "PASS"
    for n, name, at, scale, refresh in screens:
        STATES["web"].clear()
        STATES["native"].clear()
        label = f"the Mac's {name}, {scale:g}×, {refresh:g} Hz" + ("" if len(screens) > 1 else " (the one screen macOS shows windows on: a second one is off, closed or mirrored)")
        print(f"(racing on {label})", flush=True)
        st, msg, rows = m6_mac_screen(race, n, at, scale, label)
        said.append(f"{label}: {st} {msg}")
        if rows:
            tables.append(rows)
            keep_logs(OUT / "race-mac", f"mac-screen{n}", rows)
        worst = "FAIL" if "FAIL" in (st, worst) else ("BLOCKED" if "BLOCKED" in (st, worst) else "PASS")
    if tables:
        (ROOT / "docs/goals/79/race-mac.md").write_text("\n\n".join(tables))
    return worst, "; ".join(said)[:900]


def m6_mac_screen(race, screen, at, dpr, label):
    """(status, message, table). (D-7988) M6's Mac half, as Linux's: the web at its best on the M4 (benchmark-f034 under macgpu.mjs, memory, a fresh
    Chrome's cold start) and native pnote on the AppKit host (first opens A/B, the race on both notes, start-up and RSS).
    The table is the caller's to write."""
    if mac_sh(f"test -x {MAC_WEB}/node/bin/node && test -d {MAC_WEB}/pn/node_modules/playwright", 60).returncode:
        return "BLOCKED", f"the Mac has no ~/{MAC_WEB} (ruling B's setup: docs/goals/79/mac-setup.md)", None
    for note in RACE_NOTES:
        if not (race / f"race-{note}.db").exists():
            return "FAIL", f"no {race}/race-{note}.db (Linux's M6 seeds the race notes through the web API first)", None
    MAC_SCREEN[0] = str(screen)
    err = make_ref(REF_MAC, MAC_DPR) if not (REF_MAC / "pn.db").exists() else ""
    if err:
        return "FAIL", "the Mac's reference: " + err, None
    rm = OUT / "race-mac"
    rm.mkdir(parents=True, exist_ok=True)
    # the web, on the Mac
    print("(the web's race on the Mac in its own Chrome on Metal: several minutes)", flush=True)
    lock = MacLock().__enter__()
    mac_sh(f"mkdir -p {MAC_WEB}/pn/.g79 {MAC_WEB}/race-mac {MAC_WEB}/tmp", 60)
    for f in ("headed.mjs", "webmem.mjs", "webcold.mjs", "webswitch.mjs", "webopen.mjs", "webtype.mjs", "desktop_cold_mac.py"):
        if not mac_put(ROOT / "docs/goals/79" / f, f"{MAC_WEB}/pn/.g79/{f}"):
            return "FAIL", f"copying {f} to the Mac", None
    if not mac_put(REF_MAC / "pn.db", f"{MAC_WEB}/race-mac/ref.db"):
        return "FAIL", "copying the reference database to the Mac", None
    envp = f"cd {MAC_WEB}/pn && export PATH=$HOME/{MAC_WEB}/node/bin:$PATH PW_CHANNEL=chrome WEB_WINDOW_AT={at} TMPDIR=$HOME/{MAC_WEB}/tmp PN_PYTHON=$HOME/{MAC_WEB}/pyenv/.pixi/envs/default/bin/python && "
    r, e = mac_web("web race", envp + f"node --import ./.g79/headed.mjs scripts/benchmark-f034.mjs --gpu --dpr={dpr:g} --note=both --out=../race-mac/web-f034.json", 3600)
    if e:
        return "FAIL", e, None
    web_states("web race", r.stdout + r.stderr)
    (rm / "web-f034.log").write_text(r.stdout + r.stderr)
    if r.returncode or not mac_get(f"{MAC_WEB}/race-mac/web-f034.json", rm / "web-f034.json"):
        return "FAIL", f"benchmark-f034 on the Mac, exit {r.returncode}: {tail(r.stdout + r.stderr)}", None
    gpu = re.search(r"^WEBSTATE: .*browser=(.*)$", r.stdout + r.stderr, re.M)
    web = web_race(json.loads((rm / "web-f034.json").read_text()), "")
    r, e = mac_web("web memory", envp + f"node --import ./.g79/headed.mjs .g79/webmem.mjs ../race-mac/ref.db --gpu --dpr={dpr:g}", 900)
    if e:
        return "FAIL", e, None
    web_states("web memory", r.stdout + r.stderr)
    (rm / "web-mem.log").write_text(r.stdout + r.stderr)
    mm = re.search(r"WEB RSS MB: ([\d.]+)", r.stdout)
    web["rss_mb"] = float(mm.group(1)) if mm else None
    r, e = mac_web("web switch", envp + f"node --import ./.g79/headed.mjs .g79/webswitch.mjs ../race-mac/ref.db --gpu --dpr={dpr:g}", 900)  # (D-8001)
    if e:
        return "FAIL", e, None
    web_states("web switch", r.stdout + r.stderr)
    (rm / "web-switch.log").write_text(r.stdout + r.stderr)
    web.update(web_switch(r.stdout))
    r, e = mac_web("web type", envp + f"node --import ./.g79/headed.mjs .g79/webtype.mjs ../race-mac/ref.db --gpu --dpr={dpr:g}", 900)
    if e:
        return "FAIL", e, None
    web_states("web type", r.stdout + r.stderr)
    (rm / "web-type.log").write_text(r.stdout + r.stderr)
    web["type page"] = web_type(r.stdout)
    for mode in ("desktop", "chromium"):
        r, e = mac_web(f"web cold {mode}", envp + f"node .g79/webcold.mjs ../race-mac/ref.db {mode} 5", 900)
        if e:
            return "FAIL", e, None
        (rm / f"web-cold-{mode}.log").write_text(r.stdout + r.stderr)
        mc = re.search(rf"WEBCOLD {mode} median: ([\d.]+)", r.stdout)
        web[f"cold_{mode}_ms"] = float(mc.group(1)) if mc else None
        mw_ = re.search(r"WEBCOLD desktop window median: ([\d.]+)", r.stdout)
        if mode == "desktop":
            web["cold_desktop_window_ms"] = float(mw_.group(1)) if mw_ else None
    for note in RACE_NOTES:  # (D-8026)
        if not mac_put(race / f"race-{note}.db", f"{MAC_WEB}/race-mac/race-{note}.db"):
            return "FAIL", f"copying race-{note}.db to the Mac", None
        r, e = mac_web(f"web open {note}", envp + f"node --import ./.g79/headed.mjs .g79/webopen.mjs ../race-mac/race-{note}.db --gpu --dpr={dpr:g}", 900)
        if e:
            return "FAIL", e, None
        (rm / f"web-open-{note}.log").write_text(r.stdout + r.stderr)
        web_states(f"web open {note}", r.stdout + r.stderr)
        web.setdefault(note, {}).update(web_open(r.stdout))
    lock.__exit__()
    # (D-8002) built once, then every native run from that bundle, the machine held for one note's runs at a time
    lock = MacLock().__enter__()
    out, e = mac_run("build", ["wait:300"], {"PNOTE_DB": "{data}/pn.db", "OMX_CONFIG": "{data}/cfg-build"}, [REF_MAC / "pn.db"])
    if e:
        return "FAIL", f"building on the Mac: {e}", None
    lock.__exit__()
    # native, on the Mac: kept views and settings in the Mac's scratch folder ({data}), never ~/.config
    nat, snapinfo = {}, {}
    stamp = time.strftime("%H%M%S")
    for note in RACE_NOTES:
        lock = MacLock().__enter__()
        db = race / f"race-{note}.db"
        other = subprocess.run(["sqlite3", str(db), "SELECT id FROM notes WHERE note_type = 'page' AND secure = 0 ORDER BY id LIMIT 1"],
                               capture_output=True, text=True).stdout.strip()
        base = {"PNOTE_DB": "{data}/" + db.name, "PNOTE_SNAPS": "{data}/snaps-" + note + "-" + stamp, "OMX_CONFIG": "{data}/cfg-first-" + note + "-" + stamp, "MOJOUI_SNAP_LOG": "1"}
        for run_ in ("A", "B"):
            steps = ["wait:800", "window:1440x900", "appbench:desk=coldopens", "framebench:desk=open,1"] + (["wait:4000"] if run_ == "A" else [])
            # (D-7994: one build for the Mac's half, the first run's; the kept view names its program, as on Linux)
            out, e = mac_measured(f"first-{note}-{run_}", steps, dict(base, PNOTE_FIRST=other), [db])
            if not e and run_ == "A" and "SNAP: saved" not in out:  # (D-8016: it once kept none and was run again; the cause is fixed, so it is a failure)
                return "FAIL", f"first open A on {note} kept no view (a note opened and left must keep it: D-8016)", None
            if e:
                return "FAIL", f"first open {run_} on {note}: {e}", None
            fo = native_race(out).get("open")
            snapinfo.setdefault(note, {})[run_] = {"open": fo, "snap": "SNAP: restored" in out, "saved": "SNAP: saved" in out}
            if run_ == "B" and fo:
                nat.setdefault(note, {})["first open"] = dict(fo, snap="SNAP: restored" in out)
        out, e = mac_measured(f"race-{note}", ["wait:800", "window:1440x900"] + NATIVE_RACE, dict(base, OMX_CONFIG="{data}/cfg-race-" + note + "-" + stamp), [db])  # (a fresh folder, as Linux's race: no glyphs kept)
        if e:
            return "FAIL", f"race on {note}: {e}", None
        if "PNOTE WEB:" not in out:
            return "FAIL", f"the Mac's race on {note} didn't run pnote's web look", None
        first_ = nat.get(note, {}).get("first open")
        nat[note] = native_race(out)
        if first_:
            nat[note]["first open"] = first_
        cold = out.split("APPBENCH: coldopens", 1)[-1].split("APPBENCH: keptopens", 1)[0]
        snapinfo[note]["cold"] = (cold.count("SNAP: restored"), cold.count("SNAP: restored") + cold.count("SNAP: none") + cold.count("SNAP: refused"))
        lock.__exit__()
    # (continuation 21) the frames as they are shown: only with the screen unlocked and the app in front, at every step
    paced, unwarm, opens, live = {}, {}, {}, True
    for note in RACE_NOTES:
        db = race / f"race-{note}.db"
        other = subprocess.run(["sqlite3", str(db), "SELECT id FROM notes WHERE note_type = 'page' AND secure = 0 ORDER BY id LIMIT 1"], capture_output=True, text=True).stdout.strip()
        for tag, extra, steps in (("A", {}, None), ("B", {}, None), ("warm", {}, PACED_RACE), ("notwarm", {"MOJOUI_SCENEWARM": "0", "MOJOUI_GLYPHWARM": "0"}, PACED_RACE)):
            if not live:
                break
            lock = MacLock().__enter__()
            env = dict({"PNOTE_DB": "{data}/" + db.name, "PNOTE_SNAPS": "{data}/snaps-paced-" + note + "-" + stamp, "OMX_CONFIG": "{data}/cfg-paced-" + note + "-" + stamp,
                        "MOJOUI_SNAP_LOG": "1", "MOJOUI_BENCH_PACED": "1", "MOJOUI_BENCHSTATE": "1"}, **extra)
            if steps is None:
                env["PNOTE_FIRST"] = other
                run_steps = ["wait:800", "window:1440x900", "appbench:desk=coldopens", "framebench:desk=open,1"] + (["wait:4000"] if tag == "A" else [])
            else:
                run_steps = ["wait:800", "window:1440x900"] + steps
            out, e = mac_measured(f"paced-{note}-{tag}", run_steps, env, [db])
            lock.__exit__()
            if e:
                return "FAIL", f"paced {tag} on {note}: {e}", None
            live = mac_live(out)
            native_states(f"paced {note} {tag}", out)
            if steps is None:
                opens.setdefault(note, {})[tag] = dict(native_race(out).get("open") or {}, snap="SNAP: restored" in out)
            else:
                (paced if tag == "warm" else unwarm)[note] = native_race(out)
    typed = None
    if live and (race / "race-page.db").exists():
        lock = MacLock().__enter__()
        out, e = mac_measured("paced-type", TYPE_STEPS, {"PNOTE_DB": "{data}/race-page.db", "OMX_CONFIG": "{data}/cfg-type-" + stamp, "MOJOUI_BENCH_PACED": "1", "MOJOUI_BENCHSTATE": "1"}, [race / "race-page.db"])
        lock.__exit__()
        if e:
            return "FAIL", f"paced typing on a long page: {e}", None
        live = mac_live(out)
        native_states("typing", out)
        typed = native_race(out).get("typing")
    if not live:
        print("(the Mac's screen is locked or the app isn't in front: its frames shown aren't judged)", flush=True)
        paced, unwarm, opens = {}, {}, {}
    lock = MacLock().__enter__()
    starts, walls = [], []
    for i in range(6):  # (D-8002: five first starts, each with a settings folder of its own, as on Linux; then a second start, printed)
        out, e = mac_measured(f"start-{i}", ["firstscreen:", "noteswitch:5", "omnibar:5", "openall:", "rss:"],
                         {"PNOTE_DB": "{data}/pn.db", "OMX_CONFIG": "{data}/cfg-start-" + stamp + f"-{min(i, 4)}"}, [REF_MAC / "pn.db"])
        if e:
            return "FAIL", f"start-up run {i}: {e}", None
        starts.append(out)
        if live:  # (the steps to their pictures handed over, in a run of their own)
            out, e = mac_measured(f"start-paced-{i}", ["wait:800", "noteswitch:5", "omnibar:5"],
                                  {"PNOTE_DB": "{data}/pn.db", "OMX_CONFIG": "{data}/cfg-startp-" + stamp + f"-{min(i, 4)}", "MOJOUI_BENCH_PACED": "1", "MOJOUI_BENCHSTATE": "1"}, [REF_MAC / "pn.db"])
            if e:
                return "FAIL", f"start-up paced run {i}: {e}", None
            live = mac_live(out)
            walls.append(out)
    lock.__exit__()
    if live:
        starts = [a + "\n" + b for a, b in zip(starts, walls)]
    nstart = native_start(starts[:5])
    nstart["second"] = native_start(starts[5:])
    saved = dict(SNAPINFO)
    SNAPINFO.clear()
    SNAPINFO.update(snapinfo)
    rows, ok = race_table(web, nat, nstart, {}, machine="mac", paced=paced, unwarm=unwarm, opens=opens, live=live, typed=typed, states=STATES, screen=label)
    SNAPINFO.clear()
    SNAPINFO.update(saved)
    rows = rows.replace("\n\n", f"\n\nWeb renderer on the Mac: {gpu.group(1) if gpu else 'not reported'}.\n\n", 1)
    rows += "\nThe Mac while measured (load, busiest processes at each measured run's start; void ones named):\n" + "\n".join("- " + l for l in MAC_LOAD) + "\n"
    probs = unlike(STATES)
    if probs:
        return "BLOCKED", "not like-for-like, not judged: " + "; ".join(probs)[:500], rows
    if not live:
        return "BLOCKED", "the screen was locked or the app not in front at some step: not judged", None
    if not ok:
        return "FAIL", "; ".join(l for l in rows.splitlines() if "✗" in l)[:700], rows
    return "PASS", "", rows


NOTE_DUMP = """
const [out] = process.argv.slice(1);
const { generateNote, COLUMNS, ROWS } = await import('./scripts/benchmark-note.mjs');
const { generateStressNote } = await import('./src/modules/speedtest/stress-note.js');
const fs = await import('node:fs');
fs.writeFileSync(out + '/note-600.json', JSON.stringify(generateNote()));
const s = generateStressNote(5400, { columns: 4, rows: 4 });
fs.writeFileSync(out + '/note-stress.json', JSON.stringify(s.content));
""".replace("const [out] = process.argv.slice(1);", "const out = process.argv[1];")
# (D-7934) "open" is judged cold (nothing kept: the row read and parsed every time); the reopen of a canvas kept parsed at
# the revision the file still holds is measured after it and printed beside, not judged
NATIVE_RACE = ["appbench:desk=coldopens", "framebench:desk=open,20", "framebench:desk=openpress,10", "appbench:desk=keptopens", "framebench:desk=open,20", "appbench:desk=zoom30", "framebench:desk=pan,120", "framebench:desk=zoom,60", "appbench:desk=zoom100",
               "framebench:desk=pan,120", "framebench:desk=dragone,60", "framebench:desk=drag40,60", "framebench:desk=undo,25", "framebench:desk=redo,25",
               "framebench:desk=draw,300", "framebench:desk=typing,80"]
NATIVE_NAMES = {"open": "open", "zoom": "zoom from 30%", "dragone": "drag one", "drag40": "drag 40", "undo": "undo", "redo": "redo",
                "draw": "pen", "typing": "typing", "type": "typing"}


def native_race(out):
    res = {}
    zoom = "30%"
    opens = "open"
    for line in out.splitlines():
        if line.startswith("APPBENCH: zoom"):
            zoom = "30%" if "zoom30" in line else "100%"
        if line.startswith("APPBENCH: coldopens"):
            opens = "open"
        if line.startswith("APPBENCH: keptopens"):
            opens = "open (kept)"
        if not line.startswith("FRAMEBENCH:"):
            continue
        kv = dict(re.findall(r"(\w+)=([^\s]+)", line))
        # (fixed 11-19, D-7919) the host prints `FRAMEBENCH: <what> n=… p95=… gpu_frames=…`; frames not drawn by the GPU
        # renderer are CPU frames (n − gpu_frames)
        what = re.match(r"FRAMEBENCH: (\w+) ", line)
        if not what:
            continue
        name = "pan " + zoom if what.group(1) == "pan" else (opens if what.group(1) == "open" else NATIVE_NAMES.get(what.group(1), what.group(1)))
        try:
            n = int(kv["n"])
            cpu = int(kv["cpu_frames"]) if "cpu_frames" in kv else n - int(kv.get("gpu_frames", "0"))
            if n == 0:
                continue
            res[name] = {"p95": float(kv["p95"]), "max": float(kv["max"]), "cpu": cpu, "shown_n": int(kv.get("shown_n", "0")),
                         "shown_p95": float(kv.get("shown_p95", "0")), "shown_max": float(kv.get("shown_max", "0"))}
            for k in ("gap_n", "gap_p95", "gap_max", "gap_over20", "lat_p95", "lat_max", "press_lat_n", "press_lat_p95", "press_lat_max", "complete_p95"):
                if k in kv:
                    res[name][k] = float(kv[k])
            if what.group(1) == "openpress" and "press_lat_n" in kv:
                res.setdefault(opens, {}).update({k: float(kv[k]) for k in ("press_lat_n", "press_lat_p95", "press_lat_max")})
            if what.group(1) == "openpress":  # (review 2, D-7953) a press during the open: judged with the frames during it
                o = res.setdefault(opens, {})
                o.update(press_n=int(kv.get("press_n", "0")), press_p95=float(kv.get("press_p95", "0")), press_max=float(kv.get("press_max", "0")))
                res.pop(name, None)
                continue
            if "complete_max" in kv:  # (D-7944: the progressive open's frames after its first, and its completion)
                res[name].update(during_n=int(kv.get("during_n", "0")), during_p95=float(kv.get("during_p95", "0")),
                                 during_max=float(kv.get("during_max", "0")), complete_p50=float(kv.get("complete_p50", "0")),
                                 complete_max=float(kv["complete_max"]))
        except (KeyError, ValueError):
            pass
    return res


# (D-8026) the paced run (frames shown): the web benchmark's own numbers of gestures (120 wheel events, 120 zooms, 90 drag
# moves, four strokes of 60, 80 keys), so "missed" counts mean the same number of gestures on both sides
PACED_RACE = ["appbench:desk=coldopens", "framebench:desk=open,20", "framebench:desk=openpress,10", "appbench:desk=zoom30", "framebench:desk=pan,120", "framebench:desk=zoom,120",
              "appbench:desk=zoom100", "framebench:desk=pan,120", "framebench:desk=dragone,90", "framebench:desk=drag40,60", "framebench:desk=undo,25", "framebench:desk=redo,25",
              "framebench:desk=draw,240", "framebench:desk=typing,80"]


def not_free():
    """'' when the machine is free for a GPU program (scripts/gpu-free), else why not: each measured run asks (continuation 20)."""
    r = run(["scripts/gpu-free"], 60)
    return "" if r.returncode == 0 else "the machine isn't free: " + (r.stderr or r.stdout).strip()[:200]


def web_open(out):
    """webopen.mjs's lines: {'web open first'|'again'|'gaps'|'press': {p95, max, n}}."""
    res = {}
    for k in ("first", "again", "gaps", "press"):
        m = re.search(rf"^WEBOPEN {k} p95: ([\d.]+) max: ([\d.]+).* n: (\d+)", out, re.M)
        if m:
            res["web open " + k] = {"p95": float(m.group(1)), "max": float(m.group(2)), "n": int(m.group(3))}
    return res


REFRESH = 1000 / 60  # (one refresh at 60 Hz: what "a tie at the display's refresh" means; the web's rAF runs at 60)
CLOSE = 1.03         # ("very close": within 3 %, the main session's reading of the owner's ruling, GOAL.md M6's amendment)


def verdict(n, w, gaps=False):
    """(owner, 2026-11-24, as the main session reads it) native against the web, the same number on both sides: 'better',
    'within 3 %', 'tie at the display's refresh' (both show it in one refresh), or '' (worse). Never an absolute bar."""
    if n is None or w is None:
        return ""
    if n < w:
        return "better"
    if n <= w * CLOSE:
        return "within 3 %"
    one = (lambda ms: ms <= 20.0) if gaps else (lambda ms: ms <= REFRESH * 1.1)  # (over 20 ms is benchmark-f034's own "slow" frame)
    return "tie at the display's refresh" if one(n) and one(w) else ""


def verdicts(pairs, gaps=False):
    """(passes, words) of several (native, web) numbers of one row: the worst of them says."""
    order = ["", "tie at the display's refresh", "within 3 %", "better"]
    vs = [verdict(n, w, gaps) for n, w in pairs]
    worst = min(vs, key=order.index) if vs else ""
    return bool(worst), worst or "worse than the web"


HEADED = ROOT / "docs/goals/79/headed.mjs"
# (review 5, M3) the web's windows on the hidden test screen: Playwright's whole Chromium by its app id (nothing of the owner's has
# it), 1500×1000 so that a 1440×900 page area lies on the screen; and, while webcold runs, its own app windows
WEB_ENV = {"MOJOUI_TESTSCREEN_CLASSES": "^(chromium-browser|mojotest-.*)$", "MOJOUI_TESTSCREEN_RULE": 'float = true, size = "1500 1000", move = "20 -87"'}
COLD_ENV = {"MOJOUI_TESTSCREEN_CLASSES": r"^chrome-127[.]0[.]0[.]1__.*$"}
STATES = {"web": [], "native": []}  # what each measured window was drawn at: (what, scale, refresh, size, shown)


def web_headed(script, *args, timeout=900):
    """A web script of the race in a visible window on the hidden test screen (headed.mjs preloaded)."""
    r = run([str(ROOT / "scripts/testscreen"), "node", "--import", str(HEADED), str(script), *args], timeout, env=dict(os.environ, **WEB_ENV), cwd=PN)
    web_states(Path(str(script)).name, r.stdout + r.stderr)
    return r


def web_states(what, out):
    n = 0
    for m in re.finditer(r"^WEBSTATE: when=(\w+) headed=1 dpr=([\d.]+) raf=([\d.]+) inner=(\d+)x(\d+) screen=\S+ visible=(\w+)", out, re.M):
        STATES["web"].append((f"{what} {m.group(1)}", float(m.group(2)), float(m.group(3)), (int(m.group(4)), int(m.group(5))), m.group(6) == "visible"))
        n += 1
    if n == 0:
        STATES["web"].append((f"{what}: no WEBSTATE (not in a visible window)", 0.0, 0.0, (0, 0), False))


def native_states(what, out):
    n = 0
    for m in re.finditer(r"^BENCHSTATE: (\S+) .*?scale=([\d.]+) refresh=([\d.]+) size=(\d+)x(\d+)", out, re.M):
        STATES["native"].append((f"{what} {m.group(1)}", float(m.group(2)), float(m.group(3)), (int(m.group(4)), int(m.group(5))), True))
        n += 1
    if n == 0:
        STATES["native"].append((f"{what}: no BENCHSTATE", 0.0, 0.0, (0, 0), False))


def unlike(states):
    """Why the two sides' windows aren't alike (empty: they are): each web page headed and visible, every window at one scale and
    one refresh (within 3 %), native's canvas 1440×900 and the web's window big enough for a 1440×900 page."""
    probs = []
    web, nat = states["web"], states["native"]
    if not web or not nat:
        return ["what the web's windows were drawn at isn't known" if not web else "what native's window was drawn at isn't known"]
    for what, scale, refresh, size, shown in web:
        if not shown or scale <= 0:
            probs.append(f"the web's {what} isn't a visible window")
        elif size[0] < 1440 or size[1] < 900:
            probs.append(f"the web's {what} window is {size[0]}x{size[1]}: no 1440x900 page fits")
    for what, scale, refresh, size, shown in nat:
        if not shown or scale <= 0:
            probs.append(f"native's {what}")
        elif size != (1440, 900):
            probs.append(f"native's {what} is {size[0]}x{size[1]}, not 1440x900")
    good = [(w, s, r) for side in (web, nat) for w, s, r, _, ok in side if ok and s > 0]
    if good:
        w0, s0, r0 = good[-1]
        for w, s, r in good:
            if abs(s - s0) > 0.01:
                probs.append(f"{w} is drawn at {s:g}×, {w0} at {s0:g}×")
            if r0 <= 0 or abs(r - r0) / max(r0, 1) > 0.03:
                probs.append(f"{w} refreshes at {r:.1f} Hz, {w0} at {r0:.1f}")
    return probs


# (review 5) The reviewer's fair rule, PREPARED AND OFF: one late frame of one run decides a row today, and the owner has been asked
# whether five runs should. On (True), M6 runs five interleaved rounds of Personal Note's benchmark and of native's paced race, and
# a step's row is judged by the median of the five runs' p95 (Personal Note's own benchmark gives each run's p95, not its frames,
# so they can't be pooled), the median of the five maxima, and the missed frames of all five together, both sides alike. Off,
# nothing of it runs, and nothing it would say is reported.
FAIR_RULE = False
FAIR_ROUNDS = 5


def middle(v):
    v = sorted(v)
    return v[len(v) // 2] if len(v) % 2 else (v[len(v) // 2 - 1] + v[len(v) // 2]) / 2


def fair_row(web_runs, native_runs):
    """((web p95, max), (native p95, max), (web missed, native missed)) over the rounds; None when a round has no number. Each run:
    (p95, max, missed)."""
    if len(web_runs) != FAIR_ROUNDS or len(native_runs) != FAIR_ROUNDS or any(r is None for r in web_runs + native_runs):
        return None
    side = lambda runs: (middle([r[0] for r in runs]), middle([r[1] for r in runs]))
    return side(web_runs), side(native_runs), (sum(r[2] for r in web_runs), sum(r[2] for r in native_runs))


def fair_rounds(race):
    """Five rounds, the web's benchmark then native's paced race (warm, not warmed) on both notes, interleaved: {(note, step):
    {"web": [...], "warm": [...], "notwarm": [...]}} of (p95, max, missed)."""
    out = {}
    for k in range(FAIR_ROUNDS):
        web_headed("scripts/benchmark-f034.mjs", "--gpu", f"--dpr={LINUX_DPR}", "--note=both", f"--out={race / f'fair-web-{k}.json'}", timeout=3600)
        try:
            w = web_race(json.loads((race / f"fair-web-{k}.json").read_text()), "")
        except (OSError, ValueError):
            w = {}
        for note in RACE_NOTES:
            for warm in (True, False):
                cfg = race / f"cfg-fair-{note}"
                shutil.rmtree(cfg, ignore_errors=True)
                cfg.mkdir()
                shutil.copy(race / f"race-{note}.db", cfg / "pn.db")
                env = dict(os.environ, PNOTE_DIR=str(cfg), OMX_CONFIG=str(cfg), PNOTE_DB=str(cfg / "pn.db"), MOJOUI_BENCH_PACED="1", MOJOUI_TEST=";".join(["wait:800", "window:1440x900"] + PACED_RACE), MOJOUI_SHOT="")
                if not warm:
                    env.update(MOJOUI_SCENEWARM="0", MOJOUI_GLYPHWARM="0")
                r = run(["scripts/testscreen", str(APP)], 1800, env=env)
                (race / f"fair-native-{note}-{k}{'' if warm else '-notwarm'}.log").write_text(r.stdout + r.stderr)
                native_states(f"fair {note}", r.stdout + r.stderr)
                n = native_race(r.stdout + r.stderr)
                for step in RACE_STEPS[1:]:
                    d = out.setdefault((note, step), {"web": [], "warm": [], "notwarm": []})
                    if warm:
                        x = w.get(note, {}).get(step)
                        d["web"].append((x["p95"], x["max"], x.get("missed") or 0) if x else None)
                    v = n.get(step)
                    a, b = ("lat_p95", "lat_max") if step in ("undo", "redo") else ("gap_p95", "gap_max")
                    d["warm" if warm else "notwarm"].append((v[a], v[b], v.get("gap_over20", 0)) if v and a in v else None)
    return out


def web_type(out):
    """webtype.mjs's line: {p95, max, n} (ms)."""
    m = re.search(r"^WEBTYPE p95: ([\d.]+) max: ([\d.]+) n: 80\s*$", out, re.M)
    return {"p95": float(m.group(1)), "max": float(m.group(2))} if m else None


TYPE_STEPS = ["wait:800", "window:1440x900", "wait:1500", "framebench:desk=typing,80"]
M6_RUNNING = [False]


def web_switch(out):
    """webswitch.mjs's lines (D-8001): {switch, switch_max, omnibar, omnibar_max} (ms)."""
    res = {}
    for k, name in [("switch", "note switch"), ("omnibar", "omnibar")]:
        m = re.search(rf"^WEBSWITCH {name} p95: ([\d.]+) max: ([\d.]+)", out, re.M)
        if m:
            res[k], res[k + "_max"] = float(m.group(1)), float(m.group(2))
    return res


def web_race(f034, first_screen_text):
    """{note: {step: {p95, max}}} from PN's benchmark-f034 --out JSON, plus first screen ms."""
    res = {}
    for r in f034.get("results", []):
        note = "stress" if "stress" in json.dumps(r.get("note", r.get("name", r.get("setup", ""))))[:200] else "600"
        for sc in r.get("scenarios", r.get("rows", [])):
            name = str(sc.get("scenario", "")).lower()
            # (fixed 11-19, D-7915) the web's own row names: "drag 30 selected objects" is its drag-40 step (it drags
            # the 40 it can see), "undo/redo" is the worse of its undo and redo rows timed "to the frame after", and
            # the open row has only a p50 (one cold open): that number stands for its p95 and max
            step = None
            if name.startswith("open"):
                step = "open"
            elif name.startswith("drag one"):
                step = "drag one"
            elif re.match(r"drag \d+ selected", name):
                step = "drag 40"
            elif name.startswith("undo") and "frame after" in name:
                step = "undo"
            elif name.startswith("redo") and "frame after" in name:
                step = "redo"
            elif name.startswith("pen strokes") and "frame gaps" in name:
                step = "pen"
            elif name.startswith("typing") and "frame gaps" in name:
                step = "typing"
            elif name.startswith("pan") and "30%" in name:
                step = "pan 30%"
            elif name.startswith("pan") and "100%" in name:
                step = "pan 100%"
            elif name.startswith("zoom") and "30%" in name:
                step = "zoom from 30%"
            if name.startswith("pen strokes") and "input to frame" in name:
                res.setdefault(note, {})["pen input"] = {"p95": float(sc["p95"]), "max": float(sc["max"])}
            if name.startswith("typing") and "key to paint" in name:
                res.setdefault(note, {})["typing input"] = {"p95": float(sc["p95"]), "max": float(sc["max"])}
            if step is None:
                continue
            p95 = sc.get("p95") if sc.get("p95") is not None else sc.get("p50", 0)
            mx = sc.get("max") if sc.get("max") is not None else sc.get("p50", 0)
            # (11-20, D-7929) one web row per step: no more "the worse of two rows" against one native run
            res.setdefault(note, {})[step] = {"p95": float(p95), "max": float(mx), "missed": sc.get("slow"), "n": sc.get("n")}
    m = re.search(r"first screen (\d+)", first_screen_text)
    res["first_screen_ms"] = float(m.group(1)) if m else None
    m = re.search(r"rss[^\d]*(\d+)", first_screen_text, re.I)
    res["rss_mb"] = float(m.group(1)) if m else None
    return res


def native_start(outs):
    vals = {"first": [], "switch": [], "omnibar": [], "rss": [], "switch_max": [], "omnibar_max": [], "wswitch": [], "womnibar": [], "wswitch_max": [], "womnibar_max": []}
    for o in outs:
        for k, pat in [("first", r"^FIRSTSCREEN: ([\d.]+)"), ("switch", r"^NOTESWITCH: .* p95=([\d.]+)"), ("omnibar", r"^OMNIBAR: .* p95=([\d.]+)"),
                       ("wswitch", r"^NOTESWITCH: .*wall_p95=([\d.]+)"), ("womnibar", r"^OMNIBAR: .*wall_p95=([\d.]+)"),
                       ("wswitch_max", r"^NOTESWITCH: .*wall_max=([\d.]+)"), ("womnibar_max", r"^OMNIBAR: .*wall_max=([\d.]+)"),
                       ("switch_max", r"^NOTESWITCH: .* max=([\d.]+)"), ("omnibar_max", r"^OMNIBAR: .* max=([\d.]+)"),
                       ("rss", r"^RSS: ([\d.]+)")]:
            m = re.search(pat, o, re.M)
            if m:
                vals[k].append(float(m.group(1)))
    med = lambda v: sorted(v)[len(v) // 2] if v else None
    return {k: (max(v) if v else None) if k.endswith("_max") else med(v) for k, v in vals.items()}


def mac_live(out):
    """True when macOS had the app active, its window key and the screen unlocked at every measured step (BENCHSTATE lines, at
    least one): only then is a paced number like-for-like with the web's (continuation 21)."""
    st = re.findall(r"^BENCHSTATE: .*active=(-?\d+) key=(-?\d+) locked=(-?\d+)", out, re.M)
    return bool(st) and all(a == "1" and k == "1" and l == "0" for a, k, l in st)


def race_table(web, nat, start, shown=None, machine="linux", paced=None, unwarm=None, opens=None, live=False, typed=None, states=None, screen="", fair=None):
    """(D-8025, D-8026: the owner's ruling of 2026-11-24) (race.md's text, every judged row passes). Judged: native against
    the web over the same span, nothing absolute; the 8.3 / 16.7 ms marks are still computed and printed on every row."""
    shown, paced, unwarm, opens = shown or {}, paced or {}, unwarm or {}, opens or {}
    ok = [True]
    mac = machine == "mac"
    lines = ["# Goal 79 race: native pnote vs the web Personal Note (generated by docs/goals/79-check.py M6)" + (f": {screen}" if screen else ""), ""]
    bad = unlike(states) if states is not None else []
    if bad:
        ok[0] = False
        lines += ["> **NOT LIKE-FOR-LIKE, NOT JUDGED.** " + "; ".join(bad)[:1500] + ". No verdict below counts.", ""]
    elif states is not None:
        w, n = states["web"][-1], states["native"][-1]
        lines += [f"**The two windows** (review 5, M3: both visible, checked at every script's start and end): the web's at {w[1]:g}× and {w[2]:.1f} Hz (its own "
                  f"devicePixelRatio and requestAnimationFrame, nothing emulated), native's at {n[1]:g}× and {n[2]:.1f} Hz, its canvas {n[3][0]}×{n[3][1]}; {len(states['web'])} and "
                  f"{len(states['native'])} readings, all alike.", ""]
    if mac:  # (D-7988)
        lines += [f"**The Mac (M4), 1440×900 at {(states or {}).get('native', [('', 0)])[-1][1] if states and states['native'] else 0:g}×.** Web: benchmark-f034.mjs unchanged, under docs/goals/79/headed.mjs (a visible window of the Mac's own "
                  "Chrome, ANGLE on Metal: PN's Vulkan flags fall back to software on macOS, D-7986); memory, note switch, opens and the fresh-Chrome "
                  "cold start by webmem, webswitch, webopen and webcold.mjs on macOS, in ~/omxcode-g79-web (ruling B). Native: pnote's web look on "
                  "the AppKit host, Metal; frame work = event + draw (CPU) + AppKit's display and commit + the GPU's time. "
                  + ("**Frames shown: measured (MOJOUI_BENCH_PACED on AppKit: the app's own tick, by the screen's clock since D-8060, the screen unlocked, the app active and its "
                     "window key at every step), judged as Linux's.** " if live else
                     "**The Mac's frames shown aren't measured (its screen was locked or the app not in front): its frame rows say \"work only, "
                     "not like-for-like\" and are not judged.** ") + "PN's own Mac launcher is a WKWebView window with no DevTools port: its row is a lower "
                  "bound of its first paint, process start to its own server sending the page (D-7992).", ""]
    lines += [
        f"Same machine, same notes (PN's own generators, stored through the web app's API: seedrace.mjs), 1440×900 at {LINUX_DPR if not mac else (states['native'][-1][1] if states and states['native'] else 0):g}×. "
        "Web: benchmark-f034.mjs --gpu, webopen.mjs, webswitch.mjs, webtype.mjs in a visible Chromium window with the GPU (headed.mjs). Native: pnote's web look (PNOTE_DB)"
        + (" on the hidden test screen" if not mac else "") + ", the same steps through test mode.", "",
        "**How it is judged** (the owner, 2026-11-24: \"yandong have a bar,  it sjust need better than web (sind its antive) if tis very close its "
        "ok\"; the main session's reading, not the owner's words: no absolute ms bar decides; a row passes when native is better than the web on "
        "the same machine, and *very close* is within 3 %). A frame that both show in one refresh at 60 Hz is \"a tie at the display's refresh\" "
        "and passes. Still required: no canvas frame drawn on the CPU; tests/test_canvasload (a pan and an edit during an open): "
        + ("passes." if OPEN_TEST_OK[0] else "**FAILS.**") + " The silky marks (p95 ≤ 8.3 ms, max ≤ 16.7 ms of work) are printed on every row, as information.", "",
        "**What is compared:**",
        "- *Frames* (pan, zoom, drags, pen, typing, the frames of an open): the gap from one frame to the next. Web: requestAnimationFrame gaps "
        "(every refresh, whether or not the picture changed). Native: from one frame's paint to the next one's, every frame showing a new "
        "picture, the next gesture given once the last is painted, nothing measured inside the frames (MOJOUI_BENCH_PACED). p95, max and missed "
        "frames (gaps over 20 ms, benchmark-f034's own \"slow\"), over the same number of gestures. Neither side has the compositor's presentation "
        "time: the hidden screen reports none (\"shown: not measured\" in every earlier race), and a page can't read it.",
        "- *Latency* (opens, a press during one, undo, redo, note switch, omnibar): from the event to the frame that shows it painted by the app's "
        "thread and handed on. Web: a requestAnimationFrame, then a task after it; from the input event's own timestamp, undo and redo from the call "
        "(as benchmark-f034 times them). Native: to GTK's after-paint; undo and redo from the key event, the note switch and omnibar from the app's "
        "own step (no pointer event in front: the one difference left, in native's favour by its hit test).",
        "- *Opens*: the same note opened inside the running app from another note, first time in the process (native: nothing kept, the note "
        "parsed; and a new process opening it from the view the last one kept) and again. Web: webopen.mjs, the click to the frame after its canvas "
        "settled; native: the open request to the frame that completes the board. benchmark-f034's own open row (a page load in a new browser "
        "context) is printed, not compared: it loads the app too.",
        "- *Not warmed*: pnote readies glyphs and the next zoom's and undo's pictures while nothing happens (D-8002, D-8019). The paced race is run once "
        "more with that off (MOJOUI_SCENEWARM=0, MOJOUI_GLYPHWARM=0) and judged against the web as well; the start-up rows are the first start's, "
        "nothing readied.",
        "- *native work* (beside): each frame's own work: event, update, redraw, GPU time, GTK's paint and a display round trip, in a run of its own.", "",
        "| note | row | web p95 / max (missed) | native p95 / max (missed) | verdict | native work p95 / max | silky marks (information) |",
        "|---|---|---|---|---|---|---|"]

    def mark(p95, mx):
        return "≤ 8.3 and ≤ 16.7" if p95 <= P95 and mx <= MAX else "over: " + ", ".join([x for x in ("p95 > 8.3" if p95 > P95 else "", "max > 16.7" if mx > MAX else "") if x])

    def add(note, label, w, n, work=None, gaps=False, extra="", need=True, missed=None):
        """One judged row: w and n are (p95, max) or None; missed: (web's, native's) or None."""
        if mac and n is None:
            ok[0] = False
            said = "work only, not like-for-like"
        elif w is None or n is None:
            ok[0] = False
            said = "✗ not measured: " + ("the web" if w is None else "native")
        else:
            good, said = verdicts(list(zip(n, w)), gaps)
            if good and missed and missed[1] > missed[0]:
                good, said = False, f"more missed frames ({missed[1]:.0f} against {missed[0]:.0f})"
            if good and not need:
                good, said = False, extra or "CPU frames"
            ok[0] = ok[0] and good
            said = ("✓ " if good else "✗ ") + said
        f = lambda v, m: (f"{v[0]} / {v[1]}" + (f" ({m:.0f})" if m is not None else "")) if v else "—"
        lines.append(f"| {note} | {label} | {f(w, missed[0] if missed else None)} | {f(n, missed[1] if missed else None)} | {said} | "
                     f"{f'{work[0]} / {work[1]}' if work else '—'} | {mark(*work) if work else ''} |")

    pair = lambda d, a="p95", b="max": (d[a], d[b]) if d and a in d and b in d else None
    for note in RACE_NOTES:
        wn = web.get(note, {})
        pn = paced.get(note, {})
        un = unwarm.get(note, {})
        wo = wn.get("web open first")
        for run_, label in (("A", "the first open ever (nothing kept: parsed)"), ("B", "a new process's first open, from the view the last one kept")):
            o = opens.get(note, {}).get(run_, {})
            if run_ == "B" and o and not o.get("snap"):
                label += " (NO kept view was used)"
            wk = SNAPINFO.get(note, {}).get(run_, {}).get("open")
            work = pair(wk) if wk else None
            add(note, label + ": its first frame", pair(wo), pair(o, "lat_p95", "lat_max"), work)
            add(note, label + ": complete", pair(wo), (o["complete_max"], o["complete_max"]) if "complete_max" in o else None)
        o = pn.get("open", {})
        wk = nat.get(note, {}).get("open")
        si = SNAPINFO.get(note, {})
        add(note, "open again (cold: the row read each time): its first frame", pair(wn.get("web open again")), pair(o, "lat_p95", "lat_max"), pair(wk) if wk else None,
            need=OPEN_TEST_OK[0], extra="tests/test_canvasload fails")
        add(note, "open again: complete", pair(wn.get("web open again")), pair(o, "complete_p95", "complete_max"))
        add(note, "open again: the frames while it comes in (gaps)", pair(wn.get("web open gaps")), pair(o, "gap_p95", "gap_max") if o.get("gap_n") else None,
            pair(wk, "during_p95", "during_max") if wk else None, gaps=True)
        add(note, "a press during an open", pair(wn.get("web open press")), pair(o, "press_lat_p95", "press_lat_max") if o.get("press_lat_n") else None,
            pair(wk, "press_p95", "press_max") if wk and wk.get("press_n") else None)
        for step in RACE_STEPS[1:]:
            w = wn.get(step)
            wk = nat.get(note, {}).get(step)
            work = pair(wk) if wk else None
            cpu = (wk or {}).get("cpu", 0) == 0
            for d, label in ((pn, step), (un, step + ", not warmed")):
                n = d.get(step)
                if FAIR_RULE and fair is not None:
                    v = fair.get((note, step), {})
                    got = fair_row(v.get("web", []), v.get("warm" if d is pn else "notwarm", []))
                    add(note, label + f" (median of {FAIR_ROUNDS} runs)", got[0] if got else None, got[1] if got else None, work if d is pn else None,
                        gaps=step not in ("undo", "redo"), need=cpu, missed=got[2] if got and step not in ("undo", "redo") else None)
                    continue
                if step in ("undo", "redo"):
                    add(note, label + " (latency)", pair(w), pair(n, "lat_p95", "lat_max"), work if d is pn else None, need=cpu)
                else:
                    missed = (w["missed"], n["gap_over20"]) if w and n and w.get("missed") is not None and "gap_over20" in n else None
                    add(note, label + " (frames)", pair(w), pair(n, "gap_p95", "gap_max"), work if d is pn else None, gaps=True, need=cpu, missed=missed)

    add("page", "typing in the middle of a 20,000-character paragraph (key to its frame)", pair(web.get("type page")), pair(typed, "lat_p95", "lat_max"),
        need=(typed or {}).get("cpu", 0) == 0)

    lines += ["", "**Beside, not judged:**", "", "| note | what | web | native |", "|---|---|---|---|"]
    for note in RACE_NOTES:
        wn, pn, si = web.get(note, {}), paced.get(note, {}), SNAPINFO.get(note, {})
        if "open" in wn:
            lines.append(f"| {note} | benchmark-f034's open (a page load in a new context) | {wn['open']['p95']} | |")
        for k, label in (("pen", "pen: input to frame p95 / max"), ("typing", "typing: key to paint (web: 8 ms steps, at least 16) p95 / max")):
            w, n = wn.get(k + " input"), pn.get(k, {})
            lines.append(f"| {note} | {label} | {f'{w['p95']} / {w['max']}' if w else '—'} | {f'{n['lat_p95']} / {n['lat_max']}' if 'lat_p95' in n else '—'} |")
        cold_ = si.get("cold")
        if cold_:
            lines.append(f"| {note} | cold opens that showed the kept view | | {cold_[0]} of {cold_[1]} |")
        for k, label in (("A", "work: the first open ever, first frame · frames during p95 / max · complete"), ("B", "work: a new process's first open from the kept view"),):
            o = si.get(k, {}).get("open")
            if o:
                lines.append(f"| {note} | {label} | | {o['max']} · {o.get('during_p95', '—')} / {o.get('during_max', '—')} · {o.get('complete_max', '—')} |")
        off = si.get("off")
        if off and "complete_max" in off:
            lines.append(f"| {note} | work: cold open with the kept view off (MOJOUI_SNAP=0): first frame · during · press · complete | | "
                         f"{off['max']} · {off['during_p95']} / {off['during_max']} · {off.get('press_p95', '—')} / {off.get('press_max', '—')} · {off['complete_max']} |")
        kept = nat.get(note, {}).get("open (kept)")
        if kept:
            lines.append(f"| {note} | work: open again, kept parsed | | {kept['p95']} / {kept['max']} |")
        for step in RACE_STEPS:
            v = shown.get(note, {}).get(step)
            if v:
                lines.append(f"| {note} | work, GTK compositing the canvas (MOJOUI_OFFLOAD=0): {step} p95 / max · paint to presented | | {v['p95']} / {v['max']} · "
                             + (f"{v['shown_p95']} / {v['shown_max']} ({v['shown_n']:.0f})" if v.get("shown_n", 0) > 0 else "not measured") + " |")

    lines += ["", "| | web | native | verdict |", "|---|---|---|---|"]
    n = start.get("first")
    desk_label = "cold start: Personal Note's desktop launcher (server + Chromium app window)"
    if mac:  # (D-7992, ruling D)
        wm = web.get("cold_desktop_window_ms")
        desk_label = ("cold start: Personal Note's Mac launcher (pywebview), a LOWER BOUND of its first paint: its process's start to its "
                      "own server sending the page (D-7992)" + (f"; its window on screen at {wm} ms" if wm else ""))

    def line(label, w, n, unit, judged=True):
        good, said = verdicts([(n, w)] if not isinstance(n, tuple) else list(zip(n, w or (None, None)))) if n is not None and w is not None else (False, "not measured")
        if mac and unit == "ms" and not live:
            judged, said = False, said + " (work only: the screen is locked; not judged)"
            ok[0] = False
        if judged:
            ok[0] = ok[0] and good
            said = ("✓ " if good else "✗ ") + said
        f = lambda v: "not measured" if v is None else (f"{v[0]} / {v[1]} {unit}" if isinstance(v, tuple) else f"{v} {unit}")
        lines.append(f"| {label} | {f(w)} | {f(n)} | {said} |")

    line(desk_label, web.get("cold_desktop_ms"), n, "ms")
    line("cold start: a fresh Chromium process on the built app", web.get("cold_chromium_ms"), n, "ms")
    lines.append(f"| warm page load in a running Chromium (PN's benchmark-first-screen; not judged: no process starts) | {web.get('first_screen_ms') or '—'} ms | {n if n else '—'} ms | |")
    line("RSS after opening all three kinds", web.get("rss_mb"), start.get("rss"), "MB")
    two = lambda d, k: (d.get(k), d.get(k + "_max")) if d.get(k) is not None and d.get(k + "_max") is not None else None
    sec = start.get("second") or {}
    for k in ["switch", "omnibar"]:  # (D-8001; D-8026: from the step to the frame painted, as the web's to the frame after)
        what = "note switch" if k == "switch" else "omnibar open"
        line(f"{what} p95 / max, the first start: nothing readied (5 runs of 5; p95 the median run's, max the worst)", two(web, k), two(start, "w" + k), "ms")
        line(f"{what} p95 / max, the second start (the first one's glyphs readied, D-8002)", two(web, k), two(sec, "w" + k), "ms")
        lines.append(f"| {what}: native work p95 / max (first start · second), beside | | {start.get(k)} / {start.get(k + '_max')} · {sec.get(k)} / {sec.get(k + '_max')} ms | "
                     f"{mark(start[k], start[k + '_max']) if start.get(k) is not None and start.get(k + '_max') is not None else ''} |")
    lines += ["", "Cold start (D-7950): every number runs from its process's start to its first screen. Web: docs/goals/79/webcold.mjs, the "
              "title island (#island-title) holding the note's title, painted (two animation frames after), read through Chromium's DevTools "
              "port; the desktop launcher's start is its Python process's (by /proc, as the native one), the fresh Chromium's the moment "
              "before it is spawned, its API already serving; medians of 5, scratch databases and profiles, on the hidden screen. Native: "
              "FIRSTSCREEN, the first canvas picture (title island included) handed to GTK, by /proc. Each side's 'quiet' rule: no run starts "
              "while scripts/gpu-free says another job has the machine, or while 3 or more cores' worth of work runs (Linux, /proc/stat over 2 s: the web's "
              "runs and the native ones alike, waiting up to 5 minutes), or while the Mac's load is 3 or more; a race with a run that started on a "
              "busy machine is void (BLOCKED), not judged."]
    if LINUX_LOAD and not mac:
        lines += ["", f"The machine before each of the {len(LINUX_LOAD)} measured runs: at most {max(c for _, c, _ in LINUX_LOAD)} cores busy."]
    return "\n".join(lines) + "\n", ok[0]


# ---------------------------------------------------------------- the Mac

def mac_reachable():
    r = run(["ssh", "-i", MAC_KEY, "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", MAC_SSH, "true"], 60)
    return "" if r.returncode == 0 else f"the Mac ({MAC_SSH}) isn't reachable"


class MacLock:
    """The Mac held for one batch (scripts/mac-ssh's ~/.cache/omx-mac.lock, shared with goal 80's checker): its runs and
    ssh commands inside don't take it again."""

    def __enter__(self):
        import fcntl
        self.f = open(os.path.expanduser("~/.cache/omx-mac.lock"), "a")
        end = time.time() + 5400
        while True:
            try:
                fcntl.flock(self.f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.time() > end:
                    raise TimeoutError("~/.cache/omx-mac.lock held for 90 minutes")
                time.sleep(5)
        os.environ["OMX_MAC_LOCKED"] = "1"
        return self

    def __exit__(self, *exc):
        os.environ.pop("OMX_MAC_LOCKED", None)
        self.f.close()


def mac_quiet(what, limit=3.0, wait=600):
    """Waits (up to `wait` s) for the Mac's load to fall under `limit`; its uptime and busiest processes, printed and kept."""
    end = time.time() + wait
    while True:
        r = mac_sh("sysctl -n vm.loadavg | awk '{print $2}'; uptime; ps -Ao pcpu,comm -r | awk 'NR>1 && NR<5{printf \"%s %s; \",$1,$2}'", 60)
        load = float((r.stdout.split() or ["99"])[0])
        if load < limit or time.time() > end:
            line = f"{what}: load {load} {' '.join(r.stdout.split(chr(10))[1:]).strip()[:160]}{'' if load < limit else ' (NOT QUIET)'}"
            MAC_LOAD.append(line)
            print("  MAC " + line, flush=True)
            return load < limit
        time.sleep(15)


def mac_web(tag, cmd, timeout, tries=3):
    """(review 3, B4) A web run on the Mac under the native runs' rule: started only on a quiet machine, else void and
    tried again (3×). (the CompletedProcess, '') or (None, why)."""
    for _ in range(tries):
        if mac_quiet(tag):
            return mac_sh(cmd, timeout), ""
        MAC_LOAD.append(f"{tag}: VOID (not quiet), run again")
    return None, f"{tag}: the Mac was never quiet"


def mac_measured(tag, steps, env, data, tries=3):
    """A run on the Mac whose timing counts: the bundle built beforehand, the machine quiet when it starts. A run that
    started on a loaded machine is void and run again (3×)."""
    for _ in range(tries):
        mac_quiet(tag)
        n = len(MAC_LOAD)
        out, e = mac_run(tag, steps, env, data, nobuild=True)
        loads = [float(m.group(1)) for l in MAC_LOAD[n:] for m in [re.search(r"load averages?: ([\d.]+)", l)] if m]
        if e or not loads or loads[-1] < 3.0:
            return out, e
        MAC_LOAD.append(f"{tag}: VOID (load {loads[-1]} at the start), run again")
        print(f"  MAC {tag}: void, load {loads[-1]}", flush=True)
    return "", f"{tag}: the Mac was never quiet ({loads[-1]})"


MAC_SCREEN = [""]  # the screen native's window opens on there (MOJOUI_SCREEN; "": the main one)
MAC_LOAD = []  # (MACLOAD: lines of the Mac runs so far, for race-mac.md)


def mac_run(tag, steps, env, data, nobuild=False):
    """pnote on the M4 through scripts/mac-ssh; (stdout, '') or ('', why). nobuild: the bundle the last run built (D-7994)."""
    print(f"(opening a pnote window on the Mac: {tag}, about a minute)", flush=True)
    sf = OUT / f"mac-{tag}.steps"
    sf.parent.mkdir(parents=True, exist_ok=True)
    sf.write_text("\n".join(steps + ["quit"]) + "\n")
    if MAC_SCREEN[0]:
        env = dict(env, MOJOUI_SCREEN=MAC_SCREEN[0])
    e = dict(os.environ, MAC_SSH=MAC_SSH, MAC_ENV=",".join(f"{k}={v}" for k, v in env.items()), MAC_NOBUILD="1" if nobuild else "0")
    for attempt in range(3):  # (D-7995: the Mac drops off the network for minutes at a time; a run that brought no report back is run again once it answers)
        r = run(["scripts/mac-ssh", "pnote", str(sf)] + [str(d) for d in data], 3600, env=e)
        lines = (r.stdout + r.stderr).strip().splitlines()
        report = Path(lines[-1]) if lines else None
        if not r.returncode and report and (ROOT / report / "stdout.txt").exists():
            break
        if attempt == 2:
            return "", f"mac-ssh exit {r.returncode}: {tail(r.stdout + r.stderr, 400)}"
        for _ in range(40):
            if not mac_reachable():
                break
            time.sleep(15)
    out = (ROOT / report / "stdout.txt").read_text()
    (OUT / f"mac-{tag}.log").write_text(out)
    for line in (r.stdout + r.stderr).splitlines():
        if line.startswith("MACLOAD:"):
            MAC_LOAD.append(f"{tag}: {line[9:]}")
            print(f"  {line[:200]}", flush=True)
    return out, ""


# ---------------------------------------------------------------- M7: both machines, nothing regressed

def m7():
    probs, said = [], []
    m = mac_reachable()
    if m:
        probs.append(f"Mac: {m}")
    else:
        err = make_ref(REF_MAC, MAC_DPR)
        if err:
            probs.append("ref at 2×: " + err)
        else:
            # the web's Mac window layout: PN's own verify-mac-chrome.mjs must pass (traffic lights, drag strips)
            r = run(["node", "scripts/verify-mac-chrome.mjs", str(OUT / "mac-chrome")], 1200, cwd=PN)
            if r.returncode or "FAIL" in r.stdout:
                probs.append("verify-mac-chrome: " + tail(r.stdout, 300))
            for s in M2_SCREENS + M3_SCREENS:
                data = OUT / "mac" / s
                data.mkdir(parents=True, exist_ok=True)
                # (fixed 11-22: the Mac half had never run: no `boxes:` step exists (pnote writes its boxes after every frame to
                # PNOTE_BOXES, as on Linux) and files written to {data} never came back: {out} is fetched into the report)
                out, e = mac_run(f"look-{s}", ["wait:800", "window:1440x900", "wait:600"] + screen_steps(s, REF_MAC) + ["wait:600", "render:desk={out}/" + f"{s}.png"],
                                 {"PNOTE_DB": "{data}/pn.db", "PNOTE_SKIN": "night" if s.endswith("night") else "crayon" if s.endswith("crayon") else "paper",
                                  "PNOTE_CHROME": "mac", "PNOTE_BOXES": "{out}/" + f"{s}.boxes.json", "MOJOUI_RENDER_SCALE": str(MAC_DPR)}, [REF_MAC / "pn.db"])
                if e:
                    probs.append(f"Mac {s}: {e}")
                    continue
                rep = next(iter(sorted((ROOT / "build/mac-ssh").glob("pnote-*"))[-1:]), None)
                png = next(iter(rep.rglob(f"{s}.png")), None) if rep else None
                bx = next(iter(rep.rglob(f"{s}.boxes.json")), None) if rep else None
                if not png or not bx:
                    probs.append(f"Mac {s}: the app's own shot or boxes didn't come back")
                    continue
                p, sc = compare_screen(f"Mac {s}", REF_MAC / f"{s}.png", json.loads((REF_MAC / f"{s}.boxes.json").read_text()), png,
                                       json.loads(bx.read_text()), MAC_DPR, OUT / f"mac-{s}-compare.png")
                probs += p
                said.append(f"{s} {sc:.3f}")
    r = run(["pixi", "run", "python", "docs/goals/74-check.py", "M1", "M2", "M3", "M4", "M5", "M6"], 7200)
    if r.stdout.count(": PASS") < 6:
        probs.append("goal 74: " + " | ".join(l[:140] for l in r.stdout.splitlines() if "FAIL" in l or "BLOCKED" in l))
    r = run(["pixi", "run", "python", "docs/goals/75-check.py", "M2", "M3", "M4", "M5", "M6"], 7200)
    if r.stdout.count(": PASS") < 5:
        probs.append("goal 75: " + " | ".join(l[:140] for l in r.stdout.splitlines() if "FAIL" in l or "BLOCKED" in l))
    run(["pixi", "run", "python", "scripts/components.py"], 1800)
    comp = (ROOT / "docs/components.md").read_text()
    row = next((l for l in comp.splitlines() if "`mojoui/fonttext.mojo`" in l and l.startswith("|")), "")
    cells = [c.strip() for c in row.split("|")]
    # columns: name | file | uses | Linux | web | iPhone | Mac | Android | wasm | apps (as gpu2d's row)
    if not row or len(cells) < 8 or cells[4] != "✅" or cells[7] != "✅":
        probs.append(f"components.md: fonttext isn't ✅ on Linux and Mac ({row[:160]!r})")
    r = run(["pixi", "run", "python", "scripts/decisions_lint.py"], 600)
    if r.returncode:
        probs.append("decisions lint: " + tail(r.stdout + r.stderr, 200))
    if probs:
        return ("BLOCKED" if probs == [f"Mac: {m}"] else "FAIL"), "; ".join(probs)[:1500]
    return "PASS", f"Mac at 2× ({', '.join(said)}), verify-mac-chrome, goal 74 M1–M6, goal 75 M2–M6, fonttext ✅ Linux and Mac, decisions lint"


def builds():
    """(review 4's aftermath) Everything here compiles: the framework's every function and every example (scripts/build-all)."""
    r = run(["scripts/build-all"], 5400)
    bad = [l for l in r.stdout.splitlines() if l.startswith("FAIL")]
    n = sum(l.startswith("OK") for l in r.stdout.splitlines())
    if bad or r.returncode or n < 40:
        return "FAIL", ("; ".join(bad) or tail(r.stdout + r.stderr))[:900]
    return "PASS", f"{n} builds: mojoui whole, every example on Linux"


def package():
    """(review 6, P1 and P2) The Linux download as a person gets it, and its installer against notes that must stay."""
    err = build_linux()
    if err:
        return "FAIL", err
    r = run(["scripts/install_test.sh"], 300)
    q = run(["pixi", "run", "python", "-B", "scripts/package_test.py"], 900)
    if r.returncode or "install_test: ok" not in r.stdout or q.returncode or "package: ok" not in q.stdout:
        return "FAIL", tail(r.stdout + r.stderr + q.stdout + q.stderr)[:900]
    return "PASS", "the installer touches nothing it didn't write; the package draws its words from a scratch folder, installed, updated, removed; without its fonts in the system's"


def keys():
    """(review 6, M2) A real keyboard and pointer in six apps on Linux (XTEST), and the Mac's own key events (CGEvent → keyDown:) in two."""
    for ex in ["kit", "workbook", "sketch", "media", "omxplorer", "pnote"]:
        r = run(["scripts/build.sh", ex, "linux"], 1800)
        if r.returncode:
            return "FAIL", f"{ex}: {tail(r.stdout + r.stderr)}"
    r = run(["pixi", "run", "python", "-B", "tests/realkeys.py"], 600)
    if r.returncode or "realkeys: ok" not in r.stdout:
        return "FAIL", "Linux: " + "; ".join(l for l in r.stdout.splitlines() if l.startswith("BAD"))[:800]
    if m := mac_reachable():
        return "BLOCKED", f"Linux PASS (six apps); Mac BLOCKED ({m})"
    probs = []
    sf = OUT / "mac-realkeys.steps"
    sf.parent.mkdir(parents=True, exist_ok=True)
    sf.write_text("\n".join(["wait:1500", "realkeys:canvas=ab1", "realkey:canvas=Space", "realkey:canvas=ArrowDown", "wait:300", "quit"]) + "\n")
    r = run(["scripts/mac-ssh", "kit", str(sf)], 1800, env=dict(os.environ, MAC_SSH=MAC_SSH))
    rep = ROOT / ((r.stdout + r.stderr).strip().splitlines() or ["none"])[-1]
    dumps = [p.read_text() for p in sorted(rep.glob("0*.txt"))] if rep.exists() else []
    for want in ["Key 1", "Key  ", "Key ArrowDown"]:
        if not any(f"Text '{want}'" in d for d in dumps):
            probs.append(f"Mac: kit doesn't say {want!r}")
    ref = REF / "pn.db"
    if make_ref():
        probs.append("no reference notes")
    else:
        os.environ["MAC_FETCH"] = "pn.db pn.db-wal pn.db-shm"
        out_mac, e = mac_run("realkeys", ["wait:1500", "key:desk=ctrl+k", "wait:400", "realkeys:desk=Weekly review", "wait:500", "realkey:desk=Enter", "wait:900",
                                          "key:desk=ctrl+End", "realkeys:desk= hé q1 t", "wait:2500"], {"PNOTE_DB": "{data}/pn.db", "PNOTE_SKIN": "paper"}, [ref])
        os.environ.pop("MAC_FETCH", None)
        rep = next(iter(sorted((ROOT / "build/mac-ssh").glob("pnote-*"))[-1:]), None)
        dbm = next(iter(rep.rglob("pn.db")), None) if rep else None
        md = page_markdown(dbm, "Weekly review") if dbm else None
        if e or md is None or " hé q1 t" not in md:
            probs.append(f"Mac: pnote's page after real keys: {e or (md or '')[-60:]!r}")
    if probs:
        return "FAIL", "; ".join(probs)
    return "PASS", "Linux: real keys and a pointer in kit, workbook, sketch, the player, omxplorer, pnote; Mac: the system's key events in kit and pnote"


CHECKS = {"BUILDS": builds, "KEYS": keys, "PACKAGE": package, "M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5, "M6": m6, "M7": m7}

if __name__ == "__main__":
    want = sys.argv[1:] or list(CHECKS)
    bad = False
    for k in want:
        try:
            verdict, why = CHECKS[k]()
        except Exception as e:
            import traceback
            traceback.print_exc()
            verdict, why = "FAIL", f"{type(e).__name__}: {e}"
        print(f"{k}: {verdict}  {why}", flush=True)
        bad = bad or verdict == "FAIL"
    sys.exit(1 if bad else 0)
