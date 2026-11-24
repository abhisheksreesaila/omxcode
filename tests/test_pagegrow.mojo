# mojoui.pagegrow: pages.js's own cases (pages.test.js), and a board's frame shifted with its undo.
from std.testing import assert_true, assert_equal
from mojoui.pagegrow import PageBox, PageGrid, settle_pages, grow_for_drag, grow_for_text
from mojoui.objectlayer import ObjectLayer, export_json_canvas

comptime W = 860.0
comptime H = 1080.0


def same(g: PageGrid, c: Int, r: Int, x: Float64, y: Float64) raises:
    assert_true(g.columns == c and g.rows == r and g.shift_x == x and g.shift_y == y, String(g.columns) + "x" + String(g.rows) + " " + String(g.shift_x) + "," + String(g.shift_y))


def box(l: Float64, t: Float64, r: Float64, b: Float64) -> PageBox:
    return PageBox(True, l, t, r, b)


def main() raises:
    same(settle_pages(1, 1, box(10, 10, W + 6, 100), W, H), 1, 1, 0, 0)
    same(settle_pages(1, 1, box(10, 10, W + 7, H + 7), W, H), 2, 2, 0, 0)
    assert_equal(settle_pages(1, 1, box(0, 0, 3 * W, 10), W, H).columns, 3)
    same(settle_pages(1, 1, box(-7, 10, 100, 100), W, H), 2, 1, W, 0)
    same(settle_pages(2, 1, box(10, -1200, W + 300, 100), W, H), 2, 3, 0, 2 * H)
    same(settle_pages(1, 1, box(-6, 10, 100, 100), W, H), 1, 1, 0, 0)
    same(settle_pages(3, 1, box(10, 10, W + 50, 100), W, H), 2, 1, 0, 0)
    same(settle_pages(3, 1, box(W + 20, 10, 2 * W + 40, 100), W, H), 2, 1, -W, 0)
    same(settle_pages(1, 4, box(10, 3 * H + 5, 100, 3 * H + 90), W, H), 1, 1, 0, -3 * H)
    same(settle_pages(3, 3, PageBox.none(), W, H), 1, 1, 0, 0)
    same(grow_for_drag(1, 1, box(10, 10, W - 25, H - 25), W, H), 1, 1, 0, 0)
    same(grow_for_drag(1, 1, box(10, 10, W - 23, H - 25), W, H), 2, 1, 0, 0)
    same(grow_for_text(1, 1, box(10, 10, 200, H - 40), 20, W, H), 1, 2, 0, 0)
    var ol = ObjectLayer()
    var a = ol.add_sticky(10, 10, 100, "a")
    var t = ol.add_text(300, 40, 200, 30, "words")
    var before = export_json_canvas(ol)
    ol.select(a)
    ol.move_by(-100, 0)
    var b = ol.content_box()
    var g = settle_pages(1, 1, b, W, H)
    same(g, 2, 1, W, 0)
    ol.shift_frame(g.shift_x, g.shift_y)
    assert_equal(ol.objs[ol.index(a)].x, W - 90)
    assert_equal(ol.objs[ol.index(t)].x, W + 300)
    _ = ol.undo()
    assert_equal(ol.objs[ol.index(a)].x, W + 10, "undo in the new frame")
    _ = ol.redo()
    assert_equal(ol.objs[ol.index(a)].x, W - 90)
    _ = ol.undo()
    g = settle_pages(2, 1, ol.content_box(), W, H)
    same(g, 1, 1, -W, 0)
    ol.shift_frame(g.shift_x, g.shift_y)
    assert_equal(export_json_canvas(ol), before, "and back")
    print("pagegrow: ok")
