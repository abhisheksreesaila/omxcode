# mojoui.clipgrid (goal 71): a grid of clips. Each tile: its poster is a tappable Image (message base + 2 i), its title,
# its detail, a badge (or "shown" for the shown clip), a pick toggle (base + 2 i + 1); clip_message reads a message back;
# clip_columns fits tiles to a width (one column on a phone). On GTK and the web: docs/goals/71/clipgrid_web.py.
from std.testing import assert_equal, assert_true
from mojoui import IMAGE, BUTTON, TEXT, GRID
from mojoui.clipgrid import ClipTile, ClipGrid, clip_message, clip_columns, CLIP_MSGS


def main() raises:
    var px = List[UInt32](length=4 * 3, fill=UInt32(0xFF0000FF))
    var tiles = List[ClipTile]()
    tiles.append(ClipTile("a:1", "pick up the cube", "SO-100 · 9.0 s", "0.991", px, 4, 3))
    tiles.append(ClipTile("a:2", "stack the cubes", "SO-100 · 8.0 s", "0.990", px, 4, 3, shown=True))
    tiles.append(ClipTile("a:3", "sort the cubes", "SO-100 · 7.0 s", "0.980", px, 4, 3, picked=True))
    var v = ClipGrid(tiles, 500, columns=2)
    assert_equal(v.nodes[0].kind, GRID)
    assert_equal(v.nodes[0].value, 2)
    var images = 0
    var picks = List[Int]()
    var texts = List[String]()
    for n in v.nodes:
        if n.kind == IMAGE:
            assert_equal(n.msg, 500 + images * CLIP_MSGS)  # the poster sends its tile's message
            assert_equal(n.name, "clip-" + String(images))
            assert_equal(len(n.pixels), 12)
            images += 1
        elif n.kind == BUTTON:
            picks.append(n.msg)
            texts.append(n.text)
        elif n.kind == TEXT:
            texts.append(n.text)
    assert_equal(images, 3)
    assert_equal(len(picks), 3)
    assert_equal(picks[1], 500 + 1 * CLIP_MSGS + 1)
    assert_true("pick up the cube" in texts and "SO-100 · 9.0 s" in texts and "0.991" in texts, "tile words")
    assert_true("shown" in texts and "0.990" not in texts, "the shown tile says shown instead of its score")
    assert_true("Unpick" in texts, "a picked tile's toggle reads Unpick")
    var m = clip_message(5 * CLIP_MSGS + 1)
    assert_equal(m[0], 5)
    assert_true(m[1], "pick")
    assert_true(not clip_message(4 * CLIP_MSGS)[1], "poster")
    assert_equal(clip_columns(358), 1)     # a phone
    assert_equal(clip_columns(1392), 6)
    assert_equal(clip_columns(848, 240), 3)
    print("clipgrid: ok")
