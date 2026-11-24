# A page's ink (mojoui.pageink, pagesheet; goal 79, docs/goals/79-gaps.md 28): what a document holds is read, drawn and saved
# as it was; positions follow the words through edits (counted in UTF-16 units there); a mark goes with its word and comes
# back with undo; pens, highlighter, eraser; one history with the words. No display.
#   pixi run mojo run -I . tests/test_pageink.mojo
from std.testing import assert_equal, assert_true
from mojoui.json import Json
from mojoui.pageink import PageInk, utf16_at, byte_at_utf16
from mojoui.pagesheet import PageSheet
from mojoui.textedit import Pos
from mojoui.notesshell import Boxes
from mojoui.scene import Scene
from mojoui.canvas import rgba

comptime MD = "# é 📚 title\n\nsome words here\nlast line"
# ("words" begins at UTF-16 unit 19: "# é 📚 title" is 12, two newlines, "some ")
comptime SRC = '{"version":1,"markdown":"# é 📚 title\\n\\nsome words here\\nlast line","ink":{"marks":[{"id":"a","tool":"red","points":[[0,0],[10,2.50]],"anchor":{"pos":19,"end":24,"quote":{"exact":"words","prefix":"x"}},"dx":1.0,"dy":4,"future":[1]},{"id":"l","tool":"pen","points":[[0,0]],"loose":true,"anchor":{"pos":null,"end":null,"quote":{"exact":"gone"}},"dx":0,"dy":0}],"drawings":[{"id":"d","pos":30,"side":-1,"height":40,"link":{"pos":25,"end":29,"quote":{"exact":"here"}},"strokes":[]}],"extra":true}}'


def drawn(mut p: PageSheet) -> Scene:
    var sc = Scene(1200, 800, 1.0)
    var bx = Boxes()
    p.draw(sc, bx, 10, 66, 1188, 788, 1, "", rgba(255, 255, 255), 14)
    return sc^


def opened() raises -> PageSheet:
    var p = PageSheet()
    p.set_markdown(MD)
    p.load_ink(SRC)
    _ = drawn(p)
    return p^


def anchor(saved: String, i: Int) raises -> Tuple[Int, Int]:
    var j = Json.parse(saved)
    var a = j.get(j.at(j.get(j.get(0, "ink"), "marks"), i), "anchor")
    return (Int(j.real(j.get(a, "pos"))), Int(j.real(j.get(a, "end"))))


def drag(mut p: PageSheet, x0: Float64, y0: Float64, x1: Float64, y1: Float64) -> Bool:
    p.mark_press(x0, y0)
    for i in range(1, 11):
        p.mark_move(x0 + (x1 - x0) * Float64(i) / 10, y0 + (y1 - y0) * Float64(i) / 10)
    return p.mark_release()


def main() raises:
    assert_equal(utf16_at(MD, String(MD).find("words")), 19)
    assert_equal(byte_at_utf16(MD, 19), String(MD).find("words"))
    assert_equal(byte_at_utf16(MD, 999), String(MD).byte_length())
    # read and saved: the very text; drawn at its word
    var p = opened()
    assert_equal(p.page_json(SRC), SRC)
    assert_equal(len(p.ink.marks), 2)
    var o = p.mark_origin(0)
    assert_true(o[2] and abs(o[0] - (p.text_x + p.x_at(2, 0, 5) + 1)) < 0.01 and o[1] > p.tops[2] and o[1] < p.tops[2] + 16, "at its word")
    assert_true(not p.mark_origin(1)[2], "loose ink is on no word")
    # an edit before it: its position follows, everything else of it as it was
    p.ed.move_to(Pos(2, 0), False)
    p.insert("é📚 ")
    var saved = p.page_json(SRC)
    assert_true(anchor(saved, 0) == (19 + 4, 24 + 4), saved)
    assert_true(saved.find('"points":[[0,0],[10,2.50]]') >= 0 and saved.find('"future":[1]') >= 0 and saved.find('"prefix":"x"') >= 0 and saved.find('"loose":true') >= 0 and saved.find('"extra":true') >= 0, saved)
    assert_true(saved.find('"pos":34,"side":-1') >= 0 and saved.find('"link":{"pos":29,"end":33') >= 0, "the drawing and its link too: " + saved)
    _ = drawn(p)
    assert_true(p.mark_origin(0)[0] > o[0] + 10, "and it moves on screen")
    for _ in range(3):
        p.backspace()
    assert_equal(p.page_json(SRC), SRC)  # (all as it was: the very text)
    # an edit after it changes nothing of it; typing at its end doesn't stretch it, inside it does
    p.caret_end()
    p.insert("!")
    assert_true(anchor(p.page_json(SRC), 0) == (19, 24), "after it")
    p.ed.move_to(Pos(2, 10), False)
    p.insert("x")
    assert_true(anchor(p.page_json(SRC), 0) == (19, 24), "at its end")
    p.ed.move_to(Pos(2, 7), False)
    p.insert("yy")
    assert_true(anchor(p.page_json(SRC), 0) == (19, 26), "inside it")
    # its word deleted: it goes; undone: it is back
    p = opened()
    p.ed.move_to(Pos(2, 5), False)
    p.ed.move_to(Pos(2, 10), True)
    _ = p.key("Delete", 0, 0)
    assert_equal(len(p.ink.marks), 1)
    assert_true(p.page_json(SRC).find('"id":"a"') < 0, "gone from what is saved")
    assert_true(p.key("z", 2, 0) == 2 and len(p.ink.marks) == 2, "back")
    assert_equal(p.page_json(SRC), SRC)
    assert_true(p.key("y", 2, 0) == 2 and len(p.ink.marks) == 1 and p.key("z", 2, 0) == 2, "redo, undo")
    # part of it deleted: it stays on what is left
    p.ed.move_to(Pos(2, 3), False)
    p.ed.move_to(Pos(2, 7), True)
    _ = p.key("Delete", 0, 0)
    assert_true(anchor(p.page_json(SRC), 0) == (17, 20), "on what is left")
    # made here: pens, positions in UTF-16; the eraser; one history with the words
    p = opened()
    var y = p.tops[2] + 12
    var x = p.text_x + p.x_at(2, 0, 11)
    p.tool = "highlight"
    assert_true(drag(p, x, y, x + 60, y + 2), "highlighted")
    p.tool = "red"
    assert_true(drag(p, x, y + 60, x + 40, y + 60), "and a red one")
    assert_equal(len(p.ink.marks), 4)
    saved = p.page_json(SRC)
    assert_true(saved.find('"tool":"highlight"') >= 0 and saved.find('"exact":"here"') >= 0, saved)
    assert_true(anchor(saved, 2) == (25, 29), "here, in UTF-16 units")
    assert_true(saved.find('"id":"a","tool":"red","points":[[0,0],[10,2.50]]') >= 0, "the document's as it was")
    var q = PageSheet()  # (read again: the same marks in the same places)
    q.set_markdown(MD)
    q.load_ink(saved)
    _ = drawn(q)
    for i in range(4):
        var a = p.mark_origin(i)
        var b = q.mark_origin(i)
        assert_true(abs(a[0] - b[0]) < 0.11 and abs(a[1] - b[1]) < 0.11 and a[2] == b[2], "mark " + String(i))
    assert_equal(q.page_json(saved), saved)
    p.ed.move_to(Pos(3, 0), False)
    _ = p.key("w", 0, 99000)
    p.tool = "eraser"
    assert_true(not drag(p, 5, 5, 6, 6), "nothing there")
    assert_true(drag(p, x - 20, y, x + 80, y), "erases what it touches")
    assert_equal(len(p.ink.marks), 3)
    assert_true(p.page_json(SRC).find('"tool":"highlight"') < 0, "gone")
    assert_true(p.key("z", 2, 0) == 2 and len(p.ink.marks) == 4 and p.ink.marks[2].tool == "highlight", "undo: it, where it was")
    assert_true(p.key("z", 2, 0) == 2 and p.markdown() == MD and len(p.ink.marks) == 4, "then the w")
    assert_true(p.key("z", 2, 0) == 2 and p.key("z", 2, 0) == 2 and len(p.ink.marks) == 2, "then the marks")
    assert_equal(p.page_json(SRC), SRC)
    assert_true(p.key("y", 2, 0) == 2 and p.key("y", 2, 0) == 2 and p.key("y", 2, 0) == 2 and p.key("y", 2, 0) == 2 and len(p.ink.marks) == 3, "all of it again")
    # the document's own mark erased
    o = p.mark_origin(0)
    assert_true(drag(p, o[0], o[1], o[0] + 2, o[1]), "the document's own")
    assert_true(p.page_json(SRC).find('"id":"a"') < 0 and p.page_json(SRC).find('"id":"l"') >= 0, "gone, the loose one kept")
    # never read: never dropped
    var r = PageSheet()
    r.set_markdown(MD)
    assert_equal(r.page_json(SRC), SRC)
    # a highlight lies under the words, a pen over them
    var sc = drawn(q)
    assert_true(len(sc.kinds) > 0, "drawn")
    print("pageink: ok")
