# Particles: a million points (up to twenty million) pulled by your pointer, stepped and drawn on the GPU.
#
# The whole app is this file (showcase/SPEC.md): `advance` is one particle's physics, `place` and `tint` are where
# it lands on screen and the light it adds. mojoui.gpu runs all three as GPU kernels (one thread per particle),
# the points never leave the GPU between frames, and the picture is copied once into the Canvas each frame.
# Press and drag on the field to pull the particles; let go and the attractor goes back to circling.
#
# Scripted (for measuring): particles --scripted --n 10000 --frames 120 [--out DIR] (or PARTICLES_SCRIPTED=1,
# PARTICLES_N, PARTICLES_FRAMES, PARTICLES_OUT): no input, the attractor follows c(t), then DIR/positions.bin
# (N × 2 float32) and DIR/timings.json (per frame: total = frame to frame, work = step + splat + the copy to the CPU,
# one GPU wait a frame; then a separate measurement pass of as many frames, each part waited for on its own:
# step, splat = the GPU's draw, readback = the picture's copy to the CPU).

from std.sys import argv, exit
from std.os import getenv

from mojoui.maths import sqrt, cos, sin
from mojoui import (
    App, Event, View, Surface, VStack, HStack, Text, Slider, Canvas, Spacer,
    HEADLINE, CAPTION, CENTER, PAN, PRESS, RELEASE, TAP,
)
from mojoui.gpu import PointCloud, Point, Knobs, OUTSIDE
from mojoui.clock import now_ns
from mojoui.theme import Theme
from themes.omxqua import omxqua

comptime GESTURE = 1
comptime FRAME = 2
comptime COUNT = 3

comptime W = 1280  # the field, in points (SPEC: 1280 × 720; world [-1.6, 1.6] × [-0.9, 0.9])
comptime H = 720
comptime BAR = 52  # the bar above the field
comptime DT = Float32(1.0 / 60.0)
comptime SIZES: List[Int] = [1_000_000, 2_000_000, 5_000_000, 10_000_000, 20_000_000]


# ---------- one particle: p = (x, y, vx, vy); k = (attractor x, y, dt, brightness, …) ----------

def advance(p: Point, k: Knobs) -> Point:
    var dx = k[0] - p[0]
    var dy = k[1] - p[1]
    var s = Float32(0.5) / (dx * dx + dy * dy + Float32(0.01))
    var vx = p[2] * Float32(0.985) + dx * s * k[2]
    var vy = p[3] * Float32(0.985) + dy * s * k[2]
    return Point(p[0] + vx * k[2], p[1] + vy * k[2], vx, vy)


def place(p: Point, w: Int, h: Int, k: Knobs) -> Int:
    var px = (p[0] + Float32(1.6)) * (Float32(w) / Float32(3.2))
    var py = (Float32(0.9) - p[1]) * (Float32(h) / Float32(1.8))
    if px < 0 or py < 0 or px >= Float32(w) or py >= Float32(h):
        return OUTSIDE
    return Int(py) * w + Int(px)


def tint(p: Point, k: Knobs) -> SIMD[DType.float32, 4]:
    """Deep indigo (#3b2bd6) when slow, white at |v| ≥ 1.5, times the brightness k[3]."""
    var t = min(sqrt(p[2] * p[2] + p[3] * p[3]) / Float32(1.5), Float32(1))
    var slow = SIMD[DType.float32, 4](59.0 / 255.0, 43.0 / 255.0, 214.0 / 255.0, 0)
    return (slow + (SIMD[DType.float32, 4](1, 1, 1, 0) - slow) * t) * k[3]


# ---------- the seed (SPEC: xorshift32 from 42, x then y per particle, v = 0) ----------

def seeded(n: Int, use_gpu: Bool = True) -> PointCloud:
    var pts = List[Float32](length=4 * n, fill=0)
    var s = UInt32(42)
    for i in range(2 * n):
        s ^= s << 13
        s ^= s >> 17
        s ^= s << 5
        pts[4 * (i // 2) + (i % 2)] = Float32(s >> 8) * Float32(1.0 / 16777216.0) * 2 - 1
    return PointCloud(pts^, use_gpu=use_gpu)


def orbit(frame: Int) -> Tuple[Float32, Float32]:
    """The scripted attractor c(t) = 0.5 (cos t, sin t), t = frame × dt (dt as float32, like the reference)."""
    var t = Float64(frame) * Float64(DT)
    return (Float32(0.5 * cos(t)), Float32(0.5 * sin(t)))


# ---------- formatting ----------

def millions(n: Int) -> String:
    return String(n // 1_000_000) + "M" if n % 1_000_000 == 0 else String(n)


def fixed(x: Float64, places: Int) -> String:
    var scale = 10 ** places
    var v = Int(abs(x) * Float64(scale) + 0.5)
    var frac = String(v % scale)
    while frac.byte_length() < places:
        frac = "0" + frac
    return String(v // scale) + ("." + frac if places > 0 else "")


def json_list(xs: List[Float64]) -> String:
    var out = String("[")
    for i in range(len(xs)):
        out += ("," if i > 0 else "") + fixed(xs[i], 4)
    return out + "]"


# ---------- scripted mode ----------

def flag(name: String, env: String, fallback: String) -> String:
    var args = argv()
    for i in range(len(args)):
        if String(args[i]) == name:
            return String(args[i + 1]) if i + 1 < len(args) and not String(args[i + 1]).startswith("--") else "1"
    var v = getenv(env)
    return v if v != "" else fallback


def number(s: String, fallback: Int) -> Int:
    try:
        return Int(s)
    except:
        return fallback


# ---------- the app ----------

struct Main(App):
    var cloud: PointCloud
    var size: Int  # index into SIZES (the slider's stop)
    var n: Int
    var frame: Int  # steps taken
    var holding: Bool  # the pointer is down on the field: it is the attractor
    var cx: Float32
    var cy: Float32
    var fps: Float64
    var step_ms: Float64
    var shown_fps: Float64  # what the readout says (refreshed four times a second, so it can be read)
    var shown_step: Float64
    var shown_at: Int
    var started: Int  # this frame's start (now_ns), for work and total
    var last_start: Int
    var drawn_once: Bool
    var undrawn: Bool  # a step not drawn yet
    # scripted
    var scripted: Bool
    var frames: Int
    var out: String
    var positions: Bool  # --positions 0: don't write positions.bin (benchmarks: no 8N-byte copy at the end)
    var totals: List[Float64]
    var steps: List[Float64]
    var works: List[Float64]

    def __init__(out self):
        self.scripted = flag("--scripted", "PARTICLES_SCRIPTED", "") != ""
        self.n = number(flag("--n", "PARTICLES_N", "1000000"), 1_000_000)
        self.frames = number(flag("--frames", "PARTICLES_FRAMES", "600"), 600)
        self.out = flag("--out", "PARTICLES_OUT", ".")
        self.positions = flag("--positions", "PARTICLES_POSITIONS", "1") != "0"
        var sizes = materialize[SIZES]()
        self.size = 0
        for i in range(len(sizes)):
            if sizes[i] <= self.n:
                self.size = i
        self.cloud = seeded(self.n)
        self.frame = 0
        self.holding = False
        var c = orbit(0)
        self.cx = c[0]
        self.cy = c[1]
        self.fps = 0
        self.step_ms = 0
        self.shown_fps = 0
        self.shown_step = 0
        self.shown_at = 0
        self.started = 0
        self.last_start = 0
        self.drawn_once = False
        self.undrawn = False
        self.totals = List[Float64]()
        self.steps = List[Float64]()
        self.works = List[Float64]()

    def title(self) -> String:
        return "Particles"

    def window_size(self) -> Tuple[Int, Int]:
        return (W, H + BAR)

    def theme(self) -> Theme:
        return omxqua(True)  # a black field: omxqua at night, whatever the desktop says

    def brightness(self) -> Float32:
        """Each particle's light: a sixteenth of full at 1M, dimmer as the field gets denser, so the core still has shape."""
        return Float32(0.06 * sqrt(1_000_000.0 / Float64(max(self.n, 1))))

    def knobs(self) -> Knobs:
        return Knobs(self.cx, self.cy, DT, self.brightness(), 0, 0, 0, 0)

    def to_world(mut self, x: Float64, y: Float64):
        self.cx = Float32(x / Float64(W) * 3.2 - 1.6)
        self.cy = Float32(0.9 - y / Float64(H) * 1.8)

    def update(mut self, event: Event):
        if event.message == FRAME:
            if self.scripted and (self.frame >= self.frames or self.undrawn):
                return  # (scripted: one step per drawn frame, so every step's work is measured)
            var t0 = now_ns()
            if self.last_start > 0:
                var seconds = Float64(t0 - self.last_start) / 1e9
                self.fps = 1.0 / seconds if self.fps == 0 else 0.9 * self.fps + 0.1 / seconds
                if self.scripted:
                    self.totals.append(seconds * 1000.0)
            elif self.scripted:
                self.totals.append(Float64(event.number) / 1000.0)
            self.last_start = t0
            self.started = t0
            if not self.holding:
                var c = orbit(self.frame)
                self.cx = c[0]
                self.cy = c[1]
            # Queued, not waited for: draw()'s splat waits once for both. The readout's step time comes from one
            # timed step four times a second (never in scripted runs: finish() measures the step on its own pass).
            var show = t0 - self.shown_at > 250_000_000
            self.cloud.step[advance](self.knobs(), timed=show and not self.scripted)
            self.frame += 1
            self.undrawn = True
            if show:
                self.shown_at = t0
                self.shown_fps = self.fps
                if not self.scripted:
                    self.step_ms = self.cloud.milliseconds
                    self.shown_step = self.step_ms
        elif event.message == GESTURE and not self.scripted:
            if event.number == PRESS or event.number == PAN:
                self.holding = True
                self.to_world(event.x, event.y)
            elif event.number == RELEASE or event.number == TAP:
                self.holding = False
        elif event.message == COUNT and not self.scripted:
            var stop = min(max((event.number + 12) // 25, 0), 4)
            if stop != self.size:
                self.size = stop
                self.n = materialize[SIZES]()[stop]
                self.cloud = seeded(self.n)
                self.frame = 0
                self.fps = 0
                self.last_start = 0

    def draw(mut self, canvas: Int, mut surface: Surface):
        self.cloud.splat[place, tint](surface, self.knobs())
        surface.again = True  # (the field always moves: the host draws it again next frame, no version to bump)
        if not self.drawn_once:
            self.drawn_once = True
            print("particles: first frame", flush=True)
        if self.scripted and self.undrawn:
            self.works.append(Float64(now_ns() - self.started) / 1e6)
            if len(self.works) == self.frames:
                self.finish()
        self.undrawn = False

    def finish(mut self):
        """Scripted: positions after `frames` steps, the timings, then quit."""
        var xy = List[Float32]()
        if self.positions:
            self.cloud.download()  # (the GPU's points into the cloud's own CPU copy: no second copy of all of them)
            xy = List[Float32](length=2 * self.n, fill=0)
            for i in range(self.n):
                xy[2 * i] = self.cloud.host[4 * i]
                xy[2 * i + 1] = self.cloud.host[4 * i + 1]
        try:
            if self.positions:
                with open(self.out + "/positions.bin", "w") as f:
                    f.write_bytes(Span(unsafe_ptr=xy.unsafe_ptr().bitcast[UInt8](), length=8 * self.n))
            var parts = self.measure()
            with open(self.out + "/timings.json", "w") as f:
                f.write(
                    '{"n": ' + String(self.n) + ', "frames": ' + String(self.frames) + ', "device": "'
                    + self.cloud.device_name() + '",\n "total": ' + json_list(self.totals) + ',\n "work": '
                    + json_list(self.works) + ',\n "measured_separately": "step, splat, readback: a second pass, each waited for",\n "step": '
                    + json_list(self.steps) + ',\n "splat": ' + json_list(parts[0]) + ',\n "readback": ' + json_list(parts[1]) + "}\n"
                )
        except e:
            print("particles: couldn't write the results: " + String(e))
            exit(1)
        _ = len(xy)
        print("particles: wrote " + self.out + "/positions.bin and timings.json", flush=True)
        exit(0)

    def measure(mut self) -> Tuple[List[Float64], List[Float64]]:
        """Scripted, after the positions are saved: `frames` more frames into a scratch picture, each part waited for on
        its own (the frame loop waits once a frame, so it can't split them): steps, then (splat GPU ms, readback ms)."""
        var pixels = List[UInt32](length=W * H, fill=0)
        var surface = Surface(Int(pixels.unsafe_ptr()), W, H, 1.0)
        var splats = List[Float64]()
        var reads = List[Float64]()
        for _ in range(self.frames):
            var c = orbit(self.frame)
            self.cx = c[0]
            self.cy = c[1]
            self.cloud.step[advance](self.knobs(), timed=True)
            self.steps.append(self.cloud.milliseconds)
            self.cloud.splat[place, tint](surface, self.knobs(), timed=True)
            splats.append(self.cloud.splat_ms)
            reads.append(self.cloud.readback_ms)
            self.frame += 1
        _ = len(pixels)
        return (splats^, reads^)

    def view(self) -> View:
        # One bar above the field, not islands over it: the field is the whole picture, and nothing has to be
        # composited over it every frame (islands cost ~4 ms a frame on a software renderer, scripts/headless.py).
        var readout = (
            millions(self.n) + " particles · " + fixed(self.shown_fps, 0) + " fps · step " + fixed(self.shown_step, 2)
            + " ms on " + self.cloud.device_name()
        )
        var bar = HStack(
            Text("Particles", style=HEADLINE),
            Text(readout, style=CAPTION),
            Spacer(),
            Text("Press and drag to pull", style=CAPTION),
            Text("Count", style=CAPTION),
            Slider(self.size * 25, on_change=COUNT).width(200),
            Text(millions(self.n), style=HEADLINE).width(40),
            spacing=14,
        ).padding(10, 18).height(BAR).align(CENTER).fill()
        return VStack(
            bar^,
            Canvas(0, 0, on_gesture=GESTURE, on_frame=FRAME).width(W).height(H),
            spacing=0,
        ).grow().fill()
