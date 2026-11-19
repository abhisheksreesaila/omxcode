"""What goal 78's milestone proofs share: omxplorer on the private Xvfb display with MOJOUI_TEST steps (real drags through
the host's own gesture signals: freedrag:, boards:, boardscrollx:, shortcut:…), the web host in headless Chromium with a real
mouse and keyboard (scripts/drive.py), and the parsers for what the hosts print. Truth is the hosts' geometry (GTK's
allocations, the page's boxes) and pixels, never the app's own word for it."""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build/g78"
APP = ROOT / "build/omxplorer/linux/omxplorer"
WEB = ROOT / "build/omxplorer/web"
CANVAS_APP = ROOT / "build/canvas/linux/canvas"
CANVAS_WEB = ROOT / "build/canvas/web"
DATA = Path(os.environ.get("G78_DATA", ROOT / "build/g47/full"))  # (goal 47's DROID folder: scripts/robot_data.py)
DEMO = Path(os.environ.get("G78_DEMO", Path.home() / "Downloads/omxplorer-demo-data/robots"))  # (the owner's demo copy, read-only)
W, H = 1440, 900
GAP = 8
sys.path.insert(0, str(ROOT / "scripts"))


def run(cmd, timeout=3600, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))


def mojo_test(src, labels, timeout=1800):
    exe = ROOT / "build" / Path(src).stem
    b = run(["scripts/mxbuild.sh", src, "-o", str(exe)], timeout)
    if b.returncode:
        return False, (b.stdout + b.stderr)[-800:], labels
    r = run([str(exe)], timeout)
    out = r.stdout + r.stderr
    missing = [l for l in labels if not re.search(rf"^{re.escape(l)}: ok", out, re.M)]
    return (r.returncode == 0 and not missing), out, missing


def build(what):
    """scripts/build.sh omxplorer|canvas linux|web once per run (an error is the check's FAIL)."""
    key = "_built_" + "_".join(what)
    if not globals().get(key):
        r = run(["scripts/build.sh", *what], 3600)
        if r.returncode:
            raise RuntimeError(f"build {' '.join(what)} failed: " + (r.stdout + r.stderr)[-1500:])
        globals()[key] = True


def home(name, settings="appearance=light\n"):
    d = OUT / name
    for sub in ("docs", "config"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    (d / "config/settings.txt").write_text(settings)
    return d


def gtk(steps, name, size=(W, H), settings="appearance=light\n", open_path=None, app=APP, extra=None):
    """omxplorer (or `app`) on the private display with MOJOUI_TEST `steps`; its output (a TEST: line is a FAIL)."""
    import headless
    headless.ensure()
    h = home(name, settings)
    env = {"OMX_DOCUMENTS": str(h / "docs"), "OMX_CONFIG": str(h / "config"), "MOJOUI_TEST": ";".join(steps) if isinstance(steps, list) else steps,
           "MOJOUI_WINDOW": f"{size[0]}x{size[1]}", "MOJOUI_SHOT": str(OUT / f"{name}-final.png"), "MOJOUI_TRACE": "1", "MOJOUI_BUDGET_MS": "50",
           "MOJOUI_SHOTS_EACH": str(OUT / name)}
    if open_path:
        env["OMX_OPEN"] = str(open_path)
    env.update(extra or {})
    r = run([str(app)], 1800, env)
    out = r.stdout + r.stderr
    (OUT / f"{name}.log").write_text(out)
    bad = [l for l in out.splitlines() if l.startswith("TEST:")]
    if r.returncode != 0 or bad:
        raise RuntimeError(f"GTK run {name} failed (exit {r.returncode}): " + " / ".join(bad)[:600] + ("" if bad else out[-600:]))
    return out


BOARDS_RE = re.compile(r"^BOARDS: (\S+) (\d+)x(\d+)(?: in (\d+)x(\d+))?(?: zoom (\d+))?$")
BOARD_RE = re.compile(r"^BOARD: (\S+) at (-?\d+),(-?\d+) (\d+)x(\d+)(?: \(asked (-?\d+),(-?\d+) (\d+)x(\d+)\))?$")
LIVE_RE = re.compile(r"^LIVE: (\S+) (\d+)/(\d+) (-?\d+),(-?\d+) (\d+)x(\d+)$")


def boards(out):
    """Each `boards:` dump by its step: {"size": (W, H), "room": (w, h), "zoom": z, "cards": {tag: (x, y, w, h) as GTK has it},
    "asked": {tag: (x, y, w, h) the app's page points}} (the snap guides aside)."""
    dumps, cur = {}, None
    for line in out.splitlines():
        m = BOARDS_RE.match(line)
        if m:
            cur = {"size": (int(m.group(2)), int(m.group(3))), "room": (int(m.group(4) or 0), int(m.group(5) or 0)),
                   "zoom": int(m.group(6) or 100), "cards": {}, "asked": {}}
            dumps[m.group(1)] = cur
            continue
        b = BOARD_RE.match(line)
        if b and cur is not None and b.group(1) != "board-guide":
            got = tuple(int(v) for v in b.groups()[1:5])
            cur["cards"][b.group(1)] = got
            cur["asked"][b.group(1)] = tuple(int(v) for v in b.groups()[5:9]) if b.group(6) is not None else got
        elif not line.startswith("BOARD") and not line.startswith("GUIDE") and line.strip() and cur is not None and not line.startswith("TRACE"):
            pass
    return dumps


def live(out):
    """Every freedrag's motion frames: a list of (tag, k, steps, (x, y, w, h)), in order."""
    return [(m.group(1), int(m.group(2)), int(m.group(3)), tuple(int(v) for v in m.groups()[3:])) for m in map(LIVE_RE.match, out.splitlines()) if m]


def drags(out):
    """The freedrags one by one: [(tag, handle, cursor, [frames…], [guide lines…])]."""
    res, cur = [], None
    for line in out.splitlines():
        if line.startswith("CURSOR: "):
            parts = line.split(" ", 3)
            cur = [parts[1], parts[2], parts[3] if len(parts) > 3 else "", [], []]
            res.append(cur)
        elif cur is not None:
            m = LIVE_RE.match(line)
            if m:
                cur[3].append(tuple(int(v) for v in m.groups()[3:]))
            elif line.startswith("LIVEGUIDE: "):
                cur[4].append(line[len("LIVEGUIDE: "):])
    return res


def scroll(out, axis=""):
    """Every `BOARDSCROLL{X}: value of upper, page` line, in order."""
    tag = "BOARDSCROLLX" if axis == "x" else "BOARDSCROLL"
    return [tuple(int(v) for v in m.groups()) for m in re.finditer(rf"^{tag}: (\d+) of (\d+), (\d+)$", out, re.M)]


def overlaps(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah


def any_overlap(rects):
    items = list(rects.items())
    return [f"{a} overlaps {b}" for i, (a, ra) in enumerate(items) for (b, rb) in items[i + 1:] if overlaps(ra, rb)]


def near(a, b, tol=1):
    return abs(a - b) <= tol


CARDS_JS = """() => { const b = document.querySelector('.board'), sc = b.parentElement, z = Number(b.dataset.zoom || 100) / 100, v = sc.getBoundingClientRect();
  return { zoom: z, board: [b.offsetWidth, b.offsetHeight], scroll: [sc.scrollLeft, sc.scrollTop, sc.scrollWidth, sc.scrollHeight, sc.clientWidth, sc.clientHeight],
           view: [v.left, v.top, v.width, v.height],
           cards: Object.fromEntries([...b.querySelectorAll(':scope > .object[data-tag]')].filter(e => e.dataset.tag !== 'board-guide')
             .map(e => { const r = e.getBoundingClientRect(); return [e.dataset.tag, [e.offsetLeft, e.offsetTop, e.offsetWidth, e.offsetHeight, r.left, r.top, r.width, r.height]]; })),
           guides: [...b.querySelectorAll(':scope > .object[data-tag=board-guide]')].map(e => [e.offsetLeft, e.offsetTop, e.offsetWidth, e.offsetHeight]).filter(g => g[0] >= 0) }; }"""


def web_drag(page, tag, handle, dx, dy, steps=6, alt=False, shot=None, read=None, mid=None, before_up=None):
    """Card `tag` grabbed by `handle` with the real mouse (where window.mojouiFreeHandle says a hand grabs it), moved dx, dy in
    `steps` moves (Alt held: no snap), let go. Returns (the cursor there, [each frame's card box (x, y, w, h) in page points])."""
    page.evaluate("""([t, h, dx, dy]) => { const sc = document.querySelector('.board').parentElement, v = sc.getBoundingClientRect(), p = window.mojouiFreeHandle(t, h);
      if (!p) return;  // (a hand drags where it can see: the handle, and where it goes, scrolled into the page first)
      const lo = (a, b) => Math.min(a, b), hi = (a, b) => Math.max(a, b);
      const x0 = lo(p[0], p[0] + dx), x1 = hi(p[0], p[0] + dx), y0 = lo(p[1], p[1] + dy), y1 = hi(p[1], p[1] + dy);
      if (x0 < v.left + 20 || x1 > v.right - 20) sc.scrollLeft += x0 - (v.left + 40);
      if (y0 < v.top + 20 || y1 > v.bottom - 20) sc.scrollTop += y0 - (v.top + 60); }""", [tag, handle, dx if abs(dx) < 600 else 0, dy])
    page.wait_for_timeout(300)
    at = page.evaluate("([t, h]) => window.mojouiFreeHandle(t, h)", [tag, handle])
    if not at:
        raise RuntimeError(f"web: no card {tag}")
    x, y = at
    page.mouse.move(x, y)
    page.wait_for_timeout(120)
    cursor = page.evaluate("([x, y, t]) => { const o = document.querySelector(`.board > .object[data-tag='${t}']`), e = document.elementFromPoint(x, y); "
                           "return getComputedStyle(e).cursor + '|' + (o && o.dataset.grab ? getComputedStyle(o).getPropertyValue('--grab').trim() : '') + '|' + o.closest('.board').style.cursor; }",
                           [x, y, tag])
    if alt:
        page.keyboard.down("Alt")
    page.mouse.down()
    frames = []
    for k in range(1, steps + 1):
        page.mouse.move(x + dx * k / steps, y + dy * k / steps)
        page.wait_for_timeout(160)
        s = page.evaluate(CARDS_JS)
        frames.append(tuple(s["cards"][tag][:4]))
        if read is not None:
            read.append(s)
        if shot and k == steps // 2:
            page.screenshot(path=str(shot))
        if mid and k == steps // 2:  # (something happens half way, the button still held: a scroll, a pause)
            mid(page)
    if before_up:  # (something happens after the last frame, the button still held, then the release with no move: a zoom)
        before_up(page)
    page.mouse.up()
    if alt:
        page.keyboard.up("Alt")
    page.wait_for_timeout(500)
    return cursor, frames
