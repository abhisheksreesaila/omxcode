# mojoui.focusmode (goal 82 M1): focus mode's pure parts, for any writing app: the window becomes only the words, and the same key
# puts back exactly what was there. The app keeps what it changes (tool, view, selection, caret, panels) in its own record and
# hands it back on leaving; these are the rules it follows, the same as Personal Note's web app (focus-mode.js, F-073).
#
#   if focus_shortcut(name, mods): toggle            Ctrl+. (Cmd+. on a Mac: mojoui's CTRL bit is Command there), no Shift or Alt
#   var v = focus_view(win_w, text_x, text_y, text_w, scale)   the canvas view that puts a text in the window's middle, 96 px down
#   count_words(text)                                 words as the web counts them (runs of non-space)
#   word_label(n)                                     "1 word", "12 words"

from mojoui.pagedesk import DeskView

comptime FOCUS_TOP = 96.0  # where the top of the text sits, in window px
comptime FOCUS_SIDE = 24.0  # a text wider than the window starts this far in
comptime FOCUS_HINT_MS = 2600  # the "Esc or Ctrl . to leave" hint shows this long, fading over its last 30 %


def focus_shortcut(name: String, mods: Int) -> Bool:
    """The key that switches focus mode: "." with the command modifier (Ctrl; Command on a Mac) and neither Shift (1) nor
    Alt (4)."""
    return name == "." and (mods & 2) != 0 and (mods & 1) == 0 and (mods & 4) == 0


def focus_view(view_w: Float64, text_x: Float64, text_y: Float64, text_w: Float64, scale: Float64) -> DeskView:
    """The view that puts a text (page px: its left, top and width) in the middle of a window `view_w` wide at `scale`, its top
    FOCUS_TOP below the window's top; a text wider than the window starts FOCUS_SIDE from its left edge."""
    var width = text_w * scale
    var centred = (view_w - width) / 2 - text_x * scale
    var left_edge = FOCUS_SIDE - text_x * scale
    return DeskView(left_edge if width + 2 * FOCUS_SIDE > view_w else centred, FOCUS_TOP - text_y * scale, scale)


def _space(b: UInt8) -> Bool:
    return b == 32 or b == 9 or b == 10 or b == 13 or b == 12 or b == 11


def count_words(text: String) -> Int:
    """Words as the web's countWords counts them: runs of characters between ASCII white space (String.split(/\\s+/) of the
    trimmed text; a no-break space joins words, as JavaScript's \\s would not: the web counts it as a space too, so do we)."""
    var n = 0
    var inside = False
    var b = text.as_bytes()
    var i = 0
    while i < len(b):
        var c = b[i]
        var sp = _space(c)
        if c == 0xC2 and i + 1 < len(b) and b[i + 1] == 0xA0:  # (U+00A0)
            sp = True
            i += 1
        elif c == 0xE2 and i + 2 < len(b) and b[i + 1] == 0x80 and (b[i + 2] >= 0x80 and b[i + 2] <= 0x8A or b[i + 2] == 0xA8 or b[i + 2] == 0xA9 or b[i + 2] == 0xAF):  # (U+2000–200A, 2028, 2029, 202F)
            sp = True
            i += 2
        elif c == 0xE3 and i + 2 < len(b) and b[i + 1] == 0x80 and b[i + 2] == 0x80:  # (U+3000)
            sp = True
            i += 2
        if sp:
            inside = False
        elif not inside:
            inside = True
            n += 1
        i += 1
    return n


def word_label(n: Int) -> String:
    return String(n) + (" word" if n == 1 else " words")


def hint_alpha(elapsed_ms: Int) -> Float64:
    """The hint's opacity `elapsed_ms` after focus began (the web's keyframes: 0 → 0.9 at 70 %, → 0 at the end)."""
    if elapsed_ms < 0 or elapsed_ms >= FOCUS_HINT_MS:
        return 0.0
    var t = Float64(elapsed_ms) / Float64(FOCUS_HINT_MS)
    if t <= 0.7:
        return 1.0 - 0.1 * t / 0.7
    return 0.9 * (1.0 - (t - 0.7) / 0.3)
