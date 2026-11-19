"""Goal 78 M2: Hyprland-style keys (docs/goals/78.md). `check() -> (ok, why)`.

omxplorer with fleet.csv + telemetry.parquet on the free canvas. A click in a card focuses it (its ring: BOARDFOCUS / the page's
data-tone 5). Then, on Super and again on Alt (Hyprland grabs Super+arrows before an app sees them):
  Super+Down / Alt+Down focus the nearest card below, Super+Up / Alt+Up back;
  Super+Shift+Right / Shift+Alt+Left move it 32 pt; Super+Shift+Alt+Right / Ctrl+Shift+Alt+Left 8 pt;
  Super+Ctrl+Right / Ctrl+Alt+Left grow / shrink its width 32; Super+Ctrl+Up / Ctrl+Alt+Down its height;
  Super+F / Alt+F fill the visible window with it, the same again puts it back; Super+T / Alt+T tidy (no overlap);
  the arrows alone still move the table's selection (the cards stay put).
GTK through the window's own key controller (shortcut: steps), the web with Chromium's real keyboard (Meta is the Super key on
Linux). Shots in build/g78/m2-*.png.
"""
import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("g78common", HERE / "common.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)

# (the key, the step's name, what it does to the focused card: (dx, dy, dw, dh), or "focus:<tag>", "fill", "unfill", "tidy")
SUPER = [("Super+ArrowDown", "s1", "focus:tablecard0"), ("Super+Shift+ArrowRight", "s2", (32, 0, 0, 0)), ("Super+Shift+Alt+ArrowRight", "s3", (8, 0, 0, 0)),
         ("Super+Ctrl+ArrowRight", "s4", (0, 0, 32, 0)), ("Super+Ctrl+ArrowUp", "s5", (0, 0, 0, -32)), ("Super+Ctrl+ArrowDown", "s6", (0, 0, 0, 32)),
         ("Super+F", "s7", "fill"), ("Super+F", "s8", "unfill"), ("Super+ArrowUp", "s9", "focus:table"), ("Super+T", "s10", "tidy")]
ALT = [("Alt+ArrowRight", "a1", "focus:tablecard0"),  # (after Tidy telemetry sits right of the table)
       ("Shift+Alt+ArrowLeft", "a2", (-32, 0, 0, 0)), ("Ctrl+Shift+Alt+ArrowLeft", "a3", (-8, 0, 0, 0)),
       ("Ctrl+Alt+ArrowLeft", "a4", (0, 0, -32, 0)), ("Ctrl+Alt+ArrowDown", "a5", (0, 0, 0, 32)), ("Ctrl+Alt+ArrowUp", "a6", (0, 0, 0, -32)),
       ("Alt+F", "a7", "fill"), ("Alt+F", "a8", "unfill"), ("Alt+ArrowLeft", "a9", "focus:table"), ("Alt+T", "a10", "tidy")]


def expect(seq, before, focus_before, cards, focus_of, view_of, label):
    """Each step of `seq` against the dump before it: the focused card moved/resized as the key says, every other card
    still; focus moves; fill fills the visible part (view_of(step) -> (x, y, w, h)) and comes back; tidy: no overlap."""
    probs = []
    prev, pf = before, focus_before
    filled_from = None
    for key, step, want in seq:
        now, nf = cards(step), focus_of(step)
        if isinstance(want, str) and want.startswith("focus:"):
            if nf != want[6:]:
                probs.append(f"{label} {key}: focus {nf}, not {want[6:]}")
            if now != prev:
                probs.append(f"{label} {key}: a focus key moved cards")
        elif want == "fill":
            filled_from = prev[pf]
            v = view_of(step)
            r = now[pf]
            if v and (abs(r[0] - v[0]) > 2 or abs(r[1] - v[1]) > 2 or abs(r[2] - (v[2] - c.GAP)) > 2 or abs(r[3] - (v[3] - c.GAP)) > 2):
                probs.append(f"{label} {key}: {pf} at {r}, not filling the visible {v}")
            if r == filled_from:
                probs.append(f"{label} {key}: {pf} stayed {r}")
        elif want == "unfill":
            if now[pf] != filled_from:
                probs.append(f"{label} {key} again: {pf} at {now[pf]}, not back at {filled_from}")
        elif want == "tidy":
            probs += [f"{label} {key}: {p}" for p in c.any_overlap(now)]
        else:
            dx, dy, dw, dh = want
            x, y, w, h = prev[pf]
            exp = (max(x + dx, 0), max(y + dy, 0), w + dw, h + dh)
            if now[pf] != exp:
                probs.append(f"{label} {key}: {pf} {prev[pf]} -> {now[pf]}, not {exp}")
            for k, v in now.items():
                if k != pf and v != prev.get(k):
                    probs.append(f"{label} {key}: {k} moved too ({prev.get(k)} -> {v})")
        prev, pf = now, nf
    return probs


def gtk():
    d = c.DATA
    steps = ["waitfor:Create table=60000", "tap:Create table", "waitfor:Links=60000", "pause:800",
             f"pick:Table={d / 'telemetry.parquet'}", "waitfor:close-telemetry=120000", "pause:1500", "boardscroll:0", "pause:400",
             "hold:telemetry=40", "release:", "pause:300", "boards:p0",  # (a press on a card, through the Board's own gesture: it takes the focus)
             "tapat:grid=300,200", "pause:400", "boards:f0", f"shot:{c.OUT}/m2-gtk-0-focused.png"]
    for seq in (SUPER, ALT):
        for key, step, want in seq:
            if want == "fill":
                steps += ["boardscroll:now", "boardscrollx:now"]
            steps += [f"shortcut:{key}", "pause:400", f"boards:{step}"]
            if step in ("s7", "a2"):
                steps.append(f"shot:{c.OUT}/m2-gtk-{step}-{key.replace('+', '-')}.png")
    steps += ["tapat:grid=300,200", "pause:300", "boards:k0", "key:grid=ArrowDown", "pause:300", "key:grid=ArrowDown", "pause:300", "boards:k1"]
    out = c.gtk(steps, "m2-gtk", open_path=d / "fleet.csv")
    b = c.boards(out)
    focus = {}
    cur = None
    for line in out.splitlines():  # (each dump's focused card: its BOARDFOCUS line)
        if line.startswith("BOARDS: "):
            cur = line.split()[1]
            focus[cur] = None
        elif line.startswith("BOARDFOCUS: ") and cur:
            focus[cur] = line.split()[1]
    views = {}
    scroll_y, scroll_x = c.scroll(out), c.scroll(out, "x")  # (boardscroll:0 first; then, before each fill, the page's scroll and size)
    for i, fill_step in enumerate(["s7", "a7"]):
        if len(scroll_y) > i + 1 and len(scroll_x) > i:
            (vy, _, ph), (vx, _, pw) = scroll_y[i + 1], scroll_x[i]
            views[fill_step] = (vx, vy, pw, ph)
    probs = []
    if focus.get("p0") != "tablecard0":
        probs.append(f"a press on the telemetry card didn't focus it (focus {focus.get('p0')})")
    if focus.get("f0") != "table":
        probs.append(f"a click in the table didn't focus it (focus {focus.get('f0')})")
    cards = lambda s: b[s]["cards"]
    probs += expect(SUPER, cards("f0"), focus.get("f0"), cards, lambda s: focus.get(s), lambda s: views.get(s), "Super")
    probs += expect(ALT, cards("s10"), focus.get("s10"), cards, lambda s: focus.get(s), lambda s: views.get(s), "Alt")
    cells = [l for l in out.splitlines() if l.startswith("CELL: ")]
    rows = [int(l.split()[2]) for l in cells[-3:]]
    if len(rows) < 3 or rows[1] != rows[0] + 1 or rows[2] != rows[0] + 2:
        probs.append(f"the arrows alone didn't move the table's selection: {cells[-3:]}")
    if b["k1"]["cards"] != b["k0"]["cards"]:
        probs.append("the arrows alone moved a card")
    if probs:
        return False, "GTK: " + "; ".join(probs)[:1500]
    return True, (f"GTK: click focuses; {len(SUPER)} Super keys and {len(ALT)} Alt keys each did their one thing (focus, 32/8 pt moves, "
                  f"grow/shrink, fill and back, tidy without overlap); the arrows alone moved the table's selection rows {rows}")


def web():
    import drive
    d = c.DATA
    h = c.home("m2-web")
    env = {"OMX_DOCUMENTS": str(h / "docs"), "OMX_CONFIG": str(h / "config"), "OMX_OPEN": str(d / "fleet.csv")}
    seen, focus, views = {}, {}, {}
    status = []
    FOCUS_JS = "() => { const o = document.querySelector('.board.free > .object[data-tone=\"5\"]'); return o ? o.dataset.tag : null; }"
    STATUS_JS = "() => (document.body.innerText.match(/Selection [^\\n]*?row ([0-9,]+)/) || [null, null])[1]"

    def press(page, key):
        page.keyboard.press(key.replace("Super", "Meta").replace("Ctrl", "Control"))
        page.wait_for_timeout(600)

    def during(page):
        page.evaluate("() => { document.querySelector('.board').parentElement.scrollTop = 0; }")
        page.wait_for_timeout(500)
        g = page.locator("[data-tag=grid] canvas").first.bounding_box()
        page.mouse.click(g["x"] + g["width"] * 0.3, g["y"] + g["height"] * 0.3)
        page.wait_for_timeout(600)
        seen["f0"] = page.evaluate(c.CARDS_JS)
        focus["f0"] = page.evaluate(FOCUS_JS)
        for seq in (SUPER, ALT):
            for key, step, want in seq:
                if want == "fill":
                    s = page.evaluate(c.CARDS_JS)["scroll"]
                    views[step] = (s[0], s[1], s[4], s[5])
                press(page, key)
                seen[step] = page.evaluate(c.CARDS_JS)
                focus[step] = page.evaluate(FOCUS_JS)
                if step == "s7":
                    page.screenshot(path=str(c.OUT / "m2-web-s7-super-f-fill.png"))
        page.evaluate("() => { document.querySelector('.board').parentElement.scrollTop = 0; document.querySelector('.board').parentElement.scrollLeft = 0; }")
        page.wait_for_timeout(400)
        g = page.locator("[data-tag=grid] canvas").first.bounding_box()
        page.mouse.click(g["x"] + g["width"] * 0.3, g["y"] + g["height"] * 0.3)
        page.wait_for_timeout(500)
        seen["k0"] = page.evaluate(c.CARDS_JS)
        status.append(page.evaluate(STATUS_JS))
        page.keyboard.press("ArrowDown")
        page.wait_for_timeout(400)
        page.keyboard.press("ArrowDown")
        page.wait_for_timeout(600)
        status.append(page.evaluate(STATUS_JS))
        seen["k1"] = page.evaluate(c.CARDS_JS)
        return "WEB: done\n"

    steps = ";".join(["wait:Create table", "tap:Create table", "wait:Links", "pause:800", "tap:Insert", "pause:300",
                      f"pick:Table={d / 'telemetry.parquet'}", "pause:5000"])
    r, out = drive.web_run(c.WEB, steps, viewport=(c.W, c.H), color_scheme="light", env=env, during=during)
    (c.OUT / "m2-web.log").write_text(out)
    if r.returncode != 0 or "k1" not in seen:
        return False, f"web run: exit {r.returncode}, saw {list(seen)}: {out[-800:]}"
    cards = lambda s: {k: tuple(v[:4]) for k, v in seen[s]["cards"].items()}
    probs = []
    if focus["f0"] != "table":
        probs.append(f"a click in the table didn't focus it ({focus['f0']})")
    probs += expect(SUPER, cards("f0"), focus["f0"], cards, lambda s: focus.get(s), lambda s: views.get(s), "web Super")
    probs += expect(ALT, cards("s10"), focus["s10"], cards, lambda s: focus.get(s), lambda s: views.get(s), "web Alt")
    try:
        r0, r1 = (int(v.replace(",", "")) for v in status)
    except Exception:  # noqa: BLE001
        r0 = r1 = None
    if r0 is None or r1 != r0 + 2:
        probs.append(f"the arrows alone: the selection's row {status[0]} -> {status[1]} (want two down)")
    if cards("k1") != cards("k0"):
        probs.append("the arrows alone moved a card")
    if probs:
        return False, "web: " + "; ".join(probs)[:1500]
    return True, f"web: the same {len(SUPER) + len(ALT)} keys with the real keyboard (Meta as Super); the arrows alone: row {r0} -> {r1}"


def check():
    if not (c.DATA / "fleet.csv").exists():
        return None, f"no DROID data in {c.DATA}"
    c.OUT.mkdir(parents=True, exist_ok=True)
    c.build(("omxplorer", "linux"))
    ok, why = gtk()
    if not ok:
        return False, why
    parts = [why]
    c.build(("omxplorer", "web"))
    ok, why = web()
    if not ok:
        return False, why
    parts.append(why)
    return True, "; ".join(parts) + "; under Hyprland, Super+arrows reach the app only with the pass-through binds in docs/goals/78-report.md (Alt works as is)"
