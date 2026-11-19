# mojoui.livetiles (goal 77 M7b): every preset fills the 4 x 3 grid exactly; dense packing puts each size where CSS's
# grid-auto-flow: dense would; the water spring (k 150, c 19.5) settles within 1 s with at most 3 % overshoot, on its own and
# as a promoted tile's rect; a tile's words are laid out at its final rect from the first frame of a size change (and faded
# in from 0); a drag reorders, a corner grip resizes (snapping s -> w -> l -> xl) and both are reported; omxqua's press
# amounts; a big tile makes the 3-tile xl layout; more than six tiles overflow.
#   pixi run mojo run --disable-warnings -I . tests/test_livetiles.mojo
# Prints one "<name>: ok" line per check, then "livetiles: ok".
from std.testing import assert_equal, assert_true, assert_false
from mojoui.canvas import Surface
from mojoui.livetiles import (
    Box, LiveTiles, Tile, Face, TileLook, TileResult, preset, pack, cell_box, press_amount, size_name, water_ms, fade_at,
    TILE_S, TILE_W, TILE_L, TILE_XL, TILE_BAND, TILE_FULL, TAPPED, ACTION, REORDERED, RESIZED, DROPPED, WATER_K, WATER_C,
    preset_compact, pack_grid, compact_rows_height,
)
from mojoui.spring import Spring
from mojoui.text import Font
from mojoui.theme import Palette, rgba
from mojoui.tiling import Rect
from mojoui.view import PRESS, PAN, RELEASE, TAP

comptime W: Float64 = 900.0
comptime H: Float64 = 600.0
comptime FRAME_US = 16667


def sample(n: Int) -> List[Tile]:
    var names: List[String] = ["traffic", "todo", "cal", "counter", "bday", "weather", "home", "photos"]
    var out = List[Tile]()
    for i in range(n):
        var t = Tile(names[i], rgba(20 * i, 120, 200), names[i].upper(), "Big line " + String(i), "sub line " + String(i))
        if i == 0:
            t.why = "it matters now"
            t.actions = ["Go", "Later"]
        out.append(t^)
    return out^


def promoted(tiles: List[Tile], id: String) -> List[Tile]:
    """The same tiles with `id` moved to the front (the most urgent), its why set."""
    var out = List[Tile]()
    for t in tiles:
        if t.id == id:
            var c = t.copy()
            c.why = "rain starts before pickup"
            out.append(c^)
    for t in tiles:
        if t.id != id:
            var c = t.copy()
            c.why = ""
            out.append(c^)
    return out^


def at(tiles: LiveTiles, id: String) -> Rect:
    var lay = tiles.layout()
    for j in range(len(lay.ids)):
        if lay.ids[j] == id:
            return lay.cells[j]
    return Rect(-1, -1, 0, 0)


def size_of(tiles: LiveTiles, id: String) -> Int:
    var lay = tiles.layout()
    for j in range(len(lay.ids)):
        if lay.ids[j] == id:
            return lay.sizes[j]
    return -1


def test_presets() raises:
    assert_equal(preset(1)[0], TILE_FULL)  # (a lone tile fills the grid: "the grid is always full" for 1-6 tiles)
    var lone = LiveTiles()
    lone.set_area(W, H)
    var one_tile = sample(1)
    one_tile[0].big = True  # (big asks for xl; alone it still fills the grid)
    lone.set_tiles(one_tile)
    assert_equal(lone.layout().holes, 0)
    assert_equal(lone.layout().sizes[0], TILE_FULL)
    for n in range(1, 7):  # the contract's presets (GOAL.md M7b: 6, 5, 4, 3, 2) and one
        var p = preset(n)
        assert_equal(len(p), n)
        var k = pack(p)
        assert_equal(k.holes, 0, "preset " + String(n) + " leaves holes")
        for f in k.fits:
            assert_true(f, "preset " + String(n) + ": a tile did not fit")
        var cells = 0
        for c in k.cells:
            cells += c.w * c.h
        assert_equal(cells, 12, "preset " + String(n))
    print("presets 1-6 fill 12 cells: ok")


def test_dense() raises:
    var five = pack(preset(5))  # l w w w w
    assert_true(five.cells[0] == Rect(0, 0, 2, 2))
    assert_true(five.cells[1] == Rect(2, 0, 2, 1))
    assert_true(five.cells[2] == Rect(2, 1, 2, 1))
    assert_true(five.cells[3] == Rect(0, 2, 2, 1))
    assert_true(five.cells[4] == Rect(2, 2, 2, 1))
    var six = pack(preset(6))  # l w w w s s
    assert_true(six.cells[3] == Rect(0, 2, 2, 1))
    assert_true(six.cells[4] == Rect(2, 2, 1, 1))
    assert_true(six.cells[5] == Rect(3, 2, 1, 1))
    var three = pack(preset(3))  # xl w w
    assert_true(three.cells[0] == Rect(0, 0, 4, 2))
    assert_true(three.cells[1] == Rect(0, 2, 2, 1))
    assert_true(three.cells[2] == Rect(2, 2, 2, 1))
    var two = pack(preset(2))  # xl band
    assert_true(two.cells[1] == Rect(0, 2, 4, 1))
    var four = pack(preset(4))  # l l w w
    assert_true(four.cells[1] == Rect(2, 0, 2, 2))
    assert_true(four.cells[3] == Rect(2, 2, 2, 1))
    # dense: a later small tile fills an earlier hole (s, l, s: the second s goes beside the first, not after the l)
    var holey = pack([TILE_S, TILE_L, TILE_S])
    assert_true(holey.cells[2] == Rect(3, 0, 1, 1), "dense back-fill")
    # and what cannot fit is reported, the holes counted
    var over = pack([TILE_XL, TILE_L, TILE_L])
    assert_false(over.fits[1])
    assert_false(over.fits[2])
    assert_equal(over.holes, 4)
    var gap = pack([TILE_L, TILE_W, TILE_W, TILE_W, TILE_S])
    assert_equal(gap.holes, 1)
    print("dense packing: ok")


def test_spring() raises:
    var s = Spring(0.0, WATER_K, WATER_C)
    s.to(1.0)
    var peak = 0.0
    var us = 0
    while s.step(FRAME_US):
        us += FRAME_US
        peak = max(peak, s.value)
        assert_true(us < 2_000_000, "never settles")
    var ms = us // 1000
    print("  water spring: settled in", ms, "ms, overshoot", Float64(Int((peak - 1.0) * 1000.0)) / 10.0, "%; water_ms =", water_ms())
    assert_true(ms <= 1000, "settles within 1 s")
    assert_true(peak - 1.0 <= 0.03, "overshoot <= 3 %")
    assert_true(peak > 1.0, "a slight overshoot (it is underdamped: water, not a door)")
    print("water spring: ok")


def test_promotion() raises:
    """A promoted tile's rect glides there in <= 1 s (within 0.5 pt), never more than 3 % past its change."""
    var tiles = LiveTiles()
    tiles.set_area(W, H)
    var six = sample(6)
    tiles.set_tiles(six)
    var before = tiles.box_of("weather")
    assert_equal(size_of(tiles, "weather"), TILE_S)
    tiles.set_tiles(promoted(six, "weather"))
    assert_equal(size_of(tiles, "weather"), TILE_L)
    var goal = tiles.target_of("weather")
    var t_ms = 0
    var settled_ms = -1
    var worst = 0.0
    for f in range(120):
        _ = tiles.frame(FRAME_US)
        t_ms += FRAME_US // 1000
        var b = tiles.box_of("weather")
        # progress of each side, as a fraction of its change: never beyond 1.03, never backwards before arriving
        var pw = (b.w - before.w) / (goal.w - before.w)
        var ph = (b.h - before.h) / (goal.h - before.h)
        worst = max(worst, max(pw, ph))
        var close = abs(b.x - goal.x) < 0.5 and abs(b.y - goal.y) < 0.5 and abs(b.w - goal.w) < 0.5 and abs(b.h - goal.h) < 0.5
        if close and settled_ms < 0:
            settled_ms = t_ms
        if not close:
            settled_ms = -1
    print("  promotion: weather s -> l settled (0.5 pt) at", settled_ms, "ms, peak", Float64(Int(worst * 1000.0)) / 10.0, "% of its change")
    assert_true(settled_ms > 0 and settled_ms <= 1000, "settles within 1 s")
    assert_true(worst <= 1.03, "overshoot <= 3 %")
    print("promotion glides: ok")


def test_text_at_final() raises:
    """From the first frame of a size change the words are laid out in the final rect (never the surface's stretching
    one), drawn with the final size's font, clear at first (opacity 0) and fully in once the water settles."""
    var tiles = LiveTiles()
    var font = Font()
    var px = List[UInt32](length=900 * 600, fill=0)
    var surface = Surface(Int(px.unsafe_ptr()), 900, 600, 1.0)
    var look = TileLook.of(Palette.plain())
    var six = sample(6)
    tiles.set_tiles(six)
    tiles.draw(surface, look, font)
    tiles.set_tiles(promoted(six, "weather"))
    var goal = tiles.target_of("weather")
    var frames = 0
    var mid = False
    for f in range(60):
        _ = tiles.frame(FRAME_US)
        tiles.draw(surface, look, font)
        frames += 1
        var line = String("")
        for l in tiles.record().split("\n"):
            if String(l).startswith("weather "):
                line = String(l)
        var v = line.split(" ")
        var sw = Float64(String(v[3]))
        var tw = Float64(String(v[7]))
        var th = Float64(String(v[8]))
        var op = Float64(String(v[9]))
        var font_pt = Float64(String(v[10]))
        assert_true(abs(tw - goal.w) < 0.11 and abs(th - goal.h) < 0.11, "words in the final rect at frame " + String(f))
        assert_equal(font_pt, 32.0, "the final (large) font from the first frame")
        if f == 0:
            assert_true(op == 0.0, "clear on the first frame")
            assert_true(abs(sw - goal.w) > 20.0, "the surface is still small on the first frame")
        if abs(sw - goal.w) > 5.0 and abs(sw - goal.w) < goal.w - 5.0:
            mid = True
    assert_true(mid, "a mid-motion frame was seen")
    var last = String("")
    for l in tiles.record().split("\n"):
        if String(l).startswith("weather "):
            last = String(l)
    assert_true(Float64(String(last.split(" ")[9])) == 100.0, "fully in after the water")
    assert_true(fade_at(100.0, 700.0) == 0.0 and fade_at(700.0, 700.0) == 1.0)
    _ = len(px)  # (the pixels outlive every draw, D-7748)
    print("words at the final rect from frame 1: ok")


def test_reorder() raises:
    var tiles = LiveTiles()
    tiles.set_area(W, H)
    tiles.set_tiles(sample(6))  # traffic l, todo w (2,0), cal w (2,1), counter w (0,2), bday s, weather s
    var a = tiles.target_of("todo")
    var b = tiles.target_of("cal")
    tiles.gesture(PRESS, a.x + a.w / 2, a.y + a.h / 2)
    for i in range(1, 6):  # moves down onto cal
        tiles.gesture(PAN, a.x + a.w / 2, a.y + a.h / 2 + (b.y - a.y) * Float64(i) / 5.0)
        _ = tiles.frame(FRAME_US)
    tiles.gesture(RELEASE, b.x + b.w / 2, b.y + b.h / 2)
    var res = tiles.take_results()
    assert_equal(len(res), 1)
    assert_equal(res[0].kind, REORDERED)
    assert_equal(res[0].text, "traffic,cal,todo,counter,bday,weather")
    assert_true(at(tiles, "cal") == Rect(2, 0, 2, 1) and at(tiles, "todo") == Rect(2, 1, 2, 1), "cal and todo traded places")
    # the dropped tile glides from where it was let go into its new slot; the others flowed on the same water
    var settled = False
    for f in range(70):
        if not tiles.frame(FRAME_US):
            settled = True
            break
    assert_true(settled, "settled after the drop")
    # the urgent tile keeps the lead after a later promotion's update; dragging something before it takes the lead away
    var tr = tiles.target_of("traffic")
    var cal = tiles.target_of("cal")
    tiles.gesture(PRESS, cal.x + 20, cal.y + 20)
    tiles.gesture(PAN, cal.x + 30, cal.y + 30)
    tiles.gesture(PAN, tr.x + 40, tr.y + 40)
    tiles.gesture(RELEASE, tr.x + 40, tr.y + 40)
    var r2 = tiles.take_results()
    assert_equal(r2[0].text, "cal,traffic,todo,counter,bday,weather")
    assert_equal(size_of(tiles, "cal"), TILE_L, "the first place is the large one")
    tiles.reset()
    assert_equal(tiles.layout().ids[0], "traffic")
    print("drag reorders: ok")


def test_grip() raises:
    var tiles = LiveTiles()
    tiles.set_area(W, H)
    tiles.set_tiles(sample(6))
    var c = tiles.target_of("counter")  # w at (0, 2)
    var cell = cell_box(Rect(0, 0, 1, 1), W, H)
    select(tiles, c)  # (the grip is drawn, and live, on the selected tile only)
    tiles.gesture(PRESS, c.x + c.w - 6, c.y + c.h - 6)  # the corner grip
    tiles.gesture(PAN, c.x + c.w - 6 - (cell.w + 12) * 0.9, c.y + c.h - 6)  # a cell narrower
    tiles.gesture(RELEASE, c.x + c.w - 6 - (cell.w + 12) * 0.9, c.y + c.h - 6)
    var res = tiles.take_results()
    assert_true(len(res) >= 1 and res[len(res) - 1].kind == RESIZED and res[len(res) - 1].text == "s", "w -> s")
    assert_equal(size_of(tiles, "counter"), TILE_S)
    assert_equal(tiles.layout().holes, 1, "a user's size may leave a hole: reported")
    for f in range(90):  # (the others flow into place: a person presses where a tile is drawn)
        _ = tiles.frame(FRAME_US)
    # a small one pulled a cell right snaps to w (and fills the hole again)
    var b = tiles.target_of("bday")  # s at (1, 2)
    select(tiles, b)
    tiles.gesture(PRESS, b.x + b.w - 5, b.y + b.h - 5)
    tiles.gesture(PAN, b.x + b.w - 5 + cell.w + 12, b.y + b.h - 5)
    tiles.gesture(RELEASE, b.x + b.w - 5 + cell.w + 12, b.y + b.h - 5)
    assert_equal(size_of(tiles, "bday"), TILE_W, "s -> w")
    assert_equal(tiles.layout().holes, 0, "full again")
    for f in range(90):
        _ = tiles.frame(FRAME_US)
    # a wide one pulled a cell down snaps to l; what no longer fits is reported, not drawn over
    var t = tiles.target_of("todo")  # w at (2, 0)
    select(tiles, t)
    tiles.gesture(PRESS, t.x + t.w - 5, t.y + t.h - 5)
    tiles.gesture(PAN, t.x + t.w - 5, t.y + t.h - 5 + cell.h + 12)
    tiles.gesture(RELEASE, t.x + t.w - 5, t.y + t.h - 5 + cell.h + 12)
    assert_equal(size_of(tiles, "todo"), TILE_L, "w -> l")
    assert_true(at(tiles, "todo") == Rect(2, 0, 2, 2))
    var rs = tiles.take_results()
    assert_equal(rs[len(rs) - 1].text, "l")
    var lay = tiles.layout()
    print("  after the grips:", len(lay.ids), "shown,", len(lay.overflow), "overflow,", lay.holes, "holes")
    assert_true(len(lay.overflow) >= 1, "the tile that no longer fits is reported")
    print("grip resizes: ok")


def select(mut tiles: LiveTiles, b: Box):
    """A tap in the middle of a tile (it becomes the selected one); its result taken."""
    tiles.gesture(PRESS, b.x + b.w / 2, b.y + b.h / 2)
    tiles.gesture(TAP, b.x + b.w / 2, b.y + b.h / 2)
    _ = tiles.take_results()


def test_grip_rules() raises:
    """The grip works only on the selected tile (where it is drawn); a press and release on it without moving is a tap; a
    resize whose tile a patch removed records nothing."""
    var tiles = LiveTiles()
    tiles.set_area(W, H)
    tiles.set_tiles(sample(6))
    var cell = cell_box(Rect(0, 0, 1, 1), W, H)
    var c = tiles.target_of("counter")
    # not selected: its corner is just part of the tile (a tap there is a tap; a drag from it would reorder)
    tiles.gesture(PRESS, c.x + c.w - 6, c.y + c.h - 6)
    tiles.gesture(TAP, c.x + c.w - 6, c.y + c.h - 6)
    var r = tiles.take_results()
    assert_true(len(r) == 1 and r[0].kind == TAPPED and r[0].id == "counter", "a corner tap on an unselected tile is a tap")
    assert_equal(tiles.selected, "counter")
    # selected now: pressing the grip and letting go without moving is still a tap, never a resize
    tiles.gesture(PRESS, c.x + c.w - 6, c.y + c.h - 6)
    tiles.gesture(RELEASE, c.x + c.w - 6, c.y + c.h - 6)
    r = tiles.take_results()
    assert_true(len(r) == 1 and r[0].kind == TAPPED, "a grip press without a move falls back to a tap")
    assert_equal(size_of(tiles, "counter"), TILE_W)
    # a resize under way when a patch takes the tile away: nothing is recorded, nothing reported
    tiles.gesture(PRESS, c.x + c.w - 6, c.y + c.h - 6)
    var rest = sample(6)
    _ = rest.pop(3)  # (counter goes)
    tiles.set_tiles(rest)
    tiles.gesture(PAN, c.x + c.w - 6 - (cell.w + 12) * 0.9, c.y + c.h - 6)
    tiles.gesture(RELEASE, c.x + c.w - 6 - (cell.w + 12) * 0.9, c.y + c.h - 6)
    assert_equal(len(tiles.take_results()), 0, "no RESIZED for a tile that is gone")
    assert_equal(tiles.user_size("counter"), -1)
    print("grip rules: ok")


def test_promote_beats_grip() raises:
    """A size the person chose with the grip gives way when the agent promotes that tile (it leads, large, the grid full);
    sizes of tiles that went are forgotten, so a tile added again starts fresh."""
    var tiles = LiveTiles()
    tiles.set_area(W, H)
    var six = sample(6)
    tiles.set_tiles(six)
    var cell = cell_box(Rect(0, 0, 1, 1), W, H)
    var d = tiles.target_of("cal")  # w
    select(tiles, d)
    tiles.gesture(PRESS, d.x + d.w - 6, d.y + d.h - 6)
    tiles.gesture(PAN, d.x + d.w - 6 - (cell.w + 12) * 0.9, d.y + d.h - 6)
    tiles.gesture(RELEASE, d.x + d.w - 6 - (cell.w + 12) * 0.9, d.y + d.h - 6)
    assert_equal(size_of(tiles, "cal"), TILE_S)
    tiles.set_tiles(promoted(six, "cal"))
    var lay = tiles.layout()
    assert_equal(lay.ids[0], "cal")
    assert_equal(lay.sizes[0], TILE_L, "the promoted tile is large, not the size the grip gave it")
    assert_equal(lay.holes, 0)
    # another tile's chosen size, then that tile removed and added again: it comes back at the preset's size
    var b = tiles.target_of("bday")
    for f in range(90):
        _ = tiles.frame(FRAME_US)
    b = tiles.target_of("bday")
    select(tiles, b)
    tiles.gesture(PRESS, b.x + b.w - 5, b.y + b.h - 5)
    tiles.gesture(PAN, b.x + b.w - 5 + cell.w + 12, b.y + b.h - 5)
    tiles.gesture(RELEASE, b.x + b.w - 5 + cell.w + 12, b.y + b.h - 5)
    assert_true(tiles.user_size("bday") != -1)
    var without = List[Tile]()
    for t in promoted(six, "cal"):
        if t.id != "bday":
            without.append(t.copy())
    tiles.set_tiles(without)
    assert_equal(tiles.user_size("bday"), -1, "a removed tile's size is forgotten")
    tiles.set_tiles(promoted(six, "cal"))
    assert_equal(tiles.layout().holes, 0)
    print("promote beats the grip: ok")


def test_compact() raises:
    """A phone: two columns of 112 pt rows, the first large, the rest a row each (six: l w w w s s), every row full; an
    xl lead is large there; the canvas height follows the rows."""
    for n in range(1, 7):
        var k = pack_grid(preset_compact(n), 2, 64)
        assert_equal(k.holes, 0, "compact preset " + String(n))
    var tiles = LiveTiles()
    tiles.set_area(342, 800)
    tiles.set_columns(2)
    tiles.set_tiles(sample(6))
    var lay = tiles.layout()
    assert_equal(len(lay.ids), 6)
    assert_equal(lay.holes, 0)
    for c in lay.cells:
        assert_true(c.x + c.w <= 2, "two columns")
    assert_equal(tiles.compact_height(), compact_rows_height(6))  # (l: 2 rows, three w, one row of two s)
    var b = tiles.target_of("traffic")
    assert_true(abs(b.h - 236.0) < 0.01, "a large tile is two 112 pt rows and a gap")
    var w = tiles.target_of("todo")
    assert_true(abs(w.w - (342 - 28)) < 0.01 and abs(w.h - 112.0) < 0.01, "a w tile is a whole row")
    var big = sample(3)
    big[0].big = True
    tiles.set_tiles(big)
    assert_equal(tiles.layout().sizes[0], TILE_L, "xl is large on a phone")
    tiles.set_columns(4)
    assert_equal(tiles.layout().sizes[0], TILE_XL)
    print("a phone's two columns: ok")


def test_drop_zone() raises:
    """A tile dragged out of the grid and let go over a drop zone (outside the canvas) is DROPPED there, not reordered."""
    var tiles = LiveTiles()
    tiles.set_area(W, H)
    tiles.set_tiles(sample(6))
    tiles.drop_zone("pinned", Box(-300, 0, 260, 400))
    var t = tiles.target_of("todo")
    tiles.gesture(PRESS, t.x + 30, t.y + 30)
    tiles.gesture(PAN, t.x + 50, t.y + 40)
    tiles.gesture(PAN, -150, 120)
    assert_equal(tiles.hover_zone, "pinned")
    tiles.gesture(RELEASE, -150, 120)
    var r = tiles.take_results()
    assert_equal(len(r), 1)
    assert_equal(r[0].kind, DROPPED)
    assert_equal(r[0].id, "todo")
    assert_equal(r[0].text, "pinned")
    assert_equal(tiles.hover_zone, "")
    # let go anywhere else outside the grid: a plain drop (it glides home)
    for f in range(90):
        _ = tiles.frame(FRAME_US)
    tiles.gesture(PRESS, t.x + 30, t.y + 30)
    tiles.gesture(PAN, t.x + 50, t.y + 40)
    tiles.gesture(PAN, -150, 520)
    tiles.gesture(RELEASE, -150, 520)
    assert_equal(tiles.take_results()[0].kind, REORDERED)
    print("drop zones: ok")


def test_press() raises:
    assert_equal(press_amount(40.0), 0.9)
    assert_equal(press_amount(200.0), 0.955)
    assert_equal(press_amount(300.0), 0.975)
    var tiles = LiveTiles()
    tiles.set_area(W, H)
    tiles.set_tiles(sample(6))
    var t = tiles.target_of("todo")  # w: wider than 260 pt at 900 wide
    assert_true(t.w > 260.0)
    var s = tiles.target_of("bday")  # s: narrower
    assert_true(s.w <= 260.0)
    tiles.gesture(PRESS, t.x + 30, t.y + 30)
    for f in range(30):
        _ = tiles.frame(FRAME_US)
    assert_true(abs(tiles.anims[tiles._anim("todo")].press.value - 0.975) < 0.002, "a large tile squashes to 0.975")
    tiles.gesture(TAP, t.x + 30, t.y + 30)
    var peak = 0.0
    var us = 0
    while tiles.frame(FRAME_US) and us < 1_000_000:
        us += FRAME_US
        peak = max(peak, tiles.anims[tiles._anim("todo")].press.value)
    var over = (peak - 1.0) / (1.0 - 0.975)
    print("  press: back in", us // 1000, "ms, overshoot", Float64(Int(over * 1000.0)) / 10.0, "% of the squash")
    assert_true(us <= 400_000, "back on the fast spring (~300 ms)")
    assert_true(over <= 0.02, "fast spring overshoot <= 2 %")
    var res = tiles.take_results()
    assert_equal(res[0].kind, TAPPED)
    assert_equal(res[0].id, "todo")
    tiles.gesture(PRESS, s.x + 20, s.y + 20)
    for f in range(30):
        _ = tiles.frame(FRAME_US)
    assert_true(abs(tiles.anims[tiles._anim("bday")].press.value - 0.955) < 0.002, "a small tile squashes to 0.955")
    tiles.gesture(TAP, s.x + 20, s.y + 20)
    print("press amounts: ok")


def test_actions_tap() raises:
    var tiles = LiveTiles()
    var font = Font()
    var px = List[UInt32](length=900 * 600, fill=0)
    var surface = Surface(Int(px.unsafe_ptr()), 900, 600, 1.0)
    tiles.set_tiles(sample(6))
    tiles.draw(surface, TileLook.of(Palette.plain()), font)
    var found = False
    for i in range(len(tiles.pill_ids)):
        if tiles.pill_text[i] == "Later":
            var b = tiles.pill_box[i]
            tiles.gesture(PRESS, b.x + b.w / 2, b.y + b.h / 2)
            tiles.gesture(TAP, b.x + b.w / 2, b.y + b.h / 2)
            found = True
    assert_true(found, "the urgent tile shows its actions")
    var res = tiles.take_results()
    assert_equal(res[0].kind, ACTION)
    assert_equal(res[0].text, "Later")
    _ = len(px)
    print("action pills: ok")


def test_big_and_overflow() raises:
    var tiles = LiveTiles()
    tiles.set_area(W, H)
    var six = sample(6)
    six[4].big = True  # bday
    tiles.set_tiles(six)
    var lay = tiles.layout()
    assert_equal(len(lay.ids), 3)
    assert_equal(lay.ids[0], "bday")
    assert_true(lay.sizes[0] == TILE_XL and lay.sizes[1] == TILE_W and lay.sizes[2] == TILE_W)
    assert_equal(len(lay.overflow), 3)
    assert_equal(lay.holes, 0)
    var eight = LiveTiles()
    eight.set_area(W, H)
    eight.set_tiles(sample(8))
    var l8 = eight.layout()
    assert_equal(len(l8.ids), 6)
    assert_equal(l8.overflow[0], "home")
    assert_equal(l8.overflow[1], "photos")
    assert_equal(l8.holes, 0)
    print("big and overflow: ok")


def test_parts() raises:
    var tiles = LiveTiles()
    tiles.set_area(W, H)
    tiles.set_tiles(sample(5))
    var parts = tiles.parts("stage", "stage.tiles")
    assert_equal(len(parts), 5)
    assert_equal(parts[0].card + "." + parts[0].part, "stage.traffic")
    assert_equal(parts[0].inside, "stage.tiles")
    assert_equal(parts[0].names[0], "TRAFFIC")
    print("pointer parts: ok")


def main() raises:
    test_presets()
    test_dense()
    test_spring()
    test_promotion()
    test_text_at_final()
    test_reorder()
    test_grip()
    test_grip_rules()
    test_promote_beats_grip()
    test_compact()
    test_drop_zone()
    test_press()
    test_actions_tap()
    test_big_and_overflow()
    test_parts()
    print("livetiles: ok")
