# mojoui.orb: the liquid orb of a voice app (goal 72 M4): one drawn ball that listens, thinks and speaks, and the rim that
# says a cloud model is answering. Both are Canvases the app's draw() paints; their sizes and colours come from here and
# the palette (the accent, the theme's data colours, its warning tone), never from the app.
#
#   Orb:   self.orb.mode(ORB_LISTEN); self.orb.drive(mic.level() * 6.0)      update(): what it is doing and how loud
#          OrbView(ORB_CANVAS, self.orb.version(), big=True)                  view(): big fills the room it is given, small sits beside words
#          draw(): self.orb.draw(surface, palette)                              springs step by the time since the last draw
#   Rim:   RimView(RIM_CANVAS, version) over the page (Overlay)  ·  draw_rim(surface, palette, on)
#
# The motion is Liquid's: the loudness, the size and the colour are springs (mojoui.spring), so the orb swells with a
# voice and settles without a bounce; three overlapping blobs drift on a slow phase so it reads as one liquid body. When
# the canvas changes size (Home's big orb becomes the work screen's small one) the radius is a spring too, so it shrinks
# into place instead of jumping. draw() asks for the next frame while anything moves (the breathing never stops).
# Drawing is straight-alpha over a see-through canvas (`passthrough`): the page shows round it.

from std.math import sin, cos, sqrt
from mojoui.canvas import Surface
from mojoui.clock import now_ns
from mojoui.draw import over
from mojoui.spring import Spring
from mojoui.theme import Palette, mix
from mojoui.view import View, Canvas

comptime ORB_IDLE = 0  # resting: a slow breath
comptime ORB_LISTEN = 1  # swelling with the voice it hears
comptime ORB_THINK = 2  # contracted, three points circling it
comptime ORB_SPEAK = 3  # swelling with its own voice
comptime ORB_WHITE: UInt32 = 0xFFFFFFFF
comptime ORB_MAX_RADIUS = 190.0  # pixels: what one frame of drawing can afford on the CPU path
comptime SMALL_SIDE = 84  # points: the orb beside words


def _paint(mut s: Surface, x: Int, y: Int, color: UInt32, cov: Float64):
    if 0 <= x < s.width and 0 <= y < s.height and cov > 0.0:
        var p = s.pixels().unsafe_offset(y * s.width + x)
        p[] = over(p[], color, min(cov, 1.0))


def soft_disc(mut s: Surface, cx: Float64, cy: Float64, radius: Float64, color: UInt32, soft: Float64 = 1.0):
    """A disc whose edge fades over `soft` pixels (1: crisp, radius: a glow that is brightest at the centre), straight-alpha
    over what is there (a see-through canvas stays see-through round it)."""
    var edge = max(soft, 1.0)
    var x0 = max(Int(cx - radius - 1), 0)
    var x1 = min(Int(cx + radius + 2), s.width)
    var y0 = max(Int(cy - radius - 1), 0)
    var y1 = min(Int(cy + radius + 2), s.height)
    for py in range(y0, y1):
        for px in range(x0, x1):
            var ex = Float64(px) + 0.5 - cx
            var ey = Float64(py) + 0.5 - cy
            var d = sqrt(ex * ex + ey * ey)
            var cov = (radius + 0.5 - d) / edge
            if cov > 0:
                _paint(s, px, py, color, min(cov, 1.0))


def _tone(color: UInt32, alpha: Float64) -> UInt32:
    return (color & 0x00FFFFFF) | (UInt32(Int(min(max(alpha, 0.0), 1.0) * 255.0 + 0.5)) << 24)


struct Orb(Movable):
    var _mode: Int
    var loud: Spring  # the voice's loudness, 0…1 (smoothed: a syllable swells it, silence lets it settle)
    var calm: Spring  # 1 while thinking: contracts the body and brings the circling points in
    var radius: Spring  # pixels; follows the canvas's size, so a layout change morphs
    var cloud: Spring  # 1 while a cloud model speaks: the colour moves to the warning tone
    var phase: Float64
    var last_ns: Int
    var stamp: Int
    var placed: Bool

    def __init__(out self):
        self._mode = ORB_IDLE
        self.loud = Spring(0.0, 120.0, 17.0)
        self.calm = Spring(0.0, 90.0, 19.0)
        self.radius = Spring(0.0, 140.0, 22.0)
        self.cloud = Spring(0.0, 90.0, 19.0)
        self.phase = 0.0
        self.last_ns = 0
        self.stamp = 0
        self.placed = False

    def mode(mut self, m: Int):
        if m != self._mode:
            self._mode = m
            self.stamp += 1
            self.calm.to(1.0 if m == ORB_THINK else 0.0)

    def current(self) -> Int:
        return self._mode

    def drive(mut self, level: Float64):
        """How loud the voice is now (0…1: Microphone.level() × a few, or the speaker's own level)."""
        self.loud.to(min(max(level, 0.0), 1.0) if self._mode == ORB_LISTEN or self._mode == ORB_SPEAK else 0.0)

    def lane(mut self, cloud: Bool):
        self.cloud.to(1.0 if cloud else 0.0)

    def version(self) -> Int:
        """A Canvas version that moves when the mode does (the orb itself keeps asking for frames)."""
        return self.stamp

    def draw(mut self, mut s: Surface, p: Palette):
        s.fill(0)  # (every frame from clear: the canvas keeps what was drawn, and the glow would pile up)
        var now = now_ns()
        var dt = Float64(now - self.last_ns) / 1e9 if self.last_ns > 0 else 0.016
        self.last_ns = now
        _ = self.loud.step(Int(dt * 1e6))
        _ = self.calm.step(Int(dt * 1e6))
        _ = self.cloud.step(Int(dt * 1e6))
        self.phase += dt * (0.7 + 1.6 * self.calm.value)
        var fit = min(Float64(s.width), Float64(s.height)) * 0.30
        var base = min(fit, ORB_MAX_RADIUS)
        if not self.placed:
            self.radius.snap(base)
            self.placed = True
        self.radius.to(base)
        _ = self.radius.step(Int(dt * 1e6))
        var cx = Float64(s.width) / 2.0
        var cy = Float64(s.height) / 2.0
        var breath = 0.035 * sin(self.phase * 1.3)
        var r = self.radius.value * (1.0 + breath + 0.32 * self.loud.value - 0.18 * self.calm.value)
        var accent = mix(p.accent, p.warn, self.cloud.value)
        var cool = mix(accent, p.series[2] if len(p.series) > 2 else p.accent, 0.55)
        var light = mix(accent, ORB_WHITE, 0.30)
        var wob = 0.10 * r * (0.6 + self.loud.value)
        var halo = min(r * 1.9, 0.5 * min(Float64(s.width), Float64(s.height)))  # (a glow that fades out before the canvas's edge)
        soft_disc(s, cx, cy, halo, _tone(accent, 0.34 + 0.22 * self.loud.value), halo)
        soft_disc(s, cx + wob * sin(self.phase), cy + wob * cos(self.phase * 0.9), r, _tone(accent, 0.86), 1.5)
        soft_disc(s, cx + wob * sin(self.phase + 2.1), cy + wob * cos(self.phase * 1.1 + 2.1), r * 0.96, _tone(cool, 0.55), 1.5)
        soft_disc(s, cx + wob * sin(self.phase + 4.2), cy + wob * cos(self.phase * 0.8 + 4.2), r * 0.92, _tone(light, 0.40), 1.5)
        soft_disc(s, cx - 0.30 * r, cy - 0.36 * r, 0.45 * r, _tone(ORB_WHITE, 0.30), 0.45 * r)
        if self.calm.value > 0.02:  # thinking: three points circle it
            for k in range(3):
                var a = self.phase * 1.6 + Float64(k) * 2.0944
                soft_disc(s, cx + 1.4 * r * cos(a), cy + 1.4 * r * sin(a), 0.07 * r, _tone(light, 0.9 * self.calm.value), 1.5)
        s.again = True  # (it breathes: the host draws it again next frame)


def OrbView(canvas: Int, version: Int, big: Bool = True) -> View:
    """The orb's Canvas: `big` takes the room it is given (Home), else it is a small one beside words (the work screen)."""
    if big:
        return Canvas(canvas, version).passthrough().grow().fill().tag("orb")
    return Canvas(canvas, version).passthrough().width(SMALL_SIDE).height(SMALL_SIDE).tag("orb-small")


def draw_rim(mut s: Surface, p: Palette, on: Bool):
    """A frame round the whole canvas in the warning tone, brightest at the edge and fading inward (`on`: a cloud model is
    answering; off paints nothing). Pixels: a band 4 points wide plus a 14 points glow."""
    s.fill(0)
    if not on:
        return
    var edge = Int(4.0 * s.scale)
    var glow = Int(18.0 * s.scale)
    var w = s.width
    var h = s.height
    for y in range(h):
        var full = y < glow or y >= h - glow  # (the top and bottom bands run the whole row; the middle only its two ends)
        for pass_ in range(2):
            var from_x = 0 if (full or pass_ == 0) else w - glow
            var to_x = (w if full else glow) if pass_ == 0 else w
            if full and pass_ == 1:
                break
            for x in range(from_x, to_x):
                var d = min(min(x, w - 1 - x), min(y, h - 1 - y))
                if d >= glow:
                    continue
                var cov = 0.95 if d < edge else 0.38 * Float64(glow - d) / Float64(glow - edge)
                _paint(s, x, y, _tone(p.warn, cov), 1.0)


def RimView(canvas: Int, version: Int) -> View:
    """The cloud frame's Canvas, over the whole page (put it last in an Overlay): presses go through to the page."""
    return Canvas(canvas, version).passthrough().fill().tag("rim")
