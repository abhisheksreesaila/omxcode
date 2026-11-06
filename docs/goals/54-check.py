"""Goal 54's proof: omxplorer shell A, and cards that tile (GOAL.md). Prints "Mn: PASS|FAIL  why".

    pixi run python docs/goals/54-check.py [M0 M1 ...]          (default: every milestone)

GTK runs on the private Xvfb display (scripts/headless.py) with MOJOUI_TEST steps: real drags through the host
(move:/resize:), the Board's rects read from its `BOARD:` lines (`boards:` mid-run). Truth is geometry and pixels,
never the app's own word for it.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/g54"
FULL = ROOT / "build/g47/full"
APP = ROOT / "build/omxplorer/linux/omxplorer"
GAP = 8
sys.path.insert(0, str(ROOT / "scripts"))


def run(cmd, timeout=3600, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))


def mojo_test(src, labels, timeout=1800, env=None):
    exe = ROOT / "build" / Path(src).stem
    b = run(["scripts/mxbuild.sh", src, "-o", str(exe)], timeout)
    if b.returncode:
        return False, b.stdout + b.stderr, labels
    r = run([str(exe)], timeout, env)
    out = r.stdout + r.stderr
    missing = [l for l in labels if not re.search(rf"^{re.escape(l)}: ok", out, re.M)]
    return (r.returncode == 0 and not missing), out, missing


_built = False


def build_app():
    global _built
    if not _built:
        r = run(["scripts/build.sh", "omxplorer", "linux"], 3600)
        if r.returncode or not APP.exists():
            raise SystemExit("omxplorer didn't build: " + (r.stdout + r.stderr)[-1500:])
        _built = True


def gtk(steps, name, size=(1440, 900), appearance="light"):
    """omxplorer on the private display with MOJOUI_TEST `steps`; (output, final shot)."""
    import headless
    headless.ensure()
    build_app()
    home = OUT / name
    for d in ("docs", "config"):
        (home / d).mkdir(parents=True, exist_ok=True)
    (home / "config" / "settings.txt").write_text(f"appearance={appearance}\n")
    shot = OUT / f"{name}.png"
    env = {"OMX_DOCUMENTS": str(home / "docs"), "OMX_CONFIG": str(home / "config"), "MOJOUI_TEST": steps, "MOJOUI_WINDOW": f"{size[0]}x{size[1]}",
           "MOJOUI_SHOT": str(shot), "MOJOUI_TRACE": "1", "MOJOUI_BUDGET_MS": "50", "OMX_PACKS": str(ROOT / "build/packs")}
    r = run([str(APP)], 1200, env)
    out = r.stdout + r.stderr
    (OUT / f"{name}.log").write_text(out)
    if r.returncode != 0 or "TEST: " in out:
        raise RuntimeError(f"GTK run {name} failed (exit {r.returncode}): " + "\n".join(l for l in out.splitlines() if "TEST" in l or "rror" in l)[-800:])
    return out, shot


BOARD_RE = re.compile(r"^BOARD: (\S+) at (-?\d+),(-?\d+) (\d+)x(\d+)(?: \(asked -?\d+,-?\d+ \d+x\d+\))?$")
SIZE_RE = re.compile(r"^BOARDS: (\S+) (\d+)x(\d+)(?: in (\d+)x(\d+))?$")


ROOMS = {}  # each dump's room: the Board's scroller (a Board bigger than it would scroll)


def boards(out):
    """Each `boards:` dump in order: (step, (W, H), {name: (x, y, w, h)})."""
    dumps, cur = [], None
    for line in out.splitlines():
        m = SIZE_RE.match(line)
        if m:
            cur = (m.group(1), (int(m.group(2)), int(m.group(3))), {})
            dumps.append(cur)
            if m.group(4):
                ROOMS[m.group(1)] = (int(m.group(4)), int(m.group(5)))
            continue
        b = BOARD_RE.match(line)
        if b and cur is not None:
            cur[2][b.group(1)] = tuple(int(v) for v in b.groups()[1:])
    return dumps


def tiled(size, rects):
    """Problems with one layout: overlaps, outside the board, gaps not 8 ± 1 between neighbours."""
    W, H = size
    bad = []
    items = list(rects.items())
    for n, (x, y, w, h) in items:
        if x < 0 or y < 0 or x + w > W + 1 or y + h > H + 1:
            bad.append(f"{n} outside {W}x{H}: {x},{y} {w}x{h}")
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            (a, (ax, ay, aw, ah)), (b, (bx, by, bw, bh)) = items[i], items[j]
            if ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah:
                bad.append(f"{a} overlaps {b}")
            # neighbours side by side (their spans overlap): the gap between them is 8 ± 1
            if ay < by + bh and by < ay + ah:
                g = bx - (ax + aw) if bx >= ax + aw else (ax - (bx + bw) if ax >= bx + bw else None)
                if g is not None and g < 40 and abs(g - GAP) > 1:
                    bad.append(f"{a}|{b} gap {g}")
            if ax < bx + bw and bx < ax + aw:
                g = by - (ay + ah) if by >= ay + ah else (ay - (by + bh) if ay >= by + bh else None)
                if g is not None and g < 40 and abs(g - GAP) > 1:
                    bad.append(f"{a}/{b} gap {g}")
    return bad


def m0():
    labels = ["insert", "remove", "resize", "swap", "fit", "text", "random"]
    ok, out, missing = mojo_test("tests/test_tiling.mojo", labels)
    return ok, "; ".join(l for l in out.splitlines() if l.endswith(": ok") or "random" in l)[-300:] if ok else f"missing {missing}: {out[-600:]}"


HERO = "F00118"


def m1_steps():
    fleet, tele, clip = FULL / "fleet.csv", FULL / "telemetry.parquet", FULL / "clips" / f"{HERO}.mp4"
    return ";".join([
        f"pick:Choose a file={fleet}", "waitfor:Create table=60000", "tap:Create table", "wait:800", "boards:table",
        f"pick:Table={tele}", "waitfor:close-telemetry=120000", "wait:500", "boards:telemetry",
        "tap:Chart", "wait:800", "boards:chart",
        "tap:Video", "wait:300", f"pick:Choose a video…={clip}", "wait:1500", "boards:video",
        "tap:Query", "wait:300", "textarea:0=SELECT lab, COUNT(*) AS n FROM fleet GROUP BY lab", "tap:run-query", "waitfor:close-query-1=60000", "wait:500", "boards:query",
        "tap:close-query-1", "wait:600", "boards:closed",
        "resize:table=-120,0", "wait:600", "boards:resized",
        "resize:table=60,0", "wait:600", "boards:regrown",
        "dragcard:tablecard0=table", "wait:600", "boards:swapped",
        "window:1280x800", "wait:900", "boards:smaller",
    ])


def m1():
    if not (FULL / "fleet.csv").exists():
        return False, f"no {FULL} (goal 47's robot data)"
    out, shot = gtk(m1_steps(), "m1-tiles")
    d = boards(out)
    steps = [s for s, _, _ in d]
    want = ["table", "telemetry", "chart", "video", "query", "closed", "resized", "regrown", "swapped", "smaller"]
    if steps != want:
        return False, f"board dumps {steps}, wanted {want}"
    probs = []
    for step, size, rects in d:
        probs += [f"{step}: {p}" for p in tiled(size, rects)]
    by = {s: r for s, _, r in d}
    if len(by["query"]) != len(by["video"]) + 1 or len(by["closed"]) != len(by["video"]):
        probs.append(f"cards: video {len(by['video'])}, query {len(by['query'])}, closed {len(by['closed'])}")
    # the corner drag (120 pt in): the table's right edge moved by that much, and every card that faced that edge moved
    # its left edge with it (they gave way), the row still tiled
    t0, t1 = by["closed"].get("table"), by["resized"].get("table")
    grew = (t1[2] - t0[2]) if t0 and t1 else 0
    if grew != -120:
        probs.append(f"the table's width changed by {grew} after a -120 pt corner drag")
    edge0 = t0[0] + t0[2] + GAP if t0 else -1
    facing = [n for n, r in by["closed"].items() if n != "table" and r[0] == edge0]
    gave = [n for n in facing if n in by["resized"] and by["resized"][n][0] == edge0 + grew]  # (nested parts share the space, as Hyprland's splits do)
    if not facing or gave != facing:
        probs.append(f"cards facing the table's edge {facing}, moved with it {gave}")
    # the corner dragged back out 60 pt: the table grows by that much and the same cards move their left edges with it
    t2 = by["regrown"].get("table")
    regrew = (t2[2] - t1[2]) if t1 and t2 else 0
    if regrew != 60:
        probs.append(f"the table's width changed by {regrew} after a +60 pt corner drag")
    followed = [n for n in facing if n in by["regrown"] and by["regrown"][n][0] == edge0 + grew + regrew]
    if followed != facing:
        probs.append(f"after growing, cards facing the edge {facing}, moved with it {followed}")
    # never a scroll: every layout fits the room the window gives the Board
    for step, (W, H), _ in d:
        room = ROOMS.get(step)
        if not room or W > room[0] or H > room[1]:
            probs.append(f"{step}: board {W}x{H} in room {room}")
    # the drop: the two cards' rects swapped
    a0, b0 = by["regrown"].get("table"), by["regrown"].get("tablecard0")
    a1, b1 = by["swapped"].get("table"), by["swapped"].get("tablecard0")
    if not (a0 and b0 and a1 == b0 and b1 == a0):
        probs.append(f"swap: table {a0}→{a1}, telemetry {b0}→{b1}")
    sizes = {s: z for s, z, _ in d}
    if not (sizes["smaller"][0] <= sizes["swapped"][0] - 150 and sizes["smaller"][1] <= sizes["swapped"][1] - 80):
        probs.append(f"the window went 1440×900 → 1280×800 but the board went {sizes['swapped']} → {sizes['smaller']}")
    slow = [l for l in out.splitlines() if l.startswith("SLOW:")]
    if slow:
        probs.append(f"{len(slow)} SLOW lines: {slow[0]}")
    if probs:
        return False, "; ".join(probs)[:900]
    return True, f"{len(d)} layouts, no overlap, gaps 8, never a scroll; corner drag {grew} then +{regrew} pt, {', '.join(gave)} moved with the edge; swap exact; 0 SLOW; {shot}"


def edge_pixels(png, chrome_check):
    """The corners and the right edge mid-height: chrome, not backdrop (chrome_check(rgb) → bool)."""
    from PIL import Image
    im = Image.open(png).convert("RGB")
    W, H = im.size
    spots = {"top-left": (3, 3), "top-right": (W - 4, 3), "bottom-left": (3, H - 4), "bottom-right": (W - 4, H - 4), "right-mid": (W - 4, H // 2)}
    bad = [f"{k} {im.getpixel(p)}" for k, p in spots.items() if not chrome_check(im.getpixel(p))]
    return bad, im


def backdrop_of(appearance):
    # Liquid's backdrop: light #e1e7ef (gradient #e6ebf2 → #dbe2eb), dark #12151b (a shade either side)
    return [(225, 231, 239), (230, 235, 242), (219, 226, 235)] if appearance == "light" else [(18, 21, 27), (22, 25, 32), (15, 18, 23)]


def near(a, b, tol=5):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def lines_at(im, x, y0, y1):
    """y where a 1–2 px line runs across column x between y0 and y1: a pixel unlike the ones 3 above and 3 below,
    which are like each other (a line between two fills, or on one)."""
    out = []
    for y in range(y0 + 3, y1 - 3):
        a, m, b = im.getpixel((x, y - 3)), im.getpixel((x, y)), im.getpixel((x, y + 3))
        if sum(abs(p - q) for p, q in zip(m, a)) >= 9 and sum(abs(p - q) for p, q in zip(m, b)) >= 9:
            out.append(y)
    return out


def cols_at(im, y, x0, x1):
    out = []
    for x in range(x0 + 3, x1 - 3):
        a, m, b = im.getpixel((x - 3, y)), im.getpixel((x, y)), im.getpixel((x + 3, y))
        if sum(abs(p - q) for p, q in zip(m, a)) >= 9 and sum(abs(p - q) for p, q in zip(m, b)) >= 9:
            out.append(x)
    return out


def mockup_shot():
    """The mockup's option A as a picture, for the compare page."""
    from playwright.sync_api import sync_playwright
    png = OUT / "mockup-A.png"
    with sync_playwright() as p:
        b = p.chromium.launch(executable_path="/usr/bin/chromium")
        pg = b.new_page(viewport={"width": 1480, "height": 1000})
        pg.goto("file://" + str(ROOT / "docs/design/chrome/options.html"))
        pg.click('button[data-opt="A"]')
        pg.wait_for_timeout(600)
        pg.locator("#win").screenshot(path=str(png))
        b.close()
    return png


def m2():
    if not (FULL / "fleet.csv").exists():
        return False, f"no {FULL}"
    probs, shots = [], []
    for ap in ("light", "dark"):
        out, shot = gtk(f"pick:Choose a file={FULL / 'fleet.csv'};waitfor:Create table=60000;tap:Create table;wait:1200", f"m2-shell-{ap}", appearance=ap)
        shots.append(str(shot))
        backs = backdrop_of(ap)
        bad, im = edge_pixels(shot, lambda px: not any(near(px, b) for b in backs))
        probs += [f"{ap}: {b} is backdrop" for b in bad]
        W, H = im.size
        # the 1 px lines where the docked parts meet the board: under the top band, over the bottom band, beside the
        # rail and beside the inspector (looked for along a column and a row through the board)
        if not lines_at(im, W // 3, 40, 140):
            probs.append(f"{ap}: no line under the top band")
        if not lines_at(im, W // 3, H - 110, H - 40):
            probs.append(f"{ap}: no line over the bottom band")
        xs = cols_at(im, H // 2, 20, 90)
        if not xs:
            probs.append(f"{ap}: no line beside the rail")
        if not cols_at(im, H // 2, W - 360, W - 260):
            probs.append(f"{ap}: no line beside the inspector")
    # a wide window: the toolbar shows its titles (taller); the Board still fits the room it's given
    out, wide = gtk(f"pick:Choose a file={FULL / 'fleet.csv'};waitfor:Create table=60000;tap:Create table;wait:1200;boards:wide", "m2-shell-wide", size=(1920, 1080))
    shots.append(str(wide))
    boards(out)
    d = boards(out)
    room = ROOMS.get("wide")
    if not d or not room or d[0][1][0] > room[0] or d[0][1][1] > room[1]:
        probs.append(f"1920×1080: board {d[0][1] if d else None} in room {room}")
    if probs:
        return False, "; ".join(probs)
    mock = mockup_shot()
    compare = OUT / "compare.html"
    compare.write_text("<!doctype html><meta charset=utf-8><title>goal 54: shell A</title><body style='margin:0;background:#111;color:#eee;font:13px Inter,sans-serif'>"
                       "<div style='display:grid;grid-template-columns:1fr 1fr;gap:8px;padding:8px'>"
                       f"<figure style='margin:0'><figcaption>Mockup, option A</figcaption><img src='file://{mock}' style='width:100%'></figure>"
                       + "".join(f"<figure style='margin:0'><figcaption>{Path(x).name}</figcaption><img src='file://{x}' style='width:100%'></figure>" for x in shots)
                       + "</div>")
    return True, f"edges are chrome and the docked lines are there, light and dark; the board fits at 1920×1080 with titles; compare page {compare} (look at it)"


def m3():
    import headless
    headless.ensure()
    b = run(["scripts/build.sh", "omxplorer", "web"], 3600)
    if b.returncode:
        return False, "web build failed: " + (b.stdout + b.stderr)[-800:]
    r = run(["pixi", "run", "python", str(ROOT / "docs/goals/54-web.py"), str(OUT / "m3-web.png")], 900,
            {"OMX_DOCUMENTS": str(OUT / "m3" / "docs"), "OMX_CONFIG": str(OUT / "m3" / "config")})
    out = r.stdout + r.stderr
    (OUT / "m3-web.log").write_text(out)
    if r.returncode:
        return False, out[-800:]
    bad, _ = edge_pixels(OUT / "m3-web.png", lambda px: not any(near(px, b) for b in backdrop_of("light")))
    if bad:
        return False, "web: " + "; ".join(bad)
    return True, out.strip().splitlines()[-1] if out.strip() else "ok"


def m4():
    probs = []
    for src, labels in [("tests/test_regions.mojo", None), ("tests/test_diff_keep.mojo", None),
                        ("tests/test_script.mojo", ["parse", "run", "chain", "error", "fn", "frames", "recipe"])]:
        ok, out, missing = mojo_test(src, labels or [], env={"G49_OUT": str(OUT / "g49t")})
        if not ok:
            probs.append(f"{src}: {missing or out[-300:]}")
    for check, ms in [("docs/goals/49-check.py", ["M1", "M2", "M3", "M4"]), ("docs/goals/51-check.py", ["M4"])]:
        r = run(["pixi", "run", "python", check] + ms, 7200)
        lines = [l for l in (r.stdout + r.stderr).splitlines() if re.match(r"^M\d: ", l)]
        fails = [l for l in lines if "PASS" not in l.split()[1:2]]
        if fails or len(lines) < len(ms):
            probs.append(f"{check}: {fails or lines or (r.stdout + r.stderr)[-300:]}")
    return (not probs), "; ".join(probs)[:900] if probs else "regions, diff_keep, script ok; goal 49 M1–M4 and goal 51 M4 PASS"


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4}

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    picked = sys.argv[1:] or list(MILESTONES)
    for k in picked:
        try:
            ok, why = MILESTONES[k]()
        except Exception as e:  # (a crash is a FAIL with its reason, never a silent skip)
            ok, why = False, f"{type(e).__name__}: {e}"
        print(f"{k}: {'PASS' if ok else 'FAIL'}  {why}", flush=True)
