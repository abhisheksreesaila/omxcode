"""Goal 36b M6 (c): on the live desktop (D-735, a measurement window), the particle app's GPU Canvas reaches the screen
with no GPU→CPU readback. Runs examples/particles scripted at N = 1M for 660 frames in GTK on Wayland (GTK's GL
renderer, the field at 1280×720 pixels), with the host's present counters (MOJOUI_PRESENT_STATS=1), and writes
docs/goals/36/present-desktop.json. Refuses to run without a Wayland desktop (never headless: that's the fallback).

    pixi run python scripts/present_smoke.py
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import particles_bench as pb  # noqa: E402

OUT = ROOT / "docs/goals/36/present-desktop.json"
APP = ROOT / "build/particles/linux/particles"


def desktop_env(extra=None):
    """The owner's Wayland session (D-735): GTK on Wayland, not the headless X display; X11 variables dropped."""
    wl = os.environ.get("WAYLAND_DISPLAY")
    if not wl or not (Path(os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())) / wl).exists():
        sys.exit("present_smoke: no Wayland desktop (WAYLAND_DISPLAY) — this proof runs on the real desktop only")
    env = {k: v for k, v in os.environ.items() if k not in ("DISPLAY", "GSK_RENDERER", "GDK_DISABLE", "GDK_SCALE")}
    env.update({"MOJOUI_HEADLESS": "0", "GDK_BACKEND": "wayland", "MOJOUI_CANVAS_SCALE": "1"})
    env.update(extra or {})
    return env


def run(n=1_000_000, frames=660, extra=None):
    with tempfile.TemporaryDirectory() as d:
        env = desktop_env({"MOJOUI_PRESENT_STATS": "1", "GDK_DEBUG": "no-vsync", **(extra or {})})
        r = subprocess.run([str(APP), "--scripted", "--n", str(n), "--frames", str(frames), "--out", d, "--positions", "0"],
                           cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
        out = r.stdout + r.stderr
        if r.returncode != 0 or not (Path(d) / "timings.json").exists():
            sys.exit(f"present_smoke: the app failed (exit {r.returncode}):\n{out[-2000:]}")
        t = json.loads((Path(d) / "timings.json").read_text())
    stats = re.search(r"present stats: gpu_blended (\d+), gpu_copied (\d+), cpu_copied (\d+), hand-over ms ([\d.e-]+), "
                      r"gpu copy ms ([\d.e-]+), blend ms ([\d.e-]+),.*renderer (\S*)", out)
    path = next((l for l in out.splitlines() if l.startswith("mojoui: GPU canvas pictures")), "")
    choice = [l for l in out.splitlines() if l.startswith("mojoui: additive points")]
    if not stats:
        sys.exit("present_smoke: no present stats in the app's output:\n" + out[-2000:])
    b, c, cpu = (int(stats.group(i)) for i in (1, 2, 3))
    return {
        "n": n, "frames": frames, "device": t["device"], "path": path, "additive_points_choice": choice,
        "gpu_blended": b, "gpu_copied": c, "cpu_copied": cpu, "gpu_presented": b + c,
        "hand_over_ms_mean": float(stats.group(4)), "gpu_copy_ms_mean": float(stats.group(5)),
        "blend_issue_ms_mean": float(stats.group(6)), "gsk_renderer": stats.group(7),
        "frame_ms_mean": sum(t["total"][60:]) / len(t["total"][60:]),
    }


def main():
    if not APP.exists():
        sys.exit("present_smoke: build the app first (scripts/build.sh particles linux)")
    res = run()
    res.update({"when": time.strftime("%Y-%m-%d %H:%M"), "sources_sha256": pb.sources_sha(), "display": "Wayland "
                + os.environ.get("WAYLAND_DISPLAY", "?"), "canvas_pixels": "1280x720 (MOJOUI_CANVAS_SCALE=1)"})
    OUT.write_text(json.dumps(res, indent=1) + "\n")
    print(json.dumps(res, indent=1))
    ok = res["cpu_copied"] == 0 and res["gpu_presented"] >= res["frames"] - 1 and "without a copy" in res["path"]
    print("present desktop: " + ("ok" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
