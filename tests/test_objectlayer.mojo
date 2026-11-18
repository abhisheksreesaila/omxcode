# The object layer (goal 74 M4): free objects on an infinite canvas: every kind made, selected (click, shift, marquee,
# all), moved, nudged, resized by each of 8 handles with the opposite corner fixed, turned, z-ordered, locked, deleted,
# duplicated; connectors that follow their ends; every change one undo step (a drag too); 3,000 random operations undone
# to the start and redone to the end; Personal Note's 645-object benchmark note painted per pan and hit-tested in time.
#   pixi run mojo run -I . tests/test_objectlayer.mojo
from std.testing import assert_equal, assert_true, assert_false
from std.time import perf_counter_ns
from std.math import sqrt, cos, sin

from mojoui.objectlayer import (ObjectLayer, Obj, import_fabric, TEXT, STICKY, RECT, ELLIPSE, PICTURE, INK, CONNECTOR,
                                H_NW, H_N, H_NE, H_E, H_SE, H_S, H_SW, H_W, H_ROTATE, MIN_SIZE, PI)
from mojoui.ink import Stroke
from mojoui.text import Font
from mojoui.scene import Scene


def near(a: Float64, b: Float64, tol: Float64 = 1e-6) -> Bool:
    return abs(a - b) <= tol


def p95(var xs: List[Float64]) -> Float64:
    sort(xs)
    return xs[min(Int(Float64(len(xs)) * 0.95), len(xs) - 1)]


struct Rng(Movable):
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> UInt64:
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return self.s

    def int(mut self, n: Int) -> Int:
        return Int(self.next() % UInt64(max(n, 1)))

    def real(mut self, a: Float64, b: Float64) -> Float64:
        return a + (b - a) * Float64(self.next() % 1000000) / 1000000.0


def a_stroke(x: Float64, y: Float64, n: Int, width: Float64 = 3) -> Stroke:
    var s = Stroke(width, 0xFF332222)
    for i in range(n):
        s.add(x + Float64(i) * 4, y + sin(Float64(i) * 0.4) * 10, 0.5 + 0.4 * sin(Float64(i)))
    s.seal()
    return s^


def drawn(s: Scene, what: String) -> Bool:
    for n in s.notes:
        if n == what:
            return True
    return False


def drawn_objects(s: Scene) -> Int:
    var n = 0
    for t in s.notes:
        if t.startswith("object "):
            n += 1
    return n


def check_handle(h: Int, rot: Float64) raises:
    """Handle h of a 200×100 box (turned by rot) dragged 30 along its x and 20 along its y: the opposite handle's page
    point doesn't move, and the size grows by exactly what the handle's side allows."""
    var ol = ObjectLayer()
    var id = ol.add_rect(100, 100, 200, 100, 0xFF0000FF)
    ol.set_rotation(id, rot)
    ol.select(id)
    var p = ol.index(id)
    var opp = (h + 4) % 8
    var before = ol.handle_point(p, opp)
    var hp = ol.handle_point(p, h)
    assert_equal(ol.handle_at(hp[0], hp[1]), h)
    var c = cos(rot)
    var s = sin(rot)
    ol.resize_handle(h, hp[0] + 30 * c - 20 * s, hp[1] + 30 * s + 20 * c)
    var after = ol.handle_point(ol.index(id), opp)
    assert_true(near(before[0], after[0], 1e-6) and near(before[1], after[1], 1e-6), "handle " + String(h) + ": the opposite point moved")
    var sx = [-1, 0, 1, 1, 1, 0, -1, -1][h]
    var sy = [-1, -1, -1, 0, 1, 1, 1, 0][h]
    var o = ol.get(id)
    assert_true(near(o.w, 200 + 30 * Float64(sx), 1e-6), "handle " + String(h) + " width " + String(o.w))
    assert_true(near(o.h, 100 + 20 * Float64(sy), 1e-6), "handle " + String(h) + " height " + String(o.h))
    # dragged far past the anchor: never smaller than MIN_SIZE (and the anchor still stays)
    ol.resize_handle(h, before[0] - 1000 * Float64(sx) * c + 1000 * Float64(sy) * s, before[1] - 1000 * Float64(sx) * s - 1000 * Float64(sy) * c)
    o = ol.get(id)
    if sx != 0:
        assert_true(near(o.w, MIN_SIZE), "min width")
    if sy != 0:
        assert_true(near(o.h, MIN_SIZE), "min height")
    var again = ol.handle_point(ol.index(id), opp)
    assert_true(near(before[0], again[0], 1e-6) and near(before[1], again[1], 1e-6), "anchor at min size")


def test_edit(font: Font) raises:
    var ol = ObjectLayer()
    var t = ol.add_text(40, 40, 200, 60, "Ship the export", 18)
    var st = ol.add_sticky(300, 40, 160, "Idea")
    var r = ol.add_rect(40, 300, 200, 120, 0x2610C8F0, 0xFF4A6FB0, 2, 6)
    var e = ol.add_ellipse(300, 300, 160, 100, 0xFF55AA55)
    var px = List[UInt32]()
    for i in range(16):
        px.append(UInt32(0xFF000000 + i * 4000))
    var pic = ol.add_picture(520, 40, 120, 120, px, 4, 4)
    var ink = ol.add_ink(a_stroke(520, 320, 30))
    var c = ol.add_connector(r, e)
    for k in [TEXT, STICKY, RECT, ELLIPSE, PICTURE, INK, CONNECTOR]:
        assert_equal(ol.count_kind(k), 1)
    # everything paints, each noted by kind and id
    var sc = Scene(1440, 900, 1)
    ol.paint(sc, font, 0, 0, 1440, 900, 1)
    for pair in [(t, "text"), (st, "sticky"), (r, "rect"), (e, "ellipse"), (pic, "picture"), (ink, "ink"), (c, "connector")]:
        assert_true(drawn(sc, "object " + pair[1] + " " + String(pair[0])), "painted " + pair[1])
    # culled: a view far away draws nothing
    var far = Scene(1440, 900, 1)
    ol.paint(far, font, 10000, 10000, 1440, 900, 1)
    assert_equal(drawn_objects(far), 0)
    # hit tests: each kind under its own middle
    assert_equal(ol.hit_test(140, 360), r)
    assert_equal(ol.hit_test(380, 350), e)
    assert_equal(ol.hit_test(305, 305), -1)  # (the ellipse's box corner is outside the ellipse)
    assert_equal(ol.hit_test(580, 100), pic)
    assert_equal(ol.hit_test(100, 60), t)
    assert_equal(ol.hit_test(380, 120), st)
    var io = ol.get(ink)
    assert_equal(ol.hit_test(io.stroke.xs[5], io.stroke.ys[5]), ink)
    var co = ol.get(c)
    assert_equal(ol.hit_test((co.ax + co.bx) / 2, (co.ay + co.by) / 2), c)
    # select, shift-select toggles, marquee (wholly inside only), select all, clear
    _ = ol.click(140, 360)
    assert_true(len(ol.selected) == 1 and ol.selected[0] == r)
    _ = ol.click(380, 350, True)
    assert_equal(len(ol.selected), 2)
    _ = ol.click(380, 350, True)
    assert_true(len(ol.selected) == 1 and ol.selected[0] == r)
    _ = ol.click(1000, 800)
    assert_equal(len(ol.selected), 0)
    ol.marquee(30, 290, 470, 430)  # (the rect and the ellipse wholly; their connector too)
    assert_equal(len(ol.selected), 3)
    assert_true(ol.is_selected(r) and ol.is_selected(e) and ol.is_selected(c))
    ol.marquee(30, 290, 400, 430)  # (cuts the ellipse: the rect and the connector, not the ellipse)
    assert_true(len(ol.selected) == 2 and ol.is_selected(r) and ol.is_selected(c) and not ol.is_selected(e))
    ol.select_all()
    assert_equal(len(ol.selected), 7)
    ol.clear_selection()
    assert_equal(len(ol.selected), 0)
    # move, nudge (1 pt; shift 10)
    ol.select(r)
    ol.move_by(10, 5)
    assert_true(near(ol.get(r).x, 50) and near(ol.get(r).y, 305))
    ol.nudge(1, 0)
    ol.nudge(0, -1, True)
    assert_true(near(ol.get(r).x, 51) and near(ol.get(r).y, 295))
    # 8 handles, upright and turned: the opposite corner fixed; min size
    for h in range(8):
        check_handle(h, 0)
        check_handle(h, 0.6)
    # rotate: the handle dragged to the right of the centre turns the top to face it (a quarter turn)
    var bar = ol.add_rect(800, 400, 200, 20, 0xFF000000)
    ol.select(bar)
    var bo = ol.get(bar)
    var rp = ol.handle_point(ol.index(bar), H_ROTATE)
    assert_equal(ol.handle_at(rp[0], rp[1]), H_ROTATE)
    ol.rotate_towards(bo.cx() + 100, bo.cy())
    assert_true(near(ol.get(bar).rot, PI / 2, 1e-6), "rot " + String(ol.get(bar).rot))
    assert_equal(ol.hit_test(bo.cx(), bo.cy() + 80), bar)  # (turned: now tall)
    assert_equal(ol.hit_test(bo.cx() + 80, bo.cy()), -1)
    # z order: three overlapping squares
    var z = ObjectLayer()
    var a = z.add_rect(0, 0, 100, 100, 0xFF0000FF)
    var b = z.add_rect(50, 50, 100, 100, 0xFF00FF00)
    var d = z.add_rect(25, 25, 100, 100, 0xFFFF0000)
    assert_equal(z.hit_test(75, 75), d)
    z.select(d)
    z.send_to_back()
    assert_equal(z.hit_test(75, 75), b)
    assert_equal(z.z_rank(d), 0)
    z.bring_to_front()
    assert_equal(z.hit_test(75, 75), d)
    z.send_backward()
    assert_equal(z.hit_test(75, 75), b)
    assert_equal(z.z_rank(d), 1)
    z.bring_forward()
    assert_equal(z.z_rank(d), 2)
    z.select(a)
    z.bring_forward()
    assert_equal(z.z_rank(a), 1)
    # lock: no click, marquee or select-all picks it; it still paints; unlock brings it back
    z.select(d)
    z.lock_selection()
    assert_equal(len(z.selected), 0)
    assert_true(z.get(d).locked)
    assert_equal(z.hit_test(110, 110), b)  # (d is on top there, but locked)
    _ = z.click(110, 30)
    assert_false(z.is_selected(d))
    z.marquee(-10, -10, 200, 200)
    assert_false(z.is_selected(d))
    assert_equal(len(z.selected), 2)
    z.select_all()
    assert_false(z.is_selected(d))
    z.select(d)
    assert_false(z.is_selected(d))
    var zs = Scene(800, 600, 1)
    z.paint(zs, font, 0, 0, 800, 600, 1)
    assert_true(drawn(zs, "object rect " + String(d)))
    assert_equal(z.hit_locked(110, 110), d)
    z.set_locked(d, False)
    assert_equal(z.hit_test(110, 110), d)
    # delete, duplicate
    z.select(a)
    z.delete_selection()
    assert_false(z.has(a))
    assert_equal(z.count(), 2)
    z.select(b)
    z.duplicate_selection()
    assert_equal(z.count(), 3)
    var dup = z.selected[0]
    assert_true(dup != b and near(z.get(dup).x, 66) and near(z.get(dup).y, 66))
    # text: keys go to the box being edited; the box takes the text on end
    assert_true(ol.begin_text_edit(t))
    for ch in [" now", "!"]:
        for cp in ch.codepoint_slices():
            _ = ol.text_key(String(cp), 0, 0, font)
    assert_equal(ol.editor_text(), "Ship the export now!")
    ol.end_text_edit()
    assert_equal(ol.get(t).text, "Ship the export now!")
    var ts = Scene(1440, 900, 1)
    ol.paint(ts, font, 0, 0, 1440, 900, 1)
    var found = False
    for k in range(len(ts.texts)):
        if ts.texts[k] == "Ship the export now!":
            found = True
    assert_true(found, "the edited text paints")
    # selection layer: outline and 9 handles for one selected box
    ol.select(r)
    var hs = Scene(1440, 900, 1)
    ol.paint(hs, font, 0, 0, 1440, 900, 1)
    assert_true(drawn(hs, "selected " + String(r)))
    for h in range(9):
        assert_true(drawn(hs, "handle " + String(h)))
    print("objectlayer edit: ok")


def test_connectors() raises:
    var ol = ObjectLayer()
    var a = ol.add_rect(0, 0, 100, 100, 0xFF0000FF)
    var b = ol.add_rect(300, 0, 100, 100, 0xFF00FF00)
    var c = ol.add_connector(a, b)
    var o = ol.get(c)
    assert_true(near(o.ax, 100) and near(o.ay, 50) and near(o.bx, 300) and near(o.by, 50), "right side to left side")
    # the far end moves below: bottom middle to top middle
    ol.select(b)
    ol.move_by(0, 400)
    o = ol.get(c)
    assert_true(near(o.ax, 50) and near(o.ay, 100) and near(o.bx, 350) and near(o.by, 400), "re-routed after a move")
    # the near end resizes (its bottom edge goes down): the connector's start follows
    ol.select(a)
    var hp = ol.handle_point(ol.index(a), H_S)
    ol.resize_handle(H_S, hp[0], hp[1] + 50)
    o = ol.get(c)
    assert_true(near(o.ax, 50) and near(o.ay, 150), "follows a resize")
    # a drag of the near end, in a gesture: follows every step
    ol.begin_gesture()
    for _ in range(10):
        ol.move_by(5, 0)
    ol.end_gesture()
    o = ol.get(c)
    assert_true(near(o.ax, 100) and near(o.ay, 150), "follows a drag")
    # turning an end re-routes too
    ol.set_rotation(b, PI / 2)
    var bo = ol.get(b)
    var top = bo.to_page(0, -bo.h / 2)
    o = ol.get(c)
    var ends_ok = False
    for side in range(4):
        var m = bo.to_page([0.0, bo.w / 2, 0.0, -bo.w / 2][side], [-bo.h / 2, 0.0, bo.h / 2, 0.0][side])
        if near(o.bx, m[0]) and near(o.by, m[1]):
            ends_ok = True
    assert_true(ends_ok, "a turned end: attached to one of its turned side midpoints")
    _ = top
    # a free end point
    var f = ol.add_connector_to_point(a, 600, 600)
    o = ol.get(f)
    assert_true(near(o.bx, 600) and near(o.by, 600))
    # duplicating both ends duplicates the connector between them (attached to the copies)
    ol.select(a)
    ol.select(b, True)
    ol.duplicate_selection()
    assert_equal(ol.count_kind(CONNECTOR), 4)  # (c and its copy; f and its copy, whose free end moves along)
    var a2 = -1
    var b2 = -1
    for id in ol.selected:
        var q = ol.get(id)
        if q.kind == RECT and near(q.w, ol.get(a).w) and near(q.h, ol.get(a).h) and id != a:
            a2 = id
        elif q.kind == RECT and id != b:
            b2 = id
    assert_true(a2 > 0 and b2 > 0)
    var linked = False
    for ref q in ol.objs:
        if q.kind == CONNECTOR and q.from_id == a2 and q.to_id == b2:
            linked = True
    assert_true(linked, "the copied connector joins the copies")
    # duplicating one end alone copies no connector
    var before = ol.count_kind(CONNECTOR)
    ol.select(b)
    ol.duplicate_selection()
    assert_equal(ol.count_kind(CONNECTOR), before)
    # deleting an end deletes its connectors
    ol.select(a)
    ol.delete_selection()
    assert_false(ol.has(c))
    assert_false(ol.has(f))
    assert_equal(len(ol.connectors_of(a)), 0)
    ol.delete(b2)
    for ref q in ol.objs:
        assert_true(q.kind != CONNECTOR or (ol.has(q.from_id) and (q.to_id < 0 or ol.has(q.to_id))), "no dangling connector")
    # undo brings the connectors back, attached as before
    _ = ol.undo()
    _ = ol.undo()
    assert_true(ol.has(c) and ol.has(f))
    print("objectlayer connectors: ok")


def roundtrip(mut ol: ObjectLayer, d0: String, what: String) raises:
    """The last operation undoes to d0 and redoes to what it made."""
    var d1 = ol.dump()
    assert_true(d1 != d0, what + ": changed nothing")
    assert_true(ol.undo(), what + ": no undo step")
    assert_true(ol.dump() == d0, what + ": undo isn't exact")
    assert_true(ol.redo(), what + ": no redo step")
    assert_true(ol.dump() == d1, what + ": redo isn't exact")


def test_undo(font: Font) raises:
    var ol = ObjectLayer()
    var d = ol.dump()
    var r = ol.add_rect(0, 0, 100, 100, 0xFF0000FF)
    roundtrip(ol, d, "add rect")
    d = ol.dump()
    var e = ol.add_ellipse(300, 0, 100, 60, 0xFF00FF00)
    roundtrip(ol, d, "add ellipse")
    d = ol.dump()
    var t = ol.add_text(0, 300, 200, 50, "hello")
    roundtrip(ol, d, "add text")
    d = ol.dump()
    var s = ol.add_sticky(300, 300, 120, "note")
    roundtrip(ol, d, "add sticky")
    d = ol.dump()
    var px: List[UInt32] = [0xFF000000, 0xFFFFFFFF, 0xFFFFFFFF, 0xFF000000]
    _ = ol.add_picture(600, 0, 80, 80, px, 2, 2)
    roundtrip(ol, d, "add picture")
    d = ol.dump()
    var ink = ol.add_ink(a_stroke(600, 300, 20))
    roundtrip(ol, d, "add ink")
    d = ol.dump()
    var c = ol.add_connector(r, e)
    roundtrip(ol, d, "add connector")
    ol.select(r)
    d = ol.dump()
    ol.move_by(7, 3)
    roundtrip(ol, d, "move (with its connector)")
    d = ol.dump()
    ol.nudge(-1, 0, True)
    roundtrip(ol, d, "nudge")
    for h in range(8):
        d = ol.dump()
        var hp = ol.handle_point(ol.index(r), h)
        ol.resize_handle(h, hp[0] + 9, hp[1] + 4)
        roundtrip(ol, d, "resize " + String(h))
    d = ol.dump()
    ol.rotate_towards(500, 500)
    roundtrip(ol, d, "rotate")
    d = ol.dump()
    ol.bring_to_front()
    roundtrip(ol, d, "front")
    d = ol.dump()
    ol.send_to_back()
    roundtrip(ol, d, "back")
    d = ol.dump()
    ol.bring_forward()
    roundtrip(ol, d, "forward")
    d = ol.dump()
    ol.send_backward()
    roundtrip(ol, d, "backward")
    d = ol.dump()
    ol.select(ink)
    ol.lock_selection()
    roundtrip(ol, d, "lock")
    d = ol.dump()
    ol.unlock_all()
    roundtrip(ol, d, "unlock")
    d = ol.dump()
    ol.set_color(s, 0xFF123456)
    roundtrip(ol, d, "colour")
    d = ol.dump()
    ol.select(ink)
    var hp = ol.handle_point(ol.index(ink), H_SE)
    ol.resize_handle(H_SE, hp[0] + 40, hp[1] + 20)
    roundtrip(ol, d, "ink resize")
    d = ol.dump()
    ol.select(r)
    ol.select(e, True)
    ol.duplicate_selection()
    roundtrip(ol, d, "duplicate (with the connector)")
    d = ol.dump()
    ol.select(e)
    ol.delete_selection()
    roundtrip(ol, d, "delete (with the connector)")
    d = ol.dump()
    _ = ol.begin_text_edit(t)
    for cp in String(" world").codepoint_slices():
        _ = ol.text_key(String(cp), 0, 0, font)
    _ = ol.text_key("Backspace", 0, 0, font)
    ol.end_text_edit()
    assert_equal(ol.get(t).text, "hello worl")
    roundtrip(ol, d, "text edit (one step)")
    # a 30-step drag is one undo step
    ol.select(r)
    var steps = len(ol.history.done)
    d = ol.dump()
    ol.begin_gesture()
    for _ in range(30):
        ol.move_by(1, 2)
    ol.end_gesture()
    assert_equal(len(ol.history.done), steps + 1)
    roundtrip(ol, d, "30-step drag")
    # a resize drag (each step from where it began) is one step
    steps = len(ol.history.done)
    d = ol.dump()
    ol.begin_gesture()
    var h0 = ol.handle_point(ol.index(r), H_NE)
    for k in range(12):
        ol.resize_handle(H_NE, h0[0] + Float64(k) * 3, h0[1] - Float64(k) * 2)
    ol.end_gesture()
    assert_equal(len(ol.history.done), steps + 1)
    roundtrip(ol, d, "resize drag")
    # an empty gesture leaves no step
    steps = len(ol.history.done)
    ol.begin_gesture()
    ol.end_gesture()
    assert_equal(len(ol.history.done), steps)
    _ = c
    print("objectlayer undo: ok")


def test_random(font: Font) raises:
    var ol = ObjectLayer()
    var rng = Rng(74_2026_11_17)
    for i in range(12):
        _ = ol.add_rect(rng.real(0, 1500), rng.real(0, 1000), rng.real(20, 200), rng.real(20, 200), 0xFF000000 + UInt32(i))
    ol.history.clear()
    var start = ol.dump()
    var ops = 0
    while ops < 3000:
        var pick = rng.int(24)
        var n = ol.count()
        var some = ol.objs[rng.int(n)].id if n > 0 else -1
        if pick == 0:
            _ = ol.add_rect(rng.real(0, 1500), rng.real(0, 1000), rng.real(10, 200), rng.real(10, 200), 0xFF00AA00)
        elif pick == 1:
            _ = ol.add_ellipse(rng.real(0, 1500), rng.real(0, 1000), rng.real(10, 200), rng.real(10, 200), 0xFF00AAAA)
        elif pick == 2:
            _ = ol.add_sticky(rng.real(0, 1500), rng.real(0, 1000), 120, "s" + String(ops))
        elif pick == 3:
            _ = ol.add_text(rng.real(0, 1500), rng.real(0, 1000), 160, 40, "t" + String(ops))
        elif pick == 4:
            _ = ol.add_ink(a_stroke(rng.real(0, 1500), rng.real(0, 1000), 3 + rng.int(12)))
        elif pick == 5 and n >= 2:
            _ = ol.add_connector(some, ol.objs[rng.int(n)].id)
        elif pick == 6:
            _ = ol.click(rng.real(0, 1600), rng.real(0, 1100), rng.int(3) == 0)
        elif pick == 7:
            ol.select(some, rng.int(2) == 0)
        elif pick == 8:
            var x = rng.real(-100, 1500)
            var y = rng.real(-100, 1000)
            ol.marquee(x, y, x + rng.real(50, 900), y + rng.real(50, 700))
        elif pick == 9:
            if rng.int(4) == 0:
                ol.select_all()
            else:
                ol.clear_selection()
        elif pick == 10:
            ol.move_by(rng.real(-50, 50), rng.real(-50, 50))
        elif pick == 11:
            ol.begin_gesture()
            for _ in range(1 + rng.int(8)):
                ol.move_by(rng.real(-9, 9), rng.real(-9, 9))
            ol.end_gesture()
        elif pick == 12:
            ol.nudge(rng.int(3) - 1, rng.int(3) - 1, rng.int(2) == 0)
        elif pick == 13:
            ol.select(some)
            var h = rng.int(8)
            var p = ol.index(some)
            if ol.is_selected(some) and ol.get(some).kind != CONNECTOR:
                var hp = ol.handle_point(p, h)
                if rng.int(2) == 0:
                    ol.begin_gesture()
                    for _ in range(1 + rng.int(5)):
                        ol.resize_handle(h, hp[0] + rng.real(-60, 60), hp[1] + rng.real(-60, 60))
                    ol.end_gesture()
                else:
                    ol.resize_handle(h, hp[0] + rng.real(-60, 60), hp[1] + rng.real(-60, 60))
        elif pick == 14:
            ol.select(some)
            ol.rotate_towards(rng.real(0, 1500), rng.real(0, 1000))
        elif pick == 15:
            ol.bring_to_front()
        elif pick == 16:
            ol.send_to_back()
        elif pick == 17:
            if rng.int(2) == 0:
                ol.bring_forward()
            else:
                ol.send_backward()
        elif pick == 18:
            if rng.int(3) == 0:
                ol.lock_selection()
            else:
                ol.unlock_all()
        elif pick == 19:
            ol.delete_selection()
        elif pick == 20:
            ol.duplicate_selection(rng.real(5, 30))
        elif pick == 21:
            if ol.begin_text_edit(some):
                for cp in String("ab").codepoint_slices():
                    _ = ol.text_key(String(cp), 0, 0, font)
                if rng.int(2) == 0:
                    _ = ol.text_key("Backspace", 0, 0, font)
                ol.end_text_edit()
        elif pick == 22:
            ol.set_color(some, UInt32(0xFF000000) + UInt32(rng.int(0xFFFFFF)))
        else:
            if ol.can_undo() and rng.int(2) == 0:
                _ = ol.undo()
            elif ol.can_redo():
                _ = ol.redo()
        ops += 1
        if ops % 500 == 0:  # (the grid stays right: every object found where it is)
            for ref o in ol.objs:
                if not o.locked and o.kind == RECT:
                    var hid = ol.hit_test(o.cx(), o.cy())
                    assert_true(hid >= 0)
    var end = ol.dump()
    var steps = 0
    while ol.undo():
        steps += 1
    assert_true(ol.dump() == start, "undo everything: not the start")
    while ol.redo():
        pass
    assert_true(ol.dump() == end, "redo everything: not the end")
    print("random:", ops, "operations,", steps, "undo steps,", ol.count(), "objects at the end")
    print("objectlayer random: ok")


def seeded_note() -> ObjectLayer:
    """When build/g74/bench-note.json isn't there: Personal Note's benchmark mix, seeded (12 pages of 860×1080 in 3
    columns × 4 rows: 300 texts, 240 ink strokes of ~121 points, 60 rects, 45 connectors)."""
    var ol = ObjectLayer()
    var rng = Rng(600)
    var rects = List[Int]()
    var font = Font()
    for i in range(300):
        var pg = i % 12
        var x = Float64(pg % 3) * 860 + rng.real(40, 600)
        var y = Float64(pg // 3) * 1080 + rng.real(40, 900)
        var text = ["Meeting notes: ship the export", "Idea: spatial search\nacross pages", "TODO\n- draw\n- link\n- review"][i % 3]
        var o = Obj(0, TEXT, x, y, 320, 100, 0xFF222222)
        o.text = text
        o.size = 20 + Float64(i % 3) * 4
        _ = ol.adopt(o^)
    for i in range(240):
        var pg = i % 12
        var s = Stroke(2.5, 0xFF332222)
        var x = Float64(pg % 3) * 860 + rng.real(40, 600)
        var y = Float64(pg // 3) * 1080 + rng.real(40, 900)
        for k in range(121):
            s.add(x + Float64(k) * 2, y + sin(Float64(k) * 0.2) * 12, 1.0)
        s.seal()
        var o = Obj(0, INK, s.x0, s.y0, s.x1 - s.x0, s.y1 - s.y0, s.color)
        o.stroke = s^
        _ = ol.adopt(o^)
    for i in range(60):
        var pg = i % 12
        var o = Obj(0, RECT, Float64(pg % 3) * 860 + rng.real(40, 500), Float64(pg // 3) * 1080 + rng.real(40, 900), 270, 130, 0x26C87850)
        o.line = 0xFFB06F4A
        rects.append(ol.adopt(o^))
    for i in range(45):
        var o = Obj(0, CONNECTOR, 0, 0, 0, 0, 0xFF332222)
        o.from_id = rects[i]
        o.to_id = rects[(i + 1) % 60]
        o.line_width = 2.6
        _ = ol.adopt(o^)
    _ = font
    return ol^


def test_600(font: Font) raises:
    var ol: ObjectLayer
    var source: String
    var t0 = perf_counter_ns()
    var text = String()
    var have_file = True
    try:  # (only a missing file falls back: review round 1 found the counts inside this try, so a bad import hid)
        var f = open("build/g74/bench-note.json", "r")
        text = f.read()
        f.close()
    except:
        have_file = False
    if have_file:
        ol = import_fabric(text, font)
        source = "build/g74/bench-note.json"
        assert_equal(ol.count_kind(TEXT), 300)
        assert_equal(ol.count_kind(INK), 240)
        assert_equal(ol.count_kind(RECT), 60)
        assert_equal(ol.count_kind(CONNECTOR), 45)
    else:
        ol = seeded_note()
        source = "a seeded 645-object note (no build/g74/bench-note.json)"
    var load_ms = Float64(perf_counter_ns() - t0) / 1e6
    assert_equal(ol.count(), 645)
    var pts = 0
    for ref o in ol.objs:
        if o.kind == INK:
            pts += o.stroke.points()
    # the page area the note covers
    var x0 = 1e300
    var y0 = 1e300
    var x1 = -1e300
    var y1 = -1e300
    for ref o in ol.objs:
        var b = o.bounds()
        x0 = min(x0, b[0])
        y0 = min(y0, b[1])
        x1 = max(x1, b[2])
        y1 = max(y1, b[3])
    # 100 pans: a zigzag down the pages, a 1440×900-point view painted into a Scene each step
    var vw = 1440.0
    var vh = 900.0
    var sc = Scene(1440, 900, 1)
    var times = List[Float64]()
    var most = 0
    var total = 0
    for i in range(100):
        var row = i // 10
        var col = i % 10
        var fx = Float64(col if row % 2 == 0 else 9 - col) / 9.0
        var vx = x0 + (x1 - x0 - vw) * fx
        var vy = y0 + (y1 - y0 - vh) * Float64(i) / 99.0
        var t = perf_counter_ns()
        sc.reset(1440, 900, 1)
        ol.paint(sc, font, vx, vy, vw, vh, 1)
        times.append(Float64(perf_counter_ns() - t) / 1e6)
        var n = drawn_objects(sc)
        most = max(most, n)
        total += n
        assert_true(n > 0 and n < ol.count(), "culled: drew " + String(n))
    var pan_p95 = p95(times.copy())
    var pan_max = 0.0
    for t in times:
        pan_max = max(pan_max, t)
    # 1,000 hit tests at random points over the note
    var rng = Rng(1000)
    var hits = List[Float64]()
    var found = 0
    for _ in range(1000):
        var px = rng.real(x0, x1)
        var py = rng.real(y0, y1)
        var t = perf_counter_ns()
        var id = ol.hit_test(px, py)
        hits.append(Float64(perf_counter_ns() - t) / 1e6)
        if id >= 0:
            found += 1
    var hit_p95 = p95(hits.copy())
    print("600: source", source, "| objects", ol.count(), "| ink points", pts, "| load", load_ms, "ms")
    print("600: pan paint p95", pan_p95, "ms (max", pan_max, "ms; up to", most, "objects drawn, avg", total // 100, ")")
    print("600: hit test p95", hit_p95, "ms (", found, "of 1000 points on an object )")
    assert_true(pan_p95 <= 4.0, "pan paint p95 over 4 ms")
    assert_true(hit_p95 <= 0.1, "hit test p95 over 0.1 ms")
    print("objectlayer 600: ok")


def main() raises:
    var font = Font()
    test_edit(font)
    test_connectors()
    test_undo(font)
    test_random(font)
    test_600(font)
    test_save(font)


def test_save(font: Font) raises:
    """Added by the parent (D-7423): save_text → load_text keeps every object, its kind, box, text, ink and connector
    ends; saving the loaded layer again gives the same text (ids are reissued, so the first save is compared by counts)."""
    var ol = ObjectLayer()
    var a = ol.add_text(10, 20, 200, 60, "Ship\nthe \\ export\tnow", 18)
    var b = ol.add_sticky(400, 50, 160, "Idea")
    _ = ol.add_ellipse(50, 300, 120, 80, 0xFF88CC88)
    var st = Stroke(3, 0xFF222222)
    for k in range(20):
        st.add(100 + Float64(k) * 5, 400 + Float64(k % 3), 0.5)
    st.seal()
    _ = ol.add_ink(st)
    _ = ol.add_connector(a, b)
    var s1 = ol.save_text()
    var l2 = ObjectLayer()
    l2.load_text(s1)
    assert_equal(l2.count(), ol.count())
    for k in [TEXT, STICKY, ELLIPSE, INK, CONNECTOR]:
        assert_equal(l2.count_kind(k), ol.count_kind(k))
    var s2 = l2.save_text()
    var l3 = ObjectLayer()
    l3.load_text(s2)
    assert_equal(l3.save_text(), s2)
    assert_true(s2.find("Ship\\nthe \\\\ export\\tnow") >= 0)
    var kept = False
    for i in range(l2.count()):
        if l2.objs[i].kind == TEXT:
            kept = l2.objs[i].text == "Ship\nthe \\ export\tnow"
    assert_true(kept)
    var bad = ObjectLayer()
    var refused = False
    try:
        bad.load_text("objectlayer 1\n1\t2\t3\n")
    except:
        refused = True
    assert_true(refused)
    var found = False
    for i in range(l2.count()):
        if l2.objs[i].kind == CONNECTOR:
            found = l2.has(l2.objs[i].from_id) and l2.has(l2.objs[i].to_id)
    assert_true(found)
    print("objectlayer save: ok")
