# A Canvas's picture as a display list (goal 26, D-252): the drawing code says *what* goes where (rects, lines,
# circles, text runs, in layers) and each host draws it with its own GPU renderer (GTK: render nodes; the web:
# Canvas2D; Apple: Metal). The same drawing code also paints today's CPU Surface, through SurfacePainter, which stays
# the reference (tests, screenshots) and the fallback.
#
#   def draw[P: Painter](mut self, mut p: P, ...):
#       p.begin_layer("cells")
#       p.rect(0, 0, w, h, CARD, 0)
#       p.text(font, "1,204.50", x, baseline, 13, INK, REGULAR, RIGHT, 0)
#       p.begin_layer("ring")        # a layer that moves on its own: the host reuses the cells' nodes untouched
#       ...

from std.collections import Dict
from mojoui.canvas import Surface
from mojoui.draw import rect, line, circle, hline, polygon, blend
from mojoui.shadow import draw_shadow, shadow_reach
from mojoui.text import Font, REGULAR, LEFT
from mojoui.clock import now_ns
from mojoui.fonttext import TextStyle, shape, draw_run, Clip, run_x

comptime OP_RECT = 1  # x, y, w, h, radius, hole (D-7973: > 0 the middle, inside the box shrunk by it, may be left out)
comptime OP_CIRCLE = 2  # x, y, radius
comptime OP_LINE = 3  # x0, y0, x1, y1, width
comptime OP_TEXT = 4  # x, baseline, size, slant, weight, align (+ the text)
comptime OP_FILL = 5  # the whole canvas, one colour (set, not blended)
comptime OP_CLIP = 6  # x, y, w, h: what follows (until OP_UNCLIP) is cut to this rect
comptime OP_UNCLIP = 7
comptime OP_IMAGE = 8  # x, y, w, h, image (pixels made elsewhere: a lens, a video frame), scaled to the rect
comptime OP_POLY = 9  # first point, points (the points in Scene.path, x, y interleaved): a filled polygon, non-zero (goal 40); 2–5: its bounds x0, y0, x1, y1 (goal 80)
comptime OP_STROKE = 11  # first point, points, width (the points in Scene.path): a polyline with round caps and joins (D-7940)
comptime OP_RUN = 10  # x, baseline, size, weight, align·2 + italic, letter spacing (+ "family\x1ftext"): a run in a real face (mojoui.fonttext, goal 79)
comptime OP_SHADOW = 12  # x, y, w, h, radius, blur (CSS's blur radius, 2 sigma): a rounded box's Gaussian shadow (goal 80, mojoui.shadow)
comptime STRIDE = 6  # floats per op


def snap_px(v: Float64) -> Float64:
    """A translation snapped to a whole device pixel (a tiled layer's, D-7940: its kept tiles then land 1:1)."""
    return Float64(Int(v + 0.5)) if v >= 0 else -Float64(Int(-v + 0.5))


struct KeptOps(Copyable, Movable):
    """(D-7963) A run of a layer's ops kept from one frame to replay in a later one (Painter.ops_capture/ops_replay):
    its texts, images and polygon points travel with it, renumbered when it is replayed. An app keeps one with the
    token its ops depend on and replays it while the token holds, instead of drawing the same items again."""

    var ok: Bool
    var kinds: List[UInt8]
    var nums: List[Float32]
    var colors: List[UInt32]
    var text_of: List[Int32]
    var texts: List[String]
    var images: List[List[UInt32]]
    var path: List[Float32]
    var note_ops: List[Int]
    var notes: List[String]
    var from_v: Int  # (D-7987) the source layer's ops version when kept (-1: unknown): a renderer's index of that version still fits them
    var layer_off: Int  # (D-7987) where in that layer the kept run began (ops from the layer's first)

    def __init__(out self):
        self.from_v = -1
        self.layer_off = 0
        self.ok = False
        self.kinds = List[UInt8]()
        self.nums = List[Float32]()
        self.colors = List[UInt32]()
        self.text_of = List[Int32]()
        self.texts = List[String]()
        self.images = List[List[UInt32]]()
        self.path = List[Float32]()
        self.note_ops = List[Int]()
        self.notes = List[String]()

    def ops(self) -> Int:
        return len(self.kinds)


trait Painter:
    """What drawing code paints with: pixels (SurfacePainter) or a display list (Scene). Sizes are pixels."""

    def width(self) -> Int:
        ...

    def height(self) -> Int:
        ...

    def scale(self) -> Float64:
        ...

    def still(self) -> Bool:
        """The person asked for less motion (or a still picture is wanted): animations jump to their end."""
        ...

    def set_again(mut self):
        """Mid-animation: the host draws the next frame too."""
        ...

    def time_ns(self) -> Int:
        """When this frame will be shown (mojoui.clock.now_ns's clock, ns). Animations sample their time here, not from
        the clock: a host may draw a frame ahead of time (D-7560), and then it is shown later than it is drawn."""
        ...

    def begin_layer(mut self, key: String):
        """What follows (until the next layer) is one layer: a host can keep it when it comes again unchanged."""
        ...

    def layer_version(mut self, version: Int):
        """The current layer's version, when the drawing code knows it: the same key and version is the same picture
        (a host reuses it without comparing its items). Unset (or -1): the host compares the items."""
        ...

    def layer_transform(mut self, dx: Float64, dy: Float64, k: Float64):
        """The current layer is shown scaled by k and moved by (dx, dy): a point (x, y) it draws lands at
        (x·k + dx, y·k + dy) (goal 40, D-1202). It isn't part of the layer's picture: a host keeps a layer that came
        again unchanged and only moves it (a pan or a zoom redraws nothing). A new layer starts at no transform."""
        ...

    def layer_tiles(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        """(goal 79, D-7940) The current layer may be kept as raster tiles at its zoom (a big board: a pan or a zoom then
        composites what's kept instead of drawing every item again). Its ops are complete inside this rect of its units
        (items beyond it may be left out: tiles there aren't rastered from this frame). Its translation is snapped to
        whole device pixels, so a kept tile lands 1:1. Call after layer_transform; no clips, fills or replacing images
        in such a layer (a host then draws it directly)."""
        ...

    def layer_damage(mut self, since: Int, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        """(D-7940) Since the layer's version `since`, only what's inside this rect (its units) changed; call once per
        rect, all with the same `since`. A host whose tiles show version `since` rasters again only the tiles these
        meet; with no damage (or another base) a new version invalidates every tile."""
        ...

    def layer_ops_version(mut self, v: Int):
        """(D-7969) The current layer's ops are the same as the last ones given this ops version (its picture's version,
        layer_version, may still move: damage elsewhere). A renderer keeps what it built from the ops (bins) while it
        holds. -1 (the default): the layer version stands for both."""
        ...

    def ops_mark(self) -> Int:
        """(D-7963) How many ops the painter holds now (for ops_capture), -1 when it can't keep ops."""
        ...

    def ops_capture(self, from_op: Int) -> KeptOps:
        """(D-7963) The ops from from_op on, kept to be replayed in a later frame (empty when it can't keep ops)."""
        ...

    def ops_replay_range(mut self, kept: KeptOps, a: Int, b: Int) -> Bool:
        """(D-7974) Kept ops [a, b) appended as if drawn again (False: this painter can't)."""
        ...

    def ops_replay(mut self, kept: KeptOps) -> Bool:
        """(D-7963) Ops kept from an earlier frame appended as if drawn again (False: this painter can't; draw them)."""
        ...

    def layer_snapshot(mut self, path: String, tag: String, hold: Bool, note: String):
        """(D-7956) A tiled layer's last view may be kept in the file at `path` (mojoui.viewsnap) and shown from it the
        next time the layer opens with the same `tag` (the app's: what its picture depends on, e.g. the document's
        revision and the skin; the host adds the zoom, view, size, renderer and build). An empty tag: nothing is kept
        or shown (the layer is being edited). note: the app's own words kept in the file's head (read back before the
        document is: e.g. its page grid, to lay the view out). hold: the layer's ops aren't complete in the view yet (a document still
        loading): the host shows the kept view, if it has one that matches, and rasters nothing from the ops."""
        ...

    def push_clip(mut self, x: Float64, y: Float64, w: Float64, h: Float64):
        """Cuts what follows (until pop_clip) to this rect."""
        ...

    def pop_clip(mut self):
        ...

    def image(mut self, pixels: List[UInt32], pw: Int, ph: Int, x: Float64, y: Float64, w: Float64, h: Float64):
        """Pixels made elsewhere (a GPU kernel's output: the lens, a heat map, a video frame), scaled into the rect."""
        ...

    def note(mut self, meaning: String):
        """What the item just drawn stands for ("cell amount 2"), for the agent host and tests; hosts don't draw it."""
        ...

    def fill(mut self, color: UInt32):
        ...

    def rect(mut self, x: Float64, y: Float64, w: Float64, h: Float64, color: UInt32, radius: Float64):
        ...

    def shadow(mut self, x: Float64, y: Float64, w: Float64, h: Float64, radius: Float64, blur: Float64, color: UInt32):
        """(goal 80) The Gaussian shadow of the rounded box (x, y, w, h): `blur` is CSS's blur radius (2 sigma); the
        shadow reaches 1.5 × blur past the box. Offsets and spread are the caller's: pass the shadow's own box."""
        ...

    def rect_hole(mut self, x: Float64, y: Float64, w: Float64, h: Float64, color: UInt32, radius: Float64, hole: Float64):
        """(D-7973) A rounded rect a caller will cover, inside the box shrunk by `hole`, with something opaque: a
        painter may leave that middle out (the same picture, less fill). The CPU painter draws it whole."""
        ...

    def line(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64, width: Float64, color: UInt32):
        ...

    def circle(mut self, x: Float64, y: Float64, radius: Float64, color: UInt32):
        ...

    def polygon(mut self, pts: List[Float64], color: UInt32):
        """A filled polygon (x, y interleaved, closed implicitly), non-zero winding, anti-aliased: an ink stroke's
        outline (mojoui.ink), a shape."""
        ...

    def stroke(mut self, pts: List[Float64], width: Float64, color: UInt32):
        """(D-7940) A polyline through the points (x, y interleaved) `width` wide with round caps and joins: each
        segment a capsule, each point a disc, as one item (a pen line of 60 points is one op, not 121)."""
        ...

    def text(mut self, font: Font, text: String, x: Float64, baseline: Float64, size: Float64, color: UInt32, weight: Int, align: Int,
             slant: Float64):
        """`text` with its baseline at `baseline`, starting at x (or centred on it, or ending at it: `align`)."""
        ...

    def run(mut self, st: TextStyle, text: String, x: Float64, baseline: Float64, color: UInt32, align: Int):
        """`text` in a real face (mojoui.fonttext: shaped, fallback faces, glyphs rasterized at device pixels), its
        baseline at `baseline`, at x by `align` (fonttext.ALIGN_*). Sizes are the layer's units (layout px)."""
        ...


def blit(mut s: Surface, pixels: List[UInt32], pw: Int, ph: Int, x: Float64, y: Float64, w: Float64, h: Float64):
    """Pixels scaled (nearest) into a rect of the surface."""
    if pw <= 0 or ph <= 0 or w <= 0 or h <= 0:
        return
    var x0 = Int(x)
    var y0 = Int(y)
    for dy in range(Int(h)):
        var sy = min(ph - 1, Int(Float64(dy) * Float64(ph) / h))
        for dx in range(Int(w)):
            var sx = min(pw - 1, Int(Float64(dx) * Float64(pw) / w))
            var src = pixels[sy * pw + sx]
            var a = (src >> 24) & 0xFF
            if a == 255:
                s.set(x0 + dx, y0 + dy, src)
            elif a > 0:  # (straight alpha over what's there: icons, glyph-like pictures; goal 79)
                s.set(x0 + dx, y0 + dy, blend(s.get(x0 + dx, y0 + dy), src, 1.0))


struct SurfacePainter(Painter, Movable):
    """Paints into pixels, exactly as before the Scene (the reference and the fallback)."""

    var s: Surface
    var tx: Float64  # the current layer's transform (layer_transform)
    var ty: Float64
    var tk: Float64
    var clips: List[Clip]  # push_clip's rects in device px (runs honour them; goal 79)

    def __init__(out self, var s: Surface):
        self.s = s^
        self.tx = 0
        self.ty = 0
        self.tk = 1
        self.clips = List[Clip]()

    def width(self) -> Int:
        return self.s.width

    def height(self) -> Int:
        return self.s.height

    def scale(self) -> Float64:
        return self.s.scale

    def still(self) -> Bool:
        return self.s.still

    def set_again(mut self):
        self.s.again = True

    def time_ns(self) -> Int:
        return now_ns()

    def begin_layer(mut self, key: String):
        self.tx = 0
        self.ty = 0
        self.tk = 1

    def layer_version(mut self, version: Int):
        pass

    def layer_transform(mut self, dx: Float64, dy: Float64, k: Float64):
        self.tx = dx
        self.ty = dy
        self.tk = k

    def layer_tiles(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        self.tx = snap_px(self.tx)  # (as the Scene does: the same picture on every path)
        self.ty = snap_px(self.ty)

    def layer_damage(mut self, since: Int, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        pass

    def layer_ops_version(mut self, v: Int):
        pass

    def ops_mark(self) -> Int:
        return -1

    def ops_capture(self, from_op: Int) -> KeptOps:
        return KeptOps()

    def ops_replay_range(mut self, kept: KeptOps, a: Int, b: Int) -> Bool:
        return False

    def ops_replay(mut self, kept: KeptOps) -> Bool:
        return False

    def layer_snapshot(mut self, path: String, tag: String, hold: Bool, note: String):
        pass

    def push_clip(mut self, x: Float64, y: Float64, w: Float64, h: Float64):
        var k = self.tk
        var c = Clip(Int(x * k + self.tx + 0.5), Int(y * k + self.ty + 0.5), Int((x + w) * k + self.tx + 0.5), Int((y + h) * k + self.ty + 0.5))
        if len(self.clips) > 0:
            ref o = self.clips[len(self.clips) - 1]
            c = Clip(max(c.x0, o.x0), max(c.y0, o.y0), min(c.x1, o.x1), min(c.y1, o.y1))
        self.clips.append(c)
        self._cut()

    def pop_clip(mut self):
        if len(self.clips) > 0:
            _ = self.clips.pop()
        self._cut()

    def _cut(mut self):
        """Every primitive honours the innermost clip (the GPU renderer's scissor does the same)."""
        var c = self.clip()
        self.s.clip_x0 = c.x0
        self.s.clip_y0 = c.y0
        self.s.clip_x1 = c.x1
        self.s.clip_y1 = c.y1

    def clip(self) -> Clip:
        if len(self.clips) > 0:
            return self.clips[len(self.clips) - 1]
        return Clip(0, 0, self.s.width, self.s.height)

    def run(mut self, st: TextStyle, text: String, x: Float64, baseline: Float64, color: UInt32, align: Int):
        if text == "":
            return
        var r = shape(st, text)
        var k = self.tk
        draw_run(self.s, r, run_x(r, x, align) * k + self.tx, baseline * k + self.ty, k, color, self.clip())

    def image(mut self, pixels: List[UInt32], pw: Int, ph: Int, x: Float64, y: Float64, w: Float64, h: Float64):
        blit(self.s, pixels, pw, ph, x * self.tk + self.tx, y * self.tk + self.ty, w * self.tk, h * self.tk)

    def note(mut self, meaning: String):
        pass

    def fill(mut self, color: UInt32):
        self.s.fill(color)

    def rect(mut self, x: Float64, y: Float64, w: Float64, h: Float64, color: UInt32, radius: Float64):
        var k = self.tk
        rect(self.s, x * k + self.tx, y * k + self.ty, w * k, h * k, color, radius * k)

    def shadow(mut self, x: Float64, y: Float64, w: Float64, h: Float64, radius: Float64, blur: Float64, color: UInt32):
        var k = self.tk
        draw_shadow(self.s, x * k + self.tx, y * k + self.ty, w * k, h * k, radius * k, blur / 2 * k, color)

    def rect_hole(mut self, x: Float64, y: Float64, w: Float64, h: Float64, color: UInt32, radius: Float64, hole: Float64):
        self.rect(x, y, w, h, color, radius)

    def line(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64, width: Float64, color: UInt32):
        var k = self.tk
        line(self.s, x0 * k + self.tx, y0 * k + self.ty, x1 * k + self.tx, y1 * k + self.ty, width * k, color)

    def circle(mut self, x: Float64, y: Float64, radius: Float64, color: UInt32):
        circle(self.s, x * self.tk + self.tx, y * self.tk + self.ty, radius * self.tk, color)

    def polygon(mut self, pts: List[Float64], color: UInt32):
        polygon(self.s, pts, color, self.tx, self.ty, self.tk)

    def stroke(mut self, pts: List[Float64], width: Float64, color: UInt32):
        var k = self.tk
        for i in range(0, len(pts) - 2, 2):
            line(self.s, pts[i] * k + self.tx, pts[i + 1] * k + self.ty, pts[i + 2] * k + self.tx, pts[i + 3] * k + self.ty, width * k, color)
        for i in range(0, len(pts) - 1, 2):
            circle(self.s, pts[i] * k + self.tx, pts[i + 1] * k + self.ty, width / 2 * k, color)

    def text(mut self, font: Font, text: String, x: Float64, baseline: Float64, size: Float64, color: UInt32, weight: Int, align: Int,
             slant: Float64):
        var k = self.tk
        font.draw(self.s, text, x * k + self.tx, baseline * k + self.ty, size * k, color, weight, align, slant)


struct Scene(Painter, Movable, Copyable):
    """A display list: ops in order, STRIDE floats each, a colour each, a text for text ops; layers are runs of ops."""

    var w: Int
    var h: Int
    var k: Float64
    var is_still: Bool
    var again: Bool
    var t_ns: Int  # when the frame will be shown (now_ns's clock), set by a host; 0: now (time_ns reads the clock)
    var kinds: List[UInt8]
    var nums: List[Float32]
    var colors: List[UInt32]
    var text_of: List[Int32]  # the op's text (index into texts), or -1
    var texts: List[String]
    var layer_keys: List[String]
    var layer_starts: List[Int]  # the first op of each layer
    var layer_versions: List[Int]  # each layer's version (-1: compare its items)
    var images: List[List[UInt32]]  # OP_IMAGE's pixels (num 4 = which, num 5 = its width; height = len / width)
    var path: List[Float32]  # OP_POLY's points, x, y interleaved (num 0 = the first point's index, num 1 = how many)
    var layer_tx: List[Float64]  # each layer's transform (layer_transform; not part of its picture: same_layer ignores it)
    var layer_ty: List[Float64]
    var layer_tk: List[Float64]
    var note_ops: List[Int]  # the ops that carry a meaning, and the meanings
    var notes: List[String]
    var layer_tiled: List[Bool]  # (D-7940) layer_tiles: kept as raster tiles; its extent (x0, y0, x1, y1 per layer)
    var layer_ext: List[Float64]
    var layer_since: List[Int]  # layer_damage's base version (-1: no damage given), and the rects (layer, x0, y0, x1, y1)
    var layer_snap: List[String]  # (D-7956) layer_snapshot: the file, the app's tag, and whether its ops are still coming
    var layer_snap_tag: List[String]
    var layer_hold: List[Bool]
    var layer_opsv: List[Int]  # (D-7969) layer_ops_version (-1: none given)
    var layer_reuse_v: List[Int]  # (D-7987) the ops version every replayed run in the layer was kept at (-1: none, -2: several)
    var reuse: List[Int]  # (D-7987) replayed runs: layer, offset in it, offset in the kept version's layer, count (4 per run)
    var layer_snap_note: List[String]  # (written in the snapshot's head for the app to read back first: its page grid)
    var dmg_layer: List[Int]
    var dmg: List[Float64]

    def __init__(out self, width: Int, height: Int, scale: Float64):
        self.w = width
        self.h = height
        self.k = scale
        self.is_still = False
        self.again = False
        self.t_ns = 0
        self.kinds = List[UInt8](capacity=4096)
        self.nums = List[Float32](capacity=4096 * STRIDE)
        self.colors = List[UInt32](capacity=4096)
        self.text_of = List[Int32](capacity=4096)
        self.texts = List[String](capacity=1024)
        self.layer_keys = List[String]()
        self.layer_starts = List[Int]()
        self.layer_versions = List[Int]()
        self.images = List[List[UInt32]]()
        self.path = List[Float32](capacity=4096)
        self.layer_tx = List[Float64]()
        self.layer_ty = List[Float64]()
        self.layer_tk = List[Float64]()
        self.note_ops = List[Int]()
        self.notes = List[String]()
        self.layer_tiled = List[Bool]()
        self.layer_ext = List[Float64]()
        self.layer_since = List[Int]()
        self.layer_snap = List[String]()
        self.layer_snap_tag = List[String]()
        self.layer_hold = List[Bool]()
        self.layer_snap_note = List[String]()
        self.layer_opsv = List[Int]()
        self.layer_reuse_v = List[Int]()
        self.reuse = List[Int]()
        self.dmg_layer = List[Int]()
        self.dmg = List[Float64]()

    def reset(mut self, width: Int, height: Int, scale: Float64):
        """Empty again for the next frame, keeping the memory (a host recycles last frame's list)."""
        self.w = width
        self.h = height
        self.k = scale
        self.is_still = False
        self.again = False
        self.t_ns = 0
        self.kinds.clear()
        self.nums.clear()
        self.colors.clear()
        self.text_of.clear()
        self.texts.clear()
        self.layer_keys.clear()
        self.layer_starts.clear()
        self.layer_versions.clear()
        self.images.clear()
        self.path.clear()
        self.layer_tx.clear()
        self.layer_ty.clear()
        self.layer_tk.clear()
        self.note_ops.clear()
        self.notes.clear()
        self.layer_tiled.clear()
        self.layer_ext.clear()
        self.layer_since.clear()
        self.layer_snap.clear()
        self.layer_snap_tag.clear()
        self.layer_hold.clear()
        self.layer_snap_note.clear()
        self.layer_opsv.clear()
        self.layer_reuse_v.clear()
        self.reuse.clear()
        self.dmg_layer.clear()
        self.dmg.clear()

    def width(self) -> Int:
        return self.w

    def height(self) -> Int:
        return self.h

    def scale(self) -> Float64:
        return self.k

    def still(self) -> Bool:
        return self.is_still

    def set_again(mut self):
        self.again = True

    def time_ns(self) -> Int:
        return self.t_ns if self.t_ns > 0 else now_ns()

    def ops(self) -> Int:
        return len(self.kinds)

    def begin_layer(mut self, key: String):
        self.layer_keys.append(key)
        self.layer_starts.append(len(self.kinds))
        self.layer_versions.append(-1)
        self.layer_tx.append(0)
        self.layer_ty.append(0)
        self.layer_tk.append(1)
        self.layer_tiled.append(False)
        for _ in range(4):
            self.layer_ext.append(0)
        self.layer_since.append(-1)
        self.layer_snap.append("")
        self.layer_snap_tag.append("")
        self.layer_hold.append(False)
        self.layer_snap_note.append("")
        self.layer_opsv.append(-1)
        self.layer_reuse_v.append(-1)

    def layer_tiles(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        if len(self.layer_keys) == 0:
            self.begin_layer("")
        var i = len(self.layer_keys) - 1
        self.layer_tiled[i] = True
        self.layer_ext[4 * i] = x0
        self.layer_ext[4 * i + 1] = y0
        self.layer_ext[4 * i + 2] = x1
        self.layer_ext[4 * i + 3] = y1
        self.layer_tx[i] = snap_px(self.layer_tx[i])
        self.layer_ty[i] = snap_px(self.layer_ty[i])

    def layer_damage(mut self, since: Int, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        if len(self.layer_keys) == 0:
            return
        var i = len(self.layer_keys) - 1
        if self.layer_since[i] != -1 and self.layer_since[i] != since:
            self.layer_since[i] = -2  # (two bases: no usable damage, every tile goes)
            return
        if self.layer_since[i] == -2:
            return
        self.layer_since[i] = since
        self.dmg_layer.append(i)
        self.dmg.append(x0)
        self.dmg.append(y0)
        self.dmg.append(x1)
        self.dmg.append(y1)

    def layer_ops_version(mut self, v: Int):
        if len(self.layer_keys) > 0:
            self.layer_opsv[len(self.layer_keys) - 1] = v

    def ops_mark(self) -> Int:
        return len(self.kinds)

    def ops_capture(self, from_op: Int) -> KeptOps:
        var k = KeptOps()
        k.ok = True
        if len(self.layer_keys) > 0:  # (D-7987) which version of the layer these ops belong to, and where in it they began
            var li = len(self.layer_keys) - 1
            k.from_v = self.layer_opsv[li] if self.layer_opsv[li] >= 0 else self.layer_versions[li]
            k.layer_off = from_op - self.layer_range(li)[0]
        var n = len(self.kinds)
        var imap = Dict[Int, Int]()
        for op in range(from_op, n):
            var kind = Int(self.kinds[op])
            k.kinds.append(self.kinds[op])
            for c in range(STRIDE):
                k.nums.append(self.nums[op * STRIDE + c])
            k.colors.append(self.colors[op])
            var t = Int(self.text_of[op])
            if t >= 0:
                k.text_of.append(Int32(len(k.texts)))
                k.texts.append(self.texts[t])
            else:
                k.text_of.append(-1)
            var b = (op - from_op) * STRIDE
            if kind == OP_IMAGE:
                var im = Int(self.nums[op * STRIDE + 4])
                if im not in imap:
                    imap[im] = len(k.images)
                    k.images.append(self.images[im].copy())
                k.nums[b + 4] = Float32(imap.get(im, 0))
            elif kind == OP_POLY or kind == OP_STROKE:
                var first = Int(self.nums[op * STRIDE])
                var cnt = Int(self.nums[op * STRIDE + 1])
                k.nums[b] = Float32(len(k.path) // 2)
                for q in range(2 * first, 2 * (first + cnt)):
                    k.path.append(self.path[q])
        for q in range(len(self.note_ops)):
            if self.note_ops[q] >= from_op:
                k.note_ops.append(self.note_ops[q] - from_op)
                k.notes.append(self.notes[q])
        return k^

    def ops_replay_range(mut self, kept: KeptOps, a: Int, b: Int) -> Bool:
        if not kept.ok or a < 0 or b > len(kept.kinds) or a > b:
            return False
        if len(self.layer_keys) == 0:
            self.begin_layer("")
        var base = len(self.kinds)
        self._reused(kept, base, a, b - a)
        var nb = len(self.nums)
        for op in range(a, b):
            var kind = Int(kept.kinds[op])
            self.kinds.append(kept.kinds[op])
            for c in range(STRIDE):
                self.nums.append(kept.nums[op * STRIDE + c])
            self.colors.append(kept.colors[op])
            var t = Int(kept.text_of[op])
            if t >= 0:
                self.text_of.append(Int32(len(self.texts)))
                self.texts.append(kept.texts[t])
            else:
                self.text_of.append(-1)
            var at = nb + (op - a) * STRIDE
            if kind == OP_IMAGE:
                self.nums[at + 4] = Float32(len(self.images))
                self.images.append(kept.images[Int(kept.nums[op * STRIDE + 4])].copy())
            elif kind == OP_POLY or kind == OP_STROKE:
                var first = Int(kept.nums[op * STRIDE])
                var cnt = Int(kept.nums[op * STRIDE + 1])
                self.nums[at] = Float32(len(self.path) // 2)
                for q in range(2 * first, 2 * (first + cnt)):
                    self.path.append(kept.path[q])
        var lo = 0  # (notes are kept in op order: the first at or after a, by halves)
        var hi = len(kept.note_ops)
        while lo < hi:
            var mid = (lo + hi) // 2
            if kept.note_ops[mid] < a:
                lo = mid + 1
            else:
                hi = mid
        var q = lo
        while q < len(kept.note_ops) and kept.note_ops[q] < b:
            self.note_ops.append(kept.note_ops[q] - a + base)
            self.notes.append(kept.notes[q])
            q += 1
        return True

    def _reused(mut self, kept: KeptOps, base: Int, a: Int, n: Int):
        """(D-7987) Kept ops [a, a + n) now at op `base` of the current layer: a renderer whose index was built from the
        version they were kept at may take their boxes from it instead of measuring them again."""
        var li = len(self.layer_keys) - 1
        if li < 0 or n <= 0:
            return
        if kept.from_v < 0:
            self.layer_reuse_v[li] = -2
            return
        if self.layer_reuse_v[li] == -1:
            self.layer_reuse_v[li] = kept.from_v
        elif self.layer_reuse_v[li] != kept.from_v:
            self.layer_reuse_v[li] = -2
            return
        var dst = base - self.layer_range(li)[0]
        var src = a + kept.layer_off
        var r = len(self.reuse)
        if r >= 4 and self.reuse[r - 4] == li and self.reuse[r - 3] + self.reuse[r - 1] == dst and self.reuse[r - 2] + self.reuse[r - 1] == src:
            self.reuse[r - 1] += n  # (one run with the one before it)
            return
        self.reuse += [li, dst, src, n]

    def reuse_of(self, i: Int) -> List[Int]:
        """(D-7987) Layer i's replayed runs as (offset in the layer, offset in the kept version's layer, count) triples,
        all kept at version layer_reuse_v[i]; empty when none, or when they came from several versions."""
        var out = List[Int]()
        if i >= len(self.layer_reuse_v) or self.layer_reuse_v[i] < 0:
            return out^
        for q in range(len(self.reuse) // 4):
            if self.reuse[4 * q] == i:
                out += [self.reuse[4 * q + 1], self.reuse[4 * q + 2], self.reuse[4 * q + 3]]
        return out^

    def ops_replay(mut self, kept: KeptOps) -> Bool:
        if not kept.ok:
            return False
        if len(self.layer_keys) == 0:
            self.begin_layer("")
        var base = len(self.kinds)
        self._reused(kept, base, 0, len(kept.kinds))
        var t0 = len(self.texts)
        var i0 = len(self.images)
        var p0 = len(self.path) // 2
        self.kinds += kept.kinds.copy()
        var nb = len(self.nums)
        self.nums += kept.nums.copy()
        self.colors += kept.colors.copy()
        for t in kept.text_of:
            self.text_of.append(Int32(Int(t) + t0) if t >= 0 else Int32(-1))
        for op in range(len(kept.kinds)):
            var kind = Int(kept.kinds[op])
            if kind == OP_IMAGE:
                self.nums[nb + op * STRIDE + 4] += Float32(i0)
            elif kind == OP_POLY or kind == OP_STROKE:
                self.nums[nb + op * STRIDE] += Float32(p0)
        self.texts += kept.texts.copy()
        for im in kept.images:
            self.images.append(im.copy())
        self.path += kept.path.copy()
        for q in range(len(kept.note_ops)):
            self.note_ops.append(kept.note_ops[q] + base)
            self.notes.append(kept.notes[q])
        return True

    def layer_snapshot(mut self, path: String, tag: String, hold: Bool, note: String):
        if len(self.layer_keys) == 0:
            return
        var i = len(self.layer_keys) - 1
        self.layer_snap[i] = path
        self.layer_snap_tag[i] = tag
        self.layer_hold[i] = hold
        self.layer_snap_note[i] = note

    def damage_of(self, i: Int) -> List[Float64]:
        """Layer i's damage rects (x0, y0, x1, y1 each), in its units."""
        var out = List[Float64]()
        for d in range(len(self.dmg_layer)):
            if self.dmg_layer[d] == i:
                for c in range(4):
                    out.append(self.dmg[4 * d + c])
        return out^

    def layer_version(mut self, version: Int):
        if len(self.layer_versions) > 0:
            self.layer_versions[len(self.layer_versions) - 1] = version

    def layer_transform(mut self, dx: Float64, dy: Float64, k: Float64):
        if len(self.layer_keys) == 0:
            self.begin_layer("")
        var i = len(self.layer_keys) - 1
        self.layer_tx[i] = dx
        self.layer_ty[i] = dy
        self.layer_tk[i] = k

    def moved(self, i: Int) -> Bool:
        """Whether layer i is shown with a transform (not as drawn)."""
        return self.layer_tx[i] != 0 or self.layer_ty[i] != 0 or self.layer_tk[i] != 1

    def push_clip(mut self, x: Float64, y: Float64, w: Float64, h: Float64):
        self._op(OP_CLIP, x, y, w, h, 0, 0, 0, -1)

    def pop_clip(mut self):
        self._op(OP_UNCLIP, 0, 0, 0, 0, 0, 0, 0, -1)

    def image(mut self, pixels: List[UInt32], pw: Int, ph: Int, x: Float64, y: Float64, w: Float64, h: Float64):
        if pw <= 0 or ph <= 0 or len(pixels) < pw * ph:
            return
        var exact = List[UInt32](capacity=pw * ph)  # (exactly pw × ph: a replay reads the height back as len / pw)
        for k in range(pw * ph):
            exact.append(pixels[k])
        self.images.append(exact^)
        self._op(OP_IMAGE, x, y, w, h, Float64(len(self.images) - 1), Float64(pw), 0, -1)

    def note(mut self, meaning: String):
        if len(self.kinds) > 0:
            self.note_ops.append(len(self.kinds) - 1)
            self.notes.append(meaning)

    def meaning_of(self, op: Int) -> String:
        """What op `op` stands for ("" when it carries no note)."""
        for k in range(len(self.note_ops)):
            if self.note_ops[k] == op:
                return self.notes[k]
        return ""

    def layers(self) -> Int:
        return len(self.layer_keys)

    def layer_range(self, i: Int) -> Tuple[Int, Int]:
        """Layer i's ops: [first, end). Ops before the first layer belong to layer 0 (a scene with no layers is one)."""
        var first = 0 if i == 0 else self.layer_starts[i]
        var end = self.layer_starts[i + 1] if i + 1 < len(self.layer_starts) else len(self.kinds)
        return (first, end)

    def _op(mut self, kind: Int, a: Float64, b: Float64, c: Float64, d: Float64, e: Float64, f: Float64, color: UInt32, text: Int32):
        if len(self.layer_keys) == 0:
            self.begin_layer("")
        self.kinds.append(UInt8(kind))
        self.nums.append(Float32(a))
        self.nums.append(Float32(b))
        self.nums.append(Float32(c))
        self.nums.append(Float32(d))
        self.nums.append(Float32(e))
        self.nums.append(Float32(f))
        self.colors.append(color)
        self.text_of.append(text)

    def fill(mut self, color: UInt32):
        self._op(OP_FILL, 0, 0, Float64(self.w), Float64(self.h), 0, 0, color, -1)

    def rect(mut self, x: Float64, y: Float64, w: Float64, h: Float64, color: UInt32, radius: Float64):
        if w <= 0 or h <= 0:
            return
        self._op(OP_RECT, x, y, w, h, radius, 0, color, -1)

    def shadow(mut self, x: Float64, y: Float64, w: Float64, h: Float64, radius: Float64, blur: Float64, color: UInt32):
        if w <= 0 or h <= 0:
            return
        self._op(OP_SHADOW, x, y, w, h, radius, max(blur, 0.0), color, -1)

    def rect_hole(mut self, x: Float64, y: Float64, w: Float64, h: Float64, color: UInt32, radius: Float64, hole: Float64):
        if w <= 0 or h <= 0:
            return
        var hl = hole if hole > 0 and w - 2 * hole > 1 and h - 2 * hole > 1 else 0.0  # (no middle worth leaving out: 0)
        self._op(OP_RECT, x, y, w, h, radius, hl, color, -1)

    def line(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64, width: Float64, color: UInt32):
        self._op(OP_LINE, x0, y0, x1, y1, width, 0, color, -1)

    def circle(mut self, x: Float64, y: Float64, radius: Float64, color: UInt32):
        self._op(OP_CIRCLE, x, y, radius, 0, 0, 0, color, -1)

    def polygon(mut self, pts: List[Float64], color: UInt32):
        var n = len(pts) // 2
        if n < 3:
            return
        var first = len(self.path) // 2
        var at = len(self.path)
        var total = at + 2 * n
        if total > self.path.capacity():
            self.path.reserve(total + total // 2)
        self.path.resize(unsafe_uninit_length=total)
        var q = self.path.unsafe_ptr()
        var p = pts.unsafe_ptr()
        # (goal 80: the bounds are taken while the points go by, in pairs; batching and culling read them)
        var lo = SIMD[DType.float32, 2](Float32(pts[0]), Float32(pts[1]))
        var hi = lo
        for z in range(n):
            var v = SIMD[DType.float32, 2](Float32(p.unsafe_offset(2 * z)[]), Float32(p.unsafe_offset(2 * z + 1)[]))
            lo = min(lo, v)
            hi = max(hi, v)
            q.unsafe_offset(at + 2 * z)[] = v[0]
            q.unsafe_offset(at + 2 * z + 1)[] = v[1]
        self._op(OP_POLY, Float64(first), Float64(n), Float64(lo[0]), Float64(lo[1]), Float64(hi[0]), Float64(hi[1]), color, -1)

    def stroke(mut self, pts: List[Float64], width: Float64, color: UInt32):
        var n = len(pts) // 2
        if n < 1:
            return
        var first = len(self.path) // 2
        for v in pts:
            self.path.append(Float32(v))
        self._op(OP_STROKE, Float64(first), Float64(n), width, 0, 0, 0, color, -1)

    def poly_x(self, op: Int, i: Int) -> Float64:
        """Point i of polygon op."""
        return Float64(self.path[(Int(self.nums[op * STRIDE]) + i) * 2])

    def poly_y(self, op: Int, i: Int) -> Float64:
        return Float64(self.path[(Int(self.nums[op * STRIDE]) + i) * 2 + 1])

    def text(mut self, font: Font, text: String, x: Float64, baseline: Float64, size: Float64, color: UInt32, weight: Int, align: Int,
             slant: Float64):
        if text == "":
            return
        self.texts.append(text)
        self._op(OP_TEXT, x, baseline, size, slant, Float64(weight), Float64(align), color, Int32(len(self.texts) - 1))

    def run(mut self, st: TextStyle, text: String, x: Float64, baseline: Float64, color: UInt32, align: Int):
        if text == "":
            return
        self.texts.append(st.family + "\x1f" + text)
        self._op(OP_RUN, x, baseline, st.size, Float64(st.weight), Float64(align * 4 + (2 if st.exact else 0) + (1 if st.italic else 0)), st.letter_spacing, color,
                 Int32(len(self.texts) - 1))

    def run_style(self, op: Int) -> TextStyle:
        """An OP_RUN's style (its family, weight, italic, size, letter spacing)."""
        var t = self.text_at(op)
        var cut = t.find("\x1f")
        var st = TextStyle(String(t[byte=:cut]), Int(self.num(op, 3)), (Int(self.num(op, 4)) & 1) == 1, self.num(op, 2))
        st.letter_spacing = self.num(op, 5)
        st.exact = (Int(self.num(op, 4)) & 2) == 2
        return st

    def run_text(self, op: Int) -> String:
        var t = self.text_at(op)
        return String(t[byte=t.find("\x1f") + 1:])

    def run_align(self, op: Int) -> Int:
        return Int(self.num(op, 4)) // 4

    def num(self, op: Int, j: Int) -> Float64:
        return Float64(self.nums[op * STRIDE + j])

    def text_at(self, op: Int) -> String:
        var t = Int(self.text_of[op])
        return self.texts[t] if t >= 0 else String("")

    def same_op(self, p: Int, other: Scene, q: Int) -> Bool:
        """Whether op p here draws exactly what op q of `other` does (kind, numbers, colour, text, points, pixels)."""
        if self.kinds[p] != other.kinds[q] or self.colors[p] != other.colors[q]:
            return False
        if Int(self.kinds[p]) == OP_POLY or Int(self.kinds[p]) == OP_STROKE:  # (its points, not where they sit in the path list)
            var m = Int(self.num(p, 1))
            if Int(other.num(q, 1)) != m or self.nums[p * STRIDE + 2] != other.nums[q * STRIDE + 2]:
                return False
            var a0 = Int(self.num(p, 0)) * 2
            var b0 = Int(other.num(q, 0)) * 2
            for z in range(2 * m):
                if self.path[a0 + z] != other.path[b0 + z]:
                    return False
            return True
        for x in range(STRIDE):
            if self.nums[p * STRIDE + x] != other.nums[q * STRIDE + x]:
                return False
        if self.text_of[p] >= 0 and self.text_at(p) != other.text_at(q):
            return False
        if Int(self.kinds[p]) == OP_IMAGE and self.images[Int(self.num(p, 4))] != other.images[Int(other.num(q, 4))]:
            return False
        return True

    def same_layer(self, i: Int, other: Scene, j: Int) -> Bool:
        """Whether layer i of this scene draws exactly what layer j of `other` does (same ops, numbers, colours, texts)."""
        var a = self.layer_range(i)
        var b = other.layer_range(j)
        if self.layer_keys[i] != other.layer_keys[j]:
            return False
        if self.layer_tiled[i] != other.layer_tiled[j]:
            return False
        if self.layer_tiled[i]:  # (D-7940: a tiled layer's version is its content's; its ops also depend on its extent)
            for c in range(4):
                if self.layer_ext[4 * i + c] != other.layer_ext[4 * j + c]:
                    return False
        if self.layer_versions[i] >= 0 and other.layer_versions[j] >= 0:  # (the drawing code said which picture it is)
            return self.layer_versions[i] == other.layer_versions[j]
        if a[1] - a[0] != b[1] - b[0]:
            return False
        for n in range(a[1] - a[0]):
            if not self.same_op(a[0] + n, other, b[0] + n):
                return False
        return True

    def appends(self, i: Int, other: Scene, j: Int) -> Int:
        """When layer i is layer j of `other` with more ops drawn after it (a finished ink stroke joining the page): how
        many ops they share (the new ones follow), so a host adds only those to what it kept. -1 otherwise: another key,
        fewer or as many ops, any op different, a clip among the new ones or one the shared ops leave open (D-1219).
        Compares the items, whatever the layers' versions say."""
        if self.layer_keys[i] != other.layer_keys[j]:
            return -1
        var a = self.layer_range(i)
        var b = other.layer_range(j)
        var n = b[1] - b[0]
        if a[1] - a[0] <= n:
            return -1
        for op in range(a[0] + n, a[1]):
            var kind = Int(self.kinds[op])
            if kind == OP_CLIP or kind == OP_UNCLIP or kind == OP_FILL:  # (what's added must stand on its own)
                return -1
        var open = 0  # (a clip left open by the shared ops would cut the new ones: not an append)
        for m in range(n):
            if not self.same_op(a[0] + m, other, b[0] + m):
                return -1
            var kind = Int(self.kinds[a[0] + m])
            open += 1 if kind == OP_CLIP else (-1 if kind == OP_UNCLIP else 0)
        return n if open == 0 else -1

    def op_bounds(self, op: Int) -> List[Float64]:
        """Where op draws, in its layer's units: [x0, y0, x1, y1] (polygons, rects, circles, lines, images); empty for
        the others (text, fills, clips: no box the Scene knows). Rect and circle boxes leave out a stroke's width: a host
        that repaints by box (GTK's mend) pads them by 3 px, enough for ink polygons, not for thick-stroked shapes."""
        var kind = Int(self.kinds[op])
        var out = List[Float64]()
        if kind == OP_POLY or kind == OP_STROKE:
            var x0 = self.poly_x(op, 0)
            var y0 = self.poly_y(op, 0)
            var x1 = x0
            var y1 = y0
            for z in range(1, Int(self.num(op, 1))):
                var x = self.poly_x(op, z)
                var y = self.poly_y(op, z)
                x0 = min(x0, x)
                x1 = max(x1, x)
                y0 = min(y0, y)
                y1 = max(y1, y)
            var hw = self.num(op, 2) / 2 + 1 if kind == OP_STROKE else 0.0
            out = [x0 - hw, y0 - hw, x1 + hw, y1 + hw]
        elif kind == OP_RECT or kind == OP_IMAGE:
            out = [self.num(op, 0), self.num(op, 1), self.num(op, 0) + self.num(op, 2), self.num(op, 1) + self.num(op, 3)]
        elif kind == OP_SHADOW:
            var g = shadow_reach(self.num(op, 5) / 2)
            out = [self.num(op, 0) - g, self.num(op, 1) - g, self.num(op, 0) + self.num(op, 2) + g, self.num(op, 1) + self.num(op, 3) + g]
        elif kind == OP_CIRCLE:
            var r = self.num(op, 2)
            out = [self.num(op, 0) - r, self.num(op, 1) - r, self.num(op, 0) + r, self.num(op, 1) + r]
        elif kind == OP_LINE:
            var hw = self.num(op, 4) / 2 + 1
            out = [min(self.num(op, 0), self.num(op, 2)) - hw, min(self.num(op, 1), self.num(op, 3)) - hw,
                   max(self.num(op, 0), self.num(op, 2)) + hw, max(self.num(op, 1), self.num(op, 3)) + hw]
        return out^

    def removed_ops(self, i: Int, other: Scene, j: Int) -> List[Int]:
        """When layer i is layer j of `other` with some ops taken out and nothing else changed (strokes erased): which
        of the other layer's ops went, counted from its first op, in order. Empty otherwise: another key, nothing taken
        out, anything new or different. A host keeps what it built for the rest (GTK: the layer node's children,
        D-1707) instead of building the layer again."""
        var out = List[Int]()
        if self.layer_keys[i] != other.layer_keys[j]:
            return out^
        var a = self.layer_range(i)
        var b = other.layer_range(j)
        if a[1] - a[0] >= b[1] - b[0]:
            return out^
        var p = a[0]
        for q in range(b[0], b[1]):  # (greedy: this layer must be a subsequence of the other's)
            if p < a[1] and self.same_op(p, other, q):
                p += 1
                continue
            out.append(q - b[0])
        if p != a[1]:
            return List[Int]()
        return out^

    def removed_box(self, other: Scene, j: Int, gone: List[Int]) -> List[Float64]:
        """The box around ops `gone` of layer j of `other` ([x0, y0, x1, y1], the layer's units); empty when one of them
        has no box (text)."""
        var out = List[Float64]()
        var first = other.layer_range(j)[0]
        for n in range(len(gone)):
            var box = other.op_bounds(first + gone[n])
            if len(box) == 0:
                return List[Float64]()
            if n == 0:
                out = box^
            else:
                out = [min(out[0], box[0]), min(out[1], box[1]), max(out[2], box[2]), max(out[3], box[3])]
        return out^

    def removes(self, i: Int, other: Scene, j: Int) -> List[Float64]:
        """When layer i is layer j of `other` with some ops taken out and nothing else changed (strokes erased): the box
        around what was taken out ([x0, y0, x1, y1], the layer's units), so a host redraws only there (D-1220). Empty
        otherwise: another key, nothing taken out, anything new or different, or a taken-out op with no box (text)."""
        var gone = self.removed_ops(i, other, j)
        if len(gone) == 0:
            return List[Float64]()
        return self.removed_box(other, j, gone)

    def raster(self, mut s: Surface, font: Font):
        """Plays the list into pixels (the CPU reference: tests, screenshots, hosts without a GPU path), each layer
        through its transform."""
        var clips = List[Tuple[Float64, Float64, Float64, Float64]]()  # (x0, y0, x1, y1): rects are cut to the innermost
        var layer = -1
        var end = 0
        var tx = 0.0
        var ty = 0.0
        var tk = 1.0
        for op in range(len(self.kinds)):
            while op >= end and layer + 1 < self.layers():
                layer += 1
                end = self.layer_range(layer)[1]
                tx = self.layer_tx[layer]
                ty = self.layer_ty[layer]
                tk = self.layer_tk[layer]
            var kind = Int(self.kinds[op])
            var c = self.colors[op]
            if kind == OP_FILL:
                s.fill(c)
            elif kind == OP_CLIP:
                var x0 = self.num(op, 0) * tk + tx
                var y0 = self.num(op, 1) * tk + ty
                var x1 = x0 + self.num(op, 2) * tk
                var y1 = y0 + self.num(op, 3) * tk
                if len(clips) > 0:
                    ref o = clips[len(clips) - 1]
                    x0 = max(x0, o[0])
                    y0 = max(y0, o[1])
                    x1 = min(x1, o[2])
                    y1 = min(y1, o[3])
                clips.append((x0, y0, x1, y1))
            elif kind == OP_UNCLIP:
                if len(clips) > 0:
                    _ = clips.pop()
            elif kind == OP_RECT:
                var x = self.num(op, 0) * tk + tx
                var y = self.num(op, 1) * tk + ty
                var w = self.num(op, 2) * tk
                var h = self.num(op, 3) * tk
                if len(clips) > 0:  # (text isn't cut: pixels are measured with the metrics they're drawn with)
                    ref k = clips[len(clips) - 1]
                    var x1 = min(x + w, k[2])
                    var y1 = min(y + h, k[3])
                    x = max(x, k[0])
                    y = max(y, k[1])
                    w = x1 - x
                    h = y1 - y
                if w > 0 and h > 0:
                    rect(s, x, y, w, h, c, self.num(op, 4) * tk)
            elif kind == OP_SHADOW:
                var cut = len(clips) > 0
                var keep0 = s.clip_x0
                var keep1 = s.clip_y0
                var keep2 = s.clip_x1
                var keep3 = s.clip_y1
                if cut:
                    ref q = clips[len(clips) - 1]
                    s.clip_x0 = max(keep0, Int(q[0] + 0.5))
                    s.clip_y0 = max(keep1, Int(q[1] + 0.5))
                    s.clip_x1 = min(keep2, Int(q[2] + 0.5))
                    s.clip_y1 = min(keep3, Int(q[3] + 0.5))
                draw_shadow(s, self.num(op, 0) * tk + tx, self.num(op, 1) * tk + ty, self.num(op, 2) * tk, self.num(op, 3) * tk, self.num(op, 4) * tk,
                            self.num(op, 5) / 2 * tk, c)
                s.clip_x0 = keep0
                s.clip_y0 = keep1
                s.clip_x1 = keep2
                s.clip_y1 = keep3
            elif kind == OP_CIRCLE:
                circle(s, self.num(op, 0) * tk + tx, self.num(op, 1) * tk + ty, self.num(op, 2) * tk, c)
            elif kind == OP_LINE:
                line(s, self.num(op, 0) * tk + tx, self.num(op, 1) * tk + ty, self.num(op, 2) * tk + tx, self.num(op, 3) * tk + ty, self.num(op, 4) * tk, c)
            elif kind == OP_POLY:
                var m = Int(self.num(op, 1))
                var a0 = Int(self.num(op, 0)) * 2
                var pts = List[Float64](capacity=2 * m)
                for z in range(2 * m):
                    pts.append(Float64(self.path[a0 + z]))
                polygon(s, pts, c, tx, ty, tk)
            elif kind == OP_STROKE:
                var m = Int(self.num(op, 1))
                var sw = self.num(op, 2) * tk
                for z in range(m - 1):
                    line(s, self.poly_x(op, z) * tk + tx, self.poly_y(op, z) * tk + ty, self.poly_x(op, z + 1) * tk + tx, self.poly_y(op, z + 1) * tk + ty, sw, c)
                for z in range(m):
                    circle(s, self.poly_x(op, z) * tk + tx, self.poly_y(op, z) * tk + ty, sw / 2, c)
            elif kind == OP_IMAGE:
                var pw = Int(self.num(op, 5))
                ref px = self.images[Int(self.num(op, 4))]
                blit(s, px, pw, len(px) // pw, self.num(op, 0) * tk + tx, self.num(op, 1) * tk + ty, self.num(op, 2) * tk, self.num(op, 3) * tk)
            elif kind == OP_TEXT:
                font.draw(s, self.text_at(op), self.num(op, 0) * tk + tx, self.num(op, 1) * tk + ty, self.num(op, 2) * tk, c, Int(self.num(op, 4)), Int(self.num(op, 5)),
                          self.num(op, 3))
            elif kind == OP_RUN:
                var r = shape(self.run_style(op), self.run_text(op))
                var cl = Clip(0, 0, s.width, s.height)
                if len(clips) > 0:
                    ref q = clips[len(clips) - 1]
                    cl = Clip(Int(q[0] + 0.5), Int(q[1] + 0.5), Int(q[2] + 0.5), Int(q[3] + 0.5))
                draw_run(s, r, run_x(r, self.num(op, 0), self.run_align(op)) * tk + tx, self.num(op, 1) * tk + ty, tk, c, cl)
