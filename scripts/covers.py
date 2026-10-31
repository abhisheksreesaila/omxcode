"""Record the omxlabs covers' clips (goal 39 M9) from the real apps: the GTK window on the private headless display
(scripts/headless.py), recorded with ffmpeg's x11grab, driven ONLY through the agent link (MOJOUI_AGENT_SOCKET; the
same tools an agent gets, scripts/agent_client.py --attach). Paced for a viewer: it waits between steps.

  pixi run python scripts/covers.py warehouse [--media build/g39/media] [--out build/covers]   → clip-warehouse.mp4 + .jpg
  pixi run python scripts/covers.py drone ...                                                   → clip-drone.mp4 + .jpg
  pixi run -e models python scripts/covers.py claims [--media build/g41/data]                   → clip-claims.mp4 + .jpg (and a copy
        in ~/Projects/omxlabs/assets/img, --site); the models environment: the app reads the BOLs with docTR in process
  pixi run python scripts/covers.py tools warehouse|drone                                       → the tools on screen, no recording

warehouse: omxplorer opens warehouse.mp4 → Analyze (the warehouse preset) → the detections table → shipments.csv as a table
(the caption's source) → Make a reel (damaged pallets, faces blurred, the shipment burned in) → the reel card plays → the
video card's Edit → Cut it (the clips from the rows) → play.
drone: omxplorer opens drone_a.mp4 and telemetry_a.csv (the chart and the map) → play (the cursor and the dot follow) →
Analyze (inspection) → flight b the same way (a jump cut) → Compare inspections → "worse" → Flight plan → the waypoints.
claims (goal 41 M11, Liquid dark, 1920×1200 copied at 1440×900): the dock video, the shipments sheet and the BOL folder land
→ Analyze + Read (OCR) → shipments.shipment_id dragged onto the video ("Link these?" → Link) and onto the BOLs' fields → the
shipments card held: the peek → the question in words and its SQL → the answer → each row picked: the video jumps to the damage,
the BOL marks "Exceptions: None" → Export pack. The drags and the hold are real pointer input on the display (agents have no
drag tool); everything else is agent tools.
Jump cuts only, nothing sped up: Xvfb draws a popover's shadow black, and setup steps a viewer needn't watch.
Builds are copied to <out>/apps first, so a check rebuilding build/ never swaps the binary mid-recording.
"""

import argparse
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import headless  # noqa: E402
from agent_client import Client  # noqa: E402

SIZE = (1440, 900)


class Rec:
    """One app on the headless display with its agent link, and an x11grab recording of its window."""

    def __init__(self, app, env, out, size=SIZE):
        self.size = size
        headless.ensure()
        from Xlib import X, display
        from Xlib.ext import xtest
        d = display.Display(os.environ["DISPLAY"])  # the pointer off the window: no hover, no tooltip
        xtest.fake_input(d, X.MotionNotify, x=SIZE[0] + 400, y=SIZE[1] + 400)
        d.sync()
        d.close()
        self.dir = tempfile.TemporaryDirectory()
        self.sock = Path(self.dir.name) / "app.sock"
        env = dict(os.environ, MOJOUI_AGENT_SOCKET=str(self.sock), MOJOUI_WINDOW=f"{size[0]}x{size[1]}", MOJOUI_TRACE="1",
                   CUDA_VISIBLE_DEVICES=os.environ.get("CUDA_VISIBLE_DEVICES", "0"), **env)
        env.pop("MOJOUI_TEST", None)
        self.log = open(out.with_suffix(".log"), "w")
        self.app = subprocess.Popen([str(app)], cwd=ROOT, env=env, stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)
        for _ in range(600):
            if self.sock.exists():
                break
            if self.app.poll() is not None:
                raise SystemExit(f"{app} exited: see {self.log.name}")
            time.sleep(0.1)
        else:
            raise SystemExit("the app never opened its agent link")
        time.sleep(2.5)  # the window maps and lays out
        self.c = Client(attach=self.sock)
        self.raw = out.with_suffix(".raw.mp4")
        self.ffmpeg = None
        self.t0, self.marks = None, {}  # when the recording started; when each tool was called (seconds into it)
        self.spans = []  # (tool, called, answered): seconds into the recording

    def record(self):
        self.ffmpeg = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "0", "-video_size", f"{self.size[0]}x{self.size[1]}",
                                        "-framerate", "30", "-i", os.environ["DISPLAY"] + "+0,0", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                                        "-crf", "14", "-preset", "veryfast", str(self.raw)], stdin=subprocess.PIPE)
        time.sleep(0.6)
        self.t0 = time.time()

    def stop(self):
        if self.ffmpeg is not None:
            self.ffmpeg.communicate(b"q", timeout=60)
            self.ffmpeg = None

    def tools(self):
        return {t["name"]: t.get("description", "") for t in self.c.tools()}

    def call(self, tool, pause=0.0, **args):
        """A tool, as an agent calls it; then `pause` seconds for the viewer."""
        print(f"→ {tool} {args or ''}", flush=True)
        if self.t0 is not None:
            self.marks.setdefault(tool, time.time() - self.t0)
        called = time.time()
        text, _, err = self.c.call(tool, **args)
        if self.t0 is not None:
            self.spans.append((tool, called - self.t0, time.time() - self.t0))
        for line in [l for l in text.splitlines() if l.strip()][:6]:
            print(f"    {line}")
        if err:
            self.close()
            raise SystemExit(f"tool {tool} failed: {text}")
        time.sleep(pause)
        return text

    def until(self, tool, timeout=60.0, poll=0.25):
        """Wait until `tool` is on screen (a card landed, a dialog opened)."""
        t0 = time.time()
        while time.time() - t0 < timeout:
            if tool in self.tools():
                return
            time.sleep(poll)
        self.close()
        raise SystemExit(f"{tool} never appeared; on screen: {sorted(self.tools())}")

    def wheel(self, x, y, notches, pause=0.6):
        """Scroll the wheel there (real X input, as a person would; negative: up), then the pointer leaves the window.
        The sheet scrolls to reveal what lands; this brings the video card back into view."""
        from Xlib import X, display
        from Xlib.ext import xtest
        d = display.Display(os.environ["DISPLAY"])
        xtest.fake_input(d, X.MotionNotify, x=x, y=y)
        d.sync()
        time.sleep(0.05)
        b = 5 if notches > 0 else 4
        for _ in range(abs(notches)):
            xtest.fake_input(d, X.ButtonPress, b)
            xtest.fake_input(d, X.ButtonRelease, b)
            d.sync()
            time.sleep(0.03)
        xtest.fake_input(d, X.MotionNotify, x=self.size[0] + 400, y=self.size[1] + 400)
        d.sync()
        d.close()
        time.sleep(pause)

    def pointer(self):
        """The display, for real pointer input (xtest): press, move, hold and let go as a hand does."""
        if getattr(self, "_d", None) is None:
            from Xlib import display
            self._d = display.Display(os.environ["DISPLAY"])
        return self._d

    def move(self, x, y):
        from Xlib import X
        from Xlib.ext import xtest
        d = self.pointer()
        xtest.fake_input(d, X.MotionNotify, x=int(x), y=int(y))
        d.sync()

    def button(self, down):
        from Xlib import X
        from Xlib.ext import xtest
        d = self.pointer()
        xtest.fake_input(d, X.ButtonPress if down else X.ButtonRelease, 1)
        d.sync()

    def away(self):
        self.move(self.size[0] + 400, self.size[1] + 400)

    def drag(self, x0, y0, x1, y1, secs=1.3, linger=0.5):
        """Press at (x0, y0), glide to (x1, y1) (ease in and out, 60 steps a second), wait `linger`, let go."""
        self.move(x0, y0)
        time.sleep(0.2)
        self.button(True)
        time.sleep(0.15)
        n = max(int(secs * 60), 1)
        for k in range(1, n + 1):
            f = k / n
            f = f * f * (3 - 2 * f)
            self.move(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f)
            time.sleep(secs / n)
        time.sleep(linger)
        self.button(False)

    def frame(self):
        """The window's pixels now (numpy, H × W × 3)."""
        import numpy as np
        from Xlib import X
        root = self.pointer().screen().root
        raw = root.get_image(0, 0, self.size[0], self.size[1], X.ZPixmap, 0xFFFFFFFF).data
        return np.frombuffer(raw, np.uint8).reshape(self.size[1], self.size[0], 4)[:, :, 2::-1]

    def dialogs_centred(self):
        """Xvfb has no window manager: a dialog maps at the screen's corner. Centre each other top-level window over the
        app's window, as a desktop would place it. True when one moved."""
        main, moved = self.size, False
        for w in self.pointer().screen().root.query_tree().children:
            try:
                if w.get_attributes().map_state != 2:
                    continue
                g = w.get_geometry()
            except Exception:
                continue
            if (g.width, g.height) == main or g.width < 120 or g.height < 80:
                continue
            x, y = (main[0] - g.width) // 2, max((main[1] - g.height) // 3, 0)
            if (g.x, g.y) != (x, y):
                w.configure(x=x, y=y)
                moved = True
        self.pointer().sync()
        return moved

    def until_text(self, text, timeout=60.0, poll=0.4):
        """Wait until `text` is on screen (a table card named so landed)."""
        t0 = time.time()
        while time.time() - t0 < timeout:
            if text in self.c.call("screen")[0]:
                return
            time.sleep(poll)
        self.close()
        raise SystemExit(f"{text!r} never appeared on screen")

    def close(self):
        self.stop()
        if getattr(self, "_d", None) is not None:
            try:
                self._d.close()
            except Exception:
                pass
        try:
            self.c.close()
        except Exception:
            pass
        try:
            os.killpg(self.app.pid, signal.SIGTERM)
            self.app.wait(timeout=10)
        except Exception:
            pass
        self.log.close()


def finish(raw, out, poster_at, drop=(), scale=None):
    """The site's copy: H.264, faststart, no audio, small; and a poster JPEG from the moment that says the most (seconds in the
    copy). drop: (from, to) spans of the recording cut out (jump cuts; nothing sped up): a popover Xvfb draws as a black box."""
    vf = "format=yuv420p" if scale is None else f"scale={scale[0]}:{scale[1]}:flags=lanczos,format=yuv420p"
    if drop:
        vf = "select='not(" + "+".join(f"between(t,{a:.2f},{b:.2f})" for a, b in drop) + ")',setpts=N/30/TB," + vf
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(raw), "-an", "-vf", vf, "-r", "30", "-c:v", "libx264", "-preset", "slow", "-crf", "27",
                    "-tune", "animation", "-movflags", "+faststart", str(out)], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", f"{poster_at}", "-i", str(out), "-frames:v", "1", "-q:v", "4",
                    str(out.with_suffix(".jpg"))], check=True)
    raw.unlink()
    print(f"{out} ({out.stat().st_size // 1024} KB), poster {out.with_suffix('.jpg')}")


def copy_app(name, out):
    """The app's build, copied once it is whole (a check may be rebuilding build/ meanwhile: then the last copy stays)."""
    src, dst = ROOT / f"build/{name}/linux", out / "apps" / name
    for _ in range(600):
        if (src / name).exists() and not subprocess.run(["pgrep", "-f", f"mojo build .*examples/{name} .*linux_main"], capture_output=True).stdout:
            shutil.rmtree(dst, ignore_errors=True)
            shutil.copytree(src, dst)
            return dst / name
        if (dst / name).exists():
            return dst / name
        time.sleep(2)
    raise SystemExit(f"no whole build of {name}")


def warehouse(media, out, record=True):
    docs = out / "warehouse-docs"
    shutil.rmtree(docs, ignore_errors=True)
    (docs / "config").mkdir(parents=True)
    r = Rec(copy_app("omxplorer", out), {"OMX_DOCUMENTS": str(docs), "OMX_CONFIG": str(docs / "config")}, out / "clip-warehouse.mp4")
    if not record:
        return r
    try:
        r.record()
        time.sleep(1.0)
        r.call("open-file", 1.8, path=str(media / "warehouse.mp4"))
        r.call("analyze", 0.3)  # (its popover: cut from the copy, Xvfb has no compositor and draws its shadow black)
        r.call("analyze-objects-codes-warehouse-preset")
        after_popover = time.time() - r.t0 + 0.2
        r.until("make-reel", 60)
        time.sleep(1.8)  # the detections table, read
        r.call("insert-table", 0.4)
        r.call("choose-table", 1.2, path=str(media / "shipments.csv"))
        r.call("make-reel", 0.7)
        r.call("reel-where", 0.4, option="damaged")
        r.call("reel-caption", 0.4, option="shipments · shipment")
        r.call("reel-blur-faces", 0.6, on=True)
        r.call("reel-make")
        r.until("play-2", 120)  # the reel lands as a new card
        time.sleep(0.6)
        r.call("play-2", 2.0)  # (the call answers once the app settles: a playing video holds it a few seconds)
        t_reel_end = time.time() - r.t0
        r.call("edit", 0.5)  # the source card's Edit: the editor, with the analysis as lanes
        r.until("cut-it", 90)
        time.sleep(1.0)
        r.call("cut-it", 2.0)
        r.call("play", 4.0)
        r.call("pause", 0.8)
        seg = time.time() - r.t0
        r.stop()
    finally:
        r.close()
    m = r.marks
    print("marks: " + ", ".join(f"{k} {v:.1f}" for k, v in m.items()) + f"; segment {seg:.1f}")
    drop = [(m["analyze"], after_popover),  # the popover Xvfb draws black
            (m["insert-table"], m["make-reel"] + 0.1),  # adding shipments.csv (the caption's source): a jump cut
            (m["make-reel"] + 1.4, m["reel-make"] - 0.3),  # the dialog's choices, set one by one
            (min(m["play-2"] + 6.5, t_reel_end), m["edit"] - 0.1),  # the reel plays 6.5 s
            (m["play"] + 5.0, seg - 0.05)]  # the edit plays 5 s (the play call holds while the video runs)
    gone = sum(b - a for a, b in drop[:3])
    finish(r.raw, out / "clip-warehouse.mp4", m["play-2"] + 3.0 - gone, drop)


def drone(media, out, record=True):
    """The drone in omxplorer (scripts/scenario.py drone's tools): flight a with its telemetry (chart and map), playing, the
    cursor and the map's dot following; Analyze (inspection); flight b set up the same way (cut from the copy); Compare
    inspections → the "worse" table; Flight plan → the waypoints."""
    docs = out / "drone-docs"
    shutil.rmtree(docs, ignore_errors=True)
    (docs / "config").mkdir(parents=True)
    r = Rec(copy_app("omxplorer", out), {"OMX_DOCUMENTS": str(docs), "OMX_CONFIG": str(docs / "config")}, out / "clip-drone.mp4",
            size=(1440, 1080))  # (taller: the telemetry chart and map sit under the video card)
    if not record:
        return r
    cut = []
    try:
        r.record()
        time.sleep(0.6)
        r.call("open-file", 1.2, path=str(media / "drone_a.mp4"))
        r.call("insert-table", 0.3)  # the flight's log first: the inspection preset places what it finds by it
        r.call("choose-table", 1.5, path=str(media / "telemetry_a.csv"))
        r.wheel(900, 600, -15)  # back up to the video card (GTK opens no popover on a button scrolled out of view)
        t = time.time() - r.t0
        if t - r.marks["choose-table"] > 3.0:  # the chart and the map landed: keep 2.5 s of them, then on to Analyze
            cut.append((r.marks["choose-table"] + 2.5, t))
        r.call("analyze", 0.3)
        r.call("analyze-assets-defects-inspection-preset")
        cut.append((t, time.time() - r.t0 + 0.2))  # (the popover: Xvfb draws its shadow black)
        r.until_text("drone_a places", 90)
        landed = time.time() - r.t0
        if landed - cut[-1][1] > 3.0:  # the analysis runs in the background: keep 1.5 s of its progress
            cut.append((cut[-1][1] + 1.5, landed - 0.3))
        time.sleep(1.5)  # the assets and defects, as rows
        r.wheel(900, 600, -15)
        r.call("play", 1.5)  # the chart's cursor and the map's dot follow the picture (the call itself holds ~5 s)
        r.call("pause", 0.6)
        t = time.time() - r.t0
        r.call("open", 0.3, path=str(media / "drone_b.mp4"))
        r.call("insert-table", 0.3)
        r.call("choose-table", 0.3, path=str(media / "telemetry_b.csv"))
        r.call("seek-2", 0.2, value=0.0)  # (flight b's card into view: its Analyze opens a popover only when shown)
        r.call("analyze-2", 0.3)
        r.call("analyze-assets-defects-inspection-preset")
        r.until_text("drone_b places", 90)
        time.sleep(0.3)
        r.call("insert-compare-inspections", 0.3)
        r.call("compare-earlier", 0.2, option="drone_a_places")
        r.call("compare-later", 0.2, option="drone_b_places")
        cut.append((t, time.time() - r.t0 - 0.9))  # flight b, set up the same way: a jump cut to the Compare dialog
        r.call("compare-go")
        r.until_text("worse", 60)
        time.sleep(2.0)
        r.call("flight-plan")
        r.until_text("waypoints", 60)
        time.sleep(2.5)
        seg = time.time() - r.t0
        r.stop()
    finally:
        r.close()
    print("marks: " + ", ".join(f"{k} {v:.1f}" for k, v in r.marks.items()) + f"; cut {[(round(a, 1), round(b, 1)) for a, b in cut]}; segment {seg:.1f}")
    play = r.marks["play"]  # the poster: playing, the cursor and the dot partway along
    finish(r.raw, out / "clip-drone.mp4", play + 4.0 - sum(b - a for a, b in cut if b <= play), cut)


CLAIMS_SIZE = (1920, 1200)  # (the sheet, the BOL card and the answer side by side; the copy is scaled to 1440 × 900)
BOARD = (84, 162)  # the sheet's Board origin in the window at this size (its cards' "at x,y" are from here), scrolled to the top
HEADER = (130, 69)  # a table card's first column header, from the card's corner (its title bar, then the grid's header row)


def board_shift(before, after, top=170, bottom=1090, x0=100, x1=700):
    """How far the Board scrolled down between two frames (points): the shift that best lines up their rows' brightness."""
    import numpy as np
    a = before[top:bottom, x0:x1].mean(axis=(1, 2))
    b = after[top:bottom, x0:x1].mean(axis=(1, 2))
    best, err = 0, float("inf")
    for d in range(0, 600):
        e = np.abs(a[d:] - b[: len(b) - d]).mean() if d else np.abs(a - b).mean()
        if e < err:
            best, err = d, e
    return best


def cards(r):
    """The Board's cards now, by name: (x, y, w, h) in Board points (the screen tool's "Object [tag] at x,y w×h" lines)."""
    import re
    out, tag = {}, None
    for line in r.c.call("screen")[0].splitlines():
        m = re.match(r"\s*Object \[([\w-]+)\] at (\d+),(\d+) (\d+)×(\d+)", line)
        if m:
            tag = m.group(1)
            out[tag] = tuple(int(m.group(k)) for k in range(2, 6))
        elif tag and line.strip().startswith('"') and tag + ":name" not in out:
            out[tag + ":name"] = line.strip().strip('"')
    return {out[k + ":name"]: v for k, v in out.items() if not k.endswith(":name") and k + ":name" in out}


def claims(media, out, site=None):
    """The claim in omxplorer, in Liquid dark (its default look): which damaged pallets the carrier owes for, from the dock
    camera, the shipments sheet and the signed BOLs, linked by hand and asked in words. Agent tools (scenario.py claims's),
    plus the two drags and the hold as real pointer input. The copy keeps only the moments a viewer follows (`keep`):
    jump cuts between them, nothing sped up."""
    sys.path.insert(0, str(ROOT / "scripts"))
    import scenario
    docs = out / "claims-docs"
    shutil.rmtree(docs, ignore_errors=True)
    (docs / "config").mkdir(parents=True)
    (docs / "config" / "settings.txt").write_text("inspector=no\n")  # (the sheet gets the window's width: the answer lands beside the BOLs; the look stays the default, Liquid dark)
    r = Rec(copy_app("omxplorer", out), {"OMX_DOCUMENTS": str(docs), "OMX_CONFIG": str(docs / "config")}, out / "clip-claims.mp4",
            size=CLAIMS_SIZE)
    ox, oy = BOARD
    keep = []  # (from, to): seconds into the recording that make the copy

    def now():
        return time.time() - r.t0

    def inspector(on):
        for _ in range(3):
            if ("Inspector (Ctrl+Shift+I) ✓" in r.c.call("screen")[0]) == on:
                return
            r.call("view-inspector", 0.3)

    def top():
        r.wheel(1450, 1050, -15, pause=0.5)  # (over the empty page right of the cards: the Board scrolls, no card zooms)

    def called(tool):  # when the last call of `tool` started (seconds into the recording)
        return next(c for n, c, _ in reversed(r.spans) if n == tool)

    try:
        r.record()
        time.sleep(0.8)
        r.call("open-file", 0.0, path=str(media / "dock.mp4"))
        keep.append((0.0, called("open-file") + 2.4))  # the start page, the video lands
        time.sleep(max(0.0, called("open-file") + 2.4 - now()))
        r.call("insert-table", 0.2)
        r.call("choose-table", 0.0, path=str(media / "shipments.csv"))
        t = now()
        time.sleep(1.3)
        keep.append((t, now()))  # the sheet lands (the Add a table dialog cut)
        r.call("insert-documents", 0.0, path=str(media / "bol"))
        keep.append((called("insert-documents"), called("insert-documents") + 1.9))  # the BOL folder lands (the page scrolls to it)
        top()
        r.call("analyze", 0.0)
        if "close-popover" in r.tools():  # (the popover: Xvfb draws its shadow black)
            r.call("close-popover", 0.0)
        keep.append((called("analyze") + 0.1, called("analyze") + 1.4))  # Analyze: its progress
        r.until_text("6,845 rows", 90)
        t = now()
        time.sleep(1.4)
        keep.append((t - 0.2, now()))  # the detections, as rows
        r.call("fields", 0.0, text=scenario.CLAIM_FIELDS)
        keep.append((called("fields"), called("fields") + 1.0))  # the labels printed on the form, typed
        r.call("read-documents", 0.0)
        keep.append((called("read-documents"), called("read-documents") + 1.6))  # Read: OCR, in the app's process
        r.until("export-bol-fields", 180)
        t = now()
        time.sleep(1.4)
        keep.append((t - 0.3, now()))  # the fields land as a table
        r.call("highlight-field", 0.0, option="Exceptions")
        r.call("links", 0.3)  # (the Links panel: it fills as the links are made)
        c = cards(r)
        sx, sy, sw, sh = c["shipments"]
        vx, vy, vw, vh = c["dock.mp4"]
        t = now()
        r.drag(ox + sx + HEADER[0], oy + sy + HEADER[1], ox + vx + vw * 0.55, oy + vy + vh * 0.45)
        r.away()
        r.until_text("Link these?", 10)
        time.sleep(1.7)  # "Link these?": 14 of 18 match
        r.call("link", 0.0)
        keep.append((t, called("link") + 1.0))  # shipment_id dragged onto the video, confirmed
        time.sleep(max(0.0, called("link") + 1.0 - now()))
        before = r.frame()
        t = now()
        r.wheel(1450, 1050, 3, pause=0.4)  # (down, so the BOL fields card is whole: its confirm opens where it's let go)
        down = board_shift(before, r.frame())
        bx, by, bw, bh = c["bol fields"]
        r.drag(ox + sx + HEADER[0], oy + sy + HEADER[1] - down, ox + bx + bw * 0.5, oy + by + bh * 0.4 - down)
        r.away()
        r.until_text("Link these?", 10)
        time.sleep(1.5)
        r.call("link", 0.0)
        keep.append((t, called("link") + 0.8))  # onto the BOLs' fields, confirmed
        time.sleep(max(0.0, called("link") + 0.8 - now()))
        r.move(ox + sx + sw * 0.45, oy + sy + 28 - down)  # hold the shipments card (its title bar): the peek
        time.sleep(0.2)
        t = now()
        r.button(True)
        time.sleep(2.2)
        r.button(False)
        r.away()
        time.sleep(0.6)
        keep.append((t, now()))  # held: what it's linked to
        inspector(False)
        top()
        r.call("query", 0.0)
        for _ in range(20):  # (until the dialog sits where a desktop puts it, and has been drawn there)
            if not r.dialogs_centred():
                break
            time.sleep(0.1)
        time.sleep(0.5)
        t = now()
        time.sleep(0.8)
        keep.append((t, now()))  # the Query dialog (placed as a desktop would)
        r.call("ask", 0.0, text=scenario.CLAIM_QUESTION)
        keep.append((called("ask"), called("ask") + 1.1))  # the question, in words
        r.call("sql", 0.0, text=scenario.CLAIM_SQL)
        keep.append((called("sql"), called("sql") + 1.8))  # what it means, in SQL: FROM shipments JOIN LINKED
        r.call("query-name", 0.0, text="answer")  # (the answer's name: its card and its pack say it)
        r.call("run-query", 0.0)
        r.until("table-answer", 60)
        t = now()
        time.sleep(1.5)
        keep.append((called("run-query"), called("run-query") + 0.3))
        keep.append((t - 0.2, now()))  # the answer: three shipments
        for k in (1, 2):
            r.call("table-answer", 0.0, value=float(k))  # the video seeks to the damage; the BOL marks Exceptions: None
            t = called("table-answer")
            time.sleep(max(0.0, t + 2.3 - now()))
            keep.append((t, t + 2.3))
            if k == 1:
                poster = t + 1.6
        r.call("export-pack", 0.0)
        t = called("export-pack")
        keep.append((t, t + 1.3))
        t0 = time.time()
        while time.time() - t0 < 120 and len(list((docs / "pack").glob("*.mp4"))) < 3:  # (a PDF and a reel per shipment)
            time.sleep(0.2)
        t = now()
        time.sleep(2.2)
        keep.append((t - 0.3, now()))  # the claim pack, written
        seg = now()
        r.stop()
    finally:
        r.close()
    keep = sorted((max(a, 0.0), min(b, seg)) for a, b in keep if b > a)
    drop, at = [], 0.0
    for a, b in keep:
        if a > at + 0.05:
            drop.append((at, a))
        at = max(at, b)
    if seg > at + 0.05:
        drop.append((at, seg + 1.0))
    print(f"keep {[(round(a, 1), round(b, 1)) for a, b in keep]}; {sum(b - a for a, b in keep):.1f} s of {seg:.1f}")
    clip = out / "clip-claims.mp4"
    finish(r.raw, clip, poster - sum(b - a for a, b in drop if b <= poster), drop, scale=(1440, 900))
    if site:
        site.mkdir(parents=True, exist_ok=True)
        for f in (clip, clip.with_suffix(".jpg")):
            shutil.copyfile(f, site / f.name)
        print(f"copied to {site}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("what", choices=["warehouse", "drone", "claims", "tools", "all"])
    ap.add_argument("app", nargs="?")
    ap.add_argument("--media", default="build/g39/media")
    ap.add_argument("--out", default="build/covers")
    ap.add_argument("--site", default=str(Path.home() / "Projects/omxlabs/assets/img"), help="claims: where the site's copy goes ('' for none)")
    a = ap.parse_args()
    if a.what == "claims":
        try:
            import doctr  # noqa: F401  (the app reads the BOLs with docTR in its own process: the models environment's Python)
        except ImportError:
            import scenario
            py = scenario.models_python()
            if py is None:
                raise SystemExit("claims needs the models environment: pixi run -e models python scripts/covers.py claims")
            os.execv(str(py), [str(py), *sys.argv])
        if a.media == "build/g39/media":
            a.media = "build/g41/data"
        media, out = (ROOT / a.media).resolve(), (ROOT / a.out).resolve()
        out.mkdir(parents=True, exist_ok=True)
        claims(media, out, Path(a.site) if a.site else None)
        return
    media, out = (ROOT / a.media).resolve(), (ROOT / a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    if a.what == "tools":
        r = {"warehouse": warehouse, "drone": drone}[a.app](media, out, record=False)
        try:
            for k, v in sorted(r.tools().items()):
                print(f"{k} — {v[:100]}")
        finally:
            r.close()
        return
    for what in (["warehouse", "drone"] if a.what == "all" else [a.what]):
        {"warehouse": warehouse, "drone": drone}[what](media, out)


if __name__ == "__main__":
    main()
