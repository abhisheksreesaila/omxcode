"""Goal 71 M2: mojoui.clipgrid on GTK (headless) and the web host, through examples/clips: tap a poster, pick two tiles,
unpick one; both hosts must end with the same state line ("Like: c3 · Picked: c5") and show every tile.

    pixi run python docs/goals/71/clipgrid_web.py <web-shot.png>
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
import headless  # noqa: E402

STEPS = "tap:clip-2;tap:clip-pick-1;tap:clip-pick-4;tap:clip-pick-1"
WANT = "Like: c3 · Picked: c5"


def label(out):
    m = re.findall(r"^LABEL: (Like: .*)$", out, re.M)
    return m[-1] if m else None


def main(shot):
    for p in ("linux", "web"):
        r = subprocess.run(["scripts/build.sh", "clips", p], cwd=ROOT, capture_output=True, text=True)
        if r.returncode:
            sys.exit(f"build {p}: {(r.stdout + r.stderr)[-400:]}")
    headless.ensure()
    g = subprocess.run([str(ROOT / "build/clips/linux/clips")], cwd=ROOT, env=dict(os.environ, MOJOUI_TEST=STEPS), capture_output=True, text=True, timeout=120)
    gout = g.stdout + g.stderr
    if g.returncode or "TEST: " in gout:
        sys.exit(f"GTK: exit {g.returncode}: {gout[-500:]}")
    import drive

    r, wout = drive.web_run(ROOT / "build/clips/web", STEPS, shot=shot, viewport=(1000, 760))
    if r.returncode:
        sys.exit(f"web: {wout[-500:]}")
    gl, wl = label(gout), label(wout)
    if gl != WANT or wl != WANT:
        sys.exit(f"state: GTK {gl!r}, web {wl!r}, want {WANT!r}")
    imgs_g = len(re.findall(r"^IMAGE: ", gout, re.M))
    if imgs_g < 6:
        sys.exit(f"GTK shows {imgs_g} images, want 6")
    print(f"clipgrid: GTK and web both '{WANT}'; GTK {imgs_g} posters; web shot {shot}")


if __name__ == "__main__":
    main(sys.argv[1])
