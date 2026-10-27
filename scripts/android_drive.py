"""Drive a mojoui Android app on the emulator with the same steps as the GTK test mode.

  pixi run python scripts/android_drive.py hello "tap:Greet;tap:Greet"

Every step is real input from `adb shell input` (taps, typed keys, Return, swipes);
the state is read back from the real views with `uiautomator dump`, in screen order,
as LABEL/BUTTON/FIELD/TOGGLE/DROPDOWN/SLIDER/PROGRESS/IMAGE/SEGMENTED/TABS/RADIO lines,
plus BOX lines (in dp) for tagged views. Starts the emulator (AVD "mojoui") if needed.
"""

import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent.parent
SDK = Path(os.environ.get("ANDROID_HOME", Path.home() / "Android/Sdk"))
ADB = str(SDK / "platform-tools/adb")
AVD_HOME = Path.home() / ".config/.android/avd"  # where avdmanager put it (XDG)


def adb(*args, check=False, timeout=60):
    r = subprocess.run([ADB, *args], capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f"adb {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout


def booted():
    return adb("shell", "getprop", "sys.boot_completed").strip() == "1"


def ensure_emulator():
    """Boots the "mojoui" emulator headless if no device is up."""
    if "\tdevice" in adb("devices"):
        if booted():
            return
    else:
        env = dict(os.environ, ANDROID_AVD_HOME=str(AVD_HOME))
        subprocess.Popen([str(SDK / "emulator/emulator"), "-avd", "mojoui", "-no-window", "-no-audio", "-no-boot-anim",
                          "-no-snapshot-save", "-gpu", "swiftshader_indirect"],
                         env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        adb("wait-for-device", timeout=300)
    for _ in range(150):
        if booted():
            return
        time.sleep(2)
    raise RuntimeError("emulator didn't boot")


def density():
    m = re.search(r"(\d+)", adb("shell", "wm", "density").split("Override density:")[-1])
    return int(m.group(1)) / 160 if m else 2.625


def dump():
    """The window's views (uiautomator), as dicts in screen order; only the app's content."""
    for _ in range(5):
        adb("shell", "uiautomator", "dump", "/sdcard/ui.xml")
        xml = adb("exec-out", "cat", "/sdcard/ui.xml")
        if xml.startswith("<?xml"):
            break
        time.sleep(0.5)
    root = ET.fromstring(xml)
    return root


def nodes(root, inside_content=True):
    """Flattened view nodes; inside_content: only those under android:id/content."""
    out = []

    def walk(el, depth, in_content, parents):
        if el.tag == "node":
            in_content = in_content or el.get("resource-id") == "android:id/content"
            if in_content or not inside_content:
                b = [int(v) for v in re.findall(r"\d+", el.get("bounds", "[0,0][0,0]"))]
                out.append(dict(cls=el.get("class", ""), text=el.get("text", ""), desc=el.get("content-desc", ""),
                                hint=el.get("hint", ""), checked=el.get("checked") == "true", bounds=b, el=el,
                                parents=parents, package=el.get("package", "")))
            parents = parents + [el.get("class", "")]
        for c in el:
            walk(c, depth + 1, in_content, parents)

    walk(root, 0, False, [])
    return [n for n in out if n["el"].get("resource-id") != "android:id/content"]


def centre(n):
    x1, y1, x2, y2 = n["bounds"]
    return (x1 + x2) // 2, (y1 + y2) // 2


def tap(n):
    x, y = centre(n)
    adb("shell", "input", "tap", str(x), str(y))


def landed(before, wait=2.0):
    """After a tap, wait (up to `wait` s) for the screen's texts to change, as a person waits to see a tap land
    before the next one. Why: in two of goal 29's full runs, 3 taps on hello's Greet read "click 2"; the same APK
    gave "click 3" in every run on its own (5 of 5) and in the other chain positions of the same runs, and only the
    full runs load the machine (GTK, web, GPU checks around it), so the lost tap is put down to the emulator, not
    the app. It never retries a tap: a tap the app drops still fails the check. A tap that changes no text costs
    `wait` and says so on stderr."""
    deadline = time.time() + wait
    while time.time() < deadline:
        if [n["text"] for n in nodes(dump())] != before:
            return
        time.sleep(0.2)
    print(f"android_drive: no text changed {wait:.0f} s after a tap", file=sys.stderr)


def field_text(n):
    """An EditText's text ("" when it only shows its hint)."""
    return "" if n["hint"] and n["text"] == n["hint"] else n["text"]


def find(kind, pred=lambda n: True, nth=0, ns=None):
    """The nth view of a kind; waits up to 10 s for it (a loaded emulator draws late), as a person would."""
    deadline = time.time() + 10
    while True:
        here = ns if ns is not None else nodes(dump())
        found = [n for n in here if n["cls"].endswith("." + kind) and pred(n)]
        if len(found) > nth:
            return found[nth]
        if ns is not None or time.time() > deadline:
            raise ValueError(f"no {kind} #{nth}")
        time.sleep(0.5)


def settle():
    time.sleep(0.5)


def step(s, scale):
    verb, _, rest = s.partition(":")
    if verb == "tap":
        title, _, nth = rest.partition("@")
        button = find("Button", lambda n: n["text"] == title, int(nth or 0))  # (waits for a late screen)
        before = [n["text"] for n in nodes(dump())]
        tap(button)
        landed(before)
    elif verb in ("type", "submit", "enter"):
        hint, _, text = rest.partition("=")
        f = find("EditText", lambda n: n["hint"] == hint or (n["text"] == hint and not n["hint"]))
        tap(f)  # focus it (a real touch)
        if verb in ("type", "enter"):
            current = field_text(f)
            adb("shell", "input", "keyevent", "KEYCODE_MOVE_END", *(["KEYCODE_DEL"] * len(current)))
            if text:
                adb("shell", "input", "text", "'" + text.replace(" ", "%s").replace("'", "") + "'")
        if verb in ("submit", "enter"):
            adb("shell", "input", "keyevent", "KEYCODE_ENTER")
    elif verb == "toggle":
        tap(find("Switch", lambda n: n["text"] == rest))
    elif verb == "select":
        k, _, option = rest.partition("=")
        tap(find("Spinner", nth=int(k)))
        time.sleep(0.6)
        popup = [n for n in nodes(dump(), inside_content=False) if n["text"] == option and "Spinner" not in "".join(n["parents"])]
        if not popup:
            raise ValueError(f"no option {option}")
        tap(popup[-1])
    elif verb in ("segment", "tab", "radio"):
        k, _, option = rest.partition("=")
        kind = {"segment": "segmented", "tab": "tabs", "radio": "radio"}[verb]
        ns = nodes(dump())
        group = find("RadioGroup", lambda n: n["desc"] == kind, int(k), ns)
        tap(next(n for n in ns if n["cls"].endswith("RadioButton") and n["text"] == option and inside(n, group)))
    elif verb == "slide":  # real taps on the bar: calibrate with two, then tap where the value is
        k, _, value = rest.partition("=")
        want = int(value)
        bar = find("SeekBar", nth=int(k))
        x1, y1, x2, y2 = bar["bounds"]
        y = str((y1 + y2) // 2)

        def tap_at(x):
            adb("shell", "input", "tap", str(int(round(x))), y)
            time.sleep(0.3)
            return int(find("SeekBar", nth=int(k))["desc"] or 0)

        xa, xb = x1 + (x2 - x1) * 0.2, x1 + (x2 - x1) * 0.8
        va, vb = tap_at(xa), tap_at(xb)
        per = (xb - xa) / max(vb - va, 1)  # pixels per step
        target = xa + (want - va) * per
        if abs(target - xb) < 60:  # a tap on the thumb itself doesn't move it: step away first
            tap_at(xa)
        got = tap_at(target)
        for _ in range(4):
            if got == want:
                break
            target += (want - got) * per
            tap_at(xa if abs(target - xa) > 60 else xb)
            got = tap_at(target)
    elif verb == "drag":
        k, _, arg = rest.partition("=")
        dx, dy = (int(v) for v in arg.split(","))
        canvas = find("ImageView", lambda n: not re.fullmatch(r"\d+x\d+", n["desc"]), int(k))
        x, y = centre(canvas)
        adb("shell", "input", "swipe", str(x), str(y), str(round(x + dx * scale)), str(round(y + dy * scale)), "400")
    else:
        raise ValueError(f"unknown step {s}")
    settle()


def inside(n, group):
    a, b = n["bounds"], group["bounds"]
    return a[0] >= b[0] and a[1] >= b[1] and a[2] <= b[2] and a[3] <= b[3]


def report(scale):
    """State lines in screen order, read from the real views."""
    ns = nodes(dump())
    lines = []
    for n in ns:
        cls, parents = n["cls"].rsplit(".", 1)[-1], "".join(n["parents"])
        if "Spinner" in parents or "RadioGroup" in parents or "ListView" in parents:
            continue  # reported by their container
        if cls == "TextView":
            lines.append("LABEL: " + n["text"])
        elif cls == "Button":
            lines.append("BUTTON: " + n["text"])
        elif cls == "EditText":
            lines.append("FIELD: " + field_text(n))
        elif cls == "Switch":
            lines.append(f"TOGGLE: {n['text']}={'on' if n['checked'] else 'off'}")
        elif cls == "Spinner":
            shown = [c for c in ns if "Spinner" in "".join(c["parents"]) and inside(c, n) and c["text"]]
            lines.append("DROPDOWN: " + (shown[0]["text"] if shown else ""))
        elif cls == "SeekBar":
            lines.append("SLIDER: " + n["desc"])
        elif cls == "ProgressBar":
            lines.append("PROGRESS: " + n["desc"])
        elif cls == "ImageView" and re.fullmatch(r"\d+x\d+", n["desc"]):
            lines.append("IMAGE: " + n["desc"])
        elif cls == "RadioGroup" and n["desc"] in ("segmented", "tabs", "radio"):
            picked = [c for c in ns if c["cls"].endswith("RadioButton") and c["checked"] and inside(c, n)]
            lines.append(f"{n['desc'].upper()}: " + (picked[0]["text"] if picked else ""))
        if n["desc"] and not re.fullmatch(r"\d+(x\d+)?|segmented|tabs|radio", n["desc"]):
            x1, y1, x2, y2 = n["bounds"]
            lines.append(f"BOX: {n['desc']} {x1 / scale:.1f} {y1 / scale:.1f} {(x2 - x1) / scale:.1f} {(y2 - y1) / scale:.1f}")
    return lines


def android_run(example, steps, shot=None, landscape=False, dpi=None):
    """Returns (result, output) like a process run: result.returncode is 0 on success."""
    ensure_emulator()
    apk = next((ROOT / "build" / example / "android").glob("*.apk"), None)
    if apk is None:
        return SimpleNamespace(returncode=1), f"no APK for {example}"
    pkg = f"dev.mojoui.{example}"
    try:
        adb("install", "-r", str(apk), check=True, timeout=120)
    except RuntimeError as e:  # (another worktree's build signed it with its own debug key: the test app goes, then installs)
        if "INSTALL_FAILED_UPDATE_INCOMPATIBLE" not in str(e):
            raise
        adb("uninstall", pkg, timeout=120)
        adb("install", str(apk), check=True, timeout=120)
    adb("shell", "settings", "put", "system", "accelerometer_rotation", "0")
    adb("shell", "settings", "put", "system", "user_rotation", "1" if landscape else "0")
    adb("shell", "wm", "density", str(dpi) if dpi else "reset")  # dpi: a "bigger" screen in dp (more fits)
    adb("shell", "am", "force-stop", pkg)
    # a loaded machine can leave a "System UI isn't responding" dialog over everything: close it, or every
    # later tap lands on the dialog (seen twice: docs/lessons.md)
    adb("shell", "am", "broadcast", "-a", "android.intent.action.CLOSE_SYSTEM_DIALOGS")
    adb("logcat", "-c")
    adb("shell", "am", "start", "-W", "-n", f"{pkg}/dev.mojoui.MojoActivity", check=True, timeout=120)
    # Until the app's own views are up: a fresh (cold-booted) emulator takes several seconds for
    # the first launch (dex optimisation, the Mojo library), well past the old fixed 1.5 s.
    deadline = time.time() + 60
    while time.time() < deadline:  # (the app's own views: the launcher behind it has TextViews too)
        if any(n["package"] == pkg and n["cls"].endswith((".TextView", ".Button", ".EditText")) and n["bounds"][2] > 0 for n in nodes(dump())):
            break
        time.sleep(1)
    # and until its window has the input focus: after the density and rotation settings and the system-dialog close,
    # a tap sent while the window manager still hands focus over is dropped (goal 33 M8: "click 2" after 3 taps in
    # two full runs, "no text changed 2 s after a tap"; 3 of 3 on their own). Still no retried taps.
    deadline = time.time() + 15
    while time.time() < deadline:
        if f"mCurrentFocus=Window{{" in (w := adb("shell", "dumpsys", "window")) and re.search(r"mCurrentFocus=Window\{[^}]*" + re.escape(pkg) + "/", w):
            break
        time.sleep(0.5)
    time.sleep(1.5)
    scale = density()
    out, failed = "", False
    try:
        for s in [s for s in steps.split(";") if s]:
            step(s, scale)
        time.sleep(0.5)
        out += "NATIVE: Android " + adb("shell", "getprop", "ro.build.version.release").strip() + "\n"
        out += "\n".join(report(scale)) + "\n"
        if shot:
            Path(shot).write_bytes(subprocess.run([ADB, "exec-out", "screencap", "-p"], capture_output=True).stdout)
            out += f"SHOT: {shot}\n"
    except Exception as e:  # a failing step is a failing run
        out += f"STEP FAILED: {e!r}\n"
        failed = True
    log = adb("logcat", "-d", "-s", "AndroidRuntime:E", "mojoui:*", "art:E", "DEBUG:*")
    crashes = [l for l in log.splitlines() if re.search(r"FATAL|JNI DETECTED ERROR|no method|Exception|signal \d+", l)]
    if crashes:
        out += "CRASH: " + " | ".join(crashes[:6]) + "\n"
        failed = True
    adb("shell", "settings", "put", "system", "user_rotation", "0")
    adb("shell", "wm", "density", "reset")
    return SimpleNamespace(returncode=1 if failed else 0), out


if __name__ == "__main__":
    shot = sys.argv[3] if len(sys.argv) > 3 else None
    r, out = android_run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "", shot=shot,
                         landscape=os.environ.get("LANDSCAPE") == "1",
                         dpi=int(os.environ["DPI"]) if os.environ.get("DPI") else None)
    print(out, end="")
    sys.exit(r.returncode)
