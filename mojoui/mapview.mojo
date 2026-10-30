# mojoui.mapview: a small map drawn on a Canvas (goal 39 M8). A generic component: a route (a flight, a drive, a walk)
# as a line on the ground, places on it as marks (assets, findings, stops: a tone and a size each), and where the
# recording is now as a dot. No tiles, no network: the ground is the canvas's own tonal surface, north up, metres to
# scale (a scale bar says how many), so it works offline on every host.
#
#   var map = MapView(lats, lons)                         # the route (degrees), in order
#   map.mark(52.0103, 5.1204, "P02", MARK_PLACE)          # a place: a ring and its name
#   map.mark(52.0103, 5.1204, "", MARK_FINDING, 3)        # a finding: a dot sized by its level (1…5)
#   map.at(52.0105, 5.1207)                               # the dot: where the recording is now
#   draw():  map.draw(surface, font, palette)             # fits the route and the marks to the canvas
#   map.describe()                                        # for an agent: the route's extent, the marks, the dot
#
# The projection is a local flat earth (east and north metres from the route's middle, mojoui.geo's), good over a few
# kilometres; a tiled basemap would replace draw()'s ground only. Colours come from the palette: the route in the
# accent's tint (flown so far in the accent), places in the secondary ink, findings in the palette's `bad` tone (no
# colour of its own), the dot in the accent with a card-coloured ring.

from std.math import cos, pi, log10, floor
from mojoui.canvas import Surface
from mojoui.draw import rect, line, circle, with_alpha, blend
from mojoui.text import Font, MEDIUM, REGULAR, LEFT, CENTRE, RIGHT
from mojoui.theme import Palette
from mojoui.charts import fixed

comptime MARK_PLACE = 0  # a ring and its name
comptime MARK_FINDING = 1  # a filled dot in the bad tone, sized by level
comptime M_PER_DEG = 111320.0


@fieldwise_init
struct MapMark(Copyable, Movable, ImplicitlyCopyable):
    var lat: Float64
    var lon: Float64
    var label: String
    var kind: Int
    var level: Int


struct MapView(Copyable, Movable):
    var lats: List[Float64]
    var lons: List[Float64]
    var marks: List[MapMark]
    var dot_lat: Float64
    var dot_lon: Float64
    var has_dot: Bool
    var upto: Int  # route points flown so far (the dot's place along it): drawn in the accent

    def __init__(out self, var lats: List[Float64], var lons: List[Float64]):
        self.lats = lats^
        self.lons = lons^
        self.marks = List[MapMark]()
        self.dot_lat = 0
        self.dot_lon = 0
        self.has_dot = False
        self.upto = 0

    def mark(mut self, lat: Float64, lon: Float64, label: String, kind: Int = MARK_PLACE, level: Int = 1):
        self.marks.append(MapMark(lat, lon, label, kind, level))

    def at(mut self, lat: Float64, lon: Float64, upto: Int = -1):
        """The dot (where the recording is now); `upto`: how many route points lead up to it (-1: the nearest one's)."""
        self.dot_lat = lat
        self.dot_lon = lon
        self.has_dot = True
        if upto >= 0:
            self.upto = upto
        else:
            var best = 1e300
            for i in range(len(self.lats)):
                var d = (self.lats[i] - lat) ** 2 + ((self.lons[i] - lon) * cos(lat * pi / 180.0)) ** 2
                if d < best:
                    best = d
                    self.upto = i + 1

    def bounds(self) -> Tuple[Float64, Float64, Float64, Float64]:
        """lat_lo, lat_hi, lon_lo, lon_hi over the route and the marks."""
        var a = 1e300
        var b = -1e300
        var c = 1e300
        var d = -1e300
        for i in range(len(self.lats)):
            a = min(a, self.lats[i])
            b = max(b, self.lats[i])
            c = min(c, self.lons[i])
            d = max(d, self.lons[i])
        for ref m in self.marks:
            a = min(a, m.lat)
            b = max(b, m.lat)
            c = min(c, m.lon)
            d = max(d, m.lon)
        if a > b:
            return (0.0, 0.0, 0.0, 0.0)
        return (a, b, c, d)

    def projection(self, width: Float64, height: Float64, pad: Float64) -> Tuple[Float64, Float64, Float64, Float64, Float64]:
        """(lat0, lon0, metres → pixels, centre x, centre y): the route and marks fitted into width × height less pad,
        the same scale both ways (metres are metres)."""
        var bb = self.bounds()
        var lat0 = (bb[0] + bb[1]) / 2
        var lon0 = (bb[2] + bb[3]) / 2
        var k_lon = M_PER_DEG * cos(lat0 * pi / 180.0)
        var span_e = max((bb[3] - bb[2]) * k_lon, 1.0)
        var span_n = max((bb[1] - bb[0]) * M_PER_DEG, 1.0)
        var scale = min((width - 2 * pad) / span_e, (height - 2 * pad) / span_n)
        return (lat0, lon0, max(scale, 1e-6), width / 2, height / 2)

    def to_xy(self, p: Tuple[Float64, Float64, Float64, Float64, Float64], lat: Float64, lon: Float64) -> Tuple[Float64, Float64]:
        var k_lon = M_PER_DEG * cos(p[0] * pi / 180.0)
        var e = (lon - p[1]) * k_lon
        var n = (lat - p[0]) * M_PER_DEG
        return (p[3] + e * p[2], p[4] - n * p[2])

    def draw(self, mut s: Surface, font: Font, pal: Palette):
        var k = s.scale
        var w = Float64(s.width)
        var h = Float64(s.height)
        s.fill(pal.card)  # (opaque first: drawing blends over what's there and keeps its alpha)
        rect(s, 0, 0, w, h, pal.raised, 12 * k)  # (the ground: a tonal surface, rounded as the card's content is)
        if len(self.lats) < 2:
            font.draw(s, "No route", w / 2, h / 2, 12 * k, pal.ink3, REGULAR, CENTRE)
            return
        var p = self.projection(w, h, 30 * k)
        # a faint 50-ish metre grid: the ground has a scale before anything is on it
        var step_m = nice_step(Float64(w) / p[2] / 4)
        var step_px = step_m * p[2]
        if step_px > 12 * k:
            var gx = p[3] - floor(p[3] / step_px) * step_px
            while gx < w:
                line(s, gx, 0, gx, h, 1 * k, with_alpha(pal.line, 0.7))
                gx += step_px
            var gy = p[4] - floor(p[4] / step_px) * step_px
            while gy < h:
                line(s, 0, gy, w, gy, 1 * k, with_alpha(pal.line, 0.7))
                gy += step_px
        # the route: all of it in the accent's tint, the part flown so far in the accent
        var prev = self.to_xy(p, self.lats[0], self.lons[0])
        for i in range(1, len(self.lats)):
            var q = self.to_xy(p, self.lats[i], self.lons[i])
            var flown = self.has_dot and i < self.upto
            line(s, prev[0], prev[1], q[0], q[1], (3.0 if flown else 2.0) * k, pal.accent if flown else pal.accent_tint)
            prev = q
        # places first (rings and names), findings over them (dots by level)
        for ref m in self.marks:
            if m.kind == MARK_PLACE:
                var q = self.to_xy(p, m.lat, m.lon)
                circle(s, q[0], q[1], 6 * k, pal.card)
                circle(s, q[0], q[1], 6 * k - 2 * k, pal.ink2)
                circle(s, q[0], q[1], 6 * k - 3.5 * k, pal.card)
                if m.label != "":
                    font.draw(s, m.label, q[0] + 10 * k, q[1] - 6 * k, 10.5 * k, pal.ink2, MEDIUM, LEFT)
        for ref m in self.marks:
            if m.kind == MARK_FINDING:
                var q = self.to_xy(p, m.lat, m.lon)
                var r = (2.5 + 1.1 * Float64(max(min(m.level, 5), 1))) * k
                circle(s, q[0], q[1], r + 1.5 * k, pal.card)
                circle(s, q[0], q[1], r, pal.bad)
        if self.has_dot:
            var q = self.to_xy(p, self.dot_lat, self.dot_lon)
            circle(s, q[0], q[1], 11 * k, with_alpha(pal.accent, 0.16))
            circle(s, q[0], q[1], 7 * k, pal.card)
            circle(s, q[0], q[1], 5 * k, pal.accent)
        # the scale bar and north, bottom left and top right
        var bar_px = step_m * p[2]
        if bar_px > 12 * k and bar_px < w - 40 * k:
            var bx = 14 * k
            var by = h - 14 * k
            line(s, bx, by, bx + bar_px, by, 2 * k, pal.ink3)
            line(s, bx, by - 4 * k, bx, by + 1 * k, 1.5 * k, pal.ink3)
            line(s, bx + bar_px, by - 4 * k, bx + bar_px, by + 1 * k, 1.5 * k, pal.ink3)
            font.draw(s, metres_text(step_m), bx + bar_px + 6 * k, by + 3.5 * k, 10.5 * k, pal.ink3, REGULAR, LEFT)
        font.draw(s, "N", w - 16 * k, 20 * k, 10.5 * k, pal.ink3, MEDIUM, CENTRE)
        line(s, w - 16 * k, 24 * k, w - 16 * k, 34 * k, 1.5 * k, pal.ink3)

    def describe(self) -> String:
        """The route's extent, the marks and the dot, for an agent."""
        var bb = self.bounds()
        var out = "Map: a route of " + String(len(self.lats)) + " points, lat " + fixed(bb[0], 5) + "…" + fixed(bb[1], 5) + ", lon " + fixed(bb[2], 5) + "…" + fixed(bb[3], 5)
        var places = 0
        var found = 0
        for ref m in self.marks:
            if m.kind == MARK_PLACE:
                places += 1
            else:
                found += 1
        out += "; " + String(places) + " places, " + String(found) + " findings"
        if self.has_dot:
            out += "; now at " + fixed(self.dot_lat, 6) + ", " + fixed(self.dot_lon, 6)
        return out^


def nice_step(m: Float64) -> Float64:
    """A round number of metres near m: 1, 2 or 5 × a power of ten."""
    if m <= 0:
        return 1.0
    var p = 10.0 ** floor(log10(m))
    var f = m / p
    if f < 1.5:
        return p
    if f < 3.5:
        return 2 * p
    if f < 7.5:
        return 5 * p
    return 10 * p


def metres_text(m: Float64) -> String:
    if m >= 1000:
        return fixed(m / 1000.0, 1 if m < 10000 else 0) + " km"
    return String(Int(m + 0.5)) + " m"
