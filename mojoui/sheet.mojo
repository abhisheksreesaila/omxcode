# mojoui.sheet: omxplorer's table, on the MX frame package (`from omxcore import …`): a package `Frame` (the shared
# columns, this session's edits, formula columns), what the package leaves to the app (each column's display format),
# and the GPU copy of the table when there is a GPU. It is a DataGrid's source (nulls show blank, edited cells get the
# corner mark) and it formats values for cells, totals, charts and pivots. Every aggregate goes through
# `Sheet.totals`: one `Query(frame).on_device(dt)…compute(AUTO)` (docs/mxframe-mojo-api.md section 5).
#
# A sheet can also be *streamed* (D-185, D-213): a Parquet file too big for memory, opened with the package's
# `scan_parquet` as a `Frame(scan)`. Its rows are read through the frame's cache of decoded column chunks as the grid
# shows them, every aggregate is a `Query(frame)` that streams the file with the session's edits applied (AUTO: the
# package runs it on the GPU where that's faster, F-146),
# and it edits, undoes and saves (`Frame.save`, streamed) like a sheet in memory. Sorting holds ~50 bytes a row
# (the package's permutation), so it's refused when that wouldn't fit a quarter of memory (D-215).
#
# The stand-in engine (mojoui.frame, frame_gpu) stays for MX Studio and the Workbook.

from std.memory import ArcPointer
from std.collections import Dict
from omxcore import float_text
from omxcore.frame import FORMULA  # (a formula step in the package's undo log)
from omxcore import (Frame as MxFrame, Table, SharedTable, DeviceTable, Query, Expr, col, sum, count, min_of, max_of, count_distinct, median, percentile,
                     AUTO as MX_AUTO, GPU as MX_GPU, CPU as MX_CPU, TEXT as MX_TEXT, DECIMAL as MX_DECIMAL, DATE as MX_DATE,
                     gpu_available, ParquetScan, frame_snapshot, JobCtl)
from mojoui.datagrid import GridSource
from mojoui.cellstyle import CellStyle, ALL_PARTS
from mojoui.shared import memory_bytes
from mojoui.numformat import (ColumnFormat, format_number, format_date, date_text, parse_decimal, decimal_text, AUTO, NUMBER, PERCENT,
                              CURRENCY)

# column kinds as the app reads them (the package's ColumnKind values)
comptime INT = 0
comptime DECIMAL = 1
comptime TEXT = 2
comptime DATE = 3
comptime BOOL = 4
comptime FLOAT = 5  # float64 (MX frame 321870f, F-157): the value holds the float's bits; shown, not summed yet
comptime STYLE_COLS = 1 << 16  # a cell override's key: row * STYLE_COLS + column



def csv_cell(text: String) -> String:
    """One CSV value: as it is, or in double quotes (its quotes doubled) when it holds a comma, a quote or a line break."""
    if text.find(",") < 0 and text.find("\"") < 0 and text.find("\n") < 0 and text.find("\r") < 0:
        return text
    return "\"" + text.replace("\"", "\"\"") + "\""


def float_cell(v: Int64) -> String:
    """A FLOAT value (its float64's bits) as the shortest text that reads back to it."""
    return float_text(Float64(from_bits=UInt64(v)))

@fieldwise_init
struct StyleStep(Copyable, Movable):
    """One part of a change the sheet logs itself, as it was before (Undo puts it back): a column's style (row -1), a
    cell's override (`had`: there was one) or a column's number format (row -2). Formula columns are steps of the
    package's own log (omxcore 2585dc9), like the edits."""

    var col: Int
    var row: Int
    var bits: Int
    var had: Bool
    var number: ColumnFormat  # (a number-format step: the format before; `row` is -2)


@fieldwise_init
struct StyleChange(Copyable, Movable):
    """One format change the user made (it may touch a column and many overrides at once); `edits` is how many of
    the table's own edits there were then, so Undo knows which came last."""

    var steps: List[StyleStep]
    var edits: Int


@fieldwise_init
struct Sums(Copyable, Movable):
    """One group-by: per group the sum of the value column, the rows, and the rows where the value isn't empty."""

    var sums: List[Int]
    var counts: List[Int]  # rows
    var present: List[Int]  # rows whose value is not null (averages divide by this)
    var milliseconds: Float64
    var on_gpu: Bool


comptime SORT_BYTES_PER_ROW = 50  # a streamed sort's order (the package's permutation: keys and row numbers)
comptime MEDIAN_BYTES = 27  # an exact median over a scan: every non-empty value, grouped (the package's measure)
comptime DISTINCT_BYTES = 35  # count distinct over a scan: per different value (the package's measure)


struct Notes(Movable):
    """What a sheet's read-only methods learn as they read (a grid draws through them), behind an ArcPointer: the
    last read that failed, where the last aggregate ran, and each column's plain totals while the edits stand."""

    var problem: String  # the last read that failed (a streamed file changed or cut short since it was opened): shown, not hidden
    var last_gpu: Bool  # the last aggregate ran on the GPU
    var plain: Dict[Int, Sums]  # (streamed) column → its totals over every row, kept while `plain_edits` holds
    var plain_edits: Int

    def __init__(out self):
        self.problem = ""
        self.last_gpu = False
        self.plain = Dict[Int, Sums]()
        self.plain_edits = 0


def empty_table() raises -> Table:
    """A one-cell placeholder (a column "A" holding ""), what the app shows before a file is opened."""
    var t = Table.empty()
    var c = t.add_column("A", MX_TEXT)
    _ = t.add_word(c, "")
    t.append(c, 0)
    return t^


def blank_table(rows: Int = 20) raises -> Table:
    """A new blank sheet's table: Item (text), Amount (decimal, 2 places) and Date, `rows` empty-ish rows."""
    var t = Table.empty()
    var item = t.add_column("Item", MX_TEXT)
    _ = t.add_word(item, "")
    var amount = t.add_column("Amount", MX_DECIMAL, 2)
    var day = t.add_column("Date", MX_DATE)
    for _ in range(rows):
        t.append(item, 0)
        t.append(amount, 0)
        t.append(day, 20089)  # (2025-01-01)
    return t^


def placeholder_sheet() -> Sheet:
    """What the app holds before a file is opened (no GPU copy)."""
    try:
        return Sheet(empty_table().share(), False)
    except:
        return Sheet(Table.empty().share(), False)


struct Sheet(Movable, GridSource):
    var frame: MxFrame
    var formats: List[ColumnFormat]  # per column (stored, then formulas): how its values read; AUTO = by type
    var device: Optional[DeviceTable]  # the table on the GPU (None: no GPU, or the table didn't fit)
    var device_name: String
    var mode: Int  # CPU, GPU or AUTO (the default: the GPU from a million rows); tests force the GPU to compare it with the CPU
    var scan: Optional[ParquetScan]  # a streamed file (D-185): the frame reads its rows from here
    var notes: ArcPointer[Notes]
    var styles: List[Int]  # per column: its CellStyle's bits (mojoui.cellstyle); missing = plain
    var cell_styles: Dict[Int, Int]  # row * STYLE_COLS + column → the cell's own style, over its column's (sparse)
    var style_log: List[StyleChange]  # format changes Undo can take back, newest last (the package logs the rest: edits, merges, formulas)
    var last_undone: String  # what the last undo took back ("a format change", "the formula column x", "an edit")
    var job: JobCtl  # the background job this sheet's queries run for (a snapshot's: progress in rows, cancel); JobCtl() for plain calls

    def __init__(out self, table: SharedTable, use_gpu: Bool = True):
        self.frame = MxFrame(table)
        self.formats = List[ColumnFormat]()
        self.styles = List[Int]()
        self.cell_styles = Dict[Int, Int]()
        self.style_log = List[StyleChange]()
        self.last_undone = ""
        self.job = JobCtl()
        self.device = None
        self.device_name = "CPU"
        self.mode = MX_AUTO
        self.scan = None
        self.notes = ArcPointer(Notes())
        if use_gpu and gpu_available():
            try:
                var dt = DeviceTable(table)
                self.device_name = dt.context().name()
                self.device = dt
            except:
                self.device = None

    def __init__(out self, scan: ParquetScan, use_gpu: Bool = True):
        """A streamed sheet over a Parquet file: its columns now, its words and rows when they're shown; editable.
        use_gpu False: always the CPU."""
        self.frame = MxFrame(scan)
        self.formats = List[ColumnFormat]()
        self.styles = List[Int]()
        self.cell_styles = Dict[Int, Int]()
        self.style_log = List[StyleChange]()
        self.last_undone = ""
        self.job = JobCtl()
        self.device = None
        self.device_name = "CPU"
        self.mode = MX_AUTO if use_gpu else MX_CPU  # (the package picks per machine and plan: F-146; the CPU on many cores, the GPU on few)
        if use_gpu and gpu_available():  # (the GPU's name, for "… ms on <GPU>": a one-row device table, given back at once)
            try:
                var probe = DeviceTable(empty_table().share())
                self.device_name = probe.context().name()
                probe.release()
            except:
                pass
        self.scan = scan.copy()
        self.notes = ArcPointer(Notes())

    def snapshot(self) -> Sheet:
        """A sheet of its own with this one's edits, formulas and formats as they are now, for a background job: the
        caller goes on editing this one. It shares the table and the GPU copy (read only: a DeviceTable is a shared
        handle) and the file, not the notes. Don't release() this sheet while a job holds its snapshot."""
        var out = Sheet(self.scan.value(), False) if self.scan else Sheet(self.frame.base, False)
        out.frame = frame_snapshot(self.frame)
        out.formats = self.formats.copy()
        out.styles = self.styles.copy()
        out.cell_styles = self.cell_styles.copy()
        out.device = self.device
        out.device_name = self.device_name
        out.mode = self.mode
        return out^

    def streamed(self) -> Bool:
        return Bool(self.scan)

    def last_device(self) -> String:
        """Where the last aggregate ran: the GPU's name, or "CPU"."""
        return self.device_name if self.notes[].last_gpu else "CPU"

    def read_problem(self) -> String:
        """Why the last rows read from a streamed file failed ("" when they didn't)."""
        return self.notes[].problem

    def release(mut self):
        """Gives the GPU copy back (the document closed or was replaced)."""
        if self.device:
            self.device.value().release()
        self.device = None

    def table(self) -> SharedTable:
        return self.frame.base

    # ---------- shape ----------

    def stored(self) -> Int:
        return self.frame.stored()

    def columns(self) -> Int:
        return self.frame.columns()

    def rows(self) -> Int:
        return self.frame.rows()

    def alive(self, row: Int) -> Bool:
        return self.frame.alive(row)

    def name(self, c: Int) -> String:
        return self.frame.name(c)

    def kind(self, c: Int) -> Int:
        return self.frame.kind(c).value

    def scale(self, c: Int) -> Int:
        return self.frame.scale(c)

    def index(self, name: String) -> Int:
        return self.frame.index(name)

    def edits(self) -> Int:
        return self.frame.edits

    def word_count(self, c: Int) -> Int:
        """A text column's values now (its dictionary and the words typed into it): its codes run 0 up to this.
        Streamed: the file's dictionary is built by the package on first use; a failure is the read problem."""
        if not (c < self.stored() and self.kind(c) == TEXT):
            return 0
        try:
            return self.frame.word_count(c)
        except e:
            self.note_problem(e)
            return 0

    def text_of(self, c: Int, code: Int64) -> String:
        try:
            return self.frame.text_of(c, code)
        except e:
            self.note_problem(e)
            return ""

    def code_of(self, c: Int, word: String) -> Int:
        try:
            return self.frame.code_of(c, word)
        except e:
            self.note_problem(e)
            return -1

    def note_problem(self, e: Error):
        """A failed read of a streamed file is shown (the status bar) until a read from the file works again; a sheet
        in memory has no file to fail (its lookups answer empty)."""
        if self.scan:
            self.notes[].problem = String(e)

    # ---------- values ----------

    def value(self, c: Int, row: Int) -> Int64:
        try:
            var loads = self.frame.cache_loads() if self.scan else 0
            var v = self.frame.get(c, row)
            if self.notes[].problem != "" and self.scan and self.frame.cache_loads() != loads:
                self.notes[].problem = ""  # (a read from the file worked again; one from the cache proves nothing)
            return v
        except e:
            self.note_problem(e)
            return 0

    def is_null(self, c: Int, row: Int) -> Bool:
        try:
            var loads = self.frame.cache_loads() if self.scan else 0
            var empty = self.frame.is_null(c, row)
            if self.notes[].problem != "" and self.scan and self.frame.cache_loads() != loads:
                self.notes[].problem = ""  # (a read from the file worked again)
            return empty
        except e:
            self.note_problem(e)
            return False

    def edited(self, c: Int, row: Int) -> Bool:
        return c < self.stored() and self.frame.edited(c, row)

    # ---------- formats (per column; applied only to what's shown) ----------

    def format_of(self, c: Int) -> ColumnFormat:
        return self.formats[c].copy() if 0 <= c < len(self.formats) else ColumnFormat.auto()

    def set_format(mut self, c: Int, f: ColumnFormat):
        while len(self.formats) <= c:
            self.formats.append(ColumnFormat.auto())
        self.formats[c] = f.copy()

    def format_value(self, c: Int, v: Int64, total: Bool = False) -> String:
        """A value of column c (as stored, scaled) as the column's format shows it: cells, totals, pivots, charts.
        total: a sum or an average (a column without a format still gets thousands separators there)."""
        var kind = self.kind(c)
        var f = self.format_of(c)
        if total and f.is_auto() and (kind == INT or kind == DECIMAL):
            f = ColumnFormat(NUMBER, -1, True, False, "$")
        if kind == DATE:
            return date_text(v) if f.is_auto() else format_date(v, f)
        if kind == TEXT:
            return String(v)
        if kind == BOOL:
            return "true" if v != 0 else "false"
        if kind == FLOAT:
            return float_cell(v)
        if f.is_auto():
            return decimal_text(v, self.scale(c)) if kind == DECIMAL else String(v)
        return format_number(v, self.scale(c) if kind == DECIMAL else 0, f)

    def plain_text(self, c: Int, row: Int) -> String:
        """The value as typed, without its column's format ($, separators, %): what an editor starts from."""
        if self.is_null(c, row):
            return ""
        var v = self.value(c, row)
        var kind = self.kind(c)
        if kind == TEXT and c < self.stored():
            return self.text_of(c, v)
        if kind == DATE:
            return date_text(v)
        if kind == DECIMAL:
            return decimal_text(v, self.scale(c))
        if kind == BOOL:
            return "true" if v != 0 else "false"
        if kind == FLOAT:
            return float_cell(v)
        return String(v)

    def csv(self) -> String:
        """Every live row as CSV (RFC 4180: a header of the column names, values as typed, without formats; a value with a
        comma, a quote or a line break in quotes, its quotes doubled). Formula columns included, edits applied."""
        var out = String()
        var cols = self.columns()
        for c in range(cols):
            out += ("," if c > 0 else "") + csv_cell(self.name(c))
        out += "\n"
        for r in range(self.rows()):
            if not self.alive(r):
                continue
            for c in range(cols):
                out += ("," if c > 0 else "") + csv_cell(self.plain_text(c, r))
            out += "\n"
        return out^

    def write_csv(self, path: String) raises:
        """The table as a CSV file at `path` (csv())."""
        with open(path, "w") as f:
            f.write(self.csv())

    def format_average(self, c: Int, total: Int, count: Int) -> String:
        """total ÷ count of column c in its format, rounded once (half away from zero), with two more places
        than a whole-number column has (qty's 4.8 reads 4.80) and two more for a percent (36.42%)."""
        var scale = self.scale(c) if self.kind(c) == DECIMAL else 0
        var f = self.format_of(c)
        if f.is_auto():
            f = ColumnFormat(NUMBER, -1, True, False, "$")
        if f.decimals < 0:
            f.decimals = scale if scale > 0 else 2
        var places = f.decimals + (2 if f.style == PERCENT else 0)
        var num = total * Int(10 ** places)
        var den = max(count, 1) * Int(10 ** scale)
        var q = (abs(num) + den // 2) // den
        return format_number(Int64(q if num >= 0 else -q), places, f)

    def display(self, c: Int, row: Int) -> String:
        """What the cell shows: blank for a null, the column's format for a number or date."""
        if self.is_null(c, row):
            return ""
        var v = self.value(c, row)
        var kind = self.kind(c)
        if kind == TEXT and c < self.stored():
            return self.text_of(c, v)
        if not self.format_of(c).is_auto() or kind == BOOL:
            return self.format_value(c, v)
        if kind == DATE:
            return date_text(v)
        if kind == DECIMAL:
            return decimal_text(v, self.scale(c))
        return String(v)

    # ---------- edits ----------

    def set_text(mut self, c: Int, row: Int, text: String) raises:
        """A typed value: empty makes the cell empty (null); numbers read what the formats print back
        ("$1,234.50", "(1,234)", "36.4%"); the other kinds as the package parses them."""
        var kind = self.kind(c)
        if String(text.strip()) == "" or (c >= self.stored()):
            self.frame.set_text(c, row, text)
        elif kind == INT:
            self.frame.set(c, row, parse_decimal(text, 0))
        elif kind == DECIMAL:
            self.frame.set(c, row, parse_decimal(text, self.scale(c)))
        else:
            self.frame.set_text(c, row, text)

    def append(mut self) raises -> Int:
        """A new empty row; returns its number."""
        return self.frame.append(List[String]())

    def undo_depth(self) -> Int:
        """How many changes Undo could take back now (edits and format changes): an app that keeps its own changes
        (a chart's settings) records this with each, so one Undo takes back whichever came last."""
        return len(self.frame.log) + len(self.style_log)

    def undo_drops(self) -> Int:
        """The column the next Undo would take away (a new formula column), -1 if none: an app moves or refuses what
        reads it first (a chart, a tile, a sort)."""
        var name = self._next_formula_step()
        if name.byte_length() == 0 or self.frame.index(name) < 0:
            return -1
        for f in self.frame.swaps[self.frame.log[len(self.frame.log) - 1].row]:
            if f.name == name:
                return -1  # (a replaced formula's old one comes back: no column goes)
        return self.frame.index(name)

    def _next_formula_step(self) -> String:
        """The formula column the next Undo changes (added, replaced or removed: one step of the package's log), ""
        when it changes something else."""
        var edits = len(self.frame.log)
        if edits == 0 or (len(self.style_log) > 0 and self.style_log[len(self.style_log) - 1].edits >= edits):
            return ""
        ref e = self.frame.log[edits - 1]
        if e.kind != FORMULA:
            return ""
        ref before = self.frame.swaps[e.row]  # (the formulas the step's undo puts back)
        for m in range(self.stored(), self.columns()):  # added or replaced: a formula now that wasn't, or read otherwise
            var t = self.frame.formula_text(m)
            var same = False
            for f in before:
                if f.text == t:
                    same = True
            if not same:
                return self.name(m)
        for f in before:  # removed: one there was that isn't
            if self.frame.index(f.name) < 0:
                return f.name
        return ""

    def undo(mut self) -> Bool:
        """Takes back the last change: a format change (styles, number formats) or an edit to the table, whichever
        came last."""
        var edits = len(self.frame.log)
        if len(self.style_log) > 0 and self.style_log[len(self.style_log) - 1].edits >= edits:
            var change = self.style_log.pop()
            self.last_undone = "a format change"
            var k = len(change.steps) - 1
            while k >= 0:
                ref s = change.steps[k]
                if s.row == -2:
                    self.set_format(s.col, s.number)
                elif s.row < 0:
                    self.set_column_style(s.col, s.bits)
                elif s.had:
                    self.cell_styles[s.row * STYLE_COLS + s.col] = s.bits
                else:
                    _ = self.cell_styles.pop(s.row * STYLE_COLS + s.col, 0)
                k -= 1
            return True
        var formula = self._next_formula_step()
        self.last_undone = "the formula column " + formula if formula.byte_length() > 0 else "an edit"
        return self.frame.undo()

    # ---------- cell styles (mojoui.cellstyle: a column's, and sparse cell overrides) ----------

    def column_style(self, c: Int) -> CellStyle:
        return CellStyle(self.styles[c]) if 0 <= c < len(self.styles) else CellStyle()

    def style_of(self, c: Int, row: Int) -> CellStyle:
        """How cell (c, row) looks: its own style if it has one, else its column's (row -1: the column's)."""
        if row >= 0 and len(self.cell_styles) > 0:
            var own = self.cell_styles.get(row * STYLE_COLS + c)
            if own:
                return CellStyle(own.value())
        return self.column_style(c)

    def set_column_style(mut self, c: Int, bits: Int):
        while len(self.styles) <= c:
            self.styles.append(0)
        self.styles[c] = bits

    def set_cell_style(mut self, c: Int, row: Int, bits: Int):
        """A cell's own style, as read from a file (not logged)."""
        self.cell_styles[row * STYLE_COLS + c] = bits

    def styled_cells(self) -> List[Tuple[Int, Int, Int]]:
        """Every cell override as (column, row, bits), in row then column order (a file writes them)."""
        var out = List[Tuple[Int, Int, Int]]()
        var keys = List[Int]()
        for e in self.cell_styles.items():
            keys.append(e.key)
        sort(keys)
        for key in keys:
            out.append((key % STYLE_COLS, key // STYLE_COLS, self.cell_styles.get(key).value()))
        return out^

    def restyle(mut self, c: Int, row: Int, mask: Int, value: Int):
        """Sets the parts of the style under `mask` (mojoui.cellstyle's bits) to `value`'s: on cell (c, row), or with
        row -1 on the whole column, which sets the same parts of every cell override in it too, as a spreadsheet
        does (an override left equal to its column's goes). Undo takes it back in one step."""
        if not (0 <= c < self.columns()):
            return
        var steps = List[StyleStep]()
        if row >= 0:
            var key = row * STYLE_COLS + c
            var own = self.cell_styles.get(key)
            steps.append(StyleStep(c, row, own.value() if own else 0, Bool(own), ColumnFormat.auto()))
            var bits = self.style_of(c, row).set(mask, value).bits
            if bits == self.column_style(c).bits:
                _ = self.cell_styles.pop(key, 0)
            else:
                self.cell_styles[key] = bits
        else:
            steps.append(StyleStep(c, -1, self.column_style(c).bits, False, ColumnFormat.auto()))
            self.set_column_style(c, self.column_style(c).set(mask, value).bits)
            var mine = List[Tuple[Int, Int]]()
            for e in self.cell_styles.items():
                if e.key % STYLE_COLS == c:
                    mine.append((e.key, e.value))
            var column = self.column_style(c).bits
            for m in mine:
                var key = m[0]
                var before = m[1]
                steps.append(StyleStep(c, key // STYLE_COLS, before, True, ColumnFormat.auto()))
                var bits = CellStyle(before).set(mask, value).bits
                if bits == column:
                    _ = self.cell_styles.pop(key, 0)
                else:
                    self.cell_styles[key] = bits
        self.style_log.append(StyleChange(steps^, len(self.frame.log)))

    def restyle_cells(mut self, cells: List[Tuple[Int, Int]], mask: Int, value: Int):
        """restyle() on each (column, row) of a block: one Undo step for all of them."""
        var before = len(self.style_log)
        for at in cells:
            self.restyle(at[0], at[1], mask, value)
        if len(self.style_log) - before > 1:
            var steps = List[StyleStep]()
            var edits = self.style_log[before].edits
            for k in range(before, len(self.style_log)):
                for st in self.style_log[k].steps:
                    steps.append(st.copy())
            while len(self.style_log) > before:
                _ = self.style_log.pop()
            self.style_log.append(StyleChange(steps^, edits))

    def clear_style(mut self, c: Int, row: Int):
        """Clear formatting: the cell (or with row -1 the column and every cell in it) back to plain, its number
        format too when it's the whole column."""
        if row < 0:
            self.change_format(c, ColumnFormat.auto())
            var number = self.style_log.pop()  # (one Undo step for both)
            self.restyle(c, -1, ALL_PARTS, 0)
            self.style_log[len(self.style_log) - 1].steps.insert(0, number.steps[0].copy())
        else:
            self.restyle(c, row, ALL_PARTS, 0)

    def change_format(mut self, c: Int, f: ColumnFormat):
        """A column's number format, changed by the user (Undo takes it back; set_format doesn't log)."""
        var steps = List[StyleStep]()
        steps.append(StyleStep(c, -2, 0, False, self.format_of(c)))
        self.set_format(c, f)
        self.style_log.append(StyleChange(steps^, len(self.frame.log)))

    def formula(mut self, text: String) raises -> Int:
        """A new (or replaced) formula column; Undo takes it back (one step of the package's log, omxcore 2585dc9)."""
        return self.frame.formula(text)

    def fits(self, bytes: Int, what: String) raises:
        """Refuses work on a streamed file that would hold more than a quarter of memory, saying how much."""
        if bytes > memory_bytes() // 4:
            raise Error(what + " over " + String(self.rows()) + " streamed rows needs about " + String(max(bytes >> 30, 1))
                        + " GB, more than a quarter of this computer's memory")

    def sort_bytes(self) -> Int:
        """What sorting holds while it runs (streamed: the package's keys and row numbers, about 50 bytes a row)."""
        return self.rows() * SORT_BYTES_PER_ROW if self.scan else 0

    def permutation(self, c: Int, descending: Bool = False) raises -> List[Int]:
        """The rows in the order of column c. Streamed, refused when its order wouldn't fit a quarter of memory."""
        if self.scan:
            self.fits(self.sort_bytes(), "sorting")
        return self.frame.permutation(c, descending)

    # ---------- aggregates ----------

    def query(self) raises -> Query:
        """A query over this session's view of the table (its edits included), on the GPU copy when there is one;
        over the file, streamed, when the sheet is."""
        var q = Query(self.frame)
        if self.device:
            q = q^.on_device(self.device.value())
        return q^

    def totals(self, value: Int, key: Optional[Expr] = None, groups: Int = 1, filter: Optional[Expr] = None) raises -> Sums:
        """Sum of column `value` (a formula column too), the rows and the non-empty rows, per group of `key`
        (0 … groups-1; none: one group), over the rows `filter` keeps. The session's edits are included.
        A streamed sheet keeps each column's plain totals (no key, no filter) until the next edit or undo."""
        var plain = not key and not filter and Bool(self.scan)
        var now = (self.frame.edits * 1_000_003 + len(self.frame.log)) * 4 + self.mode  # (moves with every edit and undo, and the device asked for)
        if plain:
            if self.notes[].plain_edits != now:
                self.notes[].plain = Dict[Int, Sums]()
                self.notes[].plain_edits = now
            var kept = self.notes[].plain.get(value)
            if kept:
                return kept.value().copy()
        var q = self.query()
        if filter:
            q = q^.where(filter.value().copy())
        if key:
            q = q^.group_by(key.value().copy(), groups)
        var v = col(self.name(value))
        q = q^.agg(sum(v), count(), count(v))
        var r = q^.compute(self.mode, self.job)
        var sums = Sums(r.values(0), r.counts.copy(), r.values(2), r.milliseconds, r.device == MX_GPU)
        self.notes[].last_gpu = sums.on_gpu
        if plain:
            self.notes[].plain[value] = sums.copy()
        return sums^

    def distinct(self, c: Int, filter: Optional[Expr] = None) raises -> Int:
        """How many different values column c holds over the rows `filter` keeps (empty cells don't count; text: different
        words, a merged spelling once). The engine's count_distinct, on the CPU; streamed too."""
        if self.scan:  # (the engine keeps ~35 bytes per different value while it counts: at most a text column's words, else every row)
            var bound = (self.word_count(c) if c < self.stored() and self.kind(c) == TEXT else self.rows()) * DISTINCT_BYTES
            self.fits(bound, "counting the different values of " + self.name(c))
        var q = self.query()
        if filter:
            q = q^.where(filter.value().copy())
        var r = q^.agg(count_distinct(col(self.name(c)))).compute(MX_CPU, self.job)  # (CPU only in the package)
        return Int(r.values(0)[0])

    def median(self, c: Int, filter: Optional[Expr] = None) raises -> Tuple[Int64, Bool]:
        """The middle value of number column c over the rows `filter` keeps (two middle values: their mean, as
        DuckDB, Excel and pandas), at the column's scale plus one place (the engine's median, exact); False when there
        are no values."""
        if self.scan:  # (an exact median keeps every value: ~27 bytes a row)
            self.fits(self.rows() * MEDIAN_BYTES, "the median of " + self.name(c))
        var q = self.query()
        if filter:
            q = q^.where(filter.value().copy())
        var r = q^.agg(median(col(self.name(c)))).compute(MX_CPU, self.job)  # (CPU only in the package)
        return (Int64(r.values(0)[0]), r.present(0, 0))

    def group_median(self, c: Int, key: Expr, groups: Int, p: Float64 = -1.0, filter: Optional[Expr] = None) raises -> Tuple[List[Int], List[Bool]]:
        """Per group of `key` (0 … groups-1): the median of number column c (p < 0: interpolated, at the column's scale
        plus one place, as `median`) or its value at fraction p (0–1: DuckDB's quantile_disc, a value of the column, at
        its scale); and whether the group has a value. Exact, on the CPU (the engine's holistic aggregates)."""
        if self.scan:
            self.fits(self.rows() * MEDIAN_BYTES, "the median of " + self.name(c))
        var q = self.query()
        if filter:
            q = q^.where(filter.value().copy())
        q = q^.group_by(key.copy(), groups)
        var r = q^.agg(median(col(self.name(c))) if p < 0 else percentile(col(self.name(c)), p)).compute(MX_CPU, self.job)
        var vals = r.values(0)
        var present = List[Bool]()
        for g in range(groups):
            present.append(r.present(0, g))
        return (vals^, present^)

    def format_median(self, c: Int, m: Int64) -> String:
        """A median (one place finer than the column) as the column shows its values: its own places, rounded half away
        from zero; a whole-number column shows .5 when the middle falls between two."""
        var scale = (self.scale(c) if self.kind(c) == DECIMAL else 0) + 1
        var f = self.format_of(c)
        if f.is_auto():
            f = ColumnFormat(NUMBER, -1, True, False, "$")
        if f.decimals < 0:
            f.decimals = scale - 1 if scale > 1 or m % 10 == 0 else 1
        return format_number(m, scale, f)

    def span(self, c: Int) raises -> Tuple[Int64, Int64, Bool]:
        """The smallest and largest value of column c over its non-empty rows (False: there are none)."""
        var v = col(self.name(c))
        var r = self.query().agg(min_of(v), max_of(v)).compute(self.mode, self.job)
        if not r.present(0, 0):
            return (Int64(0), Int64(0), False)
        return (Int64(r.values(0)[0]), Int64(r.values(1)[0]), True)

    def where_is(self, c: Int, code: Int) -> Expr:
        """The filter "column c is the text with this code"."""
        return col(self.name(c)) == Expr(code)

    # ---------- as a DataGrid's source (mojoui.datagrid) ----------

    def grid_rows(self) -> Int:
        return self.rows()

    def grid_alive(self, row: Int) -> Bool:
        return self.alive(row)

    def grid_columns(self) -> Int:
        return self.columns()

    def grid_name(self, c: Int) -> String:
        return self.name(c)

    def grid_numeric(self, c: Int) -> Bool:
        return self.kind(c) == INT or self.kind(c) == DECIMAL

    def grid_editable(self, c: Int) -> Bool:
        return c < self.stored()

    def grid_formula(self, c: Int) -> Bool:
        return c >= self.stored()

    def grid_text(self, c: Int, row: Int) -> String:
        return self.display(c, row)

    def grid_badge(self, c: Int) -> String:
        if c >= self.stored():
            return "ƒx"
        var kind = self.kind(c)
        if kind == TEXT:
            return "Aa"
        if kind == DATE:
            return "date"
        if kind == BOOL:
            return "bool"
        if kind == INT:
            return "#"
        var f = self.format_of(c)
        return (f.symbol if f.symbol != "" else "$") if f.style == CURRENCY else ("%" if f.style == PERCENT else "0.0")

    def grid_edited(self, c: Int, row: Int) -> Bool:
        return self.edited(c, row)

    def grid_style(self, c: Int, row: Int) -> CellStyle:
        return self.style_of(c, row)

    def grid_type_width(self, c: Int) -> Float64:
        var kind = self.kind(c)
        if kind == DATE:
            return 104
        if kind == TEXT and c < self.stored() and self.scan:
            return 118  # (a streamed file's words aren't read just to size a column)
        if kind == TEXT and c < self.stored():
            var longest = 0
            for w in self.frame.base.dictionary(c):
                longest = max(longest, w.byte_length())
            return 190 if longest > 20 else 118  # (long names, such as products, get a wider column)
        if kind == DECIMAL:
            return 96
        if kind == BOOL:
            return 72
        return 72
