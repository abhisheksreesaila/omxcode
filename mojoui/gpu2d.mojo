# The GPU 2D renderer's core (goal 75 M1): a Scene (mojoui.scene, the display list) becomes draw runs a GPU backend
# replays with a few fixed pipelines (Zed GPUI style, docs/research/rendering.md). Backend-free: no GL, no Metal, no
# host code. The GL backend (M2) and the Metal backend (M3) upload what this builds; execute_cpu draws the same runs
# into a Surface with the math a shader does: the reference a GPU readback is compared to, and the fallback.
#
#   var atlas = GlyphAtlas(font)                     # once: every baked face in one R8 texture
#   var frame = build_batches(scene, atlas, font)    # each frame (or fill_batches(frame, ...) to keep the memory)
#   for layer in frame.layers: for run in its runs: bind run.pipe, draw run.count instances from run.first
#   execute_cpu(frame, atlas, surface)               # the same picture on the CPU
#
# Coordinates in the instance lists are the layer's own units (what the drawing code passed); the backend applies the
# layer's transform: a point (x, y) lands at (x·k + dx, y·k + dy) in pixels. Clip rects are in the layer's units too.
# Colours are 4 floats, straight alpha, 0–1. Blending: BLEND_OVER = src·a + dst·(1 − a) on RGB, the destination's
# alpha kept (GL: glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ZERO, ONE)), as mojoui.draw.blend does;
# BLEND_REPLACE writes the colour as it is (blending off): fills and images, as Surface.fill and scene.blit do.
#
# Pipelines and their instances (flat Float32 lists, a fixed number of floats each; groups of 4 are one vec4
# attribute):
#
# QUAD (QUAD_FLOATS = 16): rects, rounded rects, circles, fills, lines.
#   0–3  a, b, c, d     SHAPE_BOX: x, y, w, h.   SHAPE_CAPSULE: x0, y0, x1, y1 (the segment's ends)
#   4    radius         BOX: corner radius (clamped to min(w, h)/2 in the shader).   CAPSULE: half the width
#   5    shape          SHAPE_BOX (0) or SHAPE_CAPSULE (1)
#   6    hole           (D-7973) BOX: > 0, pixels inside the box shrunk by it may be skipped (an opaque cover comes)
#   7    (0)            reserved
#   8–11 r, g, b, a
#   12–15 clip x0, y0, x1, y1 (±NO_CLIP: none)
#   Coverage (pixels, after the transform): BOX = min(distance to the nearest edge + 0.5, in a corner r − distance to
#   the corner's centre + 0.5) clamped 0–1, i.e. a signed-distance rounded box with a 1-px ramp (draw.rect's math).
#   CAPSULE = half width + 0.5 − distance to the segment: lines get round ends; a circle is a capsule whose ends are
#   its centre (radius = half width), exactly draw.circle's and draw.line's math. The vertex shader covers the box (or
#   the segment's rotated rectangle, extended by the half width at both ends) padded by 1 pixel.
#   OP_FILL: a BOX covering the whole canvas (in the layer's units, so the transform lands it on the canvas), no
#   clip, in its own BLEND_REPLACE run.
#
# GLYPH (GLYPH_FLOATS = 20): one per glyph that has pixels (a space has none: it only moves the pen, no instance).
#   0–3  x, y, w, h       the glyph's box before slanting (pen + left·s, baseline + top·s, w·s, h·s; s = size / face size)
#   4–7  u0, v0, u1, v1   its rect in the combined atlas, in texels (divide by GlyphAtlas.width/height for 0–1 uvs)
#   8–11 r, g, b, a
#   12   slant            each pixel row moves right by slant × its height above the baseline (row centre)
#   13   baseline         in the layer's units
#   14–15 (0, 0)          reserved
#   16–19 clip x0, y0, x1, y1
#   Sampling (Face.draw's): texel = (pixel − (x + slant·(baseline − row centre), y)) / s inside [0, w)×[0, h) of the
#   glyph, bilinear; 2×2 supersamples per pixel when s·k < 0.75 (s·k = w·k / (u1 − u0)); coverage × a; ≤ 0.003 drawn
#   nothing. Face choice and alignment follow Font.draw (Font.pick at the size on screen, size·k).
#
# IMAGE (IMAGE_FLOATS = 12): a picture scaled into a rect, BLEND_REPLACE (see-through ones BLEND_OVER), filtered as
# mojoui.bitmap says (goal 81).
#   0–3  x, y, w, h
#   4    which          index into Frame2D.pics (the scene's pictures: Bitmap handles)
#   5–6  pw, ph
#   7    0 filtered, 1 nearest
#   8–11 clip x0, y0, x1, y1
#   A pixel whose centre is in the rect shows the picture at ((centre − x) / w, …); unscaled, or nearest: texel floor(that · pw).
#
# POLY (POLY_FLOATS = 16): filled polygons, non-zero winding, by stencil and cover.
#   0    first fan vertex   into Frame2D.fan (x, y pairs; n − 2 triangles zig-zagging in from both ends of the
#                           outline, whose signed windings sum to the polygon's, as a fan from p0 would)
#   1    fan vertices       3 · (n − 2)
#   2    first point        into Frame2D.points (the polygon's points, x, y pairs)
#   3    points             n
#   4–7  r, g, b, a
#   8–11 bounds x0, y0, x1, y1 (the cover quad)
#   12–15 clip x0, y0, x1, y1
#   GPU: draw the fan into the stencil (front faces increment, back faces decrement, wrapping), then the bounds quad
#   where stencil ≠ 0 (and reset it); MSAA gives the edge. CPU: the same non-zero rule by scan lines, POLY_SUB lines per
#   pixel row, exact spans along each (draw.polygon's math).
#
# Clips: OP_CLIP / OP_UNCLIP never become draws: each instance carries the innermost clip (nested clips intersect, in
# pixels, as Scene.raster does, then mapped back into the instance's layer). A pixel is drawn only when its centre is
# inside [x0, x1) × [y0, y1). Runs: within a layer, consecutive ops of one pipeline (and blend) are one run; a
# different kind in between starts a new run, so painter's order is kept exactly.

from std.math import sqrt, ceil, floor
from mojoui.canvas import Surface
from mojoui.draw import blend
from mojoui.text import Font, Face, LEFT, CENTRE, RIGHT
from mojoui.shadow import shadow_alpha, shadow_reach, shadow_columns, shadow_row, shadow_at
from mojoui.fonttext import engine as font_engine, shape as ft_shape, run_in as ft_run_in, run_x, GlyphImage, TextStyle, FontEngine
from mojoui.shared import get_shared, put_shared
from std.memory import Pointer
from std.memory.alloc import alloc, Layout
from std.collections import Dict
from std.atomic import Atomic
from std.sys.info import num_logical_cores
from mojoui import libc
from mojoui.scene import Scene, OP_RECT, OP_CIRCLE, OP_LINE, OP_TEXT, OP_FILL, OP_CLIP, OP_UNCLIP, OP_IMAGE, OP_POLY, OP_RUN, OP_STROKE, OP_SHADOW
from mojoui.bitmap import Bitmap, Sampler, make_bitmap, ready

comptime PIPE_QUAD = 0
comptime PIPE_GLYPH = 1
comptime PIPE_IMAGE = 2
comptime PIPE_POLY = 3

comptime QUAD_FLOATS = 16
comptime SHAPE_SHADOW = 2  # (goal 80) a rounded box's Gaussian shadow: float 7 holds sigma (mojoui.shadow)
comptime GLYPH_FLOATS = 20
comptime IMAGE_FLOATS = 12
comptime POLY_FLOATS = 16

comptime SHAPE_BOX = 0
comptime SHAPE_CAPSULE = 1

comptime BLEND_REPLACE = 0
comptime BLEND_OVER = 1

comptime SLOT_KEYS = 1 << 20  # glyph keys kept in a list (GlyphPages.slot_of); others in a hash
comptime NO_CLIP = 1.0e30  # a clip edge this far out (or further) means no clip on that side
comptime POLY_SUB = 4  # scan lines per pixel row for polygons (draw.polygon's)
comptime FACES = 5  # Font.pick's faces: 0 regular, 1 medium, 2 display, 3 mono, 4 mono bold


comptime DYN_ROWS = 2048  # rows of the atlas kept for mojoui.fonttext's glyphs (goal 79), packed as they're first drawn
comptime SLOT_GLYPH_PAGES = 232  # mojoui.shared slot: the process's GlyphPages


struct GlyphPages(Movable):
    """fonttext's glyphs (coverage, rasterized at device px by the platform's engine) packed in shelves into the atlas's
    dynamic rows, once per (face, instance, glyph, device size, subpixel x): keyed by fonttext's own image index. One per
    process, shared by every canvas; a backend uploads the rows written since the version it last synced (rows_since,
    goal 80: one new glyph sends its rows, not every row in use; D-7910 sent rows [0, used) on every change)."""
    var width: Int
    var bytes: List[UInt8]
    var slot_of: List[Int32]  # engine image index → slot (-1: not placed): image indices are dense, so a list, not a hash (goal 80)
    var fonts: Int  # the font engine's address, once known (a registry lookup costs ~0.5 µs, mostly getpid)
    var slot_other: Dict[Int, Int]  # any other key (negative, or past SLOT_KEYS)
    var sx: List[Int]
    var sy: List[Int]
    var shelf_x: Int
    var shelf_y: Int
    var shelf_h: Int
    var used: Int  # rows holding glyphs
    var version: Int
    var resets: Int
    var row_v: List[Int]  # (goal 80) the version that last wrote each row
    var straight_of: Dict[Int, Int]  # a colour glyph (engine image × 256 + the run's alpha) → its straight-alpha pixels
    var straight_px: List[Bitmap]

    def __init__(out self, width: Int):
        self.width = width
        self.bytes = List[UInt8](length=width * DYN_ROWS, fill=0)
        self.slot_of = List[Int32]()
        self.slot_other = Dict[Int, Int]()
        self.fonts = 0
        self.sx = List[Int]()
        self.sy = List[Int]()
        self.shelf_x = 1
        self.shelf_y = 1
        self.shelf_h = 0
        self.used = 0
        self.version = 0
        self.resets = 0
        self.row_v = List[Int](length=DYN_ROWS, fill=0)
        self.straight_of = Dict[Int, Int]()
        self.straight_px = List[Bitmap]()

    def straight(mut self, image: Int, alpha: Int, rgba: List[UInt32], w: Int, h: Int) -> Bitmap:
        """A colour glyph's premultiplied pixels as straight alpha times the run's alpha, converted once and kept
        (bounded: 2,048 kept, then started again), not on every frame (D-7932)."""
        var key = image * 256 + alpha
        var at = self.straight_of.get(key, -1)
        if at < 0:
            if len(self.straight_px) >= 2048:
                self.straight_of = Dict[Int, Int]()
                self.straight_px.clear()
            var pix = List[UInt32](capacity=len(rgba))
            for q in rgba:
                var aa = Int((q >> 24) & 0xFF)
                if aa == 0:
                    pix.append(0)
                    continue
                var rr = min(255, Int(q & 0xFF) * 255 // aa)
                var gg = min(255, Int((q >> 8) & 0xFF) * 255 // aa)
                var bb = min(255, Int((q >> 16) & 0xFF) * 255 // aa)
                pix.append(UInt32(rr) | (UInt32(gg) << 8) | (UInt32(bb) << 16) | (UInt32(aa * alpha // 255) << 24))
            self.straight_px.append(make_bitmap(pix^, w, h))
            at = len(self.straight_px) - 1
            self.straight_of[key] = at
        return self.straight_px[at].copy()

    def place(mut self, key: Int, img: GlyphImage) -> Int:
        """The glyph's slot (packing it on first use, a column and a row of zeros around it)."""
        var dense = key >= 0 and key < SLOT_KEYS
        if dense:
            if key < len(self.slot_of):
                var have = Int(self.slot_of[key])
                if have >= 0:
                    return have
        else:
            var have = self.slot_other.get(key, -1)
            if have >= 0:
                return have
        var w = img.w
        var h = img.h
        if self.shelf_x + w + 1 > self.width:
            self.shelf_y += self.shelf_h + 1
            self.shelf_x = 1
            self.shelf_h = 0
        if self.shelf_y + h + 1 > DYN_ROWS:  # full: start again (glyphs pack again as they're drawn)
            for i in range(len(self.bytes)):
                self.bytes[i] = 0
            for i in range(len(self.slot_of)):
                self.slot_of[i] = -1
            self.slot_other = Dict[Int, Int]()
            self.sx.clear()
            self.sy.clear()
            self.shelf_x = 1
            self.shelf_y = 1
            self.shelf_h = 0
            self.resets += 1
            for r in range(DYN_ROWS):  # (every row was cleared: all go up again)
                self.row_v[r] = self.version + 1
        var x = self.shelf_x
        var y = self.shelf_y
        for yy in range(h):
            for xx in range(w):
                self.bytes[(y + yy) * self.width + x + xx] = img.cov[yy * w + xx]
        self.shelf_x += w + 1
        self.shelf_h = max(self.shelf_h, h)
        self.used = max(self.used, y + h + 1)
        self.sx.append(x)
        self.sy.append(y)
        if dense:
            while len(self.slot_of) <= key:
                self.slot_of.append(-1)
            self.slot_of[key] = Int32(len(self.sx) - 1)
        else:
            self.slot_other[key] = len(self.sx) - 1
        self.version += 1
        for r in range(y, min(y + h + 1, DYN_ROWS)):
            self.row_v[r] = self.version
        return len(self.sx) - 1

    def rows_since(self, v: Int) -> Tuple[Int, Int]:
        """(goal 80) The rows [lo, hi) written after version v ((0, 0): none): what a backend that synced at v uploads."""
        var lo = DYN_ROWS
        var hi = 0
        for r in range(DYN_ROWS):
            if self.row_v[r] > v:
                lo = min(lo, r)
                hi = r + 1
        return (lo, hi) if hi > lo else (0, 0)


@fieldwise_init
struct LayerTraits(ImplicitlyCopyable, Movable):
    """What a kept layer's batches depend on (shared by the GL and Metal renderers, D-7930): `fixed`, not on its
    transform (no clip, fill or image); `zoom_bound`, on its zoom (text drawn from glyphs rasterized at size × zoom:
    OP_TEXT and fonttext's OP_RUN; a pan reuses it, a zoom rebuilds it); `runs`, it places fonttext glyphs in
    GlyphPages (a reset of the pages invalidates it); `open`, clips left open after it."""
    var fixed: Bool
    var zoom_bound: Bool
    var runs: Bool
    var open: Int


def layer_traits(scene: Scene, i: Int, open_before: Int) -> LayerTraits:
    var span = scene.layer_range(i)
    var open = open_before
    var t = LayerTraits(open_before == 0, False, False, 0)
    for op in range(span[0], span[1]):
        var kind = Int(scene.kinds[op])
        if kind == OP_TEXT:
            t.zoom_bound = True
        elif kind == OP_RUN:
            t.zoom_bound = True
            t.runs = True
        elif kind == OP_FILL or kind == OP_IMAGE:
            t.fixed = False
        elif kind == OP_CLIP:
            t.fixed = False
            open += 1
        elif kind == OP_UNCLIP:
            t.fixed = False
            open = max(open - 1, 0)
    t.open = open
    return t


def glyph_pages(width: Int) -> Pointer[GlyphPages, MutUntrackedOrigin]:
    var have = get_shared(SLOT_GLYPH_PAGES)
    if have != 0:
        return Pointer[GlyphPages, MutUntrackedOrigin](unsafe_from_address=have)
    var a = alloc(Layout[GlyphPages].single())
    var p = a^.unsafe_leak()
    p.unsafe_write(GlyphPages(width))
    put_shared(SLOT_GLYPH_PAGES, Int(p))
    return Pointer[GlyphPages, MutUntrackedOrigin](unsafe_from_address=Int(p))


def _rows(face: Face) -> Int:
    return (len(face.atlas) + face.width - 1) // face.width


struct GlyphAtlas(Movable):
    """Every baked face's R8 coverage atlas in one R8 texture (width × height bytes, rows with no gaps), so a backend
    uploads one texture. Faces are stacked top to bottom in Font.pick's order, with a row of zeros above, between and
    below them and a column of zeros at each side: bilinear sampling (and a GPU's CLAMP_TO_EDGE) reads zeros past a
    face's edges, as Face.coverage does."""

    var pages_at: Int  # the process's GlyphPages (goal 80: looked up once)
    var width: Int
    var height: Int
    var bytes: List[UInt8]
    var face_x: List[Int]  # where face f's texel (0, 0) is
    var face_y: List[Int]
    var dyn_y0: Int  # the first of the DYN_ROWS rows kept for fonttext's glyphs (GlyphPages)

    def __init__(out self, font: Font):
        var w = max(max(max(font.regular.width, font.medium.width), max(font.display.width, font.mono.width)), font.mono_bold.width)
        var rows = [_rows(font.regular), _rows(font.medium), _rows(font.display), _rows(font.mono), _rows(font.mono_bold)]
        var ys = List[Int]()
        var y = 1
        for f in range(FACES):
            ys.append(y)
            y += rows[f] + 1
        self.width = w + 2
        self.pages_at = Int(glyph_pages(w + 2))
        self.dyn_y0 = y
        self.height = y + DYN_ROWS
        self.bytes = List[UInt8](length=self.width * self.height, fill=0)
        self.face_x = [1, 1, 1, 1, 1]
        self.face_y = ys^
        self._put(font.regular, 0)
        self._put(font.medium, 1)
        self._put(font.display, 2)
        self._put(font.mono, 3)
        self._put(font.mono_bold, 4)

    def _put(mut self, face: Face, f: Int):
        var ox = self.face_x[f]
        var oy = self.face_y[f]
        for i in range(len(face.atlas)):
            var y = i // face.width
            var x = i - y * face.width
            self.bytes[(oy + y) * self.width + ox + x] = face.atlas[i]

    def pages(self) -> Pointer[GlyphPages, MutUntrackedOrigin]:
        """The process's GlyphPages (its address kept when the atlas was made)."""
        return Pointer[GlyphPages, MutUntrackedOrigin](unsafe_from_address=self.pages_at)

    def at(self, x: Int, y: Int) -> Float64:
        if x < 0 or y < 0 or x >= self.width or y >= self.height:
            return 0
        if y >= self.dyn_y0:
            var pg = self.pages()
            return Float64(Int(pg[].bytes[(y - self.dyn_y0) * self.width + x])) / 255.0
        return Float64(Int(self.bytes[y * self.width + x])) / 255.0

    @always_inline
    def at_in(self, x: Int, y: Int, own: Pointer[UInt8, MutUntrackedOrigin], dyn: Pointer[UInt8, MutUntrackedOrigin]) -> Float64:
        """at() with both byte stores' addresses in hand (goal 80: at() looked GlyphPages up in the process's registry
        for every texel, ~0.4 µs: text on the CPU took half a second a frame)."""
        if x < 0 or y < 0 or x >= self.width or y >= self.height:
            return 0
        if y >= self.dyn_y0:
            return Float64(Int(dyn.unsafe_offset((y - self.dyn_y0) * self.width + x)[])) / 255.0
        return Float64(Int(own.unsafe_offset(y * self.width + x)[])) / 255.0

    @always_inline
    def coverage_in(self, x: Float64, y: Float64, own: Pointer[UInt8, MutUntrackedOrigin], dyn: Pointer[UInt8, MutUntrackedOrigin]) -> Float64:
        var x0 = Int(floor(x - 0.5))
        var y0 = Int(floor(y - 0.5))
        var fx = x - 0.5 - Float64(x0)
        var fy = y - 0.5 - Float64(y0)
        var a = self.at_in(x0, y0, own, dyn)
        var b = self.at_in(x0 + 1, y0, own, dyn)
        var c = self.at_in(x0, y0 + 1, own, dyn)
        var d = self.at_in(x0 + 1, y0 + 1, own, dyn)
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy

    def coverage(self, x: Float64, y: Float64) -> Float64:
        """Bilinear coverage (0–1) at a point in texels (texel centres at +0.5), as a GPU's linear filter."""
        var x0 = Int(floor(x - 0.5))
        var y0 = Int(floor(y - 0.5))
        var fx = x - 0.5 - Float64(x0)
        var fy = y - 0.5 - Float64(y0)
        var a = self.at(x0, y0)
        var b = self.at(x0 + 1, y0)
        var c = self.at(x0, y0 + 1)
        var d = self.at(x0 + 1, y0 + 1)
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


@fieldwise_init
struct Run(Copyable, Movable, ImplicitlyCopyable):
    """One draw: `count` instances of pipeline `pipe` from instance `first` of its list, blended by `blend`."""

    var pipe: Int
    var first: Int
    var count: Int
    var blend: Int


@fieldwise_init
struct Layer2D(Copyable, Movable):
    """A Scene layer: its key, version (-1: unknown) and transform as the Scene stores them, and its runs
    (Frame2D.runs[first_run : first_run + runs]), in paint order."""

    var key: String
    var version: Int
    var dx: Float64
    var dy: Float64
    var k: Float64
    var first_run: Int
    var runs: Int


struct Frame2D(Movable):
    """A Scene as GPU work: layers of runs, and one flat instance list per pipeline (field order at the top)."""

    var width: Int
    var height: Int
    var scale: Float64
    var layers: List[Layer2D]
    var runs: List[Run]
    var quads: List[Float32]
    var glyphs: List[Float32]
    var images: List[Float32]
    var polys: List[Float32]
    var points: List[Float32]  # POLY's points, x, y pairs
    var fan: List[Float32]  # POLY's stencil fans as triangles, x, y per vertex (ready to upload)
    var pics: List[Bitmap]  # IMAGE's pictures (the scene's images, shared, and colour glyphs)

    def __init__(out self):
        self.width = 0
        self.height = 0
        self.scale = 1
        self.layers = List[Layer2D]()
        self.runs = List[Run](capacity=256)
        self.quads = List[Float32](capacity=4096 * QUAD_FLOATS)
        self.glyphs = List[Float32](capacity=8192 * GLYPH_FLOATS)
        self.images = List[Float32]()
        self.polys = List[Float32](capacity=1024 * POLY_FLOATS)
        self.points = List[Float32](capacity=8192)
        self.fan = List[Float32](capacity=24576)
        self.pics = List[Bitmap]()

    def clear(mut self):
        """Empty, keeping the memory."""
        self.layers.clear()
        self.runs.clear()
        self.quads.clear()
        self.glyphs.clear()
        self.images.clear()
        self.polys.clear()
        self.points.clear()
        self.fan.clear()
        self.pics.clear()

    def instances(self, pipe: Int) -> Int:
        """How many instances pipeline `pipe` has in the frame."""
        if pipe == PIPE_QUAD:
            return len(self.quads) // QUAD_FLOATS
        if pipe == PIPE_GLYPH:
            return len(self.glyphs) // GLYPH_FLOATS
        if pipe == PIPE_IMAGE:
            return len(self.images) // IMAGE_FLOATS
        return len(self.polys) // POLY_FLOATS


@always_inline
def _grow(mut out: List[Float32], n: Int) -> Pointer[Float32, MutUntrackedOrigin]:
    """n more floats on the list, uninitialized; the address of the first (goal 80: an instance written at once, not by
    16–20 appends, each checking the list's capacity). Grown by half again, so the next ones fit."""
    var at = len(out)
    if at + n > out.capacity():
        out.reserve(at + n + (at + n) // 2)
    out.resize(unsafe_uninit_length=at + n)
    return Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(out.unsafe_ptr()) + 4 * at)


@always_inline
def _put_color(p: Pointer[Float32, MutUntrackedOrigin], at: Int, c: UInt32):
    p.unsafe_offset(at)[] = Float32(Int(c & 0xFF)) / 255.0
    p.unsafe_offset(at + 1)[] = Float32(Int((c >> 8) & 0xFF)) / 255.0
    p.unsafe_offset(at + 2)[] = Float32(Int((c >> 16) & 0xFF)) / 255.0
    p.unsafe_offset(at + 3)[] = Float32(Int((c >> 24) & 0xFF)) / 255.0


@always_inline
def _put_clip(p: Pointer[Float32, MutUntrackedOrigin], at: Int, c0: Float64, c1: Float64, c2: Float64, c3: Float64):
    p.unsafe_offset(at)[] = Float32(c0)
    p.unsafe_offset(at + 1)[] = Float32(c1)
    p.unsafe_offset(at + 2)[] = Float32(c2)
    p.unsafe_offset(at + 3)[] = Float32(c3)


def _color(mut out: List[Float32], c: UInt32):
    out.append(Float32(Int(c & 0xFF)) / 255.0)
    out.append(Float32(Int((c >> 8) & 0xFF)) / 255.0)
    out.append(Float32(Int((c >> 16) & 0xFF)) / 255.0)
    out.append(Float32(Int((c >> 24) & 0xFF)) / 255.0)


def _clip4(mut out: List[Float32], c0: Float64, c1: Float64, c2: Float64, c3: Float64):
    out.append(Float32(c0))
    out.append(Float32(c1))
    out.append(Float32(c2))
    out.append(Float32(c3))


def _quad(mut out: List[Float32], a: Float64, b: Float64, c: Float64, d: Float64, radius: Float64, shape: Int, color: UInt32,
          c0: Float64, c1: Float64, c2: Float64, c3: Float64, hole: Float64 = 0, sigma: Float64 = 0):
    var p = _grow(out, QUAD_FLOATS)
    p[] = Float32(a)
    p.unsafe_offset(1)[] = Float32(b)
    p.unsafe_offset(2)[] = Float32(c)
    p.unsafe_offset(3)[] = Float32(d)
    p.unsafe_offset(4)[] = Float32(radius)
    p.unsafe_offset(5)[] = Float32(shape)
    p.unsafe_offset(6)[] = Float32(hole)  # (D-7973: the middle a box may leave out, its units)
    p.unsafe_offset(7)[] = Float32(sigma)  # (goal 80: a shadow's sigma, its units)
    _put_color(p, 8, color)
    _put_clip(p, 12, c0, c1, c2, c3)


def _segment_meets(x0: Float64, y0: Float64, x1: Float64, y1: Float64, hw: Float64, r0: Float64, r1: Float64, r2: Float64, r3: Float64) -> Bool:
    """Whether a line of half width hw may have pixels in the rect: its box meets it, and the rect's corners aren't all
    further than hw on one side of it (a diagonal's box is mostly empty)."""
    if max(x0, x1) + hw < r0 or min(x0, x1) - hw > r2 or max(y0, y1) + hw < r1 or min(y0, y1) - hw > r3:
        return False
    var dx = x1 - x0
    var dy = y1 - y0
    var l = sqrt(dx * dx + dy * dy)
    if l < 1e-9:
        return True
    var nx = -dy / l
    var ny = dx / l
    var mid = (0.5 * (r0 + r2) - x0) * nx + (0.5 * (r1 + r3) - y0) * ny
    var half = 0.5 * ((r2 - r0) * abs(nx) + (r3 - r1) * abs(ny))
    return abs(mid) <= half + hw


def _glyphs(mut out: List[Float32], face: Face, ox: Int, oy: Int, text: String, x: Float64, baseline: Float64, size: Float64,
            color: UInt32, slant: Float64, c0: Float64, c1: Float64, c2: Float64, c3: Float64,
            rx0: Float64 = -NO_CLIP, ry0: Float64 = -NO_CLIP, rx1: Float64 = NO_CLIP, ry1: Float64 = NO_CLIP, pad: Float64 = 0):
    """One GLYPH instance per glyph with pixels, the pen moving as Face.draw's. Glyphs whose box (widened by the slant
    and `pad`) misses the region rx0..ry1 make none (goal 80: what a clip hides is never sent)."""
    var s = size / face.size
    var pen = x
    for ch in text.codepoints():
        var gi = face.find(Int(ch.to_u32()))
        if gi < 0:
            continue
        ref g = face.glyphs[gi]
        var gx0 = pen + Float64(g.left) * s
        var gy0 = baseline + Float64(g.top) * s
        # (a slanted row moves by slant × its height above the baseline: the box's sideways reach)
        var lean = abs(slant) * max(abs(baseline - gy0), abs(gy0 + Float64(g.h) * s - baseline))
        if g.w > 0 and g.h > 0 and (gx0 + Float64(g.w) * s + lean + pad < rx0 or gx0 - lean - pad > rx1
                                    or gy0 + Float64(g.h) * s + pad < ry0 or gy0 - pad > ry1):
            pen += g.advance * s
            continue
        if g.w > 0 and g.h > 0:
            out.append(Float32(pen + Float64(g.left) * s))
            out.append(Float32(baseline + Float64(g.top) * s))
            out.append(Float32(Float64(g.w) * s))
            out.append(Float32(Float64(g.h) * s))
            out.append(Float32(ox + g.x))
            out.append(Float32(oy + g.y))
            out.append(Float32(ox + g.x + g.w))
            out.append(Float32(oy + g.y + g.h))
            _color(out, color)
            out.append(Float32(slant))
            out.append(Float32(baseline))
            out.append(0)
            out.append(0)
            _clip4(out, c0, c1, c2, c3)
        pen += g.advance * s


def opening_fill(f: Frame2D, li: Int, tx: Float64, ty: Float64, tk: Float64, w: Int, h: Int) -> Int:
    """(goal 80) The quad that fills the whole w × h canvas before anything else in layer li (a Scene's opening fill, at the
    layer's transform this frame): its index in f.quads, or -1. A backend clears to its colour instead of drawing it."""
    if li >= len(f.layers) or f.layers[li].runs == 0:
        return -1
    var run = f.runs[f.layers[li].first_run]
    if run.pipe != PIPE_QUAD or run.blend != BLEND_REPLACE or run.count <= 0:
        return -1
    var q = run.first * QUAD_FLOATS
    if Int(f.quads[q + 5]) != SHAPE_BOX or f.quads[q + 4] != 0 or f.quads[q + 6] != 0:
        return -1
    if f.quads[q + 12] > -NO_CLIP / 2 or f.quads[q + 13] > -NO_CLIP / 2 or f.quads[q + 14] < NO_CLIP / 2 or f.quads[q + 15] < NO_CLIP / 2:
        return -1
    var x0 = Float64(f.quads[q]) * tk + tx
    var y0 = Float64(f.quads[q + 1]) * tk + ty
    var x1 = x0 + Float64(f.quads[q + 2]) * tk
    var y1 = y0 + Float64(f.quads[q + 3]) * tk
    if x0 > 0.01 or y0 > 0.01 or x1 < Float64(w) - 0.01 or y1 < Float64(h) - 0.01:
        return -1
    return run.first


def build_batches(scene: Scene, atlas: GlyphAtlas, font: Font, cull: Bool = True) -> Frame2D:
    """The scene as GPU work (see the top of this file)."""
    var f = Frame2D()
    fill_batches(f, scene, atlas, font, cull)
    return f^


def fill_batches(mut f: Frame2D, scene: Scene, atlas: GlyphAtlas, font: Font, cull: Bool = True):
    """build_batches into an existing frame, reusing its memory (a host keeps one Frame2D). When GlyphPages fill and
    start again while it builds, the glyphs placed before that are gone: the frame is built once more (D-7930)."""
    var pg = atlas.pages()
    var r0 = pg[].resets
    fill_layers(f, scene, atlas, font, 0, scene.layers(), cull=cull)
    if pg[].resets != r0:
        var r1 = pg[].resets
        fill_layers(f, scene, atlas, font, 0, scene.layers(), cull=cull)
        if pg[].resets != r1:
            print("GLYPHPAGES: one frame needs more glyphs than the pages hold (" + String(DYN_ROWS) + " rows)", flush=True)


def _clip_op(mut clips: List[Float64], scene: Scene, op: Int, tx: Float64, ty: Float64, tk: Float64):
    """OP_CLIP (push, intersected with the clip it's inside, in pixels) or OP_UNCLIP (pop) on the clip stack."""
    var base = op * 6
    if Int(scene.kinds[op]) == OP_CLIP:
        var x0 = Float64(scene.nums[base]) * tk + tx
        var y0 = Float64(scene.nums[base + 1]) * tk + ty
        var x1 = x0 + Float64(scene.nums[base + 2]) * tk
        var y1 = y0 + Float64(scene.nums[base + 3]) * tk
        var n = len(clips)
        if n > 0:
            x0 = max(x0, clips[n - 4])
            y0 = max(y0, clips[n - 3])
            x1 = min(x1, clips[n - 2])
            y1 = min(y1, clips[n - 1])
        clips.append(x0)
        clips.append(y0)
        clips.append(x1)
        clips.append(y1)
    elif len(clips) > 0:
        for _ in range(4):
            _ = clips.pop()


def _zigzag_start(path: List[Float32], p0: Int, n: Int) -> Int:
    """Where a polygon's zig-zag triangles start (fill_layers): the index k whose chords k+j ↔ k−1−j, at j = n/8, n/4
    and 3n/8, are shortest (squared lengths summed), searched every n/16 points and then around the best. 0 for small
    polygons (any start covers them about once)."""
    if n < 16:
        return 0
    var pts = path.unsafe_ptr() + p0
    var j1 = n // 8
    var j2 = n // 4
    var j3 = 3 * n // 8

    @always_inline
    @parameter
    def chord(k: Int, j: Int) -> Float32:
        var a = k + j
        if a >= n:
            a -= n
        var b = k - 1 - j
        if b < 0:
            b += n
        var dx = pts[2 * a] - pts[2 * b]
        var dy = pts[2 * a + 1] - pts[2 * b + 1]
        return dx * dx + dy * dy

    var stride = max(n // 16, 1)
    var best = 0
    var best_s: Float32 = 3e38
    var k = 0
    while k < n:
        var sk = chord(k, j1) + chord(k, j2) + chord(k, j3)
        if sk < best_s:
            best_s = sk
            best = k
        k += stride
    var c = best
    for d in range(1 - stride, stride):
        var kk = c + d
        if kk < 0:
            kk += n
        elif kk >= n:
            kk -= n
        var sk = chord(kk, j1) + chord(kk, j2) + chord(kk, j3)
        if sk < best_s:
            best_s = sk
            best = kk
    return best


@always_inline
def _style_is[O: Origin](st: TextStyle, family: Pointer[UInt8, O], n: Int, size: Float64, weight: Float64, flags: Float64, spacing: Float64) -> Bool:
    """Whether an OP_RUN's numbers (Scene.run_style's fields) and family are the style in hand."""
    if st.size != size or Float64(st.weight) != weight or st.letter_spacing != spacing:
        return False
    if st.italic != ((Int(flags) & 1) == 1) or st.exact != ((Int(flags) & 2) == 2):
        return False
    var fb = st.family.as_bytes()
    if len(fb) != n:
        return False
    for i in range(n):
        if fb[i] != family.unsafe_offset(i)[]:
            return False
    return True


@always_inline
def _box_meets(x0: Float64, y0: Float64, x1: Float64, y1: Float64, rx0: Float64, ry0: Float64, rx1: Float64, ry1: Float64) -> Bool:
    return x1 >= rx0 and x0 <= rx1 and y1 >= ry0 and y0 <= ry1


def _path_meets(scene: Scene, first: Int, n: Int, grow: Float64, rx0: Float64, ry0: Float64, rx1: Float64, ry1: Float64) -> Bool:
    if n <= 0:
        return False
    var p0 = first * 2
    var bx0 = Float64(scene.path[p0])
    var by0 = Float64(scene.path[p0 + 1])
    var bx1 = bx0
    var by1 = by0
    for z in range(1, n):
        var x = Float64(scene.path[p0 + 2 * z])
        var y = Float64(scene.path[p0 + 2 * z + 1])
        bx0 = min(bx0, x)
        by0 = min(by0, y)
        bx1 = max(bx1, x)
        by1 = max(by1, y)
    return _box_meets(bx0 - grow, by0 - grow, bx1 + grow, by1 + grow, rx0, ry0, rx1, ry1)


def _op_meets(scene: Scene, op: Int, kind: Int, rx0: Float64, ry0: Float64, rx1: Float64, ry1: Float64, pad: Float64) -> Bool:
    """(goal 80) Whether an op may put a pixel inside the region rx0..ry1 (layer units): a conservative box per op, its
    antialiasing grown by `pad`. Text before shaping: its height from the size (ink lies within 2 em above the baseline
    and 1 em below, every script and emoji included), its width unknown, so bounded only on the side it's aligned to."""
    if rx1 < rx0 or ry1 < ry0:
        return False
    var base = op * 6
    var a = Float64(scene.nums[base])
    var b = Float64(scene.nums[base + 1])
    var c = Float64(scene.nums[base + 2])
    var d = Float64(scene.nums[base + 3])
    var e = Float64(scene.nums[base + 4])
    if kind == OP_RECT or kind == OP_IMAGE:
        return _box_meets(a - pad, b - pad, a + c + pad, b + d + pad, rx0, ry0, rx1, ry1)
    if kind == OP_SHADOW:
        var g = 1.5 * Float64(scene.nums[base + 5]) + pad  # (3 sigma)
        return _box_meets(a - g, b - g, a + c + g, b + d + g, rx0, ry0, rx1, ry1)
    if kind == OP_CIRCLE:
        return _box_meets(a - c - pad, b - c - pad, a + c + pad, b + c + pad, rx0, ry0, rx1, ry1)
    if kind == OP_LINE:
        var g = e / 2 + pad
        return _box_meets(min(a, c) - g, min(b, d) - g, max(a, c) + g, max(b, d) + g, rx0, ry0, rx1, ry1)
    if kind == OP_TEXT or kind == OP_RUN:
        var size = c
        var lean = abs(d) * size if kind == OP_TEXT else 0.5 * size  # (a slant; a run's italic leans < 0.5 em)
        if b + size + pad < ry0 or b - 2 * size - pad > ry1:
            return False
        var align = Int(scene.nums[base + 5]) if kind == OP_TEXT else scene.run_align(op)
        if kind == OP_RUN and scene.nums[base + 5] < 0:
            return True  # (letters pulled together may run back past their start: only the per-glyph test can say)
        if align == LEFT and a - size - lean - pad > rx1:
            return False
        if align == RIGHT and a + size + lean + pad < rx0:
            return False
        return True
    if kind == OP_POLY:  # (its bounds, kept by Scene.polygon)
        return _box_meets(c - pad, d - pad, e + pad, Float64(scene.nums[base + 5]) + pad, rx0, ry0, rx1, ry1)
    if kind == OP_STROKE:
        return _path_meets(scene, Int(a), Int(b), c / 2 + pad, rx0, ry0, rx1, ry1)
    return True


def fill_layers(mut f: Frame2D, scene: Scene, atlas: GlyphAtlas, font: Font, first: Int, end: Int, skip_ops: Int = 0,
                only: List[Int] = List[Int](), content_k: Float64 = 0, part: List[Float64] = List[Float64](), cull: Bool = True):
    """build_batches of layers [first, end) only, into f (emptied first): a host that keeps each layer's batches
    rebuilds just the layers that changed. Clips that earlier layers left open still cut these, as in the whole frame.
    skip_ops: layer `first`'s first ops left out (a layer that only grew, Scene.appends: just the new ops; the ops left
    out must leave no clip open). content_k > 0 (D-7940, a raster tile): just the ops in `only` of layer `first`
    (offsets from its first op, ascending, no clips or images among them; empty: none), built as if the layer were drawn at zoom
    content_k with no translation (glyphs rasterized and snapped for that zoom; a tile moves it by whole pixels).
    part (D-8022; with content_k): the rect (x0, y0, x1, y1, the layer's units, antialiasing padded) that will be drawn:
    boxes, capsules and glyphs wholly outside it aren't built (a long stroke's, a big shadow's, a paragraph's others).

    cull (goal 80, on unless a test compares): an op, or a glyph of a text run, wholly outside the region that can show
    makes no instances; text runs are tested before they are shaped. The region is the clip, and the canvas too for a
    layer that is rebuilt when it moves (not LayerTraits.fixed: a fixed layer's batches are kept and drawn again through
    a pan, so content past the canvas's edge may come into view). Bounds are conservative: the picture is the same,
    bit for bit (tests/test_gpu2d_cull).
    (The merge of goals 79 and 81: one region, the clip ∩ the canvas (as above) ∩ `part` when given; 80's bounds and its
    2 px pad for all of it; a tile (content_k > 0) never by the canvas.)"""
    f.clear()
    f.width = scene.w
    f.height = scene.h
    f.scale = scene.k
    if content_k <= 0:  # (a tile's layer has no OP_IMAGE: its only pixels are colour glyphs, added as they come)
        for ref b in scene.images:
            f.pics.append(b.copy())  # (the handle)
    var styles = List[TextStyle]()  # (the frame's first few styles: a card's label, number and note alternate)
    var st = TextStyle("", 0, False, 0)  # (the last run's style: made again only when the next one's differs)
    var pg = atlas.pages()  # (goal 80: no registry lookup per build, let alone per text op)
    if pg[].fonts == 0:
        pg[].fonts = Int(font_engine())
    var eng = Pointer[FontEngine, MutUntrackedOrigin](unsafe_from_address=pg[].fonts)
    var clips = List[Float64](capacity=64)  # the clip stack in pixels, x0, y0, x1, y1 per entry (already intersected)
    for layer in range(min(first, scene.layers())):  # (what earlier layers left open)
        var span0 = scene.layer_range(layer)
        for op in range(span0[0], span0[1]):
            var kind0 = Int(scene.kinds[op])
            if kind0 == OP_CLIP or kind0 == OP_UNCLIP:
                _clip_op(clips, scene, op, scene.layer_tx[layer], scene.layer_ty[layer], scene.layer_tk[layer])
    for layer in range(first, min(end, scene.layers())):
        var span = scene.layer_range(layer)
        var tx = scene.layer_tx[layer]
        var ty = scene.layer_ty[layer]
        var tk = scene.layer_tk[layer]
        var subset = content_k > 0 and layer == first  # (a tile: exactly `only`, none when it's empty)
        if content_k > 0 and layer == first:
            tx = 0
            ty = 0
            tk = content_k
        var ik = 1.0 / tk if tk != 0 else 1.0
        var has_part = subset and len(part) == 4  # (D-8022: a raster tile builds what it draws)
        var cull_on = tk > 0 and (cull or has_part)
        var by_canvas = cull and cull_on and content_k <= 0 and not layer_traits(scene, layer, len(clips) // 4).fixed
        var rx0 = -NO_CLIP  # the region that can show, this layer's units (the clip, ∩ the canvas when by_canvas, ∩ part)
        var ry0 = -NO_CLIP
        var rx1 = NO_CLIP
        var ry1 = NO_CLIP
        var pad = 2.0 * ik  # (antialiasing ramps reach half a pixel past a box: 2 px is generous)
        var q0 = -NO_CLIP  # (the region padded: D-8021's bands and D-8022's segments are tested against it)
        var q1 = -NO_CLIP
        var q2 = NO_CLIP
        var q3 = NO_CLIP
        var first_run = len(f.runs)
        f.layers.append(Layer2D(scene.layer_keys[layer].copy(), scene.layer_versions[layer], tx, ty, tk, first_run, 0))
        var cur_pipe = -1
        var cur_blend = -1
        # the innermost clip in this layer's units
        var c0 = -NO_CLIP
        var c1 = -NO_CLIP
        var c2 = NO_CLIP
        var c3 = NO_CLIP
        var clip_dirty = True
        var o0 = span[0] + (skip_ops if layer == first else 0)
        var count = len(only) if subset else span[1] - o0
        for oi in range(count):
            var op = span[0] + only[oi] if subset else o0 + oi
            var kind = Int(scene.kinds[op])
            var base = op * 6
            if kind == OP_CLIP or kind == OP_UNCLIP:
                _clip_op(clips, scene, op, tx, ty, tk)
                clip_dirty = True
                continue
            if clip_dirty:
                clip_dirty = False
                var n = len(clips)
                if n == 0:
                    c0 = -NO_CLIP
                    c1 = -NO_CLIP
                    c2 = NO_CLIP
                    c3 = NO_CLIP
                else:
                    c0 = (clips[n - 4] - tx) * ik
                    c1 = (clips[n - 3] - ty) * ik
                    c2 = (clips[n - 2] - tx) * ik
                    c3 = (clips[n - 1] - ty) * ik
                if cull_on:
                    rx0 = c0 if cull else -NO_CLIP
                    ry0 = c1 if cull else -NO_CLIP
                    rx1 = c2 if cull else NO_CLIP
                    ry1 = c3 if cull else NO_CLIP
                    if by_canvas:
                        rx0 = max(rx0, -tx * ik)
                        ry0 = max(ry0, -ty * ik)
                        rx1 = min(rx1, (Float64(scene.w) - tx) * ik)
                        ry1 = min(ry1, (Float64(scene.h) - ty) * ik)
                    if has_part:
                        rx0 = max(rx0, part[0])
                        ry0 = max(ry0, part[1])
                        rx1 = min(rx1, part[2])
                        ry1 = min(ry1, part[3])
                    q0 = rx0 - pad
                    q1 = ry0 - pad
                    q2 = rx1 + pad
                    q3 = ry1 + pad
            if cull_on and kind != OP_FILL and not _op_meets(scene, op, kind, rx0, ry0, rx1, ry1, pad):
                continue
            var color = scene.colors[op]
            var a = Float64(scene.nums[base])
            var b = Float64(scene.nums[base + 1])
            var c = Float64(scene.nums[base + 2])
            var d = Float64(scene.nums[base + 3])
            var e = Float64(scene.nums[base + 4])
            var pipe = PIPE_QUAD
            var mode = BLEND_OVER
            var before: Int
            var added: Int
            if kind == OP_TEXT:
                pipe = PIPE_GLYPH
                before = len(f.glyphs) // GLYPH_FLOATS
                ref text = scene.texts[Int(scene.text_of[op])]
                var weight = Int(e)
                var align = Int(scene.nums[base + 5])
                var on_screen = c * tk  # (Font.pick and measure see the size on screen, as SurfacePainter's draw does)
                var pen = a
                if align != LEFT:
                    var w = font.measure(text, on_screen, weight) * ik
                    pen -= w / 2 if align == CENTRE else w
                var fi = font.pick(weight, on_screen, text)
                var ox = atlas.face_x[fi]
                var oy = atlas.face_y[fi]
                if fi == 0:
                    _glyphs(f.glyphs, font.regular, ox, oy, text, pen, b, c, color, d, c0, c1, c2, c3, rx0, ry0, rx1, ry1, pad)
                elif fi == 1:
                    _glyphs(f.glyphs, font.medium, ox, oy, text, pen, b, c, color, d, c0, c1, c2, c3, rx0, ry0, rx1, ry1, pad)
                elif fi == 2:
                    _glyphs(f.glyphs, font.display, ox, oy, text, pen, b, c, color, d, c0, c1, c2, c3, rx0, ry0, rx1, ry1, pad)
                elif fi == 3:
                    _glyphs(f.glyphs, font.mono, ox, oy, text, pen, b, c, color, d, c0, c1, c2, c3, rx0, ry0, rx1, ry1, pad)
                else:
                    _glyphs(f.glyphs, font.mono_bold, ox, oy, text, pen, b, c, color, d, c0, c1, c2, c3, rx0, ry0, rx1, ry1, pad)
                added = len(f.glyphs) // GLYPH_FLOATS - before
            elif kind == OP_RUN:  # (goal 79) fonttext's shaped run: coverage glyphs from GlyphPages, colour ones as images
                ref full = scene.texts[Int(scene.text_of[op])]  # ("family\x1ftext", read in place)
                var fb = full.as_bytes()
                var cut = 0
                while cut < len(fb) and fb[cut] != 0x1F:
                    cut += 1
                if not _style_is(st, fb.unsafe_ptr(), cut, c, d, e, Float64(scene.nums[base + 5])):
                    var seen = -1
                    for si in range(len(styles)):
                        if _style_is(styles[si], fb.unsafe_ptr(), cut, c, d, e, Float64(scene.nums[base + 5])):
                            seen = si
                            break
                    if seen >= 0:
                        st = styles[seen]
                    else:
                        st = scene.run_style(op)
                        if len(styles) < 8:
                            styles.append(st)
                var rp = ft_run_in(eng, st, String(full[byte=cut + 1:]))  # (goal 80: not copied; valid until the next run_in)
                ref r = rp[]
                var xl = run_x(r, a, scene.run_align(op))
                var size_dev = st.size * tk
                var bdev = b * tk + ty
                var by = Int(bdev + 0.5) if bdev >= 0 else Int(bdev - 0.5)
                var g0 = len(f.glyphs) // GLYPH_FLOATS
                var i0 = len(f.images) // IMAGE_FLOATS
                var reach = 2.0 * st.size + pad  # (a glyph's ink lies within 2 em of its pen: tested before rasterizing)
                for ref g in r.glyphs:
                    if cull_on and (xl + g.x - reach > rx1 or xl + g.x + reach < rx0):
                        continue
                    var gx = (xl + g.x) * tk + tx
                    var px = Int(gx + 0.5) if gx >= 0 else Int(gx - 0.5)
                    var gy = g.y * tk
                    var py = by - (Int(gy + 0.5) if gy >= 0 else Int(gy - 0.5))
                    var ii = eng[].image(g.inst, g.gid, size_dev, 0)
                    ref im = eng[].images[ii]
                    var iw = im.w
                    if iw == 0:
                        continue
                    var ih = im.h
                    var x_l = (Float64(px + im.left) - tx) * ik
                    var y_l = (Float64(py - im.top) - ty) * ik
                    if cull_on and (x_l + Float64(iw) * ik + pad < rx0 or x_l - pad > rx1 or y_l + Float64(ih) * ik + pad < ry0 or y_l - pad > ry1):
                        continue
                    if im.color:
                        var al = Int((color >> 24) & 0xFF)
                        f.pics.append(pg[].straight(ii, al, im.rgba, iw, ih))
                        f.images.append(Float32(x_l))
                        f.images.append(Float32(y_l))
                        f.images.append(Float32(Float64(iw) * ik))
                        f.images.append(Float32(Float64(ih) * ik))
                        f.images.append(Float32(len(f.pics) - 1))
                        f.images.append(Float32(iw))
                        f.images.append(Float32(ih))
                        f.images.append(0)
                        _clip4(f.images, c0, c1, c2, c3)
                    else:
                        var slot = pg[].place(ii, im)
                        var u0 = pg[].sx[slot]
                        var v0 = atlas.dyn_y0 + pg[].sy[slot]
                        var gp = _grow(f.glyphs, GLYPH_FLOATS)
                        gp[] = Float32(x_l)
                        gp.unsafe_offset(1)[] = Float32(y_l)
                        gp.unsafe_offset(2)[] = Float32(Float64(iw) * ik)
                        gp.unsafe_offset(3)[] = Float32(Float64(ih) * ik)
                        gp.unsafe_offset(4)[] = Float32(u0)
                        gp.unsafe_offset(5)[] = Float32(v0)
                        gp.unsafe_offset(6)[] = Float32(u0 + iw)
                        gp.unsafe_offset(7)[] = Float32(v0 + ih)
                        _put_color(gp, 8, color)
                        gp.unsafe_offset(12)[] = 0
                        gp.unsafe_offset(13)[] = Float32(b)
                        gp.unsafe_offset(14)[] = 0
                        gp.unsafe_offset(15)[] = 0
                        _put_clip(gp, 16, c0, c1, c2, c3)
                var ng = len(f.glyphs) // GLYPH_FLOATS - g0
                var ni = len(f.images) // IMAGE_FLOATS - i0
                if ng > 0:
                    if cur_pipe == PIPE_GLYPH and cur_blend == BLEND_OVER:
                        f.runs[len(f.runs) - 1].count += ng
                    else:
                        f.runs.append(Run(PIPE_GLYPH, g0, ng, BLEND_OVER))
                        cur_pipe = PIPE_GLYPH
                        cur_blend = BLEND_OVER
                if ni > 0:
                    if cur_pipe == PIPE_IMAGE and cur_blend == BLEND_OVER:
                        f.runs[len(f.runs) - 1].count += ni
                    else:
                        f.runs.append(Run(PIPE_IMAGE, i0, ni, BLEND_OVER))
                        cur_pipe = PIPE_IMAGE
                        cur_blend = BLEND_OVER
                continue
            elif kind == OP_POLY:
                pipe = PIPE_POLY
                before = len(f.polys) // POLY_FLOATS
                var first = Int(a)
                var n = Int(b)
                if n < 3:  # (Scene.polygon never records one: the block writes below need three points)
                    continue
                var p0 = first * 2
                var pt0 = len(f.points) // 2
                var fan0 = len(f.fan) // 2
                var bx0 = scene.nums[base + 2]  # (its bounds, kept by Scene.polygon)
                var by0 = scene.nums[base + 3]
                var bx1 = scene.nums[base + 4]
                var by1 = scene.nums[base + 5]
                var pp = _grow(f.points, 2 * n)
                var sp = scene.path.unsafe_ptr()
                for z in range(2 * n):
                    pp.unsafe_offset(z)[] = sp.unsafe_offset(p0 + z)[]
                # n − 2 triangles zig-zagging in from both ends ((lo, lo+1, hi), then (lo, hi−1, hi), …): their edges
                # inside the polygon cancel in pairs, so their signed windings add up to the polygon's (like a fan from
                # p0), but a ribbon (an ink outline: one side out, the other back) is covered about once instead of
                # being swept by long fan triangles: ~10× less stencil work for a stroke (goal 75 M2)
                # (started where the two chains face each other across the polygon: the start whose chords an eighth,
                # a quarter and three eighths of the way round are shortest. An ink outline's list begins at the left
                # edge, so a zig-zag from index 0 paired each left point with a right point a whole cap further on:
                # slivers whose boxes summed to 35× the strokes' area; from the cap's middle they're ~the stroke, D-7537)
                var rot = _zigzag_start(scene.path, p0, n)
                var lo = rot
                var hi = rot + n - 1
                var upper = True
                var fp = _grow(f.fan, 6 * (n - 2))
                var w = 0
                while hi - lo >= 2:
                    var ia: Int
                    var ib: Int
                    if upper:
                        ia = lo
                        ib = lo + 1
                        lo += 1
                    else:
                        ia = hi - 1
                        ib = hi
                        hi -= 1
                    var ic = hi if upper else lo
                    if ia >= n:
                        ia -= n
                    if ib >= n:
                        ib -= n
                    if ic >= n:
                        ic -= n
                    var v0 = ia if upper else ic  # (the same three corners, in the order that keeps the winding)
                    var v1 = ib if upper else ia
                    var v2 = ic if upper else ib
                    fp.unsafe_offset(w)[] = sp.unsafe_offset(p0 + 2 * v0)[]
                    fp.unsafe_offset(w + 1)[] = sp.unsafe_offset(p0 + 2 * v0 + 1)[]
                    fp.unsafe_offset(w + 2)[] = sp.unsafe_offset(p0 + 2 * v1)[]
                    fp.unsafe_offset(w + 3)[] = sp.unsafe_offset(p0 + 2 * v1 + 1)[]
                    fp.unsafe_offset(w + 4)[] = sp.unsafe_offset(p0 + 2 * v2)[]
                    fp.unsafe_offset(w + 5)[] = sp.unsafe_offset(p0 + 2 * v2 + 1)[]
                    w += 6
                    upper = not upper
                f.polys.append(Float32(fan0))
                f.polys.append(Float32(3 * (n - 2)))
                f.polys.append(Float32(pt0))
                f.polys.append(Float32(n))
                _color(f.polys, color)
                f.polys.append(bx0)
                f.polys.append(by0)
                f.polys.append(bx1)
                f.polys.append(by1)
                _clip4(f.polys, c0, c1, c2, c3)
                added = 1
            elif kind == OP_IMAGE:
                pipe = PIPE_IMAGE
                mode = BLEND_REPLACE
                before = len(f.images) // IMAGE_FLOATS
                var which = Int(e)
                var smooth = scene.nums[base + 5] > 0
                var pic = scene.images[which].copy()
                if not pic[].opaque:  # (a picture with see-through pixels is blended over: icons, D-7910)
                    mode = BLEND_OVER
                var pw = pic[].w
                ready(pic, c * tk, d * tk, smooth)  # (the half sizes it's read from)
                f.images.append(Float32(a))
                f.images.append(Float32(b))
                f.images.append(Float32(c))
                f.images.append(Float32(d))
                f.images.append(Float32(which))
                f.images.append(Float32(pw))
                f.images.append(Float32(pic[].h))
                f.images.append(Float32(0) if smooth else Float32(1))
                _clip4(f.images, c0, c1, c2, c3)
                added = 1
            else:
                before = len(f.quads) // QUAD_FLOATS
                added = 1
                if kind == OP_RECT:
                    var hole = Float64(scene.nums[op * 6 + 5])
                    if hole < 0:  # (D-8021) the bottom-right corner's own radius: three boxes cut along pixels that meet exactly
                        var bx = a + c + hole
                        var by = b + d + hole
                        if not cull_on or (b <= q3 and by >= q1):
                            _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, c1, c2, min(c3, by))
                        if not cull_on or (b + d >= q1 and by <= q3 and a <= q2 and bx >= q0):
                            _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, max(c1, by), min(c2, bx), c3)
                        if not cull_on or (b + d >= q1 and by <= q3 and bx <= q2 and a + c >= q0):
                            _quad(f.quads, a, b, c, d, -hole, SHAPE_BOX, color, max(c0, bx), max(c1, by), c2, c3)
                        added = len(f.quads) // QUAD_FLOATS - before
                    elif hole == 0:
                        _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, c1, c2, c3)
                    else:  # (D-7973) the box minus its middle as up to four clipped bands: no pixel of the middle is made
                        var hx0 = a + hole
                        var hy0 = b + hole
                        var hx1 = a + c - hole
                        var hy1 = b + d - hole
                        var br = scene.corner_of(op)
                        if br > 0:  # (and its bottom-right corner's own radius: the bands cut again where that corner begins)
                            var bx = a + c - br
                            var cy = min(b + d - br, hy1)
                            if not cull_on or (b <= q3 and hy0 >= q1):
                                _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, c1, c2, min(c3, hy0))
                            if not cull_on or (hy1 <= q3 and b + d >= q1):
                                if not cull_on or (a <= q2 and bx >= q0):
                                    _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, max(c1, hy1), min(c2, bx), c3)
                                if not cull_on or (bx <= q2 and a + c >= q0):
                                    _quad(f.quads, a, b, c, d, br, SHAPE_BOX, color, max(c0, bx), max(c1, hy1), c2, c3)
                            if not cull_on or (hy0 <= q3 and hy1 >= q1):
                                if not cull_on or (a <= q2 and hx0 >= q0):
                                    _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, max(c1, hy0), min(c2, hx0), min(c3, hy1))
                                if not cull_on or (hx1 <= q2 and a + c >= q0):
                                    _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, max(c0, hx1), max(c1, hy0), c2, min(c3, cy))
                                    if cy < hy1:
                                        _quad(f.quads, a, b, c, d, br, SHAPE_BOX, color, max(c0, max(hx1, bx)), max(c1, cy), c2, min(c3, hy1))
                                        if bx > hx1:
                                            _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, max(c0, hx1), max(c1, cy), min(c2, bx), min(c3, hy1))
                            added = len(f.quads) // QUAD_FLOATS - before
                        else:
                            if not cull_on or (b <= q3 and hy0 >= q1):
                                _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, c1, c2, min(c3, hy0))
                            if not cull_on or (hy1 <= q3 and b + d >= q1):
                                _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, max(c1, hy1), c2, c3)
                            if not cull_on or (hy0 <= q3 and hy1 >= q1):
                                if not cull_on or (a <= q2 and hx0 >= q0):
                                    _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, max(c1, hy0), min(c2, hx0), min(c3, hy1))
                                if not cull_on or (hx1 <= q2 and a + c >= q0):
                                    _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, max(c0, hx1), max(c1, hy0), c2, min(c3, hy1))
                        added = len(f.quads) // QUAD_FLOATS - before
                elif kind == OP_SHADOW:  # (goal 80) e = corner radius, nums[5] = CSS blur (2 sigma)
                    if c > 0 and d > 0:
                        _quad(f.quads, a, b, c, d, e, SHAPE_SHADOW, color, c0, c1, c2, c3, 0, max(Float64(scene.nums[base + 5]) / 2, 0.25 * ik))
                    else:
                        added = 0
                elif kind == OP_CIRCLE:
                    _quad(f.quads, a, b, a, b, c, SHAPE_CAPSULE, color, c0, c1, c2, c3)
                elif kind == OP_LINE:
                    if not cull_on or _segment_meets(a, b, c, d, e / 2, q0, q1, q2, q3):
                        _quad(f.quads, a, b, c, d, e / 2, SHAPE_CAPSULE, color, c0, c1, c2, c3)
                    else:
                        added = 0
                elif kind == OP_STROKE:  # (D-7940: the capsules and discs a polyline of lines and circles would make)
                    var p0 = Int(a) * 2
                    var m = Int(b)
                    var hw = c / 2
                    var g = hw + pad  # (goal 80: a capsule or disc wholly outside the region is left out)
                    for z in range(m - 1):
                        var xa = Float64(scene.path[p0 + 2 * z])
                        var ya = Float64(scene.path[p0 + 2 * z + 1])
                        var xb = Float64(scene.path[p0 + 2 * z + 2])
                        var yb = Float64(scene.path[p0 + 2 * z + 3])
                        if cull_on and not _box_meets(min(xa, xb) - g, min(ya, yb) - g, max(xa, xb) + g, max(ya, yb) + g, rx0, ry0, rx1, ry1):
                            continue
                        _quad(f.quads, xa, ya, xb, yb, hw, SHAPE_CAPSULE, color, c0, c1, c2, c3)
                    for z in range(m):
                        var px = Float64(scene.path[p0 + 2 * z])
                        var py = Float64(scene.path[p0 + 2 * z + 1])
                        if cull_on and not _box_meets(px - g, py - g, px + g, py + g, rx0, ry0, rx1, ry1):
                            continue
                        _quad(f.quads, px, py, px, py, hw, SHAPE_CAPSULE, color, c0, c1, c2, c3)
                    added = len(f.quads) // QUAD_FLOATS - before
                elif kind == OP_FILL:  # the whole canvas, whatever the layer's transform and clip
                    mode = BLEND_REPLACE
                    _quad(f.quads, -tx * ik, -ty * ik, c * ik, d * ik, 0, SHAPE_BOX, color, -NO_CLIP, -NO_CLIP, NO_CLIP, NO_CLIP)
                else:
                    added = 0
            if added == 0:
                continue
            if pipe == cur_pipe and mode == cur_blend:
                f.runs[len(f.runs) - 1].count += added
            else:
                f.runs.append(Run(pipe, before, added, mode))
                cur_pipe = pipe
                cur_blend = mode
        f.layers[len(f.layers) - 1].runs = len(f.runs) - first_run


# ---- the CPU executor: the runs drawn with a shader's math ----


def _lo(edge: Float64, t: Float64, k: Float64, limit: Int) -> Int:
    """The first pixel whose centre is at or after a clip edge (in the layer's units) once transformed."""
    if edge <= -NO_CLIP * 0.5:
        return 0
    var e = edge * k + t
    return Int(min(max(ceil(e - 0.5), 0.0), Float64(limit)))


def _hi(edge: Float64, t: Float64, k: Float64, limit: Int) -> Int:
    """One past the last pixel whose centre is before a clip edge once transformed."""
    if edge >= NO_CLIP * 0.5:
        return limit
    var e = edge * k + t
    return Int(min(max(ceil(e - 0.5), 0.0), Float64(limit)))


def _u32(r: Float32, g: Float32, b: Float32, a: Float32) -> UInt32:
    return (UInt32(Int(Float64(r) * 255.0 + 0.5)) | (UInt32(Int(Float64(g) * 255.0 + 0.5)) << 8) | (UInt32(Int(Float64(b) * 255.0 + 0.5)) << 16)
            | (UInt32(Int(Float64(a) * 255.0 + 0.5)) << 24))


def _cpu_quad(mut s: Surface, q: List[Float32], at: Int, tx: Float64, ty: Float64, tk: Float64, mode: Int, r0: Int, r1: Int):
    var color = _u32(q[at + 8], q[at + 9], q[at + 10], q[at + 11])
    var xlo = _lo(Float64(q[at + 12]), tx, tk, s.width)
    var ylo = max(_lo(Float64(q[at + 13]), ty, tk, s.height), r0)
    var xhi = _hi(Float64(q[at + 14]), tx, tk, s.width)
    var yhi = min(_hi(Float64(q[at + 15]), ty, tk, s.height), r1)
    var p = s.pixels()
    if Int(q[at + 5]) == SHAPE_SHADOW:  # (goal 80: mojoui.shadow's math, as the shaders)
        var x = Float64(q[at]) * tk + tx
        var y = Float64(q[at + 1]) * tk + ty
        var w = Float64(q[at + 2]) * tk
        var h = Float64(q[at + 3]) * tk
        if w <= 0 or h <= 0:
            return
        var sg = max(Float64(q[at + 7]) * tk, 0.25)
        var hx = w / 2
        var hy = h / 2
        var r = min(Float64(q[at + 4]) * tk, min(hx, hy))
        var g = shadow_reach(sg)
        var x0 = max(Int(floor(x - g)), xlo)
        var y0 = max(Int(floor(y - g)), ylo)
        var x1 = min(Int(floor(x + w + g)) + 1, xhi)
        var y1 = min(Int(floor(y + h + g)) + 1, yhi)
        if y1 <= y0 or x1 <= x0:
            return
        var cols = shadow_columns(x0, x1, x + hx, hx, hy, r, sg)  # (what a column needs, once, not per pixel)
        for py in range(y0, y1):
            var row = shadow_row(Float64(py) + 0.5 - (y + hy), hy, r, sg)
            for px in range(x0, x1):
                var cov = shadow_at(Float64(px) + 0.5 - (x + hx), Float64(py) + 0.5 - (y + hy), hx, hy, r, sg, cols[px - x0], row)
                if cov > 0:
                    var d = p.unsafe_offset(py * s.width + px)
                    d[] = color if mode == BLEND_REPLACE else blend(d[], color, min(cov, 1.0))
        return
    if Int(q[at + 5]) == SHAPE_BOX:
        var x = Float64(q[at]) * tk + tx
        var y = Float64(q[at + 1]) * tk + ty
        var w = Float64(q[at + 2]) * tk
        var h = Float64(q[at + 3]) * tk
        if w <= 0 or h <= 0:
            return
        var r = min(Float64(q[at + 4]) * tk, min(w, h) / 2)
        var x0 = max(Int(floor(x)), xlo)
        var y0 = max(Int(floor(y)), ylo)
        var x1 = min(Int(floor(x + w)) + 1, xhi)
        var y1 = min(Int(floor(y + h)) + 1, yhi)
        for py in range(y0, y1):
            var cy = Float64(py) + 0.5
            var vy = min(cy - y, y + h - cy) + 0.5
            # (goal 80) the row's solid stretch [fill0, fill1): pixels wholly inside, not beside a corner: no per-pixel
            # coverage. A solid colour (or a replace) is stored, anything else blended at coverage 1, as below.
            var fill0 = x1
            var fill1 = x1
            if vy >= 1.0:
                var inset = 0.5 if (r <= 0 or (cy >= y + r and cy <= y + h - r)) else max(r, 0.5)
                fill0 = min(max(Int(ceil(x + inset - 0.5)), x0), x1)
                fill1 = max(min(Int(floor(x + w - inset - 0.5)) + 1, x1), fill0)
                if mode == BLEND_REPLACE or (color >> 24) == 255:
                    for px in range(fill0, fill1):
                        var d = p.unsafe_offset(py * s.width + px)
                        d[] = color if mode == BLEND_REPLACE else ((color & 0x00FFFFFF) | (d[] & 0xFF000000))
                else:
                    for px in range(fill0, fill1):
                        var d = p.unsafe_offset(py * s.width + px)
                        d[] = blend(d[], color, 1.0)
            for px in range(x0, x1):
                if px >= fill0 and px < fill1:
                    continue
                var cx = Float64(px) + 0.5
                var cov = min(min(cx - x, x + w - cx) + 0.5, vy)
                if r > 0:
                    var dx = max(max(x + r - cx, cx - (x + w - r)), 0.0)
                    var dy = max(max(y + r - cy, cy - (y + h - r)), 0.0)
                    if dx > 0 and dy > 0:
                        cov = min(cov, r - sqrt(dx * dx + dy * dy) + 0.5)
                if cov > 0:
                    var d = p.unsafe_offset(py * s.width + px)
                    d[] = color if mode == BLEND_REPLACE else blend(d[], color, min(cov, 1.0))
    else:
        var ax = Float64(q[at]) * tk + tx
        var ay = Float64(q[at + 1]) * tk + ty
        var bx = Float64(q[at + 2]) * tk + tx
        var by = Float64(q[at + 3]) * tk + ty
        var hw = Float64(q[at + 4]) * tk
        var x0 = max(Int(floor(min(ax, bx) - hw - 1)), xlo)
        var x1 = min(Int(floor(max(ax, bx) + hw + 2)), xhi)
        var y0 = max(Int(floor(min(ay, by) - hw - 1)), ylo)
        var y1 = min(Int(floor(max(ay, by) + hw + 2)), yhi)
        var dx = bx - ax
        var dy = by - ay
        var len2 = dx * dx + dy * dy
        for py in range(y0, y1):
            var cy = Float64(py) + 0.5
            for px in range(x0, x1):
                var cx = Float64(px) + 0.5
                var t = 0.0 if len2 == 0 else min(max(((cx - ax) * dx + (cy - ay) * dy) / len2, 0.0), 1.0)
                var ex = cx - (ax + t * dx)
                var ey = cy - (ay + t * dy)
                var cov = hw + 0.5 - sqrt(ex * ex + ey * ey)
                if cov > 0:
                    var d = p.unsafe_offset(py * s.width + px)
                    d[] = color if mode == BLEND_REPLACE else blend(d[], color, min(cov, 1.0))


def _cpu_glyph(mut s: Surface, atlas: GlyphAtlas, q: List[Float32], at: Int, tx: Float64, ty: Float64, tk: Float64, r0: Int, r1: Int,
               own: Pointer[UInt8, MutUntrackedOrigin], dyn: Pointer[UInt8, MutUntrackedOrigin]):
    var left = Float64(q[at]) * tk + tx
    var top = Float64(q[at + 1]) * tk + ty
    var gw = Float64(q[at + 6] - q[at + 4])
    var gh = Float64(q[at + 7] - q[at + 5])
    if gw <= 0 or gh <= 0:
        return
    var sc = Float64(q[at + 2]) * tk / gw  # texels → pixels
    var u0 = Float64(q[at + 4])
    var v0 = Float64(q[at + 5])
    var r = Float64(q[at + 8]) * 255.0
    var gr = Float64(q[at + 9]) * 255.0
    var b = Float64(q[at + 10]) * 255.0
    var alpha = Float64(q[at + 11])
    var slant = Float64(q[at + 12])
    var baseline = Float64(q[at + 13]) * tk + ty
    var xlo = _lo(Float64(q[at + 16]), tx, tk, s.width)
    var ylo = max(_lo(Float64(q[at + 17]), ty, tk, s.height), r0)
    var xhi = _hi(Float64(q[at + 18]), tx, tk, s.width)
    var yhi = min(_hi(Float64(q[at + 19]), ty, tk, s.height), r1)
    var sub = 2 if sc < 0.75 else 1
    var lean_top = slant * (baseline - top)
    var lean_bottom = slant * (baseline - top - gh * sc)
    var x0 = max(Int(floor(left + min(lean_bottom, 0.0))), xlo)
    var y0 = max(Int(floor(top)), ylo)
    var x1 = min(Int(floor(left + gw * sc + max(lean_top, 0.0))) + 1, xhi)
    var y1 = min(Int(floor(top + gh * sc)) + 1, yhi)
    var p = s.pixels()
    for py in range(y0, y1):
        var row_left = left + slant * (baseline - Float64(py) - 0.5)
        for px in range(x0, x1):
            var cov = 0.0
            for sy in range(sub):
                for sx in range(sub):
                    var ax = (Float64(px) + (Float64(sx) + 0.5) / Float64(sub) - row_left) / sc
                    var ay = (Float64(py) + (Float64(sy) + 0.5) / Float64(sub) - top) / sc
                    if ax >= 0.0 and ax < gw and ay >= 0.0 and ay < gh:
                        cov += atlas.coverage_in(u0 + ax, v0 + ay, own, dyn)
            cov = cov / Float64(sub * sub) * alpha
            if cov <= 0.003:
                continue
            var dp = p.unsafe_offset(py * s.width + px)
            var d = dp[]
            var nr = UInt32(Int(r * cov + Float64(Int(d & 0xFF)) * (1 - cov) + 0.5))
            var ng = UInt32(Int(gr * cov + Float64(Int((d >> 8) & 0xFF)) * (1 - cov) + 0.5))
            var nb = UInt32(Int(b * cov + Float64(Int((d >> 16) & 0xFF)) * (1 - cov) + 0.5))
            dp[] = nr | (ng << 8) | (nb << 16) | (d & 0xFF000000)


def _cpu_image(mut s: Surface, frame: Frame2D, q: List[Float32], at: Int, tx: Float64, ty: Float64, tk: Float64, mode: Int, r0: Int, r1: Int):
    var x = Float64(q[at]) * tk + tx
    var y = Float64(q[at + 1]) * tk + ty
    var w = Float64(q[at + 2]) * tk
    var h = Float64(q[at + 3]) * tk
    var which = Int(q[at + 4])
    var pw = Int(q[at + 5])
    var ph = Int(q[at + 6])
    if w <= 0 or h <= 0 or pw <= 0 or ph <= 0 or which < 0 or which >= len(frame.pics):
        return
    var at_uv = Sampler(frame.pics[which], w, h, q[at + 7] == 0)
    var x0 = max(Int(ceil(x - 0.5)), _lo(Float64(q[at + 8]), tx, tk, s.width))
    var y0 = max(Int(ceil(y - 0.5)), _lo(Float64(q[at + 9]), ty, tk, s.height))
    var x1 = min(Int(ceil(x + w - 0.5)), _hi(Float64(q[at + 10]), tx, tk, s.width))
    var y1 = min(Int(ceil(y + h - 0.5)), _hi(Float64(q[at + 11]), ty, tk, s.height))
    var p = s.pixels()
    for py in range(max(y0, r0), min(y1, r1)):
        var v = (Float64(py) + 0.5 - y) / h
        for qx in range(max(x0, 0), min(x1, s.width)):
            var src = at_uv.at((Float64(qx) + 0.5 - x) / w, v)
            var dp = p.unsafe_offset(py * s.width + qx)
            if mode == BLEND_REPLACE or (src >> 24) == 255:
                dp[] = src
            elif (src >> 24) != 0:
                dp[] = blend(dp[], src, 1.0)


def _span(mut cov: List[Float64], a: Float64, b: Float64, x0: Int, w: Int, share: Float64):
    """Adds `share` × how much of each pixel [a, b) covers (pixel columns x0 … x0 + w − 1) to cov."""
    var lo = max(a, Float64(x0))
    var hi = min(b, Float64(x0 + w))
    if hi <= lo:
        return
    var ia = Int(lo)
    var ib = Int(hi)
    if ia == ib:
        cov[ia - x0] += (hi - lo) * share
        return
    cov[ia - x0] += (Float64(ia + 1) - lo) * share
    for i in range(ia + 1, min(ib, x0 + w)):
        cov[i - x0] += share
    if ib < x0 + w:
        cov[ib - x0] += (hi - Float64(ib)) * share


struct _PolyScratch(Movable):
    var xs: List[Float64]
    var ys: List[Float64]
    var cov: List[Float64]
    var cx: List[Float64]
    var cd: List[Int]

    def __init__(out self):
        self.xs = List[Float64](capacity=1024)
        self.ys = List[Float64](capacity=1024)
        self.cov = List[Float64](capacity=2048)
        self.cx = List[Float64](capacity=64)
        self.cd = List[Int](capacity=64)


def _cpu_poly(mut s: Surface, frame: Frame2D, at: Int, tx: Float64, ty: Float64, tk: Float64, mut sc: _PolyScratch, r0: Int, r1: Int):
    ref q = frame.polys
    var first = Int(q[at + 2])
    var n = Int(q[at + 3])
    if n < 3:
        return
    var color = _u32(q[at + 4], q[at + 5], q[at + 6], q[at + 7])
    var xlo = _lo(Float64(q[at + 12]), tx, tk, s.width)
    var ylo = max(_lo(Float64(q[at + 13]), ty, tk, s.height), r0)
    var xhi = _hi(Float64(q[at + 14]), tx, tk, s.width)
    var yhi = min(_hi(Float64(q[at + 15]), ty, tk, s.height), r1)
    sc.xs.clear()
    sc.ys.clear()
    var bx0 = 1e30
    var by0 = 1e30
    var bx1 = -1e30
    var by1 = -1e30
    for i in range(n):
        var x = Float64(frame.points[(first + i) * 2]) * tk + tx
        var y = Float64(frame.points[(first + i) * 2 + 1]) * tk + ty
        sc.xs.append(x)
        sc.ys.append(y)
        bx0 = min(bx0, x)
        by0 = min(by0, y)
        bx1 = max(bx1, x)
        by1 = max(by1, y)
    var x0 = max(Int(floor(bx0)), 0)
    var x1 = min(Int(floor(bx1)) + 1, s.width)
    var y0 = max(Int(floor(by0)), ylo)
    var y1 = min(Int(floor(by1)) + 1, yhi)
    if x1 <= x0 or y1 <= y0:
        return
    var w = x1 - x0
    sc.cov.clear()
    for _ in range(w):
        sc.cov.append(0.0)
    var share = 1.0 / Float64(POLY_SUB)
    var p = s.pixels()
    var plo = max(x0, xlo)
    var phi = min(x1, xhi)
    for py in range(y0, y1):
        for i in range(w):
            sc.cov[i] = 0.0
        var any = False
        for sub in range(POLY_SUB):
            var sy = Float64(py) + (Float64(sub) + 0.5) * share
            sc.cx.clear()
            sc.cd.clear()
            for i in range(n):
                var j = i + 1 if i + 1 < n else 0
                var ya = sc.ys[i]
                var yb = sc.ys[j]
                if (ya <= sy and sy < yb) or (yb <= sy and sy < ya):
                    var x = sc.xs[i] + (sy - ya) * (sc.xs[j] - sc.xs[i]) / (yb - ya)
                    var d = 1 if yb > ya else -1
                    var k = len(sc.cx)
                    sc.cx.append(x)
                    sc.cd.append(d)
                    while k > 0 and sc.cx[k - 1] > x:
                        sc.cx[k] = sc.cx[k - 1]
                        sc.cd[k] = sc.cd[k - 1]
                        k -= 1
                    sc.cx[k] = x
                    sc.cd[k] = d
            var wind = 0
            var start = 0.0
            for c in range(len(sc.cx)):
                var before = wind
                wind += sc.cd[c]
                if before == 0 and wind != 0:
                    start = sc.cx[c]
                elif before != 0 and wind == 0:
                    _span(sc.cov, start, sc.cx[c], x0, w, share)
                    any = True
        if any:
            for qx in range(plo, phi):
                var cv = sc.cov[qx - x0]
                if cv > 0:
                    var d = p.unsafe_offset(py * s.width + qx)
                    d[] = blend(d[], color, min(cv, 1.0))


comptime BAND_ROWS = 16  # rows a thread takes at a time
comptime CPU_THREADS_MAX = 16  # (more gained nothing on a 12-core, 24-thread machine: the hardware threads share their cores)


struct _BandJob:
    """What every thread of one execute_cpu shares, on the caller's stack until all have joined."""

    var frame: Int
    var atlas: Int
    var pixels: Int
    var width: Int
    var height: Int
    var scale: Float64
    var rows: Int  # each instance's device rows in paint order: y0, y1 (Int32 pairs)
    var dyn: Int
    var next: Int64  # the next band to take

    def __init__(out self, frame: Int, atlas: Int, pixels: Int, width: Int, height: Int, scale: Float64, rows: Int, dyn: Int):
        self.frame = frame
        self.atlas = atlas
        self.pixels = pixels
        self.width = width
        self.height = height
        self.scale = scale
        self.rows = rows
        self.dyn = dyn
        self.next = 0


def _instance_rows(frame: Frame2D, height: Int) -> List[Int32]:
    """Every instance's device rows [y0, y1), conservative, in paint order: a band skips what isn't in it."""
    var out = List[Int32]()
    for li in range(len(frame.layers)):
        ref layer = frame.layers[li]
        var ty = layer.dy
        var tk = layer.k
        for ri in range(layer.first_run, layer.first_run + layer.runs):
            var run = frame.runs[ri]
            for i in range(run.first, run.first + run.count):
                var y0: Float64
                var y1: Float64
                if run.pipe == PIPE_QUAD:
                    var q = i * QUAD_FLOATS
                    var b = Float64(frame.quads[q + 1])
                    var d = Float64(frame.quads[q + 3])
                    var shape = Int(frame.quads[q + 5])
                    if shape == SHAPE_CAPSULE:
                        var hw = Float64(frame.quads[q + 4])
                        y0 = min(b, d) - hw
                        y1 = max(b, d) + hw
                    else:
                        y0 = b
                        y1 = b + d
                        if shape == SHAPE_SHADOW:
                            var g = 3 * max(Float64(frame.quads[q + 7]), 0.25 / tk if tk > 0 else 0.25)
                            y0 -= g
                            y1 += g
                elif run.pipe == PIPE_GLYPH:
                    var q = i * GLYPH_FLOATS
                    y0 = Float64(frame.glyphs[q + 1])
                    y1 = y0 + Float64(frame.glyphs[q + 3])
                elif run.pipe == PIPE_IMAGE:
                    var q = i * IMAGE_FLOATS
                    y0 = Float64(frame.images[q + 1])
                    y1 = y0 + Float64(frame.images[q + 3])
                else:
                    var q = i * POLY_FLOATS
                    y0 = Float64(frame.polys[q + 9])
                    y1 = Float64(frame.polys[q + 11])
                var a = min(y0 * tk, y1 * tk) + ty - 3
                var z = max(y0 * tk, y1 * tk) + ty + 3
                out.append(Int32(Int(min(max(floor(a), 0.0), Float64(height)))))
                out.append(Int32(Int(min(max(ceil(z), 0.0), Float64(height)))))
    return out^


def _execute_rows(frame: Frame2D, atlas: GlyphAtlas, mut surface: Surface, r0: Int, r1: Int, rows: Pointer[Int32, MutUntrackedOrigin],
                  dyn: Pointer[UInt8, MutUntrackedOrigin], mut scratch: _PolyScratch):
    """The frame's runs in paint order, only the surface's rows [r0, r1)."""
    var own = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(atlas.bytes.unsafe_ptr()))
    var k = 0
    for li in range(len(frame.layers)):
        ref layer = frame.layers[li]
        var tx = layer.dx
        var ty = layer.dy
        var tk = layer.k
        for ri in range(layer.first_run, layer.first_run + layer.runs):
            var run = frame.runs[ri]
            for i in range(run.first, run.first + run.count):
                var at = k
                k += 1
                if Int(rows.unsafe_offset(2 * at)[]) >= r1 or Int(rows.unsafe_offset(2 * at + 1)[]) <= r0:
                    continue
                if run.pipe == PIPE_QUAD:
                    _cpu_quad(surface, frame.quads, i * QUAD_FLOATS, tx, ty, tk, run.blend, r0, r1)
                elif run.pipe == PIPE_GLYPH:
                    _cpu_glyph(surface, atlas, frame.glyphs, i * GLYPH_FLOATS, tx, ty, tk, r0, r1, own, dyn)
                elif run.pipe == PIPE_IMAGE:
                    _cpu_image(surface, frame, frame.images, i * IMAGE_FLOATS, tx, ty, tk, run.blend, r0, r1)
                else:
                    _cpu_poly(surface, frame, i * POLY_FLOATS, tx, ty, tk, scratch, r0, r1)


def _bands(addr: Int):
    """Takes bands of rows until none are left (each thread of an execute_cpu runs this)."""
    ref job = Pointer[_BandJob, MutUntrackedOrigin](unsafe_from_address=addr)[]
    ref frame = Pointer[Frame2D, MutUntrackedOrigin](unsafe_from_address=job.frame)[]
    ref atlas = Pointer[GlyphAtlas, MutUntrackedOrigin](unsafe_from_address=job.atlas)[]
    var s = Surface(job.pixels, job.width, job.height, job.scale)
    var rows = Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=job.rows)
    var dyn = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=job.dyn)
    var scratch = _PolyScratch()
    while True:
        var band = Int(Atomic[Scalar[DType.int64]].fetch_add(Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=Int(Pointer(to=job.next))), 1))
        var r0 = band * BAND_ROWS
        if r0 >= job.height:
            return
        _execute_rows(frame, atlas, s, r0, min(r0 + BAND_ROWS, job.height), rows, dyn, scratch)


def _band_thread(arg: libc.ThreadArg) -> libc.ThreadArg:
    _bands(Int(arg))
    return libc.null_arg()


def execute_cpu(frame: Frame2D, atlas: GlyphAtlas, mut surface: Surface, threads: Int = 0):
    """Draws the frame's runs into the surface, in order, each layer through its transform, with the shaders' math
    (top of this file): the reference for a GPU backend's readback, and the fallback. (Goal 80) The rows are split in
    bands that `threads` threads take in turn (0: one per core, at most CPU_THREADS_MAX; small frames and 1: this thread alone): every band
    draws every instance that meets it in paint order, so the picture is the same for any number (tests/test_cpu_threads).
    Plain pthreads, joined before this returns: no runtime pool, so it works on any thread and every platform."""
    var rows = _instance_rows(frame, surface.height)
    var dyn = Int(atlas.pages()[].bytes.unsafe_ptr())
    var n = threads
    if n <= 0:
        n = 1 if surface.width * surface.height < 65536 else num_logical_cores()
    n = max(1, min(min(n, CPU_THREADS_MAX), (surface.height + BAND_ROWS - 1) // BAND_ROWS))
    var job = _BandJob(Int(Pointer(to=frame)), Int(Pointer(to=atlas)), surface.address, surface.width, surface.height, surface.scale,
                       Int(rows.unsafe_ptr()), dyn)
    var addr = Int(Pointer(to=job))
    var tids = List[Int](length=n, fill=0)
    var started = 0
    for i in range(n - 1):
        if libc.pthread_create[_band_thread](addr, Int(tids.unsafe_ptr()) + 8 * started) == 0:
            started += 1
    _bands(addr)
    for i in range(started):
        _ = libc.pthread_join(tids[i])
    _ = job.height  # (the job, the rows and the frame live until every thread has joined)
    _ = len(rows)
    _ = len(tids)
