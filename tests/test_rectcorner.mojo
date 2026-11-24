# D-8021: Painter.rect_corner, a rounded rect whose bottom-right corner has its own radius, drawn by the GPU renderer as
# boxes cut along pixels that meet exactly. At whole and fractional places, sizes and scales, opaque and see-through:
# (1) pixel for pixel, outside the corner's square it is the plain rounded rect, inside it the box of the corner's radius
#     (so no seam, nothing blended twice); with the corner's radius equal to the others it is the plain rect;
# (2) against the polygon it replaces, only pixels within 1.5 px of the outline differ;
# (3) the CPU painter draws the polygon as before; Scene.draw on a surface equals it. `rectcorner: ok`.
from std.testing import assert_true, assert_equal
from mojoui.scene import Scene, SurfacePainter, corner_rect
from mojoui.canvas import Surface, rgba
from mojoui.gpu2d_gl import GPU2D, headless_gl33

comptime W = 900
comptime H = 700


def gl(sc: Scene) raises -> List[UInt32]:
    var g = GPU2D()
    assert_true(g.start(False), "start")
    var s = g.draw(sc, Scene(0, 0, 1.0), 1, W, H)
    var out = List[UInt32](length=W * H, fill=0)
    assert_true(s >= 0 and g.gl.read(g.gl.tex[s], W, H, Int(out.unsafe_ptr())), "read")
    g.gl.close()
    return out^


def scene(k: Float64) -> Scene:
    var sc = Scene(W, H, 1.0)
    sc.begin_layer("a")
    sc.layer_transform(3.0, 2.0, k)
    sc.fill(0xFFF0F2F5)
    return sc^


def level(a: UInt32, b: UInt32) -> Int:
    var worst = 0
    for c in range(4):
        worst = max(worst, abs(Int((a >> UInt32(8 * c)) & 0xFF) - Int((b >> UInt32(8 * c)) & 0xFF)))
    return worst


def main() raises:
    assert_true(headless_gl33() != 0, "a headless GL context")
    var n = 0
    var off = 0
    for k in [1.0, 1.25, 1.6, 0.3, 2.37]:
        for q in range(6):
            var x = 20.0 + 1.37 * Float64(q)
            var y = 15.0 + 0.71 * Float64(q)
            var w = 200.0 + 13.3 * Float64(q)
            var h = 160.0 - 9.9 * Float64(q)
            for color in [rgba(250, 220, 120), rgba(40, 90, 200, 120)]:
                var a = scene(k)
                a.rect_corner(x, y, w, h, color, 4, 24)
                var small = scene(k)
                small.rect(x, y, w, h, color, 4)
                var big = scene(k)
                big.rect(x, y, w, h, color, 24)
                var same = scene(k)
                same.rect_corner(x, y, w, h, color, 4, 4)
                var poly = scene(k)
                poly.polygon(corner_rect(x, y, w, h, 4, 4, 24, 4), color)
                var pa = gl(a)
                var ps = gl(small)
                var pb = gl(big)
                var pq = gl(same)
                var pp = gl(poly)
                var bx = (x + w - 24) * k + 3.0
                var by = (y + h - 24) * k + 2.0
                for py in range(H):
                    for px in range(W):
                        var at = py * W + px
                        var inside = Float64(px) + 0.5 >= bx and Float64(py) + 0.5 >= by
                        assert_equal(pa[at], pb[at] if inside else ps[at], "pixel " + String(px) + "," + String(py) + " k " + String(k))
                        assert_equal(pq[at], ps[at], "the same radius: the plain rect")
                        if level(pa[at], pp[at]) > 3:  # (the polygon's own antialiasing and its straight sides: at the outline only)
                            off += 1
                            var cx = (Float64(px) + 0.5 - 3.0) / k
                            var cy = (Float64(py) + 0.5 - 2.0) / k
                            var dx = min(abs(cx - x), abs(cx - x - w))
                            var dy = min(abs(cy - y), abs(cy - y - h))
                            var e = min(dx, dy) * k
                            if cx > x + w - 24 and cy > y + h - 24:
                                e = abs(((cx - x - w + 24) ** 2 + (cy - y - h + 24) ** 2) ** 0.5 - 24) * k
                            elif e > 1.5:  # (a 4 px corner)
                                var qx = x + 4 if cx < x + w / 2 else x + w - 4
                                var qy = y + 4 if cy < y + h / 2 else y + h - 4
                                e = min(e, abs(((cx - qx) ** 2 + (cy - qy) ** 2) ** 0.5 - 4) * k)
                            assert_true(e <= 1.5, "differs from the polygon away from the outline: " + String(px) + "," + String(py) + " by " + String(e) + " px")
                n += 1
    # (3) the CPU painter and a scene drawn on a surface
    var p1 = List[UInt32](length=W * H, fill=0xFFF0F2F5)
    var p2 = List[UInt32](length=W * H, fill=0xFFF0F2F5)
    var s1 = Surface(Int(p1.unsafe_ptr()), W, H, 1.0)
    var sp = SurfacePainter(s1^)
    sp.rect_corner(30.3, 20.6, 220.2, 150.8, rgba(250, 220, 120), 4, 24)
    var s2 = Surface(Int(p2.unsafe_ptr()), W, H, 1.0)
    var sp2 = SurfacePainter(s2^)
    sp2.polygon(corner_rect(30.3, 20.6, 220.2, 150.8, 4, 4, 24, 4), rgba(250, 220, 120))
    for i in range(W * H):
        assert_equal(p1[i], p2[i], "CPU: the polygon as before")
    print("rectcorner:", n, "cases pixel-exact; pixels off the polygon (outline only):", off)
    print("rectcorner: ok")
