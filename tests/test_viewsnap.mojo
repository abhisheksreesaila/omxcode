# Goal 79, D-7956: a tiled layer's last view kept on disk (mojoui.viewsnap) and shown on the next open.
# (1) the RLE codec gives back exactly what it took (runs, literals, edges, random pixels); (2) a snapshot file reads
# back with its key, note and tiles; a torn or foreign file is refused; (3) a key differing in any one part (the app's
# tag: revision or skin; the zoom (device scale); the view; the size; the renderer; the build) doesn't match;
# (4) on the real GL renderer (headless): a board's frame drawn by a fresh renderer from the snapshot alone (its layer
# holding: no ops yet) is pixel-identical to the frame the renderer that kept it drew, and the real tiles that replace
# it are too; a snapshot whose key differs is never shown; the app's note comes back from the head for its tag only;
# (5) a renderer already showing the board's real tiles, given a new picture of it (BoardLook.forget(), a cold open)
# that holds, shows the snapshot in that same frame, identical, nothing rastered; (6) an edit in the frame the hold ends
# (the app withdraws its tag: unsaved) promotes the snapshot and applies the edit's damage: equal to a fresh raster.
# `viewsnap: ok`.
#   pixi run mojo run -I . -I vendor tests/test_viewsnap.mojo
from std.testing import assert_true, assert_equal
from std.random import random_ui64, seed
from std.os import getenv
from std.time import perf_counter_ns
from mojoui.viewsnap import rle_encode, rle_decode, SnapKey, ViewSnap, SnapWriter, snap_read, snap_ahead, snap_take, snap_dir_ready, build_id
from mojoui.scene import Scene
from mojoui.gpu2d_gl import GPU2D, headless_gl33
from mojoui.pagedesk import DeskView, BoardLook, BoardTools
from mojoui.objectlayer import ObjectLayer, import_json_canvas, CH_MOVE
from mojoui.libc import unlink

comptime W = 2304
comptime H = 1440
comptime K = 1.6


def board() -> ObjectLayer:
    try:
        var f = open("build/g79/race/note-stress.json", "r")
        var t = f.read()
        f.close()
        var l = import_json_canvas(t)
        l.set_connector_gap(6)
        return l^
    except:
        var l = ObjectLayer()
        for i in range(1200):
            var x = Float64(i % 40) * 120
            var y = Float64(i // 40) * 110
            if i % 2 == 0:
                _ = l.add_text(x, y, 100, 40, "Text " + String(i))
            else:
                _ = l.add_sticky(x, y, 90, "Sticky " + String(i))
        return l^


def frame(mut g: GPU2D, mut look: BoardLook, mut layer: ObjectLayer, v: DeskView) raises -> List[UInt32]:
    var sc = Scene(W, H, 1.0)
    sc.begin_layer("bg")
    sc.fill(0xFFF0F2F5)
    look.paint(sc, layer, v, 1440, 900, K)
    var s = g.draw(sc, Scene(0, 0, 1.0), 1, W, H)
    assert_true(s >= 0, "draw: " + g.gl.why)
    var px = List[UInt32](length=W * H, fill=0)
    assert_true(g.gl.read(g.gl.tex[s], W, H, Int(px.unsafe_ptr())), "read")
    return px^


def differ(a: List[UInt32], b: List[UInt32]) -> Int:
    var n = 0
    for i in range(len(a)):
        if a[i] != b[i]:
            n += 1
    return n


def gl_identity() raises:
    assert_true(headless_gl33() != 0, "a headless GL context")
    var dir = getenv("TMPDIR", "/tmp") + "/viewsnap-test"
    assert_true(snap_dir_ready(dir), "folder")
    var path = dir + "/board.snap"
    _ = unlink(path)
    var layer = board()
    print("   board:", len(layer.objs), "objects")
    var v = DeskView(-300, -200, 1.0)
    # the renderer that keeps it: the first frame rasters every visible tile; once settled it reads them back, one a frame
    var look = BoardLook()
    look.keep_path = path
    look.keep_tag = "note=1;rev=5;skin=paper"
    look.keep_note = "grid=4x4"
    var g = GPU2D()
    assert_true(g.start(False), "start")
    var a = frame(g, look, layer, v)
    var t_settle = perf_counter_ns()
    var settle_frames = 0
    while not snap_read(path, True).ok and perf_counter_ns() - t_settle < 5_000_000_000:  # (D-7962: a save waits for 750 ms of a still view)
        var again = frame(g, look, layer, v)
        assert_equal(differ(again, a), 0)  # (reading tiles back changes nothing on screen)
        settle_frames += 1
    for _ in range(40):  # (and the last tiles' reads after the file appears change nothing either)
        assert_equal(differ(frame(g, look, layer, v), a), 0)
    assert_true(perf_counter_ns() - t_settle >= 700_000_000, "not saved before the view held still")
    var kept = snap_read(path)
    assert_true(kept.ok, "kept after settling")
    print("   kept:", len(kept.tiles), "tiles,", len(kept.bytes), "bytes")
    # (D-8015) read ahead: the same file's bytes and key, the renderer's picture from it the same (below, once each way);
    # another path, or one asked for too late, is read as it is
    snap_ahead(path)
    var ahead = snap_take(path)
    assert_true(ahead.ok and ahead.key.same(kept.key) and ahead.note == kept.note, "read ahead: the same head")
    assert_equal(len(ahead.tiles), len(kept.tiles))
    assert_true(ahead.bytes == kept.bytes, "read ahead: the same bytes")
    snap_ahead(path + ".gone")
    assert_true(not snap_take(path + ".gone").ok, "no file: none")
    snap_ahead(path + ".gone")
    assert_true(snap_take(path).ok, "another path than the one read ahead")
    snap_ahead(path)
    # a fresh renderer, the board not loaded yet (holding): the kept view alone, nothing rastered
    var empty = ObjectLayer()
    var look2 = BoardLook()
    look2.keep_path = path
    look2.keep_tag = "note=1;rev=5;skin=paper"
    look2.keep_hold = True
    assert_true(look2.kept_view(path, look2.keep_tag, v, 1440, 900, K), "the app's check agrees with the renderer's")
    assert_equal(look2.kept_note(path, look2.keep_tag), "grid=4x4")
    assert_equal(look2.kept_note(path, "note=1;rev=6;skin=paper"), "")
    var g2 = GPU2D()
    assert_true(g2.start(False), "start 2")
    var b = frame(g2, look2, empty, v)
    assert_equal(g2.tiles.rastered, 0)
    assert_true(g2.tiles.has_snap("board", 1), "shown from the snapshot")
    var d = differ(a, b)
    print("   first frame from the snapshot vs the first frame drawn:", d, "pixels differ")
    assert_equal(d, 0)
    # the board arrives: its real tiles replace the snapshot a few a frame, every frame identical
    look2.keep_hold = False
    var frames = 0
    while g2.tiles.has_snap("board", 1) and frames < 60:
        var c = frame(g2, look2, layer, v)
        assert_equal(differ(a, c), 0)
        frames += 1
    assert_true(not g2.tiles.has_snap("board", 1), "replaced")
    print("   became the layer's tiles after", frames, "frames, each identical")
    # (D-7956) promoted tiles are good for the part they hold: a pan rasters only the strips the view newly reaches, and
    # the frame equals a fresh renderer's raster of the same view; so does a zoom's settled frame
    var pans = [DeskView(-340, -230, 1.0), DeskView(-200, -120, 1.0)]
    for pv in pans:
        var pl = BoardLook()
        var gr = GPU2D()
        assert_true(gr.start(False), "start ref")
        var want = frame(gr, pl, layer, pv)
        for _ in range(3):
            want = frame(gr, pl, layer, pv)
        gr.gl.close()
        var got = frame(g2, look2, layer, pv)
        for _ in range(3):
            got = frame(g2, look2, layer, pv)
        var dp = differ(want, got)
        print("   panned over promoted tiles:", dp, "pixels differ from a fresh raster")
        assert_equal(dp, 0)
    # an edit over promoted tiles: its stale part rastered again, the frame equals a fresh raster of the edited board
    var pv2 = DeskView(-200, -120, 1.0)
    var vis = BoardTools().visible_objects(layer, pv2, 1440, 900)
    layer.select(layer.objs[vis[len(vis) // 2]].id, False)
    layer.begin_gesture(CH_MOVE)
    layer.move_by(41, 23)
    layer.end_gesture()
    var got2 = frame(g2, look2, layer, pv2)
    for _ in range(3):
        got2 = frame(g2, look2, layer, pv2)
    var gr2 = GPU2D()
    assert_true(gr2.start(False), "start ref 2")
    var pl2 = BoardLook()
    var want2 = frame(gr2, pl2, layer, pv2)
    for _ in range(3):
        want2 = frame(gr2, pl2, layer, pv2)
    gr2.gl.close()
    var de = differ(want2, got2)
    print("   an edit over promoted tiles:", de, "pixels differ from a fresh raster")
    assert_equal(de, 0)
    _ = layer.undo()
    # stale: another revision, skin, zoom, view or size is never shown
    var stale_tags: List[String] = ["note=1;rev=6;skin=paper", "note=1;rev=5;skin=night"]
    for t in stale_tags:
        var l3 = BoardLook()
        l3.keep_path = path
        l3.keep_tag = t
        l3.keep_hold = True
        assert_true(not l3.kept_view(path, t, v, 1440, 900, K), "app check refuses " + t)
        var g3 = GPU2D()
        assert_true(g3.start(False), "start 3")
        _ = frame(g3, l3, empty, v)
        assert_true(not g3.tiles.has_snap("board", 1), "refused: " + t)
        g3.gl.close()
    var views = [DeskView(-301, -200, 1.0), DeskView(-300, -200, 1.25)]
    for vv in views:
        var g4 = GPU2D()
        assert_true(g4.start(False), "start 4")
        assert_true(not look2.kept_view(path, look2.keep_tag, vv, 1440, 900, K), "app check refuses a view")
        look2.keep_hold = True
        _ = frame(g4, look2, empty, vv)
        assert_true(not g4.tiles.has_snap("board", 1), "refused: another view")
        g4.gl.close()
    assert_true(not look2.kept_view(path, look2.keep_tag, v, 1440, 900, 2.0), "another device scale")
    assert_true(not look2.kept_view(path, look2.keep_tag, v, 1441, 900, K), "another size")
    # (5) the renderer that kept it, its real tiles on screen, then a new picture (a cold open) holding: the snapshot now
    look.forget()
    look.keep_hold = True
    var e = frame(g, look, empty, v)
    assert_true(g.tiles.has_snap("board", 1), "a new picture restores the snapshot in its own frame")
    assert_equal(g.tiles.rastered, 0)
    assert_equal(differ(a, e), 0)
    print("   a cold open on a live renderer: shown from the snapshot in its first frame, identical")
    # (6) the hold ends with an edit in the same frame (the tag withdrawn: an unsaved board)
    var g6 = GPU2D()
    assert_true(g6.start(False), "start 6")
    var look6 = BoardLook()
    look6.keep_path = path
    look6.keep_tag = "note=1;rev=5;skin=paper"
    look6.keep_hold = True
    _ = frame(g6, look6, empty, v)
    assert_true(g6.tiles.has_snap("board", 1), "6: shown from the snapshot")
    var vis6 = BoardTools().visible_objects(layer, v, 1440, 900)
    var moved = layer.objs[vis6[len(vis6) // 3]].id
    layer.select(moved, False)
    layer.begin_gesture(CH_MOVE)
    layer.move_by(-33, 29)
    layer.end_gesture()
    look6.keep_hold = False
    look6.keep_tag = ""
    var got6 = frame(g6, look6, layer, v)
    for _ in range(3):
        got6 = frame(g6, look6, layer, v)
    var gr6 = GPU2D()
    assert_true(gr6.start(False), "start ref 6")
    var pl6 = BoardLook()
    var want6 = frame(gr6, pl6, layer, v)
    for _ in range(3):
        want6 = frame(gr6, pl6, layer, v)
    var d6 = differ(want6, got6)
    print("   an edit as the hold ends: promoted, damaged:", d6, "pixels differ from a fresh raster")
    assert_equal(d6, 0)
    _ = layer.undo()
    gr6.gl.close()
    g6.gl.close()
    g.gl.close()
    g2.gl.close()
    print("gl: ok")


def codec() raises:
    seed(7)
    for cs in range(6):
        var n = [1, 2, 3, 1000, 4096, 262144][cs]
        var px = List[UInt32](length=n, fill=0)
        for i in range(n):
            var r = Int(random_ui64(0, 9))
            if cs % 2 == 0 and i > 0 and r < 7:
                px[i] = px[i - 1]  # (runs)
            else:
                px[i] = UInt32(random_ui64(0, 0xFFFFFFFF)) if r < 9 else 0
        var enc = List[UInt8]()
        rle_encode(Int(px.unsafe_ptr()), n, enc)
        var back = List[UInt32](length=n, fill=7)
        assert_true(rle_decode(Int(enc.unsafe_ptr()), len(enc), Int(back.unsafe_ptr()), n), "decodes")
        for i in range(n):
            assert_equal(back[i], px[i])
        # (a short or long count is refused, not read past)
        var short = List[UInt32](length=n + 1, fill=0)
        assert_true(not rle_decode(Int(enc.unsafe_ptr()), len(enc), Int(short.unsafe_ptr()), n + 1), "a wrong length is refused")
    var blank = List[UInt32](length=512 * 512, fill=0)
    var enc = List[UInt8]()
    rle_encode(Int(blank.unsafe_ptr()), len(blank), enc)
    assert_true(len(enc) == 8, "a blank tile is one run")
    print("codec: ok")


def files() raises:
    var dir = getenv("TMPDIR", "/tmp") + "/viewsnap-test"
    assert_true(snap_dir_ready(dir), "folder")
    var key = SnapKey("note=7;rev=12;skin=paper", 99, build_id(), 1.6, -120.0, 64.0, 2304, 1440)
    var w = SnapWriter(dir + "/a.snap", key, "cols=2;rows=1")
    var px = List[UInt32](length=40 * 30, fill=0xFF112233)
    px[5] = 0
    w.add(3, -1, 1, 2, 40, 30, Int(px.unsafe_ptr()))
    w.add(4, -1, 0, 0, 0, 0, 0)
    assert_true(w.finish(), "written")
    var s = snap_read(dir + "/a.snap")
    assert_true(s.ok, "read")
    assert_true(s.key.same(key), "its key: " + s.key.why_not(key))
    assert_equal(s.note, "cols=2;rows=1")
    assert_equal(len(s.tiles), 2)
    assert_equal(s.tiles[0].i, 3)
    assert_equal(s.tiles[0].j, -1)
    assert_equal(s.tiles[1].w, 0)
    var back = List[UInt32](length=40 * 30, fill=0)
    assert_true(s.decode(s.tiles[0], Int(back.unsafe_ptr())), "tile")
    for i in range(len(px)):
        assert_equal(back[i], px[i])
    var h = snap_read(dir + "/a.snap", True)
    assert_true(h.ok and h.key.same(key) and len(h.tiles) == 0, "head only")
    # (a torn file: refused)
    var b = List[UInt8]()
    try:
        var f = open(dir + "/a.snap", "r")
        b = f.read_bytes()
        f.close()
        var g = open(dir + "/torn.snap", "w")
        g.write_bytes(Span(b)[: len(b) - 9])
        g.close()
    except:
        pass
    assert_true(not snap_read(dir + "/torn.snap").ok, "torn file refused")
    assert_true(not snap_read(dir + "/missing.snap").ok, "no file")
    # (3) any one part different: no match
    var other = [SnapKey("note=7;rev=13;skin=paper", 99, key.build, 1.6, -120.0, 64.0, 2304, 1440),  # revision
                 SnapKey("note=7;rev=12;skin=night", 99, key.build, 1.6, -120.0, 64.0, 2304, 1440),  # skin
                 SnapKey(key.tag, 99, key.build, 2.0, -120.0, 64.0, 2304, 1440),  # device scale / zoom
                 SnapKey(key.tag, 99, key.build, 1.6, -121.0, 64.0, 2304, 1440),  # view
                 SnapKey(key.tag, 99, key.build, 1.6, -120.0, 64.0, 2304, 1441),  # size
                 SnapKey(key.tag, 98, key.build, 1.6, -120.0, 64.0, 2304, 1440),  # renderer
                 SnapKey(key.tag, 99, key.build + 1, 1.6, -120.0, 64.0, 2304, 1440)]  # build
    for o in other:
        assert_true(not s.key.same(o) and s.key.why_not(o) != "", "differs: " + o.text())
    print("files: ok")


def kept_by_more_alone() raises:
    """(D-8016) A host draws again only while the renderer says there is more to do: from any board and view, that alone
    ends with the view kept. (Once, on the Mac, a frame that rastered its last tile asked for nothing more: the view was
    never kept and the next open started from nothing.)"""
    var dir = getenv("TMPDIR", "/tmp") + "/viewsnap-test"
    var missed = String("")
    var n = 0
    for size in [1, 7, 30, 90, 300, 700, 1200]:
        for q in range(4):
            var layer = ObjectLayer()
            for i in range(size):
                _ = layer.add_sticky(Float64(i % 40) * 120, Float64(i // 40) * 110, 90, "Sticky " + String(i))
            var v = [DeskView(-300, -200, 1.0), DeskView(100, 80, 0.3), DeskView(-1700, -900, 1.7), DeskView(40, 30, 1.0)][q]
            var path = dir + "/more-" + String(size) + "-" + String(q) + ".snap"
            _ = unlink(path)
            var look = BoardLook()
            look.keep_path = path
            look.keep_tag = "note=2;rev=1;skin=paper"
            var g = GPU2D()
            assert_true(g.start(False), "start")
            var t0 = perf_counter_ns()
            while True:
                _ = frame(g, look, layer, v)
                if not g.more or perf_counter_ns() - t0 > 6_000_000_000:
                    break
            if g.tiles.drawn == 0:  # (a board too small for tiles draws whole: there is nothing to keep)
                g.gl.close()
                continue
            n += 1
            if not snap_read(path, True).ok:
                missed += " " + String(size) + "@" + String(q)
            g.gl.close()
    print("   kept by `more` alone:", n, "boards and views; not kept:" + (missed if missed != "" else String(" none")))
    assert_equal(missed, "")
    assert_true(n >= 8, "tiled boards tried: " + String(n))


def closing_keeps() raises:
    """(D-8016) A window closing right after its first frames (a note opened and left at once): drawn again in a hurry, the
    view is kept whole, the same tiles and pixels as the unhurried save; the next renderer shows it identical."""
    var dir = getenv("TMPDIR", "/tmp") + "/viewsnap-test"
    var layer = board()
    for v in [DeskView(-300, -200, 1.0), DeskView(0, 0, 0.5), DeskView(37, -190, 1.3)]:
        var snaps = List[ViewSnap]()
        var pic = List[UInt32]()
        for hurry in [False, True]:
            var path = dir + "/close-" + ("h" if hurry else "n") + ".snap"
            _ = unlink(path)
            var look = BoardLook()
            look.keep_path = path
            look.keep_tag = "note=3;rev=1;skin=paper"
            var g = GPU2D()
            assert_true(g.start(False), "start")
            pic = frame(g, look, layer, v)
            if hurry:
                assert_true(g.tiles.keeping_due(), "not kept yet")
                g.tiles.hurry = True
                var draws = 0
                while draws < 3:
                    draws += 1
                    assert_equal(differ(frame(g, look, layer, v), pic), 0)
                    if not g.more:
                        break
                assert_true(not g.tiles.keeping_due(), "kept in " + String(draws) + " draws")
            else:
                var t0 = perf_counter_ns()
                while (g.more or not snap_read(path, True).ok) and perf_counter_ns() - t0 < 5_000_000_000:
                    _ = frame(g, look, layer, v)
            snaps.append(snap_read(path))
            g.gl.close()
        assert_true(snaps[0].ok and snaps[1].ok, "both kept")
        assert_equal(len(snaps[0].tiles), len(snaps[1].tiles), "as many tiles")
        assert_true(len(snaps[0].tiles) >= 12, "a window's worth")
        var same = 0
        for ref a in snaps[0].tiles:
            for ref b in snaps[1].tiles:
                if a.i == b.i and a.j == b.j:
                    assert_true(a.w == b.w and a.h == b.h and a.x0 == b.x0 and a.y0 == b.y0 and a.n == b.n, "the same part")
                    for q in range(a.n):
                        assert_equal(snaps[0].bytes[a.at + q], snaps[1].bytes[b.at + q])
                    same += 1
        assert_equal(same, len(snaps[0].tiles), "every tile")
        var empty = ObjectLayer()
        var look2 = BoardLook()
        look2.keep_path = dir + "/close-h.snap"
        look2.keep_tag = "note=3;rev=1;skin=paper"
        look2.keep_hold = True
        var g2 = GPU2D()
        assert_true(g2.start(False), "start 2")
        assert_equal(differ(frame(g2, look2, empty, v), pic), 0, "shown from the hurried save: identical")
        g2.gl.close()
    print("   closing: kept whole in a hurry, the same tiles as an unhurried save, shown identical (3 views)")


def main() raises:
    codec()
    files()
    gl_identity()
    kept_by_more_alone()
    closing_keeps()
    print("viewsnap: ok")
