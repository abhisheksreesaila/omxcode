# mojoui.islandcard (goal 79): a title island that opens into a card of actions, the way Personal Note's web island
# does: the name in a field, a status line (a coloured dot, words, and a place on the right), one wide action with a key
# hint, and a grid of icon tiles four across (a danger tile in the skin's danger colour). Generic: the app hands in
# the words, icons and ids; taps reach it through the Boxes names.
#
#   var c = IslandCard(); c.title = "Book mind map"; c.tiles = …; c.draw(p, bx, slot_x0, slot_x1, k, sk)

from mojoui.scene import Painter
from mojoui.skin import Skin, mix, with_alpha
from mojoui.fonttext import TextStyle, measure, line_metrics, ALIGN_CENTER, ALIGN_RIGHT
from mojoui.notesshell import Boxes, draw_shadows, draw_bordered, text_at, text_normal
from mojoui.strokeicon import draw_icon

comptime UI = "Geist"
comptime MONO = "Geist Mono"


@fieldwise_init
struct CardTile(Copyable, Movable):
    var id: String  # the box name (#share-print …)
    var label: String
    var icon: String
    var danger: Bool


struct IslandCard(Movable):
    var title: String
    var status: String
    var status_dot: UInt32
    var place: String
    var wide_id: String
    var wide_label: String
    var wide_icon: String
    var wide_key: String
    var tiles: List[CardTile]

    def __init__(out self):
        self.title = ""
        self.status = ""
        self.status_dot = 0
        self.place = ""
        self.wide_id = ""
        self.wide_label = ""
        self.wide_icon = ""
        self.wide_key = ""
        self.tiles = List[CardTile]()

    def draw[P: Painter](self, mut p: P, mut bx: Boxes, slot_x0: Float64, slot_x1: Float64, k: Float64, sk: Skin):
        var rows = (len(self.tiles) + 3) // 4
        var w = 422.0
        var inner_h = 14 + 38 + 8 + 15.59 + 10 + 44 + Float64(rows) * 70 + 12  # (padding 14 above, 12 below)
        var h = inner_h + 2
        var x = Float64(Int(((slot_x0 + slot_x1) / 2 - w / 2) * 2 + 0.5)) / 2
        var y = 16.0
        draw_shadows(p, x, y, w, h, 20, sk.shadow2)
        p.rect(x, y, w, h, sk.panel, 20)
        bx.add("#island", x, y, w, h)
        bx.add("#share-menu", x + 1, y + 1, w - 2, inner_h)
        var cx = x + 1 + 14
        var cw = w - 2 - 28
        var cy = y + 1 + 14
        # the name
        draw_bordered(p, cx, cy, cw, 38, 10, sk.panel, sk.line)
        var tst = TextStyle(UI, 600, False, 15)
        text_at(p, tst, self.title, cx + 12, cy + 11.5, 15, sk.ink)
        bx.add("#note-title", cx, cy, cw, 38)
        cy += 38 + 8
        # the status line
        var mst = TextStyle(UI, 400, False, 12)
        var mx = cx + 2
        var mw = cw - 4
        bx.add(".isl-meta:" + self.status + self.place, mx, cy, mw, 15.59)
        p.circle(mx + 3, cy + 4.8 + 3, 3, self.status_dot)
        var sw = measure(mst, self.status)
        text_at(p, mst, self.status, mx + 12, cy, 15.6, sk.ui_muted)
        bx.add("#save-state", mx, cy, 12 + sw, 15.59)
        var pw = measure(mst, self.place)
        text_at(p, mst, self.place, mx + mw, cy, 15.6, sk.ui_muted, ALIGN_RIGHT)
        bx.add("#island-notebook", mx + mw - pw, cy, pw, 15.59)
        cy += 15.59 + 10
        # the grid: one wide action, then tiles four across
        var cut = String("")
        var n = 0
        var all_words = self.wide_label + self.wide_key + " "
        for t in self.tiles:
            all_words += t.label + " "
        for c in all_words.codepoints():
            if n >= 40:
                break
            cut += String(c)
            n += 1
        bx.add(".isl-grid:" + cut, cx, cy, cw, 44 + Float64(rows) * 70)
        draw_bordered(p, cx, cy, cw, 44, 12, sk.panel, sk.line)
        var wst = TextStyle(UI, 600, False, 13)
        var kst = TextStyle(MONO, 400, False, 11)
        var lw = measure(wst, self.wide_label)
        var kw = measure(kst, self.wide_key) + 14
        var total = 18 + 10 + lw + 10 + kw
        var wx = cx + (cw - total) / 2
        draw_icon(p, self.wide_icon, wx, cy + 13, 18, k, sk.ink)
        text_normal(p, wst, self.wide_label, wx + 28, cy + 13.5, sk.ink)
        var kx = wx + 28 + lw + 10
        draw_bordered(p, kx, cy + 12.3, kw, 19.39, 6, sk.panel, sk.line)
        text_at(p, kst, self.wide_key, kx + 7, cy + 14.3, 15.4, sk.ui_muted)
        bx.add("#focus-top-kbd", kx, cy + 12.3, kw, 19.39)
        bx.add(self.wide_id, cx, cy, cw, 44)
        cy += 44 + 6
        var tw = (cw - 18) / 4
        var lst = TextStyle(UI, 400, False, 11.5)
        for i in range(len(self.tiles)):
            ref t = self.tiles[i]
            var tx = cx + Float64(i % 4) * (tw + 6)
            var ty = cy + Float64(i // 4) * 70
            draw_bordered(p, tx, ty, tw, 64, 12, sk.panel, sk.line)
            var fg = sk.danger if t.danger else sk.ink
            draw_icon(p, t.icon, tx + (tw - 18) / 2, ty + 12.5, 18, k, fg)
            text_normal(p, lst, t.label, tx + tw / 2, ty + 36.5, fg, ALIGN_CENTER)
            bx.add(t.id, tx, ty, tw, 64)
