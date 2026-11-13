# Goal 70 (D-7006): mojoui.tablecard.add_sheet puts a sheet in a SQL catalog. An untouched sheet goes in as its shared
# table, so a selective filter on a big sheet is counted before the join picks its build side (on omxcore a9a3c37 a
# Frame is streamed through the join uncounted: goal 47's questions ran 5–12× slower); a sheet with any change (an
# edit, an appended or removed row, a merge, a formula) goes in as its frame, so SQL reads the change.
#   scripts/mxbuild.sh tests/test_add_sheet.mojo -o build/test_add_sheet && build/test_add_sheet
from std.testing import assert_equal, assert_true
from omxcore import Catalog, Table, TEXT, INT
from mojoui.sheet import Sheet
from mojoui.tablecard import add_sheet, query_table

comptime JOIN = "SELECT COUNT(*) AS n, SUM(t.v) AS v FROM f JOIN t ON f.k = t.k WHERE t.v > 990"


def f_table() raises -> Table:
    """f: 2,000 keys."""
    var f = Table.empty()
    var fk = f.add_column("k", TEXT)
    for i in range(2000):
        f.append_text(fk, "e" + String(i))
    f.check()
    return f^


def t_table() raises -> Table:
    """t: 200,000 rows, 10 of them with v > 990 (every 20,000th row: k e0, v 991)."""
    var t = Table.empty()
    var tk = t.add_column("k", TEXT)
    var tv = t.add_column("v", INT)
    for i in range(200_000):
        t.append_text(tk, "e" + String(i % 2000))
        t.append(tv, Int64(991 if i % 20_000 == 0 else i % 990))
    t.check()
    return t^


def answer(fsheet: Sheet, tsheet: Sheet, text: String = JOIN) raises -> Tuple[Int, Int]:
    """(first, second) column of the one-row answer, with both sheets put in through add_sheet."""
    var cat = Catalog()
    add_sheet(cat, "f", fsheet.frame)
    add_sheet(cat, "t", tsheet.frame)
    var a = query_table(cat, text)
    return (Int(a.get(0, 0)), Int(a.get(1, 0)) if a.columns() > 1 else 0)


def plan_of(fsheet: Sheet, tsheet: Sheet) raises -> String:
    var cat = Catalog()
    add_sheet(cat, "f", fsheet.frame)
    add_sheet(cat, "t", tsheet.frame)
    var p = query_table(cat, "EXPLAIN ANALYZE " + JOIN)
    var s = String("")
    for r in range(p.rows()):
        s += p.text_of(0, Int(p.get(0, r))) + "\n"
    return s^


def builds_on_filtered(fsheet: Sheet, tsheet: Sheet) raises:
    var plan = plan_of(fsheet, tsheet)
    assert_true("10 rows of t after their filters" in plan, plan)
    assert_true("join build side: t (10 rows" in plan, plan)


def main() raises:
    var fsheet = Sheet(f_table().share(), False)
    # untouched: plain tables, the filtered side builds
    var t0 = Sheet(t_table().share(), False)
    var a = answer(fsheet, t0)
    assert_equal(a[0], 10)
    assert_equal(a[1], 9910)
    builds_on_filtered(fsheet, t0)
    print("untouched sheets: ok (the 10 filtered rows build the join)")
    # an edit, then its undo (untouched again)
    var t1 = Sheet(t_table().share(), False)
    t1.frame.set(1, 1, 995)  # (row 1: k e1, v 1 → 995)
    a = answer(fsheet, t1)
    assert_equal(a[0], 11)
    assert_equal(a[1], 9910 + 995)
    _ = t1.frame.undo()
    a = answer(fsheet, t1)
    assert_equal(a[0], 10)
    assert_equal(a[1], 9910)
    builds_on_filtered(fsheet, t1)
    print("edit, undo: ok")
    # an appended row
    var t2 = Sheet(t_table().share(), False)
    _ = t2.frame.append(["e5", "999"])
    a = answer(fsheet, t2)
    assert_equal(a[0], 11)
    assert_equal(a[1], 9910 + 999)
    print("appended row: ok")
    # a removed row (row 0: k e0, v 991)
    var t3 = Sheet(t_table().share(), False)
    t3.frame.remove(0)
    a = answer(fsheet, t3)
    assert_equal(a[0], 9)
    assert_equal(a[1], 9910 - 991)
    print("removed row: ok")
    # a formula column (only the frame has it)
    var t4 = Sheet(t_table().share(), False)
    _ = t4.frame.formula("w = v + 1000")
    a = answer(fsheet, t4, "SELECT COUNT(*) AS n, SUM(t.w) AS w FROM f JOIN t ON f.k = t.k WHERE t.v > 990")
    assert_equal(a[0], 10)
    assert_equal(a[1], 19910)
    print("formula: ok")
    # a merge: e0 folded into e1, so no row reads e0 any more
    var t5 = Sheet(t_table().share(), False)
    var codes = List[Int64]()
    codes.append(Int64(t5.frame.code_of(0, "e0")))
    _ = t5.frame.merge(0, codes, Int64(t5.frame.code_of(0, "e1")))
    a = answer(fsheet, t5, "SELECT COUNT(*) AS n FROM t WHERE t.k = 'e0'")
    assert_equal(a[0], 0)
    a = answer(fsheet, t5, "SELECT COUNT(*) AS n FROM t WHERE t.k = 'e1' AND t.v > 990")
    assert_equal(a[0], 10)
    print("merge: ok")
