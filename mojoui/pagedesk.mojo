# mojoui.pagedesk (goal 79): a whiteboard laid out on pages, the way Personal Note's canvas draws it, as generic pieces
# over mojoui.objectlayer: the view a note opens at (every page on the desk when that stays readable), the page frame in
# screen pixels (the skin's shadow as bands, a hairline edge, the paper, dashed folds between pages, "Page N" under each
# page), and the board painted in the paper look: text boxes and stickies in real faces (mojoui.fonttext, Fabric's line
# metrics), stickies with their dog-ear corner and baked drop shadow, arrows with a filled head. The board is one layer in
# page units shown through the view (layer_transform), so a pan or a zoom moves a kept picture and text re-rasterizes at
# the new size (never a scaled bitmap).
#
#   var v = opening_view(view_w, view_h, cols * PAGE_W, rows * PAGE_H)
#   draw_page_chrome(p, bx, v, view_w, view_h, cols, rows, PAGE_W, PAGE_H, k, sk)
#   var look = BoardLook(); look.paint(p, layer, v, view_w, view_h, k)

from std.collections import Dict
from std.math import sqrt, cos, sin, atan2, exp, floor, ceil
from mojoui.scene import Painter
from mojoui.skin import Skin, Shadow, with_alpha
from mojoui.fonttext import TextStyle, measure
from mojoui.notesshell import Boxes, draw_shadows
from mojoui.objectlayer import ObjectLayer, Obj, TEXT, STICKY, RECT, ELLIPSE, INK, PICTURE, CONNECTOR
from mojoui.canvas import rgba

comptime PAGE_W = 860.0
comptime PAGE_H = 1080.0
comptime PI = 3.141592653589793
# Fabric's text metrics (Personal Note keeps them on Leafer: style.js): a line is size · 1.13 · line height, the first
# baseline size · 1.13 · (1 − 0.222) below the box's top
comptime FONT_SIZE_MULT = 1.13
comptime FONT_SIZE_FRACTION = 0.222
comptime STICKY_PAD = 22.0
comptime CONNECTOR_HEAD = 15.0
comptime LABEL_FAMILY = "Geist Mono"
comptime LABEL_SIZE = 10.5
comptime FOLD: UInt32 = 0x21161B1F  # rgba(31, 27, 22, .13)


@fieldwise_init
struct DeskView(ImplicitlyCopyable, Movable):
    """Where the page frame's origin is on screen (layout px) and the zoom (screen px per page px)."""
    var x: Float64
    var y: Float64
    var scale: Float64

    def to_screen(self, px: Float64, py: Float64) -> Tuple[Float64, Float64]:
        return (self.x + px * self.scale, self.y + py * self.scale)

    def to_page(self, sx: Float64, sy: Float64) -> Tuple[Float64, Float64]:
        return ((sx - self.x) / self.scale, (sy - self.y) / self.scale)

    def zoomed_at(self, scale: Float64, sx: Float64, sy: Float64) -> DeskView:
        """The view at a new zoom, the page point under (sx, sy) staying there."""
        var p = self.to_page(sx, sy)
        return DeskView(sx - p[0] * scale, sy - p[1] * scale, scale)


def view_margins(window_w: Float64) -> Tuple[Float64, Float64, Float64, Float64]:
    """(left, right, top, bottom) the islands keep clear, by window width (viewport.js viewMargins)."""
    if window_w <= 560:
        return (12.0, 12.0, 88.0, 96.0)
    if window_w <= 800:
        return (12.0, 12.0, 64.0, 112.0)
    return (140.0, 140.0, 104.0, 180.0)


def fit_view(view_w: Float64, view_h: Float64, content_w: Float64, content_h: Float64, ml: Float64, mr: Float64, mt: Float64,
             mb: Float64, lo: Float64, hi: Float64) -> DeskView:
    """The content fitted inside the margins, centred, the zoom kept in [lo, hi] (navigation.js fitView)."""
    var free_w = view_w - ml - mr
    var free_h = view_h - mt - mb
    var s = min(hi, max(lo, min(free_w / content_w, free_h / content_h)))
    return DeskView(ml + (free_w - content_w * s) / 2, mt + (free_h - content_h * s) / 2, s)


def opening_view(view_w: Float64, view_h: Float64, content_w: Float64, content_h: Float64, lo: Float64 = 0.4, hi: Float64 = 1.0) -> DeskView:
    """The view a page grid opens at on a wide window: every page on the desk (72 px at the sides, the islands' margins
    above and 10 more below) when that keeps the zoom ≥ lo, otherwise the first page's corner at lo (openingView)."""
    var m = view_margins(view_w)
    var free_w = view_w - 72 - 72
    var free_h = view_h - m[2] - (m[3] + 10)
    if min(free_w / content_w, free_h / content_h) < lo:
        return DeskView(72, m[2], lo)
    return fit_view(view_w, view_h, content_w, content_h, 72, 72, m[2], m[3] + 10, lo, hi)


def _normal_cdf(z: Float64) -> Float64:
    var t = 1 / (1 + 0.3275911 * abs(z) / 1.4142135623730951)
    var poly = ((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592
    var erf = 1 - poly * t * exp(-(z * z) / 2)
    return 0.5 * (1 + (erf if z >= 0 else -erf))


def shadow_bands(blur: Float64, spread: Float64, peak: Float64, steps: Int = 32) -> List[Tuple[Float64, Float64]]:
    """A blurred rectangle's shadow as stacked solid rects, outermost first: (grow, alpha) each (viewport.js shadowBands)."""
    var out = List[Tuple[Float64, Float64]]()
    if blur <= 0:
        out.append((spread, peak))
        return out^
    var sigma = blur / 2
    var covered = 0.0
    for k in range(steps):
        var edge = blur - (2 * blur * Float64(k)) / Float64(steps - 1)
        var target = peak * (1 - _normal_cdf(edge / sigma))
        var alpha = 0.0 if covered >= 1 else max(0.0, 1 - (1 - target) / (1 - covered))
        out.append((spread + edge, alpha))
        covered = max(covered, target)
    return out^


def draw_page_chrome[P: Painter](mut p: P, mut bx: Boxes, v: DeskView, view_w: Float64, view_h: Float64, columns: Int, rows: Int,
                                 page_w: Float64, page_h: Float64, k: Float64, sk: Skin):
    """The page frame in screen px (chrome.js pageChrome): the skin's shadow layers as bands, the edge one hairline out,
    the paper, dashed folds between pages, "Page N" under each page of the bottom row (inside the corner above it)."""
    var w = Float64(columns) * page_w * v.scale
    var h = Float64(rows) * page_h * v.scale
    if w <= 0 or h <= 0:
        return
    for s in sk.shadow2:
        var a = Float64(Int((s.color >> 24) & 0xFF)) / 255.0
        for band in shadow_bands(s.blur, s.spread, a):
            if band[1] <= 0:
                continue
            p.rect(v.x - band[0] + s.dx, v.y - band[0] + s.dy, w + band[0] * 2, h + band[0] * 2, with_alpha(s.color, band[1]), 0)
    var r = sk.page_radius
    p.rect(v.x - 1, v.y - 1, w + 2, h + 2, sk.edge, r + 1)
    p.rect(v.x, v.y, w, h, sk.paper, r)
    bx.add("#paper-sheet", v.x, v.y, w, h)
    for c in range(1, columns):
        _dashed(p, v.x + Float64(c) * page_w * v.scale, v.y, v.x + Float64(c) * page_w * v.scale, v.y + h)
    for rw in range(1, rows):
        _dashed(p, v.x, v.y + Float64(rw) * page_h * v.scale, v.x + w, v.y + Float64(rw) * page_h * v.scale)
    var st = TextStyle(LABEL_FAMILY, 400, False, LABEL_SIZE)
    st.exact = True
    if columns * rows <= 400:
        for rw in range(rows):
            for c in range(columns):
                var left = v.x + Float64(c) * page_w * v.scale
                var bottom = v.y + Float64(rw + 1) * page_h * v.scale
                if left > view_w or left + page_w * v.scale < 0 or bottom > view_h + 40 or bottom < -40:
                    continue
                var last = rw == rows - 1
                var lx = left + (0.0 if last else 14.0)
                var ly = bottom + (11.0 if last else -26.0)
                # a Leafer text row: the baseline (row + 0.7 · size) / 2 below its top, the row as tall as the size
                p.run(st, "Page " + String(rw * columns + c + 1), lx, ly + (LABEL_SIZE + 0.7 * LABEL_SIZE) / 2, sk.ui_muted, 0)


def _dashed[P: Painter](mut p: P, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
    var dx = x1 - x0
    var dy = y1 - y0
    var l = sqrt(dx * dx + dy * dy)
    if l <= 0:
        return
    var t = 0.0
    while t < l:
        var e = min(t + 6, l)
        p.line(x0 + dx * t / l, y0 + dy * t / l, x0 + dx * e / l, y0 + dy * e / l, 1.5, FOLD)
        t += 11


@fieldwise_init
struct WrapKey(Copyable, Movable):
    var rev: Int
    var width: Float64


struct BoardLook(Movable):
    """The paper look of a page board: faces and sizes from each object (a document's own type), defaults for objects that
    have none, wrapped lines cached per object revision and width."""
    var family: String  # the face of a text with none of its own
    var line_height: Float64  # × size, for a text with none of its own
    var wrap_rev: Dict[Int, Int]
    var wrap_w: Dict[Int, Float64]
    var wrap_lines: Dict[Int, List[String]]

    def __init__(out self, family: String = "Source Serif 4", line_height: Float64 = 1.16):
        self.family = family
        self.line_height = line_height
        self.wrap_rev = Dict[Int, Int]()
        self.wrap_w = Dict[Int, Float64]()
        self.wrap_lines = Dict[Int, List[String]]()

    def style_of(self, ref o: Obj) -> TextStyle:
        var st = TextStyle(o.family if o.family != "" else self.family, 400, False, o.size)
        st.exact = True  # canvas text: measureText's advances, unrounded
        return st

    def lines(mut self, ref o: Obj, width: Float64) -> List[String]:
        """The object's words broken into lines at `width` page px: its own line breaks, then at the last space that
        fits (a word wider than the box stays whole on its line)."""
        var rev = self.wrap_rev.get(o.id, -1)
        if rev == o.rev and self.wrap_w.get(o.id, -1.0) == width:
            try:
                return self.wrap_lines[o.id].copy()
            except:
                pass
        var st = self.style_of(o)
        var out = List[String]()
        for para in o.text.split("\n"):
            var words = String(para).split(" ")
            var line = String("")
            var first = True
            for wd in words:
                var word = String(wd)
                var trial = word if first else line + " " + word
                if not first and measure(st, trial) > width + 0.01:
                    out.append(line)
                    line = word
                else:
                    line = trial
                first = False
            out.append(line)
        self.wrap_rev[o.id] = o.rev
        self.wrap_w[o.id] = width
        self.wrap_lines[o.id] = out.copy()
        return out^

    def paint[P: Painter](mut self, mut p: P, mut layer: ObjectLayer, v: DeskView, view_w: Float64, view_h: Float64, k: Float64):
        """The objects meeting the window, in z order, as one layer in page px shown through the view."""
        var tl = v.to_page(0, 0)
        var br = v.to_page(view_w, view_h)
        p.begin_layer("board")
        p.layer_transform(v.x * k, v.y * k, v.scale * k)
        for i in layer.query(tl[0] - 64, tl[1] - 64, br[0] + 64, br[1] + 64):
            self.paint_obj(p, layer, i)

    def paint_obj[P: Painter](mut self, mut p: P, mut layer: ObjectLayer, i: Int):
        var kind = layer.objs[i].kind
        if kind == TEXT:
            ref o = layer.objs[i]
            self._words(p, o, o.x + o.pad, o.y + o.pad, o.w - 2 * o.pad, o.color)
            p.note("object text " + String(o.id))
        elif kind == STICKY:
            ref o = layer.objs[i]
            draw_shadows(p, o.x, o.y, o.w, o.h, 6, [Shadow(0, 9, 16, 0, rgba(0, 0, 0, 66))])
            p.polygon(corner_rect(o.x, o.y, o.w, o.h, 4, 4, 24, 4), o.color)
            self._words(p, o, o.x + STICKY_PAD, o.y + STICKY_PAD, o.w - 2 * STICKY_PAD, o.ink)
            p.note("object sticky " + String(o.id))
        elif kind == CONNECTOR:
            ref o = layer.objs[i]
            draw_arrow(p, o.ax, o.ay, o.bx, o.by, o.line_width, o.color, o.head_end)
            p.note("object connector " + String(o.id))
        else:
            _ = layer.paint_shape(p, i)

    def _words[P: Painter](mut self, mut p: P, ref o: Obj, x: Float64, top: Float64, width: Float64, color: UInt32):
        var st = self.style_of(o)
        var lh = o.line_height if o.line_height > 0 else self.line_height
        var pitch = o.size * FONT_SIZE_MULT * lh
        var base = top + o.size * FONT_SIZE_MULT * (1 - FONT_SIZE_FRACTION)
        var ls = self.lines(o, width)
        for n in range(len(ls)):
            if ls[n] != "":
                p.run(st, ls[n], x, base + Float64(n) * pitch, color, 0)


def corner_rect(x: Float64, y: Float64, w: Float64, h: Float64, tl: Float64, tr: Float64, br: Float64, bl: Float64) -> List[Float64]:
    """A rect with its own radius at each corner (CSS order: top-left, top-right, bottom-right, bottom-left) as a polygon."""
    var out = List[Float64]()
    var rs: List[Float64] = [tl, tr, br, bl]
    var cxs: List[Float64] = [x + tl, x + w - tr, x + w - br, x + bl]
    var cys: List[Float64] = [y + tl, y + tr, y + h - br, y + h - bl]
    var starts: List[Float64] = [PI, 1.5 * PI, 0, 0.5 * PI]
    for c in range(4):
        var r = min(rs[c], min(w, h) / 2)
        var n = max(2, Int(r * 0.6) + 2)
        for s in range(n + 1):
            var a = starts[c] + 0.5 * PI * Float64(s) / Float64(n)
            out.append(cxs[c] + r * cos(a))
            out.append(cys[c] + r * sin(a))
    return out^


def draw_arrow[P: Painter](mut p: P, ax: Float64, ay: Float64, bx: Float64, by: Float64, width: Float64, color: UInt32, head: Bool = True):
    """An arrow as Personal Note draws one (connectors.js arrowPathFrom): a line to the base of the head and the head, a
    triangle (min(15, length · 0.6) long, wings π/7 off the line) filled and stroked, round caps and joins."""
    var dx = bx - ax
    var dy = by - ay
    var length = sqrt(dx * dx + dy * dy)
    if length < 1e-6:
        return
    var hw = width / 2
    if not head:
        p.line(ax, ay, bx, by, width, color)
        p.circle(ax, ay, hw, color)
        p.circle(bx, by, hw, color)
        return
    var size = min(CONNECTOR_HEAD, length * 0.6)
    var ang = atan2(dy, dx)
    var spread = PI / 7
    var w1x = bx - size * cos(ang - spread)
    var w1y = by - size * sin(ang - spread)
    var w2x = bx - size * cos(ang + spread)
    var w2y = by - size * sin(ang + spread)
    var tx = (w1x + w2x) / 2
    var ty = (w1y + w2y) / 2
    p.line(ax, ay, tx, ty, width, color)
    p.circle(ax, ay, hw, color)
    p.circle(tx, ty, hw, color)
    # the head, filled, its outline stroked: a triangle grown by the stroke's half width with round corners
    p.polygon([bx, by, w1x, w1y, w2x, w2y], color)
    p.line(bx, by, w1x, w1y, width, color)
    p.line(w1x, w1y, w2x, w2y, width, color)
    p.line(w2x, w2y, bx, by, width, color)
    p.circle(bx, by, hw, color)
    p.circle(w1x, w1y, hw, color)
    p.circle(w2x, w2y, hw, color)
