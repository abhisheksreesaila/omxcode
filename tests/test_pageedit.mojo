# A page note is edited as a text editor is (goal 79, docs/goals/79-gaps.md 17–24, 27): wrapping at the sheet's width,
# scrolling with the caret in view, selection by keys and pointer, words, copy and cut, undo and redo of words and ink in
# one history, Tab. No display: drawn into a Scene.
#   pixi run mojo run -I . tests/test_pageedit.mojo

from std.testing import assert_equal, assert_true
from mojoui.pagesheet import PageSheet, PAGE_SELECTION
from mojoui.textedit import Pos
from mojoui.notesshell import Boxes
from mojoui.scene import Scene
from mojoui.canvas import rgba

comptime SHIFT = 1
comptime CTRL = 2
comptime W: Float64 = 1200
comptime H: Float64 = 800


def drawn(mut p: PageSheet) -> Scene:
    var sc = Scene(1200, 800, 1.0)
    var bx = Boxes()
    p.draw(sc, bx, 10, 66, W - 12, H - 12, 1, "", rgba(255, 255, 255), 14)
    return sc^


def keys(mut p: PageSheet, names: List[String], mods: Int = 0):
    for n in names:
        _ = p.key(n, mods, 1000)


def sel_rects(sc: Scene) -> Int:
    var n = 0
    for k in range(len(sc.colors)):
        if sc.colors[k] == PAGE_SELECTION:
            n += 1
    return n


def test_wraps() raises:
    var words = String("")
    for i in range(120):
        words += "wandering" + String(i) + (" " if i % 7 != 0 else "-")
    words += "x" * 300  # (no place to break: cut anywhere)
    words += " 日本語の文章はどこでも折り返せます。" * 12
    var p = PageSheet()
    p.set_markdown("# Title\n" + words + "\nshort")
    _ = drawn(p)
    assert_equal(len(p.laid[0].lines), 1)
    assert_equal(len(p.laid[2].lines), 1)
    ref ls = p.laid[1].lines
    assert_true(len(ls) > 12, String(len(ls)))
    var back = String("")
    for k in range(len(ls)):
        assert_true(ls[k].end > ls[k].start, "every line holds something")
        var text = String(words[byte=ls[k].start:ls[k].end])
        back += text
        var wide = p.width_of(p.laid[1].segs, ls[k].start, ls[k].end)
        assert_true(wide <= p.text_w + 0.01, "line " + String(k) + " fits: " + String(wide))
        if k > 0:
            assert_equal(ls[k].start, ls[k - 1].end)
            assert_true(abs(ls[k].top - ls[k - 1].top - ls[k - 1].height) < 0.001, "lines stack")
            assert_true(not text.startswith(" "), "a line doesn't start with the space it broke after")
    assert_equal(back, words)
    assert_true(abs(p.tops[2] - p.tops[1] - p.laid[1].height) < 0.001, "the next line of Markdown comes under all of them")
    # a bold run that crosses a wrap keeps its words
    var q = PageSheet()
    q.set_markdown("plain words here and **" + "bold words " * 20 + "end** and after")
    _ = drawn(q)
    assert_true(len(q.laid[0].lines) >= 3, "wraps")
    # an edit lays out only what changed, a different width all
    p.ed.move_to(Pos(2, 5), False)
    p.insert("!")
    _ = drawn(p)
    assert_equal(p.laid[2].text, "short!")


def test_caret_moves() raises:
    var p = PageSheet()
    p.set_markdown("The first line is here\n" + "many words that go on and on " * 12 + "\nlast")
    _ = drawn(p)
    var n = len(p.laid[1].lines)
    assert_true(n >= 3, "wrapped")
    p.ed.move_to(Pos(0, 10), False)
    keys(p, ["ArrowDown"])
    assert_equal(p.ed.caret.para, 1)
    var x0 = p.x_at(0, 0, 10)
    var x1 = p.x_at(1, 0, p.ed.caret.byte)
    assert_true(abs(x0 - x1) < 10, "down keeps the x")
    for _ in range(n):
        keys(p, ["ArrowDown"])
    assert_equal(p.ed.caret.para, 2)
    keys(p, ["ArrowDown"])
    assert_true(p.ed.caret == Pos(2, 4), "past the last line: the end")
    for _ in range(n + 1):
        keys(p, ["ArrowUp"])
    assert_equal(p.ed.caret.para, 0)
    keys(p, ["ArrowUp"])
    assert_true(p.ed.caret == Pos(0, 0), "past the first line: the start")
    p.ed.move_to(Pos(1, p.laid[1].lines[1].start + 4), False)  # Home and End go by the shown line
    keys(p, ["End"])
    assert_equal(p.ed.caret.byte, p.laid[1].lines[1].end)
    var at = p.ed.caret.copy()
    assert_equal(p.vline_of(at, p.at_end), 1)
    keys(p, ["Home"])
    assert_equal(p.ed.caret.byte, p.laid[1].lines[1].start)
    keys(p, ["Home", "End"], CTRL)
    assert_true(p.ed.caret == Pos(2, 4), "Ctrl+End")
    keys(p, ["ArrowLeft"], CTRL)
    assert_true(p.ed.caret == Pos(2, 0), "by a word")


def test_selection_and_clipboard() raises:
    var p = PageSheet()
    p.set_markdown("alpha beta\ngamma delta\nend")
    assert_equal(sel_rects(drawn(p)), 0)
    p.ed.move_to(Pos(0, 6), False)
    keys(p, ["ArrowDown"], SHIFT)
    assert_true(p.ed.has_selection() and p.ed.sel_start() == Pos(0, 6) and p.ed.sel_end().para == 1, "Shift+Down")
    assert_equal(sel_rects(drawn(p)), 2)
    assert_equal(p.key("c", CTRL, 0), 1)
    assert_true(p.ed.clip.startswith("beta\n"), p.ed.clip)
    var clip = p.ed.clip
    assert_equal(p.key("x", CTRL, 0), 2)
    assert_equal(p.ed.clip, clip)
    assert_equal(len(p.ed.paras), 2)
    p.insert(clip)  # (the host's paste)
    assert_equal(p.markdown(), "alpha beta\ngamma delta\nend")
    assert_equal(p.key("v", CTRL, 0), 0)  # (the host's own paste follows)
    keys(p, ["a"], CTRL)
    assert_equal(p.ed.selected_text(), p.markdown())
    _ = p.key("Z", 0, 0)  # typing over a selection
    assert_equal(p.markdown(), "Z")
    _ = p.key("z", CTRL, 0)
    assert_equal(p.markdown(), "alpha beta\ngamma delta\nend")
    # pointer: press, drag, release; a double click's word; a triple click's line; Shift+click
    _ = drawn(p)
    var y0 = p.tops[0] + 10
    var y1 = p.tops[1] + 10
    assert_true(p.press(p.text_x + p.x_at(0, 0, 2), y0, False), "on words")
    assert_true(p.drag(p.text_x + p.x_at(1, 0, 5), y1), "drags")
    assert_equal(p.ed.selected_text(), "pha beta\ngamma")
    assert_true(p.release() and not p.drag(0, 0), "released")
    assert_true(p.tap(p.text_x + p.x_at(0, 0, 8), y0) and not p.ed.has_selection(), "a tap puts the caret")
    assert_true(p.select_word(p.text_x + p.x_at(0, 0, 8), y0), "a word")
    assert_equal(p.ed.selected_text(), "beta")
    assert_true(p.select_para(p.text_x + 5, y1), "a line")
    assert_equal(p.ed.selected_text(), "gamma delta")
    assert_true(p.tap(p.text_x + p.x_at(0, 0, 1), y0), "")
    assert_true(p.press(p.text_x + p.x_at(0, 0, 5), y0, False) and p.extend_tap(p.text_x + p.x_at(0, 0, 5), y0), "Shift+click")
    assert_equal(p.ed.selected_text(), "lpha")
    assert_true(not p.press(p.text_x + 500, y0, False) and not p.press(p.text_x, p.tops[2] + 300, False), "off the words: the web starts a mark")
    # nothing typed: an input method's composition isn't text
    p.preedit = "かな"
    _ = drawn(p)
    assert_equal(p.markdown(), "alpha beta\ngamma delta\nend")


def test_undo() raises:
    var p = PageSheet()
    p.set_markdown("one")
    for c in " two".codepoint_slices():
        _ = p.key(String(c), 0, 1000)
    _ = p.key("Enter", 0, 5000)
    _ = p.key("x", 0, 9000)
    assert_equal(p.markdown(), "one two\nx")
    _ = drawn(p)
    p.mark_press(400, 300)
    p.mark_move(420, 310)
    assert_true(p.mark_release(), "a mark")
    _ = p.key("y", 0, 20000)
    assert_equal(p.key("z", CTRL, 0), 2)  # the y
    assert_equal(p.markdown(), "one two\nx")
    assert_equal(len(p.ink.marks), 1)
    assert_equal(p.key("z", CTRL, 0), 2)  # the mark
    assert_equal(len(p.ink.marks), 0)
    assert_equal(p.markdown(), "one two\nx")
    _ = p.key("z", CTRL, 0)
    _ = p.key("z", CTRL, 0)
    assert_equal(p.markdown(), "one two")
    _ = p.key("z", CTRL, 0)
    assert_true(p.markdown() == "one" or p.markdown() == "one ", p.markdown())
    for _ in range(6):
        _ = p.key("y", CTRL, 0)
    assert_equal(p.markdown(), "one two\nxy")
    assert_equal(len(p.ink.marks), 1)
    assert_equal(p.key("y", CTRL, 0), 1)  # nothing more
    p.set_markdown("another")
    assert_equal(p.key("z", CTRL, 0), 1)  # another note's history isn't this one's
    assert_equal(p.markdown(), "another")


def test_tab() raises:
    var p = PageSheet()
    p.set_markdown("a\nb\nc")
    p.ed.move_to(Pos(0, 1), False)
    assert_equal(p.key("Tab", 0, 0), 2)
    assert_equal(p.markdown(), "  a\nb\nc")
    assert_true(p.ed.caret == Pos(0, 3), "the caret stays with its letter")
    p.ed.move_to(Pos(0, 0), False)
    p.ed.move_to(Pos(1, 1), True)
    _ = p.key("Tab", 0, 0)
    assert_equal(p.markdown(), "    a\n  b\nc")
    _ = p.key("Tab", SHIFT, 0)
    _ = p.key("Tab", SHIFT, 0)
    assert_equal(p.markdown(), "a\nb\nc")
    _ = p.key("z", CTRL, 0)
    assert_equal(p.markdown(), "  a\nb\nc")


def test_scroll() raises:
    var p = PageSheet()
    var md = String("top")
    for i in range(200):
        md += "\nline " + String(i)
    p.set_markdown(md)
    _ = drawn(p)
    assert_equal(p.scroll, 0)  # (opened at its top, the caret at its end, as the web)
    assert_true(p.wheel(300) and p.scroll == 300, "wheel")
    assert_true(p.wheel(1e9), "to the end")
    var most = p.scroll
    assert_true(not p.wheel(50) and p.scroll == most, "and no further")
    assert_true(abs(most - (p.content_h - p.view_h)) < 0.01, "the end")
    _ = p.wheel(-1e9)
    _ = p.key("ArrowLeft", 0, 0)  # the caret moved at the end: brought into view
    _ = drawn(p)
    assert_true(p.caret_rect[1] > 66 and p.caret_rect[1] < H - 12, "in view: " + String(p.caret_rect[1]))
    _ = p.key("Home", CTRL, 0)
    _ = drawn(p)
    assert_true(p.caret_rect[1] > 66 + 60 and p.caret_rect[1] < H - 12, "and at the top: " + String(p.caret_rect[1]))
    _ = p.wheel(2000)
    var sc = drawn(p)
    var runs = len(sc.kinds)
    var q = PageSheet()
    for _ in range(2000):
        md += "\nmore"
    q.set_markdown(md)
    _ = drawn(q)
    _ = q.wheel(2000)
    var sc2 = drawn(q)
    assert_true(len(sc2.kinds) < runs + 60, "only the lines in view are drawn: " + String(len(sc2.kinds)) + " against " + String(runs))
    p.set_markdown("x")
    _ = drawn(p)
    assert_equal(p.scroll, 0)


def test_styles() raises:
    var p = PageSheet()
    p.set_markdown("a ~~gone~~ and [words](http://x.y) end\n```py\nx = **1**\n```\n**b**")
    _ = drawn(p)
    var joined = String("")
    for ref s in p.laid[0].segs:
        joined += s.text
    assert_equal(joined, p.ed.paras[0])
    assert_true(p.laid[0].segs[2].text == "gone" and p.laid[0].segs[2].strike and not p.laid[0].segs[4].strike, "struck")
    assert_true(p.laid[0].segs[6].text == "words" and p.laid[0].segs[6].color != p.laid[0].segs[4].color, "a link's words")
    assert_true(len(p.laid[2].segs) == 1 and p.laid[2].segs[0].style.family == "Geist Mono" and p.laid[4].segs[1].text == "b", "code is code, what follows isn't")
    p.ed.move_to(Pos(1, 0), False)
    p.insert("x")  # (no fence any more: the line after the other fence is code now)
    _ = drawn(p)
    assert_true(len(p.laid[2].segs) > 1 and len(p.laid[4].segs) == 1, "followed at once")


def main() raises:
    test_styles()
    test_wraps()
    test_caret_moves()
    test_selection_and_clipboard()
    test_undo()
    test_tab()
    test_scroll()
    print("pageedit: ok")
