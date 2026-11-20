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
from std.os import getenv
from std.math import sqrt, cos, sin, atan2, exp, floor, ceil
from mojoui.scene import Painter
from mojoui.skin import Skin, Shadow, with_alpha
from mojoui.fonttext import TextStyle, measure, baseline_in
from mojoui.ink import Stroke
from mojoui.objectlayer import CH_ADD, CH_MOVE
from mojoui.notesshell import Boxes, draw_shadows
from mojoui.objectlayer import ObjectLayer, Obj, TEXT, STICKY, RECT, ELLIPSE, INK, PICTURE, CONNECTOR
from mojoui.canvas import rgba
from mojoui.damage import DamageSnap

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
comptime BOARD_TILE = 512.0  # the board layer culls to whole tiles of page px (a pan inside them keeps the layer)


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


def draw_page_chrome[P: Painter](mut p: P, mut bx: Boxes, at: DeskView, win_w: Float64, win_h: Float64, columns: Int, rows: Int,
                                 page_w: Float64, page_h: Float64, k: Float64, sk: Skin):
    """The page frame in screen px (chrome.js pageChrome): the skin's shadow layers as bands, the edge one hairline out,
    the paper, dashed folds between pages, "Page N" under each page of the bottom row (inside the corner above it).
    Its own layer, drawn about the frame's origin and moved there by the layer's transform, with a version from what
    shapes it (zoom, pages, skin, device scale): a pan moves the kept picture and draws nothing (D-7929)."""
    var w = Float64(columns) * page_w * at.scale
    var h = Float64(rows) * page_h * at.scale
    if w <= 0 or h <= 0:
        return
    bx.add("desk.sheet", at.x, at.y, w, h)
    p.begin_layer("page-frame")
    p.layer_version((Int(at.scale * 1_000_000) * 1000003 + columns * 7919 + rows * 104729 + Int(k * 1000) * 31 + Int(sk.paper) * 131
                     + Int(sk.edge) * 17 + Int(page_w * 10) * 13 + Int(page_h * 10) * 7) & 0x3FFFFFFFFFFFFFFF)
    p.layer_transform(at.x * k, at.y * k, k)
    var v = DeskView(0, 0, at.scale)
    _ = win_w
    _ = win_h
    var view_w = Float64(1e12)  # (every label is drawn: the picture mustn't depend on where the window is)
    var view_h = Float64(1e12)
    var r = sk.page_radius
    # (D-7940) the paper is opaque, so a band is drawn only where it can show: its rect less the paper's inside (kept
    # under the paper by the radius and 3 px, so every pixel the paper doesn't wholly cover gets every band, as before);
    # 32 bands as sheet-sized rects were ~100 M fragments a frame at 100 % on a 16-page desk
    var opaque = (sk.paper >> 24) == 0xFF
    var m = r + 3
    for s in sk.shadow2:
        var a = Float64(Int((s.color >> 24) & 0xFF)) / 255.0
        for band in shadow_bands(s.blur, s.spread, a):
            if band[1] <= 0:
                continue
            var c = with_alpha(s.color, band[1])
            var bx0 = v.x - band[0] + s.dx
            var by0 = v.y - band[0] + s.dy
            var bx1 = bx0 + w + band[0] * 2
            var by1 = by0 + h + band[0] * 2
            if not opaque or w <= 2 * m or h <= 2 * m:
                p.rect(bx0, by0, bx1 - bx0, by1 - by0, c, 0)
                continue
            _ring(p, bx0, by0, bx1, by1, v.x + m, v.y + m, v.x + w - m, v.y + h - m, c)
    p.rect(v.x - 1, v.y - 1, w + 2, h + 2, sk.edge, r + 1)
    p.rect(v.x, v.y, w, h, sk.paper, r)
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


def _ring[P: Painter](mut p: P, bx0: Float64, by0: Float64, bx1: Float64, by1: Float64, hx0: Float64, hy0: Float64, hx1: Float64, hy1: Float64,
                      c: UInt32):
    """The rect (bx0, by0)–(bx1, by1) less the hole (hx0, hy0)–(hx1, hy1), as up to four rects that don't overlap."""
    var ix0 = max(bx0, hx0)
    var iy0 = max(by0, hy0)
    var ix1 = min(bx1, hx1)
    var iy1 = min(by1, hy1)
    if ix0 >= ix1 or iy0 >= iy1:  # (no hole inside it)
        p.rect(bx0, by0, bx1 - bx0, by1 - by0, c, 0)
        return
    if iy0 > by0:
        p.rect(bx0, by0, bx1 - bx0, iy0 - by0, c, 0)
    if by1 > iy1:
        p.rect(bx0, iy1, bx1 - bx0, by1 - iy1, c, 0)
    if ix0 > bx0:
        p.rect(bx0, iy0, ix0 - bx0, iy1 - iy0, c, 0)
    if bx1 > ix1:
        p.rect(ix1, iy0, bx1 - ix1, iy1 - iy0, c, 0)


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


def board_rect(v: DeskView, view_w: Float64, view_h: Float64) -> Tuple[Float64, Float64, Float64, Float64]:
    """The page rect BoardLook.paint draws objects from for this view: the window, 64 px more, snapped out to whole
    BOARD_TILEs (a progressive open's first slice takes exactly this: mojoui.canvasload.OpenBoard)."""
    var tl = v.to_page(0, 0)
    var br = v.to_page(view_w, view_h)
    return (floor((tl[0] - 64) / BOARD_TILE) * BOARD_TILE, floor((tl[1] - 64) / BOARD_TILE) * BOARD_TILE,
            ceil((br[0] + 64) / BOARD_TILE) * BOARD_TILE, ceil((br[1] + 64) / BOARD_TILE) * BOARD_TILE)


@fieldwise_init
struct WrapKey(Copyable, Movable):
    var rev: Int
    var width: Float64


def _mix(h: UInt64, v: UInt64) -> UInt64:
    """One FNV-1a-style step over a 64-bit value (each field mixed in, so two fields can't cancel each other out)."""
    var x = (h ^ v) * 0x100000001B3
    return x ^ (x >> 29)


def _obj_key(ref o: Obj) -> Int:
    """What an object's picture depends on beyond its box (its text's revision, colours, type, stacking, ink length):
    a hash over every field (review 2: a weighted sum let changes cancel out)."""
    var h = UInt64(0xCBF29CE484222325)
    h = _mix(h, UInt64(o.kind))
    h = _mix(h, UInt64(o.rev))
    h = _mix(h, UInt64(o.color))
    h = _mix(h, UInt64(o.line))
    h = _mix(h, UInt64(o.ink))
    h = _mix(h, UInt64(o.z))
    h = _mix(h, o.size.to_bits().cast[DType.uint64]())
    h = _mix(h, UInt64(o.weight))
    h = _mix(h, o.line_height.to_bits().cast[DType.uint64]())
    h = _mix(h, o.pad.to_bits().cast[DType.uint64]())
    h = _mix(h, UInt64(1 if o.markdown else 0))
    h = _mix(h, UInt64(1 if o.head_end else 0))
    h = _mix(h, UInt64(o.text.byte_length()))
    h = _mix(h, UInt64(len(o.stroke.xs)))
    h = _mix(h, o.rot.to_bits().cast[DType.uint64]())
    h = _mix(h, o.line_width.to_bits().cast[DType.uint64]())
    h = _mix(h, o.radius.to_bits().cast[DType.uint64]())
    for b in o.family.as_bytes():
        h = _mix(h, UInt64(b))
    h = _mix(h, UInt64(len(o.pixels)))
    return Int(h >> 1)


struct BoardLook(Movable):
    """The paper look of a page board: faces and sizes from each object (a document's own type), defaults for objects that
    have none, wrapped lines cached per object revision and width."""
    var family: String  # the face of a text with none of its own
    var line_height: Float64  # × size, for a text with none of its own
    var wrap_rev: Dict[Int, Int]
    var wrap_w: Dict[Int, Float64]
    var wrap_lines: Dict[Int, List[String]]
    var generation: Int  # bump when the look itself changes (its defaults): part of the board layer's version
    # (D-7940) the board as raster tiles: its own version (bumped when what it draws changes), the snapshot that finds
    # what changed (damage), the document version and lift set last seen, the objects lifted out of it during a drag
    var snap: DamageSnap
    var board_version: Int
    var since: Int
    var dmg: List[Float64]
    var seen_doc: Int
    var seen_gen: Int
    var lift_ids: List[Int]  # the lifted objects and the connectors that end at them (ids)
    var lift_key: List[Int]  # the lifted objects as asked (selection ids), to see when the lift changes
    var lift_set: Dict[Int, Bool]
    var snap_lift: List[Int]  # the lift and the look's generation the snapshot was taken with
    var snap_gen: Int

    def __init__(out self, family: String = "Source Serif 4", line_height: Float64 = 1.16):
        self.family = family
        self.line_height = line_height
        self.generation = 0
        self.snap = DamageSnap()
        self.board_version = 0
        self.since = -1
        self.dmg = List[Float64]()
        self.seen_doc = -1
        self.seen_gen = -1
        self.lift_ids = List[Int]()
        self.lift_key = List[Int]()
        self.lift_set = Dict[Int, Bool]()
        self.snap_lift = List[Int]()
        self.snap_gen = 0
        self.wrap_rev = Dict[Int, Int]()
        self.wrap_w = Dict[Int, Float64]()
        self.wrap_lines = Dict[Int, List[String]]()

    def style_of(self, ref o: Obj) -> TextStyle:
        var st = TextStyle(o.family if o.family != "" else self.family, o.weight, False, o.size)
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

    def paint[P: Painter](mut self, mut p: P, mut layer: ObjectLayer, v: DeskView, view_w: Float64, view_h: Float64, k: Float64,
                          lifted: List[Int] = List[Int]()):
        """The objects meeting the window, in z order, as one layer in page px shown through the view, kept by the
        renderer as raster tiles (D-7940): a pan or a zoom composites what's kept, an edit rasters again only the tiles
        its damage meets. `lifted` (ids: what a drag is moving) is drawn in a layer of its own above the board, with the
        connectors that end at it, so the board's tiles stay as they are until the drag lets go."""
        # culled to the window snapped out to whole tiles of page px (D-7929): the layer's extent, its ops complete there
        var cull = board_rect(v, view_w, view_h)
        var tx0 = cull[0]
        var ty0 = cull[1]
        var tx1 = cull[2]
        var ty1 = cull[3]
        self._lift(layer, lifted)
        self._track(layer, len(lifted) > 0)
        p.begin_layer("board")
        p.layer_version(self.board_version)
        p.layer_transform(v.x * k, v.y * k, v.scale * k)
        # (objects are culled by their boxes; a sticky's shadow or a text's lines reach past them, so the ops are complete
        # only a margin inside the culled rect: that is the extent. The window stays inside it: 64 px were added first)
        p.layer_tiles(tx0 + 64, ty0 + 64, tx1 - 64, ty1 - 64)
        for d in range(len(self.dmg) // 4):
            p.layer_damage(self.since, self.dmg[4 * d], self.dmg[4 * d + 1], self.dmg[4 * d + 2], self.dmg[4 * d + 3])
        var any_lift = len(self.lift_ids) > 0
        var up = List[Int]()
        for i in layer.query(tx0, ty0, tx1, ty1):
            if any_lift and layer.objs[i].id in self.lift_set:
                up.append(i)
                continue
            self.paint_obj(p, layer, i)
        if any_lift:  # (the lifted objects: all of them, wherever they are, over the board)
            p.begin_layer("board-lift")
            p.layer_transform(v.x * k, v.y * k, v.scale * k)
            var all = List[Int]()
            for id in self.lift_ids:
                var q = layer.index(id)
                if q >= 0:
                    all.append(layer.rank_of(q) * (len(layer.objs) + 1) + q)
            sort(all)
            for r in all:
                self.paint_obj(p, layer, r % (len(layer.objs) + 1))

    def _lift(mut self, mut layer: ObjectLayer, lifted: List[Int]):
        """The lift set: the lifted ids and the connectors ending at them (worked out once per lift, not per frame)."""
        var same = len(lifted) == len(self.lift_key)
        if same:
            for n in range(len(lifted)):
                if lifted[n] != self.lift_key[n]:
                    same = False
                    break
        if same:
            return
        self.lift_key = lifted.copy()
        self.lift_ids = List[Int]()
        self.lift_set = Dict[Int, Bool]()
        if len(lifted) == 0:
            return
        for id in lifted:
            self.lift_set[id] = True
        for ref o in layer.objs:
            if o.kind == CONNECTOR and (o.from_id in self.lift_set or o.to_id in self.lift_set):
                self.lift_set[o.id] = True
        for e in self.lift_set.items():
            self.lift_ids.append(e.key)

    def _track(mut self, mut layer: ObjectLayer, lifting: Bool):
        """The board's version and damage: when the document (or the lift) changed, every object's key and painted box
        compared with the last snapshot (lifted ones left out, as if gone); a new version only when something did. A
        drag that keeps its lift only moves lifted things: nothing to compare."""
        self.dmg.clear()
        var lift_changed = self.lift_key != self.snap_lift
        if layer.version == self.seen_doc and self.generation == self.seen_gen and not lift_changed:
            return
        if lifting and not lift_changed and self.generation == self.seen_gen:
            self.seen_doc = layer.version
            return
        self.seen_doc = layer.version
        self.seen_gen = self.generation
        self.snap_lift = self.lift_key.copy()
        var regen = self.generation != self.snap_gen
        self.snap_gen = self.generation
        self.snap.begin()
        for ref o in layer.objs:
            if len(self.lift_set) > 0 and o.id in self.lift_set:
                continue
            if o.kind == CONNECTOR:  # (along the line: its arrowhead, width and antialiasing within 24 px)
                self.snap.feed_line(o.id, _obj_key(o), o.ax, o.ay, o.bx, o.by, o.line_width + CONNECTOR_HEAD + 9)
                continue
            var b = self.paint_box(o)
            self.snap.feed(o.id, _obj_key(o), b[0], b[1], b[2], b[3])
        var rects = self.snap.finish()
        if getenv("MOJOUI_TILE_TRACE") == "1":
            print("BOARD: doc " + String(layer.version) + " board " + String(self.board_version) + " rects " + String(len(rects) // 4) + " fresh " + String(self.snap.fresh)
                  + " lift " + String(len(self.lift_ids)), flush=True)
        if self.snap.fresh or regen:
            self.since = -1
            self.board_version += 1
            return
        if len(rects) == 0:
            return
        self.since = self.board_version
        self.board_version += 1
        self.dmg = rects^

    def forget(mut self):
        """The next paint is a new picture of the board (another document, or a cold open measured as one): no damage
        from the last, so the renderer drops the board layer's kept tiles."""
        self.generation += 1

    def paint_box(mut self, ref o: Obj) -> Tuple[Float64, Float64, Float64, Float64]:
        """Where the object paints, in page px, generously: its box, a sticky's shadow, a text's lines past its box."""
        var b = o.bounds()
        var pad = 28.0
        var y1 = b[3]
        var x1 = b[2]
        if o.kind == TEXT or o.kind == STICKY:
            var inner = o.w - 2 * (o.pad if o.kind == TEXT else STICKY_PAD)
            var n = self.line_count(o, inner)
            var lh = o.line_height if o.line_height > 0 else self.line_height
            y1 = max(y1, o.y + 2 * STICKY_PAD + Float64(n) * o.size * FONT_SIZE_MULT * lh + o.size)
            pad += o.size
            x1 = max(x1, b[2] + o.size)
        return (b[0] - pad, b[1] - pad, x1 + pad, y1 + pad)

    def line_count(mut self, ref o: Obj, width: Float64) -> Int:
        """How many lines the object's words wrap into at `width` (from the wrap cache when it holds them)."""
        if self.wrap_rev.get(o.id, -1) == o.rev and self.wrap_w.get(o.id, -1.0) == width:
            try:
                return len(self.wrap_lines[o.id])
            except:
                pass
        return len(self.lines(o, width))

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
        elif kind == INK:
            ref o = layer.objs[i]
            var rel = List[Float64]()
            for k in range(len(o.stroke.xs)):
                rel.append(o.stroke.xs[k] - o.stroke.xs[0])
                rel.append(o.stroke.ys[k] - o.stroke.ys[0])
            if len(o.stroke.xs) > 0:
                polyline(p, o.stroke.xs[0], o.stroke.ys[0], rel, o.stroke.width, o.stroke.color)
            p.note("object ink " + String(o.id))
        elif kind == CONNECTOR:
            ref o = layer.objs[i]
            draw_arrow(p, o.ax, o.ay, o.bx, o.by, o.line_width, o.color, o.head_end)
            p.note("object connector " + String(o.id))
        else:
            _ = layer.paint_shape(p, i)

    def _words[P: Painter](mut self, mut p: P, ref o: Obj, x: Float64, top: Float64, width: Float64, color: UInt32):
        var st = self.style_of(o)
        var lh = o.line_height if o.line_height > 0 else self.line_height
        if o.markdown:
            # Markdown text is laid out by the browser in CSS line boxes (markdown-layout.js): a row of size · line height,
            # rounded to 1/100 px, the baseline where the inline box puts it
            var row = Float64(Int(o.size * lh * 100 + 0.5)) / 100
            var mls = self.lines(o, width)
            for n in range(len(mls)):
                if mls[n] != "":
                    p.run(st, mls[n], x, baseline_in(top + Float64(n) * row, row, st), color, 0)
            return
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


def polyline[P: Painter](mut p: P, x0: Float64, y0: Float64, pts: List[Float64], width: Float64, color: UInt32):
    """A stroke through points (relative to (x0, y0)), round caps and joins: one Painter.stroke (D-7940)."""
    var abs_pts = List[Float64](capacity=len(pts))
    for i in range(0, len(pts) - 1, 2):
        abs_pts.append(x0 + pts[i])
        abs_pts.append(y0 + pts[i + 1])
    p.stroke(abs_pts, width, color)


# ------------------------------------------------ the tools of a page board (the web's dock and Leafer editor)

comptime SELECT_BLUE: UInt32 = 0xFFA8701C  # #1c70a8
comptime DRAWING_TOOLS = "pen highlight eraser shape sticky connect"
comptime OPENS_PAGE = "shape sticky connect"
comptime ZOOM_STEP = 1.25
comptime T_NONE = 0
comptime T_MOVE = 1
comptime T_INK = 2
comptime T_CONNECT = 3
comptime T_PAN = 4  # the hand tool moving the view


def clamp_axis(offset: Float64, view: Float64, content: Float64, before: Float64, after: Float64, previous: Float64) -> Float64:
    """viewport.js clampAxis: an offset with the content between the margins is kept; outside, it comes back to the
    nearest end (and may stay where it was a moment ago)."""
    var far = view - after - content
    var lo = min(min(before, far), previous)
    var hi = max(max(before, far), previous)
    return min(hi, max(lo, offset))


def page_view(view_w: Float64, view_h: Float64, cx: Float64, cy: Float64, columns: Int, rows: Int, page_w: Float64 = PAGE_W,
              page_h: Float64 = PAGE_H) -> DeskView:
    """The view that shows the whole page under page point (cx, cy) inside the islands' margins (navigation.js pageView)."""
    var m = view_margins(view_w)
    var col = min(columns - 1, max(0, Int(floor(cx / page_w))))
    var row = min(rows - 1, max(0, Int(floor(cy / page_h))))
    var f = fit_view(view_w, view_h, page_w, page_h, m[0], m[1], m[2], m[3], 0.4, 1)
    return DeskView(f.x - Float64(col) * page_w * f.scale, f.y - Float64(row) * page_h * f.scale, f.scale)


struct BoardTools(Movable):
    """What a press, a drag, a tap and a key do on a page board, by tool: select (pick, drag to move), text (a new
    Markdown text where tapped, written in place), sticky (a sticky centred where tapped, written in place), pen (a stroke),
    connect (drag from one object to another), with the web's view moves (writing comes back to 100 %, a drawing tool
    opens the page up). The look of new objects is the app's (the fields below). `changed` turns True on every change
    to the document (the app saves then)."""
    var tool: String
    var editing: Int  # an object being written (-1: none; -2: a new text not made yet)
    var edit_words: String
    var edit_x: Float64
    var edit_y: Float64
    var edit_w: Float64
    var drag: Int
    var drag_from: Int
    var last_x: Float64
    var last_y: Float64
    var wet: Stroke
    var changed: Bool
    var text_family: String
    var text_size: Float64
    var text_line: Float64
    var text_color: UInt32
    var sticky_fill: UInt32
    var sticky_ink: UInt32
    var sticky_family: String
    var sticky_size: Float64
    var sticky_weight: Int
    var sticky_line: Float64
    var pen_color: UInt32
    var pen_width: Float64
    var line_color: UInt32

    def __init__(out self):
        self.tool = "text"
        self.editing = -1
        self.edit_words = ""
        self.edit_x = 0
        self.edit_y = 0
        self.edit_w = 0
        self.drag = T_NONE
        self.drag_from = -1
        self.last_x = 0
        self.last_y = 0
        self.wet = Stroke(3, 0xFF1E2020)
        self.changed = False
        self.text_family = "Geist Mono"
        self.text_size = 24
        self.text_line = 1.45
        self.text_color = 0xFF1E2020
        self.sticky_fill = 0xFF6BD6FF
        self.sticky_ink = 0xFF112229
        self.sticky_family = "Caveat"
        self.sticky_size = 34
        self.sticky_weight = 500
        self.sticky_line = 1.05
        self.pen_color = 0xFF1E2020
        self.pen_width = 3
        self.line_color = 0xFF1E2020

    def set_tool(mut self, name: String, mut layer: ObjectLayer, mut view: DeskView, view_w: Float64, view_h: Float64, columns: Int, rows: Int):
        """A tool picked (the dock, a key). A tool that places things on the page opens the page up (the whole page under
        the window's centre) when the view is closer than that."""
        self.finish(layer)
        self.tool = name
        if name == "shape" or name == "sticky" or name == "connect":  # (OPENS_PAGE)
            var c = view.to_page(view_w / 2, view_h / 2)
            var t = page_view(view_w, view_h, c[0], c[1], columns, rows)
            if view.scale > t.scale + 0.01:
                view = t

    def lifted(self, layer: ObjectLayer) -> List[Int]:
        """What a drag is moving (the selection while a move is under way), for BoardLook.paint to lift out of the
        board's tiles (D-7940); empty otherwise."""
        if self.drag == T_MOVE:
            return layer.selected.copy()
        return List[Int]()

    def finish(mut self, mut layer: ObjectLayer):
        """Ends the writing in progress: a new text with words is made (one undo step with them), a sticky keeps its words."""
        if self.editing == -2:
            var words = String(self.edit_words)
            if String(words.strip()) != "":
                layer.begin_gesture(CH_ADD)
                var id = layer.add_text(self.edit_x, self.edit_y, self.edit_w, Float64(Int(self.text_size * self.text_line * 100 + 0.5)) / 100, words,
                                        self.text_size, self.text_color)
                layer.restyle(id, self.text_family, self.text_size, self.text_line, 400, True, self.text_color)
                layer.end_gesture()
                self.changed = True
        elif self.editing >= 0:
            layer.end_gesture()
            self.changed = True
        self.editing = -1
        self.edit_words = ""

    def tap(mut self, sx: Float64, sy: Float64, mut layer: ObjectLayer, mut view: DeskView, view_w: Float64, view_h: Float64) -> Bool:
        # (a tap comes after its press: a drag the press began never happened)
        if self.drag == T_MOVE:
            layer.end_gesture()
        self.drag = T_NONE
        self.drag_from = -1
        var pt = view.to_page(sx, sy)
        if self.tool == "text":
            self.finish(layer)
            # a new Markdown text, wrapping at its page's right margin (text-ops.js writingBox: margin 56, at least 200 wide)
            var col = max(0, Int(floor(pt[0] / PAGE_W)))
            var right = Float64(col + 1) * PAGE_W - 56
            var x = min(pt[0], right - 200)
            self.editing = -2
            self.edit_words = ""
            self.edit_x = x
            self.edit_y = pt[1]
            self.edit_w = Float64(Int(right - x + 0.5))
            # writing comes back to 100 % (about the page frame's origin), the line kept 16 px above the window's bottom
            if view.scale < 0.99:
                view = DeskView(view.x, view.y, 1.0)
            var bottom = view.y + (pt[1] + Float64(Int(self.text_size * self.text_line * 100 + 0.5)) / 100) * view.scale
            if bottom > view_h - 16:
                view.y -= bottom - (view_h - 16)
            return True
        if self.tool == "sticky":
            self.finish(layer)
            layer.begin_gesture(CH_ADD)
            var id = layer.add_sticky(pt[0] - 120, pt[1] - 100, 240, "", self.sticky_fill, self.sticky_size)
            var q = layer.index(id)
            layer.objs[q].h = 200
            layer.restyle(id, self.sticky_family, self.sticky_size, self.sticky_line, self.sticky_weight, False, self.sticky_ink)
            layer.select(id)
            self.editing = id
            self.edit_words = ""
            self.changed = True
            return True
        if self.tool == "select":
            self.finish(layer)
            _ = layer.click(pt[0], pt[1])
            return True
        return False

    def press(mut self, sx: Float64, sy: Float64, mut layer: ObjectLayer, view: DeskView) -> Bool:
        var pt = view.to_page(sx, sy)
        self.last_x = pt[0]
        self.last_y = pt[1]
        if self.tool == "hand":  # (the view follows the pointer: the web's hand tool and space-drag)
            self.drag = T_PAN
            self.last_x = sx
            self.last_y = sy
            return True
        if self.tool == "select":
            var id = layer.hit_test(pt[0], pt[1], 2)
            if id >= 0:
                self.finish(layer)
                if not layer.is_selected(id):
                    layer.select(id)
                layer.begin_gesture(CH_MOVE)
                self.drag = T_MOVE
                return True
        elif self.tool == "pen":
            self.finish(layer)
            self.wet = Stroke(self.pen_width, self.pen_color)
            self.wet.add(pt[0], pt[1], 0.5)
            self.drag = T_INK
            return True
        elif self.tool == "connect":
            var id = layer.hit_test(pt[0], pt[1], 2)
            if id >= 0:
                self.drag_from = id
                self.drag = T_CONNECT
                return True
        return False

    def pan(mut self, sx: Float64, sy: Float64, mut layer: ObjectLayer, mut view: DeskView) -> Bool:
        if self.drag == T_PAN:
            view = DeskView(view.x + sx - self.last_x, view.y + sy - self.last_y, view.scale)
            self.last_x = sx
            self.last_y = sy
            return True
        var pt = view.to_page(sx, sy)
        if self.drag == T_MOVE:
            layer.move_by(pt[0] - self.last_x, pt[1] - self.last_y)
        elif self.drag == T_INK:
            self.wet.add(pt[0], pt[1], 0.5)
        elif self.drag == T_NONE:
            return False
        self.last_x = pt[0]
        self.last_y = pt[1]
        return True

    def release(mut self, sx: Float64, sy: Float64, mut layer: ObjectLayer, view: DeskView) -> Bool:
        var pt = view.to_page(sx, sy)
        var kind = self.drag
        self.drag = T_NONE
        if kind == T_PAN:
            return True
        if kind == T_MOVE:
            layer.end_gesture()
            self.changed = True
            return True
        if kind == T_INK:
            if self.wet.points() > 1:
                _ = layer.add_ink(self.wet)
                self.changed = True
            return True
        if kind == T_CONNECT:
            var to = layer.hit_test(pt[0], pt[1], 2)
            if to >= 0 and to != self.drag_from:
                _ = layer.add_connector(self.drag_from, to, self.line_color, 2.6)
                layer.clear_selection()
                self.changed = True
            self.drag_from = -1
            return True
        return False

    def key(mut self, name: String, mods: Int, mut layer: ObjectLayer, mut view: DeskView, view_w: Float64, view_h: Float64, columns: Int,
            rows: Int) -> Bool:
        """mods: SHIFT 1, CTRL 2, ALT 4."""
        if self.editing != -1:
            if name == "Escape":
                self.finish(layer)
                self.tool = "select"
                return True
            if name == "Backspace":
                var b = self.edit_words.as_bytes()
                var at = len(b) - 1
                while at > 0 and (Int(b[at]) & 0xC0) == 0x80:
                    at -= 1
                var cut = String(self.edit_words[byte=0:max(at, 0)])
                self.edit_words = cut
            elif name == "Enter":
                self.edit_words += "\n"
            elif (mods & 2) == 0 and (name.byte_length() == 1 or Int(name.as_bytes()[0]) >= 0x80):
                self.edit_words += name
            else:
                return False
            if self.editing >= 0:
                layer.set_words(self.editing, self.edit_words)
            return True
        if (mods & 2) != 0 and (name == "z" or name == "Z"):
            layer.select_on_undo = True  # (the web selects what an undo brings back)
            if (mods & 1) != 0:
                _ = layer.redo()
            else:
                _ = layer.undo()
            self.changed = True
            return True
        if name == "Delete" or name == "Backspace":
            if len(layer.selected) > 0:
                layer.delete_selection()
                self.changed = True
            return True
        if mods != 0 or name.byte_length() != 1:
            return False
        var keys: List[String] = ["v", "t", "p", "d", "e", "r", "n", "c", "h", "m"]
        var tools: List[String] = ["select", "text", "pen", "pen", "eraser", "shape", "sticky", "connect", "hand", "highlight"]
        for i in range(len(keys)):
            if name == keys[i]:
                self.set_tool(tools[i], layer, view, view_w, view_h, columns, rows)
                return True
        return False

    def undo(mut self, mut layer: ObjectLayer):
        self.finish(layer)
        layer.select_on_undo = True
        if layer.undo():
            self.changed = True

    def redo(mut self, mut layer: ObjectLayer):
        self.finish(layer)
        layer.select_on_undo = True
        if layer.redo():
            self.changed = True

    def hug_routes(self, mut layer: ObjectLayer, mut look: BoardLook):
        """After an undo or redo: connectors at Markdown texts route to the words' box (the web draws those texts again
        from the document, hugging their words, and routes by what it drew; D-7943)."""
        var widths = Dict[Int, Float64]()
        for ref o in layer.objs:
            if o.kind == TEXT and o.markdown and len(layer.connectors_of(o.id)) > 0:
                var b = self.selection_box(look, o)
                widths[o.id] = b[2]
        if len(widths) > 0:
            layer.route_widths(widths)

    def zoom_step(self, view: DeskView, direction: Int, view_w: Float64, view_h: Float64, columns: Int, rows: Int) -> DeskView:
        """The zoom island's − and +: a step of 1.25 about the window's centre, kept inside the margins (zoomTarget)."""
        var s = view.scale * (ZOOM_STEP if direction > 0 else 1 / ZOOM_STEP)
        s = min(4.0, max(0.25, s))
        var z = view.zoomed_at(s, view_w / 2, view_h / 2)
        var m = view_margins(view_w)
        z.x = clamp_axis(z.x, view_w, Float64(columns) * PAGE_W * s, m[0], m[1], view.x)
        z.y = clamp_axis(z.y, view_h, Float64(rows) * PAGE_H * s, m[2], m[3], view.y)
        return z

    def scroll(self, view: DeskView, dx: Float64, dy: Float64, view_w: Float64, view_h: Float64, columns: Int, rows: Int) -> DeskView:
        """A wheel or two-finger scroll: the view moves by (dx, dy) screen px, kept inside the margins (clampAxis)."""
        var m = view_margins(view_w)
        var x = clamp_axis(view.x + dx, view_w, Float64(columns) * PAGE_W * view.scale, m[0], m[1], view.x)
        var y = clamp_axis(view.y + dy, view_h, Float64(rows) * PAGE_H * view.scale, m[2], m[3], view.y)
        return DeskView(x, y, view.scale)

    def zoom_at(self, view: DeskView, factor: Float64, sx: Float64, sy: Float64, view_w: Float64, view_h: Float64, columns: Int,
                rows: Int) -> DeskView:
        """A pinch or Ctrl+wheel: the zoom times `factor` about (sx, sy), between 25 % and 400 % (main.js CANVAS_ZOOM_MIN/MAX),
        kept inside the margins."""
        var s = min(4.0, max(0.25, view.scale * factor))
        var z = view.zoomed_at(s, sx, sy)
        var m = view_margins(view_w)
        z.x = clamp_axis(z.x, view_w, Float64(columns) * PAGE_W * s, m[0], m[1], view.x)
        z.y = clamp_axis(z.y, view_h, Float64(rows) * PAGE_H * s, m[2], m[3], view.y)
        return z

    def visible_objects(self, layer: ObjectLayer, view: DeskView, view_w: Float64, view_h: Float64) -> List[Int]:
        """Objects wholly in the window, away from its edges, big enough to grab (benchmark-f034's visibleObjects rule):
        their indices, in stacking order. Ink and connectors are left out."""
        var out = List[Int]()
        for i in range(len(layer.objs)):
            ref o = layer.objs[i]
            if o.kind == INK or o.kind == CONNECTOR or o.locked:
                continue
            var a = view.to_screen(o.x, o.y)
            var sw = o.w * view.scale
            var sh = o.h * view.scale
            if a[0] > 40 and a[1] > 40 and a[0] + sw < view_w - 80 and a[1] + sh < view_h - 80 and sw > 12 and sh > 12:
                out.append(i)
        return out^

    def selection_box(self, mut look: BoardLook, ref o: Obj) -> Tuple[Float64, Float64, Float64, Float64]:
        """The box the editor outlines: a Markdown text hugs its words (its widest line), anything else its box."""
        if o.kind == TEXT and o.markdown:
            var st = look.style_of(o)
            var wmax = 0.0
            for l in look.lines(o, o.w):
                wmax = max(wmax, measure(st, l))
            return (o.x, o.y, ceil(wmax), o.h)
        return (o.x, o.y, o.w, o.h)

    def paint_overlay[P: Painter](mut self, mut p: P, mut look: BoardLook, mut layer: ObjectLayer, v: DeskView, k: Float64):
        """In screen px over the board: the text being written, the stroke being drawn, the selection's outline and handles."""
        p.begin_layer("board-edit")
        p.layer_transform(0, 0, k)
        if self.editing == -2:
            var o = Obj(0, TEXT, self.edit_x, self.edit_y, self.edit_w, 34.8, self.text_color)
            o.text = self.edit_words
            o.size = self.text_size
            o.family = self.text_family
            o.line_height = self.text_line
            o.markdown = True
            o.rev = -1 - self.edit_words.byte_length()
            var st = look.style_of(o)
            var row = Float64(Int(o.size * o.line_height * 100 + 0.5)) / 100
            var sz = TextStyle(st.family, st.weight, st.italic, st.size * v.scale)
            sz.exact = True
            var tl = v.to_screen(o.x, o.y)
            if self.edit_words != "":
                p.run(sz, self.edit_words, tl[0], baseline_in(tl[1], row * v.scale, sz), o.color, 0)
            var cw = measure(sz, self.edit_words)
            p.rect(tl[0] + cw, tl[1] + 4 * v.scale, 1.5, (row - 8) * v.scale, o.color, 0)
        if self.drag == T_INK and len(self.wet.xs) > 1:
            var rel = List[Float64]()
            var a = v.to_screen(self.wet.xs[0], self.wet.ys[0])
            for i in range(len(self.wet.xs)):
                var q = v.to_screen(self.wet.xs[i], self.wet.ys[i])
                rel.append(q[0] - a[0])
                rel.append(q[1] - a[1])
            polyline(p, a[0], a[1], rel, self.wet.width * v.scale, self.wet.color)
        for id in layer.selected:
            var q = layer.index(id)
            if q < 0 or layer.objs[q].kind == CONNECTOR:
                continue
            var b = self.selection_box(look, layer.objs[q])
            var tl = v.to_screen(b[0], b[1])
            var w = b[2] * v.scale
            var h = b[3] * v.scale
            var lw = 1.5
            p.rect(tl[0] - lw / 2, tl[1] - lw / 2, w + lw, lw, SELECT_BLUE, 0)
            p.rect(tl[0] - lw / 2, tl[1] + h - lw / 2, w + lw, lw, SELECT_BLUE, 0)
            p.rect(tl[0] - lw / 2, tl[1] - lw / 2, lw, h + lw, SELECT_BLUE, 0)
            p.rect(tl[0] + w - lw / 2, tl[1] - lw / 2, lw, h + lw, SELECT_BLUE, 0)
            for c in range(4):
                p.circle(tl[0] + (w if c % 2 == 1 else 0.0), tl[1] + (h if c >= 2 else 0.0), 5.5, SELECT_BLUE)
            p.circle(tl[0] + w / 2, tl[1] - 28, 6.5, SELECT_BLUE)
            p.circle(tl[0] + w / 2, tl[1] - 28, 5, 0xFFFFFFFF)
