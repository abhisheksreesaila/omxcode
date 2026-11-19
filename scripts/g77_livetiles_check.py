"""Goal 77 M7b's proof: mojoui.livetiles (GOAL.md M7b). Run by docs/goals/77-stage-check.py m7b(), or alone:

    pixi run python scripts/g77_livetiles_check.py

1. tests/test_livetiles.mojo (presets fill 12 cells, dense packing, the water spring settles within 1 s and overshoots
   at most 3 %, words at the final rect from the first frame, drag, grip, press amounts, overflow, parts).
2. examples/livetiles built for Linux and the web.
3. On GTK (headless) and on the web host (headless Chromium), 1280 x 820: "Promote weather" makes weather the large tile.
   The app writes every frame it draws (LIVETILES_TRACE: each tile's surface rect and its words' box, opacity, font size,
   with the wall clock). From that record: the promoted tile's surface moves monotonically to its new rect (each side's
   progress never goes back before it arrives, and never passes the change by more than 3 %), settles within 0.5 pt in
   <= 1.1 s of wall time, and its words are laid out at the final rect, at the final font size, on every frame (clear for
   the first 30 % of the water's time): never stretched. Then a synthetic drag (todo onto calendar) must report the new
   order and a corner-grip drag (counter's) must report "counter resized to s".
4. Pictures: docs/goals/77/m7b-{before,mid,after,drag,dark}.png (GTK; mid = the canvas's own pixels 250 ms into the
   motion, since a GTK test step settles for up to a second) and m7b-web-{before,mid,after,dark}.png (Chromium screenshots
   taken every ~40 ms during the motion).
Prints the numbers; returns ("PASS" | "FAIL" | "BLOCKED", why).
"""
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build/g77/m7b"
SHOTS = ROOT / "docs/goals/77"
sys.path.insert(0, str(ROOT / "scripts"))

PAD, GAP, COLS, ROWS = 14.0, 12.0, 4, 3
SETTLE_MS = 1100
OVERSHOOT = 0.03
ORDER_AFTER_DRAG = "traffic,cal,todo,counter,bday,weather"


def sh(cmd, timeout=1800, env=None):
    e = dict(os.environ)
    e.update(env or {})
    return subprocess.run(cmd, cwd=ROOT, env=e, capture_output=True, text=True, timeout=timeout)


def cell_box(c, r, cw_cells, rh_cells, w, h):
    """mojoui.livetiles.cell_box in Python: a cell rect's box in points on a canvas w x h."""
    cw = (w - 2 * PAD - (COLS - 1) * GAP) / COLS
    ch = (h - 2 * PAD - (ROWS - 1) * GAP) / ROWS
    return (PAD + c * (cw + GAP), PAD + r * (ch + GAP), cw_cells * cw + (cw_cells - 1) * GAP, rh_cells * ch + (rh_cells - 1) * GAP)


def read_trace(path):
    """[(kind, wall_ms, payload)]: EV lines (text) and D frames ({id: [sx, sy, sw, sh, tx, ty, tw, th, op, font]}, canvas w, h)."""
    out = []
    cur = None
    for line in Path(path).read_text().splitlines():
        if line.startswith("EV "):
            _, ms, text = line.split(" ", 2)
            out.append(("EV", int(ms), text))
            cur = None
        elif line.startswith("D "):
            v = line.split()
            cur = {"clock": int(v[2]), "w": float(v[3]), "h": float(v[4]), "tiles": {}}
            out.append(("D", int(v[1]), cur))
        elif cur is not None and line.strip():
            v = line.split()
            cur["tiles"][v[0]] = [float(x) for x in v[1:]]
    return out


def motion(trace, event, tile):
    """The promoted tile's frames from `event` (an EV text prefix) to the next EV: numbers and problems."""
    i0 = next((i for i, e in enumerate(trace) if e[0] == "EV" and e[2].startswith(event)), None)
    if i0 is None:
        return None, [f"no '{event}' in the trace"]
    before = next((e[2]["tiles"][tile] for e in reversed(trace[:i0]) if e[0] == "D" and tile in e[2]["tiles"]), None)
    frames = []
    for e in trace[i0 + 1:]:
        if e[0] == "EV" and not e[2].startswith("SHOT"):
            break
        if e[0] == "D" and tile in e[2]["tiles"]:
            frames.append((e[1] - trace[i0][1], e[2]["clock"], e[2]["tiles"][tile]))
    if before is None or len(frames) < 5:
        return None, [f"{tile}: {len(frames)} frames recorded after '{event}' (need a before and >= 5)"]
    end = frames[-1][2]
    probs = []
    worst = 0.0
    for k in range(4):  # x, y, w, h
        a, b = before[k], end[k]
        d = b - a
        if abs(d) < 1.0:
            continue
        arrived = False
        last = 0.0
        for _, _, f in frames:
            q = (f[k] - a) / d
            worst = max(worst, q - 1.0)
            if not arrived:
                if q < last - 0.002:
                    probs.append(f"side {'xywh'[k]} went back before arriving ({last:.3f} -> {q:.3f})")
                    break
                last = q
                arrived = q >= 1.0 - 1e-6 or abs(f[k] - b) < 0.5
            elif abs(q - 1.0) > OVERSHOOT:
                probs.append(f"side {'xywh'[k]} strayed {abs(q - 1.0) * 100:.1f}% after arriving")
                break
    if worst > OVERSHOOT:
        probs.append(f"overshoot {worst * 100:.1f}% > {OVERSHOOT * 100:.0f}%")
    settled = None
    for wall, clock, f in frames:
        close = all(abs(f[k] - end[k]) < 0.5 for k in range(4))
        if close and settled is None:
            settled = (wall, clock)
        elif not close:
            settled = None
    if settled is None or settled[0] > SETTLE_MS:
        probs.append(f"settled at {settled} ms (wall, frame clock) > {SETTLE_MS} ms")
    # the words: the final rect and the final font on every frame, clear for the first 30 % of the water's time
    stretched = [f for _, _, f in frames if abs(f[6] - end[2]) > 0.11 or abs(f[7] - end[3]) > 0.11 or f[9] != end[9]]
    if stretched:
        probs.append(f"{len(stretched)} frames drew the words outside the final rect or at another size")
    early_lit = [(c, f[8]) for _, c, f in frames if c - frames[0][1] < 150 and f[8] > 0.0]
    if early_lit:
        probs.append(f"words visible early: {early_lit[:3]}")
    grew = end[2] * end[3] > before[2] * before[3]
    if not grew:
        probs.append("the promoted tile did not grow")
    nums = {"frames": len(frames), "from": [round(x, 1) for x in before[:4]], "to": [round(x, 1) for x in end[:4]],
            "overshoot_pct": round(worst * 100, 2), "settled_wall_ms": settled[0] if settled else None,
            "settled_clock_ms": settled[1] - frames[0][1] if settled else None, "text_box": [end[6], end[7]], "font": end[9]}
    return nums, probs


def gtk_run(steps, trace, shot=None, timeout=180):
    import headless

    headless.ensure()
    env = {"LIVETILES_TRACE": str(trace), "MOJOUI_TEST": steps}
    if shot:
        env["LIVETILES_SHOT"] = shot
    if trace.exists():
        trace.unlink()
    return sh([str(ROOT / "build/livetiles/linux/livetiles")], timeout, env)


def results(trace):
    return [e[2][len("RESULT "):] for e in trace if e[0] == "EV" and e[2].startswith("RESULT ")]


def gestures_ok(trace, where):
    got = results(trace)
    probs = []
    if f"order: {ORDER_AFTER_DRAG}" not in got:
        probs.append(f"{where}: the drag did not reorder to {ORDER_AFTER_DRAG} (results {got})")
    if "counter resized to s" not in got:
        probs.append(f"{where}: the grip did not resize counter to s (results {got})")
    return probs


def first_frame(trace):
    return next(e[2] for e in trace if e[0] == "D")


def check_gtk(said, probs):
    OUT.mkdir(parents=True, exist_ok=True)
    cal = OUT / "gtk-calibrate.txt"
    r = gtk_run(f"wait:600;shot:{OUT}/gtk-calibrate.png", cal)  # (a test run shows its window only for a shot)
    t = read_trace(cal) if cal.exists() else []
    if not t or not any(e[0] == "D" for e in t):
        probs.append("GTK: the app drew nothing: " + (r.stdout + r.stderr)[-400:])
        return
    f0 = first_frame(t)
    w, h = f0["w"], f0["h"]
    todo = cell_box(2, 0, 2, 1, w, h)
    cal_ = cell_box(2, 1, 2, 1, w, h)
    counter = cell_box(0, 2, 2, 1, w, h)
    tx, ty = todo[0] + todo[2] / 2, todo[1] + todo[3] / 2
    cx, cy = cal_[0] + cal_[2] / 2, cal_[1] + cal_[3] / 2
    drag = ";".join(f"{tx:.0f},{ty + (cy - ty) * k / 4:.0f},0.5" for k in range(5))
    gx, gy = counter[0] + counter[2] - 6, counter[1] + counter[3] - 6
    grip = ";".join(f"{gx - (counter[2] / 2) * k / 3:.0f},{gy:.0f},0.5" for k in range(4))
    trace = OUT / "gtk-trace.txt"
    mid = OUT / "m7b-mid.png"
    if mid.exists():
        mid.unlink()
    steps = (f"wait:800;shot:{OUT}/m7b-before.png;tap:Promote weather;wait:1500;shot:{OUT}/m7b-after.png;tap:Reset;wait:1200;"
             f"stroke:tiles={drag};wait:1200;stroke:tiles={grip};wait:1200;shot:{OUT}/m7b-drag.png;scheme:dark;wait:800;shot:{OUT}/m7b-dark.png")
    r = gtk_run(steps, trace, shot=f"{mid}@250")
    if not trace.exists():
        probs.append("GTK: no trace: " + (r.stdout + r.stderr)[-400:])
        return
    t = read_trace(trace)
    nums, bad = motion(t, "RAIN AT PICKUP", "weather")
    probs += ["GTK: " + b for b in bad]
    probs += gestures_ok(t, "GTK")
    if nums:
        said.append(f"GTK {w:.0f}x{h:.0f} pt: weather {nums['from']} -> {nums['to']} in {nums['frames']} frames, overshoot {nums['overshoot_pct']}%, "
                    f"settled {nums['settled_wall_ms']} ms wall / {nums['settled_clock_ms']} ms frame clock, words {nums['text_box']} at {nums['font']} pt every frame")
    if not gestures_ok(t, "GTK"):
        said.append("GTK drag -> order " + ORDER_AFTER_DRAG + ", grip -> counter s")
    if mid.exists():  # (mojoui.png stores its pixels uncompressed: 3.5 MB; Pillow writes the same picture compressed)
        from PIL import Image
        Image.open(mid).save(mid, optimize=True)
    for name in ("m7b-before.png", "m7b-mid.png", "m7b-after.png", "m7b-drag.png", "m7b-dark.png"):
        if (OUT / name).exists():
            shutil.copy(OUT / name, SHOTS / name)
        else:
            probs.append(f"GTK: no {name}")


def check_web(said, probs):
    import drive

    trace = OUT / "web-trace.txt"
    if trace.exists():
        trace.unlink()
    shots = {}

    def during(page):
        box = drive.canvas_at(page, "tiles").bounding_box()
        page.wait_for_timeout(600)
        page.screenshot(path=str(OUT / "m7b-web-before.png"))
        page.locator("[data-kind=button]").filter(has_text=drive.exact("Promote weather")).first.click()
        t0 = time.time()
        k = 0
        while time.time() - t0 < 1.3:
            p = OUT / f"web-frame-{k:02d}.png"
            page.screenshot(path=str(p))
            shots[k] = (time.time() - t0, p)
            k += 1
            page.wait_for_timeout(40)
        page.wait_for_timeout(500)
        page.screenshot(path=str(OUT / "m7b-web-after.png"))
        page.locator("[data-kind=button]").filter(has_text=drive.exact("Reset")).first.click()
        page.wait_for_timeout(1500)
        t = read_trace(trace)
        f0 = first_frame(t)
        w, h = f0["w"], f0["h"]
        todo = cell_box(2, 0, 2, 1, w, h)
        cal_ = cell_box(2, 1, 2, 1, w, h)
        counter = cell_box(0, 2, 2, 1, w, h)
        x0, y0 = box["x"], box["y"]
        page.mouse.move(x0 + todo[0] + todo[2] / 2, y0 + todo[1] + todo[3] / 2)
        page.mouse.down()
        for s in range(1, 9):
            page.mouse.move(x0 + todo[0] + todo[2] / 2, y0 + todo[1] + todo[3] / 2 + (cal_[1] - todo[1]) * s / 8)
            page.wait_for_timeout(30)
        page.mouse.up()
        page.wait_for_timeout(1300)
        gx, gy = x0 + counter[0] + counter[2] - 6, y0 + counter[1] + counter[3] - 6
        page.mouse.move(gx, gy)
        page.mouse.down()
        for s in range(1, 7):
            page.mouse.move(gx - counter[2] / 2 * s / 6, gy)
            page.wait_for_timeout(30)
        page.mouse.up()
        page.wait_for_timeout(1300)
        return f"WEB CANVAS: {box['width']:.0f}x{box['height']:.0f}\n"

    r, out = drive.web_run(ROOT / "build/livetiles/web", "", viewport=(1280, 820), env={"LIVETILES_TRACE": str(trace)}, during=during)
    if not trace.exists():
        probs.append("web: no trace: " + out[-400:])
        return
    t = read_trace(trace)
    nums, bad = motion(t, "RAIN AT PICKUP", "weather")
    probs += ["web: " + b for b in bad]
    probs += gestures_ok(t, "web")
    if r.returncode:
        probs.append("web: page errors: " + out[-300:])
    if nums:
        said.append(f"web: weather {nums['from']} -> {nums['to']} in {nums['frames']} frames, overshoot {nums['overshoot_pct']}%, "
                    f"settled {nums['settled_wall_ms']} ms wall / {nums['settled_clock_ms']} ms frame clock, words {nums['text_box']} at {nums['font']} pt every frame")
    if not gestures_ok(t, "web"):
        said.append("web drag -> order, grip -> counter s")
    # the mid-motion picture: the screenshot nearest 250 ms after the click; the frames differ from each other (it moved)
    if shots:
        k = min(shots, key=lambda i: abs(shots[i][0] - 0.25))
        shutil.copy(shots[k][1], SHOTS / "m7b-web-mid.png")
        sizes = {p.read_bytes().__hash__() for _, p in shots.values()}
        said.append(f"web: {len(shots)} screenshots during the motion, {len(sizes)} distinct")
        if len(sizes) < 4:
            probs.append(f"web: only {len(sizes)} distinct screenshots during the motion")
    for name in ("m7b-web-before.png", "m7b-web-after.png"):
        if (OUT / name).exists():
            shutil.copy(OUT / name, SHOTS / name)
    # dark, once more on its own page
    r2, _ = drive.web_run(ROOT / "build/livetiles/web", "pause:600", shot=str(OUT / "m7b-web-dark.png"), viewport=(1280, 820), color_scheme="dark")
    if (OUT / "m7b-web-dark.png").exists():
        shutil.copy(OUT / "m7b-web-dark.png", SHOTS / "m7b-web-dark.png")


def run():
    said, probs = [], []
    OUT.mkdir(parents=True, exist_ok=True)
    SHOTS.mkdir(parents=True, exist_ok=True)
    r = sh(["pixi", "run", "mojo", "run", "--disable-warnings", "-I", ".", "tests/test_livetiles.mojo"], 900)
    if "livetiles: ok" not in r.stdout:
        return "FAIL", "tests/test_livetiles: " + (r.stdout + r.stderr)[-600:]
    unit = [l.strip() for l in r.stdout.splitlines() if l.startswith("  ")]
    said.append("unit: " + "; ".join(unit))
    for target in ("linux", "web"):
        b = sh(["bash", "scripts/build.sh", "livetiles", target], 1800)
        if b.returncode:
            return "FAIL", f"build {target}: " + (b.stdout + b.stderr)[-600:]
    check_gtk(said, probs)
    check_web(said, probs)
    print("\n".join("  " + s for s in said))
    if probs:
        return "FAIL", "; ".join(probs)
    return "PASS", " | ".join(said)


if __name__ == "__main__":
    state, why = run()
    print(f"M7B: {state}  {why}")
    sys.exit(0 if state == "PASS" else 1)
