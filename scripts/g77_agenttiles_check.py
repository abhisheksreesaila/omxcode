"""Goal 77 M7c's proof: agent-driven live tiles (GOAL.md M7c). Run by docs/goals/77-stage-check.py m7c(), or alone:

    pixi run python scripts/g77_agenttiles_check.py

No model: a scripted stand-in agent (examples/agenttiles: a LocalAgent answering each RunAgentInput with AG-UI events) goes through
the real client loop (mojoui.agui.Agent.run_local, mojoui.agentui.Screens).
1. tests/test_genui_tiles.mojo: genui validates LiveTiles' sample and refuses bad tiles (a duplicate id, a bad id, no faces, a bad
   kind, no centre tile, too many actions, ...) with a reason the agent can act on; the card draws, its tiles are pointer parts.
   tests/test_tiles_agent.mojo: the patch path (Screens.patch, CUSTOM ui_patch: validated again, a bad patch changes nothing) and the
   tiles tool's ops (promote, promote big, add, set_face, remove, refusals); 2-6 tiles promoted: first, large, 0 holes.
2. examples/agenttiles built for Linux and the web.
3. GTK (headless Xvfb) and the web host (headless Chromium), 1280 x 820: "What matters this morning?" -> render_ui shows a LiveTiles
   card (traffic first); "Rain at pickup" -> the tiles tool promotes weather (it is the first, large tile; the grid stays full: 0 holes);
   the agent then sends a CUSTOM point naming the weather tile and the pointer's ring lands on it: the ring's rect (from the springs
   it is painted with) inside the tile's rect (its canvas's rect plus the layout's cell) within 3 pt, IoU >= 0.9; on GTK also by the
   ring's own pixels: the centre of what a screenshot while it shows differs from one after it faded lies inside the tile.
4. Pictures: docs/goals/77/m7c-gtk-morning.png, m7c-gtk-point.png, m7c-web-point.png.
Returns ("PASS" | "FAIL" | "BLOCKED", why).
"""
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build/g77/m7c"
SHOTS = ROOT / "docs/goals/77"
sys.path.insert(0, str(ROOT / "scripts"))
TOL = 3.0


def sh(cmd, timeout=1800, env=None):
    e = dict(os.environ)
    e.update(env or {})
    return subprocess.run(cmd, cwd=ROOT, env=e, capture_output=True, text=True, timeout=timeout)


def tail(r, n=700):
    return (r.stdout + r.stderr)[-n:]


def rect(text):
    return [float(v) for v in text.split(",")]


def iou(a, b):
    x0, y0 = max(a[0], b[0]), max(a[1], b[1])
    x1, y1 = min(a[0] + a[2], b[0] + b[2]), min(a[1] + a[3], b[1] + b[3])
    inter = max(0, x1 - x0) * max(0, y1 - y0)
    return inter / (a[2] * a[3] + b[2] * b[3] - inter)


def read_run(host, text, probs):
    """The app's TILES lines: shown, the layouts, the tool's patch, the point. Returns the numbers for the report."""
    got = {}
    shown = re.search(r"^TILES SHOWN: card=(\S+) shape=(\S+) problem=(.*)$", text, re.M)
    if not shown or shown.group(3).strip() or "LiveTiles" not in shown.group(2):
        probs.append(f"{host}: render_ui's LiveTiles card not shown ({shown.group(0) if shown else 'no TILES SHOWN line'})")
        return got
    got["card"] = shown.group(1)
    lays = re.findall(r"^TILES LAYOUT: card=\S+ ids=(\S+) holes=(\d+)$", text, re.M)
    if len(lays) < 2:
        probs.append(f"{host}: {len(lays)} TILES LAYOUT lines (want one per turn)")
        return got
    before, after = lays[0], lays[-1]
    if not before[0].startswith("traffic:"):
        probs.append(f"{host}: the morning's first tile is {before[0].split(',')[0]} (want traffic)")
    tool = re.search(r"^TILES: card=\S+ op=promote order=(\S+) first=(\S+) size=(\S+) holes=(\d+)$", text, re.M)
    if not tool:
        probs.append(f"{host}: the tiles tool's promote didn't apply: " + " | ".join(re.findall(r"^TILES: .*$", text, re.M)))
        return got
    first = after[0].split(",")[0]
    n_tiles = len(after[0].split(","))
    if first not in ("weather:l", "weather:xl") or after[1] != "0" or tool.group(2) != "weather":
        probs.append(f"{host}: after the promote the grid is {after[0]} with {after[1]} holes (want weather first and large, 0 holes)")
    got.update(before=before[0], after=after[0], holes=int(after[1]), n=n_tiles)
    pt = re.search(r"^TILES POINT: tag=(\S+) ring=(\S+) tile=(\S+) canvas=(\S+) layout=(\S+) holes=(\d+)$", text, re.M)
    if not pt:
        probs.append(f"{host}: no TILES POINT line (the ring never settled on a tile): " + " | ".join(re.findall(r"^TILES POINT.*$", text, re.M)))
        return got
    tag, ring, tile = pt.group(1), rect(pt.group(2)), rect(pt.group(3))
    if tag != got["card"] + ".weather":
        probs.append(f"{host}: the point went to {tag} (want {got['card']}.weather)")
    inside = (ring[0] >= tile[0] - TOL and ring[1] >= tile[1] - TOL and ring[0] + ring[2] <= tile[0] + tile[2] + TOL
              and ring[1] + ring[3] <= tile[1] + tile[3] + TOL)
    q = iou(ring, tile)
    if not inside or q < 0.9:
        probs.append(f"{host}: the ring {pt.group(2)} is not on the weather tile {pt.group(3)} (IoU {q:.3f})")
    got.update(tag=tag, ring=pt.group(2), tile=pt.group(3), iou=round(q, 3))
    return got


def ring_pixels(with_ring, without, tile):
    """The centre of what differs between a picture while the ring shows and one after it faded (window pixels = points here)."""
    from PIL import Image, ImageChops
    a = Image.open(with_ring).convert("RGB")
    b = Image.open(without).convert("RGB")
    d = ImageChops.difference(a, b).convert("L").point(lambda v: 255 if v > 24 else 0)
    box = d.getbbox()
    if not box:
        return None, 0, None
    px = d.load()
    sx = sy = n = 0
    for y in range(box[1], box[3]):
        for x in range(box[0], box[2]):
            if px[x, y]:
                sx += x
                sy += y
                n += 1
    return (sx / n, sy / n), n, box


def check_gtk(said, probs):
    import headless
    headless.ensure()
    for f in ("gtk-morning.png", "gtk-point.png", "gtk-faded.png"):
        (OUT / f).unlink(missing_ok=True)
    steps = (f"wait:900;tap:What matters this morning?;wait:1500;shot:{OUT}/gtk-morning.png;tap:Rain at pickup;"
             f"shot:{OUT}/gtk-point.png;wait:7500;shot:{OUT}/gtk-faded.png;wait:200")
    r = sh([str(ROOT / "build/agenttiles/linux/agenttiles")], 240, {"MOJOUI_TEST": steps})
    (OUT / "gtk.txt").write_text(r.stdout + r.stderr)
    if r.returncode:
        probs.append(f"GTK: exit {r.returncode}: {tail(r)}")
        return
    got = read_run("GTK", r.stdout, probs)
    if "tile" in got and (OUT / "gtk-point.png").exists() and (OUT / "gtk-faded.png").exists():
        c, n, box = ring_pixels(OUT / "gtk-point.png", OUT / "gtk-faded.png", rect(got["tile"]))
        t = rect(got["tile"])
        reach = 24  # (the ring's gap 5 + glow 9 + its width, and the pointed tile's 2.5 % lift)
        if (c is None or not (t[0] <= c[0] <= t[0] + t[2] and t[1] <= c[1] <= t[1] + t[3]) or n < 1500
                or not (box[0] >= t[0] - reach and box[1] >= t[1] - reach and box[2] <= t[0] + t[2] + reach and box[3] <= t[1] + t[3] + reach)):
            probs.append(f"GTK: the ring's pixels ({n} changed, centre {c}, within {box}) are not round the weather tile {got['tile']} only")
        else:
            got["pixels"] = f"{n} px changed, all within {box[0]},{box[1]}..{box[2]},{box[3]}, centre {c[0]:.0f},{c[1]:.0f}"
        shutil.copy(OUT / "gtk-morning.png", SHOTS / "m7c-gtk-morning.png")
        shutil.copy(OUT / "gtk-point.png", SHOTS / "m7c-gtk-point.png")
    if "iou" in got:
        said.append(f"GTK: {got['before'].split(',')[0]} first -> promote -> {got['after']} ({got['holes']} holes), ring {got['ring']} on tile {got['tile']} "
                    f"(IoU {got['iou']}; ring pixels {got.get('pixels', '-')})")


def check_web(said, probs):
    import drive
    from playwright.sync_api import sync_playwright
    port = drive.free_port()
    server = subprocess.Popen([sys.executable, str(ROOT / "mojoui/hosts/web.py"), str(ROOT / "build/agenttiles/web"), str(port)],
                              cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = []
    reader = threading.Thread(target=lambda: lines.extend(iter(server.stdout.readline, "")), daemon=True)
    reader.start()
    errors = []
    try:
        for _ in range(900):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/static/htmx.min.js", timeout=1)
                break
            except OSError:
                if server.poll() is not None:
                    probs.append("web: the server died: " + "".join(lines)[-500:])
                    return
                time.sleep(0.1)
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path=drive.CHROMIUM, headless=True)
            page = browser.new_page(viewport={"width": 1280, "height": 820})
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.goto(f"http://127.0.0.1:{port}/")
            page.wait_for_timeout(1500)
            page.locator("[data-kind=button]").filter(has_text=drive.exact("What matters this morning?")).first.click()
            page.wait_for_timeout(2000)
            page.screenshot(path=str(OUT / "web-morning.png"))
            page.locator("[data-kind=button]").filter(has_text=drive.exact("Rain at pickup")).first.click()
            page.wait_for_timeout(1700)
            page.screenshot(path=str(OUT / "web-point.png"))
            page.wait_for_timeout(800)
            browser.close()
    finally:
        server.terminate()
        server.wait(timeout=10)
        reader.join(timeout=5)
    text = "".join(lines)
    (OUT / "web.txt").write_text(text)
    if errors:
        probs.append("web: page errors: " + "; ".join(errors)[:300])
    got = read_run("web", text, probs)
    if (OUT / "web-point.png").exists():
        shutil.copy(OUT / "web-point.png", SHOTS / "m7c-web-point.png")
    if "iou" in got:
        said.append(f"web: promote -> {got['after']} ({got['holes']} holes), ring {got['ring']} on tile {got['tile']} (IoU {got['iou']})")


def run():
    OUT.mkdir(parents=True, exist_ok=True)
    said, probs = [], []
    for name, want in (("test_genui_tiles", "genui tiles: ok"), ("test_tiles_agent", "tiles agent: ok")):
        b = sh(["scripts/mxbuild.sh", f"tests/{name}.mojo", "-o", f"build/{name}"], 1800)
        if b.returncode:
            return ("FAIL", f"{name} doesn't build: {tail(b)}")
        t = sh([f"build/{name}"], 600)
        if t.returncode or want not in t.stdout:
            return ("FAIL", f"{name}: {tail(t)}")
        if name == "test_genui_tiles":
            refusal = re.search(r"^refused: (.*)$", t.stdout, re.M)
            said.append("genui: the sample valid; a bad one refused: \"" + (refusal.group(1) if refusal else "?") + "\" (and 8 more kinds of bad tiles)")
        else:
            promos = re.findall(r"^tiles (\d) : promoted \S+ first, (\w+) , holes (\d+)$", t.stdout, re.M)
            said.append("tests: patch path, CUSTOM ui_patch, tiles ops; promoted first for " + ", ".join(f"{n} tiles ({s}, {h} holes)" for n, s, h in promos))
    for host in ("linux", "web"):
        b = sh(["scripts/build.sh", "agenttiles", host], 3600)
        if b.returncode:
            return ("FAIL", f"scripts/build.sh agenttiles {host}: {tail(b, 900)}")
    check_gtk(said, probs)
    check_web(said, probs)
    (OUT / "m7c.txt").write_text("\n".join(said + probs) + "\n")
    print("\n".join(said + probs))
    if probs:
        return ("FAIL", "; ".join(probs))
    return ("PASS", "; ".join(said) + "; shots docs/goals/77/m7c-gtk-morning.png, m7c-gtk-point.png, m7c-web-point.png")


if __name__ == "__main__":
    state, why = run()
    print(state, why)
    sys.exit(0 if state == "PASS" else 1)
