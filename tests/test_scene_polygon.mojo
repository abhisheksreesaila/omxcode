# Filled paths and layer transforms in the Scene (goal 40 M1): the CPU painter fills a polygon antialiased; a Scene
# records it as its own op and replays it into the same pixels as painting directly; a layer drawn once and shown
# moved and scaled (layer_transform) equals drawing it there; a layer that only gained ops at its end says so (appends:
# a host adds the new ops to what it kept, D-1219).
#   pixi run mojo run -I . tests/test_scene_polygon.mojo
from std.testing import assert_true, assert_equal

from mojoui.canvas import Surface
from mojoui.draw import polygon
from mojoui.text import Font
from mojoui.scene import Scene, SurfacePainter, Painter, OP_POLY
from mojoui.ink import Stroke

comptime W = 200
comptime H = 160


def red(px: List[UInt32], x: Int, y: Int) -> Int:
    return Int(px[y * W + x] & 0xFF)


def worst(a: List[UInt32], b: List[UInt32]) -> Int:
    """The largest difference of any channel of any pixel."""
    var m = 0
    for i in range(len(a)):
        for sh in range(0, 32, 8):
            m = max(m, abs(Int((a[i] >> UInt32(sh)) & 0xFF) - Int((b[i] >> UInt32(sh)) & 0xFF)))
    return m


def shapes[P: Painter](mut p: P):
    """What both sides draw: a triangle, a star (overlapping, filled by non-zero winding) and an ink stroke."""
    p.fill(0xFF000000)
    var tri: List[Float64] = [20.0, 20.0, 120.0, 30.0, 40.0, 110.0]
    p.polygon(tri, 0xFFFFFFFF)
    var star = List[Float64]()
    for k in range(5):
        var a = k * 2 % 5
        star.append(150.0 + 30.0 * [0.0, 0.951, 0.588, -0.588, -0.951][a])
        star.append(60.0 - 30.0 * [1.0, 0.309, -0.809, -0.809, 0.309][a])
    p.polygon(star, 0xFF3366CC)
    var s = Stroke(9.0, 0xFF22AA44)
    for i in range(12):
        s.add(30.0 + 12.0 * Float64(i), 130.0 + 10.0 * Float64(i % 3), 0.2 + 0.07 * Float64(i))
    s.draw(p)


def test_cpu() raises:
    var px = List[UInt32](length=W * H, fill=0)
    var sp = SurfacePainter(Surface(Int(px.unsafe_ptr()), W, H, 1.0))
    sp.fill(0xFF000000)
    var tri: List[Float64] = [20.0, 20.0, 120.0, 30.0, 40.0, 110.0]
    sp.polygon(tri, 0xFFFFFFFF)
    assert_equal(red(px, 50, 50), 255, "inside is full")
    assert_equal(red(px, 150, 100), 0, "outside is empty")
    assert_equal(red(px, 5, 5), 0, "outside is empty")
    var between = 0
    for x in range(20, 130):  # along the slanted top edge: some pixel is partly covered
        var v = red(px, x, 25)
        if v > 0 and v < 255:
            between += 1
    assert_true(between > 0, "an edge pixel is strictly between")
    var star = List[Float64]()
    var sx: List[Float64] = [0.0, 0.951, 0.588, -0.588, -0.951]
    var sy: List[Float64] = [1.0, 0.309, -0.809, -0.809, 0.309]
    for k in range(5):
        var a = k * 2 % 5
        star.append(100.0 + 50.0 * sx[a])
        star.append(80.0 - 50.0 * sy[a])
    sp.fill(0xFF000000)
    sp.polygon(star, 0xFFFFFFFF)
    assert_equal(red(px, 100, 80), 255, "a star's middle is filled (non-zero winding, not even-odd)")
    print("polygon cpu: ok")


def test_scene() raises:
    var font = Font()
    var a = List[UInt32](length=W * H, fill=0)
    var b = List[UInt32](length=W * H, fill=0)
    var sp = SurfacePainter(Surface(Int(a.unsafe_ptr()), W, H, 1.0))
    shapes(sp)
    var sc = Scene(W, H, 1.0)
    shapes(sc)
    var polys = 0
    for op in range(sc.ops()):
        if Int(sc.kinds[op]) == OP_POLY:
            polys += 1
    assert_equal(polys, 3, "each polygon is one op")
    var sb = Surface(Int(b.unsafe_ptr()), W, H, 1.0)
    sc.raster(sb, font)
    assert_equal(worst(a, b), 0, "the replay paints what painting directly did")
    var again = Scene(W, H, 1.0)
    shapes(again)
    assert_true(again.same_layer(0, sc, 0), "the same polygons are the same layer")
    var other = Scene(W, H, 1.0)
    other.fill(0xFF000000)
    var tri: List[Float64] = [20.0, 20.0, 120.0, 30.0, 40.0, 111.0]
    other.polygon(tri, 0xFFFFFFFF)
    var tri2: List[Float64] = [20.0, 20.0, 120.0, 30.0, 40.0, 110.0]
    var other2 = Scene(W, H, 1.0)
    other2.fill(0xFF000000)
    other2.polygon(tri2, 0xFFFFFFFF)
    assert_true(not other.same_layer(0, other2, 0), "a moved point is a new picture")
    print("polygon scene: ok")


def ink[P: Painter](mut p: P, k: Float64, dx: Float64, dy: Float64):
    """Strokes drawn at (x·k + dx, y·k + dy) by hand (the reference)."""
    var tri: List[Float64] = [10.0 * k + dx, 10.0 * k + dy, 60.0 * k + dx, 15.0 * k + dy, 20.0 * k + dx, 55.0 * k + dy]
    p.polygon(tri, 0xFFFFFFFF)
    var s = Stroke(6.0, 0xFF22AA44)  # (the same outline, moved: a stroke made at another size is sampled differently)
    for i in range(10):
        s.add(10.0 + 6.0 * Float64(i), 60.0 + 5.0 * Float64(i % 2), 0.3 + 0.07 * Float64(i))
    var o = s.outline()
    for z in range(len(o)):
        o[z] = o[z] * k + (dx if z % 2 == 0 else dy)
    p.polygon(o, s.color)
    p.rect(5 * k + dx, 5 * k + dy, 8 * k, 4 * k, 0xFFCC3333, 1 * k)


def test_layer_transform() raises:
    var font = Font()
    var a = List[UInt32](length=W * H, fill=0)
    var b = List[UInt32](length=W * H, fill=0)
    var c = List[UInt32](length=W * H, fill=0)
    var k = 1.75
    var dx = 37.0
    var dy = 12.5
    var sp = SurfacePainter(Surface(Int(a.unsafe_ptr()), W, H, 1.0))
    sp.begin_layer("paper")
    sp.fill(0xFF000000)
    sp.begin_layer("ink")
    ink(sp, k, dx, dy)  # drawn there
    var sc = Scene(W, H, 1.0)
    sc.begin_layer("paper")
    sc.fill(0xFF000000)
    sc.begin_layer("ink")
    sc.layer_transform(dx, dy, k)
    ink(sc, 1.0, 0.0, 0.0)  # drawn once at the origin, shown there
    var sb = Surface(Int(b.unsafe_ptr()), W, H, 1.0)
    sc.raster(sb, font)
    var d1 = worst(a, b)
    assert_true(d1 <= 1, "the transformed layer equals drawing it there (within 1 level): " + String(d1))
    var sp2 = SurfacePainter(Surface(Int(c.unsafe_ptr()), W, H, 1.0))
    sp2.begin_layer("paper")
    sp2.fill(0xFF000000)
    sp2.begin_layer("ink")
    sp2.layer_transform(dx, dy, k)
    ink(sp2, 1.0, 0.0, 0.0)
    var d2 = worst(a, c)
    assert_true(d2 <= 1, "the CPU painter honours the transform too: " + String(d2))
    var moved = Scene(W, H, 1.0)
    moved.begin_layer("paper")
    moved.fill(0xFF000000)
    moved.begin_layer("ink")
    moved.layer_transform(dx + 40, dy, k * 0.5)
    ink(moved, 1.0, 0.0, 0.0)
    assert_true(moved.same_layer(1, sc, 1) and moved.moved(1), "a pan or zoom keeps the layer's picture: the host only moves it")
    print("layer transform: ok")


def strokes(mut sc: Scene, n: Int, version: Int):
    """Paper, then n strokes in the "ink" layer (its version given), then a "wet" one."""
    sc.begin_layer("paper")
    sc.fill(0xFFFFFFFF)
    sc.begin_layer("ink")
    sc.layer_version(version)
    sc.layer_transform(10, 20, 2)
    for k in range(n):
        var s = Stroke(4.0, 0xFF000000 + UInt32(k))
        for i in range(6):
            s.add(10.0 + 8.0 * Float64(i), 10.0 + 9.0 * Float64(k), 0.5)
        s.seal()
        s.draw(sc)
    sc.begin_layer("wet")


def test_appends() raises:
    var a = Scene(W, H, 1.0)
    strokes(a, 3, 1)
    var b = Scene(W, H, 1.0)
    strokes(b, 5, 2)
    assert_true(not b.same_layer(1, a, 1), "a new version is a new picture")
    assert_equal(b.appends(1, a, 1), a.layer_range(1)[1] - a.layer_range(1)[0], "two strokes more: the first three are shared")
    assert_equal(a.appends(1, b, 1), -1, "fewer strokes (an undo, an erase) aren't an append")
    assert_equal(a.appends(1, a, 1), -1, "the same strokes aren't an append")
    assert_equal(b.appends(0, a, 1), -1, "another layer isn't an append")
    var c = Scene(W, H, 1.0)  # (stroke 0 gone: the rest shifts, nothing is shared at the start)
    c.begin_layer("paper")
    c.fill(0xFFFFFFFF)
    c.begin_layer("ink")
    for k in range(1, 5):
        var s = Stroke(4.0, 0xFF000000 + UInt32(k))
        for i in range(6):
            s.add(10.0 + 8.0 * Float64(i), 10.0 + 9.0 * Float64(k), 0.5)
        s.seal()
        s.draw(c)
    assert_equal(c.appends(1, a, 1), -1, "a changed first stroke isn't an append")
    var box = c.removes(1, b, 1)  # (c is b without its first stroke: y 10 ± the width)
    assert_equal(len(box), 4, "a stroke taken out is a removal")
    assert_true(box[1] < 10 and box[3] > 10 and box[3] < 19, "the box is around the first stroke only: " + String(box[1]) + ".." + String(box[3]))
    assert_equal(len(a.removes(1, b, 1)), 4, "the last two strokes taken out is a removal too")
    assert_equal(len(b.removes(1, a, 1)), 0, "strokes added aren't a removal")
    assert_equal(len(c.removes(1, a, 1)), 0, "a stroke taken out and another added isn't a removal")
    print("layer append: ok")


def main() raises:
    test_cpu()
    test_scene()
    test_layer_transform()
    test_appends()
