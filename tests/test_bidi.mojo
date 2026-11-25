# Right to left and mixed lines (mojoui.bidi; goal 79, gap 81): levels and order against ICU's (Chrome's) on random lines (Linux;
# tests/bidi_icu.py writes build/bidi.txt), known lines by hand, and the caret, a press and a selection as properties.
#   python3 tests/bidi_icu.py 40000 > build/bidi.txt
#   pixi run mojo build -I . -I vendor tests/test_bidi.mojo -o build/test_bidi && build/test_bidi
from std.testing import assert_true, assert_equal
from mojoui.files import file_exists
from mojoui.bidi import BidiData, BidiLine, bidi_levels, line_levels, needs_bidi, visual_runs, _removed


def chars(text: String) -> List[Int]:
    var out = List[Int]()
    for c in text.codepoints():
        out.append(Int(c.to_u32()))
    return out^


def joined(v: List[Int]) -> String:
    var s = String("")
    for x in v:
        s += ("," if s != "" else "") + String(x)
    return s


def order(levels: List[Int]) -> List[Int]:
    var out = List[Int]()
    for r in visual_runs(levels):
        if r.level & 1:
            for i in range(r.end - 1, r.start - 1, -1):
                out.append(i)
        else:
            for i in range(r.start, r.end):
                out.append(i)
    return out^


def against(data: BidiData, file: String, strict: Bool) raises -> Int:
    """Strict: the levels themselves (Unicode's own lines), else each character's way (ICU gives a line all of one way one level)."""
    var t: String
    with open(file, "r") as f:
        t = f.read()
    var n = 0
    for line in t.split("\n"):
        var p = String(line).split(" ")
        if len(p) < 5:
            continue
        var cs = List[Int]()
        for h in String(p[2]).split(","):
            cs.append(atol(String(h), 16))
        var b = bidi_levels(cs, data, Int(String(p[0])))
        assert_equal(b.base, Int(String(p[1])), String(line))
        var want = List[Int]()
        for x in String(p[3]).split(","):
            want.append(Int(String(x)))
        var ll = line_levels(b, 0, len(cs))  # (ICU's have the end of the paragraph's line in them)
        for i in range(len(cs)):  # (what the algorithm takes out has whatever level a program likes)
            if not _removed(b.cls[i]) and (ll[i] != want[i] if strict else ll[i] & 1 != want[i] & 1):
                raise Error("levels of " + String(line) + " are " + joined(ll) + " (at " + String(i) + ")")
        var mine = List[Int]()
        var theirs = List[Int]()
        var kept = List[Int]()
        var where = List[Int]()
        for i in range(len(cs)):
            if not _removed(b.cls[i]):
                kept.append(ll[i])
                where.append(i)
        for i in order(kept):
            mine.append(where[i])
        for x in String(p[4]).split(","):
            if String(x) != "-" and not _removed(b.cls[Int(String(x))]):
                theirs.append(Int(String(x)))
        assert_equal(joined(mine), joined(theirs), String(line))
        n += 1
    return n


def line(data: BidiData, text: String, base: Int = -1) -> BidiLine:
    """Every character 10 wide, marks 0."""
    var cs = chars(text)
    var b = bidi_levels(cs, data, base)
    var w = List[Float64]()
    for i in range(len(cs)):
        w.append(0.0 if b.cls[i] == 8 or _removed(b.cls[i]) else 10.0)
    return BidiLine(b, 0, len(cs), w)


def spans(l: BidiLine, a: Int, b: Int) -> String:
    var s = String("")
    for x in l.spans(a, b):
        s += String(Int(x[0])) + "-" + String(Int(x[1])) + " "
    return s


def by_hand(data: BidiData) raises:
    var h = line(data, "שלום")  # (Hebrew alone: from the right)
    assert_equal(h.base, 1)
    assert_true(h.caret_x(0) == 40 and h.caret_x(1) == 30 and h.caret_x(4) == 0)
    assert_true(h.at(36) == 0 and h.at(33) == 1 and h.at(-5) == 4 and h.at(90) == 0)
    assert_equal(spans(h, 0, 2), "20-40 ")
    assert_true(h.moved(0, False) == 1 and h.moved(0, True) == -1 and h.moved(4, True) == 3)
    var a = line(data, "مرحبا")
    assert_true(a.base == 1 and a.caret_x(0) == 50 and a.at(1) == 5)
    var m = line(data, "ab שלום cd")  # (Hebrew in an English line: 3..6 stand from 70 back to 30)
    assert_equal(m.base, 0)
    assert_true(m.caret_x(0) == 0 and m.caret_x(2) == 20 and m.caret_x(10) == 100)
    assert_true(m.caret_x(4) == 60 and m.caret_x(6) == 40)
    assert_true(m.caret_x(3) == 30, "between the two, where English goes on")
    assert_true(m.caret_x(7) == 70 and m.caret_x(7, True) == 30)
    assert_true(m.at(68) == 3 and m.at(62) == 4 and m.at(31) == 7 and m.at(12) == 1)
    assert_equal(spans(m, 0, 5), "0-30 50-70 ")
    assert_equal(spans(m, 4, 9), "30-60 70-90 ")
    assert_equal(spans(m, 0, 10), "0-100 ")
    var n = line(data, "עמוד 123 כאן")  # (a number in Hebrew runs left to right)
    assert_true(n.base == 1 and n.caret_x(0) == 120 and n.caret_x(6) == 50 and n.caret_x(7) == 60)
    var e = line(data, "abc אב", 1)  # (an English word first in a paragraph that goes right to left)
    assert_true(e.base == 1 and e.x0[0] == 30 and e.x0[5] == 0)
    var p = line(data, "(אב)", 0)
    assert_true(p.x0[0] == 0 and p.x0[3] == 30 and p.x0[1] == 20)
    var v = line(data, "שָׁ")  # (its points belong to it)
    assert_true(v.caret_x(1) == v.caret_x(0) and v.at(2) == 3 and v.at(8) == 0)
    var empty = line(data, "")
    assert_true(empty.caret_x(0) == 0 and empty.at(4) == 0 and len(empty.spans(0, 0)) == 0)


def properties(data: BidiData) raises -> Int:
    """On ICU's lines: carets stand at edges, a press at a character's edge means the place whose caret may stand there, a
    selection covers just its characters, all of it all of the line, arrows go through without stopping."""
    var t: String
    with open("build/bidi.txt", "r") as f:
        t = f.read()
    var n = 0
    for row in t.split("\n"):
        var p = String(row).split(" ")
        if len(p) < 5:
            continue
        n += 1
        if n > 8000:
            break
        var cs = List[Int]()
        for h in String(p[2]).split(","):
            cs.append(atol(String(h), 16))
        var b = bidi_levels(cs, data, Int(String(p[0])))
        var w = List[Float64]()
        for i in range(len(cs)):
            w.append(0.0 if b.cls[i] == 8 or _removed(b.cls[i]) else Float64(4 + (i * 7) % 9))
        var l = BidiLine(b, 0, len(cs), w)
        var total = 0.0
        for x in w:
            total += x
        assert_true(abs(l.width - total) < 1e-6)
        for i in range(len(cs)):
            if not l.head[i] or w[i] == 0:
                continue
            var z = i + 1
            while z < len(cs) and not l.head[z]:
                z += 1
            var rtl = l.level[i] & 1 == 1
            if l.x0[i] > 0 and l.x1[i] < l.width:
                assert_equal(l.at(l.x0[i] + 0.4), z if rtl else i, String(row))
                assert_equal(l.at(l.x1[i] - 0.4), i if rtl else z, String(row))
            var cx = l.caret_x(i)
            var edge = False
            for k in range(len(cs)):
                edge = edge or abs(cx - l.x0[k]) < 1e-6 or abs(cx - l.x1[k]) < 1e-6
            assert_true(edge, String(row))
        for k in range(6):
            var f = (k * 5 + n) % (len(cs) + 1)
            var e = (k * 11 + n * 3) % (len(cs) + 1)
            if f > e:
                swap(f, e)
            var want = 0.0
            for i in range(f, e):
                want += w[i]
            var got = 0.0
            var last = -1.0
            for s in l.spans(f, e):
                assert_true(s[0] > last and s[1] > s[0], String(row))
                got += s[1] - s[0]
                last = s[1]
            assert_true(abs(got - want) < 1e-6, String(row) + " " + String(f) + " " + String(e))
        var at = l.at(-1)
        var steps = 0
        var x = l.caret_x(at)
        while True:
            var next = l.moved(at, True)
            if next < 0:
                break
            assert_true(l.caret_x(next) > x, String(row))
            x = l.caret_x(next)
            at = next
            steps += 1
            assert_true(steps <= len(cs), String(row))
    return n


def test_needs() raises:
    for s in ["", "plain words", "naïve – “quoted” … €", "語", "emoji"]:
        assert_true(not needs_bidi(s), s)
    for s in ["א", "a ب c", "a‏b", "a‮b", "⁧x"]:
        assert_true(needs_bidi(s), s)


def main() raises:
    var data = BidiData()
    by_hand(data)
    test_needs()
    if file_exists("build/bidi-ucd.txt"):
        print("   ", against(data, "build/bidi-ucd.txt", True), "of Unicode's own conformance lines")
    if file_exists("build/bidi.txt"):
        print("   ", properties(data), "lines' carets, presses and selections")
        print("   ", against(data, "build/bidi.txt", False), "lines as ICU has them")
    else:
        print("    build/bidi.txt isn't there (tests/bidi_icu.py): not held against ICU")
    print("bidi: ok")
