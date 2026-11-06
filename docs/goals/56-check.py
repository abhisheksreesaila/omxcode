"""Goal 56's proof: omxplorer on the owner's Mac, and omxqua's latest details (GOAL.md). Prints "Mn: PASS|FAIL  why".

    pixi run python docs/goals/56-check.py [M0 M1 ...]          (default: every milestone)

M1 reads the newest scripts/mac-ssh report for omxplorer (build/mac-ssh/omxplorer-*/), and runs scripts/mac-ssh first
when there is none or the sources are newer than it (the owner's Mac over SSH: a native Metal build, about 5 minutes).
Truth is what the host drew: the Mac's view dumps (each view's frame as AppKit laid it out) and pictures, GTK's widget
bounds and pixels, Chromium's computed styles.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/g56"
FULL = Path(os.environ.get("G56_DATA", ROOT.parent / "mojo-ui-omxcode/build/g47/full"))
if not (FULL / "fleet.csv").exists():
    FULL = ROOT / "build/g47/full"
sys.path.insert(0, str(ROOT / "scripts"))
ACCENT_LIGHT = (0x0e, 0x7c, 0x86)  # Liquid light's accent (themes/liquid.mojo)


def run(cmd, timeout=3600, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))


def mojo_test(src, marker, timeout=1800):
    exe = ROOT / "build" / Path(src).stem
    b = run(["scripts/mxbuild.sh", src, "-o", str(exe)], timeout)
    if b.returncode:
        return False, (b.stdout + b.stderr)[-800:]
    r = run([str(exe)], timeout)
    out = r.stdout + r.stderr
    return (r.returncode == 0 and marker in out), out[-400:]


# ---- M0: sentences size their card ----

def m0():
    ok, out = mojo_test("tests/test_sentence.mojo", "SENTENCE TESTS PASSED")
    src = (ROOT / "mojoui/sheetpage.mojo").read_text()
    sized = "sentence_lines(words, chars)" in src and "max(16, (obj.w - 130) // 8)" in src  # (wiring only: M1's Mac dumps prove the bar holds its lines)
    return ok and sized, ("sentence_lines = the lines drawn at widths 4–200; a chart's title bar follows its lines" if ok and sized
                          else f"test ok={ok}, sheetpage sized={sized}: {out}")


# ---- M1: the owner's Mac ----

DUMP_LINE = re.compile(r"^(\s*)(\S+)(?: '([^']*)')?(?: \[([^\]]*)\])?(?: #(\S+))? @ (-?\d+),(-?\d+) (\d+)x(\d+)(.*)$")


def parse_dump(path):
    """A view dump as a list of (depth, kind, text, flags, tag, x, y, w, h, rest)."""
    out = []
    for line in Path(path).read_text().splitlines():
        m = DUMP_LINE.match(line)
        if m:
            sp, kind, text, flags, tag, x, y, w, h, rest = m.groups()
            out.append((len(sp) // 2, kind, text or "", flags or "", tag or "", int(x), int(y), int(w), int(h), rest))
    return out


def block(nodes, i):
    """Node i's descendants' indices."""
    d = nodes[i][0]
    j = i + 1
    while j < len(nodes) and nodes[j][0] > d:
        j += 1
    return list(range(i + 1, j))


def snapshots(report):
    """{step number: (step text, last snapshot name before the next step)} from the report's log."""
    steps = {}
    cur = None
    for line in (report / "log.txt").read_text().splitlines():
        m = re.match(r"step (\d+): (.*)", line)
        if m:
            cur = int(m.group(1))
            steps[cur] = [m.group(2), None]
        m = re.match(r"snapshot (\S+)", line)
        if m and cur is not None:
            steps[cur][1] = m.group(1)
    return steps


def newest_report():
    reps = sorted((ROOT / "build/mac-ssh").glob("omxplorer-*/log.txt"), key=lambda p: p.stat().st_mtime)
    return reps[-1].parent if reps else None


def sources_newer(than):
    t = (than / "log.txt").stat().st_mtime
    for d in ["mojoui", "themes", "hosts", "examples/omxplorer", "apple", "docs/goals/56/mac.steps"]:
        p = ROOT / d
        files = [p] if p.is_file() else [f for f in p.rglob("*") if f.is_file() and "__pycache__" not in f.parts]
        if any(f.stat().st_mtime > t for f in files):
            return True
    return False


def luma(px):
    return 0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]


def m1():
    from PIL import Image
    rep = newest_report()
    if rep is None or sources_newer(rep):
        r = run(["scripts/mac-ssh", "omxplorer", "docs/goals/56/mac.steps", str(FULL / "fleet.csv"), str(FULL / "limits.csv")], 1800,
                env={"MAC_SETTINGS": "appearance=system", "MAC_SSH": os.environ.get("MAC_SSH", "")})
        rep = newest_report()
        if r.returncode or rep is None:
            return False, "scripts/mac-ssh failed: " + (r.stdout + r.stderr)[-800:]
    steps = snapshots(rep)
    probs = []
    log = (rep / "log.txt").read_text()
    if "TEST: done" not in log:
        probs.append("the steps didn't finish")
    for line in log.splitlines():
        if line.startswith("TEST: ") and not line.startswith("TEST: done"):
            probs.append(line)
    sizes = {}
    for n, (text, snap) in sorted(steps.items()):
        if snap:
            sizes[n] = Image.open(rep / f"{snap}.png").size
    # the import keeps the window's width: every step from the first through the charts (before resize:1280x800)
    first_small = min((n for n, (t, _) in steps.items() if t == "resize:1280x800"), default=None)
    before = [sizes[n][0] for n in sizes if first_small is None or n < first_small]
    if not before or any(w != 1440 for w in before):
        probs.append(f"the window's width before the first resize: {sorted(set(before))}")
    # 1920 → 1440 lands at 1440
    back = [n for n, (t, _) in steps.items() if t == "resize:1440x900" and n > (first_small or 0)]
    if not back or sizes.get(back[0] + 1, (0, 0))[0] != 1440:
        probs.append(f"after 1920 → 1440 the window is {sizes.get(back[0] + 1) if back else None}")
    # light, then dark: the chrome's corners (top-left, top-right, bottom-left) in the picture after the switch's wait
    for want in ["light", "dark"]:
        n = next((k for k, (t, _) in steps.items() if t == f"scheme:{want}"), None)
        if n is None or n + 1 not in steps:
            probs.append(f"no scheme:{want} step")
            continue
        im = Image.open(rep / f"{steps[n + 1][1]}.png").convert("RGB")
        W, H = im.size
        corners = [luma(im.getpixel(p)) for p in [(4, 4), (W - 5, 4), (4, H - 5), (W - 5, H // 2)]]
        if want == "light" and min(corners) < 170 or want == "dark" and max(corners) > 90:
            probs.append(f"{want}: corner lightness {[int(c) for c in corners]}")
    # in every picture's dump with charts: sentences end above their card's body, none of their words squeezed; no overlap
    checked = 0
    for n, (t, snap) in sorted(steps.items()):
        if not snap:
            continue
        nodes = parse_dump(rep / f"{snap}.txt")
        board = next((i for i, nd in enumerate(nodes) if nd[1] == "Board"), None)
        if board is None:
            continue
        cards = [i for i in block(nodes, board) if nodes[i][0] == nodes[board][0] + 1]
        rects = [(nodes[i][4] or nodes[i][1], nodes[i][5], nodes[i][6], nodes[i][7], nodes[i][8]) for i in cards]
        for a in range(len(rects)):
            for b in range(a + 1, len(rects)):
                _, ax, ay, aw, ah = rects[a]
                _, bx, by, bw, bh = rects[b]
                if ax < bx + bw - 1 and bx < ax + aw - 1 and ay < by + bh - 1 and by < ay + ah - 1:
                    probs.append(f"{snap}: {rects[a][0]} overlaps {rects[b][0]}")
        for i, nd in enumerate(nodes):
            if not nd[4].startswith("sentence-") or nd[1] != "VStack":
                continue
            checked += 1
            bottom = nd[6] + nd[8]
            # the card's body: the header's next sibling (the header is this sentence's parent row)
            head = max(k for k in range(i) if nodes[k][0] == nd[0] - 1)
            body = next((k for k in range(i + 1, len(nodes)) if nodes[k][0] == nodes[head][0]), None)
            if body is not None and nodes[body][0] == nodes[head][0] and bottom > nodes[body][6] + 1:
                probs.append(f"{snap}: {nd[4]} ends at {bottom}, its card's body starts at {nodes[body][6]}")
            for k in block(nodes, i):
                if nodes[k][1] == "Text" and nodes[k][2].strip() and ("ZERO-SIZE" in nodes[k][9] or nodes[k][7] <= 2):  # (a comma at 1 pt is squeezed too)
                    probs.append(f"{snap}: {nd[4]}'s '{nodes[k][2]}' squeezed to nothing")
    if checked == 0:
        probs.append("no chart sentence in any dump")
    # the corner drag: the table's width changes by the drag (its neighbours give way); the swap: chart0 and chart1 trade frames
    def cards_at(n):
        nodes = parse_dump(rep / f"{steps[n][1]}.txt")
        board = next((i for i, nd in enumerate(nodes) if nd[1] == "Board"), None)
        if board is None:
            return {}
        return {nodes[i][4]: nodes[i][5:9] for i in block(nodes, board) if nodes[i][0] == nodes[board][0] + 1 and nodes[i][4]}
    cl = next((k for k, (t, _) in steps.items() if t == "tap:close-limits"), None)
    if cl is None:
        probs.append("no tap:close-limits step")
    else:
        b0, a0 = cards_at(cl - 1), cards_at(cl + 1)
        if not (any(k.startswith("tablecard") for k in b0) and not any(k.startswith("tablecard") for k in a0) and len(a0) == len(b0) - 1):
            probs.append(f"tap:close-limits didn't close the limits card: {sorted(b0)} → {sorted(a0)}")
    rz = next((k for k, (t, _) in steps.items() if t.startswith("resize:table=")), None)
    dc = next((k for k, (t, _) in steps.items() if t.startswith("dragcard:")), None)
    resized = swapped = None
    if rz is None or dc is None:
        probs.append("no card resize or dragcard step")
    else:
        before, after = cards_at(rz - 1), cards_at(rz + 1)
        if "table" in before and "table" in after:
            resized = after["table"][2] - before["table"][2]
            if not -110 <= resized <= -90:
                probs.append(f"the corner drag of -100 changed the table's width by {resized}")
        else:
            probs.append(f"no table card around the resize: {sorted(before)} / {sorted(after)}")
        b2, a2 = cards_at(dc - 1), cards_at(dc + 1)
        if {"chart0", "chart1"} <= set(b2) and {"chart0", "chart1"} <= set(a2):
            swapped = a2["chart0"][:2] == b2["chart1"][:2] and a2["chart1"][:2] == b2["chart0"][:2]
            if not swapped:
                probs.append(f"dragcard didn't swap: before {b2['chart0']}/{b2['chart1']}, after {a2['chart0']}/{a2['chart1']}")
        else:
            probs.append(f"no chart0/chart1 around dragcard: {sorted(b2)} / {sorted(a2)}")
    last = sorted(n for n in steps if steps[n][1])[-1]
    island = next((l for l in (rep / f"{steps[last][1]}.txt").read_text().splitlines() if "#island" in l), "")
    gpu = re.search(r"says '[^']*Apple[^']*ready", island) is not None  # (the island's words, as VoiceOver reads them)
    if not gpu:
        probs.append("the island doesn't name the Apple GPU: " + island.strip()[:160])
    probs = list(dict.fromkeys(probs))
    return (not probs), ("; ".join(probs)[:900] if probs else
                         f"{rep.name}: 1440 through the import, 1920 → 1440 lands, light and dark corners, {checked} sentences above their bodies, no overlap, close by tag, corner drag {resized} pt, swap exact, Apple GPU ready")


# ---- M2 / M3: omxqua's focus ring and tabular figures (GTK: the gallery in Liquid) ----

def gallery(skin, steps):
    import headless
    headless.ensure()
    exe = ROOT / "build/gallery/linux/gallery"
    env = {"MOJOUI_TEST": steps}
    if skin:
        env["GALLERY_SKIN"] = skin
    r = run([str(exe)], 120, env)
    return r.stdout + r.stderr


_gallery_built = False


def build_gallery():
    global _gallery_built
    if not _gallery_built:
        r = run(["scripts/build.sh", "gallery", "linux"], 1800)
        if r.returncode:
            raise SystemExit("gallery didn't build: " + (r.stdout + r.stderr)[-800:])
        _gallery_built = True


_web_built = False


def web_focus():
    """omxplorer's web build in Chromium: Tab until a button has focus; its computed outline and the body's font features."""
    global _web_built
    import drive
    if not _web_built:
        r = run(["scripts/build.sh", "omxplorer", "web"], 3600)
        if r.returncode:
            return None, "omxplorer web didn't build: " + (r.stdout + r.stderr)[-800:]
        _web_built = True
    seen = {}

    def during(page):
        for _ in range(40):  # (the first button Tab reaches; the sheet's grid, a focusable canvas, may keep the keys)
            page.keyboard.press("Tab")
            tag = page.evaluate("() => document.activeElement && document.activeElement.tagName")
            if tag in ("BUTTON", "CANVAS"):
                break
        seen.update(page.evaluate("""() => { const e = document.activeElement, s = getComputedStyle(e);
            return {tag: e.tagName, text: (e.innerText || e.getAttribute('aria-label') || '').slice(0, 30), style: s.outlineStyle,
                    width: s.outlineWidth, offset: s.outlineOffset, color: s.outlineColor, visible: e.matches(':focus-visible'),
                    tnum: getComputedStyle(document.body).fontFeatureSettings,
                    accent: (() => { const t = document.createElement('i'); t.style.color = 'var(--o-accent)'; document.body.appendChild(t);
                                     const c = getComputedStyle(t).color; t.remove(); return c; })()}; }"""))
        return ""

    r, out = drive.web_run(ROOT / "build/omxplorer/web", f"pick:Choose a file={FULL / 'fleet.csv'};wait:Create table;tap:Create table;wait:1500",
                           viewport=(1440, 900), color_scheme="light", during=during)
    return seen, out


def m2():
    build_gallery()
    out = gallery("liquid", "wait:500;shot:/tmp/g56-before.png;focus:Reset;wait:400;shot:/tmp/g56-focus.png")
    OUT.mkdir(parents=True, exist_ok=True)
    m = re.search(r"FOCUS: Reset at (\d+),(\d+) (\d+)x(\d+)", out)
    if not m:
        return False, "no FOCUS line: " + out[-600:]
    from PIL import Image
    x, y, w, h = map(int, m.groups())
    probs = []
    for name, want in [("/tmp/g56-before.png", False), ("/tmp/g56-focus.png", True)]:
        im = Image.open(name).convert("RGB")
        im.save(OUT / Path(name).name.replace("/tmp/", ""))
        sides = {"left": [(x - d, y + h // 2) for d in (2, 3, 4)], "right": [(x + w - 1 + d, y + h // 2) for d in (2, 3, 4)],
                 "top": [(x + w // 2, y - d) for d in (2, 3, 4)], "bottom": [(x + w // 2, y + h - 1 + d) for d in (2, 3, 4)]}
        lit = {s: any(sum(abs(a - b) for a, b in zip(im.getpixel(p), ACCENT_LIGHT)) < 60 for p in pts) for s, pts in sides.items()}
        if want and not all(lit.values()):
            probs.append(f"focused: accent on {lit}")
        if not want and any(lit.values()):
            probs.append(f"before focus: accent already on {lit}")
    seen, wout = web_focus()
    if seen is None:
        return False, wout
    want_color = seen.get("accent")  # (the app's own accent: omxplorer's brand green over Liquid's teal)
    if not (seen.get("style") == "solid" and seen.get("width") == "2px" and seen.get("offset") == "2px" and want_color and seen.get("color") == want_color and seen.get("visible")):
        probs.append(f"web: {seen}")
    return (not probs), ("; ".join(probs)[:900] if probs else
                         f"GTK: accent 2–4 px outside Reset on all four sides once focused, none before; web: Tab → {seen.get('tag')} '{seen.get('text')}' outline 2px solid {want_color} (the app's accent) offset 2px")


def m3():
    build_gallery()
    widths = {}
    for skin in ["liquid", ""]:
        out = gallery(skin, "wait:500;measure:1,111.11;measure:8,888.88")
        w = dict((t, int(v)) for t, v in re.findall(r"MEASURE: (\S+) (\d+)x\d+", out))
        widths[skin or "plain"] = w
    liq, plain = widths["liquid"], widths["plain"]
    gtk_ok = len(liq) == 2 and len(plain) == 2 and liq["1,111.11"] == liq["8,888.88"] and plain["1,111.11"] != plain["8,888.88"]
    seen, wout = web_focus()
    web_ok = seen is not None and "tnum" in (seen.get("tnum") or "")
    return gtk_ok and web_ok, (f"GTK Liquid {liq} (equal), plain {plain} (not); web body font-feature-settings {seen.get('tnum') if seen else None}"
                               if gtk_ok and web_ok else f"GTK {widths}; web {seen if seen else wout[-300:]}")


# ---- M4: nothing regressed ----

def m4():
    probs = []
    for src, marker in [("tests/test_tiling.mojo", "random: ok"), ("tests/test_boardtiles.mojo", "focus: ok"), ("tests/test_sentence.mojo", "SENTENCE TESTS PASSED")]:
        ok, out = mojo_test(src, marker)
        if not ok:
            probs.append(f"{src}: {out}")
    r = run([sys.executable, "docs/goals/54-check.py", "M1", "M2", "M3"], 3600)
    fails = [l for l in r.stdout.splitlines() if re.match(r"M\d: FAIL", l)]
    if r.returncode or fails or r.stdout.count(": PASS") < 3:
        probs.append("goal 54: " + ("; ".join(fails) or (r.stdout + r.stderr)[-600:]))
    return (not probs), ("; ".join(probs)[:900] if probs else "tiling, boardtiles, sentence ok; goal 54 M1–M3 PASS")


# ---- M5: the omxplorer page's dark shots (docs/omxplorer.html, "The look") ----

IMG = ROOT / "docs/img"
SHOTS = {"linux": IMG / "omxplorer-shell-linux.jpg", "mac": IMG / "omxplorer-shell-mac.jpg", "web": IMG / "omxplorer-shell-web.jpg"}


def scene(wait_for=True):
    """One board on every screen: the fleet, two charts and the limits table, tiled (as mac.steps' end)."""
    fleet, limits, clip = FULL / "fleet.csv", FULL / "limits.csv", FULL / "clips/F00118.mp4"
    return [f"pick:Choose a file={fleet}", "waitfor:Create table=60000" if wait_for else "wait:Create table", "tap:Create table", "wait:1500",
            "tap:Chart", "wait:1200", "tap:Chart", "wait:1200", f"pick:Table={limits}", "wait:3000"]  # (no video: the Mac can't decode yet, D-5612)


def gtk_shot(out_png):
    import headless
    headless.ensure()
    app = ROOT / "build/omxplorer/linux/omxplorer"
    r = run(["scripts/build.sh", "omxplorer", "linux"], 3600)
    if r.returncode or not app.exists():
        return "omxplorer didn't build: " + (r.stdout + r.stderr)[-600:]
    home = OUT / "page-linux"
    for d in ("docs", "config"):
        (home / d).mkdir(parents=True, exist_ok=True)
    (home / "config" / "settings.txt").write_text("appearance=dark\n")
    r = run([str(app)], 1200, {"OMX_DOCUMENTS": str(home / "docs"), "OMX_CONFIG": str(home / "config"), "MOJOUI_TEST": ";".join(scene()),
                               "MOJOUI_WINDOW": "1440x900", "MOJOUI_SHOT": str(out_png), "OMX_PACKS": str(ROOT / "build/packs")})
    out = r.stdout + r.stderr
    return None if r.returncode == 0 and "TEST: " not in out and Path(out_png).exists() else f"GTK shot failed: {out[-600:]}"


def web_shot(out_png):
    import drive
    global _web_built
    if not _web_built:
        r = run(["scripts/build.sh", "omxplorer", "web"], 3600)
        if r.returncode:
            return "omxplorer web didn't build: " + (r.stdout + r.stderr)[-600:]
        _web_built = True
    home = OUT / "page-web"
    (home / "config").mkdir(parents=True, exist_ok=True)
    (home / "config" / "settings.txt").write_text("appearance=dark\n")
    r, out = drive.web_run(ROOT / "build/omxplorer/web", ";".join(scene(wait_for=False)), shot=str(out_png), viewport=(1440, 900),
                           color_scheme="dark", env={"OMX_CONFIG": str(home / "config")})
    return None if r.returncode == 0 and Path(out_png).exists() else f"web shot failed: {out[-600:]}"


def m5():
    from PIL import Image
    OUT.mkdir(parents=True, exist_ok=True)
    probs = []
    pngs = {"linux": OUT / "page-linux.png", "web": OUT / "page-web.png"}
    for k, fn in [("linux", gtk_shot), ("web", web_shot)]:
        err = fn(pngs[k])
        if err:
            probs.append(err)
    rep = newest_report()
    if rep is not None:
        steps = snapshots(rep)
        last = sorted(n for n in steps if steps[n][1])[-1]
        pngs["mac"] = rep / f"{steps[last][1]}.png"
    else:
        probs.append("no Mac report (M1 first)")
    for k, png in pngs.items():
        if not Path(png).exists():
            probs.append(f"no {k} picture")
            continue
        im = Image.open(png).convert("RGB")
        if im.size != (1440, 900):
            probs.append(f"{k}: {im.size}")
        W, H = im.size
        corners = [luma(im.getpixel(p)) for p in [(4, 4), (W - 5, 4), (4, H - 5), (W - 5, H // 2)]]
        if max(corners) > 90:
            probs.append(f"{k} isn't dark: corners {[int(c) for c in corners]}")
        im.save(SHOTS[k], quality=88, optimize=True, progressive=True)
    page = (ROOT / "docs/omxplorer.html").read_text()
    for k, jpg in SHOTS.items():
        if f"img/{jpg.name}" not in page:
            probs.append(f"docs/omxplorer.html doesn't show {jpg.name}")
    return (not probs), ("; ".join(probs)[:900] if probs else
                         "docs/img/omxplorer-shell-{linux,mac,web}.jpg: 1440×900, dark, the same tiled board; on the page's \"The look\"")


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5}

if __name__ == "__main__":
    wanted = sys.argv[1:] or list(MILESTONES)
    bad = 0
    for k in wanted:
        try:
            ok, why = MILESTONES[k]()
        except Exception as e:  # a crashing proof is a failing proof
            ok, why = False, f"crashed: {e!r}"
        print(f"{k}: {'PASS' if ok else 'FAIL'}  {why}", flush=True)
        bad += not ok
    sys.exit(1 if bad else 0)
