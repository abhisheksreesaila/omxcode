# mojoui.boardtiles (goal 54): an app's cards kept in step with the tiling: new cards split the one last touched, a
# closed card's space goes to its neighbour even when the cards after it are renumbered, a card that resized itself goes
# back to its tile, a drop swaps, a corner drag moves the shared edge.
#   scripts/mxbuild.sh tests/test_boardtiles.mojo -o build/test_boardtiles && build/test_boardtiles
# Prints "add: ok", "close: ok", "self: ok", "drop: ok", "resize: ok", "focus: ok".
from std.testing import assert_equal, assert_true
from mojoui.boardtiles import BoardTiles
from mojoui.tiling import Rect, GAP


def s(r: Rect) -> String:
    return String(r)


def main() raises:
    var W = 1000
    var H = 600
    var bt = BoardTiles()
    # add: the first card fills the Board, the next splits it, the third splits the second (the one just added)
    var tags: List[String] = ["table"]
    var rects: List[Rect] = [Rect(0, 0, 0, 0)]
    rects = bt.sync(tags, rects, W, H)
    assert_equal(s(rects[0]), "0,0 1000x600")
    tags.append("video0")
    rects.append(Rect(5, 5, 200, 100))  # (wherever the app first put it: the tiling decides)
    rects = bt.sync(tags, rects, W, H)
    assert_equal(s(rects[0]), "0,0 496x600")
    assert_equal(s(rects[1]), "504,0 496x600")
    tags.append("video1")
    rects.append(Rect(0, 0, 10, 10))
    rects = bt.sync(tags, rects, W, H)
    assert_equal(s(rects[1]), "504,0 496x296")
    assert_equal(s(rects[2]), "504,304 496x296")
    tags.append("video2")
    rects.append(Rect(0, 0, 10, 10))
    rects = bt.sync(tags, rects, W, H)
    var v2 = rects[3]
    print("add: ok")

    # close: video1 goes; video2 is renumbered video1 but keeps its place; video1's space goes to its neighbour
    var t2: List[String] = ["table", "video0", "video1"]
    var r2: List[Rect] = [rects[0], rects[1], v2]
    var after = bt.sync(t2, r2, W, H)
    assert_equal(len(bt.tiles), 3)
    # (with four cards the minimums had squeezed the table to 384; with three, the splits' own ratios hold again)
    assert_equal(s(after[0]), "0,0 496x600")
    assert_equal(s(after[1]), "504,0 496x296")
    assert_equal(after[2].x, 504)
    assert_equal(after[2].y, 304)  # (the old video2, now in the space video1 and it shared)
    assert_equal(after[2].h, 296)
    print("close: ok")

    # self: a card that changed its own size goes back to its tile
    var r3: List[Rect] = [after[0], Rect(after[1].x, after[1].y, 900, 50), after[2]]
    var back = bt.sync(t2, r3, W, H)
    assert_true(back[1] == after[1], s(back[1]))
    assert_equal(len(bt.tiles), 3)
    print("self: ok")

    # drop: video0's middle dropped on the table: they trade places; dropped on nothing, it goes back
    var sw = bt.drop(1, back[0].x + back[0].w // 2 - (back[1].x + back[1].w // 2), 0, t2, back)
    assert_true(sw[1] == back[0] and sw[0] == back[1], s(sw[0]) + " " + s(sw[1]))
    var same = bt.drop(1, 0, 5000, t2, sw)
    assert_true(same[1] == sw[1])
    print("drop: ok")

    # resize: the table (now on the right) shares its left edge; a drag left moves that edge left: it grows
    var before = bt.sync(t2, same, W, H)
    var grown = bt.resize(0, -100, 0, t2, before)
    assert_equal(grown[0].x, before[0].x - 100)
    assert_equal(grown[0].w, before[0].w + 100)
    assert_equal(grown[1].w, before[1].w - 100)
    print("resize: ok")

    # focus: a new card splits the card last touched (by its tile, so a close before it doesn't move the focus)
    bt.touch(1, t2, grown)  # (video0)
    var t3: List[String] = ["table", "video0", "video1", "chart0"]
    var r4: List[Rect] = [grown[0], grown[1], grown[2], Rect(0, 0, 1, 1)]
    var r5 = bt.sync(t3, r4, W, H)
    assert_equal(r5[3].x, r5[1].x)  # (video0's space was halved: the chart sits under or beside it, in its column)
    assert_true(r5[3].y >= r5[1].y)
    print("focus: ok")

    # grow (goal 73): a corner dragged past what the Board can give makes the Board taller; only the dragged card's row
    # grows (the table's neighbours beside it are in its row), every other card keeps its pixels
    var g = BoardTiles()
    var gt: List[String] = ["table", "a", "b"]
    var gr: List[Rect] = [Rect(0, 0, 0, 0), Rect(0, 0, 0, 0), Rect(0, 0, 0, 0)]
    gr = g.sync(gt, gr, W, H)
    assert_equal(g.height(H), 600)
    assert_equal(s(gr[0]), "0,0 496x600")
    assert_equal(s(gr[1]), "504,0 496x296")
    gr = g.resize(0, 0, 300, gt, gr)  # (the table's corner 300 down: nothing below it to give, so the Board grows)
    assert_equal(g.height(H), 900)
    assert_equal(s(gr[0]), "0,0 496x900")
    assert_equal(s(gr[1]), "504,0 496x296")  # (a keeps its pixels; b, in the table's row, takes the rest)
    assert_equal(s(gr[2]), "504,304 496x596")
    gr = g.sync(gt, gr, W, H)  # (the next event: the Board's height is remembered, and nothing moves)
    assert_equal(g.height(H), 900)
    assert_equal(s(gr[0]), "0,0 496x900")
    assert_equal(g.height(1200), 1200)  # (never less than the window's room)
    # a drag the card below can give is today's: it moves the shared edge and the Board stays as tall as the window
    var small = BoardTiles()
    var st: List[String] = ["table", "a", "b"]
    var sr: List[Rect] = [Rect(0, 0, 0, 0), Rect(0, 0, 0, 0), Rect(0, 0, 0, 0)]
    sr = small.sync(st, sr, W, H)
    sr = small.resize(1, 0, 60, st, sr)
    assert_equal(small.height(H), 600)
    assert_equal(s(sr[1]), "504,0 496x356")
    assert_equal(s(sr[2]), "504,364 496x236")
    # past what b can give (it stops at its minimum, 200), the rest makes the Board taller: a ends 400 taller in all
    sr = small.resize(1, 0, 400, st, sr)
    assert_equal(sr[1].h, 356 + 400)
    assert_equal(sr[2].h, 200)
    assert_equal(small.height(H), 600 + 364)
    assert_equal(sr[0].h, 964)
    print("grow: ok")

    # shrink: the bottom card's corner dragged up gives the height back, down to the window's room and no further
    var down = small.resize(2, 0, -2000, st, sr)  # (b is a bottom card now; the Board is 964, the window's room 600)
    assert_equal(small.height(H), 600)
    assert_equal(down[0].h, 600)
    assert_true(down[1].h >= 200 and down[2].h >= 200, s(down[1]) + " " + s(down[2]))
    print("shrink: ok")

    # bottom: a card that would squeeze another under its minimum goes below everything (a new row), the others unmoved
    var bt2 = BoardTiles()
    var bt_tags = List[String]()
    var bt_rects = List[Rect]()
    var grew_at = -1
    for k in range(9):
        var prev = List[Rect]()  # (where each card was before this one came)
        for r in bt_rects:
            prev.append(r)
        bt_tags.append("c" + String(k))
        bt_rects.append(Rect(0, 0, 1, 1))
        var tall0 = bt2.height(H)
        bt_rects = bt2.sync(bt_tags, bt_rects, W, H)
        for r in bt_rects:
            assert_true(r.w >= 300 and r.h >= 200, "card " + String(k) + " under its minimum: " + s(r))
        if bt2.height(H) > tall0 and grew_at < 0:
            grew_at = k
            assert_equal(bt_rects[k].x, 0)  # (the new row: the whole width, under everything)
            assert_equal(bt_rects[k].w, W)
            assert_equal(bt_rects[k].y, tall0 + 8)
            assert_true(bt_rects[k].h >= 200)
            for j in range(k):  # (every card that was there keeps its place and size exactly)
                assert_equal(s(bt_rects[j]), s(prev[j]))
    assert_true(grew_at > 0 and grew_at <= 8, "the Board never grew: " + String(grew_at))
    print("bottom: ok")
