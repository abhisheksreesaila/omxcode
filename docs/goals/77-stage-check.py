"""Goal 77 M7a–M7f: the Stage (GOAL.md, D-7780). One function per milestone, each returning (state, why).

    pixi run python docs/goals/77-check.py M7A M7B ...

Milestones not built yet report BLOCKED. examples/stage shows the framework pieces without a model (GTK headless and the
web host in headless Chromium); M7f runs the real omx.
"""


# ---------------------------------------------------------------------------------------------------------------- M7a
# The Stage shell (mojoui.stage, omxqua's Counter family): examples/stage on GTK (headless Xvfb) and the web host (headless
# Chromium) at 1280x820 (light and night), 900x820 (no right column) and 390x844 (a phone). The regions' rects come from
# the running app (GTK: the regions: test step, mojoui.regions; the web: drive.py's REGIONS from data-tag); the panel's
# look from the web's computed style and from GTK's own pixels (its fill and its rounded corner).

_M7A_ROOT = __import__("pathlib").Path(__file__).resolve().parents[2]
_M7A_OUT = _M7A_ROOT / "build/g77/m7a"
_M7A_SHOTS = _M7A_ROOT / "docs/goals/77"
_M7A_RUNS = [("desktop-light", 1280, 820, False), ("desktop-dark", 1280, 820, True), ("narrow", 900, 820, False), ("phone", 390, 844, False)]
_M7A_GROUND = {False: (245, 245, 247), True: (0, 0, 0)}  # tokens.css --oq-counter-ground


def _m7a_sh(cmd, timeout=1800, env=None):
    import os
    import subprocess
    e = dict(os.environ)
    e.update(env or {})
    return subprocess.run(cmd, cwd=_M7A_ROOT, env=e, capture_output=True, text=True, timeout=timeout)


def _m7a_gtk(name, w, h, dark):
    """examples/stage on GTK at w x h: its regions (by name) and a picture."""
    import json
    import sys
    sys.path.insert(0, str(_M7A_ROOT / "scripts"))
    import headless
    headless.ensure()
    rj, png = _M7A_OUT / f"gtk-{name}.json", _M7A_OUT / f"gtk-{name}.png"
    for f in (rj, png):
        f.unlink(missing_ok=True)
    steps = "wait:900;" + ("scheme:dark;wait:900;" if dark else "") + f"regions:{rj};shot:{png};wait:150"
    r = _m7a_sh([str(_M7A_ROOT / "build/stage/linux/stage")], 180, {"MOJOUI_TEST": steps, "MOJOUI_WINDOW": f"{w}x{h}"})
    if not rj.exists():
        raise RuntimeError(f"GTK {name}: no regions written (exit {r.returncode}): " + (r.stdout + r.stderr)[-600:])
    return {x["name"]: x for x in json.loads(rj.read_text())}, png


_M7A_STYLE = """() => { const s = sel => { const e = document.querySelector(sel); if (!e) return null; const c = getComputedStyle(e);
  return { bg: c.backgroundColor, radius: c.borderTopLeftRadius, shadow: c.boxShadow, tl: c.borderTopLeftRadius, tr: c.borderTopRightRadius }; };
  const sides = [...document.querySelectorAll('[data-tag=stage-side]')].map(e => { const c = getComputedStyle(e); return { bg: c.backgroundColor, tl: c.borderTopLeftRadius, tr: c.borderTopRightRadius }; });
  return { panel: s('[data-tag=stage-panel]'), bar: s('[data-tag=stage-bar]'), sides, scroll_w: document.documentElement.scrollWidth }; }"""


def _m7a_web(name, w, h, dark):
    """examples/stage on the web host in headless Chromium at w x h (prefers-color-scheme light or dark): its regions, the
    panel's and the bands' computed style, a picture. Its own session rather than drive.web_run: the orb breathes, so the
    page never 'settles' (drive.py waits for every canvas to stop asking for frames)."""
    import json
    import subprocess
    import sys
    import time
    import urllib.request
    sys.path.insert(0, str(_M7A_ROOT / "scripts"))
    import drive
    from playwright.sync_api import sync_playwright
    port = drive.free_port()
    png = _M7A_OUT / f"web-{name}.png"
    server = subprocess.Popen([sys.executable, str(_M7A_ROOT / "mojoui/hosts/web.py"), str(_M7A_ROOT / "build/stage/web"), str(port)],
                              cwd=_M7A_ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(600):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/static/htmx.min.js", timeout=1)
                break
            except OSError:
                if server.poll() is not None:
                    raise RuntimeError(f"web {name}: the server died")
                time.sleep(0.1)
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path=drive.CHROMIUM, headless=True)
            page = browser.new_page(viewport={"width": w, "height": h}, color_scheme="dark" if dark else "light")
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.goto(f"http://127.0.0.1:{port}/")
            page.wait_for_selector("[data-tag=stage-panel]", timeout=30000)
            page.wait_for_timeout(2200)  # (fonts, the canvases' first frames)
            regions = {x["name"]: x for x in page.evaluate(drive.REGIONS)}
            style = page.evaluate(_M7A_STYLE)
            page.screenshot(path=str(png))
            browser.close()
        if errors:
            raise RuntimeError(f"web {name}: page errors: " + "; ".join(errors)[:400])
        return regions, style, png
    finally:
        server.terminate()
        server.wait(timeout=10)


def _m7a_layout(host, name, w, h, rg):
    """The rects in order and proportion; [] when right, else what's wrong."""
    bad, need = [], ["stage-top", "stage-left", "stage-centre", "stage-panel", "stage-bar"] + (["stage-right"] if w >= 1000 or w <= 760 else [])
    for k in need:
        if k not in rg:
            bad.append(f"{host} {name}: no {k} region")
    if bad:
        return bad, ""
    t, l, c, p, b = (rg[k] for k in ("stage-top", "stage-left", "stage-centre", "stage-panel", "stage-bar"))
    if w <= 760:  # a phone: one column, stacked, the bar at the bottom of the window
        r = rg["stage-right"]
        ys = [t["y"], l["y"], c["y"], r["y"]]
        if ys != sorted(ys) or len(set(ys)) < 4:
            bad.append(f"{host} {name}: not stacked top, left, centre, right (y {ys})")
        for k in ("stage-top", "stage-left", "stage-centre", "stage-right", "stage-bar"):
            if abs(rg[k]["x"] - 14) > 2 or abs(rg[k]["w"] - (w - 28)) > 2:
                bad.append(f"{host} {name}: {k} at x {rg[k]['x']} w {rg[k]['w']} (want 14, {w - 28})")
        if not (h - 16 <= b["y"] + b["h"] <= h - 4) or abs(b["h"] - 64) > 1:
            bad.append(f"{host} {name}: the bar is not fixed at the bottom ({b['y']}+{b['h']} of {h})")
        return bad, f"stacked y {ys[0]}<{ys[1]}<{ys[2]}<{ys[3]}, columns {l['w']} wide, bar {b['y']}..{b['y'] + b['h']} of {h}"
    if "stage-right" in rg and w < 1000:
        bad.append(f"{host} {name}: a right column below 1000")
    if not (l["x"] + l["w"] <= c["x"]):
        bad.append(f"{host} {name}: left overlaps centre")
    if abs(l["x"] - 18) > 2 or abs(t["y"] - 14) > 3 or t["w"] < w - 40:
        bad.append(f"{host} {name}: outer padding (left x {l['x']}, top y {t['y']} w {t['w']})")
    if t["y"] + t["h"] > l["y"]:
        bad.append(f"{host} {name}: the top bar overlaps the columns")
    if not (p["y"] + p["h"] <= b["y"] and abs(b["h"] - 64) <= 1 and abs((b["y"] + b["h"]) - (h - 14)) <= 3):
        bad.append(f"{host} {name}: panel {p} / bar {b} (the bar 64 high, 14 from the bottom, under the panel)")
    ratio = c["w"] / l["w"]
    if w >= 1000:
        r = rg["stage-right"]
        if not (c["x"] + c["w"] <= r["x"]) or abs(l["w"] - r["w"]) > 2:
            bad.append(f"{host} {name}: right column at {r['x']} w {r['w']} (left w {l['w']})")
        if not (2.6 <= ratio <= 2.9):
            bad.append(f"{host} {name}: centre {c['w']} / side {l['w']} = {ratio:.2f} (want 2.75)")
        return bad, f"left {l['x']}+{l['w']} < centre {c['x']}+{c['w']} < right {r['x']}+{r['w']}, centre/side {ratio:.2f}, bar {b['h']} high at {b['y']}"
    if not (2.45 <= ratio <= 2.75):
        bad.append(f"{host} {name}: centre {c['w']} / left {l['w']} = {ratio:.2f} (want 2.6)")
    return bad, f"left {l['w']} | centre {c['w']} ({ratio:.2f}), no right column"


def _m7a_pixels(png, panel, dark):
    """GTK's panel read from its own pixels: the fill in its padding, the corner (rounded: the room shows), the shadow's
    step under its bottom edge."""
    from PIL import Image
    im = Image.open(png).convert("RGB")
    fill = im.getpixel((panel["x"] + 7, panel["y"] + panel["h"] // 2))
    corner = im.getpixel((panel["x"] + 1, panel["y"] + 1))
    cx = panel["x"] + panel["w"] // 2
    below = sum(im.getpixel((cx + d, panel["y"] + panel["h"] + 1))[0] for d in range(-40, 40)) / 80
    away = sum(im.getpixel((cx + d, panel["y"] + panel["h"] + 9))[0] for d in range(-40, 40)) / 80
    want = _M7A_GROUND[dark]
    ok_fill = max(abs(a - b) for a, b in zip(fill, want)) <= 3
    rounded = max(abs(a - b) for a, b in zip(corner, want)) > 6
    return ok_fill and rounded, f"fill rgb{fill} (want rgb{want}), corner rgb{corner} ({'rounded' if rounded else 'square'}), shadow step {away - below:.1f}"


def _m7a_style(style, dark):
    """The web's computed panel and bands: the ground, radius 30, a shadow; the shade see-through; the outer corners square."""
    bad = []
    p = style["panel"] or {}
    want_bg = "rgb(0, 0, 0)" if dark else "rgb(245, 245, 247)"
    if p.get("bg") != want_bg or p.get("radius") != "30px" or p.get("shadow") in (None, "none"):
        bad.append(f"panel {p} (want {want_bg}, 30px, a shadow)")
    want_side = "rgba(0, 0, 0, 0.42)" if dark else "rgba(10, 12, 22, 0.2)"
    sides = style["sides"]
    if not sides or any(s["bg"] != want_side for s in sides):
        bad.append(f"bands {sides} (want {want_side})")
    elif len(sides) == 2 and not (sides[0]["tl"] == "0px" and sides[0]["tr"] == "28px" and sides[1]["tl"] == "28px" and sides[1]["tr"] == "0px"):
        bad.append(f"band corners {sides} (square at the window's edge, 28 by the centre)")
    return bad, f"panel {p.get('bg')} r {p.get('radius')} shadow '{p.get('shadow')}', bands {sides[0]['bg'] if sides else '-'}"


def m7a():
    _M7A_OUT.mkdir(parents=True, exist_ok=True)
    for host in ("linux", "web"):
        r = _m7a_sh(["scripts/build.sh", "stage", host], 3600)
        if r.returncode:
            return ("FAIL", f"scripts/build.sh stage {host}: " + (r.stdout + r.stderr)[-800:])
    t = _m7a_sh(["pixi", "run", "mojo", "run", "--disable-warnings", "-I", ".", "tests/test_stage.mojo"], 900)
    if t.returncode or "test_stage: 7 tests passed" not in t.stdout:
        return ("FAIL", "tests/test_stage.mojo: " + (t.stdout + t.stderr)[-600:])
    import shutil
    bad, said = [], []
    for name, w, h, dark in _M7A_RUNS:
        rg, png = _m7a_gtk(name, w, h, dark)
        b, s = _m7a_layout("GTK", name, w, h, rg)
        bad += b
        said.append(f"GTK {name}: {s}")
        if w >= 1000 and "stage-panel" in rg:
            ok, s = _m7a_pixels(png, rg["stage-panel"], dark)
            said.append(f"GTK {name} panel: {s}")
            if not ok:
                bad.append(f"GTK {name} panel: {s}")
        wr, style, wpng = _m7a_web(name, w, h, dark)
        b, s = _m7a_layout("web", name, w, h, wr)
        bad += b
        said.append(f"web {name}: {s}")
        if style["scroll_w"] > w:
            bad.append(f"web {name}: the page scrolls sideways ({style['scroll_w']} > {w})")
        if w != 390:
            b, s = _m7a_style(style, dark)
            bad += [f"web {name}: {x}" for x in b]
            said.append(f"web {name} look: {s}")
        if name != "narrow":
            shutil.copy(png, _M7A_SHOTS / f"m7a-gtk-{name}.png")
            shutil.copy(wpng, _M7A_SHOTS / f"m7a-web-{name}.png")
    (_M7A_OUT / "m7a.txt").write_text("\n".join(said + bad) + "\n")
    if bad:
        return ("FAIL", "; ".join(bad))
    return ("PASS", "test_stage 7/7; " + "; ".join(said) + "; shots docs/goals/77/m7a-{gtk,web}-{desktop-light,desktop-dark,phone}.png")


def m7b():
    """Live tiles (mojoui.livetiles): the unit test, examples/livetiles built for Linux and the web, then on GTK (headless)
    and the web host (headless Chromium) a promotion sampled frame by frame from the app's own record (the surface moves
    monotonically to its new rect within 3 %, settles <= 1.1 s, the words at the final rect and size on every frame), a
    synthetic drag that reorders and a grip drag that resizes; pictures docs/goals/77/m7b-*.png. scripts/g77_livetiles_check.py."""
    import importlib.util
    from pathlib import Path

    path = Path(__file__).resolve().parents[2] / "scripts/g77_livetiles_check.py"
    spec = importlib.util.spec_from_file_location("g77_livetiles_check", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.run()


def m7c():
    """Agent-driven tiles (genui's LiveTiles, Screens.patch, the tiles tool): the two unit tests, then examples/agenttiles on GTK
    (headless) and the web host (headless Chromium), a scripted stand-in agent through the real AG-UI client loop: render_ui shows
    the tiles, the tiles tool promotes weather (first, large, 0 holes), a CUSTOM point puts the ring on it (its rect inside the tile's,
    and on GTK the ring's own pixels round that tile only); pictures docs/goals/77/m7c-*.png. scripts/g77_agenttiles_check.py."""
    import importlib.util
    from pathlib import Path

    path = Path(__file__).resolve().parents[2] / "scripts/g77_agenttiles_check.py"
    spec = importlib.util.spec_from_file_location("g77_agenttiles_check", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.run()


def m7d():
    return ("BLOCKED", "the TV: not built yet")


def m7e():
    return ("BLOCKED", "sides, pins and charms: not built yet")


def m7f():
    return ("BLOCKED", "omx on the Stage: not built yet")
