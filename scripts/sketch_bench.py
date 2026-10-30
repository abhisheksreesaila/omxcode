"""Goal 40 M4: is Sketch fast enough to draw on? Writes docs/goals/40/bench.json.

Runs examples/sketch headless (scripts/headless.py: Xvfb, GTK's renderer recorded) with SKETCH_STROKES=1000 (1,000
seeded strokes, 101,000 points) and the GTK host's generic `framebench:` step: 120 pans, 120 zoom steps and a 120-move
pen stroke, one frame each. A frame's work = the gesture's handling + the canvas's redraw (draw_scene, replay) + GTK's
paint of that frame. The "ink" layer must be rebuilt 0 times while panning and zooming (only moved).

    pixi run python scripts/sketch_bench.py            (builds first unless --no-build)
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import headless  # noqa: E402

STROKES = 1000
POINTS_EACH = 101
N = 120


def main():
    if "--no-build" not in sys.argv:
        subprocess.run(["scripts/build.sh", "sketch", "linux"], cwd=ROOT, check=True)
    headless.ensure()
    steps = ["pause:300", "tap:Pan", f"framebench:0=pan,{N}", f"framebench:0=zoom,{N}", "tap:Pen", f"framebench:0=draw,{N}"]
    env = dict(os.environ, MOJOUI_TEST=";".join(steps), SKETCH_STROKES=str(STROKES), MOJOUI_SHOT="/tmp/sketch-bench.png")
    r = subprocess.run([str(ROOT / "build/sketch/linux/sketch")], cwd=ROOT, env=env, capture_output=True, text=True, timeout=1800)
    out = r.stdout + r.stderr
    res = {}
    for line in out.splitlines():
        if not line.startswith("FRAMEBENCH:"):
            continue
        what = line.split()[1]
        kv = dict(re.findall(r"(\w+)=(\S+)", line))
        res[what] = kv
    if r.returncode != 0 or set(res) != {"pan", "zoom", "draw"}:
        print(out[-2000:])
        sys.exit("the bench didn't finish")
    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    bench = {
        "commit": commit,
        "strokes": STROKES,
        "points": STROKES * POINTS_EACH,
        "renderer": res["pan"]["renderer"],
        "display": "Xvfb (scripts/headless.py), GDK_SCALE=1, " + os.environ.get("GSK_RENDERER", "?"),
        "frame": "gesture handling + canvas redraw (draw_scene + replay) + GTK paint of that frame + display round trip (X server drawing) + the canvas's whole picture rendered to a texture by the same renderer (an upper bound), ms",
    }
    for what in ("pan", "zoom", "draw"):
        kv = res[what]
        bench[what] = {
            "frames": int(kv["n"]), "missed": int(kv["missed"]),
            "p50_ms": float(kv["p50"]), "p95_ms": float(kv["p95"]), "max_ms": float(kv["max"]),
            "event_p95_ms": float(kv["event_p95"]), "draw_p95_ms": float(kv["draw_p95"]), "paint_p95_ms": float(kv["paint_p95"]),
            "sync_p95_ms": float(kv["sync_p95"]), "raster_p95_ms": float(kv["raster_p95"]),
            "layers_built": int(kv["layers_built"]), "layers_reused": int(kv["reused"]), "ink_layer_rebuilds": int(kv["ink_built"]),
            "layer_textures": int(kv["textures"]),
        }
    path = ROOT / "docs/goals/40/bench.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(bench, indent=2) + "\n")
    print(json.dumps(bench, indent=2))


if __name__ == "__main__":
    main()
