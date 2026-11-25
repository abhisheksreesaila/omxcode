# A long paragraph (review 4, MUST 5): graphemes found from near by, lines broken as before (the old way, kept here as the
# reference), a key's layout the same as a fresh one's and quick, 500 KB on one line usable.
#   pixi run mojo build -I . -I vendor tests/test_longpara.mojo && ./test_longpara
from std.testing import assert_true, assert_equal
from mojoui.graphemes import prev_grapheme, next_grapheme
from mojoui.docstore import clock_us
from mojoui.pagesheet import PageSheet, Seg, _may_break, seg_starts
from mojoui.textedit import decode_at, Pos
from mojoui.wordsedit import WordsEdit
from mojoui.fonttext import TextStyle

comptime WORDS = "the quick brown fox **jumps** over a *lazy* dog, `code here` and a-very-long/hyphenated_word [a link](https://example.org/a/b?c=d) 漢字かな交じり文。한국어 문장 नमस्ते दुनिया é e\u0301 👩‍👩‍👧‍👦 🇮🇳🇺🇸 👍🏽 pneumonoultramicroscopicsilicovolcanoconiosis"


struct Rng:
    var s: UInt64

    def __init__(out self, seed: Int):
        self.s = UInt64(seed * 2654435761 + 12345)

    def next(mut self, n: Int) -> Int:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return Int((self.s >> 33) % UInt64(n))


def slow_next(text: String, at: Int) -> Int:
    var pos = 0
    for g in text.graphemes():
        pos += g.byte_length()
        if pos > at:
            return pos
    return text.byte_length()


def slow_prev(text: String, at: Int) -> Int:
    var pos = 0
    for g in text.graphemes():
        var n = g.byte_length()
        if pos + n >= at:
            return pos
        pos += n
    return min(pos, at)


def slow_cut(s: PageSheet, words: String, segs: List[Seg], start: Int, end: Int) -> Int:
    var best = slow_next(words, start)
    var i = best
    while i < end:
        i = slow_next(words, i)
        if s.width_of(segs, start, i) > s.text_w:
            break
        best = i
    return best


def slow_wrap(s: PageSheet, words: String, segs: List[Seg]) -> List[Int]:
    """The wrap as it was (every place measured from the line's start)."""
    var cuts: List[Int] = [0]
    var n = words.byte_length()
    if n == 0 or s.width_of(segs, 0, n) <= s.text_w:
        cuts.append(n)
        return cuts^
    var start = 0
    var fits = 0
    var i = 0
    var before = 0
    var x = 0
    while i < n:
        var e = slow_next(words, i)
        var y = decode_at(words, i)
        if i > start and x != 0 and _may_break(before, x, y):
            if s.width_of(segs, start, i) <= s.text_w:
                fits = i
            else:
                if fits <= start:
                    fits = slow_cut(s, words, segs, start, i)
                cuts.append(fits)
                start = fits
                while s.width_of(segs, start, i) > s.text_w:
                    start = slow_cut(s, words, segs, start, i)
                    cuts.append(start)
                fits = i
        before = x
        x = y
        i = e
    while s.width_of(segs, start, n) > s.text_w:
        if fits > start:
            start = fits
        else:
            start = slow_cut(s, words, segs, start, n)
        cuts.append(start)
    cuts.append(n)
    return cuts^


def some_text(mut r: Rng, n: Int) -> String:
    var all = List[String]()
    for w in String(WORDS).split(" "):
        all.append(String(w))
    var t = String("")
    while t.byte_length() < n:
        var k = r.next(len(all) + 3)
        t += all[k] if k < len(all) else String("x") * r.next(120)
        if r.next(12) > 0:
            t += " "
        if r.next(40) == 0:
            t += "   "
    return t


def graphemes() raises:
    var r = Rng(7)
    for _ in range(300):
        var t = some_text(r, 10 + r.next(160))
        for at in range(t.byte_length() + 1):
            assert_equal(next_grapheme(t, at), slow_next(t, at), t + " after " + String(at))
            if at > 0:
                assert_equal(prev_grapheme(t, at), slow_prev(t, at), t + " before " + String(at))
    var big = String("é漢a👩‍👩‍👧 ") * 40_000
    var t0 = clock_us()
    for k in range(2000):
        _ = next_grapheme(big, big.byte_length() // 2 + k)
        _ = prev_grapheme(big, big.byte_length() - k)
    assert_true(clock_us() - t0 < 400_000, "from near by: " + String(clock_us() - t0))
    print("   graphemes")


def lines_text(s: PageSheet, i: Int) -> String:
    var t = String("")
    for l in s.laid[i].lines:
        t += String(l.start) + "-" + String(l.end) + "@" + String(Int(l.top * 64)) + "h" + String(Int(l.height * 64)) + "b" + String(Int(l.base * 64)) + " "
    return t


def sheet(text: String, w: Float64) -> PageSheet:
    var s = PageSheet()
    s.text_w = w
    s.set_markdown(text)
    return s^


def wrapping() raises:
    var r = Rng(11)
    for turn in range(160):
        var w = 60.0 + Float64(r.next(600))
        var t = some_text(r, r.next(1200))
        if turn % 5 == 0:
            t = "## " + t
        if turn % 7 == 0:
            t = "- [ ] " + t
        if turn % 11 == 0:
            t = String("").join([String(c) for c in t.codepoint_slices() if String(c) != " "])
        var s = sheet(t, w)
        _ = s.lay(0)
        var want = slow_wrap(s, t, s.laid[0].segs)
        var got = s.wrap(t, s.laid[0].segs)
        assert_equal(len(got), len(want), "turn " + String(turn) + " width " + String(w) + ": " + t)
        for k in range(len(got)):
            assert_equal(got[k], want[k], "turn " + String(turn) + " line " + String(k) + " width " + String(w) + ": " + t)
    print("   lines broken as before: 160 texts")


def edits() raises:
    var r = Rng(23)
    for turn in range(40):
        var w = 90.0 + Float64(r.next(560))
        var s = sheet(some_text(r, 300 + r.next(3000)), w)
        _ = s.lay(0)
        for step in range(50):
            var para = s.ed.paras[0]
            var n = para.byte_length()
            var a = 0 if n == 0 else prev_grapheme(para, 1 + r.next(n))
            var k = r.next(8)
            if k < 3:
                s.ed.move_to(Pos(0, a), False)
                s.insert(some_text(r, 1 + r.next(6)))
            elif k == 3:
                s.ed.move_to(Pos(0, a), False)
                s.insert("**" if r.next(2) == 0 else "`")
            elif k == 4:
                s.ed.move_to(Pos(0, a), False)
                s.insert("word" if r.next(2) == 0 else " ")
            elif k == 5:
                s.ed.move_to(Pos(0, a), False)
                s.ed.move_to(Pos(0, next_grapheme(para, min(a + r.next(200), max(n - 1, 0))) if n > 0 else 0), True)
                _ = s.key("Delete", 0, 0)
            elif k == 6:
                s.ed.move_to(Pos(0, a), False)
                _ = s.key("Backspace", 0, 0)
            else:
                _ = s.key("z", 2, 0)
            if r.next(4) > 0:  # (some edits go by without a layout between)
                _ = s.lay(0)
                var f = sheet(s.ed.paras[0], w)
                _ = f.lay(0)
                assert_equal(lines_text(s, 0), lines_text(f, 0), "turn " + String(turn) + " step " + String(step))
    print("   a layout built on the one before is a fresh one: 2,000 edits")


def long_words() raises:
    """(review 5) A word longer than a line, changed far inside it: whether it fits again decides a line long before."""
    var r = Rng(41)
    for turn in range(60):
        var w = 90.0 + Float64(r.next(300))
        var s = sheet(String("  ") + ("ab " if r.next(2) == 0 else "") + String("x") * (30 + r.next(200)) + (" tail words here" if r.next(2) == 0 else ""), w)
        _ = s.lay(0)
        for step in range(12):
            var n = s.ed.paras[0].byte_length()
            var a = r.next(n + 1)
            s.ed.move_to(Pos(0, a), False)
            if r.next(3) > 0:
                s.ed.move_to(Pos(0, min(n, a + r.next(120))), True)
                _ = s.key("Delete", 0, 0)
            else:
                s.insert(String("y") * r.next(60) + (" " if r.next(3) == 0 else ""))
            _ = s.lay(0)
            var f = sheet(s.ed.paras[0], w)
            _ = f.lay(0)
            assert_equal(lines_text(s, 0), lines_text(f, 0), "long word, turn " + String(turn) + " step " + String(step))
    print("   words longer than a line")


def per_key(mut s: PageSheet, keys: Int) -> Int:
    """The slowest of `keys` keys typed in the middle, each with its layout and caret (µs)."""
    var n = s.ed.paras[0].byte_length()
    s.ed.move_to(Pos(0, prev_grapheme(s.ed.paras[0], n // 2)), False)
    var worst = 0
    for k in range(keys):
        var t0 = clock_us()
        s.insert("a" if k % 7 < 6 else " ")
        _ = s.lay(0)
        var c = s.ed.caret.copy()
        var at = s.vline_of(c, False)
        _ = s.x_at(0, at, c.byte)
        worst = max(worst, clock_us() - t0)
    return worst


def quick() raises:
    var r = Rng(5)
    var t = some_text(r, 20_000)
    var s = sheet(t, 612)
    var t0 = clock_us()
    _ = s.lay(0)
    var first = clock_us() - t0
    var worst = per_key(s, 60)
    print("   20 KB paragraph: opened in", first // 1000, "ms, a key at most", worst, "us")
    assert_true(worst < 16_900, "a key in 20 KB: " + String(worst) + " us")
    var bare = sheet(String("x") * 20_000, 612)
    t0 = clock_us()
    _ = bare.lay(0)
    first = clock_us() - t0
    worst = per_key(bare, 60)
    print("   20 KB without a space: opened in", first // 1000, "ms, a key at most", worst, "us")
    assert_true(worst < 16_900, "a key in 20 KB of x: " + String(worst) + " us")
    var big = sheet(some_text(r, 500_000), 612)
    t0 = clock_us()
    _ = big.lay(0)
    first = clock_us() - t0
    worst = per_key(big, 20)
    print("   500 KB on one line: opened in", first // 1000, "ms, a key at most", worst, "us")
    assert_true(first < 4_000_000 and worst < 100_000, "500 KB: " + String(first) + " / " + String(worst))
    # a canvas's words: up and down, a press
    var w = WordsEdit()
    var st = TextStyle("Source Serif 4", 400, False, 16)
    st.exact = True
    w.begin(String("x") * 21_000, st, 700)
    t0 = clock_us()
    _ = w.key("ArrowUp", 0, 0)
    w.press(300, 10, 20, False)
    assert_true(clock_us() - t0 < 200_000, "a canvas's 21,000 characters: " + String(clock_us() - t0) + " us")
    print("   a canvas's 21,000 characters:", clock_us() - t0, "us")


def main() raises:
    graphemes()
    wrapping()
    edits()
    long_words()
    quick()
    print("longpara: ok")
