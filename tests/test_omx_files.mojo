# mojoui.omxfile (format 2, MX frame's Parquet): a document round-trips everything a session can do to a table (edits,
# empty cells, a new word, added and removed rows, merged spellings, formulas, formats, charts, pivots, the Report and
# its filter), and a file that isn't an omxplorer document is refused with a message.
#   scripts/mxbuild.sh tests/test_omx_files.mojo -o build/test_omx_files && build/test_omx_files build/omx-files
from std.testing import assert_equal, assert_true
from std.sys import argv
from omxcore import Table, write_parquet, TEXT as MX_TEXT, DECIMAL as MX_DECIMAL, DATE as MX_DATE
from mojoui.sheet import Sheet
from mojoui.numformat import ColumnFormat, CURRENCY
from mojoui.omxfile import save_omx, open_omx, open_document
from mojoui.sheetpage import SheetObject, OBJ_PIVOT, CHART_LINE
from mojoui.reportpage import ReportTile, ReportFilter, new_tile, TILE_SUM, TILE_CHART
from mojoui.shared import make_dir


def small_table() raises -> Table:
    var t = Table.empty()
    var name = t.add_column("name", MX_TEXT)
    var amount = t.add_column("amount", MX_DECIMAL, 2)
    for w in ["Acme", "Beta"]:
        _ = t.add_word(name, w)
    t.append(name, 0)
    t.append(name, 1)
    t.append(amount, 100)
    t.append(amount, 250)
    return t^


def refused(path: String, why: String) raises:
    var raised = False
    try:
        _ = open_omx(path)
    except e:
        raised = True
        assert_true(String(e).startswith("can't open"), why + ": " + String(e))
        assert_true(why in String(e), why + " is not in: " + String(e))
    assert_true(raised, why + ": the file was opened")


def main() raises:
    var args = argv()
    var folder = String(args[1]) if len(args) > 1 else String("build/omx-files")
    make_dir(folder)

    # ---- a round trip of everything a session does ----
    var t = Table.empty()
    var customer = t.add_column("customer", MX_TEXT)
    var amount = t.add_column("amount", MX_DECIMAL, 2)
    var day = t.add_column("day", MX_DATE)
    for w in ["Acme Corp", "ACME Corporation", "Beta"]:
        _ = t.add_word(customer, w)
    for k in range(6):
        t.append(customer, Int64(k % 3))
        t.append(amount, Int64(1000 * (k + 1)))
        t.append(day, Int64(20089 + k))
    var sheet = Sheet(t^.share(), False)
    sheet.set_text(1, 0, "12.34")  # an edit
    sheet.set_text(0, 2, "Gamma")  # a word the dictionary didn't have
    sheet.set_text(1, 4, "")  # an empty cell
    var codes = List[Int64]()
    codes.append(1)
    _ = sheet.frame.merge(0, codes, 0)  # "ACME Corporation" reads as "Acme Corp"
    sheet.frame.remove(3)  # a removed row
    var values: List[String] = ["Delta", "7.00", "2025-03-01"]
    _ = sheet.frame.append(values)  # an added row (and another new word)
    var margin = sheet.formula("double = amount * 2")
    sheet.set_format(1, ColumnFormat(CURRENCY, 2, True, True, "€"))
    sheet.set_format(margin, ColumnFormat(CURRENCY, 0, True, False, "$"))
    var objects = List[SheetObject]()
    var pie = SheetObject.pivot(1, 0, -1, 10, 20, 400, 300)
    pie.style = CHART_LINE
    objects.append(pie^)
    var tiles = List[ReportTile]()
    tiles.append(new_tile(TILE_SUM, 1, -1))
    tiles.append(new_tile(TILE_CHART, 1, 0))
    var beta = sheet.code_of(0, "Beta")
    var path = folder + "/roundtrip.omx"
    save_omx(path, sheet, objects, tiles, ReportFilter(0, beta))

    var back_objects = List[SheetObject]()
    var back_tiles = List[ReportTile]()
    var back_filter = ReportFilter(-1, 0)
    var back = open_document(path, back_objects, back_tiles, back_filter)
    assert_equal(back.rows(), 6)  # 6 - 1 removed + 1 added
    var shown_names = String("")
    for r in range(back.rows()):
        shown_names += back.display(0, r) + "|"
    assert_equal(shown_names, "Acme Corp|Acme Corp|Gamma|Acme Corp|Beta|Delta|")  # (row 3 gone; merged; new words)
    assert_equal(back.plain_text(1, 0), "12.34")
    assert_equal(back.display(1, 3), "")  # the empty cell (row 4 was removed: it is row 3 now) stays empty
    assert_true(back.is_null(1, 3))
    assert_equal(back.plain_text(1, 5), "7.00")
    assert_equal(back.display(2, 5), "2025-03-01")
    assert_equal(back.display(1, 0), "€12.34")  # the format came back
    assert_equal(back.name(3), "double")
    assert_equal(back.plain_text(3, 0), "24.68")  # the formula came back and computes
    assert_equal(back.display(3, 0), "$25")
    assert_equal(len(back_objects), 1)
    assert_equal(back_objects[0].kind, OBJ_PIVOT)
    assert_equal(back_objects[0].x, 10)
    assert_equal(back_objects[0].h, 300)
    assert_equal(back_objects[0].style, CHART_LINE)
    assert_equal(len(back_tiles), 2)
    assert_equal(back_tiles[1].kind, TILE_CHART)
    assert_equal(back_filter.col, 0)
    assert_equal(back.text_of(0, Int64(back_filter.code)), "Beta")  # the filter is stored as a word

    # ---- files that aren't what they say ----
    var good = folder + "/good.omx"
    save_omx(good, Sheet(small_table().share(), False))
    assert_equal(open_omx(good).rows(), 2)
    write_parquet(folder + "/old-format.omx", small_table(), '{"omx": 1, "columns": [], "formulas": []}')
    refused(folder + "/old-format.omx", "older omxplorer")
    write_parquet(folder + "/no-metadata.omx", small_table(), "")
    refused(folder + "/no-metadata.omx", "isn't an omxplorer document")
    write_parquet(folder + "/not-json.omx", small_table(), "{not json")
    refused(folder + "/not-json.omx", "not JSON")
    write_parquet(folder + "/future.omx", small_table(), '{"omx": 3, "columns": []}')
    refused(folder + "/future.omx", "isn't an omxplorer document")
    write_parquet(folder + "/described-not-stored.omx", small_table(),
                  '{"omx": 2, "columns": [{"name": "name"}, {"name": "amount"}, {"name": "extra"}], "formulas": []}')
    refused(folder + "/described-not-stored.omx", "describes 3 columns but stores 2")
    write_parquet(folder + "/other-name.omx", small_table(), '{"omx": 2, "columns": [{"name": "name"}, {"name": "money"}], "formulas": []}')
    refused(folder + "/other-name.omx", "another name")
    write_parquet(folder + "/bad-formula.omx", small_table(),
                  '{"omx": 2, "columns": [{"name": "name"}, {"name": "amount"}], "formulas": [{"text": "x = nothing + 1"}]}')
    refused(folder + "/bad-formula.omx", "a formula column can't be rebuilt")
    refused("tests/fixtures/zero-columns.omx", "no columns")  # valid omx:2 metadata over a Parquet file with 0 columns (the writer refuses to make one)
    refused("tests/fixtures/format1.omx", "older omxplorer")  # a real format-1 file, made by the old pyarrow writer (tests/fixtures/make_v1.py)
    with open(folder + "/garbage.omx", "w") as g:
        g.write("this is not a parquet file at all")
    refused(folder + "/garbage.omx", "can't open")
    print("OMX FILE TESTS PASSED · round trip + 10 bad files refused")
