"""Goal 77 M7f: the slow half of the proof, with the real model on the GPUs (tens of minutes). It runs goal 72's M3-M6 and goal
77's M1-M6 exactly as their checkers do (their own commands, their output kept), then omx's Stage pictures at 1280x820 and
390x844, light and dark (home with tiles; the TV open with a card; a point landing), and writes what happened to
build/g77/m7f/results.json with a fingerprint of every file the runs depend on. docs/goals/77-stage-check.py m7f() reads that
file and refuses it when the fingerprint no longer matches the tree (an edit since the run) or any line isn't PASS.

    CUDA_DEVICE_ORDER=PCI_BUS_ID pixi run python scripts/g77_m7f_run.py [g72] [g77] [shots]     (default: all three)
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build/g77/m7f"
SHOTS = ROOT / "docs/goals/77"
# what the runs depend on: the framework, the app, the themes, the hosts, the checkers and the scripts they drive
DEPENDS = ["mojoui", "examples/omx", "themes", "hosts", "bridge", "scripts", "tests", "docs/goals/72-check.py", "docs/goals/77-check.py",
           "docs/goals/33-check.py", "pixi.toml", "pixi.lock"]
ASK = "Show me the word ephemeral as a card, then walk me through it: the word, what it means, and an example."
TEAL = {False: (14, 124, 134), True: (60, 196, 207)}  # the ring (the Counter family's teal, as goal 77's ring proofs read it)


def fingerprint():
    """A hash of every file under DEPENDS that git tracks or would track (untracked but not ignored ones too), as it is on disk
    now: commits don't change it, an edit or a new file does."""
    listed = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "--", *DEPENDS], cwd=ROOT, capture_output=True, text=True).stdout.split("\n")
    h = hashlib.sha256()
    for f in sorted(set(x for x in listed if x and x != "scripts/g77_m7f_run.py")):  # (this file measures the pictures: its own hash, below)
        p = ROOT / f
        h.update(f.encode() + b"\0")
        h.update(p.read_bytes() if p.is_file() else b"(gone)")
    return h.hexdigest()[:16]


def runner_hash():
    """This file's own hash: the pictures part is measured by it, so that part (only) is stale when it changes."""
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()[:16]


def checker(script, names, timeout):
    """One goal's checker on these milestones: its lines "Mn: STATE  why" as {Mn: [state, why]} and the whole output saved."""
    env = dict(os.environ, CUDA_DEVICE_ORDER="PCI_BUS_ID")
    t0 = time.time()
    r = subprocess.run(["pixi", "run", "python", script, *names], cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    tag = Path(script).stem.split("-")[0]
    (OUT / f"g{tag}-output.txt").write_text(r.stdout + "\n--- stderr ---\n" + r.stderr[-20000:])
    got = {}
    for line in r.stdout.splitlines():
        m = re.match(r"^(M\d+[A-Z]?):\s+(PASS|FAIL|BLOCKED)\s*(.*)$", line)
        if m:
            got[m.group(1)] = [m.group(2), m.group(3)]
    for n in names:
        got.setdefault(n, ["FAIL", f"the checker printed no line for {n} (exit {r.returncode}): " + (r.stdout + r.stderr)[-400:]])
    return {"lines": got, "seconds": round(time.time() - t0)}


def near_teal(c, dark):
    return sum(abs(a - b) for a, b in zip(c, TEAL[dark])) < 90


def ring_band(png, after, rect, dark):
    """The ring's own pixels round `rect` (x, y, w, h: the app's OMX POINT ring=, in the window's points): teal pixels in the band
    from 3 pt inside the rect to 16 pt outside it that aren't teal in `after` (the same screen once the ring has faded)."""
    from PIL import Image
    im, ref = Image.open(png).convert("RGB"), Image.open(after).convert("RGB")
    px, rp = im.load(), ref.load()
    x, y, w, h = rect
    n = 0
    for yy in range(max(0, y - 16), min(im.height, y + h + 16)):
        for xx in range(max(0, x - 16), min(im.width, x + w + 16)):
            if x + 3 <= xx < x + w - 3 and y + 3 <= yy < y + h - 3:
                continue
            if near_teal(px[xx, yy], dark) and not near_teal(rp[xx, yy], dark):
                n += 1
    return n


def regions(path):
    return {r["name"]: r for r in json.loads(Path(path).read_text())} if Path(path).exists() else {}


def busy_share(png, r, ground):
    """How much of region r in the picture isn't the flat ground colour (tiles drawn on the stage, a card in the TV)."""
    from PIL import Image
    im = Image.open(png).convert("RGB")
    px = im.load()
    n = hit = 0  # (within the picture: a phone's page scrolls, so a region can run past the window's bottom)
    for yy in range(max(int(r["y"]) + 20, 0), min(int(r["y"] + r["h"]) - 20, im.height), 3):
        for xx in range(max(int(r["x"]) + 20, 0), min(int(r["x"] + r["w"]) - 20, im.width), 3):
            n += 1
            hit += sum(abs(a - b) for a, b in zip(px[xx, yy], ground)) > 12
    return round(hit / max(n, 1), 3)


GROUND = {False: (245, 245, 247), True: (0, 0, 0)}  # the stage's own ground (--oq-counter-ground)


def shots():
    """omx on GTK (the headless display) with the real model, once per size and scheme: home, then a typed question that shows a
    Word card and walks through it (the TV opens, the ring lands on its parts); pictures picked and copied to docs/goals/77."""
    sys.path.insert(0, str(ROOT / "docs/goals"))
    import importlib.util
    spec = importlib.util.spec_from_file_location("g72check", ROOT / "docs/goals/72-check.py")
    g72 = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g72)
    g72.ensure_wavs()
    out = []
    for size, window in (("desktop", "1280x820"), ("phone", "390x844")):
        for dark in (False, True):
            name = f"{size}-{'dark' if dark else 'light'}"
            for f in OUT.glob(f"shot-{name}-*.png"):
                f.unlink()
            todo = OUT / "todo.json"
            todo.write_text('{"items":[{"text":"buy milk","done":false},{"text":"call mum","done":false},{"text":"book the dentist","done":false}]}')
            steps = (f"waitfor:Listening=300000;" + ("scheme:dark;" if dark else "") + f"wait:2500;regions:{OUT}/shot-{name}-home.json;shot:{OUT}/shot-{name}-home.png;wait:200;"
                     + f"tap:Type;wait:500;enter:Type to omx={ASK};waitfor:meaning=120000;"
                     + "".join(f"shot:{OUT}/shot-{name}-p{k:02d}.png;wait:120;" for k in range(16))
                     + f"waitfor:Listening=170000;wait:6000;regions:{OUT}/shot-{name}-tv.json;shot:{OUT}/shot-{name}-tv.png;wait:200")
            with g72.NullSink():
                ev, r = g72.run_app(g72.SILENT, steps, window=window, env={"OMX_LLM_CTX": "32768", "MOJOUI_TODO": str(todo)}, timeout=900)
            (OUT / f"shot-{name}.log").write_text(r.stdout[-30000:])
            cards = [e for e in ev if e["kind"] == "CARD"]
            points = [e for e in ev if e["kind"] == "POINT"]
            stage = [e for e in ev if e["kind"] == "STAGE"]
            after = OUT / f"shot-{name}-tv.png"
            frames = sorted(OUT.glob(f"shot-{name}-p*.png"))
            rects = []
            for e in points:
                m = re.match(r"(-?\d+),(-?\d+),(\d+),(\d+)$", str(e.get("ring", "")))
                if m:
                    rects.append((e.get("tag"), tuple(int(v) for v in m.groups())))
            best, best_n, best_tag = None, 0, None
            if after.exists():
                for f in frames:
                    for tag, rect in rects:
                        n = ring_band(f, after, rect, dark)
                        if n > best_n:
                            best, best_n, best_tag = f, n, tag
            home_rg, tv_rg = regions(OUT / f"shot-{name}-home.json"), regions(OUT / f"shot-{name}-tv.json")
            home_png = OUT / f"shot-{name}-home.png"
            row = {"name": name, "window": window, "dark": dark, "cards": [c.get("shape") for c in cards], "points": [p.get("tag") for p in points],
                   "ring_pixels": best_n, "ring_on": best_tag,
                   "home_stage": stage[0]["raw"] if stage else "", "home_regions": sorted(home_rg),
                   "home_panel_busy": busy_share(home_png, home_rg["stage-panel"], GROUND[dark]) if "stage-panel" in home_rg and home_png.exists() else 0,
                   "tv_regions": sorted(tv_rg),
                   "tv_card_busy": busy_share(after, tv_rg["stage-tv-card"], GROUND[dark]) if "stage-tv-card" in tv_rg and after.exists() else 0,
                   "tv_card_in_tv": bool("stage-tv" in tv_rg and "stage-tv-card" in tv_rg and tv_rg["stage-tv"]["x"] <= tv_rg["stage-tv-card"]["x"]
                                         and tv_rg["stage-tv-card"]["y"] + tv_rg["stage-tv-card"]["h"] <= tv_rg["stage-tv"]["y"] + tv_rg["stage-tv"]["h"] + 1),
                   "pictures": {}}
            for kind, src in (("home", home_png), ("tv", after), ("point", best)):
                if src and Path(src).exists():
                    dst = SHOTS / f"m7f-{name}-{kind}.png"
                    shutil.copy(src, dst)
                    row["pictures"][kind] = str(dst.relative_to(ROOT))
            out.append(row)
            print(json.dumps(row), flush=True)
    return out


def main():
    want = set(sys.argv[1:]) or {"g72", "g77", "shots"}
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / "results.json"
    res = json.loads(path.read_text()) if path.exists() else {}
    res["fingerprint_at_start"] = fingerprint()
    res["started"] = time.strftime("%Y-%m-%d %H:%M:%S")
    if "g72" in want:
        res["g72"] = checker("docs/goals/72-check.py", ["M3", "M4", "M5", "M6"], 4 * 3600)
        res["g72"]["fingerprint"] = res["fingerprint_at_start"]
        path.write_text(json.dumps(res, indent=1))
        print("g72:", json.dumps(res["g72"]["lines"]), flush=True)
    if "g77" in want:
        res["g77"] = checker("docs/goals/77-check.py", ["M1", "M2", "M3", "M4", "M5", "M6"], 4 * 3600)
        res["g77"]["fingerprint"] = res["fingerprint_at_start"]
        path.write_text(json.dumps(res, indent=1))
        print("g77:", json.dumps(res["g77"]["lines"]), flush=True)
    if "shots" in want:
        res["shots"] = {"rows": shots(), "fingerprint": res["fingerprint_at_start"], "runner": runner_hash()}
    res["fingerprint_at_end"] = fingerprint()
    res["finished"] = time.strftime("%Y-%m-%d %H:%M:%S")
    path.write_text(json.dumps(res, indent=1))
    print("m7f run: written", path, flush=True)


if __name__ == "__main__":
    main()
