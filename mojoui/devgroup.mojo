# mojoui.devgroup: a group-by over the rows of an MX frame `DeviceTable` on the GPU, limited to a slice of rows. The
# engine's GPU Query reads every row of the table on each call; when the table is sorted by a time column
# (mojoui.tableprep.sort_rows) a date range is a slice of rows, and this reads only that slice.
#
#   var key = dcol(product) * dlit(days) + (dcol(day) - dlit(first))                  # a dense group number, 0 … groups − 1
#   var g = group_rows(ctx, dt, [ColumnRange(region, 3, 3)], key, groups, [dcol(amount), (dcol(amount) - dcol(cost)) // dcol(amount)],
#                      rows=by_day.slice(table, lo, hi), scratch=scratch)
#   g.counts[k], g.sums[0][k], g.sums[1][k]                                            # per group: rows, and each sum
#   var both = group_sets(ctx, dt, ranges, [GroupSet(dcol(product), 40, sums), GroupSet(dcol(day) - dlit(first), days)], rows=…)
#
# `group_sets` is SQL's GROUPING SETS: several group-bys over the same matching rows in one pass (each row read once).
#
# Keys and values are small integer programs over int64 columns (+ − × // and constants, four deep at most), summed
# exactly in int64 (wrapping, as the engine's INT sums: the caller keeps them in range). A row whose key falls outside
# 0 … groups − 1 is skipped. Few groups (Σ groups × (sums + 1) ≤ SHARED_SLOTS over the sets) add up per block in
# shared memory first; more go straight to global atomics. Columns read by a program must have no nulls (a filter's column may).

from std.atomic import Atomic, Ordering
from std.memory import stack_allocation
from std.bit import pop_count, count_trailing_zeros
from std.math import ceildiv
from max.gpu import global_idx, grid_dim, block_dim, thread_idx, barrier
from max.gpu.primitives.warp import vote, shuffle_idx, shuffle_down
from max.gpu.primitives.id import lane_id
from max.gpu.host import DeviceContext
from max.gpu.memory import AddressSpace
from omxcore import DeviceTable
from mojoui.gpu import GPU_BUILD
from mojoui.devrows import ColumnRange, GpuScratch, MAX_RANGES
from mojoui.tableprep import RowSlice
from mojoui.clock import now_ns

comptime OP_LIT = 0
comptime OP_COL = 1
comptime OP_ADD = 2
comptime OP_SUB = 3
comptime OP_MUL = 4
comptime OP_FLOORDIV = 5
comptime MAX_DEPTH = 4
comptime SHARED_SLOTS = 3584  # int64 accumulators per block in shared memory (28 KiB: with MAX_SPEC, 32 KiB, every GPU's floor, D-789)
comptime MAX_SUMS = 6
comptime MAX_SPEC = 512  # int64s of a call's spec (ranges and programs), staged in shared memory per block
comptime SLOT_GSPEC = 3  # GpuScratch slots (mojoui.devrows uses 0–2)
comptime SLOT_ACC = 4


struct DevExpr(Copyable, Movable):
    """An integer expression over a row's columns, kept as a postfix program: (op, arg) pairs (arg: a column for
    OP_COL, the value for OP_LIT)."""
    var prog: List[Int64]

    def __init__(out self, var prog: List[Int64]):
        self.prog = prog^

    def _join(self, other: DevExpr, op: Int) -> DevExpr:
        var p = self.prog.copy()
        p.extend(other.prog.copy())
        p.append(Int64(op))
        p.append(0)
        return DevExpr(p^)

    def __add__(self, other: DevExpr) -> DevExpr:
        return self._join(other, OP_ADD)

    def __sub__(self, other: DevExpr) -> DevExpr:
        return self._join(other, OP_SUB)

    def __mul__(self, other: DevExpr) -> DevExpr:
        return self._join(other, OP_MUL)

    def __floordiv__(self, other: DevExpr) -> DevExpr:
        """Floor division (x // 0 is 0)."""
        return self._join(other, OP_FLOORDIV)

    def depth(self) -> Int:
        var d = 0
        var most = 0
        for k in range(len(self.prog) // 2):
            d += 1 if self.prog[2 * k] <= OP_COL else -1
            most = max(most, d)
        return most

    def eval(self, values: List[Int64]) -> Int64:
        """The value for one row whose columns are `values` (the CPU's answer, for tests)."""
        var stack = List[Int64]()
        for k in range(len(self.prog) // 2):
            var op = Int(self.prog[2 * k])
            var arg = self.prog[2 * k + 1]
            if op == OP_LIT:
                stack.append(arg)
            elif op == OP_COL:
                stack.append(values[Int(arg)])
            else:
                var b = stack.pop()
                var a = stack.pop()
                stack.append(_apply(op, a, b))
        return stack[0] if len(stack) > 0 else 0


def dcol(c: Int) -> DevExpr:
    return DevExpr([Int64(OP_COL), Int64(c)])


def dlit(v: Int) -> DevExpr:
    return DevExpr([Int64(OP_LIT), Int64(v)])


@always_inline
def _apply(op: Int, a: Int64, b: Int64) -> Int64:
    if op == OP_ADD:
        return a + b
    if op == OP_SUB:
        return a - b
    if op == OP_MUL:
        return a * b
    return a // b if b != 0 else 0


@always_inline
def _warp_sum(v: Int64) -> Int64:
    """The sum over the warp's 32 lanes, in lane 0 (shuffles move 32 bits: two halves)."""
    var x = v
    comptime for k in range(5):
        var bits = UInt64(x)
        var lo = shuffle_down(UInt32(bits & 0xFFFFFFFF), UInt32(16 >> k))
        var hi = shuffle_down(UInt32(bits >> 32), UInt32(16 >> k))
        x += Int64((UInt64(hi) << 32) | UInt64(lo))
    return x


@always_inline
def _add(shared: Bool, local: Pointer[Int64, MutUntrackedOrigin, address_space=AddressSpace.SHARED], acc: UnsafePointer[Int64, MutAnyOrigin], k: Int, v: Int64):
    if shared:
        _ = Atomic.fetch_add[ordering=Ordering.RELAXED](local + k, v)
    else:
        _ = Atomic.fetch_add[ordering=Ordering.RELAXED](acc + k, v)


@always_inline
def _eval(spec: Pointer[Int64, MutUntrackedOrigin, address_space=AddressSpace.SHARED], at: Int, n: Int, i: Int) -> Int64:
    """Program spec[at : at + 2n] for row i (OP_COL's arg is the column's device address), the stack in four registers."""
    var s0: Int64 = 0
    var s1: Int64 = 0
    var s2: Int64 = 0
    var s3: Int64 = 0
    var sp = 0
    for k in range(n):
        var op = Int(spec[at + 2 * k])
        var arg = spec[at + 2 * k + 1]
        if op <= OP_COL:
            var v = arg if op == OP_LIT else UnsafePointer[Int64, MutAnyOrigin](unsafe_from_address=Int(arg))[unsafe_offset=i]
            if sp == 0:
                s0 = v
            elif sp == 1:
                s1 = v
            elif sp == 2:
                s2 = v
            else:
                s3 = v
            sp += 1
        else:
            sp -= 1
            var b = s3 if sp == 3 else (s2 if sp == 2 else s1)
            var a = s2 if sp == 3 else (s1 if sp == 2 else s0)
            var r = _apply(op, a, b)
            if sp == 1:
                s0 = r
            elif sp == 2:
                s1 = r
            else:
                s2 = r
    return s0


def _group_kernel(
    gspec: UnsafePointer[Int64, MutAnyOrigin], nspec: Int64, start: Int64, end: Int64, acc: UnsafePointer[Int64, MutAnyOrigin],
    slots: Int64,
):
    """spec: nranges, nsets, then per range (data, validity or 0, lo, hi), then per set: groups, its first slot, nsums,
    the key (length, pairs), each sum (length, pairs). acc: per set, per group, the count then each sum."""
    var local = stack_allocation[SHARED_SLOTS, Int64, address_space=AddressSpace.SHARED]()
    var spec = stack_allocation[MAX_SPEC, Int64, address_space=AddressSpace.SHARED]()
    var shared = Int(slots) <= SHARED_SLOTS
    var t = Int(thread_idx.x)
    var k = t
    while k < Int(nspec):
        spec[k] = gspec[unsafe_offset=k]
        k += Int(block_dim.x)
    if shared:
        k = t
        while k < Int(slots):
            local[k] = 0
            k += Int(block_dim.x)
    barrier()
    var nranges = Int(spec[0])
    var nsets = Int(spec[1])
    var sets_at = 2 + 4 * nranges
    var stride = Int(grid_dim.x) * Int(block_dim.x)
    var lane = Int(lane_id())
    var i = Int(start) + Int(global_idx.x)
    # (every lane runs the same number of turns, so the warp's votes and shuffles see all 32 lanes)
    for _ in range(ceildiv(Int(end) - Int(start), stride)):
        var keep = i < Int(end)
        var row = i if keep else Int(start)  # (a lane past the end reads a real row and adds nothing)
        for f in range(nranges):  # (no early exit: every lane of a warp does the same reads)
            var data = UnsafePointer[Int64, MutAnyOrigin](unsafe_from_address=Int(spec[2 + 4 * f]))
            var v = data[unsafe_offset=row]
            keep = keep and v >= spec[2 + 4 * f + 2] and v <= spec[2 + 4 * f + 3]
            var va = Int(spec[2 + 4 * f + 1])
            if va != 0:
                var bits = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=va)
                keep = keep and (bits[unsafe_offset=row >> 3] >> UInt8(row & 7)) & 1 != 0
        if vote[DType.uint32](keep) != UInt32(0):
            var at = sets_at
            for _ in range(nsets):
                var groups = Int(spec[at])
                var first = Int(spec[at + 1])
                var nsums = Int(spec[at + 2])
                var key_n = Int(spec[at + 3])
                var g = Int(_eval(spec, at + 4, key_n, row))
                at += 4 + 2 * key_n
                var adds = keep and g >= 0 and g < groups
                var who = vote[DType.uint32](adds)
                if who == UInt32(0):
                    for _ in range(nsums):
                        at += 1 + 2 * Int(spec[at])
                    continue
                # one group for every lane that adds (rows in key order: a time key): the warp adds up, lane 0 adds once
                var g0 = shuffle_idx(Int32(g), UInt32(count_trailing_zeros(who)))
                var uniform = vote[DType.uint32](not adds or Int32(g) == g0) == UInt32(0xFFFFFFFF)
                var base = first + g * (nsums + 1)
                if uniform:
                    base = first + Int(g0) * (nsums + 1)
                    if lane == 0:
                        _add(shared, local, acc, base, Int64(pop_count(who)))
                elif adds:
                    _add(shared, local, acc, base, Int64(1))
                for s in range(nsums):
                    var n = Int(spec[at])
                    var v = _eval(spec, at + 1, n, row) if adds else Int64(0)
                    if uniform:
                        var total = _warp_sum(v)
                        if lane == 0:
                            _add(shared, local, acc, base + 1 + s, total)
                    elif adds:
                        _add(shared, local, acc, base + 1 + s, v)
                    at += 1 + 2 * n
        i += stride
    if shared:
        barrier()
        k = t
        while k < Int(slots):
            if local[k] != 0:
                _ = Atomic.fetch_add[ordering=Ordering.RELAXED](acc + k, local[k])
            k += Int(block_dim.x)


struct GroupSet(Copyable, Movable):
    """One group-by of a `group_sets` call: rows go to group `key` (0 … groups − 1; others are skipped), each `sums`
    expression summed per group."""
    var key: DevExpr
    var groups: Int
    var sums: List[DevExpr]

    def __init__(out self, var key: DevExpr, groups: Int, var sums: List[DevExpr] = List[DevExpr]()):
        self.key = key^
        self.groups = groups
        self.sums = sums^


struct DevGroups(Movable):
    var counts: List[Int]  # per group: the matching rows
    var sums: List[List[Int]]  # per sum asked for, per group
    var milliseconds: Float64  # the call, upload of its program to copy back

    def __init__(out self):
        self.counts = List[Int]()
        self.sums = List[List[Int]]()
        self.milliseconds = 0


def _program(dt: DeviceTable, e: DevExpr, mut spec: List[Int64]) raises:
    if e.depth() > MAX_DEPTH:
        raise Error("group_rows: an expression deeper than " + String(MAX_DEPTH))
    if len(e.prog) == 0:
        raise Error("group_rows: an empty expression")
    spec.append(Int64(len(e.prog) // 2))
    for k in range(len(e.prog) // 2):
        var op = e.prog[2 * k]
        var arg = e.prog[2 * k + 1]
        if op == OP_COL:
            if dt.validity_address(Int(arg)) != 0:
                raise Error("group_rows: column " + String(arg) + " has nulls (an expression reads columns without)")
            arg = Int64(dt.data_address(Int(arg)))
        spec.append(op)
        spec.append(arg)


def group_rows(
    ctx: DeviceContext, dt: DeviceTable, ranges: List[ColumnRange], key: DevExpr, groups: Int, sums: List[DevExpr],
    rows: RowSlice = RowSlice.everything(), scratch: GpuScratch = GpuScratch(),
) raises -> DevGroups:
    """Per group (key's value, 0 … groups − 1): how many rows match every range, and each `sums` expression summed over
    them; only `rows` are read. On the GPU (raises on a build without one)."""
    var sets = List[GroupSet]()
    sets.append(GroupSet(key.copy(), groups, sums.copy()))
    var out = group_sets(ctx, dt, ranges, sets, rows, scratch)
    return out.pop(0)


def group_sets(
    ctx: DeviceContext, dt: DeviceTable, ranges: List[ColumnRange], sets: List[GroupSet],
    rows: RowSlice = RowSlice.everything(), scratch: GpuScratch = GpuScratch(),
) raises -> List[DevGroups]:
    """Each set's group-by (as group_rows) over the same rows matching every range, in one pass over `rows`. Each
    result's milliseconds is the whole call's."""
    var t0 = now_ns()
    if len(ranges) > MAX_RANGES:
        raise Error("group_rows: up to " + String(MAX_RANGES) + " ranges")
    var results = List[DevGroups]()
    var span = rows.bounded(dt.rows())
    comptime if GPU_BUILD:
        var spec: List[Int64] = [Int64(len(ranges)), Int64(len(sets))]
        for r in ranges:
            spec.append(Int64(dt.data_address(r.col)))
            spec.append(Int64(dt.validity_address(r.col)))
            spec.append(r.lo)
            spec.append(r.hi)
        var slots = 0
        for st in sets:
            if len(st.sums) > MAX_SUMS or st.groups < 0:
                raise Error("group_rows: up to " + String(MAX_SUMS) + " sums a set, and groups ≥ 0")
            spec.append(Int64(st.groups))
            spec.append(Int64(slots))
            spec.append(Int64(len(st.sums)))
            _program(dt, st.key, spec)
            for x in st.sums:
                _program(dt, x, spec)
            slots += st.groups * (len(st.sums) + 1)
        if len(spec) > MAX_SPEC:
            raise Error("group_rows: the ranges and expressions take " + String(len(spec)) + " numbers, more than " + String(MAX_SPEC))
        var dspec = scratch.int64s(ctx, SLOT_GSPEC, len(spec))
        ctx.enqueue_copy(dst_buf=dspec, src_ptr=spec.unsafe_ptr())
        var acc = scratch.int64s(ctx, SLOT_ACC, slots)
        ctx.enqueue_memset(acc, 0)
        if span.rows() > 0 and slots > 0:
            ctx.enqueue_function[_group_kernel](
                dspec.unsafe_ptr(), Int64(len(spec)), Int64(span.start), Int64(span.end), acc.unsafe_ptr(), Int64(slots),
                grid_dim=scratch.blocks(ctx, span.rows()), block_dim=256,
            )
        var host = List[Int64](length=max(slots, 1), fill=0)
        ctx.enqueue_copy(dst_ptr=host.unsafe_ptr(), src_buf=acc)
        ctx.synchronize()
        _ = len(spec)
        var first = 0
        for st in sets:
            var out = DevGroups()
            var width = len(st.sums) + 1
            out.counts = List[Int](capacity=st.groups)
            for g in range(st.groups):
                out.counts.append(Int(host[first + g * width]))
            for x in range(len(st.sums)):
                var col = List[Int](capacity=st.groups)
                for g in range(st.groups):
                    col.append(Int(host[first + g * width + 1 + x]))
                out.sums.append(col^)
            first += st.groups * width
            results.append(out^)
    else:
        raise Error("group_rows: no GPU on this build")
    var ms = Float64(now_ns() - t0) / 1e6
    for i in range(len(results)):
        results[i].milliseconds = ms
    return results^
