# Pressure ink (goal 40, D-1201): a stroke is the points a pen passed through, each with a pressure, and is drawn as
# ONE closed outline polygon (a variable-width ribbon with round ends) that every Painter fills: the CPU SurfacePainter,
# GTK's GskPath fill, later Core Graphics or Metal. Nothing here knows about a host.
#
#   var s = Stroke(6.0, INK)               # 6 px wide at full pressure
#   s.add(x, y, event.pressure)            # every PRESS / PAN; pressure 0 = the device has none (a width from speed)
#   s.seal()                               # the outline, computed once (also done lazily by draw())
#   s.draw(painter)                        # one polygon
#   if s.hits(x, y, 0): ...                # the eraser's test
#
# Coordinates are whatever the caller draws in (an app's world space); widths are in the same units.

from std.math import sqrt, cos, sin, atan2, ceil

from mojoui.scene import Painter

comptime MIN_SHARE = 0.3  # the width at pressure 0+ as a share of the full width (a feather touch still shows)
comptime CAP_STEPS = 8  # segments in each round end
comptime PI = 3.141592653589793


def ink_width(full: Float64, pressure: Float64) -> Float64:
    """The ribbon's width at a pressure (0–1): `full` at 1, MIN_SHARE of it as the pressure goes to 0."""
    var p = min(max(pressure, 0.0), 1.0)
    return full * (MIN_SHARE + (1.0 - MIN_SHARE) * p)


def speed_pressure(distance: Float64, previous: Float64) -> Float64:
    """A pressure for a device that has none (a mouse, a finger): pointer events arrive at a steady rate, so the
    distance since the last point is the speed. Slow (≤ 2 px a step) is 1, fast (≥ 40 px a step) is 0.35, linear in
    between, eased toward the previous point's value (40 % new) so a jerk doesn't make a notch. The first point gets 0.8."""
    if previous <= 0:
        return 0.8
    var target = 1.0 - (min(max(distance, 2.0), 40.0) - 2.0) / 38.0 * 0.65
    return previous * 0.6 + target * 0.4


struct Centre(Movable):
    """A stroke's smoothed centre line: points and the half-width at each."""

    var x: List[Float64]
    var y: List[Float64]
    var r: List[Float64]

    def __init__(out self):
        self.x = List[Float64]()
        self.y = List[Float64]()
        self.r = List[Float64]()


struct Stroke(Copyable, Movable):
    """A pen stroke: points, their pressures (device or from speed), its full width and colour, and its outline."""

    var xs: List[Float64]
    var ys: List[Float64]
    var ps: List[Float64]  # pressures used (0–1); a device's when it has one, else speed_pressure's
    var width: Float64
    var color: UInt32
    var shape: List[Float64]  # the outline, x, y interleaved (empty until seal())
    var sealed: Bool
    var x0: Float64  # bounds of the points (the outline is within width/2 of them)
    var y0: Float64
    var x1: Float64
    var y1: Float64

    def __init__(out self, width: Float64, color: UInt32):
        self.xs = List[Float64]()
        self.ys = List[Float64]()
        self.ps = List[Float64]()
        self.width = width
        self.color = color
        self.shape = List[Float64]()
        self.sealed = False
        self.x0 = 1e30
        self.y0 = 1e30
        self.x1 = -1e30
        self.y1 = -1e30

    def points(self) -> Int:
        return len(self.xs)

    def add(mut self, x: Float64, y: Float64, pressure: Float64):
        """One more point. `pressure` > 0: the device's; 0: none, so one from speed. A point within 0.5 of the last is
        dropped (a pen at rest sends many), except that its pressure is kept."""
        var n = len(self.xs)
        var d = 0.0
        if n > 0:
            var dx = x - self.xs[n - 1]
            var dy = y - self.ys[n - 1]
            d = sqrt(dx * dx + dy * dy)
            if d < 0.5:
                if pressure > 0:
                    self.ps[n - 1] = min(pressure, 1.0)
                return
        var p = min(pressure, 1.0) if pressure > 0 else speed_pressure(d, self.ps[n - 1] if n > 0 else 0.0)
        self.xs.append(x)
        self.ys.append(y)
        self.ps.append(p)
        self.x0 = min(self.x0, x)
        self.y0 = min(self.y0, y)
        self.x1 = max(self.x1, x)
        self.y1 = max(self.y1, y)
        self.sealed = False

    def centre(self) -> Centre:
        """The smoothed centre line: a Catmull-Rom curve through every point (so it passes through each exactly),
        about one sample per 2.5 units, with the half-width interpolated along it."""
        var c = Centre()
        var n = len(self.xs)
        for i in range(n):
            var j0 = max(i - 1, 0)
            var j2 = min(i + 1, n - 1)
            var j3 = min(i + 2, n - 1)
            var ax = self.xs[j0]
            var ay = self.ys[j0]
            var bx = self.xs[i]
            var by = self.ys[i]
            var ccx = self.xs[j2]
            var ccy = self.ys[j2]
            var dx = self.xs[j3]
            var dy = self.ys[j3]
            var ra = ink_width(self.width, self.ps[i]) / 2
            var rb = ink_width(self.width, self.ps[j2]) / 2
            var seg = sqrt((ccx - bx) * (ccx - bx) + (ccy - by) * (ccy - by))
            var steps = 1 if i == n - 1 else min(max(Int(ceil(seg / 2.5)), 1), 24)
            for k in range(steps):
                var t = Float64(k) / Float64(steps)
                var t2 = t * t
                var t3 = t2 * t
                c.x.append(0.5 * (2 * bx + (-ax + ccx) * t + (2 * ax - 5 * bx + 4 * ccx - dx) * t2 + (-ax + 3 * bx - 3 * ccx + dx) * t3))
                c.y.append(0.5 * (2 * by + (-ay + ccy) * t + (2 * ay - 5 * by + 4 * ccy - dy) * t2 + (-ay + 3 * by - 3 * ccy + dy) * t3))
                c.r.append(ra + (rb - ra) * t)
        return c^

    def outline(self) -> List[Float64]:
        """The closed outline polygon (x, y interleaved): the left edge forward, a round end, the right edge back, a
        round start. A single point is a disc. Fill it with the non-zero rule (the ends overlap the ribbon)."""
        var out = List[Float64]()
        var n = len(self.xs)
        if n == 0:
            return out^
        var c = self.centre()
        ref cx = c.x
        ref cy = c.y
        ref r = c.r
        var m = len(cx)
        if m == 1:
            for k in range(2 * CAP_STEPS):
                var a = 2 * PI * Float64(k) / Float64(2 * CAP_STEPS)
                out.append(cx[0] + r[0] * cos(a))
                out.append(cy[0] + r[0] * sin(a))
            return out^
        var nx = List[Float64](capacity=m)  # unit normals (left of travel)
        var ny = List[Float64](capacity=m)
        var tx = 1.0
        var ty = 0.0
        for k in range(m):
            var a = max(k - 1, 0)
            var b = min(k + 1, m - 1)
            var ex = cx[b] - cx[a]
            var ey = cy[b] - cy[a]
            var l = sqrt(ex * ex + ey * ey)
            if l > 1e-9:
                tx = ex / l
                ty = ey / l
            nx.append(-ty)
            ny.append(tx)
        for k in range(m):
            out.append(cx[k] + nx[k] * r[k])
            out.append(cy[k] + ny[k] * r[k])
        var ae = atan2(ny[m - 1], nx[m - 1])  # the round end: from the left edge, through the travel direction, to the right
        for s in range(1, CAP_STEPS):
            var a = ae - PI * Float64(s) / Float64(CAP_STEPS)
            out.append(cx[m - 1] + r[m - 1] * cos(a))
            out.append(cy[m - 1] + r[m - 1] * sin(a))
        for k in range(m - 1, -1, -1):
            out.append(cx[k] - nx[k] * r[k])
            out.append(cy[k] - ny[k] * r[k])
        var a0 = atan2(ny[0], nx[0]) + PI  # the round start: from the right edge, through behind, to the left
        for s in range(1, CAP_STEPS):
            var a = a0 - PI * Float64(s) / Float64(CAP_STEPS)
            out.append(cx[0] + r[0] * cos(a))
            out.append(cy[0] + r[0] * sin(a))
        return out^

    def seal(mut self):
        """Computes the outline once and keeps it (a finished stroke; draw() calls it when needed)."""
        if not self.sealed:
            self.shape = self.outline()
            self.sealed = True

    def draw[P: Painter](mut self, mut p: P):
        """The stroke as one filled polygon."""
        self.seal()
        p.polygon(self.shape, self.color)

    def hits(self, x: Float64, y: Float64, slop: Float64) -> Bool:
        """Whether (x, y) is on the ink: within the ribbon's half-width (at the nearest place) plus `slop` of its
        centre line. The eraser's test."""
        var n = len(self.xs)
        if n == 0:
            return False
        var reach = self.width / 2 + slop
        if x < self.x0 - reach or x > self.x1 + reach or y < self.y0 - reach or y > self.y1 + reach:
            return False
        var c = self.centre()
        ref cx = c.x
        ref cy = c.y
        ref r = c.r
        if len(cx) == 1:
            return (x - cx[0]) * (x - cx[0]) + (y - cy[0]) * (y - cy[0]) <= (r[0] + slop) * (r[0] + slop)
        for k in range(len(cx) - 1):
            var dx = cx[k + 1] - cx[k]
            var dy = cy[k + 1] - cy[k]
            var l2 = dx * dx + dy * dy
            var t = 0.0 if l2 == 0 else min(max(((x - cx[k]) * dx + (y - cy[k]) * dy) / l2, 0.0), 1.0)
            var ex = x - (cx[k] + t * dx)
            var ey = y - (cy[k] + t * dy)
            var rr = r[k] + (r[k + 1] - r[k]) * t + slop
            if ex * ex + ey * ey <= rr * rr:
                return True
        return False
