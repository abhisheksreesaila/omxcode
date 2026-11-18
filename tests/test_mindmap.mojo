# The native mind map (goal 74 M5): a 500-topic random map laid out with no two shown boxes overlapping, every topic on
# its first-level ancestor's side, collapse hiding and expand restoring the same places, a Scene paint with one note per
# topic and one polygon per branch; the keys (Tab, Enter, typing, F2, Escape, Delete, arrows, Space); undo and redo of
# every step, and the outline text round trip. Goal 75 M4: motion (topics glide on springs to their places, grow out of
# their parent, shrink into it when removed or folded; frames are asked for only while something moves; less motion
# jumps), per-frame paint+step time on a 300-topic map, and that map drawn to build/g75/map-ours.png.
#   pixi run mojo run -I . tests/test_mindmap.mojo
from std.testing import assert_equal, assert_true, assert_false
from std.time import perf_counter_ns
from std.os import makedirs

from mojoui.mindmap import MindMap, MapView, RIGHT_SIDE, LEFT_SIDE, DONE_OPEN, DONE_YES
from mojoui.text import Font
from mojoui.scene import Scene, SurfacePainter, OP_POLY
from mojoui.canvas import Surface, rgba
from mojoui.png import encode_png
from mojoui.textedit import SHIFT, CTRL


struct Rng(Movable):
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> Int:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return Int((self.s >> 33) & 0x7FFFFFFF)

    def below(mut self, n: Int) -> Int:
        return self.next() % n


def typed(mut m: MindMap, text: String, font: Font, mut t: Int):
    for ch in text.codepoint_slices():
        _ = m.key(String(ch), 0, t, font)
        t += 40


def press(mut m: MindMap, name: String, font: Font, mut t: Int, mods: Int = 0):
    _ = m.key(name, mods, t, font)
    t += 40


def overlaps(m: MindMap, a: Int, b: Int) -> Bool:
    ref p = m.boxes[a]
    ref q = m.boxes[b]
    return p.x < q.x + q.w and q.x < p.x + p.w and p.y < q.y + q.h and q.y < p.y + p.h


def check_layout(mut m: MindMap) raises:
    """No two shown boxes overlap; every shown topic is beyond the root on its first-level ancestor's side."""
    var shown = List[Int]()
    for id in range(len(m.model.nodes)):
        assert_equal(m.boxes[id].visible, m.is_visible(id))
        if m.boxes[id].visible:
            shown.append(id)
    for i in range(len(shown)):
        for j in range(i + 1, len(shown)):
            if overlaps(m, shown[i], shown[j]):
                raise Error("boxes overlap: " + String(shown[i]) + " and " + String(shown[j]))
    ref root = m.boxes[0]
    for id in shown:
        if id == 0:
            continue
        var f = m.model.first_level(id)
        var s = m.model.nodes[f].side
        assert_equal(m.side(id), s)
        if s == RIGHT_SIDE:
            assert_true(m.boxes[id].x >= root.x + root.w)
        else:
            assert_true(m.boxes[id].x + m.boxes[id].w <= root.x)


def count_notes(sc: Scene, prefix: String, need_poly: Bool) raises -> Int:
    var n = 0
    for k in range(len(sc.notes)):
        if sc.notes[k].startswith(prefix):
            n += 1
            if need_poly:
                assert_equal(Int(sc.kinds[sc.note_ops[k]]), OP_POLY)
    return n


def sample_map(n: Int) -> MindMap:
    """The judged map (as examples/pnote's scene_map): n topics, eight main branches, seeded words; balanced."""
    var words: List[String] = ["Plan", "Ideas", "Budget", "Garden", "Trip", "Reading", "Health", "Work", "milk", "eggs",
                               "flights", "hotel", "notes", "draft", "review", "launch", "seeds", "soil", "run", "sleep"]
    var m = MindMap("Life plan")
    var ids = List[Int]()
    ids.append(0)
    var s = UInt32(9)
    for k in range(n - 1):
        s ^= s << 13
        s ^= s >> 17
        s ^= s << 5
        var parent = 0 if k < 8 else ids[1 + Int(s % UInt32(len(ids) - 1))]
        var text = words[Int((s >> 5) % UInt32(len(words)))] + (" " + words[Int((s >> 11) % UInt32(len(words)))] if s % 3 == 0 else "")
        ids.append(m.add_child(parent, text, 0))
    m.balance()
    m.set_focus(0)
    m.clear_history()
    return m^


def has_note(sc: Scene, text: String) -> Bool:
    for k in range(len(sc.notes)):
        if sc.notes[k] == text:
            return True
    return False


def mentions(sc: Scene, id: Int) -> Bool:
    """Any note naming topic id (as a topic, a leaving topic or a branch's child)."""
    var a = "node " + String(id) + " "
    var b = "leaving " + String(id) + " "
    var c = "->" + String(id)
    for k in range(len(sc.notes)):
        ref n = sc.notes[k]
        if n.startswith(a) or n.startswith(b) or n.endswith(c):
            return True
    return False


def at_rest(m: MindMap) raises:
    """Nothing moves and every shown topic is drawn exactly at its laid-out place, fully there."""
    assert_false(m.moving())
    for id in range(len(m.model.nodes)):
        if m.boxes[id].visible:
            assert_equal(m.shown_x(id), m.boxes[id].cx())
            assert_equal(m.shown_y(id), m.boxes[id].cy())
            assert_equal(m.presence(id), 1.0)


def frame(mut m: MindMap, mut sc: Scene, font: Font, dt: Float64) -> Float64:
    """One frame of dt ms (step, then paint into a fresh list); returns its time in ms."""
    var t0 = perf_counter_ns()
    _ = m.step(dt)
    sc.reset(1440, 900, 1.0)
    m.paint(sc, font, MapView(720, 450, 0.5))
    return Float64(perf_counter_ns() - t0) / 1e6


def save_png(px: List[UInt32], w: Int, h: Int, path: String) raises:
    var png = encode_png(px, w, h)
    with open(path, "w") as f:
        f.write_bytes(Span(png))


def main() raises:
    var font = Font()
    var t = 1000

    # ---------------------------------------------------------------- layout
    var rng = Rng(74)
    var words = List[String]()
    for w in ["milk", "a", "garden", "project plan", "x", "notes on the quarterly review", "ok", "Ünïcode ✓", "road",
              "very long label that certainly needs to wrap over several lines in its pill", "tea", "bread and butter"]:
        words.append(w)
    var m = MindMap("Big map")
    var ids = List[Int]()
    ids.append(0)
    for _ in range(499):
        var parent = ids[rng.below(len(ids))]
        var text = String()
        for k in range(1 + rng.below(4)):
            if k > 0:
                text += " "
            text += words[rng.below(len(words))]
        ids.append(m.add_child(parent, text, t))
    assert_equal(m.nodes(), 500)
    var folded = 0
    for _ in range(25):
        var id = ids[1 + rng.below(499)]
        if len(m.model.nodes[id].children) > 0 and not m.model.nodes[id].collapsed:
            m.toggle(id, t)
            folded += 1
    assert_true(folded > 5)
    m.clear_history()

    m.boxes.clear()
    m.dirty = True
    var t0 = perf_counter_ns()
    m.layout(font)
    var cold = Float64(perf_counter_ns() - t0) / 1e6
    var warm = 1e9
    for _ in range(20):
        m.dirty = True
        var t1 = perf_counter_ns()
        m.layout(font)
        warm = min(warm, Float64(perf_counter_ns() - t1) / 1e6)
    assert_true(m.visible_nodes() < 500)
    check_layout(m)
    var lefts = 0
    var rights = 0
    for c in m.children(0):
        if m.model.nodes[c].side == LEFT_SIDE:
            lefts += 1
        else:
            rights += 1
    assert_true(lefts > 0 and rights > 0)

    # collapse hides a subtree, expand puts every box back where it was
    var big = -1
    for id in range(1, 500):
        if m.is_visible(id) and not m.model.nodes[id].collapsed and m.hidden_count(id) >= 3:
            big = id
            break
    assert_true(big > 0)
    var xs = List[Float64]()
    var ys = List[Float64]()
    for id in range(500):
        xs.append(m.boxes[id].x)
        ys.append(m.boxes[id].y)
    var before_n = m.visible_nodes()
    m.toggle(big, t)
    m.layout(font)
    assert_true(m.visible_nodes() < before_n)
    for c in m.children(big):
        assert_false(m.boxes[c].visible)
    check_layout(m)
    m.toggle(big, t)
    m.layout(font)
    assert_equal(m.visible_nodes(), before_n)
    for id in range(500):
        if m.boxes[id].visible:
            assert_equal(m.boxes[id].x, xs[id])
            assert_equal(m.boxes[id].y, ys[id])

    # a Scene paint: one node note per shown topic, one branch polygon per shown edge
    var sc = Scene(1440, 900, 1.0)
    m.paint(sc, font, MapView(720, 450, 1.0))
    var vis = m.visible_nodes()
    assert_equal(count_notes(sc, "node ", False), vis)
    assert_equal(count_notes(sc, "branch ", True), vis - 1)
    assert_true(count_notes(sc, "collapsed ", False) > 0)
    # hit: the middle of a shown topic (screen points) finds it
    var probe = ids[1]
    while not m.boxes[probe].visible:
        probe += 1
    assert_equal(m.hit(720 + m.boxes[probe].cx(), 450 + m.boxes[probe].cy()), probe)
    print("mindmap layout: ok")
    print("mindmap layout time: 500 nodes", cold, "ms cold,", warm, "ms warm")

    # ---------------------------------------------------------------- keys
    var g = MindMap("Groceries")
    var states = List[String]()  # the outline after each undo step
    states.append(g.to_text())
    press(g, "Tab", font, t)
    assert_equal(g.editing, 1)
    typed(g, "Milk", font, t)
    press(g, "Enter", font, t)
    states.append(g.to_text())
    press(g, "Enter", font, t)
    typed(g, "Eggs", font, t)
    press(g, "Enter", font, t)
    states.append(g.to_text())
    press(g, "Enter", font, t)
    typed(g, "Bread", font, t)
    press(g, "Enter", font, t)
    states.append(g.to_text())
    assert_equal(g.nodes(), 4)
    var kids = g.children(0)
    assert_equal(len(kids), 3)
    assert_equal(g.text_of(kids[0]), "Milk")
    assert_equal(g.text_of(kids[1]), "Eggs")
    assert_equal(g.text_of(kids[2]), "Bread")
    assert_equal(g.editing, -1)
    var milk = kids[0]
    var eggs = kids[1]
    var bread = kids[2]
    assert_equal(g.focus(), bread)
    # arrows on the right side: Up/Down through siblings, Left to the parent, Right to the nearest child
    press(g, "ArrowUp", font, t)
    assert_equal(g.focus(), eggs)
    press(g, "ArrowUp", font, t)
    assert_equal(g.focus(), milk)
    press(g, "ArrowDown", font, t)
    assert_equal(g.focus(), eggs)
    press(g, "ArrowLeft", font, t)
    assert_equal(g.focus(), 0)
    press(g, "ArrowRight", font, t)
    assert_equal(g.focus(), eggs)  # (the middle one sits level with the root)
    # a topic on the left (Tab on the root balances it there); arrows mirror
    press(g, "ArrowLeft", font, t)
    press(g, "Tab", font, t)
    typed(g, "Chores", font, t)
    press(g, "Enter", font, t)
    states.append(g.to_text())
    var chores = g.focus()
    assert_equal(g.side(chores), LEFT_SIDE)
    press(g, "Tab", font, t)
    typed(g, "Laundry", font, t)
    press(g, "Enter", font, t)
    states.append(g.to_text())
    var laundry = g.focus()
    assert_equal(g.parent(laundry), chores)
    assert_equal(g.side(laundry), LEFT_SIDE)
    press(g, "ArrowRight", font, t)
    assert_equal(g.focus(), chores)
    press(g, "ArrowRight", font, t)
    assert_equal(g.focus(), 0)
    press(g, "ArrowLeft", font, t)
    assert_equal(g.focus(), chores)
    press(g, "ArrowLeft", font, t)
    assert_equal(g.focus(), laundry)
    g.layout(font)
    check_layout(g)
    # F2 edits keeping the words; typing replaces them
    g.set_focus(milk)
    press(g, "F2", font, t)
    typed(g, " 2L", font, t)
    press(g, "Enter", font, t)
    assert_equal(g.text_of(milk), "Milk 2L")
    states.append(g.to_text())
    g.set_focus(bread)
    typed(g, "Rye", font, t)
    assert_equal(g.editing, bread)
    press(g, "Enter", font, t)
    assert_equal(g.text_of(bread), "Rye")
    states.append(g.to_text())
    # Escape on an empty new topic removes it (and leaves no undo step); on a typed one it commits
    var n0 = g.nodes()
    press(g, "Tab", font, t)
    assert_equal(g.nodes(), n0 + 1)
    press(g, "Escape", font, t)
    assert_equal(g.nodes(), n0)
    assert_equal(g.focus(), bread)
    assert_equal(g.to_text(), states[len(states) - 1])
    press(g, "Tab", font, t)
    typed(g, "Sourdough", font, t)
    press(g, "Escape", font, t)
    assert_equal(g.nodes(), n0 + 1)
    var sour = g.focus()
    assert_equal(g.text_of(sour), "Sourdough")
    states.append(g.to_text())
    # Space collapses (and expands) a topic with children
    g.set_focus(bread)
    var v0 = g.visible_nodes()
    press(g, " ", font, t)
    assert_true(g.model.nodes[bread].collapsed)
    assert_equal(g.visible_nodes(), v0 - 1)
    states.append(g.to_text())
    var sc2 = Scene(800, 600, 1.0)
    g.paint(sc2, font, MapView(400, 300, 1.0))
    assert_equal(count_notes(sc2, "collapsed ", False), 1)
    press(g, " ", font, t)
    assert_equal(g.visible_nodes(), v0)
    states.append(g.to_text())
    # Delete removes a subtree and focuses the previous sibling (else the parent); the root stays
    g.set_focus(bread)
    press(g, "Delete", font, t)
    assert_equal(g.nodes(), n0 - 1)
    assert_false(g.model.nodes[sour].alive)
    assert_equal(g.focus(), eggs)
    states.append(g.to_text())
    g.set_focus(chores)
    press(g, "Backspace", font, t)
    assert_equal(g.focus(), 0)
    assert_equal(g.nodes(), n0 - 3)
    states.append(g.to_text())
    assert_false(g.key("Delete", 0, t, font))
    assert_equal(g.nodes(), n0 - 3)
    # a pointer: tap focuses, a second tap edits
    g.layout(font)
    var sc3 = Scene(800, 600, 1.0)
    g.paint(sc3, font, MapView(400, 300, 1.0))
    var ex = 400 + g.boxes[eggs].cx()
    var ey = 300 + g.boxes[eggs].cy()
    _ = g.tap(ex, ey, t, font)
    assert_equal(g.focus(), eggs)
    assert_equal(g.editing, -1)
    _ = g.tap(ex, ey, t + 200, font)
    assert_equal(g.editing, eggs)
    var sc4 = Scene(800, 600, 1.0)
    g.paint(sc4, font, MapView(400, 300, 1.0))
    assert_equal(count_notes(sc4, "node ", False), g.visible_nodes())
    press(g, "Escape", font, t)  # (unchanged words: no step)
    assert_equal(g.to_text(), states[len(states) - 1])
    print("mindmap keys: ok")

    # ---------------------------------------------------------------- undo
    var steps = len(states) - 1
    for i in range(steps):
        assert_true(g.key("z", CTRL, t, font))
        t += 40
        assert_equal(g.to_text(), states[steps - 1 - i])
    assert_equal(g.nodes(), 1)
    assert_false(g.key("z", CTRL, t, font))
    for i in range(steps):
        assert_true(g.key("z", CTRL | SHIFT, t, font))
        t += 40
        assert_equal(g.to_text(), states[i + 1])
    assert_false(g.key("z", CTRL | SHIFT, t, font))
    # ctrl+z while editing undoes typing inside the topic, not the map
    g.set_focus(eggs)
    press(g, "F2", font, t)
    typed(g, "!", font, t)
    _ = g.key("z", CTRL, t + 5000, font)
    assert_equal(g.editing, eggs)
    assert_equal(g.ed.text(), "Eggs")
    press(g, "Enter", font, t)
    assert_equal(g.to_text(), states[steps])

    # the outline round-trips, flags and awkward words included
    g.set_done(eggs, DONE_YES, t)
    var milk2 = g.children(0)[0]
    g.set_done(milk2, DONE_OPEN, t)
    g.set_color(milk2, 0xFF336699, t)
    g.set_text(eggs, "two\nlines \\ and a [bracket]", t)
    var deep = g.add_child(milk2, "  leading spaces", t)
    _ = g.add_child(deep, "deeper", t)
    g.toggle(deep, t)
    var outline = g.to_text()
    var back = MindMap()
    back.from_text(outline)
    assert_equal(back.to_text(), outline)
    assert_equal(back.nodes(), g.nodes())
    assert_equal(back.visible_nodes(), g.visible_nodes())
    var big_back = MindMap()
    big_back.from_text(m.to_text())
    assert_equal(big_back.to_text(), m.to_text())
    assert_equal(big_back.nodes(), 500)
    big_back.layout(font)
    check_layout(big_back)
    print("mindmap undo: ok")

    # ---------------------------------------------------------------- motion
    var mm = sample_map(300)
    var scm = Scene(1440, 900, 1.0)
    _ = frame(mm, scm, font, 0)
    assert_false(scm.again)  # a map that is just there asks for no frames
    at_rest(mm)
    # an add: the new topic grows out of its parent, the rest glide to the new layout, within 400 ms, overshooting
    # no more than 8 % of their travel
    var par = mm.children(mm.children(0)[0])[0]
    var nid = mm.add_child(par, "new idea", t)
    var first = frame(mm, scm, font, 0)
    assert_true(scm.again)
    assert_equal(mm.shown_x(nid), mm.shown_x(par))
    assert_equal(mm.shown_y(nid), mm.shown_y(par))
    assert_equal(mm.presence(nid), 0.0)
    var n_all = len(mm.model.nodes)
    var x0 = List[Float64]()
    var y0 = List[Float64]()
    var moved = 0
    for id in range(n_all):
        x0.append(mm.shown_x(id))
        y0.append(mm.shown_y(id))
        if mm.boxes[id].visible and (mm.boxes[id].cx() != x0[id] or mm.boxes[id].cy() != y0[id]):
            moved += 1
    assert_true(moved > 1)  # (the new topic and the ones it pushed aside)
    var over = 0.0
    var worst = 0.0
    var total = first
    var frames = 1
    var elapsed = 0.0
    while elapsed < 400:
        var ms = frame(mm, scm, font, 16)
        elapsed += 16
        worst = max(worst, ms)
        total += ms
        frames += 1
        for id in range(n_all):
            if not mm.boxes[id].visible:
                continue
            var ux = mm.boxes[id].cx() - x0[id]
            var uy = mm.boxes[id].cy() - y0[id]
            var travel = ux * ux + uy * uy
            if travel > 4:
                var along = ((mm.shown_x(id) - x0[id]) * ux + (mm.shown_y(id) - y0[id]) * uy) / travel
                over = max(over, along - 1)
        if elapsed <= 32:
            assert_true(scm.again)
    at_rest(mm)
    assert_true(over <= 0.08)
    _ = frame(mm, scm, font, 16)
    assert_false(scm.again)  # settled: no more frames asked for
    assert_true(has_note(scm, "node " + String(nid) + " new idea"))
    worst = max(worst, first)
    # less motion: an add lands at once, asking for nothing
    var nid2 = mm.add_child(par, "at once", t)
    scm.reset(1440, 900, 1.0)
    scm.is_still = True
    mm.paint(scm, font, MapView(720, 450, 0.5))
    assert_false(scm.again)
    at_rest(mm)
    assert_equal(mm.presence(nid2), 1.0)
    # a removal: the topic shrinks into its parent, fading ("leaving" while it does), then is gone from the notes
    mm.remove(nid, t)
    _ = frame(mm, scm, font, 0)
    assert_true(scm.again)
    assert_true(has_note(scm, "leaving " + String(nid) + " new idea"))
    assert_false(has_note(scm, "node " + String(nid) + " new idea"))
    elapsed = 0
    while elapsed < 400:
        _ = frame(mm, scm, font, 16)
        elapsed += 16
    _ = frame(mm, scm, font, 16)
    assert_false(scm.again)
    assert_false(mentions(scm, nid))
    at_rest(mm)
    # collapse glides the subtree into its topic and away; expand grows it back to the same places
    var fold = mm.children(0)[1]
    var kids_of = mm.children(fold)
    var kx = mm.boxes[kids_of[0]].cx()
    var ky = mm.boxes[kids_of[0]].cy()
    mm.toggle(fold, t)
    _ = frame(mm, scm, font, 0)
    assert_true(has_note(scm, "leaving " + String(kids_of[0]) + " " + mm.text_of(kids_of[0])))
    elapsed = 0
    while elapsed < 400:
        _ = frame(mm, scm, font, 16)
        elapsed += 16
    assert_false(mentions(scm, kids_of[0]))
    at_rest(mm)
    mm.toggle(fold, t)
    _ = frame(mm, scm, font, 0)
    assert_equal(mm.shown_x(kids_of[0]), mm.shown_x(fold))  # (growing out of the topic)
    elapsed = 0
    while elapsed < 400:
        _ = frame(mm, scm, font, 16)
        elapsed += 16
    at_rest(mm)
    assert_equal(mm.boxes[kids_of[0]].cx(), kx)
    assert_equal(mm.boxes[kids_of[0]].cy(), ky)
    _ = frame(mm, scm, font, 16)
    assert_false(scm.again)
    assert_equal(count_notes(scm, "node ", False), mm.visible_nodes())
    assert_equal(count_notes(scm, "branch ", True), mm.visible_nodes() - 1)
    # the clock drives a host's frames (no step()): a settled map asks for nothing
    var live = sample_map(40)
    var scl = Scene(800, 600, 1.0)
    live.paint(scl, font, MapView(400, 300, 1.0))
    assert_false(scl.again)
    _ = live.add_child(0, "grows", t)
    scl.reset(800, 600, 1.0)
    live.paint(scl, font, MapView(400, 300, 1.0))
    assert_true(scl.again)
    assert_true(worst < 4.0)  # (the budget is 2 ms; noise on a busy machine is allowed for, the mean is printed)
    print("mindmap motion: ok")
    print("mindmap motion frame (300 topics, step + paint into a Scene, add animation):", total / Float64(frames), "ms mean,", worst,
          "ms worst over", frames, "frames; overshoot", over * 100, "% of travel")

    # ---------------------------------------------------------------- the judged picture: build/g75/map-ours.png
    var pic = sample_map(300)
    pic.layout(font)
    var bx0 = 1e9
    var by0 = 1e9
    var bx1 = -1e9
    var by1 = -1e9
    for id in range(len(pic.model.nodes)):
        if pic.boxes[id].visible:
            bx0 = min(bx0, pic.boxes[id].x)
            by0 = min(by0, pic.boxes[id].y)
            bx1 = max(bx1, pic.boxes[id].x + pic.boxes[id].w)
            by1 = max(by1, pic.boxes[id].y + pic.boxes[id].h)
    var W = 1440
    var H = 900
    var k = min(Float64(W - 40) / (bx1 - bx0), Float64(H - 40) / (by1 - by0))
    var px = List[UInt32](length=W * H, fill=rgba(0xF7, 0xF8, 0xFA))
    var sp = SurfacePainter(Surface(Int(px.unsafe_ptr()), W, H, 1.0))
    pic.paint(sp, font, MapView(Float64(W) / 2 - (bx0 + bx1) / 2 * k, Float64(H) / 2 - (by0 + by1) / 2 * k, k))
    makedirs("build/g75", exist_ok=True)
    save_png(px, W, H, "build/g75/map-ours.png")
    print("mindmap picture: build/g75/map-ours.png,", Int(bx1 - bx0), "x", Int(by1 - by0), "map points at zoom", k)
