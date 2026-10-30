# mojoui.omxfile: an omxplorer document on disk, one file `name.omx` (format 2): a Parquet file written by MX frame
# (no Python) whose columns are the table as it stands (the session's edits, added and removed rows baked in; kinds,
# decimal scales, dictionaries and empty cells are Parquet's own) and whose metadata ("omx") is JSON: each column's
# format, the formula columns (their text and format), the sheet's charts and pivots, and the Report (its tiles and
# its filter, as a column and a word), each column's style and every styled cell (mojoui.cellstyle: bold, colours,
# alignment…), and the tabs' names. Other tools can read its columns.
#
# Format 1 (the pyarrow shim's files) is refused with a message that says so.

from omxcore import write_parquet, read_parquet, scan_parquet, ParquetScan, Table, UNCOMPRESSED
from mojoui.sheet import Sheet, placeholder_sheet, INT, DECIMAL, TEXT, BOOL, DATE
from mojoui.csvio import streams
from mojoui.json import Json, json_string
from mojoui.numformat import ColumnFormat
from mojoui.cellstyle import ALL_PARTS
from mojoui.sheetpage import SheetObject, OBJ_CHART, OBJ_PIVOT, COMBINE_SUM, COMBINE_COUNT, COMBINE_P90, ORDER_TABLE, ORDER_AZ
from mojoui.reportpage import ReportTile, ReportFilter, new_tile, TILE_SUM, TILE_COUNT, TILE_CHART, TILE_DISTINCT, TILE_LAST

comptime FORMAT = 2


def format_json(f: ColumnFormat) -> String:
    return ('{"style": ' + String(f.style) + ', "decimals": ' + String(f.decimals) + ', "thousands": ' + ("true" if f.thousands else "false")
            + ', "parens": ' + ("true" if f.parens else "false") + ', "symbol": ' + json_string(f.symbol) + "}")


def metadata(sheet: Sheet, objects: List[SheetObject], tiles: List[ReportTile], filter: ReportFilter, tab_names: List[String] = []) -> String:
    var stored = sheet.stored()
    var meta = String('{"omx": ' + String(FORMAT) + ', "columns": [')
    for c in range(stored):
        meta += ("," if c > 0 else "") + '{"name": ' + json_string(sheet.name(c)) + ', "format": ' + format_json(sheet.format_of(c))
        meta += ', "style": ' + String(sheet.column_style(c).bits) + "}"
    meta += '], "formulas": ['
    for f in range(sheet.columns() - stored):
        meta += ("," if f > 0 else "") + '{"text": ' + json_string(sheet.frame.formula_text(stored + f))
        meta += ', "format": ' + format_json(sheet.format_of(stored + f)) + ', "style": ' + String(sheet.column_style(stored + f).bits) + "}"
    meta += '], "cells": ['  # (column, row as saved: removed rows don't count, bits)
    var cells = sheet.styled_cells()
    var row = 0
    var saved = 0  # rows alive before `row`
    var first = True
    for cell in cells:
        if not sheet.alive(cell[1]):
            continue
        while row < cell[1]:
            if sheet.alive(row):
                saved += 1
            row += 1
        meta += ("" if first else ",") + "[" + String(cell[0]) + "," + String(saved) + "," + String(cell[2]) + "]"
        first = False
    meta += '], "tabs": ['
    for k in range(len(tab_names)):
        meta += ("," if k > 0 else "") + json_string(tab_names[k])
    meta += '], "objects": ['
    for k in range(len(objects)):
        ref o = objects[k]
        meta += ("," if k > 0 else "") + ('{"kind": ' + String(o.kind) + ', "x": ' + String(o.x) + ', "y": ' + String(o.y) + ', "w": ' + String(o.w)
                                          + ', "h": ' + String(o.h) + ', "value": ' + String(o.value) + ', "group": ' + String(o.group)
                                          + ', "across": ' + String(o.across) + ', "style": ' + String(o.style) + spec_json(o, sheet) + "}")
    meta += '], "report": {"tiles": ['
    for k in range(len(tiles)):
        meta += ("," if k > 0 else "") + '{"kind": ' + String(tiles[k].kind) + ', "col": ' + String(tiles[k].col) + ', "group": ' + String(tiles[k].group) + spec_json(tiles[k].chart, sheet) + "}"
    meta += '], "filter": {"col": ' + String(filter.col) + ', "word": '
    meta += json_string(sheet.text_of(filter.col, Int64(filter.code)) if filter.col >= 0 else "") + "}}}"
    return meta


def spec_json(o: SheetObject, sheet: Sheet) -> String:
    """A chart's spec as JSON keys (goal 28; all optional: an older file has none and opens as it was). The filter keeps
    its value as text, like the Report's, so it survives the column's codes changing."""
    var only = String("")
    if o.only_col >= 0:
        only = ', "only_col": ' + String(o.only_col) + ', "only_word": ' + json_string(sheet.text_of(o.only_col, Int64(o.only_code)) if sheet.kind(o.only_col) == TEXT else String(o.only_code))
    var num = String("")
    if o.num_col >= 0 and o.num_op != 0:
        num = ', "num_col": ' + String(o.num_col) + ', "num_op": ' + String(o.num_op) + ', "num_lo": ' + String(o.num_lo) + ', "num_hi": ' + String(o.num_hi)
    return ', "combine": ' + String(o.combine) + ', "order": ' + String(o.order) + ', "top": ' + String(o.top) + ', "part": ' + String(o.part) + only + num


def read_spec(j: Json, node: Int, mut o: SheetObject, sheet: Sheet):
    """The keys spec_json wrote, each checked (an unknown value keeps the default)."""
    var combine = j.number(j.get(node, "combine"), COMBINE_SUM)
    o.combine = combine if COMBINE_SUM <= combine <= COMBINE_P90 else COMBINE_SUM
    var order = j.number(j.get(node, "order"), ORDER_TABLE)
    o.order = order if ORDER_TABLE <= order <= ORDER_AZ else ORDER_TABLE
    o.top = max(j.number(j.get(node, "top"), 0), 0)
    var part = j.number(j.get(node, "part"), 0)
    o.part = part if 0 <= part <= 3 and (part == 0 or (0 <= o.group < sheet.columns() and sheet.kind(o.group) == DATE)) else 0
    var only = j.number(j.get(node, "only_col"), -1)
    o.only_col = -1  # (every row, unless the file names a filter it still can)
    var nc = j.number(j.get(node, "num_col"), -1)
    var op = j.number(j.get(node, "num_op"), 0)
    o.num_col = -1
    o.num_op = 0
    if 0 <= nc < sheet.columns() and (sheet.kind(nc) == INT or sheet.kind(nc) == DECIMAL) and 1 <= op <= 5:  # (a number condition on a number column)
        o.num_col = nc
        o.num_op = op
        o.num_lo = j.number(j.get(node, "num_lo"), 0)
        o.num_hi = j.number(j.get(node, "num_hi"), 0)
    if 0 <= only < sheet.columns() and (sheet.kind(only) == TEXT or sheet.kind(only) == BOOL):
        var word = j.text(j.get(node, "only_word"))
        if sheet.kind(only) == BOOL:
            o.only_col = only
            o.only_code = 1 if word == "1" else 0
        else:
            for code in range(sheet.word_count(only)):
                if sheet.text_of(only, Int64(code)) == word:
                    o.only_col = only
                    o.only_code = code


def save_omx(path: String, sheet: Sheet, objects: List[SheetObject] = [], tiles: List[ReportTile] = [],
             filter: ReportFilter = ReportFilter(-1, 0), tab_names: List[String] = []) raises:
    """Writes the table as it stands (every alive row, the edits applied), its styles, the sheet's charts and pivots,
    the Report (its tiles and filter) and the tabs' names to `path` (.omx)."""
    # uncompressed for now: a document saved on Linux must open on the Mac build, which has no zstd or snappy (vendoring static codecs for it is a follow-up)
    var meta = metadata(sheet, objects, tiles, filter, tab_names)
    if sheet.streamed():  # (D-214: streamed out a row group at a time, the edits applied; atomic, so it may replace the file it reads)
        sheet.frame.save(path, meta, UNCOMPRESSED)
    else:
        write_parquet(path, sheet.frame.bake(), meta, UNCOMPRESSED)


def format_from(j: Json, node: Int) -> ColumnFormat:
    """A saved format, or Automatic if it isn't one this code can draw."""
    if node < 0:
        return ColumnFormat.auto()
    var f = ColumnFormat(j.number(j.get(node, "style")), j.number(j.get(node, "decimals"), -1), j.flag(j.get(node, "thousands"), True),
                         j.flag(j.get(node, "parens")), j.text(j.get(node, "symbol"), "$"))
    return f^ if f.valid() else ColumnFormat.auto()


def is_number(sheet: Sheet, c: Int) -> Bool:
    return 0 <= c < sheet.columns() and (sheet.kind(c) == INT or sheet.kind(c) == DECIMAL)


def is_text(sheet: Sheet, c: Int) -> Bool:
    return 0 <= c < sheet.stored() and sheet.kind(c) == TEXT


def read_meta(path: String, mut table: Table) raises -> Json:
    """The file's table (moved into `table`) and its metadata, refused unless it is a format-2 omxplorer document."""
    var r = read_parquet(path)
    table = r.take_table()
    if table.columns() == 0:
        raise Error("it has no columns")
    return parse_meta(r.metadata)


def parse_meta(text: String) raises -> Json:
    """A document's "omx" metadata, refused unless it is format 2."""
    if text == "":
        raise Error("it isn't an omxplorer document")
    var j = Json.parse(text)
    var version = j.number(j.get(0, "omx"))
    if version == 1:
        raise Error("it was saved by an older omxplorer (format 1); open the original CSV and save it again")
    if version != FORMAT:
        raise Error("it isn't an omxplorer document")
    return j^


def open_omx(path: String, use_gpu: Bool = True) raises -> Sheet:
    """Reads `path` (.omx): the table, its formula columns and every column's format."""
    var j = Json()
    return read_document(path, j, use_gpu)


def read_document(path: String, mut j: Json, use_gpu: Bool) raises -> Sheet:
    """The table with its formulas and formats; `j` is the file's metadata (the objects and the Report are in it).
    A document too big for memory (as for a Parquet file, D-184) opens streamed (D-214)."""
    var sheet = placeholder_sheet()
    var big = Optional[ParquetScan](None)
    try:
        var scan = scan_parquet(path)  # (the footer only: how big it is)
        if scan.columns() > 0 and streams(scan.rows(), scan.columns()):
            big = scan^
    except:
        pass  # (not Parquet, or unreadable: the whole read below says why, as it always has)
    var streamed = Bool(big)
    if streamed:  # (decided first: a big document's metadata problems are reported, never "fixed" by reading it whole)
        try:
            j = parse_meta(big.value().metadata())
        except e:
            raise Error("can't open " + path + ": " + String(e))
        sheet = Sheet(big.value(), use_gpu)
    else:
        var table = Table()
        try:
            j = read_meta(path, table)
        except e:
            raise Error("can't open " + path + ": " + String(e))
        sheet = Sheet(table^.share(), use_gpu)
    var specs = j.get(0, "columns")
    if j.size(specs) != sheet.stored():
        raise Error("can't open " + path + ": it describes " + String(j.size(specs)) + " columns but stores " + String(sheet.stored()))
    for c in range(sheet.stored()):
        if j.text(j.get(j.at(specs, c), "name")) != sheet.name(c):
            raise Error("can't open " + path + ": column " + String(c + 1) + " is described as another name than it is stored under")
    for c in range(sheet.stored()):
        sheet.set_format(c, format_from(j, j.get(j.at(specs, c), "format")))
        sheet.set_column_style(c, style_from(j, j.get(j.at(specs, c), "style")))
    var formulas = j.get(0, "formulas")
    for k in range(j.size(formulas)):
        var c: Int
        try:
            c = sheet.formula(j.text(j.get(j.at(formulas, k), "text")))
        except e:
            raise Error("can't open " + path + ": a formula column can't be rebuilt: " + String(e))
        sheet.set_format(c, format_from(j, j.get(j.at(formulas, k), "format")))
        sheet.set_column_style(c, style_from(j, j.get(j.at(formulas, k), "style")))
    var cells = j.get(0, "cells")  # (missing in files saved before goal 21: no styles)
    for k in range(j.size(cells)):
        var spec = j.at(cells, k)
        var c = j.number(j.at(spec, 0), -1)
        var row = j.number(j.at(spec, 1), -1)
        if 0 <= c < sheet.columns() and 0 <= row < sheet.rows():
            sheet.set_cell_style(c, row, style_from(j, j.at(spec, 2)))
    return sheet^


def style_from(j: Json, node: Int) -> Int:
    """A saved style's bits, or plain if it isn't a style this code knows."""
    var bits = j.number(node, 0) if node >= 0 else 0
    return bits if bits & ~ALL_PARTS == 0 and bits >= 0 else 0


def open_document(path: String, mut objects: List[SheetObject], mut tiles: List[ReportTile], mut filter: ReportFilter) raises -> Sheet:
    var tab_names = List[String]()
    return open_document(path, objects, tiles, filter, tab_names)


def open_document(path: String, mut objects: List[SheetObject], mut tiles: List[ReportTile], mut filter: ReportFilter,
                  mut tab_names: List[String]) raises -> Sheet:
    """Reads `path` (.omx): returns the table and fills in the sheet's objects, the Report and the tabs' names as
    saved (the sheet's, the Report's; "" for one that keeps its own name). An object or tile that names a column the
    table doesn't have (or a kind this code doesn't know) is left out rather than trusted."""
    var j = Json()
    var sheet = read_document(path, j, True)
    tab_names = List[String]()
    var tabs = j.get(0, "tabs")  # (missing in files saved before goal 21)
    for k in range(min(j.size(tabs), 2)):
        var name = j.text(j.at(tabs, k))
        tab_names.append(name if name.byte_length() <= 64 else "")
    objects = List[SheetObject]()
    var specs = j.get(0, "objects")
    for k in range(j.size(specs)):
        var o = j.at(specs, k)
        var kind = j.number(j.get(o, "kind"))
        var value = j.number(j.get(o, "value"), -1)
        var group = j.number(j.get(o, "group"), -1)
        var across = j.number(j.get(o, "across"), -1)
        var dated = kind == OBJ_CHART and 0 <= group < sheet.columns() and sheet.kind(group) == DATE and 1 <= j.number(j.get(o, "part"), 0) <= 3  # (a chart of a date's months)
        if (kind != OBJ_CHART and kind != OBJ_PIVOT) or not is_number(sheet, value) or not (is_text(sheet, group) or dated) or not (across == -1 or is_text(sheet, across)):
            continue
        var obj = SheetObject.chart(value, group, j.number(j.get(o, "x")), j.number(j.get(o, "y")), j.number(j.get(o, "w"), 520), j.number(j.get(o, "h"), 340))
        obj.kind = kind
        obj.across = across
        obj.style = j.number(j.get(o, "style"))
        read_spec(j, o, obj, sheet)
        objects.append(obj^)
    tiles = List[ReportTile]()
    var report = j.get(0, "report")
    var tile_specs = j.get(report, "tiles")
    for k in range(j.size(tile_specs)):
        var t = j.at(tile_specs, k)
        var kind = j.number(j.get(t, "kind"), -1)
        var col = j.number(j.get(t, "col"), -1)
        var group = j.number(j.get(t, "group"), -1)
        var column_ok = (0 <= col < sheet.columns()) if (kind == TILE_DISTINCT or kind == TILE_COUNT) else is_number(sheet, col)  # (distinct and count: any column)
        var dated = kind == TILE_CHART and 0 <= group < sheet.columns() and sheet.kind(group) == DATE and 1 <= j.number(j.get(t, "part"), 0) <= 3
        if not (TILE_SUM <= kind <= TILE_LAST) or not column_ok or (kind == TILE_CHART and not (is_text(sheet, group) or dated)):
            continue
        var tile = new_tile(kind, col, group)
        read_spec(j, t, tile.chart, sheet)
        tiles.append(tile^)
    var f = j.get(report, "filter")
    var fcol = j.number(j.get(f, "col"), -1)
    filter = ReportFilter(-1, 0)
    if is_text(sheet, fcol):
        var code = sheet.code_of(fcol, j.text(j.get(f, "word")))
        if code >= 0:
            filter = ReportFilter(fcol, code)
    return sheet^
