"""A headless X display for the GTK checks, so test windows never appear on the desktop.

Starts Xvfb (from the pixi environment) once per process on a free display and points GDK at it
(X11 backend, the cairo renderer: Xvfb has no GPU-backed GL). Screenshots (MOJOUI_SHOT) and the
frame clock work as on a real screen. Set MOJOUI_HEADLESS=0 to watch the windows instead.
"""
import atexit
import os
import socket
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_server = None


def _free_display():
    n = 90
    while Path(f"/tmp/.X11-unix/X{n}").exists() or Path(f"/tmp/.X{n}-lock").exists():
        n += 1
    return n


def _xkb_dir():
    for d in (Path("/usr/share/X11/xkb"), ROOT / ".pixi/envs/default/share/xkeyboard-config-2"):
        if (d / "rules").exists():
            return str(d)
    return None


def ensure():
    """Starts the display (once) and sets the environment for every GTK run after it. Returns True when headless."""
    global _server
    if os.environ.get("MOJOUI_HEADLESS", "1") == "0":
        return False
    if _server is not None:
        return True
    xvfb = ROOT / ".pixi/envs/default/bin/Xvfb"
    if not xvfb.exists():
        print("headless: no Xvfb in the pixi environment (pixi install); windows will show")
        return False
    n = _free_display()
    screen = os.environ.get("MOJOUI_HEADLESS_SCREEN", "2560x1600")  # (a bigger one for 2× recordings: scripts/robotclip.py)
    cmd = [str(xvfb), f":{n}", "-screen", "0", f"{screen}x24", "-nolisten", "tcp"]
    xkb = _xkb_dir()
    if xkb:
        cmd += ["-xkbdir", xkb]
    _server = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    atexit.register(stop)
    for _ in range(100):
        if Path(f"/tmp/.X11-unix/X{n}").exists():
            break
        if _server.poll() is not None:
            print("headless: Xvfb exited; windows will show")
            _server = None
            return False
        time.sleep(0.05)
    # Scale 1: the desktop's GDK_SCALE=2 would make every frame four times the pixels (the lens
    # drops to 27 fps through cairo at 1880×1600); a 1× monitor is a real target too.
    os.environ.update({"DISPLAY": f":{n}", "GDK_BACKEND": "x11", "GSK_RENDERER": "cairo", "GDK_DISABLE": "gl,vulkan", "GDK_SCALE": "1",
                       "MOJOUI_PRIVATE_DISPLAY": "1"})  # (nobody types here: test windows may take the keyboard)
    os.environ.pop("WAYLAND_DISPLAY", None)
    os.environ.pop("GDK_DPI_SCALE", None)
    return True


def stop():
    global _server
    if _server is not None and _server.poll() is None:
        _server.terminate()
        try:
            _server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            _server.kill()
    _server = None
