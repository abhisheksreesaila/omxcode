"""Goal 78 M1: a free canvas, a framework piece (docs/goals/78.md). `check() -> (ok, why)`.

1. the unit tests of mojoui.freeboard (handles, move, resize, snap, extent, first free spot, sync, Tidy, keys, zoom, FreeCanvas);
2. omxplorer on GTK (headless 1440x900, fleet.csv + telemetry.parquet), real drags through the host's own gesture signals:
   telemetry goes to the first free spot and the table doesn't move; the table's right edge dragged 900 pt past the window (every
   motion frame read from GTK's layout) leaves the telemetry card untouched, the canvas grows and scrolls right to its edge; each
   of the 8 handles of the telemetry card resizes it live (its box read at every frame, the cursor over each handle named), the
   table untouched, overlap allowed; a snapped drag shows its guide line; a new chart goes to a free spot, nothing moves;
   Ctrl+- four times (33 %) shows every card, Ctrl+0 and Ctrl+wheel come back; Super+T tiles with no overlap;
3. the same on the web host with Chromium's real mouse and keyboard, read from the page's own boxes.
Shots in build/g78/m1-*.png.
"""
import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("g78common", HERE / "common.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)

HANDLES = [("n", 0, -60), ("s", 0, 80), ("e", 160, 0), ("w", 60, 0), ("ne", 100, -40), ("nw", 40, -32), ("sw", -48, 60), ("se", 72, 40)]
CURSOR = {"n": "ns-resize", "s": "ns-resize", "e": "ew-resize", "w": "ew-resize", "ne": "nesw-resize", "sw": "nesw-resize", "nw": "nwse-resize", "se": "nwse-resize", "move": "move"}
STEPS = 4


def resized(r, handle, dx, dy):
    """What mojoui.freeboard.drag_rect gives without snap (no minimum reached in these drags)."""
    x, y, w, h = r
    left, top, right, bottom = x, y, x + w, y + h
    if "w" in handle:
        left = max(x + dx, 0)
    if "e" in handle:
        right += dx
    if "n" in handle:
        top = max(y + dy, 0)
    if "s" in handle:
        bottom += dy
    return (left, top, right - left, bottom - top)


def units():
    labels = ["handles", "move", "resize", "snap", "nosnap", "extent", "free", "sync", "tidy", "keys", "fill", "zoom", "canvas", "act", "events", "setzoom", "rebase"]
    ok, out, missing = c.mojo_test("tests/test_freeboard.mojo", labels)
    return (True, f"test_freeboard {len(labels)} ok") if ok else (False, f"test_freeboard: missing {missing}: {out[-600:]}")


def gtk():
    d = c.DATA
    steps = ["waitfor:Create table=60000", "tap:Create table", "waitfor:Links=60000", "pause:800", "boards:launch",
             f"pick:Table={d / 'telemetry.parquet'}", "waitfor:close-telemetry=120000", "pause:1500", "boards:tele",
             "boardscroll:0", "freedrag:table=e,900,0,6,alt", "pause:300", "boards:wide", "boardscrollx:end", "pause:300", f"shot:{c.OUT}/m1-gtk-1-wide-scrolled-right.png",
             "boardscrollx:0", "pause:200"]
    for h, dx, dy in HANDLES:
        steps += [f"freedrag:tablecard0={h},{dx},{dy},{STEPS},alt", "pause:200"]
    steps += ["boards:handles", f"shot:{c.OUT}/m1-gtk-2-eight-handles.png",
              "freedrag:tablecard0=move,-46,0,4", "pause:200", "boards:snapped",  # (left edge 50 → 4, within 8 of the table's 0: snaps, a guide)
              "shortcut:Ctrl+Shift+C", "pause:1500", "boards:chart",
              "shortcut:Ctrl+-", "pause:300", "shortcut:Ctrl+-", "pause:300", "shortcut:Ctrl+-", "pause:300", "shortcut:Ctrl+-", "pause:600", "boardscroll:0", "boardscrollx:0", "pause:300",
              "boards:zoomed", f"shot:{c.OUT}/m1-gtk-3-zoomed-out.png",
              "shortcut:Ctrl+0", "pause:600", "boards:actual", "ctrlwheel:1", "pause:500", "boards:wheel", "ctrlwheel:-1", "pause:500", "boards:wheelback",
              "shortcut:Super+T", "pause:800", "boardscroll:0", "boardscrollx:0", "boards:tidy", f"shot:{c.OUT}/m1-gtk-4-tidy.png"]
    out = c.gtk(steps, "m1-gtk", open_path=d / "fleet.csv")
    b = c.boards(out)
    probs = []
    launch, tele = b["launch"], b["tele"]
    room = launch["room"]
    if launch["size"][1] > room[1] or launch["size"][0] > room[0]:
        probs.append(f"launch: the canvas {launch['size']} is bigger than its room {room} (it would scroll)")
    t0 = tele["cards"]["table"]
    card = tele["cards"].get("tablecard0")
    if t0 != launch["cards"]["table"]:
        probs.append(f"the table moved when telemetry came: {launch['cards']['table']} -> {t0}")
    if not card or card[0] != 0 or card[1] != t0[1] + t0[3] + c.GAP:
        probs.append(f"telemetry at {card}, not the first free spot under the table (0, {t0[1] + t0[3] + c.GAP})")
    # the table 900 wider, live
    drags = c.drags(out)
    wide = drags[0]
    frames = wide[3]
    want = [t0[2] + 900 * k // 6 for k in range(1, 7)]
    if [f[2] for f in frames] != want:
        probs.append(f"the table's width on each motion frame {[f[2] for f in frames]}, not {want}")
    if wide[2] != "ew-resize":
        probs.append(f"the cursor over the table's right edge: {wide[2]}")
    w1 = b["wide"]
    if w1["cards"]["tablecard0"] != card:
        probs.append(f"telemetry changed when the table grew: {card} -> {w1['cards']['tablecard0']}")
    if w1["cards"]["table"][2] != t0[2] + 900 or w1["size"][0] < t0[2] + 900 + 1:
        probs.append(f"the table {w1['cards']['table']} / canvas {w1['size']} after a 900 pt drag")
    sx = c.scroll(out, "x")[0]
    if sx[1] < w1["size"][0] or sx[0] + sx[2] < sx[1] - 1:
        probs.append(f"scrolled right: {sx[0]} + {sx[2]} of {sx[1]} (canvas {w1['size'][0]})")
    # the 8 handles, each live
    r = card
    for (h, dx, dy), dr in zip(HANDLES, drags[1:9]):
        if dr[1] != h or dr[2] != CURSOR[h]:
            probs.append(f"{h}: cursor {dr[2]!r} (want {CURSOR[h]})")
        exp = [resized(r, h, dx * k // STEPS, dy * k // STEPS) for k in range(1, STEPS + 1)]
        if dr[3] != exp:
            probs.append(f"{h}: frames {dr[3]} not {exp}")
        r = exp[-1]
    hb = b["handles"]
    if hb["cards"]["tablecard0"] != r:
        probs.append(f"after the 8 handles telemetry is {hb['cards']['tablecard0']}, not {r}")
    if hb["cards"]["table"] != w1["cards"]["table"]:
        probs.append(f"the table changed under the telemetry card's drags: {w1['cards']['table']} -> {hb['cards']['table']}")
    if not c.overlaps(hb["cards"]["table"], hb["cards"]["tablecard0"]):
        probs.append("the telemetry card was dragged over the table but they don't overlap (overlap is allowed)")
    snap = drags[9]
    sn = b["snapped"]["cards"]["tablecard0"]
    if sn[0] != 0 or not snap[4]:
        probs.append(f"a move to x 4 (8 from the table's edge) landed at {sn[0]} with guides {snap[4]}")
    ch = b["chart"]
    new = [k for k in ch["cards"] if k not in b["snapped"]["cards"]]
    if len(new) != 1:
        probs.append(f"Ctrl+Shift+C added {new}")
    else:
        for k, v in b["snapped"]["cards"].items():
            if ch["cards"][k] != v:
                probs.append(f"{k} moved when the chart came: {v} -> {ch['cards'][k]}")
        for k, v in ch["cards"].items():
            if k != new[0] and c.overlaps(v, ch["cards"][new[0]]):
                probs.append(f"the new chart {ch['cards'][new[0]]} covers {k} {v}")
    z = b["zoomed"]
    if z["zoom"] != 33:
        probs.append(f"Ctrl+- four times: zoom {z['zoom']} (want 33: 100, 80, 67, 50, 33)")
    for k, (x, y, w, h) in z["cards"].items():
        if x + w > z["room"][0] + 1 or y + h > z["room"][1] + 1:
            probs.append(f"zoomed out, {k} ends at {x + w},{y + h}, outside the window's {z['room']}")
        ax, ay, aw, ah = z["asked"][k]
        if not (c.near(w, aw * z["zoom"] // 100, 2) and c.near(x, ax * z["zoom"] // 100, 2)):
            probs.append(f"zoomed out, {k} is {x},{y} {w}x{h} for {ax},{ay} {aw}x{ah} at {z['zoom']} %")
    if b["actual"]["zoom"] != 100 or b["actual"]["cards"] != ch["cards"]:
        probs.append(f"Ctrl+0: zoom {b['actual']['zoom']}, cards {b['actual']['cards']} (were {ch['cards']})")
    if b["wheel"]["zoom"] != 91 or b["wheelback"]["zoom"] != 100:
        probs.append(f"Ctrl+wheel out then in: zoom {b['wheel']['zoom']} then {b['wheelback']['zoom']} (want 91, 100)")
    t = b["tidy"]
    probs += [f"Tidy: {p}" for p in c.any_overlap(t["cards"])]
    for k, (x, y, w, h) in t["cards"].items():
        if x < 0 or x + w > t["room"][0] + 1:
            probs.append(f"Tidy: {k} at {x},{y} {w}x{h} outside the room's width {t['room'][0]}")
    slow = [l for l in out.splitlines() if l.startswith("SLOW:") and "msg=" in l]
    if probs:
        return False, "GTK: " + "; ".join(probs)[:1500]
    return True, (f"GTK: telemetry at the first free spot {card}; the table {t0[2]} -> {t0[2] + 900} over 6 live frames, telemetry untouched, "
                  f"scrolled right {sx[0]}+{sx[2]} of {sx[1]}; 8 handles live ({STEPS} frames each, cursors right), final {r}; snap guide; "
                  f"chart at a free spot; zoom 33 % shows all {len(z['cards'])} cards; Ctrl+0, wheel 91 -> 100; Tidy: no overlap"
                  + (f"; {len(slow)} SLOW update lines (see m1-gtk.log)" if slow else ""))


# Heights (review 1): a chart's and the table's S and NW handles change sizes inside the card too (the chart's canvas, the grid);
# then a second drag of the same card must start where the first ended.
HEIGHTS = [("chart0", "s", 0, 80, ""), ("chart0", "nw", 40, -60, ""), ("chart0", "s", 0, 60, ""), ("table", "s", 0, -120, ""),
           ("table", "nw", 32, 40, ""), ("table", "s", 0, 48, ""),
           # (review 2: half way the page scrolls and the app hears "view", the button still held: the drag must not rebase)
           ("chart0", "e", 120, 0, "view"), ("table", "s", 0, 60, "view"),
           # (review 3: half way a Ctrl+wheel notch zooms out to 91 %, the button still held; last, so the drags before it are at 100 %)
           ("chart0", "e", 120, 0, "zoom")]


def expect_heights(cards, frames_of, label, tol=0, zoom_after=None):
    """Each drag's frames against resized() from where the last one on that card ended; ([problems], final rects).
    The model for a zoom half way (frame m = STEPS // 2), with P_k the pointer's movement since the press in screen points and the
    zoom z0 = 1 before, z1 after: frame k <= m is the start + P_k / z0; frame k > m is frame m's rect + (P_k - P_m) / z1 (the
    hosts restart the press where the last frame sent was, at the new zoom; the app truncates offsets to whole points)."""
    probs, now = [], dict(cards)
    m = STEPS // 2
    for (tag, h, dx, dy, mode), frames in zip(HEIGHTS, frames_of):
        if mode == "zoom":
            z1 = (zoom_after or 100) / 100
            rm = resized(now[tag], h, int(dx * m / STEPS), int(dy * m / STEPS))
            exp = [resized(now[tag], h, int(dx * k / STEPS), int(dy * k / STEPS)) if k <= m else
                   resized(rm, h, int((dx * k / STEPS - dx * m / STEPS) / z1), int((dy * k / STEPS - dy * m / STEPS) / z1)) for k in range(1, STEPS + 1)]
        else:
            exp = [resized(now[tag], h, round(dx * k / STEPS), round(dy * k / STEPS)) for k in range(1, STEPS + 1)]
        t = max(tol, 1) if mode == "zoom" else tol  # (a zoomed card's box is read back through the zoom: a point of rounding)
        if len(frames) != STEPS or any(max(abs(a - b) for a, b in zip(f, e)) > t for f, e in zip(frames, exp)):
            probs.append(f"{label} {tag} {h} {dx},{dy} {mode}: frames {frames} not {exp}")
        now[tag] = exp[-1]
    return probs, now


def gtk_heights():
    d = c.DATA
    steps = ["waitfor:Create table=60000", "tap:Create table", "waitfor:Links=60000", "pause:800", "shortcut:Ctrl+Shift+C", "pause:1500", "boardscroll:0", "boards:h0"]
    for tag, h, dx, dy, mode in HEIGHTS:
        steps += [f"freedrag:{tag}={h},{dx},{dy},{STEPS},alt" + ("+" + mode if mode else ""), "pause:300", f"boards:h-{tag}-{h}-{dy}-{mode}"]
    steps.append(f"shot:{c.OUT}/m1-gtk-5-heights.png")
    out = c.gtk(steps, "m1-gtk-heights", open_path=d / "fleet.csv")
    b = c.boards(out)
    dr = c.drags(out)
    zl = [l.split() for l in out.splitlines() if l.startswith("LIVEZOOM: ")]
    z1 = int(zl[0][-1]) if zl else None
    probs, final = expect_heights(b["h0"]["cards"], [x[3] for x in dr], "GTK", zoom_after=z1)
    last = b["h-chart0-e-0-zoom"]["asked"]  # (page points: the board is at 91 % by then)
    if out.count("LIVEVIEW: ") != 2:
        probs.append(f"GTK: {out.count('LIVEVIEW: ')} mid-drag scrolls, not 2")
    if z1 != 91:
        probs.append(f"GTK: the mid-drag Ctrl+wheel left the zoom at {z1} (want 91)")
    for tag in ("chart0", "table"):
        if last[tag] != final[tag]:
            probs.append(f"GTK: {tag} ended at {last[tag]}, its last frame said {final[tag]}")
    if probs:
        return False, "GTK heights: " + "; ".join(probs)[:1200]
    return True, (f"GTK: S and NW of chart0 and the table live, each second drag from where the first ended, two drags with a scroll and a "
                  f"view event half way and one with a Ctrl+wheel to {z1} % half way still exact (chart0 {final['chart0']}, table {final['table']})")


def gtk_perf():
    """~10 cards (the table, 2 table cards, 6 charts, a pivot), the table's corner dragged live over 16 frames: per frame the
    app's update + the patches applied (LIVEMS update), to the frame GTK laid out (frame), and how many canvases drew."""
    d = c.DATA
    steps = ["waitfor:Create table=60000", "tap:Create table", "waitfor:Links=60000", "pause:800",
             f"pick:Table={d / 'telemetry.parquet'}", "waitfor:close-telemetry=120000", "pause:800", f"pick:Table={d / 'limits.csv'}", "waitfor:close-limits=60000", "pause:800"]
    steps += ["shortcut:Ctrl+Shift+C", "pause:900"] * 6 + ["shortcut:Ctrl+Shift+P", "pause:1500", "boards:p0", "boardscroll:0", "pause:500",
              "freedrag:table=se,-320,-240,16,alt", "pause:500", "freedrag:tablecard0=e,240,0,16,alt", "pause:500", "boards:p1"]
    out = c.gtk(steps, "m1-gtk-perf", open_path=d / "fleet.csv")
    n = len(c.boards(out)["p0"]["cards"])
    rows = [l.split() for l in out.splitlines() if l.startswith("LIVEMS: ")]
    upd = sorted(float(r[4]) for r in rows)
    frm = sorted(float(r[6]) for r in rows)
    draws = [int(r[8]) for r in rows]
    # (the SLOW lines from the drags on: the watchdog's 50 ms budget, MOJOUI_BUDGET_MS)
    after = out[out.find("CURSOR: table se"):]
    slow = [l for l in after.splitlines() if l.startswith("SLOW:")]
    med = lambda v: v[len(v) // 2]
    p95 = lambda v: v[min(len(v) - 1, int(round(0.95 * (len(v) - 1))))]
    nums = (f"{n} cards, {len(rows)} live frames: update median {med(upd):.1f} ms, p95 {p95(upd):.1f} ms, max {upd[-1]:.1f}; to the laid-out frame "
            f"median {med(frm):.1f} ms, p95 {p95(frm):.1f} ms; canvases drawn per frame after the first: max {max(draws[1:16] + draws[17:])}; SLOW at 50 ms: {len(slow)}")
    (c.OUT / "m1-perf.txt").write_text(nums + "\n")
    probs = []
    if n < 10:
        probs.append(f"only {n} cards")
    if slow:
        probs.append(f"{len(slow)} SLOW lines: {slow[:2]}")
    if max(draws[1:16] + draws[17:]) > 2:
        probs.append(f"canvases drawn per frame: {draws}")
    return (False, "GTK perf: " + "; ".join(probs) + " (" + nums + ")") if probs else (True, "GTK perf: " + nums)


def web():
    import drive
    d = c.DATA
    h = c.home("m1-web")
    env = {"OMX_DOCUMENTS": str(h / "docs"), "OMX_CONFIG": str(h / "config"), "OMX_OPEN": str(d / "fleet.csv")}
    seen = {}
    notes = []

    def during(page):
        s0 = page.evaluate(c.CARDS_JS)
        seen["tele"] = s0
        cur, frames = c.web_drag(page, "table", "e", 900, 0, steps=6, alt=True)
        seen["wide_frames"] = frames
        seen["wide_cursor"] = cur
        page.wait_for_timeout(600)
        seen["wide"] = page.evaluate(c.CARDS_JS)
        page.evaluate("() => { const sc = document.querySelector('.board').parentElement; sc.scrollLeft = sc.scrollWidth; }")
        page.wait_for_timeout(400)
        seen["scrolled"] = page.evaluate(c.CARDS_JS)
        page.screenshot(path=str(c.OUT / "m1-web-1-wide-scrolled-right.png"))
        page.evaluate("() => { const sc = document.querySelector('.board').parentElement; sc.scrollLeft = 0; sc.scrollTop = sc.scrollHeight; }")
        page.wait_for_timeout(400)
        hs = []
        for hd, dx, dy in HANDLES:
            hs.append((hd,) + c.web_drag(page, "tablecard0", hd, dx, dy, steps=STEPS, alt=True,
                                         shot=c.OUT / "m1-web-2-live-resize-mid-drag.png" if hd == "se" else None))
        seen["handles"] = hs
        seen["after"] = page.evaluate(c.CARDS_JS)
        page.screenshot(path=str(c.OUT / "m1-web-2-eight-handles.png"))
        for _ in range(4):
            page.keyboard.press("Control+-")
            page.wait_for_timeout(500)
        page.evaluate("() => { const sc = document.querySelector('.board').parentElement; sc.scrollLeft = 0; sc.scrollTop = 0; }")
        page.wait_for_timeout(500)
        seen["zoomed"] = page.evaluate(c.CARDS_JS)
        page.screenshot(path=str(c.OUT / "m1-web-3-zoomed-out.png"))
        page.keyboard.press("Control+0")
        page.wait_for_timeout(600)
        seen["actual"] = page.evaluate(c.CARDS_JS)
        page.keyboard.press("Alt+t")
        page.wait_for_timeout(900)
        seen["tidy"] = page.evaluate(c.CARDS_JS)
        page.screenshot(path=str(c.OUT / "m1-web-4-tidy.png"))
        return "WEB: done\n"

    def heights(page):
        page.keyboard.press("Control+Shift+c")
        page.wait_for_timeout(1500)
        seen["h0"] = page.evaluate(c.CARDS_JS)
        hs, insides = [], []
        INNER = """() => { const o = t => document.querySelector(`.board > .object[data-tag=${t}]`);
          const cv = o('chart0').querySelector('[data-kind=canvas]'), g = o('table').querySelector('[data-tag=grid]');
          return { chart: [o('chart0').offsetHeight, cv ? cv.offsetHeight : -1], table: [o('table').offsetHeight, g ? g.offsetHeight : -1] }; }"""

        views = []  # (every "view" the page posts: BOARD_VIEW, number 13)
        page.on("request", lambda r: views.append(1) if r.method == "POST" and "number=13&" in ((r.post_data or "") + "&") else None)
        scrolls, zooms = [], []

        def scroll_and_wait(page):  # (the page scrolled 40 pt mid-drag; past the 150 ms after which the page sends "view")
            n0 = len(views)
            before = page.evaluate("() => document.querySelector('.board').parentElement.scrollTop")
            page.evaluate("""() => { const sc = document.querySelector('.board').parentElement;  // (40 pt whichever way the page can go)
              sc.scrollTop += sc.scrollTop + sc.clientHeight + 40 <= sc.scrollHeight ? 40 : -40; }""")
            page.wait_for_timeout(400)
            after = page.evaluate("() => document.querySelector('.board').parentElement.scrollTop")
            scrolls.append((before, after, len(views) - n0))

        def wheel_zoom(page):  # (a Ctrl+wheel notch out over the canvas, the button still held)
            page.keyboard.down("Control")
            page.mouse.wheel(0, 120)
            page.keyboard.up("Control")
            page.wait_for_timeout(700)
            zooms.append(page.evaluate("() => Number(document.querySelector('.board').dataset.zoom)"))

        seen["inside0"] = page.evaluate(INNER)  # (before any drag: the distance between each card and what's inside it)
        for tag, hd, dx, dy, mode in HEIGHTS:
            cur, frames = c.web_drag(page, tag, hd, dx, dy, steps=STEPS, alt=True, mid={"view": scroll_and_wait, "zoom": wheel_zoom}.get(mode),
                                     shot=c.OUT / "m1-web-5-chart-height-mid-drag.png" if (tag, hd) == ("chart0", "s") and not hs else None)
            hs.append(frames)
            page.wait_for_timeout(300)
            insides.append((tag, page.evaluate(INNER)))
        seen["insides"] = insides
        seen["scrolls"] = scrolls
        seen["zooms"] = zooms
        # (review 2: a size mark from an older screen is dropped; one for this screen is applied: the guard, then the path)
        seen["marks"] = page.evaluate("""async () => {
          const g = document.querySelector('[data-tag=grid]'), id = g.id.slice(1), box = document.getElementById('mojoui-sizes'), v = document.getElementById('mojoui-v').value;
          const before = g.style.height, put = (ver, h) => { const m = document.createElement('i'); m.hidden = true; m.dataset.kind = 'size';
            Object.assign(m.dataset, { node: id, v: ver, w: '0', h: String(h), minw: '0', maxw: '0' }); box.append(m); };
          put(String(Number(v) - 1), 77); await new Promise(r => setTimeout(r, 200));
          const stale = [g.style.height, box.children.length];
          put(v, 333); await new Promise(r => setTimeout(r, 200));
          const fresh = g.style.height; g.style.height = before;
          return { before, stale, fresh }; }""")
        seen["hdrags"] = hs
        seen["h1"] = page.evaluate(c.CARDS_JS)
        # (review 4: a Ctrl+wheel after the last frame, then a release with no move: the card stays where that frame left it)
        zn = len(zooms)
        _, zf = c.web_drag(page, "chart0", "e", 60, 0, steps=STEPS, alt=True, before_up=wheel_zoom)
        page.wait_for_timeout(400)
        seen["zoomend"] = {"last": list(zf[-1]), "after": list(page.evaluate(c.CARDS_JS)["cards"]["chart0"][:4]), "zoomed": len(zooms) > zn,
                           "zoom": zooms[-1] if zooms else None}
        # (review 5: a release the page never saw (Alt+Tab, let go elsewhere): the pointer comes back 400 pt away with no button
        # held; the drag ends where its last frame left the card, not there)
        def lost_release(page):
            page.evaluate("""() => window.dispatchEvent(new PointerEvent('pointermove', { pointerId: 1, pointerType: 'mouse', isPrimary: true,
              buttons: 0, clientX: 30, clientY: 30, bubbles: true }))""")
            page.wait_for_timeout(600)
        _, lf = c.web_drag(page, "chart0", "e", -60, 0, steps=STEPS, alt=True, before_up=lost_release)
        page.wait_for_timeout(400)
        seen["lostup"] = {"last": list(lf[-1]), "after": list(page.evaluate(c.CARDS_JS)["cards"]["chart0"][:4])}
        inner = page.evaluate("() => { const o = document.querySelector('.board > .object[data-tag=chart0]'), cv = o.querySelector('[data-kind=canvas]');"
                              " return [o.offsetHeight, cv ? cv.offsetHeight : -1]; }")
        seen["inner"] = inner
        page.screenshot(path=str(c.OUT / "m1-web-5-heights.png"))
        return "WEB: heights\n"

    steps = ";".join(["wait:Create table", "tap:Create table", "wait:Links", "pause:800", "tap:Insert", "pause:300",
                      f"pick:Table={d / 'telemetry.parquet'}", "pause:5000"])
    r, out = drive.web_run(c.WEB, steps, viewport=(c.W, c.H), color_scheme="light", env=env, during=during)
    (c.OUT / "m1-web.log").write_text(out)
    if r.returncode != 0 or "zoomed" not in seen or "tidy" not in seen:
        return False, f"web run: exit {r.returncode}, saw {list(seen)}: {out[-800:]}"
    h = c.home("m1-web-h")
    seen2 = {}
    r2, out2 = drive.web_run(c.WEB, "wait:Create table;tap:Create table;wait:Links;pause:800", viewport=(c.W, c.H), color_scheme="light",
                             env={"OMX_DOCUMENTS": str(h / "docs"), "OMX_CONFIG": str(h / "config"), "OMX_OPEN": str(d / "fleet.csv")},
                             during=heights)
    (c.OUT / "m1-web-heights.log").write_text(out2)
    if r2.returncode != 0 or "hdrags" not in seen:
        return False, f"web heights run: exit {r2.returncode}: {out2[-600:]}"
    probs = []
    wz = seen["zooms"][0] if seen["zooms"] else None
    hp, final = expect_heights({k: tuple(v[:4]) for k, v in seen["h0"]["cards"].items()}, seen["hdrags"], "web", tol=2, zoom_after=wz)
    if wz != 91:
        hp.append(f"web: the mid-drag Ctrl+wheel left the zoom at {wz} (want 91)")
    for before, after, posted in seen["scrolls"]:  # (review 3: the scroll really happened, and the page told the app before the next frame)
        if abs(after - before) < 39 or posted < 1:
            hp.append(f"web: the mid-drag scroll went {before} -> {after} with {posted} view posts (want 40 pt, and at least one post before the next frame)")
    probs += hp
    endc = {k: tuple(v[:4]) for k, v in seen["h1"]["cards"].items()}
    for tag in ("chart0", "table"):
        if max(abs(a - b) for a, b in zip(endc[tag], final[tag])) > 2:
            probs.append(f"web: {tag} ended at {endc[tag]}, its last frame said {final[tag]}")
    if seen["inner"][1] <= 0 or seen["inner"][1] > seen["inner"][0]:
        probs.append(f"web: chart0's canvas {seen['inner'][1]} tall in a {seen['inner'][0]} card")
    ze = seen["zoomend"]
    if not ze["zoomed"] or ze["zoom"] in (None, wz) or max(abs(x - y) for x, y in zip(ze["last"], ze["after"])) > 2:
        probs.append(f"web: zoom ({wz} -> {ze['zoom']}) after the last frame, then a release: chart0 at {ze['after']}, its last frame said {ze['last']}")
    lu = seen["lostup"]
    if max(abs(x - y) for x, y in zip(lu["last"], lu["after"])) > 2:
        probs.append(f"web: a release the page never saw, the pointer back at (30, 30): chart0 at {lu['after']}, its last frame said {lu['last']}")
    mk = seen["marks"]
    if mk["stale"] != [mk["before"], 0] or mk["fresh"] != "333px":
        probs.append(f"web size marks: a stale one left the grid at {mk['stale']} (was {mk['before']!r}), a current one set {mk['fresh']!r} (want 333px)")
    # (after every drag, what's inside the dragged card followed it: the table's grid and the chart's canvas keep the distance to
    # their card's height they had before any drag (the table: its 44 pt title band plus the card's padding, 66 on the web))
    i0 = seen["inside0"]
    gaps = {"table": i0["table"][0] - i0["table"][1], "chart": i0["chart"][0] - i0["chart"][1]}
    for tag, ins in seen["insides"]:
        key = "table" if tag == "table" else "chart"
        card_h, inner_h = ins[key]
        if inner_h <= 0 or abs((card_h - inner_h) - gaps[key]) > 2:
            probs.append(f"web: after a {tag} drag what's inside is {inner_h} tall in a {card_h} card (before any drag: {gaps[key]} less)")
    t0 = seen["tele"]["cards"]["table"][:4]
    card = seen["tele"]["cards"].get("tablecard0", [None] * 4)[:4]
    if card[0] != 0 or card[1] != t0[1] + t0[3] + c.GAP:
        probs.append(f"telemetry at {card}, not the first free spot under the table")
    want = [t0[2] + round(900 * k / 6) for k in range(1, 7)]
    got = [f[2] for f in seen["wide_frames"]]
    if any(abs(a - b) > 2 for a, b in zip(got, want)) or len(set(got)) < 5:
        probs.append(f"the table's width per frame {got}, not {want}")
    if "ew-resize" not in seen["wide_cursor"]:
        probs.append(f"cursor over the table's right edge: {seen['wide_cursor']}")
    if seen["wide"]["cards"]["tablecard0"][:4] != card:
        probs.append(f"telemetry moved when the table grew: {card} -> {seen['wide']['cards']['tablecard0'][:4]}")
    sl, st, sw, sh, cw, chh = seen["scrolled"]["scroll"]
    if sw < t0[2] + 900 or sl + cw < sw - 1 or cw > c.W or sl <= 0:  # (the canvas scrolls inside the window; the page never widens)
        probs.append(f"scrolled right: {sl} + {cw} of {sw} (table {t0[2] + 900})")
    r0 = tuple(card)
    for hd, cur, frames in seen["handles"]:
        dx, dy = [(x, y) for (n, x, y) in HANDLES if n == hd][0]
        exp = [resized(r0, hd, round(dx * k / STEPS), round(dy * k / STEPS)) for k in range(1, STEPS + 1)]
        if any(max(abs(a - b) for a, b in zip(f, e)) > 2 for f, e in zip(frames, exp)):
            probs.append(f"web {hd}: frames {frames} not {exp}")
        if CURSOR[hd] not in cur:
            probs.append(f"web {hd}: cursor {cur} (want {CURSOR[hd]})")
        r0 = tuple(frames[-1])
    if seen["after"]["cards"]["table"][:4] != seen["wide"]["cards"]["table"][:4]:
        probs.append("the table changed under the telemetry card's drags")
    z = seen["zoomed"]
    if abs(z["zoom"] - 0.33) > 0.01:
        probs.append(f"Ctrl+- four times: zoom {z['zoom']}")
    vx, vy, vw, vh = z["view"]
    for k, v in z["cards"].items():
        if v[4] + v[6] > vx + vw + 1 or v[5] + v[7] > vy + vh + 1:
            probs.append(f"zoomed out, {k} ends at {v[4] + v[6]:.0f},{v[5] + v[7]:.0f} outside the page's {vx + vw:.0f},{vy + vh:.0f}")
    if abs(seen["actual"]["zoom"] - 1) > 0.01:
        probs.append(f"Ctrl+0: zoom {seen['actual']['zoom']}")
    tc = {k: tuple(v[:4]) for k, v in seen["tidy"]["cards"].items()}
    probs += [f"web Tidy: {p}" for p in c.any_overlap(tc)]
    if probs:
        return False, "web: " + "; ".join(probs)[:1500]
    return True, (f"web: telemetry at {card}; the table {t0[2]} -> {got[-1]} live over 6 frames, scrolled right {sl:.0f}+{cw} of {sw}; "
                  f"S and NW of chart0 and the table live, second drags from where the first ended, two with a scroll and a view half way "
                  f"(scrollTop before, after, view posts: {seen['scrolls']}), one with a Ctrl+wheel to {wz} % half way; after each drag the grid "
                  f"and the chart's canvas keep their distance to the card ({gaps['table']}, {gaps['chart']} pt); a stale size mark dropped, a current one applied; "
                  f"8 handles live with their cursors; zoom 33 % shows all {len(z['cards'])} cards; Ctrl+0; Alt+T tidy: no overlap")


def check():
    if not (c.DATA / "fleet.csv").exists():
        return None, f"no DROID data in {c.DATA}"
    c.OUT.mkdir(parents=True, exist_ok=True)
    parts = []
    ok, why = units()
    if not ok:
        return False, why
    parts.append(why)
    c.build(("omxplorer", "linux"))
    for fn in (gtk, gtk_heights, gtk_perf):
        ok, why = fn()
        if not ok:
            return False, why
        parts.append(why)
    c.build(("omxplorer", "web"))
    ok, why = web()
    if not ok:
        return False, why
    parts.append(why)
    return True, "; ".join(parts) + f"; shots {c.OUT}/m1-*.png"
