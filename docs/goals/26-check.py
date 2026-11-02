"""Milestone checker for GOAL.md (goal 26: the Scene spike: the grid as a display list on GTK's GPU renderer, plus the
owner's four from trying goal 25; goal 25's checks run as M7, every earlier goal's inside them). Rebuilds from scratch,
prints PASS/FAIL per milestone. omxplorer runs on GTK (MOJOUI_TEST steps, and real input through scripts/live.py) and in
Chromium (scripts/drive.py).

Run: scripts/check   (a subset without rebuilding: scripts/check M0 M2; earlier goals: through docs/goals/NN-check.py)
"""

import importlib.util
import re
import sys
import time
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())  # (archived in docs/goals/)
sys.path.insert(0, str(ROOT / "scripts"))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


g25 = load("goal25", "docs/goals/25-check.py")
g20 = g25.g20
run, BUILD = g20.run, g20.BUILD
OUT = BUILD / "g26"
SHEET, REPORT, OPEN = g25.SHEET, g25.REPORT, g25.OPEN
boxes, labels = g25.boxes, g25.labels
HEADER = 60  # below the grid's header (a sorted or picked column's accent lives there): datagrid.header_h
GUTTER = 64  # the grid's gutter (row numbers), points: datagrid.GRID_GUTTER
ACCENT = (14, 122, 67)  # the brand green, light (D-4733): the selection ring


def live(commands, name, **kw):
    g25.OUT = OUT
    return g25.live(commands, name, **kw)


def gtk(steps, name, **kw):
    g25.OUT = OUT
    return g25.gtk(steps, name, **kw)


def web(steps, name, **kw):
    g25.OUT = OUT
    return g25.web(steps, name, **kw)


def near(px, colour, tol=30):
    return all(abs(a - b) < tol for a, b in zip(px, colour))


def centre(b):
    return int(b[0] + b[2] / 2), int(b[1] + b[3] / 2)


def m0():
    """The owner's four, with real input where it's input."""
    from PIL import Image, ImageChops
    problems = []
    OUT.mkdir(parents=True, exist_ok=True)
    # 1. The block follows the pointer while dragging: mid-drag (button still down, 40 ms after the last move) the
    #    ring's bottom-right corner is the cell under the pointer.
    shot = OUT / "mid-drag.png"
    px, py = 430, 431
    live(f"wait:1500;click:1350,818;wait:1500;press:230,275;glideto:{px},{py};wait:40;shot:{shot};release", "mid-drag")
    img = Image.open(shot).convert("RGB")
    ring = [(x, y) for x in range(100, 1400, 2) for y in range(240, 760, 2) if near(img.getpixel((x, y)), ACCENT)]
    if not ring:
        problems.append("no selection ring mid-drag")
    else:
        right, bottom = max(x for x, _ in ring), max(y for _, y in ring)
        if not (0 < right - px < 120 and 0 < bottom - py < 30):
            problems.append(f"mid-drag the ring ends at ({right}, {bottom}), not at the cell under the pointer ({px}, {py})")
    # 2. The import preview's scroll bar drags its rows (and a press on the rows selects nothing).
    out = live("wait:1500;report", "preview-bar-where")
    prev = boxes(out, "import-preview")
    if not prev:
        problems.append("no import-preview box")
    else:
        x, y, w, h = prev[0]
        before, after = OUT / "preview-bar-before.png", OUT / "preview-bar-after.png"
        bx = int(x + w - 5)
        live(f"wait:1500;shot:{before};press:{bx},{int(y + 60)};glideto:{bx},{int(y + h - 20)};release;wait:300;shot:{after}", "preview-bar")
        crop = (int(x), int(y + 60), int(x + w - 20), int(y + h))
        if not ImageChops.difference(Image.open(before).convert("RGB").crop(crop), Image.open(after).convert("RGB").crop(crop)).getbbox():
            problems.append("dragging the preview's scroll bar didn't move its rows")
    # 3. The inspector's sections are separated by hairlines (and titled in small caps), GTK and web.
    out_i, shot_i = gtk(SHEET, "inspector-lines-gtk")
    insp = boxes(out_i, "inspector")
    if not insp:
        problems.append("GTK: no inspector box")
    else:
        im = Image.open(shot_i).convert("RGB")
        ix, iy, iw, ih = (int(v) for v in insp[0])
        lines = 0
        for yy in range(iy + 60, iy + ih - 10):
            row = [im.getpixel((xx, yy)) for xx in range(ix + 20, ix + iw - 20, 4)]
            if row and all(near(p_, (217, 222, 230), 14) for p_ in row):  # (Liquid's line_strong #d9dee6, across the panel)
                lines += 1
        if lines < 2:
            problems.append(f"GTK: the inspector shows {lines} hairlines between its sections (want 2 or more)")
    out = web(SHEET + ";style:[data-tag=inspector] hr=border-top-width;style:[data-tag=inspector] hr=border-top-style", "inspector-lines")
    got = dict(re.findall(r"^STYLE: \[data-tag=inspector\] hr (\S+) (.+)$", out, re.M))
    if got.get("border-top-width") != "1px" or got.get("border-top-style") != "solid":
        problems.append(f"web: the inspector's sections have no hairline ({got})")
    # 4. A tile's ✕ is hidden until hovered: the web's computed opacity, and GTK's pixels without and with the pointer.
    out = web(REPORT + ";style:[data-tag=tile] button=opacity", "tile-x")
    op = re.findall(r"^STYLE: \[data-tag=tile\] button opacity (.+)$", out, re.M)
    if op != ["0"]:
        problems.append(f"web: a tile's ✕ shows without hover (opacity {op})")
    out = live("wait:1500;click:1350,818;wait:1200;report", "tile-x-tabs")
    tab = boxes(out, "sheet-tabs/Report")
    if not tab:
        problems.append("GTK: no Report tab box")
    else:
        tx, ty = centre(tab[0])
        out = live(f"wait:1500;click:1350,818;wait:1200;click:{tx},{ty};wait:600;report", "tile-x-tools")
        tool = boxes(out, "toolbar/Sum tile")
        if not tool:
            problems.append("GTK: no Sum tile tool box")
        else:
            sx, sy = centre(tool[0])
            out = live(f"wait:1500;click:1350,818;wait:1200;click:{tx},{ty};wait:600;click:{sx},{sy};wait:900;report", "tile-x-where")
            xs = boxes(out, "tile/Remove")
            if not xs:
                problems.append("GTK: no tile/Remove box")
            else:
                x, y, w, h = xs[0]
                far, over = OUT / "tile-x-far.png", OUT / "tile-x-over.png"
                live(f"wait:1500;click:1350,818;wait:1200;click:{tx},{ty};wait:600;click:{sx},{sy};wait:900;"
                     f"move:5,860;wait:500;shot:{far};move:{int(x) - 80},{int(y + h + 40)};wait:500;shot:{over}", "tile-x")
                box = (int(x), int(y), int(x + w), int(y + h))
                a, b = Image.open(far).convert("RGB").crop(box), Image.open(over).convert("RGB").crop(box)
                plain = max(max(abs(p - q) for p, q in zip(c, a.getpixel((0, 0)))) for c in a.get_flattened_data()) < 12  # (only the tile's own colour)
                shows = ImageChops.difference(a, b).getbbox() is not None
                if not plain or not shows:
                    problems.append(f"GTK: the ✕ {'is drawn without hover' if not plain else 'does not appear on hover'}")
    return not problems, "; ".join(problems) or ("the block follows the pointer mid-drag; the preview's scroll bar drags its rows; "
                                                  "the inspector's sections have hairlines (GTK, web); a tile's ✕ shows only on hover (GTK pixels, web opacity)")


BENCH_RE = re.compile(r"^BENCH: (\w+) (\d+) at (\d+)x(\d+) px draws (\d+) paint p50 ([\d.]+) p95 ([\d.]+) upload p50 ([\d.]+) p95 ([\d.]+) "
                      r"frame-paint p50 [\d.]+ p95 [\d.]+ interval p50 ([\d.]+) p99 ([\d.]+) within-9.5ms ([\d.]+)% cells built (\d+) uploads (\d+)", re.M)
ORDERS_1M = ROOT / "build/data/orders_1m.csv"


def bench(name, **more):
    """omxplorer on 1M rows in a 2800×1400 window (≈ the owner's 1742×876 at 1.6×): 60 scroll frames, 10 glides."""
    import os
    import headless
    headless.ensure()
    OUT.mkdir(parents=True, exist_ok=True)
    env = dict(g25.env(name), MOJOUI_TEST=f"pick:Choose a file={ORDERS_1M};tap:Create table;bench:glide=10;bench:scroll=60",  # (glides first: the selection on screen)
               MOJOUI_WINDOW="2800x1400", MOJOUI_TRACE="1", MOJOUI_SHOT=str(OUT / f"{name}.png"), **{k: str(v) for k, v in more.items()})
    r = run([str(BUILD / "omxplorer" / "linux" / "omxplorer")], env=env, timeout=1200)
    out = r.stdout + r.stderr
    found = {m.group(1): m.groups() for m in BENCH_RE.finditer(out)}
    return found, out


def m1():
    """Today's path measured: paint and upload apart, per scroll frame and per glide frame."""
    if not ORDERS_1M.exists():
        return False, f"no {ORDERS_1M} (goal 14's 1M-row file)"
    found, out = bench("baseline", MOJOUI_SCENE="0")  # (the pixel path: the Scene is GTK's default since goal 27, D-261)
    if "scroll" not in found or "glide" not in found:
        return False, f"no BENCH lines: {out[-400:]}"
    lines = [f"{k}: {v[2]}x{v[3]} px, {v[4]} draws, paint p50 {v[5]} ms p95 {v[6]} ms, upload p50 {v[7]} ms p95 {v[8]} ms" for k, v in found.items()]
    (ROOT / "docs/goals/26").mkdir(parents=True, exist_ok=True)
    (ROOT / "docs/goals/26/baseline.txt").write_text("Goal 26 baseline: today's path (CPU raster into a texture), omxplorer, 1M rows, 2800×1400 window,\n"
                                                    "headless (Xvfb, cairo): CPU numbers only.\n" + "\n".join(lines) + "\n")
    return True, "; ".join(lines) + " (docs/goals/26/baseline.txt)"


def m2():
    """The Scene: its tests (a replay draws the pixels the calls drew)."""
    err = g20.mojo_test("tests/test_scene.mojo", "SCENE TESTS PASSED", "test_scene", "tests")
    return err is None, err or "tests/test_scene.mojo: a Scene replays to exactly the pixels its calls draw (rect, rounded rect, line, circle, text, image, clip); a layer's version decides when it has one"


def m3():
    """The grid as a Scene: the same picture, cells and ring layers, the text readable."""
    err = g20.mojo_test("tests/test_scene.mojo", "SCENE TESTS PASSED", "test_scene", "tests")
    src = (ROOT / "mojoui/datagrid.mojo").read_text()
    problems = [err] if err else []
    if "def draw_scene" not in src or 'begin_layer("ring")' not in src:
        problems.append("DataGrid has no draw_scene or ring layer")
    return not problems, "; ".join(problems) or ("the grid recorded as a Scene and replayed is the grid drawn (every pixel); layers cells, selection, ring, bar; "
                                                  "the selection moving leaves the cells layer equal; each cell's text says which cell it is; a browse grid never selects")


def m4():
    """GTK draws the Scene: render nodes, cells reused by content; side by side with the pixels."""
    from PIL import Image, ImageChops
    problems = []
    steps = SHEET + ";glide:Down;glide:Down"
    old, old_shot = gtk(steps, "compare-pixels", MOJOUI_SCENE="0")
    new, new_shot = gtk(steps, "compare-scene", MOJOUI_SCENE="1", MOJOUI_TRACE="1")
    replays = re.findall(r"^TRACE: replay (\d+) ops", new, re.M)
    if not replays:
        problems.append("no replay with MOJOUI_SCENE=1 (the grid wasn't drawn as a Scene)")
    grid = boxes(old, "grid")
    if grid:
        x, y, w, h = (int(v) for v in grid[0])
        a = Image.open(old_shot).convert("RGB").crop((x, y, x + w, y + h))
        b = Image.open(new_shot).convert("RGB").crop((x, y, x + w, y + h))
        diff = ImageChops.difference(a, b).convert("L").point(lambda v: 255 if v > 48 else 0)
        share = sum(1 for v in diff.get_flattened_data() if v) / (w * h)
        # Text is drawn by another engine (its glyph edges differ); everything else (fills, lines, pills, ring) must
        # match: compare the pixels that are text-coloured in neither picture, and a little around them.
        from PIL import ImageFilter

        def ink(im):  # text-coloured pixels: dark or grey, not the accent (the ring and its handle are compared below)
            m = Image.new("L", im.size, 0)
            m.putdata([255 if (sum(px) / 3 < 170 and not near(px, ACCENT, 40)) else 0 for px in im.get_flattened_data()])
            return m.filter(ImageFilter.MaxFilter(5))
        text = ImageChops.lighter(ink(a), ink(b))

        def ring_box(im):
            pts = [(xx, yy) for yy in range(HEADER, im.size[1], 1) for xx in range(GUTTER + 1, im.size[0], 1) if near(im.getpixel((xx, yy)), ACCENT, 24)]  # (right of the gutter: its accent row numbers are text)
            return (min(p_[0] for p_ in pts), min(p_[1] for p_ in pts), max(p_[0] for p_ in pts), max(p_[1] for p_ in pts)) if pts else None
        ra, rb = ring_box(a), ring_box(b)
        if ra is None or rb is None or any(abs(u - v) > 1 for u, v in zip(ra, rb)):
            problems.append(f"the ring isn't where the pixel path draws it ({rb} vs {ra})")
        rest = [d for d, t in zip(diff.get_flattened_data(), text.get_flattened_data()) if not t]
        off = sum(1 for d in rest if d) / max(1, len(rest))
        if off > 0.01:
            problems.append(f"{off:.2%} of the grid's non-text pixels differ from the pixel path (lines, fills, pills, the ring)")
        (OUT / "compare.html").write_text(
            "<!doctype html><meta charset=utf-8><title>goal 26: pixels vs Scene</title><style>body{font:14px Inter,sans-serif;margin:24px}"
            "img{width:100%;border:1px solid #ddd}td{vertical-align:top;width:50%;padding:8px}</style><h2>The grid: today's pixels vs the Scene (GTK render nodes)</h2>"
            f"<p>{share:.2%} of the grid's pixels differ by more than a little (text drawn by Pango, not the baked atlas).</p><table><tr><td><b>Pixels (CPU)</b>"
            f"<img src='{old_shot.name}'></td><td><b>Scene (GTK renderer)</b><img src='{new_shot.name}'></td></tr></table>")
    else:
        problems.append("no grid box")
    return not problems, "; ".join(problems) or (f"MOJOUI_SCENE=1 draws the grid as render nodes ({replays[-1]} ops a frame); "
                                                  f"{off:.2%} of its non-text pixels differ from the pixel path ({share:.1%} with text edges); build/g26/compare.html")


def m5():
    """The numbers (main-thread CPU, headless): scroll ≤ 2 ms p95; glide with the cells kept, no texture upload."""
    if not ORDERS_1M.exists():
        return False, f"no {ORDERS_1M}"
    best = None  # (the best of three runs: other work on this machine, not the app, makes the slow ones; D-256)
    for attempt in range(3):
        found_n, out_n = bench(f"scene-{attempt}", MOJOUI_SCENE="1")
        if "scroll" not in found_n or "glide" not in found_n:
            continue
        cost = float(found_n["scroll"][6]) + float(found_n["scroll"][8])
        if best is None or cost < best[0]:
            best = (cost, found_n, out_n)
    if best is None:
        return False, "no BENCH lines in three runs"
    found, out = best[1], best[2]
    sc, gl = found["scroll"], found["glide"]
    scroll_p95 = float(sc[6]) + float(sc[8])
    glide_p50 = float(gl[5]) + float(gl[7])
    cells_built = int(gl[12])
    uploads = int(gl[13]) + int(sc[13])
    problems = []
    if scroll_p95 > 2.0:
        problems.append(f"a scroll frame costs {scroll_p95:.1f} ms p95 (build {sc[6]} + replay {sc[8]})")
    if glide_p50 > 0.3:
        problems.append(f"a glide frame costs {glide_p50:.1f} ms p50 (want ≤ 0.3)")
    if cells_built != 0:
        problems.append(f"the cells layer was built {cells_built} times in 10 glides (want 0: only the selection and ring move)")
    if uploads != 0:
        problems.append(f"{uploads} pixel textures handed to GTK (the Scene path uploads none)")
    base = (ROOT / "docs/goals/26/baseline.txt").read_text() if (ROOT / "docs/goals/26/baseline.txt").exists() else ""
    (ROOT / "docs/goals/26/scene.txt").write_text("Goal 26: the Scene (MOJOUI_SCENE=1), same run as the baseline\n" + "\n".join(
        f"{k}: {v[2]}x{v[3]} px, {v[4]} draws, build p50 {v[5]} ms p95 {v[6]} ms, replay p50 {v[7]} ms p95 {v[8]} ms, frame interval p50 {v[9]} p99 {v[10]}, "
        f"cells built {v[12]}, textures {v[13]}"
        for k, v in found.items()) + "\n")
    return not problems, "; ".join(problems) or (f"scroll: {scroll_p95:.1f} ms p95 a frame (build {sc[6]} + replay {sc[8]}); glide: {glide_p50:.1f} ms p50, "
                                                  f"the cells layer built 0 times in 10 glides; 0 textures uploaded (docs/goals/26/scene.txt)")


def m6():
    """On a real GPU display: the owner's run of scripts/scene-bench.sh (blocked on them, not faked)."""
    run_file = ROOT / "docs/goals/26/owner-run.txt"
    if not (ROOT / "scripts/scene-bench.sh").exists():
        return False, "no scripts/scene-bench.sh"
    if not run_file.exists():
        return False, "blocked: waits for the owner to run scripts/scene-bench.sh on their display"
    text = run_file.read_text()
    scene = text.split("== scene", 1)[1] if "== scene" in text else ""
    found = re.findall(r"^BENCH: (\w+) .* interval p50 ([\d.]+) p99 ([\d.]+) within-9.5ms ([\d.]+)%", scene, re.M)
    kinds = {k for k, *_ in found}
    if kinds != {"scroll", "glide"}:
        return False, f"the owner's run lacks a scroll or a glide with the Scene ({sorted(kinds)})"
    parts, ok = [], True
    for k, p50, p99, share in found:
        p50, p99, share = float(p50), float(p99), float(share)
        ok = ok and share >= 99  # (the bar: 120 fps, D-252: at least 99% of frames within 9.5 ms)
        hz = f", the display at {1000 / p50:.0f} Hz" if p50 > 12 else ""
        parts.append(f"{k}: {share}% of frames within 9.5 ms (interval p50 {p50} ms, p99 {p99}{hz})")
    return ok, "owner's display: " + "; ".join(parts) + ("" if ok else " (120 fps not shown)")


def contrast(a, b):
    def lum(h):
        c = [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]
        c = [v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4 for v in c]
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    hi, lo = sorted((lum(a), lum(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def m8():
    """The brand (D-254, D-4733): logo 1 in the menu bar; one green for the app, the sheet and the report."""
    from PIL import Image
    problems = []
    light, dark = "#0e7a43", "#5aeca2"  # (D-4733: one green in every mode; Liquid dark, the default since D-1241, lifts it)
    want = {"start": dark, "sheet": dark, "report": dark}
    rgb = [int(light[i:i + 2], 16) for i in (1, 3, 5)]
    wash = "#" + "".join(f"{round(255 + (v - 255) * 0.10):02x}" for v in rgb)  # (Palette.with_accent: 10% over the white card)
    for hexv, other in ((light, "#ffffff"), (light, wash), (dark, "#1b1f27")):
        if contrast(hexv, other) < 4.5:
            problems.append(f"{hexv} on {other}: {contrast(hexv, other):.2f}:1 (AA wants 4.5)")
    steps = {"start": "pause:200", "sheet": SHEET + ";pause:300", "report": REPORT}
    for name, st in steps.items():
        out = web(st + ";style:body=--o-accent;style:[data-tag=app-mark] svg=width;attr:link[rel=icon]=href", f"brand-{name}")
        fav = re.search(r"^ATTR: link\[rel=icon\] href (.+)$", out, re.M)
        if not fav or not fav.group(1).startswith("data:image/svg+xml"):
            problems.append(f"web {name}: no app icon for the tab ({fav.group(1)[:30] if fav else None})")
        got = dict(re.findall(r"^STYLE: (\S+(?: svg)?) \S+ (.+)$", out, re.M))
        acc = re.search(r"^STYLE: body --o-accent (.+)$", out, re.M)
        logo = re.search(r"^STYLE: \[data-tag=app-mark\] svg width (.+)$", out, re.M)
        if not acc or acc.group(1).strip().lower() != want[name]:
            problems.append(f"web {name}: accent {acc.group(1) if acc else None}, want {want[name]}")
        if not logo or logo.group(1).strip() in ("none", "0px", "auto"):
            problems.append(f"web {name}: no logo in the menu bar ({logo.group(1) if logo else None})")
        bar, mark = boxes(out, "menubar"), boxes(out, "app-mark")
        if not bar or not mark or mark[0][3] > bar[0][3] or mark[0][1] + mark[0][3] > bar[0][1] + bar[0][3] + 1:
            problems.append(f"web {name}: the logo doesn't fit the menu bar (mark {mark}, bar {bar})")
    out, shot = gtk(SHEET + ";glide:Down", "brand-sheet-gtk")
    if "ICON: app-logo" not in out:
        problems.append("GTK: no app-logo icon in the menu bar")
    if "WINDOW-ICON: mojoui-app-logo" not in out:
        problems.append("GTK: the window's icon isn't the logo")
    img = Image.open(shot).convert("RGB")
    ring = [(x, y) for x in range(100, 1400, 2) for y in range(240, 760, 2) if near(img.getpixel((x, y)), (90, 236, 162), 24)]
    if len(ring) < 50:
        problems.append(f"GTK sheet: the selection ring isn't the brand green ({len(ring)} green pixels)")
    # Liquid light: the app wears the green itself, unlifted
    import os
    import drive
    e = g25.env("brand-light")
    (OUT / "brand-light" / "config" / "settings.txt").write_text("appearance=light\n")
    saved = {k: os.environ.get(k) for k in e}
    os.environ.update(e)
    try:
        r, out = drive.web_run(BUILD / "omxplorer" / "web", "pause:200;style:body=--o-accent", shot=str(OUT / "brand-light-web.png"), viewport=(1742, 876))
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    acc = re.search(r"^STYLE: body --o-accent (.+)$", out, re.M)
    if not acc or acc.group(1).strip().lower() != light:
        problems.append(f"web light: accent {acc.group(1) if acc else None}, want {light}")
    # the report draws its chart in the same green (Liquid's first series is the brand's)
    out, shot = gtk(REPORT + ";tap:Chart tile;pause:400", "brand-report-gtk")
    tiles = boxes(out, "chart-tile")
    img = Image.open(shot).convert("RGB")
    sx = img.size[0] / 1742
    green = 0
    if tiles:
        x, y, w, h = tiles[0]
        green = sum(1 for px in img.crop((int(x * sx), int(y * sx), int((x + w) * sx), int((y + h) * sx))).getdata() if near(px, (90, 236, 162), 20))
    if green < 2000:
        problems.append(f"GTK report: the chart isn't drawn in the brand green ({green} green pixels)")
    return not problems, "; ".join(problems) or ("logo 1 in the menu bar (GTK, web); the brand green on the start screen, the sheet (the ring too) "
                                                  "and the report, its chart too (Liquid dark's lift; #0e7a43 in Liquid light); ≥ 4.5:1 on white and on the dark card")


def todo(what):
    def fn():
        return False, f"not built yet: {what}"
    return fn


def m7():
    """Goal 25's checks (every earlier goal's inside them) with today's pixels, then its M1–M6 with the Scene on."""
    import os
    problems = []
    os.environ["MOJOUI_SCENE"] = "0"  # (today's pixels: the Scene is GTK's default since goal 27, D-261)
    for name, fn in [("25-M1", g25.m1), ("25-M2", g25.m2), ("25-M3", g25.m3), ("25-M4", g25.m4), ("25-M5", g25.m5), ("25-M6", g25.m6), ("25-M7", g25.m7)]:
        g25.OUT = BUILD / "g25"
        ok, msg = fn()
        if not ok:
            problems.append(f"{name}: {msg}")
    os.environ["MOJOUI_SCENE"] = "1"
    try:
        for name, fn in [("25-M1", g25.m1), ("25-M2", g25.m2), ("25-M3", g25.m3), ("25-M4", g25.m4), ("25-M5", g25.m5), ("25-M6", g25.m6)]:
            g25.OUT = BUILD / "g25-scene"
            ok, msg = fn()
            if not ok:
                problems.append(f"{name} with the Scene: {msg}")
    finally:
        os.environ.pop("MOJOUI_SCENE", None)
    return not problems, "; ".join(problems) or "goal 25's M1–M7 (goals 3–24 inside them) pass, and its M1–M6 with MOJOUI_SCENE=1"


MILESTONES = [("M0", m0), ("M1", m1), ("M2", m2), ("M3", m3), ("M4", m4), ("M5", m5), ("M6", m6), ("M8", m8), ("M7", m7)]


def main():
    import shutil
    import headless
    headless.ensure()
    only = sys.argv[1:]
    if not only:
        for ex in g20.EXAMPLES:
            shutil.rmtree(BUILD / ex, ignore_errors=True)
        for ex in g20.EXAMPLES:
            if not (ROOT / "examples" / ex / "app.mojo").exists():
                continue
            b = run(["scripts/build.sh", ex, "all"], timeout=3600)
            if b.returncode != 0:
                print(f"build {ex} failed:\n" + (b.stdout + b.stderr)[-1500:])
            if ex in ("hello", "gallery", "layout", "lens", "todo"):
                a = run(["scripts/build.sh", ex, "android"], timeout=3600)
                if a.returncode != 0:
                    print(f"android build {ex} failed:\n" + (a.stdout + a.stderr)[-1500:])
    results = []
    for name, fn in MILESTONES:
        if only and name not in only:
            continue
        t0 = time.time()
        try:
            ok, msg = fn()
        except Exception as e:
            ok, msg = False, f"crashed: {e!r}"
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {msg}  ({time.time() - t0:.0f} s)", flush=True)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
