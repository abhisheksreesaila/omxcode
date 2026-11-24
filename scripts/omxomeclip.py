"""omx's cover clips (docs/omxome.html): short loops of the real app moving, recorded off the private headless display.

    pixi run python scripts/omxomeclip.py take  [map live pin …]    raw takes → build/omxome/<name>/ (raw.mp4, events.json)
    pixi run python scripts/omxomeclip.py edit  [map live pin …]    compose → docs/img/omx/clip-<name>.mp4 + .jpg (no new take)
    pixi run python scripts/omxomeclip.py all   [names]                    both                                   (default: map live pin, the cover's)

It runs ready builds and never builds: OMXOME_BUILDS (default: this checkout) holds
build/omx/linux/omx (the real app: Qwen3.8-27B in this process, voice, AG-UI cards) and build/stage/linux/stage (the Stage
demo: sample tiles, canned answers, no model). Its goal 72 checker supplies the model environment (OMX_MODELS, the GPU, a
silent microphone, a null sink for the speaker): docs/goals/72-check.py.

The cover's takes are the app at night (STAGE_DARK, OMX_DARK), at 7:45 on a Wednesday (the Stage demo: STAGE_CLOCK; omx:
MOJOUI_NOW), without demo controls or "sample" on the tiles (STAGE_CLEAN, OMX_CLEAN; the page's footer says the day is sample data). Every framing keeps whole words: a crop's edges fall in the gaps between columns,
or the rails fade out around the TV (Clip.matte).

take: the app at 1280×820 points with GDK_SCALE=2 (2560×1640 pixels, so a push-in on one card stays sharp) on its own Xvfb
  screen (scripts/headless.py), driven by its own test steps (MOJOUI_TEST: tap a button by its title, type into a field,
  wait for a text) while ffmpeg grabs the window (x11grab, 30 fps, the live.py `record:` line). Each line the app prints
  is kept with its time into the recording (events.json): the edit cuts on those, never on fixed seconds. Model takes
  start recording once the model has loaded (the app says "Listening"); each take reloads it (about a minute).
    tv      omx: "What does ephemeral mean?" typed into the chat bar; the bar grows into the TV (the word card left, the
            talk right); the ring walks the card's parts as she says them; × ("Back to the tiles") folds it back
    tiles   the Stage demo: "Try a day" pills: 2:30 rain at 4 (weather leaves Today and takes the big spot, an umbrella
            charm), Game tonight (a pennant), then back to the morning so the loop closes
    cards   omx: "How does a heat pump work?": the explain card (an isometric diagram) built by the model; the ring walks
            its blocks
    hybrid  omx with OMX_LANE_SWITCH=1: the test button flips the lane pill to "Claude · cloud" (an orange frame) and back.
            Nothing is asked while the cloud lane is on: no request ever goes to the cloud. On the headless display the
            tiles canvas draws empty for 4 frames (133 ms) as the screen rebuilds on each flip: the edit shows the last
            good frame for those (Clip.blank), so that clip is not published (docs/omxome.html doesn't use it) until the flash is understood
edit: 1600×1024 (the window's shape, as the stills were), a camera that eases in on the card that matters and back out,
  no lower-third captions on the cover's clips (the page's headings say it), a small touch mark where a test step tapped (the
  steps send no pointer, so the take shows none). Waiting on the model is cut or sped up, and a small tag says so
  ("thinking · 6×", "cut · 5 s"); everything else plays at real time. Each clip starts and ends on the same calm frame so it
  loops. H.264, yuv420p, +faststart, no audio, crf 26; the poster is the payoff frame.
"""
import datetime
import json
import math
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILDS = Path(os.environ.get("OMXOME_BUILDS") or ROOT).resolve()
WORK = ROOT / "build/omxome"
IMG = ROOT / "docs/img/omx"
SCALE = 2
WIN_PT = (1280, 820)
WIN = (WIN_PT[0] * SCALE, WIN_PT[1] * SCALE)  # the take's pixels
OUT = (1600, 1024)
FPS = 30
CRF = int(os.environ.get("OMXOME_CRF", "26"))
NAMES = ["tv", "tiles", "cards", "hybrid", "map", "live", "pin"]
COVER = ["map", "live", "pin"]  # the cover's (and live's first frame: stage-day.jpg)
STAGE = {"STAGE_DARK": "1", "STAGE_CLEAN": "1", "STAGE_CLOCK": "7:45"}
OMX = {"OMX_DARK": "1", "OMX_CLEAN": "1", "MOJOUI_NOW": str(int(datetime.datetime(2026, 11, 18, 7, 45).timestamp()))}  # the Stage demo's Wednesday
TODO = '{"items":[{"text":"buy milk","done":false},{"text":"call mum","done":false},{"text":"book the dentist","done":false}]}'
OPEN = "waitfor:Listening=300000;wait:2500;"  # (the model has loaded; the stage settles)


def typed(field, text, ms=45):
    """A question typed a few letters at a time (each `type:` sets the field's text, as typing it would), then Return."""
    steps = []
    for k in range(2, len(text), 2):
        steps.append(f"type:{field}={text[:k]};wait:{ms}")
    steps.append(f"enter:{field}={text}")
    return ";".join(steps)


def g72():
    import importlib.util
    spec = importlib.util.spec_from_file_location("g72check", BUILDS / "docs/goals/72-check.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


# ------------------------------------------------------------------------------------------------------------------ takes


def plan(name, d):
    """(binary, steps, env, start recording on this printed line or None, timeout s) for each take."""
    if name == "tiles":
        steps = ";".join([f"shot:{d}/first.png", "wait:2500", f"regions:{d}/regions.json", "wait:1500",
                          "tap:2:30 rain at 4", "wait:4500", "tap:Game tonight", "wait:4500", "tap:7:45 school run", "wait:3500"])
        return BUILDS / "build/stage/linux/stage", steps, {"STAGE_TRACE": str(d / "trace.txt")}, None, 120
    env = {"OMX_LLM_CTX": "32768", "MOJOUI_TODO": str(d / "todo.json"), "OMX_TV_QUIET": "60000", **OMX}
    if name == "tv":
        q = os.environ.get("OMXOME_TV_ASK", "What does ephemeral mean?")
        steps = (OPEN + f"regions:{d}/home.json;wait:1200;tap:Type;wait:700;" + typed("Type to omx", q)
                 + ";waitfor:meaning=180000;wait:1500;" + f"regions:{d}/tv.json;"
                 + "waitfor:Listening=170000;wait:2500;tap:Back to the tiles;wait:4000;" + f"shot:{d}/last.png")
        return BUILDS / "build/omx/linux/omx", steps, env, "WAITED: Listening", 900
    if name == "cards":
        q = os.environ.get("OMXOME_CARDS_ASK", "How does a heat pump work?")
        steps = (OPEN + f"regions:{d}/home.json;wait:1200;tap:Type;wait:700;" + typed("Type to omx", q)
                 + ";waitfor:Back to the tiles=240000;wait:2500;" + f"regions:{d}/tv.json;"
                 + "waitfor:Listening=240000;wait:2500;tap:Back to the tiles;wait:4000;" + f"shot:{d}/last.png")
        return BUILDS / "build/omx/linux/omx", steps, env, "WAITED: Listening", 900
    if name == "map":
        q = os.environ.get("OMXOME_MAP_ASK", "Plan a Saturday in Lisbon: the castle, tram 28 and Belém")
        steps = (OPEN + f"regions:{d}/home.json;wait:1200;tap:Type;wait:700;" + typed("Type to omx", q)
                 + ";wait:3000;waitfor:Listening=300000;" + f"regions:{d}/tv.json;"
                 + "wait:2500;tap:Back to the tiles;wait:4000;" + f"shot:{d}/last.png")
        return BUILDS / "build/omx/linux/omx", steps, env, "WAITED: Listening", 900
    if name == "live":
        # (the plain morning long enough for the timer and a score change in Live)
        steps = ";".join([f"shot:{d}/first.png", "wait:2500", f"regions:{d}/regions.json", "wait:17000", f"shot:{d}/last.png"])
        return BUILDS / "build/stage/linux/stage", steps, {"STAGE_TRACE": str(d / "trace.txt"), **STAGE}, None, 120
    if name == "pin":
        # no test steps: GTK's gestures ignore real pointer input while MOJOUI_TEST drives (a first take's XTest drag never
        # moved the tile), so the whole take is real X input (drag_to_pinned), as scripts/live.py drives an app
        return BUILDS / "build/stage/linux/stage", None, {"STAGE_TRACE": str(d / "trace.txt"), "MOJOUI_LIVE_REPORT": "1", **STAGE}, None, 60
    if name == "hybrid":
        env["OMX_LANE_SWITCH"] = "1"
        steps = OPEN + f"regions:{d}/home.json;wait:1500;tap:Switch lane;wait:3500;tap:Switch lane;wait:3000;shot:{d}/last.png"
        return BUILDS / "build/omx/linux/omx", steps, env, "WAITED: Listening", 600
    raise SystemExit("unknown take " + name)


def take(name):
    d = WORK / name
    d.mkdir(parents=True, exist_ok=True)
    for f in ("raw.mp4", "events.json", "home.json", "tv.json", "regions.json", "trace.txt"):
        (d / f).unlink(missing_ok=True)
    (d / "todo.json").write_text(TODO)
    binary, steps, extra, start_on, timeout = plan(name, d)
    os.environ.setdefault("MOJOUI_HEADLESS_SCREEN", f"{WIN[0] + 40}x{WIN[1] + 60}")
    sys.path.insert(0, str(BUILDS / "scripts"))
    import headless
    headless.ensure()
    env = dict(os.environ, GDK_SCALE=str(SCALE), MOJOUI_WINDOW=f"{WIN_PT[0]}x{WIN_PT[1]}")
    if steps is not None:
        env["MOJOUI_TEST"] = steps
    else:
        env.pop("MOJOUI_TEST", None)
    sink = None
    if binary.name == "omx":
        m = g72()
        env.update({"CUDA_VISIBLE_DEVICES": m.GPU, "OMX_LLM_GPU": "0", "OMX_MODELS": str(m.MODELS), "MOJOUI_AUDIO_SINK": m.SINK,
                    "MOJOUI_AUDIO_SOURCE": m.SILENT.replace("W/", str(m.WAV) + "/"), "OMX_SD": "0", "OMX_TRACE": "1"})
        sink = m.NullSink()
        sink.__enter__()
    env.update(extra)
    lines, rec, t_rec = [], [None], [None]

    def start_recording():
        rec[0] = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "0", "-video_size", f"{WIN[0]}x{WIN[1]}",
                                   "-framerate", str(FPS), "-i", os.environ["DISPLAY"] + "+0,0", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                                   "-crf", "14", "-preset", "ultrafast", str(d / "raw.mp4")], stdin=subprocess.PIPE)
        t_rec[0] = time.monotonic() + 0.15  # (x11grab's first frame: about when it opened the display)

    t0 = time.monotonic()
    app = subprocess.Popen([str(binary)], env=env, cwd=str(BUILDS),  # (its libraries are found from its own tree: build/llm)
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    print(f"take {name}: pid {app.pid}", flush=True)
    if start_on is None:
        time.sleep(0.8)
        start_recording()
    if name == "pin":
        threading.Thread(target=drag_to_pinned, args=(d, t_rec, app, lines), daemon=True).start()
    killer = threading.Timer(timeout, app.kill)
    killer.start()
    try:
        for line in app.stdout:
            now = time.monotonic()
            line = line.rstrip("\n")
            if rec[0] is None and start_on and line.startswith(start_on):
                start_recording()
            if line.startswith(("OMX ", "WAITED", "TEST", "QUIT")):
                print(f"{now - t0:7.1f} {line[:160]}", flush=True)
            lines.append([round(now - (t_rec[0] or now), 3) if t_rec[0] else None, line])
        app.wait()
    finally:
        killer.cancel()
        if rec[0] is not None:
            rec[0].communicate(b"q", timeout=60)
        if sink:
            sink.__exit__(None, None, None)
    (d / "events.json").write_text(json.dumps([l for l in lines if not l[1].startswith(("LABEL:", "ICON:"))], indent=0))
    print(f"take {name}: exit {app.returncode}, {d / 'raw.mp4'}", flush=True)


def drag_to_pinned(d, t_rec, app, lines, at=3.0, carry=1.4, tile="todo", hold=5.0):
    """A person's drag, as real X input: press on the to-do tile, carry it over `carry` seconds onto Pinned (left column),
    let go. Aimed as scripts/g77_stage_sides_check.py aims its drag: the app's own record (STAGE_TRACE: the last EV ZONES,
    the pinned box in the tiles canvas's points and the canvas in the window's; the last EV TILES, each tile's box in canvas
    points). Then `hold` seconds with the card in Pinned, a click on its pin-off button (found from the app's own report:
    SIGUSR1 with MOJOUI_LIVE_REPORT=1 prints BOX: lines; the lowest stage-unpin is the new card's), 3 s more, and the app
    is closed. Every pointer position goes to pointer.json with its time into the recording (the edit draws the dot)."""
    import signal
    from Xlib import X, display
    from Xlib.ext import xtest
    trace = d / "trace.txt"
    zone = canvas = box = None
    while time.monotonic() < t_rec[0] + at:
        if trace.exists():
            for line in trace.read_text().splitlines():
                m = re.search(r"EV \d+ ZONES pinned=(-?\d+),(-?\d+),(\d+),(\d+) canvas=(\d+),(\d+),(\d+),(\d+)", line)
                if m:
                    v = [int(x) for x in m.groups()]
                    zone, canvas = v[:4], v[4:]
                if " TILES " in line:
                    mm = re.search(rf"[ ;]{tile} ([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+)", line)
                    if mm:
                        box = [float(x) for x in mm.groups()]
        time.sleep(0.1)
    if not (zone and canvas and box):
        print(f"drag: no ZONES / TILES record to aim at ({zone}, {canvas}, {box})", flush=True)
        return
    x0, y0 = (canvas[0] + box[0] + box[2] / 2) * SCALE, (canvas[1] + box[1] + box[3] / 2) * SCALE
    x1, y1 = (canvas[0] + zone[0] + zone[2] / 2) * SCALE, (canvas[1] + zone[1] + min(zone[3] / 2, 60)) * SCALE
    dpy = display.Display(os.environ["DISPLAY"])
    log = []

    def move(x, y):
        xtest.fake_input(dpy, X.MotionNotify, x=int(x), y=int(y))
        dpy.sync()
        log.append([round(time.monotonic() - t_rec[0], 3), round(x), round(y), down[0]])

    down = [0]
    move(x0, y0)
    time.sleep(0.35)
    xtest.fake_input(dpy, X.ButtonPress, 1)
    dpy.sync()
    down[0] = 1
    move(x0, y0)
    time.sleep(0.2)
    n = int(carry * 60)
    for k in range(1, n + 1):
        u = ease(k / n)
        move(x0 + (x1 - x0) * u, y0 + (y1 - y0) * u - 40 * SCALE * math.sin(math.pi * u))  # (a hand's arc, not a ruler line)
        time.sleep(carry / n)
    time.sleep(0.25)
    xtest.fake_input(dpy, X.ButtonRelease, 1)
    dpy.sync()
    down[0] = 0
    move(x1, y1)
    print(f"drag: {tile} ({x0:.0f},{y0:.0f}) -> Pinned ({x1:.0f},{y1:.0f}), {len(log)} moves", flush=True)
    time.sleep(1.5)
    n0 = len(lines)
    os.kill(app.pid, signal.SIGUSR1)  # (the widgets' report: where the pinned card's pin-off button is)
    time.sleep(1.0)
    unpins = []
    for _, line in lines[n0:]:
        m = re.match(r"BOX: stage-unpin ([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+)", line)
        if m:
            unpins.append([float(v) for v in m.groups()])
    clicks = []
    if unpins:
        b = max(unpins, key=lambda r: r[1])
        ux, uy = (b[0] + b[2] / 2) * SCALE, (b[1] + b[3] / 2) * SCALE
        time.sleep(max(hold - 3.0, 0.3))
        for k in range(1, 25):  # (the hand goes to the button and presses at once: resting on it opens its tooltip, which
            u = ease(k / 24)     # Xvfb draws as a black box, no compositor)
            move(x1 + (ux - x1) * u, y1 + (uy - y1) * u)
            time.sleep(0.4 / 24)
        xtest.fake_input(dpy, X.ButtonPress, 1)
        dpy.sync()
        down[0] = 1
        move(ux, uy)
        time.sleep(0.08)
        xtest.fake_input(dpy, X.ButtonRelease, 1)
        dpy.sync()
        down[0] = 0
        move(ux, uy)
        clicks.append([log[-1][0], ux, uy])
        away = (ux - 160 * SCALE, uy + 120 * SCALE)  # (and leaves it, before a tooltip can open)
        for k in range(1, 13):
            u = ease(k / 12)
            move(ux + (away[0] - ux) * u, uy + (away[1] - uy) * u)
            time.sleep(0.25 / 12)
        print(f"unpin: clicked ({ux:.0f},{uy:.0f})", flush=True)
    else:
        print("unpin: no stage-unpin in the report", flush=True)
    (d / "pointer.json").write_text(json.dumps({"from": [x0, y0], "to": [x1, y1], "moves": log, "clicks": clicks}))
    time.sleep(3.5)
    app.terminate()


# ------------------------------------------------------------------------------------------------------------------ edit


def events(name):
    return json.loads((WORK / name / "events.json").read_text())


def when(evs, pattern, nth=0, after=0.0):
    """Seconds into the recording of the nth printed line matching pattern (after `after`)."""
    hits = [t for t, l in evs if t is not None and t >= after and re.search(pattern, l)]
    return hits[nth] if len(hits) > nth else None


def regions(path):
    p = Path(path)
    if not p.exists():
        return {}
    return {r["name"]: [r["x"] * SCALE, r["y"] * SCALE, r["w"] * SCALE, r["h"] * SCALE] for r in json.loads(p.read_text())}


def ease(u):
    u = min(max(u, 0.0), 1.0)
    return u * u * (3 - 2 * u)


def cam_fit(rect, pad=0.04):
    """rect (take pixels) grown to the output's shape round its centre (plus a margin), kept inside the window."""
    x, y, w, h = rect
    w, h = w * (1 + 2 * pad), h * (1 + 2 * pad)
    a = OUT[0] / OUT[1]
    if w / h > a:
        h = w / a
    else:
        w = h * a
    w, h = min(w, WIN[0]), min(h, WIN[1])
    cx, cy = x + rect[2] / 2, y + rect[3] / 2
    return [min(max(cx - w / 2, 0), WIN[0] - w), min(max(cy - h / 2, 0), WIN[1] - h), w, h]


FULL = [0, 0, WIN[0], WIN[1]]


def lerp(a, b, u):
    return [a[k] + (b[k] - a[k]) * u for k in range(4)]


class Clip:
    """The edit: segments of the raw take (each at a speed), a camera path, captions and touch marks, all on one output
    timeline; frames drawn with PIL and piped to ffmpeg."""

    def __init__(self, name):
        self.name = name
        self.raw = WORK / name / "raw.mp4"
        self.segs = []  # (src_t0, src_t1, speed, out_t0)
        self.t = 0.0
        self.cams = []  # (out_t, rect): keyframes, eased between
        self.caps = []  # (out_t0, out_t1, text)
        self.taps = []  # (src_t, x, y): take pixels
        self.poster_t = None
        self.checks = {}  # name -> out_t
        self.loop = 0.0  # the last seconds dissolve into the first frame, so the loop has no jump
        self.blank = None  # a rect (take pixels) that must never show flat: such a frame is replaced by the last good one
        self.matte = None  # (out_t0, out_t1, rect): everything outside rect (take pixels) fades to the app's ground between these times
        self.tags = []  # (out_t0, out_t1, text): a small tag in the top bar's empty middle (the take at another speed)
        self.path = []  # (src_t, x, y, down): a real pointer's moves (take pixels); drawn as a dot while the button is down

    def seg(self, t0, t1, speed=1.0):
        self.segs.append((t0, t1, speed, self.t))
        self.t += (t1 - t0) / speed
        return self.t

    def hold(self, src_t, secs):
        """The frame at src_t frozen for secs (the payoff, or the loop's calm ends)."""
        self.segs.append((src_t, src_t, 0.0, self.t, secs))
        self.t += secs
        return self.t

    def out_of(self, src_t):
        """The output time where source time src_t plays (the first segment holding it)."""
        for sg in self.segs:
            if sg[2] != 0.0 and sg[0] <= src_t <= sg[1]:
                return sg[3] + (src_t - sg[0]) / sg[2]
        raise ValueError(f"source {src_t:.2f} s is cut")

    def cam(self, out_t, rect):
        self.cams.append((out_t, rect))

    def cap(self, t0, t1, text, top=False):
        self.caps.append((t0, t1, text, top))

    def camera(self, t):
        if not self.cams:
            return FULL
        if t <= self.cams[0][0]:
            return self.cams[0][1]
        for (ta, ra), (tb, rb) in zip(self.cams, self.cams[1:]):
            if ta <= t <= tb:
                return lerp(ra, rb, ease((t - ta) / max(tb - ta, 1e-6)))
        return self.cams[-1][1]

    def source_times(self):
        """(out frame index -> src time, speed) for the whole timeline."""
        out = []
        for s in self.segs:
            if s[2] == 0.0:
                n = int(round(s[4] * FPS))
                out += [(s[0], 0.0)] * n
            else:
                n = int(round((s[1] - s[0]) / s[2] * FPS))
                out += [(s[0] + k / FPS * s[2], s[2]) for k in range(n)]
        return out

    def render(self, check_dir):
        import numpy as np
        from PIL import Image
        times = self.source_times()
        lo = max(min(t for t, _ in times) - 0.5, 0)
        hi = max(t for t, _ in times) + 0.5
        frames = decode(self.raw, lo, hi)  # every raw frame in [lo, hi] at 30 fps
        cuts = []  # (out time, seconds left out): each jump forward in the take gets a small "cut" chip, so no cut passes as real time
        for a, b in zip(self.segs, self.segs[1:]):
            gap = b[0] - (a[1] if a[2] != 0.0 else a[0])
            if gap > 0.5:
                cuts.append((b[3], gap))
        mp4 = IMG / f"clip-{self.name}.mp4"
        enc = subprocess.Popen(["ffmpeg", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{OUT[0]}x{OUT[1]}", "-r", str(FPS), "-i", "-",
                                "-an", "-c:v", "libx264", "-preset", "slow", "-crf", str(CRF), "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(mp4)],
                               stdin=subprocess.PIPE)
        check_dir.mkdir(parents=True, exist_ok=True)
        for f in check_dir.glob("*.png"):
            f.unlink()
        want = {int(round(t * FPS)): n for n, t in self.checks.items()}
        poster_i = int(round(self.poster_t * FPS)) if self.poster_t is not None else len(times) // 2
        good = 0
        for i, (st, speed) in enumerate(times):
            t = i / FPS
            k = min(max(int(round((st - lo) * FPS)), 0), len(frames) - 1)
            if self.blank is not None:
                bx, by, bw, bh = [int(v) for v in self.blank]
                if frames[k][by:by + bh, bx:bx + bw].std() < 2.0:
                    k = good
                good = k
            cam = self.camera(t)
            x, y, w, h = cam
            im = Image.fromarray(frames[k]).crop((int(x), int(y), int(x + w), int(y + h))).resize(OUT, Image.LANCZOS).convert("RGBA")
            if self.matte is not None:
                m0, m1, r = self.matte
                a = min(ease((t - m0) / 0.9), ease((m1 - t) / 0.9))
                if a > 0:
                    sx, sy = OUT[0] / w, OUT[1] / h
                    im = matte(im, [(r[0] - x) * sx, (r[1] - y) * sy, (r[0] + r[2] - x) * sx, (r[1] + r[3] - y) * sy], a)
            if self.path:
                im = carry_dot(im, self.path, st, cam)
            for (ts, tx, ty) in self.taps:
                age = st - ts + 0.32  # (the press shows just before the screen answers it, and is gone as it changes)
                if 0 <= age <= 0.36 and speed != 0.0:
                    im = touch(im, ((tx - x) * OUT[0] / w, (ty - y) * OUT[1] / h), age / 0.36)
            for (ct, gap) in cuts:
                if ct <= t <= ct + 1.0:
                    im = chip(im, f"cut · {gap:.0f} s", min(1.0, (ct + 1.0 - t) / 0.3))
            for (c0, c1, text) in self.tags:
                if c0 <= t <= c1:
                    im = chip(im, text, min(1.0, (t - c0) / 0.25, (c1 - t) / 0.25), middle=True)
            for (c0, c1, text, top) in self.caps:
                if c0 - 0.25 <= t <= c1 + 0.25:
                    a = min(1.0, (t - (c0 - 0.25)) / 0.25, ((c1 + 0.25) - t) / 0.25)
                    im = caption(im, text, a, top)
            rgb = im.convert("RGB")
            if i == 0:
                first = rgb
            n_loop = int(round(self.loop * FPS))
            if n_loop and i >= len(times) - n_loop:
                rgb = Image.blend(rgb, first, ease((i - (len(times) - n_loop) + 1) / n_loop))
            enc.stdin.write(rgb.tobytes())
            if i in want:
                rgb.save(check_dir / f"{want[i]}.png")
            if i == poster_i:
                rgb.save(IMG / f"clip-{self.name}.jpg", quality=86)
        enc.stdin.close()
        enc.wait()
        size = mp4.stat().st_size / 1e6
        print(f"{mp4}: {len(times) / FPS:.1f} s, {size:.2f} MB; checks in {check_dir}", flush=True)


def decode(raw, t0, t1):
    import numpy as np
    w, h = WIN
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", f"{t0:.3f}", "-i", str(raw), "-t", f"{t1 - t0:.3f}", "-vf", f"fps={FPS}",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    out, n = [], w * h * 3
    while True:
        b = p.stdout.read(n)
        if len(b) < n:
            break
        out.append(np.frombuffer(b, np.uint8).reshape(h, w, 3))
    p.wait()
    return out


def font(size, weight=600):
    from PIL import ImageFont
    f = ImageFont.truetype(str(ROOT / "mojoui/hosts/static/fonts/Geist-Variable.ttf"), size)
    try:
        f.set_variation_by_axes([weight])
    except Exception:
        pass
    return f


INK, PAGE, LINE, ACCENT = (241, 244, 249), (18, 21, 27), (50, 57, 70), (60, 196, 207)  # director.py's Liquid dark


def caption(im, text, alpha, top=False):
    """director.py's lower third at this clip's size: a dark bar, one line, a teal tick."""
    from PIL import Image, ImageDraw
    if alpha <= 0:
        return im
    f = font(40, 600)
    tw = f.getlength(text)
    bw, bh = tw + 90, 78
    x0, y0 = (OUT[0] - bw) / 2, (100 if top else OUT[1] - 60 - bh)  # (top: under the top bar, where a wide shot's chat bar is busy)
    layer = Image.new("RGBA", OUT, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    a = int(255 * alpha)
    d.rounded_rectangle([x0, y0, x0 + bw, y0 + bh], 22, fill=PAGE + (int(214 * alpha),), outline=LINE + (a,), width=2)
    d.rounded_rectangle([x0 + 26, y0 + 22, x0 + 32, y0 + bh - 22], 3, fill=ACCENT + (a,))
    d.text((x0 + 52, y0 + 15), text, font=f, fill=INK + (a,))
    return Image.alpha_composite(im, layer)


GROUND = (17, 18, 22)  # the Counter's page at night, between the columns (the app's own pixels)


def matte(im, box, a):
    """Everything outside box (output pixels) faded to the app's own ground: the rails leave as the camera comes in on the
    TV, so no rail word is cut by the frame's edge."""
    from PIL import Image, ImageDraw
    layer = Image.new("RGBA", OUT, GROUND + (int(255 * a),))
    ImageDraw.Draw(layer).rectangle(box, fill=(0, 0, 0, 0))
    return Image.alpha_composite(im, layer)


def chip(im, text, alpha, middle=False):
    """A small tag (top right; middle: top centre): where the edit left time out, or plays it faster."""
    from PIL import Image, ImageDraw
    f = font(26, 600)
    w = f.getlength(text)
    x1, y0 = (OUT[0] + w + 36) / 2 if middle else OUT[0] - 28, 18 if middle else 28
    x0 = x1 - w - 36
    layer = Image.new("RGBA", OUT, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    a = int(255 * alpha)
    d.rounded_rectangle([x0, y0, x1, y0 + 46], 14, fill=PAGE + (int(200 * alpha),), outline=LINE + (a,), width=2)
    d.text((x0 + 18, y0 + 8), text, font=f, fill=INK + (a,))
    return Image.alpha_composite(im, layer)


def carry_dot(im, path, st, cam):
    """The pointer while it holds the button (a drag): a firm dot that follows the take's own moves, fading in at the
    press and out after the release."""
    from PIL import Image, ImageDraw
    k = max((i for i, p in enumerate(path) if p[0] <= st), default=-1)
    if k < 0:
        return im
    downs = [p[0] for p in path if p[3] == 1]
    if not downs:
        return im
    t_press = downs[0]
    t_release = next((p[0] for p in path if p[0] > t_press and p[3] == 0), downs[-1])
    if st < t_press - 0.05 or st > t_release + 0.3:
        return im
    a = min(1.0, (st - t_press + 0.05) / 0.15) * (1.0 if st <= t_release else max(0.0, 1 - (st - t_release) / 0.3))
    x, y = path[k][1], path[k][2]
    cx, cy, cw, ch = cam
    ox, oy = (x - cx) * OUT[0] / cw, (y - cy) * OUT[1] / ch
    layer = Image.new("RGBA", OUT, (0, 0, 0, 0))
    dr = ImageDraw.Draw(layer)
    r = 22
    dr.ellipse([ox - r - 8, oy - r - 8, ox + r + 8, oy + r + 8], fill=(255, 255, 255, int(30 * a)))
    dr.ellipse([ox - r, oy - r, ox + r, oy + r], fill=(255, 255, 255, int(90 * a)), outline=(255, 255, 255, int(200 * a)), width=3)
    return Image.alpha_composite(im, layer)


def touch(im, xy, u):
    """Where a test step tapped: a soft dot that swells and fades (the steps send no pointer, so the take shows none)."""
    from PIL import Image, ImageDraw
    x, y = xy
    r = 18 + 26 * ease(u)
    a = int(150 * (1 - ease(u)))
    layer = Image.new("RGBA", OUT, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255, a // 2), outline=(255, 255, 255, a), width=3)
    return Image.alpha_composite(im, layer)


def pill_boxes(evs):
    """The app's last BOX report: name -> list of rects (take pixels), in order."""
    out = {}
    for _, l in evs:
        m = re.match(r"BOX: (\S+) ([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+)", l)
        if m:
            out.setdefault(m.group(1), []).append([float(v) * SCALE for v in m.groups()[1:]])
    return out


def centre(r):
    return r[0] + r[2] / 2, r[1] + r[3] / 2


EDITS = {}
_MOTION = {}


def motion(raw):
    """[(t, changed pixels)] between successive frames of the take at 1/8 size (cached per take)."""
    if raw in _MOTION:
        return _MOTION[raw]
    import numpy as np
    w, h = WIN[0] // 8, WIN[1] // 8
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-i", str(raw), "-vf", f"fps={FPS},scale={w}:{h}", "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                         stdout=subprocess.PIPE)
    out, prev, i = [], None, 0
    while True:
        b = p.stdout.read(w * h)
        if len(b) < w * h:
            break
        f = np.frombuffer(b, np.uint8).astype(np.int16)
        if prev is not None:
            out.append((i / FPS, int((np.abs(f - prev) > 8).sum())))
        prev, i = f, i + 1
    p.wait()
    _MOTION[raw] = out
    return out


def onset(raw, near, before=1.0, after=2.0, least=60):
    """The first frame from near-before to near+after where the picture changes (a tap's answer): its time, else near."""
    for t, n in motion(raw):
        if near - before <= t <= near + after and n >= least:
            return t - 1 / FPS
    return near


def settled(raw, start, quiet=0.5, least=40, limit=30.0):
    """The first time after start when the picture has stayed still for `quiet` seconds."""
    last = start
    for t, n in motion(raw):
        if t < start:
            continue
        if n >= least:
            last = t
        elif t - last >= quiet:
            return last + 1 / FPS
        if t > start + limit:
            break
    return last


def trace_events(path):
    """The Stage demo's STAGE_TRACE lines: [(ms since it started, text)]."""
    out = []
    for line in Path(path).read_text().splitlines():
        m = re.match(r"EV (\d+) (.*)$", line)
        if m:
            out.append((int(m.group(1)) / 1000, m.group(2)))
    return out


# ------------------------------------------------------------------------------------------------------------------ the clips


def edit_tiles():
    """The Stage demo: morning, then rain at 4 (weather takes the big spot, an umbrella charm), then Game tonight (a
    pennant), then back to the morning; all real time; the camera pushes in on the big tile after each tap."""
    c = Clip("tiles")
    d = WORK / "tiles"
    ev = trace_events(d / "trace.txt")
    rg = regions(d / "regions.json")
    pills = [r for r in pill_boxes(events("tiles")).get("stage-pill", []) if r[0] > WIN[0] * 0.7]
    day = {text.split()[1]: t for t, text in ev if text.startswith("DAY ")}
    off = 0.95  # (the app's clock starts about this long before the recording: refined by each tap's first changed frame)
    t_rain = onset(c.raw, day["rain"] - off)
    t_game = onset(c.raw, day["game"] - off)
    t_am = onset(c.raw, day["am"] - off)
    left, panel = rg["stage-left"], rg["stage-panel"]
    big = [left[0], panel[1], panel[0] + panel[2] * 0.5 - left[0], panel[3] * 0.80]  # Today (where weather was) + the big tile
    # (its height runs past the tile so the tile's buttons stay above the caption)
    near = cam_fit(big, pad=0.03)
    start = t_rain - 1.6
    end = min(t_am + 2.0, settled(c.raw, t_am) + 1.0)
    c.seg(start, end)
    o = lambda st: st - start  # (one real-time segment: out time = source time - start)
    c.cam(0, FULL)
    c.cam(o(t_rain) + 0.15, FULL)
    c.cam(o(t_rain) + 1.15, near)
    c.cam(o(t_game) - 1.3, near)
    c.cam(o(t_game) - 0.2, FULL)
    c.cam(o(t_game) + 0.15, FULL)
    c.cam(o(t_game) + 1.15, near)
    c.cam(o(t_am) - 1.2, near)
    c.cam(o(t_am) - 0.1, FULL)
    # the pills sit under Live, whose rows come and go with the moment: each tap lands where its pill was before the tap
    live = [len(text.split(" live=")[1].split(" ")[0].split(",")) for _, text in ev if text.startswith("FEED ")]
    pitch = 58 * SCALE  # (a Live row and its gap)
    at = lambda k, rows: (centre(pills[k])[0], centre(pills[k])[1] + (rows - live[-1]) * pitch)
    c.taps = [(t_rain, *at(2, live[0])), (t_game, *at(3, live[1])), (t_am, *at(0, live[2]))]
    c.cap(o(t_rain) + 0.3, o(t_rain) + 2.6, "Rain at 4: the weather takes the stage")
    c.cap(o(t_game) + 0.3, o(t_game) + 2.6, "Game tonight: a pennant on the card")
    c.loop = 0.4
    c.poster_t = o(t_rain) + 2.0
    c.checks = {"1-morning": 0.5, "2-rain-tap": o(t_rain) - 0.15, "2b-game-tap": o(t_game) - 0.15, "3-rain-mid": o(t_rain) + 0.45, "4-rain-payoff": o(t_rain) + 2.0,
                "5-game": o(t_game) + 2.0, "6-back": c.t - 0.6}
    c.render(d / "check")


EDITS["tiles"] = edit_tiles


def omx_marks(name):
    """The model take's moments, in seconds into the recording: what was sent, the card, each point, the end of speech."""
    ev = events(name)
    m = {"sent": when(ev, r"^OMX HEARD"), "card": when(ev, r"^OMX CARD"), "done": when(ev, r"^WAITED: Listening", after=1.0),
         "points": [(t, re.search(r"tag=(\S+)", l).group(1)) for t, l in ev if t is not None and l.startswith("OMX POINT:")]}
    return ev, m


def tv_close(c, after):
    """The × ("Back to the tiles") tap's answer: the first frame the fold changes the screen, after the ring has faded."""
    for t, n in motion(c.raw):
        if t > after and n >= 2000:
            return t - 1 / FPS
    raise ValueError("no fold found")


X_PT = (952, 98)  # the TV's × in the window (points): the head's right end (stagetv.mojo: a 36 pt icon button)


def edit_answer(name, rect_of, captions, poster_tag, think_speed=4.0, lead=3.0, linger=1.2, card_secs=None, keep_points=None,
                trim_walk=None):
    """A typed question, the TV opening, the model's thinking at think_speed (said in a caption), the card and the ring at
    real time (pushed in on rect_of(regions)), then the fold back to the tiles; a dissolve closes the loop. card_secs: the
    card's arrival plays that long, then a cut to just before the first point (the reply's words streaming in between);
    keep_points: the walk is cut after that many points; trim_walk: a still stretch between two points longer than this
    (seconds) is cut down to 1.4 s after the first lands. Every cut shows a small "cut · N s" chip (Clip.render)."""
    c = Clip(name)
    d = WORK / name
    ev, m = omx_marks(name)
    rg = regions_from_events(ev, "stage-tv")
    near = cam_fit(rect_of(rg), pad=0.0)
    sent, card = m["sent"], m["card"]
    if keep_points:
        m["points"] = m["points"][:keep_points]
    last_point = m["points"][-1][0]
    fold = tv_close(c, m["done"] + 1.0)
    t_open_end = sent + 0.7  # (the bar's grow into the TV)
    c.seg(sent - lead, sent)  # the question typed
    c.seg(sent, t_open_end)  # the TV opens
    o_think = c.t
    c.seg(t_open_end, card - 0.1, think_speed)  # thinking
    o_think_end = c.t
    if card_secs and m["points"][0][0] - 0.35 > card + card_secs:
        c.seg(card - 0.1, card + card_secs)  # the card arrives
        c.seg(m["points"][0][0] - 0.35, last_point + linger)  # (cut) the ring walking it
    elif trim_walk:
        t = card - 0.1
        for (pa, _), (pb, _) in zip(m["points"], m["points"][1:]):
            if pb - pa > trim_walk:
                c.seg(t, pa + 1.4)  # (to this point's landing)
                t = pb - 0.3  # (cut) on to just before the next one
        c.seg(t, last_point + linger)
    else:
        c.seg(card - 0.1, last_point + linger)  # the card, the ring walking it
    o_fold = c.t
    c.seg(fold - 0.45, fold + 1.6)  # × and the fold back
    c.hold(fold + 1.6, 0.4)
    c.cam(0, FULL)
    c.cam(c.out_of(card) - 0.1, FULL)  # (the whole Stage while it thinks, then in on the card)
    c.cam(c.out_of(card) + 1.2, near)
    c.cam(o_fold + 0.3, near)
    c.cam(o_fold + 1.3, FULL)
    c.taps = [(fold, X_PT[0] * SCALE, X_PT[1] * SCALE)]
    tv = rg["stage-tv"]
    # (the rails and the top bar gone before the camera moves in, back after it has come out: no word is cut on the way either)
    c.matte = (c.out_of(card) - 1.0, o_fold + 2.1, [tv[0] - 4 * SCALE, tv[1] - 4 * SCALE, tv[2] + 8 * SCALE, WIN[1]])
    if captions[0]:
        c.cap(0.3, lead - 0.3, captions[0], top=True)
    c.tags = [(o_think + 0.1, o_think_end - 0.1, f"thinking · {think_speed:g}×")]
    if captions[1]:  # (None: the card's own text fills the bottom, and the ring says it alone)
        c.cap(c.out_of(m["points"][1][0]), c.out_of(m["points"][-1][0]) + 0.4, captions[1])
    if captions[2]:
        c.cap(o_fold + 0.3, c.t - 0.5, captions[2])
    c.loop = 0.4
    tp = [t for t, tag in m["points"] if poster_tag in tag]
    t_poster = (tp[0] if tp else m["points"][len(m["points"]) // 2][0]) + 0.9
    c.poster_t = c.out_of(t_poster)
    c.checks = {"1-home": 0.2, "2-typed": c.out_of(sent) - 0.1, "3-opening": c.out_of(sent) + 0.35, "4-thinking": (o_think + o_think_end) / 2,
                "5-card": c.out_of(card) + 0.5}
    for k, (t, tag) in enumerate(m["points"]):
        c.checks[f"6-point{k}-{tag.split('.')[-1]}"] = c.out_of(t) + 0.5
    c.checks.update({"7-tap": o_fold + 0.3, "8-folding": o_fold + 0.7, "9-tiles": c.t - 0.6})
    print(f"{name}: sent {sent:.2f}, card {card:.2f}, points {[round(t, 2) for t, _ in m['points']]}, fold {fold:.2f}", flush=True)
    c.render(d / "check")


def regions_from_events(ev, needs):
    """The REGION lines of the last regions: step that showed `needs`, as name -> rect (take pixels)."""
    blocks, cur, last_t = [], {}, None
    for t, l in ev:
        mm = re.match(r"REGION: (\S+) (-?\d+),(-?\d+) (\d+)x(\d+)", l)
        if not mm:
            continue
        if last_t is not None and t != last_t:
            blocks.append(cur)
            cur = {}
        cur[mm.group(1)] = [int(v) * SCALE for v in mm.groups()[1:]]
        last_t = t
    blocks.append(cur)
    hits = [b for b in blocks if needs in b]
    return hits[-1] if hits else {}


def edit_tv():
    # the word card, its title row and the talk's first bubbles: the ring's walk fills the frame, above the caption
    edit_answer("tv", lambda rg: [rg["stage-tv"][0] + 10 * SCALE, rg["stage-tv"][1] - 4 * SCALE, 680 * SCALE, 470 * SCALE],
                ["Ask out loud, or type", "It points at what it means", "Then it folds back"], "meaning")


EDITS["tv"] = edit_tv


def edit_cards():
    # the diagram card (the same TV layout as the word card): its blocks and the talk beside it, above the caption
    # (taller than the word card's: the step under the diagram stays above the caption)
    edit_answer("cards", lambda rg: [rg["stage-tv"][0] + 10 * SCALE, rg["stage-tv"][1] - 4 * SCALE, 680 * SCALE, 560 * SCALE],
                ["Ask how something works", None, "Then it folds back"], "compressor",
                think_speed=6.0, lead=1.8, card_secs=1.1, keep_points=4)


EDITS["cards"] = edit_cards


def edit_map():
    # the map card (taller than the word card: the map runs to ~530 pt) and the talk beside it; the rails fade out around the TV
    edit_answer("map", lambda rg: [rg["stage-tv"][0] + 10 * SCALE, rg["stage-tv"][1] - 4 * SCALE, 680 * SCALE, 580 * SCALE],
                [None, None, None], "stop2",
                think_speed=6.0, lead=2.0, linger=1.7, trim_walk=3.0)


EDITS["map"] = edit_map


def edit_live():
    """The Stage demo's Live column on the plain morning: the whole Stage, then a push-in on its three rows (the pasta timer
    ticking each second, Hoops' score moving as the home and away sides score, Mum's landing time), all real time, about
    12 s so the timer and the score both change on screen; the loop dissolves back to the first frame. The push-in's left
    edge is the gap between the stage's two columns of tiles, so no word is cut. The first frame is also stage-day.jpg."""
    from PIL import Image
    c = Clip("live")
    d = WORK / "live"
    rg = regions(d / "regions.json")
    panel = rg["stage-panel"]
    mid = panel[0] + panel[2] / 2 + 1 * SCALE  # between the tile columns (a 12 pt gap)
    w = WIN[0] - mid
    tight = [mid, 10 * SCALE, w, w * OUT[1] / OUT[0]]
    start = 1.6
    c.seg(start, start + 11.6)
    c.cam(0, FULL)
    c.cam(0.9, FULL)
    c.cam(2.1, tight)
    c.loop = 0.5
    c.poster_t = 9.0
    c.checks = {f"t{k:02d}": k + 0.5 for k in range(12)}
    c.render(d / "check")
    first = decode(c.raw, start, start + 0.2)[0]
    Image.fromarray(first).resize(OUT, Image.LANCZOS).save(IMG / "stage-day.jpg", quality=88)


EDITS["live"] = edit_live


def edit_pin():
    """The Stage demo's left column: the to-do tile dragged by hand (real X input) from the stage onto Pinned; it joins
    Pinned and the grid closes the gap; its pin-off button puts it back. All real time; the pointer is drawn as a dot while
    it carries the tile (pointer.json: the take's own moves). The tiles canvas can't draw outside itself, so the carried
    tile is cut off at the stage's edge before it lands in Pinned: that is how the app looks, not an edit."""
    c = Clip("pin")
    d = WORK / "pin"
    ptr = json.loads((d / "pointer.json").read_text())
    moves = ptr["moves"]
    press = next(m[0] for m in moves if m[3] == 1)
    release = next(m[0] for m in moves if m[0] > press and m[3] == 0)
    click = ptr["clicks"][0][0] if ptr["clicks"] else release + 5.0
    drop = onset(c.raw, release, before=0.1, after=1.5, least=2000)
    unpin = onset(c.raw, click, before=0.05, after=1.5, least=2000)
    start = press - 1.6
    end = min(unpin + 2.4, ffprobe_duration(c.raw) - 0.6)
    c.seg(start, end)
    o = lambda st: st - start
    wide = FULL
    near = [0, 190 * SCALE, 640 * SCALE, 640 * SCALE * OUT[1] / OUT[0]]  # Today's rows, Pinned and the stage's first column of tiles: its
    # right edge is the gap between the tile columns, so no word is cut
    c.cam(0, wide)
    c.cam(o(drop) + 0.3, wide)
    c.cam(o(drop) + 1.2, near)
    c.cam(o(unpin) - 1.1, near)
    c.cam(o(unpin) - 0.2, wide)
    c.path = [(m[0], m[1], m[2], m[3]) for m in moves]
    c.taps = [(unpin, ptr["clicks"][0][1], ptr["clicks"][0][2])] if ptr["clicks"] else []
    c.loop = 0.4
    c.poster_t = o(drop) + 1.9
    c.checks = {"1-start": 0.3, "2-press": o(press) + 0.1, "3-carry-a": o(press) + 0.6, "4-carry-b": o(press) + 1.1,
                "5-carry-c": o(release) - 0.15, "6-dropped": o(drop) + 0.5, "7-pinned": o(drop) + 1.9, "8-unpin": o(unpin) - 0.1,
                "9-back": o(unpin) + 1.2, "10-end": c.t - 0.3}
    print(f"pin: press {press:.2f}, release {release:.2f}, drop {drop:.2f}, unpin {unpin:.2f}", flush=True)
    c.render(d / "check")


def ffprobe_duration(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)], capture_output=True, text=True)
    return float(r.stdout.strip() or 0)


EDITS["pin"] = edit_pin


def blank_run(raw, t0, t1, rect):
    """(first, last) times of the frames in [t0, t1] where rect (take pixels) is one flat colour: the tiles canvas drawn empty
    for a few frames while the whole screen rebuilds (seen on the headless display when the lane flips), else None."""
    import numpy as np
    w, h = WIN
    x, y, rw, rh = [int(v) for v in rect]
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", f"{t0:.3f}", "-i", str(raw), "-t", f"{t1 - t0:.3f}", "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                         stdout=subprocess.PIPE)
    hits, i = [], 0
    while True:
        b = p.stdout.read(w * h)
        if len(b) < w * h:
            break
        f = np.frombuffer(b, np.uint8).reshape(h, w)
        if f[y:y + rh, x:x + rw].std() < 2.0:
            hits.append(t0 + i / FPS)
        i += 1
    p.wait()
    return (hits[0], hits[-1]) if hits else None


def edit_hybrid():
    """The lane flip: "Switch lane" (the test button) turns the pill to "Claude · cloud" and frames the screen in orange; a
    push-in on the pill; the flip back. Nothing is asked: no request goes to the cloud. The few frames where the tiles
    canvas draws empty during the flip's rebuild are cut (133 ms each time; said in the report)."""
    c = Clip("hybrid")
    rg = regions(WORK / "hybrid/home.json")
    panel = rg["stage-panel"]
    inner = [panel[0] + 80, panel[1] + 80, panel[2] - 160, panel[3] - 160]
    flips = []
    t = 3.0
    for _ in range(2):
        t = onset(c.raw, t + 1.0, before=0.0, after=8.0, least=2000) + 1 / FPS  # (the first changed frame)
        b = blank_run(c.raw, t - 0.1, t + 0.5, inner)
        flips.append((t, b))
        t = (b[1] if b else t) + 0.5
    (f1, b1), (f2, b2) = flips
    skip1 = (b1[0] - 0.5 / FPS, b1[1] + 0.5 / FPS) if b1 else (f1, f1)
    skip2 = (b2[0] - 0.5 / FPS, b2[1] + 0.5 / FPS) if b2 else (f2, f2)
    pill = cam_fit([800 * SCALE, 0, 480 * SCALE, 300 * SCALE], pad=0.0)  # the top bar's right end: the lane pill, Switch lane
    start = f1 - 1.4
    c.seg(start, skip1[0])
    o_on = c.t
    c.seg(skip1[1], skip2[0])
    o_off = c.t
    c.seg(skip2[1], skip2[1] + 1.4)
    c.cam(0, FULL)
    c.cam(o_on + 1.6, FULL)
    c.cam(o_on + 2.4, pill)
    c.cam(o_off - 1.0, pill)
    c.cam(o_off - 0.1, FULL)
    sw = (1205 * SCALE, 33 * SCALE)  # "Switch lane" in the top bar (points: the test button after the lane pill)
    c.taps = [(skip1[1], *sw), (skip2[1], *sw)]
    c.cap(o_on + 0.1, o_on + 1.4, "One tap hands the turn to the cloud: an orange frame", top=True)  # (the orb below turns too;
    # top, and only while wide: the push-in lands on the pill, at the top)
    c.cap(o_off + 0.1, c.t - 0.3, "Back on this machine", top=True)
    c.loop = 0.3
    c.blank = inner
    c.poster_t = o_on + 3.0
    c.checks = {"1-local": 0.3, "2-tap": o_on - 0.1, "3-cloud": o_on + 0.1, "4-cloud-wide": o_on + 0.8, "5-pill": o_on + 3.0,
                "6-back": o_off + 0.1, "7-end": c.t - 0.4}
    print(f"hybrid: flips {f1:.2f} (blank {b1}), {f2:.2f} (blank {b2})", flush=True)
    c.render(WORK / "hybrid/check")


EDITS["hybrid"] = edit_hybrid

# ------------------------------------------------------------------------------------------------------------------ main


def main():
    args = sys.argv[1:]
    verb = args[0] if args and args[0] in ("take", "edit", "all") else "all"
    names = [a for a in args if a in NAMES] or COVER
    for n in names:
        if verb in ("take", "all"):
            take(n)
        if verb in ("edit", "all"):
            EDITS[n]()


if __name__ == "__main__":
    main()
