# 2D drawing on a Surface: anti-aliased rounded rectangles, lines, circles and areas.
# Coordinates are pixels (multiply points by surface.scale). Colours are rgba(...) values.

from std.math import sqrt
from mojoui.canvas import Surface


def blend(d: UInt32, color: UInt32, cov: Float64) -> UInt32:
    """`color` over the pixel `d`, with coverage 0–1 (times the colour's own alpha)."""
    var a = cov * Float64(Int((color >> 24) & 0xFF)) / 255.0
    if a <= 0.0:
        return d
    if a >= 1.0:
        return (color & 0x00FFFFFF) | (d & 0xFF000000)
    var r = Float64(Int(color & 0xFF)) * a + Float64(Int(d & 0xFF)) * (1 - a)
    var g = Float64(Int((color >> 8) & 0xFF)) * a + Float64(Int((d >> 8) & 0xFF)) * (1 - a)
    var b = Float64(Int((color >> 16) & 0xFF)) * a + Float64(Int((d >> 16) & 0xFF)) * (1 - a)
    return UInt32(Int(r + 0.5)) | (UInt32(Int(g + 0.5)) << 8) | (UInt32(Int(b + 0.5)) << 16) | (d & 0xFF000000)


def over(d: UInt32, color: UInt32, cov: Float64) -> UInt32:
    """`color` over the pixel `d` as straight-alpha compositing (the result's alpha grows): for a clear canvas
    (Canvas.passthrough) whose unpainted parts must stay see-through, where blend() keeps the pixel's alpha."""
    var a = cov * Float64(Int((color >> 24) & 0xFF)) / 255.0
    if a <= 0.0:
        return d
    var da = Float64(Int((d >> 24) & 0xFF)) / 255.0
    var oa = a + da * (1 - a)
    if oa <= 0.0:
        return 0
    var r = (Float64(Int(color & 0xFF)) * a + Float64(Int(d & 0xFF)) * da * (1 - a)) / oa
    var g = (Float64(Int((color >> 8) & 0xFF)) * a + Float64(Int((d >> 8) & 0xFF)) * da * (1 - a)) / oa
    var b = (Float64(Int((color >> 16) & 0xFF)) * a + Float64(Int((d >> 16) & 0xFF)) * da * (1 - a)) / oa
    return UInt32(Int(r + 0.5)) | (UInt32(Int(g + 0.5)) << 8) | (UInt32(Int(b + 0.5)) << 16) | (UInt32(Int(oa * 255.0 + 0.5)) << 24)


def with_alpha(color: UInt32, alpha: Float64) -> UInt32:
    return (color & 0x00FFFFFF) | (UInt32(Int(min(max(alpha, 0.0), 1.0) * 255.0 + 0.5)) << 24)


def plot(mut s: Surface, x: Int, y: Int, color: UInt32, cov: Float64):
    if 0 <= x < s.width and 0 <= y < s.height and cov > 0.0:
        var p = s.pixels().unsafe_offset(y * s.width + x)
        p[] = blend(p[], color, min(cov, 1.0))


def rect(mut s: Surface, x: Float64, y: Float64, w: Float64, h: Float64, color: UInt32, radius: Float64 = 0):
    """A filled rectangle with anti-aliased edges and optionally rounded corners."""
    if w <= 0 or h <= 0:
        return
    var r = min(radius, min(w, h) / 2)
    var x0 = max(Int(x), 0)
    var y0 = max(Int(y), 0)
    var x1 = min(Int(x + w) + 1, s.width)
    var y1 = min(Int(y + h) + 1, s.height)
    for py in range(y0, y1):
        var cy = Float64(py) + 0.5
        var vy = min(cy - y, y + h - cy) + 0.5  # coverage across the top/bottom edges
        for px in range(x0, x1):
            var cx = Float64(px) + 0.5
            var cov = min(min(cx - x, x + w - cx) + 0.5, vy)
            if r > 0:  # corners: distance to the corner circle
                var dx = max(max(x + r - cx, cx - (x + w - r)), 0.0)
                var dy = max(max(y + r - cy, cy - (y + h - r)), 0.0)
                if dx > 0 and dy > 0:
                    cov = min(cov, r - sqrt(dx * dx + dy * dy) + 0.5)
            if cov > 0:
                plot(s, px, py, color, min(cov, 1.0))


def line(mut s: Surface, x0: Float64, y0: Float64, x1: Float64, y1: Float64, width: Float64, color: UInt32, clear: Bool = False):
    """An anti-aliased line with round ends. `clear`: composited with over() (a see-through canvas keeps its alpha right)."""
    var hw = width / 2
    var minx = max(Int(min(x0, x1) - hw - 1), 0)
    var maxx = min(Int(max(x0, x1) + hw + 2), s.width)
    var miny = max(Int(min(y0, y1) - hw - 1), 0)
    var maxy = min(Int(max(y0, y1) + hw + 2), s.height)
    var dx = x1 - x0
    var dy = y1 - y0
    var len2 = dx * dx + dy * dy
    for py in range(miny, maxy):
        for px in range(minx, maxx):
            var cx = Float64(px) + 0.5
            var cy = Float64(py) + 0.5
            var t = 0.0 if len2 == 0 else min(max(((cx - x0) * dx + (cy - y0) * dy) / len2, 0.0), 1.0)
            var ex = cx - (x0 + t * dx)
            var ey = cy - (y0 + t * dy)
            var cov = hw + 0.5 - sqrt(ex * ex + ey * ey)
            if cov > 0:
                if clear:
                    if 0 <= px < s.width and 0 <= py < s.height:
                        var p = s.pixels().unsafe_offset(py * s.width + px)
                        p[] = over(p[], color, min(cov, 1.0))
                else:
                    plot(s, px, py, color, min(cov, 1.0))


def circle(mut s: Surface, x: Float64, y: Float64, radius: Float64, color: UInt32):
    for py in range(max(Int(y - radius - 1), 0), min(Int(y + radius + 2), s.height)):
        for px in range(max(Int(x - radius - 1), 0), min(Int(x + radius + 2), s.width)):
            var ex = Float64(px) + 0.5 - x
            var ey = Float64(py) + 0.5 - y
            var cov = radius + 0.5 - sqrt(ex * ex + ey * ey)
            if cov > 0:
                plot(s, px, py, color, min(cov, 1.0))


def hline(mut s: Surface, x0: Float64, x1: Float64, y: Float64, color: UInt32, thickness: Float64 = 1):
    """A crisp horizontal rule (snapped to whole pixels)."""
    rect(s, Float64(Int(x0)), Float64(Int(y)), Float64(Int(x1) - Int(x0)), max(Float64(Int(thickness + 0.5)), 1.0), color)


def area(mut s: Surface, xs: List[Float64], ys: List[Float64], bottom: Float64, top_color: UInt32, bottom_color: UInt32):
    """Fills under a polyline (xs ascending) down to `bottom`, fading from top_color at the line's
    highest point to bottom_color at the bottom."""
    if len(xs) < 2:
        return
    var highest = bottom
    for y in ys:
        highest = min(highest, y)
    for px in range(max(Int(xs[0]), 0), min(Int(xs[len(xs) - 1]) + 1, s.width)):
        var cx = Float64(px) + 0.5
        var k = 0
        while k < len(xs) - 2 and xs[k + 1] < cx:
            k += 1
        var t = min(max((cx - xs[k]) / max(xs[k + 1] - xs[k], 1e-9), 0.0), 1.0)
        var ytop = ys[k] + (ys[k + 1] - ys[k]) * t
        for py in range(max(Int(ytop), 0), min(Int(bottom), s.height)):
            var f = (Float64(py) - highest) / max(bottom - highest, 1.0)
            var a1 = Float64(Int((top_color >> 24) & 0xFF))
            var a2 = Float64(Int((bottom_color >> 24) & 0xFF))
            var alpha = (a1 + (a2 - a1) * min(max(f, 0.0), 1.0)) / 255.0
            var cov = min(Float64(py) + 1.0 - ytop, 1.0)  # soft top edge
            plot(s, px, py, with_alpha(top_color, alpha), max(cov, 0.0))


comptime POLY_SUB = 4  # sub-scanlines per pixel row in polygon(): 4 vertical coverage steps, exact horizontally


def _span(mut cov: List[Float64], a: Float64, b: Float64, x0: Int, w: Int, share: Float64):
    """Adds `share` × how much of each pixel [a, b) covers (pixel columns x0 … x0 + w - 1) to cov."""
    var lo = max(a, Float64(x0))
    var hi = min(b, Float64(x0 + w))
    if hi <= lo:
        return
    var ia = Int(lo)
    var ib = Int(hi)
    if ia == ib:
        cov[ia - x0] += (hi - lo) * share
        return
    cov[ia - x0] += (Float64(ia + 1) - lo) * share
    for i in range(ia + 1, min(ib, x0 + w)):
        cov[i - x0] += share
    if ib < x0 + w:
        cov[ib - x0] += (hi - Float64(ib)) * share


def polygon(mut s: Surface, pts: List[Float64], color: UInt32, dx: Float64 = 0, dy: Float64 = 0, k: Float64 = 1):
    """A filled polygon (x, y interleaved; closed implicitly), non-zero winding, anti-aliased, shown at
    (x·k + dx, y·k + dy). Each pixel row is sampled on POLY_SUB lines; along each, the inside spans are exact."""
    var n = len(pts) // 2
    if n < 3:
        return
    var xs = List[Float64](capacity=n)
    var ys = List[Float64](capacity=n)
    var bx0 = 1e30
    var by0 = 1e30
    var bx1 = -1e30
    var by1 = -1e30
    for i in range(n):
        var x = pts[2 * i] * k + dx
        var y = pts[2 * i + 1] * k + dy
        xs.append(x)
        ys.append(y)
        bx0 = min(bx0, x)
        by0 = min(by0, y)
        bx1 = max(bx1, x)
        by1 = max(by1, y)
    var x0 = max(Int(bx0), 0)
    var x1 = min(Int(bx1) + 1, s.width)
    var y0 = max(Int(by0), 0)
    var y1 = min(Int(by1) + 1, s.height)
    if x1 <= x0 or y1 <= y0:
        return
    var w = x1 - x0
    var cov = List[Float64](length=w, fill=0.0)
    var cx = List[Float64]()
    var cd = List[Int]()
    var share = 1.0 / Float64(POLY_SUB)
    for py in range(y0, y1):
        for i in range(w):
            cov[i] = 0.0
        var any = False
        for sub in range(POLY_SUB):
            var sy = Float64(py) + (Float64(sub) + 0.5) * share
            cx.clear()
            cd.clear()
            for i in range(n):
                var j = i + 1 if i + 1 < n else 0
                var ya = ys[i]
                var yb = ys[j]
                if (ya <= sy and sy < yb) or (yb <= sy and sy < ya):
                    var x = xs[i] + (sy - ya) * (xs[j] - xs[i]) / (yb - ya)
                    var d = 1 if yb > ya else -1
                    var at = len(cx)  # (insertion sort: a scan line crosses an ink outline a few times)
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
                    _span(cov, start, cx[c], x0, w, share)
                    any = True
        if any:
            for i in range(w):
                if cov[i] > 0:
                    plot(s, x0 + i, py, color, min(cov[i], 1.0))
