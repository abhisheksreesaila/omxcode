# mojoui.visual (goal 77 M5): which kind of card a turn went for, and what the framework's prompt tells the model.
from std.testing import assert_equal, assert_true
from mojoui.visual import card_kind, VISUAL_SYSTEM
from mojoui.llmagent import compact_catalog


def main() raises:
    assert_equal(card_kind("show_map", ""), "map")
    assert_equal(card_kind("explain", ""), "iso")
    assert_equal(card_kind("todo_add", ""), "todo")
    assert_equal(card_kind("news", ""), "news")
    assert_equal(card_kind("", "WordCard"), "word")
    assert_equal(card_kind("", "Card(Text,Table)"), "table")
    assert_equal(card_kind("", "Card(MapView)"), "map")
    assert_equal(card_kind("", "Card(Text,Meter)"), "other")
    assert_equal(card_kind("", ""), "")
    # the prompt names every card tool it routes to, and asks for show first, then one or two sentences
    var prompt = String(VISUAL_SYSTEM)
    for name in ["WordCard", "show_map", "explain", "Table", "to-do"]:
        assert_true(prompt.find(name) >= 0, name + " is named in the prompt")
    assert_true(prompt.find("FIRST, before you say a word") >= 0)
    assert_true(prompt.find("one or two short sentences") >= 0)
    # the model's catalog says what the WordCard is for and which parts it has (a pointable card's line carries its description)
    var catalog = compact_catalog()
    assert_true(catalog.find("WordCard(word*:text") >= 0)
    assert_true(catalog.find("can point at its parts by name: word, sounds, meaning, example, origin") >= 0)
    print("visual: ok")
