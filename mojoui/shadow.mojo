# Gaussian shadows of rounded rectangles (goal 80), as GPUI draws them (NOTICE): the box's coverage blurred by a
# Gaussian, after Evan Wallace's "fast rounded rectangle shadows" (madebyevan.com/shaders/fast-rounded-rectangle-shadows):
# exact across x (the integral of a Gaussian is erf), and exact along y over the box's straight middle; only the rounded
# corners' bands are sampled (goal 80: GPUI samples the whole height, so its solid middle stops at 99.7 %). `blur` is CSS's blur
# radius (box-shadow, filter: blur), twice the Gaussian's standard deviation; the shadow reaches 3 sigma past its box.
# The same math runs in the GL and Metal quad shaders (mojoui.gpu2d_gl, gpu2d_metal) and the CPU executor (gpu2d):
# tests/test_gpu2d_shadow holds them to each other and to a brute-force 2-D convolution.
#
#   shadow_alpha(px, py, hx, hy, corner, sigma)   coverage 0–1 at p (from the box's centre), half size (hx, hy)
#   draw_shadow(s, x, y, w, h, radius, sigma, color)   into a Surface (its clip honoured), pixels

from std.math import sqrt
from mojoui.canvas import Surface
from mojoui.draw import blend

comptime SQRT_HALF = 0.7071067811865476


@always_inline
def _erf(x: Float64) -> Float64:
    """erf by Abramowitz & Stegun 7.1.27 (as the shaders: |error| < 5e-4)."""
    var a = abs(x)
    var t = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a
    t *= t
    var v = 1.0 - 1.0 / (t * t)
    return v if x >= 0 else -v


@always_inline
def _blur_along_x(x: Float64, y: Float64, sigma: Float64, corner: Float64, hx: Float64, hy: Float64) -> Float64:
    var delta = min(hy - corner - abs(y), 0.0)
    var curved = hx - corner + sqrt(max(0.0, corner * corner - delta * delta))
    var lo = 0.5 + 0.5 * _erf((x - curved) * (SQRT_HALF / sigma))
    var hi = 0.5 + 0.5 * _erf((x + curved) * (SQRT_HALF / sigma))
    return hi - lo


@always_inline
def _side(x: Float64, half: Float64, k: Float64) -> Float64:
    """How much of a Gaussian centred at x falls between −half and half."""
    return 0.5 * (_erf((x + half) * k) - _erf((x - half) * k))


def shadow_at(x: Float64, y: Float64, w: Float64, h: Float64, corner: Float64, sigma: Float64, col: Tuple[Float64, Float64], row: Tuple[Float64, Float64]) -> Float64:
    """shadow_alpha with what its column (shadow_columns) and row (shadow_row) share already worked out."""
    var c = min(abs(corner), min(w, h))
    var reach = 3.0 * sigma
    var ax = abs(x)
    var ay = abs(y)
    if ax > w + reach + 1.0 or ay > h + reach + 1.0:  # (past the reach: nothing; the shaders cut their quads there)
        return 0.0
    if ax + reach <= w - c:  # (every row within reach is full width here: the height's blur alone)
        return row[0]
    if ay + reach <= h - c:
        return col[0]
    # above the corner's diagonal the rows narrow ever faster: there the box is sliced by columns (it is its own transpose)
    var turn = ay - h > ax - w
    var px = y if turn else x
    var py = x if turn else y
    var hx = h if turn else w
    var hy = w if turn else h
    var alpha = row[0] * col[1] if turn else col[0] * row[1]
    if c > 0.0:
        var s = hy - c
        var k = SQRT_HALF / sigma
        for side in range(2):  # the corner bands [s, hy] and [−hy, −s], where the rows narrow
            var lo = max(s if side == 0 else -hy, py - reach)
            var hi = min(hy if side == 0 else -s, py + reach)
            if hi <= lo:
                continue
            # (4 slices: each one's Gaussian weight exact, by erf; only the row's width is taken, at its middle)
            var step = (hi - lo) * 0.25
            var e0 = _erf((py - lo) * k)
            for i in range(1, 5):
                var y1 = lo + step * Float64(i)
                var e1 = _erf((py - y1) * k)
                alpha += _blur_along_x(px, y1 - 0.5 * step, sigma, c, hx, hy) * 0.5 * (e0 - e1)
                e0 = e1
    return min(max(alpha, 0.0), 1.0)


def shadow_columns(x0: Int, x1: Int, cx: Float64, hx: Float64, hy: Float64, corner: Float64, sigma: Float64) -> List[Tuple[Float64, Float64]]:
    """Per pixel column x0 … x1 − 1 of a box centred at cx: its share of the whole width, and of the straight part
    (between the corners)."""
    var out = List[Tuple[Float64, Float64]](capacity=max(x1 - x0, 1))
    var k = SQRT_HALF / sigma
    var c = min(abs(corner), min(hx, hy))
    for px in range(x0, x1):
        out.append((_side(Float64(px) + 0.5 - cx, hx, k), _side(Float64(px) + 0.5 - cx, hx - c, k)))
    return out^


def shadow_row(py: Float64, hy: Float64, corner: Float64, sigma: Float64) -> Tuple[Float64, Float64]:
    """A row's share along y: of the whole height, and of the straight middle (between the corner bands)."""
    var k = SQRT_HALF / sigma
    return (_side(py, hy, k), _side(py, hy - abs(corner), k))


def shadow_alpha(px: Float64, py: Float64, hx: Float64, hy: Float64, corner: Float64, sigma: Float64) -> Float64:
    """The shadow's coverage (0–1) at p, measured from the box's centre; half size (hx, hy), corner radius, sigma > 0
    (pixels). Across x the blur is exact (erf). Along y, the rows of the box's straight middle all blur alike across x,
    so that part is exact too (one more erf): only the two corner bands (c tall) are sampled, 4 slices each within
    3 sigma, their Gaussian weights exact (GPUI samples the whole height). Away from the corners, and for square ones, it is exact up to erf's
    approximation."""
    var c = min(abs(corner), min(hx, hy))
    var k = SQRT_HALF / sigma
    return shadow_at(px, py, hx, hy, c, sigma, (_side(px, hx, k), _side(px, hx - c, k)), shadow_row(py, hy, c, sigma))


def shadow_reach(sigma: Float64) -> Float64:
    """How far past its box a shadow has pixels: 3 sigma (+ a pixel)."""
    return 3.0 * sigma + 1.0


def draw_shadow(mut s: Surface, x: Float64, y: Float64, w: Float64, h: Float64, radius: Float64, sigma: Float64, color: UInt32):
    """The shadow of the rounded box (x, y, w, h) blended into s within its clip; sizes in pixels."""
    if w <= 0 or h <= 0:
        return
    var sg = max(sigma, 0.25)
    var g = shadow_reach(sg)
    var hx = w / 2
    var hy = h / 2
    var cx0 = x + hx
    var cy0 = y + hy
    var r = min(radius, min(hx, hy))
    var x0 = max(Int(x - g), s.clip_x0)
    var y0 = max(Int(y - g), s.clip_y0)
    var x1 = min(Int(x + w + g) + 1, s.clip_x1)
    var y1 = min(Int(y + h + g) + 1, s.clip_y1)
    var p = s.pixels()
    for py in range(max(y0, 0), min(y1, s.height)):
        for px in range(max(x0, 0), min(x1, s.width)):
            var a = shadow_alpha(Float64(px) + 0.5 - cx0, Float64(py) + 0.5 - cy0, hx, hy, r, sg)
            if a > 0.0:
                var d = p.unsafe_offset(py * s.width + px)
                d[] = blend(d[], color, min(a, 1.0))
