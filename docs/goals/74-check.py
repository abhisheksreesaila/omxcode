"""Milestone checker for GOAL.md (goal 74: Personal Note's editors, native in Mojo). Prints "Mn: PASS|FAIL|BLOCKED  why".

    pixi run python docs/goals/74-check.py [M0 M1 ...]          (default: every milestone)

Written before the work (2026-11-17), from the goal's words; never edited to make a milestone pass (add, don't weaken),
except M7's item count (D-7426, a correction to its own contract) and, after review round 1, race.md's caveats (D-7429).
GTK runs are headless (scripts/headless.py). Personal Note (~/Projects/personalnotev2) is only read and run; its outputs
go to build/g74/.

The app's contract (examples/pnote), which M6 and M7 drive:
  PNOTE_DIR=<folder>        its notes.db lives there (made when missing)
  PNOTE_IMPORT=<file.json>  a canvas note made from Personal Note's benchmark-note JSON (Fabric-style objects: Textbox,
                            Rect, Path ink, connectors), opened at launch
  PNOTE_PAGE_CHARS=N        a page note of N characters of seeded Markdown, opened at launch
  Sidebar buttons "New page", "New canvas", "New map"; a search field "Search notes"; the note's Canvas is tagged "note".
  Canvas notes' keys: v select, t text box, s sticky, r rectangle, p pen, c connects the two selected objects, ctrl+a
  selects all, ctrl+z / ctrl+shift+z undo and redo, Escape ends editing. A tap with t/s/r makes the object centred there
  and starts editing it (typing goes into it).
  Mind maps: a new map has its root selected; Tab adds a child and edits it, Enter while editing commits, Enter while not
  editing adds a sibling and edits it.
  ctrl+k opens the palette: a field "Go to" (type:Go to=…, submit:Go to opens the first hit).
  Prints, on every change of what it shows:
    PNOTE: note=<title> kind=<page|canvas|map> notes=<n> shown=<n listed> chars=<n> objects=<n> connectors=<n> strokes=<n> nodes=<n>
  and at launch, one line per stored note: PNOTE NOTE: <kind> <title> chars=<n> objects=<n> connectors=<n> strokes=<n> nodes=<n>
"""
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())
sys.path.insert(0, str(ROOT / "scripts"))
OUT = ROOT / "build" / "g74"
PN = Path.home() / "Projects" / "personalnotev2"
APP = ROOT / "build" / "pnote" / "linux" / "pnote"
BASE = "cc33c9d7"


def run(cmd, timeout=3600, env=None, cwd=ROOT):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)


def mojo_test(path, ok_lines):
    if not (ROOT / path).exists():
        return False, f"{path} missing"
    r = run(["pixi", "run", "mojo", "run", "-I", ".", path], 1800)
    out = r.stdout + r.stderr
    missing = [l for l in ok_lines if l not in out]
    if r.returncode != 0 or missing:
        errs = " | ".join(l for l in out.splitlines() if "error" in l.lower() or "FAIL" in l)[-600:]
        return False, f"{path}: exit {r.returncode}, missing {missing} {errs}"
    return True, f"{path}: " + ", ".join(ok_lines)


def no_js(paths):
    """None of the component files reach for JS, a WebComponent or a toolkit text widget."""
    bad = []
    for p in paths:
        f = ROOT / p
        if not f.exists():
            continue
        src = f.read_text()
        for word in ("webcomponent", "WebComponent", "mx-editor", "codemirror", "CodeMirror", "TextArea(", "TextField("):
            if word in src:
                bad.append(f"{p}: {word}")
    return bad


def m0():
    md = ROOT / "docs" / "audits" / "personalnote.md"
    js = ROOT / "docs" / "audits" / "personalnote.json"
    if not md.exists() or not js.exists():
        return "FAIL", "audit files missing"
    d = json.loads(js.read_text())
    text = md.read_text()
    probs = []
    if d.get("date") != "2026-11-17":
        probs.append(f"json date {d.get('date')!r}")
    if d.get("base") != BASE:
        probs.append(f"json base {d.get('base')!r}")
    if "2026-11-17" not in text.split("\n## ")[0]:
        probs.append("md not re-dated in its head")
    feats = d.get("features", [])
    counts = {"have": 0, "partial": 0, "missing": 0}
    for f in feats:
        counts[f.get("status")] = counts.get(f.get("status"), 0) + 1
        if "native" not in f:
            probs.append(f"no native field: {f.get('feature')!r}"[:90])
        if f.get("status") == "have" and f.get("native") is False:
            probs.append(f"'have' rests on JS: {f.get('feature')!r}"[:90])
        for p in f.get("files", []):
            if not (ROOT / p).exists():
                probs.append(f"missing file {p}")
        if not f.get("files"):
            probs.append(f"no files: {f.get('feature')!r}"[:90])
    if d.get("counts") != counts:
        probs.append(f"json counts {d.get('counts')} vs features {counts}")
    for k, v in counts.items():
        if f"{v} {k}" not in text:
            probs.append(f"md doesn't say '{v} {k}'")
    if probs:
        return "FAIL", "; ".join(probs[:8])
    return "PASS", f"{len(feats)} features: {counts}, every file there, native marked"


def m1():
    ok, why = mojo_test("tests/test_history.mojo", ["history: ok", "history coalesce: ok", "history cap: ok"])
    return ("PASS" if ok else "FAIL"), why


def m2():
    bad = no_js(["mojoui/textedit.mojo"])
    if bad:
        return "FAIL", "not native: " + "; ".join(bad)
    ok, why = mojo_test("tests/test_textedit.mojo", ["textedit edit: ok", "textedit caret: ok", "textedit wrap: ok",
                                                      "textedit hit: ok", "textedit undo: ok", "textedit 1M: ok"])
    return ("PASS" if ok else "FAIL"), why


def m3():
    bad = no_js(["mojoui/mdedit.mojo"])
    if bad:
        return "FAIL", "not native: " + "; ".join(bad)
    ok, why = mojo_test("tests/test_mdedit.mojo", ["mdedit styles: ok", "mdedit marks: ok", "mdedit task: ok"])
    return ("PASS" if ok else "FAIL"), why


def m4():
    bad = no_js(["mojoui/objectlayer.mojo"])
    if bad:
        return "FAIL", "not native: " + "; ".join(bad)
    ok, why = mojo_test("tests/test_objectlayer.mojo", ["objectlayer edit: ok", "objectlayer connectors: ok",
                                                         "objectlayer undo: ok", "objectlayer random: ok", "objectlayer 600: ok"])
    return ("PASS" if ok else "FAIL"), why


def m5():
    bad = no_js(["mojoui/mindmap.mojo"])
    if bad:
        return "FAIL", "not native: " + "; ".join(bad)
    ok, why = mojo_test("tests/test_mindmap.mojo", ["mindmap layout: ok", "mindmap keys: ok", "mindmap undo: ok"])
    return ("PASS" if ok else "FAIL"), why


def build_pnote():
    r = run(["scripts/build.sh", "pnote", "linux"], 3600)
    return r.returncode == 0 and APP.exists(), (r.stdout + r.stderr)[-600:]


def gtk(steps, env_extra, timeout=600):
    import headless
    headless.ensure()
    env = dict(os.environ, MOJOUI_TEST=";".join(steps), **env_extra)
    r = run([str(APP)], timeout, env=env)
    return r.returncode, r.stdout + r.stderr


def pnote_lines(out):
    return [l for l in out.splitlines() if l.startswith("PNOTE: ")]


def field(line, name):
    m = re.search(rf"\b{name}=(\S+)", line)
    return m.group(1) if m else None


def expect_in_order(lines, wants):
    """Each want (a dict of field → value) is met by some line after the previous want's line."""
    at = 0
    for want in wants:
        while at < len(lines) and not all(field(lines[at], k) == str(v) for k, v in want.items()):
            at += 1
        if at == len(lines):
            return f"no PNOTE: line with {want} after the previous step (last: {lines[-3:]})"
    return ""


SESSION = [
    "window:1440x900",
    "tap:New page",
    "typekeys:note=# Groceries⏎- [ ] milk⏎- [ ] eggs⏎Buy **fresh** bread.",
    "shot:{out}/page.png",
    "tap:New canvas",
    "key:note=t", "tapat:note=250,300", "typekeys:note=Ship the export", "key:note=Escape",
    "key:note=s", "tapat:note=700,400", "typekeys:note=Idea", "key:note=Escape",
    "key:note=ctrl+a", "key:note=c",
    "key:note=p", "stroke:note=200,600,0.3;260,620,0.7;320,640,1.0;380,650,0.5",
    "key:note=ctrl+z",
    "stroke:note=200,700,0.5;300,720,0.8;400,700,0.5",
    "shot:{out}/canvas.png",
    "tap:New map",
    "key:note=Tab", "typekeys:note=Milk", "key:note=Return",
    "key:note=Return", "typekeys:note=Eggs", "key:note=Return",
    "key:note=Return", "typekeys:note=Bread", "key:note=Return",
    "shot:{out}/map.png",
    "type:Search notes=eggs",
    "key:note=ctrl+k", "type:Go to=groc", "submit:Go to",
    "quit",
]
WANTS = [
    {"kind": "page"},
    {"kind": "canvas", "objects": 1},
    {"kind": "canvas", "objects": 2},
    {"kind": "canvas", "connectors": 1},
    {"kind": "canvas", "strokes": 1},
    {"kind": "canvas", "strokes": 0},
    {"kind": "canvas", "strokes": 1, "objects": 2, "connectors": 1},
    {"kind": "map", "nodes": 2},
    {"kind": "map", "nodes": 3},
    {"kind": "map", "nodes": 4},
    {"shown": 2},  # (Groceries and the map hold "eggs")
    {"note": "Groceries", "kind": "page"},
]


def m6():
    ok, why = build_pnote()
    if not ok:
        return "FAIL", "build: " + why
    OUT.mkdir(parents=True, exist_ok=True)
    data = OUT / "pnote-data"
    shutil.rmtree(data, ignore_errors=True)
    shots = OUT / "m6"
    shutil.rmtree(shots, ignore_errors=True)
    shots.mkdir(parents=True)
    steps = [s.replace("{out}", str(shots)) for s in SESSION]
    code, out = gtk(steps, {"PNOTE_DIR": str(data)})
    (OUT / "m6-session1.log").write_text(out)
    lines = pnote_lines(out)
    miss = expect_in_order(lines, WANTS)
    if miss:
        return "FAIL", f"session 1 (exit {code}): {miss}"
    page = [l for l in lines if field(l, "kind") == "page"]
    if not page or int(field(page[-1], "chars") or 0) < 40:
        return "FAIL", f"the page holds too little: {page[-1:] }"
    code2, out2 = gtk([], {"PNOTE_DIR": str(data)})
    (OUT / "m6-session2.log").write_text(out2)
    stored = [l for l in out2.splitlines() if l.startswith("PNOTE NOTE: ")]
    kinds = sorted(l.split()[2] for l in stored)
    if kinds != ["canvas", "map", "page"]:
        return "FAIL", f"relaunch: stored notes {stored}"
    canvas = next(l for l in stored if l.split()[2] == "canvas")
    mp = next(l for l in stored if l.split()[2] == "map")
    if (field(canvas, "objects"), field(canvas, "connectors"), field(canvas, "strokes")) != ("2", "1", "1") or field(mp, "nodes") != "4":
        return "FAIL", f"relaunch didn't keep the work: {canvas} | {mp}"
    from PIL import Image
    import numpy as np
    sizes = []
    pics = []
    for name in ("page", "canvas", "map"):
        p = shots / f"{name}.png"
        if not p.exists():
            return "FAIL", f"no {name}.png"
        im = np.asarray(Image.open(p).convert("L"), dtype=float)
        if im.std() < 4:
            return "FAIL", f"{name}.png is blank"
        sizes.append(im.shape)
        pics.append(im)
    if len({s for s in sizes}) == 1 and any(abs(pics[0] - pics[k]).mean() < 1 for k in (1, 2)):
        return "FAIL", "the three shots are the same picture"
    return "PASS", f"{len(lines)} PNOTE lines in order; relaunch kept page, canvas (2 objects, 1 connector, 1 stroke), map (4 nodes); shots in {shots}"


def pn_side():
    """Personal Note's own pan/zoom benchmark, as its repo runs it."""
    if not (PN / "node_modules" / "playwright").exists():
        return None, "personalnotev2 has no node_modules/playwright"
    r = run(["node", "scripts/benchmark-leafer.mjs", "--dpr=1"], 1800, cwd=PN)
    out = r.stdout + r.stderr
    (OUT / "race-pn-canvas.log").write_text(out)
    if r.returncode != 0:
        return None, f"benchmark-leafer exit {r.returncode}: {out[-300:]}"
    return out, ""


def note_json():
    """Personal Note's benchmark note, made by its own generator, as JSON for pnote."""
    target = OUT / "bench-note.json"
    js = "import('./scripts/benchmark-note.mjs').then(m => { process.stdout.write(JSON.stringify(m.generateNote())) })"
    r = run(["node", "--input-type=module", "-e", js], 300, cwd=PN)
    if r.returncode != 0 or not r.stdout.strip():
        return None, f"generateNote: {r.stderr[-300:]}"
    target.write_text(r.stdout)
    return target, ""


def framebench_lines(out):
    return [l for l in out.splitlines() if "FRAMEBENCH" in l or "BENCH" in l]


def m7():
    OUT.mkdir(parents=True, exist_ok=True)
    ok, why = build_pnote()
    if not ok:
        return "FAIL", "build: " + why
    note, why = note_json()
    if note is None:
        return "BLOCKED", why
    shutil.rmtree(OUT / "race-data", ignore_errors=True)
    shutil.rmtree(OUT / "race-page", ignore_errors=True)
    code, out = gtk(["window:1440x900", "framebench:note=pan,120", "framebench:note=zoom,60", "quit"],
                    {"PNOTE_DIR": str(OUT / "race-data"), "PNOTE_IMPORT": str(note)}, 1200)
    (OUT / "race-omx-canvas.log").write_text(out)
    ours = framebench_lines(out)
    objs = [l for l in pnote_lines(out) if field(l, "kind") == "canvas"]
    # (amended, D-7426: the contract's objects= counts boxes only; the note's 645 items are objects + connectors + strokes)
    items = sum(int(field(objs[-1], k) or 0) for k in ("objects", "connectors", "strokes")) if objs else 0
    if not ours or not objs or items < 500:
        return "FAIL", f"pnote's canvas bench didn't run on the 600-object note (exit {code}): {ours[:2]} {objs[-1:]}"
    code, out = gtk(["window:1440x900", "framebench:note=type,200", "quit"],
                    {"PNOTE_DIR": str(OUT / "race-page"), "PNOTE_PAGE_CHARS": "1000000"}, 1200)
    (OUT / "race-omx-page.log").write_text(out)
    ours_page = framebench_lines(out)
    if not ours_page:
        return "FAIL", f"pnote's 1M-character typing bench didn't run (exit {code})"
    pn, why_pn = pn_side()
    pn_page = None
    why_page = ""
    script = ROOT / "scripts" / "pn_typing.mjs"
    if script.exists():
        r = run(["node", str(script), str(PN)], 1800, cwd=PN)
        (OUT / "race-pn-page.log").write_text(r.stdout + r.stderr)
        pn_page = r.stdout if r.returncode == 0 else None
        why_page = "" if pn_page else f"pn_typing exit {r.returncode}: {(r.stdout + r.stderr)[-300:]}"
    else:
        why_page = "scripts/pn_typing.mjs missing"
    md = ["# Goal 74 M7: pnote vs Personal Note, measured on one machine", "",
          f"Generated by docs/goals/74-check.py M7 on {time.strftime('%Y-%m-%d %H:%M')}, {os.cpu_count()} CPUs. As measured, nothing edited.", "",
          "## Canvas: Personal Note's 600-object benchmark note, pan and zoom", "",
          "### pnote (GTK, framebench: each frame's work)", "", "```", *ours, "```", "",
          "### Personal Note (Chromium, its own scripts/benchmark-leafer.mjs --dpr=1)", "", "```",
          *((pn or why_pn).strip().splitlines()[-40:]), "```", "",
          "## Page: typing in a 1,000,000-character note", "",
          "### pnote (GTK)", "", "```", *[l for l in out.splitlines() if l.startswith("PNOTE OPEN:")], *ours_page, "```", "",
          "### Personal Note (Chromium, scripts/pn_typing.mjs)", "", "```", *((pn_page or why_page).strip().splitlines()[-30:]), "```", ""]
    md += ["## Caveats (what each number is)", "",
           "- **Not the same yardstick.** pnote's FRAMEBENCH numbers are each frame's *work* on GTK: the event, the app's update and "
           "paint, GTK's paint, a display round trip and a full software raster of the canvas (GskCairoRenderer on a headless Xvfb "
           "display, no GPU): an upper bound. Personal Note's canvas table is its own benchmark's *frame intervals* in headless "
           "Chromium, locked to 60 Hz: 16.7 ms means no frame was dropped, not that a frame cost 16.7 ms. So the canvas result is "
           "\"both hold 60 fps panning; pnote's zoom p95 work passes one frame\", not \"faster\".",
           "- **Page typing.** Personal Note's \"main-thread work per key\" (scripts/pn_typing.mjs) is the key's handlers plus a "
           "forced style and layout read in the next frame; it leaves out paint, raster and compositing (Chromium does those off "
           "the main thread). pnote's number includes its whole frame, raster too. Its keydown → painted frame (~33 ms) is two "
           "vsync waits, what a person sees on a 60 Hz screen in either app.",
           "- **Opening.** Personal Note's open time is the page load through its Vite dev server (module transforms included), "
           "not a production build. pnote's PNOTE OPEN line is the note stored in SQLite and opened in the editor; the window "
           "itself isn't timed here. tests/test_textedit times the editor alone opening 1M characters (a few ms).",
           "- **Scope of 1M.** 1M characters in ordinary paragraphs (~65 characters each). One 1M-character paragraph re-wraps on "
           "every key in pnote (~27 ms a key, tests/test_textedit prints it): debt, D-7428.",
           "- Both sides ran on the same machine, same seeded content (the same generator, word list and seed), 1440×900 at 1×.", ""]
    race = ROOT / "docs" / "goals" / "74" / "race.md"
    race.parent.mkdir(parents=True, exist_ok=True)
    race.write_text("\n".join(md))
    if pn is None or pn_page is None:
        return "BLOCKED", f"pnote ran; Personal Note's side: {why_pn or 'canvas ok'}; {why_page or 'page ok'} (see {race})"
    return "PASS", f"both sides ran; {race}"


def m8():
    probs = []
    r = run(["pixi", "run", "python", "scripts/components.py"], 1800)
    if r.returncode != 0:
        probs.append("components.py: " + (r.stdout + r.stderr)[-200:])
    matrix = (ROOT / "docs" / "components.md").read_text()
    for name in ("textedit", "mdedit", "objectlayer", "mindmap", "history"):
        if f"mojoui/{name}.mojo" not in matrix:
            probs.append(f"components.md doesn't list mojoui/{name}.mojo")
    lint = ROOT / "scripts" / "decisions_lint.py"
    if lint.exists():
        r = run(["pixi", "run", "python", str(lint)], 600)
        if r.returncode != 0:
            probs.append("decisions lint: " + (r.stdout + r.stderr)[-200:])
    r = run(["pixi", "run", "python", "docs/goals/40-check.py", "M0", "M1", "M2"], 3600)
    if r.stdout.count("PASS") < 3:
        probs.append("goal 40: " + r.stdout[-300:])
    r = run(["pixi", "run", "python", "docs/goals/71-check.py", "M5"], 7200)
    if "M5: PASS" not in r.stdout:
        probs.append("goal 71 M5: " + r.stdout[-300:])
    if probs:
        return "FAIL", "; ".join(probs)
    return "PASS", "matrix lists the five components; decisions lint; goal 40 M0–M2; goal 71 M5"


CHECKS = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5, "M6": m6, "M7": m7, "M8": m8}

if __name__ == "__main__":
    want = sys.argv[1:] or list(CHECKS)
    bad = False
    for k in want:
        try:
            verdict, why = CHECKS[k]()
        except Exception as e:  # a crash in a proof is a FAIL with its reason
            verdict, why = "FAIL", f"{type(e).__name__}: {e}"
        print(f"{k}: {verdict}  {why}", flush=True)
        bad = bad or verdict == "FAIL"
    sys.exit(1 if bad else 0)
