"""Goal 73 M2: a Board that grows (docs/goals/73.md). `check() -> (ok, why)`.

1. the unit tests of mojoui.tiling / mojoui.boardtiles (stretch, grow, shrink, bottom row);
2. omxplorer on GTK (headless, MOJOUI_WINDOW=1440x900) with real drags through the host: the fleet table's corner dragged 600 pt
   down ends 600 pt taller (± the gap), the cards beside it keep their pixels, the page scrolls to its bottom; a card beside
   it dragged past what its neighbour can give; a bottom card dragged up gives the height back; six cards each keep TILE_MIN
   (300 x 200), the sixth goes in a new row below and is scrolled into view; the window resized still tiles;
3. the same on the web host in headless Chromium (scripts/drive.py), read from the page's own boxes.
Layouts are read from the host's `BOARD:` lines / the page's DOM, never the app's own word for it; screenshots in build/g73/m2/.
"""
import importlib.util
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build/g73/m2"
DATA = [Path(os.environ.get("G73_DATA", ROOT / "build/g47/full"))]  # (goal 47's DROID folder: scripts/robot_data.py)
GAP = 8
MIN_W, MIN_H = 300, 200  # omxplorer's TILE_MIN_W / TILE_MIN_H
sys.path.insert(0, str(ROOT / "scripts"))


def _g54():
    spec = importlib.util.spec_from_file_location("g54", ROOT / "docs/goals/54-check.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.OUT = OUT
    return mod


def _full():
    for d in DATA:
        if (d / "fleet.csv").exists() and (d / "telemetry.parquet").exists():
            return d
    return None


def _near(a, b, tol=GAP + 1):
    return abs(a - b) <= tol


def _scroll(out):
    """Every `BOARDSCROLL: value of upper, page` line, in order."""
    return [tuple(int(v) for v in m.groups()) for m in re.finditer(r"^BOARDSCROLL: (\d+) of (\d+), (\d+)$", out, re.M)]


def _units(g):
    labels = [("tests/test_tiling.mojo", ["insert", "remove", "resize", "swap", "fit", "text", "stretch", "random"]),
              ("tests/test_boardtiles.mojo", ["add", "close", "self", "drop", "resize", "focus", "grow", "shrink", "bottom"])]
    done = []
    for src, want in labels:
        ok, out, missing = g.mojo_test(src, want)
        if not ok:
            return False, f"{src}: missing {missing}: {out[-500:]}"
        done.append(f"{Path(src).stem} {len(want)} ok")
    return True, "; ".join(done)


def _gtk_grow(g, full):
    fleet, tele = full / "fleet.csv", full / "telemetry.parquet"
    start = [f"pick:Choose a file={fleet}", "waitfor:Create table=60000", "tap:Create table", "wait:800",
             "shortcut:Ctrl+Shift+I", "wait:300",  # (the inspector open, as it opened by default when this proof was written; goal 76 starts it closed)
             f"pick:Table={tele}", "waitfor:close-telemetry=120000", "wait:500", "tap:Chart", "wait:800"]
    steps = ";".join(start + [
        "boards:before", f"shot:{OUT / 'gtk-1-before.png'}",
        "resize:table=0,600", "wait:800", "boards:grown", "boardscroll:end", "wait:300", "boards:bottom", f"shot:{OUT / 'gtk-2-grown-bottom.png'}",
        "boardscroll:0", f"shot:{OUT / 'gtk-3-grown-top.png'}",
        "resize:tablecard0=0,900", "wait:800", "boards:pushed",
        "resize:chart0=0,-3000", "wait:800", "boards:shrunk", "boardscroll:now",
    ])
    out, _ = g.gtk(steps, "m2-grow")
    d = {s: (size, r) for s, size, r in g.boards(out)}
    probs = []
    (bw0, bh0), r0 = d["before"]
    (bw1, bh1), r1 = d["grown"]
    room = g.ROOMS["before"]
    if not _near(r1["table"][3] - r0["table"][3], 600):
        probs.append(f"the table is {r1['table'][3] - r0['table'][3]} pt taller after a 600 pt drag")
    if bh1 != bh0 + 600 or bw1 != bw0:
        probs.append(f"the Board went {bw0}x{bh0} -> {bw1}x{bh1}")
    if r1["tablecard0"][3] != r0["tablecard0"][3]:
        probs.append(f"tablecard0 (above the dragged row's bottom) changed height {r0['tablecard0'][3]} -> {r1['tablecard0'][3]}")
    if r1["chart0"][3] != r0["chart0"][3] + 600:
        probs.append(f"chart0 (beside the table, at the bottom) {r0['chart0'][3]} -> {r1['chart0'][3]}")
    # the page scrolls to its bottom: the scroller's content is as tall as the Board and ends in view
    sc = _scroll(out)
    value, upper, page = sc[0]  # (boardscroll:end)
    if upper < bh1 or value + page < upper - 1 or value < bh1 - room[1] - 2:
        probs.append(f"scroll to the end: {value} of {upper}, page {page} (Board {bh1}, room {room[1]})")
    bottom = max(y + h for (x, y, w, h) in d["bottom"][1].values())
    if bottom != bh1:
        probs.append(f"cards end at {bottom}, the Board is {bh1} tall")
    # past what the card below can give (it stops at its minimum): the rest makes the Board taller
    (_, bh2), r2 = d["pushed"]
    if not _near(r2["tablecard0"][3] - r1["tablecard0"][3], 900):
        probs.append(f"tablecard0 is {r2['tablecard0'][3] - r1['tablecard0'][3]} pt taller after a 900 pt drag")
    if r2["chart0"][3] < MIN_H:
        probs.append(f"chart0 pushed to {r2['chart0'][3]} pt, under {MIN_H}")
    if bh2 <= bh1:
        probs.append(f"the Board didn't grow past what the card below gave: {bh1} -> {bh2}")
    # a bottom card dragged up gives the height back, no further than the window's room
    (_, bh3), r3 = d["shrunk"]
    if bh3 != bh0:
        probs.append(f"the bottom card dragged up left the Board {bh3} tall (the window's room: {bh0})")
    for step in ("before", "grown", "pushed", "shrunk"):
        probs += [f"{step}: {p}" for p in g.tiled(d[step][0], d[step][1])]
        probs += [f"{step}: {n} {r[2]}x{r[3]} under {MIN_W}x{MIN_H}" for n, r in d[step][1].items() if r[2] < MIN_W or r[3] < MIN_H]
    if probs:
        return False, "GTK grow: " + "; ".join(probs)[:800]
    return True, (f"GTK: the table +{r1['table'][3] - r0['table'][3]} for a 600 pt drag (Board {bh0} -> {bh1}, scroll {value}+{page} of {upper}); "
                  f"tablecard0 +{r2['tablecard0'][3] - r1['tablecard0'][3]} for 900, chart0 held at {r2['chart0'][3]}, Board {bh2}; shrunk back to {bh3}")


def _gtk_six(g, full):
    fleet, tele = full / "fleet.csv", full / "telemetry.parquet"
    steps = [f"pick:Choose a file={fleet}", "waitfor:Create table=60000", "tap:Create table", "wait:800",
             f"pick:Table={tele}", "waitfor:close-telemetry=120000", "wait:500", "boards:n2"]
    for n in range(3, 8):
        steps += ["tap:Chart", "wait:800", f"boards:n{n}", "boardscroll:now"]
    steps += [f"shot:{OUT / 'gtk-4-seven-cards.png'}", "boardscroll:0", f"shot:{OUT / 'gtk-5-seven-cards-top.png'}", "window:1280x800", "wait:900", "boards:smaller"]
    out, _ = g.gtk(";".join(steps), "m2-six", size=(1440, 900))
    d = g.boards(out)
    by = {s: (size, r) for s, size, r in d}
    probs = []
    for n in range(2, 8):
        (w, h), rects = by[f"n{n}"]
        if len(rects) != n:
            probs.append(f"n{n}: {len(rects)} cards")
        probs += [f"n{n}: {p}" for p in g.tiled((w, h), rects)]
        probs += [f"n{n}: {k} {r[2]}x{r[3]} under {MIN_W}x{MIN_H}" for k, r in rects.items() if r[2] < MIN_W or r[3] < MIN_H]
    room = g.ROOMS["n2"]
    heights = [by[f"n{n}"][0][1] for n in range(2, 8)]
    if heights[0] > room[1] or heights[-1] <= room[1]:
        probs.append(f"the Board went {heights} in a room {room[1]} high")
    first = next(n for n in range(2, 8) if by[f"n{n}"][0][1] > room[1])
    # the card added when that happened sits under the others, the whole width, and the page is scrolled so it shows
    (w, h), rects = by[f"n{first}"]
    newest = [k for k in rects if k not in by[f"n{first - 1}"][1]][0]
    x, y, cw, ch = rects[newest]
    if not (x == 0 and cw == w and y >= max(v[1] + v[3] for k, v in rects.items() if k != newest) + GAP - 1):
        probs.append(f"{newest} at {x},{y} {cw}x{ch} isn't a row under the others in a {w}-wide Board")
    scrolls = _scroll(out)  # (one per card added, after it)
    for n in range(3, 8):  # every card added is in view (the page scrolled to it when it went below the fold)
        added = [k for k in by[f"n{n}"][1] if k not in by[f"n{n - 1}"][1]][0]
        top = by[f"n{n}"][1][added][1]
        value, upper, page = scrolls[n - 3]
        if not (value <= top < value + page):
            probs.append(f"n{n}: {added} (top {top}) not in view: page scrolled {value}, shows {page}")
    value = scrolls[first - 3][0]
    (sw, sh), srects = by["smaller"]
    if sw > by["n7"][0][0] - 100:
        probs.append(f"the window went 1440x900 -> 1280x800 but the Board is {sw} wide (was {by['n7'][0][0]})")
    probs += [f"smaller: {p}" for p in g.tiled((sw, sh), srects)]
    if probs:
        return False, "GTK six: " + "; ".join(probs)[:800]
    return True, f"GTK: 7 cards on 1440x900, each at least {MIN_W}x{MIN_H}; card {first} went below ({newest}, Board {room[1]} -> {by['n' + str(first)][0][1]}), scrolled into view ({value}); window 1280x800 still tiles"


CARDS = """() => { const b = document.querySelector('.board'), sc = b.parentElement;
  return { board: [b.offsetWidth, b.offsetHeight], scroll: [Math.round(sc.scrollTop), sc.scrollHeight, sc.clientHeight, getComputedStyle(sc).overflowY],
           cards: [...b.querySelectorAll(':scope > [data-tag]')].map(e => [e.dataset.tag, e.offsetLeft, e.offsetTop, e.offsetWidth, e.offsetHeight]) }; }"""


def _web(g, full):
    import drive

    fleet, limits = full / "fleet.csv", full / "limits.csv"
    seen = {}
    notes = []

    def read(page, label):
        s = page.evaluate(CARDS)
        s["cards"] = {c[0]: tuple(c[1:]) for c in s["cards"]}
        s["board"] = [s["board"][0], max(v[1] + v[3] for v in s["cards"].values())]  # (the cards' bottom: the box itself fills the room)
        seen[label] = s
        return s

    def step(page, text):
        drive.step(page, text)
        drive.settle(page)

    def corner(page, tag, dy):
        """The card's corner dragged `dy` with the mouse, as a hand does: the page scrolled until the corner shows first."""
        page.evaluate("""(tag) => { const o = document.querySelector(`.board > [data-tag=${tag}]`), sc = o.closest('.board-scroll');
          const r = o.getBoundingClientRect(), v = sc.getBoundingClientRect(); sc.scrollTop += r.bottom - (v.bottom - 90); }""", tag)
        box = page.locator(f"[data-kind=object][data-tag={tag!r}]").first.bounding_box()
        sx, sy = box["x"] + box["width"] - 8, box["y"] + box["height"] - 8
        page.mouse.move(sx, sy)
        page.mouse.down()
        page.mouse.move(sx, sy + dy / 2)
        page.mouse.move(sx, sy + dy)
        page.mouse.up()
        step(page, "wait:1200")

    def during(page):
        step(page, f"pick:Table={limits}")
        page.locator('[data-tag="close-limits"]').first.wait_for(state="attached", timeout=60000)
        step(page, "wait:800")
        step(page, "tap:Chart")
        step(page, "wait:1000")
        read(page, "before")
        page.screenshot(path=str(OUT / "web-1-before.png"))
        step(page, "resize:table=0,600")
        step(page, "wait:1200")
        read(page, "grown")
        page.evaluate("() => { const sc = document.querySelector('.board').parentElement; sc.scrollTop = sc.scrollHeight; }")
        step(page, "wait:300")
        read(page, "bottom")
        page.screenshot(path=str(OUT / "web-2-grown-bottom.png"))
        page.evaluate("() => { document.querySelector('.board').parentElement.scrollTop = 0; }")
        corner(page, "chart0", -700)  # (a hand can only drag as far as the window is high)
        read(page, "shrunk")
        for n in range(4, 8):
            step(page, "tap:Chart")
            step(page, "wait:1000")
            read(page, f"n{n}")
        page.screenshot(path=str(OUT / "web-3-seven-cards.png"))
        return "WEB: done\n"

    r, out = drive.web_run(ROOT / "build/omxplorer/web", f"pick:Choose a file={fleet};wait:Create table;tap:Create table;wait:1500",
                           shot=str(OUT / "web-final.png"), viewport=(1440, 900), color_scheme="light", during=during)
    if r.returncode or len(seen) < 8:
        return False, f"web run: exit {r.returncode}, saw {list(seen)}: {out[-600:]}"
    probs = []

    def tiled(label):
        (bw, bh) = seen[label]["board"]
        return [f"{label}: {p}" for p in g.tiled((bw, bh), {k: v for k, v in seen[label]["cards"].items()})]

    b, gr = seen["before"], seen["grown"]
    if not _near(gr["cards"]["table"][3] - b["cards"]["table"][3], 600):
        probs.append(f"the table is {gr['cards']['table'][3] - b['cards']['table'][3]} pt taller after a 600 pt drag")
    if gr["board"][1] != b["board"][1] + 600:
        probs.append(f"the Board went {b['board']} -> {gr['board']} (cards {b['cards']} -> {gr['cards']})")
    sc = seen["bottom"]["scroll"]
    if sc[3] not in ("auto", "scroll") or sc[1] <= sc[2] or sc[0] + sc[2] < sc[1] - 1:
        probs.append(f"the page scrolled to {sc[0]} of {sc[1]} (page {sc[2]}, overflow {sc[3]})")
    if seen["shrunk"]["board"][1] != b["board"][1]:
        probs.append(f"shrunk Board {seen['shrunk']['board']}, was {b['board']}")
    for label in ("before", "grown", "shrunk") + tuple(f"n{n}" for n in range(4, 8)):
        probs += tiled(label)
        probs += [f"{label}: {k} {v[2]}x{v[3]} under {MIN_W}x{MIN_H}" for k, v in seen[label]["cards"].items() if v[2] < MIN_W or v[3] < MIN_H]
    for n in range(4, 8):  # every card added is in view
        before = seen["shrunk" if n == 4 else f"n{n - 1}"]["cards"]
        added = [k for k in seen[f"n{n}"]["cards"] if k not in before][0]
        top, (value, _, page, _) = seen[f"n{n}"]["cards"][added][1], seen[f"n{n}"]["scroll"]
        if not (value <= top < value + page):
            probs.append(f"n{n}: {added} (top {top}) not in view: page scrolled {value}, shows {page}")
    n7 = seen["n7"]
    if len(n7["cards"]) != 7 or n7["board"][1] <= seen["before"]["board"][1]:
        probs.append(f"seven cards: {len(n7['cards'])} cards, Board {n7['board']}")
    if probs:
        return False, "web: " + "; ".join(probs)[:800]
    return True, (f"web: the table +{gr['cards']['table'][3] - b['cards']['table'][3]} for 600 pt (Board {b['board'][1]} -> {gr['board'][1]}, scroll {sc[0]}+{sc[2]} of {sc[1]}); "
                  f"shrunk back to {seen['shrunk']['board'][1]}; 7 cards each >= {MIN_W}x{MIN_H}, Board {n7['board'][1]}")


def check():
    os.environ["OMX_CANVAS"] = "tiled"  # (goal 78: this proof measures the tiling, which omxplorer keeps as "Tile the cards"; the free canvas is the default now)
    full = _full()
    if full is None:
        return None, f"no fleet.csv + telemetry.parquet in {DATA} (goal 47's robot data)"
    OUT.mkdir(parents=True, exist_ok=True)
    g = _g54()
    ok, why = _units(g)
    if not ok:
        return False, why
    parts = [why]
    g.build_app()
    for fn in (_gtk_grow, _gtk_six):
        ok, why = fn(g, full)
        if not ok:
            return False, why
        parts.append(why)
    r = g.run(["scripts/build.sh", "omxplorer", "web"], 3600)
    if r.returncode:
        return False, "web build failed: " + (r.stdout + r.stderr)[-800:]
    ok, why = _web(g, full)
    if not ok:
        return False, why
    parts.append(why)
    return True, "; ".join(parts) + f"; shots {OUT}"
