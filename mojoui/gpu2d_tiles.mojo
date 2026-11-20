# Raster tiles for big layers (goal 79, D-7940): the GPU 2D renderer's kept pictures of a layer that said
# Painter.layer_tiles. Backend-free: what to rasterize, what to keep, what to show and where; the GL and Metal backends
# only rasterize a tile (the layer's ops that meet it, through mojoui.gpu2d.fill_layers(only=…, content_k=…)) and draw
# tile quads (docs/research/big-boards.md: Chromium's tiles, Figma's, Excalidraw's interactive canvas).
#
#   var tiles = Tiles()                                   # one per renderer
#   var plan = tiles.plan(scene, i, owner, w, h)          # each frame, for each tiled layer i
#   for r in plan.rasters: build r.ops' batches at r.k (content px), draw them into texture r.slot moved by
#                          (−r.i·TILE + TILE_BORDER, −r.j·TILE + TILE_BORDER), premultiplied, cleared first
#   for d in plan.draws:   pixel centre p on screen: content c = (p − (d.tx, d.ty)) / d.s; drawn when c is inside the
#                          tile's [i·TILE, (i+1)·TILE)² and p inside d's clip; texel = c − (i·TILE, j·TILE) + TILE_BORDER
#   tiles.more             # another frame is wanted (tiles left to rasterize, or a zoom to settle)
#
# Content px: a layer unit × the tile set's zoom k (device px at that zoom, no translation). A tile is TILE × TILE content
# px plus a TILE_BORDER ring rastered from its neighbours' content (bilinear sampling when scaled never reads past it).
# Rules:
# - Pan: the layer's translation is snapped to whole device px (Scene.layer_tiles), so kept tiles land 1:1 and the frame
#   equals a direct render. Tiles newly in view are rastered at once; a ring one tile round the view is rastered within
#   a budget per frame (TILE_BUDGET_NS), so a pan finds its next tiles ready.
# - Edit: a new version with Painter.layer_damage from the version the tiles show frees only the tiles the rects meet;
#   without damage every tile goes.
# - Zoom: while the zoom moves, the kept tiles are drawn scaled (bilinear). Once it has held still for TILE_SETTLE_NS (or
#   strays past 2× either way), a tiling at the new zoom is rastered progressively, nearest the middle first, the old one
#   drawn scaled under the tiles still missing; text ends rasterized at the zoom it is shown at (M1's rule).
# - A tile is rastered from the frame's ops, complete only inside the layer's extent: it remembers the part it is good
#   for, and is rastered again when the view reaches past that part.

from std.math import floor, ceil
from std.time import perf_counter_ns
from std.collections import Dict
from mojoui.scene import Scene, OP_RECT, OP_CIRCLE, OP_LINE, OP_TEXT, OP_FILL, OP_CLIP, OP_UNCLIP, OP_IMAGE, OP_POLY, OP_RUN

comptime TILE = 512  # content px per tile side
comptime TILE_BORDER = 1
comptime TILE_TEX = TILE + 2 * TILE_BORDER  # a tile texture's side
comptime TILE_SETTLE_NS = 120_000_000  # a zoom held this long gets tiles at its own scale
comptime TILE_BUDGET_NS = 3_000_000  # rasters beyond those a frame must have (ring, settling): stop after this much
comptime TILE_POOL = 128  # tile textures at most (128 × 514² × 4 B ≈ 135 MB of GPU memory)
comptime TILE_PAD_PX = 3.0  # device px round an op's bounds (antialiasing, glyph snapping)


def _pack(i: Int, j: Int) -> Int:
    return (i + 1048576) * 2097152 + (j + 1048576)


def _unpack(key: Int) -> Tuple[Int, Int]:
    return (key // 2097152 - 1048576, key % 2097152 - 1048576)


def op_box(scene: Scene, op: Int) -> Tuple[Float64, Float64, Float64, Float64]:
    """Where op may draw, in its layer's units, generously (text: up to one em per byte either side of x)."""
    var kind = Int(scene.kinds[op])
    var a = scene.num(op, 0)
    var b = scene.num(op, 1)
    var c = scene.num(op, 2)
    var d = scene.num(op, 3)
    if kind == OP_RECT or kind == OP_IMAGE:
        return (a, b, a + c, b + d)
    if kind == OP_CIRCLE:
        return (a - c, b - c, a + c, b + c)
    if kind == OP_LINE:
        var hw = scene.num(op, 4) / 2
        return (min(a, c) - hw, min(b, d) - hw, max(a, c) + hw, max(b, d) + hw)
    if kind == OP_POLY:
        var n = Int(b)
        var x0 = 1e300
        var y0 = 1e300
        var x1 = -1e300
        var y1 = -1e300
        for z in range(n):
            var x = scene.poly_x(op, z)
            var y = scene.poly_y(op, z)
            x0 = min(x0, x)
            y0 = min(y0, y)
            x1 = max(x1, x)
            y1 = max(y1, y)
        return (x0, y0, x1, y1)
    if kind == OP_TEXT or kind == OP_RUN:
        var t = Int(scene.text_of[op])
        var n = scene.texts[t].byte_length() if t >= 0 else 0
        var size = c
        var spacing = scene.num(op, 5) if kind == OP_RUN else 0.0
        var wide = Float64(n) * (size * 1.2 + abs(spacing)) + size
        return (a - wide, b - size * 1.6, a + wide, b + size * 0.8)
    return (-1e300, -1e300, 1e300, 1e300)  # (fills, clips: everywhere; a tiled layer has none)


struct OpBins(Movable):
    """A tiled layer's ops binned by where they draw (offsets from the layer's first op): built once per (version,
    extent, op count), queried per tile."""
    var version: Int
    var ext: List[Float64]
    var nops: Int
    var cell: Float64
    var gx0: Float64
    var gy0: Float64
    var nx: Int
    var ny: Int
    var start: List[Int]
    var items: List[Int]
    var bx0: List[Float32]
    var by0: List[Float32]
    var bx1: List[Float32]
    var by1: List[Float32]
    var stamp: List[Int]
    var stamp_now: Int

    def __init__(out self):
        self.version = -999
        self.ext = List[Float64]()
        self.nops = -1
        self.cell = 256
        self.gx0 = 0
        self.gy0 = 0
        self.nx = 0
        self.ny = 0
        self.start = List[Int]()
        self.items = List[Int]()
        self.bx0 = List[Float32]()
        self.by0 = List[Float32]()
        self.bx1 = List[Float32]()
        self.by1 = List[Float32]()
        self.stamp = List[Int]()
        self.stamp_now = 0

    def fresh(self, scene: Scene, i: Int) -> Bool:
        var span = scene.layer_range(i)
        if self.version != scene.layer_versions[i] or self.nops != span[1] - span[0] or scene.layer_versions[i] < 0 or len(self.ext) != 4:
            return False
        for c in range(4):
            if self.ext[c] != scene.layer_ext[4 * i + c]:
                return False
        return True

    def build(mut self, scene: Scene, i: Int):
        var span = scene.layer_range(i)
        var n = span[1] - span[0]
        self.version = scene.layer_versions[i]
        self.nops = n
        self.ext = List[Float64]()
        for c in range(4):
            self.ext.append(scene.layer_ext[4 * i + c])
        self.bx0 = List[Float32](capacity=n)
        self.by0 = List[Float32](capacity=n)
        self.bx1 = List[Float32](capacity=n)
        self.by1 = List[Float32](capacity=n)
        var x0 = 1e300
        var y0 = 1e300
        var x1 = -1e300
        var y1 = -1e300
        for o in range(n):
            var b = op_box(scene, span[0] + o)
            self.bx0.append(Float32(b[0]))
            self.by0.append(Float32(b[1]))
            self.bx1.append(Float32(b[2]))
            self.by1.append(Float32(b[3]))
            if b[0] > -1e299:
                x0 = min(x0, b[0])
                y0 = min(y0, b[1])
                x1 = max(x1, b[2])
                y1 = max(y1, b[3])
        self.stamp = List[Int](length=n, fill=0)
        self.stamp_now = 0
        if n == 0 or x0 > x1:
            self.nx = 0
            self.ny = 0
            self.start = List[Int]()
            self.items = List[Int]()
            return
        self.cell = 256
        while ((x1 - x0) / self.cell + 1) * ((y1 - y0) / self.cell + 1) > 65536:
            self.cell *= 2
        self.gx0 = floor(x0 / self.cell) * self.cell
        self.gy0 = floor(y0 / self.cell) * self.cell
        self.nx = Int((x1 - self.gx0) / self.cell) + 1
        self.ny = Int((y1 - self.gy0) / self.cell) + 1
        var cells = self.nx * self.ny
        var counts = List[Int](length=cells + 1, fill=0)
        for o in range(n):
            var r = self._cells(Float64(self.bx0[o]), Float64(self.by0[o]), Float64(self.bx1[o]), Float64(self.by1[o]))
            for cy in range(r[1], r[3] + 1):
                for cx in range(r[0], r[2] + 1):
                    counts[cy * self.nx + cx + 1] += 1
        for c in range(cells):
            counts[c + 1] += counts[c]
        self.items = List[Int](length=counts[cells], fill=0)
        var at = counts.copy()
        for o in range(n):
            var r = self._cells(Float64(self.bx0[o]), Float64(self.by0[o]), Float64(self.bx1[o]), Float64(self.by1[o]))
            for cy in range(r[1], r[3] + 1):
                for cx in range(r[0], r[2] + 1):
                    var c = cy * self.nx + cx
                    self.items[at[c]] = o
                    at[c] += 1
        self.start = counts^

    def _cells(self, x0: Float64, y0: Float64, x1: Float64, y1: Float64) -> Tuple[Int, Int, Int, Int]:
        var a = Int(floor((max(x0, -1e15) - self.gx0) / self.cell))
        var b = Int(floor((max(y0, -1e15) - self.gy0) / self.cell))
        var c = Int(floor((min(x1, 1e15) - self.gx0) / self.cell))
        var d = Int(floor((min(y1, 1e15) - self.gy0) / self.cell))
        return (max(a, 0), max(b, 0), min(c, self.nx - 1), min(d, self.ny - 1))

    def query(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64) -> List[Int]:
        """The ops (offsets, ascending: paint order) whose bounds meet the rect."""
        var out = List[Int]()
        if self.nx == 0:
            return out^
        self.stamp_now += 1
        var r = self._cells(x0, y0, x1, y1)
        for cy in range(r[1], r[3] + 1):
            for cx in range(r[0], r[2] + 1):
                var c = cy * self.nx + cx
                for q in range(self.start[c], self.start[c + 1]):
                    var o = self.items[q]
                    if self.stamp[o] == self.stamp_now:
                        continue
                    self.stamp[o] = self.stamp_now
                    if Float64(self.bx1[o]) < x0 or Float64(self.bx0[o]) > x1 or Float64(self.by1[o]) < y0 or Float64(self.by0[o]) > y1:
                        continue
                    out.append(o)
        sort(out)
        return out^


@fieldwise_init
struct TileRaster(Copyable, Movable):
    """Rasterize ops (offsets in layer `layer`) at zoom k into tile (i, j)'s texture `slot`."""
    var layer: Int
    var slot: Int
    var i: Int
    var j: Int
    var k: Float64
    var ops: List[Int]


@fieldwise_init
struct TileDraw(Copyable, Movable, ImplicitlyCopyable):
    """Show tile (i, j)'s texture `slot`: content px c lands at c·s + (tx, ty) on screen; only pixel centres inside the
    clip rect (screen px) and the tile."""
    var slot: Int
    var i: Int
    var j: Int
    var s: Float64
    var tx: Float64
    var ty: Float64
    var cx0: Float64
    var cy0: Float64
    var cx1: Float64
    var cy1: Float64


struct TileSet(Movable):
    """One tiled layer's kept tiles (for one canvas): the current tiling at zoom k, the one before (fallback) at fb_k."""
    var key: String
    var owner: Int
    var k: Float64
    var version: Int
    var tiles: Dict[Int, Int]  # packed (i, j) → slot
    var good: Dict[Int, Int]  # packed (i, j) → index into good_r: the part (layer units) the tile was rastered for
    var good_r: List[Float64]
    var fb_k: Float64
    var fb: Dict[Int, Int]
    var k_seen: Float64
    var k_since: Int
    var used: Int
    var bins: OpBins

    def __init__(out self, key: String, owner: Int):
        self.key = key
        self.owner = owner
        self.k = 0
        self.version = -999
        self.tiles = Dict[Int, Int]()
        self.good = Dict[Int, Int]()
        self.good_r = List[Float64]()
        self.fb_k = 0
        self.fb = Dict[Int, Int]()
        self.k_seen = 0
        self.k_since = 0
        self.used = 0
        self.bins = OpBins()


struct TilePlan(Movable):
    var rasters: List[TileRaster]
    var draws: List[TileDraw]

    def __init__(out self):
        self.rasters = List[TileRaster]()
        self.draws = List[TileDraw]()


struct Tiles(Movable):
    """Every tiled layer's tiles and the texture slots they use (a backend makes slot n's texture on first use)."""
    var sets: List[TileSet]
    var free: List[Int]
    var slots: Int  # slots handed out so far (≤ TILE_POOL)
    var more: Bool  # a later frame has tiles to rasterize or a zoom to settle
    var stamp: Int
    var rastered: Int  # tiles rastered / drawn / freed by damage, last frame (tests, framebench)
    var drawn: Int
    var damaged: Int
    var budget_ns: Int
    var settle_ns: Int

    def __init__(out self):
        self.sets = List[TileSet]()
        self.free = List[Int]()
        self.slots = 0
        self.more = False
        self.stamp = 0
        self.rastered = 0
        self.drawn = 0
        self.damaged = 0
        self.budget_ns = TILE_BUDGET_NS
        self.settle_ns = TILE_SETTLE_NS

    def begin_frame(mut self):
        self.stamp += 1
        self.more = False
        self.rastered = 0
        self.drawn = 0
        self.damaged = 0

    def _set(mut self, key: String, owner: Int) -> Int:
        for s in range(len(self.sets)):
            if self.sets[s].key == key and self.sets[s].owner == owner:
                return s
        self.sets.append(TileSet(key, owner))
        return len(self.sets) - 1

    def _slot(mut self, keep: Int) -> Int:
        """A free texture slot (-1: none, even after freeing other sets' and far tiles)."""
        if len(self.free) > 0:
            return self.free.pop()
        if self.slots < TILE_POOL:
            self.slots += 1
            return self.slots - 1
        # (full: the least recently used other set's tiles go, then fallbacks)
        var old = -1
        for s in range(len(self.sets)):
            if s != keep and (len(self.sets[s].tiles) > 0 or len(self.sets[s].fb) > 0) and (old < 0 or self.sets[s].used < self.sets[old].used):
                old = s
        if old >= 0:
            self._drop_all(old)
        elif len(self.sets[keep].fb) > 0:
            self._drop_fb(keep)
        if len(self.free) > 0:
            return self.free.pop()
        return -1

    def _drop_fb(mut self, s: Int):
        for e in self.sets[s].fb.items():
            self.free.append(e.value)
        self.sets[s].fb = Dict[Int, Int]()

    def _drop_tiles(mut self, s: Int):
        for e in self.sets[s].tiles.items():
            self.free.append(e.value)
        self.sets[s].tiles = Dict[Int, Int]()
        self.sets[s].good = Dict[Int, Int]()
        self.sets[s].good_r = List[Float64]()

    def _drop_all(mut self, s: Int):
        self._drop_tiles(s)
        self._drop_fb(s)

    def forget(mut self, owner: Int):
        """A canvas gone: its tiles' slots are free again."""
        var s = 0
        while s < len(self.sets):
            if self.sets[s].owner == owner:
                self._drop_all(s)
                _ = self.sets.pop(s)
            else:
                s += 1

    def plan(mut self, scene: Scene, i: Int, owner: Int, w: Int, h: Int) -> TilePlan:
        """What to rasterize and draw this frame for tiled layer i of `scene` (shown on a w × h target)."""
        var out = TilePlan()
        var s = self._set(scene.layer_keys[i], owner)
        self.sets[s].used = self.stamp
        var now = Int(perf_counter_ns())
        var k = scene.layer_tk[i]
        var tx = scene.layer_tx[i]
        var ty = scene.layer_ty[i]
        var v = scene.layer_versions[i]
        if not self.sets[s].bins.fresh(scene, i):
            self.sets[s].bins.build(scene, i)
        # an edit: the damaged tiles go (all of them without damage from the version they show)
        if self.sets[s].version != v or v < 0:
            var since = scene.layer_since[i]
            if since >= 0 and since == self.sets[s].version and v >= 0:
                var dm = scene.damage_of(i)
                self._damage(s, dm, False)
                self._damage(s, dm, True)
            else:
                self.damaged += len(self.sets[s].tiles)
                self._drop_all(s)
            self.sets[s].version = v
        # the zoom
        if k != self.sets[s].k_seen:
            self.sets[s].k_seen = k
            self.sets[s].k_since = now
        if self.sets[s].k == 0 or (len(self.sets[s].tiles) == 0 and len(self.sets[s].fb) == 0):
            self.sets[s].k = k
        if k != self.sets[s].k:
            var ratio = k / self.sets[s].k
            if now - self.sets[s].k_since >= self.settle_ns or ratio > 2.0 or ratio < 0.5:
                # a new tiling at k; the old one stays under it as the fallback while it fills (unless the old fallback
                # covers more of what's on screen than the current tiling does: then that one stays)
                if len(self.sets[s].tiles) >= len(self.sets[s].fb) or self.sets[s].fb_k == 0:
                    self._drop_fb(s)
                    swap(self.sets[s].fb, self.sets[s].tiles)
                    self.sets[s].fb_k = self.sets[s].k
                    self.sets[s].tiles = Dict[Int, Int]()
                    self.sets[s].good = Dict[Int, Int]()
                    self.sets[s].good_r = List[Float64]()
                else:
                    self._drop_tiles(s)
                self.sets[s].k = k
            else:
                self.more = True  # (settle later: a frame after the zoom holds still)
        var tk = self.sets[s].k
        var sc = k / tk  # content px at tk → screen
        # the view in content px at tk, and the tiles it meets
        var vx0 = (0 - tx) / sc
        var vy0 = (0 - ty) / sc
        var vx1 = (Float64(w) - tx) / sc
        var vy1 = (Float64(h) - ty) / sc
        var i0 = Int(floor(vx0 / TILE))
        var j0 = Int(floor(vy0 / TILE))
        var i1 = Int(floor((vx1 - 0.001) / TILE))
        var j1 = Int(floor((vy1 - 0.001) / TILE))
        var ex0 = scene.layer_ext[4 * i] * tk
        var ey0 = scene.layer_ext[4 * i + 1] * tk
        var ex1 = scene.layer_ext[4 * i + 2] * tk
        var ey1 = scene.layer_ext[4 * i + 3] * tk
        var cx = (vx0 + vx1) / 2
        var cy = (vy0 + vy1) / 2
        var t0 = Int(perf_counter_ns())
        # visible tiles, nearest the middle first
        var order = List[Int]()
        for jj in range(j0, j1 + 1):
            for ii in range(i0, i1 + 1):
                var dx = (Float64(ii) + 0.5) * TILE - cx
                var dy = (Float64(jj) + 0.5) * TILE - cy
                order.append(Int(dx * dx + dy * dy) * 4096 + (jj - j0) * 64 + (ii - i0))
        sort(order)
        var missing = List[Int]()  # visible tiles not ready this frame (drawn from the fallback)
        for q in order:
            var ii = i0 + (q % 4096) % 64
            var jj = j0 + (q % 4096) // 64
            var key = _pack(ii, jj)
            # the part of this tile on screen, in layer units (it must lie in the part the tile was rastered for)
            var px0 = max(Float64(ii) * TILE, vx0) / tk
            var py0 = max(Float64(jj) * TILE, vy0) / tk
            var px1 = min(Float64(ii + 1) * TILE, vx1) / tk
            var py1 = min(Float64(jj + 1) * TILE, vy1) / tk
            var ready = key in self.sets[s].tiles and self._good_for(s, key, px0, py0, px1, py1)
            if ready:
                continue
            var has_fb = len(self.sets[s].fb) > 0 and self._fb_covers(s, ii, jj, tk)
            var spent = Int(perf_counter_ns()) - t0
            if has_fb and spent >= self.budget_ns:
                missing.append(key)
                self.more = True
                continue
            if not self._raster(out, s, i, ii, jj, tk, ex0, ey0, ex1, ey1):
                if has_fb:
                    missing.append(key)
                continue
        # the ring round the view (within the budget, the current zoom only, once nothing on screen is missing)
        if len(missing) == 0 and tk == k:
            for jj in range(j0 - 1, j1 + 2):
                for ii in range(i0 - 1, i1 + 2):
                    if jj >= j0 and jj <= j1 and ii >= i0 and ii <= i1:
                        continue
                    var key = _pack(ii, jj)
                    if key in self.sets[s].tiles:
                        continue
                    # (only where the extent has ops: a tile beyond it has nothing it is good for)
                    var gx0 = max(Float64(ii) * TILE, ex0)
                    var gy0 = max(Float64(jj) * TILE, ey0)
                    if gx0 >= min(Float64(ii + 1) * TILE, ex1) or gy0 >= min(Float64(jj + 1) * TILE, ey1):
                        continue
                    if Int(perf_counter_ns()) - t0 >= self.budget_ns or len(out.rasters) >= 6:
                        self.more = True
                        break
                    _ = self._raster(out, s, i, ii, jj, tk, ex0, ey0, ex1, ey1)
        # what's shown: the fallback under the missing tiles, then the current tiles
        if len(missing) > 0:
            var fsc = k / self.sets[s].fb_k
            for key in missing:
                var ij = _unpack(key)
                var sx0 = Float64(ij[0]) * TILE * sc + tx
                var sy0 = Float64(ij[1]) * TILE * sc + ty
                var sx1 = Float64(ij[0] + 1) * TILE * sc + tx
                var sy1 = Float64(ij[1] + 1) * TILE * sc + ty
                for e in self.sets[s].fb.items():
                    var fij = _unpack(e.key)
                    var fx0 = Float64(fij[0]) * TILE * fsc + tx
                    var fy0 = Float64(fij[1]) * TILE * fsc + ty
                    var fx1 = Float64(fij[0] + 1) * TILE * fsc + tx
                    var fy1 = Float64(fij[1] + 1) * TILE * fsc + ty
                    if fx1 <= sx0 or fx0 >= sx1 or fy1 <= sy0 or fy0 >= sy1:
                        continue
                    out.draws.append(TileDraw(e.value, fij[0], fij[1], fsc, tx, ty, max(sx0, 0.0), max(sy0, 0.0), min(sx1, Float64(w)), min(sy1, Float64(h))))
        elif len(self.sets[s].fb) > 0 and tk == k:
            self._drop_fb(s)  # (the new tiling covers the view: the old one goes)
        for jj in range(j0, j1 + 1):
            for ii in range(i0, i1 + 1):
                var key = _pack(ii, jj)
                if key in self.sets[s].tiles and not self._in(missing, key):
                    out.draws.append(TileDraw(self.sets[s].tiles.get(key, -1), ii, jj, sc, tx, ty, 0, 0, Float64(w), Float64(h)))
        if tk != k:
            self.more = True
        self.drawn += len(out.draws)
        # far tiles go (beyond two tiles round the view), keeping the pool for what's near
        var far = List[Int]()
        for e in self.sets[s].tiles.items():
            var ij = _unpack(e.key)
            if ij[0] < i0 - 3 or ij[0] > i1 + 3 or ij[1] < j0 - 3 or ij[1] > j1 + 3:
                far.append(e.key)
        if self.slots >= TILE_POOL * 3 // 4:
            for key in far:
                try:
                    self.free.append(self.sets[s].tiles.pop(key))
                    _ = self.sets[s].good.pop(key)
                except:
                    pass
        return out^

    def _in(self, keys: List[Int], key: Int) -> Bool:
        for k in keys:
            if k == key:
                return True
        return False

    def _good_for(self, s: Int, key: Int, x0: Float64, y0: Float64, x1: Float64, y1: Float64) -> Bool:
        var g = self.sets[s].good.get(key, -1)
        if g < 0:
            return False
        ref r = self.sets[s].good_r
        return r[4 * g] <= x0 + 1e-6 and r[4 * g + 1] <= y0 + 1e-6 and r[4 * g + 2] >= x1 - 1e-6 and r[4 * g + 3] >= y1 - 1e-6

    def _fb_covers(self, s: Int, ii: Int, jj: Int, tk: Float64) -> Bool:
        """Whether the fallback tiling has any tile under current tile (ii, jj)."""
        var f = self.sets[s].fb_k / tk
        var a0 = Int(floor(Float64(ii) * f))
        var b0 = Int(floor(Float64(jj) * f))
        var a1 = Int(floor((Float64(ii + 1) * f) - 1e-9))
        var b1 = Int(floor((Float64(jj + 1) * f) - 1e-9))
        for b in range(b0, b1 + 1):
            for a in range(a0, a1 + 1):
                if _pack(a, b) in self.sets[s].fb:
                    return True
        return False

    def _raster(mut self, mut out: TilePlan, s: Int, layer: Int, ii: Int, jj: Int, tk: Float64, ex0: Float64, ey0: Float64, ex1: Float64,
                ey1: Float64) -> Bool:
        """Plans tile (ii, jj) at zoom tk (its texture slot taken or reused): False when no slot is free."""
        var key = _pack(ii, jj)
        var slot = self.sets[s].tiles.get(key, -1)
        if slot < 0:
            slot = self._slot(s)
            if slot < 0:
                return False
            self.sets[s].tiles[key] = slot
        # the tile with its border, padded for antialiasing, in layer units
        var pad = Float64(TILE_BORDER) + TILE_PAD_PX
        var lx0 = (Float64(ii) * TILE - pad) / tk
        var ly0 = (Float64(jj) * TILE - pad) / tk
        var lx1 = (Float64(ii + 1) * TILE + pad) / tk
        var ly1 = (Float64(jj + 1) * TILE + pad) / tk
        var ops = self.sets[s].bins.query(lx0, ly0, lx1, ly1)
        out.rasters.append(TileRaster(layer, slot, ii, jj, tk, ops^))
        var g = self.sets[s].good.get(key, -1)
        if g < 0:
            if len(self.sets[s].good_r) >= 4 * 8192:  # (compacted now and then: only kept tiles' parts stay)
                var r2 = List[Float64]()
                var g2 = Dict[Int, Int]()
                for e in self.sets[s].good.items():
                    g2[e.key] = len(r2) // 4
                    for c in range(4):
                        r2.append(self.sets[s].good_r[4 * e.value + c])
                self.sets[s].good_r = r2^
                self.sets[s].good = g2^
            g = len(self.sets[s].good_r) // 4
            for _ in range(4):
                self.sets[s].good_r.append(0)
            self.sets[s].good[key] = g
        self.sets[s].good_r[4 * g] = max(Float64(ii) * TILE, ex0) / tk
        self.sets[s].good_r[4 * g + 1] = max(Float64(jj) * TILE, ey0) / tk
        self.sets[s].good_r[4 * g + 2] = min(Float64(ii + 1) * TILE, ex1) / tk
        self.sets[s].good_r[4 * g + 3] = min(Float64(jj + 1) * TILE, ey1) / tk
        self.rastered += 1
        return True

    def _damage(mut self, s: Int, dm: List[Float64], fallback: Bool):
        """Frees the tiles (current or fallback) the damage rects (layer units) meet."""
        var tk = self.sets[s].fb_k if fallback else self.sets[s].k
        if tk <= 0:
            return
        var pad = (Float64(TILE_BORDER) + TILE_PAD_PX) / tk
        var gone = List[Int]()
        var keys = List[Int]()
        if fallback:
            for e in self.sets[s].fb.items():
                keys.append(e.key)
        else:
            for e in self.sets[s].tiles.items():
                keys.append(e.key)
        for key in keys:
            var ij = _unpack(key)
            var x0 = Float64(ij[0]) * TILE / tk - pad
            var y0 = Float64(ij[1]) * TILE / tk - pad
            var x1 = Float64(ij[0] + 1) * TILE / tk + pad
            var y1 = Float64(ij[1] + 1) * TILE / tk + pad
            for d in range(len(dm) // 4):
                if dm[4 * d] <= x1 and dm[4 * d + 2] >= x0 and dm[4 * d + 1] <= y1 and dm[4 * d + 3] >= y0:
                    gone.append(key)
                    break
        for key in gone:
            try:
                if fallback:
                    self.free.append(self.sets[s].fb.pop(key))
                else:
                    self.free.append(self.sets[s].tiles.pop(key))
                    _ = self.sets[s].good.pop(key)
                    self.damaged += 1
            except:
                pass
