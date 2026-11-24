# mojoui.graphemes and every field that uses it (review 3, MUST 6): é composed and decomposed, an emoji family, flags, skin
# tones, Japanese with voiced marks, Hindi, Korean: the caret and Backspace go a whole character at a time, nothing aborts,
# what is left is whole text. graphemes: ok
from std.testing import assert_true, assert_equal
from mojoui.graphemes import prev_grapheme, next_grapheme, without_last, typed_text
from mojoui.omnibar import Omnibar
from mojoui.pagesheet import PageSheet
from mojoui.buzanmap import BuzanMap
from mojoui.islandcard import IslandCard
from mojoui.pagedesk import BoardTools, DeskView
from mojoui.objectlayer import ObjectLayer
from mojoui.textedit import TextEdit


def whole() -> List[String]:
    return ["a", "é", "é", "👩‍👩‍👧", "🇮🇳", "👍🏽", "が", "が", "नि", "한", "漢", "ß", "​" if False else "ñ", "🏳️‍🌈", "Ạ̊"]


def main() raises:
    var all = String("")
    var ends = List[Int]()
    for g in whole():
        all += g
        ends.append(all.byte_length())
    var at = 0
    for e in ends:
        at = next_grapheme(all, at)
        assert_equal(at, e)
    assert_equal(next_grapheme(all, at), at, "at the end")
    for q in range(len(ends) - 1, -1, -1):
        at = prev_grapheme(all, at)
        assert_equal(at, ends[q - 1] if q > 0 else 0)
    assert_equal(prev_grapheme(all, 0), 0)
    assert_equal(prev_grapheme("", 0), 0)
    assert_equal(without_last(""), "")
    # a caret that stands inside a character (a stale position) lands on a boundary
    for b in range(all.byte_length() + 1):
        var p = prev_grapheme(all, b)
        var n = next_grapheme(all, b)
        assert_true(p == 0 or p in ends, "a boundary")
        assert_true(n in ends, "a boundary")
    assert_true(typed_text("é") and typed_text("a") and typed_text("漢") and typed_text(" ") and not typed_text("Enter") and not typed_text("") and not typed_text("\t"), "what types")
    # the search field: each character typed, then each taken back
    var o = Omnibar()
    for g in whole():
        assert_true(o.query_key(g, 0), "typed " + g)
    assert_equal(o.query, all)
    for q in range(len(ends) - 1, -1, -1):
        assert_true(o.query_key("Backspace", 0))
        assert_equal(o.query, String(all[byte=0:ends[q - 1] if q > 0 else 0]))
    assert_true(not o.query_key("Backspace", 0), "nothing to take")
    assert_true(not o.query_key("a", 2), "Ctrl+A isn't text")
    # a page: typed, Left to the start, Right to the end, Delete and Backspace
    var p = PageSheet()
    p.set_markdown("")
    for g in whole():
        p.insert(g)
    for q in range(len(ends) - 1, -1, -1):
        p.caret_left()
        assert_equal(p.caret_col, ends[q - 1] if q > 0 else 0)
    for e in ends:
        p.caret_right()
        assert_equal(p.caret_col, e)
    for q in range(len(ends) - 1, -1, -1):
        p.backspace()
        assert_equal(p.markdown(), String(all[byte=0:ends[q - 1] if q > 0 else 0]))
    p.set_markdown(all)
    p.caret_home()
    for e in ends:
        p.delete_forward()
        assert_equal(p.markdown(), String(all[byte=e:]))
    # a mind map idea, the title card, a board's text, a text editor
    var m = BuzanMap()
    _ = m.add(-1, "", 0, 0, 0xFF000000)
    m.begin_edit(0)
    for g in whole():
        _ = m.edit_key(g, 0)
    assert_equal(m.edit_text, all)
    for q in range(len(ends) - 1, -1, -1):
        _ = m.edit_key("Backspace", 0)
        assert_equal(m.edit_text, String(all[byte=0:ends[q - 1] if q > 0 else 0]))
    var c = IslandCard()
    c.editing = True
    for g in whole():
        _ = c.title_key(g, 0)
    for q in range(len(ends) - 1, -1, -1):
        _ = c.title_key("Backspace", 0)
        assert_equal(c.title, String(all[byte=0:ends[q - 1] if q > 0 else 0]))
    var l = ObjectLayer()
    var t = BoardTools()
    var v = DeskView(0, 0, 1)
    t.set_tool("text", l, v, 1440, 900, 1, 1)
    _ = t.tap(400, 300, l, v, 1440, 900)
    for g in whole():
        _ = t.key(g, 0, l, v, 1440, 900, 1, 1)
    assert_equal(t.edit_words, all)
    for q in range(len(ends) - 1, -1, -1):
        _ = t.key("Backspace", 0, l, v, 1440, 900, 1, 1)
        assert_equal(t.edit_words, String(all[byte=0:ends[q - 1] if q > 0 else 0]))

    print("graphemes: ok")
