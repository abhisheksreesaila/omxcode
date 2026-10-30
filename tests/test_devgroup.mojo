# mojoui.devgroup.group_rows against a plain loop over the same rows: few groups (shared memory) and many (global
# atomics), one to three sums including a quotient, filters with nulls, row slices (the whole table, a middle, an empty
# one), keys out of range skipped, expressions on a column with nulls and deeper than four refused.
#   scripts/mxbuild.sh tests/test_devgroup.mojo -o build/test_devgroup && build/test_devgroup
from std.testing import assert_equal, assert_true
from max.gpu.host import DeviceContext
from mojoui.devrows import ColumnRange, GpuScratch
from mojoui.devgroup import DevExpr, GroupSet, dcol, dlit, group_rows, group_sets
from mojoui.tableprep import RowSlice
from mxframe import Table, SharedTable, DeviceTable, INT, gpu_available


def make(n: Int, sorted_days: Bool = False) raises -> SharedTable:
    var t = Table.empty()
    var day = t.add_column("day", INT)
    var product = t.add_column("product", INT)
    var amount = t.add_column("amount", INT)
    var cost = t.add_column("cost", INT)
    var maybe = t.add_column("maybe", INT)
    var s = UInt64(99)
    for i in range(n):
        s ^= s << 13
        s ^= s >> 7
        s ^= s << 17
        t.append(day, Int64(i // 347) if sorted_days else Int64(s % 731))  # (sorted: a warp's rows share a day)
        t.append(product, Int64((s >> 12) % 40))
        var a = Int64(100 + (s >> 20) % 500_000)
        t.append(amount, a)
        t.append(cost, a * Int64((s >> 44) % 99 + 1) // 100)
        if (s >> 50) % 7 == 0:
            t.append_null(maybe)
        else:
            t.append(maybe, Int64((s >> 33) % 100))
    return t^.share()


def row_values(t: SharedTable, i: Int) -> List[Int64]:
    var v = List[Int64]()
    for c in range(t.columns()):
        v.append(t.get(c, i))
    return v^


def check(ctx: DeviceContext, t: SharedTable, dt: DeviceTable, scratch: GpuScratch, ranges: List[ColumnRange], key: DevExpr,
          groups: Int, sums: List[DevExpr], sl: RowSlice, label: String) raises:
    var got = group_rows(ctx, dt, ranges, key, groups, sums, rows=sl, scratch=scratch)
    var counts = List[Int](length=groups, fill=0)
    var want = List[List[Int]]()
    for _ in range(len(sums)):
        want.append(List[Int](length=groups, fill=0))
    var span = sl.bounded(t.rows())
    for i in range(span.start, span.end):
        var keep = True
        for r in ranges:
            if t.is_null(r.col, i) or t.get(r.col, i) < r.lo or t.get(r.col, i) > r.hi:
                keep = False
        if not keep:
            continue
        var v = row_values(t, i)
        var g = Int(key.eval(v))
        if g < 0 or g >= groups:
            continue
        counts[g] += 1
        for s in range(len(sums)):
            want[s][g] += Int(sums[s].eval(v))
    var total = 0
    for g in range(groups):
        assert_equal(got.counts[g], counts[g], label + ": count of group " + String(g))
        total += counts[g]
        for s in range(len(sums)):
            assert_equal(got.sums[s][g], want[s][g], label + ": sum " + String(s) + " of group " + String(g))
    print("  " + label + ": " + String(total) + " rows in " + String(groups) + " groups")


def main() raises:
    if not gpu_available():
        print("test_devgroup: no GPU here; skipped")
        return
    var n = 250_000
    var t = make(n)
    var dt = DeviceTable(t)
    var ctx = DeviceContext()
    var scratch = GpuScratch()
    var profit = (dcol(2) - dcol(3)) * dlit(10_000_000_000) // dcol(2)
    var by_product = dcol(1)
    var by_product_day = dcol(1) * dlit(731) + (dcol(0) - dlit(0))
    var region_like: List[ColumnRange] = [ColumnRange(4, 10, 40)]  # (a column with nulls: a null never matches)
    var amount_min: List[ColumnRange] = [ColumnRange(2, 250_000, Int64.MAX)]
    var none = List[ColumnRange]()
    for sl in [RowSlice.everything(), RowSlice(1_000, 200_000), RowSlice(7, 7)]:
        check(ctx, t, dt, scratch, none, by_product, 40, [dcol(2), profit.copy()], sl, "product, no filter")
        check(ctx, t, dt, scratch, region_like, by_product, 40, [dcol(2)], sl, "product, nullable filter")
        check(ctx, t, dt, scratch, amount_min, by_product_day, 40 * 731, [dcol(2), profit.copy()], sl, "product x day (global)")
        check(ctx, t, dt, scratch, amount_min, dcol(0) - dlit(100), 600, List[DevExpr](), sl, "day count, keys out of range skipped")
        # grouping sets: each set equals its own group_rows call (shared memory; and global when one set is large)
        for big in [False, True]:
            var sets = List[GroupSet]()
            sets.append(GroupSet(by_product.copy(), 40, [dcol(2), profit.copy()]))
            sets.append(GroupSet(dcol(0) - dlit(30), 700))
            if big:
                sets.append(GroupSet(by_product_day.copy(), 40 * 731, [dcol(3)]))
            var got = group_sets(ctx, dt, amount_min, sets, rows=sl, scratch=scratch)
            for k in range(len(sets)):
                var one = group_rows(ctx, dt, amount_min, sets[k].key, sets[k].groups, sets[k].sums, rows=sl, scratch=scratch)
                for g in range(sets[k].groups):
                    assert_equal(got[k].counts[g], one.counts[g], "set " + String(k) + " count")
                    for x in range(len(sets[k].sums)):
                        assert_equal(got[k].sums[x][g], one.sums[x][g], "set " + String(k) + " sum")
    # rows in day order: most warps add one group (one atomic each), the warps at a day's edge and the filtered lanes not
    var st = make(n, True)
    var sdt = DeviceTable(st)
    for sl in [RowSlice.everything(), RowSlice(333, 100_001)]:
        check(ctx, st, sdt, scratch, none, dcol(0), 731, [dcol(2), profit.copy()], sl, "sorted: day")
        check(ctx, st, sdt, scratch, amount_min, dcol(0), 731, [dcol(2), profit.copy()], sl, "sorted: day, amount filter")
        check(ctx, st, sdt, scratch, region_like, dcol(1) * dlit(731) + dcol(0), 40 * 731, [dcol(3)], sl, "sorted: product x day, nullable filter")
    var refused = False
    try:
        _ = group_rows(ctx, dt, none, dcol(4), 100, List[DevExpr]())
    except e:
        refused = "has nulls" in String(e)
    assert_true(refused, "an expression on a column with nulls is refused")
    refused = False
    var deep = dcol(0) + (dcol(1) + (dcol(2) + (dcol(3) + dcol(0))))
    try:
        _ = group_rows(ctx, dt, none, by_product, 40, [deep.copy()])
    except e:
        refused = "deeper" in String(e)
    assert_true(refused, "an expression deeper than four is refused")
    print("test_devgroup: ok (shared and global groups, sums with a quotient, nullable filters, slices, out-of-range keys, grouping sets, refusals)")
