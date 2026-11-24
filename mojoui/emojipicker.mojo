# mojoui.emojipicker (goal 79, 79-gaps 10): an emoji and a tint chosen from a small card: a search field (words, or an emoji pasted),
# the ones used last, a few common ones, five tints, and two quiet buttons (Personal Note's note-icon-picker.js, 300 px, 8 columns of
# 34 px). The app gives the catalog and the tints' colours and does the saving.
#
#   var e = EmojiPicker(); e.common = …; e.more.append(EmojiWords("💡", "idea light bulb")); e.tints = …
#   e.show(x, below_y); e.draw(p, bx, w, h, k, sk)       # boxes "emoji", "emoji.pick:<i>" (shown[i]), "emoji.tint:<n>", "emoji.guess", "emoji.remove"
#   e.key(name, mods) / e.insert(words)                   # the search field: True when it was the picker's

from mojoui.fonttext import TextStyle, measure, baseline_in, ALIGN_CENTER
from mojoui.graphemes import next_grapheme, without_last, typed_text, one_line
from mojoui.notesshell import Boxes, draw_lifted, draw_bordered, text_at, text_normal
from mojoui.scene import Painter
from mojoui.skin import Skin, mix, with_alpha
from mojoui.canvas import rgba

comptime UI = "Geist"


@fieldwise_init
struct EmojiWords(Copyable, Movable):
    var emoji: String
    var words: String


struct EmojiPicker(Copyable, Movable):
    var open: Bool
    var x: Float64
    var y: Float64  # below the button it opened from
    var top: Float64  # that button's top (it opens above when there is no room below)
    var query: String
    var recent: List[String]
    var common: List[String]
    var more: List[EmojiWords]
    var tints: List[UInt32]
    var chosen: String  # the one it has now ("" when it shows a guess)
    var tint: Int  # 1…
    var search_label: String
    var common_label: String
    var guess_label: String
    var remove_label: String
    var shown: List[String]  # what the boxes "emoji.pick:<i>" name

    def __init__(out self):
        self.open = False
        self.x = 0
        self.y = 0
        self.top = 0
        self.query = ""
        self.recent = List[String]()
        self.common = List[String]()
        self.more = List[EmojiWords]()
        self.tints = List[UInt32]()
        self.chosen = ""
        self.tint = 0
        self.search_label = "Search emoji, or paste one…"
        self.common_label = "Common"
        self.guess_label = "Guess"
        self.remove_label = "Remove"
        self.shown = List[String]()

    def show(mut self, x: Float64, top: Float64, bottom: Float64):
        self.open = True
        self.query = ""
        self.x = x
        self.top = top
        self.y = bottom + 8

    def found(self) -> List[String]:
        """What the search finds: an emoji typed or pasted, else the ones whose words all begin with what was typed."""
        var q = String(self.query.strip())
        if q.byte_length() > 0 and next_grapheme(q, 0) == q.byte_length() and is_emoji(q):
            return [q]
        var out = List[String]()
        for ref m in self.more:
            var all = True
            for w in q.lower().split():
                var hit = False
                for have in m.words.split(" "):
                    if String(have).startswith(String(w)):
                        hit = True
                all = all and hit
            if all:
                out.append(m.emoji)
        return out^

    def key(mut self, name: String, mods: Int) -> Bool:
        """A key while it is open: Escape closes; the rest is the search field's (Enter picks nothing by itself)."""
        if name == "Escape":
            self.open = False
            return True
        if (mods & 2) != 0:
            return name != "v" and name != "V"
        if name == "Backspace":
            self.query = without_last(self.query)
        elif typed_text(name):
            self.insert(name)
        return True

    def insert(mut self, words: String):
        var w = one_line(words)
        if (self.query + w).byte_length() <= 160:
            self.query += w

    def height(self) -> Float64:
        var h = 12.0 + 34 + 10
        if String(self.query.strip()) != "":
            var n = len(self.found())
            h += (13 + 6 + self.rows(n) if n > 0 else 36.0)
        else:
            if len(self.recent) > 0:
                h += 13 + 6 + self.rows(len(self.recent)) + 10
            h += 13 + 6 + self.rows(len(self.common))
        return h + 10 + 13 + 8 + 26 + 10 + 27 + 12 - 12

    @staticmethod
    def rows(n: Int) -> Float64:
        return Float64((n + 7) // 8) * 36 - 2

    def draw[P: Painter](mut self, mut p: P, mut bx: Boxes, win_w: Float64, win_h: Float64, k: Float64, sk: Skin):
        var w = 300.0
        var h = self.height()
        var x = max(8.0, min(self.x, win_w - w - 8))
        var y = self.y if self.y + h <= win_h - 8 else max(8.0, self.top - h - 8)
        draw_lifted(p, x, y, w, h, 16, sk.shadow2, sk.edge if sk.dark else sk.line)
        p.rect(x + 1, y + 1, w - 2, h - 2, sk.panel, 15)
        bx.add("emoji", x, y, w, h)
        self.shown = List[String]()
        var ix = x + 12
        var iw = w - 24
        var cy = y + 12
        draw_bordered(p, ix, cy, iw, 34, 9, sk.desk, sk.line)
        bx.add("emoji.search", ix, cy, iw, 34)
        var st = TextStyle(UI, 400, False, 13)
        text_at(p, st, self.query if self.query != "" else self.search_label, ix + 11, cy, 34, sk.ink if self.query != "" else sk.ui_muted)
        p.rect(ix + 11 + (measure(st, self.query) if self.query != "" else 0.0), cy + 9, 1.5, 16, sk.ink, 0)
        cy += 34 + 10
        if String(self.query.strip()) != "":
            var f = self.found()
            if len(f) > 0:
                cy = self._grid(p, bx, sk, ix, cy, iw, "Results", f)
            else:
                text_at(p, TextStyle(UI, 400, False, 12), "Nothing matches “" + String(self.query.strip()) + "”", ix + 8, cy, 36, sk.ui_muted)
                cy += 36
        else:
            if len(self.recent) > 0:
                var r = self.recent.copy()
                cy = self._grid(p, bx, sk, ix, cy, iw, "Recent", r) + 10
            var c = self.common.copy()
            cy = self._grid(p, bx, sk, ix, cy, iw, String(self.common_label), c)
        cy += 10
        self._head(p, sk, ix, cy, "Tint")
        cy += 13 + 8
        for t in range(len(self.tints)):
            var tx = ix + Float64(t) * 34
            if t + 1 == self.tint:
                p.circle(tx + 13, cy + 13, 17, sk.ink)
                p.circle(tx + 13, cy + 13, 15, sk.panel)
            p.circle(tx + 13, cy + 13, 13, sk.line)
            p.circle(tx + 13, cy + 13, 12, mix(self.tints[t], 40, sk.panel))
            bx.add("emoji.tint:" + String(t + 1), tx, cy, 26, 26)
        cy += 26 + 10
        var fst = TextStyle(UI, 400, False, 12)
        text_at(p, fst, self.guess_label, ix, cy, 15, sk.ui_muted)
        bx.add("emoji.guess", ix - 8, cy - 6, measure(fst, self.guess_label) + 16, 27)
        var rw = measure(fst, self.remove_label)
        text_at(p, fst, self.remove_label, ix + iw - rw, cy, 15, sk.ui_muted if self.chosen != "" else with_alpha(sk.ui_muted, 0.5))
        bx.add("emoji.remove", ix + iw - rw - 8, cy - 6, rw + 16, 27)

    def _head[P: Painter](self, mut p: P, sk: Skin, x: Float64, y: Float64, words: String):
        var st = TextStyle(UI, 600, False, 10.5)
        st.letter_spacing = 0.84
        text_at(p, st, words.upper(), x, y, 13, sk.ui_muted)

    def _grid[P: Painter](mut self, mut p: P, mut bx: Boxes, sk: Skin, x: Float64, y: Float64, w: Float64, title: String, list: List[String]) -> Float64:
        self._head(p, sk, x, y, title)
        var gy = y + 13 + 6
        var cw = (w - 14) / 8
        var st = TextStyle("emoji", 400, False, 20)
        for i in range(len(list)):
            var cx = x + Float64(i % 8) * (cw + 2)
            var cy = gy + Float64(i // 8) * 36
            if list[i] == self.chosen:
                p.rect(cx, cy, cw, 34, sk.accent_soft, 9)
            p.run(st, list[i], cx + cw / 2, baseline_in(cy + 7, 20, st), rgba(0, 0, 0), ALIGN_CENTER)
            bx.add("emoji.pick:" + String(len(self.shown)), cx, cy, cw, 34)
            self.shown.append(list[i])
        return gy + self.rows(len(list))


def is_emoji(s: String) -> Bool:
    """One emoji (its first code point is in the pictographic ranges, or it is a keycap or a flag)."""
    for cp in s.codepoints():
        var v = Int(cp.to_u32())
        if v >= 0x1F000 or (v >= 0x2190 and v <= 0x2BFF) or v == 0x203C or v == 0x2049 or v == 0x3030 or v == 0x303D or v == 0x3297 or v == 0x3299 or v == 0xA9 or v == 0xAE:
            return True
        return s.find("\u20E3") >= 0 and (v == 35 or v == 42 or (v >= 48 and v <= 57))
    return False
