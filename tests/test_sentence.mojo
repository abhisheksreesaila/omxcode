# mojoui.sentence (goal 28 M1): plain runs and tokens on lines that wrap at a word's edge, never inside one; tokens are
# TOKEN buttons with their message and tag; the plain text reads as the sentence.
#   scripts/mxbuild.sh tests/test_sentence.mojo -o build/test_sentence && build/test_sentence
from std.testing import assert_equal, assert_true
from mojoui.view import BUTTON, TEXT, HSTACK, VSTACK, TOKEN
from mojoui.sentence import Word, Sentence, sentence_text, sentence_lines


def words() -> List[Word]:
    return [Word("Sum", 10, "w0"), Word(" of "), Word("amount", 11, "w1"), Word(" by "), Word("region", 12, "w2"), Word(", "),
            Word("largest first", 13, "w3"), Word(", "), Word("top 5", 14, "w4")]


def main() raises:
    assert_equal(sentence_text(words()), "Sum of amount by region, largest first, top 5")
    var one = Sentence(words(), width=80)
    assert_equal(one.nodes[0].kind, VSTACK)
    assert_equal(len(one.nodes[0].children), 1, "it fits one line")
    var tokens = 0
    for n in one.nodes:
        if n.kind == BUTTON:
            assert_equal(n.style, TOKEN)
            tokens += 1
    assert_equal(tokens, 5)
    var narrow = Sentence(words(), width=24)
    var lines = len(narrow.nodes[0].children)
    assert_true(lines >= 2, "a narrow sentence wraps")
    var texts = List[String]()
    for i in range(len(narrow.nodes)):
        if narrow.nodes[i].kind == BUTTON or narrow.nodes[i].kind == TEXT:
            texts.append(narrow.nodes[i].text)
    var joined = String("")
    for t in texts:
        joined += t + "|"
    assert_true("largest first|" in joined, "a token is never split")
    for i in range(len(narrow.nodes)):
        if narrow.nodes[i].kind == HSTACK:  # (a line never starts with a space)
            var first = narrow.nodes[narrow.nodes[i].children[0]].text
            assert_true(not first.startswith(" "), "line starts with '" + first + "'")
    for n in narrow.nodes:
        if n.kind == BUTTON and n.text == "amount":
            assert_equal(n.msg, 11)
            assert_equal(n.name, "w1")
    # sentence_lines counts the lines Sentence draws, at every width (a card sizes its title bar by it, goal 56)
    for width in [4, 10, 16, 24, 48, 200]:
        var drawn = 0
        var v = Sentence(words(), width=width)
        for n in v.nodes:
            if n.kind == HSTACK:
                drawn += 1
        assert_equal(sentence_lines(words(), width), drawn, "width " + String(width))
    assert_equal(sentence_lines(words(), 200), 1)
    assert_true(sentence_lines(words(), 10) >= 4)
    assert_equal(sentence_lines(List[Word](), 10), 0)
    # a run past a comma may break after it: ", as " never glues "as" to a full line (goal 56)
    var chart: List[Word] = [Word("every outcome", 1, "a"), Word(", "), Word("every row", 2, "b"), Word(", as "), Word("bars", 3, "c")]
    var cut = Sentence(chart, width=24)
    var cut_lines = 0
    for n in cut.nodes:
        if n.kind == HSTACK:
            cut_lines += 1
    assert_equal(cut_lines, 2)
    assert_equal(sentence_lines(chart, 24), 2)
    assert_equal(sentence_text(chart), "every outcome, every row, as bars")
    print("SENTENCE TESTS PASSED")
