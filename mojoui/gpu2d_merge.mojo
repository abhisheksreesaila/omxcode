# Fewer draws for the GPU 2D renderer (goal 75 M2): a Frame2D's runs regrouped so that runs of the same pipeline and
# blend that painter's order keeps apart become one run, without changing a single pixel. Backend-free (GL and Metal
# both use it); mojoui.gpu2d builds the runs, this only reorders them.
#
#   merge_runs(built, merged)   # merged: the same picture in fewer runs (built is left as scratch memory)
#
# Why: drawing code interleaves kinds (a mind map draws branch, pill, words, branch, pill, words …), so build_batches
# keeps 200 runs for 400 ops, and each run is a draw call with its state changes (a polygon run: two, plus the stencil
# set-up). Measured on the 3090 for the 300-topic map: ~500 GL calls a frame, 1–2 ms of CPU.
#
# The rule: within a layer, run R may join the latest earlier group G of its pipeline and blend when no run drawn after
# G's runs (the runs of every group after G) touches R's pixels: then drawing R before them gives the same picture,
# since blending order only matters where pictures overlap. "Touches" is tested on bounds: each instance's box (quads:
# the rect or the capsule's, glyphs: the slanted box, images: the rect, polygons: their bounds), cut by its clip and
# padded by PAD pixels (the anti-aliased edge: coverage reaches 0.5 px past a shape; a layer reused under a zoom out
# keeps its pad in layer units, so 4 px leaves room for one 4× zoom out). A run's bounds are its instances' bounds,
# kept per instance for long runs (BOXES_PER_RUN of them) so a long run of scattered words doesn't block everything.
# Within a group runs keep their order; groups keep the order of their first run. A group is searched for at most
# SEARCH groups back (the cost stays linear).

from mojoui.gpu2d import (_grow, Frame2D, Run, Layer2D, PIPE_QUAD, PIPE_GLYPH, PIPE_IMAGE, PIPE_POLY, QUAD_FLOATS, GLYPH_FLOATS,
                          IMAGE_FLOATS, POLY_FLOATS, SHAPE_CAPSULE, SHAPE_SHADOW, NO_CLIP)

comptime PAD = 4.0  # pixels around each instance's box (see above)
comptime SEARCH = 64  # groups looked back through for one to join
comptime BOXES_PER_RUN = 16  # a run's bounds as at most this many boxes (instances binned in order)


def _floats(pipe: Int) -> Int:
    if pipe == PIPE_QUAD:
        return QUAD_FLOATS
    if pipe == PIPE_GLYPH:
        return GLYPH_FLOATS
    if pipe == PIPE_IMAGE:
        return IMAGE_FLOATS
    return POLY_FLOATS


def _box(f: Frame2D, pipe: Int, i: Int, pad: Float32) -> SIMD[DType.float32, 4]:
    """Instance i's pixels' bounds in its layer's units (x0, y0, x1, y1), padded, cut by its clip."""
    var x0: Float32
    var y0: Float32
    var x1: Float32
    var y1: Float32
    var c: SIMD[DType.float32, 4]
    if pipe == PIPE_QUAD:
        var at = i * QUAD_FLOATS
        if Int(f.quads[at + 5]) == SHAPE_CAPSULE:
            var hw = f.quads[at + 4]
            x0 = min(f.quads[at], f.quads[at + 2]) - hw
            y0 = min(f.quads[at + 1], f.quads[at + 3]) - hw
            x1 = max(f.quads[at], f.quads[at + 2]) + hw
            y1 = max(f.quads[at + 1], f.quads[at + 3]) + hw
        elif Int(f.quads[at + 5]) == SHAPE_SHADOW:  # (goal 80: a shadow reaches 3 sigma past its box)
            var g = 3 * f.quads[at + 7] + 1
            x0 = f.quads[at] - g
            y0 = f.quads[at + 1] - g
            x1 = f.quads[at] + f.quads[at + 2] + g
            y1 = f.quads[at + 1] + f.quads[at + 3] + g
        else:
            x0 = f.quads[at]
            y0 = f.quads[at + 1]
            x1 = x0 + f.quads[at + 2]
            y1 = y0 + f.quads[at + 3]
        c = SIMD[DType.float32, 4](f.quads[at + 12], f.quads[at + 13], f.quads[at + 14], f.quads[at + 15])
    elif pipe == PIPE_GLYPH:
        var at = i * GLYPH_FLOATS
        var x = f.glyphs[at]
        var y = f.glyphs[at + 1]
        var h = f.glyphs[at + 3]
        var slant = f.glyphs[at + 12]
        var base = f.glyphs[at + 13]
        var lean_top = slant * (base - y)
        var lean_bottom = slant * (base - y - h)
        x0 = x + min(Float32(0), min(lean_top, lean_bottom))
        x1 = x + f.glyphs[at + 2] + max(Float32(0), max(lean_top, lean_bottom))
        y0 = y
        y1 = y + h
        c = SIMD[DType.float32, 4](f.glyphs[at + 16], f.glyphs[at + 17], f.glyphs[at + 18], f.glyphs[at + 19])
    elif pipe == PIPE_IMAGE:
        var at = i * IMAGE_FLOATS
        x0 = f.images[at]
        y0 = f.images[at + 1]
        x1 = x0 + f.images[at + 2]
        y1 = y0 + f.images[at + 3]
        c = SIMD[DType.float32, 4](f.images[at + 8], f.images[at + 9], f.images[at + 10], f.images[at + 11])
    else:
        var at = i * POLY_FLOATS
        x0 = f.polys[at + 8]
        y0 = f.polys[at + 9]
        x1 = f.polys[at + 10]
        y1 = f.polys[at + 11]
        c = SIMD[DType.float32, 4](f.polys[at + 12], f.polys[at + 13], f.polys[at + 14], f.polys[at + 15])
    x0 = max(x0 - pad, c[0])
    y0 = max(y0 - pad, c[1])
    x1 = min(x1 + pad, c[2])
    y1 = min(y1 + pad, c[3])
    return SIMD[DType.float32, 4](x0, y0, x1, y1)


def _union(a: SIMD[DType.float32, 4], b: SIMD[DType.float32, 4]) -> SIMD[DType.float32, 4]:
    if a[2] <= a[0] or a[3] <= a[1]:
        return b
    if b[2] <= b[0] or b[3] <= b[1]:
        return a
    return SIMD[DType.float32, 4](min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3]))


def _meets(a: SIMD[DType.float32, 4], b: SIMD[DType.float32, 4]) -> Bool:
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


struct _Plan(Movable):
    """One layer's regrouping: each group's pipeline, blend and member runs (frame run indexes, in order)."""

    var pipe: List[Int]
    var blend: List[Int]
    var members: List[List[Int]]
    var box_first: List[Int]  # run r's boxes: boxes[box_first[r] : box_first[r + 1]] (r relative to the layer's first run)
    var boxes: List[SIMD[DType.float32, 4]]
    var hull: List[SIMD[DType.float32, 4]]  # per run: the union of its boxes (a quick reject)

    def __init__(out self):
        self.pipe = List[Int]()
        self.blend = List[Int]()
        self.members = List[List[Int]]()
        self.box_first = List[Int]()
        self.boxes = List[SIMD[DType.float32, 4]]()
        self.hull = List[SIMD[DType.float32, 4]]()

    def meets(self, r: Int, s: Int) -> Bool:
        """Whether runs r and s (relative indexes) may share a pixel."""
        if not _meets(self.hull[r], self.hull[s]):
            return False
        for i in range(self.box_first[r], self.box_first[r + 1]):
            for j in range(self.box_first[s], self.box_first[s + 1]):
                if _meets(self.boxes[i], self.boxes[j]):
                    return True
        return False


def _plan(f: Frame2D, layer: Layer2D) -> _Plan:
    var p = _Plan()
    var pad = Float32(PAD / layer.k) if layer.k > 0 else Float32(PAD)
    p.box_first.reserve(layer.runs + 1)
    p.hull.reserve(layer.runs)
    for r in range(layer.runs):
        var run = f.runs[layer.first_run + r]
        p.box_first.append(len(p.boxes))
        var per = max(1, (run.count + BOXES_PER_RUN - 1) // BOXES_PER_RUN)
        var hull = SIMD[DType.float32, 4](0, 0, 0, 0)
        var i = 0
        while i < run.count:
            var b = SIMD[DType.float32, 4](0, 0, 0, 0)
            for k in range(i, min(i + per, run.count)):
                b = _union(b, _box(f, run.pipe, run.first + k, pad))
            if b[2] > b[0] and b[3] > b[1]:
                p.boxes.append(b)
                hull = _union(hull, b)
            i += per
        p.hull.append(hull)
    p.box_first.append(len(p.boxes))
    for r in range(layer.runs):
        var run = f.runs[layer.first_run + r]
        var target = -1
        var g = len(p.pipe) - 1
        var looked = 0
        while g >= 0 and looked < SEARCH:
            if p.pipe[g] == run.pipe and p.blend[g] == run.blend:
                target = g
                break
            var hit = False
            for m in p.members[g]:
                if p.meets(m - layer.first_run, r):
                    hit = True
                    break
            if hit:
                break
            g -= 1
            looked += 1
        if target >= 0:
            p.members[target].append(layer.first_run + r)
        else:
            p.pipe.append(run.pipe)
            p.blend.append(run.blend)
            p.members.append([layer.first_run + r])
    return p^


def _copy(mut dst: List[Float32], src: List[Float32], first: Int, n: Int):
    var p = _grow(dst, n)
    var q = src.unsafe_ptr()
    for i in range(n):
        p.unsafe_offset(i)[] = q.unsafe_offset(first + i)[]


def merge_runs(mut src: Frame2D, mut dst: Frame2D):
    """src's picture as dst, its runs regrouped into as few as the rule above allows. When nothing can merge, src's
    memory is swapped into dst (no copy). src is scratch afterwards (clear it or fill it again)."""
    var plans = List[_Plan]()
    var groups = 0
    for li in range(len(src.layers)):
        plans.append(_plan(src, src.layers[li]))
        groups += len(plans[li].pipe)
    if groups == len(src.runs):
        swap(src, dst)
        return
    dst.clear()
    dst.width = src.width
    dst.height = src.height
    dst.scale = src.scale
    swap(dst.pixels, src.pixels)
    for li in range(len(src.layers)):
        ref layer = src.layers[li]
        var first_run = len(dst.runs)
        dst.layers.append(Layer2D(layer.key.copy(), layer.version, layer.dx, layer.dy, layer.k, first_run, 0))
        ref p = plans[li]
        for g in range(len(p.pipe)):
            var pipe = p.pipe[g]
            var fl = _floats(pipe)
            var start = (len(dst.quads) if pipe == PIPE_QUAD else (len(dst.glyphs) if pipe == PIPE_GLYPH else (
                len(dst.images) if pipe == PIPE_IMAGE else len(dst.polys)))) // fl
            var count = 0
            for m in p.members[g]:
                var run = src.runs[m]
                if pipe == PIPE_QUAD:
                    _copy(dst.quads, src.quads, run.first * fl, run.count * fl)
                elif pipe == PIPE_GLYPH:
                    _copy(dst.glyphs, src.glyphs, run.first * fl, run.count * fl)
                elif pipe == PIPE_IMAGE:
                    _copy(dst.images, src.images, run.first * fl, run.count * fl)
                else:
                    for i in range(run.first, run.first + run.count):
                        var at = i * POLY_FLOATS
                        var fan0 = Int(src.polys[at])
                        var nf = Int(src.polys[at + 1])
                        var pt0 = Int(src.polys[at + 2])
                        var np = Int(src.polys[at + 3])
                        dst.polys.append(Float32(len(dst.fan) // 2))
                        dst.polys.append(src.polys[at + 1])
                        dst.polys.append(Float32(len(dst.points) // 2))
                        _copy(dst.polys, src.polys, at + 3, POLY_FLOATS - 3)
                        _copy(dst.fan, src.fan, 2 * fan0, 2 * nf)
                        _copy(dst.points, src.points, 2 * pt0, 2 * np)
                count += run.count
            dst.runs.append(Run(pipe, start, count, p.blend[g]))
        dst.layers[len(dst.layers) - 1].runs = len(dst.runs) - first_run


def append_frame(mut dst: Frame2D, src: Frame2D) -> Int:
    """src's runs (one layer: a layer's new ops, built with fill_layers(…, skip_ops)) added after dst's single layer:
    instances, fans and points appended to dst's lists (indexes moved to match), runs added as runs of their own. Returns
    the index of the first added run (what a backend uploads from), or -1 when it can't (not one layer each, or src has
    images: its pixel list would differ)."""
    if len(dst.layers) != 1 or len(src.layers) != 1 or len(src.images) > 0:
        return -1
    var first_new = len(dst.runs)
    var q0 = len(dst.quads) // QUAD_FLOATS
    var g0 = len(dst.glyphs) // GLYPH_FLOATS
    var p0 = len(dst.polys) // POLY_FLOATS
    var fan0 = len(dst.fan) // 2
    var pt0 = len(dst.points) // 2
    for r in range(src.layers[0].first_run, src.layers[0].first_run + src.layers[0].runs):
        var run = src.runs[r]
        var at = q0 if run.pipe == PIPE_QUAD else (g0 if run.pipe == PIPE_GLYPH else p0)
        dst.runs.append(Run(run.pipe, run.first + at, run.count, run.blend))
    dst.layers[0].runs += src.layers[0].runs
    _copy(dst.quads, src.quads, 0, len(src.quads))
    _copy(dst.glyphs, src.glyphs, 0, len(src.glyphs))
    for i in range(len(src.polys) // POLY_FLOATS):
        var at = i * POLY_FLOATS
        dst.polys.append(src.polys[at] + Float32(fan0))
        dst.polys.append(src.polys[at + 1])
        dst.polys.append(src.polys[at + 2] + Float32(pt0))
        _copy(dst.polys, src.polys, at + 3, POLY_FLOATS - 3)
    _copy(dst.fan, src.fan, 0, len(src.fan))
    _copy(dst.points, src.points, 0, len(src.points))
    return first_new
