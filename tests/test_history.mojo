# Undo and redo, generic (goal 74 M1): steps undo and redo in order, a new edit drops the redo branch, typing within the
# window merges into one step (and a seal, a pause or another kind splits it), the cap forgets the oldest.
#   pixi run mojo run -I . tests/test_history.mojo
from std.testing import assert_equal, assert_true, assert_false

from mojoui.history import History, Undoable, Snapshot


@fieldwise_init
struct Typed(Undoable):
    """Text typed at an offset; merges when the later text continues right after it."""

    var at: Int
    var text: String

    def merge(mut self, later: Self) -> Bool:
        if later.at != self.at + self.text.byte_length():
            return False
        self.text += later.text
        return True


def apply_undo(mut doc: String, s: Typed):
    doc = String(doc[byte = 0 : s.at]) + String(doc[byte = s.at + s.text.byte_length() :])


def apply_redo(mut doc: String, s: Typed):
    doc = String(doc[byte = 0 : s.at]) + s.text + String(doc[byte = s.at :])


def type_into(mut doc: String, mut h: History[Typed], at: Int, text: String, now: Int, coalesce: Bool = True):
    apply_redo(doc, Typed(at, text))
    h.push(Typed(at, text), now, coalesce)


def main() raises:
    # Order, redo, the redo branch dropped.
    var doc = String("")
    var h = History[Typed]()
    type_into(doc, h, 0, "a", 0, False)
    type_into(doc, h, 1, "b", 10, False)
    type_into(doc, h, 2, "c", 20, False)
    assert_equal(doc, "abc")
    apply_undo(doc, h.undo().value())
    apply_undo(doc, h.undo().value())
    assert_equal(doc, "a")
    apply_redo(doc, h.redo().value())
    assert_equal(doc, "ab")
    type_into(doc, h, 2, "X", 30, False)
    assert_false(h.can_redo())
    assert_equal(doc, "abX")
    apply_undo(doc, h.undo().value())
    apply_undo(doc, h.undo().value())
    apply_undo(doc, h.undo().value())
    assert_equal(doc, "")
    assert_false(h.undo())
    assert_true(h.can_redo())
    print("history: ok")

    # Coalescing: a word typed letter by letter is one step; a pause, a seal, a jump or a refusal splits.
    doc = ""
    var c = History[Typed](window_ms=500)
    var t = 0
    for ch in ["h", "e", "l", "l", "o"]:
        type_into(doc, c, doc.byte_length(), ch, t)
        t += 100
    assert_equal(len(c.done), 1)
    type_into(doc, c, doc.byte_length(), " ", t + 2000)  # (a pause: a new step)
    assert_equal(len(c.done), 2)
    type_into(doc, c, doc.byte_length(), "w", t + 2100)
    c.seal()
    type_into(doc, c, doc.byte_length(), "o", t + 2150)  # (sealed: a new step)
    assert_equal(len(c.done), 3)
    type_into(doc, c, 0, "!", t + 2200)  # (not right after: merge refused)
    assert_equal(len(c.done), 4)
    assert_equal(doc, "!hello wo")
    apply_undo(doc, c.undo().value())
    apply_undo(doc, c.undo().value())
    assert_equal(doc, "hello w")
    apply_undo(doc, c.undo().value())
    assert_equal(doc, "hello")
    apply_undo(doc, c.undo().value())
    assert_equal(doc, "")
    # Snapshots merge by kind: the first before, the last after.
    var s = History[Snapshot[Int]]()
    s.push(Snapshot[Int](1, 0, 5), 0, True)
    s.push(Snapshot[Int](1, 5, 9), 100, True)
    s.push(Snapshot[Int](2, 9, 12), 200, True)
    assert_equal(len(s.done), 2)
    var top = s.undo().value().copy()
    assert_equal(top.before, 9)
    var first = s.undo().value().copy()
    assert_equal(first.before, 0)
    assert_equal(first.after, 9)
    print("history coalesce: ok")

    # The cap keeps the newest.
    var k = History[Snapshot[Int]](cap=3)
    for i in range(10):
        k.push(Snapshot[Int](0, i, i + 1), i * 10)
    assert_equal(len(k.done), 3)
    assert_equal(k.undo().value().before, 9)
    assert_equal(k.undo().value().before, 8)
    assert_equal(k.undo().value().before, 7)
    assert_false(k.can_undo())
    print("history cap: ok")
