"""omxconsole's highlight clip: the console (examples/console, GTK) on its Mojo daemon (examples/consoled), four beats.

    pixi run python scripts/clips.py console            (record + compose; or: python scripts/consoleclip.py record|compose)
    pixi run python scripts/consoleclip.py stage        (the daemon and the console on the private display, left running for
                                                         exploring with `do`; `consoleclip.py stop` ends them)

record: a throwaway daemon (MXC_HOME build/clipconsole/home, its own MXC_PORT, MXC_ADMIN_KEY and MXC_EXPOSE_PORT; never
  the owner's :11435 or ~/.mxc; MAX from the import-model skill's env, Claude Code as the porting assistant) and the
  console on the private headless display (scripts/headless.py), 1280×720 points at 2× (2560×1440 pixels). Every tap and
  every key is real X input (XTest) at the place the console says the button is (the agent link's `view` + `bounds`);
  nothing is placed by eye. Each beat is its own raw take (ffmpeg x11grab, 30 fps) with its real start and end times in
  build/clipconsole/timeline.json:
    1 pull    Add a model, Qwen/Qwen2.5-0.5B-Instruct (MAX runs it), the pull's progress over the real network, Ready
    2 port    openai-community/gpt2 (an architecture MAX can't run): Port it, the port's stages end to end (16 min or
              so: shown as a time-lapse, the factor in the caption)
    3 labels  two labels made in the app, the models tagged by dragging them onto a label
    4 secure  Security → Make it secure: the steps, the HTTPS URL; then curl from outside the app: /v1/models over HTTPS
              with an app key (made through the daemon's admin API) and without one; the status codes go on the end card
compose: 1920×1080, a caption per beat (scripts/director.py's lower third), the time-lapse's speed-up in its caption,
  every number one this run measured (timeline.json). Writes docs/img/clip-console.mp4 (H.264, crf 22),
  docs/img/clip-console.gif (800 px, 12 fps, palette) and docs/img/clip-console.jpg (the poster).
"""

import json
import os
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
OUT = ROOT / "build/clipconsole"
HOME = OUT / "home"
STAGE = OUT / "stage.json"
SCALE = 2
WINDOW = (1280, 720)  # the console's window, points
SIZE = (WINDOW[0] * SCALE, WINDOW[1] * SCALE)  # the take's pixels
PORT = int(os.environ.get("CLIP_MXC_PORT", "11491"))  # (not the owner's 11435)
HTTPS_PORT = int(os.environ.get("CLIP_HTTPS_PORT", "8453"))  # (8443 is taken on this machine: D-6410)
MAX = Path.home() / ".mxc/skills/modular/import-model/.pixi/envs/default/bin/max"  # (read-only use of the owner's MAX install)
PULL = "Qwen/Qwen2.5-0.5B-Instruct"
PORT_REF = "openai-community/gpt2"
LABELS = ["chat", "ported"]
IMG = ROOT / "docs/img"


def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.168.1.1", 9))  # (no packet is sent: it picks the interface a LAN peer would reach)
        return s.getsockname()[0]
    finally:
        s.close()


# ------------------------------------------------------------------------------------------------------------ the daemon

class Daemon:
    def __init__(self, admin):
        self.admin = admin
        self.base = f"http://127.0.0.1:{PORT}"

    def poll(self, path, timeout=120):
        """A GET that may be slow (the daemon answers late while a model loads: 30 s and more during a port's serve
        stage): None instead of an exception, so a watcher keeps watching."""
        try:
            return self.call("GET", path, timeout=timeout)[1]
        except (OSError, urllib.error.URLError) as e:
            print(f"poll {path}: {e}", flush=True)
            return None

    def call(self, method, path, body=None, key=None, timeout=30):
        h = {"X-Mst-Admin": self.admin}
        if body is not None:
            h["Content-Type"] = "application/json"
        if key:
            h = {"Authorization": "Bearer " + key, "Content-Type": "application/json"}
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode() if body is not None else None, headers=h, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, json.loads(r.read() or b"null")
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw)
            except Exception:
                return e.code, raw.decode(errors="replace")


def daemon_env(admin):
    env = dict(os.environ, MXC_HOME=str(HOME), MXC_PORT=str(PORT), MXC_ADMIN_KEY=admin, MXC_MAX=str(MAX), MXC_EXPOSE_PORT=str(HTTPS_PORT),
               XDG_DATA_HOME=str(HOME / "xdg-data"), XDG_CONFIG_HOME=str(HOME / "xdg-config"))  # (Caddy's CA stays in the throwaway home)
    for k in ("MXC_URL", "MXC_API_KEY", "MOJOUI_TEST", "CUDA_VISIBLE_DEVICES"):  # (consoled picks the roomiest GPU by nvidia-smi's
        # index and asks MAX for it: hiding one from CUDA made it ask for gpu:1 when only [0] was visible, D-6418)
        env.pop(k, None)
    return env


def start_daemon(fresh=True):
    """consoled from a copy of the build (a rebuild never swaps it mid-run), on a fresh MXC_HOME."""
    if fresh:
        shutil.rmtree(HOME, ignore_errors=True)
    HOME.mkdir(parents=True, exist_ok=True)
    (OUT / "bin").mkdir(parents=True, exist_ok=True)
    exe, src = OUT / "bin/consoled", ROOT / "build/console/linux/consoled"
    if not exe.exists() or src.stat().st_mtime > exe.stat().st_mtime:  # (a rebuilt daemon is picked up; a running build never swaps it)
        shutil.copy2(src, exe)
    admin = secrets.token_hex(16)
    log = open(OUT / "consoled.log", "a")
    p = subprocess.Popen([str(exe)], env=daemon_env(admin), cwd=OUT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    d = Daemon(admin)
    for _ in range(100):
        try:
            if d.call("GET", "/admin/models")[0] == 200:
                break
        except Exception:
            pass
        if p.poll() is not None:
            raise SystemExit("consoled exited: see build/clipconsole/consoled.log")
        time.sleep(0.2)
    else:
        stop_daemon(p, d)
        raise SystemExit("consoled never answered on :" + str(PORT))
    st, got = d.call("POST", "/admin/porter", {"kind": "claude-code"})
    print("porter:", st, str(got)[:200], flush=True)
    return p, d


# ---------------------------------------------------------------------------------------------------------- the console

def left_pointer(name):
    """The root window's cursor as the usual arrow (XC_left_ptr): with no window manager Xvfb shows X's "×", and GTK's
    widgets inherit it, so the film showed a cross for a pointer."""
    from Xlib import display
    d = display.Display(name)
    font = d.open_font("cursor")
    c = font.create_glyph_cursor(font, 68, 69, (0, 0, 0), (65535, 65535, 65535))  # (XC_left_ptr and its mask)
    d.screen().root.change_attributes(cursor=c)
    d.sync()
    d.close()


class Console:
    """The console on the private display, its agent link, and real X input at the places its views are."""

    def __init__(self, admin):
        os.environ.setdefault("MOJOUI_HEADLESS_SCREEN", f"{SIZE[0]}x{SIZE[1] + 200}")
        import covers
        app = covers.copy_app("console", OUT)
        self.r = covers.Rec(app, {"MXC_URL": f"http://127.0.0.1:{PORT}", "MXC_ADMIN_KEY": admin, "GDK_SCALE": str(SCALE)},
                            OUT / "console.mp4", size=SIZE, window=WINDOW)
        self.rec = None
        left_pointer(os.environ["DISPLAY"])

    def link(self, op):
        s = socket.socket(socket.AF_UNIX)
        s.connect(str(self.r.sock))
        s.sendall((json.dumps(op) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            buf += s.recv(1 << 20)
        s.close()
        return json.loads(buf)

    def nodes(self):
        for _ in range(50):
            v = self.link({"op": "view"})
            if v.get("ok"):
                return v["nodes"]
            time.sleep(0.1)
        raise SystemExit("the console never answered `view`")

    def find(self, text, kind=None, nth=0, exact=True):
        """The node whose words (text, tag, tooltip or accessible name) are `text`, nth of them in screen order."""
        hits = []
        for i, n in enumerate(self.nodes()):
            words = [n["text"], n["name"], n["tip"], n["a11y_name"], n["hint"]]
            if kind is not None and n["kind"] != kind:
                continue
            if any((w == text) if exact else (text in w) for w in words if w):
                hits.append(i)
        return hits[nth] if len(hits) > nth else None

    def rect(self, node):
        b = self.link({"op": "bounds", "node": node})
        if not b.get("ok") or b["w"] <= 0:
            return None
        return [b["x"] * SCALE, b["y"] * SCALE, b["w"] * SCALE, b["h"] * SCALE]

    def until(self, text, timeout=120.0, exact=True, kind=None):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if self.find(text, kind=kind, exact=exact) is not None:
                return True
            time.sleep(0.3)
        return False

    def glide(self, x, y, secs=0.45):
        """The pointer moves there as a hand does (eased), so the viewer sees where the tap lands."""
        d = self.r.pointer()
        from Xlib import X
        from Xlib.ext import xtest
        p = d.screen().root.query_pointer()
        x0, y0 = p.root_x, p.root_y
        if x0 > SIZE[0] or y0 > SIZE[1]:
            x0, y0 = SIZE[0] * 0.6, SIZE[1] * 0.8
        n = max(int(secs * 60), 1)
        for k in range(1, n + 1):
            f = k / n
            f = f * f * (3 - 2 * f)
            xtest.fake_input(d, X.MotionNotify, x=int(x0 + (x - x0) * f), y=int(y0 + (y - y0) * f))
            d.sync()
            time.sleep(secs / n)

    def tap(self, text, nth=0, pause=0.6, exact=True, kind=None, timeout=30.0):
        """A real click (XTest) in the middle of the view called `text`."""
        t0 = time.time()
        while True:
            node = self.find(text, nth=nth, exact=exact, kind=kind)
            rect = self.rect(node) if node is not None else None
            if rect is not None:
                break
            if time.time() - t0 > timeout:
                raise SystemExit(f"tap: no {text!r} on screen; tools: {sorted(self.r.tools())[:80]}")
            time.sleep(0.3)
        x, y = rect[0] + rect[2] / 2, rect[1] + rect[3] / 2
        print(f"tap {text!r} at {int(x)},{int(y)}", flush=True)
        self.glide(x, y)
        time.sleep(0.12)
        self.r.button(True)
        time.sleep(0.06)
        self.r.button(False)
        time.sleep(pause)
        return rect

    def type(self, text, pause=0.4):
        """Keys (XTest) into the focused field, ~22 a second; the pointer stays over the window (no WM: keys go there)."""
        from Xlib import X, XK
        from Xlib.ext import xtest
        d = self.r.pointer()
        names = {" ": "space", ",": "comma", ".": "period", "-": "minus", "/": "slash", "_": "underscore", ":": "colon"}
        shift = d.keysym_to_keycode(XK.string_to_keysym("Shift_L"))
        for ch in text:
            name = names.get(ch, ch)
            up = ch.isupper() or ch in "_:"
            k = d.keysym_to_keycode(XK.string_to_keysym(name.lower() if ch.isupper() else name))
            if up:
                xtest.fake_input(d, X.KeyPress, shift)
            xtest.fake_input(d, X.KeyPress, k)
            xtest.fake_input(d, X.KeyRelease, k)
            if up:
                xtest.fake_input(d, X.KeyRelease, shift)
            d.sync()
            time.sleep(0.045)
        time.sleep(pause)

    def key(self, name):
        from Xlib import X, XK
        from Xlib.ext import xtest
        d = self.r.pointer()
        k = d.keysym_to_keycode(XK.string_to_keysym(name))
        xtest.fake_input(d, X.KeyPress, k)
        xtest.fake_input(d, X.KeyRelease, k)
        d.sync()
        time.sleep(0.3)

    def drag_to(self, src, dst, nth_src=0, nth_dst=0):
        a, b = self.rect(self.find(src, nth=nth_src)), self.rect(self.find(dst, nth=nth_dst))
        if a is None or b is None:
            raise SystemExit(f"drag: {src!r} or {dst!r} not on screen")
        self.glide(a[0] + min(a[2] / 2, 80 * SCALE), a[1] + a[3] / 2)
        self.r.drag(a[0] + min(a[2] / 2, 80 * SCALE), a[1] + a[3] / 2, b[0] + b[2] / 2, b[1] + b[3] / 2, secs=1.0, linger=0.4)
        time.sleep(0.8)

    def shot(self, path):
        from PIL import Image
        Image.fromarray(self.r.frame()).save(path)

    def record(self, path):
        self.stop_record()
        self.rec = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "1", "-video_size", f"{SIZE[0]}x{SIZE[1]}",
                                     "-framerate", "30", "-i", os.environ["DISPLAY"] + "+0,0", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                                     "-crf", "18", "-preset", "veryfast", str(path)], stdin=subprocess.PIPE)
        time.sleep(0.6)
        return time.time()

    def stop_record(self):
        if self.rec is not None:
            path = self.rec.args[-1]
            dead = self.rec.poll()  # (ffmpeg's x11grab segfaulted once mid-take, leaving a file with no index)
            self.rec.communicate(b"q", timeout=120)
            self.rec = None
            ok = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path], capture_output=True, text=True)
            if dead is not None or ok.returncode != 0 or not ok.stdout.strip():
                raise SystemExit(f"the recording {path} broke (ffmpeg exit {dead}): {ok.stderr.strip()[:200]}")
        return time.time()

    def screen(self):
        return self.r.c.call("screen")[0]

    def close(self):
        try:
            self.stop_record()
        finally:
            self.r.close()


# ------------------------------------------------------------------------------------------------------------ the stage

def stage():
    """The daemon and the console, left running (for exploring a screen's views with `do`); `stop` ends them."""
    import headless
    os.environ.setdefault("MOJOUI_HEADLESS_SCREEN", f"{SIZE[0]}x{SIZE[1] + 200}")
    headless.ensure()
    fresh = "--keep" not in sys.argv
    p, d = start_daemon(fresh)
    c = None
    try:
        c = Console(d.admin)
        STAGE.write_text(json.dumps({"display": os.environ["DISPLAY"], "sock": str(c.r.sock), "daemon": p.pid, "app": c.r.app.pid, "admin": d.admin}))
        print("stage up: display", os.environ["DISPLAY"], "daemon", p.pid, flush=True)  # (not the admin key)
        while not (OUT / "stage.stop").exists():
            time.sleep(0.5)
    finally:
        (OUT / "stage.stop").unlink(missing_ok=True)
        if c is not None:
            c.close()
        stop_daemon(p, d)
        STAGE.unlink(missing_ok=True)


def stop_daemon(p, d):
    """SIGTERM (as /admin/shutdown): consoled stops every max serve, the porting agent and Caddy before it goes; then its
    process group, only what this script started, if anything is left."""
    try:
        os.killpg(p.pid, signal.SIGTERM)
        p.wait(timeout=60)
    except Exception:
        pass
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except Exception:
        pass


# ------------------------------------------------------------------------------------------------------------ the take

def record(start="pull"):
    """The four beats, each its own raw take, and timeline.json: when things happened and what the daemon said.
    start="labels": beats 3 and 4 again, on the same home (its pulled and ported models), into the same timeline;
    start="pull-only": beat 1 again on the same home, the model purged first so it downloads again."""
    import headless
    os.environ.setdefault("MOJOUI_HEADLESS_SCREEN", f"{SIZE[0]}x{SIZE[1] + 200}")
    headless.ensure()
    shutil.rmtree(OUT / "apps", ignore_errors=True)
    again = start in ("labels", "pull-only")
    old = sorted(OUT.glob({"labels": "beat[34].mp4", "pull-only": "beat1.mp4"}.get(start, "beat*.mp4")))
    if old:  # (an earlier take's raw beats are kept, not deleted: a port can fail or the daemon crash mid-take)
        keep = OUT / time.strftime("take-%Y%m%d-%H%M%S")
        keep.mkdir()
        for f in old + [f for f in (OUT / "timeline.json", OUT / "take.log") if f.exists()]:
            (shutil.copy2 if again and f.name == "timeline.json" else shutil.move)(str(f), keep / f.name)
    tl = json.loads((OUT / "timeline.json").read_text()) if again else {"window": WINDOW, "scale": SCALE, "beats": {}}
    p, d = start_daemon(fresh=not again)
    c = None

    def save():
        (OUT / "timeline.json").write_text(json.dumps(tl, indent=1))

    def held(secs):
        time.sleep(secs)

    try:
        c = Console(d.admin)
        if start == "pull-only":
            d.call("DELETE", "/admin/models/qwen2.5-0.5b?purge=1", timeout=60)  # (its files too: the pull downloads again)
            c.tap("omxconsole", pause=1.5)
        if not again or start == "pull-only":
            # 1 pull ---------------------------------------------------------------------------------------------------
            b = tl["beats"]["pull"] = {"raw": "beat1.mp4", "consoled_mtime": (OUT / "bin/consoled").stat().st_mtime}
            t0 = c.record(OUT / "beat1.mp4")
            held(1.5)
            c.tap("Add a model", pause=1.0)
            c.tap("outlined-field", pause=0.2)
            c.type(PULL, pause=0.3)
            if not c.until("qwen2.5-0.5b", timeout=30):
                raise SystemExit("no search result for " + PULL)
            held(2.0)
            b["pick"] = c.tap("qwen2.5-0.5b", pause=0.0) and time.time() - t0
            while time.time() - t0 < 3600:  # (the screen is the source: its stage times are the daemon's own)
                if c.find("qwen2.5-0.5b is ready") is not None:
                    break
                if c.find("Try again") is not None:
                    raise SystemExit("the pull failed: " + c.screen()[-1200:])
                time.sleep(0.5)
            else:
                raise SystemExit("the pull never reached Ready")
            b["ready"] = time.time() - t0
            b["stages"] = [n["text"] for n in c.nodes() if n["kind"] == 1 and n["text"]]
            b.update(pull_facts(b["stages"]))
            if not b.get("fetch_s"):
                raise SystemExit("the screen gave no fetch time: " + json.dumps(b["stages"])[:600])
            b["fetched"] = b["pick"] + b["fetch_s"]  # (the fetch ends this long after the pick: the screen's own stage time)
            c.glide(SIZE[0] * 0.75, SIZE[1] * 0.92)
            held(3.5)
            b["end"] = c.stop_record() - t0
            c.shot(OUT / "beat1-ready.png")
            save()
            d.call("POST", "/admin/models/qwen2.5-0.5b/stop", {}, timeout=60)  # (one model on the GPU at a time: the port serves next)

            if start == "pull-only":
                save()
                return
            # 2 port ---------------------------------------------------------------------------------------------------
            b = tl["beats"]["port"] = {"raw": "beat2.mp4", "consoled_mtime": (OUT / "bin/consoled").stat().st_mtime}
            c.tap("Back", pause=0.8)
            t0 = c.record(OUT / "beat2.mp4")
            held(1.0)
            c.tap("Add a model", pause=1.0)
            c.tap("outlined-field", pause=0.2)
            c.type(PORT_REF, pause=0.3)
            if not c.until(PORT_REF, timeout=30) or not c.until("137M", exact=False, timeout=30):
                raise SystemExit("no search result for " + PORT_REF)
            held(1.5)
            c.tap(PORT_REF, nth=1, pause=0.0)  # (nth 0 is the field's own text)
            if not c.until("Port it", timeout=120):
                raise SystemExit("no Port it: " + c.screen()[-1500:])
            b["offer"] = time.time() - t0
            held(3.0)
            c.tap("Port it", pause=0.0)
            b["start"] = time.time() - t0
            last = None
            while time.time() - t0 < 3 * 3600:
                got = d.poll("/admin/ports")
                ports = (got or {}).get("ports", []) if isinstance(got, dict) else []
                if ports:
                    last = max(ports, key=lambda r: r["id"])
                    if last["status"] in ("done", "failed", "cancelled"):
                        break
                time.sleep(2.0)
            b["port_row"] = last
            b["port_end"] = time.time() - t0
            print("port:", last and last["status"], flush=True)
            b["smoke_ok"] = False
            for _ in range(240 if last and last["status"] == "done" else 0):  # (then the console's own smoke test, and Ready)
                if c.find("gpt2 is ready") is not None:
                    b["smoke_ok"] = True
                    break
                time.sleep(0.5)
            b["ready"] = time.time() - t0
            b["stages"] = [n["text"] for n in c.nodes() if n["kind"] == 1 and n["text"]]
            held(1.5)
            c.r.wheel(int(SIZE[0] * 0.25), int(SIZE[1] * 0.6), 8, pause=3.5)  # (the last stages and the Ready card, under the fold)
            b["end"] = c.stop_record() - t0
            c.shot(OUT / "beat2-done.png")
            save()
            if not last or last["status"] != "done":
                raise SystemExit("the port did not finish: " + json.dumps(last)[:600])
            for m in ("gpt2", "qwen2.5-0.5b"):
                d.call("POST", "/admin/models/" + m + "/stop", {}, timeout=60)

        # 3 labels -------------------------------------------------------------------------------------------------
        b = tl["beats"]["labels"] = {"raw": "beat3.mp4", "consoled_mtime": (OUT / "bin/consoled").stat().st_mtime}
        if not again:
            c.tap("Back", pause=0.3)
        else:  # (the first take's labels go, so the beat makes them again)
            for name in LABELS:
                d.call("DELETE", "/admin/labels/" + name)
        c.tap("omxconsole", pause=1.5)
        t0 = c.record(OUT / "beat3.mp4")
        held(1.2)
        for name in LABELS:
            c.tap("New label", pause=0.5)
            c.tap("new-label", pause=0.2)
            c.type(name, pause=0.2)
            c.key("Return")
            held(1.2)
        c.drag_to("row-qwen2.5-0.5b", "label-" + LABELS[0])
        held(1.0)
        c.drag_to("row-gpt2", "label-" + LABELS[1])
        held(1.2)
        c.tap(LABELS[1], pause=2.5)  # (the label as a group: only what wears it)
        c.tap("All models", pause=2.0)
        b["end"] = c.stop_record() - t0
        b["labels"] = d.call("GET", "/admin/labels")[1]
        c.shot(OUT / "beat3-labels.png")
        save()

        # 4 secure -------------------------------------------------------------------------------------------------
        b = tl["beats"]["secure"] = {"raw": "beat4.mp4", "consoled_mtime": (OUT / "bin/consoled").stat().st_mtime}
        t0 = c.record(OUT / "beat4.mp4")
        held(1.0)
        c.tap("Security", pause=1.5)
        c.tap("Make it secure", pause=0.0)
        b["click"] = time.time() - t0
        for _ in range(120):
            if c.find("https://", exact=False) is not None and c.find("Stop exposing") is not None:
                break
            time.sleep(0.25)
        b["url_shown"] = time.time() - t0
        held(2.0)
        c.r.wheel(int(SIZE[0] * 0.5), int(SIZE[1] * 0.6), 6, pause=3.0)  # (the Endpoint card with the HTTPS URL, under the fold)
        b["end"] = c.stop_record() - t0
        c.shot(OUT / "beat4-secure.png")
        b["proof"] = prove_https(d)
        save()
    finally:
        if c is not None:
            c.close()
        stop_daemon(p, d)
    print(json.dumps(tl["beats"].get("secure", {}).get("proof"), indent=1))


def prove_https(d):
    """From outside the app: curl over HTTPS on the LAN address, an app key made through the daemon's admin API, and
    the CA Caddy made (in the throwaway home), with the key and without it. The status codes are what the card says."""
    import re
    st, ex = d.call("GET", "/admin/network")
    found = re.search(r'https://[^"\s]+', json.dumps(ex))
    endpoint = found.group(0) if found else None
    host = endpoint.split("//")[1].split(":")[0] if endpoint else socket.gethostname() + ".local"
    ip = lan_ip()
    ca = HOME / "xdg-data/caddy/pki/authorities/local/root.crt"
    st, k = d.call("POST", "/admin/keys", {"app": time.strftime("clip-%H%M%S")})  # (its own app each run: a name that has a key answers 409)
    key = k.get("key") if isinstance(k, dict) else None
    if not key:
        raise SystemExit(f"no app key for the proof: {st} {k}")
    url = f"https://{host}:{HTTPS_PORT}/v1/models"
    out = {"endpoint": endpoint, "url": url, "resolved_to": ip, "ca": str(ca.relative_to(ROOT))}
    for name, extra in (("with_key", ["-H", f"Authorization: Bearer {key}"]), ("without_key", [])):
        r = subprocess.run(["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--cacert", str(ca), "--resolve", f"{host}:{HTTPS_PORT}:{ip}",
                            *extra, url], capture_output=True, text=True, timeout=30)
        out[name] = r.stdout.strip() or r.stderr.strip()
    r = subprocess.run(["curl", "-sS", "--cacert", str(ca), "--resolve", f"{host}:{HTTPS_PORT}:{ip}", "-H", f"Authorization: Bearer {key}", url],
                       capture_output=True, text=True, timeout=30)
    out["body"] = r.stdout[:400]
    print("proof:", out, flush=True)
    return out


# ----------------------------------------------------------------------------------------------------------- compose

def _frames(raw, t0, t1, speed=1.0):
    """The take from t0 to t1 (seconds), `speed` times as fast, as 1920×1080 RGBA images at 30 fps."""
    import numpy as np
    from PIL import Image
    import director
    w, h = director.OUT
    vf = f"setpts=PTS/{speed},fps={director.FPS},scale={w}:{h}:flags=lanczos"
    got = False
    pr = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", f"{max(t0, 0):.3f}", "-t", f"{max(t1 - t0, 0.04):.3f}", "-i", str(raw), "-vf", vf,
                           "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    n = w * h * 3
    while True:
        buf = pr.stdout.read(n)
        if len(buf) < n:
            break
        yield Image.fromarray(np.frombuffer(buf, np.uint8).reshape(h, w, 3)).convert("RGBA")
        got = True
    if pr.wait() != 0 or not got:  # (a broken or missing take must not drop a beat silently)
        raise SystemExit(f"no frames from {raw} {t0:.1f}–{t1:.1f} s")


def pull_facts(stages):
    """The pull's numbers as the screen showed them (the daemon's own times): "Fetch the model", "10.5s",
    "1000 MB on disk · files verified", "Compile graph", "16.0s" → fetch seconds, MB, compile seconds."""
    import re

    def secs(t):
        m = re.fullmatch(r"(?:(\d+)m\s*)?(\d+(?:\.\d+)?)s", t.strip())
        return (int(m.group(1) or 0) * 60 + float(m.group(2))) if m else None
    out = {}
    for k, t in enumerate(stages[:-1]):
        if t == "Fetch the model":
            out["fetch_s"] = secs(stages[k + 1])
            mb = re.match(r"([\d,.]+) MB on disk", stages[k + 2]) if k + 2 < len(stages) else None
            out["fetch_mb"] = float(mb.group(1).replace(",", "")) if mb else None
        if t == "Compile graph":
            out["compile_s"] = secs(stages[k + 1])
    return out


def ported_caption(row):
    """How the port ended, from its row: the attempt that passed the parity check is said when it wasn't the first."""
    n = max([st.get("attempt") or 1 for st in row["stages"] if st["name"] == "parity" and st["status"] == "done"] or [1])
    nth = {2: "2nd", 3: "3rd"}.get(n, f"{n}th")
    return "Ported, checked against Hugging Face, served" if n == 1 else f"Ported on the {nth} attempt, matches Hugging Face, served"


def _secs(x):
    if x < 60:
        return f"{x:.1f} s"
    n = int(round(x))
    return f"{n // 60} min {n % 60} s"


def proof_card(proof):
    """The last card: the two requests from outside the app, as they were sent, and the codes they got."""
    from PIL import ImageDraw, ImageFont
    import director
    W, H = director.OUT
    im = director.card(" ", sub=None)
    d = ImageDraw.Draw(im)
    title = director.font(76, 650)
    head = "One click: HTTPS on your network"
    d.text(((W - title.getlength(head)) / 2, 230), head, font=title, fill=director.INK)
    sub = director.font(36, 500)
    line = "then, from outside the app:"
    d.text(((W - sub.getlength(line)) / 2, 350), line, font=sub, fill=director.ACCENT)
    mono = ImageFont.truetype(str(ROOT / "mojoui/hosts/static/fonts/GeistMono-Variable.ttf"), 34)
    big = ImageFont.truetype(str(ROOT / "mojoui/hosts/static/fonts/GeistMono-Variable.ttf"), 44)
    url = proof["url"]
    rows = [("curl " + url + " -H 'Authorization: Bearer <app key>'", proof["with_key"], "with an app key"),
            ("curl " + url, proof["without_key"], "without one")]
    y = 470
    x0 = (W - mono.getlength("$ " + rows[0][0])) / 2
    for text, code, what in rows:
        d.text((x0, y), "$ " + text, font=mono, fill=director.INK2)
        good = code == "200"
        d.text((x0 + 40, y + 56), f"→ {code}", font=big, fill=director.GOOD if good else director.WARN)
        d.text((x0 + 40 + big.getlength(f"→ {code}") + 28, y + 66), what, font=sub, fill=director.INK2)
        y += 170
    small = director.font(30, 500)
    note = f"{url.split('/')[2].split(':')[0]} → {proof['resolved_to']} on the LAN · TLS checked against the CA Caddy made"
    d.text(((W - small.getlength(note)) / 2, y + 30), note, font=small, fill=director.INK2)
    return im


def cut(tight=False):
    """The clip's frames, streamed: (image, check name or None). Every number in a caption comes from timeline.json
    (the screen's own stage times, the port's row, curl's codes). `tight`: the GIF's cut, the same beats with less
    waiting; its time-lapse factors are recomputed for it and say so."""
    import director
    tl = json.loads((OUT / "timeline.json").read_text())
    B = tl["beats"]
    FPS = director.FPS

    def caption_on(seq, text, fade=0.3):
        for k, im in enumerate(seq):
            yield director.caption(im, text, min(1.0, k / (fade * FPS)) if fade > 0 else 1.0)

    def push(seq, check=None, at=1.5):  # (streamed: a 1080p frame is 8 MB; `check` names the frame `at` seconds in)
        for k, im in enumerate(seq):
            yield im, (check if k == int(at * FPS) else None)

    def hold(im, secs, check=None):
        yield from push([im] * int(secs * FPS), check, at=0)

    yield from hold(director.card("omxconsole", sub="your models, served by MAX, in a Mojo app",
                                  small="recorded on Linux (GTK) · a real download, a real port, a real GPU"), 1.6 if tight else 2.6, "title")

    # 1 pull: real time to the end of the fetch, the compile sped up, Ready
    b = B["pull"]
    raw = OUT / b["raw"]
    facts = pull_facts(b["stages"])
    fetched = b["fetched"]
    # no download or compile time in a caption: public pages make no speed claims, pictures included (docs/lessons.md,
    # D-4762), and the same 1 GB pull took 6 s and 10 min on one day. A time-lapse still says it's one.
    cap1 = "Pull from Hugging Face"
    if fetched - b["pick"] <= 15:
        yield from push(caption_on(_frames(raw, (b["pick"] - 3.5) if tight else max(0.5, b["pick"] - 5.8), fetched + 1.0), cap1), "pull", at=3.0)
    else:  # (a slow network: the download is a time-lapse too, and the caption says so)
        yield from push(caption_on(_frames(raw, (b["pick"] - 3.5) if tight else max(0.5, b["pick"] - 5.8), b["pick"] + 3.0), "Pull from Hugging Face"), "pull", at=3.0)
        kf = max(1, round((fetched + 1.0 - b["pick"] - 3.0) / (3.0 if tight else 6.0)))
        yield from push(caption_on(_frames(raw, b["pick"] + 3.0, fetched + 1.0, speed=kf), cap1 + f", sped up {kf}×", fade=0), "fetch")
    k = max(1, round((b["ready"] - fetched - 1.0) / (2.0 if tight else 4.0)))
    yield from push(caption_on(_frames(raw, fetched + 1.0, b["ready"], speed=k), f"MAX compiles it for this GPU, sped up {k}×", fade=0), "compile")
    yield from push(caption_on(_frames(raw, b["ready"], b["ready"] + 1.8 if tight else b["end"] - 0.3), "Ready, with its local endpoint", fade=0.2), "ready")

    # 2 port: the offer in real time, the port as a time-lapse, the result
    b = B["port"]
    raw = OUT / b["raw"]
    row = b["port_row"]
    dur = row["finished_at"] - row["started_at"]
    k = max(1, round((b["port_end"] - b["start"] - 1.0) / (11.0 if tight else 22.0)))
    yield from push(caption_on(_frames(raw, (b["offer"] - 0.8) if tight else 0.5, b["start"] + 1.0), "Port a model MAX can't run"), "offer")
    yield from push(caption_on(_frames(raw, b["start"] + 1.0, b["port_end"], speed=k), f"Claude Code ports gpt2: {_secs(dur)}, sped up {k}×", fade=0), "port", at=7.0)
    yield from push(caption_on(_frames(raw, b["port_end"], b["end"] - 0.3), ported_caption(row), fade=0.2), "ported", at=4.0)

    # 3 labels
    b = B["labels"]
    yield from push(caption_on(_frames(OUT / b["raw"], 0.4, b["end"] - 0.3), "Your models, your labels"), "labels", at=12.0)

    # 4 secure, then the proof from outside the app
    b = B["secure"]
    yield from push(caption_on(_frames(OUT / b["raw"], (b["click"] - 1.2) if tight else 0.4, b["end"] - 0.3), "One click: HTTPS on your network"), "secure", at=4.0)
    yield from hold(proof_card(b["proof"]), 3.5 if tight else 4.5, "proof")


def write(frames, path, check_dir=None, crf=22):
    """director.write for a stream of frames: 1920×1080, 30 fps, H.264 (crf 22), faststart; a PNG per named frame."""
    import director
    w, h = director.OUT
    p = subprocess.Popen(["ffmpeg", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}", "-r", str(director.FPS), "-i", "-",
                          "-c:v", "libx264", "-preset", "slow", "-crf", str(crf), "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(path)], stdin=subprocess.PIPE)
    n = 0
    for im, check in frames:
        rgb = im.convert("RGB")
        p.stdin.write(rgb.tobytes())
        if check and check_dir:
            rgb.save(check_dir / f"{check}.png")
        n += 1
    p.stdin.close()
    p.wait()
    print(f"{path}: {n / director.FPS:.1f} s", flush=True)


def compose():
    import director
    tl = json.loads((OUT / "timeline.json").read_text())
    missing = [k for k in ("pull", "port", "labels", "secure") if k not in tl["beats"] or not (OUT / tl["beats"][k]["raw"]).exists()]
    if missing:
        raise SystemExit(f"beats without a take: {missing}")
    if not tl["beats"]["port"].get("smoke_ok", True):
        raise SystemExit("the port's Ready never showed: not a clip")
    IMG.mkdir(parents=True, exist_ok=True)
    checks = OUT / "check"
    checks.mkdir(exist_ok=True)
    mp4 = IMG / "clip-console.mp4"
    for crf in (22, 24, 26):  # (≤ ~10 MB: the time-lapse's scrolling log is most of the bytes)
        write(cut(), mp4, checks if crf == 22 else None, crf=crf)
        if mp4.stat().st_size <= 10.2e6:
            break
        print(f"{mp4.stat().st_size / 1e6:.1f} MB at crf {crf}: again", flush=True)
    from PIL import Image
    Image.open(checks / "port.png").convert("RGB").save(IMG / "clip-console.jpg", quality=86)  # (the poster: the port, mid time-lapse)
    tight = OUT / "clip-console-tight.mp4"
    write(cut(tight=True), tight, None)
    gif(tight, IMG / "clip-console.gif")
    for f in (mp4, IMG / "clip-console.gif", IMG / "clip-console.jpg"):
        print(f, f"{f.stat().st_size / 1e6:.1f} MB")


def gif(mp4, out, width=800):
    """~800 px, one palette for the whole clip (palettegen → paletteuse), 12 fps; fewer colours, then 10 fps, if it is
    over ~8 MB. Never faster than the video: the captions' time-lapse factors stay true."""
    for fps, colours in ((12, 128), (12, 96), (10, 96), (10, 64)):
        vf = f"fps={fps},scale={width}:-1:flags=lanczos"
        pal = OUT / "palette.png"
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(mp4), "-vf", vf + f",palettegen=max_colors={colours}:stats_mode=diff", str(pal)], check=True)
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(mp4), "-i", str(pal), "-lavfi",
                        vf + " [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle", str(out)], check=True)
        print(f"gif: {fps} fps, {colours} colours: {out.stat().st_size / 1e6:.1f} MB", flush=True)
        if out.stat().st_size <= 8.2e6:
            return fps
    return None


class _Attached:
    """A stage's console, from another process (`do`): the agent link and the display, without starting anything."""

    def __init__(self, st):
        import covers
        from agent_client import Client
        os.environ["DISPLAY"] = st["display"]
        self.sock = Path(st["sock"])
        self.size = SIZE
        self.c = Client(attach=self.sock)
        for name in ("pointer", "move", "button", "drag", "frame", "tools"):
            setattr(self, name, getattr(covers.Rec, name).__get__(self))


def attached():
    st = json.loads(STAGE.read_text())
    c = Console.__new__(Console)
    c.r, c.rec = _Attached(st), None
    return c, Daemon(st["admin"])


def do(args):
    """One step on a stage: tools | screen | nodes [WORD] | tap TEXT [N] | type TEXT | key NAME | shot PATH | admin METHOD PATH [JSON]."""
    c, d = attached()
    verb, rest = args[0], args[1:]
    if verb == "tools":
        print("\n".join(sorted(c.r.tools())))
    elif verb == "screen":
        print(c.screen())
    elif verb == "nodes":
        for i, n in enumerate(c.nodes()):
            words = " | ".join(w for w in (n["text"], n["name"], n["tip"], n["a11y_name"]) if w)
            if words and (not rest or rest[0].lower() in words.lower()):
                print(i, n["kind"], n["msg"], words[:120])
    elif verb == "tap":
        c.tap(rest[0], nth=int(rest[1]) if len(rest) > 1 else 0, exact="--part" not in rest)
    elif verb == "type":
        c.type(rest[0])
    elif verb == "key":
        c.key(rest[0])
    elif verb == "shot":
        c.shot(rest[0])
    elif verb == "admin":
        print(d.call(rest[0], rest[1], json.loads(rest[2]) if len(rest) > 2 else None))


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what == "stage":
        stage()
    elif what == "stop":
        (OUT / "stage.stop").touch()
    elif what == "do":
        do(sys.argv[2:])
    elif what == "record":
        record("labels" if "--from-labels" in sys.argv else "pull-only" if "--only-pull" in sys.argv else "pull")
    elif what == "compose":
        compose()
