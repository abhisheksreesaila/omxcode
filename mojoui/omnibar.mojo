# mojoui.omnibar (goal 79): a search-and-jump panel the way Personal Note's web omnibar draws it, as a generic piece: a
# scrim over the app, a floating panel with the query field, filter pills with counts, grouped rows (a tinted emoji or
# icon tile, the title with the matched letters marked, a quieter line under it, a notebook pill and a time at the side),
# a preview of the selected row, and a footer of key hints. Data in, pixels and named boxes out; the app decides what a
# query finds. Also the web's time words (relative_time, short_date).
#
#   var o = Omnibar(); o.query = "li"; o.pills = …; o.groups = …; o.draw(p, bx, w, h, k, sk)

from std.ffi import external_call
from mojoui.scene import Painter
from mojoui.skin import Skin, mix, with_alpha
from mojoui.fonttext import TextStyle, measure, line_metrics, ALIGN_RIGHT, ALIGN_CENTER
from mojoui.notesshell import Boxes, draw_shadows, draw_emoji_tile, text_at, text_normal, _f
from mojoui.strokeicon import draw_icon
from mojoui.canvas import rgba

comptime UI = "Geist"
comptime MONO = "Geist Mono"


@fieldwise_init
struct OmniRow(Copyable, Movable):
    var emoji: String  # a tile's emoji, or "" for an icon tile
    var icon: String  # a Lucide icon (action rows)
    var tint: UInt32  # the tile's colour (mixed 36 % into the panel)
    var title: String
    var sub: String  # "" for none
    var badge: String  # the side pill's words ("" for none)
    var badge_dot: UInt32
    var when: String


@fieldwise_init
struct OmniGroup(Copyable, Movable):
    var title: String
    var rows: List[OmniRow]


@fieldwise_init
struct OmniPill(Copyable, Movable):
    var label: String
    var count: String  # "" for none


struct Omnibar(Movable):
    var query: String
    var pills: List[OmniPill]
    var pill: Int  # the pressed one
    var groups: List[OmniGroup]
    var selected: Int  # over all rows, in order
    var preview_kind: String  # the selected row's type, for the preview's facts
    var preview_edited: String
    var preview_created: String

    def __init__(out self):
        self.query = ""
        self.pills = List[OmniPill]()
        self.pill = 0
        self.groups = List[OmniGroup]()
        self.selected = 0
        self.preview_kind = ""
        self.preview_edited = ""
        self.preview_created = ""

    def rows(self) -> Int:
        var n = 0
        for ref g in self.groups:
            n += len(g.rows)
        return n

    def draw[P: Painter](self, mut p: P, mut bx: Boxes, w: Float64, h: Float64, k: Float64, sk: Skin):
        p.rect(0, 0, w, h, with_alpha(sk.ink, 0.28), 0)
        bx.add("#search-backdrop", 0, 0, w, h)
        var x = (w - 760) / 2
        var y = 96.0
        var ph = 1 + 56 + 42 + 320 + 36.39 + 1
        draw_shadows(p, x, y, 760, ph, 20, sk.shadow3)
        p.rect(x, y, 760, ph, sk.panel, 20)
        bx.add("[Search or jump to]", x, y, 760, ph)
        var ix = x + 1
        var iw = 758.0
        # the field
        bx.add(".spotlight-input-row:EscCancel", ix, y + 1, iw, 56)
        draw_icon(p, "search", ix + 18, y + 1 + 18, 20, k, sk.ink_soft)
        var qst = TextStyle(UI, 400, False, 17)
        var fx = ix + 18 + 20 + 12
        text_normal(p, qst, self.query, fx, y + 13 + (32 - line_metrics(qst).normal_height()) / 2, sk.ink)
        bx.add("#search-input", fx, y + 13, iw - 18 - 20 - 12 - 12 - 35 - 16, 32)
        var kst = TextStyle(MONO, 400, False, 11)
        var ex = ix + iw - 16 - 35
        text_at(p, kst, "Esc", ex + 7, y + 19.3 + 2, 15.4, sk.ui_muted)
        bx.add("#search-close", ex, y + 19.3, 35, 19.39)
        # the pills
        var cy = y + 1 + 56
        p.rect(ix, cy, iw, 1, sk.line, 0)
        bx.add("#omni-chips", ix, cy, iw, 42)
        var px = ix + 14
        var cst = TextStyle(UI, 500, False, 12.5)
        for i in range(len(self.pills)):
            ref pl = self.pills[i]
            var lw = measure(cst, pl.label + (" " if pl.count != "" else ""))
            var nw = measure(cst, pl.count)
            var pw = 22 + lw + nw
            var on = i == self.pill
            p.rect(px, cy + 9, pw, 25, sk.ink if on else with_alpha(sk.state, 0.06), 12.5)
            var fg = sk.panel if on else sk.ink_soft
            text_normal(p, cst, pl.label + (" " if pl.count != "" else ""), px + 11, cy + 13, fg)
            if pl.count != "":
                text_normal(p, cst, pl.count, px + 11 + lw, cy + 13, with_alpha(fg, 0.6))
            bx.add(".omni-chip:" + pl.label + (" " + pl.count if pl.count != "" else ""), px, cy + 9, pw, 25)
            px += pw + 6
        # the body: rows and the preview
        var by = cy + 42
        p.rect(ix, by, iw, 1, sk.line, 0)
        bx.add(".omni-body", ix, by, iw, 320)
        bx.add("#search-results", ix, by + 1, iw - 250, 319)
        var ry = by + 1 + 10
        var n = 0
        var sel_row = OmniRow("", "", 0, "", "", "", 0, "")
        for gi in range(len(self.groups)):
            ref g = self.groups[gi]
            if len(g.rows) == 0:
                continue
            var hst = TextStyle(UI, 600, False, 11)
            hst.letter_spacing = 0.77
            var gtop = ry
            text_normal(p, hst, g.title.upper(), ix + 8 + 8, ry, sk.ui_muted)
            ry += 14 + 4
            for ref r in g.rows:
                if n == self.selected:
                    sel_row = r.copy()
                self._row(p, bx, k, sk, ix + 8, ry, iw - 250 - 16, r, n == self.selected, n)
                ry += 56
                n += 1
            bx.add("[" + g.title + "]", ix + 8, gtop, iw - 250 - 16, ry - gtop)
            ry += 10
        self._preview(p, bx, k, sk, ix + iw - 250, by + 1, sel_row)
        # the footer
        var fy = by + 320
        p.rect(ix, fy, iw, 1, sk.line, 0)
        var fst = TextStyle(UI, 400, False, 11.5)
        var hx = ix + 16
        var hints: List[List[String]] = [["↑", "↓", "Move"], ["↵", "Open"], ["Esc", "Close"]]
        for hint in hints:
            for j in range(len(hint) - 1):
                var kw = measure(kst, hint[j]) + 14
                text_at(p, kst, hint[j], hx + 7, fy + 9 + 2, 15.4, sk.ui_muted)
                hx += kw + 4
            text_normal(p, fst, hint[len(hint) - 1], hx, fy + 11.19, sk.ui_muted)
            hx += measure(fst, hint[len(hint) - 1]) + 14

    def _row[P: Painter](self, mut p: P, mut bx: Boxes, k: Float64, sk: Skin, x: Float64, y: Float64, w: Float64, r: OmniRow, sel: Bool, n: Int):
        if sel:
            p.rect(x, y, w, 56, sk.hover, 12)
        bx.add("#omni-row-" + String(n), x, y, w, 56)
        if r.emoji != "":
            draw_emoji_tile(p, r.emoji, x + 10, y + 8, 40, 11, 22, mix(r.tint, 36, sk.panel))
        else:
            p.rect(x + 10, y + 8, 40, 40, mix(sk.ink, 7, sk.panel), 11)
            draw_icon(p, r.icon, x + 10 + 11, y + 8 + 11, 18, k, sk.ink_soft)
        var tx = x + 10 + 40 + 12
        var tst = TextStyle(UI, 600, False, 14.5)
        var top = y + (56 - (18.84 + 2 + 17 if r.sub != "" else 18.84)) / 2
        # the title, its matched letters marked (the c1 band from 18 % to 88 % of the line, padded 1 px each side)
        var q = self.query.lower()
        var at = _word_match(r.title.lower(), q)
        var penx = tx
        if at >= 0 and q != "":
            var before = String(r.title[byte=0:at])
            var hit = String(r.title[byte=at:at + q.byte_length()])
            var after = String(r.title[byte=at + q.byte_length():])
            text_at(p, tst, before, penx, top, 18.85, sk.ink)
            penx += measure(tst, before)
            var hw = measure(tst, hit) + 2
            p.rect(penx, top - 1 + 19 * 0.18, hw, 19 * 0.70, with_alpha(sk.c1, 0.7), 2)
            text_at(p, tst, hit, penx + 1, top, 18.85, rgba(27, 27, 27))
            penx += hw
            text_at(p, tst, after, penx, top, 18.85, sk.ink)
        else:
            text_at(p, tst, r.title, tx, top, 18.85, sk.ink)
        if r.sub != "":
            text_normal(p, TextStyle(UI, 400, False, 12.5), r.sub, tx, top + 18.84 + 2, sk.ui_muted)
        if r.badge != "":
            var bst = TextStyle(MONO, 500, False, 10.5)
            var bw = 6 + 7 + 5 + measure(bst, r.badge) + 6
            var right = x + w - 10
            var sy = y + (56 - 35.75) / 2
            p.rect(right - bw, sy, bw, 17.75, with_alpha(sk.state, 0.07), 4)
            p.circle(right - bw + 6 + 3.5, sy + 1 + 7.875, 3.5, r.badge_dot)
            text_at(p, bst, r.badge, right - bw + 6 + 7 + 5, sy + 1, 15.75, sk.ink)
            if r.when != "":
                text_normal(p, TextStyle(UI, 400, False, 11.5), r.when, right, sy + 17.75 + 3, sk.ui_muted, ALIGN_RIGHT)

    def _preview[P: Painter](self, mut p: P, mut bx: Boxes, k: Float64, sk: Skin, x: Float64, y: Float64, r: OmniRow):
        p.rect(x, y, 1, 319, sk.line, 0)
        p.rect(x + 1, y, 249, 319, mix(sk.ink, 3, sk.panel), 0)
        bx.add("#omni-preview", x, y, 250, 319)
        if r.title == "":
            return
        var px = x + 1 + 18
        var py = y + 18
        if r.emoji != "":
            var est = TextStyle("emoji", 400, False, 40)
            text_at(p, est, r.emoji, px, py, 44, rgba(0, 0, 0))
        var hst = TextStyle(sk.display, sk.display_weight, sk.display_italic, 20)
        text_at(p, hst, r.title, px, py + 44 + 8, 24, sk.ink)
        var ny = py + 44 + 8 + 24 + 6 + 3.63
        if r.badge != "":
            var bst = TextStyle(MONO, 500, False, 10.5)
            var bw = 6 + 7 + 5 + measure(bst, r.badge) + 6
            p.rect(px, ny, bw, 17.75, with_alpha(sk.state, 0.07), 4)
            p.circle(px + 6 + 3.5, ny + 1 + 7.875, 3.5, r.badge_dot)
            text_at(p, bst, r.badge, px + 6 + 7 + 5, ny + 1, 15.75, sk.ink)
        var dy = ny + 17.75 + 12
        var dst = TextStyle(UI, 400, False, 12)
        var facts: List[List[String]] = [["Type", self.preview_kind], ["Edited", self.preview_edited], ["Created", self.preview_created]]
        for f in facts:
            text_normal(p, dst, f[0], px, dy, sk.ui_muted)
            text_normal(p, dst, f[1], px + 45 + 12, dy, sk.ink)
            dy += 20


def _word_match(text: String, q: String) -> Int:
    """Where q starts a word of text (byte index), else -1."""
    if q == "":
        return -1
    var i = text.find(q)
    while i >= 0:
        if i == 0:
            return i
        var c = Int(text.as_bytes()[i - 1])
        if not ((c >= 97 and c <= 122) or (c >= 48 and c <= 57)):
            return i
        i = text.find(q, i + 1)
    return -1


def word_match(text: String, q: String) -> Bool:
    return _word_match(text.lower(), q.lower()) >= 0


def _digits(b: Span[Byte, _], a: Int, n: Int) -> Int:
    var v = 0
    for i in range(a, a + n):
        v = v * 10 + Int(b[i]) - 48
    return v


def utc_epoch(text: String) -> Int:
    """'YYYY-MM-DD HH:MM:SS' (UTC, as SQLite's CURRENT_TIMESTAMP writes it) as seconds since 1970."""
    var b = text.as_bytes()
    if len(b) < 19:
        return 0
    var y = _digits(b, 0, 4)
    var m = _digits(b, 5, 2)
    var d = _digits(b, 8, 2)
    # days from civil (Howard Hinnant's algorithm)
    var yy = y - (1 if m <= 2 else 0)
    var era = (yy if yy >= 0 else yy - 399) // 400
    var yoe = yy - era * 400
    var doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    var days = era * 146097 + doe - 719468
    return days * 86400 + _digits(b, 11, 2) * 3600 + _digits(b, 14, 2) * 60 + _digits(b, 17, 2)


def relative_time(utc: String, now: Int) -> String:
    """The web's words for when: now, n min ago, n h ago, a weekday inside the week, else the date."""
    var minutes = (now - utc_epoch(utc)) // 60
    if minutes < 1:
        return "now"
    if minutes < 60:
        return String(minutes) + " min ago"
    if minutes < 1440:
        return String(minutes // 60) + " h ago"
    return short_date(utc)


def short_date(utc: String) -> String:
    """'Nov 19' in local time (the browser's toLocaleDateString('en', {month: 'short', day: 'numeric'}))."""
    var t = List[Int](length=1, fill=utc_epoch(utc))
    var tm = List[Int32](length=16, fill=0)
    _ = external_call["localtime_r", Int](Int(t.unsafe_ptr()), Int(tm.unsafe_ptr()))
    var months: List[String] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    var s = months[Int(tm[4])] + " " + String(Int(tm[3]))
    _ = t
    _ = tm
    return s
