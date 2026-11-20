# Goal 79, D-7956: a tiled layer's last view kept on disk (mojoui.viewsnap) and shown on the next open.
# (1) the RLE codec gives back exactly what it took (runs, literals, edges, random pixels); (2) a snapshot file reads
# back with its key, note and tiles; a torn or foreign file is refused; (3) a key differing in any one part (the app's
# tag: revision or skin; the zoom (device scale); the view; the size; the renderer; the build) doesn't match;
# (4) on the real GL renderer (headless): a board's frame drawn by a fresh renderer from the snapshot alone (its layer
# holding: no ops yet) is pixel-identical to the frame the renderer that kept it drew, and the real tiles that replace
# it are too; a snapshot whose key differs is never shown. `viewsnap: ok`.
#   pixi run mojo run -I . -I vendor tests/test_viewsnap.mojo
from std.testing import assert_true, assert_equal
from std.random import random_ui64, seed
from std.os import getenv
from mojoui.viewsnap import rle_encode, rle_decode, SnapKey, SnapWriter, snap_read, snap_dir_ready, build_id
from mojoui.scene import Scene
from mojoui.gpu2d_gl import GPU2D, headless_gl33
from mojoui.pagedesk import DeskView, BoardLook
from mojoui.objectlayer import ObjectLayer, import_json_canvas
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
    var g = GPU2D()
    assert_true(g.start(False), "start")
    var a = frame(g, look, layer, v)
    for _ in range(80):
        var again = frame(g, look, layer, v)
        assert_equal(differ(again, a), 0)  # (reading tiles back changes nothing on screen)
    var kept = snap_read(path)
    assert_true(kept.ok, "kept after settling")
    print("   kept:", len(kept.tiles), "tiles,", len(kept.bytes), "bytes")
    # a fresh renderer, the board not loaded yet (holding): the kept view alone, nothing rastered
    var empty = ObjectLayer()
    var look2 = BoardLook()
    look2.keep_path = path
    look2.keep_tag = "note=1;rev=5;skin=paper"
    look2.keep_hold = True
    assert_true(look2.kept_view(path, look2.keep_tag, v, 1440, 900, K), "the app's check agrees with the renderer's")
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
    print("   replaced by real tiles over", frames, "frames, each identical")
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


def main() raises:
    codec()
    files()
    gl_identity()
    print("viewsnap: ok")
