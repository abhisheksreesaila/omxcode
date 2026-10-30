# mojoui.sheetjobs: a sheet's slow work off the UI thread, on MX frame's background jobs (23edc59, F-175). A start
# function returns a `Job` the app polls once a display frame (a Canvas's on_frame) for its progress and its result, and
# can cancel. Each job works on what it owns (a snapshot of the sheet, a copy of the object): the app goes on drawing,
# scrolling and editing meanwhile. Builds without job threads (the Mac's, unless built with -D MXFRAME_JOB_THREADS) do the
# work inside the start call: the job comes back done and the app reads it on the next frame, as before.

# (Job and its states are also what apps take from here: an app imports mojoui, never the engine, goal 5's rule)
from omxcore import Job, JobCtl, JobBody, JobProgress, start_job, JOB_RUNNING, JOB_DONE, JOB_FAILED, JOB_CANCELLED
from mojoui.sheet import Sheet
from mojoui.sheetpage import SheetObject, compute, shape_of
from mojoui.csvio import CsvImport, read_table, empty_import
from mojoui.sheet import placeholder_sheet
from mojoui.clock import now_ns
from omxcore.job import THREADS
from std.ffi import external_call, c_int
from std.sys import CompilationTarget, is_defined

comptime TRYJOIN = CompilationTarget.is_linux() and not is_defined["MOJOUI_ANDROID"]()  # (glibc's pthread_tryjoin_np)


def stopped[T: Movable & Deinitable](mut job: Job[T]) -> Bool:
    """Whether the job's thread has ended, not only been asked to: a cancelled job reads JOB_CANCELLED at once, while its
    thread runs on to its next check, reading what it holds (D-284). Never blocks on Linux; elsewhere a threaded build
    waits for it (a cancel lands within a block of rows)."""
    comptime if THREADS:
        if job.threaded and not job.joined:
            comptime if TRYJOIN:
                if external_call["pthread_tryjoin_np", c_int](job.tid, Int(0)) != 0:
                    return False  # (EBUSY: still running)
                job.joined = True
            else:
                _ = job.wait()
    return True


struct Charted(Movable):
    """A chart job's answer: the object with its numbers, and whether its queries ran on the GPU."""

    var obj: SheetObject
    var on_gpu: Bool

    def __init__(out self, var obj: SheetObject, on_gpu: Bool):
        self.obj = obj^
        self.on_gpu = on_gpu


struct ChartJob(JobBody):
    comptime Out = Charted
    var sheet: Sheet
    var obj: SheetObject

    def __init__(out self, var sheet: Sheet, var obj: SheetObject):
        self.sheet = sheet^
        self.obj = obj^

    def run(mut self, ctl: JobCtl) raises -> Charted:
        ctl.check()
        self.sheet.job = ctl  # (each query the chart runs counts its rows into the job's progress, and stops when it's cancelled)
        var t0 = now_ns()
        compute(self.obj, self.sheet)
        self.obj.milliseconds = Float64(now_ns() - t0) / 1e6  # (the whole compute, as the person waited for it)
        return Charted(self.obj.copy(), self.sheet.notes[].last_gpu)


def chart_job(sheet: Sheet, obj: SheetObject) -> Job[Charted]:
    """A chart's (or pivot's) numbers off the caller's thread, over the sheet as it is now."""
    return start_job(ChartJob(sheet.snapshot(), obj.copy()))


def take_numbers(mut obj: SheetObject, done: SheetObject):
    """A finished job's numbers into the object on screen (its place, size, picked bar and move stay as they are now)."""
    obj.labels = done.labels.copy()
    obj.cols = done.cols.copy()
    obj.sums = done.sums.copy()
    obj.counts = done.counts.copy()
    obj.present = done.present.copy()
    obj.values = done.values.copy()
    obj.stats = done.stats.copy()
    obj.has_stat = done.has_stat.copy()
    obj.milliseconds = done.milliseconds
    obj.selected = done.selected


def progress_share(p: JobProgress) -> Float64:
    """How far along, 0–1 (0 before the work knows how big it is)."""
    if p.total <= 0:
        return 0.0
    return min(Float64(p.done) / Float64(p.total), 1.0)


struct ChartQueue(Movable):
    """Charts waiting for their numbers: one job runs at a time (the GPU does one query well, not three at once), the
    newest spec per chart waits behind it, and a newer spec for the chart that's running cancels it (only the newest
    lands). A cancelled job's thread runs on until it sees the cancel (between blocks of rows): it waits in `orphans`,
    and nothing new starts until it has stopped, so two jobs never read the GPU at once and `forget(wait=True)` can
    wait for every thread before the table goes. The app polls it once a frame."""

    var job: Optional[Job[Charted]]
    var cref: Int  # the chart the running job is for (-1: none)
    var spec: SheetObject  # what it asked (its words, for the island)
    var started: Int  # ns
    var waiting: List[Tuple[Int, SheetObject]]
    var orphans: List[Job[Charted]]  # cancelled, their threads not yet stopped
    var failed: Int  # the chart whose job last failed (-1: none since the last poll), and why
    var failure: String
    var landed_gpu: Bool  # whether the chart poll() last handed out ran on the GPU

    def __init__(out self):
        self.job = None
        self.cref = -1
        self.spec = SheetObject.chart(0, 0, 0, 0)
        self.started = 0
        self.waiting = List[Tuple[Int, SheetObject]]()
        self.orphans = List[Job[Charted]]()
        self.failed = -1
        self.failure = ""
        self.landed_gpu = False

    def running(self) -> Bool:
        """A job runs for a chart (`cref`, `spec`)."""
        return self.cref >= 0

    def busy(self) -> Bool:
        """Anything left to do: a job running, a chart waiting, or a cancelled thread still stopping (keep polling)."""
        return self.cref >= 0 or len(self.waiting) > 0 or len(self.orphans) > 0

    def ask(mut self, cref: Int, spec: SheetObject, sheet: Sheet):
        """Chart `cref`'s numbers for `spec`: started now if nothing runs, else queued (replacing what that chart had
        queued); a job already running for `cref` is cancelled."""
        var kept = List[Tuple[Int, SheetObject]]()
        for w in self.waiting:
            if w[0] != cref:
                kept.append(w.copy())
        self.waiting = kept^
        if self.cref == cref:
            self.cancel_running()
        if self.cref < 0 and len(self.orphans) == 0:
            self.start(cref, spec, sheet)
        else:
            self.waiting.append((cref, spec.copy()))

    def start(mut self, cref: Int, spec: SheetObject, sheet: Sheet):
        self.job = chart_job(sheet, spec)
        self.cref = cref
        self.spec = spec.copy()
        self.started = now_ns()

    def cancel_running(mut self, wait: Bool = False):
        """The running job cancelled; with `wait`, only once its thread has stopped (it reads the sheet's table and GPU
        copy until then: wait before giving those back)."""
        if self.job:
            var job = self.job.take()
            job.cancel()
            if wait:
                _ = job.wait()
            else:
                self.orphans.append(job^)  # (a dropped handle would detach a thread that may still read the GPU copy)
        self.job = None
        self.cref = -1

    def reap(mut self, wait: Bool = False):
        """Cancelled threads that have stopped let go (with `wait`, every one, once it stops)."""
        var kept = List[Job[Charted]]()
        while len(self.orphans) > 0:
            var job = self.orphans.pop()
            if wait:
                _ = job.wait()
            elif not stopped(job):  # (not poll(): it reads CANCELLED from the cancel on, the thread still running)
                kept.append(job^)
        self.orphans = kept^

    def forget(mut self, wait: Bool = False):
        """Every job and wait dropped (the document replaced: `wait` until every thread, cancelled ones too, has
        stopped)."""
        self.cancel_running(wait)
        self.waiting = List[Tuple[Int, SheetObject]]()
        if wait:
            self.reap(wait=True)

    def remove(mut self, k: Int, sheet: Sheet):
        """Object k left the page: its job is cancelled and its wait dropped; the objects after it move down one
        (their refs too), and their jobs carry on."""
        if self.cref == k:
            self.cancel_running()
        elif self.cref > k:
            self.cref -= 1
        var kept = List[Tuple[Int, SheetObject]]()
        for w in self.waiting:
            if w[0] != k:
                kept.append((w[0] - 1 if w[0] > k else w[0], w[1].copy()))
        self.waiting = kept^
        self.next(sheet)

    def share(self) -> Float64:
        """How far the running job is, 0–1."""
        if not self.job:
            return 0.0
        return progress_share(self.job.value().progress())

    def rows_done(self) -> Int:
        """Rows the running job's queries have read so far."""
        if not self.job:
            return 0
        return self.job.value().progress().done

    def seconds(self) -> Float64:
        """How long the running job has run."""
        return Float64(now_ns() - self.started) / 1e9 if self.cref >= 0 else 0.0

    def poll(mut self, sheet: Sheet) -> Optional[Tuple[Int, SheetObject]]:
        """A chart whose numbers have landed (its cref and the computed object; landed_gpu says where it ran), or None;
        the next waiting job starts. A job that failed leaves its chart in `failed` and the reason in `failure`."""
        self.failed = -1
        if len(self.orphans) > 0:
            self.reap()
        if self.cref < 0 or not self.job:
            self.next(sheet)  # (a chart waiting for a cancelled thread to stop)
            return None
        var state = self.job.value().poll()
        if state == JOB_RUNNING:
            return None
        var cref = self.cref
        var job = self.job.take()
        self.cref = -1
        self.next(sheet)
        try:
            if state == JOB_CANCELLED:
                return None
            var done = job.result()  # (raises the job's error when it failed)
            self.landed_gpu = done.on_gpu
            return (cref, done.obj.copy())
        except e:
            self.failed = cref
            self.failure = String(e)
            return None

    def next(mut self, sheet: Sheet):
        if len(self.waiting) > 0 and self.cref < 0 and len(self.orphans) == 0:
            var w = self.waiting.pop(0)
            self.start(w[0], w[1], sheet)


@fieldwise_init
struct ColumnFigures(Copyable, Movable):
    """A number column's figures for the status bar and the inspector: its total and how many values (empties aren't
    averaged), its median (stored units, one place finer; `has_median`), how many distinct values; what it cost."""

    var col: Int
    var sum: Int
    var present: Int
    var median: Int
    var has_median: Bool
    var distinct: Int
    var milliseconds: Float64
    var on_gpu: Bool


struct ColumnJob(JobBody):
    comptime Out = ColumnFigures
    var sheet: Sheet
    var col: Int
    var stats: Bool  # the median and the distinct count too (the inspector is open)

    def __init__(out self, var sheet: Sheet, col: Int, stats: Bool):
        self.sheet = sheet^
        self.col = col
        self.stats = stats

    def run(mut self, ctl: JobCtl) raises -> ColumnFigures:
        self.sheet.job = ctl
        var t0 = now_ns()
        var r = self.sheet.totals(self.col)
        var med = (0, False)
        var distinct = -1
        if self.stats and not self.sheet.streamed():  # (a streamed file's median and distinct read every row group: they wait for a tile)
            ctl.check()
            var m = self.sheet.median(self.col)
            med = (Int(m[0]), m[1])
            ctl.check()
            distinct = self.sheet.distinct(self.col)
        return ColumnFigures(self.col, r.sums[0], r.present[0], med[0], med[1], distinct, Float64(now_ns() - t0) / 1e6, r.on_gpu)


def column_job(sheet: Sheet, col: Int, stats: Bool) -> Job[ColumnFigures]:
    """Column `col`'s total (and, with `stats`, its median and distinct count) off the caller's thread."""
    return start_job(ColumnJob(sheet.snapshot(), col, stats))


struct Opened(Movable):
    """What an open job made: the import (what the Import step shows), the sheet over its table (its GPU copy made),
    and each column's distribution for the headers' histograms (none for a streamed file: they read every row)."""

    var imp: CsvImport
    var sheet: Sheet
    var shapes: List[List[Float64]]
    var milliseconds: Float64

    def __init__(out self, var imp: CsvImport, var sheet: Sheet, var shapes: List[List[Float64]], milliseconds: Float64):
        self.imp = imp^
        self.sheet = sheet^
        self.shapes = shapes^
        self.milliseconds = milliseconds

    def take_import(mut self) -> CsvImport:
        var out = self.imp^
        self.imp = empty_import()
        return out^

    def take_sheet(mut self) -> Sheet:
        var out = self.sheet^
        self.sheet = placeholder_sheet()
        return out^

    def take_shapes(mut self) -> List[List[Float64]]:
        var out = self.shapes^
        self.shapes = List[List[Float64]]()
        return out^


struct OpenJob(JobBody):
    comptime Out = Opened
    var path: String

    def __init__(out self, var path: String):
        self.path = path^

    def run(mut self, ctl: JobCtl) raises -> Opened:
        var t0 = now_ns()
        var imp = read_table(self.path, ctl)
        ctl.check()
        var sheet = Sheet(imp.scan.value()) if imp.streamed() else Sheet(imp.table)
        imp.let_go()  # (the sheet holds the table now; the import keeps only what it showed)
        var shapes = List[List[Float64]]()
        if not sheet.streamed():
            for c in range(sheet.stored()):
                ctl.check()
                try:
                    shapes.append(shape_of(sheet, c))
                except:
                    shapes.append(List[Float64]())
        return Opened(imp^, sheet^, shapes^, Float64(now_ns() - t0) / 1e6)


def open_job(path: String) -> Job[Opened]:
    """Reads a CSV or Parquet file (as the Import step shows it) into a sheet, off the caller's thread."""
    return start_job(OpenJob(path))


def pace(rows: Int, seconds: Float64) -> String:
    """Rows a second, short: "1.4B rows/s", "820M rows/s" ("" before there's a measure)."""
    if seconds <= 0.05 or rows <= 0:
        return ""
    var r = Float64(rows) / seconds
    if r >= 1e9:
        var tenths = Int(r / 1e8)
        return String(tenths // 10) + ("." + String(tenths % 10) if tenths % 10 != 0 else "") + "B rows/s"
    if r >= 1e6:
        return String(Int(r / 1e6)) + "M rows/s"
    return String(Int(r / 1e3)) + "K rows/s"
