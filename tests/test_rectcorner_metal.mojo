# D-8021 on the Mac: Painter.rect_corner drawn by Metal, held to what tests/test_rectcorner.mojo holds GL to: pixel for pixel the
# plain rounded rect outside the corner's square and the box of the corner's radius inside it, and against the polygon it
# replaces only pixels within 1.5 px of the outline differ. The Mac draws it only after this has passed there. A Mac only
# (built as tests/test_gpu2d_metal.mojo). `rectcorner metal: ok`
from std.testing import assert_true, assert_equal
from mojoui.scene import Scene, corner_rect
from mojoui.canvas import rgba
from mojoui.text import Font
from mojoui.gpu2d import GlyphAtlas, build_batches
from mojoui.gpu2d_metal import Metal2D, read_iosurface
from mojoui.hosts.apple_canvas import io_surface, cfunc

comptime W = 900
comptime H = 700


def metal(sc: Scene, mut mtl: Metal2D, atlas: GlyphAtlas, font: Font) raises -> List[UInt32]:
    var frame = build_batches(sc, atlas, font)
    var io = io_surface(W, H)
    assert_true(io != 0 and mtl.render(frame, io, W, H), "Metal didn't draw it")
    var got = read_iosurface(io, W, H)
    mtl.forget(io)
    cfunc[NoneType]("CFRelease", io)
    return got^


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
    var font = Font()
    var atlas = GlyphAtlas(font)
    var mtl = Metal2D(atlas)
    assert_true(mtl.ok, "no Metal: " + mtl.why)
    print("Metal device:", mtl.name)
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
                var pa = metal(a, mtl, atlas, font)
                var ps = metal(small, mtl, atlas, font)
                var pb = metal(big, mtl, atlas, font)
                var pq = metal(same, mtl, atlas, font)
                var pp = metal(poly, mtl, atlas, font)
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
    print("rectcorner metal:", n, "cases pixel-exact; pixels off the polygon (outline only):", off)
    print("rectcorner metal: ok")
