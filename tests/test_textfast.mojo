# Goal 80 M2: text as cheap as a lookup. fonttext's simple-text fast path (printable ASCII learned per style from the
# shaper, glyph by glyph and pair by pair) must place glyphs exactly as the shaper does, and the run cache must hand out
# the shaper's run. For a corpus of ≥ 2 000 strings (words, numbers, prices, dates, code, punctuation, ligature bait,
# mixed case, other scripts and emoji) × every bundled family × 4 sizes × 2 weights:
#   run_for (fast path, cache or shaper) == FontEngine.shape (the shaper, uncached): same glyph ids, faces, clusters,
#   positions within 1/64 px, same width. Then each family's strings asked twice: the second time nothing is shaped.
#   pixi run mojo run -I . tests/test_textfast.mojo
from std.testing import assert_true, assert_equal

from mojoui.fonttext import TextStyle, Run, engine, run_for, fast_shape, FAST_STYLES
from tests.test_gpu2d import Rng

comptime TOL = 1.0 / 64


def corpus() -> List[String]:
    var out = List[String]()
    var words: List[String] = ["Harbour", "Quick", "note", "Inbox", "office", "affine", "flow", "waffle", "fjord", "Wolf",
        "AVAST", "Type", "LTA", "yo", "ff", "ffi", "ffl", "fi", "fl", "Th", "->", "=>", "<=", "!=", "===", "...", "--", "---",
        "www", "1/2", "3x4", "12:30", "0x1F", "#hash", "@user", "C++", "(a)", "[b]", "{c}", "\"q\"", "'s", "a.b", "x_y",
        "To", "Yo", "Va", "AT", "kerning", "Typography", "WAVE", "Pyjama", "AWAY", "f(x)", "x^2", "a*b", "100%", "$9.99"]
    for w in words:
        out.append(w)
    for i in range(400):
        out.append(String(i * 37 % 100000))
    for i in range(200):
        out.append("$" + String(i * 13) + "." + String(10 + i % 90))
        out.append(String(2020 + i % 9) + "-" + String(10 + i % 3) + "-" + String(10 + i % 19))
    var rng = Rng(80)
    var letters = String("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,;:!?-_()[]{}<>/\\|'\"`~@#$%^&*+=")
    var lb = letters.as_bytes()
    for _ in range(900):
        var n = 1 + Int(rng.real(0, 18))
        var t = String()
        for _ in range(n):
            t += chr(Int(lb[Int(rng.real(0, Float64(len(lb))))]))
        out.append(t)
    for i in range(300):
        out.append(words[i % len(words)] + " " + words[(i * 7 + 3) % len(words)] + " " + String(i))
    var other: List[String] = ["naïve café", "Zürich", "नमस्ते", "漢字かな", "한국어", "✈️ trip", "Ωmega", "é", "tab\there", "line\nbreak", "€5", "—dash—"]
    for t in other:
        out.append(t)
    return out^


def same(a: Run, b: Run, what: String) raises:
    assert_equal(len(a.glyphs), len(b.glyphs), what + ": glyph count")
    for i in range(len(a.glyphs)):
        ref x = a.glyphs[i]
        ref y = b.glyphs[i]
        assert_true(x.gid == y.gid and x.face == y.face and x.inst == y.inst and x.cluster == y.cluster, what + ": glyph " + String(i))
        assert_true(abs(x.x - y.x) <= TOL and abs(x.y - y.y) <= TOL, what + ": position of glyph " + String(i) + " " + String(x.x) + " vs " + String(y.x))
    assert_true(abs(a.width - b.width) <= TOL, what + ": width " + String(a.width) + " vs " + String(b.width))


def main() raises:
    var families: List[String] = ["Bricolage Grotesque", "Caveat", "Figtree", "Geist", "Geist Mono", "IBM Plex Mono", "IBM Plex Sans",
                                  "Instrument Serif", "Literata", "Source Serif 4"]
    var sizes: List[Float64] = [11, 13.5, 16, 28]
    var weights: List[Int] = [400, 700]
    var strings = corpus()
    var e = engine()
    var fast = 0
    var total = 0
    var out = Run()
    for fam in families:
        var fast_fam = 0
        for size in sizes:
            for w in weights:
                var st = TextStyle(fam, w, False, size)
                assert_true(e[].pick(fam, w, False) >= 0, fam + " is not a bundled face")
                for t in strings:
                    var want = e[].shape(st, t)
                    if fast_shape(st, t, out):
                        fast += 1
                        fast_fam += 1
                        same(out, want, fam + " " + String(size) + " " + String(w) + " fast '" + t + "'")
                    same(run_for(st, t)[], want, fam + " " + String(size) + " " + String(w) + " run_for '" + t + "'")
                    total += 1
        print("  ", fam, ": fast path", fast_fam, "of", len(strings) * len(sizes) * len(weights))
    # italics, letter spacing and unrounded advances (canvas text): the fast path again against the shaper
    var variants = 0
    for fam in families:
        for mode in range(3):
            var st = TextStyle(fam, 400, mode == 0, 14)
            if mode == 1:
                st.letter_spacing = 0.7
            if mode == 2:
                st.exact = True
            for t in strings:
                var want = e[].shape(st, t)
                if fast_shape(st, t, out):
                    variants += 1
                    same(out, want, fam + " variant " + String(mode) + " '" + t + "'")
    print("VARIANTS", variants, "fast runs in italic, letter-spaced and unrounded styles match the shaper")
    # styles are bounded: 600 sizes in a row keep at most FAST_STYLES, and the runs handed out stay right
    for i in range(600):
        var st = TextStyle("Geist", 400, False, 9 + Float64(i) * 0.05)
        same(run_for(st, "Row 12")[], e[].shape(st, "Row 12"), "style " + String(i))
        same(run_for(st, "a line that is longer than twenty-four bytes")[], e[].shape(st, "a line that is longer than twenty-four bytes"), "long, style " + String(i))
    assert_true(len(e[].fast) <= FAST_STYLES, "styles kept: " + String(len(e[].fast)))
    # the cache: a family's strings asked twice in a row are shaped at most once (within a generation, 4 096 runs)
    for fam in families:
        var st = TextStyle(fam, 400, False, 15)
        for t in strings:
            _ = run_for(st, t)
        var before = e[].shaped_runs
        for t in strings:
            same(run_for(st, t)[], e[].shape(st, t), fam + " again '" + t + "'")
        assert_equal(e[].shaped_runs, before, fam + ": asked again, runs were shaped again (the cache lost them)")
    print("STRINGS", len(strings), "FACES", len(families), "SIZES", len(sizes), "WEIGHTS", len(weights))
    print("FALLBACK", total - fast, "of", total, "runs went to the shaper (other scripts, ligatures, contextual pairs)")
    print("CACHE fast", e[].fast_hits, "hits", e[].cache_hits, "shaped", e[].shaped_runs)
    print("textfast: ok")
