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

from mojoui.canvas import Surface
from mojoui.draw import rect, line, circle, hline, polygon
from mojoui.text import Font, REGULAR, LEFT

comptime OP_RECT = 1  # x, y, w, h, radius
comptime OP_CIRCLE = 2  # x, y, radius
comptime OP_LINE = 3  # x0, y0, x1, y1, width
comptime OP_TEXT = 4  # x, baseline, size, slant, weight, align (+ the text)
comptime OP_FILL = 5  # the whole canvas, one colour (set, not blended)
comptime OP_CLIP = 6  # x, y, w, h: what follows (until OP_UNCLIP) is cut to this rect
comptime OP_UNCLIP = 7
comptime OP_IMAGE = 8  # x, y, w, h, image (pixels made elsewhere: a lens, a video frame), scaled to the rect
comptime OP_POLY = 9  # first point, points (the points in Scene.path, x, y interleaved): a filled polygon, non-zero (goal 40)
comptime STRIDE = 6  # floats per op


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

    def line(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64, width: Float64, color: UInt32):
        ...

    def circle(mut self, x: Float64, y: Float64, radius: Float64, color: UInt32):
        ...

    def polygon(mut self, pts: List[Float64], color: UInt32):
        """A filled polygon (x, y interleaved, closed implicitly), non-zero winding, anti-aliased: an ink stroke's
        outline (mojoui.ink), a shape."""
        ...

    def text(mut self, font: Font, text: String, x: Float64, baseline: Float64, size: Float64, color: UInt32, weight: Int, align: Int,
             slant: Float64):
        """`text` with its baseline at `baseline`, starting at x (or centred on it, or ending at it: `align`)."""
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
            s.set(x0 + dx, y0 + dy, pixels[sy * pw + sx])


struct SurfacePainter(Painter, Movable):
    """Paints into pixels, exactly as before the Scene (the reference and the fallback)."""

    var s: Surface
    var tx: Float64  # the current layer's transform (layer_transform)
    var ty: Float64
    var tk: Float64

    def __init__(out self, var s: Surface):
        self.s = s^
        self.tx = 0
        self.ty = 0
        self.tk = 1

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

    def push_clip(mut self, x: Float64, y: Float64, w: Float64, h: Float64):
        pass  # (pixels are measured with the same metrics they're drawn with: nothing spills)

    def pop_clip(mut self):
        pass

    def image(mut self, pixels: List[UInt32], pw: Int, ph: Int, x: Float64, y: Float64, w: Float64, h: Float64):
        blit(self.s, pixels, pw, ph, x * self.tk + self.tx, y * self.tk + self.ty, w * self.tk, h * self.tk)

    def note(mut self, meaning: String):
        pass

    def fill(mut self, color: UInt32):
        self.s.fill(color)

    def rect(mut self, x: Float64, y: Float64, w: Float64, h: Float64, color: UInt32, radius: Float64):
        var k = self.tk
        rect(self.s, x * k + self.tx, y * k + self.ty, w * k, h * k, color, radius * k)

    def line(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64, width: Float64, color: UInt32):
        var k = self.tk
        line(self.s, x0 * k + self.tx, y0 * k + self.ty, x1 * k + self.tx, y1 * k + self.ty, width * k, color)

    def circle(mut self, x: Float64, y: Float64, radius: Float64, color: UInt32):
        circle(self.s, x * self.tk + self.tx, y * self.tk + self.ty, radius * self.tk, color)

    def polygon(mut self, pts: List[Float64], color: UInt32):
        polygon(self.s, pts, color, self.tx, self.ty, self.tk)

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

    def __init__(out self, width: Int, height: Int, scale: Float64):
        self.w = width
        self.h = height
        self.k = scale
        self.is_still = False
        self.again = False
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

    def reset(mut self, width: Int, height: Int, scale: Float64):
        """Empty again for the next frame, keeping the memory (a host recycles last frame's list)."""
        self.w = width
        self.h = height
        self.k = scale
        self.is_still = False
        self.again = False
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

    def ops(self) -> Int:
        return len(self.kinds)

    def begin_layer(mut self, key: String):
        self.layer_keys.append(key)
        self.layer_starts.append(len(self.kinds))
        self.layer_versions.append(-1)
        self.layer_tx.append(0)
        self.layer_ty.append(0)
        self.layer_tk.append(1)

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

    def line(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64, width: Float64, color: UInt32):
        self._op(OP_LINE, x0, y0, x1, y1, width, 0, color, -1)

    def circle(mut self, x: Float64, y: Float64, radius: Float64, color: UInt32):
        self._op(OP_CIRCLE, x, y, radius, 0, 0, 0, color, -1)

    def polygon(mut self, pts: List[Float64], color: UInt32):
        var n = len(pts) // 2
        if n < 3:
            return
        var first = len(self.path) // 2
        for v in pts:
            self.path.append(Float32(v))
        self._op(OP_POLY, Float64(first), Float64(n), 0, 0, 0, 0, color, -1)

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

    def num(self, op: Int, j: Int) -> Float64:
        return Float64(self.nums[op * STRIDE + j])

    def text_at(self, op: Int) -> String:
        var t = Int(self.text_of[op])
        return self.texts[t] if t >= 0 else String("")

    def same_layer(self, i: Int, other: Scene, j: Int) -> Bool:
        """Whether layer i of this scene draws exactly what layer j of `other` does (same ops, numbers, colours, texts)."""
        var a = self.layer_range(i)
        var b = other.layer_range(j)
        if self.layer_keys[i] != other.layer_keys[j]:
            return False
        if self.layer_versions[i] >= 0 and other.layer_versions[j] >= 0:  # (the drawing code said which picture it is)
            return self.layer_versions[i] == other.layer_versions[j]
        if a[1] - a[0] != b[1] - b[0]:
            return False
        for n in range(a[1] - a[0]):
            var p = a[0] + n
            var q = b[0] + n
            if self.kinds[p] != other.kinds[q] or self.colors[p] != other.colors[q]:
                return False
            if Int(self.kinds[p]) == OP_POLY:  # (its points, not where they sit in the path list)
                var m = Int(self.num(p, 1))
                if Int(other.num(q, 1)) != m:
                    return False
                var a0 = Int(self.num(p, 0)) * 2
                var b0 = Int(other.num(q, 0)) * 2
                for z in range(2 * m):
                    if self.path[a0 + z] != other.path[b0 + z]:
                        return False
                continue
            for x in range(STRIDE):
                if self.nums[p * STRIDE + x] != other.nums[q * STRIDE + x]:
                    return False
            if self.text_of[p] >= 0 and self.text_at(p) != other.text_at(q):
                return False
            if Int(self.kinds[p]) == OP_IMAGE and self.images[Int(self.num(p, 4))] != other.images[Int(other.num(q, 4))]:
                return False
        return True

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
            elif kind == OP_IMAGE:
                var pw = Int(self.num(op, 5))
                ref px = self.images[Int(self.num(op, 4))]
                blit(s, px, pw, len(px) // pw, self.num(op, 0) * tk + tx, self.num(op, 1) * tk + ty, self.num(op, 2) * tk, self.num(op, 3) * tk)
            elif kind == OP_TEXT:
                font.draw(s, self.text_at(op), self.num(op, 0) * tk + tx, self.num(op, 1) * tk + ty, self.num(op, 2) * tk, c, Int(self.num(op, 4)), Int(self.num(op, 5)),
                          self.num(op, 3))
