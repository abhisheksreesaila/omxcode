# mojoui.focusmode (goal 82 M1): the shortcut, the view and the word count, against the web's focus-mode.js and its tests.
#   pixi run mojo run -I . tests/test_focusmode.mojo
from mojoui.focusmode import focus_shortcut, focus_view, count_words, word_label, hint_alpha, FOCUS_TOP
from mojoui.pagesheet import PageSheet
from mojoui.scene import Scene
from mojoui.notesshell import Boxes


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error("FAIL: " + what)
    print("ok  " + what)


def near(a: Float64, b: Float64) -> Bool:
    return abs(a - b) < 1e-9


def main() raises:
    # the shortcut: Ctrl/Cmd + "." only
    check(focus_shortcut(".", 2), "Ctrl+. switches")
    check(not focus_shortcut(".", 0), ". alone doesn't")
    check(not focus_shortcut(".", 3), "Ctrl+Shift+. doesn't")
    check(not focus_shortcut(".", 6), "Ctrl+Alt+. doesn't")
    check(not focus_shortcut(",", 2), "Ctrl+, doesn't")
    # the view (focus-mode.test.js's cases): centred, top 96 down
    var v = focus_view(1000, 100, 50, 400, 1)
    check(near(v.x, (1000 - 400) / 2 - 100) and near(v.y, FOCUS_TOP - 50) and near(v.scale, 1), "a text centred, its top 96 px down")
    var v2 = focus_view(1000, 100, 50, 400, 2)
    check(near(v2.x, (1000 - 800) / 2 - 200) and near(v2.y, 96 - 100), "at 2x the text's width is doubled")
    var v3 = focus_view(500, 100, 0, 600, 1)
    check(near(v3.x, 24 - 100), "a text wider than the window starts 24 px in")
    var v4 = focus_view(648, 0, 0, 600, 1)
    check(near(v4.x, 24), "exactly as wide as the window with its sides: centred (24)")
    var v5 = focus_view(647, 0, 0, 600, 1)
    check(near(v5.x, 24), "one px narrower: from the left edge (24)")
    # words
    check(count_words("") == 0 and count_words("   \n\t ") == 0, "no words")
    check(count_words("one") == 1 and count_words("  one  two\nthree\tfour ") == 4, "runs between spaces")
    check(count_words("नमस्ते दुनिया 漢字 👍🏽 ok") == 5, "any script: a word is a run of non-space")
    check(count_words("a b") == 2, "a no-break space parts words (JavaScript's \\s)")
    check(count_words("# Heading\n- [ ] task") == 6, "Markdown marks are words too, as the web counts them")
    check(word_label(1) == "1 word" and word_label(0) == "0 words" and word_label(12) == "12 words", "labels")
    check(near(hint_alpha(0), 1) and near(hint_alpha(1820), 0.9) and near(hint_alpha(2600), 0) and hint_alpha(2300) < 0.9, "the hint fades out by 2.6 s")
    # PageSheet in focus: only the words; the text starts 96 px under the window's top, in a 680 column centred
    var ps = PageSheet()
    ps.set_markdown("# Title\nSome words here to read.")
    ps.focus = True
    var sc = Scene(1440, 900, 1)
    var bx = Boxes()
    ps.draw(sc, bx, 0, 0, 1440, 900, 1, "", 0, 0)
    check(near(ps.text_w, 680) and near(ps.text_x, 16 + (1440 - 32 - 680) / 2), "the column: 680 wide, centred")
    var paper = bx.find("page.paper")
    check(paper >= 0 and near(bx.r[paper * 4 + 1], 0), "the paper starts at the window's top (no toolbar)")
    check(bx.find("page.icon") < 0 and bx.find("page.group:Mode") < 0, "no icon, no toolbar")
    ps.focus = False
    var bx2 = Boxes()
    ps.draw(sc, bx2, 0, 0, 1440, 900, 1, "", 0, 0)
    check(near(ps.text_w, 860 - 220), "out of focus: the page as it was")
    print("test_focusmode: all passed")
