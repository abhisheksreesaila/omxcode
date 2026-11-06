"""Milestone checker for GOAL.md (goal 24: omxplorer polished: the Liquid skin, the screens the owner flagged, motion,
range selection; goal 23's checks run as M6, every earlier goal's inside them). Rebuilds from scratch, prints PASS/FAIL
per milestone. omxplorer runs on GTK (MOJOUI_TEST steps, on the headless display) and in Chromium (scripts/drive.py), and
through the agent host; pyarrow writes the file (build/g20/small.parquet: order, amount, region, day, paid) and is the oracle.

Run: scripts/check   (a subset without rebuilding: scripts/check M1 M2; earlier goals: through docs/goals/NN-check.py)
"""

import importlib.util
import os
import re
import subprocess
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


g23 = load("goal23", "docs/goals/23-check.py")
g22 = g23.g22
g21, g20 = g22.g21, g22.g20
run, BUILD = g20.run, g20.BUILD
from agent_client import Client  # noqa: E402
import drive  # noqa: E402

OUT = BUILD / "g24"
DESIGN = ROOT / "docs/design/liquid"
SCREENS = ["start", "import", "sheet", "report", "phone"]
TYPE_SCALE = {11, 12, 13, 15, 17, 22, 34}
OPEN = "pick:Choose a file={f}"
SHEET = OPEN + ";tap:Create table"
REPORT = SHEET + ";tap:Report;tap:Sum tile;tap:Median tile;tap:Average tile;tap:Count tile"


def small():
    return g20.fixture("small", "small.parquet")


def env(tag, **more):
    """Test-only places for documents, settings and uploads (a fresh install each time: no settings.txt)."""
    home = OUT / tag
    for d in ("docs", "config", "uploads"):
        (home / d).mkdir(parents=True, exist_ok=True)
    for f in (home / "config").glob("*"):
        f.unlink()
    return dict(g20.g19.env(), OMX_DOCUMENTS=str(home / "docs"), OMX_CONFIG=str(home / "config"), OMXCODE_UPLOADS=str(home / "uploads"),
                **{k: str(v) for k, v in more.items()})


def gtk(steps, name, **more):
    exe = BUILD / "omxplorer" / "linux" / "omxplorer"
    OUT.mkdir(parents=True, exist_ok=True)
    r = run([str(exe)], env=dict(env(name, **more), MOJOUI_TEST=steps.format(f=small()), MOJOUI_WINDOW="1440x900",
                                 MOJOUI_SHOT=str(OUT / f"{name}-gtk.png")), timeout=900)
    out = r.stdout + r.stderr
    if r.returncode != 0 or "CRITICAL" in out or "TEST: " in out:
        raise RuntimeError(f"GTK run {name} failed (exit {r.returncode}): {out[-600:]}")
    return out


def web(steps, name, **more):
    e = env(name, **more)
    saved = {k: os.environ.get(k) for k in e}
    os.environ.update(e)
    try:
        r, out = drive.web_run(BUILD / "omxplorer" / "web", steps.format(f=small()), shot=str(OUT / f"{name}-web.png"), viewport=(1440, 900))
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    if r.returncode != 0:
        raise RuntimeError(f"web run {name} failed: {out[-600:]}")
    return out


def boxes(out, tag):
    """Bounds of the views tagged `tag`; "toolbar/*": of every button inside the tagged container (BOX: toolbar/Save …)."""
    name = re.escape(tag).replace(r"\*", "[^\n]+")
    return [tuple(float(v) for v in m.groups()) for m in re.finditer(rf"^BOX: {name} ([\d.-]+) ([\d.-]+) ([\d.-]+) ([\d.-]+)$", out, re.M)]


def pixel(png, x, y):
    """(r, g, b) of one pixel of a screenshot (ImageMagick)."""
    r = subprocess.run(["magick", str(png), "-format", f"%[fx:int(255*p{{{int(x)},{int(y)}}}.r)],%[fx:int(255*p{{{int(x)},{int(y)}}}.g)],%[fx:int(255*p{{{int(x)},{int(y)}}}.b)]", "info:"],
                       capture_output=True, text=True)
    return tuple(int(v) for v in r.stdout.strip().split(","))


def near(c, hexcol, tol=10):
    want = tuple(int(hexcol[i:i + 2], 16) for i in (1, 3, 5))
    return all(abs(a - b) <= tol for a, b in zip(c, want))


def m1():
    """The Liquid design: both engines' screens side by side, the handoff, the decision."""
    problems = []
    for s in SCREENS:
        for who in ("stitch", "claude"):
            if not (DESIGN / "img" / f"{who}-{s}.png").exists():
                problems.append(f"no {who} draft of {s}")
    page = (DESIGN / "compare.html").read_text() if (DESIGN / "compare.html").exists() else ""
    if any(f"img/stitch-{s}.png" not in page or f"img/claude-{s}.png" not in page for s in SCREENS):
        problems.append("compare.html doesn't show every screen from both engines")
    hand = ROOT / "docs/design/liquid.md"
    text = hand.read_text() if hand.exists() else ""
    for needle in ("Chosen", "Tokens", "Motion", "| Gesture |", "Phone"):
        if needle not in text:
            problems.append(f"docs/design/liquid.md has no {needle!r} section")
    if "Liquid" not in (ROOT / "docs/decisions.md").read_text().split("## Goal 24")[-1]:
        problems.append("docs/decisions.md doesn't record the Liquid choice under goal 24")
    return not problems, "; ".join(problems) or "Stitch and Claude drafts of 5 screens side by side; the handoff names the choice, tokens, motion and gestures"


def islands(out, png, host):
    """The toolbar floats inset on the backdrop; the sheet inside is white. Problems, if any."""
    problems = []
    tb = boxes(out, "toolbar")
    if not tb:
        return [f"{host}: no toolbar box"]
    x, y, w, h = tb[0]
    if x < 6 or x > 16:
        problems.append(f"{host}: the toolbar isn't inset from the window ({x:.0f} pt)")
    beside = pixel(png, max(1, x / 2), y + h / 2)
    if not near(beside, "#eef2f7", 14) and not near(beside, "#e8edf4", 14) and not near(beside, "#dce2eb", 14):  # (#dce2eb: the stronger backdrop, D-4926)
        problems.append(f"{host}: beside the toolbar is {beside}, not the Liquid backdrop")
    return problems


def m2():
    """Liquid is the default on both hosts, the other skins stay; the four screens are captured and compared."""
    problems = []
    for host, fn in (("GTK", gtk), ("web", web)):
        out = fn("", f"start-{host}")
        if "DESIGN: liquid" not in out:
            problems.append(f"{host}: a fresh install isn't Liquid ({[l for l in out.splitlines() if l.startswith('DESIGN')]})")
        for skin in ("Ledger", "Graphite", "Blueprint", "Liquid"):  # (a radio reports only its choice: pick each one)
            out = fn(f"tap:Settings…;radio:0={skin}", f"settings-{skin}-{host}")
            if f"DESIGN: {skin.lower()}" not in out:
                problems.append(f"{host}: Settings doesn't switch to {skin}")
        for name, steps in (("sheet", SHEET), ("report", REPORT)):
            out = fn(steps, f"{name}-{host}")
            problems += islands(out, OUT / f"{name}-{host}-{'gtk' if host == 'GTK' else 'web'}.png", host)
        fn(OPEN, f"import-{host}")
    rows = "".join(f'<h2>{s}</h2><div class=r><img src="../../docs/design/liquid/img/claude-{s}.png"><img src="{s}-GTK-gtk.png"><img src="{s}-web-web.png"></div>'
                   for s in ("start", "import", "sheet", "report"))
    (OUT / "compare.html").write_text("<!doctype html><meta charset=utf-8><title>goal 24: design vs GTK vs web</title><style>body{background:#111;color:#ddd;font:14px Inter,sans-serif;padding:20px}"
                                      ".r{display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px}img{width:100%;border-radius:8px}</style><p>design · GTK · web</p>" + rows)
    missing = [s for s in ("start", "import", "sheet", "report") for h in ("GTK-gtk", "web-web") if not (OUT / f"{s}-{h}.png").exists()]
    if missing:
        problems.append(f"screenshots missing: {missing}")
    return not problems, "; ".join(problems) or "a fresh install is Liquid on GTK and the web, the other skins stay in Settings; floating islands on the backdrop; build/g24/compare.html"


def m3():
    """Menus, the import dialog, report tiles, the toolbar and the type scale."""
    problems = []
    out = gtk(SHEET + ";open:Format;open:Format>Text colour", "menu-GTK")
    rows = re.findall(r"^MENUROW: (.+) ([\d.]+) ([\d.]+)$", out, re.M)
    if len(rows) < 15:
        problems.append(f"the open Format menu and its submenu report {len(rows)} rows (MENUROW)")
    if len({h for _, h, _ in rows}) > 1 or len({f for _, _, f in rows}) > 1:
        problems.append("menu rows differ: " + ", ".join(sorted({f"{h} pt/{f} px" for _, h, f in rows})))
    for host, fn in (("GTK", gtk), ("web", web)):
        out = fn(OPEN, f"import-m3-{host}")
        prev, cols = boxes(out, "import-preview"), boxes(out, "import-columns")
        if not prev or not cols or abs(prev[0][0] - cols[0][0]) > 2 or cols[0][2] < prev[0][2] - 4:
            problems.append(f"{host}: the import column table doesn't line up with the preview ({prev}, {cols})")
        out = fn(REPORT + ";pause:1000", f"tiles-{host}")  # (settled: a tile that just arrived is still rising)
        tiles, xs = boxes(out, "tile"), boxes(out, "tile/Remove")
        if len(tiles) < 4:
            problems.append(f"{host}: {len(tiles)} report tiles")
        else:
            per_row = max(sum(1 for u in tiles if abs(u[1] - t[1]) < 1) for t in tiles)
            if max(t[2] for t in tiles) - min(t[2] for t in tiles) > 1 or per_row > 3:
                problems.append(f"{host}: report tiles aren't a grid of equal widths, at most 3 a row: {tiles}")
        for x in xs:
            if not any(t[0] <= x[0] and x[0] + x[2] <= t[0] + t[2] and t[1] <= x[1] and x[1] + x[3] <= t[1] + t[3] for t in tiles):
                problems.append(f"{host}: a tile's remove button sits outside its tile: {x}")
                break
        if len(xs) < len(tiles):
            problems.append(f"{host}: {len(tiles)} tiles but {len(xs)} remove buttons")
        tools = [b for b in boxes(out, "toolbar/*") if b[2] >= 60]  # (icon-over-label tools are the wide ones; the toggles are icon squares)
        if not tools or len({round(t[3]) for t in tools}) > 1:
            problems.append(f"{host}: toolbar tools differ in height: {sorted({round(t[3]) for t in tools})}")
    src = (ROOT / "themes/liquid.mojo").read_text()  # (Liquid is a theme module since goal 27, D-260)
    m = re.search(r"def liquid_css\(.*?\n(?=def |comptime )", src, re.S)
    sizes = {float(v) for v in re.findall(r"font-size: ([\d.]+)px", m.group(0))} if m else set()
    if not m or not sizes or not sizes <= TYPE_SCALE:
        problems.append(f"the Liquid GTK skin's type sizes {sorted(sizes)} aren't the scale {sorted(TYPE_SCALE)}")
    return not problems, "; ".join(problems) or "menu rows one height and type; import table under its preview; tiles an equal-width grid with ✕ inside; tools one height; one type scale"


def m4():
    """Hover/press transitions and arrival animations on both hosts; the selection ring glides (GTK, measured)."""
    problems = []
    src = (ROOT / "themes/liquid.mojo").read_text()  # (Liquid is a theme module since goal 27, D-260)
    m = re.search(r"def liquid_css\(.*?\n(?=def |comptime )", src, re.S)
    css = m.group(0) if m else ""
    for needle, what in (("transition:", "hover and press transitions"), ("@keyframes", "an arrival animation"), ("popover", "menus and popovers"), ("dialog", "dialogs")):
        if needle not in css:
            problems.append(f"GTK Liquid skin: no {what}")
    out = gtk(SHEET + ";glide:Down;glide:Right", "glide-GTK")
    glides = [(int(n), float(ms), done) for n, ms, done in re.findall(r"^GLIDE: frames (\d+) max_ms ([\d.]+) settled (yes|no)$", out, re.M)]
    if len(glides) != 2 or any(n < 6 or n > 60 or ms >= 20 or done != "yes" for n, ms, done in glides):
        problems.append(f"the selection ring doesn't glide and settle (6–60 frames, each <20 ms): {glides}")
    out = web(SHEET + ";style:button.tool=transition-duration;style:.menu-items=animation-name;menu:File>Settings…;style:.dialog=animation-name", "motion-web")
    styles = dict(re.findall(r"^STYLE: (\S+) \S+ (.+)$", out, re.M))
    if not styles.get("button.tool") or styles["button.tool"] in ("0s", ""):
        problems.append(f"web: toolbar tools have no transition ({styles.get('button.tool')})")
    for sel in (".menu-items", ".dialog"):
        if not styles.get(sel) or styles[sel] == "none":
            problems.append(f"web: {sel} has no arrival animation ({styles.get(sel)})")
    return not problems, "; ".join(problems) or f"transitions and arrival animations on GTK and the web; the ring glides: {glides}"


def m5():
    """A block of cells: Sum, Average, Count (pyarrow's), Bold on every cell, Copy as TSV; GTK, web and the agent host."""
    import pyarrow.parquet as pq
    problems = []
    err = g20.mojo_test("tests/test_block_style.mojo", "BLOCK STYLE TESTS PASSED", "test_block_style")
    if err:
        problems.append(err)
    t = pq.read_table(small()).to_pydict()
    c = Client(BUILD / "omxplorer" / "web", env("range-agent"))
    try:
        c.call(g20.opener(c), path=str(small()))
        c.call("create-table")
        c.call("grid", gesture="tap", x=g21.COLUMN_X, y=g21.HEADER_Y + 60)  # a cell of amount, a few rows down
        texts, _, _ = c.call("read")
        ref = re.search(r"^formula-bar: amount (\d+)$", texts, re.M)  # (the cell's name: column, then row number)
        if not ref:
            raise RuntimeError("no cell of amount selected after a tap: " + texts[:300])
        row0 = int(ref.group(1)) - 1
        for _ in range(5):
            c.call("grid", gesture="key", key="ArrowDown", modifiers=["shift"])
        c.call("grid", gesture="key", key="ArrowRight", modifiers=["shift"])
        block = [v for v in t["amount"][row0:row0 + 6] if v is not None]
        filled = len(block) + sum(1 for v in t["region"][row0:row0 + 6] if v not in (None, ""))
        status = " ".join(g20.status_of(c))
        want_sum = f"{sum(block):,.2f}"
        if want_sum not in status or f"Count {filled}" not in status or "Cells 12" not in status:
            problems.append(f"agent: the status bar doesn't describe the block (want Sum {want_sum}, Count {filled} non-empty, Cells 12): {status}")
        want_avg = f"{sum(block) / len(block):,.2f}" if block else None
        if want_avg and f"Average {want_avg}" not in status:
            problems.append(f"agent: the block's Average isn't pyarrow's {want_avg}: {status}")
        c.call("grid", gesture="tap", x=g21.COLUMN_X, y=g21.HEADER_Y + 60)  # a block over a whole-number column and a decimal one
        c.call("grid", gesture="key", key="ArrowLeft", modifiers=["shift"])
        for _ in range(5):
            c.call("grid", gesture="key", key="ArrowDown", modifiers=["shift"])
        mixed = sum(t["order"][row0:row0 + 6]) + sum(block)
        if f"Sum {mixed:,.2f}" not in " ".join(g20.status_of(c)):
            problems.append(f"agent: a block of order (whole numbers) and amount (decimals) doesn't sum to pyarrow's {mixed:,.2f}: {g20.status_of(c)}")
        c.call("grid", gesture="tap", x=g21.COLUMN_X, y=g21.HEADER_Y + 60)  # (back to amount and region for Bold)
        c.call("grid", gesture="key", key="ArrowRight", modifiers=["shift"])
        for _ in range(5):
            c.call("grid", gesture="key", key="ArrowDown", modifiers=["shift"])
        c.call("bold")  # (the agent's read shows values, not styles: the app says what it formatted, as goal 21's checks read it)
        if not any(t.startswith("12 cells: bold") for t in g20.status_of(c)):
            problems.append(f"agent: Bold didn't reach the block's 12 cells: {g20.status_of(c)}")
    finally:
        c.close()
    for host, fn in (("GTK", gtk), ("web", web)):
        out = fn(SHEET + ";tapat:0=180,200;key:0=shift+ArrowDown;key:0=shift+ArrowDown;key:0=shift+ArrowRight;shortcut:Ctrl+C", f"range-{host}")
        if not re.search(r"^LABEL: Cells 6$", out, re.M):
            problems.append(f"{host}: Shift+arrows don't select a 3×2 block (status: {[l for l in out.splitlines() if 'Cells' in l or 'Count' in l][:3]})")
        clip = re.search(r"^CLIPBOARD: (.*)$", out, re.M)
        lines = [l.split("\\t") for l in clip.group(1).split("\\n")] if clip else []
        table = [(f"{a:.2f}" if a is not None else "", r or "") for a, r in zip(t["amount"], t["region"])]
        run = [tuple(l) for l in lines]
        if len(run) != 3 or any(len(l) != 2 for l in run) or not any(table[i:i + 3] == run for i in range(len(table) - 2)):
            problems.append(f"{host}: Copy didn't put 3 consecutive rows of amount and region on the clipboard as pyarrow has them ({clip.group(1)[:90] if clip else None})")
        if host == "web":  # (GTK's test clicks carry no keyboard state: Shift+click is driven with a real mouse in Chromium)
            out = fn(SHEET + ";tapat:0=180,200;shifttapat:0=300,330", "shiftclick-web")
            if not re.search(r"^LABEL: Cells ([2-9]|\d\d+)$", out, re.M):
                problems.append("web: Shift+click doesn't extend the selection to a block")
        out = fn(SHEET + ";dragat:0=180,200,150,90", f"drag-{host}")
        if not re.search(r"^LABEL: Cells ([2-9]|\d\d+)$", out, re.M):
            problems.append(f"{host}: a drag over cells doesn't select a block")
    return not problems, "; ".join(problems) or "Shift+arrows, a drag and the agent select a block; its Sum, Average and Count are pyarrow's; Bold and Copy (TSV) reach every cell; GTK and the web"


def colour_count(png, hexcol, tol=6):
    """How many pixels of a screenshot are within `tol` of a colour (ImageMagick)."""
    r = subprocess.run(["magick", str(png), "-fuzz", f"{tol * 100 // 255}%", "-fill", "black", "+opaque", hexcol, "-fill", "white", "-opaque", hexcol,
                        "-format", "%[fx:int(mean*w*h)]", "info:"], capture_output=True, text=True)
    return int(r.stdout.strip() or 0)


def m7():
    """Stitch's details on both hosts: the menu bar's name and the island (the GPU at rest), yes/no pills, stat cards, tile footers; the page."""
    problems = []
    for host, fn in (("GTK", gtk), ("web", web)):
        out = fn(SHEET, f"stitch-sheet-{host}")
        png = OUT / f"stitch-sheet-{host}-{'gtk' if host == 'GTK' else 'web'}.png"
        bar = boxes(out, "menubar")
        for tag in ("app-mark", "island"):  # (goal 30, D-287: the GPU chip became the island, which shows the GPU at rest)
            b = boxes(out, tag)
            if not b or not bar or not (bar[0][1] <= b[0][1] <= bar[0][1] + bar[0][3]):
                problems.append(f"{host}: no {tag} in the menu bar")
        rest = re.findall(r"^TIP: island = (.*)$", out, re.M)
        if not rest or not re.search(r"· (NVIDIA|AMD|Apple|CPU)", rest[-1]):
            problems.append(f"{host}: the island at rest doesn't name the GPU or the CPU ({rest[-1:]})")
        greens, reds = colour_count(png, "#e3f4e9"), colour_count(png, "#fbe5e5")
        if greens < 300 or reds < 100:
            problems.append(f"{host}: yes/no cells aren't green and red pills ({greens} green, {reds} red pixels)")
        if len(boxes(out, "stat-card")) < 4:
            problems.append(f"{host}: the inspector shows {len(boxes(out, 'stat-card'))} stat cards, not 4")
        out = fn(REPORT, f"stitch-report-{host}")
        for fact in (r"[\d,]+ matched", r"p50 exact", r"of [\d,]+ values", r"[\d.]+% of rows"):
            if not re.search(rf"^LABEL: {fact}$", out, re.M):
                problems.append(f"{host}: no report tile's footer reads {fact!r}")
    rows = "".join(f'<h2>{s}</h2><div class=r><img src="../../docs/design/liquid/img/stitch-{s}.png"><img src="{s}-GTK-gtk.png"><img src="{s}-web-web.png"></div>'
                   for s in ("start", "import", "sheet", "report"))
    (OUT / "compare.html").write_text("<!doctype html><meta charset=utf-8><title>goal 24: Stitch vs GTK vs web</title><style>body{background:#111;color:#ddd;font:14px Inter,sans-serif;padding:20px}"
                                      ".r{display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px}img{width:100%;border-radius:8px}</style><p>Stitch · GTK · web</p>" + rows)
    return not problems, "; ".join(problems) or "the menu bar's name and the island (the GPU at rest), yes/no pills, 4 stat cards, tile footers (matched, p50 exact, of N values, % of rows) on GTK and the web; build/g24/compare.html"


def m6():
    """Nothing regressed: goal 23's milestones (every earlier goal's inside them)."""
    problems = []
    for name, fn in [("23-M1", g23.m1), ("23-M2", g23.m2), ("23-M3", g23.m3)]:
        ok, msg = fn()
        if not ok:
            problems.append(f"{name}: {msg}")
    return not problems, "; ".join(problems) or "goal 23's M1–M3 (goals 3–22 inside them) pass"


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
    for name, fn in [("M1", m1), ("M2", m2), ("M3", m3), ("M4", m4), ("M5", m5), ("M7", m7), ("M6", m6)]:
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
