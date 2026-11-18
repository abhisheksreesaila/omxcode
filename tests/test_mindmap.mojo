# The native mind map (goal 74 M5): a 500-topic random map laid out with no two shown boxes overlapping, every topic on
# its first-level ancestor's side, collapse hiding and expand restoring the same places, a Scene paint with one note per
# topic and one polygon per branch; the keys (Tab, Enter, typing, F2, Escape, Delete, arrows, Space); undo and redo of
# every step, and the outline text round trip.
#   pixi run mojo run -I . tests/test_mindmap.mojo
from std.testing import assert_equal, assert_true, assert_false
from std.time import perf_counter_ns

from mojoui.mindmap import MindMap, MapView, RIGHT_SIDE, LEFT_SIDE, DONE_OPEN, DONE_YES
from mojoui.text import Font
from mojoui.scene import Scene, OP_POLY
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
