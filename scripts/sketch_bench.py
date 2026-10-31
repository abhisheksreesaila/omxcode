"""Goal 40 M4: is Sketch fast enough to draw on? Writes docs/goals/40/bench.json.

Runs examples/sketch headless (scripts/headless.py: Xvfb, GTK's renderer recorded) with SKETCH_STROKES=1000 (1,000
seeded strokes, 101,000 points) and the GTK host's generic `framebench:` step, one frame per gesture: 120 pans, 120 zoom
steps, a 120-move pen stroke, 120 frames of short strokes (finish: press, three moves, release; the releases, where a
stroke joins the page, and the frame after each also on their own), a 120-move eraser drag (erase: moves that hit
nothing don't redraw; a stroke erased keeps the other strokes' nodes: trimmed_by_layer, D-1707), and 120 zoom steps at 8× (deepzoom: past the page texture's 4096 px cap). A frame's work = the
gesture's handling + the canvas's redraw (draw_scene, replay) + GTK's paint + a display round trip + a full render of
the canvas (an upper bound). The host counts each layer key's builds (built_by_layer); the "ink" layer must be built
0 times while panning and zooming (only moved). p95 and max for every phase.

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
PHASES = ("pan", "zoom", "deepzoom", "draw", "finish", "erase")


def per_layer(s):
    """"paper:0,ink:2,wet:120" → {"paper": 0, "ink": 2, "wet": 120} ("-": none)."""
    return {} if s == "-" else {k: int(v) for k, v in (kv.split(":") for kv in s.split(","))}


def main():
    if "--no-build" not in sys.argv:
        subprocess.run(["scripts/build.sh", "sketch", "linux"], cwd=ROOT, check=True)
    headless.ensure()
    steps = ["pause:300", "tap:Pan", f"framebench:0=pan,{N}", f"framebench:0=zoom,{N}", f"framebench:0=deepzoom,{N}",
             "tap:Pen", f"framebench:0=draw,{N}", f"framebench:0=finish,{N}", "tap:Eraser", f"framebench:0=erase,{N}"]
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
    if r.returncode != 0 or set(res) != set(PHASES):
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
    for what in PHASES:
        kv = res[what]
        built = per_layer(kv["built_by_layer"])
        appended = per_layer(kv["appended_by_layer"])
        bench[what] = {
            "frames": int(kv["n"]), "missed": int(kv["missed"]),
            "p50_ms": float(kv["p50"]), "p95_ms": float(kv["p95"]), "max_ms": float(kv["max"]),
            "event_p95_ms": float(kv["event_p95"]), "draw_p95_ms": float(kv["draw_p95"]), "paint_p95_ms": float(kv["paint_p95"]),
            "sync_p95_ms": float(kv["sync_p95"]), "raster_p95_ms": float(kv["raster_p95"]),
            "draw_max_ms": float(kv["draw_max"]), "raster_max_ms": float(kv["raster_max"]),
            "layers_built": int(kv["layers_built"]), "layers_reused": int(kv["reused"]),
            "built_by_layer": built, "appended_by_layer": appended, "trimmed_by_layer": per_layer(kv.get("trimmed_by_layer", "-")),
            "ink_layer_rebuilds": built.get("ink", 0), "ink_layer_appends": appended.get("ink", 0),
            "layer_textures": int(kv["textures"]),
        }
        if what == "finish":
            bench[what]["release_p95_ms"] = float(kv["release_p95"])
            bench[what]["release_max_ms"] = float(kv["release_max"])
            bench[what]["after_release_max_ms"] = float(kv["after_max"])
        if what == "erase":
            bench[what]["unchanged"] = int(kv["unchanged"])
    path = ROOT / "docs/goals/40/bench.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(bench, indent=2) + "\n")
    print(json.dumps(bench, indent=2))


if __name__ == "__main__":
    main()
