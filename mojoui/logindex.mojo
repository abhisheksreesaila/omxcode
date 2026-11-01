# mojoui.logindex: where each recording sits in a long log (goal 47, review round 1). A log of many recordings (a fleet's
# telemetry: 16.8M rows, one episode after another) is sliced by its key many times; scanning it each time on the UI thread
# costs tens of milliseconds, and guessing that it is grouped can miss rows. KeyIndex is built once, off the UI thread, by
# one pass over the key column's dictionary codes: per key, its first row and its row count, and whether every key's rows
# are one run (grouped). Then a slice is exact and O(1).
#
#   var job = start_ui_job(KeyIndexJob(sheet.snapshot(), "episode"))    # one pass, on its own thread; wakes the UI
#   … update(): if job.poll() != JOB_RUNNING: var ix = job.take().result()
#   var span = ix.span_of(sheet.code_of(col, "F00118"))                  # (first row, count); (-1, 0) when absent
#   if ix.grouped: rows first … first + count - 1 are exactly that key's rows
#
# A key column that isn't text (dictionary codes) isn't indexed (`problem` says why); nor is a log whose keys come in more
# than one run each (`grouped` False): the caller says so instead of slicing a guess.

from std.collections import Dict
from omxcore import JobBody, JobCtl
from mojoui.sheet import Sheet, TEXT
from mojoui.clock import now_ns


struct KeyIndex(Copyable, Movable):
    var column: String
    var rows: Int  # the log's rows when it was built (a changed log needs a new index)
    var edits: Int  # the log's edits then (an edited key cell makes the index stale: compare with Sheet.edits())
    var first: Dict[Int, Int]  # key code → its first row
    var count: Dict[Int, Int]  # key code → how many rows carry it
    var grouped: Bool  # every key's rows are one run
    var problem: String
    var milliseconds: Float64

    def __init__(out self, column: String):
        self.column = column
        self.rows = 0
        self.edits = 0
        self.first = Dict[Int, Int]()
        self.count = Dict[Int, Int]()
        self.grouped = False
        self.problem = ""
        self.milliseconds = 0

    def span_of(self, code: Int) -> Tuple[Int, Int]:
        """(first row, row count) of the key with dictionary code `code`; (-1, 0) when no row carries it."""
        var f = self.first.get(code)
        var n = self.count.get(code)
        if not f or not n:
            return (-1, 0)
        return (f.value(), n.value())


def build_key_index(sheet: Sheet, column: String) -> KeyIndex:
    """One pass over `column`'s codes (see the module comment)."""
    var t0 = now_ns()
    var ix = KeyIndex(column)
    var c = sheet.index(column)
    if c < 0:
        ix.problem = "no column " + column
        return ix^
    if sheet.kind(c) != TEXT:
        ix.problem = column + " isn't a text column: a log's key is indexed by its words"
        return ix^
    var n = sheet.rows()
    ix.rows = n
    ix.edits = sheet.edits()
    var grouped = True
    var prev = Int64(-1)
    var start = 0
    for r in range(n + 1):  # (a run's length is added when it ends: one dictionary update per run, not per row)
        var v = sheet.value(c, r) if r < n else Int64(-2)
        if v == prev:
            continue
        if r > 0:
            var k = Int(prev)
            if k in ix.count:
                grouped = False  # (this key came back: a second run)
                ix.count[k] = ix.count.get(k, 0) + (r - start)
            else:
                ix.first[k] = start
                ix.count[k] = r - start
        prev = v
        start = r
    ix.grouped = grouped
    ix.milliseconds = Float64(now_ns() - t0) / 1e6
    return ix^


struct KeyIndexJob(JobBody):
    comptime Out = KeyIndex
    var sheet: Sheet
    var column: String

    def __init__(out self, var sheet: Sheet, column: String):
        self.sheet = sheet^
        self.column = column

    def run(mut self, ctl: JobCtl) raises -> KeyIndex:
        return build_key_index(self.sheet, self.column)
