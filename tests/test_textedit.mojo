# The native text editor (goal 74 M2): edits, caret moves and selection, soft wrap, hit tests both ways, undo with typing
# merged into words, and a 1,000,000-character document: opened fast, a keystroke in the middle (edit, re-layout, paint
# of the view into a Scene) well inside a frame.
#   pixi run mojo run -I . tests/test_textedit.mojo
from std.testing import assert_equal, assert_true, assert_false
from std.time import perf_counter_ns

from mojoui.textedit import TextEdit, PlainStyler, Pos, SHIFT, CTRL
from mojoui.text import Font
from mojoui.scene import Scene


def keys(mut ed: TextEdit, text: String, font: Font, st: PlainStyler, mut t: Int):
    for ch in text.codepoint_slices():
        var c = String(ch)
        _ = ed.key("Enter" if c == "\n" else c, 0, t, font, st)
        t += 50


def p95(var xs: List[Float64]) -> Float64:
    sort(xs)
    return xs[min(Int(Float64(len(xs)) * 0.95), len(xs) - 1)]


def main() raises:
    var font = Font()
    var st = PlainStyler(15)
    var t = 0

    # Edits: typing, Enter splits a paragraph, Backspace joins, Delete, a selection replaced, cut and paste.
    var ed = TextEdit("")
    keys(ed, "Hello world", font, st, t)
    assert_equal(ed.text(), "Hello world")
    _ = ed.key("Enter", 0, t, font, st)
    keys(ed, "second", font, st, t)
    assert_equal(ed.text(), "Hello world\nsecond")
    assert_equal(len(ed.paras), 2)
    _ = ed.key("Home", 0, t, font, st)
    _ = ed.key("Backspace", 0, t, font, st)
    assert_equal(ed.text(), "Hello worldsecond")
    _ = ed.key("Delete", 0, t, font, st)
    assert_equal(ed.text(), "Hello worldecond")
    ed.anchor = Pos(0, 0)
    ed.caret = Pos(0, 5)
    keys(ed, "Howdy", font, st, t)
    assert_equal(ed.text(), "Howdy worldecond")
    ed.anchor = Pos(0, 6)
    ed.caret = Pos(0, 11)
    var cut = ed.cut(t)
    assert_equal(cut, "world")
    ed.insert("ünïcode ✓\nline", t)
    assert_equal(ed.text(), "Howdy ünïcode ✓\nlineecond")
    print("textedit edit: ok")

    # Caret: characters (multi-byte too), words, line ends, document ends, shift extends, select all.
    ed.set_text("alpha beta, gamma\nünï x")
    _ = ed.key("ArrowRight", CTRL, t, font, st)
    assert_true(ed.caret == Pos(0, 5))
    _ = ed.key("ArrowRight", CTRL, t, font, st)
    assert_true(ed.caret == Pos(0, 10))
    _ = ed.key("ArrowLeft", CTRL | SHIFT, t, font, st)
    assert_equal(ed.selected_text(), "beta")
    _ = ed.key("ArrowLeft", 0, t, font, st)  # (collapses to the selection's start)
    assert_true(ed.caret == Pos(0, 6))
    _ = ed.key("End", 0, t, font, st)
    assert_true(ed.caret == Pos(0, 17))
    _ = ed.key("ArrowRight", 0, t, font, st)
    assert_true(ed.caret == Pos(1, 0))
    _ = ed.key("ArrowRight", 0, t, font, st)
    assert_true(ed.caret == Pos(1, 2))  # (ü is two bytes)
    _ = ed.key("ArrowDown", 0, t, font, st)
    assert_true(ed.caret == Pos(1, ed.paras[1].byte_length()))
    _ = ed.key("ArrowUp", 0, t, font, st)
    assert_equal(ed.caret.para, 0)
    _ = ed.key("End", CTRL, t, font, st)
    assert_true(ed.caret == Pos(1, ed.paras[1].byte_length()))
    _ = ed.key("a", CTRL, t, font, st)
    assert_equal(ed.selected_text(), "alpha beta, gamma\nünï x")
    print("textedit caret: ok")

    # Wrap: a long paragraph wraps at spaces inside the width; every line fits; a word longer than the line breaks.
    var long = String()
    for k in range(60):
        long += "word" + String(k) + " "
    ed.set_text(long + "\n" + "x" * 300)
    ed.resize(320, 400)
    ed.lay(0, font, st)
    ref l = ed.laid[0]
    assert_true(len(l.starts) > 5)
    for k in range(len(l.starts)):
        var a = l.starts[k]
        var b = l.starts[k + 1] if k + 1 < len(l.starts) else ed.paras[0].byte_length()
        var line = String(ed.paras[0][byte=a:b])
        var w = font.measure(String(line.rstrip(" ")), 15)
        assert_true(w <= ed.content_width() + 0.5)
        if k > 0:
            assert_equal(Int(ed.paras[0].as_bytes()[a - 1]), 32)  # (each line starts after a space)
    ed.lay(1, font, st)
    assert_true(len(ed.laid[1].starts) > 3)
    # Up/down inside a wrapped paragraph keep the column.
    ed.caret = Pos(0, ed.laid[0].starts[1] + 3)
    ed.anchor = ed.caret
    var x_before = ed.x_in_line(0, 1, ed.caret.byte, font)
    _ = ed.key("ArrowDown", 0, t, font, st)
    assert_equal(ed.line_of(0, ed.caret.byte), 2)
    assert_true(abs(ed.x_in_line(0, 2, ed.caret.byte, font) - x_before) < 12)
    print("textedit wrap: ok")

    # Hit: every caret position's box maps back to it; a click past a line's end lands at its end.
    ed.set_text("The quick brown fox\njumps over\n\nthe lazy dog")
    ed.resize(500, 300)
    var sc = Scene(500, 300, 1.0)
    ed.paint(sc, font, 0, 0, st)
    for para in range(len(ed.paras)):
        var b = 0
        while b <= ed.paras[para].byte_length():
            ed.caret = Pos(para, b)
            ed.anchor = ed.caret
            var cb = ed.caret_box(font, st)
            var back = ed.hit(cb[0] + 0.5, cb[1] + cb[2] / 2, font, st)
            if not (back == Pos(para, b)):
                print("HIT FAIL", para, b, "->", back.para, back.byte, cb[0], cb[1], cb[2])
            assert_true(back == Pos(para, b))
            b += 1
    var end = ed.hit(480, 5, font, st)
    assert_true(end == Pos(0, 19))
    ed.press(2, 300, False, font, st)
    ed.release()
    assert_equal(ed.caret.para, 3)
    ed.caret = Pos(0, 6)
    ed.anchor = ed.caret
    var qb = ed.caret_box(font, st)
    ed.select_word(qb[0] + 3, qb[1] + 2, font, st)
    assert_equal(ed.selected_text(), "quick")
    print("textedit hit: ok")

    # Undo: a typed word is one step; Enter its own; redo; a new edit drops redo.
    ed.set_text("")
    t = 100_000
    keys(ed, "one two", font, st, t)
    _ = ed.key("Enter", 0, t, font, st)
    keys(ed, "three", font, st, t)
    assert_equal(ed.text(), "one two\nthree")
    _ = ed.key("z", CTRL, t, font, st)
    assert_equal(ed.text(), "one two\n")
    _ = ed.key("z", CTRL, t, font, st)
    assert_equal(ed.text(), "one two")
    _ = ed.key("z", CTRL, t, font, st)
    assert_equal(ed.text(), "one ")
    _ = ed.key("z", CTRL, t, font, st)
    assert_equal(ed.text(), "")
    _ = ed.key("z", CTRL | SHIFT, t, font, st)
    _ = ed.key("z", CTRL | SHIFT, t, font, st)
    assert_equal(ed.text(), "one two")
    keys(ed, "!", font, st, t)
    assert_false(ed.history.can_redo())
    # Backspaces merge too.
    t += 5000
    for _ in range(3):
        _ = ed.key("Backspace", 0, t, font, st)
        t += 50
    assert_equal(ed.text(), "one t")
    _ = ed.key("z", CTRL, t, font, st)
    assert_equal(ed.text(), "one two!")
    print("textedit undo: ok")

    # 1M: open, then 200 keystrokes in the middle, each edit + re-layout + paint of the view into a Scene.
    var big = String()
    var s = UInt32(7)
    var words: List[String] = ["the", "note", "canvas", "mojo", "fast", "native", "editor", "ink", "page", "map", "a", "of"]
    while big.byte_length() < 1_000_000:
        s ^= s << 13
        s ^= s >> 17
        s ^= s << 5
        big += words[Int(s % UInt32(len(words)))]
        big += "\n" if s % 13 == 0 else " "
    var t0 = perf_counter_ns()
    var doc = TextEdit(big)
    doc.resize(900, 800)
    var scene = Scene(900, 800, 1.0)
    doc.paint(scene, font, 0, 0, st)
    var open_ms = Float64(perf_counter_ns() - t0) / 1e6
    assert_true(doc.chars() >= 1_000_000)
    var mid = len(doc.paras) // 2
    doc.caret = Pos(mid, doc.paras[mid].byte_length() // 2)
    doc.anchor = doc.caret
    var warm = Scene(900, 800, 1.0)
    doc.paint(warm, font, 0, 0, st)
    var times = List[Float64]()
    var typed = "native mojo is fast "
    for k in range(200):
        var ch = String(typed[byte = k % 20 : k % 20 + 1])
        var a = perf_counter_ns()
        _ = doc.key(ch, 0, 1_000_000 + k * 40, font, st)
        var frame = Scene(900, 800, 1.0)
        doc.paint(frame, font, 0, 0, st)
        times.append(Float64(perf_counter_ns() - a) / 1e6)
    var worst = p95(times^)
    print("textedit 1M numbers: chars=" + String(doc.chars()) + " paragraphs=" + String(len(doc.paras)) + " open_ms=" + String(open_ms) + " key_p95_ms=" + String(worst))
    assert_true(open_ms <= 300)
    assert_true(worst <= 4)
    print("textedit 1M: ok")
