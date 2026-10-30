"""Record the omxlabs covers' clips (goal 39 M9) from the real apps: the GTK window on the private headless display
(scripts/headless.py), recorded with ffmpeg's x11grab, driven ONLY through the agent link (MOJOUI_AGENT_SOCKET; the
same tools an agent gets, scripts/agent_client.py --attach). Paced for a viewer: it waits between steps.

  pixi run python scripts/covers.py warehouse [--media build/g39/media] [--out build/covers]   → clip-warehouse.mp4 + .jpg
  pixi run python scripts/covers.py drone ...                                                   → clip-drone.mp4 + .jpg
  pixi run python scripts/covers.py tools warehouse|drone                                       → the tools on screen, no recording

warehouse: omxplorer opens warehouse.mp4 → Analyze (the warehouse preset) → the detections table → shipments.csv as a table
(the caption's source) → Make a reel (damaged pallets, faces blurred, the shipment burned in) → the reel card plays → the
video card's Edit → Cut it (the clips from the rows) → Back.
drone: examples/media (drone_a.mp4 beside its telemetry, in step) plays, the metric changes, then its editor with the
altitude lane. (Until the drone scenario lands in omxplorer, D-1010.)
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

    def __init__(self, app, env, out):
        headless.ensure()
        from Xlib import X, display
        from Xlib.ext import xtest
        d = display.Display(os.environ["DISPLAY"])  # the pointer off the window: no hover, no tooltip
        xtest.fake_input(d, X.MotionNotify, x=SIZE[0] + 400, y=SIZE[1] + 400)
        d.sync()
        d.close()
        self.dir = tempfile.TemporaryDirectory()
        self.sock = Path(self.dir.name) / "app.sock"
        env = dict(os.environ, MOJOUI_AGENT_SOCKET=str(self.sock), MOJOUI_WINDOW=f"{SIZE[0]}x{SIZE[1]}", MOJOUI_TRACE="1",
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

    def record(self):
        self.ffmpeg = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "0", "-video_size", f"{SIZE[0]}x{SIZE[1]}",
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
        text, _, err = self.c.call(tool, **args)
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

    def close(self):
        self.stop()
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


def finish(raw, out, poster_at, drop=()):
    """The site's copy: H.264, faststart, no audio, small; and a poster JPEG from the moment that says the most (seconds in the
    copy). drop: (from, to) spans of the recording cut out (jump cuts; nothing sped up): a popover Xvfb draws as a black box."""
    vf = "format=yuv420p"
    if drop:
        vf = "select='not(" + "+".join(f"between(t,{a:.2f},{b:.2f})" for a, b in drop) + ")',setpts=N/30/TB," + vf
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(raw), "-an", "-vf", vf, "-r", "30", "-c:v", "libx264", "-preset", "slow", "-crf", "27",
                    "-tune", "animation", "-movflags", "+faststart", str(out)], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", f"{poster_at}", "-i", str(out), "-frames:v", "1", "-q:v", "4",
                    str(out.with_suffix(".jpg"))], check=True)
    raw.unlink()
    print(f"{out} ({out.stat().st_size // 1024} KB), poster {out.with_suffix('.jpg')}")


def copy_app(name, out):
    dst = out / "apps" / name
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(ROOT / f"build/{name}/linux", dst)
    return dst / name


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
        seg = time.time() - r.t0
        r.stop()
    finally:
        r.close()
    raw = [r.raw]
    # the editor: omxplorer's video card has no Edit yet on this branch, so examples/media's editor on the same footage
    e = drone(media, out, False, "warehouse")
    try:
        e.until("cut-it", 90)  # its analysis job lands: the sentence and "Cut it"
        time.sleep(0.5)
        e.record()
        time.sleep(1.0)
        e.call("cut-it", 2.0)
        e.call("play", 4.0)
        e.call("pause", 0.6)
        e.stop()
    finally:
        e.close()
    raw.append(e.raw)
    both = out / "clip-warehouse.both.mp4"
    lst = out / "concat.txt"
    lst.write_text("".join(f"file '{f}'\n" for f in raw))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(lst), "-c", "copy", str(both)], check=True)
    for f in raw:
        if f != both:
            f.unlink()
    lst.unlink()
    m = r.marks
    print("marks: " + ", ".join(f"{k} {v:.1f}" for k, v in m.items()) + f"; segment {seg:.1f}")
    drop = [(m["analyze"], after_popover),  # the popover Xvfb draws black
            (m["insert-table"], m["make-reel"] + 0.1),  # adding shipments.csv (the caption's source): a jump cut
            (m["make-reel"] + 1.4, m["reel-make"] - 0.3),  # the dialog's choices, set one by one
            (m["play-2"] + 6.5, seg - 0.05)]  # the reel plays 6.5 s
    gone = sum(b - a for a, b in drop[:3])
    finish(both, out / "clip-warehouse.mp4", m["play-2"] + 3.0 - gone, drop)


def drone(media, out, record=True, clip=""):
    r = Rec(copy_app("media", out), {"G39_MEDIA": str(media), "G39_CLIP": clip}, out / ("clip-editor.mp4" if clip else "clip-drone.mp4"))
    if not record:
        return r
    try:
        r.record()
        time.sleep(1.0)
        r.call("play", 6.0)
        r.call("pause", 1.0)
        r.call("edit")
        r.until("cut-it", 90)  # the editor's defects lane: the analysis job lands
        time.sleep(1.5)
        r.call("play", 5.0)
        r.call("pause", 1.2)
        r.stop()
    finally:
        r.close()
    finish(r.raw, out / "clip-drone.mp4", 4.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("what", choices=["warehouse", "drone", "tools", "all"])
    ap.add_argument("app", nargs="?")
    ap.add_argument("--media", default="build/g39/media")
    ap.add_argument("--out", default="build/covers")
    a = ap.parse_args()
    media, out = (ROOT / a.media).resolve(), (ROOT / a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    if a.what == "tools":
        r = (drone(media, out, False, "warehouse") if a.app == "editor" else {"warehouse": warehouse, "drone": drone}[a.app](media, out, record=False))
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
