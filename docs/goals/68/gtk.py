"""Run omxplorer headless on GTK with test steps (goal 68's checks): (exit code, output, screenshot path)."""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
APP = ROOT / "build/omxplorer/linux/omxplorer"


def gtk(steps, name, out_dir, size=(1440, 900), env=None, timeout=1800):
    import headless

    headless.ensure()
    home = Path(out_dir) / name
    for d in ("docs", "config"):
        (home / d).mkdir(parents=True, exist_ok=True)
    (home / "config/settings.txt").write_text("appearance=light\n")
    shot = Path(out_dir) / f"{name}.png"
    e = {"OMX_DOCUMENTS": str(home / "docs"), "OMX_CONFIG": str(home / "config"), "MOJOUI_TEST": ";".join(steps) if isinstance(steps, list) else steps,
         "MOJOUI_WINDOW": f"{size[0]}x{size[1]}", "MOJOUI_SHOT": str(shot), "MOJOUI_TRACE": "1", "MOJOUI_BUDGET_MS": "50"}
    e.update(env or {})
    r = subprocess.run([str(APP)], cwd=ROOT, env=dict(os.environ, **e), capture_output=True, text=True, timeout=timeout)
    out = r.stdout + r.stderr
    (Path(out_dir) / f"{name}.log").write_text(out)
    return r.returncode, out, shot
