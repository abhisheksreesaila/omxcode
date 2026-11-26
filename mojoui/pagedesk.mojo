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
from mojoui.scene import Painter, snap_px, KeptOps, corner_rect, KeptPaint, stroke_outline
from mojoui.shared import serial, new_key
from mojoui.viewsnap import snap_read, ViewSnap, SnapKey, renderer_id, build_id
from mojoui.skin import Skin, Shadow, with_alpha
from mojoui.fonttext import TextStyle, measure, baseline_in
from mojoui.ink import Stroke
from mojoui.objectlayer import CH_ADD, CH_MOVE, CH_TEXT, CH_DELETE, CH_RESIZE, CH_ROTATE, H_ROTATE
from mojoui.wordsedit import WordsEdit
from mojoui.textedit import now_ms
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
comptime BOARD_REACH = 160.0  # (D-8019) screen px
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


def writing_view(view_w: Float64, view_h: Float64, page_left: Float64, page_top: Float64, text_top: Float64, text_h: Float64) -> DeskView:
    """The view a note of writing opens at: 100 %, the page centred, its writing (text_h ≥ 0) 32 px under the islands, or its
    end at 60 % of the window when it is longer than that; no writing (text_h < 0): the page's top (navigation.js
    writingView)."""
    var m = view_margins(view_w)
    var x = view_w / 2 - (page_left + PAGE_W / 2)
    if text_h < 0:
        return DeskView(x, m[2] - page_top, 1.0)
    if text_h <= view_h - m[2] - m[3]:
        return DeskView(x, m[2] - (text_top - 32), 1.0)
    return DeskView(x, view_h * 0.6 - (text_top + text_h), 1.0)


def give_way(x: Float64, scale: Float64, area_w: Float64, right: Float64 = PAGE_W, clear: Float64 = 80) -> Float64:
    """How far a page gives way to the tool island when the area is narrow (viewport.js giveWayToIsland)."""
    var over = x + right * scale - (area_w - clear)
    return max(0.0, min(over, x - 16)) if over > 0 else 0.0


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
                                 page_w: Float64, page_h: Float64, k: Float64, sk: Skin, mut kept: KeptPaint):
    """The page frame in screen px (chrome.js pageChrome): the skin's shadow layers as bands, the edge one hairline out,
    the paper, dashed folds between pages, "Page N" under each page of the bottom row (inside the corner above it).
    Its own layer, drawn about the frame's origin and moved there by the layer's transform, with a version from what
    shapes it (zoom, pages, skin, device scale): a pan moves the kept picture and draws nothing (D-7929)."""
    var w = Float64(columns) * page_w * at.scale
    var h = Float64(rows) * page_h * at.scale
    if w <= 0 or h <= 0:
        return
    bx.add("desk.sheet", at.x, at.y, w, h)
    # (D-8024: painted once per look, its ops replayed: 962 for sixteen pages)
    var token = (String(at.scale) + "|" + String(columns) + "|" + String(rows) + "|" + String(k) + "|" + String(sk.paper) + "|" + String(sk.edge) + "|" + String(page_w) + "|" + String(page_h)
                 + "|" + String(sk.page_radius) + "|" + String(sk.ui_muted))
    for s in sk.shadow2:
        token += "|" + String(s.dx) + "," + String(s.dy) + "," + String(s.blur) + "," + String(s.spread) + "," + String(s.color)
    if not kept.begin(p, "page-frame", token, k, at.x * k, at.y * k):
        return
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
    if opaque and min(w, h) > 2 * (2 + 0.3 * (r + 1)) + 48:  # (the paper hides the edge's middle: filled once, not twice)
        p.rect_hole(v.x - 1, v.y - 1, w + 2, h + 2, sk.edge, r + 1, 2 + 0.3 * (r + 1))
    else:
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
    kept.end(p)


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


def board_rect(v: DeskView, view_w: Float64, view_h: Float64, reach: Float64 = 0) -> Tuple[Float64, Float64, Float64, Float64]:
    """The page rect BoardLook.paint draws objects from for this view: the window, 64 page px or `reach` screen px more
    (the larger), snapped out to whole BOARD_TILEs (a progressive open's first slice takes the reach 0 one:
    mojoui.canvasload.OpenBoard)."""
    var tl = v.to_page(0, 0)
    var br = v.to_page(view_w, view_h)
    var m = max(64.0, reach / max(v.scale, 0.01))
    return (floor((tl[0] - m) / BOARD_TILE) * BOARD_TILE, floor((tl[1] - m) / BOARD_TILE) * BOARD_TILE,
            ceil((br[0] + m) / BOARD_TILE) * BOARD_TILE, ceil((br[1] + m) / BOARD_TILE) * BOARD_TILE)


@fieldwise_init
struct Wrapped(Copyable, Movable):
    """An object's wrapped lines and everything they came from: good for any object of any document that has the same."""
    var text: String
    var width: Float64
    var family: String
    var size: Float64
    var weight: Int
    var lines: List[String]

    def of(self, ref o: Obj, width: Float64) -> Bool:
        return self.width == width and self.size == o.size and self.weight == o.weight and self.family == o.family and self.text == o.text


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
    h = _mix(h, o.picture[0][].hash if len(o.picture) > 0 else 0)
    return Int(h >> 1)


struct BoardLook(Movable):
    """The paper look of a page board: faces and sizes from each object (a document's own type), defaults for objects that
    have none, wrapped lines cached per object revision and width."""
    var family: String  # the face of a text with none of its own
    var line_height: Float64  # × size, for a text with none of its own
    var wraps: Dict[Int, Wrapped]  # by object id: what it was wrapped from is compared, never its revision (review 3: another document's object has the same id, revision and width)
    var seen_layer: Int  # (review 3) the document last painted (ObjectLayer.doc): another one starts everything anew
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
    var lift_was: Dict[Int, Bool]  # (D-8005) the lift set before the last change of it
    var kept_lift: List[Int]  # the lift the kept ops were taken with
    var snap_lift: List[Int]  # the lift and the look's generation the snapshot was taken with
    var snap_gen: Int
    var keep_path: String  # (D-7956) the file the board's last view is kept in ("": none), the app's tag for what it
    var keep_tag: String  # shows ("": being edited: nothing kept or shown), and whether its objects are still loading
    var keep_hold: Bool
    var kept: KeptOps  # (D-7963) the board's ops from the last paint, replayed while kept_token holds
    var kept_token: String
    var corner_quads: Bool  # (D-8021) stickies' bodies without stencils (MOJOUI_CORNER_QUADS=0: as polygons; on the Mac since test_rectcorner_metal passed there, 11-24)
    var reach: Float64  # (D-8019) how far past the window (screen px) the ops are complete, so a zoom-out finds its edges rastered (an app sets 0 while the board is still loading)
    var kept_gen: Int  # (D-8010) the look the kept ops were painted with
    var seg_at: Dict[Int, Int]  # (D-7974) the kept ops per object: id → its range [seg_a, seg_b)
    var seg_a: List[Int]
    var seg_b: List[Int]
    var dirty_ids: Dict[Int, Bool]  # objects changed since the ops were kept, and whether that is all that changed
    var dirty_known: Bool
    var patch_on: Bool  # MOJOUI_KEEP_PATCH=0: walk every changed board whole (the comparison)
    var patches: Int
    var ops_clean: Bool  # (D-7969) nothing inside the cull rect changed since the kept ops were taken
    var fill_outside: Bool  # the last look found only adoptions, none meeting the cull rect
    var cull: List[Float64]
    var last_token: String
    var keep_ops: Bool  # MOJOUI_KEEP_OPS=0: walk every paint (an A/B)
    var shadow_holes: Bool  # (D-7973) MOJOUI_SHADOW_HOLE=0: shadows drawn whole (the comparison)
    var change_log: Bool  # (D-7978) MOJOUI_CHANGE_LOG=0: every change compared over all objects (the comparison)
    var hold_skip: Bool  # MOJOUI_HOLD_SKIP=0 / MOJOUI_FILL_KEEP=0: A/B switches for D-7969
    var fill_keep: Bool
    var kept_ver: Int
    var held_paints: Int  # (D-7969) paints that walked nothing while holding
    var replays: Int  # paints that replayed the kept ops (nothing walked)
    var fills: Int  # (D-7960) looks that found only adoptions (damage from those objects alone, nothing walked)
    var keep_note: String  # the app's words kept in the file's head (kept_note() reads them back first)
    var build: Int

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
        self.lift_was = Dict[Int, Bool]()
        self.kept_lift = List[Int]()
        self.snap_lift = List[Int]()
        self.snap_gen = 0
        self.wraps = Dict[Int, Wrapped]()
        self.seen_layer = -1
        self.keep_path = ""
        self.keep_tag = ""
        self.keep_hold = False
        self.keep_note = ""
        self.fills = 0
        self.kept = KeptOps()
        self.kept_token = ""
        self.kept_gen = -1
        self.reach = BOARD_REACH
        self.corner_quads = getenv("MOJOUI_CORNER_QUADS") != "0"
        self.seg_at = Dict[Int, Int]()
        self.seg_a = List[Int]()
        self.seg_b = List[Int]()
        self.dirty_ids = Dict[Int, Bool]()
        self.dirty_known = False
        self.patch_on = getenv("MOJOUI_KEEP_PATCH") != "0"
        self.patches = 0
        self.ops_clean = False
        self.fill_outside = False
        self.cull = List[Float64]()
        self.last_token = ""
        self.replays = 0
        self.held_paints = 0
        self.hold_skip = getenv("MOJOUI_HOLD_SKIP") != "0"
        self.change_log = getenv("MOJOUI_CHANGE_LOG") != "0"
        self.shadow_holes = getenv("MOJOUI_SHADOW_HOLE") != "0"
        self.fill_keep = getenv("MOJOUI_FILL_KEEP") != "0"
        self.kept_ver = -1
        self.keep_ops = getenv("MOJOUI_KEEP_OPS") != "0"
        self.build = build_id()

    def kept_head(self, path: String) -> ViewSnap:
        """(D-8024) The head of the board's last view kept at path (a small read; ok False: none): ask head_note and
        head_shows with it, instead of reading it twice."""
        if path == "" or renderer_id() == 0:
            return ViewSnap()
        return snap_read(path, True)

    def head_shows(self, head: ViewSnap, tag: String, v: DeskView, view_w: Float64, view_h: Float64, k: Float64) -> Bool:
        """Whether the GPU renderer would show that kept view for this tag, view and size (its key, every part compared as
        the renderer will)."""
        if tag == "" or not head.ok:
            return False
        var want = SnapKey(tag, renderer_id(), self.build, v.scale * k, snap_px(v.x * k), snap_px(v.y * k), Int(view_w * k + 0.5), Int(view_h * k + 0.5))
        return head.key.same(want)

    def head_note(self, head: ViewSnap, tag: String) -> String:
        """The note kept with that view when it was kept for this tag ("" otherwise): what the app needs to lay the view
        out (its page grid) before the document is read."""
        return head.note if head.ok and tag != "" and head.key.tag == tag else String("")

    def kept_view(self, path: String, tag: String, v: DeskView, view_w: Float64, view_h: Float64, k: Float64) -> Bool:
        """(D-7956) Whether the GPU renderer would show the board's last view kept at path for this tag, view and size. An
        app opening a document asks this first: when True it can show the kept view and load the board underneath."""
        return self.head_shows(self.kept_head(path), tag, v, view_w, view_h, k)

    def kept_note(self, path: String, tag: String) -> String:
        """(D-7956) The note kept with the board's last view at path when it was kept for this tag ("" otherwise)."""
        return self.head_note(self.kept_head(path), tag)

    def style_of(self, ref o: Obj) -> TextStyle:
        var st = TextStyle(o.family if o.family != "" else self.family, o.weight, False, o.size)
        st.exact = True  # canvas text: measureText's advances, unrounded
        return st

    def lines(mut self, ref o: Obj, width: Float64) -> List[String]:
        """The object's words broken into lines at `width` page px: its own line breaks, then at the last space that
        fits (a word wider than the box stays whole on its line)."""
        try:
            if o.id in self.wraps and self.wraps[o.id].of(o, width):
                return self.wraps[o.id].lines.copy()
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
        self.wraps[o.id] = Wrapped(o.text, width, o.family, o.size, o.weight, out.copy())
        return out^

    def paint[P: Painter](mut self, mut p: P, mut layer: ObjectLayer, v: DeskView, view_w: Float64, view_h: Float64, k: Float64,
                          lifted: List[Int] = List[Int]()):
        """The objects meeting the window, in z order, as one layer in page px shown through the view, kept by the
        renderer as raster tiles (D-7940): a pan or a zoom composites what's kept, an edit rasters again only the tiles
        its damage meets. `lifted` (ids: what a drag is moving) is drawn in a layer of its own above the board, with the
        connectors that end at it, so the board's tiles stay as they are until the drag lets go."""
        if layer.doc != self.seen_layer:
            self._another_document(layer.doc)
        # culled to the window snapped out to whole tiles of page px (D-7929): the layer's extent, its ops complete there
        var cull = board_rect(v, view_w, view_h, self.reach)
        var tx0 = cull[0]
        var ty0 = cull[1]
        var tx1 = cull[2]
        var ty1 = cull[3]
        self._lift(layer, lifted)
        self.cull = [tx0, ty0, tx1, ty1]
        var ver0 = self.board_version
        self._track(layer, len(lifted) > 0)
        var inside_changed = self.board_version != ver0 and not self.fill_outside
        if self.board_version != ver0:  # (D-7974) what changed since the kept ops, by id (a new picture: unknown)
            if self.since < 0:
                self.dirty_known = False
            for id in self.snap.changed:
                self.dirty_ids[id] = True
        # (D-7963) what the board's ops depend on besides the objects: the look (generation) and the cull rect. (D-7969: not
        # the board's version: the ops stay good while every change since they were kept was objects adopted outside the
        # cull rect. D-8005: not the lift: a patch leaves lifted objects out and paints dropped ones. D-8010: not the zoom
        # or the host's scale: the ops are in page px, the layer's transform is what zooms them)
        var token = String(self.generation) + "|" + String(tx0) + "," + String(ty0) + "," + String(tx1) + "," + String(ty1)
        if self.board_version != ver0 and (inside_changed or token != self.kept_token):
            self.ops_clean = False  # (D-7969) something inside the kept ops' cull rect may have changed since they were kept
        p.begin_layer("board")
        p.layer_version(self.board_version)
        p.layer_transform(v.x * k, v.y * k, v.scale * k)
        # (objects are culled by their boxes; a sticky's shadow or a text's lines reach past them, so the ops are complete
        # only a margin inside the culled rect: that is the extent. The window stays inside it: 64 px were added first)
        p.layer_tiles(tx0 + 64, ty0 + 64, tx1 - 64, ty1 - 64)
        if self.keep_path != "":
            p.layer_snapshot(self.keep_path, self.keep_tag, self.keep_hold, self.keep_note)
        for d in range(len(self.dmg) // 4):
            p.layer_damage(self.since, self.dmg[4 * d], self.dmg[4 * d + 1], self.dmg[4 * d + 2], self.dmg[4 * d + 3])
        var any_lift = len(self.lift_ids) > 0
        var up = List[Int]()
        # (D-7963) the same board, cull rect, lift and look as the kept ops: those ops again, nothing walked (D-8005: ops kept
        # under one lift are replayed whole only under the same one)
        if self.hold_skip and self.keep_hold and self.keep_path != "" and self.keep_tag != "":
            # (D-7969) holding: the renderer shows the kept view and rasters nothing from these ops; none are walked
            self.held_paints += 1
        elif self.keep_ops and token == self.kept_token and self.kept_lift == self.lift_key and (self.ops_clean if self.fill_keep else self.kept_ver == self.board_version) and p.ops_replay(self.kept):
            self.replays += 1
            p.layer_ops_version(self.kept_ver)  # (D-7969: the same ops as at kept_ver: a renderer keeps its bins)
        else:
            # (D-7974) the same look as the kept ops and every change since known by id: a patch: changed objects, and ones
            # that came into the view (D-8010), painted; every other object's kept ops replayed; the order the layer's (z)
            var patch = self.keep_ops and self.patch_on and self.kept_gen == self.generation and self.kept.ok and self.dirty_known and p.ops_mark() >= 0
            var mark = p.ops_mark()
            var segs = List[Int]()  # per object painted: id, first op, end op (from mark)
            var run_a = -1  # kept ops waiting to be replayed: [run_a, run_b) (a patch only goes to a painter that can: it kept them)
            var run_b = -1
            for i in layer.query(tx0, ty0, tx1, ty1):
                if any_lift and layer.objs[i].id in self.lift_set:
                    up.append(i)
                    continue
                var id = layer.objs[i].id
                var sg = self.seg_at.get(id, -1) if patch and not (id in self.dirty_ids) else -1
                if sg >= 0:  # (D-7999: unchanged neighbours' kept ops replayed as one run)
                    if self.seg_a[sg] != run_b:
                        if run_b > run_a:
                            _ = p.ops_replay_range(self.kept, run_a, run_b)
                        run_a = self.seg_a[sg]
                        run_b = run_a
                    var at = p.ops_mark() + (run_b - run_a) - mark
                    run_b = self.seg_b[sg]
                    segs += [id, at, at + self.seg_b[sg] - self.seg_a[sg]]
                    continue
                if run_b > run_a:
                    _ = p.ops_replay_range(self.kept, run_a, run_b)
                    run_a = -1
                    run_b = -1
                var s0 = p.ops_mark()
                self.paint_obj(p, layer, i)
                if mark >= 0:
                    segs += [id, s0 - mark, p.ops_mark() - mark]
            if run_b > run_a:
                _ = p.ops_replay_range(self.kept, run_a, run_b)
            if patch:
                self.patches += 1
            var keep_now = token == self.last_token and not inside_changed
            if self.keep_ops and mark >= 0 and (keep_now or patch):  # (kept once it held two paints, or patched from kept)
                self.kept = p.ops_capture(mark)
                self.kept_token = token
                self.kept_gen = self.generation
                self.kept_ver = self.board_version
                self.kept_lift = self.lift_key.copy()
                self.ops_clean = True
                self.seg_at = Dict[Int, Int]()
                self.seg_a = List[Int]()
                self.seg_b = List[Int]()
                for q in range(len(segs) // 3):
                    self.seg_at[segs[3 * q]] = q
                    self.seg_a.append(segs[3 * q + 1])
                    self.seg_b.append(segs[3 * q + 2])
                self.dirty_ids = Dict[Int, Bool]()
                self.dirty_known = True
            self.last_token = token
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
        self.lift_was = self.lift_set.copy()  # (D-8005: what a change of lift concerns, with the new one)
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
        drag that keeps its lift moves lifted things, which are out of the board: only what else the change log names is
        looked at."""
        self.dmg.clear()
        self.fill_outside = False
        var lift_changed = self.lift_key != self.snap_lift
        if layer.version == self.seen_doc and self.generation == self.seen_gen and not lift_changed:
            return
        # (D-7960, D-7978) every change since the last look named by id (ObjectLayer.changes_since: edits, undo and
        # redo, re-routed connectors, removals, adoptions): their damage alone, nothing walked
        if self.change_log and self.generation == self.seen_gen and self.snap.have:
            var ch = layer.changes_since(self.seen_doc)
            if ch:
                self.seen_doc = layer.version
                self.fills += 1
                self.fill_outside = not lift_changed
                if lift_changed:  # (D-8005: what was lifted and what is now: their places vacated or filled again)
                    var more = List[Int]()
                    for e in self.lift_was.keys():
                        more.append(e)
                    for e in self.lift_set.keys():
                        more.append(e)
                    ch = ch.value() + more^
                    self.snap_lift = self.lift_key.copy()
                self.snap.changed = List[Int]()
                var rects = List[Float64]()
                var done = Dict[Int, Bool]()
                for id in ch.value():
                    if id in done:
                        continue
                    done[id] = True
                    var old = self.snap.box_of(id)
                    if len(old) == 4 and len(self.cull) == 4 and old[2] >= self.cull[0] and old[0] <= self.cull[2] and old[3] >= self.cull[1] and old[1] <= self.cull[3]:
                        self.fill_outside = False
                    var q = layer.index(id)
                    if q < 0 or (len(self.lift_set) > 0 and id in self.lift_set):  # (gone, or lifted: out of the board)
                        rects += self.snap.remove(id)
                        continue
                    ref o = layer.objs[q]
                    var ob = o.bounds()  # (what the cull query tests: meets the cull rect, its ops change)
                    if len(self.cull) == 4 and ob[2] >= self.cull[0] and ob[0] <= self.cull[2] and ob[3] >= self.cull[1] and ob[1] <= self.cull[3]:
                        self.fill_outside = False
                    if o.kind == CONNECTOR:
                        rects += self.snap.append(o.id, _obj_key(o), o.ax, o.ay, o.bx, o.by, o.line_width + CONNECTOR_HEAD + 9)
                    else:
                        var bx = self.paint_box(o)
                        rects += self.snap.append(o.id, _obj_key(o), bx[0], bx[1], bx[2], bx[3])
                if getenv("MOJOUI_TILE_TRACE") == "1":
                    var t = String("BOARDLOG: ids " + String(len(done)) + " rects")
                    for q in range(len(rects) // 4):
                        t += " " + String(Int(rects[4 * q + 2] - rects[4 * q])) + "x" + String(Int(rects[4 * q + 3] - rects[4 * q + 1])) + "@" + String(Int(rects[4 * q])) + "," + String(Int(rects[4 * q + 1]))
                    for id in done:
                        var q = layer.index(id)
                        if q >= 0:
                            t += " kind" + String(layer.objs[q].kind)
                    print(t, flush=True)
                if len(rects) > 0:
                    self.since = self.board_version
                    self.board_version = serial()
                    self.dmg = rects^
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
            self.board_version = serial()
            return
        if len(rects) == 0:
            return
        self.since = self.board_version
        self.board_version = serial()
        self.dmg = rects^

    def _another_document(mut self, doc: Int):
        """(review 3) The layer painted from here on is another document: nothing kept of the last one (its ops, the change
        log's place, its damage snapshot, its lift, its wrapped lines) means anything, however alike their ids and
        versions. The look itself is kept."""
        self.seen_layer = doc
        self.generation += 1
        self.snap = DamageSnap()
        self.seen_doc = -1
        self.since = -1
        self.dmg.clear()
        self.lift_ids.clear()
        self.lift_key.clear()
        self.lift_set = Dict[Int, Bool]()
        self.lift_was = Dict[Int, Bool]()
        self.snap_lift.clear()
        self.kept = KeptOps()
        self.kept_token = ""
        self.last_token = ""
        self.kept_lift.clear()
        self.seg_at = Dict[Int, Int]()
        self.seg_a.clear()
        self.seg_b.clear()
        self.dirty_ids = Dict[Int, Bool]()
        self.dirty_known = False
        self.ops_clean = False
        self.fill_outside = False
        self.wraps = Dict[Int, Wrapped]()

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
        try:
            if o.id in self.wraps and self.wraps[o.id].of(o, width):
                return len(self.wraps[o.id].lines)
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
            # (D-7973) an opaque sticky hides its shadow's middle: inset 10 page px stays inside its 24 px corner
            var hm = 10.0 if self.shadow_holes and ((o.color >> 24) & 0xFF) == 0xFF else -1.0
            draw_shadows(p, o.x, o.y, o.w, o.h, 6, [Shadow(0, 9, 16, 0, rgba(0, 0, 0, 66))], hm, 24)
            if self.corner_quads:
                p.rect_corner(o.x, o.y, o.w, o.h, o.color, 4, 24)
            else:
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
    if (color >> 24) != 0xFF:  # (a highlighter's: one polygon, even where it crosses itself)
        p.polygon(stroke_outline(abs_pts, width), color)
        return
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
comptime T_ERASE = 5
comptime T_WORDS = 6  # a selection in the words being written
comptime T_BOX = 7  # a marquee
comptime T_HANDLE = 8  # a corner of the selected box, or its knob
comptime ERASER_RADIUS = 13.0
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


def _dense(mut st: Stroke, step: Float64):
    """Points added along a stroke so that none is further than `step` from the next."""
    var out = Stroke(st.width, st.color)
    for k in range(len(st.xs)):
        if k > 0:
            var dx = st.xs[k] - st.xs[k - 1]
            var dy = st.ys[k] - st.ys[k - 1]
            var n = Int(sqrt(dx * dx + dy * dy) / step)
            for q in range(1, n + 1):
                var t = Float64(q) / Float64(n + 1)
                out.add(st.xs[k - 1] + dx * t, st.ys[k - 1] + dy * t, 0.5)
        out.add(st.xs[k], st.ys[k], st.ps[k] if k < len(st.ps) else 0.5)
    st = out^


def erase_at(mut layer: ObjectLayer, x: Float64, y: Float64) -> Bool:
    """The stroke eraser at a page point: the points of a pen stroke within its reach go, what is left of the stroke stays as
    strokes of its own (ink-model.js createEraser). True when it erased something. Inside the caller's gesture."""
    var any = False
    for p in layer.query(x - ERASER_RADIUS, y - ERASER_RADIUS, x + ERASER_RADIUS, y + ERASER_RADIUS):
        if layer.objs[p].kind != INK or layer.objs[p].locked:
            continue
        var st = layer.objs[p].stroke.copy()
        _dense(st, ERASER_RADIUS / 2)  # (a fast stroke has few points)
        var reach = ERASER_RADIUS + st.width / 2
        var runs = List[Stroke]()
        var run = Stroke(st.width, st.color)
        var hit = False
        for k in range(len(st.xs)):
            var dx = st.xs[k] - x
            var dy = st.ys[k] - y
            if dx * dx + dy * dy > reach * reach:
                run.add(st.xs[k], st.ys[k], 0.5)
            else:
                hit = True
                if run.points() > 1:
                    runs.append(run.copy())
                run = Stroke(st.width, st.color)
        if not hit:
            continue
        if run.points() > 1:
            runs.append(run.copy())
        any = True
        layer.delete(layer.objs[p].id)
        for k in range(len(runs)):
            _ = layer.add_ink(runs[k])
        return erase_at(layer, x, y) or any  # (the list of objects changed: again for the others here)
    return any


struct BoardTools(Movable):
    """What a press, a drag, a tap and a key do on a page board, by tool: select (pick, drag to move), text (a new
    Markdown text where tapped, written in place), sticky (a sticky centred where tapped, written in place), pen (a stroke),
    connect (drag from one object to another), with the web's view moves (writing comes back to 100 %, a drawing tool
    opens the page up). The look of new objects is the app's (the fields below). `changed` turns True on every change
    to the document (the app saves then)."""
    var tool: String
    var draft_key: String  # the new text's name in the file, once a save took it ("": none did)
    var editing: Int  # an object being written (-1: none; -2: a new text not made yet)
    var words: WordsEdit  # its words, caret and selection
    var edit_x: Float64
    var edit_y: Float64
    var edit_w: Float64
    var moved: Bool  # the move under way has moved something (what lifts it)
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
    var marker_color: UInt32  # the highlighter's
    var marker_width: Float64
    var line_color: UInt32
    var shape_fill: UInt32
    var shape_w: Float64
    var shape_h: Float64
    var shape_radius: Float64
    var handles: List[Float64]  # where the one selected box's corners and knob were last drawn (screen): handle, x, y each
    var handle: Int
    var before_press: List[Int]  # the selection before the last press (a Shift+click adds to it)
    var erased: Bool  # the eraser's drag has erased something
    var box_x0: Float64  # a marquee's start (page px)
    var box_y0: Float64

    def __init__(out self):
        self.tool = "text"
        self.editing = -1
        self.words = WordsEdit()
        self.edit_x = 0
        self.edit_y = 0
        self.edit_w = 0
        self.moved = False
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
        self.marker_color = 0x553FA0D6
        self.marker_width = 20
        self.shape_fill = 0xFF0AD6FF  # #ffd60a
        self.shape_w = 280
        self.shape_h = 180
        self.shape_radius = 28
        self.erased = False
        self.before_press = List[Int]()
        self.handles = List[Float64]()
        self.draft_key = ""
        self.handle = -1
        self.box_x0 = 0
        self.box_y0 = 0

    # ------------------------------------------------ the words being written

    def words_box(self, layer: ObjectLayer) -> Tuple[Float64, Float64, Float64, Float64, Float64]:
        """Where the words being written lie: left, top, width, a line's height, the first baseline under the top (page
        px), as BoardLook draws them there."""
        if self.editing == -2:
            var row = Float64(Int(self.text_size * self.text_line * 100 + 0.5)) / 100
            return (self.edit_x, self.edit_y, self.edit_w, row, baseline_in(0, row, self.words.style))
        var q = layer.index(self.editing)
        if q < 0:
            return (0.0, 0.0, 1.0, 1.0, 1.0)
        ref o = layer.objs[q]
        var pad = STICKY_PAD if o.kind == STICKY else o.pad
        var lh = o.line_height if o.line_height > 0 else 1.16
        if o.kind == TEXT and o.markdown or o.markdown:
            var row = Float64(Int(o.size * lh * 100 + 0.5)) / 100
            return (o.x + pad, o.y + pad, o.w - 2 * pad, row, baseline_in(0, row, self.words.style))
        var row = o.size * FONT_SIZE_MULT * lh
        return (o.x + pad, o.y + pad, o.w - 2 * pad, row, o.size * FONT_SIZE_MULT * (1 - FONT_SIZE_FRACTION))

    def in_words(self, layer: ObjectLayer, px: Float64, py: Float64) -> Bool:
        """The page point is in the box being written."""
        if self.editing == -1:
            return False
        if self.editing >= 0:
            var q = layer.index(self.editing)
            if q < 0:
                return False
            ref o = layer.objs[q]
            return px >= o.x and px <= o.x + o.w and py >= o.y and py <= o.y + o.h
        var b = self.words_box(layer)
        return px >= b[0] - 4 and px <= b[0] + b[2] and py >= b[1] and py <= b[1] + b[3] * Float64(max(len(self.words.lines), 1))

    def look_from(mut self, o: BoardTools):
        """How new things look, as `o` has it (the same board read again: the pen's colour stays)."""
        self.text_family = o.text_family
        self.text_size = o.text_size
        self.text_line = o.text_line
        self.text_color = o.text_color
        self.sticky_fill = o.sticky_fill
        self.sticky_ink = o.sticky_ink
        self.sticky_family = o.sticky_family
        self.sticky_size = o.sticky_size
        self.sticky_weight = o.sticky_weight
        self.sticky_line = o.sticky_line
        self.pen_color = o.pen_color
        self.pen_width = o.pen_width
        self.marker_color = o.marker_color
        self.marker_width = o.marker_width
        self.line_color = o.line_color
        self.shape_fill = o.shape_fill

    def begin_text(mut self, x_in: Float64, y: Float64):
        """A new Markdown text begun at a page point, wrapping at its page's right margin (text-ops.js writingBox); it is made
        when it has words."""
        var right = Float64(max(0, Int(floor(x_in / PAGE_W))) + 1) * PAGE_W - 56
        var x = min(x_in, right - 200)
        self.editing = -2
        self.edit_x = x
        self.edit_y = y
        self.edit_w = Float64(Int(right - x + 0.5))
        var st = TextStyle(self.text_family, 400, False, self.text_size)
        st.exact = True
        self.words.begin("", st, self.edit_w)

    def begin_words(mut self, mut layer: ObjectLayer, id: Int, select_all: Bool = False):
        """Writing on an object's words begins (an undo step that ends with finish)."""
        var q = layer.index(id)
        if q < 0:
            return
        layer.begin_gesture(CH_TEXT)
        self.editing = id
        var o = layer.objs[q].copy()
        var st = TextStyle(o.family if o.family != "" else String("Source Serif 4"), o.weight, False, o.size)
        st.exact = True
        self.words.begin(o.text, st, o.w - 2 * (STICKY_PAD if o.kind == STICKY else o.pad))

    def text_in(mut self, words: String, mut layer: ObjectLayer) -> Bool:
        """An input method's commit or a paste, into the words being written."""
        if self.editing == -1 or layer.read_only:
            return False
        self.words.preedit = ""
        self.words.insert(words, now_ms())
        if self.editing >= 0:
            layer.set_words(self.editing, self.words.text())
        self.changed = True  # (a new text's words too: saved as they are typed)
        return True

    def words_caret(mut self, layer: ObjectLayer, v: DeskView) -> Tuple[Float64, Float64, Float64, Float64]:
        """The caret on screen (x, y, w, h): where an input method opens its window."""
        var b = self.words_box(layer)
        var c = self.words.caret_at(b[3])
        var tl = v.to_screen(b[0] + c[0], b[1] + c[1])
        return (tl[0], tl[1], 2.0, b[3] * v.scale)

    def set_tool(mut self, name: String, mut layer: ObjectLayer, mut view: DeskView, view_w: Float64, view_h: Float64, columns: Int, rows: Int):
        """A tool picked (the dock, a key). A tool that places things on the page opens the page up (the whole page under
        the window's centre) when the view is closer than that."""
        self.finish(layer)
        self.tool = name
        if name != "select" and name != "hand":  # (placing or drawing: no handles meanwhile)
            layer.clear_selection()
        if name == "shape" or name == "sticky" or name == "connect":  # (OPENS_PAGE)
            var c = view.to_page(view_w / 2, view_h / 2)
            var t = page_view(view_w, view_h, c[0], c[1], columns, rows)
            if view.scale > t.scale + 0.01:
                view = t

    def lifted(self, layer: ObjectLayer) -> List[Int]:
        """What a drag is moving (the selection while a move is under way), for BoardLook.paint to lift out of the
        board's tiles (D-7940); empty otherwise."""
        if self.drag == T_MOVE and self.moved:  # (D-8018: from the first movement, not the press: a press alone changes nothing on the board, and a click rastered its tiles twice for nothing)
            return layer.selected.copy()
        return List[Int]()

    def draft(mut self, mut layer: ObjectLayer):
        """What is being written as the board would hold it, for a save to take meanwhile (a person's words reach the file
        while they type): a new text becomes layer.draft (the board, its undo and its tiles don't change), a text written on
        gets its height. layer.draft stays until the next call."""
        layer.draft = None
        if self.editing == -2:
            var words = self.words.text()
            if String(words.strip()) != "":
                self.words.lay()
                var row = Float64(Int(self.text_size * self.text_line * 100 + 0.5)) / 100
                var o = Obj(0, TEXT, self.edit_x, self.edit_y, self.edit_w, row * Float64(max(len(self.words.lines), 1)), self.text_color)
                o.text = words
                o.line_width = 0
                o.family = self.text_family
                o.size = self.text_size
                o.line_height = self.text_line
                o.weight = 400
                o.markdown = True
                if self.draft_key == "":
                    self.draft_key = new_key("obj-")  # (the same node from one save to the next, and when it is made)
                o.key = self.draft_key
                o.z = layer.z_top + 1
                layer.draft = o^
        elif self.editing >= 0:
            self.hug_words(layer)

    def hug_words(mut self, mut layer: ObjectLayer):
        """The text being written on, as high as its words."""
        var q = layer.index(self.editing)
        if q >= 0 and layer.objs[q].kind == TEXT and self.words.ed.history.can_undo():  # (its words changed: so may its height)
            self.words.lay()
            var pad = layer.objs[q].pad
            var row = self.words_box(layer)[3]
            layer.set_height(self.editing, row * Float64(max(len(self.words.lines), 1)) + 2 * pad)

    def finish(mut self, mut layer: ObjectLayer):
        """Ends the writing in progress: a new text with words is made (one undo step with them), a sticky keeps its words."""
        if self.editing == -2:
            var words = self.words.text()
            self.words.lay()
            if String(words.strip()) != "":
                layer.begin_gesture(CH_ADD)
                var id = layer.add_text(self.edit_x, self.edit_y, self.edit_w, Float64(Int(self.text_size * self.text_line * 100 + 0.5)) / 100 * Float64(max(len(self.words.lines), 1)), words,
                                        self.text_size, self.text_color)
                layer.restyle(id, self.text_family, self.text_size, self.text_line, 400, True, self.text_color)
                if self.draft_key != "":
                    layer.objs[layer.index(id)].key = self.draft_key
                layer.end_gesture()
                self.changed = True
            elif self.draft_key != "":  # (its words were saved while they were written, and taken back: so is it in the file)
                self.changed = True
            layer.draft = None
            self.draft_key = ""
        elif self.editing >= 0:
            self.hug_words(layer)
            layer.end_gesture()
            if self.words.ed.history.can_undo():  # (a caret that came and went changed nothing)
                self.changed = True
        self.editing = -1
        self.words.preedit = ""

    def tap(mut self, sx: Float64, sy: Float64, mut layer: ObjectLayer, mut view: DeskView, view_w: Float64, view_h: Float64, mods: Int = 0) -> Bool:
        """mods: SHIFT 1 (a Shift+click adds to the selection, or takes away)."""
        if layer.read_only:
            return False
        # (a tap comes after its press: a drag the press began never happened)
        if self.drag == T_MOVE:
            layer.end_gesture()
        if self.drag == T_ERASE or self.drag == T_HANDLE:
            layer.end_gesture()
        self.drag = T_NONE
        self.drag_from = -1
        var pt = view.to_page(sx, sy)
        if self.in_words(layer, pt[0], pt[1]):  # (its press put the caret)
            self.words.release()
            return True
        if self.tool == "text":
            self.finish(layer)
            # a new Markdown text, wrapping at its page's right margin (text-ops.js writingBox: margin 56, at least 200 wide)
            self.begin_text(pt[0], pt[1])
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
            var sst = TextStyle(self.sticky_family, self.sticky_weight, False, self.sticky_size)
            sst.exact = True
            self.words.begin("", sst, 240 - 2 * STICKY_PAD)
            self.changed = True
            return True
        if self.tool == "shape":  # (a rounded rectangle centred on the click, selected: text-ops.js newShape)
            self.finish(layer)
            var id = layer.add_rect(pt[0] - self.shape_w / 2, pt[1] - self.shape_h / 2, self.shape_w, self.shape_h, self.shape_fill, 0, 0, self.shape_radius)
            layer.select(id)
            self.tool = "select"
            self.changed = True
            return True
        if self.tool == "select":
            self.finish(layer)
            if (mods & 1) != 0 and layer.hit_test(pt[0], pt[1], 2) >= 0:  # (its press took the object alone)
                layer.selected = self.before_press.copy()
            var id = layer.click(pt[0], pt[1], (mods & 1) != 0)
            if id >= 0 and (mods & 1) == 0 and len(layer.selected) > 1:  # (a click, not a drag, on one of several: it alone)
                layer.select(id)
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
        if layer.read_only:  # (a document that couldn't be read: only the view moves)
            return False
        if self.in_words(layer, pt[0], pt[1]):  # (in the words being written: the caret)
            var b = self.words_box(layer)
            self.words.press(pt[0] - b[0], pt[1] - b[1], b[3], False)
            self.drag = T_WORDS
            return True
        if self.tool == "select" and len(layer.selected) == 1 and self.editing == -1:
            for k in range(0, len(self.handles), 3):
                if abs(sx - self.handles[k + 1]) <= 9 and abs(sy - self.handles[k + 2]) <= 9:
                    self.handle = Int(self.handles[k])
                    layer.begin_gesture(CH_ROTATE if self.handle == H_ROTATE else CH_RESIZE)
                    self.drag = T_HANDLE
                    self.moved = False
                    return True
        if self.tool == "select":
            var id = layer.hit_test(pt[0], pt[1], 2)
            if id < 0:  # (on the page: a marquee)
                self.before_press = layer.selected.copy()
                self.finish(layer)
                self.drag = T_BOX
                self.box_x0 = pt[0]
                self.box_y0 = pt[1]
                return True
            if id >= 0:
                self.finish(layer)
                self.before_press = layer.selected.copy()
                if not layer.is_selected(id):
                    layer.select(id)
                layer.begin_gesture(CH_MOVE)
                self.drag = T_MOVE
                self.moved = False
                return True
        elif self.tool == "eraser":
            self.finish(layer)
            layer.begin_gesture(CH_DELETE)
            self.drag = T_ERASE
            self.erased = erase_at(layer, pt[0], pt[1])
            return True
        elif self.tool == "pen" or self.tool == "highlight":
            self.finish(layer)
            self.wet = Stroke(self.pen_width, self.pen_color) if self.tool == "pen" else Stroke(self.marker_width, self.marker_color)
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
            if pt[0] != self.last_x or pt[1] != self.last_y:
                self.moved = True
            layer.move_by(pt[0] - self.last_x, pt[1] - self.last_y)
        elif self.drag == T_INK:
            self.wet.add(pt[0], pt[1], 0.5)
        elif self.drag == T_WORDS:
            var b = self.words_box(layer)
            self.words.drag(pt[0] - b[0], pt[1] - b[1], b[3])
        elif self.drag == T_HANDLE:
            self.moved = True
            if self.handle == H_ROTATE:
                layer.rotate_towards(pt[0], pt[1])
            else:
                layer.resize_handle(self.handle, pt[0], pt[1])
        elif self.drag == T_ERASE:
            # (along the way from the last point, half a radius at a time: a fast drag leaves no gaps)
            var dx = pt[0] - self.last_x
            var dy = pt[1] - self.last_y
            var n = max(Int(sqrt(dx * dx + dy * dy) / (ERASER_RADIUS / 2)), 1)
            var any = False
            for q in range(1, n + 1):
                if erase_at(layer, self.last_x + dx * Float64(q) / Float64(n), self.last_y + dy * Float64(q) / Float64(n)):
                    any = True
            self.erased = self.erased or any
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
        if kind == T_MOVE or kind == T_HANDLE:  # (a drag that ended where it began, or of something locked, changed nothing)
            var steps = layer.history.version
            layer.end_gesture()
            self.changed = self.changed or layer.history.version != steps
            return True
        if kind == T_WORDS:
            self.words.release()
            return True
        if kind == T_ERASE:
            layer.end_gesture()
            self.changed = self.changed or self.erased
            return True
        if kind == T_BOX:
            if abs(pt[0] - self.box_x0) > 2 or abs(pt[1] - self.box_y0) > 2:
                layer.marquee(self.box_x0, self.box_y0, pt[0], pt[1])
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
        if layer.read_only:
            return False
        if self.editing != -1:
            if name == "Escape":
                self.finish(layer)
                self.tool = "select"
                return True
            if (mods & 2) != 0 and name == "Enter":  # (Ctrl+Enter ends it, as Escape)
                self.finish(layer)
                self.tool = "select"
                return True
            var r = self.words.key(name, mods, now_ms())
            if r == 2:
                if self.editing >= 0:
                    layer.set_words(self.editing, self.words.text())
                self.changed = True  # (a new text's words too: saved as they are typed, layer.draft)
            return r != 0
        if (mods & 2) != 0 and (name == "y" or name == "Y"):
            layer.select_on_undo = True
            _ = layer.redo()
            self.changed = True
            return True
        if (mods & 6) == 2 and (name == "a" or name == "A") and self.tool != "hand":
            layer.select_all()
            return True
        if len(layer.selected) > 0 and self.tool != "hand":  # (the selection's keys: handleLeaferKey)
            if (mods & 6) == 0 and (name == "ArrowLeft" or name == "ArrowRight" or name == "ArrowUp" or name == "ArrowDown"):
                layer.nudge(-1 if name == "ArrowLeft" else (1 if name == "ArrowRight" else 0), -1 if name == "ArrowUp" else (1 if name == "ArrowDown" else 0), (mods & 1) != 0)
                self.changed = True
                return True
            if (mods & 6) == 2 and (name == "]" or name == "[" or name == "}" or name == "{"):
                self.order(layer, 1 if name == "]" or name == "}" else -1, (mods & 1) != 0 or name == "}" or name == "{")
                return True
            if (mods & 7) == 3 and (name == "l" or name == "L"):
                layer.lock_selection()
                self.changed = True
                return True
            if (mods & 6) == 0 and name == "Escape":
                layer.clear_selection()
                return True
        if (mods & 6) == 0 and name == "Escape" and self.tool != "select":
            # (drawing goes back to writing, any other tool to selecting)
            self.set_tool("text" if self.tool == "pen" or self.tool == "highlight" or self.tool == "eraser" else "select", layer, view, view_w, view_h, columns, rows)
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

    def order(mut self, mut layer: ObjectLayer, dir: Int, far: Bool):
        """The selection a place up or down the z order, or (far) to its end."""
        if dir > 0:
            if far:
                layer.bring_to_front()
            else:
                layer.bring_forward()
        elif far:
            layer.send_to_back()
        else:
            layer.send_backward()
        self.changed = True

    def edit_at(mut self, sx: Float64, sy: Float64, mut layer: ObjectLayer, mut view: DeskView, view_w: Float64, view_h: Float64) -> Bool:
        """A double click: the words of the text, sticky or shape under it are written on; on the empty page a new text
        begins there (the web's editOrCreateAt)."""
        if layer.read_only or self.tool == "hand":
            return False
        var pt = view.to_page(sx, sy)
        if self.in_words(layer, pt[0], pt[1]):
            var b = self.words_box(layer)
            self.words.select_word(pt[0] - b[0], pt[1] - b[1], b[3])
            return True
        var id = layer.hit_test(pt[0], pt[1], 2)
        if id < 0:
            self.tool = "text"
            return self.tap(sx, sy, layer, view, view_w, view_h)
        var q = layer.index(id)
        if q < 0 or (layer.objs[q].kind != TEXT and layer.objs[q].kind != STICKY) or layer.objs[q].locked:
            return False
        self.finish(layer)
        layer.select(id)
        self.begin_words(layer, id)
        return True

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
        if self.editing != -1:
            var b = self.words_box(layer)
            var tl = v.to_screen(b[0], b[1])
            var color = self.text_color
            if self.editing >= 0:
                var q = layer.index(self.editing)
                if q >= 0:
                    color = layer.objs[q].ink if layer.objs[q].kind == STICKY else layer.objs[q].color
            self.words.width = b[2]
            self.words.paint(p, tl[0], tl[1], b[3], b[4], v.scale, color, self.editing == -2)
            if self.editing == -2 or layer.index(self.editing) >= 0 and layer.objs[layer.index(self.editing)].kind == TEXT:  # (a faint line where the words wrap)
                p.rect(tl[0] + b[2] * v.scale, tl[1] - 3, 1, (b[3] * Float64(max(len(self.words.lines), 1))) * v.scale + 6, with_alpha(color, 0.22), 0)
        if self.drag == T_BOX:
            var a = v.to_screen(min(self.box_x0, self.last_x), min(self.box_y0, self.last_y))
            var w = abs(self.last_x - self.box_x0) * v.scale
            var h = abs(self.last_y - self.box_y0) * v.scale
            if w > 1 or h > 1:
                p.rect(a[0], a[1], w, h, with_alpha(SELECT_BLUE, 0.10), 0)
                p.rect(a[0], a[1], w, 1, SELECT_BLUE, 0)
                p.rect(a[0], a[1] + h - 1, w, 1, SELECT_BLUE, 0)
                p.rect(a[0], a[1], 1, h, SELECT_BLUE, 0)
                p.rect(a[0] + w - 1, a[1], 1, h, SELECT_BLUE, 0)
        if self.drag == T_INK and len(self.wet.xs) > 1:
            var rel = List[Float64]()
            var a = v.to_screen(self.wet.xs[0], self.wet.ys[0])
            for i in range(len(self.wet.xs)):
                var q = v.to_screen(self.wet.xs[i], self.wet.ys[i])
                rel.append(q[0] - a[0])
                rel.append(q[1] - a[1])
            polyline(p, a[0], a[1], rel, self.wet.width * v.scale, self.wet.color)
        self.handles.clear()
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
                self.handles.append(Float64([0, 2, 6, 4][c]))
                self.handles.append(tl[0] + (w if c % 2 == 1 else 0.0))
                self.handles.append(tl[1] + (h if c >= 2 else 0.0))
            self.handles.append(Float64(H_ROTATE))
            self.handles.append(tl[0] + w / 2)
            self.handles.append(tl[1] - 28)
            p.circle(tl[0] + w / 2, tl[1] - 28, 6.5, SELECT_BLUE)
            p.circle(tl[0] + w / 2, tl[1] - 28, 5, 0xFFFFFFFF)
