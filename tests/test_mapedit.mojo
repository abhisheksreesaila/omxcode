# A mind map edited as a person does it (goal 79, docs/goals/79-gaps.md 42–44): clicks, moves, deleting with what is under,
# undo and redo, zoom about the pointer, panning, Fit. No display.
#   pixi run mojo run -I . tests/test_mapedit.mojo

from std.testing import assert_equal, assert_true
from mojoui.buzanmap import BuzanMap

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
    print("mapedit: ok")
