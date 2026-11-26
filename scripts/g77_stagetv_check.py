"""Goal 77 M7d's proof: the Stage's TV (mojoui.stagetv, GOAL.md M7d). Run by docs/goals/77-stage-check.py m7d(), or alone:

    pixi run python scripts/g77_stagetv_check.py

1. tests/test_stagetv.mojo (the soft spring: <= 2 % overshoot, settled <= 1.1 s; open, swap, close, the 12 s quiet, less
   motion; the Stage's layers; every TV tag styled by omxqua's Counter family).
2. examples/stage built for Linux and the web.
3. On GTK (headless) and the web host (headless Chromium, its own fixed-wait session: the orb breathes, so the page never
   settles for drive.web_run), 1280 x 820: tap "Ephemeral?" (asks "What does ephemeral mean?": the TV opens with the Word card), "Heat
   pump?" (the card swaps), then x (it closes). The app writes every frame its TV canvas draws (STAGE_TRACE:
   mojoui.stagetv's record: the box's y and height, the tiles' veil, the body, the card) with the wall clock. From it:
   opening and closing, the box's height moves monotonically to its end (never back before it arrives, never past the
   change by more than 2 %), settles within 1 pt in <= 1.1 s; the tiles' veil is up (1.0) from 300 ms into the open until
   the close and down (0) after it; the body arrives >= 150 ms in and goes >= 250 ms into the close; a swap changes the card
   250-600 ms after the ask while the box stays put. The regions read back from the running app: open, the TV's body covers
   the stage panel (the tiles hidden) and its card lies inside the body and inside the box; closed, there is no body.
   The web adds the box's top edge measured in real screenshots every ~40 ms through the open (monotonic, ends at the panel).
   A second GTK run with STAGE_TV_QUIET=2000 shows the quiet closing it by itself.
4. Pictures: docs/goals/77/m7d-{gtk,web}-{closed,mid,open,swap,dark}.png (GTK mid: the TV canvas's own pixels 250 ms into the
   open, composited over the window with the native chat bar on top: a GTK test step settles for up to a second).
Prints the numbers; returns ("PASS" | "FAIL" | "BLOCKED", why).
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build/g77/m7d"
SHOTS = ROOT / "docs/goals/77"
sys.path.insert(0, str(ROOT / "scripts"))

Q_WORD = "Ephemeral?"  # the top bar's pills: they ask "What does ephemeral mean?" and "How does a heat pump work?"
Q_ISO = "Heat pump?"
CLOSE = "Back to the tiles"
SETTLE_MS = 1100
OVERSHOOT = 0.02
GROUND = {False: (245, 245, 247), True: (0, 0, 0)}
CARD = {False: (255, 255, 255), True: (28, 28, 30)}


def sh(cmd, timeout=1800, env=None):
    e = dict(os.environ)
    e.update(env or {})
    return subprocess.run(cmd, cwd=ROOT, env=e, capture_output=True, text=True, timeout=timeout)


def read_trace(path):
    """[(kind, wall_ms, payload)]: EV lines (text) and D frames ({y, h, p, hide, leave, body, card, area_h, open})."""
    out = []
    for line in Path(path).read_text().splitlines():
        if line.startswith("EV "):
            _, ms, text = line.split(" ", 2)
            out.append(("EV", int(ms), text))
        elif line.startswith("D "):
            parts = line.split()
            kv = dict(p.split("=", 1) for p in parts[3:] if "=" in p)
            out.append(("D", int(parts[1]), {"y": float(kv["y"]), "h": float(kv["h"]), "hide": float(kv["hide"]), "leave": float(kv["leave"]),
                                             "body": kv["body"] == "1", "card": kv["card"], "area_h": float(kv["area"].split("x")[1]),
                                             "open": kv["open"] == "1"}))
    return out


def frames_after(trace, prefix):
    """The EV starting with `prefix` (its wall ms) and the D frames after it up to the next open or close: [(t ms, frame)]."""
    i0 = next((i for i, e in enumerate(trace) if e[0] == "EV" and e[2].startswith(prefix)), None)
    if i0 is None:
        return None, []
    t0 = trace[i0][1]
    out = []
    for e in trace[i0 + 1:]:
        if e[0] == "EV" and (e[2].startswith("OPEN") or e[2].startswith("CLOSE")):
            break
        if e[0] == "D":
            out.append((e[1] - t0, e[2]))
    return t0, out


def motion(frames, start_h, what):
    """The box's height from start_h along the frames: numbers and problems (monotonic to within the overshoot, settled)."""
    probs = []
    if len(frames) < 8:
        return None, [f"{what}: {len(frames)} frames recorded (need >= 8)"]
    end = frames[-1][1]["h"]
    d = end - start_h
    if abs(d) < 100:
        return None, [f"{what}: the box moved only {d:.1f} pt"]
    worst, last, arrived = 0.0, 0.0, False
    for t, f in frames:
        q = (f["h"] - start_h) / d
        worst = max(worst, q - 1.0)
        if not arrived:
            if q < last - 0.002:
                probs.append(f"{what}: went back before arriving ({last:.3f} -> {q:.3f} at {t} ms)")
                break
            last = q
            arrived = q >= 1.0 - 1e-6 or abs(f["h"] - end) < 0.5
        elif abs(q - 1.0) > OVERSHOOT + 0.001:
            probs.append(f"{what}: strayed {abs(q - 1.0) * 100:.1f} % after arriving (at {t} ms)")
            break
    if worst > OVERSHOOT + 0.001:
        probs.append(f"{what}: overshoot {worst * 100:.2f} % > 2 %")
    settled = None
    for t, f in frames:
        close = abs(f["h"] - end) < 1.0
        if close and settled is None:
            settled = t
        elif not close:
            settled = None
    if settled is None or settled > SETTLE_MS:
        probs.append(f"{what}: settled at {settled} ms > {SETTLE_MS} ms")
    return {"frames": len(frames), "from": round(start_h, 1), "to": round(end, 1), "overshoot_pct": round(worst * 100, 2), "settled_ms": settled}, probs


def check_trace(trace, host):
    """Open (the Word card), swap (Iso), close (x): every rule about the frames. Returns (said, problems)."""
    said, probs = [], []
    t_open, fo = frames_after(trace, "OPEN word")
    if t_open is None:
        return said, [f"{host}: no open in the trace"]
    area_h = fo[-1][1]["area_h"] if fo else 0
    full = area_h - 28  # (14 under the bar, 14 over the box: the top bar's gap)
    n, p = motion(fo, 64.0, f"{host} open")
    probs += p
    if n:
        said.append(f"{host} open: box {n['from']} -> {n['to']} pt (column {area_h:.0f}) in {n['frames']} frames, overshoot {n['overshoot_pct']} %, settled {n['settled_ms']} ms")
        if abs(n["to"] - full) > 1.0:
            probs.append(f"{host} open: ends at {n['to']} pt, not the whole column ({full:.0f})")
    early = [f["hide"] for t, f in fo if t < 120]
    late = [f["hide"] for t, f in fo if t >= 300]
    if not late or min(late) < 0.999:
        probs.append(f"{host} open: the tiles' veil is not up from 300 ms ({min(late) if late else None})")
    if early and not (0.0 < early[0] < 1.0):
        probs.append(f"{host} open: the tiles do not fade (veil {early[0]} in the first frame)")
    body_t = next((t for t, f in fo if f["body"]), None)
    if body_t is None or body_t < 150 or body_t > 450:
        probs.append(f"{host} open: the body arrived at {body_t} ms (want 160 ms in)")
    said.append(f"{host} open: tiles' veil {early[0] if early else '-'} in the first frame, 1.0 from 300 ms; body at {body_t} ms")
    # the swap: the card changes under its veil while the box stays put
    t_swap, fs = frames_after(trace, "OPEN iso")
    if t_swap is None:
        probs.append(f"{host}: no swap")
    else:
        changed = next((t for t, f in fs if f["card"] == "iso"), None)
        moved = max((abs(f["h"] - full) for t, f in fs), default=99)
        veil = max((f["leave"] for t, f in fs), default=0)
        if changed is None or not (250 <= changed <= 600):
            probs.append(f"{host} swap: the card changed at {changed} ms (want after its 260 ms veil)")
        if moved > 1.0:
            probs.append(f"{host} swap: the box moved {moved:.1f} pt")
        if veil < 0.9:
            probs.append(f"{host} swap: the old card's veil only reached {veil}")
        said.append(f"{host} swap: word -> iso at {changed} ms under a veil up to {veil:.2f}, the box within {moved:.2f} pt")
    t_close, fc = frames_after(trace, "CLOSE x")
    if t_close is None:
        return said, probs + [f"{host}: no close"]
    n, p = motion(fc, full, f"{host} close")
    probs += p
    if n:
        said.append(f"{host} close: box {n['from']} -> {n['to']} pt in {n['frames']} frames, overshoot {n['overshoot_pct']} %, settled {n['settled_ms']} ms")
        if abs(n["to"] - 64) > 0.5:
            probs.append(f"{host} close: ends at {n['to']} pt, not the chat bar's 64")
    gone = next((t for t, f in fc if not f["body"]), None)
    if gone is None or gone < 250:
        probs.append(f"{host} close: the body went at {gone} ms (want after its 260 ms fade)")
    tail = [f["hide"] for t, f in fc if t >= 650]
    if not tail or max(tail) > 0.001:
        probs.append(f"{host} close: the tiles' veil is not down after 650 ms ({tail[-1] if tail else None})")
    said.append(f"{host} close: body gone at {gone} ms, tiles back (veil 0) by {next((t for t, f in fc if f['hide'] <= 0.001), None)} ms")
    return said, probs


def check_regions(rg, host, state):
    """Open: the body covers the panel (the tiles are hidden) and the card lies inside it; closed: no body."""
    probs = []
    if state.startswith("closed"):
        if "stage-tv" in rg:
            probs.append(f"{host} {state}: a TV body is still on screen")
        if "stage-panel" not in rg or "stage-bar" not in rg:
            probs.append(f"{host} {state}: no panel or bar")
        return probs, f"{host} {state}: panel {rg.get('stage-panel', {}).get('h')} high, bar {rg.get('stage-bar', {}).get('h')}, no TV body"
    tv, panel, card, bar = (rg.get(k) for k in ("stage-tv", "stage-panel", "stage-tv-card", "stage-bar"))
    if not tv or not panel or not card or not bar:
        return [f"{host} {state}: missing regions ({sorted(rg)})"], ""
    covers = tv["x"] <= panel["x"] + 1 and tv["y"] <= panel["y"] + 1 and tv["x"] + tv["w"] >= panel["x"] + panel["w"] - 1 and tv["y"] + tv["h"] >= panel["y"] + panel["h"] - 1
    inside = card["x"] >= tv["x"] and card["y"] >= tv["y"] and card["x"] + card["w"] <= tv["x"] + tv["w"] and card["y"] + card["h"] <= tv["y"] + tv["h"]
    left = card["x"] + card["w"] / 2 < tv["x"] + tv["w"] / 2
    if not covers:
        probs.append(f"{host} {state}: the TV {tv} does not cover the panel {panel} (the tiles would show)")
    if not inside or not left:
        probs.append(f"{host} {state}: the card {card} is not inside the TV {tv} on its left")
    if abs(tv["y"] + tv["h"] - bar["y"]) > 1:
        probs.append(f"{host} {state}: the TV's body ends at {tv['y'] + tv['h']}, the bar starts at {bar['y']}")
    th = rg.get("stage-tv-thread")
    if not th or th["x"] < card["x"] + card["w"]:
        probs.append(f"{host} {state}: the conversation {th} is not right of the card")
    return probs, (f"{host} {state}: TV body {tv['x']},{tv['y']} {tv['w']}x{tv['h']} covers the panel {panel['x']},{panel['y']} {panel['w']}x{panel['h']}; "
                   f"card {card['x']},{card['y']} {card['w']}x{card['h']} inside it, the conversation right of it")


# ------------------------------------------------------------------------------------------------------------------ GTK

def gtk_run(steps, trace, extra=None, timeout=240):
    import headless

    headless.ensure()
    trace.unlink(missing_ok=True)
    env = {"MOJOUI_TEST": steps, "STAGE_TRACE": str(trace), "MOJOUI_WINDOW": "1280x820"}
    env.update(extra or {})
    return sh([str(ROOT / "build/stage/linux/stage")], timeout, env)


def regions_of(path):
    return {x["name"]: x for x in json.loads(Path(path).read_text())}


def composite_mid(closed_png, canvas_png, centre, bar, out):
    """The TV canvas's own pixels (RGBA, the centre column's size) over the closed window, the native chat bar back on top."""
    from PIL import Image
    win = Image.open(closed_png).convert("RGBA")
    cv = Image.open(canvas_png).convert("RGBA")
    bar_img = win.crop((bar["x"], bar["y"], bar["x"] + bar["w"], bar["y"] + bar["h"]))
    win.alpha_composite(cv, (centre["x"], centre["y"]))
    win.alpha_composite(bar_img, (bar["x"], bar["y"]))
    win.convert("RGB").save(out, optimize=True)


def check_gtk(said, probs):
    trace = OUT / "gtk-trace.txt"
    mid = OUT / "gtk-canvas-mid.png"
    mid.unlink(missing_ok=True)
    o = str(OUT)
    steps = (f"wait:900;regions:{o}/gtk-closed.json;shot:{o}/gtk-closed.png;tap:{Q_WORD};wait:1500;regions:{o}/gtk-open.json;shot:{o}/gtk-open.png;"
             f"tap:{Q_ISO};wait:1300;shot:{o}/gtk-swap.png;tap:{CLOSE};wait:1500;regions:{o}/gtk-after.json;shot:{o}/gtk-after.png;"
             f"scheme:dark;wait:700;tap:{Q_ISO};wait:1500;shot:{o}/gtk-dark.png")
    r = gtk_run(steps, trace, {"STAGE_SHOT": f"{mid}@250"})
    if not trace.exists():
        probs.append("GTK: no trace: " + (r.stdout + r.stderr)[-500:])
        return
    t = read_trace(trace)
    s, p = check_trace(t, "GTK")
    said += s
    probs += p
    for state, f in (("closed", "gtk-closed.json"), ("open", "gtk-open.json"), ("closed", "gtk-after.json")):
        if not (OUT / f).exists():
            probs.append(f"GTK: no {f}")
            continue
        p, s = check_regions(regions_of(OUT / f), "GTK", state + (" again" if f == "gtk-after.json" else ""))
        probs += p
        said.append(s)
    shot = next((e for e in t if e[0] == "EV" and e[2].startswith("SHOT")), None)
    if mid.exists() and (OUT / "gtk-closed.json").exists():
        rg = regions_of(OUT / "gtk-closed.json")
        composite_mid(OUT / "gtk-closed.png", mid, rg["stage-centre"], rg["stage-bar"], OUT / "m7d-gtk-mid.png")
        said.append(f"GTK mid: the TV canvas {shot[2].split()[1] if shot else '?'} ms into the open, composited")
    else:
        probs.append("GTK: no mid-morph picture")
    # the quiet: 2 s here (STAGE_TV_QUIET), 12 s in the app
    qt = OUT / "gtk-quiet.txt"
    gtk_run(f"wait:900;shot:{OUT}/gtk-quiet-0.png;tap:{Q_WORD};wait:4200", qt, {"STAGE_TV_QUIET": "2000"})  # (a test window shows, and draws, from its first shot)
    q = read_trace(qt) if qt.exists() else []
    t_open = next((e[1] for e in q if e[0] == "EV" and e[2].startswith("OPEN")), None)
    t_quiet = next((e[1] for e in q if e[0] == "EV" and e[2] == "CLOSE quiet"), None)
    if t_open is None or t_quiet is None or not (1900 <= t_quiet - t_open <= 3200):
        probs.append(f"GTK quiet: open at {t_open}, closed by the quiet at {t_quiet} (want ~2 s after she finished)")
    else:
        last = [e[2] for e in q if e[0] == "D"][-1]
        said.append(f"GTK quiet (2 s): closed by itself {t_quiet - t_open} ms after she answered; box back to {last['h']} pt")
        if abs(last["h"] - 64) > 0.5:
            probs.append(f"GTK quiet: the box ended at {last['h']}")
    for src, dst in (("gtk-closed.png", "m7d-gtk-closed.png"), ("gtk-open.png", "m7d-gtk-open.png"), ("gtk-swap.png", "m7d-gtk-swap.png"),
                     ("gtk-dark.png", "m7d-gtk-dark.png"), ("m7d-gtk-mid.png", "m7d-gtk-mid.png")):
        if (OUT / src).exists():
            from PIL import Image
            Image.open(OUT / src).convert("RGB").save(SHOTS / dst, optimize=True)
        else:
            probs.append(f"GTK: no {src}")


# ------------------------------------------------------------------------------------------------------------------ web

def box_top(png, x, y_from, y_to, dark):
    """The TV box's top edge in a screenshot: scanning up the column x from y_from (just over the bar) to y_to, the first
    row that is no longer the box's card colour (+1)."""
    from PIL import Image
    im = Image.open(png).convert("RGB")
    card = CARD[dark]
    y = y_from
    while y > y_to:
        px = im.getpixel((x, y))
        if max(abs(a - b) for a, b in zip(px, card)) > 3:
            return y + 1
        y -= 1
    return y_to


def web_session(trace, dark, act):
    """examples/stage on the web host in headless Chromium at 1280 x 820, STAGE_TRACE on; `act(page)` drives it."""
    import drive
    from playwright.sync_api import sync_playwright

    port = drive.free_port()
    env = dict(os.environ, STAGE_TRACE=str(trace))
    server = subprocess.Popen([sys.executable, str(ROOT / "mojoui/hosts/web.py"), str(ROOT / "build/stage/web"), str(port)],
                              cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(600):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/static/htmx.min.js", timeout=1)
                break
            except OSError:
                if server.poll() is not None:
                    raise RuntimeError("web: the server died")
                time.sleep(0.1)
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path=drive.CHROMIUM, headless=True)
            page = browser.new_page(viewport={"width": 1280, "height": 820}, color_scheme="dark" if dark else "light")
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.goto(f"http://127.0.0.1:{port}/")
            page.wait_for_selector("[data-tag=stage-panel]", timeout=30000)
            page.wait_for_timeout(2200)
            out = act(page, drive)
            browser.close()
        if errors:
            raise RuntimeError("web: page errors: " + "; ".join(errors)[:400])
        return out
    finally:
        server.terminate()
        server.wait(timeout=10)


def check_web(said, probs):
    trace = OUT / "web-trace.txt"
    trace.unlink(missing_ok=True)
    for f in OUT.glob("web-frame-*.png"):
        f.unlink()

    def act(page, drive):
        res = {}
        res["closed"] = {x["name"]: x for x in page.evaluate(drive.REGIONS)}
        page.screenshot(path=str(OUT / "web-closed.png"))
        page.locator("button").filter(has_text=drive.exact(Q_WORD)).first.click()
        t0 = time.time()
        shots = []
        k = 0
        while time.time() - t0 < 1.3:
            path = OUT / f"web-frame-{k:02d}.png"
            page.screenshot(path=str(path))
            shots.append((time.time() - t0, path))
            k += 1
        page.wait_for_timeout(600)
        res["open"] = {x["name"]: x for x in page.evaluate(drive.REGIONS)}
        page.screenshot(path=str(OUT / "web-open.png"))
        page.locator("button").filter(has_text=drive.exact(Q_ISO)).first.click()
        page.wait_for_timeout(1300)
        page.screenshot(path=str(OUT / "web-swap.png"))
        page.locator("[data-tag=stage-tv-close]").first.click()
        page.wait_for_timeout(1600)
        res["after"] = {x["name"]: x for x in page.evaluate(drive.REGIONS)}
        page.screenshot(path=str(OUT / "web-after.png"))
        res["shots"] = shots
        return res

    try:
        res = web_session(trace, False, act)
    except Exception as e:  # noqa: BLE001 (the reason goes in the result)
        probs.append(f"web: {e}")
        return
    if not trace.exists():
        probs.append("web: no trace")
        return
    t = read_trace(trace)
    s, p = check_trace(t, "web")
    said += s
    probs += p
    for state, key in (("closed", "closed"), ("open", "open"), ("closed again", "after")):
        p, s = check_regions(res[key], "web", state)
        probs += p
        said.append(s)
    # the box's top edge in the real screenshots through the open: it rises monotonically and ends at the panel's top
    rg = res["closed"]
    centre, bar, panel = rg["stage-centre"], rg["stage-bar"], rg["stage-panel"]
    x = centre["x"] + 12
    tops = [(round(tt * 1000), box_top(pth, x, bar["y"] - 2, centre["y"], False)) for tt, pth in res["shots"]]
    heights = [(tt, bar["y"] + bar["h"] - top) for tt, top in tops]
    full = bar["y"] + bar["h"] - panel["y"]
    end = heights[-1][1]  # (the settled height as measured: x is 12 in, where the corner's curve takes ~6 px off the top)
    worst, back, arrived, last = 0.0, None, False, 0.0
    for tt, hgt in heights:
        q = (hgt - 64) / (end - 64)
        worst = max(worst, q - 1)
        if not arrived:
            if q < last - 0.01:
                back = (tt, hgt)
            last = max(last, q)
            arrived = q >= 0.995
    grew = [h for _, h in heights]
    if back or worst > OVERSHOOT + 0.01 or abs(grew[-1] - full) > 8 or len(set(grew)) < 5:
        probs.append(f"web pixels: the box's height in the screenshots {heights} (back {back}, overshoot {worst * 100:.1f} %, want {full})")
    said.append(f"web pixels: {len(heights)} screenshots in 1.3 s, the box's height {grew[0]} -> {grew[-1]} px (panel to bar {full}), "
                f"{len(set(grew))} distinct, never back, overshoot {max(worst, 0) * 100:.1f} %")
    k = min(range(len(res["shots"])), key=lambda i: abs(res["shots"][i][0] - 0.25))
    shutil.copy(res["shots"][k][1], OUT / "m7d-web-mid.png")
    said.append(f"web mid: the screenshot {round(res['shots'][k][0] * 1000)} ms in (box {heights[k][1]} px)")

    def dark_act(page, drive):
        page.locator("button").filter(has_text=drive.exact(Q_ISO)).first.click()
        page.wait_for_timeout(1800)
        page.screenshot(path=str(OUT / "web-dark.png"))
        return {"open": {x["name"]: x for x in page.evaluate(drive.REGIONS)}}

    try:
        dres = web_session(OUT / "web-dark-trace.txt", True, dark_act)
        p, s = check_regions(dres["open"], "web dark", "open")
        probs += p
        said.append(s)
    except Exception as e:  # noqa: BLE001
        probs.append(f"web dark: {e}")
    from PIL import Image
    for src, dst in (("web-closed.png", "m7d-web-closed.png"), ("web-open.png", "m7d-web-open.png"), ("web-swap.png", "m7d-web-swap.png"),
                     ("web-dark.png", "m7d-web-dark.png"), ("m7d-web-mid.png", "m7d-web-mid.png")):
        if (OUT / src).exists():
            Image.open(OUT / src).convert("RGB").save(SHOTS / dst, optimize=True)
        else:
            probs.append(f"web: no {src}")


def run():
    said, probs = [], []
    OUT.mkdir(parents=True, exist_ok=True)
    SHOTS.mkdir(parents=True, exist_ok=True)
    r = sh(["pixi", "run", "mojo", "run", "--disable-warnings", "-I", ".", "tests/test_stagetv.mojo"], 900)
    # (the printed count parsed and held to the file's own test functions and main()'s calls, not a fixed string)
    src = (ROOT / "tests/test_stagetv.mojo").read_text()
    defs = len(re.findall(r"^def (test_\w+)\(", src, re.M))
    calls = len(re.findall(r"^\s+test_\w+\(\)", src.split("\ndef main()", 1)[-1], re.M))
    m = re.search(r"^test_stagetv: (\d+) tests passed$", r.stdout, re.M)
    if r.returncode or not m or not (int(m.group(1)) == defs == calls):
        return "FAIL", f"tests/test_stagetv.mojo (printed {m.group(1) if m else None}, {defs} tests, {calls} called): " + (r.stdout + r.stderr)[-600:]
    said.append(f"test_stagetv {m.group(1)}/{defs}")
    for target in ("linux", "web"):
        b = sh(["bash", "scripts/build.sh", "stage", target], 1800)
        if b.returncode:
            return "FAIL", f"build stage {target}: " + (b.stdout + b.stderr)[-600:]
    check_gtk(said, probs)
    check_web(said, probs)
    (OUT / "m7d.txt").write_text("\n".join(said + probs) + "\n")
    print("\n".join("  " + s for s in said))
    if probs:
        return "FAIL", "; ".join(probs)
    return "PASS", " | ".join(said) + " | shots docs/goals/77/m7d-{gtk,web}-{closed,mid,open,swap,dark}.png"


if __name__ == "__main__":
    state, why = run()
    print(f"M7D: {state}  {why}")
    sys.exit(0 if state == "PASS" else 1)
