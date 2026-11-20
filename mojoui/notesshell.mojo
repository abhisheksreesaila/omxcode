# mojoui.notesshell (goal 79): the chrome of a notes app the way Personal Note's web app draws it, as generic pieces any
# app can compose on one full-window Canvas: the dotted desk, round island buttons, the title island, the floating notes
# panel (brand, Quick note, an Inbox of rows, PARA shelves of notebooks, the skin dots), drawn from a mojoui.skin.Skin
# with mojoui.fonttext's real faces and mojoui.strokeicon's icons. Every piece records where it drew in a Boxes list
# (named rects, layout px), which is both the hit test for taps and what tests compare with the web's DOM boxes.
#
#   var bx = Boxes()
#   draw_desk(p, w, h, k, sk)
#   draw_round_button(p, bx, "#toggle-sidebar", 16, 16, "panel-left", k, sk, sk.panel)
#   var panel = NotesPanel(); …; panel.draw(p, bx, k, sk)

from mojoui.scene import Painter
from mojoui.skin import Skin, Shadow, mix, with_alpha, hexc
from mojoui.fonttext import TextStyle, measure, line_metrics, baseline_in, ALIGN_LEFT, ALIGN_CENTER, ALIGN_RIGHT
from mojoui.strokeicon import draw_icon
from mojoui.canvas import rgba
from std.math import sqrt, exp

comptime UI = "Geist"
comptime MONO = "Geist Mono"


# ------------------------------------------------ named boxes

struct Boxes(Movable):
    """Named rects in layout px, in drawing order (the last one drawn is on top)."""
    var names: List[String]
    var r: List[Float64]

    def __init__(out self):
        self.names = List[String]()
        self.r = List[Float64]()

    def clear(mut self):
        self.names.clear()
        self.r.clear()

    def add(mut self, name: String, x: Float64, y: Float64, w: Float64, h: Float64):
        """Records a box; a name drawn again gets @2, @3… (as the reference names duplicates)."""
        var n = 1
        for ref have in self.names:
            if have == name or have.startswith(name + "@"):
                n += 1
        self.names.append(name if n == 1 else name + "@" + String(n))
        self.r.append(x)
        self.r.append(y)
        self.r.append(w)
        self.r.append(h)

    def hit(self, x: Float64, y: Float64, prefix: String = "") -> String:
        """The topmost box under a point (with this prefix): its name, or ""."""
        var i = len(self.names) - 1
        while i >= 0:
            if self.names[i].startswith(prefix):
                var bx = self.r[i * 4]
                var by = self.r[i * 4 + 1]
                if x >= bx and y >= by and x < bx + self.r[i * 4 + 2] and y < by + self.r[i * 4 + 3]:
                    return self.names[i]
            i -= 1
        return ""

    def hit_any(self, x: Float64, y: Float64, prefixes: List[String]) -> String:
        """The topmost box under a point among those whose names start with one of `prefixes` (the things a tap can
        act on; containers recorded after their children don't swallow the tap)."""
        var i = len(self.names) - 1
        while i >= 0:
            var bx = self.r[i * 4]
            var by = self.r[i * 4 + 1]
            if x >= bx and y >= by and x < bx + self.r[i * 4 + 2] and y < by + self.r[i * 4 + 3]:
                for ref pf in prefixes:
                    if self.names[i].startswith(pf):
                        return self.names[i]
            i -= 1
        return ""

    def find(self, name: String) -> Int:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def json(self) -> String:
        var out = String("{")
        for i in range(len(self.names)):
            if i > 0:
                out += ",\n"
            out += '"' + _esc(self.names[i]) + '": [' + _f(self.r[i * 4]) + ", " + _f(self.r[i * 4 + 1]) + ", " + _f(self.r[i * 4 + 2]) + ", " + _f(self.r[i * 4 + 3]) + "]"
        return out + "}"


def _f(v: Float64) -> String:
    var r = Float64(Int(v * 100 + (0.5 if v >= 0 else -0.5))) / 100
    return String(r)


def _esc(s: String) -> String:
    var out = String("")
    for c in s.codepoints():
        var u = Int(c.to_u32())
        if u == 34:
            out += '\\"'
        elif u == 92:
            out += "\\\\"
        else:
            out += String(c)
    return out^


# ------------------------------------------------ surfaces

def draw_shadows[P: Painter](mut p: P, x: Float64, y: Float64, w: Float64, h: Float64, radius: Float64, shadows: List[Shadow]):
    """CSS box-shadows under a rounded rect: a spread ring as one rect, a blurred one as layered rects whose summed alpha
    follows the Gaussian's falloff (σ = blur / 2), so the same picture reaches the CPU painter and the GPU."""
    for s in shadows:
        var a = Float64(Int((s.color >> 24) & 0xFF)) / 255.0
        if s.blur <= 0:
            p.rect(x - s.spread + s.dx, y - s.spread + s.dy, w + 2 * s.spread, h + 2 * s.spread, s.color, radius + s.spread)
            continue
        var sigma = s.blur / 2
        comptime N = 10
        # layers from the outermost (2σ out) to the innermost (2σ in); layer j covers distance ≤ d_j outside the edge
        var prev = 0.0
        for j in range(N):
            var d = 2 * sigma - 4 * sigma * Float64(j) / Float64(N - 1)  # 2σ … −2σ
            var target = a * 0.5 * _erfc((d) / (sigma * 1.41421356))
            var la = (target - prev) / (1 - prev) if prev < 1 else 0.0
            prev = target
            if la <= 0.002:
                continue
            var e = d + s.spread
            p.rect(x - e + s.dx, y - e + s.dy, w + 2 * e, h + 2 * e, with_alpha(s.color, min(1.0, la)), max(0.0, radius + e))


def _erfc(x: Float64) -> Float64:
    # Abramowitz–Stegun 7.1.26
    var z = abs(x)
    var t = 1.0 / (1.0 + 0.3275911 * z)
    var y = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429)))) * exp(-z * z)
    return y if x >= 0 else 2 - y


def draw_bordered[P: Painter](mut p: P, x: Float64, y: Float64, w: Float64, h: Float64, radius: Float64, fill: UInt32, border: UInt32,
                              bw: Float64 = 1):
    """A rounded rect with a border inside its box (CSS border-box)."""
    if (border >> 24) == 0:
        p.rect(x, y, w, h, fill, radius)
        return
    p.rect(x, y, w, h, border, radius)
    p.rect(x + bw, y + bw, w - 2 * bw, h - 2 * bw, fill, max(0.0, radius - bw))


def draw_desk[P: Painter](mut p: P, w: Float64, h: Float64, k: Float64, sk: Skin):
    """The desk: its colour and a dot every 22 px (radial-gradient(dot 1px, transparent 1.2px) / 22px 22px)."""
    p.fill(sk.desk)
    var y = 11.0
    while y < h + 11:
        var x = 11.0
        while x < w + 11:
            p.circle(x, y, 1.1, sk.desk_dot)
            x += 22
        y += 22


def text_at[P: Painter](mut p: P, st: TextStyle, s: String, x: Float64, top: Float64, line_height: Float64, color: UInt32, align: Int = ALIGN_LEFT):
    """A line of text in a CSS line box (top, line-height): the baseline where Blink puts it."""
    p.run(st, s, x, baseline_in(top, line_height, st), color, align)


def text_normal[P: Painter](mut p: P, st: TextStyle, s: String, x: Float64, top: Float64, color: UInt32, align: Int = ALIGN_LEFT):
    """A line of text whose line-height is normal, its line box starting at top."""
    var m = line_metrics(st)
    p.run(st, s, x, top + Float64(m.ascent), color, align)


def draw_round_button[P: Painter](mut p: P, mut bx: Boxes, name: String, x: Float64, y: Float64, icon: String, k: Float64, sk: Skin,
                                  bg: UInt32, size: Float64 = 44, hovered: Bool = False):
    """A round island button (the panel toggle, search): the skin's panel lifted by its shadow, a 20 px icon; hovered,
    the skin's state layer (8 %) over its fill (the web's --lift)."""
    draw_shadows(p, x, y, size, size, size / 2, sk.shadow2)
    p.rect(x, y, size, size, bg, size / 2)
    if hovered:
        p.rect(x, y, size, size, sk.hover, size / 2)
    draw_icon(p, icon, x + (size - 20) / 2, y + (size - 20) / 2, 20, k, sk.ink_soft)
    bx.add(name, x, y, size, size)


def draw_emoji_tile[P: Painter](mut p: P, emoji: String, x: Float64, y: Float64, size: Float64, radius: Float64, font_px: Float64,
                                bg: UInt32):
    """A note's emoji on its tinted tile, centred (font_px: the emoji's CSS size, line-height = font_px)."""
    p.rect(x, y, size, size, bg, radius)
    var st = TextStyle("emoji", 400, False, font_px)
    var top = y + (size - font_px) / 2
    p.run(st, emoji, x + size / 2, baseline_in(top, font_px, st), rgba(0, 0, 0), ALIGN_CENTER)


def title_island_width(title: String, has_icon: Bool) -> Float64:
    var tw = measure(TextStyle(UI, 400, False, 16), title)
    return 2 + (44.0 if has_icon else 18.0) + tw + 18


def draw_title_island[P: Painter](mut p: P, mut bx: Boxes, slot_x0: Float64, slot_x1: Float64, title: String, emoji: String, tint: UInt32,
                                  k: Float64, sk: Skin, face_emoji: String = ""):
    """The note's title on an island centred over the note area (with its emoji button for canvas and map notes)."""
    var has_icon = emoji != ""
    var w = title_island_width(title, has_icon)
    var x = Float64(Int(((slot_x0 + slot_x1) / 2 - w / 2) * 2 + 0.5)) / 2  # (centred as flex does: half-px steps)
    var y = 16.0
    draw_shadows(p, x, y, w, 44, 22, sk.shadow2)
    p.rect(x, y, w, 44, sk.panel, 22)
    bx.add("#island", x, y, w, 44)
    var title_x = x + 1 + 18
    bx.add(".isl-face:" + face_emoji + title, x + 1, y + 1, w - 2, 42)
    if has_icon:
        draw_emoji_tile(p, emoji, x + 1 + 10, y + 1 + 9, 24, 7, 14, mix(tint, 36, sk.panel))
        bx.add("#island-icon", x + 1, y + 1, 44, 42)
        title_x = x + 1 + 44
    bx.add("#share-button", x + 1, y + 1, w - 2, 42)
    var st = TextStyle(UI, 400, False, 16)
    var tw = measure(st, title)
    text_normal(p, st, title, title_x, y + (44 - line_metrics(st).normal_height()) / 2, sk.ink)
    bx.add("#island-title", title_x, y + (44 - line_metrics(st).normal_height()) / 2, tw, line_metrics(st).normal_height())


# ------------------------------------------------ the notes panel

@fieldwise_init
struct PanelNote(Copyable, Movable):
    var id: Int
    var title: String
    var kind: String  # page | canvas | mindmap
    var emoji: String
    var tint: Int  # 1–5
    var notebook: Int  # 0: the Inbox


@fieldwise_init
struct PanelNotebook(Copyable, Movable):
    var id: Int
    var name: String
    var color: UInt32
    var category: String  # projects | areas | resources | archive
    var icon: String  # a Lucide name, or "" for its letter
    var count: Int


struct NotesPanel(Movable):
    """The floating notes panel's state: which shelves are open, which note is active."""
    var notes: List[PanelNote]
    var notebooks: List[PanelNotebook]
    var active: Int
    var inbox_open: Bool
    var open_shelves: List[Bool]  # projects, areas, resources, archive
    var skin_name: String

    def __init__(out self):
        self.notes = List[PanelNote]()
        self.notebooks = List[PanelNotebook]()
        self.active = 0
        self.inbox_open = True
        self.open_shelves = [True, True, True, False]
        self.skin_name = "paper"

    def toggle_shelf(mut self, at: Int):
        """Folds or opens a shelf: 0 the Inbox, 1–4 Projects, Areas, Resources, Archive (a tap on its head)."""
        if at == 0:
            self.inbox_open = not self.inbox_open
        elif at >= 1 and at <= 4:
            self.open_shelves[at - 1] = not self.open_shelves[at - 1]

    def draw[P: Painter](self, mut p: P, mut bx: Boxes, k: Float64, sk: Skin, h: Float64):
        var x = 16.0
        var y = 72.0
        var w = 280.0
        var ph = h - 72 - 16
        draw_shadows(p, x, y, w, ph, sk.radius, sk.shadow2)
        p.rect(x, y, w, ph, sk.panel, sk.radius)
        bx.add("#sidebar", x, y, w, ph)
        var cx = x + 1 + 10  # content box: border 1, padding 14 10
        var cw = w - 2 - 20
        var cy = y + 1 + 14
        # brand
        bx.add(".brand-row", cx, cy, cw, 44)
        var mx = cx + 6
        var my = cy + 2
        p.rect(mx, my, 26, 30, sk.accent, 5)  # (4px 7px 7px 4px: drawn with the mean corner)
        p.rect(mx, my, 3, 30, mix(sk.accent, 62, rgba(0, 0, 0)), 1.5)
        p.rect(mx + 26 - 5 - 3, my, 3, 30, with_alpha(sk.accent_ink, 0.7), 0)
        bx.add(".brand-mark", mx, my, 26, 30)
        var bst = TextStyle(sk.display, sk.display_weight, sk.display_italic, 17)
        bst.letter_spacing = sk.title_track * 17
        text_at(p, bst, "Personal Note", mx + 26 + 9, my + 5, 20, sk.ink)
        bx.add(".brand-name:Personal Note", mx + 26 + 9, my + 5, cw - 6 - 26 - 9 - 6, 20)
        cy += 44 + 2
        # quick note
        draw_shadows(p, cx, cy, cw, 38, 19, sk.shadow1)
        p.rect(cx, cy, cw, 38, sk.accent_fill, 19)
        bx.add("#rail-new-note", cx, cy, cw, 38)
        draw_icon(p, "plus", cx + 12, cy + 11, 16, k, sk.accent_ink)
        var qst = TextStyle(UI, 500, False, 13)
        text_normal(p, qst, "Quick note", cx + 12 + 16 + 8, cy + (38 - 17) / 2, sk.accent_ink)
        var kst = TextStyle(MONO, 400, False, 11)
        var kw = measure(kst, "Alt N") + 14
        var kx = cx + cw - 12 - kw
        var ky = cy + (38 - 20.3) / 2
        var kc = with_alpha(sk.accent_ink, 0.8)
        p.rect(kx, ky, kw, 20.3, with_alpha(sk.accent_ink, 0.3 * 0.8), 6)
        p.rect(kx + 1, ky + 1, kw - 2, 18.3, sk.accent_fill, 5)
        text_at(p, kst, "Alt N", kx + 7, ky + 3, 14.3, kc)
        bx.add("#quick-note-kbd", kx, ky, kw, 20.3)
        cy += 38 + 10 + 2  # margin 10, the panel's gap 2
        # the navigator: Inbox and the four shelves
        bx.add("#notebook-navigator", cx - 4, cy, cw + 8, y + ph - 1 - 14 - (29 + 6 + 2) - cy)
        var list_top = cy
        var inbox_notes = List[Int]()
        for i in range(len(self.notes)):
            if self.notes[i].notebook == 0:
                inbox_notes.append(i)
        var inbox_h = 2 + 34 + 2 + ((Float64(len(inbox_notes)) * 35 - 1 + 6 + 2) if self.inbox_open else 0.0)
        if self.inbox_open:
            p.rect(cx, cy, cw, inbox_h, sk.shelf, 13)
        bx.add(".sec", cx, cy, cw, inbox_h)
        cy = self._shelf(p, bx, k, sk, cx, cy, cw, "Inbox", "inbox", self.inbox_open, String(len(inbox_notes)), True, False)
        if self.inbox_open:
            var rows_y = cy + 2
            var rows_h = Float64(len(inbox_notes)) * 35 - 1
            p.rect(cx + 2 + 13, rows_y, 1.5, rows_h, sk.line, 0)
            bx.add("[Inbox]", cx + 2 + 13, rows_y, cw - 4 - 13, rows_h)
            var ry = rows_y
            for i in inbox_notes:
                self._note_row(p, bx, k, sk, cx + 2 + 13 + 1.5 + 7.5, ry, cw - 4 - 13 - 9, self.notes[i])
                ry += 35
            cy = rows_y + rows_h + 6 + 2
        else:
            cy += 2
        var cats: List[String] = ["projects", "areas", "resources", "archive"]
        var labels: List[String] = ["Projects", "Areas", "Resources", "Archive"]
        var icons: List[String] = ["target", "compass", "book-open", "archive"]
        for s in range(4):
            cy += 4
            var books = List[Int]()
            for i in range(len(self.notebooks)):
                if self.notebooks[i].category == cats[s]:
                    books.append(i)
            var is_archive = s == 3
            var open = self.open_shelves[s]
            var sh = 2 + 34 + 2 + ((26.8 if len(books) == 0 else Float64(len(books)) * 31 - 1) if open else 0.0)
            if open:
                p.rect(cx, cy, cw, sh, sk.shelf, 13)
            cy = self._shelf(p, bx, k, sk, cx, cy, cw, labels[s], icons[s], open, String(len(books)) if is_archive else "", False, is_archive)
            if open:
                if len(books) == 0:
                    var est = TextStyle(UI, 400, False, 12)
                    text_at(p, est, "Drop a notebook here", cx + 2 + 8, cy + 5, 16.8, sk.ui_muted)
                    bx.add(".empty-notebook:Drop a notebook here", cx + 2, cy, cw - 4, 26.8)
                    cy += 26.8 + 2
                else:
                    var ny = cy
                    for i in books:
                        self._notebook_row(p, bx, k, sk, cx + 2, ny, cw - 4, self.notebooks[i])
                        ny += 31
                    cy = ny - 1 + 2
            else:
                if is_archive:
                    bx.add(".empty-notebook:Drop a notebook here", cx + 2, cy, cw - 4, 10)
                cy += 2
        bx.add("#notebook-list", cx, list_top, cw, cy - list_top)
        # footer
        var fy = y + ph - 1 - 14 - 29
        p.rect(cx - 2, fy, cw + 4, 1, sk.line, 0)
        bx.add(".sidebar-footer", cx - 2, fy, cw + 4, 29)
        var fst = TextStyle(MONO, 400, False, 12)
        text_normal(p, fst, "Skin", cx - 2 + 8, fy + 1 + 11, sk.ui_muted)
        bx.add(".skin-label:Skin", cx - 2 + 8, fy + 12, measure(fst, "Skin"), 16)
        var sx = cx + cw + 2 - 6 - 68
        var sy = fy + 11
        bx.add("#skin-switcher", sx, sy, 68, 18)
        var names: List[String] = ["crayon", "paper", "night"]
        var labels2: List[String] = ["Crayon skin", "Paper skin", "Night skin"]
        var swatches: List[UInt32] = [hexc("#2f6fe0"), hexc("#1f1b16"), hexc("#1b2130")]
        for i in range(3):
            var ox = sx + Float64(i) * 25
            if names[i] == self.skin_name:
                p.circle(ox + 9, sy + 9, 11, sk.accent)
            p.circle(ox + 9, sy + 9, 9, sk.panel)
            p.circle(ox + 9, sy + 9, 7, swatches[i])
            bx.add("[" + labels2[i] + "]", ox, sy, 18, 18)

    def _shelf[P: Painter](self, mut p: P, mut bx: Boxes, k: Float64, sk: Skin, x: Float64, y: Float64, w: Float64, label: String, icon: String,
                           open: Bool, count: String, badge: Bool, archive: Bool) -> Float64:
        """A shelf's head (and its open wash, drawn behind what follows); the y below the head."""
        _ = archive
        var hx = x + 2
        var hy = y + 2
        bx.add(".sec-head", hx, hy, w - 4, 34)
        draw_icon(p, icon, hx + 8, hy + 9, 16, k, sk.ink_soft, 1.8 if icon == "archive" else 2.0)
        bx.add(".sec-ic", hx + 8, hy + 9, 16, 16)
        var st = TextStyle(UI, 600, False, 13.5)
        text_at(p, st, label, hx + 8 + 16 + 8, hy + 10.25, 13.5, sk.ink)
        if badge:
            var bst = TextStyle(MONO, 500, False, 10.5)
            var tw = measure(bst, count)
            var bw = tw + 10
            var bxx = hx + w - 4 - 8 - 14 - 8 - bw
            p.rect(bxx, hy + 8, bw, 18, with_alpha(sk.state, 0.10), 4)
            text_at(p, bst, count, bxx + 5, hy + 8, 18, sk.ink)
            bx.add("#inbox-badge", bxx, hy + 8, bw, 18)
        elif count != "":
            var cst = TextStyle(MONO, 400, False, 11)
            var tw = measure(cst, count)
            text_at(p, cst, count, hx + w - 4 - 8 - 14 - 8 - tw, hy + 11.5, 11, sk.ui_muted)
        draw_icon(p, "chevron-down" if open else "chevron-right", hx + w - 4 - 8 - 14, hy + 10, 14, k, with_alpha(sk.ink, 0.7))
        return hy + 34

    def _note_row[P: Painter](self, mut p: P, mut bx: Boxes, k: Float64, sk: Skin, x: Float64, y: Float64, w: Float64, n: PanelNote):
        var active = n.id == self.active
        if active:
            p.rect(x, y, w, 34, with_alpha(sk.state, 0.12), 8)
        var fg = sk.accent_text if active else sk.ink_soft
        draw_emoji_tile(p, n.emoji, x + 8, y + 5, 24, 7, 14, mix(sk.tint(n.tint), 36, sk.panel))
        var st = TextStyle(UI, 400, False, 12.5)
        text_at(p, st, n.title, x + 8 + 24 + 8, y + 8.875, 16.25, fg)
        var icon = "git-fork" if n.kind == "mindmap" else ("file-pen" if n.kind == "page" else "file-text")
        draw_icon(p, icon, x + w - 8 - 14, y + 10, 14, k, with_alpha(fg, 0.65))
        bx.add("row:" + n.emoji + " " + n.title, x, y, w, 34)

    def _notebook_row[P: Painter](self, mut p: P, mut bx: Boxes, k: Float64, sk: Skin, x: Float64, y: Float64, w: Float64, nb: PanelNotebook):
        if nb.icon == "":
            p.rect(x + 6, y + 6, 18, 18, nb.color, 6)
            var lst = TextStyle(UI, 600, False, 11)
            var letter = String(nb.name[byte=0:1]).upper()
            text_at(p, lst, letter, x + 15, y + 6, 18, rgba(255, 255, 255), ALIGN_CENTER)
        else:
            draw_icon(p, nb.icon, x + 7, y + 7, 16, k, nb.color)
        bx.add("[Icon and colour of " + nb.name + "]", x, y, 30, 30)
        var st = TextStyle(UI, 400, False, 13)
        text_normal(p, st, nb.name, x + 33, y + 6.5, sk.ink_soft)
        var cst = TextStyle(MONO, 400, False, 11)
        var cnt = String(nb.count)
        var tw = measure(cst, cnt)
        text_at(p, cst, cnt, x + w - 8 - 14 - 9 - tw, y + 9.5, 11, sk.ui_muted)
        draw_icon(p, "chevron-right", x + w - 8 - 14, y + 8, 14, k, with_alpha(sk.ink_soft, 0.7))
        bx.add(".nav-row:" + nb.name + " " + cnt + (" " + String(nb.name[byte=0:1]).upper() if nb.icon == "" else ""), x, y, w, 30)


def draw_tool_dock[P: Painter](mut p: P, mut bx: Boxes, x: Float64, y: Float64, labels: List[String], icons: List[String], k: Float64, sk: Skin,
                              group: String = ""):
    """A vertical island of 44 px round tool buttons, 2 apart (an empty label: a divider with 8 above and below), padded
    6 (+1 border), the skin's radius. Returns nothing; its box is [Canvas tools], its buttons [label]."""
    var inner = 0.0
    for i in range(len(labels)):
        if labels[i] == "":
            inner += 17
        else:
            inner += 44 + (2.0 if i + 1 < len(labels) and labels[i + 1] != "" else 0.0)
    var h = inner + 14
    draw_shadows(p, x, y, 56, h, sk.radius, sk.shadow2)
    p.rect(x, y, 56, h, sk.panel, sk.radius)
    bx.add("[Canvas tools]", x, y, 56, h)
    if group != "":
        bx.add(group, x + 6, y + 7, 44, inner)
    var by = y + 7
    for i in range(len(labels)):
        if labels[i] == "":
            p.rect(x + 14, by + 8, 28, 1, sk.line, 0)
            bx.add(".dock-divider", x + 14, by + 8, 28, 1)
            by += 17
        else:
            draw_icon(p, icons[i], x + 18, by + 12, 20, k, sk.ink_soft)
            bx.add("[" + labels[i] + "]", x + 6, by, 44, 44)
            by += 44 + (2.0 if i + 1 < len(labels) and labels[i + 1] != "" else 0.0)


def draw_zoom_island[P: Painter](mut p: P, mut bx: Boxes, x: Float64, y: Float64, percent: Int, k: Float64, sk: Skin):
    """The map's zoom island: minus, the zoom as a label (a press resets it), plus."""
    p.rect(x, y, 132, 42, sk.line, sk.radius_control)
    p.rect(x + 1, y + 1, 130, 40, sk.panel, sk.radius_control - 1)
    bx.add("[Zoom controls]", x, y, 132, 42)
    draw_icon(p, "minus", x + 4 + 9, y + 4 + 9, 16, k, sk.muted)
    bx.add("[Zoom out]", x + 4, y + 4, 34, 34)
    var st = TextStyle(UI, 400, False, 11)
    text_normal(p, st, String(percent) + "%", x + 40 + 26, y + 4 + (34 - 14) / 2, 0xFF656F74, ALIGN_CENTER)
    bx.add(".mindmap-zoom-label:" + String(percent) + "%", x + 40, y + 4, 52, 34)
    draw_icon(p, "plus", x + 94 + 9, y + 4 + 9, 16, k, sk.muted)
    bx.add("[Zoom in]", x + 94, y + 4, 34, 34)


def draw_hint[P: Painter](mut p: P, mut bx: Boxes, cx: Float64, y: Float64, words: String, sk: Skin, ink: UInt32 = 0xFF656F74,
                         bg: UInt32 = 0xFFFCFFFF):
    """A quiet hint pill centred on cx (11 px words, padded 7 10, lifted by the skin's first shadow)."""
    var st = TextStyle(UI, 400, False, 11)
    var w = measure(st, words) + 20
    var x = Float64(Int((cx - w / 2) * 2 + 0.5)) / 2
    draw_shadows(p, x, y, w, 28, 5, sk.shadow1)
    p.rect(x, y, w, 28, bg, 5)
    text_normal(p, st, words, x + 10, y + 7, ink)
    var cut = String("")
    var n = 0
    for c in words.codepoints():
        if n >= 40:
            break
        cut += String(c)
        n += 1
    bx.add(".mindmap-hint:" + cut, x, y, w, 28)


def draw_radial_steps[P: Painter](mut p: P, x: Float64, y: Float64, w: Float64, h: Float64, at_x: Float64, at_y: Float64, inner: UInt32,
                                  outer: UInt32, stop: Float64, radius: Float64):
    """A CSS radial-gradient(circle at at_x at_y, inner 0, outer stop%) over the box, farthest-corner sized, drawn as its
    8-bit colour steps: the box in the outer colour, then one circle per step inward, each in the exact colour the
    browser shows there. No gradient primitive is needed, so the CPU painter and the GPU draw it alike, with ≤ 3 × 255
    circles (here a handful). `radius`: the box's corner radius for the outer fill."""
    var cx = x + at_x * w
    var cy = y + at_y * h
    var fx = max(cx - x, x + w - cx)
    var fy = max(cy - y, y + h - cy)
    var r_end = (fx * fx + fy * fy) ** 0.5 * stop
    p.rect(x, y, w, h, outer, radius)
    # t where any channel's rounded value changes, from the outside in
    var ts = List[Float64]()
    for ch in range(3):
        var a = Float64(Int((inner >> UInt32(8 * ch)) & 0xFF))
        var b = Float64(Int((outer >> UInt32(8 * ch)) & 0xFF))
        if a == b:
            continue
        var lo = Int(min(a, b))
        var hi = Int(max(a, b))
        for v in range(lo, hi):
            ts.append(((Float64(v) + 0.5) - a) / (b - a))  # where a + (b − a)·t crosses v + .5
    # sort descending
    for i in range(len(ts)):
        for j in range(i + 1, len(ts)):
            if ts[j] > ts[i]:
                var tmp = ts[i]
                ts[i] = ts[j]
                ts[j] = tmp
    p.push_clip(x, y, w, h)
    for t in ts:
        var tt = t - 1e-6  # (the colour just inside this boundary)
        var c = UInt32(0xFF000000)
        for ch in range(3):
            var a = Float64(Int((inner >> UInt32(8 * ch)) & 0xFF))
            var b = Float64(Int((outer >> UInt32(8 * ch)) & 0xFF))
            c |= UInt32(Int(a + (b - a) * tt + 0.5)) << UInt32(8 * ch)
        p.circle(cx, cy, t * r_end, c)
    p.pop_clip()


# ------------------------------------------------ the tool island, generalized (goal 79, the canvas screen)

comptime DOCK_TOOL = 0
comptime DOCK_DIVIDER = 1
comptime DOCK_DOT = 2  # a colour dot in a tool button (the ink options)
comptime DOCK_ACCENT = 3  # the accent round button (the voice button)


@fieldwise_init
struct DockItem(Copyable, Movable):
    """One child of a tool island: its name in the Boxes ("[Select]", "#dock-more", ".dock-divider"), its icon (a Lucide
    name or an icon spec, see strokeicon), its kind, and for a dot its colour."""
    var name: String
    var icon: String
    var kind: Int
    var color: UInt32


def dock_height(items: List[DockItem]) -> Float64:
    """The island's height: children 2 apart (a column with gap 2), a divider 1 tall with 6 above and below, padded 6, a
    1 px border."""
    var inner = 0.0
    for i in range(len(items)):
        inner += 13.0 if items[i].kind == DOCK_DIVIDER else 44.0
        if i + 1 < len(items):
            inner += 2
    return inner + 14


def draw_dock[P: Painter](mut p: P, mut bx: Boxes, x: Float64, y: Float64, items: List[DockItem], active: String, k: Float64, sk: Skin,
                         group: String = "", stroke: Float64 = 1.7):
    """A vertical island of 44 px round buttons (the web's .tool-dock): the active tool filled with the ink and its icon in
    the panel's colour, a colour dot ringed in the panel and the edge, the accent button with its glow. Its box is
    [Canvas tools]; `group` names the column of children."""
    var h = dock_height(items)
    draw_shadows(p, x, y, 56, h, sk.radius, sk.shadow2)
    p.rect(x, y, 56, h, sk.panel, sk.radius)
    bx.add("[Canvas tools]", x, y, 56, h)
    if group != "":
        bx.add(group, x + 6, y + 7, 44, h - 14)
    var by = y + 7
    for i in range(len(items)):
        ref it = items[i]
        if it.kind == DOCK_DIVIDER:
            p.rect(x + 14, by + 6, 28, 1, sk.line, 0)
            bx.add(it.name, x + 14, by + 6, 28, 1)
            by += 13
        else:
            var cx = x + 28
            var cy = by + 22
            if it.kind == DOCK_ACCENT:
                draw_shadows(p, x + 6, by, 44, 44, 22, [Shadow(0, 6, 16, -6, sk.accent)])
                p.circle(cx, cy, 22, sk.accent)
                draw_icon(p, it.icon, x + 18, by + 12, 20, k, sk.accent_ink, 2.0)
            elif it.kind == DOCK_DOT:
                p.circle(cx, cy, 17, sk.edge)
                p.circle(cx, cy, 16, sk.panel)
                p.circle(cx, cy, 14, mix(rgba(0, 0, 0), 14, it.color))
                p.circle(cx, cy, 13, it.color)
                var dot_name = it.name + "-dot"
                if it.name.endswith("-trigger"):
                    dot_name = String(it.name[byte=:it.name.byte_length() - 8]) + "-dot"
                bx.add(dot_name, cx - 14, cy - 14, 28, 28)
            elif it.name == active:
                p.circle(cx, cy, 22, sk.ink)
                draw_icon(p, it.icon, x + 18, by + 12, 20, k, sk.panel, stroke)
            else:
                draw_icon(p, it.icon, x + 18, by + 12, 20, k, sk.ink_soft, stroke)
            bx.add(it.name, x + 6, by, 44, 44)
            by += 44
        if i + 1 < len(items):
            by += 2


def canvas_dock_items(ink: UInt32) -> List[DockItem]:
    """A canvas note's tool island as Personal Note draws it (its own 24 px dock icons, stroke 1.7)."""
    var out = List[DockItem]()
    out.append(DockItem("[Select]", "path d=M5 3l6 16 2.2-6.8L20 10 5 3z", DOCK_TOOL, 0))
    out.append(DockItem("[Text]", "path d=M5 6V4h14v2M12 4v16M9 20h6", DOCK_TOOL, 0))
    out.append(DockItem("[Pen]", "path d=M4 20l4-1 11-11-3-3L5 16l-1 4z|path d=M14 6l3 3", DOCK_TOOL, 0))
    out.append(DockItem("[Stroke eraser]", "path d=M8 20h12|path d=M4.5 15.5l9-9a2 2 0 012.8 0l2.2 2.2a2 2 0 010 2.8L12 18H7l-2.5-2.5z", DOCK_TOOL, 0))
    out.append(DockItem("[Shape]", "rect x=4 y=4 width=16 height=16 rx=3", DOCK_TOOL, 0))
    out.append(DockItem("[Sticky note]", "path d=M5 4h14v10l-5 6H5z|path d=M14 20v-6h5", DOCK_TOOL, 0))
    out.append(DockItem(".dock-divider", "", DOCK_DIVIDER, 0))
    out.append(DockItem("#ink-options-trigger", "", DOCK_DOT, ink))
    out.append(DockItem("#dock-more", "plus", DOCK_TOOL, 0))
    out.append(DockItem("#voice-divider", "", DOCK_DIVIDER, 0))
    out.append(DockItem("#voice-button", "rect x=9 y=3 width=6 height=11 rx=3|path d=M5.5 11a6.5 6.5 0 0013 0M12 17.5V21", DOCK_ACCENT, 0))
    return out^


def draw_history_island[P: Painter](mut p: P, mut bx: Boxes, x: Float64, y: Float64, k: Float64, sk: Skin):
    """Undo and redo in a pill (the web's .history-island: 48 tall, padded 0 6, 44 px buttons 2 apart)."""
    draw_shadows(p, x, y, 104, 48, 24, sk.shadow2)
    p.rect(x, y, 104, 48, sk.panel, 24)
    bx.add("#history-island", x, y, 104, 48)
    draw_icon(p, "path d=M9 7L4.5 11.5 9 16|path d=M5 11.5h9a5 5 0 010 10h-2", x + 7 + 12, y + 2 + 12, 20, k, sk.ink_soft, 1.7)
    bx.add("#undo", x + 7, y + 2, 44, 44)
    draw_icon(p, "path d=M15 7l4.5 4.5L15 16|path d=M19 11.5h-9a5 5 0 000 10h2", x + 53 + 12, y + 2 + 12, 20, k, sk.ink_soft, 1.7)
    bx.add("#redo", x + 53, y + 2, 44, 44)


def draw_page_zoom[P: Painter](mut p: P, mut bx: Boxes, right: Float64, y: Float64, percent: Int, k: Float64, sk: Skin):
    """The canvas's zoom island ending at `right` (the web's .zoom-control): minus, the zoom (a press resets it), plus, a
    divider, fit all pages."""
    var x = right - 185
    draw_shadows(p, x, y, 185, 48, 24, sk.shadow2)
    p.rect(x, y, 185, 48, sk.panel, 24)
    bx.add("#zoom-control", x, y, 185, 48)
    draw_icon(p, "minus", x + 7 + 10.5, y + 6 + 10.5, 15, k, sk.ink_soft)
    bx.add("#zoom-out", x + 7, y + 6, 36, 36)
    var st = TextStyle(MONO, 400, False, 11.5)
    text_at(p, st, String(percent) + "%", x + 45 + 24, y + 8, 32, sk.ink_soft, ALIGN_CENTER)
    bx.add("#zoom-value", x + 45, y + 8, 48, 32)
    draw_icon(p, "plus", x + 95 + 10.5, y + 6 + 10.5, 15, k, sk.ink_soft)
    bx.add("#zoom-in", x + 95, y + 6, 36, 36)
    p.rect(x + 136, y + 15, 1, 18, sk.line, 0)
    draw_icon(p, "maximize-2", x + 142 + 10.5, y + 6 + 10.5, 15, k, sk.ink_soft)
    bx.add("#zoom-fit", x + 142, y + 6, 36, 36)
