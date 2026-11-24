# Review 3, MUST 1: documents never share a cache. Two boards whose ids, revisions, versions, counts and widths collide,
# under one BoardLook (one window's look, as pnote's), switched A → B → A, opened cold, progressively and as kept parses:
# what is drawn is the open one's, op for op as a fresh look draws it, with and without the kept ops, the change log and
# the patches; and versions handed to a renderer are never the same for two documents, whichever looks drew them (a
# renderer takes the same number for the same picture). CPU only: display lists. `twodocs: ok`.
#   pixi run mojo build -I . -I vendor tests/test_twodocs.mojo -o build/test_twodocs && build/test_twodocs
from std.testing import assert_true, assert_equal
from mojoui.scene import Scene, KeptPaint
from mojoui.canvas import rgba
from mojoui.pagedesk import DeskView, BoardLook, board_rect
from mojoui.canvasload import OpenBoard
from mojoui.docstore import KeptDocs
from mojoui.objectlayer import ObjectLayer, import_json_canvas, CH_MOVE


def doc(n: Int, word: String, w: Int = 200) -> String:
    var s = String('{"nodes":[')
    for i in range(n):
        if i > 0:
            s += ","
        s += ('{"id":"n' + String(i) + '","type":"text","x":' + String(40 + (i % 4) * 260) + ',"y":' + String(40 + (i // 4) * 160) + ',"width":' + String(w)
              + ',"height":80,"text":"' + word + " " + String(i) + ' and some words that wrap over lines"}')
    s += '],"edges":[]}'
    return s


def drawn(mut look: BoardLook, mut layer: ObjectLayer, v: DeskView) -> Scene:
    var sc = Scene(1440, 900, 1.0)
    look.paint(sc, layer, v, 1440, 900, 1.0)
    return sc^


def same(a: Scene, b: Scene) -> Bool:
    if a.ops() != b.ops():
        return False
    for op in range(a.ops()):
        if not a.same_op(op, b, op):
            return False
    return True


def words(sc: Scene) -> String:
    var out = String("")
    for ref t in sc.texts:
        out += String(t) + "|"
    return out


def is_document(mut look: BoardLook, mut layer: ObjectLayer, v: DeskView, what: String) raises:
    """Three paints of the layer by the look in use: each as a fresh look draws it."""
    for q in range(3):
        var got = drawn(look, layer, v)
        var fresh = BoardLook()
        fresh.keep_ops = False
        var want = drawn(fresh, layer, v)
        assert_true(same(got, want), what + ", paint " + String(q) + ": drew " + words(got) + " for " + words(want))


def switches(na: Int, nb: Int, wb: Int, log: Bool, patch: Bool, keep: Bool) raises:
    var name = String(na) + " and " + String(nb) + " objects, log " + String(log) + " patch " + String(patch) + " keep " + String(keep)
    var v = DeskView(0, 0, 1.0)
    var r = board_rect(v, 1440, 900)
    var look = BoardLook()
    look.change_log = log
    look.patch_on = patch
    look.keep_ops = keep
    # progressive opens into one OpenBoard, as an app's
    var b = OpenBoard()
    for round in range(2):
        for d in range(2):
            assert_equal(b.open(doc(na if d == 0 else nb, "AAA" if d == 0 else "BEE", 200 if d == 0 else wb), r[0], r[1], r[2], r[3], 6), "")
            is_document(look, b.layer, v, name + ": open " + String(d))
            for _ in range(4):
                _ = b.step(r[0], r[1], r[2], r[3], 2000)
                is_document(look, b.layer, v, name + ": step of " + String(d))
            # edits collide too (the same versions again)
            b.layer.select(b.layer.objs[0].id, False)
            b.layer.begin_gesture(CH_MOVE)
            b.layer.move_by(7, 5)
            b.layer.end_gesture()
            is_document(look, b.layer, v, name + ": edit of " + String(d))
    # kept parses: the very layers back, unchanged (A, B, A, B)
    var kept = KeptDocs[ObjectLayer](4)
    kept.keep(1, 1, import_json_canvas(doc(na, "AAA")))
    kept.keep(2, 1, import_json_canvas(doc(nb, "BEE", wb)))
    for round in range(6):
        var id = 1 + round % 2
        var l = kept.take(kept.find(id, 1))
        is_document(look, l, v, name + ": kept parse " + String(id))
        if round == 3:
            l.select(l.objs[1].id, False)
            l.begin_gesture(CH_MOVE)
            l.move_by(3, 9)
            l.end_gesture()
            is_document(look, l, v, name + ": kept parse edited")
        kept.keep(id, 1, l^)


def versions() raises:
    """Two documents never hand a renderer the same layer version: not two layers under one look, not two looks (an app
    that makes a look per document), not two kept pictures."""
    var v = DeskView(0, 0, 1.0)
    var a = import_json_canvas(doc(5, "AAA"))
    var b = import_json_canvas(doc(5, "BEE"))
    var look = BoardLook()
    var sa = drawn(look, a, v)
    var sb = drawn(look, b, v)
    var sa2 = drawn(look, a, v)
    assert_true(not sa.same_layer(0, sb, 0), "one look, two documents: two pictures")
    assert_true(not sb.same_layer(0, sa2, 0), "and back")
    var la = BoardLook()
    var lb = BoardLook()
    var ta = drawn(la, a, v)
    var tb = drawn(lb, b, v)
    assert_true(not ta.same_layer(0, tb, 0), "a look each: two pictures")
    for _ in range(3):  # (looks that have painted the same number of times)
        ta = drawn(la, a, v)
        tb = drawn(lb, b, v)
        assert_true(not ta.same_layer(0, tb, 0), "a look each, later")
    var ka = KeptPaint()
    var kb = KeptPaint()
    var pa = Scene(100, 100, 1.0)
    if ka.begin(pa, "x", "t", 1.0):
        pa.rect(1, 1, 5, 5, rgba(255, 0, 0), 0)
        ka.end(pa)
    var pb = Scene(100, 100, 1.0)
    if kb.begin(pb, "x", "t", 1.0):
        pb.rect(1, 1, 5, 5, rgba(0, 0, 255), 0)
        kb.end(pb)
    assert_true(not pa.same_layer(0, pb, 0), "two KeptPaints: two pictures")
    assert_true(a.doc != b.doc, "each layer its own document")


def main() raises:
    for keep in [True, False]:
        for log in [True, False]:
            for patch in [True, False]:
                switches(5, 5, 200, log, patch, keep)
                switches(3, 6, 200, log, patch, keep)
                switches(6, 3, 230, log, patch, keep)
    versions()
    print("twodocs: ok")
