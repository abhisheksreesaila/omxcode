"""Archived milestone checker (goal 6: GPU Data Lens; goal 5's checks run as M8, earlier goals' inside them).
Rebuilds from scratch, prints PASS/FAIL per milestone.

Run: scripts/check   (earlier goals' checkers: docs/goals/0N-check.py)

The lens is driven with the shared step language (scripts/drive.py) plus canvas steps:
  drag:0=100,50   pan canvas 0 by (100, 50) points
  zoom:0=2        zoom canvas 0 by 2× around its centre
  frames:0=180    let canvas 0 run 180 display frames; prints FRAMES: n in ms = fps, draws d
Each host reports CANVAS: <w>x<h> pt <W>x<H> px scale <s> colours <k> draws <d> painted <p>.
"""

import importlib.util
import re
import sys
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())  # (archived in docs/goals/)
sys.path.insert(0, str(ROOT / "scripts"))
from documented import documented  # noqa: E402

# Goal 5's checker (and through it goals 3–4): its helpers and milestones, pointed at this repo.
_spec = importlib.util.spec_from_file_location("goal5", ROOT / "docs/goals/05-check.py")
g5 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(g5)
g5.ROOT, g5.BUILD = ROOT, ROOT / "build"
run, gtk, web, apple_ok, state, BUILD = g5.run, g5.gtk, g5.web, g5.apple_ok, g5.state, g5.BUILD
# libSystem's maths and clock (D-61): the lens's trip generator uses sin/cos, PointCloud times frames.
g5.ALLOWED |= {"_sin", "_cos", "___sincos_stret", "_clock_gettime_nsec_np"}

EXAMPLES = g5.EXAMPLES + ["lens"]
TOTAL = 20_000_000
# Lines that depend on the canvas's size or on timing, so they differ between hosts by design.
GEOMETRY_OR_TIMING = ("LABEL: In view", "LABEL: Frame", "LABEL: Device")


def lens_state(out):
    return [l for l in state(out) if not l.startswith(GEOMETRY_OR_TIMING)]


def canvas(out):
    m = re.search(r"^CANVAS: (\d+)x(\d+) pt (\d+)x(\d+) px scale ([\d.]+) colours (\d+) draws (\d+) painted (\d+)$", out, re.M)
    return None if not m else dict(wpt=int(m[1]), hpt=int(m[2]), wpx=int(m[3]), hpx=int(m[4]), scale=float(m[5]),
                                   colours=int(m[6]), draws=int(m[7]), painted=int(m[8]))


PAINTED = 15  # percent of the canvas away from its background: blank ≈ 0, the lens tens of percent (goal 7's measure, D-70;
# colour counts depended on the renderer's antialiasing and on JPEG vs PNG frames; owner's decision 2026-10-16)


def frames(out):
    m = re.search(r"^FRAMES: (\d+) in ([\d.]+) ms = ([\d.]+) fps, draws (\d+)$", out, re.M)
    return None if not m else dict(n=int(m[1]), ms=float(m[2]), fps=float(m[3]), draws=int(m[4]))


def view_line(out):
    """(centre x, centre y, zoom) from the lens's 'View:' label."""
    m = re.search(r"^LABEL: View: centre \(([-\d.]+), ([-\d.]+)\), zoom ([\d.]+)×$", out, re.M)
    return None if not m else (float(m[1]), float(m[2]), float(m[3]))


def matching(out):
    m = re.search(r"^LABEL: Matching: ([\d,]+) of ([\d,]+) trips$", out, re.M)
    return None if not m else (int(m[1].replace(",", "")), int(m[2].replace(",", "")))


def gtk_shown(steps, shot=None):
    """GTK run with the window on screen (it must be shown to lay out, draw and tick)."""
    return gtk("lens", steps, shot=shot or str(BUILD / "lens" / "shown.png"))


# ---------- milestones ----------

def m1():
    t = run(["pixi", "run", "mojo", "run", "-I", ".", "tests/test_canvas.mojo"], timeout=600)
    if "CANVAS TESTS PASSED" not in t.stdout:
        return False, f"canvas tests: {(t.stdout + t.stderr)[-500:]}"
    t2 = run(["pixi", "run", "mojo", "run", "-I", ".", "tests/test_mojoui.mojo"], timeout=600)
    if t2.returncode != 0 or "FAIL" in t2.stdout:
        return False, f"core tests: {(t2.stdout + t2.stderr)[-300:]}"
    return True, "Canvas node, gesture/frame events, draw(), Surface, version → redraw patch; core tests pass"


def m2():
    problems = []
    r, base = gtk_shown("")
    if r is None:
        return False, base
    c = canvas(base)
    if not c:
        return False, f"no CANVAS line: {base[-400:]}"
    if abs(c["wpx"] - round(c["wpt"] * c["scale"])) > 1 or abs(c["hpx"] - round(c["hpt"] * c["scale"])) > 1:
        problems.append(f"canvas drawn at {c['wpx']}x{c['hpx']} px, laid out at {c['wpt']}x{c['hpt']} pt × {c['scale']}")
    if c["wpt"] < 400 or c["hpt"] < 300:
        problems.append(f"canvas too small: {c['wpt']}x{c['hpt']} pt")
    if c["painted"] < PAINTED:
        problems.append(f"canvas looks blank ({c['painted']}% painted, {c['colours']} colours)")
    r1, dragged = gtk_shown("drag:0=100,50")
    r2, zoomed = gtk_shown("drag:0=100,50;zoom:0=2")
    v0, v1, v2 = view_line(base), view_line(dragged or ""), view_line(zoomed or "")
    if not (v0 and v1 and v2):
        return False, f"no View label: {base[-300:]}"
    dx, dy = v1[0] - v0[0], v1[1] - v0[1]
    if not (dx < 0 and dy < 0 and abs(dx / dy - 2) < 0.01):
        problems.append(f"drag (100, 50) should move the centre up-left by 2:1, got {v0} → {v1}")
    if not (abs(v2[2] - 2 * v1[2]) < 1e-6 and v2[:2] == v1[:2]):
        problems.append(f"zoom 2× at the centre should double zoom, keep the centre: {v1} → {v2}")
    return not problems, "; ".join(problems) or (
        f"canvas {c['wpt']}x{c['hpt']} pt drawn at {c['wpx']}x{c['hpx']} px (scale {c['scale']}), {c['painted']}% painted; drag + zoom reach update()")


def m3():
    r, out = gtk_shown("toggle:Play;frames:0=180")
    if r is None:
        return False, out
    f = frames(out)
    if not f:
        return False, f"no FRAMES line: {out[-400:]}"
    mt = matching(out)
    problems = []
    if not mt or mt[1] != TOTAL:
        problems.append(f"lens should hold {TOTAL:,} points: {mt}")
    if f["fps"] < 55:
        problems.append(f"{f['fps']} fps < 55")
    if f["draws"] < f["n"] - 5:
        problems.append(f"only {f['draws']} redraws in {f['n']} frames")
    return not problems, "; ".join(problems) or f"GTK, playing, {TOTAL:,} points: {f['n']} frames in {f['ms']:.0f} ms = {f['fps']} fps, {f['draws']} redraws"


def bench():
    exe = BUILD / "bench_lens"
    b = run(["scripts/mxbuild.sh", "-I", "examples/lens", "-I", ".", "tests/bench_lens.mojo", "-o", str(exe)], timeout=900)
    if b.returncode != 0:
        return None, f"bench build failed: {(b.stdout + b.stderr)[-500:]}"
    r = run([str(exe)], timeout=600)
    m = re.search(r"^BENCH: (.*)$", r.stdout, re.M)
    if r.returncode != 0 or not m:
        return None, f"bench failed: {(r.stdout + r.stderr)[-500:]}"
    return dict(kv.split("=", 1) for kv in m[1].split()), r.stdout


def m4():
    b, out = bench()
    if b is None:
        return False, out
    problems = []
    ms = float(b["gpu_median_ms"])
    if int(b["points"]) != TOTAL or b["size"] != "1920x1080":
        problems.append(f"bench should draw {TOTAL:,} points at 1920x1080: {b}")
    if ms > 8:
        problems.append(f"GPU frame {ms} ms > 8 ms")
    if int(b["uploads"]) != 1:
        problems.append(f"data uploaded {b['uploads']} times (want once)")
    if b["matched_gpu"] != b["matched_cpu"]:
        problems.append(f"GPU matched {b['matched_gpu']} != CPU {b['matched_cpu']}")
    if float(b["same_pixels"]) < 0.999:
        problems.append(f"only {b['same_pixels']} of pixels match the CPU")
    return not problems, "; ".join(problems) or (
        f"{TOTAL:,} points at 1920x1080: GPU {ms} ms/frame (bin + shade + copy), CPU {b['cpu_ms']} ms; "
        f"matched {b['matched_gpu']} on both; {float(b['same_pixels']) * 100:.3f}% identical pixels; uploaded once")


def m5():
    problems = []
    src = (ROOT / "examples/lens/app.mojo").read_text()
    imports = set(re.findall(r"^\s*(?:from|import)\s+([\w.]+)", src, re.M))
    if any(not (i == "mojoui" or i.startswith("mojoui.")) for i in imports):
        problems.append(f"lens imports more than mojoui: {sorted(imports)}")
    if g5.PLATFORM_WORDS.search(src):
        problems.append(f"lens mentions a platform API: {g5.PLATFORM_WORDS.search(src)[0]}")
    b, out = bench()
    if b is None:
        return False, out
    counts = {}
    for steps in ["", "segment:0=Taxi", "segment:0=Rideshare", "segment:0=Bike", "slide:0=30", "segment:0=Bike;slide:0=30"]:
        r, o = gtk_shown(steps) if steps == "" else gtk("lens", steps)
        mt = matching(o or "")
        if r is None or not mt:
            return False, f"lens run '{steps}' failed: {(o or '')[-300:]}"
        counts[steps] = mt[0]
    if counts[""] != TOTAL:
        problems.append(f"all trips should match at start: {counts['']}")
    kinds = counts["segment:0=Taxi"] + counts["segment:0=Rideshare"] + counts["segment:0=Bike"]
    if kinds != TOTAL or min(counts["segment:0=Taxi"], counts["segment:0=Rideshare"], counts["segment:0=Bike"]) == 0:
        problems.append(f"the three kinds should split all trips: {counts}")
    if str(counts["segment:0=Bike;slide:0=30"]) != b.get("naive_bike_hour30"):
        problems.append(f"Bike at the hour-30 setting: app {counts['segment:0=Bike;slide:0=30']} vs an independent count {b.get('naive_bike_hour30')}")
    if not 0 < counts["slide:0=30"] < TOTAL:
        problems.append(f"the hour slider should filter: {counts['slide:0=30']}")
    shot = BUILD / "lens" / "shown.png"
    try:
        from PIL import Image
        colours = len(set(Image.open(shot).convert("RGB").getdata()))
        if colours < 500:
            problems.append(f"screenshot has only {colours} colours")
    except Exception as e:
        problems.append(f"screenshot unreadable: {e!r}")
    return not problems, "; ".join(problems) or (
        f"imports only mojoui; kinds split {TOTAL:,} trips; hour filter matches an independent count ({counts['segment:0=Bike;slide:0=30']:,}); rich screenshot")


LENS_STEPS = "segment:0=Rideshare;slide:0=40;drag:0=120,-60;zoom:0=2"


def m6():
    problems = []
    r, wout = web("lens", LENS_STEPS, shot=str(BUILD / "lens" / "web.png"))
    if r is None:
        return False, wout
    rg, gout = gtk("lens", LENS_STEPS)
    if rg is None:
        return False, gout
    c = canvas(wout)
    if not c:
        return False, f"no CANVAS on the web: {wout[-400:]}"
    if abs(c["wpx"] - round(c["wpt"] * c["scale"])) > 1 or abs(c["hpx"] - round(c["hpt"] * c["scale"])) > 1:
        problems.append(f"web frame {c['wpx']}x{c['hpx']} px for a {c['wpt']}x{c['hpt']} pt canvas × {c['scale']}")
    if c["painted"] < PAINTED:
        problems.append(f"web canvas looks blank ({c['painted']}% painted, {c['colours']} colours)")
    ws, gs = lens_state(wout), lens_state(gout)
    if ws != gs:
        problems.append(f"web and GTK differ:\n  web {ws}\n  gtk {gs}")
    if not view_line(wout) or view_line(wout)[2] != 2.0:
        problems.append(f"real wheel/drag didn't reach the app on the web: {view_line(wout)}")
    # A frame that changes the screen's shape (playback ends, a button appears) must reach the page.
    (BUILD / "frame_rebuild" / "web").mkdir(parents=True, exist_ok=True)  # (a fresh worktree has no such folder)
    b = run(["scripts/mxbuild.sh", "-I", "tests/frame_rebuild", "-I", ".", "hosts/web_main.mojo", "--emit", "shared-lib",
             "-o", str(BUILD / "frame_rebuild" / "web" / "mojoui_app.so")], timeout=900)
    import drive
    rr, rout = drive.web_run(BUILD / "frame_rebuild" / "web", "toggle:Play;wait:Replay;tap:Replay") if b.returncode == 0 else (None, b.stderr[-300:])
    if rr is None or rr.returncode != 0 or "LABEL: Frames: 0" not in rout or "TOGGLE: Play=off" not in rout:
        problems.append(f"a frame-driven rebuild didn't reach the page: {rout[-300:]}")
    rp, pout = web("lens", "toggle:Play;frames:0=60")
    f = frames(pout or "")
    if rp is None or not f:
        problems.append(f"web playing: no FRAMES: {(pout or '')[-300:]}")
    elif f["fps"] < 20:
        problems.append(f"web streams {f['fps']} fps < 20")
    return not problems, "; ".join(problems) or (
        f"web canvas {c['wpx']}x{c['hpx']} px, real drag + wheel reach the app, state identical to GTK; playing {f['fps']} fps")


def m7():
    problems = []
    for plat in ("mac", "ios"):
        ok, msg = apple_ok("lens", plat)
        if not ok:
            problems.append(msg)
    for host, words in {"mojoui/hosts/appkit.mojo": ["CANVAS", "NSImageView", "displayLinkWithTarget", "NSPanGestureRecognizer",
                                                      "NSMagnificationGestureRecognizer", "draw_canvas"],
                        "mojoui/hosts/uikit.mojo": ["CANVAS", "UIImageView", "CADisplayLink", "UIPanGestureRecognizer",
                                                     "UIPinchGestureRecognizer", "draw_canvas"]}.items():
        text = (ROOT / host).read_text()
        # (the Mac's canvases tick from a 60 Hz NSTimer since 6ce216a: the view's display link never fired on macOS 26;
        # either clock counts as the frame clock, D-560)
        missing = [w for w in words if w not in text and not (w == "displayLinkWithTarget" and "timerWithTimeInterval:target:selector:userInfo:repeats:" in text)]
        if missing:
            problems.append(f"{host} lacks {missing}")
    bad = g5.same_source("lens", ["linux", "web", "mac", "ios"])
    if bad:
        problems.append(f"not built from the same app.mojo: {bad}")
    return not problems, "; ".join(problems) or "lens builds, links and signs for Mac + iPhone (CPU path, Apple system functions only); Canvas mapped to image view + display link + pan/pinch"


def m8():
    problems = []
    for name in ["m1", "m2", "m3", "m4", "m5", "m6", "m7", "m8", "m9", "m10", "m11"]:
        ok, msg = getattr(g5, name)()
        if not ok:
            problems.append(f"goal 5 {name.upper()}: {msg[:200]}")
    return not problems, "; ".join(problems) or "goal 5's checks (and goals 3–4's inside them) still pass"


def m9():
    problems = []
    readme = documented()  # README.md + docs/reference.md (D-270)
    for m in ("Canvas(", "on_gesture", "on_frame", "def draw(", "Surface", "mojoui.gpu", "PAN", "ZOOM", "examples/lens/app.mojo"):
        if m not in readme:
            problems.append(f"README.md doesn't show {m}")
    report = ROOT / "docs/goals/06-report.md"
    text = report.read_text() if report.exists() else ""
    if not re.search(r"\d+(\.\d+)? fps", text) or not re.search(r"\d+(\.\d+)? ms", text):
        problems.append("docs/goals/06-report.md lacks fps and ms numbers")
    imgs = re.findall(r"\]\((img/[^)]+\.png)\)", text)
    if not imgs or any(not (ROOT / "docs" / i).exists() for i in imgs):
        problems.append(f"report screenshots missing: {imgs}")
    return not problems, "; ".join(problems) or "README documents Canvas, gestures, frames, draw(), mojoui.gpu; report has numbers + screenshots"


def main():
    import shutil
    for ex in EXAMPLES:
        shutil.rmtree(BUILD / ex, ignore_errors=True)
    for ex in EXAMPLES:
        if not (ROOT / "examples" / ex / "app.mojo").exists():
            continue
        b = run(["scripts/build.sh", ex, "all"], timeout=3600)
        if b.returncode != 0:
            print(f"build {ex} failed:\n" + (b.stdout + b.stderr)[-1500:])
    results = []
    for name, fn in [("M1", m1), ("M2", m2), ("M3", m3), ("M4", m4), ("M5", m5), ("M6", m6), ("M7", m7),
                     ("M8", m8), ("M9", m9)]:
        try:
            ok, msg = fn()
        except Exception as e:  # a crashing check is a failing check
            ok, msg = False, f"check crashed: {e!r}"
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {msg}")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
