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
STEPS_MIN = 25        # M4
P95 = 8.3             # M6: silky
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
RACE_STEPS = ["open", "pan", "zoom", "drag one", "drag 40", "undo/redo", "pen", "typing"]
RACE_NOTES = ["600", "stress"]

_ref_done = {}


def run(cmd, timeout=3600, env=None, cwd=ROOT):
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
            out_mac, e = mac_run("fontcheck", [], {"PNOTE_FONTCHECK": "1", "FONTTEXT_REF": "{data}/textwidths.json",
                                                    "FONTTEXT_FIXTURE": "{data}/fixture.json", "FONTTEXT_DPR": str(MAC_DPR)},
                                 [REF_MAC / "textwidths.json", FIXTURE])
            if e:
                probs.append("Mac: " + e)
            else:
                pm, worst_m, crisp_m = judge_fonttext(out_mac, json.loads((REF_MAC / "textwidths.json").read_text())["widths"], "Mac")
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
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    mu_a, mu_b = _blur(a), _blur(b)
    saa = _blur(a * a) - mu_a ** 2
    sbb = _blur(b * b) - mu_b ** 2
    sab = _blur(a * b) - mu_a * mu_b
    m = ((2 * mu_a * mu_b + c1) * (2 * sab + c2)) / ((mu_a ** 2 + mu_b ** 2 + c1) * (saa + sbb + c2))
    return float(m.mean())


def sampled_fill(img, box, dpr):
    """An element's fill: the most common colour inside its box, inset by up to 3 logical px (text and edges vote less
    than the fill they sit on)."""
    x, y, w, h = box
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
    open_page = [f"tapat:desk={box_center(sb, row('Lighthouse trip'))}", "wait:600"]
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
    steps = ["wait:800"] + screen_steps(screen, ref) + ["wait:400", f"render:desk={png}"]
    cfg = outdir / f"cfg-{screen}"
    shutil.rmtree(cfg, ignore_errors=True)
    cfg.mkdir()
    env = dict(os.environ, PNOTE_DB=str(db), PNOTE_SKIN=skin, PNOTE_BOXES=str(boxes), OMX_CONFIG=str(cfg), PNOTE_DIR=str(cfg),
               MOJOUI_TEST=";".join(steps), MOJOUI_SHOT="")
    r = run(["scripts/testscreen", str(APP)], 600, env=env)
    log = r.stdout + r.stderr
    (outdir / f"{screen}.log").write_text(log)
    if not png.exists():
        return f"{screen}: no picture (exit {r.returncode}): {tail(log, 400)}"
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
        return {"markdown": md.strip(), "ink": len((content.get("ink") or {}).get("drawings", [])) if isinstance(content, dict) else 0}
    if kind == "mindmap":
        nodes = content.get("nodes", [])
        byid = {n["id"]: n for n in nodes}
        path = lambda n: (path(byid[n["parentId"]]) + "/" if n.get("parentId") in byid else "") + n.get("text", "")
        return sorted(path(n) for n in nodes)
    if kind == "canvas":
        objs = content.get("nodes") or content.get("objects") or []
        kinds = sorted((o.get("type", ""), (o.get("text") or "").strip(), str(o.get("color", ""))) for o in objs)
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
    runs, cur = [[]], 0
    for i, s in enumerate(steps):
        acts = s["native"] if isinstance(s["native"], list) else [s["native"]]
        for a in acts:
            if a == "relaunch":
                runs.append([])
            else:
                runs[-1].append(a)
        runs[-1].append(f"render:desk={out / 'native' / f'{i:02d}.png'}")
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
    if "PNOTE IME: context=GtkIMMulticontext" not in log and "PNOTE IME: context=" not in log:
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
        out_mac, e = mac_run("ime", ["wait:800", "imemarked:desk=かんじ", "imefirstrect:desk", "imeinsert:desk=漢字", "key:desk=Return",
                                     "imemarked:desk=नमस्", "imeinsert:desk=नमस्ते", "key:desk=Return", "imemarked:desk=한", "imeinsert:desk=한국어",
                                     "key:desk=Return", "clipboard:漢字 नमस्ते 한국어", "key:desk=cmd+v", "wait:800", "notes:"],
                             {"PNOTE_DB": "{data}/pn.db", "PNOTE_OPEN": "Weekly review"}, [REF / "pn.db"])
        if e:
            probs.append("Mac: " + e)
        else:
            if not re.search(r"^PNOTE IME: marked=\"かんじ\" underline=1", out_mac, re.M) or "PNOTE IME: firstRect=" not in out_mac:
                probs.append("Mac: setMarkedText/firstRectForCharacterRange not seen on the real view")
            mm = re.search(r"^PNOTE NOTE: Weekly review (.*)$", out_mac, re.M)
            if not mm or want.replace("\n", "\\n") not in mm.group(1):
                probs.append(f"Mac: saved Markdown lacks the words ({mm.group(1)[:80] if mm else 'no PNOTE NOTE line'})")
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
    err = build_linux()
    if err:
        return "FAIL", err
    race = OUT / "race"
    race.mkdir(parents=True, exist_ok=True)
    probs = []
    # the web at its best: PN's own benchmarks, Chromium with the GPU, at the native run's device scale
    print("(running Personal Note's own benchmarks: several minutes)", flush=True)
    r = run(["node", "scripts/benchmark-f034.mjs", "--gpu", f"--dpr={LINUX_DPR}", "--note=both", f"--out={race / 'web-f034.json'}"], 3600, cwd=PN)
    (race / "web-f034.log").write_text(r.stdout + r.stderr)
    if r.returncode or not (race / "web-f034.json").exists():
        return "FAIL", f"benchmark-f034 exit {r.returncode}: {tail(r.stdout + r.stderr)}"
    r2 = run(["node", "scripts/benchmark-first-screen.mjs"], 1800, cwd=PN)
    (race / "web-first-screen.log").write_text(r2.stdout + r2.stderr)
    web = web_race(json.loads((race / "web-f034.json").read_text()), r2.stdout)
    # the native app: the same notes (dumped from PN's own generators), the same steps
    r = run(["node", "-e", NOTE_DUMP, str(race)], 600, cwd=PN)
    if r.returncode:
        return "FAIL", f"dumping PN's benchmark notes: {tail(r.stderr)}"
    nat = {}
    for note in RACE_NOTES:
        cfg = race / f"cfg-{note}"
        shutil.rmtree(cfg, ignore_errors=True)
        cfg.mkdir()
        env = dict(os.environ, PNOTE_DIR=str(cfg), OMX_CONFIG=str(cfg), PNOTE_SCENE="canvas", PNOTE_IMPORT=str(race / f"note-{note}.json"),
                   MOJOUI_TEST=";".join(["wait:800", "window:1440x900"] + NATIVE_RACE), MOJOUI_SHOT="")
        r = run(["scripts/testscreen", str(APP)], 1800, env=env)
        (race / f"native-{note}.log").write_text(r.stdout + r.stderr)
        nat[note] = native_race(r.stdout + r.stderr)
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
        starts.append(r.stdout + r.stderr)
    nstart = native_start(starts)
    rows, ok = race_table(web, nat, nstart)
    (ROOT / "docs/goals/79").mkdir(parents=True, exist_ok=True)
    (ROOT / "docs/goals/79/race.md").write_text(rows)
    if not ok:
        return "FAIL", "see docs/goals/79/race.md: " + "; ".join(l for l in rows.splitlines() if "✗" in l)[:900]
    mac = mac_reachable()
    if mac:
        return "BLOCKED", f"Linux PASS (docs/goals/79/race.md); Mac BLOCKED ({mac})"
    out_mac, e = mac_run("race", ["wait:800", "window:1440x900"] + NATIVE_RACE, {"PNOTE_SCENE": "canvas", "PNOTE_IMPORT": "{data}/note-600.json"},
                         [race / "note-600.json"])
    if e:
        return "FAIL", "Mac: " + e
    bad = [f"{k} {v['p95']}/{v['max']}" for k, v in native_race(out_mac).items() if v["p95"] > P95 or v["max"] > MAX or v.get("cpu", 0)]
    if bad:
        return "FAIL", "Mac not silky: " + ", ".join(bad)
    return "PASS", "native faster on every step, starts sooner, less memory, silky; Mac silky; docs/goals/79/race.md"


NOTE_DUMP = """
const [out] = process.argv.slice(1);
const { generateNote, COLUMNS, ROWS } = await import('./scripts/benchmark-note.mjs');
const { generateStressNote } = await import('./src/modules/speedtest/stress-note.js');
const fs = await import('node:fs');
fs.writeFileSync(out + '/note-600.json', JSON.stringify({ content: generateNote(), pageState: { columns: COLUMNS, rows: ROWS } }));
const s = generateStressNote(5400, { columns: 4, rows: 4 });
fs.writeFileSync(out + '/note-stress.json', JSON.stringify({ content: s.content, pageState: s.pageState }));
""".replace("const [out] = process.argv.slice(1);", "const out = process.argv[1];")
NATIVE_RACE = ["framebench:note=open,20", "framebench:note=pan,120", "framebench:note=zoom,60", "framebench:note=dragone,60",
               "framebench:note=drag40,60", "framebench:note=undoredo,40", "framebench:note=draw,300", "framebench:note=typing,60"]
NATIVE_NAMES = {"open": "open", "pan": "pan", "zoom": "zoom", "dragone": "drag one", "drag40": "drag 40", "undoredo": "undo/redo",
                "draw": "pen", "typing": "typing"}


def native_race(out):
    res = {}
    for line in out.splitlines():
        if not line.startswith("FRAMEBENCH:"):
            continue
        kv = dict(re.findall(r"(\w+)=([^\s]+)", line))
        what = re.search(r"FRAMEBENCH: \S+=(\w+)", line)
        if not what:
            continue
        name = NATIVE_NAMES.get(what.group(1), what.group(1))
        try:
            res[name] = {"p95": float(kv["p95"]), "max": float(kv["max"]), "cpu": int(kv.get("cpu_frames", "0"))}
        except (KeyError, ValueError):
            pass
    return res


def web_race(f034, first_screen_text):
    """{note: {step: {p95, max}}} from PN's benchmark-f034 --out JSON, plus first screen ms."""
    res = {}
    for r in f034.get("results", []):
        note = "stress" if "stress" in str(r.get("note", r.get("name", ""))) else "600"
        for sc in r.get("scenarios", r.get("rows", [])):
            name = str(sc.get("scenario", "")).lower()
            for step in RACE_STEPS:
                if name.startswith(step) or step in name:
                    res.setdefault(note, {})[step] = {"p95": float(sc.get("p95", 0)), "max": float(sc.get("max", 0))}
                    break
    m = re.search(r"first screen (\d+)", first_screen_text)
    res["first_screen_ms"] = float(m.group(1)) if m else None
    m = re.search(r"rss[^\d]*(\d+)", first_screen_text, re.I)
    res["rss_mb"] = float(m.group(1)) if m else None
    return res


def native_start(outs):
    vals = {"first": [], "switch": [], "omnibar": [], "rss": []}
    for o in outs:
        for k, pat in [("first", r"^FIRSTSCREEN: ([\d.]+)"), ("switch", r"^NOTESWITCH: .*p95=([\d.]+)"), ("omnibar", r"^OMNIBAR: .*p95=([\d.]+)"),
                       ("rss", r"^RSS: ([\d.]+)")]:
            m = re.search(pat, o, re.M)
            if m:
                vals[k].append(float(m.group(1)))
    med = lambda v: sorted(v)[len(v) // 2] if v else None
    return {k: med(v) for k, v in vals.items()}


def race_table(web, nat, start):
    ok = True
    lines = ["# Goal 79 race: native pnote vs the web Personal Note (generated by docs/goals/79-check.py M6)", "",
             f"Same machine, same notes (PN's own generators), 1440×900 at {LINUX_DPR}×. Web: benchmark-f034.mjs --gpu (Chromium with the GPU). "
             f"Native: the same steps through test mode on the hidden test screen. Silky = p95 ≤ {P95} ms and max ≤ {MAX} ms, no CPU frame.", "",
             "| note | step | web p95 / max ms | native p95 / max ms | |", "|---|---|---|---|---|"]
    for note in RACE_NOTES:
        for step in RACE_STEPS:
            w = web.get(note, {}).get(step)
            n = nat.get(note, {}).get(step)
            good = bool(w and n and n["p95"] < w["p95"] and n["max"] < w["max"] and n["p95"] <= P95 and n["max"] <= MAX and n.get("cpu", 0) == 0)
            ok = ok and good
            lines.append(f"| {note} | {step} | {f'{w['p95']} / {w['max']}' if w else '—'} | {f'{n['p95']} / {n['max']}' if n else '—'} | {'✓' if good else '✗'} |")
    lines += ["", "| | web | native | |", "|---|---|---|---|"]
    for k, wk, unit in [("first", "first_screen_ms", "ms"), ("rss", "rss_mb", "MB")]:
        w, n = web.get(wk), start.get(k)
        good = bool(w and n and n < w)
        ok = ok and good
        lines.append(f"| {'cold start to first screen' if k == 'first' else 'RSS after opening all three kinds'} | {w if w else '—'} {unit} | {n if n else '—'} {unit} | {'✓' if good else '✗'} |")
    for k in ["switch", "omnibar"]:
        n = start.get(k)
        good = bool(n is not None and n <= P95)
        ok = ok and good
        lines.append(f"| {'note switch' if k == 'switch' else 'omnibar open'} p95 | — | {n if n is not None else '—'} ms | {'✓' if good else '✗'} |")
    return "\n".join(lines) + "\n", ok


# ---------------------------------------------------------------- the Mac

def mac_reachable():
    r = run(["ssh", "-i", MAC_KEY, "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", MAC_SSH, "true"], 60)
    return "" if r.returncode == 0 else f"the Mac ({MAC_SSH}) isn't reachable"


def mac_run(tag, steps, env, data):
    """pnote on the M4 through scripts/mac-ssh; (stdout, '') or ('', why)."""
    print(f"(opening a pnote window on the Mac: {tag}, about a minute)", flush=True)
    sf = OUT / f"mac-{tag}.steps"
    sf.parent.mkdir(parents=True, exist_ok=True)
    sf.write_text("\n".join(steps + ["quit"]) + "\n")
    e = dict(os.environ, MAC_SSH=MAC_SSH, MAC_ENV=",".join(f"{k}={v}" for k, v in env.items()))
    r = run(["scripts/mac-ssh", "pnote", str(sf)] + [str(d) for d in data], 3600, env=e)
    lines = (r.stdout + r.stderr).strip().splitlines()
    report = Path(lines[-1]) if lines else None
    if r.returncode or not report or not (ROOT / report / "stdout.txt").exists():
        return "", f"mac-ssh exit {r.returncode}: {tail(r.stdout + r.stderr, 400)}"
    out = (ROOT / report / "stdout.txt").read_text()
    (OUT / f"mac-{tag}.log").write_text(out)
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
                out, e = mac_run(f"look-{s}", ["wait:1200"] + screen_steps(s, REF_MAC) + ["wait:600", "render:desk={data}/" + f"{s}.png", "boxes:{data}/" + f"{s}.boxes.json"],
                                 {"PNOTE_DB": "{data}/pn.db", "PNOTE_SKIN": "night" if s.endswith("night") else "crayon" if s.endswith("crayon") else "paper",
                                  "PNOTE_CHROME": "mac"}, [REF_MAC / "pn.db"])
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


CHECKS = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5, "M6": m6, "M7": m7}

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
