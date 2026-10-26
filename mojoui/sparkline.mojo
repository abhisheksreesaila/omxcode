# mojoui.sparkline (goal 33 M4, D-356): the OMX Console's small charts, drawn on a Canvas. No axes, no labels.
#   Sparkline: model-page.js's areaChart: a 1.8 px line (round joins and ends, the same width at any size) over its
#     area at 12 % of the colour; the scale runs from 0 (or the lowest value, if below 0) to the highest; fewer than two
#     points draw a flat line at the bottom in the quiet ink, with no area.
#   BarTrack: blade-bench.js's bar: a track in the line colour, corners 4, filled to value / largest value (an honest
#     zero baseline); "this model" gets a 1 px ring in the ink.
#
#   var spark = Sparkline(points, colour, quiet)      # or Sparkline.themed(points, palette)
#   spark.draw(surface)                               # in App.draw() for its canvas
#   SparklineView(SPARK_CANVAS, version)              # the view: a Canvas 76 high that fills its width

from mojoui.canvas import Surface, rgba
from mojoui.draw import line, area, rect, with_alpha
from mojoui.theme import Palette, Look
from mojoui.view import View, Canvas

comptime BOX_W = 600.0  # the original's viewBox (600 × 84), stretched to the canvas (preserveAspectRatio none)
comptime BOX_H = 84.0
comptime SPARK_HEIGHT = 76  # .area { height: 76px }
comptime STROKE = 1.8  # stroke-width 1.8, vector-effect non-scaling-stroke: points, whatever the size
comptime AREA_ALPHA = 0.12
comptime BAR_HEIGHT = 12  # .bn-tr { height: 12px }
comptime BAR_RADIUS = 4.0  # .prog and .prog > i: border-radius 4px


def spark_points(values: List[Float64], width: Float64, height: Float64) -> List[Float64]:
    """The line's points in a `width` × `height` box, as x0, y0, x1, y1…: x spread evenly from 0 to width; y from
    the original's viewBox (4 from its bottom for the lowest, 6 from its top for the highest) scaled to the box.
    Fewer than two values: two points on the bottom line (the original's [0, 0])."""
    var pts = values.copy() if len(values) > 1 else [0.0, 0.0]
    var hi = pts[0]
    var lo = min(pts[0], 0.0)
    for v in pts:
        hi = max(hi, v)
        lo = min(lo, v)
    var span = hi - lo if hi - lo != 0 else 1.0
    var out = List[Float64]()
    var n = len(pts)
    for i in range(n):
        out.append(Float64(i) / Float64(n - 1) * width)
        out.append((BOX_H - 4 - (pts[i] - lo) / span * (BOX_H - 10)) * height / BOX_H)
    return out^


@fieldwise_init
struct Sparkline(Copyable, Movable):
    var values: List[Float64]
    var color: UInt32  # the line, and the area at 12 %
    var quiet: UInt32  # the flat line when there is nothing to show (--faint)

    @staticmethod
    def themed(values: List[Float64], p: Palette, series: Int = 0) -> Sparkline:
        """In the palette's `series` colour, quiet in its ink3."""
        return Sparkline(values.copy(), p.series[series % len(p.series)], p.ink3)

    @staticmethod
    def signal(values: List[Float64], look: Look, p: Palette, k: Int = 1) -> Sparkline:
        """In the look's k-th signal colour (role signal-dot-<k>: a thing's own colour), quiet in the palette's ink3."""
        var at = look.surface("signal-dot-" + String(k))
        return Sparkline(values.copy(), look.surfaces[at].fill if at >= 0 else p.series[0], p.ink3)

    def live(self) -> Bool:
        return len(self.values) > 1

    def draw(self, mut s: Surface):
        """The area, then the line, over whatever the surface holds (the card's fill)."""
        var w = Float64(s.width)
        var h = Float64(s.height)
        var pts = spark_points(self.values, w, h)
        var xs = List[Float64]()
        var ys = List[Float64]()
        for i in range(0, len(pts), 2):
            xs.append(pts[i])
            ys.append(pts[i + 1])
        if self.live():
            var tint = with_alpha(self.color, AREA_ALPHA)
            area(s, xs, ys, h, tint, tint)
        var ink = self.color if self.live() else self.quiet
        for i in range(len(xs) - 1):
            line(s, xs[i], ys[i], xs[i + 1], ys[i + 1], STROKE * s.scale, ink)


def SparklineView(canvas: Int, version: Int, height: Int = SPARK_HEIGHT) -> View:
    """A canvas `height` points high that fills its width; the app's draw() paints a Sparkline into it."""
    return Canvas(canvas, version).height(height).fill().tag("sparkline")


# ---------- bars ----------

def bar_fractions(values: List[Float64]) -> List[Float64]:
    """Each value over the largest (0 when nothing is above 0): a bar's length."""
    var top = 0.0
    for v in values:
        top = max(top, v)
    var out = List[Float64]()
    for v in values:
        out.append(v / top if top > 0 else 0.0)
    return out^


def bar_order(values: List[Float64], names: List[String], lower_is_better: Bool) -> List[Int]:
    """The rows best first: largest first (smallest when lower is better), ties by name. The first is the best."""
    var idx = List[Int]()
    for i in range(len(values)):
        idx.append(i)
    for i in range(1, len(idx)):  # (insertion sort: a handful of models)
        var k = idx[i]
        var j = i - 1
        while j >= 0 and _before(values, names, lower_is_better, k, idx[j]):
            idx[j + 1] = idx[j]
            j -= 1
        idx[j + 1] = k
    return idx^


def _before(values: List[Float64], names: List[String], lower: Bool, a: Int, b: Int) -> Bool:
    if values[a] != values[b]:
        return values[a] < values[b] if lower else values[a] > values[b]
    return names[a] < names[b]


@fieldwise_init
struct BarTrack(Copyable, Movable):
    var fraction: Float64  # 0–1
    var fill: UInt32  # the bar
    var track: UInt32  # what is left (--oq-line)
    var ring: UInt32  # a 1 px ring inside the track's edge (this model: the ink), 0 for none

    @staticmethod
    def themed(fraction: Float64, p: Palette, me: Bool = False) -> BarTrack:
        """The accent's bar on the line colour (omxqua's .prog; the console's own --mc loses to it, as recorded)."""
        return BarTrack(fraction, p.accent, p.line_strong, p.ink if me else 0)

    def draw(self, mut s: Surface):
        var w = Float64(s.width)
        var h = Float64(s.height)
        var r = BAR_RADIUS * s.scale
        rect(s, 0, 0, w, h, self.track, r)
        if self.ring != 0:
            var t = s.scale
            rect(s, 0, 0, w, h, self.ring, r)
            rect(s, t, t, w - 2 * t, h - 2 * t, self.track, max(r - t, 0.0))
        var f = min(max(self.fraction, 0.0), 1.0)
        rect(s, 0, 0, w * f, h, self.fill, r)


def BarView(canvas: Int, version: Int, height: Int = BAR_HEIGHT) -> View:
    """A canvas `height` points high that takes the free width of its row; the app's draw() paints a BarTrack."""
    return Canvas(canvas, version).height(height).grow().tag("bar")
