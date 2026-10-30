# mojoui.csvio: a CSV or Parquet file → MX frame's typed columns, for "open your data".
#
# MX frame's own readers (no Python). CSV (`mxframe.read_csv`): memory-mapped, parsed in parallel, types inferred from
# the first rows. Types: integers → INT; decimals → DECIMAL (2 places if every value has at most 2, else 4); ISO dates
# and times → DATE; true/false → BOOL; anything else → TEXT (a dictionary). An empty cell is a null.
# Parquet (`read_parquet`) carries its types. A Parquet file whose table wouldn't fit the memory budget (D-184) isn't
# read: it's opened for streaming (`scan_parquet`: the footer and the dictionaries), and the sheet reads its rows a row
# group at a time (mojoui.sheet).

from omxcore import (read_csv as mx_read_csv, CsvOptions, CsvResult, Table, SharedTable, ColumnKind, read_parquet,
                     scan_parquet, ParquetScan, JobCtl)
from mojoui.sheet import INT, DECIMAL, TEXT, DATE, BOOL, FLOAT, float_cell
from mojoui.numformat import date_text, decimal_text
from mojoui.shared import environment, memory_bytes
from std.time import perf_counter_ns


@fieldwise_init
struct CsvColumn(Copyable, Movable):
    """What the Import step shows about one column."""

    var name: String
    var kind: Int  # INT, DECIMAL, TEXT, DATE, BOOL, FLOAT
    var scale: Int
    var empty: Int  # empty cells (nulls); -1: not counted (a streamed file)
    var distinct: Int  # TEXT: values in its dictionary (0 for numbers)
    var sample: List[String]  # the first rows, as written in the file
    var failed: Int  # cells that didn't fit the column's type (now empty)


@fieldwise_init
struct CsvImport(Movable):
    var path: String
    var rows: Int
    var columns: List[CsvColumn]
    var skipped: List[String]  # columns past the limit (none: the limit is 4,096)
    var seconds: Float64  # read + parse
    var table: SharedTable  # the columns; the app builds its Sheet from it, then lets go (let_go)
    var parse_seconds: Float64
    var scan: Optional[ParquetScan]  # a streamed file: the sheet reads its rows from here (no table); let go with the table
    var is_streamed: Bool  # (still true once the sheet holds the scan)

    def streamed(self) -> Bool:
        return self.is_streamed

    def let_go(mut self) raises:
        """Drops this import's hold on the table (and the scan), so a replaced document's memory is freed."""
        self.table = SharedTable(Table.empty())
        self.scan = None


def kind_name(kind: Int) -> String:
    if kind == INT:
        return "Integer"
    if kind == DECIMAL:
        return "Decimal"
    if kind == DATE:
        return "Date"
    if kind == BOOL:
        return "Yes/No"
    if kind == FLOAT:
        return "Number"
    return "Text"


def empty_import() -> CsvImport:
    return CsvImport("", 0, List[CsvColumn](), List[String](), 0, SharedTable(Table.empty()), 0, None, False)


def read_csv(path: String, job: JobCtl = JobCtl()) raises -> CsvImport:
    """Reads the file into shared columns. Raises with a readable message if it isn't a table. `job`: the background
    job it runs for (progress in bytes, cancel; mojoui.sheetjobs)."""
    var r: CsvResult
    try:
        r = mx_read_csv(path, CsvOptions(), job)
    except e:
        raise Error("couldn't read " + path + " as CSV: " + String(e))
    var info = List[CsvColumn]()
    for c in r.columns:
        info.append(CsvColumn(c.name, c.kind.value, c.scale, c.empty, c.distinct, c.sample.copy(), c.failed_count))
    var skipped = r.skipped.copy()
    return CsvImport(path, r.rows, info^, skipped^, r.seconds, r.take_table().share(), r.seconds, None, False)


def read_table(path: String, job: JobCtl = JobCtl()) raises -> CsvImport:
    """A CSV or Parquet file (by its extension), as the Import step shows it."""
    if path.lower().endswith(".parquet"):
        return read_parquet_file(path, job)
    return read_csv(path, job)


def streams(rows: Int, columns: Int) -> Bool:
    """D-184: stream a file whose table (8 bytes a cell) is over a quarter of memory; OMX_STREAM_ROWS: over that many rows."""
    var asked = environment("OMX_STREAM_ROWS")
    if asked != "":
        try:
            return rows > Int(asked)
        except:
            pass
    return rows * max(columns, 1) * 8 > memory_bytes() // 4


def cell_text(t: Table, c: Int, row: Int) -> String:
    """A cell as written (the first rows the Import step shows)."""
    if t.is_null(c, row):
        return ""
    var v = t.get(c, row)
    var kind = t.kind(c).value
    if kind == TEXT:
        return t.text_of(c, Int(v))
    if kind == DATE:
        return date_text(v)
    if kind == DECIMAL:
        return decimal_text(v, t.scale(c))
    if kind == BOOL:
        return "true" if v != 0 else "false"
    if kind == FLOAT:
        return float_cell(v)
    return String(v)


def read_parquet_file(path: String, job: JobCtl = JobCtl()) raises -> CsvImport:
    """A Parquet file: read whole, or opened for streaming when it's too big (then its empty cells aren't counted)."""
    var t0 = perf_counter_ns()
    var scan: ParquetScan
    try:
        scan = scan_parquet(path)
    except e:
        raise Error("couldn't read " + path + " as Parquet: " + String(e))
    var info = List[CsvColumn]()
    if streams(scan.rows(), scan.columns()):
        var biggest = 0
        for g in range(scan.row_groups()):
            biggest = max(biggest, scan.group_rows(g))
        if biggest * scan.columns() * 8 > memory_bytes() // 8:  # (streaming reads a row group at a time: one must fit)
            raise Error("couldn't open " + path + ": it's too big for memory and its row groups (" + String(biggest)
                        + " rows each) are too big to stream; write it with smaller row groups")
        var cols = List[Int]()
        for c in range(scan.columns()):
            cols.append(c)
        var first = scan.read_group(0, cols) if scan.row_groups() > 0 else Table.empty()
        for c in range(scan.columns()):
            var sample = List[String]()
            var kind = scan.kind(c).value
            for r in range(min(3, first.rows())):  # (a read group's text codes are the file's: its words are the scan's)
                var text = scan.text_of(c, Int(first.get(c, r))) if kind == TEXT and not first.is_null(c, r) else cell_text(first, c, r)
                sample.append(text)
            info.append(CsvColumn(scan.name(c), kind, scan.scale(c), -1, scan.word_count(c) if kind == TEXT else 0, sample^, 0))
        var seconds = Float64(perf_counter_ns() - t0) / 1e9
        return CsvImport(path, scan.rows(), info^, List[String](), seconds, SharedTable(Table.empty()), seconds, scan^, True)
    var r = read_parquet(path, job)
    var t = r.take_table()
    for c in range(t.columns()):
        var sample = List[String]()
        for row in range(min(3, t.rows())):
            sample.append(cell_text(t, c, row))
        var kind = t.kind(c).value
        info.append(CsvColumn(t.name(c), kind, t.scale(c), t.null_count(c), len(t.dictionary(c)) if kind == TEXT else 0, sample^, 0))
    var seconds = Float64(perf_counter_ns() - t0) / 1e9
    var rows = t.rows()
    return CsvImport(path, rows, info^, List[String](), seconds, t^.share(), seconds, None, False)
