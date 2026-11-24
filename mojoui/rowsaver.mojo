# mojoui.rowsaver (goal 79, after D at 9bda0f2b): a document's row written on a thread of its own. SQLite's commit of a big changed
# document (its pages, the sync, the checkpoint) is 50 ms for 2.6 MB and 100–150 ms for 12 MB on an NVMe disk: on the UI thread
# that is several missed frames 650 ms after each edit, which a benchmark of frames' own work never sees. The same transaction
# (docstore.save_row: the revision check, the follow-ups) on the job thread's own connection.
#
#   var w = RowSaver()
#   w.start(path, save)          # one at a time: busy() until done() gives its outcome
#   var got = w.done()           # None while it runs; done(wait=True) blocks until it has ended (closing, switching documents)
#
# The order is the caller's to keep: nothing else writes that row until done() gave the outcome (the next save builds on its
# revision). Dropped while running, the write still ends on its own thread: whole or not at all.

from omxcore import Job, JobBody, JobCtl, JOB_RUNNING
from mojoui.canvasload import text_hash
from mojoui.docstore import RowSave, SaveResult, save_row, clock_us, FAILED
from mojoui.sqlite import Database
from mojoui.uijobs import start_ui_job
from mojoui import libc

comptime SAVE_WAIT_US = 15_000_000  # (a disk that doesn't answer is said, never a window that hangs; SQLite's own busy wait is 5 s)


struct SavedRow(Copyable, Movable):
    var result: SaveResult
    var hash: Int  # text_hash of the first value written (0: it didn't save)

    def __init__(out self, result: SaveResult, hash: Int):
        self.result = result.copy()
        self.hash = hash


struct RowSaveJob(JobBody):
    comptime Out = SavedRow
    var path: String
    var save: RowSave

    def __init__(out self, path: String, var save: RowSave):
        self.path = path
        self.save = save^

    def run(mut self, ctl: JobCtl) raises -> SavedRow:
        try:
            var db = Database(self.path)  # (a connection belongs to one thread)
            var r = save_row(db, self.save)
            var h = text_hash(self.save.vals[0].text) if r.ok() and len(self.save.vals) > 0 else 0
            return SavedRow(r, h)
        except e:
            return SavedRow(SaveResult(FAILED, self.save.expected, "", String(e)), 0)


struct RowSaver(Movable):
    var job: Optional[Job[SavedRow]]
    var expected: Int

    def __init__(out self):
        self.job = None
        self.expected = 0

    def busy(self) -> Bool:
        return Bool(self.job)

    def start(mut self, path: String, var save: RowSave):
        """Starts the write (the one before it must have been taken with done())."""
        self.expected = save.expected
        self.job = start_ui_job(RowSaveJob(path, save^))

    def done(mut self, wait: Bool = False) -> Optional[SavedRow]:
        """The outcome, once; None when nothing runs, or it still does (and wait is off)."""
        if not self.job:
            return None
        var by = clock_us() + SAVE_WAIT_US
        while self.job.value().poll() == JOB_RUNNING:
            if not wait:
                return None
            if clock_us() > by:
                self.job = None
                return SavedRow(SaveResult(FAILED, self.expected, "", "writing it is taking too long"), 0)
            _ = libc.usleep(100)
        var job = self.job.take()
        try:
            return job.result()
        except e:
            return SavedRow(SaveResult(FAILED, self.expected, "", String(e)), 0)
