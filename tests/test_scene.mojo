# The Scene (goal 26 M2, M3): a display list replays to exactly the pixels the drawing calls make; the grid recorded
# as a Scene replays to exactly the grid drawn into pixels; its cells and its ring are separate layers, so a host
# can tell when only the ring moved; the cells' text can be read from the list.
#   pixi run mojo run -I . tests/test_scene.mojo
from std.testing import assert_equal, assert_true, assert_false

from mojoui import Event, KEY
from mojoui.canvas import Surface
from mojoui.draw import rect, line, circle
from mojoui.text import Font, REGULAR, MEDIUM, LEFT, RIGHT
from mojoui.theme import Palette
from themes.liquid import liquid_palette
from mojoui.scene import Scene, SurfacePainter, OP_TEXT
from mojoui.datagrid import DataGrid
from tests.test_datagrid import People


def same(a: List[UInt32], b: List[UInt32]) -> Int:
    """How many pixels differ."""
    var n = 0
    for i in range(len(a)):
        if a[i] != b[i]:
            n += 1
    return n


def test_a_scene_replays_to_the_same_pixels() raises:
    var font = Font()
    var a = List[UInt32](length=300 * 120, fill=0)
    var b = List[UInt32](length=300 * 120, fill=0)
    var sa = Surface(Int(a.unsafe_ptr()), 300, 120, 2.0)
    sa.fill(0xFFFFFFFF)
    rect(sa, 10, 10, 120, 40, 0xFF86_7C0E, 8)
    line(sa, 0, 60, 300, 60, 1, 0xFF00_0000)
    circle(sa, 200, 30, 12, 0xFF33_22EE)
    font.draw(sa, "1,204.50", 290, 100, 26, 0xFF2A_170F, MEDIUM, RIGHT, 0)
    var sc = Scene(300, 120, 2.0)
    sc.fill(0xFFFFFFFF)
    sc.rect(10, 10, 120, 40, 0xFF86_7C0E, 8)
    sc.line(0, 60, 300, 60, 1, 0xFF00_0000)
    sc.circle(200, 30, 12, 0xFF33_22EE)
    sc.text(font, "1,204.50", 290, 100, 26, 0xFF2A_170F, MEDIUM, RIGHT, 0)
    var sb = Surface(Int(b.unsafe_ptr()), 300, 120, 2.0)
    sc.raster(sb, font)
    assert_equal(same(a, b), 0, "the replay draws every pixel the calls did")
    assert_equal(sc.ops(), 5)


def test_the_grid_as_a_scene_is_the_grid() raises:
    var font = Font()
    var pal = liquid_palette()
    var src = People(0)
    var w = 900
    var h = 500
    var g1 = DataGrid()
    var g2 = DataGrid()
    var a = List[UInt32](length=w * h, fill=0)
    var b = List[UInt32](length=w * h, fill=0)
    var sa = Surface(Int(a.unsafe_ptr()), w, h, 1.0)
    sa.still = True
    g1.select(4, 1)
    g2.select(4, 1)
    g1.draw(sa, src, font, pal)
    var sc = Scene(w, h, 1.0)
    sc.is_still = True
    g2.draw_scene(sc, src, font, pal)
    var sb = Surface(Int(b.unsafe_ptr()), w, h, 1.0)
    sc.raster(sb, font)
    assert_equal(same(a, b), 0, "the grid recorded and replayed is the grid drawn")
    assert_equal(sc.layers(), 4, "cells, selection, ring, scroll bar")
    assert_equal(sc.layer_keys[0], "cells")
    assert_equal(sc.layer_keys[1], "selection")
    assert_equal(sc.layer_keys[2], "ring")
    assert_equal(sc.layer_keys[3], "bar")
    var ring = sc.layer_range(2)
    assert_true(ring[1] - ring[0] <= 8, "the ring layer is a handful of shapes")
    var texts = List[String]()
    for op in range(sc.ops()):
        if Int(sc.kinds[op]) == OP_TEXT:
            texts.append(sc.text_at(op))
    assert_true("Person 7" in texts, "the cells' text is readable from the list (an agent, a test)")
    var meant = False
    for op in range(sc.ops()):
        if Int(sc.kinds[op]) == OP_TEXT and sc.text_at(op) == "Person 7":
            meant = sc.meaning_of(op) == "cell 0 7"
    assert_true(meant, "a cell's text says which cell it is (column 0, row 7)")


def test_only_the_ring_changes_when_the_selection_glides() raises:
    var font = Font()
    var pal = liquid_palette()
    var src = People(0)
    var g = DataGrid()
    g.select(4, 1)
    g.extend(6, 2, src)  # a block: the cells are tinted as one
    var first = Scene(900, 500, 1.0)
    first.is_still = True
    g.draw_scene(first, src, font, pal)
    var again = Scene(900, 500, 1.0)  # the next frame: nothing changed
    again.is_still = True
    g.draw_scene(again, src, font, pal)
    for l in range(again.layers()):
        assert_true(again.same_layer(l, first, l), "an unchanged frame: every layer is the same (a host reuses its nodes)")
    _ = g.handle(Event(1, "ArrowDown", KEY, 0, 0, 0, 0, 1), src, font, pal)  # (the block collapses; the selection moves)
    var moved = Scene(900, 500, 1.0)
    moved.is_still = True
    g.draw_scene(moved, src, font, pal)
    assert_true(moved.same_layer(0, first, 0), "the selection moved: the cells are the same (no rebuild while it glides)")
    assert_false(moved.same_layer(1, first, 1), "the selection's wash moved")
    assert_false(moved.same_layer(2, first, 2), "the ring moved")


def test_a_browse_grid_never_selects() raises:
    var font = Font()
    var pal = liquid_palette()
    var src = People(0)
    var g = DataGrid()
    g.browse = True
    var sc = Scene(900, 500, 1.0)
    g.draw_scene(sc, src, font, pal)  # (lays it out)
    from mojoui import PRESS, PAN, RELEASE
    _ = g.handle(Event(1, "", PRESS, 300, 200, 0, 0, 1), src, font, pal)
    _ = g.handle(Event(1, "", PAN, 400, 300, 100, 100, 1), src, font, pal)
    _ = g.handle(Event(1, "", RELEASE, 400, 300, 0, 0, 1), src, font, pal)
    assert_false(g.has_block(), "a press and a drag over a browse grid's cells select nothing")
    assert_false(g.dragging)


def test_clips_images_and_versions() raises:
    var font = Font()
    var px: List[UInt32] = [0xFF0000FF, 0xFF00FF00, 0xFFFF0000, 0xFFFFFFFF]
    var a = Scene(40, 40, 1.0)
    a.begin_layer("data")
    a.layer_version(7)
    a.image(px, 2, 2, 0, 0, 40, 40)
    a.push_clip(0, 0, 10, 10)
    a.rect(0, 0, 40, 40, 0xFF000000, 0)
    a.pop_clip()
    var b = Scene(40, 40, 1.0)
    b.begin_layer("data")
    b.layer_version(7)
    b.rect(5, 5, 5, 5, 0xFF000000, 0)  # (other items, same version: the drawing code says it's the same picture)
    assert_true(b.same_layer(0, a, 0), "a layer's version decides, when both have one")
    var buf = List[UInt32](length=40 * 40, fill=0)
    var s = Surface(Int(buf.unsafe_ptr()), 40, 40, 1.0)
    a.raster(s, font)
    assert_equal(s.get(39, 39), 0xFFFFFFFF, "the image is scaled into its rect (its last pixel at the far corner)")
    var big: List[UInt32] = [0xFF0000FF, 0xFF00FF00, 0xFFFF0000, 0xFFFFFFFF, 0xFF000000, 0xFF000000]  # (6 pixels for a 2 × 2 image)
    var c = Scene(40, 40, 1.0)
    c.image(big, 2, 2, 0, 0, 40, 40)
    assert_equal(len(c.images[0][].levels[0]), 4, "an image keeps exactly its width × height pixels")
    var buf2 = List[UInt32](length=40 * 40, fill=0)
    var s2 = Surface(Int(buf2.unsafe_ptr()), 40, 40, 1.0)
    c.raster(s2, font)
    assert_equal(s2.get(39, 39), 0xFFFFFFFF, "replayed at its own height (two rows), not the buffer's (three)")


def main() raises:
    test_a_scene_replays_to_the_same_pixels()
    test_the_grid_as_a_scene_is_the_grid()
    test_only_the_ring_changes_when_the_selection_glides()
    test_a_browse_grid_never_selects()
    test_clips_images_and_versions()
    print("SCENE TESTS PASSED")
