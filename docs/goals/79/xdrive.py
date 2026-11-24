"""Real X input for a window on a headless Xvfb (goal 79, continuation 20): the pointer and keys go in through the XTEST
extension, as a person's would, and pictures are the X server's own (ImageMagick's import). CPU only: GTK's cairo renderer,
no GL, no GPU program, no CUDA device."""
import ctypes
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
import headless

X = ctypes.CDLL("libX11.so.6")
T = ctypes.CDLL("libXtst.so.6")
for f, r, a in [("XOpenDisplay", ctypes.c_void_p, [ctypes.c_char_p]), ("XStringToKeysym", ctypes.c_ulong, [ctypes.c_char_p]),
                ("XKeysymToKeycode", ctypes.c_ubyte, [ctypes.c_void_p, ctypes.c_ulong]), ("XFlush", ctypes.c_int, [ctypes.c_void_p]),
                ("XSync", ctypes.c_int, [ctypes.c_void_p, ctypes.c_int]), ("XDefaultRootWindow", ctypes.c_ulong, [ctypes.c_void_p]),
                ("XChangeKeyboardMapping", ctypes.c_int, [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_ulong), ctypes.c_int]),
                ("XSetInputFocus", ctypes.c_int, [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]),
                ("XQueryTree", ctypes.c_int, [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)), ctypes.POINTER(ctypes.c_uint)]),
                ("XGetGeometry", ctypes.c_int, [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]),
                ("XMoveResizeWindow", ctypes.c_int, [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint])]:
    getattr(X, f).restype = r
    getattr(X, f).argtypes = a
for f, a in [("XTestFakeMotionEvent", [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]),
             ("XTestFakeButtonEvent", [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]),
             ("XTestFakeKeyEvent", [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong])]:
    getattr(T, f).argtypes = a
    getattr(T, f).restype = ctypes.c_int

NAMES = {"Enter": "Return", "Esc": "Escape", "PageDown": "Next", "PageUp": "Prior", "Ctrl": "Control_L", "Shift": "Shift_L", "Alt": "Alt_L"}
SPECIAL = {" ": "space", "#": "numbersign", "*": "asterisk", "`": "grave", "~": "asciitilde", "[": "bracketleft", "]": "bracketright", "(": "parenleft", ")": "parenright",
           "-": "minus", "_": "underscore", ".": "period", ",": "comma", "/": "slash", ":": "colon", "!": "exclam", "'": "apostrophe", '"': "quotedbl", "=": "equal", "+": "plus", "?": "question", "\n": "Return"}
SHIFTED = set('~!@#$%^&*()_+{}|:"<>?ABCDEFGHIJKLMNOPQRSTUVWXYZ')


class App:
    """pnote on the headless display, its boxes file, and a person's hands."""

    def __init__(self, env, log, size=(1440, 900)):
        assert headless.ensure(), "no headless display"
        self.d = X.XOpenDisplay(os.environ["DISPLAY"].encode())
        assert self.d
        self.size = size
        self.boxes_path = Path(env["PNOTE_BOXES"])
        e = dict(os.environ, **env)
        for k in list(e):
            if k.startswith("MOJOUI_TEST") or k in ("MOJOUI_SHOT", "CUDA_VISIBLE_DEVICES"):
                e.pop(k)
        e.update(CUDA_VISIBLE_DEVICES="", MOJOUI_GPU2D="0", LIBGL_ALWAYS_SOFTWARE="1", __GLX_VENDOR_LIBRARY_NAME="mesa", TZ="UTC")
        self.p = subprocess.Popen(["nice", "-n", "15", "taskset", "-c", "0-3", str(ROOT / "build/pnote/linux/pnote")], env=e, stdout=open(log, "w"), stderr=subprocess.STDOUT)
        self.spare = 8
        self.mapped = {}
        for _ in range(200):
            time.sleep(0.05)
            self.win = self.find()
            if self.win:
                break
        assert self.win, "no window"
        time.sleep(0.6)
        X.XMoveResizeWindow(self.d, self.win, 0, 0, *size)
        X.XSetInputFocus(self.d, self.win, 1, 0)
        X.XSync(self.d, 0)
        time.sleep(1.2)
        self.off = (0, 0)

    def children(self, w):
        r, pa, ch, n = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.POINTER(ctypes.c_ulong)(), ctypes.c_uint()
        X.XQueryTree(self.d, w, ctypes.byref(r), ctypes.byref(pa), ctypes.byref(ch), ctypes.byref(n))
        return [ch[i] for i in range(n.value)]

    def geometry(self, w):
        r, x, y, a, b, c, d = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_int(), ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint()
        X.XGetGeometry(self.d, w, ctypes.byref(r), ctypes.byref(x), ctypes.byref(y), ctypes.byref(a), ctypes.byref(b), ctypes.byref(c), ctypes.byref(d))
        return x.value, y.value, a.value, b.value

    def find(self):
        best = None
        for w in self.children(X.XDefaultRootWindow(self.d)):
            g = self.geometry(w)
            if g[2] > 300 and g[3] > 300 and (best is None or g[2] > self.geometry(best)[2]):
                best = w
        return best

    # ---- the pointer (layout px of the desk)
    def move(self, x, y):
        T.XTestFakeMotionEvent(self.d, -1, int(x + self.off[0]), int(y + self.off[1]), 0)
        X.XSync(self.d, 0)
        time.sleep(0.03)

    def button(self, b, down):
        T.XTestFakeButtonEvent(self.d, b, 1 if down else 0, 0)
        X.XSync(self.d, 0)
        time.sleep(0.04)

    def click(self, x, y, n=1, wait=0.35):
        self.move(x, y)
        for _ in range(n):
            self.button(1, True)
            self.button(1, False)
        time.sleep(wait)

    def drag(self, x0, y0, x1, y1, steps=12, wait=0.4):
        self.move(x0, y0)
        self.button(1, True)
        for i in range(1, steps + 1):
            self.move(x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps)
        self.button(1, False)
        time.sleep(wait)

    def path(self, pts, wait=0.4):
        self.move(*pts[0])
        self.button(1, True)
        for q in pts[1:]:
            self.move(*q)
        self.button(1, False)
        time.sleep(wait)

    def wheel(self, x, y, n):
        self.move(x, y)
        for _ in range(abs(n)):
            self.button(5 if n > 0 else 4, True)
            self.button(5 if n > 0 else 4, False)
        time.sleep(0.4)

    # ---- the keyboard
    def code(self, sym):
        ks = X.XStringToKeysym(sym.encode())
        c = X.XKeysymToKeycode(self.d, ks) if ks else 0
        return ks, c

    def key(self, name, *mods, wait=0.06):
        sym = NAMES.get(name, SPECIAL.get(name, name))
        ks, c = self.code(sym)
        assert c, name
        for m in mods:
            T.XTestFakeKeyEvent(self.d, self.code(NAMES[m])[1], 1, 0)
        T.XTestFakeKeyEvent(self.d, c, 1, 0)
        T.XTestFakeKeyEvent(self.d, c, 0, 0)
        for m in reversed(mods):
            T.XTestFakeKeyEvent(self.d, self.code(NAMES[m])[1], 0, 0)
        X.XSync(self.d, 0)
        time.sleep(wait)

    def type(self, text, wait=0.3):
        for ch in text:
            if ord(ch) < 128:
                self.key(ch, *(["Shift"] if ch in SHIFTED else []), wait=0.012)
            else:  # (a key of a layout that has it: mapped on a spare key)
                if ch not in self.mapped:
                    kc = 248 - len(self.mapped)
                    ks = (ctypes.c_ulong * 2)(0x01000000 + ord(ch) if ord(ch) > 255 else ord(ch), 0)
                    X.XChangeKeyboardMapping(self.d, kc, 2, ks, 1)
                    X.XSync(self.d, 0)
                    time.sleep(0.4)
                    self.mapped[ch] = kc
                T.XTestFakeKeyEvent(self.d, self.mapped[ch], 1, 0)
                T.XTestFakeKeyEvent(self.d, self.mapped[ch], 0, 0)
                X.XSync(self.d, 0)
                time.sleep(0.05)
        time.sleep(wait)

    # ---- what is there
    def boxes(self):
        for _ in range(40):
            try:
                return json.loads(self.boxes_path.read_text())
            except (OSError, ValueError):
                time.sleep(0.05)
        return {}

    def at(self, name, prefix=False):
        b = self.boxes()
        for k in (b if prefix else [name]):
            if k in b and (not prefix or k.startswith(name)):
                x, y, w, h = b[k]
                return x + w / 2, y + h / 2
        raise KeyError(f"no box {name!r}; there are {sorted(b)[:80]}")

    def tap(self, name, prefix=False, n=1, wait=0.45):
        self.click(*self.at(name, prefix), n=n, wait=wait)

    def shot(self, path):
        time.sleep(0.35)
        subprocess.run(["import", "-display", os.environ["DISPLAY"], "-window", "root", "-crop", f"{self.size[0]}x{self.size[1]}+0+0", "+repage", str(path)], check=True)

    def close(self):
        """The window's own close button's way: SIGTERM is the desktop's; a person's is WM_DELETE_WINDOW."""
        subprocess.run(["python3", "-c", f"""
import ctypes
X=ctypes.CDLL('libX11.so.6'); X.XOpenDisplay.restype=ctypes.c_void_p; X.XInternAtom.restype=ctypes.c_ulong; X.XInternAtom.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_int]
d=X.XOpenDisplay({os.environ['DISPLAY'].encode()!r})
class E(ctypes.Structure): _fields_=[('type',ctypes.c_int),('serial',ctypes.c_ulong),('send',ctypes.c_int),('d',ctypes.c_void_p),('w',ctypes.c_ulong),('mt',ctypes.c_ulong),('f',ctypes.c_int),('l',ctypes.c_long*5),('pad',ctypes.c_char*128)]
e=E(); e.type=33; e.w={self.win}; e.mt=X.XInternAtom(d,b'WM_PROTOCOLS',0); e.f=32; e.l[0]=X.XInternAtom(d,b'WM_DELETE_WINDOW',0)
X.XSendEvent.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_int,ctypes.c_long,ctypes.c_void_p]
X.XSendEvent(d,{self.win},0,0,ctypes.byref(e)); X.XSync.argtypes=[ctypes.c_void_p,ctypes.c_int]; X.XSync(d,0)
"""])
        try:
            self.p.wait(timeout=10)
            return self.p.returncode
        except subprocess.TimeoutExpired:
            self.p.terminate()
            self.p.wait(timeout=10)
            return "didn't close; terminated"
