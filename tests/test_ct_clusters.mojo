# Goal 82 integration (D-8907): every glyph the shaper gives carries its cluster, the byte offset in the text it came from,
# on the Mac (CoreText: CTRunGetStringIndices, UTF-16 units mapped to bytes) as on Linux (HarfBuzz). Before, every
# CoreText glyph said cluster 0: goal 80's typing fast path (its pair test needs the second glyph's cluster == 1) never
# switched on there, and the PDF's words fell back to guessing. Checked: known strings' clusters, and the fast path is on
# for plain words (goal 80's tests/test_textfast then proves it places glyphs exactly as the shaper).
#   pixi run mojo run -I . tests/test_ct_clusters.mojo        (and on the Mac through scripts/mac-test)
from std.testing import assert_true, assert_equal
from mojoui.fonttext import TextStyle, Run, engine, fast_shape


def clusters(r: Run) -> List[Int]:
    var out = List[Int]()
    for g in r.glyphs:
        out.append(g.cluster)
    return out^


def show(xs: List[Int]) -> String:
    var s = String("[")
    for i in range(len(xs)):
        s += ("" if i == 0 else ",") + String(xs[i])
    return s + "]"


def main() raises:
    var e = engine()
    var st = TextStyle("Geist", 400, False, 16)
    var want_ab: List[Int] = [0, 1]
    var got = clusters(e[].shape(st, "ab"))
    print("FACT ab", show(got))
    assert_true(got == want_ab, "ab: " + show(got))
    var t = String("Harbour")
    var w = List[Int]()
    for i in range(7):
        w.append(i)
    got = clusters(e[].shape(st, t))
    print("FACT harbour", show(got))
    assert_true(got == w, "Harbour: " + show(got))
    # two-byte letters: a é b → bytes 0, 1, 3
    got = clusters(e[].shape(st, "aéb"))
    print("FACT aeb", show(got))
    var want_aeb: List[Int] = [0, 1, 3]
    assert_true(got == want_aeb, "aéb: " + show(got))
    # an offset inside a longer text: every cluster lies in the text, never before the one before it (left to right)
    var long = String("naïve café — 漢字 and more words")
    var r = e[].shape(st, long)
    var last = -1
    for g in r.glyphs:
        assert_true(g.cluster >= last and g.cluster < long.byte_length(), "a cluster out of order or outside the text: " + String(g.cluster))
        last = g.cluster
    assert_true(last > 20, "the last glyph's cluster is near the end, not 0: " + String(last))
    print("FACT long_last", last)
    # goal 80's fast path is on for plain words now (it needs real clusters)
    var out = Run()
    var fast = 0
    var words: List[String] = ["Harbour", "Quick note", "Inbox 12", "office", "Wolf"]
    for ws in words:
        if fast_shape(st, ws, out):
            fast += 1
    print("FACT fast_words", fast, "of", len(words))
    assert_true(fast >= 3, "the fast path took " + String(fast) + " of " + String(len(words)) + " plain words")
    print("ct_clusters: ok")
