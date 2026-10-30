# mojoui.devrows: rows of an MX frame `DeviceTable`, picked on the GPU. The engine's GPU path aggregates; it has no row
# query (its ORDER BY ... LIMIT runs on the CPU: 190 ms over 100M rows), so a "first k rows" list (a dashboard's table,
# a sheet's preview of a filter) would scan every row on the CPU each time. These read the device copy instead.
#
#   var ctx = DeviceContext()                                                                   # the app's, made once
#   var scratch = GpuScratch()                                                                  # device buffers, reused by every call
#   var rows = device_rows(ctx, dt, [ColumnRange(day, lo, hi), ColumnRange(region, 3, 3)], cap)  # matching rows, ascending
#   var first = first_rows(ctx, table, dt, ranges, key, key_lo, counts, 50, tie)                 # ORDER BY key DESC, tie LIMIT 50
#   var some = device_rows(ctx, dt, ranges, cap, rows=RowSlice(a, b), scratch=scratch)          # only rows a … b − 1 are read
#
# `first_rows` needs the matching rows' count per key value (a dense integer key: a DATE, a code), which the caller has
# from the group-by it runs anyway; it finds the last key values that hold k rows and fetches only those rows. When the
# table is sorted by that key (mojoui.tableprep.sort_rows: pass its SortedKey) those key values are a slice of rows, and
# only that slice is read.
#
# A `GpuScratch` keeps the device buffers a call needs (the ranges, the rows found, a counter) and the device's SM count
# between calls, so a query allocates nothing once warm. Copies of it share the buffers: one call at a time per scratch.
#
# The context is the caller's, not `dt.context()`: outside the program's main module the package's DeviceContext is not
# the one a kernel launch here accepts (Mojo 1.1 + a .mojoc: "no matching method in call to 'enqueue_function'"). Both
# are the device's primary context, so the device table's buffers are valid on it (the test checks every row).

from std.atomic import Atomic, Ordering
from std.math import ceildiv
from std.memory import ArcPointer
from max.gpu import global_idx, grid_dim, block_dim
from max.gpu.host import DeviceContext, DeviceBuffer, DeviceAttribute  # (also what makes pointers passable to a kernel)
from omxcore import SharedTable, DeviceTable
from mojoui.gpu import GPU_BUILD
from mojoui.tableprep import RowSlice, SortedKey

comptime MAX_RANGES = 8


comptime SLOT_SPEC = 0  # GpuScratch slots used here (mojoui.devgroup uses 3 and 4)
comptime SLOT_ROWS = 1
comptime SLOT_COUNT = 2
comptime SLOTS = 6
comptime BLOCKS_PER_SM = 32


struct _Buffers(Movable):
    var bufs: List[Optional[DeviceBuffer[DType.int64]]]
    var caps: List[Int]
    var sms: Int

    def __init__(out self):
        self.bufs = List[Optional[DeviceBuffer[DType.int64]]]()
        self.caps = List[Int]()
        for _ in range(SLOTS):
            self.bufs.append(None)
            self.caps.append(0)
        self.sms = 0


struct GpuScratch(Copyable, ImplicitlyCopyable, Movable):
    """Device buffers kept between calls (copies share them) and the device's SM count, asked once."""
    var _p: ArcPointer[_Buffers]

    def __init__(out self):
        self._p = ArcPointer(_Buffers())

    def int64s(self, ctx: DeviceContext, slot: Int, n: Int) raises -> DeviceBuffer[DType.int64]:
        """At least n int64s of buffer `slot` (made, or remade larger, only when it's too small): the first n."""
        var want = max(n, 1)
        if self._p[].caps[slot] < want:
            var cap = max(want, 2 * self._p[].caps[slot])
            self._p[].bufs[slot] = ctx.enqueue_create_buffer[DType.int64](cap)
            self._p[].caps[slot] = cap
        return self._p[].bufs[slot].value().create_sub_buffer[DType.int64](0, want)

    def reserve_rows(self, ctx: DeviceContext, n: Int) raises:
        """Room for n found rows now (device_rows' buffer), so no query grows it later; the SM count is asked too."""
        _ = self.int64s(ctx, SLOT_ROWS, n)
        _ = self.blocks(ctx, 1)

    def blocks(self, ctx: DeviceContext, rows: Int, block: Int = 256) raises -> Int:
        """A grid for a grid-stride loop over `rows`: enough blocks to fill every SM, no more than the rows need."""
        if self._p[].sms == 0:
            self._p[].sms = max(Int(ctx.get_attribute(DeviceAttribute.MULTIPROCESSOR_COUNT)), 1)
        return max(min(ceildiv(rows, block), self._p[].sms * BLOCKS_PER_SM), 1)


@fieldwise_init
struct ColumnRange(Copyable, ImplicitlyCopyable, Movable):
    """lo ≤ column `col`'s stored value ≤ hi (an equality is lo == hi); a null never matches."""
    var col: Int
    var lo: Int64
    var hi: Int64


def _select_kernel(
    spec: UnsafePointer[Int64, MutAnyOrigin], nranges: Int32, start: Int64, end: Int64,
    dst: UnsafePointer[Int64, MutAnyOrigin], cap: Int64, counter: UnsafePointer[Int64, MutAnyOrigin],
):
    """spec: per range (data address, validity address or 0, lo, hi). Matching row numbers in [start, end) go to dst
    (unordered)."""
    var stride = Int(grid_dim.x) * Int(block_dim.x)
    var i = Int(start) + Int(global_idx.x)
    while i < Int(end):
        var keep = True
        for f in range(Int(nranges)):
            var data = UnsafePointer[Int64, MutAnyOrigin](unsafe_from_address=Int(spec[unsafe_offset=4 * f]))
            var v = data[unsafe_offset=i]
            if v < spec[unsafe_offset=4 * f + 2] or v > spec[unsafe_offset=4 * f + 3]:
                keep = False
                break
            var va = Int(spec[unsafe_offset=4 * f + 1])
            if va != 0:
                var bits = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=va)
                if (bits[unsafe_offset=i >> 3] >> UInt8(i & 7)) & 1 == 0:
                    keep = False
                    break
        if keep:
            var at = Atomic.fetch_add[ordering=Ordering.RELAXED](counter, Int64(1))
            if at < cap:
                dst[unsafe_offset=Int(at)] = Int64(i)
        i += stride


def device_rows(
    ctx: DeviceContext, dt: DeviceTable, ranges: List[ColumnRange], cap: Int, ordered: Bool = True,
    rows: RowSlice = RowSlice.everything(), scratch: GpuScratch = GpuScratch(),
) raises -> List[Int]:
    """The row numbers (ascending; in no order with ordered=False) whose columns lie inside every range, found on the GPU,
    among `rows` (every row by default). Raises when more than `cap` rows match (the caller sizes `cap` from a count it
    knows) or on a build without a GPU. Put the most selective range first: a row stops at the first range it fails.
    Only the rows found are copied back. Pass a kept `scratch` so repeated calls reuse its device buffers."""
    if len(ranges) > MAX_RANGES:
        raise Error("device_rows: up to " + String(MAX_RANGES) + " ranges, not " + String(len(ranges)))
    var span = rows.bounded(dt.rows())
    var found_rows = List[Int]()
    comptime if GPU_BUILD:
        var spec = List[Int64]()
        for r in ranges:
            spec.append(Int64(dt.data_address(r.col)))
            spec.append(Int64(dt.validity_address(r.col)))
            spec.append(r.lo)
            spec.append(r.hi)
        var dspec = scratch.int64s(ctx, SLOT_SPEC, len(spec))
        if len(spec) > 0:
            ctx.enqueue_copy(dst_buf=dspec, src_ptr=spec.unsafe_ptr())
        var dout = scratch.int64s(ctx, SLOT_ROWS, cap)
        var dcount = scratch.int64s(ctx, SLOT_COUNT, 1)
        ctx.enqueue_memset(dcount, 0)
        if span.rows() > 0:
            ctx.enqueue_function[_select_kernel](
                dspec.unsafe_ptr(), Int32(len(ranges)), Int64(span.start), Int64(span.end), dout.unsafe_ptr(), Int64(cap),
                dcount.unsafe_ptr(), grid_dim=scratch.blocks(ctx, span.rows()), block_dim=256,
            )
        var found = List[Int64](length=1, fill=0)
        ctx.enqueue_copy(dst_ptr=found.unsafe_ptr(), src_buf=dcount)
        ctx.synchronize()
        _ = len(spec)
        var k = Int(found[0])
        if k > cap:
            raise Error("device_rows: " + String(k) + " rows match, more than the " + String(cap) + " asked for")
        var got = List[Int64](length=k, fill=0)
        if k > 0:  # (only the k slots written come back)
            ctx.enqueue_copy(dst_ptr=got.unsafe_ptr(), src_buf=dout.create_sub_buffer[DType.int64](0, k))
            ctx.synchronize()
        found_rows = List[Int](capacity=k)
        for j in range(k):
            found_rows.append(Int(got[j]))
        if ordered:
            sort(found_rows)
    else:
        raise Error("device_rows: no GPU on this build")
    return found_rows^


def first_rows(
    ctx: DeviceContext, table: SharedTable, dt: DeviceTable, ranges: List[ColumnRange], key: Int, key_lo: Int, counts: List[Int], k: Int,
    tie: Int, descending: Bool = True, rows: RowSlice = RowSlice.everything(), sorted: Optional[SortedKey] = None,
    scratch: GpuScratch = GpuScratch(),
) raises -> List[Int]:
    """The first `k` matching rows in the order (key descending, or ascending, then `tie` ascending): ORDER BY key DESC,
    tie LIMIT k. `counts[j]` is how many rows match `ranges` (among `rows`) with key == key_lo + j (every matching row's
    key is in that span). Only the rows of the last key values that hold k rows are fetched from the GPU; when the
    table is sorted by `key` (`sorted`), only those rows are read, too."""
    var total = 0
    for c in counts:
        total += c
    var want = min(k, total)
    if want <= 0:
        return List[Int]()
    # the key values that hold the first `want` rows: [cut, end] descending, [start, cut] ascending
    var held = 0
    var cut = 0
    var j = len(counts) - 1 if descending else 0
    while True:
        held += counts[j]
        if held >= want:
            cut = j
            break
        j = j - 1 if descending else j + 1
    var picked = ranges.copy()
    var lo = Int64(key_lo + cut) if descending else Int64(key_lo)
    var hi = Int64(key_lo + len(counts) - 1) if descending else Int64(key_lo + cut)
    var span = rows.bounded(dt.rows())
    if sorted and sorted.value().col == key:  # (those key values are a slice of rows: read only it)
        var s = sorted.value().slice(table, lo, hi)
        span = RowSlice(max(span.start, s.start), max(min(span.end, s.end), max(span.start, s.start)))
    else:
        picked.insert(0, ColumnRange(key, lo, hi))
    var found = device_rows(ctx, dt, picked, held, ordered=False, rows=span, scratch=scratch)
    if len(found) != held:
        raise Error("first_rows: the GPU found " + String(len(found)) + " rows, the counts say " + String(held))
    # the best `want`, kept in order (most rows lose to the last kept one at once)
    var keys = table.values(key)
    var ties = table.values(tie)
    var best = List[Int]()

    @parameter
    def before(a: Int, b: Int) -> Bool:
        """Row a comes before row b: by key (descending or ascending), then tie ascending, then row number."""
        if keys[a] != keys[b]:
            return keys[a] > keys[b] if descending else keys[a] < keys[b]
        if ties[a] != ties[b]:
            return ties[a] < ties[b]
        return a < b

    for r in found:
        if len(best) == want and not before(r, best[want - 1]):
            continue
        var at = len(best)
        while at > 0 and before(r, best[at - 1]):
            at -= 1
        best.insert(at, r)
        if len(best) > want:
            _ = best.pop()
    return best^
