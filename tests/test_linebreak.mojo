# mojoui.linebreak: the browser's line breaks between ASCII characters (D-548). browser_breaks equals Chrome's own,
# measured over every pair of printable ASCII characters after a letter, a digit and a full stop
# (tests/fixtures/chrome_ascii_breaks.txt, scripts/linebreak_table.py); css_breaks puts a word joiner where UAX #14
# would break and Chrome doesn't, a zero-width space where Chrome breaks; plain_words takes them out.
from std.testing import assert_equal, assert_true, assert_false
from mojoui.linebreak import browser_breaks, css_breaks, plain_words, css_ends, label_words, WJ, ZWSP
from mojoui.view import Text, HStack, VStack, Button, TEXT
from mojoui.sentence import Sentence, Word


def main() raises:
    var table = open("tests/fixtures/chrome_ascii_breaks.txt", "r").read()
    var checked = 0
    for line in table.split("\n"):
        if line.byte_length() < 2:
            continue
        var pre = Int(line.as_bytes()[0])
        var pairs = String(line[byte=2:])
        var want = List[Bool](length=128 * 128, fill=False)
        var b = pairs.as_bytes()
        for k in range(0, len(b) - 1, 2):
            want[Int(b[k]) * 128 + Int(b[k + 1])] = True
        for x in range(33, 127):
            for y in range(33, 127):
                if browser_breaks(pre, x, y) != want[x * 128 + y]:
                    raise Error("after '" + chr(pre) + "': '" + chr(x) + chr(y) + "' Chrome " + ("breaks" if want[x * 128 + y] else "doesn't"))
                checked += 1
    assert_equal(checked, 3 * 94 * 94)

    # the notebook's path: no break after its slashes, a break after "qwen2.5-" before the digit
    var path = "/tmp/mxc-console-record/mxc/notebooks/qwen2.5-0.5b.ipynb"
    var said = css_breaks(path)
    assert_equal(plain_words(said), path)
    assert_true(said.startswith("/" + WJ + "tmp/" + WJ + "mxc-" + ZWSP + "console-" + ZWSP + "record/" + WJ + "mxc"))
    assert_true(("qwen2.5-" + ZWSP + "0.5b") in said)
    # plain words and non-ASCII text stay as they are; a minus sign keeps its number
    assert_equal(css_breaks("This machine only · "), "This machine only · ")
    assert_equal(css_breaks("rate -5 %"), "rate -5 %")
    assert_equal(css_breaks("café/naïve"), "café/" + WJ + "naïve")
    assert_false(browser_breaks(32, 45, 53))  # " -5"
    assert_equal(plain_words("plain"), "plain")
    # a label's ends: no spaces (a block in white-space: normal, D-549), but a sentence's words keep theirs
    assert_equal(css_ends("This machine only · "), "This machine only ·")
    assert_equal(css_ends("  a b \n"), "a b")
    assert_equal(css_ends("   "), "")
    assert_equal(css_ends("a"), "a")
    var row = VStack(HStack(Text("This machine only · "), Button("Security ›", 1), spacing=0),
                     Sentence([Word("Revenue", 2, "t"), Word(" by month "), Word("Region", 3, "u")]))
    var plain = -1
    var spaced = -1
    for k in range(len(row.nodes)):
        if row.nodes[k].text == "This machine only · ":
            plain = k
        if row.nodes[k].text == " by month ":
            spaced = k
    assert_true(plain >= 0 and spaced >= 0)
    assert_equal(row.nodes[spaced].kind, TEXT)
    assert_equal(label_words(row.nodes, plain), "This machine only ·")
    assert_equal(label_words(row.nodes, spaced), " by month ")
    print("linebreak: ok")
