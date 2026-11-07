"""Goal 47's directed clip: "Why did the robot drop it?", scene by scene, for a viewer who has never seen omxplorer.

    pixi run python scripts/clips.py robots            (record + compose; or: python scripts/robotclip.py record|compose)

record: omxplorer (Liquid dark) on the private headless display at 2560×1440, driven only through its agent tools (the
  scenario's steps and SQL), filmed with ffmpeg's x11grab. Between steps it asks the app where things are on screen (the
  agent link's `regions` and `bounds`: the window's cards and tagged views, in pixels) and writes build/g47/story/timeline.json:
  each scene's span in the raw take and the rectangles to frame. Nothing is placed by eye: the gripper lane comes from the
  telemetry chart's own layout rules (mojoui/telemetrychart.mojo), the shirt from frame differences in the episode's clip,
  the selected row from the grid's own selection outline (the theme's accent).
compose: 1920×1080, 30 fps: eased push-ins onto those rectangles, a lower-third caption on every scene (Geist, a
  semi-opaque dark bar, white, one line) shown before what it describes, title / setup / conclusion / end cards, the
  freeze at 12.7 s with a ring on the falling shirt and a box on the gripper lane in one colour, a slowed replay.
  Writes docs/img/clip-robots.mp4 (+ .jpg: the drop frame), docs/img/clip-robots-15s.mp4 (the camera → the drop),
  docs/img/clip-robots-raw.mp4 (the raw take, 1280×720) and build/g47/clipcheck/ (a frame per scene + a contact sheet).
"""

import csv
import json
import re
import math
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import director  # noqa: E402
from director import *  # noqa: E402,F401,F403  (the director: cards, captions, cameras, encoding)
G47 = ROOT / "build/g47"
STORY = G47 / "story"
SCALE = 2  # the take at 2×: the app lays out as on a 1920×1080 screen with every pixel doubled, so a push-in onto one tile stays sharp
WIN = (1920 * SCALE, 1080 * SCALE)  # the recorded window, device pixels (16:9, like the output)
director.configure(WIN)
HERO = "F00118"
DROP_T = 12.7  # the video's time when the gripper starts to open over the box's edge (D-4718)


# ---------------------------------------------------------------------------------------------------------------- record

def record(media=None):
    import covers
    import scenario
    media = Path(media or G47 / "full").resolve()
    STORY.mkdir(parents=True, exist_ok=True)
    docs = STORY / "docs"
    shutil.rmtree(docs, ignore_errors=True)
    (docs / "config").mkdir(parents=True)
    (docs / "config" / "settings.txt").write_text("inspector=no\n")
    rows = list(csv.DictReader(open(media / "fleet.csv")))
    hero_row = [r["episode"] for r in rows].index(HERO) + 1
    hero_frames = int(next(r["frames"] for r in rows if r["episode"] == HERO))
    os.environ.setdefault("MOJOUI_HEADLESS_SCREEN", f"{WIN[0]}x{WIN[1] + 200}")
    r = covers.Rec(covers.copy_app("omxplorer", STORY), {"OMX_DOCUMENTS": str(docs), "OMX_CONFIG": str(docs / "config"), "MOJOUI_BUDGET_MS": "50",
                                                         "GDK_SCALE": str(SCALE)},
                   STORY / "raw.mp4", size=WIN, window=(WIN[0] // SCALE, WIN[1] // SCALE))
    scenes = []

    def now():
        return time.time() - r.t0

    def link(op):
        s = socket.socket(socket.AF_UNIX)
        s.connect(str(r.sock))
        s.sendall((json.dumps(op) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            buf += s.recv(1 << 20)
        s.close()
        return json.loads(buf)

    def bounds(tag):
        b = link({"op": "bounds", "tag": tag})
        return [b["x"] * SCALE, b["y"] * SCALE, b["w"] * SCALE, b["h"] * SCALE] if b.get("ok") else None  # (the app's points → recorded pixels)

    def region(name):
        got = [g for g in link({"op": "regions"})["regions"] if g["name"] == name]
        return [[g["x"] * SCALE, g["y"] * SCALE, g["w"] * SCALE, g["h"] * SCALE] for g in got]

    def until(tool, timeout=300):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if tool in r.tools():
                return
            time.sleep(0.2)
        r.close()
        raise SystemExit(f"{tool} never appeared")

    def scene(name, secs, **extra):
        t = now()
        time.sleep(secs)
        scenes.append(dict(name=name, t0=t, t1=now(), **extra))

    def type_into(rect, text):
        """Types `text` with the keyboard (XTest) into the field at `rect` (window pixels): the pointer goes over it first
        (with no window manager, keys go to the window under the pointer), then off the window."""
        from Xlib import X, XK, display
        from Xlib.ext import xtest
        d = display.Display(os.environ["DISPLAY"])
        xtest.fake_input(d, X.MotionNotify, x=int(rect[0] + rect[2] / 2), y=int(rect[1] + rect[3] / 2))
        d.sync()
        time.sleep(0.15)
        names = {" ": "space", ",": "comma", ".": "period", "-": "minus", "'": "apostrophe"}
        shift = d.keysym_to_keycode(XK.string_to_keysym("Shift_L"))
        for ch in text:
            name = names.get(ch, ch.lower())
            k = d.keysym_to_keycode(XK.string_to_keysym(name))
            if ch.isupper():
                xtest.fake_input(d, X.KeyPress, shift)
            xtest.fake_input(d, X.KeyPress, k)
            xtest.fake_input(d, X.KeyRelease, k)
            if ch.isupper():
                xtest.fake_input(d, X.KeyRelease, shift)
            d.sync()
            time.sleep(0.035)
        xtest.fake_input(d, X.MotionNotify, x=WIN[0] + 400, y=WIN[1] + 100)
        d.sync()
        d.close()

    def inspector_off():
        for _ in range(3):
            if "Inspector (Ctrl+Shift+I) ✓" not in r.c.call("screen")[0]:
                return
            r.call("view-inspector", 0.3)

    try:
        r.record()
        # (setup, not filmed: the fleet as the sheet, its telemetry as a card)
        r.call("open-file", 0.0, path=str(media / "fleet.csv"))
        until("create-table")
        r.call("create-table", 0.5)
        r.call("insert-table", 0.2)
        r.call("choose-table", 0.0, path=str(media / "telemetry.parquet"))
        until("table-telemetry")
        inspector_off()
        for _ in range(24):  # (the grid's cursor to the outcome column of the first row: a failure)
            r.call("grid", gesture="key", key="ArrowLeft")
        for _ in range(4):
            r.call("grid", gesture="key", key="ArrowRight")
        r.wheel(WIN[0] - 30, 800, -30, pause=0.8)
        grid = bounds("grid")
        scene("sheet", 4.2, grid=grid, card=region("card:fleet")[0])
        r.call("grid", 0.0, value=float(hero_row))  # (no links yet: the row is only picked, the grid shows it)
        time.sleep(0.4)
        scene("pick", 3.2, grid=bounds("grid"), card=region("card:fleet")[0])
        # (not filmed: the four links, typed; the row followed again: its video and telemetry open)
        r.call("links", 0.2)
        for l in scenario.ROBOT_LINKS:
            r.call("link", 0.1, text=l, submit=True)
        r.call("links", 0.2)
        inspector_off()
        r.call("grid", 0.2, value=float(hero_row + 1))
        r.call("grid", 0.0, value=float(hero_row))
        until("telemetry-chart")
        time.sleep(1.5)
        if "pause" in r.tools():
            r.call("pause", 0.0)
        r.call("seek", 0.6, value=5.5)
        video, chart = bounds("video"), bounds("telemetry-chart")
        # (two cards are called telemetry, the 16.8M-row table and the episode's chart: the one holding the chart, wherever
        # the tiles put it)
        holds = lambda c, r_: c[0] <= r_[0] + 2 and c[1] <= r_[1] + 2 and c[0] + c[2] >= r_[0] + r_[2] - 2 and c[1] + c[3] >= r_[1] + r_[3] - 2
        cards = {"episode": next(c for c in region("card:episode") if holds(c, video)),
                 "telemetry": next(c for c in region("card:telemetry") if holds(c, chart))}
        r.call("play", 0.0)
        scene("video", 2.8, video=video, cards=cards)
        r.call("pause", 0.0)
        r.call("seek", 0.0, value=7.2)
        scene("telemetry", 3.6, chart=chart, cards=cards)
        r.call("seek", 0.2, value=8.2)
        r.call("play", 0.0)
        scene("scrub", 4.4, video=video, chart=chart, cards=cards)
        r.call("pause", 0.0)
        r.call("seek", 0.0, value=DROP_T)
        scene("freeze", 1.2, video=video, chart=chart, cards=cards)
        t = 12.2
        t_slow = now()
        while t <= 13.6:  # (the second around it, a frame every 0.2 s: 3× slower)
            r.call("seek", 0.0, value=round(t, 3))
            time.sleep(0.2)
            t += 1 / 15
        scenes.append(dict(name="slow", t0=t_slow, t1=now(), video=video, chart=chart, cards=cards))
        # the question, typed into the query's own field; the answer lands as a card
        before = set(r.tools())
        r.call("query", 0.4)
        ask = [n for n in r.tools() if n.startswith("ask") and n not in before][0]
        box = [bounds("ask"), bounds("sql")]
        t = now()
        type_into(box[0], scenario.ROBOT_Q1)  # (real keys: a focused field keeps what a person types, D-4729)
        time.sleep(0.4)
        r.call("sql", 2.2, text=scenario.ROBOT_SQL1)  # (held: the question's SQL is what a viewer reads)
        scenes.append(dict(name="ask", t0=t, t1=now(), box=box))
        r.call("query-name", 0.0, text="regrasped")
        r.call("run-query", 0.0)
        until("table-regrasped")
        time.sleep(0.5)
        scene("answer", 3.0, card=region("card:regrasped")[0] if region("card:regrasped") else None)
        # the paper (its card scrolls into view as it lands), read from its own text, the row's field marked
        r.call("insert-documents", 0.0, path=str(media / "paper"))
        until("fields")
        r.call("reader", 0.0, option="PDF text")
        r.call("fields", 0.0, text=scenario.ROBOT_FIELDS)
        r.call("read-documents", 0.0)
        until("highlight-field", 120)
        r.call("highlight-field", 0.0, option="recorded at")
        r.call("doc-fit", 0.1)
        r.call("grid", 0.2, value=float(hero_row + 1))
        r.call("grid", 0.6, value=float(hero_row))
        scene("paper", 2.6, card=region("card:paper")[0] if region("card:paper") else None)
        # the pack
        before = set(r.tools())
        r.call("query", 0.0)
        ask = [n for n in r.tools() if n.startswith("ask") and n not in before][0]
        r.call(ask, 0.0, text="the failures I picked")
        r.call("sql", 0.0, text=scenario.ROBOT_SQL3)
        r.call("query-name", 0.0, text="picked")
        r.call("run-query", 0.0)
        until("table-picked", 120)
        time.sleep(0.4)
        r.call("table-picked", 0.3, value=1.0)
        pack = [t["name"] for t in r.c.tools() if t["name"].startswith("export-pack") and "picked" in t.get("description", "")]
        r.call(pack[0] if pack else "export-pack", 0.0)
        scene("pack", 2.0, card=region("card:picked")[0] if region("card:picked") else None)
        deadline = time.time() + 60
        while time.time() < deadline and not (docs / "pack" / f"{HERO}.pdf").exists():
            time.sleep(0.5)
        time.sleep(1.5)
    finally:
        r.close()
    log = (STORY / "raw.log").read_text()
    ms = [l for l in log.splitlines() if l.startswith("JOB: query landed")]
    slow = [l for l in log.splitlines() if l.startswith("SLOW:")]
    import pyarrow.parquet as pq
    tele_rows = pq.ParquetFile(media / "telemetry.parquet").metadata.num_rows
    timeline = dict(raw=str(r.raw), win=WIN, scenes=scenes, hero_frames=hero_frames, query_ms=ms[0] if ms else "",
                    fleet_rows=len(rows), tele_rows=tele_rows,
                    pack=str(docs / "pack" / f"{HERO}.pdf"), clip=str(media / "clips" / f"{HERO}.mp4"), slow=slow)
    (STORY / "timeline.json").write_text(json.dumps(timeline, indent=1))
    print(f"recorded {len(scenes)} scenes; {len(slow)} SLOW lines; {STORY / 'timeline.json'}")
    return timeline


# ---------------------------------------------------------------------------------------------------------------- compose

def selected_cell(frame, grid):
    """The grid's selected cell, from its own outline (the theme's "good" green, the grid's cursor) inside the grid's bounds:
    x, y, w, h."""
    x, y, w, h = grid
    y0 = max(y, 0)
    gut = 60 * SCALE // 2  # (the row numbers' column, cut: 30 pt)
    sub = frame[y0:y + h, x + gut:x + w].astype(np.int16)
    m = (np.abs(sub - np.array(GOOD)).sum(2) < 45)
    ys, xs = np.nonzero(m)
    if len(xs) < 20:
        return None
    # the outline is the biggest accent shape; the row number beside it is left of x + 60 (cut)
    return [int(np.percentile(xs, 1)) + x + gut, int(np.percentile(ys, 1)) + y0, int(np.percentile(xs, 99) - np.percentile(xs, 1)),
            int(np.percentile(ys, 99) - np.percentile(ys, 1))]


def shirt_box(clip):
    """Where the shirt moves between 12.4 s (held) and 13.1 s (fallen) in the episode's clip: the peach pixels that
    changed (video pixels: x0, y0, x1, y1)."""
    def frame(n):
        raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(clip), "-vf", f"select=eq(n\\,{n})", "-frames:v", "1", "-f", "rawvideo",
                              "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
        return np.frombuffer(raw, np.uint8).reshape(720, 1280, 3).astype(np.int16)
    a, b = frame(186), frame(197)
    d = np.abs(a - b).sum(2) > 90

    def peach(f):
        r, g, bb = f[..., 0], f[..., 1], f[..., 2]
        return (r > 170) & (g > 120) & (g < 200) & (bb > 90) & (bb < 175) & (r - bb > 45)
    ys, xs = np.nonzero(d & (peach(a) | peach(b)))
    return [float(np.percentile(xs, 3)), float(np.percentile(ys, 3)), float(np.percentile(xs, 97)), float(np.percentile(ys, 97))]


def lane_rect(chart, lane, n_lanes, t0, t1, duration):
    """A lane of the telemetry chart (mojoui/telemetrychart.mojo's layout: 4 pt top, a 20 pt time axis, 6 pt gaps, a 132 pt
    gutter, 8 pt right margin), between times t0 and t1 of a recording `duration` seconds long; window pixels."""
    x, y, w, h = chart
    k = SCALE  # (the chart's layout is in points: × SCALE in recorded pixels)
    top, bottom = y + 4 * k, y + h - 20 * k
    lane_h = (bottom - top - 6 * k * (n_lanes - 1)) / n_lanes
    ly = top + lane * (lane_h + 6 * k)
    left, right = x + 132 * k, x + w - 8 * k
    xa = left + t0 / duration * (right - left)
    xb = left + t1 / duration * (right - left)
    return [xa, ly - 4 * k, xb - xa, lane_h + 8 * k]


def split(frame, video, chart):
    """The video and the telemetry chart from one raw frame (the same instant), side by side when the chart isn't wide
    (the tiled shell's chart is nearly square), else the video above and the chart below; both fitted above the caption.
    Returns the image and the two maps (window pixels → output pixels)."""
    im = Image.new("RGBA", OUT, PAGE + (255,))
    f = Image.fromarray(frame)
    sx, sy, sw, sh = STAGE
    gap = 32
    av, ac = video[2] / video[3], chart[2] / chart[3]
    if ac > 2.2:  # (stacked: one width, the two heights share the stage)
        wd = min(sw, (sh - gap) / (1 / av + 1 / ac))
        vw, vh, cw, chh = wd, wd / av, wd, wd / ac
        vx, vy = sx + (sw - wd) / 2, sy + (sh - vh - gap - chh) / 2
        cx, cy = vx, vy + vh + gap
    else:  # (side by side: one height, the two widths share the stage)
        ht = min(sh, (sw - gap) / (av + ac))
        vw, vh, cw, chh = av * ht, ht, ac * ht, ht
        vx, vy = sx + (sw - vw - gap - cw) / 2, sy + (sh - ht) / 2
        cx, cy = vx + vw + gap, vy
    v = f.crop((video[0], video[1], video[0] + video[2], video[1] + video[3])).resize((int(vw), int(vh)), Image.LANCZOS)
    c = f.crop((chart[0], chart[1], chart[0] + chart[2], chart[1] + chart[3])).resize((int(cw), int(chh)), Image.LANCZOS)
    im.paste(v, (int(vx), int(vy)))
    im.paste(c, (int(cx), int(cy)))
    return im, (vx, vy, vw / video[2], video), (cx, cy, cw / chart[2], chart)


def mapped(m, px, py):
    ox, oy, k, r = m
    return (ox + (px - r[0]) * k, oy + (py - r[1]) * k)


class Split(Canvas):
    """A split frame with overlays drawn through either map."""

    def __init__(self, frame, video, chart):
        self.im, self.mv, self.mc = split(frame, video, chart)
        self.k = 1.0
        self.cam = [0, 0, OUT[0], OUT[1]]

    def on(self, m):
        self.at = lambda px, py: mapped(m, px, py)
        self.k = m[2]
        return self


def compose(timeline=None, which="full"):
    t = timeline or json.loads((STORY / "timeline.json").read_text())
    raw = t["raw"]
    sc = {s["name"]: s for s in t["scenes"]}
    duration = (t["hero_frames"] - 1) / 15.0
    short = which == "15s"
    v, chr_ = sc["scrub"]["video"], sc["scrub"]["chart"]
    sx0, sy0, sx1, sy1 = shirt_box(t["clip"])
    ring_c = (v[0] + (sx0 + sx1) / 2 / 1280 * v[2], v[1] + (sy0 + sy1) / 2 / 720 * v[3])
    ring_r = max(sx1 - sx0, sy1 - sy0) / 2 / 1280 * v[2] * 0.85
    grip = lane_rect(chr_, 1, 4, 12.35, 13.75, duration)
    grip_lane = lane_rect(chr_, 1, 4, 0, duration, duration)
    # (the answer's numbers as the app printed them: "JOB: query landed in 333.2 ms (2,997 rows)")
    qm = re.search(r"in ([\d.,]+) ms \(([\d,]+) rows\)", t["query_ms"] or "")
    if not qm:
        raise SystemExit(f"no query time and rows in the take's log: {t['query_ms']!r}")
    ms, n_rows = qm.group(1), qm.group(2)
    fleet_n = f"{t['fleet_rows']:,}"
    tele_n = f"{t['tele_rows'] / 1e6:.1f}M"
    full = [0, 0, WIN[0], WIN[1]]
    frames = []

    def push(im, check, final=False):
        frames.append((im, check))

    def still(im, secs, cap=None, check=None, fade_in=0.0):
        n = int(secs * FPS)
        for i in range(n):
            out = caption(im, cap, alpha=ease(i / max(1, FPS * 0.35))) if cap else im
            if fade_in and i < fade_in * FPS:
                out = Image.blend(Image.new("RGBA", OUT, PAGE + (255,)), out, i / (fade_in * FPS))
            push(out, check if i == n * 2 // 3 else None)

    def shot(name, cam_from, cam_to, cap, lead=0.5, move=1.0, cap_secs=None, speed=1, check=None, extra=None, spot=None, lift=False):
        """A raw scene: its caption first (`lead` s on the first frame), then an eased push from cam_from to cam_to; at most
        cap_secs of the take, every `speed`-th frame; spot: a window rectangle the rest of the frame dims around."""
        s = sc[name]
        b = s["t1"] if cap_secs is None else min(s["t1"], s["t0"] + cap_secs * speed)
        fs = list(raw_frames(raw, s["t0"], b))[::speed]
        if not fs:
            return
        total = int(lead * FPS) + len(fs)
        for i in range(total):
            f = fs[max(i - int(lead * FPS), 0)]
            u = ease((i - lead * FPS) / (move * FPS)) if i >= lead * FPS else 0.0
            c = Canvas(f, lerp_rect(cam_from, cam_to, u), lerp_stage(u) if lift else None)
            if extra:
                extra(c, u, i - int(lead * FPS))
            im = c.im
            if spot:
                x0, y0 = c.at(spot[0], spot[1])
                x1, y1 = c.at(spot[0] + spot[2], spot[1] + spot[3])
                im = spotlight(im, [x0 - 8, y0 - 8, x1 + 8, y1 + 8], ease(u * 1.4 - 0.4))
            push(caption(im, cap, alpha=ease(i / (FPS * 0.35))), check if i == total * 3 // 4 else None)

    if which == "full":
        still(card("Why did the robot drop it?", sub="A real failure, investigated in one app"), 2.4, check="01-title", fade_in=0.4)
        still(card([f"To find out: {tele_n} telemetry rows", "and the robot's video, in one app."]), 3.0, check="02-setup")
        g = sc["sheet"]["grid"]
        fleet = sc["sheet"]["card"]  # (the fleet card as the tiles drew it: the camera is its top, at its own width)
        sheet_cam = fit169([fleet[0], g[1] - 30 * SCALE, fleet[2], fleet[2] * 9 / 16], pad=0.0)
        cell = selected_cell(raw_at(raw, sc["sheet"]["t1"] - 0.2), g)

        def sheet_marks(c, u, i):
            if cell and u > 0.55:
                c.box([cell[0] - 4, g[1] - 2, cell[2] + 8, sheet_cam[1] + sheet_cam[3] - g[1] - 140 * SCALE], ACCENT, width=5)
                c.box([g[0] + 2, cell[1] - 4, g[2] - 8, cell[3] + 8], WARN, width=5)
                x, y = c.at(cell[0] + cell[2] + 16 * SCALE, g[1] + 34 * SCALE)
                c.label("outcome: failure", x, y, ACCENT)
        shot("sheet", full, sheet_cam, f"{fleet_n} real robot runs. Some failed.", cap_secs=3.6, check="03-sheet", extra=sheet_marks)
        pcell = selected_cell(raw_at(raw, sc["pick"]["t1"] - 0.2), sc["pick"]["grid"])
        pick_cam = fit169([fleet[0], pcell[1] - sheet_cam[3] * 0.45, fleet[2], sheet_cam[3]], pad=0.0) if pcell else sheet_cam

        def pick_marks(c, u, i):
            if not pcell:
                return
            if u > 0.6:
                c.box([g[0] + 2, pcell[1] - 4, g[2] - 8, pcell[3] + 8], WARN, width=6)
            if 0.3 < u:  # (a click: a ring that grows and fades once)
                k = min(max((i - 0.3 * FPS) / (0.6 * FPS), 0.0), 1.0)
                if k < 1:
                    cx, cy = pcell[0] + pcell[2] / 2, pcell[1] + pcell[3] / 2
                    c.ring(cx, cy, 10 + 50 * k, WARN, width=max(1, int(6 * (1 - k))))
        shot("pick", sheet_cam, pick_cam, "Pick one failure: F00118.", cap_secs=3.0, check="04-pick", extra=pick_marks)
    vid = sc["video"]["video"]
    ch = sc["telemetry"]["chart"]
    lead = 0.3 if short else 0.5
    shot("video", fit169(vid, pad=0.25) if not short else fit169(vid, pad=0.02), fit169(vid, pad=0.02), "This is its camera.", lead=lead,
         cap_secs=2.6, check="05-camera")

    def grip_mark(c, u, i):
        if u > 0.7:
            c.box(grip_lane, WARN, width=5)
            x, y = c.at(grip_lane[0] + grip_lane[2] * 0.55, grip_lane[1] - 70 * SCALE)
            c.label("gripper: closed ↔ open", x, y, WARN)
    tele_cam = grown(ch, 10 * SCALE)
    shot("telemetry", fit169(vid, pad=0.02), tele_cam, "Its telemetry: joints and gripper, 15 a second.", lead=lead, cap_secs=3.4,
         check="06-telemetry", extra=grip_mark, lift=True)
    # scrub: the split screen (video above, telemetry below), playing
    fs = list(raw_frames(raw, sc["scrub"]["t0"], sc["scrub"]["t1"]))
    for i, f in enumerate(fs):
        sp = Split(f, vid, ch)
        im = sp.im
        if i < 12:  # (from the telemetry alone into the split: a short dissolve)
            im = Image.blend(Canvas(f, tele_cam, STAGE).im, im, i / 12)
        push(caption(im, "Scrub through it…", alpha=ease(i / (FPS * 0.3))), "07-scrub" if i == len(fs) * 3 // 4 else None)
    # the moment: frozen at 12.7 s, three beats
    f = raw_at(raw, sc["freeze"]["t0"] + 0.4)
    beats = [("Wait. There.", 1.6 if short else 1.8), ("Same instant: the gripper opened.", 1.9 if short else 2.2), ("That's why it dropped.", 1.5 if short else 1.9)]
    for b, (cap, secs) in enumerate(beats):
        n = int(secs * FPS)
        for i in range(n):
            sp = Split(f, vid, ch)
            pulse = 0.5 + 0.5 * math.sin(i / FPS * 2 * math.pi * 1.1) if b == 2 else 0.0
            rx, ry, rr = sp.on(sp.mv).ring(ring_c[0], ring_c[1], ring_r, WARN, glow=pulse)
            if b >= 1:
                bx = sp.on(sp.mc).box(grip, WARN, width=6, glow=pulse)
                sp.line((rx + rr * 0.6, ry + rr * 0.8), (bx[0], bx[1]), WARN)
                sp.label("12.7 s", bx[5] + 14, bx[1] - 12, WARN)
            push(caption(sp.im, cap, alpha=ease(i / (FPS * 0.3))), f"08-moment-{b + 1}" if i == n * 2 // 3 else None)
    if not short:
        fs = list(raw_frames(raw, sc["slow"]["t0"], min(sc["slow"]["t1"], sc["slow"]["t0"] + 3.6)))
        for i, f in enumerate(fs):
            sp = Split(f, vid, ch)
            sp.on(sp.mc).box(grip, WARN, width=4)
            push(caption(sp.im, "Slowed down: it opens, the shirt falls.", alpha=ease(i / (FPS * 0.3))), "09-slow" if i == len(fs) // 2 else None)
    if which == "full":
        got = [x for x in sc["ask"]["box"] if x and x[2] > 0]
        abox = union(*got) if got else full
        shot("ask", fit169(abox, pad=0.5), fit169(abox, pad=0.12), "Is it just this one? Ask in words.", check="10-ask")
        ans = sc["answer"]["card"] or full
        shot("answer", full, grown(ans, 10 * SCALE), f"{n_rows} runs that grasped twice · {ms} ms, {tele_n} rows", cap_secs=3.0,
             check="11-answer", lift=True)
        pc = sc["paper"]["card"] or full
        shot("paper", full, grown(pc, 10 * SCALE), "Linked to the paper.", lead=0.4, move=0.8, cap_secs=2.4, check="12-paper", lift=True)
        pk = sc["pack"]["card"] or full
        shot("pack", full, grown(pk, 10 * SCALE), "Export the evidence.", lead=0.4, move=0.8, cap_secs=1.6, lift=True)
        if Path(t["pack"]).exists():
            import pymupdf
            doc = pymupdf.open(t["pack"])
            pix = doc[0].get_pixmap(dpi=110)
            page = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
            bg = card("")
            ph = int(OUT[1] * 0.74)
            page = page.resize((int(page.width * ph / page.height), ph), Image.LANCZOS)
            bg.paste(page, ((OUT[0] - page.width) // 2, 50))
            still(bg, 2.4, cap="One PDF per failure: frame, numbers, source.", check="13-pack")
        still(card(["Usually: a spreadsheet, a notebook and a video", "player, lined up by hand."], sub="Here: one app."), 3.4, check="14-conclusion")
        still(card("omxplorer", sub="built on omxcode · one Mojo app, on your GPU", small="abhisheksreesaila.github.io/omxcode"), 3.4, check="15-end")
    return frames


def compose_all():
    t = json.loads((STORY / "timeline.json").read_text())
    check = G47 / "clipcheck"
    shutil.rmtree(check, ignore_errors=True)
    check.mkdir(parents=True)
    img = ROOT / "docs/img"
    full = compose(t, "full")
    write(full, img / "clip-robots.mp4", check)
    poster = check / "08-moment-2.png"
    if poster.exists():
        Image.open(poster).convert("RGB").save(img / "clip-robots.jpg", quality=88)
    write(compose(t, "15s"), img / "clip-robots-15s.mp4")
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", t["raw"], "-vf", "scale=1280:720:flags=lanczos,format=yuv420p", "-c:v", "libx264", "-crf", "28",
                    "-preset", "veryfast", "-an", "-movflags", "+faststart", str(img / "clip-robots-raw.mp4")], check=True)
    shots = sorted(check.glob("*.png"))
    tiles = [Image.open(p).convert("RGB").resize((480, 270)) for p in shots]
    cols = 4
    sheet = Image.new("RGB", (cols * 480, ((len(tiles) + cols - 1) // cols) * 270), PAGE)
    for i, tl in enumerate(tiles):
        sheet.paste(tl, ((i % cols) * 480, (i // cols) * 270))
    sheet.save(check / "contact-sheet.png")
    print(f"clipcheck: {len(shots)} frames, {check / 'contact-sheet.png'}")


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what in ("record", "all"):
        record()
    if what in ("compose", "all"):
        compose_all()
