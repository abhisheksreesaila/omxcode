# mojoui.vector: small vector drawings on a canvas (goal 77 M7e): a subset of SVG read once and drawn at any size, turned
# and faded, with its colours from the theme. It draws mojoui's Lucide icons on a canvas (the same icons every host shows
# as widgets: mojoui/icons_data.mojo) and illustrations such as mojoui.charms'.
#
#   draw_icon(surface, "gift", x, y, size, colour)        a Lucide icon in a size x size pixel square (False: unknown)
#   var v = parse_svg(svg)                                 path, circle, ellipse, rect (rx), line, polyline, polygon;
#                                                          fill / stroke / stroke-width / opacity, transform="rotate(a cx cy)"
#   draw_vector(surface, v, x, y, k, colours, current, angle=0, pivot_x=0, pivot_y=0, alpha=1)
#       x, y: where the drawing's (0, 0) lands (pixels); k: pixels per unit; turned by `angle` degrees about the pivot
#       (units); a colour written '@N' is colours[N] (so a drawing takes its colours from the palette), 'currentColor' is
#       `current`; `alpha` fades it all.
#
# Paths: M L H V C S Q T A Z, absolute and relative, Lucide's compact numbers ("1.5-2", ".5.5", arc flags run together).
# Fills are non-zero, anti-aliased on 4 sub-rows a pixel; strokes are the distance to the path's segments (round caps and
# joins), so a half-transparent stroke never darkens where its segments meet. CPU only; a few thousand pixels per icon.

from std.math import sqrt, sin, cos, atan2, pi
from mojoui.canvas import Surface
from mojoui.draw import blend
from mojoui.icons_data import lucide_svg

comptime NO_PAINT = -1
comptime CURRENT = -2
comptime _SUB = 4  # fill sub-rows per pixel row


struct VShape(Copyable, Movable):
    """One element: its outline as points (x, y interleaved, in the drawing's units), where each sub-path starts, which
    are closed; its fill and stroke (NO_PAINT, CURRENT or a colour slot '@N'), stroke width and opacity."""

    var pts: List[Float64]
    var starts: List[Int]  # point index (not float index) where each sub-path begins
    var closed: List[Bool]
    var fill: Int
    var stroke: Int
    var width: Float64
    var opacity: Float64

    def __init__(out self, fill: Int, stroke: Int, width: Float64, opacity: Float64):
        self.pts = List[Float64]()
        self.starts = List[Int]()
        self.closed = List[Bool]()
        self.fill = fill
        self.stroke = stroke
        self.width = width
        self.opacity = opacity

    def begin(mut self, x: Float64, y: Float64):
        self.starts.append(len(self.pts) // 2)
        self.closed.append(False)
        self.pts.append(x)
        self.pts.append(y)

    def to(mut self, x: Float64, y: Float64):
        if len(self.starts) == 0:
            self.begin(x, y)
            return
        self.pts.append(x)
        self.pts.append(y)

    def close(mut self):
        if len(self.closed) > 0:
            self.closed[len(self.closed) - 1] = True

    def rotate(mut self, deg: Float64, cx: Float64, cy: Float64):
        var a = deg * pi / 180.0
        var c = cos(a)
        var s = sin(a)
        for i in range(len(self.pts) // 2):
            var x = self.pts[2 * i] - cx
            var y = self.pts[2 * i + 1] - cy
            self.pts[2 * i] = cx + x * c - y * s
            self.pts[2 * i + 1] = cy + x * s + y * c


struct Vector(Copyable, Movable):
    var shapes: List[VShape]
    var w: Float64  # the viewBox's size (units)
    var h: Float64

    def __init__(out self):
        self.shapes = List[VShape]()
        self.w = 24.0
        self.h = 24.0


# ------------------------------------------------------------------------------------------------ reading SVG


def _attr(tag: String, name: String) -> String:
    """The value of ` name="…"` (or '…') in one tag, "" when it isn't there."""
    for q in [String('="'), String("='")]:
        var key = " " + name + q
        var at = tag.find(key)
        if at < 0:
            key = "\n" + name + q
            at = tag.find(key)
        if at >= 0:
            var start = at + key.byte_length()
            var quote = String('"') if q == '="' else String("'")
            var end = tag.find(quote, start)
            if end > start:
                return String(tag[byte=start:end])
            return ""
    return ""


def _num(text: String, default: Float64) -> Float64:
    var n = _Nums(text)
    var v = n.next()
    return v if n.ok else default


struct _Nums:
    """Numbers out of SVG's compact text ("M7.5 7a1 1 0 0 1 0-5", ".5.5", "1e-3")."""

    var b: List[UInt8]
    var i: Int
    var ok: Bool

    def __init__(out self, text: String):
        self.b = List[UInt8]()
        for c in text.as_bytes():
            self.b.append(c)
        self.i = 0
        self.ok = True

    def skip(mut self):
        while self.i < len(self.b) and (self.b[self.i] == 32 or self.b[self.i] == 44 or self.b[self.i] == 10 or self.b[self.i] == 9 or self.b[self.i] == 13):
            self.i += 1

    def at_number(mut self) -> Bool:
        self.skip()
        if self.i >= len(self.b):
            return False
        var c = self.b[self.i]
        return (c >= 48 and c <= 57) or c == 45 or c == 43 or c == 46

    def flag(mut self) -> Float64:
        """An arc flag: one character, 0 or 1, separators optional."""
        self.skip()
        if self.i < len(self.b) and (self.b[self.i] == 48 or self.b[self.i] == 49):
            self.i += 1
            return 1.0 if self.b[self.i - 1] == 49 else 0.0
        self.ok = False
        return 0.0

    def next(mut self) -> Float64:
        self.skip()
        var sign = 1.0
        if self.i < len(self.b) and (self.b[self.i] == 45 or self.b[self.i] == 43):
            if self.b[self.i] == 45:
                sign = -1.0
            self.i += 1
        var v = 0.0
        var digits = 0
        while self.i < len(self.b) and self.b[self.i] >= 48 and self.b[self.i] <= 57:
            v = v * 10.0 + Float64(Int(self.b[self.i]) - 48)
            self.i += 1
            digits += 1
        if self.i < len(self.b) and self.b[self.i] == 46:
            self.i += 1
            var f = 0.1
            while self.i < len(self.b) and self.b[self.i] >= 48 and self.b[self.i] <= 57:
                v += Float64(Int(self.b[self.i]) - 48) * f
                f *= 0.1
                self.i += 1
                digits += 1
        if digits == 0:
            self.ok = False
            return 0.0
        if self.i < len(self.b) and (self.b[self.i] == 101 or self.b[self.i] == 69):
            var j = self.i + 1
            var es = 1.0
            if j < len(self.b) and (self.b[j] == 45 or self.b[j] == 43):
                es = -1.0 if self.b[j] == 45 else 1.0
                j += 1
            var e = 0
            var any = False
            while j < len(self.b) and self.b[j] >= 48 and self.b[j] <= 57:
                e = e * 10 + Int(self.b[j]) - 48
                j += 1
                any = True
            if any:
                self.i = j
                var m = 1.0
                for _ in range(e):
                    m *= 10.0
                v = v * m if es > 0 else v / m
        return sign * v


def _paint(text: String, default: Int) -> Int:
    if text == "":
        return default
    if text == "none":
        return NO_PAINT
    if text.startswith("@"):
        try:
            return Int(String(text[byte=1:]))
        except:
            return CURRENT
    return CURRENT  # (currentColor, or a literal colour: a drawing here takes its colours from the caller)


def _cubic(mut sh: VShape, x0: Float64, y0: Float64, x1: Float64, y1: Float64, x2: Float64, y2: Float64, x3: Float64, y3: Float64):
    var n = 12
    for k in range(1, n + 1):
        var t = Float64(k) / Float64(n)
        var u = 1.0 - t
        sh.to(u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3,
              u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3)


def _quad(mut sh: VShape, x0: Float64, y0: Float64, x1: Float64, y1: Float64, x2: Float64, y2: Float64):
    var n = 10
    for k in range(1, n + 1):
        var t = Float64(k) / Float64(n)
        var u = 1.0 - t
        sh.to(u * u * x0 + 2 * u * t * x1 + t * t * x2, u * u * y0 + 2 * u * t * y1 + t * t * y2)


def _angle(ux: Float64, uy: Float64, vx: Float64, vy: Float64) -> Float64:
    return atan2(ux * vy - uy * vx, ux * vx + uy * vy)


def _arc(mut sh: VShape, x1: Float64, y1: Float64, rx_in: Float64, ry_in: Float64, phi_deg: Float64, fa: Float64, fs: Float64,
         x2: Float64, y2: Float64):
    """An elliptical arc as points (SVG 1.1 F.6.5: the endpoint form turned into a centre and two angles)."""
    var rx = abs(rx_in)
    var ry = abs(ry_in)
    if rx < 1e-9 or ry < 1e-9 or (abs(x1 - x2) < 1e-9 and abs(y1 - y2) < 1e-9):
        sh.to(x2, y2)
        return
    var phi = phi_deg * pi / 180.0
    var cp = cos(phi)
    var sp = sin(phi)
    var dx2 = (x1 - x2) / 2.0
    var dy2 = (y1 - y2) / 2.0
    var x1p = cp * dx2 + sp * dy2
    var y1p = -sp * dx2 + cp * dy2
    var lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1.0:
        rx *= sqrt(lam)
        ry *= sqrt(lam)
    var num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    var den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    var coef = sqrt(max(num / den, 0.0)) if den > 0 else 0.0
    if (fa > 0.5) == (fs > 0.5):
        coef = -coef
    var cxp = coef * rx * y1p / ry
    var cyp = -coef * ry * x1p / rx
    var cx = cp * cxp - sp * cyp + (x1 + x2) / 2.0
    var cy = sp * cxp + cp * cyp + (y1 + y2) / 2.0
    var ux = (x1p - cxp) / rx
    var uy = (y1p - cyp) / ry
    var vx = (-x1p - cxp) / rx
    var vy = (-y1p - cyp) / ry
    var th1 = _angle(1.0, 0.0, ux, uy)
    var dth = _angle(ux, uy, vx, vy)
    if fs < 0.5 and dth > 0:
        dth -= 2 * pi
    elif fs > 0.5 and dth < 0:
        dth += 2 * pi
    var n = max(3, Int(abs(dth) / (pi / 16.0)) + 1)
    for k in range(1, n + 1):
        var t = th1 + dth * Float64(k) / Float64(n)
        sh.to(cx + rx * cos(t) * cp - ry * sin(t) * sp, cy + rx * cos(t) * sp + ry * sin(t) * cp)


def _path(mut sh: VShape, d: String):
    var n = _Nums(d)
    var cmd: UInt8 = 0
    var x = 0.0
    var y = 0.0
    var sx = 0.0
    var sy = 0.0
    var cx = 0.0  # the last control point (S, T)
    var cy = 0.0
    var last: UInt8 = 0
    while True:
        n.skip()
        if n.i >= len(n.b):
            break
        var c = n.b[n.i]
        if (c >= 65 and c <= 90) or (c >= 97 and c <= 122):
            cmd = c
            n.i += 1
            if cmd == 90 or cmd == 122:  # Z
                sh.close()
                x = sx
                y = sy
                last = cmd
                continue
        elif not n.at_number() or cmd == 0:
            n.i += 1  # (something we don't read: skip it)
            continue
        var rel = cmd >= 97
        var up = cmd - 32 if rel else cmd
        var ox = x if rel else 0.0
        var oy = y if rel else 0.0
        if up == 77:  # M
            x = ox + n.next()
            y = oy + n.next()
            if not n.ok:
                break
            sh.begin(x, y)
            sx = x
            sy = y
            cmd = 108 if rel else 76  # (more pairs after M are lines)
        elif up == 76:  # L
            x = ox + n.next()
            y = oy + n.next()
            sh.to(x, y)
        elif up == 72:  # H
            x = ox + n.next()
            sh.to(x, y)
        elif up == 86:  # V
            y = (y if rel else 0.0) + n.next()
            sh.to(x, y)
        elif up == 67:  # C
            var x1 = ox + n.next()
            var y1 = oy + n.next()
            var x2 = ox + n.next()
            var y2 = oy + n.next()
            var x3 = ox + n.next()
            var y3 = oy + n.next()
            _cubic(sh, x, y, x1, y1, x2, y2, x3, y3)
            cx = x2
            cy = y2
            x = x3
            y = y3
        elif up == 83:  # S
            var l_up = last - 32 if last >= 97 else last
            var x1 = 2 * x - cx if l_up == 67 or l_up == 83 else x
            var y1 = 2 * y - cy if l_up == 67 or l_up == 83 else y
            var x2 = ox + n.next()
            var y2 = oy + n.next()
            var x3 = ox + n.next()
            var y3 = oy + n.next()
            _cubic(sh, x, y, x1, y1, x2, y2, x3, y3)
            cx = x2
            cy = y2
            x = x3
            y = y3
        elif up == 81:  # Q
            var x1 = ox + n.next()
            var y1 = oy + n.next()
            var x2 = ox + n.next()
            var y2 = oy + n.next()
            _quad(sh, x, y, x1, y1, x2, y2)
            cx = x1
            cy = y1
            x = x2
            y = y2
        elif up == 84:  # T
            var l_up = last - 32 if last >= 97 else last
            var x1 = 2 * x - cx if l_up == 81 or l_up == 84 else x
            var y1 = 2 * y - cy if l_up == 81 or l_up == 84 else y
            var x2 = ox + n.next()
            var y2 = oy + n.next()
            _quad(sh, x, y, x1, y1, x2, y2)
            cx = x1
            cy = y1
            x = x2
            y = y2
        elif up == 65:  # A
            var rx = n.next()
            var ry = n.next()
            var rot = n.next()
            var fa = n.flag()
            var fs = n.flag()
            var x2 = ox + n.next()
            var y2 = oy + n.next()
            _arc(sh, x, y, rx, ry, rot, fa, fs, x2, y2)
            x = x2
            y = y2
        else:
            n.i += 1
        if not n.ok:
            break
        last = cmd


def _ellipse(mut sh: VShape, cx: Float64, cy: Float64, rx: Float64, ry: Float64):
    var n = max(16, Int(max(rx, ry) * 2.0) + 8)
    n = min(n, 64)
    for k in range(n):
        var t = 2 * pi * Float64(k) / Float64(n)
        if k == 0:
            sh.begin(cx + rx * cos(t), cy + ry * sin(t))
        else:
            sh.to(cx + rx * cos(t), cy + ry * sin(t))
    sh.close()


def _round_rect(mut sh: VShape, x: Float64, y: Float64, w: Float64, h: Float64, r_in: Float64):
    var r = min(r_in, min(w, h) / 2.0)
    if r <= 0:
        sh.begin(x, y)
        sh.to(x + w, y)
        sh.to(x + w, y + h)
        sh.to(x, y + h)
        sh.close()
        return
    sh.begin(x + r, y)
    sh.to(x + w - r, y)
    _arc(sh, x + w - r, y, r, r, 0, 0, 1, x + w, y + r)
    sh.to(x + w, y + h - r)
    _arc(sh, x + w, y + h - r, r, r, 0, 0, 1, x + w - r, y + h)
    sh.to(x + r, y + h)
    _arc(sh, x + r, y + h, r, r, 0, 0, 1, x, y + h - r)
    sh.to(x, y + r)
    _arc(sh, x, y + r, r, r, 0, 0, 1, x + r, y)
    sh.close()


def parse_svg(svg: String) -> Vector:
    """The drawing in `svg` (its viewBox, then each element in order; the root's fill, stroke and stroke-width are the
    defaults)."""
    var v = Vector()
    var fill_d = 0  # (SVG's default fill is black: the first colour)
    var stroke_d = NO_PAINT
    var width_d = 1.0
    var pos = 0
    while True:
        var lt = svg.find("<", pos)
        if lt < 0:
            break
        var gt = svg.find(">", lt)
        if gt < 0:
            break
        var tag = String(svg[byte=lt:gt])
        pos = gt + 1
        var sp = tag.find(" ")
        var name = String(tag[byte=1:sp]) if sp > 0 else String(tag[byte=1:])
        if name == "svg":
            var vb = _attr(tag, "viewBox")
            if vb != "":
                var nb = _Nums(vb)
                _ = nb.next()
                _ = nb.next()
                v.w = nb.next()
                v.h = nb.next()
            fill_d = _paint(_attr(tag, "fill"), fill_d)
            stroke_d = _paint(_attr(tag, "stroke"), stroke_d)
            width_d = _num(_attr(tag, "stroke-width"), width_d)
            continue
        if name != "path" and name != "circle" and name != "ellipse" and name != "rect" and name != "line" and name != "polyline" and name != "polygon":
            continue
        var sh = VShape(_paint(_attr(tag, "fill"), fill_d), _paint(_attr(tag, "stroke"), stroke_d),
                        _num(_attr(tag, "stroke-width"), width_d), _num(_attr(tag, "opacity"), 1.0))
        if name == "path":
            _path(sh, _attr(tag, "d"))
        elif name == "circle":
            var r = _num(_attr(tag, "r"), 0.0)
            _ellipse(sh, _num(_attr(tag, "cx"), 0.0), _num(_attr(tag, "cy"), 0.0), r, r)
        elif name == "ellipse":
            _ellipse(sh, _num(_attr(tag, "cx"), 0.0), _num(_attr(tag, "cy"), 0.0), _num(_attr(tag, "rx"), 0.0), _num(_attr(tag, "ry"), 0.0))
        elif name == "rect":
            var rx = _num(_attr(tag, "rx"), _num(_attr(tag, "ry"), 0.0))
            _round_rect(sh, _num(_attr(tag, "x"), 0.0), _num(_attr(tag, "y"), 0.0), _num(_attr(tag, "width"), 0.0), _num(_attr(tag, "height"), 0.0), rx)
        elif name == "line":
            sh.begin(_num(_attr(tag, "x1"), 0.0), _num(_attr(tag, "y1"), 0.0))
            sh.to(_num(_attr(tag, "x2"), 0.0), _num(_attr(tag, "y2"), 0.0))
        else:
            var nums = _Nums(_attr(tag, "points"))
            var first = True
            while nums.at_number():
                var px = nums.next()
                var py = nums.next()
                if not nums.ok:
                    break
                if first:
                    sh.begin(px, py)
                    first = False
                else:
                    sh.to(px, py)
            if name == "polygon":
                sh.close()
        var tf = _attr(tag, "transform")
        if tf.startswith("rotate("):
            var nt = _Nums(String(tf[byte=7:]))
            var a = nt.next()
            var rcx = 0.0
            var rcy = 0.0
            if nt.at_number():
                rcx = nt.next()
                rcy = nt.next()
            sh.rotate(a, rcx, rcy)
        if len(sh.pts) >= 4:
            v.shapes.append(sh^)
    return v^


# ------------------------------------------------------------------------------------------------ drawing


def _fill(mut s: Surface, xs: List[Float64], ys: List[Float64], starts: List[Int], color: UInt32):
    """Rings (xs, ys: pixels; `starts` where each ring begins, closed implicitly), non-zero, anti-aliased."""
    var n = len(xs)
    if n < 3:
        return
    var bx0 = 1e30
    var by0 = 1e30
    var bx1 = -1e30
    var by1 = -1e30
    for i in range(n):
        bx0 = min(bx0, xs[i])
        bx1 = max(bx1, xs[i])
        by0 = min(by0, ys[i])
        by1 = max(by1, ys[i])
    var x0 = max(Int(bx0), 0)
    var x1 = min(Int(bx1) + 1, s.width)
    var y0 = max(Int(by0), 0)
    var y1 = min(Int(by1) + 1, s.height)
    if x1 <= x0 or y1 <= y0:
        return
    # the edges, ring by ring (each ring closed back to its start)
    var ea = List[Int]()
    var eb = List[Int]()
    for r in range(len(starts)):
        var a = starts[r]
        var b = starts[r + 1] if r + 1 < len(starts) else n
        if b - a < 2:
            continue
        for i in range(a, b):
            ea.append(i)
            eb.append(i + 1 if i + 1 < b else a)
    var w = x1 - x0
    var cov = List[Float64](length=w, fill=0.0)
    var cx = List[Float64]()
    var cd = List[Int]()
    var share = 1.0 / Float64(_SUB)
    for py in range(y0, y1):
        for i in range(w):
            cov[i] = 0.0
        var any = False
        for sub in range(_SUB):
            var sy = Float64(py) + (Float64(sub) + 0.5) * share
            cx.clear()
            cd.clear()
            for e in range(len(ea)):
                var ya = ys[ea[e]]
                var yb = ys[eb[e]]
                if (ya <= sy and sy < yb) or (yb <= sy and sy < ya):
                    var x = xs[ea[e]] + (sy - ya) * (xs[eb[e]] - xs[ea[e]]) / (yb - ya)
                    var d = 1 if yb > ya else -1
                    var at = len(cx)
                    cx.append(x)
                    cd.append(d)
                    while at > 0 and cx[at - 1] > x:
                        cx[at] = cx[at - 1]
                        cd[at] = cd[at - 1]
                        at -= 1
                    cx[at] = x
                    cd[at] = d
            var wind = 0
            var start = 0.0
            for c in range(len(cx)):
                var before = wind
                wind += cd[c]
                if before == 0 and wind != 0:
                    start = cx[c]
                elif before != 0 and wind == 0:
                    var lo = max(start, Float64(x0))
                    var hi = min(cx[c], Float64(x1))
                    if hi > lo:
                        any = True
                        var ia = Int(lo)
                        var ib = Int(hi)
                        if ia == ib:
                            cov[ia - x0] += (hi - lo) * share
                        else:
                            cov[ia - x0] += (Float64(ia + 1) - lo) * share
                            for k in range(ia + 1, min(ib, x1)):
                                cov[k - x0] += share
                            if ib < x1:
                                cov[ib - x0] += (hi - Float64(ib)) * share
        if any:
            for i in range(w):
                if cov[i] > 0.0:
                    var p = s.pixels().unsafe_offset(py * s.width + x0 + i)
                    p[] = blend(p[], color, min(cov[i], 1.0))


def _stroke(mut s: Surface, xs: List[Float64], ys: List[Float64], starts: List[Int], closed: List[Bool], width: Float64, color: UInt32):
    """The outline `width` pixels wide: each pixel's coverage from its distance to the nearest segment, painted once."""
    var n = len(xs)
    if n < 2:
        return
    var hw = width / 2.0
    var reach = hw + 1.0
    var bx0 = 1e30
    var by0 = 1e30
    var bx1 = -1e30
    var by1 = -1e30
    for i in range(n):
        bx0 = min(bx0, xs[i])
        bx1 = max(bx1, xs[i])
        by0 = min(by0, ys[i])
        by1 = max(by1, ys[i])
    var x0 = max(Int(bx0 - reach), 0)
    var x1 = min(Int(bx1 + reach) + 1, s.width)
    var y0 = max(Int(by0 - reach), 0)
    var y1 = min(Int(by1 + reach) + 1, s.height)
    if x1 <= x0 or y1 <= y0:
        return
    var w = x1 - x0
    var dist = List[Float64](length=w * (y1 - y0), fill=1e9)
    for r in range(len(starts)):
        var a = starts[r]
        var b = starts[r + 1] if r + 1 < len(starts) else n
        var segs = b - a - 1 + (1 if closed[r] and b - a > 2 else 0)
        if b - a == 1:
            segs = 1  # (a lone point: a dot)
        for k in range(segs):
            var i = a + k
            var j = a + k + 1 if a + k + 1 < b else a
            if b - a == 1:
                j = i
            var ax = xs[i]
            var ay = ys[i]
            var dx = xs[j] - ax
            var dy = ys[j] - ay
            var len2 = dx * dx + dy * dy
            var sx0 = max(Int(min(ax, xs[j]) - reach), x0)
            var sx1 = min(Int(max(ax, xs[j]) + reach) + 1, x1)
            var sy0 = max(Int(min(ay, ys[j]) - reach), y0)
            var sy1 = min(Int(max(ay, ys[j]) + reach) + 1, y1)
            for py in range(sy0, sy1):
                var cy = Float64(py) + 0.5
                for px in range(sx0, sx1):
                    var cx = Float64(px) + 0.5
                    var t = 0.0 if len2 == 0 else min(max(((cx - ax) * dx + (cy - ay) * dy) / len2, 0.0), 1.0)
                    var ex = cx - (ax + t * dx)
                    var ey = cy - (ay + t * dy)
                    var d2 = ex * ex + ey * ey
                    var at = (py - y0) * w + px - x0
                    if d2 < dist[at]:
                        dist[at] = d2
    for py in range(y0, y1):
        for px in range(x0, x1):
            var d2 = dist[(py - y0) * w + px - x0]
            if d2 > (reach + 0.5) * (reach + 0.5):
                continue
            var cov = hw + 0.5 - sqrt(d2)
            if cov > 0.0:
                var p = s.pixels().unsafe_offset(py * s.width + px)
                p[] = blend(p[], color, min(cov, 1.0))


def _alpha_of(color: UInt32, a: Float64) -> UInt32:
    var base = Float64(Int((color >> 24) & 0xFF)) / 255.0
    return (color & 0x00FFFFFF) | (UInt32(Int(min(max(base * a, 0.0), 1.0) * 255.0 + 0.5)) << 24)


def draw_vector(mut s: Surface, v: Vector, x: Float64, y: Float64, k: Float64, colours: List[UInt32], current: UInt32,
                angle: Float64 = 0.0, pivot_x: Float64 = 0.0, pivot_y: Float64 = 0.0, alpha: Float64 = 1.0):
    """`v` with its (0, 0) at pixel (x, y), k pixels a unit, turned `angle` degrees about (pivot_x, pivot_y) (units), faded
    by `alpha`. '@N' colours are colours[N] (missing: `current`), currentColor is `current`."""
    if alpha <= 0.004:
        return
    var a = angle * pi / 180.0
    var ca = cos(a)
    var sa = sin(a)
    for sh in v.shapes:
        var n = len(sh.pts) // 2
        var xs = List[Float64](capacity=n)
        var ys = List[Float64](capacity=n)
        for i in range(n):
            var ux = sh.pts[2 * i] - pivot_x
            var uy = sh.pts[2 * i + 1] - pivot_y
            xs.append(x + (pivot_x + ux * ca - uy * sa) * k)
            ys.append(y + (pivot_y + ux * sa + uy * ca) * k)
        if sh.fill != NO_PAINT:
            var c = current if sh.fill == CURRENT or sh.fill >= len(colours) else colours[sh.fill]
            _fill(s, xs, ys, sh.starts, _alpha_of(c, alpha * sh.opacity))
        if sh.stroke != NO_PAINT and sh.width > 0:
            var c = current if sh.stroke == CURRENT or sh.stroke >= len(colours) else colours[sh.stroke]
            _stroke(s, xs, ys, sh.starts, sh.closed, sh.width * k, _alpha_of(c, alpha * sh.opacity))


def draw_icon(mut s: Surface, name: String, x: Float64, y: Float64, size: Float64, colour: UInt32) -> Bool:
    """mojoui's Lucide icon `name` in a size x size pixel square at (x, y), its strokes in `colour`. False when there is no
    such icon (the caller draws something else)."""
    var svg = lucide_svg(name)
    if svg == "":
        return False
    var v = parse_svg(svg)
    draw_vector(s, v, x, y, size / max(v.w, 1.0), List[UInt32](), colour)
    return True
