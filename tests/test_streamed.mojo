# A streamed sheet (mojoui.sheet, D-185, D-213: the package's Frame over a scan) equals the same file read whole: every
# cell (text, decimals, dates, booleans, empty cells) across row groups and back again, the totals, a chart's and a
# pivot's group-bys, a column's span; and the same edits (typed values, an empty cell, a new word, an added row, a
# formula), undone or not, give the same cells, totals and sort on both, and save (streamed) to a file that reads back
# with them.
#   scripts/mxbuild.sh tests/test_streamed.mojo -o build/test_streamed && build/test_streamed
from std.testing import assert_equal, assert_true, assert_false
from std.os import remove
from std.python import Python
from omxcore import read_parquet, write_parquet, scan_parquet, UNCOMPRESSED, gpu_available, GPU as MX_GPU, AUTO as MX_AUTO
from mojoui.sheet import Sheet, TEXT
from mojoui.omxfile import save_omx, open_omx
from mojoui.sheetpage import SheetObject, compute

comptime SMALL = "tests/fixtures/small.parquet"  # (pyarrow wrote it: 5,000 rows, one row group)
comptime GROUPED = "build/test_streamed.parquet"  # the same rows in row groups of 312 (17 groups, the last short)


def main() raises:
    var r = read_parquet(SMALL)
    var t = r.take_table()
    write_parquet(GROUPED, t, "", UNCOMPRESSED, 312)
    var whole = Sheet(t^.share(), False)
    var scan = scan_parquet(GROUPED)
    assert_equal(scan.row_groups(), 17)
    var s = Sheet(scan)
    assert_true(s.streamed())
    assert_false(whole.streamed())
    assert_equal(s.rows(), whole.rows())
    assert_equal(s.columns(), whole.columns())

    # every cell, forwards, then a backwards walk that jumps between far groups (the kept groups turn over)
    var cells = 0
    for row in range(s.rows()):
        for c in range(s.columns()):
            assert_equal(s.display(c, row), whole.display(c, row), s.name(c) + " row " + String(row))
            assert_equal(s.is_null(c, row), whole.is_null(c, row))
            cells += 1
    var row = s.rows() - 1
    while row >= 0:
        for c in range(s.columns()):
            assert_equal(s.display(c, row), whole.display(c, row))
        row -= 1 + (row * 7919) % 900
    for c in range(s.columns()):
        assert_true(s.grid_editable(c))
        assert_false(s.grid_formula(c))
    assert_false(s.edited(1, 3))
    assert_equal(s.read_problem(), "")

    # totals (kept per column: the second call is the same), a chart and a pivot, a span
    for c in [0, 1, 3, 4]:
        var a = s.totals(c)
        var b = whole.totals(c)
        assert_equal(a.sums[0], b.sums[0], s.name(c))
        assert_equal(a.present[0], b.present[0])
        assert_equal(a.counts[0], b.counts[0])
        assert_equal(s.totals(c).sums[0], a.sums[0])
    var chart = SheetObject.chart(1, 2, 0, 0)
    var chart_whole = chart.copy()
    compute(chart, s)
    compute(chart_whole, whole)
    assert_equal(chart.labels, chart_whole.labels)
    assert_equal(chart.sums, chart_whole.sums)
    assert_equal(chart.labels[len(chart.labels) - 1], "(blank)")  # (134 rows have no region)
    var pivot = SheetObject.pivot(1, 2, 2, 0, 0)  # (region × region: the only text column; blanks on both sides)
    var pivot_whole = pivot.copy()
    compute(pivot, s)
    compute(pivot_whole, whole)
    assert_equal(pivot.sums, pivot_whole.sums)
    assert_equal(pivot.counts, pivot_whole.counts)
    var span = s.span(1)
    var span_whole = whole.span(1)
    assert_equal(span[0], span_whole[0])
    assert_equal(span[1], span_whole[1])

    # the same edits on both: they read, total and sort the same, and undo the same
    for sheet_k in range(2):
        ref x = s if sheet_k == 0 else whole
        x.set_text(1, 0, "1.00")
        x.set_text(1, 4000, "")  # (empty)
        x.set_text(2, 17, "Antarctica")  # (a word the file doesn't have)
        var added = x.append()
        x.set_text(1, added, "99.99")
        x.set_text(2, added, "West")
        _ = x.formula("double = amount * 2")
    assert_equal(s.rows(), whole.rows())
    for row in [0, 17, 4000, 4999, s.rows() - 1]:
        for c in range(s.columns()):
            assert_equal(s.display(c, row), whole.display(c, row), s.name(c) + " row " + String(row) + " after edits")
        assert_equal(s.edited(1, row), whole.edited(1, row))
    for c in [1, 5]:
        var a = s.totals(c)
        var b = whole.totals(c)
        assert_equal(a.sums[0], b.sums[0], "totals after edits: " + s.name(c))
        assert_equal(a.present[0], b.present[0])
    var by_region = SheetObject.chart(1, 2, 0, 0)
    var by_region_whole = by_region.copy()
    compute(by_region, s)
    compute(by_region_whole, whole)
    assert_equal(by_region.labels, by_region_whole.labels)
    assert_equal(by_region.sums, by_region_whole.sums)
    # the GPU (F-146): the same totals, chart and pivot over the streamed file with its edits as the CPU's
    if gpu_available():
        s.mode = MX_GPU
        for c in [1, 5]:
            var g = s.totals(c)
            assert_true(g.on_gpu, "the GPU ran the streamed total")
            assert_equal(g.sums[0], whole.totals(c).sums[0], "GPU total after edits: " + s.name(c))
            assert_equal(g.present[0], whole.totals(c).present[0])
        var on_gpu = SheetObject.chart(1, 2, 0, 0)
        compute(on_gpu, s)
        assert_equal(on_gpu.sums, by_region_whole.sums)
        var pivot_gpu = SheetObject.pivot(1, 2, 2, 0, 0)
        var pivot_cpu = pivot_gpu.copy()
        compute(pivot_gpu, s)
        compute(pivot_cpu, whole)
        assert_equal(pivot_gpu.sums, pivot_cpu.sums)
        assert_true(s.last_device() != "CPU", "the device's name: " + s.last_device())
        s.mode = MX_AUTO
        print("STREAMED GPU: totals, chart and pivot with edits equal the CPU's on " + s.last_device())
    var order = s.permutation(1, True)
    var order_whole = whole.permutation(1, True)
    for k in range(50):
        assert_equal(s.display(1, order[k]), whole.display(1, order_whole[k]))
    # saved (streamed out), it reads back with the edits
    var saved = "build/test_streamed_saved.omx"
    save_omx(saved, s)
    var back = open_omx(saved, False)
    assert_equal(back.rows(), whole.rows())
    for row in [0, 17, 4000, back.rows() - 1]:
        for c in range(back.columns()):
            assert_equal(back.display(c, row), whole.display(c, row), "saved " + back.name(c) + " row " + String(row))
    # Undo takes the formula column back first (one step of the package's log since omxcore 2585dc9), then the edits
    assert_equal(s.columns(), 6)
    assert_equal(s.undo_drops(), 5)  # (an app moves what reads it first)
    var depth = s.undo_depth()
    assert_true(s.undo())
    assert_equal(s.undo_depth(), depth - 1)  # (one change, one step: not logged twice)
    assert_equal(s.undo_drops(), -1)
    assert_equal(s.columns(), 5)
    assert_true(s.last_undone.startswith("the formula column double"), s.last_undone)
    assert_true(whole.undo())
    assert_equal(s.rows(), whole.rows())  # (the added row is still there: it came before the formula)
    # undone, both back where they were
    var undone = 0
    while s.undo():
        undone += 1
    while whole.undo():
        pass
    assert_true(undone >= 5, "undid " + String(undone))
    assert_equal(s.columns(), 5)  # (undoing the edits never brings the undone formula back)
    assert_equal(s.undo_depth(), 0)
    assert_equal(s.rows(), 5000)
    assert_equal(s.display(1, 0), whole.display(1, 0))
    assert_equal(s.totals(1).sums[0], whole.totals(1).sums[0])
    # formulas added, replaced and a format change between them: each Undo takes back one change, newest first,
    # and nothing comes back (since omxcore 2585dc9 the package logs formula steps: the sheet must not log them too)
    var fr = read_parquet(SMALL)
    var f = Sheet(fr.take_table().share(), False)
    var n = f.columns()
    _ = f.formula("double = amount * 2")
    f.change_format(0, f.format_of(0))
    _ = f.formula("triple = amount * 3")
    _ = f.formula("double = amount * 4")  # (replaced)
    assert_equal(f.columns(), n + 2)
    assert_equal(f.undo_depth(), 4)
    assert_equal(f.undo_drops(), -1)  # (the replacement's undo keeps both columns)
    assert_true(f.undo())
    assert_true(f.last_undone.startswith("the formula column double"), f.last_undone)
    assert_equal(f.frame.formula_text(n), "double = amount * 2")
    assert_equal(f.columns(), n + 2)
    assert_equal(f.undo_drops(), n + 1)
    assert_true(f.undo())
    assert_true(f.last_undone.startswith("the formula column triple"), f.last_undone)
    assert_equal(f.columns(), n + 1)
    assert_true(f.undo())
    assert_equal(f.last_undone, "a format change")
    assert_equal(f.undo_drops(), n)
    assert_true(f.undo())
    assert_true(f.last_undone.startswith("the formula column double"), f.last_undone)
    assert_equal(f.columns(), n)
    assert_equal(f.undo_depth(), 0)
    assert_false(f.undo())
    assert_equal(f.columns(), n)
    # the package holds the file open (since MX frame 581250b): one deleted after it was opened still reads right
    var gone = "build/test_streamed_gone.parquet"
    var again = read_parquet(SMALL)
    write_parquet(gone, again.take_table(), "", UNCOMPRESSED, 312)
    var g = Sheet(scan_parquet(gone))
    remove(gone)
    assert_equal(g.display(1, 4000), whole.display(1, 4000))
    assert_equal(g.read_problem(), "")
    # one that changes size while open: the rows read say so instead of showing zeros...
    var changed = "build/test_streamed_changed.parquet"
    var third = read_parquet(SMALL)
    write_parquet(changed, third.take_table(), "", UNCOMPRESSED, 312)
    var h = Sheet(scan_parquet(changed))
    var os = Python.import_module("os")
    var size = Int(py=os.path.getsize(changed))
    with open(changed, "a") as f:
        f.write("grown")
    _ = h.display(1, 4000)
    assert_true("changed since it was opened" in h.read_problem(), h.read_problem())
    # ...and once it's back to the size it had, the next row group read clears it
    _ = os.truncate(changed, size)
    _ = h.display(1, 100)
    assert_equal(h.read_problem(), "")
    assert_equal(h.display(1, 100), whole.display(1, 100))
    print("STREAMED: " + String(cells) + " cells over 17 row groups equal the whole read; totals, chart, pivot, span; edits, undo, sort and save")
    print("STREAMED TESTS PASSED")
