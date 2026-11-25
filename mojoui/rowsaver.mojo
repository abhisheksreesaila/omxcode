# mojoui.rowsaver (goal 79, D-8050, D-8052): a document's row written on a thread of its own. SQLite's commit of a big changed
# document (its pages, the sync, the checkpoint) is 50 ms for 2.6 MB and 100–150 ms for 12 MB on an NVMe disk: on the UI thread
# that is several missed frames 650 ms after each edit, which a benchmark of frames' own work never sees. The same transaction
# (docstore.save_row: the revision check, the follow-ups) on the job thread's own connection.
#
#   var w = RowSaver()
#   w.start(path, save, held, file)   # one at a time: busy() until done() gives its outcome
#   var got = w.done()                # None while it runs; done(wait=True) blocks until it has ended (closing)
#   w.give_up()                       # stops waiting for a locked file: done(wait=True) then comes back soon
#
# A file another program has locked: the save waits for it, up to PATIENCE_US; once it has waited a moment the edits are also
# written to `file` (an Unsaved, as SaveOutbox holds one), so a crash while it waits loses nothing; a save that lands takes the
# file away again. The order is the caller's to keep: nothing else writes that row until done() gave the outcome (the next save
# builds on its revision). Dropped while running, the write still ends on its own thread: whole or not at all.

from omxcore import Job, JobBody, JobCtl, JOB_RUNNING
from mojoui.canvasload import text_hash
from mojoui.docstore import RowSave, SaveResult, Unsaved, unsaved_text, save_row, clock_us, FAILED
from mojoui.files import private_write
from mojoui.sqlite import Database
from mojoui.uijobs import start_ui_job
from mojoui import libc
from mojoui.libc import unlink
from std.memory import ArcPointer

comptime PATIENCE_US = 60_000_000  # how long a save waits for a locked file
comptime SAVE_WAIT_US = 3_000_000  # how long done(wait=True) waits before it gives up (closing: never a window that hangs)
comptime TRY_MS = 100  # SQLite's own busy wait, between looks at whether to go on


struct SavedRow(Copyable, Movable):
    var result: SaveResult
    var hash: Int  # text_hash of the first value written (0: it didn't save)
    var held: Bool  # its edits are on disk in the held file (it didn't save)

    def __init__(out self, result: SaveResult, hash: Int, held: Bool = False):
        self.result = result.copy()
        self.hash = hash
        self.held = held


def is_locked(message: String) -> Bool:
    """SQLite's BUSY or LOCKED: another program is writing the file."""
    return message.find("database is locked") >= 0 or message.find("database table is locked") >= 0


struct RowSaveJob(JobBody):
    comptime Out = SavedRow
    var path: String
    var save: RowSave
    var held: Unsaved
    var file: String  # where held goes while the file is locked ("": nowhere)
    var stop: ArcPointer[Int]  # 1: stop waiting (ours, not the job's cancel: a cancelled job's outcome is lost, and this one's write may have landed)

    def __init__(out self, path: String, var save: RowSave, var held: Unsaved, file: String, stop: ArcPointer[Int]):
        self.stop = stop.copy()
        self.path = path
        self.save = save^
        self.held = held^
        self.file = file

    def run(mut self, ctl: JobCtl) raises -> SavedRow:
        var by = clock_us() + PATIENCE_US
        var spilt = False
        while True:
            var r: SaveResult
            try:
                var db = Database(self.path, busy_ms=TRY_MS)  # (a connection belongs to one thread)
                r = save_row(db, self.save)
            except e:
                r = SaveResult(FAILED, self.save.expected, "", String(e))
            if r.ok():
                if spilt:
                    _ = unlink(self.file)
                return SavedRow(r, text_hash(self.save.vals[0].text) if len(self.save.vals) > 0 else 0)
            if not is_locked(r.message):
                return SavedRow(r, 0, spilt)
            if not spilt and self.file != "" and self.stop[] == 0:  # (told to stop: whoever told holds the edits itself)
                self.held.why = r.message
                spilt = private_write(self.file, unsaved_text(self.held), durable=True)
            if clock_us() > by or self.stop[] != 0:
                return SavedRow(r, 0, spilt)


struct RowSaver(Movable):
    var job: Optional[Job[SavedRow]]
    var expected: Int
    var stop: ArcPointer[Int]

    def __init__(out self):
        self.job = None
        self.expected = 0
        self.stop = ArcPointer(0)

    def busy(self) -> Bool:
        return Bool(self.job)

    def start(mut self, path: String, var save: RowSave, var held: Unsaved = Unsaved(-1, "", 0, "", "", "", False), file: String = ""):
        """Starts the write (the one before it must have been taken with done())."""
        self.expected = save.expected
        self.stop = ArcPointer(0)
        self.job = start_ui_job(RowSaveJob(path, save^, held^, file, self.stop))

    def give_up(mut self):
        """Stops waiting for a locked file (a write under way still ends)."""
        self.stop[] = 1

    def done(mut self, wait: Bool = False) -> Optional[SavedRow]:
        """The outcome, once; None when nothing runs, or it still does (and wait is off). wait: after SAVE_WAIT_US it is told
        to give up, so a locked file never holds a window that closes; only a disk that doesn't answer can take longer."""
        if not self.job:
            return None
        var by = clock_us() + SAVE_WAIT_US
        var told = False
        while self.job.value().poll() == JOB_RUNNING:
            if not wait:
                return None
            if clock_us() > by:
                if told:
                    self.job = None
                    return SavedRow(SaveResult(FAILED, self.expected, "", "writing it is taking too long"), 0)
                told = True
                self.give_up()
                by = clock_us() + SAVE_WAIT_US
            _ = libc.usleep(100)
        var job = self.job.take()
        try:
            return job.result()
        except e:
            return SavedRow(SaveResult(FAILED, self.expected, "", String(e)), 0)
