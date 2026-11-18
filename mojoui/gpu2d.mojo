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
#   6–7  (0, 0)         reserved
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
from mojoui.scene import Scene, OP_RECT, OP_CIRCLE, OP_LINE, OP_TEXT, OP_FILL, OP_CLIP, OP_UNCLIP, OP_IMAGE, OP_POLY

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

    def __init__(out self, font: Font):
        var w = max(max(max(font.regular.width, font.medium.width), max(font.display.width, font.mono.width)), font.mono_bold.width)
        var rows = [_rows(font.regular), _rows(font.medium), _rows(font.display), _rows(font.mono), _rows(font.mono_bold)]
        var ys = List[Int]()
        var y = 1
        for f in range(FACES):
            ys.append(y)
            y += rows[f] + 1
        self.width = w + 2
        self.height = y
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
          c0: Float64, c1: Float64, c2: Float64, c3: Float64):
    out.append(Float32(a))
    out.append(Float32(b))
    out.append(Float32(c))
    out.append(Float32(d))
    out.append(Float32(radius))
    out.append(Float32(shape))
    out.append(0)
    out.append(0)
    _color(out, color)
    _clip4(out, c0, c1, c2, c3)


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
    """build_batches into an existing frame, reusing its memory (a host keeps one Frame2D)."""
    fill_layers(f, scene, atlas, font, 0, scene.layers())


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


def fill_layers(mut f: Frame2D, scene: Scene, atlas: GlyphAtlas, font: Font, first: Int, end: Int, skip_ops: Int = 0):
    """build_batches of layers [first, end) only, into f (emptied first): a host that keeps each layer's batches
    rebuilds just the layers that changed. Clips that earlier layers left open still cut these, as in the whole frame.
    skip_ops: layer `first`'s first ops left out (a layer that only grew, Scene.appends: just the new ops; the ops left
    out must leave no clip open)."""
    f.clear()
    f.width = scene.w
    f.height = scene.h
    f.scale = scene.k
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
        var ik = 1.0 / tk if tk != 0 else 1.0
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
        for op in range(span[0] + (skip_ops if layer == first else 0), span[1]):
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
                var lo = 0
                var hi = n - 1
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
                    _quad(f.quads, a, b, c, d, e, SHAPE_BOX, color, c0, c1, c2, c3)
                elif kind == OP_CIRCLE:
                    _quad(f.quads, a, b, a, b, c, SHAPE_CAPSULE, color, c0, c1, c2, c3)
                elif kind == OP_LINE:
                    _quad(f.quads, a, b, c, d, e / 2, SHAPE_CAPSULE, color, c0, c1, c2, c3)
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


def _cpu_image(mut s: Surface, frame: Frame2D, q: List[Float32], at: Int, tx: Float64, ty: Float64, tk: Float64):
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
            p.unsafe_offset(py * s.width + qx)[] = px[sy * pw + sx]


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
                    _cpu_image(surface, frame, frame.images, i * IMAGE_FLOATS, tx, ty, tk)
                else:
                    _cpu_poly(surface, frame, i * POLY_FLOATS, tx, ty, tk, scratch)
