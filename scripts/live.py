"""Drive a GTK app with real input (XTest) on the private headless display, like a person would.

The MOJOUI_TEST steps call the host's handlers directly; this sends real pointer and key events through X,
so GTK's own gestures, focus and timing run as they do on the desktop.

  pixi run python scripts/live.py <exe> "<commands>" [--size 1742x876] [--env K=V ...]
Commands, separated by ';':
  wait:MS            let the app run for MS milliseconds
  move:X,Y           move the pointer (window coordinates)
  click:X,Y          press and release button 1 there (shift+click:X,Y holds Shift)
  drag:X1,Y1,X2,Y2   press at 1, move in 12 steps over ~200 ms to 2, release
  key:NAME           press and release a key (X keysym names; Shift+Down, Control+c)
  shot:PATH          save the screen (the window's area) as a PNG
  press:X,Y          move there and hold button 1 down (until release)
  glideto:X,Y        move the pointer there in 12 steps over ~200 ms (the button stays as it is)
  release            let button 1 go
  wheel:X,Y,N        N notches of the scroll wheel down there (negative: up)
  report             the app prints its widgets' state (as a MOJOUI_TEST run's end does: LABEL:, BOX:, …)
  type:TEXT          type TEXT key by key, ~25 a second (letters, capitals too, digits, space and , . - $)
  record:PATH        start recording the window's area to PATH (ffmpeg, 30 fps, H.264) until stoprecord or the end
  stoprecord         stop the recording
The app's stdout (TRACE: lines with MOJOUI_TRACE=1) is printed at the end.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import headless  # noqa: E402
from Xlib import X, XK, display  # noqa: E402
from Xlib.ext import xtest  # noqa: E402
from PIL import Image  # noqa: E402


def app_pid(pid):
    """The app itself: through a launcher that runs it under bubblewrap (scripts/build.sh, WebKitGTK laid over /usr/lib:
    D-608) its child, since bwrap doesn't pass signals on (SIGUSR1 would end bwrap, and the app with it)."""
    for _ in range(4):
        try:
            if Path(f"/proc/{pid}/comm").read_text().strip() != "bwrap":
                return pid
            kids = Path(f"/proc/{pid}/task/{pid}/children").read_text().split()
        except OSError:
            return pid
        if not kids:
            return pid
        pid = int(kids[0])
    return pid


def main():
    args = sys.argv[1:]
    exe, commands = args[0], args[1]
    size, extra = "1742x876", {}
    i = 2
    while i < len(args):
        if args[i] == "--size":
            size = args[i + 1]
            i += 2
        elif args[i] == "--env":
            k, v = args[i + 1].split("=", 1)
            extra[k] = v
            i += 2
        else:
            i += 1
    headless.ensure()
    env = dict(os.environ, MOJOUI_WINDOW=size, MOJOUI_LIVE_REPORT="1", **extra)
    env.pop("MOJOUI_TEST", None)
    log = open(Path("build") / "live.log", "w")
    app = subprocess.Popen([exe], env=env, stdout=log, stderr=subprocess.STDOUT)
    d = display.Display(os.environ["DISPLAY"])
    w, h = (int(n) for n in size.split("x"))
    time.sleep(2.5)  # the window maps and lays out

    def move(x, y):
        xtest.fake_input(d, X.MotionNotify, x=int(x), y=int(y))
        d.sync()

    def button(down):
        xtest.fake_input(d, X.ButtonPress if down else X.ButtonRelease, 1)
        d.sync()

    def keycode(name):
        return d.keysym_to_keycode(XK.string_to_keysym(name))

    def key(combo):
        parts = combo.split("+")
        mods = [keycode({"Shift": "Shift_L", "Control": "Control_L", "Alt": "Alt_L"}[m]) for m in parts[:-1]]
        for m in mods:
            xtest.fake_input(d, X.KeyPress, m)
        k = keycode(parts[-1])
        xtest.fake_input(d, X.KeyPress, k)
        xtest.fake_input(d, X.KeyRelease, k)
        for m in reversed(mods):
            xtest.fake_input(d, X.KeyRelease, m)
        d.sync()

    pointer = [0.0, 0.0]
    recorder = [None]
    names = {" ": "space", ",": "comma", ".": "period", "-": "minus", "$": "Shift+dollar"}

    def stop_recording():
        if recorder[0] is not None:
            recorder[0].communicate(b"q", timeout=30)  # (ffmpeg finishes the file on "q")
            recorder[0] = None
    for cmd in commands.split(";"):
        if not cmd:
            continue
        verb, _, rest = cmd.partition(":")
        nums = [float(n) for n in rest.split(",")] if verb in ("move", "click", "shift+click", "drag", "wheel", "press", "glideto") else []
        if verb == "wait":
            time.sleep(float(rest) / 1000)
        elif verb == "move":
            move(*nums)
        elif verb in ("click", "shift+click"):
            if verb == "shift+click":
                xtest.fake_input(d, X.KeyPress, keycode("Shift_L"))
            move(*nums)
            time.sleep(0.05)
            button(True)
            time.sleep(0.05)
            button(False)
            if verb == "shift+click":
                xtest.fake_input(d, X.KeyRelease, keycode("Shift_L"))
                d.sync()
            time.sleep(0.25)
        elif verb == "drag":
            x1, y1, x2, y2 = nums
            move(x1, y1)
            time.sleep(0.05)
            button(True)
            for s in range(1, 13):
                move(x1 + (x2 - x1) * s / 12, y1 + (y2 - y1) * s / 12)
                time.sleep(0.016)
            time.sleep(0.05)
            button(False)
            time.sleep(0.25)
        elif verb == "key":
            key(rest)
            time.sleep(0.2)
        elif verb == "press":
            move(*nums)
            time.sleep(0.05)
            button(True)
            pointer[0], pointer[1] = nums[0], nums[1]
            time.sleep(0.05)
        elif verb == "glideto":
            x0, y0 = pointer
            for s_ in range(1, 13):
                move(x0 + (nums[0] - x0) * s_ / 12, y0 + (nums[1] - y0) * s_ / 12)
                time.sleep(0.016)
            pointer[0], pointer[1] = nums[0], nums[1]
        elif verb == "release":
            button(False)
            time.sleep(0.2)
        elif verb == "wheel":
            move(nums[0], nums[1])
            time.sleep(0.05)
            b = 5 if nums[2] > 0 else 4
            for _ in range(abs(int(nums[2]))):
                xtest.fake_input(d, X.ButtonPress, b)
                xtest.fake_input(d, X.ButtonRelease, b)
                d.sync()
                time.sleep(0.03)
            time.sleep(0.2)
        elif verb == "report":
            import signal
            os.kill(app_pid(app.pid), signal.SIGUSR1)
            time.sleep(1.0)
        elif verb == "type":
            for ch in rest:
                key(names.get(ch, "Shift+" + ch if ch.isupper() else ch))
                time.sleep(0.04)
        elif verb == "record":
            stop_recording()
            recorder[0] = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "1", "-video_size", f"{w}x{h}",
                                            "-framerate", "30", "-i", os.environ["DISPLAY"] + "+0,0", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                                            "-crf", "20", "-preset", "veryfast", rest], stdin=subprocess.PIPE)
            time.sleep(0.5)
        elif verb == "stoprecord":
            stop_recording()
        elif verb == "shot":
            raw = d.screen().root.get_image(0, 0, w, h, X.ZPixmap, 0xFFFFFFFF)
            Image.frombytes("RGB", (w, h), raw.data, "raw", "BGRX").save(rest)
        else:
            print("live: unknown command " + cmd)
    stop_recording()
    app.terminate()
    try:
        app.wait(timeout=5)
    except subprocess.TimeoutExpired:
        app.kill()
    log.close()
    print(open(Path("build") / "live.log").read())


if __name__ == "__main__":
    main()
