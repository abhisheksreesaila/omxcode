# A mind map edited as a person does it (goal 79, docs/goals/79-gaps.md 42–44): clicks, moves, deleting with what is under,
# undo and redo, zoom about the pointer, panning, Fit. No display.
#   pixi run mojo run -I . -I examples/pnote tests/test_mapedit.mojo

from std.testing import assert_equal, assert_true
from mojoui.buzanmap import BuzanMap, wrap_text
from mojoui.notesshell import Boxes
from mojoui.scene import Scene
from pnlook import skin_named

comptime W: Float64 = 1000
comptime H: Float64 = 700


def made() -> BuzanMap:
    var m = BuzanMap()
    _ = m.add(-1, "Book", 0, 0, 0xFF0000FF, "root", 28, True, "hand")
    _ = m.add(0, "Characters", 280, -130, 0xFF00FF00, "a", 22, True, "hand")
    _ = m.add(1, "Hero", 520, -180, 0xFF00FF00, "b", 19, False, "hand")
    _ = m.add(0, "Places", -280, 90, 0xFFFF0000, "c", 22, True, "hand")
    m.freeze()
    return m^


def screen(m: BuzanMap, i: Int) -> Tuple[Float64, Float64]:
    var v = m.view(W, H)
    return (v[1] + m.topics[i].x * v[0], v[2] + m.topics[i].y * v[0])


def names(m: BuzanMap) -> String:
    var out = String("")
    for i in range(len(m.topics)):
        out += m.topics[i].text + ("<" + m.topics[m.topics[i].parent].text if m.topics[i].parent >= 0 else String("")) + " "
    return out


def words_as_the_web() raises:
    """layout.js and model.js: the words in their own size (20 when a document gives none, the root's too), wrapped past 28
    letters, an emoji before them, "clean" in IBM Plex Sans."""
    var m = BuzanMap()
    _ = m.add(-1, "Week plan for the move to the new apartment", 0, 0, 0xFF0000FF, "root", 28, True, "hand")
    _ = m.add(0, "Call the bank", 300, 0, 0xFF0000FF, "a", 19, False, "clean", '"emoji":"🏦","due":"2026-11-24"')
    _ = m.add(0, "Old", -300, 0, 0xFF0000FF, "b")
    var l = wrap_text(m.topics[0].words())
    assert_equal(len(l), 2)
    assert_equal(l[0], "Week plan for the move to")
    assert_equal(l[1], "the new apartment")
    assert_equal(m.card_size(0)[1], 76 + 34)
    assert_equal(m.topics[1].words(), "🏦 Call the bank")
    assert_equal(m.label_style(1).family, "IBM Plex Sans")
    assert_equal(m.card_size(1)[1], 39)
    assert_equal(m.idea_size(2), 20)
    assert_equal(m.label_style(0).size, 28)
    assert_equal(m.label_style(0).family, "Source Serif 4")
    var long = wrap_text("abcdefghijklmnopqrstuvwxyzabcdefgh ij")
    assert_equal(len(long), 2)
    assert_equal(long[0], "abcdefghijklmnopqrstuvwxyzab")
    assert_equal(long[1], "cdefgh ij")
    # what is drawn: the root's words at 28 in both lines; the selection ring's dashes reach round its corners
    var sc = Scene(1000, 700, 1)
    var bx = Boxes()
    m.freeze()
    m.draw(sc, bx, 0, 0, W, H, 1.0, skin_named("paper"), "x")
    var drawn = String("|".join(sc.texts))
    assert_true("Week plan for the move to|" in drawn and "the new apartment" in drawn and "🏦 Call the bank" in drawn, drawn)


def writing() raises:
    """An idea's words written in the web's box: a caret, the arrows, words, copy, undo, the pointer; the root's too."""
    var m = made()
    m.begin_edit(0)
    assert_true(m.edit_all, "all selected")
    for c in ["B", "i", "g"]:
        assert_equal(m.edit_key(String(c), 0), 1)
    assert_equal(m.edit_text, "Big")
    _ = m.edit_key("Home", 0)
    _ = m.edit_key("A", 0)
    _ = m.edit_key(" ", 0)
    assert_equal(m.edit_text, "A Big")
    _ = m.edit_key("z", 2)
    assert_true(m.edit_text != "A Big", "its own undo")
    _ = m.edit_key("z", 3)
    assert_equal(m.edit_text, "A Big")
    m.edit_insert(" é")
    assert_equal(m.edit_text, "A  éBig")
    var sc = Scene(1000, 700, 1)
    var bx = Boxes()
    m.draw(sc, bx, 0, 0, W, H, 0, skin_named("paper"), "x")
    var at = bx.find("map.editor")
    assert_true(at >= 0 and m.edit_caret[0] > bx.r[at * 4] and m.edit_caret[0] < bx.r[at * 4] + bx.r[at * 4 + 2], "a caret in the box")
    assert_true("A  éBig" in String("|".join(sc.texts)) and bx.find("map.add-branch:top") < 0, "what is written shows; no handles meanwhile")
    var by = bx.r[at * 4 + 1] + bx.r[at * 4 + 3] / 2
    assert_true(m.edit_press(bx.r[at * 4] + 4, by, W, H, False, False), "a click in the box")
    assert_true(m.pen.ed.caret.byte == 0 and m.editing == 0, "puts the caret there")
    assert_true(m.edit_drag(bx.r[at * 4] + bx.r[at * 4 + 2] - 4, by, W, H) and m.edit_all, "a drag selects")
    m.pen.release()
    assert_true(not m.edit_press(5, 5, W, H, False, False), "a click elsewhere isn't its")
    _ = m.edit_key("End", 0)
    for _ in range(9):
        m.edit_insert("longer ")
    m.draw(sc, bx, 0, 0, W, H, 0, skin_named("paper"), "x")
    assert_true(m.pen_scroll > 0 and m.edit_caret[0] < bx.r[at * 4] + bx.r[at * 4 + 2] - 2, "long words scroll under the caret")
    _ = m.edit_key("Home", 0)
    m.draw(sc, bx, 0, 0, W, H, 0, skin_named("paper"), "x")
    assert_true(m.pen_scroll == 0 and m.edit_caret[0] >= bx.r[at * 4] + 2, "and back")
    _ = m.edit_key("a", 2)
    m.edit_insert("A  éBig")
    assert_equal(m.edit_key("Enter", 0), 2)
    assert_equal(m.topics[0].text, "A éBig")
    assert_true(m.undo() and m.topics[0].text == "Book", "one step of the map")


def main() raises:
    var m = made()
    for i in range(4):
        var s = screen(m, i)
        assert_equal(m.hit(s[0], s[1], W, H), i)
        m.press(s[0], s[1], W, H)
        assert_true(not m.release(), "a click moves nothing")
        assert_equal(m.selected, i)
    assert_equal(m.hit(5, 5, W, H), -1)
    assert_true(not m.past.can_undo(), "selecting isn't a step")
    # a move: one step; its child stays (the web's), undo, redo
    var s = screen(m, 1)
    var v = m.view(W, H)
    m.press(s[0], s[1], W, H)
    assert_true(not m.drag_to(s[0] + 5, s[1], W, H), "7 px of slack")
    assert_true(m.drag_to(s[0] + 60, s[1] + 30, W, H) and m.drag_to(s[0] + 120, s[1] + 60, W, H) and m.release(), "moves")
    assert_true(abs(m.topics[1].x - (280 + 120 / v[0])) < 1e-6 and m.topics[2].x == 520, "with the pointer")
    assert_true(m.undo() and m.topics[1].x == 280 and m.redo() and m.topics[1].x > 280 and m.undo(), "undo, redo")
    # deleting takes what is under it; the central idea stays
    m.selected = 1
    assert_true(m.delete_selected(), "deleted")
    assert_equal(names(m), "Book Places<Book ")
    assert_equal(m.selected, 0)
    assert_true(not m.delete_selected(), "never the central one")
    assert_true(m.undo(), "back")
    assert_equal(names(m), "Book Characters<Book Hero<Characters Places<Book ")
    assert_equal(m.topics[2].id, "b")
    # adding and writing are steps; an Escape writes nothing
    m.selected = 3
    var n = m.add_idea(False)
    assert_true(n == 4 and m.editing == 4, "a new idea, being written")
    for c in "Rome".codepoint_slices():
        _ = m.edit_key(String(c), 0)
    assert_equal(m.edit_key("Enter", 0), 2)
    assert_equal(m.topics[4].text, "Rome")
    m.begin_edit(4)
    _ = m.edit_key("x", 0)
    _ = m.edit_key("Escape", 0)
    assert_equal(m.topics[4].text, "Rome")
    assert_true(m.undo() and m.topics[4].text == "New idea" and m.undo() and len(m.topics) == 4, "a step each")
    assert_true(m.redo() and m.redo() and m.topics[4].text == "Rome" and not m.redo(), "and forward")
    # the view: zoom keeps what is under the pointer, has ends; a pan moves it; Fit shows it all again
    var p = screen(m, 2)
    m.zoom_at(m.view(W, H)[0] * 1.5, p[0], p[1], W, H)
    var q = screen(m, 2)
    assert_true(abs(p[0] - q[0]) < 1e-6 and abs(p[1] - q[1]) < 1e-6 and m.hit(p[0], p[1], W, H) == 2, "about the pointer")
    m.zoom_at(99, 10, 10, W, H)
    assert_true(abs(m.view(W, H)[0] - 2.2) < 1e-9, "220 % at most")
    m.zoom_at(0.0001, 10, 10, W, H)
    assert_true(abs(m.view(W, H)[0] - 0.25) < 1e-9, "25 % at least")
    m.fit_again()
    var f = m.view(W, H)
    m.press(5, 5, W, H)
    assert_true(m.drag_to(105, 55, W, H) and not m.release(), "a pan isn't a change")
    var g = m.view(W, H)
    assert_true(abs(g[1] - f[1] - 100) < 1e-6 and abs(g[2] - f[2] - 50) < 1e-6 and g[0] == f[0], "moved")
    m.fit_again()
    assert_true(m.view(W, H)[1] == f[1], "fit")
    m.press(5, 5, W, H)
    _ = m.release()
    assert_equal(m.selected, -1)  # (a click on the sheet)
    assert_true(m.add_idea(False) == -1 and not m.delete_selected(), "nothing selected: nothing to do")
    words_as_the_web()
    writing()
    print("mapedit: ok")
