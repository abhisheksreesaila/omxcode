# mojoui.devrows: rows of an MX frame `DeviceTable`, picked on the GPU. The engine's GPU path aggregates; it has no row
# query (its ORDER BY ... LIMIT runs on the CPU: 190 ms over 100M rows), so a "first k rows" list (a dashboard's table,
# a sheet's preview of a filter) would scan every row on the CPU each time. These read the device copy instead.
#
#   var ctx = DeviceContext()                                                                   # the app's, made once
#   var rows = device_rows(ctx, dt, [ColumnRange(day, lo, hi), ColumnRange(region, 3, 3)], cap)  # matching rows, ascending
#   var first = first_rows(ctx, table, dt, ranges, key, key_lo, counts, 50, tie)                 # ORDER BY key DESC, tie LIMIT 50
#
# `first_rows` needs the matching rows' count per key value (a dense integer key: a DATE, a code), which the caller has
# from the group-by it runs anyway; it finds the last key values that hold k rows and fetches only those rows.
#
# The context is the caller's, not `dt.context()`: outside the program's main module the package's DeviceContext is not
# the one a kernel launch here accepts (Mojo 1.1 + a .mojoc: "no matching method in call to 'enqueue_function'"). Both
# are the device's primary context, so the device table's buffers are valid on it (the test checks every row).

from std.atomic import Atomic, Ordering
from std.math import ceildiv
from max.gpu import global_idx, grid_dim, block_dim
from max.gpu.host import DeviceContext  # (also what makes pointers passable to a kernel)
from mxframe import SharedTable, DeviceTable
from mojoui.gpu import GPU_BUILD

comptime MAX_RANGES = 8


@fieldwise_init
struct ColumnRange(Copyable, ImplicitlyCopyable, Movable):
    """lo ≤ column `col`'s stored value ≤ hi (an equality is lo == hi); a null never matches."""
    var col: Int
    var lo: Int64
    var hi: Int64


def _select_kernel(
    spec: UnsafePointer[Int64, MutAnyOrigin], nranges: Int32, n: Int64,
    dst: UnsafePointer[Int64, MutAnyOrigin], cap: UInt64, counter: UnsafePointer[UInt64, MutAnyOrigin],
):
    """spec: per range (data address, validity address or 0, lo, hi). Matching row numbers go to dst (unordered)."""
    var stride = Int(grid_dim.x) * Int(block_dim.x)
    var i = Int(global_idx.x)
    while i < Int(n):
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
            var at = Atomic.fetch_add[ordering=Ordering.RELAXED](counter, UInt64(1))
            if at < cap:
                dst[unsafe_offset=Int(at)] = Int64(i)
        i += stride


def device_rows(ctx: DeviceContext, dt: DeviceTable, ranges: List[ColumnRange], cap: Int, ordered: Bool = True) raises -> List[Int]:
    """The row numbers (ascending; in no order with ordered=False) whose columns lie inside every range, found on the GPU. Raises when more than `cap`
    rows match (the caller sizes `cap` from a count it knows) or on a build without a GPU. Put the most selective range
    first: a row stops at the first range it fails."""
    if len(ranges) == 0 or len(ranges) > MAX_RANGES:
        raise Error("device_rows: 1 to " + String(MAX_RANGES) + " ranges, not " + String(len(ranges)))
    var n = dt.rows()
    var rows = List[Int]()
    comptime if GPU_BUILD:
        var spec = List[Int64]()
        for r in ranges:
            spec.append(Int64(dt.data_address(r.col)))
            spec.append(Int64(dt.validity_address(r.col)))
            spec.append(r.lo)
            spec.append(r.hi)
        var dspec = ctx.enqueue_create_buffer[DType.int64](len(spec))
        ctx.enqueue_copy(dst_buf=dspec, src_ptr=spec.unsafe_ptr())
        var slots = max(cap, 1)
        var dout = ctx.enqueue_create_buffer[DType.int64](slots)
        var dcount = ctx.enqueue_create_buffer[DType.uint64](1)
        ctx.enqueue_memset(dcount, 0)
        if n > 0:
            ctx.enqueue_function[_select_kernel](
                dspec.unsafe_ptr(), Int32(len(ranges)), Int64(n), dout.unsafe_ptr(), UInt64(cap), dcount.unsafe_ptr(),
                grid_dim=min(ceildiv(n, 256), 82 * 32), block_dim=256,
            )
        var found = List[UInt64](length=1, fill=0)
        ctx.enqueue_copy(dst_ptr=found.unsafe_ptr(), src_buf=dcount)
        ctx.synchronize()
        var k = Int(found[0])
        if k > cap:
            raise Error("device_rows: " + String(k) + " rows match, more than the " + String(cap) + " asked for")
        var got = List[Int64](length=slots, fill=0)  # (the whole buffer comes back: its first k slots are written)
        if k > 0:
            ctx.enqueue_copy(dst_ptr=got.unsafe_ptr(), src_buf=dout)
            ctx.synchronize()
        _ = len(spec)
        rows = List[Int](capacity=k)
        for j in range(k):
            rows.append(Int(got[j]))
        if ordered:
            sort(rows)
    else:
        raise Error("device_rows: no GPU on this build")
    return rows^


def first_rows(
    ctx: DeviceContext, table: SharedTable, dt: DeviceTable, ranges: List[ColumnRange], key: Int, key_lo: Int, counts: List[Int], k: Int,
    tie: Int, descending: Bool = True,
) raises -> List[Int]:
    """The first `k` matching rows in the order (key descending, or ascending, then `tie` ascending): ORDER BY key DESC,
    tie LIMIT k. `counts[j]` is how many rows match `ranges` with key == key_lo + j (every matching row's key is in
    that span). Only the rows of the last key values that hold k rows are fetched from the GPU."""
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
    if descending:
        picked.insert(0, ColumnRange(key, Int64(key_lo + cut), Int64(key_lo + len(counts) - 1)))
    else:
        picked.insert(0, ColumnRange(key, Int64(key_lo), Int64(key_lo + cut)))
    var rows = device_rows(ctx, dt, picked, held, ordered=False)
    if len(rows) != held:
        raise Error("first_rows: the GPU found " + String(len(rows)) + " rows, the counts say " + String(held))
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

    for r in rows:
        if len(best) == want and not before(r, best[want - 1]):
            continue
        var at = len(best)
        while at > 0 and before(r, best[at - 1]):
            at -= 1
        best.insert(at, r)
        if len(best) > want:
            _ = best.pop()
    return best^
