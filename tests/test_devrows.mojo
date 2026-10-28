# mojoui.devrows: rows of a DeviceTable picked on the GPU equal a plain loop over the table: device_rows for one to three
# ranges (an equality, an empty range, a column with nulls), the cap refused when passed, and first_rows (key descending
# and ascending, ties broken by a second column) for k = 1, 50 and more than match.
#   scripts/mxbuild.sh tests/test_devrows.mojo -o build/test_devrows && build/test_devrows
from std.testing import assert_equal, assert_true
from max.gpu.host import DeviceContext
from mojoui.devrows import ColumnRange, device_rows, first_rows
from mxframe import Table, SharedTable, DeviceTable, INT, gpu_available


def make(n: Int) raises -> SharedTable:
    var t = Table.empty()
    var day = t.add_column("day", INT)
    var region = t.add_column("region", INT)
    var id = t.add_column("id", INT)
    var maybe = t.add_column("maybe", INT)
    var s = UInt64(42)
    for i in range(n):
        s ^= s << 13
        s ^= s >> 7
        s ^= s << 17
        t.append(day, Int64(s % 731))
        t.append(region, Int64((s >> 20) % 8))
        t.append(id, Int64(n - i))  # (descending ids: the tie-break is not the row order)
        if (s >> 40) % 10 == 0:
            t.append_null(maybe)
        else:
            t.append(maybe, Int64((s >> 33) % 100))
    return t^.share()


def matches(t: SharedTable, ranges: List[ColumnRange], row: Int) -> Bool:
    for r in ranges:
        if t.is_null(r.col, row):
            return False
        var v = t.get(r.col, row)
        if v < r.lo or v > r.hi:
            return False
    return True


def loop_rows(t: SharedTable, ranges: List[ColumnRange]) -> List[Int]:
    var out = List[Int]()
    for i in range(t.rows()):
        if matches(t, ranges, i):
            out.append(i)
    return out^


def loop_first(t: SharedTable, ranges: List[ColumnRange], k: Int, descending: Bool) -> List[Int]:
    """Every matching row sorted by (day, then id) through one composite key (id = n - row, so the row comes back)."""
    var keys = List[Int]()
    var n = t.rows()
    for i in range(n):
        if matches(t, ranges, i):
            var d = Int(t.get(0, i))
            keys.append((730 - d if descending else d) * 1_000_000 + Int(t.get(2, i)))
    sort(keys)
    var out = List[Int]()
    for j in range(min(k, len(keys))):
        out.append(n - keys[j] % 1_000_000)
    return out^


def day_counts(t: SharedTable, ranges: List[ColumnRange]) -> List[Int]:
    var c = List[Int](length=731, fill=0)
    for i in range(t.rows()):
        if matches(t, ranges, i):
            c[Int(t.get(0, i))] += 1
    return c^


def same(a: List[Int], b: List[Int], what: String) raises:
    assert_equal(len(a), len(b), what + ": count")
    for i in range(len(a)):
        assert_equal(a[i], b[i], what + ": row " + String(i))


def main() raises:
    if not gpu_available():
        print("test_devrows: no GPU here; skipped")
        return
    var t = make(300_000)
    var dt = DeviceTable(t)
    var ctx = DeviceContext()
    var cases = List[List[ColumnRange]]()
    cases.append([ColumnRange(0, 100, 200)])
    cases.append([ColumnRange(1, 3, 3), ColumnRange(0, 700, 730)])
    cases.append([ColumnRange(3, 10, 20), ColumnRange(1, 0, 4), ColumnRange(0, 0, 365)])
    cases.append([ColumnRange(0, 900, 1000)])  # nothing matches
    cases.append([ColumnRange(0, 5, 5), ColumnRange(1, 7, 7), ColumnRange(3, 0, 1)])  # a handful
    for ci in range(len(cases)):
        var want = loop_rows(t, cases[ci])
        same(device_rows(ctx, dt, cases[ci], len(want)), want, "device_rows case " + String(ci))
        var counts = day_counts(t, cases[ci])
        for k in [1, 50, 5_000, 400_000]:
            for descending in [True, False]:
                var got = first_rows(ctx, t, dt, cases[ci], 0, 0, counts, k, 2, descending)
                same(got, loop_first(t, cases[ci], k, descending), "first_rows case " + String(ci) + " k " + String(k) + (" desc" if descending else " asc"))
    var refused = False
    try:
        _ = device_rows(ctx, dt, cases[0], 10)
    except e:
        refused = "more than the 10" in String(e)
    assert_true(refused, "a cap smaller than the matches is refused")
    print("test_devrows: ok (5 range sets, device_rows and first_rows k = 1, 50, 5000, all; both orders; cap refused)")
