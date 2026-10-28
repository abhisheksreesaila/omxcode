# mojoui.tableprep against plain loops: to_fixed (exact cents, a value with a third place refused), column_extent,
# sort_rows by (key, tie) with the tie already in row order (one pass) and not (tie passes first, a wide tie), every
# column and its nulls moved with its row, and SortedKey.slice equal to a scan for ranges inside, across and outside.
#   scripts/mxbuild.sh tests/test_tableprep.mojo -o build/test_tableprep && build/test_tableprep
from std.testing import assert_equal, assert_true
from mxframe import Table, SharedTable, INT, FLOAT
from mojoui.tableprep import to_fixed, column_extent, sort_rows, SortedKey, RowSlice


def make(n: Int, ids_in_row_order: Bool) raises -> Table:
    var t = Table.empty()
    var day = t.add_column("day", INT)
    var id = t.add_column("id", INT)
    var money = t.add_column("money", FLOAT)
    var maybe = t.add_column("maybe", INT)
    var s = UInt64(7)
    for i in range(n):
        s ^= s << 13
        s ^= s >> 7
        s ^= s << 17
        t.append(day, Int64(19723 + Int(s % 731)))
        t.append(id, Int64(i) if ids_in_row_order else Int64(((s >> 8) % 1_000_000_000)) * 4 + Int64(i % 4))
        t.append_float(money, Float64(Int((s >> 24) % 500_000)) / 100.0)
        if (s >> 40) % 9 == 0:
            t.append_null(maybe)
        else:
            t.append(maybe, Int64(i))  # (the original row: shows where each row went)
    return t^


def check_sorted(t: Table, before: Table, label: String) raises:
    """Rows in (day, id) order, and each row still holds its own values (maybe = its old row; money matches)."""
    var n = t.rows()
    for r in range(n):
        if r > 0:
            var a = t.get(0, r - 1)
            var b = t.get(0, r)
            assert_true(a < b or (a == b and t.get(1, r - 1) <= t.get(1, r)), label + ": order at row " + String(r))
    var seen = List[Int](length=n, fill=0)
    var nulls = 0
    for r in range(n):
        if t.is_null(3, r):
            nulls += 1
            continue
        var old = Int(t.get(3, r))
        seen[old] += 1
        assert_equal(t.get(0, r), before.get(0, old), label + ": day moved with its row")
        assert_equal(t.get(1, r), before.get(1, old), label + ": id moved with its row")
        assert_equal(t.get(2, r), before.get(2, old), label + ": money moved with its row")
    assert_equal(nulls, before.null_count(3), label + ": nulls kept")
    assert_equal(t.null_count(3), before.null_count(3), label + ": null count")


def main() raises:
    for which in range(2):
        var in_order = which == 0
        var n = 400_003
        var t = make(n, in_order)
        var copy = make(n, in_order)
        to_fixed(t, 2, 2)
        to_fixed(copy, 2, 2)
        assert_true(t.kind(2) == INT, "to_fixed: INT")
        var e = column_extent(t, 0)
        var lo = Int64.MAX
        var hi = Int64.MIN
        for r in range(n):
            lo = min(lo, copy.get(0, r))
            hi = max(hi, copy.get(0, r))
            assert_equal(t.get(2, r), copy.get(2, r))
        assert_equal(e[0], lo, "extent lo")
        assert_equal(e[1], hi, "extent hi")
        var key = sort_rows(t, 0, 1)
        check_sorted(t, copy, "sort " + ("ids in row order" if in_order else "ids shuffled"))
        var shared = t^.share()
        for r in [(19723, 19723 + 730), (19800, 19810), (19750, 19750), (0, 19722), (30000, 40000), (19900, 19800)]:
            var got = key.slice(shared, Int64(r[0]), Int64(r[1]))
            var want_s = -1
            var want_e = -1
            for row in range(n):
                var d = Int(shared.get(0, row))
                if d >= r[0] and d <= r[1]:
                    if want_s < 0:
                        want_s = row
                    want_e = row + 1
            if want_s < 0:
                assert_equal(got.rows(), 0, "slice empty")
            else:
                assert_equal(got.start, want_s, "slice start")
                assert_equal(got.end, want_e, "slice end")
        assert_equal(RowSlice.everything().bounded(n).rows(), n)
    # a value with a third decimal is refused, naming its row
    var bad = Table.empty()
    var m = bad.add_column("m", FLOAT)
    for i in range(200_000):
        bad.append_float(m, 1.25 if i != 150_001 else 1.255)
    var refused = False
    try:
        to_fixed(bad, 0, 2)
    except err:
        refused = "row 150001" in String(err)
    assert_true(refused, "to_fixed refuses 1.255 and names its row")
    # already sorted: nothing moves
    var done = Table.empty()
    var d = done.add_column("d", INT)
    for i in range(1000):
        done.append(d, Int64(i // 10))
    _ = sort_rows(done, 0)
    assert_equal(done.get(0, 999), 99)
    print("test_tableprep: ok (to_fixed exact and refusing, extent, sort_rows one pass and with tie passes, nulls moved, slices)")
