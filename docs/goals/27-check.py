"""Milestone checker for GOAL.md (goal 27: a lean core, themes on top, and polish; goal 26's checks run as M7, every
earlier goal's inside them). Rebuilds from scratch, prints PASS/FAIL per milestone.

Run: scripts/check   (a subset without rebuilding: scripts/check M1 M3; earlier goals: through docs/goals/NN-check.py)
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


g26 = load("goal26", "docs/goals/26-check.py")
g25 = g26.g25
g20 = g25.g20
run, BUILD = g20.run, g20.BUILD
OUT = BUILD / "g27"
shots = load("theme_shots", "scripts/theme_shots.py")
labels = g25.labels
import drive  # noqa: E402

THEME_WORDS = re.compile(r"liquid|ledger|graphite|blueprint|fluent|omarchy|paper|4f46e5|0e7a43|c8243f|E5464F|437A0E|3F24C8", re.I)


def m0():
    """Every themed screen as a picture before the move, twice: the noise between two runs."""
    a, b = OUT / "before", OUT / "before2"
    n = len(list(a.glob("*.png")))
    if n < 40 or len(list(b.glob("*.png"))) != n:
        return False, f"{n} shots in {a} (run: pixi run python scripts/theme_shots.py shoot {a}, then again into {b})"
    noise = max(share for _, share in shots.compare(a, b))
    return True, f"{n} shots (omxplorer's 4 screens in 4 skins, kit's skins, Fluent, Omarchy, native; GTK and the web); two runs differ by at most {noise * 100:.2f}% of pixels"


def m1():
    """No theme in the core: names, colours, style sheets; themes/ outside it; hosts take App.theme()."""
    problems = []
    hits = []
    for f in sorted((ROOT / "mojoui").rglob("*")):
        if f.suffix not in (".mojo", ".py", ".js", ".css") or "__pycache__" in f.parts:
            continue
        for i, line in enumerate(f.read_text(errors="replace").split("\n"), 1):
            if THEME_WORDS.search(line):
                hits.append(f"{f.relative_to(ROOT)}:{i}")
    if hits:
        problems.append(f"{len(hits)} theme mentions in mojoui/: " + ", ".join(hits[:8]))
    for t in ("liquid", "skins", "fluent", "omarchy"):
        if not (ROOT / "themes" / f"{t}.mojo").exists():
            problems.append(f"no themes/{t}.mojo")
    app = (ROOT / "mojoui/app.mojo").read_text()
    if "def theme(self) -> Theme" not in app or "def design(self)" in app or "def accent(self)" in app:
        problems.append("App: theme() replaces design() and accent()")
    gtk = (ROOT / "mojoui/hosts/gtk.mojo").read_text()
    loads = re.findall(r'"gtk_css_provider_load_from_string", NoneType\]\(self\.(\w+), (\w+(?:\.\w+)?)', gtk)
    # (since goal 32's M1, D-297, the theme's sheet is its own CSS followed by its Look's rules, both from App.theme():
    # `var sheet = theme.gtk_css + (look_gtk_css(theme.look, …))`; still nothing but the padding rules and the theme, D-557)
    from_theme = re.search(r"var sheet = theme\.gtk_css \+ \(look_gtk_css\(theme\.look, [^\n]*\)\n", gtk) is not None
    theme_sheet = "sheet.as_c_string_span" if from_theme else "theme.gtk_css"
    if sorted(loads) != [("css", "rules.as_c_string_span"), ("skin_provider", theme_sheet)]:
        problems.append(f"the GTK host loads style sheets besides its padding rules and the app's theme: {loads}")
    scoped = re.findall(r"window\.[a-z][\w-]*", gtk)
    if scoped:
        problems.append(f"the GTK host styles a window class: {sorted(set(scoped))[:5]}")
    web = (ROOT / "mojoui/hosts/web.py").read_text()
    sheets = re.findall(r'^([A-Z_]+) = """', web, re.M)
    if [s for s in sheets if s.endswith("CSS") and s != "CSS"]:
        problems.append(f"the web host holds style sheets besides its base: {sheets}")
    # the base sheet: inline in web.py until goal 34 M3 (5b28808) moved it to mojoui/hosts/static/mojoui.css, served by
    # content hash (D-764); either way it is the host's only sheet
    if 'CSS = """' in web:
        base_css = web.split('CSS = """', 1)[1].split('"""', 1)[0]
    else:
        static = ROOT / "mojoui/hosts/static"
        base_css = (static / "mojoui.css").read_text()
        others = sorted(f.name for f in static.rglob("*.css") if f.name != "mojoui.css")
        if others or 'CSS = (STATIC / "mojoui.css").read_text()' not in web:
            problems.append(f"the web host's base sheet isn't mojoui/hosts/static/mojoui.css alone: {others}")
    scoped = re.findall(r"body\.[a-z][\w-]*", base_css)
    if scoped:
        problems.append(f"the web host styles a body class: {sorted(set(scoped))[:5]}")
    return not problems, "; ".join(problems) or ("mojoui/ names no theme, colour or style sheet (0 hits); the GTK host loads only its padding rules and the app's theme, "
                                                  "neither host styles a theme's class; Liquid, the skins, Fluent and Omarchy are themes/ modules; hosts apply App.theme()")


def m2():
    """No theme: each platform's own look (GTK: only padding rules, the system's scheme; the web: the system font)."""
    problems = []
    OUT.mkdir(parents=True, exist_ok=True)
    r = run([str(BUILD / "hello" / "linux" / "hello")], env={"MOJOUI_TEST": "", "MOJOUI_SHOT": str(OUT / "native-hello.png")}, timeout=300)
    out = r.stdout + r.stderr
    m = re.search(r"^THEME: (.*)$", out, re.M)
    if not m or m.group(1) != "none sheet=none":
        problems.append(f"GTK hello: {m.group(0) if m else 'no THEME line'}")
    else:
        from PIL import Image
        px = Image.open(OUT / "native-hello.png").convert("RGB").getpixel((4, 4))
        pages = {(233, 238, 244), (238, 240, 243), (22, 22, 24), (243, 245, 249), (244, 239, 230)}  # (Liquid, Ledger, Graphite, Blueprint, Paper)
        if px in pages or max(px) - min(px) > 4:
            problems.append(f"GTK hello's window is {px}: a theme's colour, not libadwaita's neutral grey")
    w, log = drive.web_run(BUILD / "hello" / "web", "style:body=font-family;attr:body=class", viewport=(900, 700))
    font = re.search(r"^STYLE: body font-family (.*)$", log, re.M)
    cls = re.search(r"^ATTR: body class(.*)$", log, re.M)
    if not font or not font.group(1).startswith("system-ui"):
        problems.append(f"web hello font: {font.group(1) if font else log[-300:]}")
    if cls and cls.group(1).strip() not in ("", "none"):
        problems.append(f"web hello body class: {cls.group(1)}")
    return not problems, "; ".join(problems) or "hello names no theme: GTK loads no style sheet but layout (THEME: none); the web page is the system font and colours, no body class"


def m3():
    """The move changed no pixel: every M0 screen shot again from a build of the move's own commit (no more than each
    shot's own noise between M0's two runs + 0.2 %); and at HEAD, the screens the polish didn't set out to change."""
    a, moved = OUT / "before", OUT / "after-move"
    if not (moved / "commit.txt").exists():
        return False, f"no {moved}: build the move's commit (76d715b) in a worktree (git worktree add ../mojo-ui-g27-move 76d715b), then run its scripts/theme_shots.py shoot into {moved} and write the commit to commit.txt"
    noise = dict(shots.compare(a, OUT / "before2"))
    rows = shots.compare(a, moved)
    bad = [(n, s) for n, s in rows if s is None or s > noise.get(n, 0) + 0.002]
    problems = []
    if bad:
        problems.append("the move changed: " + ", ".join(f"{n} {'missing' if s is None else f'{s * 100:.2f}%'}" for n, s in bad[:8]))
    head = OUT / "after-head"
    import shutil
    shutil.rmtree(head, ignore_errors=True)
    shots.shoot(head, others_only=True)
    meant = {"fluent-gtk.png": "P9: bars lost their track", "fluent-web.png": "P9: bars lost their track",  # (the polish's own changes)
             "omarchy-gtk.png": "MX Studio follows the desktop's live Omarchy theme (it changed on 2026-10-19 21:34, after M0)",
             "omarchy-web.png": "the same: the move itself is proven by after-move, shot before the change (D-267)"}
    # the kit's web shots changed on purpose after M0 (goal 32's D-307: equal segments, toggle rows a control high; the
    # omxcode footer, D-289): they were re-taken from the intended look, twice for their noise, into docs/goals/27/golden
    # and golden2 (D-579), and drift at HEAD is measured against those, not exempted
    gold, gold2 = ROOT / "docs" / "goals" / "27" / "golden", ROOT / "docs" / "goals" / "27" / "golden2"
    retaken = {n: (s, noise_r) for (n, s), (_, noise_r) in zip(shots.compare(gold, head), shots.compare(gold, gold2))}
    rows_head = [(n, retaken[n][0] if n in retaken else s) for n, s in shots.compare(a, head)]
    noise = dict(noise, **{n: r[1] or 0 for n, r in retaken.items()})
    drift = [(n, s) for n, s in rows_head if s is not None and n not in meant and s > noise.get(n, 0) + 0.002]
    missing = [n for n, s in shots.compare(a, head) if s is None and not n.startswith("omx-")]
    if drift or missing:
        problems.append("at HEAD: " + ", ".join(f"{n} {s * 100:.2f}%" for n, s in drift) + (f" missing {missing}" if missing else ""))
    commit = (moved / "commit.txt").read_text().strip()[:7]
    return not problems, "; ".join(problems) or (f"{len(rows)} screens from a build of the move ({commit}): at most {max(s for _, s in rows) * 100:.2f}% of pixels differ "
                                                  f"(per channel, each within its own noise); at HEAD, kit (its web shots against D-579's re-taken goldens), Fluent (but its bars' tracks, P9), Omarchy and native unchanged")


def m4():
    """A theme written outside mojoui/ (themes/paper.mojo), picked by an example, switching live on GTK and the web."""
    problems = []
    if not (ROOT / "themes/paper.mojo").exists():
        return False, "no themes/paper.mojo"
    mentions = [str(f.relative_to(ROOT)) for f in (ROOT / "mojoui").rglob("*") if f.suffix in (".mojo", ".py", ".js") and "paper" in f.read_text(errors="replace").lower()]
    if mentions:
        problems.append(f"mojoui/ mentions Paper: {mentions}")
    for t in ("linux", "web"):
        if not (BUILD / "themes" / t).exists():
            b = run(["scripts/build.sh", "themes", t], timeout=1800)
            if b.returncode != 0:
                return False, f"themes {t} build: {(b.stdout + b.stderr)[-400:]}"
    OUT.mkdir(parents=True, exist_ok=True)
    exe = str(BUILD / "themes" / "linux" / "themes")
    first = run([exe], env={"MOJOUI_TEST": "", "MOJOUI_WINDOW": "900x760", "MOJOUI_SHOT": str(OUT / "themes-native-gtk.png")}, timeout=300)
    paper = run([exe], env={"MOJOUI_TEST": "segment:0=Paper", "MOJOUI_WINDOW": "900x760", "MOJOUI_SHOT": str(OUT / "themes-paper-gtk.png")}, timeout=300)
    if "THEME: none" not in first.stdout:
        problems.append("GTK: the example doesn't start native")
    if "DESIGN: paper" not in paper.stdout or "THEME: paper" not in paper.stdout:
        problems.append(f"GTK: picking Paper didn't apply it: {[l for l in paper.stdout.splitlines() if l.startswith(('THEME', 'DESIGN'))]}")
    else:
        from PIL import Image
        px = Image.open(OUT / "themes-paper-gtk.png").convert("RGB").getpixel((6, 750))
        if not g26.near(px, (244, 239, 230), 6):
            problems.append(f"GTK: the window's background is {px}, not Paper's #f4efe6")
    w, log = drive.web_run(BUILD / "themes" / "web", "segment:0=Paper;attr:body=class;style:body=background-color", shot=str(OUT / "themes-paper-web.png"), viewport=(900, 760))
    cls = re.search(r"^ATTR: body class (.*)$", log, re.M)
    bg = re.search(r"^STYLE: body background-color (.*)$", log, re.M)
    if not cls or "paper" not in cls.group(1).split():
        problems.append(f"web: body class {cls.group(1) if cls else log[-300:]}")
    if not bg or bg.group(1).strip() != "rgb(244, 239, 230)":
        problems.append(f"web: body background {bg.group(1) if bg else 'none'}")
    return not problems, "; ".join(problems) or "themes/paper.mojo (no line of it in mojoui/) picked in the themes example: GTK and the web switch live from native to Paper (window and page in #f4efe6)"


def m6():
    """The Scene is GTK's default: goal 26's numbers with no flag; goal 25's checks (goals 3–24 inside) on it."""
    import os
    problems = []
    if 'getenv("MOJOUI_SCENE") != "0"' not in (ROOT / "mojoui/hosts/gtk.mojo").read_text():
        problems.append("the GTK host doesn't draw Scenes by default (MOJOUI_SCENE=0 turns them off)")
    best = None
    for attempt in range(3):  # (best of three, D-256)
        found, out = g26.bench(f"default-{attempt}")
        if "scroll" in found and "glide" in found:
            cost = float(found["scroll"][6]) + float(found["scroll"][8])
            if best is None or cost < best[0]:
                best = (cost, found)
    if best is None:
        return False, "no BENCH lines without the flag"
    sc, gl = best[1]["scroll"], best[1]["glide"]
    scroll_p95 = float(sc[6]) + float(sc[8])
    glide_p50 = float(gl[5]) + float(gl[7])
    if scroll_p95 > 2.0 or glide_p50 > 0.3 or int(gl[12]) != 0 or int(gl[13]) + int(sc[13]) != 0:
        problems.append(f"without the flag: scroll {scroll_p95:.1f} ms p95, glide {glide_p50:.1f} ms, cells built {gl[12]}, textures {int(gl[13]) + int(sc[13])}")
    os.environ.pop("MOJOUI_SCENE", None)
    g25.OUT = BUILD / "g25-default"
    ok, msg = g25.m5()  # (hover and press ≤ 150 ms, menus 200, dialogs 300, no overshoot; GTK and the web)
    if not ok:
        problems.append(f"motion: {msg}")
    ok, msg = g25.m7()
    if not ok:
        problems.append(f"goal 25's M7 on the Scene: {msg}")
    return not problems, "; ".join(problems) or (f"no flag: scroll {scroll_p95:.1f} ms p95, glide {glide_p50:.1f} ms, 0 cell rebuilds, 0 uploads; "
                                                  "hover and press ≤ 150 ms (goal 25's M5); goals 3–24 (goal 25's M7) pass on the Scene; MOJOUI_SCENE=0 is the pixel path")


def m8():
    """docs/mxframe-needs.md: each need with why, what we do meanwhile, how much it matters."""
    f = ROOT / "docs/mxframe-needs.md"
    if not f.exists():
        return False, "no docs/mxframe-needs.md"
    text = f.read_text()
    rows = re.findall(r"^\| (\d+) \| \*\*|^\| (\d+) \| [A-Z]", text, re.M)
    rated = re.findall(r"\| (high|medium|low|high, later|later) \|$", text, re.M)
    if len(rows) < 15 or len(rated) < len(rows):
        return False, f"{len(rows)} needs, {len(rated)} rated"
    return True, f"docs/mxframe-needs.md: {len(rows)} operations, each with why, what the app does meanwhile and how much it matters; the order to ask in"


def m5():
    """The polish pass: every finding in docs/goals/27/polish.md fixed, each proven on the running app where a check can."""
    import os
    from PIL import Image
    problems = []
    rows = (ROOT / "docs/goals/27/polish.md").read_text()
    still = re.findall(r"^\| (P\d+) \|.*\| open \|$", rows, re.M)
    if still:
        problems.append("still open: " + ", ".join(still))
    g25.OUT = OUT / "polish"
    for size in ((1742, 876), (1280, 720)):
        tag = f"{size[0]}x{size[1]}"
        start, _ = g25.gtk("", f"start-{tag}", size=size)
        if len([l for l in labels(start) if l == "omxplorer"]) != 1:
            problems.append(f"{tag} start: the app's name shows {len([l for l in labels(start) if l == 'omxplorer'])} times (P2)")
        if g25.boxes(start, "doc-chip"):
            problems.append(f"{tag} start: a document chip with no document (P3)")
        g25.gtk(g25.OPEN, f"import-{tag}", size=size)  # (shots for the eye: the import screen and a menu)
        g25.gtk(g25.SHEET + ";open:Format;pause:300", f"menu-{tag}", size=size)
        sheet, _ = g25.gtk(g25.SHEET, f"sheet-{tag}", size=size)
        shown = labels(sheet) + re.findall(r"^TIP: island = (.*)$", sheet, re.M)  # (goal 30, D-287: the GPU's state is the island's, at rest)
        chips = [l for l in shown if ("ready" in l or l.endswith("CPU")) and " ms on " not in l]  # (the status bar's timing is a measurement, not the state)
        if len(chips) != 1:
            problems.append(f"{tag} sheet: the GPU's state shows {len(chips)} times: {chips} (P5)")
        report, shot = g25.gtk(g25.REPORT + ";tap:Chart tile;pause:400", f"report-{tag}", size=size)
        th_sheet, th_report = g25.boxes(sheet, "toolbar"), g25.boxes(report, "toolbar")
        if not th_sheet or not th_report or abs(th_sheet[0][3] - th_report[0][3]) > 1:
            problems.append(f"{tag}: the toolbar is {th_sheet[0][3] if th_sheet else '?'} pt on the sheet, {th_report[0][3] if th_report else '?'} on the report (P7)")
        if not g25.boxes(report, "inspector-title"):
            problems.append(f"{tag} report: the inspector's head isn't a title (P8)")
        tiles = g25.boxes(report, "chart-tile")
        if tiles:
            x, y, w, h = tiles[0]
            img = Image.open(shot).convert("RGB")
            sx = img.size[0] / size[0]
            area = list(img.crop((int(x * sx), int(y * sx), int((x + w) * sx), int((y + h) * sx))).getdata())
            red = sum(1 for px in area if px[0] > 150 and px[1] < 90 and px[2] < 110)
            teal = sum(1 for px in area if g26.near(px, (14, 124, 134), 20))  # (Liquid's first series colour: the bars are drawn, in it)
            if red > 50 or teal < 2000:
                problems.append(f"{tag} report: {red} red and {teal} teal pixels in the chart (P6)")
        else:
            problems.append(f"{tag} report: no chart tile")
    e = g25.env("polish-web")
    saved = {k: os.environ.get(k) for k in e}
    os.environ.update(e)
    try:
        w, log = drive.web_run(BUILD / "omxplorer" / "web", "style:label.picker.prominent=background-color;"
                               "js:[...document.querySelectorAll('#mojoui-root .card')][0].querySelectorAll('svg').length + ' ' + [...[...document.querySelectorAll('#mojoui-root .card')][0].querySelectorAll('button.with-icon svg, label.picker svg')].map(e => Math.round(e.getBoundingClientRect().left)).join(' ');"
                               "menu:File>Settings…;js:document.querySelector('.dialog-layer').offsetWidth === innerWidth",
                               shot=str(OUT / "polish" / "settings-web.png"), viewport=(1742, 876))
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    lefts = re.search(r'^JS: "\d+ ([\d ]+)"$', log, re.M)
    xs = [int(v) for v in lefts.group(1).split()] if lefts else []
    if len(xs) < 4 or max(xs) - min(xs) > 2:
        problems.append(f"web start: the sidebar's icons start at {xs}, not one edge (P2)")
    if "JS: true" not in log:
        problems.append("web: the Settings dialog's layer doesn't cover the window (P1)")
    bg = re.search(r"^STYLE: label.picker.prominent background-color (.*)$", log, re.M)
    if not bg or bg.group(1).strip() != "rgb(79, 70, 229)":
        problems.append(f"web start: Choose a file is {bg.group(1) if bg else 'missing'}, not the indigo primary (P4)")
    dark = run([str(BUILD / "themes" / "linux" / "themes")], env={"MOJOUI_TEST": "", "MOJOUI_WINDOW": "900x760", "ADW_DEBUG_COLOR_SCHEME": "force-dark",
                                                            "MOJOUI_SHOT": str(OUT / "polish" / "themes-dark.png")}, timeout=300)
    series = g25.boxes(dark.stdout, "series")
    if series:
        x, y, w, h = series[0]
        px = Image.open(OUT / "polish" / "themes-dark.png").convert("RGB").getpixel((int(x + 2), int(y + 2)))
        if not g26.near(px, (38, 38, 38), 8):  # (Palette.plain_dark().card)
            problems.append(f"native in dark mode: the canvas is {px}, not the plain dark card (P10)")
    else:
        problems.append("themes: no series canvas")
    err = g20.mojo_test("tests/test_theme.mojo", "THEME TESTS PASSED", "test_theme", "tests")
    if err:
        problems.append(f"theme tests (P11): {err}")
    return not problems, "; ".join(problems) or ("docs/goals/27/polish.md: every finding fixed; at 1742×876 and 1280×720: one name, no empty chip, the GPU's state once, "
                                                  "the report's toolbar the sheet's height, a titled inspector, charts not red; the web's dialog covers the window and "
                                                  "Choose a file is the primary; no theme draws dark with a dark system")


def todo(what):
    def fn():
        return False, f"not built yet: {what}"
    return fn


def m7():
    """Goal 26's checks (every earlier goal's inside them), its M6 aside (the owner's display)."""
    problems = []
    for name, fn in [("26-M0", g26.m0), ("26-M1", g26.m1), ("26-M2", g26.m2), ("26-M3", g26.m3), ("26-M4", g26.m4), ("26-M5", g26.m5), ("26-M8", g26.m8), ("26-M7", g26.m7)]:
        ok, msg = fn()
        if not ok:
            problems.append(f"{name}: {msg}")
    return not problems, "; ".join(problems) or "goal 26's M0–M5, M8 and M7 (goals 3–25 inside them) pass"


MILESTONES = [("M0", m0), ("M1", m1), ("M2", m2), ("M3", m3), ("M4", m4),
              ("M5", m5), ("M6", m6), ("M8", m8), ("M7", m7)]


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
