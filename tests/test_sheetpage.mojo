# mojoui.sheetpage and mojoui.reportpage on their own: a chart's and a pivot's GPU sums against a CPU pass (with an
# edit), the readout in the column's format, free-space placement, and a Report tile through a filter.
#   scripts/mxbuild.sh tests/test_sheetpage.mojo -o build/test_sheetpage && build/test_sheetpage
from std.testing import assert_equal, assert_true
from omxcore import gpu_available, GPU as MX_GPU, Table, TEXT as MX_TEXT, DECIMAL as MX_DECIMAL
from mojoui.sheet import Sheet, TEXT, DECIMAL
from mojoui.sample import sample_table
from mojoui.orders import REGION, PRODUCT, REVENUE, CARRIER, QTY, CUSTOMER
from mojoui.sheetpage import pivot_view
from mojoui.numformat import ColumnFormat, CURRENCY
from mojoui.sheetpage import SheetObject, compute, readout, free_spot, chart_view, OBJ_CHART, OBJ_PIVOT, CHART_LINE
from mojoui.reportpage import ReportFilter, new_tile, compute_tile, tile_value, TILE_SUM, TILE_AVERAGE, TILE_COUNT, TILE_CHART


def cpu_sums(frame: Sheet, group: Int, value: Int, across: Int = -1, n_across: Int = 1, only: Int = -1, only_code: Int = 0) -> List[Int]:
    var ng = frame.word_count(group)
    var out = List[Int](length=ng * n_across, fill=0)
    for r in range(frame.rows()):
        if not frame.alive(r):
            continue
        if only >= 0 and Int(frame.value(only, r)) != only_code:
            continue
        var g = Int(frame.value(group, r))
        var a = Int(frame.value(across, r)) if across >= 0 else 0
        out[g * n_across + a] += Int(frame.value(value, r))
    return out^


def blanks() raises:
    """Rows whose group is empty make a "(blank)" group, so charts and pivots add up to the column's total."""
    var t = Table.empty()
    var who = t.add_column("who", MX_TEXT)
    var kind = t.add_column("kind", MX_TEXT)
    var amount = t.add_column("amount", MX_DECIMAL, 2)
    for w in ["Acme", "Beta"]:
        _ = t.add_word(who, w)
    for w in ["x", "y"]:
        _ = t.add_word(kind, w)
    var whos = [0, 1, -1, -1, 0]
    var kinds = [0, 1, 0, -1, -1]
    var amounts = [100, 200, 400, 800, 1600]
    for r in range(5):
        if whos[r] < 0:
            t.append_null(who)
        else:
            t.append(who, Int64(whos[r]))
        if kinds[r] < 0:
            t.append_null(kind)
        else:
            t.append(kind, Int64(kinds[r]))
        t.append(amount, Int64(amounts[r]))
    var sheet = Sheet(t^.share(), False)
    var chart = SheetObject.chart(amount, who, 0, 0)
    compute(chart, sheet)
    assert_equal(chart.labels[0] + "|" + chart.labels[1] + "|" + chart.labels[2], "Acme|Beta|(blank)")
    assert_equal(chart.sums[0], 1700)
    assert_equal(chart.sums[1], 200)
    assert_equal(chart.sums[2], 1200)
    assert_equal(chart.counts[2], 2)
    var pivot = SheetObject.pivot(amount, who, kind, 0, 0)
    compute(pivot, sheet)
    assert_equal(len(pivot.labels), 3)
    assert_equal(pivot.cols[2], "(blank)")
    var want_sums = [100, 0, 1600, 0, 200, 0, 400, 0, 800]
    var want_counts = [1, 0, 1, 0, 1, 0, 1, 0, 1]
    assert_equal(len(pivot.sums), 9)
    for k in range(9):
        assert_equal(pivot.sums[k], want_sums[k])
        assert_equal(pivot.counts[k], want_counts[k])
    # a Report filter keeps the blank rows of the other column in its blank group too
    var filtered = SheetObject.chart(amount, who, 0, 0)
    compute(filtered, sheet, sheet.where_is(kind, 0))  # kind = x: rows 0 and 2
    assert_equal(filtered.sums[0], 100)
    assert_equal(filtered.sums[1], 0)
    assert_equal(filtered.sums[2], 400)
    # no blanks, no blank group: the sample's regions
    var plain = SheetObject.chart(amount, kind, 0, 0)
    compute(plain, sheet)
    assert_equal(len(plain.labels), 3)  # (kind has a null)
    var full = Table.empty()
    var c0 = full.add_column("g", MX_TEXT)
    var c1 = full.add_column("v", MX_DECIMAL, 2)
    _ = full.add_word(c0, "a")
    full.append(c0, 0)
    full.append(c1, 5)
    var s2 = Sheet(full^.share(), False)
    var no_blank = SheetObject.chart(1, 0, 0, 0)
    compute(no_blank, s2)
    assert_equal(len(no_blank.labels), 1)


def main() raises:
    blanks()
    # the GPU when there is one (forced: under a million rows AUTO would stay on the CPU), else the CPU; the oracle below is plain loops
    var gpu = gpu_available()
    var frame = Sheet(sample_table(200_000).share(), gpu)
    if gpu:
        frame.mode = MX_GPU
    assert_equal(frame.totals(REVENUE).on_gpu, gpu)
    frame.set_text(REVENUE, 0, "99999.99")  # an edit the GPU's copy doesn't have: added as a delta

    # a chart: revenue by region
    var chart = SheetObject.chart(REVENUE, REGION, 0, 416)
    compute(chart, frame)
    var want = cpu_sums(frame, REGION, REVENUE)
    assert_equal(len(chart.sums), len(want))
    for k in range(len(want)):
        assert_equal(chart.sums[k], want[k])
    assert_equal(chart.labels[0], frame.text_of(REGION, 0))
    assert_equal(readout(chart, frame), "Tap a bar to read it")
    frame.set_format(REVENUE, ColumnFormat(CURRENCY, 2, True, False, "$"))
    chart.selected = 1
    assert_equal(readout(chart, frame), chart.labels[1] + " · " + frame.format_value(REVENUE, Int64(want[1]), total=True))
    assert_true(readout(chart, frame).find(" · $") > 0, "the readout is in the column's format")
    chart.style = CHART_LINE
    assert_equal(chart_view(chart, frame).kind, "Line Chart")

    # a pivot: revenue by region × product
    var np = frame.word_count(PRODUCT)
    var pivot = SheetObject.pivot(REVENUE, REGION, PRODUCT, 536, 416)
    compute(pivot, frame)
    var cells = cpu_sums(frame, REGION, REVENUE, PRODUCT, np)
    assert_equal(len(pivot.cols), np)
    for k in range(len(cells)):
        assert_equal(pivot.sums[k], cells[k])

    # placement: beside an object when it fits, else below everything
    var placed = List[SheetObject]()
    placed.append(SheetObject.chart(REVENUE, REGION, 0, 416, 520, 340))
    var spot = free_spot(placed, 400, 1084, 548, 340)
    assert_equal(spot[0], 536)
    assert_equal(spot[1], 416)
    placed.append(SheetObject.pivot(REVENUE, REGION, PRODUCT, 536, 416, 548, 340))
    spot = free_spot(placed, 400, 1084, 520, 340)
    assert_equal(spot[0], 0)
    assert_equal(spot[1], 772)
    # a money column's median bars read in money ("$…"), like its sums (goal 29's polish; revenue is Currency since above)
    from mojoui.sheetpage import COMBINE_MEDIAN
    from mojoui.theme import Palette
    var med = SheetObject.chart(REVENUE, REGION, 0, 0)
    med.combine = COMBINE_MEDIAN
    compute(med, frame)
    var med_texts = chart_view(med, frame).bar_texts(Palette.plain())
    assert_true(len(med_texts) > 0 and med_texts[0].startswith("$"), "median bars in money: " + med_texts[0])
    var sum_bars = SheetObject.chart(REVENUE, REGION, 0, 0)
    compute(sum_bars, frame)
    assert_true(chart_view(sum_bars, frame).bar_texts(Palette.plain())[0].startswith("$"), "sum bars in money")

    # a Report tile through a filter (region = the first region)
    var filter = ReportFilter(REGION, 0)
    var sum = new_tile(TILE_SUM, REVENUE, -1)
    var count = new_tile(TILE_COUNT, REVENUE, -1)
    var avg = new_tile(TILE_AVERAGE, REVENUE, -1)
    var bars = new_tile(TILE_CHART, REVENUE, CARRIER)
    compute_tile(sum, frame, filter)
    compute_tile(count, frame, filter)
    compute_tile(avg, frame, filter)
    compute_tile(bars, frame, filter)
    var region0 = cpu_sums(frame, REGION, REVENUE)[0]
    var rows0 = 0
    for r in range(frame.rows()):
        if Int(frame.value(REGION, r)) == 0:
            rows0 += 1
    assert_equal(sum.total, region0)
    assert_equal(count.count, rows0)
    assert_equal(tile_value(sum, frame), frame.format_value(REVENUE, Int64(region0), total=True))
    var by_carrier = cpu_sums(frame, CARRIER, REVENUE, only=REGION, only_code=0)
    for k in range(len(by_carrier)):
        assert_equal(bars.chart.sums[k], by_carrier[k])
    assert_equal(filter.words(frame), "region = " + frame.text_of(REGION, 0))
    # the Average tile reads as the status bar does: one rounding, two more places for a whole-number column
    assert_equal(tile_value(avg, frame), frame.format_average(REVENUE, region0, rows0))
    var qty_avg = new_tile(TILE_AVERAGE, QTY, -1)
    compute_tile(qty_avg, frame, filter)
    var qty0 = 0
    for r in range(frame.rows()):
        if Int(frame.value(REGION, r)) == 0:
            qty0 += Int(frame.value(QTY, r))
    var hundredths = (qty0 * 100 + rows0 // 2) // rows0
    assert_equal(tile_value(qty_avg, frame), String(hundredths // 100) + "." + ("0" if hundredths % 100 < 10 else "") + String(hundredths % 100))
    assert_equal(tile_value(count, frame), frame.format_value(QTY, Int64(rows0), total=True).replace(".00", ""))

    # a formula value column, and a word typed this session (a new group)
    var margin = frame.formula("half = revenue / 2")
    frame.set_text(CUSTOMER, 1, "Zed Co")
    var by_customer = SheetObject.chart(margin, CUSTOMER, 0, 0)
    compute(by_customer, frame)
    var halves = cpu_sums(frame, CUSTOMER, margin)
    assert_equal(len(by_customer.sums), len(halves))
    for k in range(len(halves)):
        assert_equal(by_customer.sums[k], halves[k])
    assert_equal(by_customer.labels[len(by_customer.labels) - 1], "Zed Co")

    # a pivot row whose whole total is 0 still shows when rows fell in it (a profit that nets to nothing); a row
    # no row uses doesn't; the column totals are the cells you can see
    var hand = SheetObject.pivot(REVENUE, REGION, PRODUCT, 0, 0)
    hand.labels = ["Nets to zero", "Unused", "Plain"]
    hand.cols = ["A", "B"]
    hand.sums = [500, -500, 0, 0, 300, 200]
    hand.counts = [1, 1, 0, 0, 2, 3]
    var view = pivot_view(hand, frame, 200)
    var texts = List[String]()
    for node in view.nodes:
        if node.text != "":
            texts.append(node.text)
    var listed = String("|")
    for t in texts:
        listed += t + "|"
    assert_true("|Nets to zero|" in listed, "a row that nets to zero shows")
    assert_true("|Unused|" not in listed, "a row with no rows doesn't")
    assert_true("|$8.00|" in listed and "|−$3.00|" in listed and "|$5.00|" in listed, "column totals and grand total: " + listed)
    print("SHEETPAGE TESTS PASSED · sums on the " + ("GPU" if gpu else "CPU (no GPU here)") + " equal a CPU pass")
