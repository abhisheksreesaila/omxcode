# mojoui.wordcard (goal 77 M2): the Word card an agent builds with render_ui: validated, its parts tagged on the view, its
# parts' names for the pointer, the example's word emphasised.
from std.testing import assert_equal, assert_true
from mojoui.genui import GenUi, validate, sample
from mojoui.jsonpatch import JDoc
from mojoui.pointer import match_clause
from mojoui.view import View
from mojoui.wordcard import emphasised, word_size, word_width


def names_in(v: View) -> List[String]:
    var out = List[String]()
    for i in range(len(v.nodes)):
        if v.nodes[i].name != "":
            out.append(v.nodes[i].name)
    return out^


def has(names: List[String], want: String) -> Bool:
    for n in names:
        if n == want:
            return True
    return False


def main() raises:
    # the catalog takes it; a bad one is refused with the reason
    assert_equal(validate(sample("WordCard")), "")
    assert_true(validate('{"ui":{"component":"WordCard","word":"hi"}}').startswith("bad prop: /ui: WordCard needs \"meaning\""))
    assert_true(validate('{"ui":{"component":"WordCard","word":"hi","meaning":"a greeting","colour":"red"}}').startswith("bad prop"))
    var ui = GenUi(sample("WordCard"), 100, 10)
    ui.card = "card3"
    var shown = ui.view(JDoc(), 0)
    var names = names_in(shown)
    for part in ["word", "sounds", "meaning", "example", "origin"]:
        assert_true(has(names, "card3." + part), "the view carries a tag for " + part)
    # the pointer's parts: all five, tagged the same way
    var parts = ui.parts()
    assert_equal(len(parts), 5)
    assert_equal(parts[0].tag(), "card3.word")
    assert_equal(parts[1].tag(), "card3.meaning")
    # a card without a pronunciation or an origin offers neither
    var plain = GenUi('{"ui":{"component":"WordCard","word":"hush","meaning":"Quiet; be silent."}}', 100, 10)
    plain.card = "card1"
    assert_equal(len(plain.parts()), 3)
    assert_true(not has(names_in(plain.view(JDoc(), 0)), "card1.origin"))
    # speech about the card lands on its parts, in the order spoken
    var hits = match_clause("Ephemeral means lasting a very short time.", parts)
    assert_equal(len(hits), 2)
    assert_equal(hits[0].tag(), "card3.word")
    assert_equal(hits[1].tag(), "card3.meaning")
    assert_equal(match_clause("It comes from the Greek word for a day.", parts)[0].tag(), "card3.origin")
    # the example has the word in bold, in whatever case it is written
    var runs = emphasised("The Ephemeral beauty of ephemeral things.", "ephemeral")
    assert_equal(len(runs), 5)
    assert_equal(runs[0].text, "The ")
    assert_equal(runs[1].text, "Ephemeral")
    assert_true(runs[1].bold)
    assert_equal(runs[3].text, "ephemeral")
    assert_true(not runs[0].bold)
    # a long word is set smaller so it still fits a phone's card
    assert_equal(word_size("ephemeral"), 58.0)
    assert_true(word_size("incomprehensibilities") < 40.0)
    assert_true(word_width("serendipity") <= 308)
    print("wordcard: ok")
