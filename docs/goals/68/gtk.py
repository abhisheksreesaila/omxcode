"""Run omxplorer headless on GTK with test steps (goal 68's checks): (exit code, output, screenshot path).

Steps are mojoui/hosts/gtk.mojo's, plus `grab:NAME`: a grab of the whole headless display (dialogs are windows of their
own, which the host's `shot:` doesn't see) saved as OUT/shots/NAME.png. It becomes `say:__grab_NAME;pause:1400`: the
host prints "TEST: nothing tagged __grab_NAME" (the marker), and this driver grabs the display 700 ms into the pause.
"""
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
APP = ROOT / "build/omxplorer/linux/omxplorer"


def _grab(path, size):
    from PIL import Image
    from Xlib import X, display

    d = display.Display(os.environ["DISPLAY"])
    w, h = size
    raw = d.screen().root.get_image(0, 0, w, h, X.ZPixmap, 0xFFFFFFFF)
    Image.frombytes("RGB", (w, h), raw.data, "raw", "BGRX").save(path)
    d.close()


def gtk(steps, name, out_dir, size=(1440, 900), env=None, timeout=1800, pixi_env=None):
    import headless

    headless.ensure()
    out_dir = Path(out_dir)
    home = out_dir / name
    shots = out_dir / "shots"
    shots.mkdir(parents=True, exist_ok=True)
    for d in ("docs", "config"):
        (home / d).mkdir(parents=True, exist_ok=True)
    (home / "config/settings.txt").write_text("appearance=light\n")
    expanded = []
    for s in (steps if isinstance(steps, list) else steps.split(";")):
        if s.startswith("grab:"):
            expanded += [f"say:__grab_{s[5:]}", "pause:1400"]
        else:
            expanded.append(s)
    shot = out_dir / f"{name}.png"
    e = {"OMX_DOCUMENTS": str(home / "docs"), "OMX_CONFIG": str(home / "config"), "MOJOUI_TEST": ";".join(expanded),
         "MOJOUI_WINDOW": f"{size[0]}x{size[1]}", "MOJOUI_SHOT": str(shot), "MOJOUI_TRACE": "1", "MOJOUI_BUDGET_MS": "50"}
    e.update(env or {})
    cmd = ["pixi", "run", "-e", pixi_env, str(APP)] if pixi_env else [str(APP)]  # (models: torch in the app's process)
    p = subprocess.Popen(cmd, cwd=ROOT, env=dict(os.environ, **e), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = []

    def read():
        for line in p.stdout:
            lines.append(line)
            if line.startswith("TEST: nothing tagged __grab_"):
                grab = line.strip().split("__grab_", 1)[1]
                time.sleep(0.7)
                try:
                    _grab(shots / f"{grab}.png", size)
                except Exception as x:  # noqa: BLE001 (a failed grab is said in the output)
                    lines.append(f"GRAB: {grab} failed: {x}\n")

    t = threading.Thread(target=read, daemon=True)
    t.start()
    try:
        p.wait(timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        lines.append("TEST: timed out\n")
    t.join(10)
    out = "".join(l for l in lines if not l.startswith("TEST: nothing tagged __grab_"))
    (out_dir / f"{name}.log").write_text(out)
    return p.returncode, out, shot
