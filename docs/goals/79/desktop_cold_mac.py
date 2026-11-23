"""Personal Note's own Mac launcher, cold, for goal 79's race under ruling D (D-7992): runs desktop.py unchanged in
this process (its pywebview window, the WKWebView engine PN uses on the Mac), with only outside marks added. Prints
  PROCSTART_EPOCH_MS: <ms>   this process's start (proc_pidinfo), as the native app's FIRSTSCREEN measures its own
  SERVED_EPOCH_MS: <ms>      its own server sending the first HTML page (a marking ASGI layer around PN's app): the lower
                             bound of its first paint (nothing can be painted before the page arrives)
  WINDOW_EPOCH_MS: <ms>      its window first on screen (CGWindowListCopyWindowInfo, this process's windows: window info
                             only, no screen capture; its content can't be read without the screen-recording permission,
                             which the rules leave alone)
Only ever run with HOME, PERSONAL_NOTE_DB and the plugin/AI/voice folders pointed at scratch (webcold.mjs does): on the
Mac, PN keeps its data under ~/Library/Application Support, found through HOME.
  <PN>/.venv/bin/python docs/goals/79/desktop_cold_mac.py <PN root>
"""
import ctypes
import os
import sys
import threading
import time


def proc_start_ms() -> float:
    lib = ctypes.CDLL("/usr/lib/libproc.dylib")
    buf = ctypes.create_string_buffer(136)
    n = lib.proc_pidinfo(os.getpid(), 3, ctypes.c_uint64(0), buf, 136)  # PROC_PIDTBSDINFO
    if n < 136:
        return time.time() * 1000.0
    sec = int.from_bytes(buf.raw[120:128], "little")
    usec = int.from_bytes(buf.raw[128:136], "little")
    return sec * 1000.0 + usec / 1000.0


print(f"PROCSTART_EPOCH_MS: {proc_start_ms():.1f}", flush=True)
assert os.environ.get("PERSONAL_NOTE_DB") and os.environ.get("HOME", "").find("pn-cold") >= 0, "scratch HOME and database only"
root = sys.argv[1]
sys.path.insert(0, root)
os.chdir(root)


class Mark:
    """An ASGI layer: the first GET answered with an HTML page prints SERVED_EPOCH_MS once."""

    def __init__(self, app):
        self.app = app
        self.done = False

    def __getattr__(self, name):  # (PN's code reaches app.state, app.route … through it)
        return getattr(self.app, name)

    async def __call__(self, scope, receive, send):
        if self.done or scope.get("type") != "http" or scope.get("method") != "GET":
            return await self.app(scope, receive, send)
        html = [False]

        async def marked(msg):
            if msg["type"] == "http.response.start":
                html[0] = any(k.lower() == b"content-type" and b"text/html" in v for k, v in msg.get("headers", []))
            await send(msg)
            if msg["type"] == "http.response.body" and not msg.get("more_body") and html[0] and not self.done:
                self.done = True
                print(f"SERVED_EPOCH_MS: {time.time() * 1000.0:.1f} {scope.get('path')}", flush=True)

        return await self.app(scope, receive, marked)


def watch_window():
    try:
        import Quartz
    except Exception as e:
        print(f"WINDOW: no Quartz ({e})", flush=True)
        return
    pid = os.getpid()
    end = time.time() + 30
    while time.time() < end:
        info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID) or []
        for w in info:
            b = w.get("kCGWindowBounds", {})
            if w.get("kCGWindowOwnerPID") == pid and w.get("kCGWindowLayer", 1) == 0 and b.get("Width", 0) > 100 and b.get("Height", 0) > 100:
                print(f"WINDOW_EPOCH_MS: {time.time() * 1000.0:.1f}", flush=True)
                return
        time.sleep(0.004)


import desktop  # noqa: E402

_start = desktop.LocalServer.start


def start(self, timeout: float = 15.0):
    self.app = Mark(self.app)
    return _start(self, timeout)


desktop.LocalServer.start = start
threading.Thread(target=watch_window, daemon=True).start()
sys.exit(desktop.main(["--no-build", "--engine", "webview"]))
