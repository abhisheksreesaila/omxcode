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

from std.collections import Dict
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
    """Named rects in layout px, in drawing order (the last one drawn is on top). The framework's pieces record generic
    names ("panel", "panel.row:<words>", "title.button"); an app that wants its own names (a test comparing with its web
    twin's DOM ids) gives a table with alias(): "panel" → "#sidebar", "panel.row:" → "row:{}" ({} takes the words after
    the colon). Lookups (find, hit, hit_any) take either name (D-7928)."""
    var names: List[String]
    var r: List[Float64]
    var aliases: Dict[String, String]
    var seen: Dict[String, Int]  # how many times each name was recorded this frame (duplicates get @2, @3…)

    def __init__(out self):
        self.names = List[String]()
        self.r = List[Float64]()
        self.aliases = Dict[String, String]()
        self.seen = Dict[String, Int]()

    def clear(mut self):
        """A new frame: the boxes go, the app's names stay."""
        self.names.clear()
        self.r.clear()
        self.seen = Dict[String, Int]()

    def alias(mut self, generic: String, name: String):
        self.aliases[generic] = name

    def name_of(self, generic: String) -> String:
        """The app's name for a generic one (itself when the app gave none)."""
        if len(self.aliases) == 0:
            return generic
        try:
            if generic in self.aliases:
                return self.aliases[generic].replace("{}", "")
            var c = generic.find(":")
            if c >= 0:
                var pre = String(generic[byte=0:c + 1])
                if pre in self.aliases:
                    var d = self.aliases[pre]
                    var rest = String(generic[byte=c + 1:])
                    if d.find("{}") >= 0:
                        return d.replace("{}", rest)
                    return d + rest
        except:
            pass
        return generic

    def add(mut self, generic: String, x: Float64, y: Float64, w: Float64, h: Float64):
        """Records a box under the app's name; a name drawn again gets @2, @3… (as the reference names duplicates)."""
        var name = self.name_of(generic)
        var n = self.seen.get(name, 0) + 1
        self.seen[name] = n
        self.names.append(name if n == 1 else name + "@" + String(n))
        self.r.append(x)
        self.r.append(y)
        self.r.append(w)
        self.r.append(h)

    def hit(self, x: Float64, y: Float64, prefix: String = "") -> String:
        """The topmost box under a point (with this prefix): its name, or ""."""
        var pf = self.name_of(prefix)
        var i = len(self.names) - 1
        while i >= 0:
            if self.names[i].startswith(pf):
                var bx = self.r[i * 4]
                var by = self.r[i * 4 + 1]
                if x >= bx and y >= by and x < bx + self.r[i * 4 + 2] and y < by + self.r[i * 4 + 3]:
                    return self.names[i]
            i -= 1
        return ""

    def hit_any(self, x: Float64, y: Float64, prefixes: List[String]) -> String:
        """The topmost box under a point among those whose names start with one of `prefixes` (the things a tap can
        act on; containers recorded after their children don't swallow the tap)."""
        var pfs = List[String]()
        for ref q in prefixes:
            pfs.append(self.name_of(q))
        var i = len(self.names) - 1
        while i >= 0:
            var bx = self.r[i * 4]
            var by = self.r[i * 4 + 1]
            if x >= bx and y >= by and x < bx + self.r[i * 4 + 2] and y < by + self.r[i * 4 + 3]:
                for ref pf in pfs:
                    if self.names[i].startswith(pf):
                        return self.names[i]
            i -= 1
        return ""

    def find(self, generic: String) -> Int:
        var name = self.name_of(generic)
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

def draw_shadows[P: Painter](mut p: P, x: Float64, y: Float64, w: Float64, h: Float64, radius: Float64, shadows: List[Shadow],
                             hole_margin: Float64 = -1):
    """CSS box-shadows under a rounded rect: a spread ring as one rect, a blurred one as layered rects whose summed alpha
    follows the Gaussian's falloff (σ = blur / 2), so the same picture reaches the CPU painter and the GPU.
    hole_margin ≥ 0 (D-7973): the caller covers the box, inset by hole_margin, with something opaque right after: each
    layer leaves out its middle that lies inside that (Painter.rect_hole): the same picture with a fraction of the fill."""
    for s in shadows:
        var a = Float64(Int((s.color >> 24) & 0xFF)) / 255.0
        var off = max(abs(s.dx), abs(s.dy))
        if s.blur <= 0:
            var rx = x - s.spread + s.dx
            var ry = y - s.spread + s.dy
            if hole_margin >= 0:
                p.rect_hole(rx, ry, w + 2 * s.spread, h + 2 * s.spread, s.color, radius + s.spread, s.spread + hole_margin + off)
            else:
                p.rect(rx, ry, w + 2 * s.spread, h + 2 * s.spread, s.color, radius + s.spread)
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
            if hole_margin >= 0:
                p.rect_hole(x - e + s.dx, y - e + s.dy, w + 2 * e, h + 2 * e, with_alpha(s.color, min(1.0, la)), max(0.0, radius + e), e + hole_margin + off)
            else:
                p.rect(x - e + s.dx, y - e + s.dy, w + 2 * e, h + 2 * e, with_alpha(s.color, min(1.0, la)), max(0.0, radius + e))


def draw_lifted[P: Painter](mut p: P, x: Float64, y: Float64, w: Float64, h: Float64, radius: Float64, shadows: List[Shadow], fill: UInt32):
    """A lifted surface (a panel, an island, a window): its shadows, then its rounded rect. An opaque fill hides the
    shadows' middle, so those layers leave it out (D-8008: a 760 px panel's ten layers cost the GPU four windows of
    overdraw; the same picture without). The hole stays inside the rounded corners: 0.3 of the radius and a pixel in."""
    var hm = 0.3 * radius + 1 if ((fill >> 24) & 0xFF) == 0xFF else -1.0
    draw_shadows(p, x, y, w, h, radius, shadows, hm)
    p.rect(x, y, w, h, fill, radius)


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
    # (D-8014: an opaque fill hides the border rect's middle: left out of a big one, a window-sized box fills once, not twice)
    var hole = bw + 0.3 * radius + 1
    if ((fill >> 24) & 0xFF) == 0xFF and min(w, h) > 2 * hole + 48:
        p.rect_hole(x, y, w, h, border, radius, hole)
    else:
        p.rect(x, y, w, h, border, radius)
    p.rect(x + bw, y + bw, w - 2 * bw, h - 2 * bw, fill, max(0.0, radius - bw))


def draw_desk[P: Painter](mut p: P, w: Float64, h: Float64, k: Float64, sk: Skin, cover: List[Float64] = List[Float64]()):
    """The desk: its colour and a dot every 22 px (radial-gradient(dot 1px, transparent 1.2px) / 22px 22px). cover (x0, y0,
    x1, y1): something opaque drawn over it after: the dots wholly inside are left out (D-8024: a page's host hides 2,400
    of 2,700)."""
    p.fill(sk.desk)
    var cov = len(cover) == 4
    var y = 11.0
    while y < h + 11:
        var x = 11.0
        while x < w + 11:
            if cov and x - 2.5 > cover[0] and x + 2.5 < cover[2] and y - 2.5 > cover[1] and y + 2.5 < cover[3]:
                x += 22
                continue
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
    draw_lifted(p, x, y, size, size, size / 2, sk.shadow2, bg)
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


def _curve_inset(d: Float64, r: Float64) -> Float64:
    """How far in a rounded corner of radius r is at distance d from its straight edge (0 past the corner)."""
    if d >= r:
        return 0.0
    var e = r - d
    return r - sqrt(max(r * r - e * e, 0.0))


def draw_inner_ring[P: Painter](mut p: P, x: Float64, y: Float64, w: Float64, h: Float64, ix: Float64, iy: Float64, iw: Float64, ih: Float64,
                                ir: Float64, color: UInt32, offset: Float64 = 4, width: Float64 = 2):
    """A keyboard focus ring inside a control (CSS `outline: <width> solid; outline-offset: -<offset>px`: a rect frame
    from offset − width to offset inside the box (x, y, w, h)), cut by the rounded island it sits in (ix, iy, iw, ih,
    radius ir): its bars end where the island's curve does (D-7943)."""
    var o = offset - width  # (the frame's outer edge, inside the box)
    var fx0 = x + o
    var fy0 = y + o
    var fx1 = x + w - o
    var fy1 = y + h - o

    for side in range(2):  # top and bottom bars
        var by = fy0 if side == 0 else fy1 - width
        var d = (by + width / 2) - iy if side == 0 else iy + ih - (by + width / 2)
        var cut = _curve_inset(d, ir)
        var a = max(fx0, ix + cut)
        var b = min(fx1, ix + iw - cut)
        if b > a:
            p.rect(a, by, b - a, width, color, 0)
    for side in range(2):  # left and right bars, between the top and bottom ones
        var bx0 = fx0 if side == 0 else fx1 - width
        var d = (bx0 + width / 2) - ix if side == 0 else ix + iw - (bx0 + width / 2)
        var cut = _curve_inset(d, ir)
        var a = max(fy0 + width, iy + cut)
        var b = min(fy1 - width, iy + ih - cut)
        if b > a:
            p.rect(bx0, a, width, b - a, color, 0)


def draw_title_island[P: Painter](mut p: P, mut bx: Boxes, slot_x0: Float64, slot_x1: Float64, title: String, emoji: String, tint: UInt32,
                                  k: Float64, sk: Skin, face_emoji: String = "", focused: Bool = False):
    """The note's title on an island centred over the note area (with its emoji button for canvas and map notes).
    focused: the title button has the keyboard's focus (after a rename by Enter): the web's focus ring inside it."""
    var has_icon = emoji != ""
    var w = title_island_width(title, has_icon)
    var x = Float64(Int(((slot_x0 + slot_x1) / 2 - w / 2) * 2 + 0.5)) / 2  # (centred as flex does: half-px steps)
    var y = 16.0
    draw_lifted(p, x, y, w, 44, 22, sk.shadow2, sk.panel)
    bx.add("title", x, y, w, 44)
    var title_x = x + 1 + 18
    bx.add("title.face:" + face_emoji + title, x + 1, y + 1, w - 2, 42)
    if has_icon:
        draw_emoji_tile(p, emoji, x + 1 + 10, y + 1 + 9, 24, 7, 14, mix(tint, 36, sk.panel))
        bx.add("title.icon", x + 1, y + 1, 44, 42)
        title_x = x + 1 + 44
    bx.add("title.button", x + 1, y + 1, w - 2, 42)
    var st = TextStyle(UI, 400, False, 16)
    var tw = measure(st, title)
    text_normal(p, st, title, title_x, y + (44 - line_metrics(st).normal_height()) / 2, sk.ink)
    bx.add("title.words", title_x, y + (44 - line_metrics(st).normal_height()) / 2, tw, line_metrics(st).normal_height())
    if focused:  # (the title button: the island less its emoji button)
        var hx = x + 1 + (44.0 if has_icon else 0.0)
        draw_inner_ring(p, hx, y + 1, x + w - 1 - hx, 42, x, y, w, 44, 22, sk.accent)


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


@fieldwise_init
struct Shelf(Copyable, Movable):
    """A shelf of groups in the notes panel: the groups whose category is `key`, under a head with its label and icon."""
    var key: String
    var label: String
    var icon: String
    var open: Bool  # open at start
    var show_count: Bool  # its group count beside the chevron (and, folded, it keeps a drop target)


@fieldwise_init
struct SkinChoice(Copyable, Movable):
    """A skin the panel's footer offers: its name, the words its dot is called by, the dot's colour."""
    var name: String
    var label: String
    var swatch: UInt32


struct PanelConfig(Copyable, Movable):
    """What an app puts in the notes panel (D-7928): its name, its main action and shortcut, the shelf of loose notes,
    the shelves of groups, the words for an empty shelf and the skin row. The defaults are neutral."""
    var brand: String
    var action_label: String
    var action_icon: String
    var action_key: String  # "" : no shortcut shown
    var loose_label: String
    var loose_icon: String
    var loose_open: Bool
    var shelves: List[Shelf]
    var empty_text: String
    var skin_label: String
    var skins: List[SkinChoice]

    def __init__(out self):
        self.brand = "Notes"
        self.action_label = "New note"
        self.action_icon = "plus"
        self.action_key = ""
        self.loose_label = "Loose"
        self.loose_icon = "inbox"
        self.loose_open = True
        self.shelves = List[Shelf]()
        self.empty_text = "Empty"
        self.skin_label = "Theme"
        self.skins = List[SkinChoice]()


struct NotesPanel(Movable):
    """The floating notes panel's state: what it shows (its PanelConfig), which shelves are open, which note is active."""
    var notes: List[PanelNote]
    var notebooks: List[PanelNotebook]
    var active: Int
    var inbox_open: Bool
    var open_shelves: List[Bool]  # one per cfg.shelves
    var skin_name: String
    var cfg: PanelConfig
    var open_books: List[Int]  # the notebooks opened to their notes, by id
    var scroll: Float64  # the list, scrolled (layout px); how far it can go, and where it shows, at the last draw
    var scroll_max: Float64
    var list_y0: Float64
    var list_y1: Float64
    var hits: List[Float64]  # what the last draw showed in the list: kind (0 a note, 1 a notebook), id, x, y, w, h each

    def __init__(out self, cfg: PanelConfig = PanelConfig()):
        self.notes = List[PanelNote]()
        self.notebooks = List[PanelNotebook]()
        self.active = 0
        self.inbox_open = cfg.loose_open
        self.open_shelves = List[Bool]()
        for ref sh in cfg.shelves:
            self.open_shelves.append(sh.open)
        self.skin_name = cfg.skins[0].name if len(cfg.skins) > 0 else String("")
        self.cfg = cfg.copy()
        self.open_books = List[Int]()
        self.scroll = 0
        self.scroll_max = 0
        self.list_y0 = 0
        self.list_y1 = 0
        self.hits = List[Float64]()

    def hit(self, x: Float64, y: Float64, kind: Int) -> Int:
        """The note (kind 0) or notebook (1) whose row is at (x, y), by id; -1: none (by where it was drawn: two notes may
        have the same name)."""
        if y < self.list_y0 or y >= self.list_y1:
            return -1
        for i in range(0, len(self.hits), 6):
            if Int(self.hits[i]) == kind and x >= self.hits[i + 2] and x < self.hits[i + 2] + self.hits[i + 4] and y >= self.hits[i + 3] and y < self.hits[i + 3] + self.hits[i + 5]:
                return Int(self.hits[i + 1])
        return -1

    def toggle_book(mut self, id: Int):
        for i in range(len(self.open_books)):
            if self.open_books[i] == id:
                _ = self.open_books.pop(i)
                return
        self.open_books.append(id)

    def reveal(mut self, id: Int):
        """A note's row where it can be seen: its notebook and shelf opened (the web's revealNotebook)."""
        for ref n in self.notes:
            if n.id == id and n.notebook != 0:
                self.reveal_book(n.notebook)

    def reveal_book(mut self, id: Int):
        for ref nb in self.notebooks:
            if nb.id == id:
                for i in range(len(self.cfg.shelves)):
                    if self.cfg.shelves[i].key == nb.category:
                        self.open_shelves[i] = True
                if id not in self.open_books:
                    self.open_books.append(id)

    def wheel(mut self, dy: Float64) -> Bool:
        """The list scrolled by dy px (down: positive); True when it moved."""
        var was = self.scroll
        self.scroll = min(max(self.scroll + dy, 0), self.scroll_max)
        return self.scroll != was

    def _book_notes(self, id: Int) -> List[Int]:
        var out = List[Int]()
        for i in range(len(self.notes)):
            if self.notes[i].notebook == id:
                out.append(i)
        return out^

    def _list_height(self) -> Float64:
        """How high the whole list is (as draw lays it out)."""
        var n = len(self._book_notes(0))
        var h = 38.0 + ((Float64(n) * 35 - 1 + 8) if self.inbox_open else 2.0)
        for s in range(len(self.cfg.shelves)):
            h += 4 + 36
            if self.open_shelves[s]:
                var b = 0.0
                for ref nb in self.notebooks:
                    if nb.category == self.cfg.shelves[s].key:
                        b += 31 + self._book_height(nb.id)
                h += 26.8 + 2 if b == 0 else b - 1 + 2
            else:
                h += 2
        return h

    def _book_height(self, id: Int) -> Float64:
        """The rows under an opened notebook (0: folded)."""
        if id not in self.open_books:
            return 0
        var n = len(self._book_notes(id))
        return 2 + (Float64(n) * 35 - 1 if n > 0 else 26.8) + 6

    def toggle_shelf(mut self, at: Int):
        """Folds or opens a shelf: 0 the loose notes, 1… the shelves in order (a tap on its head)."""
        if at == 0:
            self.inbox_open = not self.inbox_open
        elif at >= 1 and at <= len(self.open_shelves):
            self.open_shelves[at - 1] = not self.open_shelves[at - 1]

    def draw[P: Painter](mut self, mut p: P, mut bx: Boxes, k: Float64, sk: Skin, h: Float64):
        var x = 16.0
        var y = 72.0
        var w = 280.0
        var ph = h - 72 - 16
        draw_lifted(p, x, y, w, ph, sk.radius, sk.shadow2, sk.panel)
        bx.add("panel", x, y, w, ph)
        var cx = x + 1 + 10  # content box: border 1, padding 14 10
        var cw = w - 2 - 20
        var cy = y + 1 + 14
        # brand
        bx.add("panel.brand", cx, cy, cw, 44)
        var mx = cx + 6
        var my = cy + 2
        p.rect(mx, my, 26, 30, sk.accent, 5)  # (4px 7px 7px 4px: drawn with the mean corner)
        p.rect(mx, my, 3, 30, mix(sk.accent, 62, rgba(0, 0, 0)), 1.5)
        p.rect(mx + 26 - 5 - 3, my, 3, 30, with_alpha(sk.accent_ink, 0.7), 0)
        bx.add("panel.brand-mark", mx, my, 26, 30)
        var bst = TextStyle(sk.display, sk.display_weight, sk.display_italic, 17)
        bst.letter_spacing = sk.title_track * 17
        text_at(p, bst, self.cfg.brand, mx + 26 + 9, my + 5, 20, sk.ink)
        bx.add("panel.brand-name:" + self.cfg.brand, mx + 26 + 9, my + 5, cw - 6 - 26 - 9 - 6, 20)
        cy += 44 + 2
        # quick note
        draw_shadows(p, cx, cy, cw, 38, 19, sk.shadow1)
        p.rect(cx, cy, cw, 38, sk.accent_fill, 19)
        bx.add("panel.action", cx, cy, cw, 38)
        draw_icon(p, self.cfg.action_icon, cx + 12, cy + 11, 16, k, sk.accent_ink)
        var qst = TextStyle(UI, 500, False, 13)
        text_normal(p, qst, self.cfg.action_label, cx + 12 + 16 + 8, cy + (38 - 17) / 2, sk.accent_ink)
        if self.cfg.action_key != "":
            var kst = TextStyle(MONO, 400, False, 11)
            var kw = measure(kst, self.cfg.action_key) + 14
            var kx = cx + cw - 12 - kw
            var ky = cy + (38 - 20.3) / 2
            var kc = with_alpha(sk.accent_ink, 0.8)
            p.rect(kx, ky, kw, 20.3, with_alpha(sk.accent_ink, 0.3 * 0.8), 6)
            p.rect(kx + 1, ky + 1, kw - 2, 18.3, sk.accent_fill, 5)
            text_at(p, kst, self.cfg.action_key, kx + 7, ky + 3, 14.3, kc)
            bx.add("panel.action-key", kx, ky, kw, 20.3)
        cy += 38 + 10 + 2  # margin 10, the panel's gap 2
        # the navigator: Inbox and the four shelves
        bx.add("panel.navigator", cx - 4, cy, cw + 8, y + ph - 1 - 14 - (29 + 6 + 2) - cy)
        self.hits.clear()
        self.list_y0 = cy
        self.list_y1 = y + ph - 1 - 14 - (29 + 6 + 2)
        self.scroll_max = max(self._list_height() - (self.list_y1 - self.list_y0), 0)
        self.scroll = min(self.scroll, self.scroll_max)
        var clipped = self.scroll_max > 0  # (everything fits: drawn as it stands)
        if clipped:
            p.push_clip(cx - 4, self.list_y0, cw + 8, self.list_y1 - self.list_y0)
            cy -= self.scroll
        var list_top = cy
        var inbox_notes = List[Int]()
        for i in range(len(self.notes)):
            if self.notes[i].notebook == 0:
                inbox_notes.append(i)
        var inbox_h = 2 + 34 + 2 + ((Float64(len(inbox_notes)) * 35 - 1 + 6 + 2) if self.inbox_open else 0.0)
        if self.inbox_open:
            p.rect(cx, cy, cw, inbox_h, sk.shelf, 13)
        bx.add("panel.shelf", cx, cy, cw, inbox_h)
        cy = self._shelf(p, bx, k, sk, cx, cy, cw, self.cfg.loose_label, self.cfg.loose_icon, self.inbox_open, String(len(inbox_notes)), True, False)
        if self.inbox_open:
            var rows_y = cy + 2
            var rows_h = Float64(len(inbox_notes)) * 35 - 1
            p.rect(cx + 2 + 13, rows_y, 1.5, rows_h, sk.line, 0)
            bx.add("panel.loose-rows:" + self.cfg.loose_label, cx + 2 + 13, rows_y, cw - 4 - 13, rows_h)
            var ry = rows_y
            for i in inbox_notes:
                if ry + 35 > self.list_y0 and ry < self.list_y1:
                    self._note_row(p, bx, k, sk, cx + 2 + 13 + 1.5 + 7.5, ry, cw - 4 - 13 - 9, self.notes[i])
                    self._hit(0, self.notes[i].id, cx + 2 + 13 + 1.5 + 7.5, ry, cw - 4 - 13 - 9, 34)
                ry += 35
            cy = rows_y + rows_h + 6 + 2
        else:
            cy += 2
        for s in range(len(self.cfg.shelves)):
            var shelf = self.cfg.shelves[s].copy()
            cy += 4
            var books = List[Int]()
            for i in range(len(self.notebooks)):
                if self.notebooks[i].category == shelf.key:
                    books.append(i)
            var is_archive = shelf.show_count
            var open = self.open_shelves[s]
            var rows_under = 0.0  # (the notes of the opened notebooks)
            for i in books:
                rows_under += self._book_height(self.notebooks[i].id)
            var sh = 2 + 34 + 2 + ((26.8 if len(books) == 0 else Float64(len(books)) * 31 - 1 + rows_under) if open else 0.0)
            if open:
                p.rect(cx, cy, cw, sh, sk.shelf, 13)
            cy = self._shelf(p, bx, k, sk, cx, cy, cw, shelf.label, shelf.icon, open, String(len(books)) if is_archive else "", False, is_archive)
            if open:
                if len(books) == 0:
                    var est = TextStyle(UI, 400, False, 12)
                    text_at(p, est, self.cfg.empty_text, cx + 2 + 8, cy + 5, 16.8, sk.ui_muted)
                    bx.add("panel.empty:" + self.cfg.empty_text, cx + 2, cy, cw - 4, 26.8)
                    cy += 26.8 + 2
                else:
                    var ny = cy
                    for i in books:
                        self._notebook_row(p, bx, k, sk, cx + 2, ny, cw - 4, self.notebooks[i])
                        self._hit(1, self.notebooks[i].id, cx + 2, ny, cw - 4, 30)
                        var bh = self._book_height(self.notebooks[i].id)
                        if bh > 0:
                            var inside = self._book_notes(self.notebooks[i].id)
                            var gy = ny + 30 + 2
                            p.rect(cx + 2 + 13, gy, 1.5, bh - 8, sk.line, 0)
                            if len(inside) == 0:
                                text_at(p, TextStyle(UI, 400, False, 12), "Empty", cx + 2 + 13 + 9 + 8, gy + 5, 16.8, sk.ui_muted)
                            for j in inside:
                                if gy + 35 > self.list_y0 and gy < self.list_y1:
                                    self._note_row(p, bx, k, sk, cx + 2 + 13 + 1.5 + 7.5, gy, cw - 4 - 13 - 9, self.notes[j])
                                    self._hit(0, self.notes[j].id, cx + 2 + 13 + 1.5 + 7.5, gy, cw - 4 - 13 - 9, 34)
                                gy += 35
                        ny += 31 + bh
                    cy = ny - 1 + 2
            else:
                if is_archive:
                    bx.add("panel.empty:" + self.cfg.empty_text, cx + 2, cy, cw - 4, 10)
                cy += 2
        bx.add("panel.list", cx, list_top, cw, cy - list_top)
        if clipped:
            p.pop_clip()
            var track = self.list_y1 - self.list_y0
            var th = max(24.0, track * track / (track + self.scroll_max))
            p.rect(cx + cw + 1, self.list_y0 + (track - th) * self.scroll / self.scroll_max, 4, th, with_alpha(sk.ink, 0.22), 2)
        # footer
        var fy = y + ph - 1 - 14 - 29
        p.rect(cx - 2, fy, cw + 4, 1, sk.line, 0)
        bx.add("panel.footer", cx - 2, fy, cw + 4, 29)
        var fst = TextStyle(MONO, 400, False, 12)
        text_normal(p, fst, self.cfg.skin_label, cx - 2 + 8, fy + 1 + 11, sk.ui_muted)
        bx.add("panel.skin-label:" + self.cfg.skin_label, cx - 2 + 8, fy + 12, measure(fst, self.cfg.skin_label), 16)
        var ns = len(self.cfg.skins)
        var sw = Float64(ns) * 25 - 7 if ns > 0 else 0.0
        var sx = cx + cw + 2 - 6 - sw
        var sy = fy + 11
        if ns > 0:
            bx.add("panel.skins", sx, sy, sw, 18)
        for i in range(ns):
            ref c = self.cfg.skins[i]
            var ox = sx + Float64(i) * 25
            if c.name == self.skin_name:
                p.circle(ox + 9, sy + 9, 11, sk.accent)
            p.circle(ox + 9, sy + 9, 9, sk.panel)
            p.circle(ox + 9, sy + 9, 7, c.swatch)
            bx.add("panel.skin:" + c.label, ox, sy, 18, 18)

    def _hit(mut self, kind: Int, id: Int, x: Float64, y: Float64, w: Float64, h: Float64):
        for v in [Float64(kind), Float64(id), x, y, w, h]:
            self.hits.append(v)

    def _shelf[P: Painter](self, mut p: P, mut bx: Boxes, k: Float64, sk: Skin, x: Float64, y: Float64, w: Float64, label: String, icon: String,
                           open: Bool, count: String, badge: Bool, archive: Bool) -> Float64:
        """A shelf's head (and its open wash, drawn behind what follows); the y below the head."""
        _ = archive
        var hx = x + 2
        var hy = y + 2
        bx.add("panel.shelf-head", hx, hy, w - 4, 34)
        draw_icon(p, icon, hx + 8, hy + 9, 16, k, sk.ink_soft, 1.8 if icon == "archive" else 2.0)
        bx.add("panel.shelf-icon", hx + 8, hy + 9, 16, 16)
        var st = TextStyle(UI, 600, False, 13.5)
        text_at(p, st, label, hx + 8 + 16 + 8, hy + 10.25, 13.5, sk.ink)
        if badge:
            var bst = TextStyle(MONO, 500, False, 10.5)
            var tw = measure(bst, count)
            var bw = tw + 10
            var bxx = hx + w - 4 - 8 - 14 - 8 - bw
            p.rect(bxx, hy + 8, bw, 18, with_alpha(sk.state, 0.10), 4)
            text_at(p, bst, count, bxx + 5, hy + 8, 18, sk.ink)
            bx.add("panel.badge", bxx, hy + 8, bw, 18)
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
        text_at(p, st, fitted(st, n.title, w - 8 - 24 - 8 - 8 - 14 - 8), x + 8 + 24 + 8, y + 8.875, 16.25, fg)
        var icon = "git-fork" if n.kind == "mindmap" else ("file-pen" if n.kind == "page" else "file-text")
        draw_icon(p, icon, x + w - 8 - 14, y + 10, 14, k, with_alpha(fg, 0.65))
        bx.add("panel.row:" + n.emoji + " " + n.title, x, y, w, 34)

    def _notebook_row[P: Painter](self, mut p: P, mut bx: Boxes, k: Float64, sk: Skin, x: Float64, y: Float64, w: Float64, nb: PanelNotebook):
        if nb.icon == "":
            p.rect(x + 6, y + 6, 18, 18, nb.color, 6)
            var lst = TextStyle(UI, 600, False, 11)
            var letter = String(nb.name[byte=0:1]).upper()
            text_at(p, lst, letter, x + 15, y + 6, 18, rgba(255, 255, 255), ALIGN_CENTER)
        else:
            draw_icon(p, nb.icon, x + 7, y + 7, 16, k, nb.color)
        bx.add("panel.group-icon:" + nb.name, x, y, 30, 30)
        var st = TextStyle(UI, 400, False, 13)
        text_normal(p, st, fitted(st, nb.name, w - 33 - 8 - 14 - 9 - 24), x + 33, y + 6.5, sk.ink_soft)
        var cst = TextStyle(MONO, 400, False, 11)
        var cnt = String(nb.count)
        var tw = measure(cst, cnt)
        text_at(p, cst, cnt, x + w - 8 - 14 - 9 - tw, y + 9.5, 11, sk.ui_muted)
        draw_icon(p, "chevron-down" if nb.id in self.open_books else "chevron-right", x + w - 8 - 14, y + 8, 14, k, with_alpha(sk.ink_soft, 0.7))
        bx.add("panel.group-row:" + nb.name + " " + cnt + (" " + String(nb.name[byte=0:1]).upper() if nb.icon == "" else ""), x, y, w, 30)


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
    draw_lifted(p, x, y, 56, h, sk.radius, sk.shadow2, sk.panel)
    bx.add("dock", x, y, 56, h)
    if group != "":
        bx.add(group, x + 6, y + 7, 44, inner)
    var by = y + 7
    for i in range(len(labels)):
        if labels[i] == "":
            p.rect(x + 14, by + 8, 28, 1, sk.line, 0)
            bx.add("dock.divider", x + 14, by + 8, 28, 1)
            by += 17
        else:
            draw_icon(p, icons[i], x + 18, by + 12, 20, k, sk.ink_soft)
            bx.add("dock.tool:" + labels[i], x + 6, by, 44, 44)
            by += 44 + (2.0 if i + 1 < len(labels) and labels[i + 1] != "" else 0.0)


def draw_zoom_island[P: Painter](mut p: P, mut bx: Boxes, x: Float64, y: Float64, percent: Int, k: Float64, sk: Skin):
    """The map's zoom island: minus, the zoom as a label (a press resets it), plus."""
    p.rect(x, y, 132, 42, sk.line, sk.radius_control)
    p.rect(x + 1, y + 1, 130, 40, sk.panel, sk.radius_control - 1)
    bx.add("zoom", x, y, 132, 42)
    draw_icon(p, "minus", x + 4 + 9, y + 4 + 9, 16, k, sk.muted)
    bx.add("zoom.out", x + 4, y + 4, 34, 34)
    var st = TextStyle(UI, 400, False, 11)
    text_normal(p, st, String(percent) + "%", x + 40 + 26, y + 4 + (34 - 14) / 2, sk.muted if sk.dark else 0xFF656F74, ALIGN_CENTER)
    bx.add("zoom.label:" + String(percent) + "%", x + 40, y + 4, 52, 34)
    draw_icon(p, "plus", x + 94 + 9, y + 4 + 9, 16, k, sk.muted)
    bx.add("zoom.in", x + 94, y + 4, 34, 34)


def draw_hint[P: Painter](mut p: P, mut bx: Boxes, cx: Float64, y: Float64, words: String, sk: Skin, ink: UInt32 = 0xFF656F74,
                         bg: UInt32 = 0xFFFCFFFF):
    """A quiet hint pill centred on cx (11 px words, padded 7 10, lifted by the skin's first shadow)."""
    var st = TextStyle(UI, 400, False, 11)
    var w = measure(st, words) + 20
    var x = Float64(Int((cx - w / 2) * 2 + 0.5)) / 2
    if sk.dark:  # (workspace-theme.css: the surface, the ink, a line, no shadow)
        p.rect(x, y, w, 28, sk.line, 5)
        p.rect(x + 1, y + 1, w - 2, 26, sk.panel, 4)
        text_normal(p, st, words, x + 10, y + 7, sk.ink)
    else:
        draw_lifted(p, x, y, w, 28, 5, sk.shadow1, bg)
        text_normal(p, st, words, x + 10, y + 7, ink)
    var cut = String("")
    var n = 0
    for c in words.codepoints():
        if n >= 40:
            break
        cut += String(c)
        n += 1
    bx.add("hint:" + cut, x, y, w, 28)


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
    for q in range(len(ts)):
        var t = ts[q]
        if q > 0 and t == ts[q - 1]:  # (two channels change at the same place: one circle, its colour the same)
            continue
        var tt = t - 1e-6  # (the colour just inside this boundary)
        var c = UInt32(0xFF000000)
        for ch in range(3):
            var a = Float64(Int((inner >> UInt32(8 * ch)) & 0xFF))
            var b = Float64(Int((outer >> UInt32(8 * ch)) & 0xFF))
            c |= UInt32(Int(a + (b - a) * tt + 0.5)) << UInt32(8 * ch)
        # (D-8012: the next circle inward hides this one's middle: the square inside that circle is left out, or 25 nested
        # discs cost the GPU ten windows of overdraw)
        var r = t * r_end
        var next = 0.0
        for n in range(q + 1, len(ts)):
            if ts[n] != t:
                next = ts[n] * r_end
                break
        var square = next * 0.70710678 - 1.5  # (half its side, the edge's antialiasing off)
        if square > 4 and r > 8:
            p.rect_hole(cx - r, cy - r, 2 * r, 2 * r, c, r, r - square)
        else:
            p.circle(cx, cy, r, c)
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
    draw_lifted(p, x, y, 56, h, sk.radius, sk.shadow2, sk.panel)
    bx.add("dock", x, y, 56, h)
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


def draw_history_island[P: Painter](mut p: P, mut bx: Boxes, x: Float64, y: Float64, k: Float64, sk: Skin):
    """Undo and redo in a pill (the web's .history-island: 48 tall, padded 0 6, 44 px buttons 2 apart)."""
    draw_lifted(p, x, y, 104, 48, 24, sk.shadow2, sk.panel)
    bx.add("history", x, y, 104, 48)
    draw_icon(p, "path d=M9 7L4.5 11.5 9 16|path d=M5 11.5h9a5 5 0 010 10h-2", x + 7 + 12, y + 2 + 12, 20, k, sk.ink_soft, 1.7)
    bx.add("history.undo", x + 7, y + 2, 44, 44)
    draw_icon(p, "path d=M15 7l4.5 4.5L15 16|path d=M19 11.5h-9a5 5 0 000 10h2", x + 53 + 12, y + 2 + 12, 20, k, sk.ink_soft, 1.7)
    bx.add("history.redo", x + 53, y + 2, 44, 44)


def draw_page_zoom[P: Painter](mut p: P, mut bx: Boxes, right: Float64, y: Float64, percent: Int, k: Float64, sk: Skin):
    """The canvas's zoom island ending at `right` (the web's .zoom-control): minus, the zoom (a press resets it), plus, a
    divider, fit all pages."""
    var x = right - 185
    draw_lifted(p, x, y, 185, 48, 24, sk.shadow2, sk.panel)
    bx.add("pagezoom", x, y, 185, 48)
    draw_icon(p, "minus", x + 7 + 10.5, y + 6 + 10.5, 15, k, sk.ink_soft)
    bx.add("pagezoom.out", x + 7, y + 6, 36, 36)
    var st = TextStyle(MONO, 400, False, 11.5)
    text_at(p, st, String(percent) + "%", x + 45 + 24, y + 8, 32, sk.ink_soft, ALIGN_CENTER)
    bx.add("pagezoom.value", x + 45, y + 8, 48, 32)
    draw_icon(p, "plus", x + 95 + 10.5, y + 6 + 10.5, 15, k, sk.ink_soft)
    bx.add("pagezoom.in", x + 95, y + 6, 36, 36)
    p.rect(x + 136, y + 15, 1, 18, sk.line, 0)
    draw_icon(p, "maximize-2", x + 142 + 10.5, y + 6 + 10.5, 15, k, sk.ink_soft)
    bx.add("pagezoom.fit", x + 142, y + 6, 36, 36)


def draw_selection_bar[P: Painter](mut p: P, mut bx: Boxes, cx: Float64, y: Float64, labels: List[String], k: Float64, sk: Skin) -> Float64:
    """The bar of actions over a selection (the web's .selection-bar): centred on cx, quiet text buttons (IBM Plex Sans 500
    12, padded 7 10) 2 apart in a 10 px rounded pill of the paper at 92 %, a hairline edge, one soft shadow. Returns its width."""
    var st = TextStyle("IBM Plex Sans", 500, False, 12)
    var w = 8.0 + 2 * Float64(max(0, len(labels) - 1))
    for l in labels:
        w += measure(st, l) + 20
    var x = cx - w / 2
    draw_shadows(p, x, y, w, 34, 10, [Shadow(0, 6, 18, 0, rgba(20, 20, 30, 31))])
    p.rect(x, y, w, 34, sk.line, 10)
    p.rect(x + 1, y + 1, w - 2, 32, mix(sk.paper, 92, sk.desk), 9)
    bx.add("selbar", x, y, w, 34)
    var bxx = x + 4
    for l in labels:
        var bw = measure(st, l) + 20
        text_at(p, st, l, bxx + 10, y + 4 + 7, 12, sk.ui_muted)
        bx.add("selbar.item:" + l, bxx, y + 4, bw, 26)
        bxx += bw + 2
    return w


def draw_locked_cover[P: Painter](mut p: P, mut bx: Boxes, x: Float64, y: Float64, w: Float64, h: Float64, title: String, heading: String,
                                  sub: String, k: Float64, sk: Skin):
    """A locked document's cover over its area (the words are not shown): a soft wash in the skin's locked colour, a 3 px
    edge on top, the title with a lock at the top left, a heading and a line centred (D-7927). Boxes: locked-cover,
    locked-title:<title>, locked-heading:<heading>."""
    p.rect(x, y, w, h, sk.locked_soft, 0)
    p.rect(x, y, w, 3, sk.locked, 0)
    bx.add("locked-cover", x, y, w, h)
    var left = x + max(20.0, min(56.0, w * 0.06))
    var tst = TextStyle(sk.display, sk.display_weight, sk.display_italic, 30)
    tst.letter_spacing = sk.title_track * 30
    draw_icon(p, "lock", left, y + 76 + 6, 22, k, sk.locked)
    var t = title if title != "" else String("Untitled note")
    text_at(p, tst, t, left + 22 + 10, y + 76, 34.5, sk.ink)
    bx.add("locked-title:" + t, left, y + 76, w - (left - x) - 20, 34.5)
    var hst = TextStyle(sk.display, sk.display_weight, sk.display_italic, 19)
    var cy = y + 72 + (h - 72 - 24) / 2 - 24
    text_at(p, hst, heading, x + w / 2, cy, 22, sk.ink, ALIGN_CENTER)
    bx.add("locked-heading:" + heading, x + w / 2 - measure(hst, heading) / 2, cy, measure(hst, heading), 22)
    var sst = TextStyle(UI, 400, False, 13)
    text_at(p, sst, sub, x + w / 2, cy + 22 + 10, 18, sk.muted, ALIGN_CENTER)


# ------------------------------------------------ what went wrong, and a way on (review 3)

def fitted(st: TextStyle, text: String, width: Float64) -> String:
    """text, cut with "…" where it is wider than `width` (CSS's text-overflow: ellipsis)."""
    if measure(st, text) <= width:
        return text
    var lo = 0
    var cuts = List[Int]()
    var i = 0
    for c in text.graphemes():
        cuts.append(i)
        i += c.byte_length()
    var hi = len(cuts) - 1
    while lo < hi:  # (the longest start that fits with the dots)
        var mid = (lo + hi + 1) // 2
        if measure(st, String(text[byte=0:cuts[mid]]) + "…") <= width:
            lo = mid
        else:
            hi = mid - 1
    return String(text[byte=0:cuts[lo]]) + "…" if len(cuts) > 0 else String("…")


def draw_toast[P: Painter](mut p: P, mut bx: Boxes, cx: Float64, bottom: Float64, words: String, action: String, sk: Skin) -> Float64:
    """A message at the bottom, centred on cx, its bottom edge at `bottom`, with one action ("" : none), as the web's
    toast. Its boxes: "toast", "toast.action". Its width."""
    var st = TextStyle(UI, 400, False, 13)
    var bst = TextStyle(UI, 600, False, 12)
    var ww = measure(st, words)
    var bw = measure(bst, action) + 20 if action != "" else 0.0
    var w = 16 + ww + (14 + bw if action != "" else 6.0) + 10
    var h = 44.0
    var x = cx - w / 2
    var y = bottom - h
    draw_lifted(p, x, y, w, h, 8, sk.shadow3, rgba(41, 42, 37))
    bx.add("toast", x, y, w, h)
    text_at(p, st, words, x + 16, y, h, rgba(255, 255, 255))
    if action != "":
        p.rect(x + 16 + ww + 14, y + 9, bw, 26, rgba(255, 255, 255, 41), 6)
        text_at(p, bst, action, x + 16 + ww + 14 + 10, y + 9, 26, rgba(255, 255, 255))
        bx.add("toast.action", x + 16 + ww + 14, y + 9, bw, 26)
    return w


@fieldwise_init
struct PropsRow(Copyable, Movable):
    """A fact in a properties card: its name and its value."""
    var name: String
    var value: String


struct PropsCard(Movable):
    """A document's properties (the web's note popover): where it is filed, with a menu to file it elsewhere, facts, and a
    danger button. Boxes: "props", "props.place", "props.place-row:<i>", "props.danger"."""
    var label: String
    var place: Int  # the chosen one of `places`
    var places: List[String]
    var place_colors: List[UInt32]  # 0: the loose place's icon
    var menu_open: Bool
    var facts: List[PropsRow]
    var danger_label: String

    def __init__(out self):
        self.label = "Notebook"
        self.place = 0
        self.places = List[String]()
        self.place_colors = List[UInt32]()
        self.menu_open = False
        self.facts = List[PropsRow]()
        self.danger_label = "Delete"

    def draw[P: Painter](self, mut p: P, mut bx: Boxes, cx: Float64, y: Float64, k: Float64, sk: Skin):
        var w = 320.0
        var x = cx - w / 2
        var lst = TextStyle(UI, 700, False, 10)
        lst.letter_spacing = 0.8
        var h = 4 + 12 + 14 + 9 + 38 + 12 + 1 + 12 + Float64(len(self.facts)) * 15 + Float64(max(len(self.facts) - 1, 0)) * 13 + 12 + 12 + 38 + 14
        draw_lifted(p, x, y, w, h, 16, sk.shadow2, sk.panel)
        bx.add("props", x, y, w, h)
        var ix = x + 18
        var iw = w - 36
        var cy = y + 16
        text_at(p, lst, self.label.upper(), ix, cy, 14, sk.ui_muted)
        cy += 23
        draw_bordered(p, ix, cy, iw, 38, 10, sk.panel, sk.line)
        bx.add("props.place", ix, cy, iw, 38)
        var place_y = cy
        self._place(p, k, sk, ix, cy, iw, self.place)
        draw_icon(p, "chevron-down", ix + iw - 10 - 14, cy + 12, 14, k, sk.ui_muted)
        cy += 38 + 12
        p.rect(x + 14, cy, w - 28, 1, sk.line, 0)
        cy += 13
        var fst = TextStyle(UI, 400, False, 12)
        for f in self.facts:
            text_at(p, fst, f.name, ix, cy, 15, sk.ui_muted)
            text_at(p, fst, f.value, ix + iw - measure(fst, f.value), cy, 15, sk.ink)
            cy += 28
        cy += 11.0 if len(self.facts) > 0 else 24.0
        draw_bordered(p, ix, cy, iw, 38, 19, sk.panel, sk.line)
        var dst = TextStyle(UI, 600, False, 12)
        var dw = 15 + 8 + measure(dst, self.danger_label)
        draw_icon(p, "trash-2", ix + (iw - dw) / 2, cy + 11.5, 15, k, sk.danger)
        text_at(p, dst, self.danger_label, ix + (iw - dw) / 2 + 23, cy, 38, sk.danger)
        bx.add("props.danger", ix, cy, iw, 38)
        if self.menu_open:
            var mh = Float64(len(self.places)) * 36 + 10
            draw_lifted(p, ix, place_y + 44, iw, mh, 12, sk.shadow2, sk.panel)
            bx.add("props.menu", ix, place_y + 44, iw, mh)
            for i in range(len(self.places)):
                var ry = place_y + 44 + 5 + Float64(i) * 36
                if i == self.place:
                    p.rect(ix + 5, ry, iw - 10, 36, sk.hover, 8)
                self._place(p, k, sk, ix + 5, ry - 1, iw - 10, i)
                bx.add("props.place-row:" + String(i), ix + 5, ry, iw - 10, 36)

    def _place[P: Painter](self, mut p: P, k: Float64, sk: Skin, x: Float64, y: Float64, w: Float64, i: Int):
        if i < 0 or i >= len(self.places):
            return
        if self.place_colors[i] == 0:
            draw_icon(p, "inbox", x + 10, y + 12, 14, k, sk.ink_soft)
        else:
            p.circle(x + 17, y + 19, 4.5, self.place_colors[i])
        var st = TextStyle(UI, 400, False, 13)
        text_at(p, st, fitted(st, self.places[i], w - 32 - 34), x + 32, y, 38, sk.ink)


def draw_pill_button[P: Painter](mut p: P, mut bx: Boxes, name: String, cx: Float64, y: Float64, label: String, sk: Skin):
    """A small filled button centred on cx, its top at y (32 high)."""
    var st = TextStyle(UI, 600, False, 13)
    var w = measure(st, label) + 28
    draw_lifted(p, cx - w / 2, y, w, 32, 16, sk.shadow2, sk.panel)
    text_at(p, st, label, cx - w / 2 + 14, y, 32, sk.ink)
    bx.add(name, cx - w / 2, y, w, 32)


def draw_problem[P: Painter](mut p: P, mut bx: Boxes, x: Float64, y: Float64, w: Float64, h: Float64, title: String, detail: String, action: String, name: String,
                             sk: Skin):
    """In place of a document that couldn't be opened: what happened, why (wrapped), and a button."""
    var cw = min(420.0, w - 48)
    var ts = TextStyle(UI, 600, False, 16)
    var ds = TextStyle(UI, 400, False, 13)
    var lines = List[String]()
    var line = String("")
    for wd in detail.split(" "):
        var trial = String(wd) if line == "" else line + " " + String(wd)
        if line != "" and measure(ds, trial) > cw - 48:
            lines.append(line)
            line = String(wd)
        else:
            line = trial
    lines.append(line)
    var ch = 24 + 22 + 10 + 20 * Float64(len(lines)) + 16 + 32 + 24
    var cx = x + (w - cw) / 2
    var cy = y + (h - ch) / 2
    draw_lifted(p, cx, cy, cw, ch, 16, sk.shadow2, sk.panel)
    bx.add(".open-problem", cx, cy, cw, ch)
    text_at(p, ts, title, cx + 24, cy + 24, 22, sk.ink)
    for n in range(len(lines)):
        text_at(p, ds, lines[n], cx + 24, cy + 24 + 22 + 10 + 20 * Float64(n), 20, sk.ui_muted)
    draw_pill_button(p, bx, name, cx + 24 + 60, cy + ch - 24 - 32, action, sk)
