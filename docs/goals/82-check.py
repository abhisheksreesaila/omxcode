"""Milestone checker for goal 82 (docs/goals/82-draft.md): pnote's features at the web app's parity. Worker A's milestones:
M1 focus mode, M2 pictures, M4 print and export (M3/M7 and M5/M6 are other workers'; their checks go beside these).
Prints "Mn: PASS|FAIL|BLOCKED  why" per milestone.

    scripts/check 82 [M1 M2 M4]          (pixi run python docs/goals/82-check.py …)

Written with the feature work (2026-11-26) from the draft's words; never edited to make a milestone pass (add, don't weaken;
checker bugs are logged in docs/decisions.md with why the fix is not a weakening).

The yardstick is the web Personal Note (~/Projects/personalnotev2, read and run only): docs/goals/82/web.mjs drives it on a
scratch database on port 4982 (goal 79's ref.mjs and the other workers use 4991) and writes its pictures, boxes and facts. The
native app is driven by MOJOUI_TEST steps on the hidden test screen (scripts/testscreen), its notes a copy of the web's seeded
pn.db. Every Mojo build and GUI run holds ~/.cache/omx-quiet.lock shared (a judged race takes it exclusively) and uses at most
6 cores; the Mac's half runs through scripts/mac-ssh, which takes ~/.cache/omx-mac.lock itself.
"""
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())
_spec = importlib.util.spec_from_file_location("g79", ROOT / "docs" / "goals" / "79-check.py")
G79 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(G79)
OUT = ROOT / "build" / "g82"
G79.OUT = OUT  # (its Mac runs write their steps and logs here)
PN = G79.PN
APP = ROOT / "build" / "pnote" / "linux" / "pnote"
QUIET = os.path.expanduser("~/.cache/omx-quiet.lock")
CORES = "0-5"  # (at most 6 cores per build: the machine hard-stopped six times in four days)

# ---- the bars, from the draft ----
SSIM_FOCUS = 0.95  # M1: native's focus picture vs the web's at the same note (goal 79's whole-frame bar)
SSIM_SAME = 0.995  # M1: native's picture after leaving vs before entering
TOP_TOL = 2.0  # M1: the words' top at 96 px, centred, layout px
SSIM_PICTURE = 0.98  # M2/M4: a picture's box in both apps; the Picture export vs the web's


def run(cmd, timeout=3600, env=None, cwd=ROOT):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)


def tail(s, n=500):
    return s[-n:].replace("\n", " | ")


def quiet(cmd):
    """A test or GUI run: under the shared quiet lock, on at most six cores."""
    return ["flock", "-s", QUIET, "taskset", "-c", CORES] + cmd


BUILD_LOCK = os.path.expanduser("~/.cache/omx-build.lock")


def building(cmd):
    """(main session, 2026-11-26 17:45) A Mojo build: one at a time across the machine (an exclusive lock), at most six cores."""
    return ["flock", BUILD_LOCK, "taskset", "-c", CORES] + cmd


_built = {}


def build_linux():
    if "linux" in _built:
        return _built["linux"]
    r = run(building(["bash", "scripts/build.sh", "pnote", "linux"]), 3600)
    _built["linux"] = "" if r.returncode == 0 and APP.exists() else f"build failed: {tail(r.stdout + r.stderr, 800)}"
    return _built["linux"]


_web = {}


def web(do, *extra):
    """The web app's run for one milestone (once per checker run): its folder, or an error string."""
    key = (do,) + extra
    if key in _web:
        return _web[key]
    out = OUT / f"web-{do}"
    if out.exists():
        shutil.rmtree(out)
    if not (PN / "node_modules" / "playwright").exists():
        _web[key] = f"{PN} (with node_modules/playwright) isn't there"
        return _web[key]
    print(f"(the web app: {do}, about a minute)", flush=True)
    r = run(["node", str(ROOT / "docs/goals/82/web.mjs"), str(out), f"--do={do}", f"--dpr={G79.LINUX_DPR}"] + list(extra), 900, cwd=PN)
    (OUT / f"web-{do}.log").write_text(r.stdout + r.stderr)
    _web[key] = out if r.returncode == 0 and (out / "facts.json").exists() else f"web.mjs {do} exit {r.returncode}: {tail(r.stdout + r.stderr)}"
    return _web[key]


def center(boxes, name, cw=1440.0, ch=900.0):
    x, y, w, h = boxes[name]
    return f"{round((x + w / 2) / cw * 1000)},{round((y + h / 2) / ch * 1000)}"


def open_steps(panel, title):
    """From a fresh start (the notes panel closed): open the note titled `title` by its row, close the panel (the web's boxes)."""
    row = next(k for k in panel if k.startswith("row:") and k.endswith(title))
    # (D-8512) a painted frame before the first tap: after the 17:39 restart the first frame came seconds late (cold shader cache)
    # and taps on an unpainted window hit nothing; gpushot waits for the canvas's frames
    return ["gpushot:desk={out}/first-frame.png", f"tapat:desk={center(panel, '#toggle-sidebar')}", "wait:600", f"tapat:desk={center(panel, row)}", "wait:900",
            f"tapat:desk={center(panel, '#toggle-sidebar')}", "wait:700"]


def native(tag, db_from, steps, env=None, media=False):
    """pnote on the hidden test screen with these steps; (log, folder) or (error, None). The notes file is copied with the media/
    folder beside it when `media` (a file another run wrote, with its pictures: never the web's seeded one, whose media/ holds the
    web's own pictures and would hide whether pnote wrote its files)."""
    d = OUT / "native" / tag
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    db = d / "pn.db"
    shutil.copy(db_from, db)
    if media and (Path(db_from).parent / "media").is_dir():
        shutil.copytree(Path(db_from).parent / "media", d / "media")
    cfg = d / "cfg"
    cfg.mkdir()
    e = dict(os.environ, PNOTE_DB=str(db), PNOTE_SKIN="paper", PNOTE_BOXES=str(d / "boxes.json"), OMX_CONFIG=str(cfg), PNOTE_DIR=str(cfg),
             MOJOUI_TEST=";".join(["wait:800"] + [s.replace("{out}", str(d)) for s in steps] + ["quit"]), MOJOUI_SHOT="")
    e.update(env or {})
    r = run(quiet(["scripts/testscreen", str(APP)]), 900, env=e)
    log = r.stdout + r.stderr
    (d / "log.txt").write_text(log)
    if r.returncode == 75 or log.startswith("gpu-free: NO"):  # (the machine's rule: no GPU window beside another project's job)
        raise NotFree(log.strip().splitlines()[0] if log.strip() else "gpu-free: NO")
    return log, d


class NotFree(Exception):
    pass


def states(log):
    return re.findall(r"^PNOTE STATE: (.*)$", log, re.M)


def drop(state, *keys):
    return " ".join(kv for kv in state.split() if kv.split("=")[0] not in keys)


def ssim_files(a, b, box=None):
    ga, gb = G79.grey(a), G79.grey(b)
    if ga.shape != gb.shape:
        return -1.0
    if box:
        x0, y0, x1, y1 = box
        ga, gb = ga[y0:y1, x0:x1], gb[y0:y1, x0:x1]
    return float(G79.ssim(ga, gb))


# ---------------------------------------------------------------- M1: focus mode

def m1_steps(panel):
    shot = lambda n: [f"gpushot:desk={{out}}/{n}.png"]
    return (open_steps(panel, "Garden plan") + ["appbench:desk=hoveraway", "wait:300", "appbench:desk=state"] + shot("canvas-before")
            + ["key:desk=ctrl+.", "wait:3200", "appbench:desk=state"] + shot("canvas-focus")
            + ["appbench:desk=hovertop", "wait:300"] + shot("canvas-focus-strip")
            + ["appbench:desk=hoveraway", "key:desk=ctrl+.", "wait:900", "appbench:desk=state"] + shot("canvas-after")
            + open_steps(panel, "Lighthouse trip") + ["appbench:desk=state"] + shot("page-before")
            + ["key:desk=ctrl+.", "wait:3200", "appbench:desk=state"] + shot("page-focus")
            + ["key:desk=Escape", "wait:900", "appbench:desk=state"] + shot("page-after")
            + open_steps(panel, "Book mind map") + ["key:desk=ctrl+.", "wait:400", "appbench:desk=state"])


def judge_focus(log, d, ref, facts, where):
    probs, said = [], []
    st = states(log)
    if len(st) != 7:
        return [f"{where}: {len(st)} PNOTE STATE lines, not 7: {tail(log, 600)}"], said
    cb, cf, ca, pb, pf, pa, mp = st[0], st[1], st[2], st[3], st[4], st[5], st[6]
    if "focus=True" not in cf or "focus=True" not in pf:
        probs.append(f"{where}: focus didn't start ({cf} | {pf})")
    for a, b, what in ((cb, ca, "canvas"), (pb, pa, "page")):
        if drop(a, "words") != drop(b, "words"):
            probs.append(f"{where}: the {what} isn't as it was after leaving: {a} → {b}")
    for s, want, what in ((cf, facts.get("canvasCount"), "canvas"), (pf, facts.get("pageCount"), "page")):
        m = re.search(r"words=(\d+)", s)
        got = f"{m.group(1)} word{'s' if m and m.group(1) != '1' else ''}" if m else "?"
        if got != want:
            probs.append(f"{where}: the {what}'s word count {got}, the web's {want}")
    if "focus=False" not in mp or "Focus mode is for notes you write on the page" not in log:
        probs.append(f"{where}: a mind map entered focus or said nothing ({mp})")
    # pictures: native's focus vs the web's; after leaving vs before
    for n in ("canvas-focus", "page-focus", "canvas-focus-strip"):
        if not (d / f"{n}.png").exists():
            probs.append(f"{where}: no picture {n}")
            continue
        if ref is not None:
            s = ssim_files(d / f"{n}.png", ref / f"{n}.png")
            said.append(f"{n} {s:.3f}")
            if s < SSIM_FOCUS:
                probs.append(f"{where}: {n} SSIM {s:.3f} vs the web's < {SSIM_FOCUS}")
    for a, b in (("canvas-before", "canvas-after"), ("page-before", "page-after")):
        if (d / f"{a}.png").exists() and (d / f"{b}.png").exists():
            s = ssim_files(d / f"{a}.png", d / f"{b}.png")
            said.append(f"{a}→after {s:.4f}")
            if s < SSIM_SAME:
                probs.append(f"{where}: {b} differs from {a} (SSIM {s:.4f} < {SSIM_SAME})")
        else:
            probs.append(f"{where}: no {a}/{b} pictures")
    return probs, said


def m1():
    err = build_linux()
    if err:
        return "FAIL", err
    ref = web("focus")
    if isinstance(ref, str):
        return "FAIL", ref
    facts = json.loads((ref / "facts.json").read_text())
    panel = json.loads((ref / "panel.boxes.json").read_text())
    log, d = native("m1", ref / "pn.db", m1_steps(panel))
    probs, said = judge_focus(log, d, ref, facts, "Linux")
    # the geometry, read from what native drew: the canvas text's top 96 px down and centred (the boxes of the last frame are
    # the mind map's; the focus frame's are taken from a run that stops there)
    log2, d2 = native("m1-geom", ref / "pn.db", open_steps(panel, "Garden plan") + ["key:desk=ctrl+.", "wait:600"])
    try:
        bx = json.loads((d2 / "boxes.json").read_text())
        x, y, w, h = bx["focus.words"]
        said.append(f"words at {x:.1f},{y:.1f} {w:.0f}×{h:.0f}")
        if abs(y - 96) > TOP_TOL or abs(x + w / 2 - 720) > TOP_TOL:
            probs.append(f"Linux: the focused words at y {y:.1f} (want 96), centre {x + w / 2:.1f} (want 720)")
        if any(k.startswith("#toggle-sidebar") or k.startswith("#search-button") or k.startswith("[Canvas tools]") for k in bx):
            probs.append("Linux: chrome drawn in focus mode: " + ", ".join(k for k in bx if k.startswith("#") or k.startswith("["))[:200])
    except Exception as e:
        probs.append(f"Linux: no focus boxes ({e}): {tail(log2, 300)}")
    mac = m1_mac(ref, facts, panel)
    if probs:
        return "FAIL", "; ".join(probs)[:1500] + f" ({', '.join(said)})"
    if mac[0] != "PASS":
        return mac[0], f"Linux PASS ({', '.join(said)}); Mac: {mac[1]}"
    return "PASS", f"Linux: {', '.join(said)}; Mac: {mac[1]}; build/g82/native/m1/*.png vs build/g82/web-focus/"


def m1_mac(ref, facts, panel):
    if G79.mac_reachable():
        return "BLOCKED", "the Mac isn't reachable"
    steps = [s.replace("{out}", "{out}") for s in m1_steps(panel)]
    out, e = G79.mac_run("g82-m1", steps, {"PNOTE_DB": "{data}/pn.db", "PNOTE_SKIN": "paper", "OMX_CONFIG": "{data}/cfg-g82-m1-" + str(int(time.time()))}, [ref / "pn.db"])
    if e:
        return "BLOCKED", e
    st = states(out)
    if len(st) != 7:
        return "FAIL", f"{len(st)} PNOTE STATE lines: {tail(out, 500)}"
    probs, said = judge_focus(out, OUT / "native" / "nonexistent", None, facts, "Mac")
    probs = [p for p in probs if "no picture" not in p and "pictures" not in p]  # (the Mac's pictures come back in its report, judged by state here)
    return ("FAIL", "; ".join(probs)) if probs else ("PASS", "states equal after leaving, counts as the web's, a map refused")


# ---------------------------------------------------------------- M2: pictures

def make_pictures(d):
    """The test pictures (Pillow, the same every run): a, b kept as they came (a small PNG, a small JPEG); c a big opaque PNG
    (→ a 1400 JPEG); d a big see-through PNG (→ a 1400 PNG); a2, b2 for the paste and the picker; e an SVG (refused)."""
    d.mkdir(parents=True, exist_ok=True)
    y, x = np.mgrid[0:1600, 0:2400]
    photo = np.stack([(x * 255 / 2400), (y * 255 / 1600), ((x + y) % 256)], -1).astype(np.uint8)
    photo[200:900, 300:1300] = [200, 40, 40]
    Image.fromarray(photo[:200, :300]).save(d / "a.png")
    Image.fromarray(photo[400:700, 500:900]).save(d / "b.jpg", quality=90)
    Image.fromarray(photo).save(d / "c.png")
    rgba = np.dstack([photo[:1200, :1800], np.full((1200, 1800), 255, np.uint8)])
    rgba[:300, :300, 3] = 0
    Image.fromarray(rgba, "RGBA").save(d / "d.png")
    Image.fromarray(photo[800:960, 1000:1240]).save(d / "a2.png")
    Image.fromarray(photo[100:250, 1800:2100]).save(d / "b2.jpg", quality=85)
    (d / "e.svg").write_text("<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect width='10' height='10'/></svg>")
    return d


def sha(path):
    import hashlib
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def image_nodes(content):
    """A canvas document's picture nodes, in order: (file, x, y, width, height, scaleX)."""
    doc = json.loads(content) if isinstance(content, str) else content
    out = []
    for n in doc.get("nodes", []):
        pn = n.get("pn") or {}
        if n.get("type") == "file" and pn.get("type") == "image":
            g = pn.get("geometry") or {}
            out.append((n.get("file"), n.get("x"), n.get("y"), n.get("width"), n.get("height"), g.get("scaleX", 1)))
    return out


def native_note(db, title):
    import sqlite3
    c = sqlite3.connect(str(db))
    row = c.execute("select content from notes where title = ?", (title,)).fetchone()
    c.close()
    return row[0] if row else ""


def web_note_content(facts):
    n = facts.get("note") or {}
    c = n.get("content")
    return c if c is not None else n.get("note", {}).get("content", "{}")


def region_of(before, after):
    r = G79.changed_region(G79.grey(before), G79.grey(after))
    ys, xs = np.nonzero(r)
    if len(xs) == 0:
        return None
    return (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)


def m2():
    err = build_linux()
    if err:
        return "FAIL", err
    probs, said = [], []
    r = run(building(["pixi", "run", "mojo", "run", "-I", ".", "-I", "vendor", "tests/test_mediastore.mojo", str(OUT / "unit-media")]), 1800)
    if r.returncode != 0 or "test_mediastore: all passed" not in r.stdout:
        probs.append(f"tests/test_mediastore: {tail(r.stdout + r.stderr, 400)}")
    (OUT / "unit").mkdir(parents=True, exist_ok=True)
    r = run(building(["pixi", "run", "mojo", "run", "-I", ".", "tests/test_jpeg.mojo", str(OUT / "unit")]), 900)
    r2 = run(["pixi", "run", "python", "tests/test_jpeg.py", str(OUT / "unit")], 300)
    if r.returncode or r2.returncode:
        probs.append(f"tests/test_jpeg: {tail(r.stdout + r.stderr + r2.stdout, 400)}")
    pics = make_pictures(OUT / "pics")
    drop = [pics / n for n in ("a.png", "b.jpg", "c.png", "d.png")]
    ref = web("pictures", "--files=" + ",".join(str(p) for p in drop), "--expect=4")
    if isinstance(ref, str):
        return "FAIL", ref
    facts = json.loads((ref / "facts.json").read_text())
    wnodes = image_nodes(web_note_content(facts))
    wmedia = {m["name"]: m for m in facts.get("media", [])}
    panel = json.loads((web("focus") / "panel.boxes.json").read_text()) if not isinstance(web("focus"), str) else None
    if panel is None:
        return "FAIL", "no web boxes to reach the note"
    # the native app: one drop of four, a paste, the picker, an SVG; the flyout's Add image found first (its box is native's own)
    _, d0 = native("m2-boxes", ref / "pn.db", open_steps(panel, "Garden plan") + [f"tapat:desk={center(json.loads((web('focus') / 'canvas-before.boxes.json').read_text()), '#dock-more')}", "wait:500"])
    try:
        nb = json.loads((d0 / "boxes.json").read_text())
        add_image = center(nb, "[Add image]")
        dock_more = center(nb, "#dock-more")
    except Exception as e:
        return "FAIL", f"the dock's Add image wasn't drawn ({e})"
    steps = (open_steps(panel, "Garden plan") + ["gpushot:desk={out}/before.png", "dropfile:desk-drop=" + ",".join(str(p) for p in drop), "wait:6000",
             "key:desk=Escape", "wait:400", "gpushot:desk={out}/after-drop.png", f"clipboardimage:{pics / 'a2.png'}", "key:desk=ctrl+v", "wait:2500",
             f"tapat:desk={dock_more}", "wait:500", f"tapat:desk={add_image}", "wait:500", f"answer:{pics / 'b2.jpg'}", "wait:2500",
             f"dropfile:desk-drop={pics / 'e.svg'}", "wait:1500", "gpushot:desk={out}/after-all.png", "wait:1500"])
    log, d = native("m2", ref / "pn.db", steps, {"MOJOUI_ASK_DRY": "1"})
    placed = re.findall(r"^PNOTE PICTURE: (media/\S+) (\d+)x(\d+) (\d+) bytes", log, re.M)
    refused = re.findall(r"^PNOTE PICTURE: refused (\S+): (.*)$", log, re.M)
    said.append(f"{len(placed)} placed, {len(refused)} refused")
    if len(placed) != 6:
        probs.append(f"Linux: {len(placed)} pictures placed, want 6 (4 dropped, 1 pasted, 1 picked): {tail(log, 600)}")
    if not refused or not refused[0][0].endswith("e.svg") or "not a PNG, JPEG, WebP or GIF" not in refused[0][1]:
        probs.append(f"Linux: the SVG wasn't refused with the web's words ({refused})")
    if "ASK: pick" not in log or "PASTE: picture" not in log:
        probs.append("Linux: the picker or the paste wasn't used (no ASK: pick / PASTE: picture)")
    nnodes = image_nodes(native_note(d / "pn.db", "Garden plan"))
    media = d / "media"
    if len(nnodes) != 6:
        probs.append(f"Linux: the saved note holds {len(nnodes)} pictures, want 6")
    # the four dropped: names as the web's (a, b byte for byte), size and kind as the web's, placed as the web placed them
    for k, src in enumerate(drop):
        if k >= len(nnodes) or k >= len(wnodes):
            break
        nf, wf = nnodes[k][0], wnodes[k][0]
        if src.name in ("a.png", "b.jpg"):
            want = "media/" + sha(src) + "." + ("png" if src.suffix == ".png" else "jpg")
            if nf != want or wf != want:
                probs.append(f"{src.name}: native {nf}, web {wf}, want {want} (stored as it came)")
        else:
            if Path(nf).suffix != Path(wf).suffix or nnodes[k][3:5] != wnodes[k][3:5]:
                probs.append(f"{src.name}: native {nf} {nnodes[k][3:5]}, web {wf} {wnodes[k][3:5]} (kind and size as the web's)")
            nm, wm = media / Path(nf).name, ref / "media" / Path(wf).name
            if nm.exists() and wm.exists():
                a = np.asarray(Image.open(nm).convert("L"), dtype=np.float64)
                b = np.asarray(Image.open(wm).convert("L"), dtype=np.float64)
                sc = float(G79.ssim(a, b)) if a.shape == b.shape else -1
                said.append(f"{src.name} SSIM {sc:.3f}")
                if sc < SSIM_PICTURE:
                    probs.append(f"{src.name}: the stored picture vs the web's SSIM {sc:.3f} < {SSIM_PICTURE}")
            else:
                probs.append(f"{src.name}: a media file is missing ({nm.exists()}, {wm.exists()})")
        for i in (1, 2, 3, 4):
            if abs(float(nnodes[k][i]) - float(wnodes[k][i])) > 2:
                probs.append(f"{src.name}: placed at {nnodes[k][1:5]}, the web at {wnodes[k][1:5]}")
                break
        if abs(float(nnodes[k][5]) - float(wnodes[k][5])) > 1e-6:
            probs.append(f"{src.name}: scale {nnodes[k][5]}, the web's {wnodes[k][5]}")
        f = media / Path(nf).name
        if f.exists() and oct(f.stat().st_mode & 0o777) != "0o600":
            probs.append(f"{f.name}: mode {oct(f.stat().st_mode & 0o777)}, the web writes 0600")
    # (D-8513) pasted: what the clipboard hands back is the picture, not the file's bytes: the same pixels and size as a PNG;
    # picked: the file itself, byte for byte (the web's rule for a small picture)
    if len(nnodes) > 4:
        f = media / Path(nnodes[4][0]).name
        same = f.exists() and np.array_equal(np.asarray(Image.open(f).convert("RGBA")), np.asarray(Image.open(pics / "a2.png").convert("RGBA")))
        if not same or not nnodes[4][0].endswith(".png"):
            probs.append(f"a2.png (pasted): stored as {nnodes[4][0]}, pixels equal {same}")
    if len(nnodes) > 5 and nnodes[5][0] != "media/" + sha(pics / "b2.jpg") + ".jpg":
        probs.append(f"b2.jpg (picked): stored as {nnodes[5][0]}, want its own bytes' name")
    # both apps' pictures of the note, over the pictures' region: the web's own drop vs native's; then the web opening native's file
    reg = region_of(d / "before.png", d / "after-drop.png") if (d / "before.png").exists() and (d / "after-drop.png").exists() else None
    if reg is None:
        probs.append("Linux: the drop changed nothing on screen")
    else:
        sc = ssim_files(d / "after-drop.png", ref / "pictures-after.png", reg)
        said.append(f"drop vs web's drop SSIM {sc:.3f} over {reg}")
        if sc < SSIM_PICTURE:
            probs.append(f"the dropped pictures vs the web's SSIM {sc:.3f} < {SSIM_PICTURE} (build/g82/native/m2/after-drop.png, build/g82/web-pictures/pictures-after.png)")
        opened = web("open", f"--db={d / 'pn.db'}", "--note=Garden plan")
        if isinstance(opened, str):
            probs.append(f"the web couldn't open native's file: {opened}")
        else:
            ofacts = json.loads((opened / "facts.json").read_text())
            if len(image_nodes(web_note_content(ofacts))) != 6:
                probs.append(f"the web read {len(image_nodes(web_note_content(ofacts)))} pictures from native's file, want 6")
            import sqlite3
            con = sqlite3.connect(str(d / "pn.db"))
            gid = con.execute("select id from notes where title = 'Garden plan'").fetchone()[0]
            con.close()
            # (the notes list is in edit order: Garden plan moved to its top; the note is opened by its id at start)
            log3, d3 = native("m2-reopen", d / "pn.db", ["gpushot:desk={out}/first-frame.png", "wait:2500", "gpushot:desk={out}/reopen.png"], {"PNOTE_FIRST": str(gid)}, media=True)
            reg2 = region_of(d / "before.png", d / "after-all.png") or reg
            if (d3 / "reopen.png").exists():
                sc = ssim_files(d3 / "reopen.png", opened / "open.png", reg2)
                said.append(f"web opening native's file vs native SSIM {sc:.3f}")
                if sc < SSIM_PICTURE:
                    probs.append(f"the web showing native's note vs native's own SSIM {sc:.3f} < {SSIM_PICTURE} (build/g82/web-open/open.png, build/g82/native/m2-reopen/reopen.png)")
            else:
                probs.append(f"no reopen picture: {tail(log3, 300)}")
    mac = m2_mac(ref, panel, pics, add_image, dock_more)
    if probs:
        return "FAIL", "; ".join(probs)[:1800] + f" ({', '.join(said)})"
    if mac[0] != "PASS":
        return mac[0], f"Linux PASS ({', '.join(said)}); Mac: {mac[1]}"
    return "PASS", f"Linux: {', '.join(said)}; Mac: {mac[1]}"


def m2_mac(ref, panel, pics, add_image, dock_more):
    if G79.mac_reachable():
        return "BLOCKED", "the Mac isn't reachable"
    steps = (["window:1440x900", "wait:600"] + open_steps(panel, "Garden plan") + ["clipboardimage:{data}/a2.png", "key:desk=Escape", "key:desk=ctrl+v", "wait:2500",
             f"tapat:desk={dock_more}", "wait:500", f"tapat:desk={add_image}", "wait:500", "answer:{data}/b2.jpg", "wait:2500",
             "answer:{data}/e.svg", "wait:1500", "wait:1500"])
    out, e = G79.mac_run("g82-m2", steps, {"PNOTE_DB": "{data}/pn.db", "PNOTE_SKIN": "paper", "MOJOUI_ASK_DRY": "1", "OMX_CONFIG": "{data}/cfg-g82-m2-" + str(int(time.time()))},
                         [ref / "pn.db", pics / "a2.png", pics / "b2.jpg", pics / "e.svg"])
    if e:
        return "BLOCKED", e
    placed = re.findall(r"^PNOTE PICTURE: (media/\S+) (\d+)x(\d+)", out, re.M)
    want_b2 = "media/" + sha(pics / "b2.jpg") + ".jpg"
    if len(placed) != 2 or not placed[0][0].endswith(".png") or placed[0][1:] != ("240", "160") or placed[1][0] != want_b2:
        return "FAIL", f"placed {placed}, want a 240x160 PNG (pasted) then {want_b2} (picked): {tail(out, 400)}"
    if "PASTE: picture" not in out or "ASK: pick" not in out or "refused" not in out:
        return "FAIL", f"paste/picker/refusal not seen: {tail(out, 400)}"
    return "PASS", "a pasted picture (a 240x160 PNG of its pixels) and a picked one under its own bytes' name, the SVG refused"


# ---------------------------------------------------------------- M4: print and export

def m4():
    err = build_linux()
    if err:
        return "FAIL", err
    probs, said = [], []
    unit = OUT / "unit-pdf"
    unit.mkdir(parents=True, exist_ok=True)
    r = run(building(["pixi", "run", "mojo", "run", "-I", ".", "-I", "vendor", "tests/test_pdfwriter.mojo", str(unit)]), 1800)
    r2 = run(["pixi", "run", "python", "tests/test_pdfwriter.py", str(unit)], 300)
    if r.returncode or r2.returncode:
        probs.append(f"tests/test_pdfwriter: {tail(r.stdout + r.stderr + r2.stdout, 500)}")
    ref = web("print")
    if isinstance(ref, str):
        return "FAIL", ref
    facts = json.loads((ref / "facts.json").read_text())
    panel = json.loads((web("focus") / "panel.boxes.json").read_text())
    card = json.loads((ref / "card.boxes.json").read_text())
    canvas = json.loads((ref / "canvas.boxes.json").read_text())
    title = center(canvas, "#island-title")
    steps = (open_steps(panel, "Garden plan") + [f"tapat:desk={title}", "wait:600", f"tapat:desk={center(card, '#share-print')}", "wait:2000",
             f"tapat:desk={title}", "wait:600", f"tapat:desk={center(card, '#share-png')}", "wait:800", "answer:{out}/picture.png", "wait:2500",
             "appbench:desk=exportpdf", "wait:500", "answer:{out}/export.pdf", "wait:2000", "appbench:desk=share", "wait:1500"])
    log, d = native("m4", ref / "pn.db", steps, {"MOJOUI_ASK_DRY": "1"})
    m = re.search(r"^PNOTE PDF: (\S+) pages (\d+)", log, re.M)
    if not m or "ASK: print" not in log:
        probs.append(f"Linux: Print made no PDF or asked for no print dialog: {tail(log, 500)}")
    pdfs = [Path(m.group(1))] if m else []
    if (d / "export.pdf").exists():
        pdfs.append(d / "export.pdf")
    else:
        probs.append("Linux: Export PDF wrote nothing at the save dialog's path")
    if "ASK: share" not in log:
        probs.append("Linux: Share asked for nothing")
    cols, rows = [int(v) for v in re.findall(r"\d+", facts.get("layout", "1 x 1"))[:2]] or [1, 1]
    for pdf in pdfs:
        info = run(["pdfinfo", str(pdf)], 60).stdout
        pages = int(re.search(r"Pages:\s+(\d+)", info).group(1)) if re.search(r"Pages:\s+(\d+)", info) else -1
        if pages != cols * rows or "645 x 810 pts" not in info:
            probs.append(f"{pdf.name}: {pages} pages ({info.split('Page size:')[-1].split(chr(10))[0].strip()}), want {cols * rows} of 645 x 810 pts")
        text = run(["pdftotext", str(pdf), "-"], 60).stdout
        for words in ("Garden plan", "Beds by the south wall", "Tomatoes", "Marigolds", "Water every"):
            if words not in " ".join(text.split()):
                probs.append(f"{pdf.name}: pdftotext doesn't find {words!r} ({' '.join(text.split())[:120]!r})")
        if run(["qpdf", "--check", str(pdf)], 60).returncode != 0:
            probs.append(f"{pdf.name}: qpdf --check fails")
    if pdfs and (ref / "sheet-1.png").exists():
        run(["pdftoppm", "-r", "192", "-png", "-f", "1", "-l", "1", str(pdfs[0]), str(d / "sheet")], 120)
        got = next(iter(sorted(d.glob("sheet-*1.png"))), None)
        if got:
            a, b = G79.grey(got), G79.grey(ref / "sheet-1.png")
            if a.shape == b.shape:
                sc = float(G79.ssim(a, b))
                said.append(f"PDF page 1 vs the web's sheet SSIM {sc:.3f} (shadows aren't printed)")
                if sc < 0.90:
                    probs.append(f"the PDF's first page vs the web's print sheet SSIM {sc:.3f} < 0.90")
            else:
                probs.append(f"the PDF's page rasterized {a.shape}, the web's sheet {b.shape}")
    if (d / "picture.png").exists() and (ref / "picture.png").exists():
        sc = ssim_files(d / "picture.png", ref / "picture.png")
        said.append(f"Picture vs the web's SSIM {sc:.3f}")
        if sc < SSIM_PICTURE:
            probs.append(f"the Picture vs the web's SSIM {sc:.3f} < {SSIM_PICTURE} (sizes {Image.open(d / 'picture.png').size} vs {Image.open(ref / 'picture.png').size})")
    else:
        probs.append(f"no Picture to compare (native {(d / 'picture.png').exists()}, web {(ref / 'picture.png').exists()})")
    # the dialogs themselves, opened for real on the hidden screen (in our process: no portal) and closed
    steps2 = (open_steps(panel, "Garden plan") + [f"tapat:desk={title}", "wait:600", f"tapat:desk={center(card, '#share-print')}", "wait:3000", "windows:", "closedialogs:", "wait:1500",
              f"tapat:desk={title}", "wait:600", f"tapat:desk={center(card, '#share-png')}", "wait:2500", "windows:", "closedialogs:", "wait:800"])
    log2, _ = native("m4-dialogs", ref / "pn.db", steps2, {"GDK_DEBUG": "no-portals"})
    wins = re.findall(r"^WINDOWS: (.*)$", log2, re.M)
    said.append("dialogs: " + " / ".join(wins))
    if len(wins) != 2 or "|" not in wins[0] or "Save the note as a picture" not in wins[1]:
        probs.append(f"Linux: the print and save dialogs weren't seen open ({wins})")
    if "PRINTED: cancelled" not in log2:
        probs.append(f"Linux: the print dialog closed without its answer: {tail(log2, 300)}")
    mac = m4_mac(ref, panel, card, title)
    if probs:
        return "FAIL", "; ".join(probs)[:1800] + f" ({', '.join(said)})"
    if mac[0] != "PASS":
        return mac[0], f"Linux PASS ({', '.join(said)}); Mac: {mac[1]}"
    return "PASS", f"Linux: {', '.join(said)}; Mac: {mac[1]}"


def m4_mac(ref, panel, card, title):
    if G79.mac_reachable():
        return "BLOCKED", "the Mac isn't reachable"
    steps = (["window:1440x900", "wait:600"] + open_steps(panel, "Garden plan") + [f"tapat:desk={title}", "wait:600", f"tapat:desk={center(card, '#share-print')}", "wait:6000",
             f"tapat:desk={title}", "wait:600", f"tapat:desk={center(card, '#share-png')}", "wait:6000", "appbench:desk=share", "wait:3000"])
    out, e = G79.mac_run("g82-m4", steps, {"PNOTE_DB": "{data}/pn.db", "PNOTE_SKIN": "paper", "MOJOUI_ASK_CLOSE_MS": "2500", "OMX_CONFIG": "{data}/cfg-g82-m4-" + str(int(time.time()))}, [ref / "pn.db"])
    if e:
        return "BLOCKED", e
    probs = []
    m = re.search(r"^PNOTE PDF: \S+ pages (\d+) runs (\d+)", out, re.M)
    if not m or int(m.group(2)) == 0:
        probs.append("no PDF with words")
    wins = re.findall(r"^WINDOWS: (.*)$", out, re.M)
    if len(wins) < 2:
        probs.append(f"the print panel and the save panel weren't seen ({wins})")
    if "PRINTED: cancelled" not in out:
        probs.append("the print panel gave no answer")
    if "SHARE: shown" not in out:
        probs.append("the share picker wasn't shown")
    if probs:
        return "FAIL", "; ".join(probs) + ": " + tail(out, 400)
    return "PASS", "PDF made, " + " / ".join(wins) + ", share picker shown"


# ---------------------------------------------------------------- typing guard: pnote's typing rows, this branch vs its base

BASE = "ad48b5f3"  # (the merged 79+80+81+main base goal 82 A starts from)
TYPE_ROWS = ["wait:800", "window:1440x900", "wait:1500", "appbench:desk=zoom100", "framebench:desk=typing,80"]
PAGE_ROWS = ["wait:800", "window:1440x900", "wait:1500", "framebench:desk=typing,80"]
RACE_DBS = [Path(os.path.expanduser("~/.abode/home/worktrees/mojo-ui/t3-82ec4fed-0290b79296d08c87/build/g79/race")), ROOT / "build" / "g79" / "race"]


def base_app():
    """pnote built from BASE in a worktree of its own (the scratch folder; its env linked as this one's): the 'before' of the guard."""
    wt = OUT / "base-wt"
    app = wt / "build" / "pnote" / "linux" / "pnote"
    if app.exists():
        return app, ""
    if not wt.exists():
        r = run(["git", "worktree", "add", "--detach", str(wt), BASE], 300)
        if r.returncode:
            return None, f"git worktree add: {tail(r.stdout + r.stderr)}"
        os.symlink(os.readlink(ROOT / ".pixi") if (ROOT / ".pixi").is_symlink() else str(ROOT / ".pixi"), wt / ".pixi")
    r = run(building(["bash", "scripts/build.sh", "pnote", "linux"]), 3600, cwd=wt)
    return (app, "") if app.exists() else (None, f"base build: {tail(r.stdout + r.stderr, 500)}")


def typing_run(app, db, steps, warm=True):
    cfg = OUT / "typing" / f"cfg-{int(time.time() * 1000)}"
    cfg.mkdir(parents=True)
    shutil.copy(db, cfg / "pn.db")
    env = dict(os.environ, PNOTE_DIR=str(cfg), OMX_CONFIG=str(cfg), PNOTE_DB=str(cfg / "pn.db"), MOJOUI_BENCH_PACED="1", MOJOUI_TEST=";".join(steps), MOJOUI_SHOT="")
    if not warm:
        env.update(MOJOUI_SCENEWARM="0", MOJOUI_GLYPHWARM="0")
    G79.linux_quiet("typing")
    r = run(quiet(["scripts/testscreen", str(app)]), 900, env=env)
    shutil.rmtree(cfg, ignore_errors=True)
    return G79.native_race(r.stdout + r.stderr).get("typing") or {}


def typing():
    err = build_linux()
    if err:
        return "FAIL", err
    base, why = base_app()
    if base is None:
        return "BLOCKED", why
    race = next((d for d in RACE_DBS if (d / "race-stress.db").exists()), None)
    if race is None:
        return "BLOCKED", "no goal-79 race notes (race-600/stress/page.db) to type in"
    rows = [("600", "race-600.db", TYPE_ROWS, True), ("600 not warmed", "race-600.db", TYPE_ROWS, False), ("stress", "race-stress.db", TYPE_ROWS, True),
            ("stress not warmed", "race-stress.db", TYPE_ROWS, False), ("page 20,000 chars", "race-page.db", PAGE_ROWS, True)]
    table, worse = [], []
    for name, db, steps, warm in rows:
        got = {"base": [], "goal-82-a": []}
        for _ in range(3):  # (alternated, three each: the middle run is judged)
            for side, app in (("base", base), ("goal-82-a", APP)):
                got[side].append(typing_run(app, race / db, steps, warm))
        med = {}
        for side in got:
            vals = {k: sorted(r.get(k, 0.0) for r in got[side]) for k in ("p95", "max", "lat_p95", "lat_max")}
            med[side] = {k: v[1] for k, v in vals.items()}
        line = f"{name}: frames p95/max {med['base']['p95']:.1f}/{med['base']['max']:.1f} → {med['goal-82-a']['p95']:.1f}/{med['goal-82-a']['max']:.1f}; key to paint {med['base']['lat_p95']:.1f}/{med['base']['lat_max']:.1f} → {med['goal-82-a']['lat_p95']:.1f}/{med['goal-82-a']['lat_max']:.1f}"
        table.append(line)
        print("  " + line, flush=True)
        for k in ("p95", "max", "lat_p95", "lat_max"):
            a, b = med["base"][k], med["goal-82-a"][k]
            if a > 0 and b > a * 1.03:
                worse.append(f"{name} {k} {a:.1f} → {b:.1f} (+{(b / a - 1) * 100:.1f} %)")
    (OUT / "typing.md").write_text("# Goal 82 A: typing rows, base vs goal-82-a (middle of 3 alternated runs each)\n\n" + "\n".join("- " + t for t in table) + "\n\nWorse by more than 3 %: " + ("; ".join(worse) or "none") + "\n")
    return ("FAIL" if worse else "PASS"), ("worse than 3 %: " + "; ".join(worse) if worse else "no row worse than 3 %") + "; build/g82/typing.md"


CHECKS = {"M1": m1, "M2": m2, "M4": m4, "TYPING": typing}

if __name__ == "__main__":
    want = sys.argv[1:] or list(CHECKS)
    bad = False
    for k in want:
        try:
            verdict, why = CHECKS[k]()
        except NotFree as e:
            verdict, why = "BLOCKED", f"the machine wasn't free for a GPU window ({e}); run again when it is"
        except Exception as e:
            import traceback
            traceback.print_exc()
            verdict, why = "FAIL", f"{type(e).__name__}: {e}"
        print(f"{k}: {verdict}  {why}", flush=True)
        bad = bad or verdict == "FAIL"
    sys.exit(1 if bad else 0)
