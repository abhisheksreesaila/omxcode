# mojoui.freeboard (goal 78): the free canvas's placement model.
#   scripts/mxbuild.sh tests/test_freeboard.mojo -o build/test_freeboard && build/test_freeboard
# Prints "handles: ok", "move: ok", "resize: ok", "snap: ok", "nosnap: ok", "extent: ok", "free: ok", "sync: ok",
# "tidy: ok", "keys: ok", "fill: ok", "zoom: ok", "canvas: ok", "act: ok".
from std.testing import assert_equal, assert_true, assert_false
from mojoui.freeboard import (FreeBoard, FreeCanvas, handle_at, handle_cursor, handle_point, drag_rect, extent, first_free, tidy,
                              nearest, nudge, grow, zoom_step, zoom_by, zoom_to_fit, board_zoom, is_free, overlaps,
                              HANDLE_NONE, HANDLE_SE, HANDLE_N, HANDLE_S, HANDLE_E, HANDLE_W, HANDLE_NE, HANDLE_NW, HANDLE_SW,
                              HANDLE_MOVE, MARGIN, GUIDES, DIR_LEFT, DIR_RIGHT, DIR_UP, DIR_DOWN,
                              act_keys, arrange_menu, ACT_FOCUS, ACT_MOVE, ACT_NUDGE, ACT_RESIZE, ACT_FILL, ACT_TIDY, ACT_ZOOM_OUT, ACT_ZOOM_RESET)
from mojoui.tiling import Rect, GAP
from mojoui.view import View, Text, BOARD, BOARD_FOCUS


def s(r: Rect) -> String:
    return String(r)


def main() raises:
    # handles: each of the 8 grips, the title band, the content; each has its own cursor
    var W = 600
    var H = 400
    var all: List[Int] = [HANDLE_N, HANDLE_S, HANDLE_E, HANDLE_W, HANDLE_NE, HANDLE_NW, HANDLE_SW, HANDLE_SE, HANDLE_MOVE]
    for h in all:
        var p = handle_point(h, W, H)
        assert_equal(handle_at(W, H, p[0], p[1]), h, "handle " + String(h) + " at " + String(p[0]) + "," + String(p[1]))
        assert_true(handle_cursor(h) != "")
    assert_equal(handle_at(W, H, 300, 200), HANDLE_NONE)  # (the card's own content)
    assert_equal(handle_at(W, H, -1, 10), HANDLE_NONE)
    assert_equal(handle_cursor(HANDLE_E), "ew-resize")
    assert_equal(handle_cursor(HANDLE_NE), "nesw-resize")
    assert_equal(handle_at(W, H, W - 8, H - 8), HANDLE_SE)  # (the old grip's spot: older steps and hosts still resize)
    print("handles: ok")

    # move: a card moved keeps its size; the others don't move; it can't leave the canvas's top or left
    var rects: List[Rect] = [Rect(0, 0, 600, 400), Rect(700, 0, 300, 300), Rect(0, 500, 400, 300)]
    var g = List[Rect]()
    var m = drag_rect(rects, 1, HANDLE_MOVE, 450, 37, False, g)
    assert_equal(s(m), "1150,37 300x300")
    assert_equal(s(drag_rect(rects, 1, HANDLE_MOVE, -2000, -50, False, g)), "0,0 300x300")
    var fb = FreeBoard()
    var r1 = fb.drag(1, HANDLE_MOVE, 100, 0, rects)
    rects[1] = r1
    var r2 = fb.drag(1, HANDLE_MOVE, 200, 0, rects)  # (dx is from the press: the start rects are kept)
    assert_equal(s(r2), "900,0 300x300")
    fb.end()
    assert_equal(len(fb.guides), 0)
    rects[1] = Rect(700, 0, 300, 300)
    print("move: ok")

    # resize: each handle moves only its own edges; never under the minimum; never past the top or left
    var c: List[Rect] = [Rect(100, 100, 400, 300), Rect(2000, 2000, 10, 10)]
    assert_equal(s(drag_rect(c, 0, HANDLE_E, 900, 50, False, g)), "100,100 1300x300")
    assert_equal(s(drag_rect(c, 0, HANDLE_W, -60, 50, False, g)), "40,100 460x300")
    assert_equal(s(drag_rect(c, 0, HANDLE_N, 9, -30, False, g)), "100,70 400x330")
    assert_equal(s(drag_rect(c, 0, HANDLE_S, 9, 120, False, g)), "100,100 400x420")
    assert_equal(s(drag_rect(c, 0, HANDLE_NE, 50, -50, False, g)), "100,50 450x350")
    assert_equal(s(drag_rect(c, 0, HANDLE_NW, -50, -50, False, g)), "50,50 450x350")
    assert_equal(s(drag_rect(c, 0, HANDLE_SW, -50, 50, False, g)), "50,100 450x350")
    assert_equal(s(drag_rect(c, 0, HANDLE_SE, 50, 50, False, g)), "100,100 450x350")
    assert_equal(s(drag_rect(c, 0, HANDLE_W, 1000, 0, False, g, 200, 120)), "300,100 200x300")  # (the minimum holds the right edge still)
    assert_equal(s(drag_rect(c, 0, HANDLE_N, 0, -500, False, g)), "100,0 400x400")  # (the top stops at the canvas's)
    assert_equal(s(drag_rect(c, 0, HANDLE_SE, -1000, -1000, False, g, 200, 120)), "100,100 200x120")
    print("resize: ok")

    # snap: an edge within 8 of a neighbour's (or GAP outside it) lands on it, with a guide line; equal widths too
    var n: List[Rect] = [Rect(0, 0, 600, 400), Rect(800, 0, 300, 300)]
    var e = drag_rect(n, 0, HANDLE_E, 195, 0, True, g)  # (right edge 795: 5 from GAP outside the other's left, 792)
    assert_equal(s(e), "0,0 792x400")
    assert_equal(len(g), 1)
    assert_equal(g[0].x, 792)
    assert_equal(g[0].w, 1)
    var mv = drag_rect(n, 1, HANDLE_MOVE, -192, 6, True, g)  # (left edge 608: GAP right of the first card's 600 snaps to 608; top 6 snaps to 0)
    assert_equal(s(mv), "608,0 300x300")
    assert_equal(len(g), 2)
    var eq: List[Rect] = [Rect(0, 0, 500, 400), Rect(0, 600, 300, 200)]
    var ew = drag_rect(eq, 1, HANDLE_E, 1194, 0, True, g)  # (width 1494: no edge near; snaps to nothing)
    assert_equal(ew.w, 1494)
    var ew2 = drag_rect(eq, 1, HANDLE_E, 205, 0, True, g)  # (width 505: the right edge is 5 from the other's 500: lands on it)
    assert_equal(ew2.w, 500)
    var eq2: List[Rect] = [Rect(0, 0, 500, 400), Rect(1000, 600, 300, 200)]
    var ew3 = drag_rect(eq2, 1, HANDLE_E, 194, 0, True, g)  # (width 494, nowhere near an edge: an equal width, marked twice)
    assert_equal(ew3.w, 500)
    assert_equal(len(g), 2)
    print("snap: ok")

    # nosnap: the same drags with snap off land where the pointer says
    assert_equal(s(drag_rect(n, 0, HANDLE_E, 195, 0, False, g)), "0,0 795x400")
    assert_equal(len(g), 0)
    print("nosnap: ok")

    # extent: the cards plus the margin, at least the room
    var ex = extent(n, 1400, 800)
    assert_equal(ex[0], 1400)
    assert_equal(ex[1], 800)
    var wide: List[Rect] = [Rect(0, 0, 2300, 500), Rect(0, 508, 400, 900)]
    ex = extent(wide, 1400, 800)
    assert_equal(ex[0], 2300 + MARGIN)
    assert_equal(ex[1], 1408 + MARGIN)
    print("extent: ok")

    # free: right of the last card when it fits the room, else a new row under everything; nothing overlaps
    var f: List[Rect] = [Rect(0, 0, 600, 400)]
    assert_equal(s(first_free(f, 500, 300, 1400)), "608,0 500x300")
    f.append(Rect(608, 0, 500, 300))
    assert_equal(s(first_free(f, 500, 300, 1400)), "0,408 500x300")  # (608+500+8+500 > 1400: below)
    print("free: ok")

    # sync: the first card fills the room; new cards go to free spots at their own (or the default) size; others stay
    var fs = FreeBoard(200, 120)
    var tags: List[String] = ["table"]
    var rs: List[Rect] = [Rect(0, 0, 0, 0)]
    rs = fs.sync(tags, rs, 1400, 800)
    assert_equal(s(rs[0]), "0,0 1400x800")
    tags.append("chart0")
    rs.append(Rect(0, 0, 520, 340))
    rs = fs.sync(tags, rs, 1400, 800)
    assert_equal(s(rs[0]), "0,0 1400x800")
    assert_equal(s(rs[1]), "0,808 520x340")
    rs[0] = Rect(0, 0, 600, 400)  # (the person made the table smaller)
    tags.append("video0")
    rs.append(Rect(0, 0, 0, 0))
    var sizes: List[Rect] = [Rect(0, 0, 0, 0), Rect(0, 0, 0, 0), Rect(0, 0, 480, 300)]
    rs = fs.sync(tags, rs, 1400, 800, sizes)
    assert_equal(s(rs[0]), "0,0 600x400")
    assert_equal(s(rs[1]), "0,808 520x340")
    assert_equal(s(rs[2]), "528,808 480x300")
    for i in range(len(rs)):
        for j in range(i + 1, len(rs)):
            assert_false(overlaps(rs[i], rs[j]))
    print("sync: ok")

    # tidy: the cards tiled, no overlap, nothing outside the room's width
    var messy: List[Rect] = [Rect(0, 0, 900, 900), Rect(100, 100, 900, 300), Rect(50, 50, 200, 200)]
    var t = tidy(messy, 1400, 800)
    assert_equal(len(t), 3)
    for i in range(len(t)):
        assert_true(t[i].x >= 0 and t[i].x + t[i].w <= 1400, s(t[i]))
        for j in range(i + 1, len(t)):
            assert_false(overlaps(t[i], t[j]), s(t[i]) + " / " + s(t[j]))
    print("tidy: ok")

    # keys: the nearest card each way; nudges; grow and shrink
    var k: List[Rect] = [Rect(0, 0, 400, 300), Rect(500, 0, 400, 300), Rect(0, 400, 400, 300), Rect(500, 400, 400, 300)]
    assert_equal(nearest(k, 0, DIR_RIGHT), 1)
    assert_equal(nearest(k, 0, DIR_DOWN), 2)
    assert_equal(nearest(k, 3, DIR_LEFT), 2)
    assert_equal(nearest(k, 3, DIR_UP), 1)
    assert_equal(nearest(k, 0, DIR_LEFT), -1)
    assert_equal(s(nudge(k[1], DIR_RIGHT, 32)), "532,0 400x300")
    assert_equal(s(nudge(k[0], DIR_LEFT, 32)), "0,0 400x300")
    assert_equal(s(nudge(k[2], DIR_UP, 8)), "0,392 400x300")
    assert_equal(s(grow(k[0], DIR_RIGHT, 32)), "0,0 432x300")
    assert_equal(s(grow(k[0], DIR_UP, 32)), "0,0 400x268")
    assert_equal(s(grow(Rect(0, 0, 210, 300), DIR_LEFT, 32, 200, 120)), "0,0 200x300")
    print("keys: ok")

    # fill: the visible part of the canvas, then back where it was
    var fl = FreeBoard()
    fl.view = Rect(300, 200, 1200, 700)
    var full = fl.fill(1, k, 1400, 800)
    assert_equal(s(full), "300,200 1192x692")
    k[1] = full
    assert_equal(s(fl.fill(1, k, 1400, 800)), "500,0 400x300")
    print("fill: ok")

    # zoom: steps, a wheel's factor (100 is sticky), the step that shows every card
    assert_equal(zoom_step(100, True), 80)
    assert_equal(zoom_step(25, True), 25)
    assert_equal(zoom_step(100, False), 125)
    assert_equal(zoom_step(90, False), 100)
    assert_equal(zoom_by(90, 1.2), 100)
    assert_equal(zoom_by(50, 0.1), 25)
    var big: List[Rect] = [Rect(0, 0, 2400, 600), Rect(0, 608, 1200, 900)]
    var z = zoom_to_fit(big, 1400, 800)
    assert_equal(z, 50)
    print("zoom: ok")

    # canvas: FreeCanvas is a Board as big as its extent, the focus ringed, GUIDES guides after the cards, the zoom in its text
    var fc = FreeBoard()
    fc.zoom = 67
    fc.focus = 1
    var items = List[View]()
    items.append(Text("a").at(0, 0).width(2300).height(500).tag("a"))
    items.append(Text("b").at(0, 508).width(400).height(300).tag("b"))
    var v = FreeCanvas(items^, wide, 1400, 800, fc, 1, 2)
    ref b = v.nodes[0]
    assert_equal(b.kind, BOARD)
    assert_equal(b.spacing, 2300 + MARGIN)
    assert_equal(len(b.children), 2 + GUIDES)
    assert_true(is_free(b.text))
    assert_equal(board_zoom(b.text), 67)
    assert_equal(b.options[1], String(BOARD_FOCUS))
    print("canvas: ok")

    # act: the keys' actions on the focused card; their shortcuts on Super and on Alt
    var ka = FreeBoard(200, 120)
    var kr: List[Rect] = [Rect(0, 0, 400, 300), Rect(500, 0, 400, 300)]
    ka.focus = 0
    kr = ka.act(ACT_FOCUS + DIR_RIGHT, kr, 1400, 800)
    assert_equal(ka.focus, 1)
    kr = ka.act(ACT_MOVE + DIR_RIGHT, kr, 1400, 800)
    assert_equal(s(kr[1]), "532,0 400x300")
    kr = ka.act(ACT_NUDGE + DIR_DOWN, kr, 1400, 800)
    assert_equal(s(kr[1]), "532,8 400x300")
    kr = ka.act(ACT_RESIZE + DIR_RIGHT, kr, 1400, 800)
    assert_equal(s(kr[1]), "532,8 432x300")
    kr = ka.act(ACT_RESIZE + DIR_UP, kr, 1400, 800)
    assert_equal(s(kr[1]), "532,8 432x268")
    assert_equal(s(kr[0]), "0,0 400x300")  # (the other card never moves)
    kr = ka.act(ACT_TIDY, kr, 1400, 800)
    assert_false(overlaps(kr[0], kr[1]))
    kr = ka.act(ACT_ZOOM_OUT, kr, 1400, 800)
    assert_equal(ka.zoom, 80)
    kr = ka.act(ACT_ZOOM_RESET, kr, 1400, 800)
    assert_equal(ka.zoom, 100)
    assert_equal(act_keys(ACT_MOVE + DIR_LEFT)[0], "Super+Shift+ArrowLeft")
    assert_equal(act_keys(ACT_MOVE + DIR_LEFT)[1], "Shift+Alt+ArrowLeft")
    assert_equal(act_keys(ACT_RESIZE + DIR_DOWN)[1], "Ctrl+Alt+ArrowDown")
    assert_equal(act_keys(ACT_FILL)[0], "Super+F")
    var menu = arrange_menu(500)
    var shortcuts = 0
    for n in menu.nodes:
        if len(n.options) > 0:
            shortcuts += 1
    assert_equal(shortcuts, 2 * 18 + 3)
    print("act: ok")
