# mojoui.tableprep: getting an MX frame `Table` ready at load, on every core: money held as whole cents (fixed point), a
# column's extent, and the rows reordered by a key so a range on that key is a contiguous slice of rows.
#
#   to_fixed(t, t.column("amount"), 2)                 # FLOAT 12.34 → INT 1234, in place; raises on a value with more places
#   var e = column_extent(t, t.column("day"))          # (lowest, highest)
#   var by_day = sort_rows(t, t.column("day"), t.column("id"))   # every column reordered by (day, id), stable
#   var rows = by_day.slice(shared, lo, hi)            # the rows with lo ≤ day ≤ hi: RowSlice(start, end), two binary searches
#
# A dashboard over a time column filters by a date range on every change; once the rows are sorted by that column the
# range is rows [start, end) and the GPU kernels (mojoui.devrows, mojoui.devgroup) read only those rows instead of
# testing every row's date. The sort is the load's cost, paid once: an LSD radix sort (16-bit digits, a per-core
# histogram, a stable scatter), then every column scattered to its new place, all on every core.

from max.algorithm import parallelize
from std.sys.info import num_physical_cores
from mxframe import Table, SharedTable, INT

comptime LP = UnsafePointer[Int64, MutAnyOrigin]
comptime BP = UnsafePointer[UInt8, MutAnyOrigin]
comptime DIGIT_BITS = 16
comptime MIN_TASK_ROWS = 65536  # fewer rows than this a task: fewer tasks


@fieldwise_init
struct RowSlice(Copyable, ImplicitlyCopyable, Movable):
    """Rows start ≤ row < end of a table. `RowSlice.everything()` (end = -1) is every row, whatever the table's size."""
    var start: Int
    var end: Int

    @staticmethod
    def everything() -> RowSlice:
        return RowSlice(0, -1)

    def bounded(self, rows: Int) -> RowSlice:
        """The slice inside a table of `rows` rows (an `everything()` slice becomes 0 … rows)."""
        var e = rows if self.end < 0 else min(self.end, rows)
        var s = min(max(self.start, 0), e)
        return RowSlice(s, e)

    def rows(self) -> Int:
        return max(self.end - self.start, 0)


def _tasks(n: Int) -> Int:
    return max(1, min(num_physical_cores(), n // MIN_TASK_ROWS))


def _par[F: def(Int) -> None](work: F, tasks: Int):
    if tasks == 1:
        work(0)
    else:
        parallelize(work, tasks, tasks)


# ---------- fixed point ----------

def to_fixed(mut t: Table, c: Int, places: Int) raises:
    """A FLOAT column → INT holding value × 10^places, in place, on every core. Raises (naming the first row) when a
    value isn't a whole number of 10^-places (it must come back as the same float64), so the change is exact."""
    var n = t.rows()
    var scale = 1
    for _ in range(places):
        scale *= 10
    var fs = Float64(scale)
    var vp = Int(t.cols[c].values.unsafe_ptr())
    var tasks = _tasks(n)
    var bad = List[Int64](length=tasks, fill=-1)
    var bp = Int(bad.unsafe_ptr())

    def work(i: Int) {imm}:
        var v = LP(unsafe_from_address=vp)
        for r in range(n * i // tasks, n * (i + 1) // tasks):
            var x = Float64(from_bits=UInt64(v[r]))
            var k = Int64(round(x * fs))
            if Float64(k) / fs != x:
                LP(unsafe_from_address=bp)[i] = Int64(r)
                return
            v[r] = k

    _par(work, tasks)
    _ = len(bad)
    for i in range(tasks):
        if bad[i] >= 0:  # (that task stopped there; the column is left half converted, so the table is unusable: raise)
            var r = Int(bad[i])
            raise Error("column " + t.name(c) + " row " + String(r) + " holds " + String(Float64(from_bits=UInt64(t.cols[c].values[r])))
                        + ", not a whole number of 1/" + String(scale))
    t.cols[c].kind = INT


# ---------- extent ----------

def column_extent(t: Table, c: Int) -> Tuple[Int64, Int64]:
    """The lowest and highest non-null value (Int64.MAX, Int64.MIN when there is none), on every core."""
    var n = t.rows()
    var tasks = _tasks(n)
    var los = List[Int64](length=tasks, fill=Int64.MAX)
    var his = List[Int64](length=tasks, fill=Int64.MIN)
    var vp = Int(t.cols[c].values.unsafe_ptr())
    var va = t.cols[c].validity_address()
    var lp = Int(los.unsafe_ptr())
    var hp = Int(his.unsafe_ptr())

    def work(i: Int) {imm}:
        var v = LP(unsafe_from_address=vp)
        var bits = BP(unsafe_from_address=va)
        var lo = Int64.MAX
        var hi = Int64.MIN
        for r in range(n * i // tasks, n * (i + 1) // tasks):
            if va != 0 and (bits[r >> 3] >> UInt8(r & 7)) & 1 == 0:
                continue
            lo = min(lo, v[r])
            hi = max(hi, v[r])
        LP(unsafe_from_address=lp)[i] = lo
        LP(unsafe_from_address=hp)[i] = hi

    _par(work, tasks)
    var lo = Int64.MAX
    var hi = Int64.MIN
    for i in range(tasks):
        lo = min(lo, los[i])
        hi = max(hi, his[i])
    return (lo, hi)


# ---------- sorting the rows ----------

@fieldwise_init
struct SortedKey(Copyable, ImplicitlyCopyable, Movable):
    """Column `col` is in ascending order down the rows (sort_rows made it so): a range on it is a slice of rows."""
    var col: Int

    def slice(self, t: SharedTable, lo: Int64, hi: Int64) -> RowSlice:
        """The rows with lo ≤ value ≤ hi: [first row ≥ lo, first row > hi)."""
        var v = t.values(self.col)
        var n = len(v)

        if hi < lo:
            return RowSlice(0, 0)
        var a = 0  # the first row whose value is ≥ lo
        var b = n
        while a < b:
            var m = (a + b) // 2
            if v[m] < lo:
                a = m + 1
            else:
                b = m
        var s = a
        b = n  # the first row whose value is > hi
        while a < b:
            var m = (a + b) // 2
            if v[m] <= hi:
                a = m + 1
            else:
                b = m
        return RowSlice(s, a)


def _ordered(t: Table, key: Int, tie: Int) -> Bool:
    """The rows are already in (key, tie) order (tie < 0: key alone, non-decreasing)."""
    var n = t.rows()
    if n < 2:
        return True
    var tasks = _tasks(n)
    var ok = List[Int64](length=tasks, fill=1)
    var kp = Int(t.cols[key].values.unsafe_ptr())
    var tp = Int(t.cols[tie].values.unsafe_ptr()) if tie >= 0 else 0
    var op = Int(ok.unsafe_ptr())

    def work(i: Int) {imm}:
        var k = LP(unsafe_from_address=kp)
        var w = LP(unsafe_from_address=tp)
        var a = max(n * i // tasks, 1)
        for r in range(a, n * (i + 1) // tasks):
            if k[r] < k[r - 1] or (tp != 0 and k[r] == k[r - 1] and w[r] < w[r - 1]):
                LP(unsafe_from_address=op)[i] = 0
                return

    _par(work, tasks)
    for i in range(tasks):
        if ok[i] == 0:
            return False
    return True


def _radix_pass(n: Int, tasks: Int, src_addr: Int, lo: Int64, shift: Int, bits: Int, order_in: Int, order_out: Int, dest: Int):
    """One stable counting pass on digit (value − lo) >> shift (`bits` wide) of column `src_addr`, rows taken in the order
    `order_in` (0: 0 … n − 1). Writes the new order to `order_out`, or, with `dest` set (the last pass), each row's final
    position to dest[row]."""
    var buckets = 1 << bits
    var mask = Int64(buckets - 1)
    var hist = List[Int64](length=tasks * buckets, fill=0)
    var hp = Int(hist.unsafe_ptr())

    def count(i: Int) {imm}:
        var v = LP(unsafe_from_address=src_addr)
        var o = LP(unsafe_from_address=order_in)
        var h = LP(unsafe_from_address=hp + 8 * i * buckets)
        for p in range(n * i // tasks, n * (i + 1) // tasks):
            var row = Int(o[p]) if order_in != 0 else p
            h[Int(((v[row] - lo) >> Int64(shift)) & mask)] += 1

    _par(count, tasks)
    var at = Int64(0)  # bucket by bucket, task by task: where each task's rows of each digit start
    for d in range(buckets):
        for i in range(tasks):
            var c = hist[i * buckets + d]
            hist[i * buckets + d] = at
            at += c

    def scatter(i: Int) {imm}:
        var v = LP(unsafe_from_address=src_addr)
        var o = LP(unsafe_from_address=order_in)
        var h = LP(unsafe_from_address=hp + 8 * i * buckets)
        var out = LP(unsafe_from_address=order_out)
        var to = LP(unsafe_from_address=dest)
        for p in range(n * i // tasks, n * (i + 1) // tasks):
            var row = Int(o[p]) if order_in != 0 else p
            var d = Int(((v[row] - lo) >> Int64(shift)) & mask)
            var q = h[d]
            h[d] = q + 1
            if dest != 0:
                to[row] = q
            else:
                out[Int(q)] = Int64(row)

    _par(scatter, tasks)
    _ = len(hist)


def sort_rows(mut t: Table, key: Int, tie: Int = -1) raises -> SortedKey:
    """Reorders every row of the table (each column's values and nulls) into ascending (key, tie) order, rows equal on
    both keeping their order: on every core, in place. `key` must have no nulls. Returns the proof that `key` is sorted.
    When `tie` is already ascending down the rows (a row number, an id), one pass on `key` is all it costs."""
    var n = t.rows()
    if t.null_count(key) > 0 or (tie >= 0 and t.null_count(tie) > 0):
        raise Error("sort_rows: the key columns must have no nulls (" + t.name(key) + ")")
    if _ordered(t, key, tie):
        return SortedKey(key)
    var tasks = _tasks(n)
    # the passes, least significant first: tie's digits (unless it's already in row order), then key's
    var passes = List[Tuple[Int, Int64, Int, Int]]()  # (column, lowest, shift, bits)
    var cols = List[Int]()
    if tie >= 0 and not _ordered(t, tie, -1):
        cols.append(tie)
    cols.append(key)
    for c in cols:
        var e = column_extent(t, c)
        var span = UInt64(e[1] - e[0])
        var width = 1
        while width < 64 and (span >> UInt64(width)) != 0:
            width += 1
        var shift = 0
        while shift < width:
            var bits = min(DIGIT_BITS, width - shift)
            passes.append((c, e[0], shift, bits))
            shift += bits
    var dest = List[Int64](unsafe_uninit_length=n)
    var orders = List[List[Int64]]()
    var cur = 0  # (the order the next pass reads its rows in: 0 = row order)
    for k in range(len(passes)):
        ref p = passes[k]
        var last = k == len(passes) - 1
        var out = 0
        if not last:
            orders.append(List[Int64](unsafe_uninit_length=n))
            out = Int(orders[len(orders) - 1].unsafe_ptr())
        _radix_pass(n, tasks, Int(t.cols[p[0]].values.unsafe_ptr()), p[1], p[2], p[3], cur, out, Int(dest.unsafe_ptr()) if last else 0)
        if len(orders) > 2:
            _ = orders.pop(0)  # (the order two passes back is read no more)
        cur = out
    _ = len(orders)
    # every column to its new place: new[dest[row]] = old[row] (reads in order; writes go to as many runs as key values)
    var dp = Int(dest.unsafe_ptr())
    var scratch = List[Int64](unsafe_uninit_length=n)
    for c in range(t.columns()):
        var src = Int(t.cols[c].values.unsafe_ptr())
        var dst = Int(scratch.unsafe_ptr())

        def move(i: Int) {imm}:
            var s = LP(unsafe_from_address=src)
            var d = LP(unsafe_from_address=dst)
            var to = LP(unsafe_from_address=dp)
            for r in range(n * i // tasks, n * (i + 1) // tasks):
                d[Int(to[r])] = s[r]

        _par(move, tasks)
        swap(t.cols[c].values, scratch)
        if len(t.cols[c].validity) > 0:  # nulls: a byte per row moved the same way, then packed back into bits
            var vb = List[UInt8](unsafe_uninit_length=n)
            var bits_addr = Int(t.cols[c].validity.unsafe_ptr())
            var vbp = Int(vb.unsafe_ptr())

            def move_bits(i: Int) {imm}:
                var b = BP(unsafe_from_address=bits_addr)
                var d = BP(unsafe_from_address=vbp)
                var to = LP(unsafe_from_address=dp)
                for r in range(n * i // tasks, n * (i + 1) // tasks):
                    d[Int(to[r])] = (b[r >> 3] >> UInt8(r & 7)) & 1

            _par(move_bits, tasks)
            var nbytes = len(t.cols[c].validity)

            def pack(i: Int) {imm}:
                var b = BP(unsafe_from_address=bits_addr)
                var s = BP(unsafe_from_address=vbp)
                for j in range(nbytes * i // tasks, nbytes * (i + 1) // tasks):
                    var x = UInt8(0)
                    for k in range(8):
                        var r = 8 * j + k
                        if r < n and s[r] != 0:
                            x |= UInt8(1) << UInt8(k)
                    b[j] = x if 8 * j + 8 <= n else (x | ~((UInt8(1) << UInt8(n - 8 * j)) - 1))

            _par(pack, tasks)
            _ = len(vb)
    _ = len(dest)
    _ = len(scratch)
    return SortedKey(key)
