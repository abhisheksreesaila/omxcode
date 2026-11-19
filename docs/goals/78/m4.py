"""Goal 78 M4: omxplorer on the free canvas, nothing regressed (docs/goals/78.md). `check() -> (ok, why)`.

1. A free .omx keeps each card's x, y, w, h (and the zoom): GTK makes a sheet (fleet + a chart), moves and resizes both, saves
   (Ctrl+S); opened again, every card is where it was. An older .omx (saved with the tiling, no "canvas" key, the format main
   writes) opens tiled as before (the chart splits the table's row, side by side, the room's width).
2. The DROID story with the owner's demo data (~/Downloads/omxplorer-demo-data/robots, read-only): fleet.csv, telemetry.parquet,
   the link fleet.clip = video.file, the row with the first clip selected (its video opens), the fleet table dragged wide
   enough for all 22 columns (the last, uuid, is drawn), the video moved beside it, the page scrolled right: the shot.
3. Goal 76's check M1–M3 (goal 73's checks and the 71 -> 70 -> 68 -> 47 chain inside), run as they are (G78_SKIP_76=1 skips
   it while iterating; the report says when it was skipped).
"""
import csv
import importlib.util
import os
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("g78common", HERE / "common.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


def saved():
    d = c.DATA
    # a free sheet, saved
    steps = ["waitfor:Create table=60000", "tap:Create table", "waitfor:Links=60000", "pause:800", "shortcut:Ctrl+Shift+C", "pause:1500",
             "freedrag:table=se,-300,-200,4,alt", "pause:300", "freedrag:chart0=move,700,-500,4,alt", "pause:300", "freedrag:chart0=e,120,0,4,alt",
             "pause:300", "shortcut:Ctrl+-", "pause:400", "boards:before", "shortcut:Ctrl+S", "pause:2000"]
    out = c.gtk(steps, "m4-save", open_path=d / "fleet.csv")
    before = c.boards(out)["before"]
    docs = c.OUT / "m4-save/docs"
    omx = sorted(docs.glob("*.omx"))
    if not omx:
        return False, "Ctrl+S saved no .omx"
    out2 = c.gtk(["waitfor:Links=60000", "pause:1500", "boards:after", f"shot:{c.OUT}/m4-1-reopened.png"], "m4-open", open_path=omx[0])
    after = c.boards(out2)["after"]
    probs = []
    if after["asked"] != before["asked"]:
        probs.append(f"reopened: {after['asked']} (saved {before['asked']})")
    if after["zoom"] != before["zoom"]:
        probs.append(f"zoom {before['zoom']} saved, {after['zoom']} reopened")
    # an older file: saved with the tiling (canvas=tiled: no "canvas" key, the format main writes), opened on a free-canvas setting
    out3 = c.gtk(["waitfor:Create table=60000", "tap:Create table", "waitfor:Links=60000", "pause:800", "shortcut:Ctrl+Shift+C", "pause:1500",
                  "boards:tiledsave", "shortcut:Ctrl+S", "pause:2000"], "m4-old", settings="appearance=light\ncanvas=tiled\n", open_path=d / "fleet.csv")
    old = sorted((c.OUT / "m4-old/docs").glob("*.omx"))
    if not old:
        return False, "the tiled sheet saved no .omx"
    meta = old[0].read_bytes()
    if b'"canvas"' in meta:
        probs.append("a sheet saved with the tiling wrote a canvas key (it should be the old format)")
    out4 = c.gtk(["waitfor:Links=60000", "pause:1500", "boards:old", f"shot:{c.OUT}/m4-2-old-omx-tiled.png"], "m4-old-open", open_path=old[0])
    o = c.boards(out4)["old"]
    t, ch = o["cards"].get("table"), o["cards"].get("chart0")
    W = o["room"][0]
    if not t or not ch or not (t[1] == ch[1] == 0 and t[0] == 0 and t[2] + c.GAP + ch[2] == W and ch[0] == t[2] + c.GAP):
        probs.append(f"the older .omx didn't open tiled: table {t}, chart {ch}, room {o['room']}")
    if probs:
        return False, "save/open: " + "; ".join(probs)
    return True, f"a free .omx reopens with every card where it was ({len(after['asked'])} cards, zoom {after['zoom']}); an older .omx opens tiled ({t}, {ch})"


def setting():
    """Settings ▸ "Tile the cards" ticked by hand (not OMX_CANVAS): settings.txt then says canvas=tiled and the cards tile at once
    (the chart splits the table's row); a second run starting tiled unticks it: canvas=free, and the cards stay where the tiles left them."""
    d = c.DATA
    label = "Tile the cards (instead of the free canvas)"
    start = ["waitfor:Create table=60000", "tap:Create table", "waitfor:Links=60000", "pause:800", "shortcut:Ctrl+Shift+C", "pause:1500", "boards:before"]
    flip = ["shortcut:Ctrl+,", "pause:500", f"toggle:{label}", "pause:600", "tap:Done", "pause:800", "boards:after"]
    out = c.gtk(start + flip + [f"shot:{c.OUT}/m4-5-setting-tiled.png"], "m4-setting", open_path=d / "fleet.csv")
    cfg = (c.OUT / "m4-setting/config/settings.txt").read_text()
    b = c.boards(out)
    out2 = c.gtk(start + flip, "m4-setting-back", settings="appearance=light\ncanvas=tiled\n", open_path=d / "fleet.csv")
    cfg2 = (c.OUT / "m4-setting-back/config/settings.txt").read_text()
    b2 = c.boards(out2)
    probs = []
    f, t = b["before"]["cards"], b["after"]["cards"]
    W = b["after"]["room"][0]
    tt, tc = t.get("table"), t.get("chart0")
    if f.get("chart0", (0, 0))[1] < f["table"][1] + f["table"][3]:
        probs.append(f"before ticking: the chart {f.get('chart0')} isn't below the table {f['table']} (the free canvas)")
    if "canvas=tiled" not in cfg:
        probs.append(f"ticked: settings.txt says {cfg.strip()!r}")
    if not tt or not tc or not (tt[1] == tc[1] == 0 and tt[2] + c.GAP + tc[2] == W):
        probs.append(f"ticked: not tiled: table {tt}, chart {tc}, room {W}")
    if "canvas=free" not in cfg2:
        probs.append(f"unticked: settings.txt says {cfg2.strip()!r}")
    if b2["after"]["cards"] != b2["before"]["cards"]:
        probs.append(f"unticked: the cards moved {b2['before']['cards']} -> {b2['after']['cards']} (free keeps them where the tiles left them)")
    if probs:
        return False, "setting: " + "; ".join(probs)
    return True, f"Settings ▸ Tile the cards ticked: canvas=tiled, the chart splits the table's row ({tt}, {tc}); unticked: canvas=free, the cards stay"


def _lstar(rgb):
    def ch(v):
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    y = 0.2126 * ch(rgb[0]) + 0.7152 * ch(rgb[1]) + 0.0722 * ch(rgb[2])
    return 116 * y ** (1 / 3) - 16 if y > 216 / 24389 else 24389 / 27 * y


def _measure(png, rect, mode):
    """Goal 73 M3's measurements on one card, found from the host's own box for it (x, y, w, h in the window): the card's
    colour in its top padding, the canvas in the gap left of it, the card's bottom edge (scanning up from under it to the
    last row of the card's colour at its middle), the rim (edge pixels against the card) and the shadow (the canvas 1 px
    under the edge against 12 px under: 3 to step past a focus ring). Returns (step dL*, rim dL*, shadow dL*, card rgb, canvas rgb)."""
    from PIL import Image
    im = Image.open(png).convert("RGB")
    W, H = im.size
    x, y, w, h = (int(round(v)) for v in rect)
    card = im.getpixel((x + w // 2, y + 8))
    canvas = im.getpixel((max(x - 4, 1), y + 20))
    mid = x + w // 3
    ys = [yy for yy in range(min(y + h + 20, H - 1), y + h // 2, -1) if max(abs(a - b) for a, b in zip(im.getpixel((mid, yy)), card)) <= 3]
    if not ys:
        return None
    edge = ys[0] + 1
    rim = max(abs(_lstar(im.getpixel((mid, min(edge + k, H - 1)))) - _lstar(card)) for k in (0, 1))
    near, far = _lstar(im.getpixel((mid, min(edge + 3, H - 1)))), _lstar(im.getpixel((mid, min(edge + 12, H - 1))))  # (+3: past a focus ring's 1.5 pt)
    return _lstar(card) - _lstar(canvas), rim, far - near, card, canvas


def depth():
    """Goal 73 M3's depth on BOTH canvas modes (review 1): tiled (OMX_CANVAS=tiled, table and chart side by side) and the free
    canvas (the table resized, the chart moved beside it: the chart, dragged last, wears the focus ring; the table is
    unfocused), light and dark, GTK and the web: each card lighter than the canvas by 73 M3's steps (light 8, dark 5), a
    visible rim (dL* >= 3) and, in light, a shadow under it (>= 1.5)."""
    import drive
    d = c.DATA
    rows, probs = [], []
    free_steps = ["boardscroll:0", "freedrag:table=se,-600,-230,4,alt", "pause:300", "freedrag:chart0=move,832,-640,4,alt", "pause:300", "boardscroll:0", "boardscrollx:0", "pause:400"]
    for canvas_mode in ("tiled", "free"):
        for mode in ("light", "dark"):
            steps = ["waitfor:Create table=60000", "tap:Create table", "waitfor:Links=60000", "pause:800", "shortcut:Ctrl+Shift+C", "pause:1500"]
            steps += (free_steps if canvas_mode == "free" else []) + ["boards:depth", "pause:500"]
            name = f"m4-depth-gtk-{canvas_mode}-{mode}"
            out = c.gtk(steps, name, settings=f"appearance={mode}\n", open_path=d / "fleet.csv", extra={"OMX_CANVAS": canvas_mode})
            focus = [l.split()[1] for l in out.splitlines() if l.startswith("BOARDFOCUS: ")]
            boxes = {m.group(1): tuple(float(v) for v in m.groups()[1:]) for m in re.finditer(r"^BOX: (table|chart0) ([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+)$", out, re.M)}
            for tag in ("table", "chart0"):
                m = _measure(c.OUT / f"{name}-final.png", boxes[tag], mode) if tag in boxes else None
                a = c.boards(out)["depth"]
                ar = a["asked"].get(tag, (0, 0, 0, 0))
                below = ar[1] + ar[3] + 12 <= a["room"][1]  # (canvas shows under it inside the page: its shadow can be seen)
                rows.append(("gtk", canvas_mode, mode, tag, "focused" if tag in focus else "unfocused", m, below))
    web_rows = {}
    for canvas_mode in ("tiled", "free"):
        for mode in ("light", "dark"):
            h = c.home(f"m4-depth-web-{canvas_mode}-{mode}", f"appearance={mode}\n")
            png = c.OUT / f"m4-depth-web-{canvas_mode}-{mode}.png"

            def during(page, canvas_mode=canvas_mode, png=png, mode=mode):
                page.keyboard.press("Control+Shift+c")
                page.wait_for_timeout(1500)
                shots = [(0, png)]
                if canvas_mode == "free":  # (the table made smaller; a click on the chart's title band gives it the focus ring)
                    c.web_drag(page, "table", "se", -600, -230, steps=4, alt=True)
                    at = page.evaluate("() => window.mojouiFreeHandle('chart0', 'move')")
                    page.mouse.click(at[0], at[1])
                    page.wait_for_timeout(600)
                    shots.append((99999, Path(str(png).replace(".png", "-bottom.png"))))
                got = []
                for top, shot in shots:
                    page.evaluate("(t) => { const sc = document.querySelector('.board').parentElement; sc.scrollTop = t; sc.scrollLeft = 0; }", top)
                    page.mouse.move(700, 880)  # (the pointer off the cards: no hover)
                    page.wait_for_timeout(800)
                    page.screenshot(path=str(shot))
                    s = page.evaluate(c.CARDS_JS)
                    tone = page.evaluate("() => Object.fromEntries([...document.querySelectorAll('.board > .object[data-tag]')].map(o => [o.dataset.tag, o.dataset.tone]))")
                    got.append((shot, {k: v[4:8] for k, v in s["cards"].items()}, tone, s["view"][1] + s["view"][3], s["view"][1]))
                web_rows[(canvas_mode, mode)] = got
                return ""

            r, outw = drive.web_run(c.WEB, "wait:Create table;tap:Create table;wait:Links;pause:800", viewport=(c.W, c.H),
                                    color_scheme=mode, env={"OMX_DOCUMENTS": str(h / "docs"), "OMX_CONFIG": str(h / "config"),
                                                           "OMX_OPEN": str(d / "fleet.csv"), "OMX_CANVAS": canvas_mode}, during=during)
            if (canvas_mode, mode) not in web_rows:
                return False, f"depth web {canvas_mode} {mode}: run failed: {outw[-500:]}"
            for tag in ("table", "chart0"):  # (each card from the shot where it shows whole)
                for shot, boxes, tone, vbottom, vtop in web_rows[(canvas_mode, mode)]:
                    b = boxes.get(tag)
                    if b and b[1] >= vtop and b[1] + b[3] <= vbottom:
                        rows.append(("web", canvas_mode, mode, tag, "focused" if tone.get(tag) == "5" else "unfocused", _measure(shot, b, mode), b[1] + b[3] + 12 <= vbottom))
                        break
                else:
                    probs.append(f"web {canvas_mode} {mode}: {tag} never shows whole")
    lines = []
    for host, cm, mode, tag, foc, m, below in rows:
        if m is None:
            probs.append(f"{host} {cm} {mode} {tag}: no card edge found")
            continue
        step, rim, sh, card, canvas = m
        lines.append(f"{host} {cm} {mode} {tag} ({foc}): step {step:+.1f}, rim {rim:.1f}, shadow {sh:.1f}" + ("" if below else " (its bottom is the page's edge: no canvas under it to cast on)"))
        if step < (8 if mode == "light" else 5) or rim < 3 or (mode == "light" and below and sh < 1.5):
            probs.append(f"{host} {cm} {mode} {tag} ({foc}): card {card} canvas {canvas}: step {step:+.1f}, rim {rim:.1f}, shadow {sh:.1f}")
    for host in ("gtk", "web"):
        if not any(r[0] == host and r[1] == "free" and r[4] == "focused" and r[6] for r in rows):
            probs.append(f"{host}: no focused card with canvas under it measured on the free canvas")
        if not any(r[0] == host and r[1] == "free" and r[4] == "unfocused" and r[6] for r in rows):
            probs.append(f"{host}: no unfocused card with canvas under it measured on the free canvas")
    (c.OUT / "m4-depth.txt").write_text("\n".join(lines) + "\n")
    if probs:
        return False, "depth: " + "; ".join(probs)[:1500]
    return True, f"depth on both modes ({len(lines)} cards: GTK and web, light and dark, tiled and free, the free canvas's focused chart too) meets 73 M3's steps, rims and shadows (build/g78/m4-depth.txt)"


def story():
    demo = c.DEMO
    if not (demo / "fleet.csv").exists() or not (demo / "telemetry.parquet").exists():
        return None, f"the owner's demo data isn't in {demo}"
    rows = list(csv.DictReader(open(demo / "fleet.csv")))
    first = next(i for i, r in enumerate(rows) if r["clip"])
    clip = Path(rows[first]["clip"]).name
    steps = ["waitfor:Create table=60000", "tap:Create table", "waitfor:Links=60000", "pause:800",
             f"pick:Table={demo / 'telemetry.parquet'}", "waitfor:close-telemetry=120000", "pause:1500",
             "tap:Links", "pause:500", "type:link=fleet.clip = video.file", "submit:link", "pause:800", "tap:panel-close", "pause:500",
             "boardscroll:0", "freedrag:table=e,2400,0,6,alt", "pause:500", "tapspot:grid=clip@1", "pause:300"]
    steps += ["key:grid=ArrowDown"] * first
    steps += ["pause:3000", "boards:opened", "hoverspot:grid=uuid", "pause:200"]
    out = c.gtk(steps, "m4-story-a", open_path=demo / "fleet.csv")
    b = c.boards(out)["opened"]
    probs = []
    if f"OPEN: video {clip}" not in out:
        probs.append(f"selecting row {first + 1} didn't play {clip}")
    v = b["cards"].get("video0")
    t = b["cards"]["table"]
    if not v:
        return False, f"story: no video card ({list(b['cards'])})"
    # the video beside the fleet table, telemetry under it; then the page scrolled right to the video
    steps2 = steps[:-4] + ["pause:3000", f"freedrag:video0=move,{t[0] + t[2] + c.GAP - v[0]},{t[1] - v[1]},6", "pause:500",
                           "boards:story", "boardscrollx:end", "boardscroll:0", "pause:500", f"shot:{c.OUT}/m4-3-droid-story-scrolled-right.png",
                           "boardscrollx:0", "pause:300", f"shot:{c.OUT}/m4-4-droid-story-left.png"]
    out2 = c.gtk(steps2, "m4-story", open_path=demo / "fleet.csv")
    s = c.boards(out2)["story"]
    v2, t2, tel = s["cards"].get("video0"), s["cards"]["table"], s["cards"].get("tablecard0")
    if not v2 or v2[0] < t2[0] + t2[2] or v2[1] != t2[1]:
        probs.append(f"the video {v2} isn't beside the fleet table {t2}")
    if not tel or tel[1] < t2[1] + t2[3]:
        probs.append(f"telemetry {tel} isn't under the fleet table {t2}")
    sx = c.scroll(out2, "x")
    if not sx or sx[0][0] + sx[0][2] < sx[0][1] - 1:
        probs.append(f"not scrolled right: {sx[:1]}")
    if probs:
        return False, "story: " + "; ".join(probs)
    return True, (f"DROID story (owner's data): row {first + 1}'s {clip} plays in the video card; fleet {t2[2]} wide shows all 22 columns "
                  f"(uuid drawn); the video beside it at {v2[:2]}, telemetry under; scrolled right {sx[0][0]}+{sx[0][2]} of {sx[0][1]}")


def g76():
    if os.environ.get("G78_SKIP_76"):
        return None, "goal 76's check skipped (G78_SKIP_76)"
    r = c.run(["pixi", "run", "python", "docs/goals/76-check.py", "M1", "M2", "M3"], 4 * 3600)
    out = r.stdout + r.stderr
    (c.OUT / "m4-76-check.log").write_text(out)
    lines = [l for l in out.splitlines() if re.match(r"^M\d: ", l)]
    if r.returncode != 0 or not lines or any(" FAIL " in l or "BLOCKED" in l for l in lines):
        return False, "76-check: " + " / ".join(l[:400] for l in lines)
    return True, "76-check " + ", ".join(l.split("  ")[0] for l in lines)


def check():
    if not (c.DATA / "fleet.csv").exists():
        return None, f"no DROID data in {c.DATA}"
    c.OUT.mkdir(parents=True, exist_ok=True)
    c.build(("omxplorer", "linux"))
    parts = []
    blocked = []
    for fn in (saved, setting, depth, story, g76):
        ok, why = fn()
        if ok is False:
            return False, why
        (parts if ok else blocked).append(why)
    if blocked:
        return None, "; ".join(parts) + "; BLOCKED: " + "; ".join(blocked)
    return True, "; ".join(parts)
