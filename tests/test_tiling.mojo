# mojoui.tiling (goal 54 M0): cards kept as a tiling window manager keeps windows (a split tree, Hyprland's dwindle):
# insert halves the focused card along its longer side, remove gives the space back, resize moves the shared edge,
# swap trades places, any area fits, the tree reads back from text; and 2,000 random operations never overlap.
#   scripts/mxbuild.sh tests/test_tiling.mojo -o build/test_tiling && build/test_tiling
# Prints "insert: ok", "remove: ok", "resize: ok", "swap: ok", "fit: ok", "text: ok", "random: ok".
from std.testing import assert_equal, assert_true, assert_false
from mojoui.tiling import Tiling, Rect, GAP


def at(t: Tiling, id: String, w: Int, h: Int) raises -> Rect:
    var r = t.rect_of(id, w, h)
    assert_true(Bool(r), "no " + id)
    return r.value()


def problems(t: Tiling, w: Int, h: Int) -> String:
    """Everything wrong with a layout: outside, overlapping, a free edge that isn't the board's or a gap of GAP."""
    var rs = t.rects(w, h)
    var ids = t.leaves()
    var bad = String("")
    for i in range(len(rs)):
        var a = rs[i]
        if a.w < 1 or a.h < 1 or a.x < 0 or a.y < 0 or a.x + a.w > w or a.y + a.h > h:
            bad += ids[i] + " outside " + String(a) + "; "
        for j in range(i + 1, len(rs)):
            var b = rs[j]
            if a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h:
                bad += ids[i] + " overlaps " + ids[j] + "; "
        # each edge is the board's, or faces another card exactly GAP away along a shared span
        var right = a.x + a.w == w
        var bottom = a.y + a.h == h
        var left = a.x == 0
        var top = a.y == 0
        for j in range(len(rs)):
            var b = rs[j]
            if j == i:
                continue
            var rows = a.y < b.y + b.h and b.y < a.y + a.h
            var cols = a.x < b.x + b.w and b.x < a.x + a.w
            if rows and b.x == a.x + a.w + GAP:
                right = True
            if rows and b.x + b.w + GAP == a.x:
                left = True
            if cols and b.y == a.y + a.h + GAP:
                bottom = True
            if cols and b.y + b.h + GAP == a.y:
                top = True
        if not (right and bottom and left and top):
            bad += ids[i] + " has an edge facing nothing at " + String(a) + "; "
    var area = 0
    for r in rs:
        area += r.w * r.h
    if area > w * h:
        bad += "more area than the board; "
    return bad


struct Lcg:
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self, n: Int) -> Int:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return Int((self.s >> 33) % UInt64(n))


def main() raises:
    var W = 1000
    var H = 600
    # insert: the whole area, then halves along the longer side, the new card second
    var t = Tiling()
    t.insert("table", "", W, H)
    assert_equal(String(at(t, "table", W, H)), "0,0 1000x600")
    t.insert("chart", "table", W, H)
    assert_equal(String(at(t, "table", W, H)), "0,0 496x600")
    assert_equal(String(at(t, "chart", W, H)), "504,0 496x600")
    t.insert("video", "chart", W, H)  # (the chart's space is taller than wide: stacked)
    assert_equal(String(at(t, "chart", W, H)), "504,0 496x296")
    assert_equal(String(at(t, "video", W, H)), "504,304 496x296")
    assert_equal(len(t), 3)
    var dup = False
    try:
        t.insert("video", "table", W, H)
    except:
        dup = True
    assert_true(dup, "the same card twice is refused")
    t.insert("notes", "nobody", W, H)  # (beside a card that isn't here: the last card's space)
    assert_true(t.has("notes"))
    assert_equal(problems(t, W, H), "")
    print("insert: ok")

    # remove: the sibling takes the space back
    assert_true(t.remove("notes"))
    assert_true(t.remove("chart"))
    assert_false(t.remove("chart"))
    assert_equal(String(at(t, "video", W, H)), "504,0 496x600")
    assert_equal(String(at(t, "table", W, H)), "0,0 496x600")
    print("remove: ok")

    # resize: the shared edge moves; the far-right card moves its left edge; minimums hold
    assert_true(t.resize("table", 100, 0, W, H))
    assert_equal(String(at(t, "table", W, H)), "0,0 596x600")
    assert_equal(String(at(t, "video", W, H)), "604,0 396x600")
    assert_true(t.resize("video", -50, 0, W, H))  # (on the far right: its left edge follows the pointer, left: it grows)
    assert_equal(String(at(t, "table", W, H)), "0,0 546x600")
    assert_equal(String(at(t, "video", W, H)), "554,0 446x600")
    _ = t.resize("table", 10000, 0, W, H)
    assert_equal(at(t, "video", W, H).w, 240)  # (min_w)
    assert_false(t.resize("table", 0, 50, W, H))  # (nothing above or below it: no edge to move)
    t.insert("tele", "video", W, H)  # video 240 wide, 600 high: stacked
    var v0 = at(t, "video", W, H)
    assert_true(t.resize("video", 0, 60, W, H))
    var v1 = at(t, "video", W, H)
    var t1 = at(t, "tele", W, H)
    assert_equal(v1.h, v0.h + 60)
    assert_equal(t1.y, v1.y + v1.h + GAP)
    assert_equal(t1.y + t1.h, H)
    assert_equal(problems(t, W, H), "")
    print("resize: ok")

    # swap: two cards trade places exactly
    var a0 = at(t, "table", W, H)
    var b0 = at(t, "tele", W, H)
    assert_true(t.swap("table", "tele"))
    assert_true(at(t, "table", W, H) == b0)
    assert_true(at(t, "tele", W, H) == a0)
    assert_false(t.swap("table", "nobody"))
    print("swap: ok")

    # fit: a smaller window squeezes the big part first and keeps minimums; a tiny one still fits without overlap
    for size in [(1280, 800), (700, 600), (520, 340), (400, 300), (60, 40)]:
        assert_equal(problems(t, size[0], size[1]), "", String(size[0]) + "x" + String(size[1]))
    assert_true(at(t, "table", 700, 600).w >= 240 and at(t, "video", 700, 600).w >= 240)
    var r = t.rects(W, H, 20, 30)  # (an offset area: the Board's padding)
    assert_equal(r[0].x >= 20 and r[0].y >= 30, True)
    print("fit: ok")

    # text: the tree and its ratios read back; names with , ( ) % and a leading v/h survive
    var saved = t.to_text()
    var back = Tiling.from_text(saved)
    assert_equal(back.to_text(), saved)
    for size in [(W, H), (1440, 900)]:
        var x = t.rects(size[0], size[1])
        var y = back.rects(size[0], size[1])
        for i in range(len(x)):
            assert_true(x[i] == y[i], saved)
    var odd = Tiling()
    odd.insert("a,b(c)", "", W, H)
    odd.insert("v0.5", "a,b(c)", W, H)
    odd.insert("h1%", "v0.5", W, H)
    var odd2 = Tiling.from_text(odd.to_text())
    assert_equal(len(odd2), 3)
    assert_true(odd2.has("a,b(c)") and odd2.has("v0.5") and odd2.has("h1%"), odd.to_text())
    assert_equal(Tiling.from_text("").to_text(), "")
    var bad = False
    try:
        _ = Tiling.from_text("v0.500(a,b")
    except:
        bad = True
    assert_true(bad, "broken text is refused")
    print("text: ok")

    # random: 2,000 operations at random sizes
    var g = Lcg(54)
    var rt = Tiling()
    var next_id = 0
    var checked = 0
    for step in range(2000):
        var w = 300 + g.next(2100)
        var h = 200 + g.next(1200)
        var ids = rt.leaves()
        var op = g.next(10)
        if len(ids) == 0 or (op < 4 and len(ids) < 12):
            rt.insert("c" + String(next_id), ids[g.next(len(ids))] if len(ids) > 0 else String(""), w, h)
            next_id += 1
        elif op < 6:
            _ = rt.remove(ids[g.next(len(ids))])
        elif op < 9:
            _ = rt.resize(ids[g.next(len(ids))], g.next(601) - 300, g.next(601) - 300, w, h)
        else:
            _ = rt.swap(ids[g.next(len(ids))], ids[g.next(len(ids))])
        var p = problems(rt, w, h)
        assert_equal(p, "", "step " + String(step) + " at " + String(w) + "x" + String(h) + ": " + rt.to_text())
        var n = len(rt)
        if n > 0 and w >= n * (240 + GAP) and h >= n * (160 + GAP):  # (room for any arrangement of minimums)
            for q in rt.rects(w, h):
                assert_true(q.w >= 240 and q.h >= 160, "a card under its minimum at step " + String(step))
        checked += 1
    print("random: ok (" + String(checked) + " operations, up to 12 cards)")
