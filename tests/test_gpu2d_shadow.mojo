# Goal 80 M4: Gaussian shadows. Painter.shadow(x, y, w, h, radius, blur, color) on every painter, drawn by the CPU
# executor and the GL backend with GPUI's analytic formula (mojoui.shadow). Proves:
#   (a) the CPU executor's picture is within 1 level (mean, over the shadow's pixels) of a brute-force 2-D Gaussian
#       convolution of the hard rounded box (numerical, 0.2 px grid), for blurs 0–32 and radii 0–24, at zoom 1 and in scaled layers;
#   (b) GL within goal 75's bounds of the CPU executor (mean ≤ 1.5 levels, ≤ 0.5 % of pixels more than 40 off) for those
#       cases and for overlapping, clipped, translucent and scaled shadows over content;
#   (c) the Scene's own CPU replay and SurfacePainter draw what the executor draws (same math, mean ≤ 0.5 levels);
#   (d) culling keeps a shadow whose box is outside the clip but whose blur reaches in.
#   pixi run mojo run -I . tests/test_gpu2d_shadow.mojo
from std.testing import assert_true
from std.math import exp, sqrt

from mojoui.canvas import Surface, rgba
from mojoui.text import Font
from mojoui.scene import Scene, SurfacePainter
from mojoui.gpu2d import GlyphAtlas, Frame2D, build_batches, execute_cpu
from mojoui.gpu2d_gl import GL2D, headless_gl33
from tests.test_gpu2d import diff
from tests.test_gpu2d_gl import cpu_of, gl_of


def inside_box(px: Float64, py: Float64, x: Float64, y: Float64, w: Float64, h: Float64, r: Float64) -> Bool:
    if px < x or px > x + w or py < y or py > y + h:
        return False
    var rr = min(r, min(w, h) / 2)
    var dx = max(max(x + rr - px, px - (x + w - rr)), 0.0)
    var dy = max(max(y + rr - py, py - (y + h - rr)), 0.0)
    return dx * dx + dy * dy <= rr * rr


def brute_field(W: Int, H: Int, x: Float64, y: Float64, w: Float64, h: Float64, r: Float64, sigma: Float64) -> List[Float64]:
    """The hard rounded box convolved with a 2-D Gaussian, numerically: the box sampled on a 5× grid (0.2 px), blurred by
    the separable Gaussian sampled at the same spacing (normalized, ±4 sigma), read at each pixel's centre."""
    var S = 5
    var gw = W * S
    var gh = H * S
    var m = List[Float64](length=gw * gh, fill=0)
    for j in range(gh):
        var py = (Float64(j) + 0.5) / Float64(S)
        for i in range(gw):
            if inside_box((Float64(i) + 0.5) / Float64(S), py, x, y, w, h, r):
                m[j * gw + i] = 1
    var sg = sigma * Float64(S)
    var rad = Int(4 * sg) + 1
    var k = List[Float64]()
    var tot = 0.0
    for t in range(-rad, rad + 1):
        var v = exp(-(Float64(t) * Float64(t)) / (2 * sg * sg))
        k.append(v)
        tot += v
    for t in range(len(k)):
        k[t] /= tot
    var tmp = List[Float64](length=gw * gh, fill=0)
    for j in range(gh):  # rows
        for i in range(gw):
            var acc = 0.0
            for t in range(-rad, rad + 1):
                var ii = i + t
                if ii >= 0 and ii < gw:
                    acc += m[j * gw + ii] * k[t + rad]
            tmp[j * gw + i] = acc
    var out = List[Float64](length=W * H, fill=0)
    for py in range(H):  # columns, only at the pixel centres (the grid cell S·p + S/2)
        var j = py * S + S // 2
        for px in range(W):
            var i = px * S + S // 2
            var acc = 0.0
            for t in range(-rad, rad + 1):
                var jj = j + t
                if jj >= 0 and jj < gh:
                    acc += tmp[jj * gw + i] * k[t + rad]
            out[py * W + px] = acc
    return out^


def against_brute(name: String, blur: Float64, radius: Float64, k: Float64, atlas: GlyphAtlas, font: Font) raises -> Float64:
    """(a) A black shadow on white, layer zoom k: the executor's picture vs the brute-force convolution, mean levels over
    pixels either one inks."""
    var W = 220
    var H = 170
    var sc = Scene(W, H, 1.0)
    sc.begin_layer("s")
    sc.fill(rgba(255, 255, 255))
    sc.begin_layer("shadow")
    sc.layer_transform(7, 5, k)
    var bx = 60.0 / k
    var by = 45.0 / k
    var bw = 90.0 / k
    var bh = 60.0 / k
    sc.shadow(bx, by, bw, bh, radius / k, blur / k, rgba(0, 0, 0))
    var got = cpu_of(build_batches(sc, atlas, font), atlas)
    var sigma = max(blur / 2, 0.25)
    var field = brute_field(W, H, 60 + 7, 45 + 5, 90, 60, radius, sigma)
    var sum = 0.0
    var n = 0
    var worst = 0.0
    for py in range(H):
        for px in range(W):
            var cov = field[py * W + px]
            var want = 255.0 * (1 - cov)
            var have = Float64(Int(got[py * W + px] & 0xFF))
            if cov > 0.002 or have < 254.5:
                var dd = abs(have - want)
                sum += dd
                worst = max(worst, dd)
                n += 1
    var mean = sum / Float64(max(n, 1))
    print("  brute", name, ": mean", round(mean, 3), "levels over", n, "pixels, worst", round(worst, 1))
    return mean


def main() raises:
    var ctx = headless_gl33()
    assert_true(ctx != 0, "a headless GL 3.3 core context")
    var gl = GL2D()
    assert_true(gl.start(False), gl.why)
    var font = Font()
    var atlas = GlyphAtlas(font)
    gl.upload_atlas(atlas)
    # (a) against the brute-force convolution
    var blurs: List[Float64] = [0, 2, 6, 16, 32]
    var radii: List[Float64] = [0, 6, 24]
    for b in blurs:
        for r in radii:
            var m = against_brute("blur " + String(b) + " radius " + String(r), b, r, 1.0, atlas, font)
            assert_true(m <= 1.0, "the CPU shadow is " + String(m) + " levels from the brute-force convolution")
    for k in [0.6, 1.7]:
        var m = against_brute("blur 12 radius 10 in a layer zoomed " + String(k), 12, 10, k, atlas, font)
        assert_true(m <= 1.0, "the zoomed CPU shadow is " + String(m) + " levels from the brute-force convolution")
    # (b) GL vs the CPU executor
    var cases = 0
    for b in blurs:
        for r in [0.0, 6.0, 24.0]:
            var sc = Scene(240, 180, 1.0)
            sc.fill(rgba(246, 245, 243))
            sc.rect(20, 20, 60, 40, rgba(40, 120, 220), 6)
            sc.shadow(60, 50, 110, 70, r, b, rgba(10, 20, 30, 140))  # (translucent, over content)
            sc.shadow(90, 80, 80, 60, r / 2, b / 2 + 1, rgba(200, 40, 40, 90))  # (overlapping)
            sc.rect(70, 60, 90, 50, rgba(255, 255, 255), r)
            var f = build_batches(sc, atlas, font)
            var d = diff(cpu_of(f, atlas), gl_of(gl, f))
            print("  GL vs CPU blur", b, "radius", r, ": mean", round(d.mean, 4), "levels,", round(d.far, 4), "% far")
            assert_true(d.mean <= 1.5 and d.far <= 0.5, "GL's shadow differs from the CPU executor")
            cases += 1
    # clipped, in a scaled, moved layer
    var sc = Scene(300, 220, 1.0)
    sc.fill(rgba(255, 255, 255))
    sc.begin_layer("cards")
    sc.layer_transform(-20, 12, 1.6)
    sc.push_clip(20, 10, 120, 80)
    for i in range(6):
        sc.shadow(10 + Float64(i) * 25, 20 + Float64(i % 3) * 18, 40, 30, 6, 4 + Float64(i) * 3, rgba(0, 0, 0, 60))
    sc.pop_clip()
    var fz = build_batches(sc, atlas, font)
    var dz = diff(cpu_of(fz, atlas), gl_of(gl, fz))
    print("  GL vs CPU clipped, zoom 1.6: mean", round(dz.mean, 4), "levels,", round(dz.far, 4), "% far")
    assert_true(dz.mean <= 1.5 and dz.far <= 0.5, "GL's clipped, zoomed shadows differ from the CPU executor")
    # (c) the Scene's CPU replay and SurfacePainter
    var px1 = List[UInt32](length=300 * 220, fill=0)
    var s1 = Surface(Int(px1.unsafe_ptr()), 300, 220, 1.0)
    sc.raster(s1, font)
    var dc = diff(cpu_of(fz, atlas), px1)
    var px2 = List[UInt32](length=300 * 220, fill=0)
    var s2 = Surface(Int(px2.unsafe_ptr()), 300, 220, 1.0)
    var sp = SurfacePainter(s2^)
    sp.fill(rgba(255, 255, 255))
    sp.begin_layer("cards")
    sp.layer_transform(-20, 12, 1.6)
    sp.push_clip(20, 10, 120, 80)
    for i in range(6):
        sp.shadow(10 + Float64(i) * 25, 20 + Float64(i % 3) * 18, 40, 30, 6, 4 + Float64(i) * 3, rgba(0, 0, 0, 60))
    sp.pop_clip()
    var ds = diff(cpu_of(fz, atlas), px2)
    print("  Scene replay vs executor: mean", round(dc.mean, 4), "; SurfacePainter vs executor: mean", round(ds.mean, 4))
    assert_true(dc.mean <= 0.5 and ds.mean <= 0.5, "the CPU painters' shadows differ from the executor's")
    # (d) a shadow whose box is outside the clip, its blur reaching in, is kept
    var sd = Scene(200, 120, 1.0)
    sd.fill(rgba(255, 255, 255))
    sd.push_clip(0, 0, 100, 120)
    sd.shadow(104, 30, 60, 50, 4, 24, rgba(0, 0, 0))
    sd.pop_clip()
    var cd = cpu_of(build_batches(sd, atlas, font), atlas)
    var dark = 0
    for y in range(120):
        for x in range(100):
            if (cd[y * 200 + x] & 0xFF) < 250:
                dark += 1
    print("  blur reaching into the clip from outside it:", dark, "pixels shaded")
    assert_true(dark > 200, "a shadow whose blur reaches into the clip was culled")
    print("gpu2d shadow: ok")
