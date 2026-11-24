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
# IMAGE (IMAGE_FLOATS = 12): pixels made elsewhere, scaled into a rect, BLEND_REPLACE (nearest, as blit).
#   0–3  x, y, w, h
#   4    which          index into Frame2D.pixels (a copy of the scene's images, rows of pw RGBA UInt32)
#   5–6  pw, ph
#   7    0              reserved
#   8–11 clip x0, y0, x1, y1
#   A pixel whose centre is in the rect samples texel floor((centre − x) / w · pw) (and the same in y).
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
from mojoui.fonttext import engine as font_engine, shape as ft_shape, run_x, GlyphImage
from mojoui.shared import get_shared, put_shared
from std.memory import Pointer
from std.memory.alloc import alloc, Layout
from std.collections import Dict
from mojoui.scene import Scene, OP_RECT, OP_CIRCLE, OP_LINE, OP_TEXT, OP_FILL, OP_CLIP, OP_UNCLIP, OP_IMAGE, OP_POLY, OP_RUN, OP_STROKE

comptime PIPE_QUAD = 0
comptime PIPE_GLYPH = 1
comptime PIPE_IMAGE = 2
comptime PIPE_POLY = 3

comptime QUAD_FLOATS = 16
comptime GLYPH_FLOATS = 20
comptime IMAGE_FLOATS = 12
comptime POLY_FLOATS = 16

comptime SHAPE_BOX = 0
comptime SHAPE_CAPSULE = 1

comptime BLEND_REPLACE = 0
comptime BLEND_OVER = 1

comptime NO_CLIP = 1.0e30  # a clip edge this far out (or further) means no clip on that side
comptime POLY_SUB = 4  # scan lines per pixel row for polygons (draw.polygon's)
comptime FACES = 5  # Font.pick's faces: 0 regular, 1 medium, 2 display, 3 mono, 4 mono bold


comptime DYN_ROWS = 2048  # rows of the atlas kept for mojoui.fonttext's glyphs (goal 79), packed as they're first drawn
comptime SLOT_GLYPH_PAGES = 232  # mojoui.shared slot: the process's GlyphPages


struct GlyphPages(Movable):
    """fonttext's glyphs (coverage, rasterized at device px by the platform's engine) packed in shelves into the atlas's
    dynamic rows, once per (face, instance, glyph, device size, subpixel x): keyed by fonttext's own image index. One per
    process, shared by every canvas; a backend uploads rows [0, used) again whenever `version` moves (D-7910)."""
    var width: Int
    var bytes: List[UInt8]
    var slot_of: Dict[Int, Int]
    var sx: List[Int]
    var sy: List[Int]
    var shelf_x: Int
    var shelf_y: Int
    var shelf_h: Int
    var used: Int  # rows holding glyphs
    var version: Int
    var resets: Int
    var straight_of: Dict[Int, Int]  # a colour glyph (engine image × 256 + the run's alpha) → its straight-alpha pixels
    var straight_px: List[List[UInt32]]

    def __init__(out self, width: Int):
        self.width = width
        self.bytes = List[UInt8](length=width * DYN_ROWS, fill=0)
        self.slot_of = Dict[Int, Int]()
        self.sx = List[Int]()
        self.sy = List[Int]()
        self.shelf_x = 1
        self.shelf_y = 1
        self.shelf_h = 0
        self.used = 0
        self.version = 0
        self.resets = 0
        self.straight_of = Dict[Int, Int]()
        self.straight_px = List[List[UInt32]]()

    def straight(mut self, image: Int, alpha: Int, rgba: List[UInt32]) -> List[UInt32]:
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
            self.straight_px.append(pix^)
            at = len(self.straight_px) - 1
            self.straight_of[key] = at
        return self.straight_px[at].copy()

    def place(mut self, key: Int, img: GlyphImage) -> Int:
        """The glyph's slot (packing it on first use, a column and a row of zeros around it)."""
        if key in self.slot_of:
            return self.slot_of.get(key, 0)
        var w = img.w
        var h = img.h
        if self.shelf_x + w + 1 > self.width:
            self.shelf_y += self.shelf_h + 1
            self.shelf_x = 1
            self.shelf_h = 0
        if self.shelf_y + h + 1 > DYN_ROWS:  # full: start again (glyphs pack again as they're drawn)
            for i in range(len(self.bytes)):
                self.bytes[i] = 0
            self.slot_of = Dict[Int, Int]()
            self.sx.clear()
            self.sy.clear()
            self.shelf_x = 1
            self.shelf_y = 1
            self.shelf_h = 0
            self.resets += 1
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
        self.slot_of[key] = len(self.sx) - 1
        self.version += 1
        return len(self.sx) - 1


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

    def at(self, x: Int, y: Int) -> Float64:
        if x < 0 or y < 0 or x >= self.width or y >= self.height:
            return 0
        if y >= self.dyn_y0:
            var pg = glyph_pages(self.width)
            return Float64(Int(pg[].bytes[(y - self.dyn_y0) * self.width + x])) / 255.0
        return Float64(Int(self.bytes[y * self.width + x])) / 255.0

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
    var pixels: List[List[UInt32]]  # IMAGE's pixels (the scene's images)

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
        self.pixels = List[List[UInt32]]()

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
        self.pixels.clear()

    def instances(self, pipe: Int) -> Int:
        """How many instances pipeline `pipe` has in the frame."""
        if pipe == PIPE_QUAD:
            return len(self.quads) // QUAD_FLOATS
        if pipe == PIPE_GLYPH:
            return len(self.glyphs) // GLYPH_FLOATS
        if pipe == PIPE_IMAGE:
            return len(self.images) // IMAGE_FLOATS
        return len(self.polys) // POLY_FLOATS


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
          c0: Float64, c1: Float64, c2: Float64, c3: Float64, hole: Float64 = 0):
    out.append(Float32(a))
    out.append(Float32(b))
    out.append(Float32(c))
    out.append(Float32(d))
    out.append(Float32(radius))
    out.append(Float32(shape))
    out.append(Float32(hole))  # (D-7973: the middle a box may leave out, its units)
    out.append(0)
    _color(out, color)
    _clip4(out, c0, c1, c2, c3)


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
            color: UInt32, slant: Float64, c0: Float64, c1: Float64, c2: Float64, c3: Float64):
    """One GLYPH instance per glyph with pixels, the pen moving as Face.draw's."""
    var s = size / face.size
    var pen = x
    for ch in text.codepoints():
        var gi = face.find(Int(ch.to_u32()))
        if gi < 0:
            continue
        ref g = face.glyphs[gi]
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


def build_batches(scene: Scene, atlas: GlyphAtlas, font: Font) -> Frame2D:
    """The scene as GPU work (see the top of this file)."""
    var f = Frame2D()
    fill_batches(f, scene, atlas, font)
    return f^


def fill_batches(mut f: Frame2D, scene: Scene, atlas: GlyphAtlas, font: Font):
    """build_batches into an existing frame, reusing its memory (a host keeps one Frame2D). When GlyphPages fill and
    start again while it builds, the glyphs placed before that are gone: the frame is built once more (D-7930)."""
    var pg = glyph_pages(atlas.width)
    var r0 = pg[].resets
    fill_layers(f, scene, atlas, font, 0, scene.layers())
    if pg[].resets != r0:
        var r1 = pg[].resets
        fill_layers(f, scene, atlas, font, 0, scene.layers())
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


def fill_layers(mut f: Frame2D, scene: Scene, atlas: GlyphAtlas, font: Font, first: Int, end: Int, skip_ops: Int = 0,
                only: List[Int] = List[Int](), content_k: Float64 = 0, part: List[Float64] = List[Float64]()):
    """build_batches of layers [first, end) only, into f (emptied first): a host that keeps each layer's batches
    rebuilds just the layers that changed. Clips that earlier layers left open still cut these, as in the whole frame.
    skip_ops: layer `first`'s first ops left out (a layer that only grew, Scene.appends: just the new ops; the ops left
    out must leave no clip open). content_k > 0 (D-7940, a raster tile): just the ops in `only` of layer `first`
    (offsets from its first op, ascending, no clips or images among them; empty: none), built as if the layer were drawn at zoom
    content_k with no translation (glyphs rasterized and snapped for that zoom; a tile moves it by whole pixels).
    part (D-8022; with content_k): the rect (x0, y0, x1, y1, the layer's units, antialiasing padded) that will be drawn:
    boxes, capsules and glyphs wholly outside it aren't built (a long stroke's, a big shadow's, a paragraph's others)."""
    f.clear()
    f.width = scene.w
    f.height = scene.h
    f.scale = scene.k
    if content_k <= 0:  # (a tile's layer has no OP_IMAGE: its only pixels are colour glyphs, added as they come)
        for ref px in scene.images:
            f.pixels.append(px.copy())
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
        var cull = subset and len(part) == 4
        var q0 = part[0] if cull else -NO_CLIP
        var q1 = part[1] if cull else -NO_CLIP
        var q2 = part[2] if cull else NO_CLIP
        var q3 = part[3] if cull else NO_CLIP
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
                    _glyphs(f.glyphs, font.regular, ox, oy, text, pen, b, c, color, d, c0, c1, c2, c3)
                elif fi == 1:
                    _glyphs(f.glyphs, font.medium, ox, oy, text, pen, b, c, color, d, c0, c1, c2, c3)
                elif fi == 2:
                    _glyphs(f.glyphs, font.display, ox, oy, text, pen, b, c, color, d, c0, c1, c2, c3)
                elif fi == 3:
                    _glyphs(f.glyphs, font.mono, ox, oy, text, pen, b, c, color, d, c0, c1, c2, c3)
                else:
                    _glyphs(f.glyphs, font.mono_bold, ox, oy, text, pen, b, c, color, d, c0, c1, c2, c3)
                added = len(f.glyphs) // GLYPH_FLOATS - before
            elif kind == OP_RUN:  # (goal 79) fonttext's shaped run: coverage glyphs from GlyphPages, colour ones as images
                var st = scene.run_style(op)
                var r = ft_shape(st, scene.run_text(op))
                var xl = run_x(r, a, scene.run_align(op))
                var eng = font_engine()
                var pg = glyph_pages(atlas.width)
                var size_dev = st.size * tk
                var bdev = b * tk + ty
                var by = Int(bdev + 0.5) if bdev >= 0 else Int(bdev - 0.5)
                var g0 = len(f.glyphs) // GLYPH_FLOATS
                var i0 = len(f.images) // IMAGE_FLOATS
                for ref g in r.glyphs:
                    var gx = (xl + g.x) * tk + tx
                    var px = Int(gx + 0.5) if gx >= 0 else Int(gx - 0.5)
                    var gy = g.y * tk
                    var py = by - (Int(gy + 0.5) if gy >= 0 else Int(gy - 0.5))
                    var ii = eng[].image(g.inst, g.gid, size_dev, 0)
                    if eng[].images[ii].w == 0:
                        continue
                    var iw = eng[].images[ii].w
                    var ih = eng[].images[ii].h
                    var x_l = (Float64(px + eng[].images[ii].left) - tx) * ik
                    var y_l = (Float64(py - eng[].images[ii].top) - ty) * ik
                    if cull and (x_l > q2 or x_l + Float64(iw) * ik < q0 or y_l > q3 or y_l + Float64(ih) * ik < q1):
                        continue
                    if eng[].images[ii].color:
                        var al = Int((color >> 24) & 0xFF)
                        f.pixels.append(pg[].straight(ii, al, eng[].images[ii].rgba))
                        f.images.append(Float32(x_l))
                        f.images.append(Float32(y_l))
                        f.images.append(Float32(Float64(iw) * ik))
                        f.images.append(Float32(Float64(ih) * ik))
                        f.images.append(Float32(len(f.pixels) - 1))
                        f.images.append(Float32(iw))
                        f.images.append(Float32(ih))
                        f.images.append(0)
                        _clip4(f.images, c0, c1, c2, c3)
                    else:
                        var slot = pg[].place(ii, eng[].images[ii])
                        var u0 = pg[].sx[slot]
                        var v0 = atlas.dyn_y0 + pg[].sy[slot]
                        f.glyphs.append(Float32(x_l))
                        f.glyphs.append(Float32(y_l))
                        f.glyphs.append(Float32(Float64(iw) * ik))
                        f.glyphs.append(Float32(Float64(ih) * ik))
                        f.glyphs.append(Float32(u0))
                        f.glyphs.append(Float32(v0))
                        f.glyphs.append(Float32(u0 + iw))
                        f.glyphs.append(Float32(v0 + ih))
                        _color(f.glyphs, color)
                        f.glyphs.append(0)
                        f.glyphs.append(Float32(b))
                        f.glyphs.append(0)
                        f.glyphs.append(0)
                        _clip4(f.glyphs, c0, c1, c2, c3)
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
                var p0 = first * 2
                var pt0 = len(f.points) // 2
                var fan0 = len(f.fan) // 2
                var bx0 = scene.path[p0]
                var by0 = scene.path[p0 + 1]
                var bx1 = bx0
                var by1 = by0
                for z in range(n):
                    var x = scene.path[p0 + 2 * z]
                    var y = scene.path[p0 + 2 * z + 1]
                    f.points.append(x)
                    f.points.append(y)
                    bx0 = min(bx0, x)
                    by0 = min(by0, y)
                    bx1 = max(bx1, x)
                    by1 = max(by1, y)
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
                    ia = ia % n
                    ib = ib % n
                    ic = ic % n
                    if upper:
                        f.fan.append(scene.path[p0 + 2 * ia])
                        f.fan.append(scene.path[p0 + 2 * ia + 1])
                        f.fan.append(scene.path[p0 + 2 * ib])
                        f.fan.append(scene.path[p0 + 2 * ib + 1])
                        f.fan.append(scene.path[p0 + 2 * ic])
                        f.fan.append(scene.path[p0 + 2 * ic + 1])
                    else:
                        f.fan.append(scene.path[p0 + 2 * ic])
                        f.fan.append(scene.path[p0 + 2 * ic + 1])
                        f.fan.append(scene.path[p0 + 2 * ia])
                        f.fan.append(scene.path[p0 + 2 * ia + 1])
                        f.fan.append(scene.path[p0 + 2 * ib])
                        f.fan.append(scene.path[p0 + 2 * ib + 1])
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
                for ref px in scene.images[which]:  # (a picture with see-through pixels is blended over: icons, D-7910)
                    if (px >> 24) != 255:
                        mode = BLEND_OVER
                        break
                var pw = Int(scene.nums[base + 5])
                f.images.append(Float32(a))
                f.images.append(Float32(b))
                f.images.append(Float32(c))
                f.images.append(Float32(d))
                f.images.append(Float32(which))
                f.images.append(Float32(pw))
                f.images.append(Float32(len(scene.images[which]) // pw if pw > 0 else 0))
                f.images.append(0)
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
                        if not cull or (b <= q3 and by >= q1):
                            _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, c1, c2, min(c3, by))
                        if not cull or (b + d >= q1 and by <= q3 and a <= q2 and bx >= q0):
                            _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, max(c1, by), min(c2, bx), c3)
                        if not cull or (b + d >= q1 and by <= q3 and bx <= q2 and a + c >= q0):
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
                            if not cull or (b <= q3 and hy0 >= q1):
                                _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, c1, c2, min(c3, hy0))
                            if not cull or (hy1 <= q3 and b + d >= q1):
                                if not cull or (a <= q2 and bx >= q0):
                                    _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, max(c1, hy1), min(c2, bx), c3)
                                if not cull or (bx <= q2 and a + c >= q0):
                                    _quad(f.quads, a, b, c, d, br, SHAPE_BOX, color, max(c0, bx), max(c1, hy1), c2, c3)
                            if not cull or (hy0 <= q3 and hy1 >= q1):
                                if not cull or (a <= q2 and hx0 >= q0):
                                    _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, max(c1, hy0), min(c2, hx0), min(c3, hy1))
                                if not cull or (hx1 <= q2 and a + c >= q0):
                                    _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, max(c0, hx1), max(c1, hy0), c2, min(c3, cy))
                                    if cy < hy1:
                                        _quad(f.quads, a, b, c, d, br, SHAPE_BOX, color, max(c0, max(hx1, bx)), max(c1, cy), c2, min(c3, hy1))
                                        if bx > hx1:
                                            _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, max(c0, hx1), max(c1, cy), min(c2, bx), min(c3, hy1))
                            added = len(f.quads) // QUAD_FLOATS - before
                        else:
                            if not cull or (b <= q3 and hy0 >= q1):
                                _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, c1, c2, min(c3, hy0))
                            if not cull or (hy1 <= q3 and b + d >= q1):
                                _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, max(c1, hy1), c2, c3)
                            if not cull or (hy0 <= q3 and hy1 >= q1):
                                if not cull or (a <= q2 and hx0 >= q0):
                                    _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, max(c1, hy0), min(c2, hx0), min(c3, hy1))
                                if not cull or (hx1 <= q2 and a + c >= q0):
                                    _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, max(c0, hx1), max(c1, hy0), c2, min(c3, hy1))
                        added = len(f.quads) // QUAD_FLOATS - before
                elif kind == OP_CIRCLE:
                    _quad(f.quads, a, b, a, b, c, SHAPE_CAPSULE, color, c0, c1, c2, c3)
                elif kind == OP_LINE:
                    if not cull or _segment_meets(a, b, c, d, e / 2, q0, q1, q2, q3):
                        _quad(f.quads, a, b, c, d, e / 2, SHAPE_CAPSULE, color, c0, c1, c2, c3)
                    else:
                        added = 0
                elif kind == OP_STROKE:  # (D-7940: the capsules and discs a polyline of lines and circles would make)
                    var p0 = Int(a) * 2
                    var m = Int(b)
                    var hw = c / 2
                    for z in range(m - 1):
                        var ax = Float64(scene.path[p0 + 2 * z])
                        var ay = Float64(scene.path[p0 + 2 * z + 1])
                        var zx = Float64(scene.path[p0 + 2 * z + 2])
                        var zy = Float64(scene.path[p0 + 2 * z + 3])
                        if cull and (max(ax, zx) + hw < q0 or min(ax, zx) - hw > q2 or max(ay, zy) + hw < q1 or min(ay, zy) - hw > q3):
                            continue
                        _quad(f.quads, ax, ay, zx, zy, hw, SHAPE_CAPSULE, color, c0, c1, c2, c3)
                    for z in range(m):
                        var px = Float64(scene.path[p0 + 2 * z])
                        var py = Float64(scene.path[p0 + 2 * z + 1])
                        if cull and (px + hw < q0 or px - hw > q2 or py + hw < q1 or py - hw > q3):
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


def _cpu_quad(mut s: Surface, q: List[Float32], at: Int, tx: Float64, ty: Float64, tk: Float64, mode: Int):
    var color = _u32(q[at + 8], q[at + 9], q[at + 10], q[at + 11])
    var xlo = _lo(Float64(q[at + 12]), tx, tk, s.width)
    var ylo = _lo(Float64(q[at + 13]), ty, tk, s.height)
    var xhi = _hi(Float64(q[at + 14]), tx, tk, s.width)
    var yhi = _hi(Float64(q[at + 15]), ty, tk, s.height)
    var p = s.pixels()
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
            for px in range(x0, x1):
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


def _cpu_glyph(mut s: Surface, atlas: GlyphAtlas, q: List[Float32], at: Int, tx: Float64, ty: Float64, tk: Float64):
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
    var ylo = _lo(Float64(q[at + 17]), ty, tk, s.height)
    var xhi = _hi(Float64(q[at + 18]), tx, tk, s.width)
    var yhi = _hi(Float64(q[at + 19]), ty, tk, s.height)
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
                        cov += atlas.coverage(u0 + ax, v0 + ay)
            cov = cov / Float64(sub * sub) * alpha
            if cov <= 0.003:
                continue
            var dp = p.unsafe_offset(py * s.width + px)
            var d = dp[]
            var nr = UInt32(Int(r * cov + Float64(Int(d & 0xFF)) * (1 - cov) + 0.5))
            var ng = UInt32(Int(gr * cov + Float64(Int((d >> 8) & 0xFF)) * (1 - cov) + 0.5))
            var nb = UInt32(Int(b * cov + Float64(Int((d >> 16) & 0xFF)) * (1 - cov) + 0.5))
            dp[] = nr | (ng << 8) | (nb << 16) | (d & 0xFF000000)


def _cpu_image(mut s: Surface, frame: Frame2D, q: List[Float32], at: Int, tx: Float64, ty: Float64, tk: Float64, mode: Int = BLEND_REPLACE):
    var x = Float64(q[at]) * tk + tx
    var y = Float64(q[at + 1]) * tk + ty
    var w = Float64(q[at + 2]) * tk
    var h = Float64(q[at + 3]) * tk
    var which = Int(q[at + 4])
    var pw = Int(q[at + 5])
    var ph = Int(q[at + 6])
    if w <= 0 or h <= 0 or pw <= 0 or ph <= 0 or which < 0 or which >= len(frame.pixels):
        return
    ref px = frame.pixels[which]
    var x0 = max(Int(ceil(x - 0.5)), _lo(Float64(q[at + 8]), tx, tk, s.width))
    var y0 = max(Int(ceil(y - 0.5)), _lo(Float64(q[at + 9]), ty, tk, s.height))
    var x1 = min(Int(ceil(x + w - 0.5)), _hi(Float64(q[at + 10]), tx, tk, s.width))
    var y1 = min(Int(ceil(y + h - 0.5)), _hi(Float64(q[at + 11]), ty, tk, s.height))
    var p = s.pixels()
    for py in range(max(y0, 0), min(y1, s.height)):
        var sy = min(ph - 1, Int(floor((Float64(py) + 0.5 - y) / h * Float64(ph))))
        for qx in range(max(x0, 0), min(x1, s.width)):
            var sx = min(pw - 1, Int(floor((Float64(qx) + 0.5 - x) / w * Float64(pw))))
            var src = px[sy * pw + sx]
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


def _cpu_poly(mut s: Surface, frame: Frame2D, at: Int, tx: Float64, ty: Float64, tk: Float64, mut sc: _PolyScratch):
    ref q = frame.polys
    var first = Int(q[at + 2])
    var n = Int(q[at + 3])
    if n < 3:
        return
    var color = _u32(q[at + 4], q[at + 5], q[at + 6], q[at + 7])
    var xlo = _lo(Float64(q[at + 12]), tx, tk, s.width)
    var ylo = _lo(Float64(q[at + 13]), ty, tk, s.height)
    var xhi = _hi(Float64(q[at + 14]), tx, tk, s.width)
    var yhi = _hi(Float64(q[at + 15]), ty, tk, s.height)
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


def execute_cpu(frame: Frame2D, atlas: GlyphAtlas, mut surface: Surface):
    """Draws the frame's runs into the surface, in order, each layer through its transform, with the shaders' math
    (top of this file): the reference for a GPU backend's readback, and the fallback."""
    var scratch = _PolyScratch()
    for li in range(len(frame.layers)):
        ref layer = frame.layers[li]
        var tx = layer.dx
        var ty = layer.dy
        var tk = layer.k
        for ri in range(layer.first_run, layer.first_run + layer.runs):
            var run = frame.runs[ri]
            for i in range(run.first, run.first + run.count):
                if run.pipe == PIPE_QUAD:
                    _cpu_quad(surface, frame.quads, i * QUAD_FLOATS, tx, ty, tk, run.blend)
                elif run.pipe == PIPE_GLYPH:
                    _cpu_glyph(surface, atlas, frame.glyphs, i * GLYPH_FLOATS, tx, ty, tk)
                elif run.pipe == PIPE_IMAGE:
                    _cpu_image(surface, frame, frame.images, i * IMAGE_FLOATS, tx, ty, tk, run.blend)
                else:
                    _cpu_poly(surface, frame, i * POLY_FLOATS, tx, ty, tk, scratch)
