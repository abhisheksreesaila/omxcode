# mojoui.videotable: a video becomes rows (goal 39 M4). VideoSource → per-frame GPU analysis → a table: one row per thing
# seen on a frame (frame, t, kind, x, y, w, h, code, damaged, track), written as CSV or kept as columns in memory.
#
#   var ranges = List[ColourRange]()                       # up to 4 colour classes, measured on the GPU in one pass
#   ranges.append(ColourRange(14, 45, 56, 192, 60, 255))   # hue 14–45°, saturation 56–192, value 60–255 (cardboard, skin)
#   var a = Both(ObjectAnalyzer(...), FaceAnalyzer(...))   # analyzers: anything with step() and finish() (the Analyzer trait)
#   var video = VideoSource("warehouse.mp4")
#   var table = scan(video, a, ranges)                     # every frame, decode overlapped with the GPU
#   table.write_csv("regions.csv")                         # or table.frame / table.kind / table.x … (columns)
#   # csvio.read_table("regions.csv") gives the sheet's (omxcore's) table
#
# What runs where. The GPU cuts each frame into cells (4×4 px by default) and, per cell, counts the pixels inside each
# colour range (HSV, integer arithmetic), sums brightness and the change from the previous frame (motion), and keeps the
# cell's mean colour. Only those small cell grids come back (320×180 cells for 720p). The CPU then joins neighbouring cells
# into regions (connected components: box, area, centroid, mean colour), and analyzers read regions — and, where they need
# detail, a few full-resolution pixels (a stripe code's bars, an edge test).
#
# Honesty: this is classic GPU vision (colour, motion, a printed stripe code), not a learned model. The Analyzer trait is
# the slot a real model plugs into later (served in process by omxconsole, docs/research/inprocess-ai.md): it gets the
# frame's pixels and the cell grid and appends rows, so a detector that returns boxes replaces ObjectAnalyzer without
# changing scan(), the table, the exporter or the sheet.

from std.ffi import external_call
from max.gpu import global_idx
from max.gpu.host import DeviceBuffer, HostBuffer
from std.math import ceildiv
from mojoui.gpu import Gpu, GPU_BUILD
from mojoui.video import VideoSource
from mojoui.clock import now_ns

comptime MAX_CLASSES = 4
comptime NO_CODE = -1
comptime Range8 = SIMD[DType.int32, 8]  # a colour range for the kernel: h_lo, h_hi, s_lo, s_hi, v_lo, v_hi, on, 0


# ---------- colour ranges (HSV in integers: hue 0–359°, saturation and value 0–255) ----------


@fieldwise_init
struct ColourRange(Copyable, Movable, ImplicitlyCopyable):
    """Pixels whose hue is in [h_lo, h_hi] degrees (h_lo > h_hi wraps through red, e.g. 350..16), saturation in
    [s_lo, s_hi] and value (max channel) in [v_lo, v_hi]."""

    var h_lo: Int
    var h_hi: Int
    var s_lo: Int
    var s_hi: Int
    var v_lo: Int
    var v_hi: Int

    def packed(self) -> Range8:
        return Range8(Int32(self.h_lo), Int32(self.h_hi), Int32(self.s_lo), Int32(self.s_hi), Int32(self.v_lo), Int32(self.v_hi), 1, 0)


def _off() -> Range8:
    return Range8(0, 0, 0, 0, 0, 0, 0, 0)


def hsv(p: UInt32) -> Tuple[Int, Int, Int]:
    """A pixel's hue (0–359), saturation and value (0–255), integers (the GPU runs the same code)."""
    var r = Int(p & 0xFF)
    var g = Int((p >> 8) & 0xFF)
    var b = Int((p >> 16) & 0xFF)
    var mx = max(r, max(g, b))
    var mn = min(r, min(g, b))
    var c = mx - mn
    var h = 0
    if c > 0:
        if mx == r:
            h = (60 * (g - b)) // c
            if h < 0:
                h += 360
        elif mx == g:
            h = 120 + (60 * (b - r)) // c
        else:
            h = 240 + (60 * (r - g)) // c
    var s = (c * 255) // mx if mx > 0 else 0
    return (h, s, mx)


def _in(h: Int, s: Int, v: Int, r: Range8) -> Bool:
    if r[6] == 0:
        return False
    var hok = (h >= Int(r[0]) and h <= Int(r[1])) if r[0] <= r[1] else (h >= Int(r[0]) or h <= Int(r[1]))
    return hok and s >= Int(r[2]) and s <= Int(r[3]) and v >= Int(r[4]) and v <= Int(r[5])


def in_range(p: UInt32, r: ColourRange) -> Bool:
    """Whether one pixel is inside the range (the CPU's check, for full-resolution detail)."""
    var t = hsv(p)
    return _in(t[0], t[1], t[2], r.packed())


def luma(p: UInt32) -> Int:
    return (Int(p & 0xFF) * 77 + Int((p >> 8) & 0xFF) * 150 + Int((p >> 16) & 0xFF) * 29) >> 8


# ---------- the per-cell measurement (one function, run by the GPU kernel or by the CPU) ----------


def _cell(
    cur: UnsafePointer[UInt32, MutAnyOrigin], prev: UnsafePointer[UInt32, MutAnyOrigin], w: Int, h: Int, cell: Int,
    cx: Int, cy: Int, rng: UnsafePointer[Int32, MutAnyOrigin],
) -> Tuple[UInt32, UInt32, UInt32]:
    """Cell (cx, cy): (class counts, 8 bits each | brightness sum, 16 bits | motion sum, 16 bits | mean colour)."""
    var n0 = 0
    var n1 = 0
    var n2 = 0
    var n3 = 0
    var lum = 0
    var dif = 0
    var sr = 0
    var sg = 0
    var sb = 0
    var n = 0
    var r0 = rng.unsafe_load[width=8]()
    var r1 = rng.unsafe_offset(8).unsafe_load[width=8]()
    var r2 = rng.unsafe_offset(16).unsafe_load[width=8]()
    var r3 = rng.unsafe_offset(24).unsafe_load[width=8]()
    var y0 = cy * cell
    var x0 = cx * cell
    for y in range(y0, min(y0 + cell, h)):
        for x in range(x0, min(x0 + cell, w)):
            var p = cur.unsafe_offset(y * w + x)[]
            var q = prev.unsafe_offset(y * w + x)[]
            var l = luma(p)
            lum += l
            var d = l - luma(q)
            dif += d if d >= 0 else -d
            sr += Int(p & 0xFF)
            sg += Int((p >> 8) & 0xFF)
            sb += Int((p >> 16) & 0xFF)
            n += 1
            var t = hsv(p)
            if _in(t[0], t[1], t[2], r0):
                n0 += 1
            if _in(t[0], t[1], t[2], r1):
                n1 += 1
            if _in(t[0], t[1], t[2], r2):
                n2 += 1
            if _in(t[0], t[1], t[2], r3):
                n3 += 1
    var counts = UInt32(n0) | (UInt32(n1) << 8) | (UInt32(n2) << 16) | (UInt32(n3) << 24)
    var stats = UInt32(min(lum, 65535)) | (UInt32(min(dif, 65535)) << 16)
    var k = max(n, 1)
    var mean = UInt32(sr // k) | (UInt32(sg // k) << 8) | (UInt32(sb // k) << 16) | 0xFF000000
    return (counts, stats, mean)


def _cells_kernel(
    cur: UnsafePointer[UInt32, MutAnyOrigin], prev: UnsafePointer[UInt32, MutAnyOrigin],
    counts: UnsafePointer[UInt32, MutAnyOrigin], stats: UnsafePointer[UInt32, MutAnyOrigin], means: UnsafePointer[UInt32, MutAnyOrigin],
    w: Int32, h: Int32, cell: Int32, gw: Int32, gh: Int32, rng: UnsafePointer[Int32, MutAnyOrigin],
):
    var cx = Int(global_idx.x)
    var cy = Int(global_idx.y)
    if cx < Int(gw) and cy < Int(gh):
        var t = _cell(cur, prev, Int(w), Int(h), Int(cell), cx, cy, rng)
        var i = cy * Int(gw) + cx
        counts.unsafe_offset(i)[] = t[0]
        stats.unsafe_offset(i)[] = t[1]
        means.unsafe_offset(i)[] = t[2]


struct Cells(Movable):
    """One frame measured per cell: gw × gh cells of `cell` × `cell` pixels."""

    var cell: Int
    var gw: Int
    var gh: Int
    var counts: List[UInt32]  # class k's pixel count in byte k
    var stats: List[UInt32]  # brightness sum (low 16 bits), motion sum (high 16 bits)
    var means: List[UInt32]  # mean colour, RGBA

    def __init__(out self, width: Int, height: Int, cell: Int):
        self.cell = cell
        self.gw = ceildiv(width, cell)
        self.gh = ceildiv(height, cell)
        self.counts = List[UInt32](length=self.gw * self.gh, fill=0)
        self.stats = List[UInt32](length=self.gw * self.gh, fill=0)
        self.means = List[UInt32](length=self.gw * self.gh, fill=0)

    def count(self, cls: Int, cx: Int, cy: Int) -> Int:
        return Int((self.counts[cy * self.gw + cx] >> UInt32(8 * cls)) & 0xFF)

    def count_in(self, cls: Int, x: Int, y: Int, w: Int, h: Int) -> Int:
        """Pixels of class `cls` in the cells that overlap the pixel rectangle."""
        var total = 0
        for cy in range(max(y // self.cell, 0), min((y + h - 1) // self.cell + 1, self.gh)):
            for cx in range(max(x // self.cell, 0), min((x + w - 1) // self.cell + 1, self.gw)):
                total += self.count(cls, cx, cy)
        return total

    def brightness(self) -> Float64:
        """Mean brightness of the frame, 0–255."""
        var s = 0
        for i in range(len(self.stats)):
            s += Int(self.stats[i] & 0xFFFF)
        return Float64(s) / Float64(len(self.stats) * self.cell * self.cell)

    def motion(self) -> Float64:
        """Mean brightness change from the previous frame per pixel, 0–255 (0: a still frame, or the first one)."""
        var s = 0
        for i in range(len(self.stats)):
            s += Int(self.stats[i] >> 16)
        return Float64(s) / Float64(len(self.stats) * self.cell * self.cell)

    def moving(self, cls_threshold: Int = 8) -> Float64:
        """Share of cells whose mean change per pixel is over the threshold (how much of the picture moves)."""
        var k = 0
        var lim = cls_threshold * self.cell * self.cell
        for i in range(len(self.stats)):
            if Int(self.stats[i] >> 16) > lim:
                k += 1
        return Float64(k) / Float64(len(self.stats))


# ---------- regions: neighbouring cells of one colour class, joined ----------


@fieldwise_init
struct Region(Copyable, Movable, ImplicitlyCopyable):
    var x: Int  # bounding box in pixels (cell-aligned)
    var y: Int
    var w: Int
    var h: Int
    var area: Int  # pixels of the class inside it
    var cx: Float64  # centroid in pixels (weighted by the class's pixels per cell)
    var cy: Float64
    var colour: UInt32  # mean colour of its cells (RGBA)


def _find(mut parent: List[Int32], i: Int) -> Int:
    var r = i
    while Int(parent[r]) != r:
        r = Int(parent[r])
    var j = i
    while Int(parent[j]) != r:
        var nxt = Int(parent[j])
        parent[j] = Int32(r)
        j = nxt
    return r


def regions(cells: Cells, cls: Int, min_count: Int = 0, min_area: Int = 0) -> List[Region]:
    """Connected components (8 neighbours) of the cells with more than half their pixels in class `cls` (or at least
    `min_count`), as regions of at least `min_area` pixels, in scan order."""
    var need = min_count if min_count > 0 else (cells.cell * cells.cell) // 2 + 1
    var gw = cells.gw
    var gh = cells.gh
    var n = gw * gh
    var parent = List[Int32](length=n, fill=-1)
    for cy in range(gh):
        for cx in range(gw):
            var i = cy * gw + cx
            if cells.count(cls, cx, cy) < need:
                continue
            parent[i] = Int32(i)
            # join with the already-visited neighbours: left, up-left, up, up-right
            if cx > 0 and parent[i - 1] >= 0:
                var a = _find(parent, i - 1)
                var b = _find(parent, i)
                parent[max(a, b)] = Int32(min(a, b))
            if cy > 0:
                for dx in range(-1, 2):
                    var nx = cx + dx
                    if nx >= 0 and nx < gw and parent[i - gw + dx] >= 0:
                        var a = _find(parent, i - gw + dx)
                        var b = _find(parent, i)
                        parent[max(a, b)] = Int32(min(a, b))
    # gather: root → slot
    var slot = List[Int32](length=n, fill=-1)
    var x0 = List[Int]()
    var y0 = List[Int]()
    var x1 = List[Int]()
    var y1 = List[Int]()
    var area = List[Int]()
    var sx = List[Float64]()
    var sy = List[Float64]()
    var sr = List[Int]()
    var sg = List[Int]()
    var sb = List[Int]()
    var nc = List[Int]()
    for cy in range(gh):
        for cx in range(gw):
            var i = cy * gw + cx
            if parent[i] < 0:
                continue
            var r = _find(parent, i)
            if slot[r] < 0:
                slot[r] = Int32(len(x0))
                x0.append(cx)
                y0.append(cy)
                x1.append(cx)
                y1.append(cy)
                area.append(0)
                sx.append(0)
                sy.append(0)
                sr.append(0)
                sg.append(0)
                sb.append(0)
                nc.append(0)
            var s = Int(slot[r])
            x0[s] = min(x0[s], cx)
            x1[s] = max(x1[s], cx)
            y1[s] = max(y1[s], cy)
            var k = cells.count(cls, cx, cy)
            area[s] += k
            sx[s] += Float64(k) * (Float64(cx * cells.cell) + Float64(cells.cell) / 2)
            sy[s] += Float64(k) * (Float64(cy * cells.cell) + Float64(cells.cell) / 2)
            var m = cells.means[i]
            sr[s] += Int(m & 0xFF)
            sg[s] += Int((m >> 8) & 0xFF)
            sb[s] += Int((m >> 16) & 0xFF)
            nc[s] += 1
    var out = List[Region]()
    for s in range(len(x0)):
        if area[s] < min_area:
            continue
        var c = nc[s]
        out.append(Region(
            x0[s] * cells.cell, y0[s] * cells.cell, (x1[s] - x0[s] + 1) * cells.cell, (y1[s] - y0[s] + 1) * cells.cell,
            area[s], sx[s] / Float64(max(area[s], 1)), sy[s] / Float64(max(area[s], 1)),
            UInt32(sr[s] // c) | (UInt32(sg[s] // c) << 8) | (UInt32(sb[s] // c) << 16) | 0xFF000000,
        ))
    return out^


def bounds_of(cells: Cells, cls: Int, x: Int, y: Int, w: Int, h: Int, min_count: Int = 0) -> Region:
    """The box of class `cls`'s cells inside a pixel rectangle (e.g. a white label inside a pallet); w = 0 if none."""
    var need = min_count if min_count > 0 else (cells.cell * cells.cell) // 2 + 1
    var bx0 = 1 << 30
    var by0 = 1 << 30
    var bx1 = -1
    var by1 = -1
    var area = 0
    for cy in range(max(y // cells.cell, 0), min((y + h) // cells.cell, cells.gh)):
        for cx in range(max(x // cells.cell, 0), min((x + w) // cells.cell, cells.gw)):
            var k = cells.count(cls, cx, cy)
            if k >= need:
                bx0 = min(bx0, cx)
                by0 = min(by0, cy)
                bx1 = max(bx1, cx)
                by1 = max(by1, cy)
                area += k
    if bx1 < 0:
        return Region(0, 0, 0, 0, 0, 0, 0, 0)
    var c = cells.cell
    return Region(bx0 * c, by0 * c, (bx1 - bx0 + 1) * c, (by1 - by0 + 1) * c, area,
                  Float64((bx0 + bx1 + 1) * c) / 2, Float64((by0 + by1 + 1) * c) / 2, 0)


def touches_edge(pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int, box: Region, r: ColourRange) -> Bool:
    """Whether the thing in `box` runs off the picture: a pixel of its colour on the picture's border next to the box
    (full resolution, so "wholly in view" is exact to the pixel, not to the cell)."""
    if box.x <= 0:
        for y in range(max(box.y, 0), min(box.y + box.h, height), 2):
            if in_range(pixels.unsafe_offset(y * width)[], r):
                return True
    if box.x + box.w >= width:
        for y in range(max(box.y, 0), min(box.y + box.h, height), 2):
            if in_range(pixels.unsafe_offset(y * width + width - 1)[], r):
                return True
    if box.y <= 0:
        for x in range(max(box.x, 0), min(box.x + box.w, width), 2):
            if in_range(pixels.unsafe_offset(x)[], r):
                return True
    if box.y + box.h >= height:
        for x in range(max(box.x, 0), min(box.x + box.w, width), 2):
            if in_range(pixels.unsafe_offset((height - 1) * width + x)[], r):
                return True
    return False


# ---------- a printed stripe code (bars on a light label): an OCR stand-in ----------


@fieldwise_init
struct StripeSpec(Copyable, Movable, ImplicitlyCopyable):
    """cells of cell_px each, dark = 1: start pattern (bits, MSB first, start_len of them), id_bits of the id MSB first,
    one even-parity bit over the id when parity, then the stop pattern. rows_from/rows_to: the part of the label's height
    the bars cover (fractions), where scan lines are read."""

    var cell_px: Int
    var start: Int
    var start_len: Int
    var id_bits: Int
    var parity: Bool
    var stop: Int
    var stop_len: Int
    var rows_from: Float64
    var rows_to: Float64

    def cells(self) -> Int:
        return self.start_len + self.id_bits + (1 if self.parity else 0) + self.stop_len


def _decode_line(pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, y: Int, x0: Int, x1: Int, spec: StripeSpec) -> Int:
    var a = max(x0, 0)
    var b = min(x1, width)
    if b - a < spec.cells() * spec.cell_px:
        return NO_CODE
    var lo = 255
    var hi = 0
    for x in range(a, b):
        var l = luma(pixels.unsafe_offset(y * width + x)[])
        lo = min(lo, l)
        hi = max(hi, l)
    if hi - lo < 80:
        return NO_CODE
    var mid = (lo + hi) // 2
    var s = -1
    for x in range(a, b):
        if luma(pixels.unsafe_offset(y * width + x)[]) < mid:
            s = x
            break
    if s < 0 or s + spec.cells() * spec.cell_px > b:
        return NO_CODE
    var bits = List[Int]()
    for i in range(spec.cells()):
        var px = s + i * spec.cell_px + spec.cell_px // 2
        bits.append(1 if luma(pixels.unsafe_offset(y * width + px)[]) < mid else 0)
    var k = 0
    for i in range(spec.start_len):
        if bits[k] != (spec.start >> (spec.start_len - 1 - i)) & 1:
            return NO_CODE
        k += 1
    var id = 0
    var ones = 0
    for _ in range(spec.id_bits):
        id = id * 2 + bits[k]
        ones += bits[k]
        k += 1
    if spec.parity:
        if bits[k] != ones % 2:
            return NO_CODE
        k += 1
    for i in range(spec.stop_len):
        if bits[k] != (spec.stop >> (spec.stop_len - 1 - i)) & 1:
            return NO_CODE
        k += 1
    return id


def read_stripe_code(pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int, label: Region, spec: StripeSpec) -> Int:
    """The id printed on a label (box `label`, full-resolution pixels), or NO_CODE: several scan lines across the bars;
    the answer is the one most lines agree on (start, stop and parity must check on each)."""
    var best = NO_CODE
    var votes = 0
    var ids = List[Int]()
    var lines = 5
    for i in range(lines):
        var f = spec.rows_from + (spec.rows_to - spec.rows_from) * (Float64(i) + 0.5) / Float64(lines)
        var y = label.y + Int(f * Float64(label.h))
        if y < 0 or y >= height:
            continue
        var id = _decode_line(pixels, width, y, label.x - 2, label.x + label.w + 2, spec)
        if id != NO_CODE:
            ids.append(id)
    for i in range(len(ids)):
        var k = 0
        for j in range(len(ids)):
            if ids[j] == ids[i]:
                k += 1
        if k > votes:
            votes = k
            best = ids[i]
    return best if votes >= 2 else NO_CODE


# ---------- the table ----------


struct VideoTable(Movable):
    """Rows, as columns: frame, t (s), kind, x, y, w, h, code (NO_CODE: none), damaged, track (-1: none); and per frame
    brightness and motion (frame_brightness[i], frame_motion[i])."""

    var frame: List[Int]
    var t: List[Float64]
    var kind: List[String]
    var x: List[Int]
    var y: List[Int]
    var w: List[Int]
    var h: List[Int]
    var code: List[Int]
    var damaged: List[Bool]
    var track: List[Int]
    var frame_brightness: List[Float64]
    var frame_motion: List[Float64]
    var fps: Float64
    var frames: Int
    var seconds: Float64  # scan(): wall time, decode included

    def __init__(out self):
        self.frame = List[Int]()
        self.t = List[Float64]()
        self.kind = List[String]()
        self.x = List[Int]()
        self.y = List[Int]()
        self.w = List[Int]()
        self.h = List[Int]()
        self.code = List[Int]()
        self.damaged = List[Bool]()
        self.track = List[Int]()
        self.frame_brightness = List[Float64]()
        self.frame_motion = List[Float64]()
        self.fps = 30
        self.frames = 0
        self.seconds = 0

    def rows(self) -> Int:
        return len(self.frame)

    def add(mut self, frame: Int, kind: String, x: Int, y: Int, w: Int, h: Int, code: Int = NO_CODE, damaged: Bool = False, track: Int = -1):
        self.frame.append(frame)
        self.t.append(Float64(frame) / self.fps)
        self.kind.append(kind)
        self.x.append(x)
        self.y.append(y)
        self.w.append(w)
        self.h.append(h)
        self.code.append(code)
        self.damaged.append(damaged)
        self.track.append(track)

    def frames_per_second(self) -> Float64:
        return Float64(self.frames) / self.seconds if self.seconds > 0 else 0

    def csv(self) -> String:
        var out = String("frame,t,kind,x,y,w,h,code,damaged,track\n")
        for i in range(self.rows()):
            out += String(self.frame[i]) + "," + _fixed3(self.t[i]) + "," + self.kind[i] + "," + String(self.x[i]) + ","
            out += String(self.y[i]) + "," + String(self.w[i]) + "," + String(self.h[i]) + ","
            out += (String(self.code[i]) if self.code[i] != NO_CODE else String("")) + ","
            out += ("1" if self.damaged[i] else "0") + "," + String(self.track[i]) + "\n"
        return out

    def write_csv(self, path: String) raises:
        with open(path, "w") as f:
            f.write(self.csv())

    def intervals(self, kind: String, damaged_only: Bool = False) -> List[Tuple[Int, Int]]:
        """Frame ranges [start, end) during which a row of this kind (damaged ones only, if asked) is on screen, merged."""
        var on = List[Bool](length=self.frames + 1, fill=False)
        for i in range(self.rows()):
            if self.kind[i] == kind and (self.damaged[i] or not damaged_only) and self.frame[i] < len(on):
                on[self.frame[i]] = True
        var out = List[Tuple[Int, Int]]()
        var start = -1
        for f in range(len(on)):
            if on[f] and start < 0:
                start = f
            elif not on[f] and start >= 0:
                out.append((start, f))
                start = -1
        return out^


def _fixed3(v: Float64) -> String:
    var m = Int(v * 1000 + 0.5)
    var frac = String(m % 1000)
    while frac.byte_length() < 3:
        frac = "0" + frac
    return String(m // 1000) + "." + frac


# ---------- analyzers ----------


trait Analyzer(Movable, Deinitable):
    """The slot a detector fills: called once per frame with its full-resolution pixels and the GPU's cell grid; appends
    rows (now, or in finish(), once it has seen every frame, e.g. to give a tracked object one code)."""

    def step(mut self, frame: Int, pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int, cells: Cells, mut table: VideoTable) raises:
        ...

    def finish(mut self, mut table: VideoTable) raises:
        ...


struct Both[A: Analyzer, B: Analyzer](Analyzer):
    """Two analyzers on the same frames (nest Both for more)."""

    var a: Self.A
    var b: Self.B

    def __init__(out self, var a: Self.A, var b: Self.B):
        self.a = a^
        self.b = b^

    def step(mut self, frame: Int, pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int, cells: Cells, mut table: VideoTable) raises:
        self.a.step(frame, pixels, width, height, cells, table)
        self.b.step(frame, pixels, width, height, cells, table)

    def finish(mut self, mut table: VideoTable) raises:
        self.a.finish(table)
        self.b.finish(table)


struct RegionsAnalyzer(Analyzer):
    """The generic one: every region of one colour class whose box is within the size limits, as a row of `kind`."""

    var kind: String
    var cls: Int
    var min_w: Int
    var max_w: Int
    var min_h: Int
    var max_h: Int

    def __init__(out self, kind: String, cls: Int, min_w: Int = 8, max_w: Int = 100000, min_h: Int = 8, max_h: Int = 100000):
        self.kind = kind
        self.cls = cls
        self.min_w = min_w
        self.max_w = max_w
        self.min_h = min_h
        self.max_h = max_h

    def step(mut self, frame: Int, pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int, cells: Cells, mut table: VideoTable) raises:
        for r in regions(cells, self.cls):
            if r.w >= self.min_w and r.w <= self.max_w and r.h >= self.min_h and r.h <= self.max_h:
                table.add(frame, self.kind, r.x, r.y, r.w, r.h)

    def finish(mut self, mut table: VideoTable) raises:
        pass


struct FaceAnalyzer(Analyzer):
    """Faces as skin-tone disks: regions of the skin class sized like a head (hair may cover the top: the box is made
    square, upward from the chin). Boxes for blurring, so they err on the large side."""

    var cls: Int
    var min_w: Int
    var max_w: Int
    var max_h: Int

    def __init__(out self, cls: Int, min_w: Int = 24, max_w: Int = 140, max_h: Int = 96):
        self.cls = cls
        self.min_w = min_w
        self.max_w = max_w
        self.max_h = max_h

    def step(mut self, frame: Int, pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int, cells: Cells, mut table: VideoTable) raises:
        for r in regions(cells, self.cls, min_area=120):
            if r.w >= self.min_w and r.w <= self.max_w and r.h <= self.max_h and r.h >= 8:
                var side = max(r.w, r.h)
                table.add(frame, "face", r.x + r.w // 2 - side // 2, r.y + r.h - side, side, side)

    def finish(mut self, mut table: VideoTable) raises:
        pass


@fieldwise_init
struct _Seen(Copyable, Movable, ImplicitlyCopyable):
    var frame: Int
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var whole: Bool


struct Track(Copyable, Movable):
    """One object followed across frames: where it was, the codes read on it (votes), the frames its defect showed."""

    var id: Int
    var seen: List[_Seen]
    var codes: List[Int]
    var defect_frames: Int
    var last_frame: Int
    var vx: Float64  # pixels per frame
    var vy: Float64

    def __init__(out self, id: Int):
        self.id = id
        self.seen = List[_Seen]()
        self.codes = List[Int]()
        self.defect_frames = 0
        self.last_frame = -1
        self.vx = 0
        self.vy = 0

    def code(self) -> Int:
        """The code most of its reads agree on (NO_CODE: never read)."""
        var best = NO_CODE
        var votes = 0
        for i in range(len(self.codes)):
            var k = 0
            for j in range(len(self.codes)):
                if self.codes[j] == self.codes[i]:
                    k += 1
            if k > votes:
                votes = k
                best = self.codes[i]
        return best

    def centre(self) -> Tuple[Float64, Float64]:
        ref s = self.seen[len(self.seen) - 1]
        return (Float64(s.x) + Float64(s.w) / 2, Float64(s.y) + Float64(s.h) / 2)


struct ObjectAnalyzer(Analyzer):
    """Objects of one colour (min size), tracked across frames (by the code read on them; by position, with their own
    velocity, while it can't be read). On each: a light label (class `label_cls`) carrying a stripe code, and a defect
    colour (class `defect_cls`, -1: none) whose pixels inside the box mark it damaged. Rows only for frames on which the
    object is wholly in view (the convention the truth uses); code and damaged are the track's, written in finish()."""

    var kind: String
    var colour: ColourRange
    var cls: Int
    var label_cls: Int
    var defect_cls: Int
    var spec: StripeSpec
    var min_w: Int
    var min_h: Int
    var defect_px: Int  # defect pixels inside the box for the frame to count
    var defect_min_frames: Int  # frames with the defect for the object to be damaged
    var max_jump: Float64  # pixels a tracked object may move between frames beyond its velocity
    var tracks: List[Track]
    var active: List[Int]

    def __init__(out self, kind: String, colour: ColourRange, cls: Int, label_cls: Int, defect_cls: Int, spec: StripeSpec,
                 min_w: Int = 96, min_h: Int = 96, defect_px: Int = 200, defect_min_frames: Int = 3, max_jump: Float64 = 40):
        self.kind = kind
        self.colour = colour
        self.cls = cls
        self.label_cls = label_cls
        self.defect_cls = defect_cls
        self.spec = spec
        self.min_w = min_w
        self.min_h = min_h
        self.defect_px = defect_px
        self.defect_min_frames = defect_min_frames
        self.max_jump = max_jump
        self.tracks = List[Track]()
        self.active = List[Int]()

    def step(mut self, frame: Int, pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int, cells: Cells, mut table: VideoTable) raises:
        var taken = List[Bool](length=len(self.active), fill=False)
        var still = List[Int]()
        for r in regions(cells, self.cls, min_area=self.min_w * self.min_h // 4):
            if r.w < self.min_w or r.h < self.min_h:
                continue
            var whole = not touches_edge(pixels, width, height, r, self.colour)
            var code = NO_CODE
            if whole and self.label_cls >= 0:
                var label = bounds_of(cells, self.label_cls, r.x + cells.cell, r.y + cells.cell, r.w - 2 * cells.cell, r.h - 2 * cells.cell)
                if label.w >= self.spec.cells() * self.spec.cell_px:
                    code = read_stripe_code(pixels, width, height, label, self.spec)
            var defect = self.defect_cls >= 0 and cells.count_in(self.defect_cls, r.x, r.y, r.w, r.h) >= self.defect_px
            # match: the same code, else the nearest predicted position
            var cx = Float64(r.x) + Float64(r.w) / 2
            var cy = Float64(r.y) + Float64(r.h) / 2
            var best = -1
            var best_d = 1e30
            for k in range(len(self.active)):
                if taken[k]:
                    continue
                ref tr = self.tracks[self.active[k]]
                var tc = tr.code()
                if code != NO_CODE and tc != NO_CODE and len(tr.codes) >= 2:
                    if tc == code:
                        best = k
                        best_d = 0
                        break
                    continue
                var c = tr.centre()
                var gap = Float64(frame - tr.last_frame)
                var dx = cx - (c[0] + tr.vx * gap)
                var dy = cy - (c[1] + tr.vy * gap)
                var d = (dx * dx + dy * dy) ** 0.5
                # an object entering or leaving changes its box's width: compare the edge that stays in view too
                var s = tr.seen[len(tr.seen) - 1]
                var dl = abs(Float64(r.x) - (Float64(s.x) + tr.vx * gap))
                var dr = abs(Float64(r.x + r.w) - (Float64(s.x + s.w) + tr.vx * gap))
                d = min(d, min(dl, dr) + abs(dy))
                if d < best_d:
                    best_d = d
                    best = k
            var ti: Int
            if best >= 0 and best_d <= self.max_jump:
                taken[best] = True
                ti = self.active[best]
            else:
                ti = len(self.tracks)
                self.tracks.append(Track(ti))
            ref tr = self.tracks[ti]
            if len(tr.seen) > 0 and whole and tr.seen[len(tr.seen) - 1].whole:
                var c = tr.centre()
                var gap = Float64(max(frame - tr.last_frame, 1))
                var vx = (cx - c[0]) / gap
                var vy = (cy - c[1]) / gap
                tr.vx = vx if tr.vx == 0 else 0.7 * tr.vx + 0.3 * vx
                tr.vy = vy if tr.vy == 0 else 0.7 * tr.vy + 0.3 * vy
            tr.seen.append(_Seen(frame, r.x, r.y, r.w, r.h, whole))
            tr.last_frame = frame
            if code != NO_CODE:
                tr.codes.append(code)
            if defect and whole:
                tr.defect_frames += 1
            still.append(ti)
        # tracks not seen for a while are done
        for k in range(len(self.active)):
            if not taken[k] and frame - self.tracks[self.active[k]].last_frame < 15:
                var dup = False
                for s in still:
                    if s == self.active[k]:
                        dup = True
                if not dup:
                    still.append(self.active[k])
        self.active = still^

    def finish(mut self, mut table: VideoTable) raises:
        for ref tr in self.tracks:
            var code = tr.code()
            var damaged = tr.defect_frames >= self.defect_min_frames
            for s in tr.seen:
                if s.whole:
                    table.add(s.frame, self.kind, s.x, s.y, s.w, s.h, code, damaged, tr.id)


# ---------- the scan: decode → GPU cells → analyzers, frame after frame ----------


struct CellGpu(Movable):
    """The GPU side of scan(): device buffers for this frame and the last (motion), the cell grids, pinned host memory
    for the frames so a copy can run while the next frame is read."""

    var gpu: Gpu
    var width: Int
    var height: Int
    var cell: Int
    var gw: Int
    var gh: Int
    var dev: List[DeviceBuffer[DType.uint32]]  # two frames (current, previous)
    var host: List[HostBuffer[DType.uint32]]  # two frames, pinned
    var out: List[DeviceBuffer[DType.uint32]]  # counts, stats, means
    var out_host: List[HostBuffer[DType.uint32]]
    var ranges: List[Int32]  # MAX_CLASSES ranges, 8 words each (ColourRange.packed)
    var rng_dev: List[DeviceBuffer[DType.int32]]

    def __init__(out self, width: Int, height: Int, cell: Int, ranges: List[ColourRange], use_gpu: Bool = True) raises:
        self.gpu = Gpu(use_gpu)
        self.width = width
        self.height = height
        self.cell = cell
        self.gw = ceildiv(width, cell)
        self.gh = ceildiv(height, cell)
        self.dev = List[DeviceBuffer[DType.uint32]]()
        self.host = List[HostBuffer[DType.uint32]]()
        self.out = List[DeviceBuffer[DType.uint32]]()
        self.out_host = List[HostBuffer[DType.uint32]]()
        self.ranges = _range_words(ranges)
        self.rng_dev = List[DeviceBuffer[DType.int32]]()
        comptime if GPU_BUILD:
            if self.gpu.ctx:
                ref ctx = self.gpu.ctx.value()
                for _ in range(2):
                    self.dev.append(ctx.enqueue_create_buffer[DType.uint32](width * height))
                    self.host.append(ctx.enqueue_create_host_buffer[DType.uint32](width * height))
                for _ in range(3):
                    self.out.append(ctx.enqueue_create_buffer[DType.uint32](self.gw * self.gh))
                    self.out_host.append(ctx.enqueue_create_host_buffer[DType.uint32](self.gw * self.gh))
                self.rng_dev.append(ctx.enqueue_create_buffer[DType.int32](8 * MAX_CLASSES))
                ctx.enqueue_copy(dst_buf=self.rng_dev[0], src_ptr=self.ranges.unsafe_ptr())
                ctx.synchronize()

    def on_gpu(self) -> Bool:
        return len(self.dev) == 2

    def frame_ptr(self, slot: Int) -> UnsafePointer[UInt32, MutAnyOrigin]:
        return _addr(Int(self.host[slot].unsafe_ptr()))

    def launch(mut self, slot: Int, first: Bool) raises:
        """Starts measuring host frame `slot` (the other slot holds the previous frame); returns before it is done."""
        comptime if GPU_BUILD:
            ref ctx = self.gpu.ctx.value()
            ctx.enqueue_copy(dst_buf=self.dev[slot], src_buf=self.host[slot])
            var prev = _addr(Int(self.dev[slot if first else 1 - slot].unsafe_ptr()))
            ctx.enqueue_function[_cells_kernel](
                _addr(Int(self.dev[slot].unsafe_ptr())), prev, _addr(Int(self.out[0].unsafe_ptr())),
                _addr(Int(self.out[1].unsafe_ptr())), _addr(Int(self.out[2].unsafe_ptr())),
                Int32(self.width), Int32(self.height), Int32(self.cell), Int32(self.gw), Int32(self.gh),
                UnsafePointer[Int32, MutAnyOrigin](unsafe_from_address=Int(self.rng_dev[0].unsafe_ptr())),
                grid_dim=(ceildiv(self.gw, 16), ceildiv(self.gh, 16)), block_dim=(16, 16),
            )
            for k in range(3):
                ctx.enqueue_copy(dst_buf=self.out_host[k], src_buf=self.out[k])

    def collect(mut self, mut cells: Cells) raises:
        """Waits for launch() and copies its grids into `cells`."""
        comptime if GPU_BUILD:
            self.gpu.ctx.value().synchronize()
            var n = self.gw * self.gh
            var a = _addr(Int(self.out_host[0].unsafe_ptr()))
            var b = _addr(Int(self.out_host[1].unsafe_ptr()))
            var c = _addr(Int(self.out_host[2].unsafe_ptr()))
            for i in range(n):
                cells.counts[i] = a.unsafe_offset(i)[]
                cells.stats[i] = b.unsafe_offset(i)[]
                cells.means[i] = c.unsafe_offset(i)[]


def _range_words(ranges: List[ColourRange]) -> List[Int32]:
    var out = List[Int32]()
    for i in range(MAX_CLASSES):
        var r = ranges[i].packed() if i < len(ranges) else _off()
        for k in range(8):
            out.append(r[k])
    return out^


def _addr(a: Int) -> UnsafePointer[UInt32, MutAnyOrigin]:
    return UnsafePointer[UInt32, MutAnyOrigin](unsafe_from_address=a)


def measure_cpu(pixels: UnsafePointer[UInt32, MutAnyOrigin], prev: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int,
                ranges: List[ColourRange], mut cells: Cells):
    """The same measurement on the CPU (machines without a GPU, and the GPU's check)."""
    var words = _range_words(ranges)
    var rp = UnsafePointer[Int32, MutAnyOrigin](unsafe_from_address=Int(words.unsafe_ptr()))
    for cy in range(cells.gh):
        for cx in range(cells.gw):
            var t = _cell(pixels, prev, width, height, cells.cell, cx, cy, rp)
            var i = cy * cells.gw + cx
            cells.counts[i] = t[0]
            cells.stats[i] = t[1]
            cells.means[i] = t[2]


def scan[A: Analyzer](mut video: VideoSource, mut analyzer: A, ranges: List[ColourRange], cell: Int = 4, use_gpu: Bool = True,
                      limit: Int = 0) raises -> VideoTable:
    """Every frame of `video` (from where it is; `limit` > 0: at most that many) through the GPU measurement and the
    analyzer. On the GPU, frame n+1 is read from the decoder while frame n is measured."""
    var table = VideoTable()
    table.fps = video.fps
    var w = video.width
    var h = video.height
    var cells = Cells(w, h, cell)
    var g = CellGpu(w, h, cell, ranges, use_gpu)
    var t0 = Int(now_ns())
    var n = 0
    var start = video.position()
    if g.on_gpu():
        var slot = 0
        var have = video.next_into_address(Int(g.frame_ptr(slot)))
        var first = True
        while have and (limit <= 0 or n < limit):
            g.launch(slot, first)
            first = False
            # read the next frame into the other pinned buffer while the GPU works on this one
            var more = (limit <= 0 or n + 1 < limit) and video.next_into_address(Int(g.frame_ptr(1 - slot)))
            g.collect(cells)
            table.frame_brightness.append(cells.brightness())
            table.frame_motion.append(cells.motion())
            analyzer.step(start + n, g.frame_ptr(slot), w, h, cells, table)
            n += 1
            slot = 1 - slot
            have = more
    else:
        var cur = List[UInt32](length=w * h, fill=0)
        var prev = List[UInt32](length=w * h, fill=0)
        var first = True
        while (limit <= 0 or n < limit) and video.next_into(cur):
            var pc = UnsafePointer[UInt32, MutAnyOrigin](unsafe_from_address=Int(cur.unsafe_ptr()))
            var pp = UnsafePointer[UInt32, MutAnyOrigin](unsafe_from_address=Int(prev.unsafe_ptr()))
            measure_cpu(pc, pc if first else pp, w, h, ranges, cells)
            first = False
            table.frame_brightness.append(cells.brightness())
            table.frame_motion.append(cells.motion())
            analyzer.step(start + n, pc, w, h, cells, table)
            n += 1
            swap(cur, prev)
    analyzer.finish(table)
    table.frames = n
    table.seconds = Float64(Int(now_ns()) - t0) / 1e9
    return table^
