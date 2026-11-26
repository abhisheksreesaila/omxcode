"""Goal 77 M7e's proof: sides, pins and charms (GOAL.md M7e). Run by docs/goals/77-stage-check.py m7e(), or alone:

    pixi run python scripts/g77_stage_sides_check.py

No model. examples/stage on GTK (headless Xvfb) and the web host (headless Chromium, a fixed-wait Playwright session: the orb
always asks for frames, D-7789), the app's own record (STAGE_TRACE: EV FEED, CHARMS, TILES, ZONES, LIVE) read back:
1. tests/test_stagefeed.mojo (the feed's rules, occasions) and tests/test_livetiles.mojo (a phone's columns, drop zones).
2. (a) a plain morning: weather in Today (the left column), not on the stage; "2:30 rain at 4": weather is the first, large tile.
   (b) a synthetic drag of the to-do tile from the stage onto Pinned (outside the tiles' canvas): it leaves the grid, the grid
   stays full (0 holes), Pinned lists it; its card's "Unpin To do" puts it back on the stage.
   (c) each occasion (school, game, Thanksgiving, rain, birthday, flight) shows its charm on the tile it is about (the record), and
   the charm is in the picture: in the charm's box, a picture with the charm differs from one with charms off (the top bar's
   Charms pill) in >= 6 % of the pixels.
   (d) the Live timer row's value changes over 2 s (the record's LIVE lines; on GTK the window's own label shows the latest one).
   (e) at 390 x 844 the stage is two columns and no tile's words overlap another's (the record's TILES: surfaces and word boxes).
3. Pictures: docs/goals/77/m7e-{gtk,web}-{desktop-light,desktop-dark,rain,pinned,phone}.png and m7e-gtk-charm-<charm>.png.
Returns ("PASS" | "FAIL" | "BLOCKED", why).
"""
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build/g77/m7e"
SHOTS = ROOT / "docs/goals/77"
sys.path.insert(0, str(ROOT / "scripts"))

# (day button, occasion's charm, the tile it is about)
DAYS = [("First day of school", "bag", "school"), ("Game tonight", "pennant", "game"), ("Thanksgiving", "turkey", "feast"),
        ("2:30 rain at 4", "umbrella", "weather"), ("Thu · birthday Sat", "hat", "bday"), ("Fri 7:20 · near the airport", "tag", "flight")]
RAIN = "2:30 rain at 4"
PLAIN = "7:45 school run"


def sh(cmd, timeout=1800, env=None):
    e = dict(os.environ)
    e.update(env or {})
    return subprocess.run(cmd, cwd=ROOT, env=e, capture_output=True, text=True, timeout=timeout)


def tail(r, n=700):
    return (r.stdout + r.stderr)[-n:]


def events(trace):
    """[(wall ms, text)] of the trace's EV lines."""
    out = []
    if not Path(trace).exists():
        return out
    for line in Path(trace).read_text().splitlines():
        if line.startswith("EV "):
            _, ms, text = line.split(" ", 2)
            out.append((int(ms), text))
    return out


def feed(text):
    """An EV FEED line as {day, stage: [(id, size, (x, y, w, h))], holes, today, live, pinned, cols}."""
    kv = dict(p.split("=", 1) for p in text.split()[1:] if "=" in p)
    stage = []
    for one in filter(None, kv.get("stage", "").split(",")):
        idsize, cell = one.split("@")
        id_, size = idsize.split(":")
        stage.append((id_, size, tuple(int(v) for v in cell.split("."))))
    lst = lambda k: [x for x in kv.get(k, "").split(",") if x]
    return {"day": kv.get("day"), "stage": stage, "holes": int(kv.get("holes", "-1")), "today": lst("today"), "live": lst("live"),
            "pinned": lst("pinned"), "cols": int(kv.get("cols", "0"))}


def feeds(ev, after=0):
    return [(ms, feed(t)) for ms, t in ev if t.startswith("FEED ") and ms >= after]


def charms_line(ev, day):
    """The last EV CHARMS of `day` with charms on (not one written while the Charms pill had them off): {tile: (charm, x, y, w,
    h)} in canvas points."""
    got = {}
    for _, t in ev:
        if t.startswith(f"CHARMS day={day} ") and t.split(" ", 2)[2].strip():
            got = {}
            for one in filter(None, t.split(" ", 2)[2].split(";")):
                v = one.split()
                if len(v) == 6:
                    got[v[0]] = (v[1], *[float(x) for x in v[2:]])
    return got


def zones(ev):
    """The last EV ZONES: (pinned box in canvas points, canvas rect in window points)."""
    z = [t for _, t in ev if t.startswith("ZONES ")]
    if not z:
        return None, None
    kv = dict(p.split("=", 1) for p in z[-1].split()[1:])
    return [float(v) for v in kv["pinned"].split(",")], [float(v) for v in kv["canvas"].split(",")]


def tiles_line(ev, cols=None):
    """The last EV TILES (as drawn once at rest): {w, h, cols, tiles: {id: [sx sy sw sh tx ty tw th op font]}}."""
    out = None
    for _, t in ev:
        if t.startswith("TILES "):
            head, _, rest = t.partition(" cols=")
            c, _, rec = rest.partition(" ")
            if cols is not None and int(c) != cols:
                continue
            kv = dict(p.split("=", 1) for p in head.split()[1:])
            tl = {}
            for one in filter(None, rec.split(";")):
                v = one.split()
                tl[v[0]] = [float(x) for x in v[1:]]
            out = {"w": float(kv["w"]), "h": float(kv["h"]), "cols": int(c), "tiles": tl}
    return out


def check_plain_rain(host, ev, probs, said):
    """(a): weather in Today on the plain morning, the first large tile on the rain day."""
    fs = feeds(ev)
    plain = next((f for _, f in fs if f["day"] == "am"), None)
    rain = next((f for _, f in fs if f["day"] == "rain"), None)
    if not plain or not rain:
        probs.append(f"{host}: no FEED for the plain morning and the rain day ({[f['day'] for _, f in fs]})")
        return
    on_stage = [s[0] for s in plain["stage"]]
    if "weather" not in plain["today"] or "weather" in on_stage:
        probs.append(f"{host}: plain morning: weather not in Today only (today {plain['today']}, stage {on_stage})")
    first = rain["stage"][0] if rain["stage"] else ("", "", ())
    if first[0] != "weather" or first[1] not in ("l", "xl", "full") or rain["holes"] != 0:
        probs.append(f"{host}: rain day: the stage is {rain['stage']} with {rain['holes']} holes (want weather first and large)")
    said.append(f"{host}: plain morning: stage {','.join(on_stage)}, weather in Today {plain['today']}; rain: {first[0]}:{first[1]} first, "
                f"{rain['holes']} holes, Today {rain['today']}")


def check_pin(host, ev, t_drag, probs, said):
    """(b): after the drag, to-do in Pinned and off the grid, 0 holes; after Unpin, back on the stage."""
    fs = feeds(ev, t_drag)
    pin = next((f for _, f in fs if "todo" in f["pinned"]), None)
    if not pin:
        probs.append(f"{host}: the drag didn't pin the to-do tile (feeds after it: {[(f['stage'], f['pinned']) for _, f in fs][:3]}); "
                     + " | ".join(t for _, t in ev if t.startswith(("PIN", "UNPIN")))[:200])
        return
    ids = [s[0] for s in pin["stage"]]
    if "todo" in ids or pin["holes"] != 0:
        probs.append(f"{host}: pinned, but the grid is {ids} with {pin['holes']} holes")
    after = [f for ms, f in fs if any(t.startswith("UNPIN todo") and m <= ms for m, t in ev)]
    back = next((f for f in after if "todo" not in f["pinned"]), None)
    if not back or "todo" not in [s[0] for s in back["stage"]]:
        probs.append(f"{host}: Unpin didn't put the to-do tile back on the stage")
    said.append(f"{host}: dragged todo onto Pinned -> grid {','.join(ids)} ({pin['holes']} holes), Pinned {pin['pinned']}; Unpin -> "
                f"{','.join(s[0] for s in back['stage']) if back else '?'}")


def check_timer(host, ev, probs, said, window=""):
    """(d): the timer's value changes over 2 s; on GTK the window's own Live row label reads 7:18 and then 7:16."""
    live = [(ms, t.split("=", 1)[1]) for ms, t in ev if t.startswith("LIVE timer=")]
    pair = next(((a, b) for a in live for b in live if b[0] - a[0] >= 2000 and b[1] != a[1]), None)
    if not pair:
        probs.append(f"{host}: the timer row didn't change over 2 s ({live[:4]})")
        return
    shown = ""
    if window:  # (GTK's waitfor: steps: each waits until a label with exactly those words is in the window)
        waited = re.findall(r"^WAITED: (\d+:\d\d) after (\d+) ms$", window, re.M)
        if [w[0] for w in waited] != ["7:18", "7:16"]:
            probs.append(f"{host}: the window's Live row never read 7:18 then 7:16 ({waited}; " + " | ".join(re.findall(r"^TEST: .*$", window, re.M))[:200] + ")")
            return
        shown = f"; the window's own label read 7:18 then 7:16 ({int(waited[1][1])} ms apart)"
    said.append(f"{host}: the timer row {pair[0][1]} at {pair[0][0]} ms -> {pair[1][1]} at {pair[1][0]} ms{shown}")


def check_phone(host, ev, probs, said):
    """(e): two columns, the words' boxes inside the canvas and apart."""
    t = tiles_line(ev, 2)
    f = [x for _, x in feeds(ev) if x["cols"] == 2]
    if not t or not f:
        probs.append(f"{host} phone: no two-column record (TILES cols=2 / FEED cols=2)")
        return
    bad = [c for c in f[-1]["stage"] if c[2][0] + c[2][2] > 2]
    if bad:
        probs.append(f"{host} phone: tiles beyond two columns: {bad}")
    boxes = {k: v[4:8] for k, v in t["tiles"].items()}
    for k, b in boxes.items():
        if b[0] < 0 or b[0] + b[2] > t["w"] + 0.5:
            probs.append(f"{host} phone: {k}'s words outside the canvas ({b}, canvas {t['w']})")
    ks = list(boxes)
    for i in range(len(ks)):
        for j in range(i + 1, len(ks)):
            a, b = boxes[ks[i]], boxes[ks[j]]
            if a[0] < b[0] + b[2] - 0.5 and b[0] < a[0] + a[2] - 0.5 and a[1] < b[1] + b[3] - 0.5 and b[1] < a[1] + a[3] - 0.5:
                probs.append(f"{host} phone: {ks[i]}'s and {ks[j]}'s words overlap ({a} / {b})")
    widths = sorted({round(v[2]) for v in t["tiles"].values()})
    said.append(f"{host} phone: {len(boxes)} tiles in 2 columns on a {t['w']:.0f} pt canvas (tile widths {widths}), no words overlap; "
                f"stage {','.join(s[0] + ':' + s[1] for s in f[-1]['stage'])}")


def charm_visible(with_charm, without, canvas, box, scale=1.0):
    """The share of the charm's box (canvas points, + the canvas's window rect) that differs between the two pictures."""
    from PIL import Image, ImageChops
    a, b = Image.open(with_charm).convert("RGB"), Image.open(without).convert("RGB")
    x0, y0 = (canvas[0] + box[0]) * scale, (canvas[1] + box[1]) * scale
    crop = (int(x0), int(y0), int(x0 + box[2] * scale), int(y0 + box[3] * scale))
    d = ImageChops.difference(a.crop(crop), b.crop(crop)).convert("L").point(lambda v: 255 if v > 30 else 0)
    n = sum(1 for v in d.get_flattened_data() if v)
    return n / max(1, d.width * d.height)


def check_charms(host, ev, shots, probs, said):
    """(c): each day's CHARMS record has its charm on its tile, and the picture shows it (differs from charms off)."""
    _, canvas = zones(ev)
    seen = []
    for label, charm, tile in DAYS:
        day = {"First day of school": "school", "Game tonight": "game", "Thanksgiving": "thanks", "2:30 rain at 4": "rain",
               "Thu · birthday Sat": "bday", "Fri 7:20 · near the airport": "airport"}[label]
        got = charms_line(ev, day)
        if got.get(tile, ("",))[0] != charm:
            probs.append(f"{host}: {label}: the record has charms {got} (want {charm} on {tile})")
            continue
        if label in shots and canvas:
            share = charm_visible(shots[label][0], shots[label][1], canvas, got[tile][1:])
            if share < 0.06:
                probs.append(f"{host}: {label}: the {charm} isn't in the picture ({share * 100:.1f} % of its box changes with charms off)")
                continue
            seen.append(f"{charm} on {tile} ({share * 100:.0f} %)")
        else:
            seen.append(f"{charm} on {tile} (record)")
    said.append(f"{host}: charms " + ", ".join(seen))


# ---------------------------------------------------------------------------------------------------------------- GTK


def gtk(steps, trace, window="1280x820", timeout=300):
    import headless
    headless.ensure()
    trace.unlink(missing_ok=True)
    return sh([str(ROOT / "build/stage/linux/stage")], timeout, {"MOJOUI_TEST": steps, "MOJOUI_WINDOW": window, "STAGE_TRACE": str(trace)})


def check_gtk(said, probs):
    # calibrate: where the to-do tile and Pinned are (the app's own record), the plain morning, the timer
    t1 = OUT / "gtk-plain.txt"
    r = gtk(f"wait:600;waitfor:7:18=6000;waitfor:7:16=6000;shot:{OUT}/gtk-desktop-light.png;wait:300", t1)
    ev = events(t1)
    if r.returncode or not ev:
        probs.append(f"GTK: the stage didn't run: {tail(r)}")
        return
    check_timer("GTK", ev, probs, said, r.stdout)
    zone, canvas = zones(ev)
    tl = tiles_line(ev, 4)
    if not zone or not tl or "todo" not in tl["tiles"]:
        probs.append(f"GTK: no ZONES / TILES record to aim the drag ({zone}, {list(tl['tiles']) if tl else None})")
        return
    s = tl["tiles"]["todo"]
    x0, y0 = s[0] + s[2] / 2, s[1] + s[3] / 2
    x1, y1 = zone[0] + zone[2] / 2, zone[1] + min(zone[3] / 2, 60)
    path = ";".join(f"{x0 + (x1 - x0) * k / 10:.0f},{y0 + (y1 - y0) * k / 10:.0f},0.5" for k in range(11))
    # the drag, the pinned card, unpin; then the days (each with charms on and off), the rain picture, night
    days = ""
    for label, charm, _ in DAYS:
        days += f"tap:{label};wait:1700;shot:{OUT}/gtk-charm-{charm}.png;tap:Charms;wait:900;shot:{OUT}/gtk-charm-{charm}-off.png;tap:Charms;wait:500;"
    t2 = OUT / "gtk-run.txt"
    steps = (f"wait:1500;stroke:stage.tiles={path};wait:1500;shot:{OUT}/gtk-pinned.png;tap:Unpin To do;wait:1500;shot:{OUT}/gtk-unpinned.png;"
             + days + f"tap:{RAIN};wait:1700;shot:{OUT}/gtk-rain.png;tap:{PLAIN};wait:1200;scheme:dark;wait:1200;shot:{OUT}/gtk-desktop-dark.png;wait:200")
    r = gtk(steps, t2, timeout=600)
    ev2 = events(t2)
    if r.returncode or not ev2:
        probs.append(f"GTK: the run failed: {tail(r)}")
        return
    t_drag = next((ms for ms, t in ev2 if t.startswith("PIN ")), 10 ** 9)
    check_pin("GTK", ev2, min(t_drag, 10 ** 9), probs, said)
    check_plain_rain("GTK", ev2, probs, said)
    shots = {label: (OUT / f"gtk-charm-{c}.png", OUT / f"gtk-charm-{c}-off.png") for label, c, _ in DAYS}
    check_charms("GTK", ev2, shots, probs, said)
    # the phone
    t3 = OUT / "gtk-phone.txt"
    r = gtk(f"wait:1800;shot:{OUT}/gtk-phone.png;wait:200", t3, window="390x844")
    check_phone("GTK", events(t3), probs, said)
    for src, dst in [("gtk-desktop-light.png", "m7e-gtk-desktop-light.png"), ("gtk-desktop-dark.png", "m7e-gtk-desktop-dark.png"),
                     ("gtk-rain.png", "m7e-gtk-rain.png"), ("gtk-pinned.png", "m7e-gtk-pinned.png"), ("gtk-phone.png", "m7e-gtk-phone.png")] + \
                    [(f"gtk-charm-{c}.png", f"m7e-gtk-charm-{c}.png") for _, c, _ in DAYS]:
        if (OUT / src).exists():
            shutil.copy(OUT / src, SHOTS / dst)
        else:
            probs.append(f"GTK: no picture {src}")


# ---------------------------------------------------------------------------------------------------------------- web


def web_session(viewport, dark, trace, act):
    """examples/stage on the web host in headless Chromium (its own session, fixed waits); `act(page)` drives it."""
    import drive
    from playwright.sync_api import sync_playwright
    port = drive.free_port()
    trace.unlink(missing_ok=True)
    env = dict(os.environ)
    env["STAGE_TRACE"] = str(trace)
    server = subprocess.Popen([sys.executable, str(ROOT / "mojoui/hosts/web.py"), str(ROOT / "build/stage/web"), str(port)], cwd=ROOT, env=env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    errors = []
    try:
        for _ in range(600):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/static/htmx.min.js", timeout=1)
                break
            except OSError:
                if server.poll() is not None:
                    raise RuntimeError("the web server died")
                time.sleep(0.1)
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path=drive.CHROMIUM, headless=True)
            page = browser.new_page(viewport={"width": viewport[0], "height": viewport[1]}, color_scheme="dark" if dark else "light")
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.goto(f"http://127.0.0.1:{port}/")
            page.wait_for_selector("[data-tag=stage-panel]", timeout=30000)
            page.wait_for_timeout(2200)
            act(page)
            browser.close()
    finally:
        server.terminate()
        server.wait(timeout=10)
    return errors


def click(page, label):
    import drive
    page.locator("[data-kind=button]").filter(has_text=drive.exact(label)).first.click()


def check_web(said, probs):
    trace = OUT / "web-run.txt"

    dom = []

    def act(page):
        page.screenshot(path=str(OUT / "web-desktop-light.png"))
        dom.append(page.inner_text("[data-tag=stage-live]"))  # (the Live rows as the page shows them, twice, 2.1 s apart)
        page.wait_for_timeout(2100)
        dom.append(page.inner_text("[data-tag=stage-live]"))
        page.wait_for_timeout(200)
        zone, canvas = zones(events(trace))
        tl = tiles_line(events(trace), 4)
        if not zone or not tl or "todo" not in tl["tiles"]:
            raise RuntimeError(f"no ZONES / TILES record to aim the drag ({zone}, {tl})")
        s = tl["tiles"]["todo"]
        x0, y0 = canvas[0] + s[0] + s[2] / 2, canvas[1] + s[1] + s[3] / 2
        x1, y1 = canvas[0] + zone[0] + zone[2] / 2, canvas[1] + zone[1] + min(zone[3] / 2, 60)
        page.mouse.move(x0, y0)
        page.mouse.down()
        for k in range(1, 13):
            page.mouse.move(x0 + (x1 - x0) * k / 12, y0 + (y1 - y0) * k / 12)
            page.wait_for_timeout(40)
        page.mouse.up()
        page.wait_for_timeout(1500)
        page.screenshot(path=str(OUT / "web-pinned.png"))
        page.locator("[data-kind=button][title='Unpin To do'], [data-kind=button][aria-label='Unpin To do']").first.click()
        page.wait_for_timeout(1500)
        for label, charm, _ in DAYS:
            click(page, label)
            page.wait_for_timeout(1700)
            page.screenshot(path=str(OUT / f"web-charm-{charm}.png"))
            click(page, "Charms")
            page.wait_for_timeout(900)
            page.screenshot(path=str(OUT / f"web-charm-{charm}-off.png"))
            click(page, "Charms")
            page.wait_for_timeout(500)
        click(page, RAIN)
        page.wait_for_timeout(1700)
        page.screenshot(path=str(OUT / "web-rain.png"))

    try:
        errors = web_session((1280, 820), False, trace, act)
    except Exception as e:  # (the drive failed: report what the record says so far)
        errors = [f"the session failed: {e}"]
    ev = events(trace)
    if errors:
        probs.append("web: " + "; ".join(errors)[:400])
    check_timer("web", ev, probs, said)
    clocks = [re.findall(r"\b\d:\d\d\b", d) for d in dom]
    if len(clocks) == 2 and clocks[0] and clocks[1] and clocks[0][0] != clocks[1][0]:
        said.append(f"web: the page's Live row read {clocks[0][0]}, then {clocks[1][0]} 2.1 s later")
    else:
        probs.append(f"web: the page's Live row didn't tick ({clocks})")
    t_drag = next((ms for ms, t in ev if t.startswith("PIN ")), 0)
    check_pin("web", ev, t_drag, probs, said)
    check_plain_rain("web", ev, probs, said)
    shots = {label: (OUT / f"web-charm-{c}.png", OUT / f"web-charm-{c}-off.png") for label, c, _ in DAYS}
    check_charms("web", ev, shots, probs, said)
    dark = OUT / "web-dark.txt"
    web_session((1280, 820), True, dark, lambda page: page.screenshot(path=str(OUT / "web-desktop-dark.png")))
    phone = OUT / "web-phone.txt"
    errs = web_session((390, 844), False, phone, lambda page: page.screenshot(path=str(OUT / "web-phone.png")))
    if errs:
        probs.append("web phone: " + "; ".join(errs)[:300])
    check_phone("web", events(phone), probs, said)
    for name in ("desktop-light", "desktop-dark", "rain", "pinned", "phone"):
        if (OUT / f"web-{name}.png").exists():
            shutil.copy(OUT / f"web-{name}.png", SHOTS / f"m7e-web-{name}.png")
        else:
            probs.append(f"web: no picture web-{name}.png")


def run():
    OUT.mkdir(parents=True, exist_ok=True)
    said, probs = [], []
    for name, want in (("test_stagefeed", "stagefeed: ok"), ("test_livetiles", "livetiles: ok")):
        t = sh(["pixi", "run", "mojo", "run", "--disable-warnings", "-I", ".", f"tests/{name}.mojo"], 900)
        if t.returncode or want not in t.stdout:
            return ("FAIL", f"{name}: {tail(t)}")
    said.append("tests: stagefeed (urgent first, centre, fill to 5, sides, pins, occasions), livetiles (a phone's columns, drop zones)")
    for host in ("linux", "web"):
        b = sh(["scripts/build.sh", "stage", host], 3600)
        if b.returncode:
            return ("FAIL", f"scripts/build.sh stage {host}: {tail(b, 900)}")
    check_gtk(said, probs)
    check_web(said, probs)
    (OUT / "m7e.txt").write_text("\n".join(said + probs) + "\n")
    print("\n".join(said + probs))
    if probs:
        return ("FAIL", "; ".join(probs))
    return ("PASS", "; ".join(said) + "; shots docs/goals/77/m7e-{gtk,web}-{desktop-light,desktop-dark,rain,pinned,phone}.png, m7e-gtk-charm-*.png")


if __name__ == "__main__":
    state, why = run()
    print(state, why)
    sys.exit(0 if state == "PASS" else 1)
