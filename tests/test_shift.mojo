# The page frame shifted (review 5, MUST 1): every kind of object, in every way it can be looked at, moves by the same distance:
# its box, its ink, its ends, what a press hits, the saved document, and what that opens as; with undo and redo around it, and
# growing and folding on all four sides. A kind added without a sample here fails the first assert.
#   pixi run mojo build -I . -I vendor tests/test_shift.mojo -o build/test_shift && build/test_shift
from std.testing import assert_true, assert_equal
from mojoui.ink import Stroke
from mojoui.objectlayer import ObjectLayer, import_json_canvas, export_json_canvas, KINDS, kind_name, TEXT, STICKY, RECT, ELLIPSE, PICTURE, INK, CONNECTOR
from mojoui.pagegrow import settle_pages

comptime W = 860.0
comptime H = 1080.0


def sample(mut l: ObjectLayer, kind: Int, x: Float64, y: Float64) raises -> Int:
    if kind == TEXT:
        return l.add_text(x, y, 160, 40, "some words")
    if kind == STICKY:
        return l.add_sticky(x, y, 120, "note")
    if kind == RECT:
        return l.add_rect(x, y, 140, 60, 0xFFCC8844, 0, 3, 8)
    if kind == ELLIPSE:
        return l.add_ellipse(x, y, 140, 60, 0xFF4488CC)
    if kind == PICTURE:
        return l.add_picture(x, y, 40, 40, List[UInt32](length=16, fill=0xFF00FF00), 4, 4)
    if kind == INK:
        var s = Stroke(6, 0xFF2040A0)
        for k in range(24):
            s.add(x + Float64(k) * 6, y + Float64((k * 7) % 23), 0.3 + Float64(k % 5) / 10)
        return l.add_ink(s)
    if kind == CONNECTOR:
        var a = l.add_rect(x, y, 30, 30, 0xFF112233)
        var b = l.add_rect(x + 220, y + 90, 30, 30, 0xFF112233)
        _ = l.add_connector_to_point(a, x + 100, y + 160)
        return l.add_connector(a, b)
    raise Error("no sample of kind " + String(kind))


def picture(l: ObjectLayer) -> ObjectLayer:
    """The objects as they are now, in a layer of their own."""
    var n = ObjectLayer()
    for i in range(len(l.objs)):
        n.objs.append(l.objs[i].copy())
        n.pos_of[l.objs[i].id] = i
    n._changed()
    return n^


def near(a: Float64, b: Float64, what: String) raises:
    assert_true(abs(a - b) < 1e-6, what + ": " + String(a) + " is not " + String(b))


def moved_by(mut was: ObjectLayer, mut now: ObjectLayer, dx: Float64, dy: Float64, what: String) raises:
    """`now` is `was`, everything moved by (dx, dy)."""
    assert_equal(len(was.objs), len(now.objs), what)
    for i in range(len(was.objs)):
        ref a = was.objs[i]
        assert_true(now.index(a.id) >= 0, what + ": object " + String(a.id) + " is there")
        ref b = now.objs[now.index(a.id)]
        var w = what + ", " + kind_name(a.kind)
        near(b.x, a.x + dx, w + " x")
        near(b.y, a.y + dy, w + " y")
        near(b.w, a.w, w + " w")
        near(b.h, a.h, w + " h")
        var p = a.bounds()
        var q = b.bounds()
        near(q[0], p[0] + dx, w + " bounds")
        near(q[1], p[1] + dy, w + " bounds")
        near(q[2], p[2] + dx, w + " bounds")
        near(q[3], p[3] + dy, w + " bounds")
        if a.kind == INK:
            assert_equal(len(a.stroke.xs), len(b.stroke.xs), w)
            for k in range(len(a.stroke.xs)):
                near(b.stroke.xs[k], a.stroke.xs[k] + dx, w + " point")
                near(b.stroke.ys[k], a.stroke.ys[k] + dy, w + " point")
            assert_equal(len(a.stroke.shape), len(b.stroke.shape), w + " outline")
            for k in range(0, len(a.stroke.shape), 2):
                near(b.stroke.shape[k], a.stroke.shape[k] + dx, w + " outline")
                near(b.stroke.shape[k + 1], a.stroke.shape[k + 1] + dy, w + " outline")
            near(b.stroke.x0, a.stroke.x0 + dx, w + " ink box")
            near(b.stroke.y1, a.stroke.y1 + dy, w + " ink box")
        if a.kind == CONNECTOR:
            near(b.ax, a.ax + dx, w + " end")
            near(b.ay, a.ay + dy, w + " end")
            near(b.bx, a.bx + dx, w + " end")
            near(b.by, a.by + dy, w + " end")
            if a.to_id < 0:
                near(b.fx, a.fx + dx, w + " free end")
                near(b.fy, a.fy + dy, w + " free end")
    var box = was.content_box()
    var hits = 0
    for gx in range(40):
        for gy in range(40):
            var px = box.left - 5 + (box.right - box.left + 10) * Float64(gx) / 39
            var py = box.top - 5 + (box.bottom - box.top + 10) * Float64(gy) / 39
            var h = was.hit_test(px, py, 2)
            assert_equal(now.hit_test(px + dx, py + dy, 2), h, what + ": a press at " + String(px) + ", " + String(py))
            if h >= 0:
                hits += 1
    assert_true(hits > 3, what + ": the presses meet something")


def saved(mut l: ObjectLayer, mut ref_: ObjectLayer, dx: Float64, dy: Float64, what: String) raises:
    """The document saved now opens as the document saved before, moved."""
    var was = import_json_canvas(export_json_canvas(ref_))
    var now = import_json_canvas(export_json_canvas(l))
    assert_true(len(was.objs) > 0, what)
    if len(was.objs) == len(now.objs):
        moved_by(was, now, dx, dy, what + ", saved and opened")
    else:
        assert_equal(len(was.objs), len(now.objs), what + ", saved and opened")


def each_kind() raises:
    assert_equal(kind_name(KINDS + 1), kind_name(99), "KINDS is the last kind")
    for kind in range(1, KINDS + 1):
        for turned in range(2):
            var l = ObjectLayer()
            var id = sample(l, kind, 120, 200)
            if turned == 1:
                if kind == CONNECTOR:
                    continue
                l.objs[l.index(id)].rot = 0.6
                l.objs[l.index(id)].rev += 1
                l._changed()
            var was = picture(l)
            var what = kind_name(kind) + (" turned" if turned == 1 else "")
            for d in [(W, 0.0), (0.0, H), (-W, 0.0), (0.0, -H), (2 * W, -3 * H)]:
                l.shift_frame(d[0], d[1])
                moved_by(was, l, d[0], d[1], what)
                if kind != PICTURE and kind != ELLIPSE:  # (pnote makes neither: a picture of pixels alone and an ellipse made here aren't in a canvas document)
                    saved(l, was, d[0], d[1], what)
                l.shift_frame(-d[0], -d[1])
                moved_by(was, l, 0, 0, what + " and back")
    print("   every kind, by frame, ink, ends, presses, the saved document and what it opens as")


def with_undo() raises:
    """Shifts between edits: undo and redo go through the same pictures, all in the new frame."""
    var l = ObjectLayer()
    var ids = List[Int]()
    for kind in range(1, KINDS + 1):
        ids.append(sample(l, kind, 100 + 60 * Float64(kind), 100 + 110 * Float64(kind)))
    var dx = 0.0
    var dy = 0.0
    var pictures = List[ObjectLayer]()  # what each undo depth looked like, in the frame it had
    var at = List[Tuple[Float64, Float64]]()
    for step in range(KINDS * 3):
        var was = picture(l)
        var steps = len(l.history.done)
        var id = ids[step % KINDS]
        l.begin_gesture()
        if step % 3 == 0:
            l.select(id)
            l.move_by(13, -7)
        elif step % 3 == 1:
            if step % 2 == 1:
                l.delete(id)
            else:
                l.move_object(id, 40 + Float64(step), 60)
        else:
            ids[step % KINDS] = sample(l, 1 + step % KINDS, 50 + Float64(step) * 9, 500)
        l.end_gesture()
        if len(l.history.done) > steps:
            pictures.append(was^)
            at.append((dx, dy))
        if step % 2 == 0:
            var sx = W if step % 4 == 0 else -W
            var sy: Float64 = H if step % 3 == 0 else 0.0
            l.shift_frame(sx, sy)
            dx += sx
            dy += sy
    var n = len(pictures)
    assert_true(n > KINDS * 2)
    var end = picture(l)
    for step in range(n - 1, -1, -1):
        assert_true(l.undo())
        moved_by(pictures[step], l, dx - at[step][0], dy - at[step][1], "undone to " + String(step))
        l.shift_frame(W, -H)
        dx += W
        dy -= H
    while l.redo():
        pass
    moved_by(end, l, Float64(n) * W, -Float64(n) * H, "redone")
    print("   undo and redo in the frame there is now")


def grows_and_folds() raises:
    for side in range(4):
        for kind in range(1, KINDS + 1):
            var l = ObjectLayer()
            var stay = sample(l, STICKY, 300, 300)
            var id = sample(l, kind, 300, 600)
            var before = picture(l)
            var d = [(-500.0, 0.0), (0.0, -800.0), (700.0, 0.0), (0.0, 700.0)][side]
            var goes = List[Int]()
            for ref o in before.objs:
                if o.id != stay:
                    goes.append(o.id)
            l.begin_gesture()
            l.select(goes[0])
            for k in range(1, len(goes)):
                l.select(goes[k], True)
            l.move_by(d[0], d[1])
            l.end_gesture()
            var after = picture(l)
            var g = settle_pages(1, 1, l.content_box(), W, H)
            assert_true(g.columns * g.rows == 2, "grew: " + String(side) + " " + kind_name(kind))
            assert_true((g.shift_x > 0) == (side == 0) and (g.shift_y > 0) == (side == 1), "which way")
            l.shift_frame(g.shift_x, g.shift_y)
            moved_by(after, l, g.shift_x, g.shift_y, "grown")
            assert_true(l.undo())
            moved_by(before, l, g.shift_x, g.shift_y, "undone")
            var f = settle_pages(g.columns, g.rows, l.content_box(), W, H)
            assert_true(f.columns == 1 and f.rows == 1, "folds back")
            l.shift_frame(f.shift_x, f.shift_y)
            moved_by(before, l, 0, 0, "folded back where it was")
            if kind != PICTURE and kind != ELLIPSE:
                saved(l, before, 0, 0, "folded back")
            assert_true(l.redo())
            moved_by(after, l, 0, 0, "and redone")
    print("   four sides: grown, undone, folded, redone")


def documents() raises:
    """A web document of every node kind, known here or not: read, shifted, saved, opened."""
    var t = String('{"nodes":[{"id":"g","type":"group","x":10,"y":10,"width":400,"height":300,"label":"G"},{"id":"i","type":"file","x":20,"y":20,"width":100,"height":80,"file":"media/a.png","pn":{"type":"image","geometry":{"x":20,"y":20,"width":100,"height":80,"rotation":0,"scaleX":1,"scaleY":1}}},{"id":"l","type":"link","x":30,"y":30,"width":100,"height":80,"url":"https://e.org"},{"id":"t","type":"text","x":40,"y":40,"width":100,"height":30,"text":"plain"},{"id":"u","type":"weird","x":50,"y":50,"width":10,"height":10},{"id":"p","type":"file","x":300,"y":300,"width":60,"height":40,"file":"","pn":{"type":"stroke","path":"M 300 300 Q 320 340 340 310 L 360 340","geometry":{"x":300,"y":300,"width":60,"height":40,"rotation":0,"scaleX":1,"scaleY":1},"stroke":"#202020","strokeWidth":4}}],"edges":[{"id":"e","fromNode":"t","toNode":"i"}],"pn":{"schemaVersion":1,"page":{"columns":1,"rows":1}}}')
    var was = import_json_canvas(t)
    var l = import_json_canvas(t)
    l.shift_frame(W, H)
    moved_by(was, l, W, H, "a web document")
    var back = import_json_canvas(export_json_canvas(l))
    moved_by(was, back, W, H, "a web document, saved and opened")
    back.shift_frame(-W, -H)
    moved_by(was, back, 0, 0, "and back")
    print("   web documents")


def main() raises:
    each_kind()
    with_undo()
    grows_and_folds()
    documents()
    print("shift: ok")
