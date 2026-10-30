# Goal 28 M0: a chart's spec (combine, order, top N, its own filter) on a table small enough to add up by hand; a
# document keeps the spec (a sheet chart and a Report chart tile), and an older document's charts open as they were.
#   scripts/mxbuild.sh -I tests tests/test_chartspec.mojo -o build/test_chartspec && build/test_chartspec
from std.testing import assert_equal, assert_true
from omxcore import Table, TEXT as MX_TEXT, DECIMAL as MX_DECIMAL
from mojoui.sheet import Sheet
from mojoui.omxfile import save_omx, open_document, read_spec
from mojoui.json import Json
from mojoui.sheetpage import (SheetObject, compute, chart_view, chart_text, readout, object_title, COMBINE_SUM, COMBINE_AVERAGE, COMBINE_COUNT,
                              COMBINE_MEDIAN, NUM_OVER, NUM_BETWEEN, ORDER_TABLE, ORDER_LARGEST, ORDER_SMALLEST, ORDER_AZ)
from mojoui.reportpage import ReportTile, ReportFilter, new_tile, TILE_CHART
from mojoui.shared import make_dir


def table() raises -> Sheet:
    """who (Acme ×2, Beta, Cole, blank), kind (x, y), amount: 1.00, 2.00, 4.00, 8.00, 16.00 (Beta's empty)."""
    var t = Table.empty()
    var who = t.add_column("who", MX_TEXT)
    var kind = t.add_column("kind", MX_TEXT)
    var amount = t.add_column("amount", MX_DECIMAL, 2)
    for w in ["Cole", "Acme", "Beta"]:
        _ = t.add_word(who, w)
    for w in ["x", "y"]:
        _ = t.add_word(kind, w)
    var whos = [1, 1, 2, 0, -1]
    var kinds = [0, 1, 0, 1, 0]
    var amounts = [100, 200, -1, 800, 1600]
    for r in range(5):
        if whos[r] < 0:
            t.append_null(who)
        else:
            t.append(who, Int64(whos[r]))
        t.append(kind, Int64(kinds[r]))
        if amounts[r] < 0:
            t.append_null(amount)
        else:
            t.append(amount, Int64(amounts[r]))
    return Sheet(t^.share(), False)


def chart(combine: Int, order: Int = ORDER_TABLE, top: Int = 0, only: Int = -1, code: Int = 0) -> SheetObject:
    var o = SheetObject.chart(2, 0, 0, 0)  # amount by who
    o.combine = combine
    o.order = order
    o.top = top
    o.only_col = only
    o.only_code = code
    return o^


def lines(o: SheetObject, sheet: Sheet) -> String:
    return chart_text(o, sheet).replace("\n", " | ")


def main() raises:
    var sheet = table()
    var o = chart(COMBINE_SUM)
    compute(o, sheet)
    assert_equal(lines(o, sheet), "who\tamount | Cole\t8.00 | Acme\t3.00 | Beta\t0.00 | (blank)\t16.00")
    o = chart(COMBINE_AVERAGE)
    compute(o, sheet)
    assert_equal(lines(o, sheet), "who\taverage amount | Cole\t8.00 | Acme\t1.50 | Beta\t— | (blank)\t16.00")
    o = chart(COMBINE_COUNT)
    compute(o, sheet)
    assert_equal(lines(o, sheet), "who\trows | Cole\t1 | Acme\t2 | Beta\t1 | (blank)\t1")
    o = chart(COMBINE_SUM, ORDER_LARGEST, 2)
    compute(o, sheet)
    assert_equal(lines(o, sheet), "who\tamount | (blank)\t16.00 | Cole\t8.00")
    o = chart(COMBINE_SUM, ORDER_SMALLEST)
    compute(o, sheet)
    assert_equal(lines(o, sheet), "who\tamount | Beta\t0.00 | Acme\t3.00 | Cole\t8.00 | (blank)\t16.00")
    o = chart(COMBINE_COUNT, ORDER_AZ)
    compute(o, sheet)
    assert_equal(lines(o, sheet), "who\trows | Acme\t2 | Beta\t1 | Cole\t1 | (blank)\t1", "A to Z, (blank) last")
    o = chart(COMBINE_SUM, ORDER_TABLE, 0, 1, 0)  # (only kind = x)
    compute(o, sheet)
    assert_equal(lines(o, sheet), "who\tamount | Cole\t0.00 | Acme\t1.00 | Beta\t0.00 | (blank)\t16.00", "its own filter")
    assert_equal(object_title(chart(COMBINE_AVERAGE), sheet), "average amount by who")
    assert_equal(object_title(chart(COMBINE_COUNT), sheet), "rows by who")
    o = chart(COMBINE_SUM, ORDER_LARGEST, 2)
    compute(o, sheet)
    o.selected = 1
    assert_equal(readout(o, sheet), "Cole · 8.00", "a picked bar reads its figure, in the chart's order")
    o.order = ORDER_SMALLEST  # (computed again in another order, every group: the picked bar stays on Cole)
    o.top = 0
    compute(o, sheet)
    assert_equal(readout(o, sheet), "Cole · 8.00", "a picked bar stays on its group when the bars move")

    # a document keeps the spec: a sheet chart and a Report chart tile (its own filter as its word)
    var dir = String("build/test-chartspec")
    make_dir(dir)
    var path = dir + "/spec.omx"
    var objects: List[SheetObject] = [chart(COMBINE_AVERAGE, ORDER_AZ, 3, 1, 1), chart(COMBINE_MEDIAN)]
    objects[1].num_col = 2  # (goal 29: amount between 1.50 and 9.00)
    objects[1].num_op = NUM_BETWEEN
    objects[1].num_lo = 150
    objects[1].num_hi = 900
    var tile = new_tile(TILE_CHART, 2, 0)
    tile.chart.combine = COMBINE_COUNT
    tile.chart.order = ORDER_LARGEST
    tile.chart.top = 5
    var tiles: List[ReportTile] = [tile^]
    save_omx(path, sheet, objects, tiles, ReportFilter(-1, 0))
    var back_objects = List[SheetObject]()
    var back_tiles = List[ReportTile]()
    var back_filter = ReportFilter(-1, 0)
    _ = open_document(path, back_objects, back_tiles, back_filter)
    assert_equal(len(back_objects), 2)
    assert_true(back_objects[1].combine == COMBINE_MEDIAN and back_objects[1].num_col == 2 and back_objects[1].num_op == NUM_BETWEEN
                and back_objects[1].num_lo == 150 and back_objects[1].num_hi == 900, "a median and a number condition kept")
    assert_equal(back_objects[0].combine, COMBINE_AVERAGE)
    assert_equal(back_objects[0].order, ORDER_AZ)
    assert_equal(back_objects[0].top, 3)
    assert_equal(back_objects[0].only_col, 1)
    assert_equal(back_objects[0].only_code, 1, "the filter's word (y) found again")
    assert_equal(back_tiles[0].chart.combine, COMBINE_COUNT)
    assert_equal(back_tiles[0].chart.order, ORDER_LARGEST)
    assert_equal(back_tiles[0].chart.top, 5)

    # an older document's chart (goal 27 wrote no spec keys): written here by hand, read by the same code a file is
    var old = Json.parse('{"kind": 1, "x": 0, "y": 0, "w": 520, "h": 340, "value": 2, "group": 0, "across": -1, "style": 0}')
    var opened = SheetObject.chart(2, 0, 0, 0)
    opened.combine = COMBINE_COUNT  # (anything: what the file doesn't say must come back to its default)
    opened.order = ORDER_AZ
    opened.top = 3
    opened.only_col = 1
    read_spec(old, 0, opened, sheet)
    assert_true(opened.combine == COMBINE_SUM and opened.order == ORDER_TABLE and opened.top == 0 and opened.only_col == -1,
                "no spec keys: a sum, in data order, every group, every row")
    # a spec naming a value the column doesn't have any more: the filter goes, the rest stays
    var gone = Json.parse('{"combine": 1, "order": 1, "top": 5, "only_col": 1, "only_word": "zzz"}')
    var o2 = SheetObject.chart(2, 0, 0, 0)
    read_spec(gone, 0, o2, sheet)
    assert_true(o2.combine == COMBINE_AVERAGE and o2.order == ORDER_LARGEST and o2.top == 5 and o2.only_col == -1)
    # goal 29's keys, each checked: a combine, a month on a text column, a condition on a text column or with no such
    # comparison: each falls back to its default, not to what the file says
    var bad = Json.parse('{"combine": 9, "part": 1, "num_col": 0, "num_op": 2, "num_lo": 5}')
    var o3 = SheetObject.chart(2, 0, 0, 0)
    read_spec(bad, 0, o3, sheet)
    assert_true(o3.combine == COMBINE_SUM and o3.part == 0 and o3.num_col == -1 and o3.num_op == 0, "bad goal 29 keys refused")
    var bad_op = Json.parse('{"num_col": 2, "num_op": 6, "num_lo": 5}')
    read_spec(bad_op, 0, o3, sheet)
    assert_true(o3.num_col == -1 and o3.num_op == 0, "an unknown comparison refused")
    var good = Json.parse('{"num_col": 2, "num_op": 1, "num_lo": 500}')
    read_spec(good, 0, o3, sheet)
    assert_true(o3.num_col == 2 and o3.num_op == NUM_OVER and o3.num_lo == 500)
    # a group with no figure (Beta's median: no values; "(blank)": no median yet) draws no bar and reads "—", not 0
    var med = chart(COMBINE_MEDIAN)
    compute(med, sheet)
    var cv = chart_view(med, sheet)
    for k in range(len(med.labels)):
        assert_equal(cv.missing[k], med.labels[k] == "Beta" or med.labels[k] == "(blank)", med.labels[k])
    # a part on a group that isn't a column (a corrupt or hand-edited file) is refused, not read past the columns
    for g in [-1, 3, 99]:
        var odd = SheetObject.chart(2, 0, 0, 0)
        odd.group = g
        read_spec(Json.parse('{"part": 1}'), 0, odd, sheet)
        assert_equal(odd.part, 0, "group " + String(g))
    # only a median or p90 keeps a stat per group; a sum with a "(blank)" group keeps none
    var plain = chart(COMBINE_SUM)
    compute(plain, sheet)
    assert_true(len(plain.stats) == 0 and len(plain.has_stat) == 0 and "(blank)" in plain.labels)
    print("CHARTSPEC TESTS PASSED")
