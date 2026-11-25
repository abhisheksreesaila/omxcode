# mojoui.docstore: documents kept as rows with a revision, saved the way a careful web app saves them (goal 79, D-7927).
#
# Three pieces, none tied to one app:
#   SaveTimer   a debounce: an edit asks for a save `delay_ms` later; more edits push it back; due() says when to write.
#               An app lists Every(timer.tick_ms(), SAVE_TICK) while pending() and calls its save when due(now).
#   RowSave     one row's new values plus the statements that must land in the same transaction (a change log, a search
#               index), and the revision the editor last saw.
#   save_row    writes it as `UPDATE t SET … , rev = expected + 1 WHERE key = ? AND rev = expected`: when another writer
#               moved the row on, nothing is written and the result says CONFLICT (the caller keeps its edits and shows it).
#
#   var s = RowSave("notes", "id", 7, "revision", 12)
#   s.set("content", text_arg(json)); s.stamp("updated_at"); s.read_back("updated_at")
#   s.then("DELETE FROM note_search WHERE note_id = ?", [int_arg(7)])
#   var r = save_row(db, s)        # r.status: SAVED | CONFLICT | FAILED, r.revision = 13, r.value = the stamp read back

from mojoui.sqlite import Database, Statement
from mojoui.json import Json, json_string
from mojoui.files import private_write, FileLock, file_name, file_exists, sync_file, sync_dir, bytes_sum
from mojoui.libc import unlink, rename, usleep, getpid, kill
from mojoui.uijobs import start_ui_job
from omxcore import Job, JobBody, JobCtl, JOB_RUNNING
from mojoui.shared import new_key
from std.memory import ArcPointer
from std.os import listdir, getenv
from std.time import perf_counter_ns

comptime SAVED = 0
comptime CONFLICT = 1
comptime FAILED = 2


def clock_us() -> Int:
    """A monotonic clock in microseconds (what SaveTimer counts in)."""
    return Int(perf_counter_ns() // 1000)


struct SaveTimer(Copyable, Movable):
    """A save debounce. touch() after each edit; due(now) once `delay_ms` passed since the last one; done() after the
    write. A flush (closing, switching documents) writes at once whatever is pending."""

    var delay_ms: Int
    var due_us: Int  # -1: nothing pending

    def __init__(out self, delay_ms: Int = 650):
        self.delay_ms = delay_ms
        self.due_us = -1

    def touch(mut self, now_us: Int):
        self.due_us = now_us + self.delay_ms * 1000

    def pending(self) -> Bool:
        return self.due_us >= 0

    def due(self, now_us: Int) -> Bool:
        return self.due_us >= 0 and now_us >= self.due_us

    def done(mut self):
        self.due_us = -1

    def tick_ms(self) -> Int:
        """How often an app's timer should ask due(): a tenth of the delay, at least 10 ms."""
        return max(10, self.delay_ms // 10)


@fieldwise_init
struct SqlArg(Copyable, Movable):
    """A value to bind: text or a whole number."""

    var text: String
    var number: Int
    var is_number: Bool


def text_arg(s: String) -> SqlArg:
    return SqlArg(s, 0, False)


def int_arg(n: Int) -> SqlArg:
    return SqlArg("", n, True)


def _bind(mut st: Statement, at: Int, a: SqlArg) raises:
    if a.is_number:
        st.bind(at, a.number)
    else:
        st.bind(at, a.text)


@fieldwise_init
struct Followup(Copyable, Movable):
    var sql: String
    var args: List[SqlArg]


struct RowSave(Copyable, Movable):
    """One row's change: the columns to set, the columns stamped with CURRENT_TIMESTAMP, the statements to run after it
    in the same transaction, and one column to read back (e.g. the stamp, so the caller's copy matches the file)."""

    var table: String
    var key: String
    var id: Int
    var rev: String
    var expected: Int
    var cols: List[String]
    var vals: List[SqlArg]
    var stamps: List[String]
    var after: List[Followup]
    var back: String

    def __init__(out self, table: String, key: String, id: Int, rev: String, expected: Int):
        self.table = table
        self.key = key
        self.id = id
        self.rev = rev
        self.expected = expected
        self.cols = List[String]()
        self.vals = List[SqlArg]()
        self.stamps = List[String]()
        self.after = List[Followup]()
        self.back = ""

    def set(mut self, col: String, v: SqlArg):
        self.cols.append(col)
        self.vals.append(v.copy())

    def stamp(mut self, col: String):
        self.stamps.append(col)

    def then(mut self, sql: String, args: List[SqlArg]):
        self.after.append(Followup(sql, args.copy()))

    def read_back(mut self, col: String):
        self.back = col

    def sql(self) -> String:
        var s = "UPDATE " + self.table + " SET "
        for i in range(len(self.cols)):
            s += self.cols[i] + " = ?, "
        for c in self.stamps:
            s += c + " = CURRENT_TIMESTAMP, "
        s += self.rev + " = ? WHERE " + self.key + " = ? AND " + self.rev + " = ?"
        return s


@fieldwise_init
struct SaveResult(Copyable, Movable):
    var status: Int  # SAVED | CONFLICT | FAILED
    var revision: Int  # the row's revision after the save (the expected one on a conflict or failure)
    var value: String  # the read-back column ("" when none)
    var message: String  # why it didn't save

    def ok(self) -> Bool:
        return self.status == SAVED


def _undo(mut db: Database):
    try:
        db.rollback()
    except:
        pass


def save_row(mut db: Database, s: RowSave) -> SaveResult:
    """Writes the change only if the row still has the revision the editor saw, with its follow-ups, in one transaction.
    A moved-on row (another app saved first) writes nothing: CONFLICT, "Resource revision does not match"."""
    try:
        db.begin()
    except e:
        return SaveResult(FAILED, s.expected, "", String(e))
    try:
        _stage("begun")
        var up = db.prepare(s.sql())
        var at = 1
        for ref v in s.vals:
            _bind(up, at, v)
            at += 1
        up.bind(at, s.expected + 1)
        up.bind(at + 1, s.id)
        up.bind(at + 2, s.expected)
        _ = up.step()
        _stage("written")
        if db.changes() == 0:
            _undo(db)
            return SaveResult(CONFLICT, s.expected, "", "Resource revision does not match")
        for ref f in s.after:
            var st = db.prepare(f.sql)
            for i in range(len(f.args)):
                _bind(st, i + 1, f.args[i])
            _ = st.step()
        var value = String("")
        if s.back != "":
            var q = db.prepare("SELECT " + s.back + " FROM " + s.table + " WHERE " + s.key + " = ?")
            q.bind(1, s.id)
            if q.step():
                value = q.text(0)
        _stage("before commit")
        db.commit()
        _stage("committed")
        return SaveResult(SAVED, s.expected + 1, value, "")
    except e:
        _undo(db)
        return SaveResult(FAILED, s.expected, "", String(e))


comptime NEW_ROW = -9_000_000_001  # (as a follow-up's int_arg) the id of the row just inserted


struct RowNew(Copyable, Movable):
    """A new row: its columns and the statements in the same transaction; int_arg(NEW_ROW) in one of them is its id."""

    var table: String
    var cols: List[String]
    var vals: List[SqlArg]
    var after: List[Followup]

    def __init__(out self, table: String):
        self.table = table
        self.cols = List[String]()
        self.vals = List[SqlArg]()
        self.after = List[Followup]()

    def set(mut self, col: String, v: SqlArg):
        self.cols.append(col)
        self.vals.append(v.copy())

    def then(mut self, sql: String, args: List[SqlArg]):
        self.after.append(Followup(sql, args.copy()))


@fieldwise_init
struct NewResult(Copyable, Movable):
    var id: Int  # 0: it wasn't made
    var message: String


def new_row(mut db: Database, s: RowNew) -> NewResult:
    """Inserts the row and runs its follow-ups, all or nothing."""
    try:
        db.begin()
    except e:
        return NewResult(0, String(e))
    try:
        var sql = "INSERT INTO " + s.table + " ("
        var marks = String("")
        for i in range(len(s.cols)):
            sql += (", " if i > 0 else "") + s.cols[i]
            marks += ", ?" if i > 0 else "?"
        var st = db.prepare(sql + ") VALUES (" + marks + ")")
        for i in range(len(s.vals)):
            _bind(st, i + 1, s.vals[i])
        _ = st.step()
        var id = db.last_id()
        for ref f in s.after:
            var q = db.prepare(f.sql)
            for i in range(len(f.args)):
                _bind(q, i + 1, int_arg(id) if f.args[i].is_number and f.args[i].number == NEW_ROW else f.args[i].copy())
            _ = q.step()
        db.commit()
        return NewResult(id, "")
    except e:
        _undo(db)
        return NewResult(0, String(e))


def drop_row(mut db: Database, table: String, key: String, id: Int, before: List[Followup]) -> String:
    """Deletes a row after the statements that go with it (its index, its change log: they run first, while it is there),
    all or nothing. "" or why not; a row already gone is "gone"."""
    try:
        db.begin()
    except e:
        return String(e)
    try:
        for ref f in before:
            var q = db.prepare(f.sql)
            for i in range(len(f.args)):
                _bind(q, i + 1, f.args[i])
            _ = q.step()
        var st = db.prepare("DELETE FROM " + table + " WHERE " + key + " = ?")
        st.bind(1, id)
        _ = st.step()
        if db.changes() == 0:
            _undo(db)
            return "gone"
        db.commit()
        return ""
    except e:
        _undo(db)
        return String(e)


def row_revision(mut db: Database, table: String, key: String, id: Int, rev: String) -> Int:
    """The row's revision now (-1: no such row)."""
    try:
        var q = db.prepare("SELECT " + rev + " FROM " + table + " WHERE " + key + " = ?")
        q.bind(1, id)
        if q.step():
            return q.int(0)
    except:
        pass
    return -1


comptime DOC_NONE = 0  # nothing open
comptime DOC_LOADING = 1  # still being read: not to be saved
comptime DOC_READY = 2  # read whole: may be edited and saved
comptime DOC_FAILED = 3  # couldn't be read: shown as such, never edited, never saved, never kept


comptime Plain = def(String) thin -> String


def as_it_is(text: String) -> String:
    return text


struct DocBase(Copyable, Movable):
    """(review 6, M1) What a save builds on: the row as this window last knew it, its revision and its text. It belongs to the
    open document and goes with it: read with it, replaced by every save that lands, kept with a kept parse, carried by a save
    on its way and by held edits. A row that moved on with this very text (`plain`: the text without what doesn't count) is not
    a conflict; one with any other text is, also one that went back to what it once was. `sum` stands for the text when only
    that is left (a held edit of an earlier run); 0: not known."""
    var revision: Int
    var text: String
    var sum: Int
    var plain: Plain

    def __init__(out self, revision: Int = -1, text: String = "", sum: Int = 0, plain: Plain = as_it_is):
        self.revision = revision
        self.text = text
        self.sum = sum
        self.plain = plain

    def known(self) -> Bool:
        return self.text != "" or self.sum != 0

    def same(self, text: String) -> Bool:
        """Whether a row holding `text` is the row this is."""
        if self.text != "":
            return text == self.text or self.plain(text) == self.plain(self.text)
        return self.sum != 0 and _sum(self.plain(text)) == self.sum

    def kept_sum(self) -> Int:
        """The sum a held edit's file keeps of it (a big text: milliseconds; asked where the file is written)."""
        return _sum(self.plain(self.text)) if self.text != "" else self.sum

    def moved(self, revision: Int, text: String) -> DocBase:
        """The row after a save of `text` landed."""
        return DocBase(revision, text, 0, self.plain)


def _sum(text: String) -> Int:
    var n = bytes_sum(Int(text.unsafe_ptr()), text.byte_length())
    _ = text.byte_length()
    return max(n, 1)


struct OpenDoc(Copyable, Movable):
    """(review 3, MUST 3) Which document is open and whether it was read: the one gate between a screen and its row. An app
    begins an open, says ready or failed, and asks may_save before every write and may_keep before keeping a parse: a
    document that couldn't be read shows its problem and a Retry, and nothing of the empty screen ever reaches its row.

        doc.begin(id); … doc.ready(id, revision) or doc.failed(id, why)
        if not doc.may_edit(): … show doc.problem and a Retry button …
        if doc.may_save(id, revision): save_row(…); doc.saved(new_revision)"""

    var id: Int
    var state: Int
    var revision: Int  # the row's revision the screen was read at (or last saved)
    var base: DocBase  # the row as it was then
    var problem: String

    def __init__(out self):
        self.id = -1
        self.state = DOC_NONE
        self.revision = -1
        self.base = DocBase()
        self.problem = ""

    def begin(mut self, id: Int):
        self.id = id
        self.state = DOC_LOADING
        self.revision = -1
        self.base = DocBase()
        self.problem = ""

    def ready(mut self, id: Int, revision: Int, var base: DocBase = DocBase()):
        """Read whole, at this revision (an answer for another document, or after a failure, changes nothing); base: the row
        its saves build on."""
        if id == self.id and self.state == DOC_LOADING:
            self.state = DOC_READY
            self.revision = revision
            self.base = base^
            self.base.revision = revision

    def failed(mut self, id: Int, why: String):
        if id == self.id:
            self.state = DOC_FAILED
            self.problem = why if why != "" else String("It couldn't be read.")

    def saved(mut self, revision: Int):
        """The row is at this revision, its text the one it was (renamed, filed, written again as it was)."""
        if self.state == DOC_READY:
            self.revision = revision
            self.base.revision = revision

    def landed(mut self, revision: Int, text: String):
        """A save of it landed: the row holds `text`."""
        if self.state == DOC_READY:
            self.revision = revision
            self.base = self.base.moved(revision, text)

    def loading(self) -> Bool:
        return self.state == DOC_LOADING

    def is_failed(self) -> Bool:
        return self.state == DOC_FAILED

    def may_edit(self) -> Bool:
        return self.state == DOC_READY

    def may_save(self, id: Int, revision: Int) -> Bool:
        """The screen is this row's document, read whole, at the revision the save will build on."""
        return self.state == DOC_READY and id == self.id and revision == self.revision

    def may_keep(self, id: Int) -> Bool:
        return self.state == DOC_READY and id == self.id


struct Unsaved(Copyable, Movable):
    """Edits that couldn't be written: the document as it was to be saved, at the revision it was read at, and why."""

    var id: Int
    var kind: String
    var revision: Int
    var content: String
    var body: String
    var why: String
    var conflict: Bool
    var base: DocBase  # the row it builds on (its file keeps the sum)
    var of: String  # whose edits: the document's own name that never changes ("": not known), so that another one with its number isn't taken for it

    def __init__(out self, id: Int, kind: String, revision: Int, content: String, body: String, why: String, conflict: Bool, var base: DocBase = DocBase(), of: String = ""):
        self.base = base^
        self.of = of
        self.id = id
        self.kind = kind
        self.revision = revision
        self.content = content
        self.body = body
        self.why = why
        self.conflict = conflict


def unsaved_text(u: Unsaved, over: List[String] = List[String]()) -> String:
    """A held save as its file has it (SaveOutbox, RowSaver while a locked file keeps it waiting). over: the names of the files
    it stands for."""
    var names = String("")
    for n in over:
        names += ("," if names != "" else "") + json_string(n)
    var t = ('{"id":' + String(u.id) + ',"kind":' + json_string(u.kind) + ',"revision":' + String(u.revision) + ',"conflict":' + ("true" if u.conflict else "false")
             + ',"why":' + json_string(u.why) + (',"of":' + json_string(u.of) if u.of != "" else String("")) + (',"base":' + String(u.base.kept_sum()) if u.base.known() else String("")) + ',"body":' + json_string(u.body) + ',"over":[' + names + '],"content":' + json_string(u.content))
    return t + SUM_MARK + String(bytes_sum(Int(t.unsafe_ptr()), t.byte_length())) + "}"


comptime SUM_MARK = ',"sum":'


def unsaved_whole(text: String) -> Bool:
    """Whether a held save's file is all there: its sum, last in it, is of what stands before."""
    var at = text.rfind(SUM_MARK)
    if at < 0:
        return False
    var n = bytes_sum(Int(text.unsafe_ptr()), at)
    _ = text.byte_length()
    return String(text[byte = at + SUM_MARK.byte_length() :]) == String(n) + "}"


def _stage(name: String):
    """(tests: MOJOUI_SAVE_STAGE) The process stops here for a while, for something to be done to it at this very moment."""
    if getenv("MOJOUI_SAVE_STAGE") == name:
        print("STAGE: " + name, flush=True)
        _ = usleep(20_000_000)


struct HeldFile(Copyable, Movable):
    """A file of an outbox: whose document, its number, where."""
    var id: Int
    var seq: Int
    var path: String
    var job: Bool  # a save's thread may still write it: it stays listed until that save is over

    def __init__(out self, id: Int, seq: Int, path: String, job: Bool = False):
        self.id = id
        self.seq = seq
        self.path = path
        self.job = job


struct HeldVersion(Copyable, Movable):
    """A held version of a document found at a start: what it says, and every file of the owner that held it, for that
    document (its earlier versions)."""
    var held: Unsaved
    var owner: String
    var seq: Int
    var path: String  # its file (files: the earlier ones' too)
    var files: List[String]
    var olds: List[String]  # what it stands for of other windows

    def __init__(out self, var held: Unsaved, owner: String, seq: Int, path: String):
        self.held = held^
        self.owner = owner
        self.seq = seq
        self.path = path
        self.files = List[String]()
        self.olds = List[String]()


struct Settle(Copyable, Movable):
    """A held file to settle (HeldDisk.settle) and what may go once it is."""
    var path: String
    var olds: List[String]

    def __init__(out self, path: String, var olds: List[String]):
        self.path = path
        self.olds = olds^


def held_space(dir: String, path: String, identity: String, identity_of: def(String) thin -> String) -> Tuple[String, List[String]]:
    """SaveOutbox's `space` of the store at `path`, which says it is `identity` ("": it doesn't say), and the names it had at
    places it has left (`also`): so a file put in its place isn't given its edits, and it finds them again after it was moved.
    A note of each is kept in `dir` (space-….json). identity_of: what the store at a path says it is now ("" when there is none)."""
    var head = path + "|" + identity if identity != "" else path
    var space = String(_sum(head))
    var also = List[String]()
    if dir == "" or identity == "":
        return (space, also^)
    var own = dir + "/space-" + space + ".json"
    if not file_exists(own):
        _ = private_write(own, '{"path":' + json_string(path) + ',"identity":' + json_string(identity) + "}", durable=True)
    try:
        for name in listdir(dir):
            var n = String(name)
            if not n.startswith("space-") or not n.endswith(".json") or n == "space-" + space + ".json":
                continue
            var t: String
            with open(dir + "/" + n, "r") as f:
                t = f.read()
            var j = Json.parse(t)
            var was = j.text(j.get(0, "path"))
            if j.text(j.get(0, "identity")) == identity and was != path and identity_of(was) != identity:  # (it isn't there any more: this is it)
                also.append(String(n[byte = 6 : n.byte_length() - 5]))
    except e:
        print("held_space: " + String(e), flush=True)
    return (space, also^)


struct DiskOp(Copyable, Movable):
    """One thing done to the disk (tests: HeldDisk.ops)."""
    var kind: String  # write | file (its bytes on the disk) | rename | dir (the names on the disk) | unlink
    var a: String
    var b: String

    def __init__(out self, kind: String, a: String, b: String = ""):
        self.kind = kind
        self.a = a
        self.b = b


struct HeldDisk(Copyable, Movable):
    """What SaveOutbox does to its folder, step by step. A file is written as "<name>.new.json" (whole, or not there, however
    the process ends), then settled: its bytes on the disk, renamed to "<name>.json", the folder on the disk, and only then
    are the files it stands for removed. So whenever the power goes, a "<name>.json" is whole, and what it stands for is there
    as long as it isn't; a torn "<name>.new.json" is known by its sum."""
    var fault: Int  # (tests) the steps left before this window "dies": from then on nothing of it happens (-1: none)
    var inline: Bool  # (tests) no thread: what waits is settled in sync(True) and by settle_next; a model's disk: no real fsync
    var tracing: Bool  # (tests) what is done is noted in ops
    var ops: List[DiskOp]

    def __init__(out self):
        self.fault = -1
        self.inline = False
        self.tracing = False
        self.ops = List[DiskOp]()

    def step(mut self) -> Bool:
        """One more step; False: this window is dead."""
        if self.fault == 0:
            return False
        if self.fault > 0:
            self.fault -= 1
        return True

    def note(mut self, kind: String, a: String, b: String = ""):
        if self.tracing:
            self.ops.append(DiskOp(kind, a, b))

    def write(mut self, path: String, text: String) -> Bool:
        """The file `path` as its first name has it."""
        if not self.step() or not private_write(new_name(path), text):
            return False
        self.note("write", new_name(path), text)
        return True

    def remove(mut self, path: String):
        """The file, by either name: the first one first, so that a settle on its thread can't bring it back."""
        for name in [new_name(path), path]:
            if file_exists(name) and self.step() and unlink(name) == 0:
                self.note("unlink", name)

    def settle(mut self, s: Settle) -> Bool:
        """The file `s.path` on the disk itself under its own name, whole; then what it stands for goes."""
        var new = new_name(s.path)
        if file_exists(new):
            if not self.step() or (not self.inline and not sync_file(new)):
                return False
            self.note("file", new)
            if not self.step() or rename(new, s.path) != 0:  # (removed meanwhile)
                return False
            self.note("rename", new, s.path)
        elif not file_exists(s.path):  # (removed meanwhile)
            return False
        if not self.step() or (not self.inline and not sync_dir(s.path)):
            return False
        self.note("dir", s.path)
        for o in s.olds:
            self.remove(o)
        return True


def new_name(path: String) -> String:
    """A held file's first name, until it is settled."""
    return String(path[byte = 0 : path.byte_length() - 5]) + ".new.json"


def settled_name(path: String) -> String:
    """A held file's own name, of either."""
    return String(path[byte = 0 : path.byte_length() - 9]) + ".json" if path.endswith(".new.json") else path


struct SaveOutbox(Movable):
    """(review 3, SHOULD 7; review 4, MUST 1; review 5, MUST 2) Saves that failed, met a conflict or wait for a locked file, held
    until they land or the person drops them: in memory, and as files (0600, in a 0700 folder of the app's), so a switch, a
    quit, a crash or the power going loses nothing. `space` names the store the ids belong to; `also`, the names it had (a file
    that was moved), whose held edits load() takes too. Windows and processes share the folder.

    Its invariants (tests/test_outboxmodel.mojo holds random windows, saves, kills at every step and take-overs to them):
     1. A file is written once, under a name nobody used (document, number, owner), in one step, and never written to again.
        It is renamed once, when its bytes are on the disk itself (HeldDisk: "….new.json", then "….json"). A later version is
        a new file.
     2. A file goes only when what it holds has landed, or a later version by the same window, or one that took it over, is
        already on the disk itself, its name too, or the person dropped it. That later file names the ones it stands for
        ("over"), so that they don't come back when both are there.
     3. Only the window that owns a file, by its own name or by having taken it over, removes it. A window owns a name while it
        holds that name's lock file; the kernel lets go when it ends, however it ends. To take over is to hold the lock:
        nothing on disk changes, so a kill in the middle of a take-over leaves everything as it was for the next start.
        Where files can't be locked, an owner is gone when its process is.
     4. Of one window and one document the highest number is the newest, and holds all its earlier ones. Of two windows both
        are kept: the one at the higher revision (the later, of equals) is `items`', each other one is in `extras`, for the
        app to make a document of its own from; then extra_done().
     5. A file that can't be read, or is torn (its sum), is left alone and hides no other.
     6. (tests/test_powercut.mojo) Whenever the power goes, what was settled is there and whole, or a later version is.

    What isn't promised: words typed since the last save was asked for (the app's own delay), and, if the power goes, since
    the last file was settled (a thread's work, some milliseconds behind)."""

    var dir: String
    var space: String
    var also: List[String]
    var owner: String
    var lock: FileLock
    var claimed: String  # the folder `owner` is claimed in
    var seq: Int  # the last number given
    var items: List[Unsaved]
    var files: List[HeldFile]  # the files that stand for items, and those a save's own thread may write
    var extras: List[Unsaved]
    var extra_files: List[List[String]]
    var taken: List[ArcPointer[FileLock]]  # the gone owners' locks: theirs are ours while this lives
    var syncs: List[Settle]  # files to settle
    var syncer: Optional[Job[Int]]
    var settling: List[Settle]  # those the thread has
    var disk: HeldDisk

    def __init__(out self, dir: String = "", space: String = ""):
        self.dir = dir
        self.space = space
        self.also = List[String]()
        self.owner = ""
        self.lock = FileLock()
        self.claimed = ""
        self.seq = 0
        self.items = List[Unsaved]()
        self.files = List[HeldFile]()
        self.extras = List[Unsaved]()
        self.extra_files = List[List[String]]()
        self.taken = List[ArcPointer[FileLock]]()
        self.syncs = List[Settle]()
        self.syncer = None
        self.settling = List[Settle]()
        self.disk = HeldDisk()

    def __deinit__(deinit self):
        if self.disk.fault != 0:
            self.sync(True)  # (its thread is done before its lock is let go)
            if len(self.items) == 0 and len(self.files) == 0 and len(self.extras) == 0 and self.lock.held():
                _ = unlink(self.lock.path)  # (nothing of it left: its name neither)

    # ------------------------------------------------ the disk

    def claim(mut self):
        """This outbox's own name in its folder, and the lock that says it lives. Where files can't be locked the name says
        the process instead ("n<pid>-…")."""
        if self.dir == "" or self.claimed == self.dir or not self.disk.step():
            return
        self.claimed = self.dir
        for _ in range(8):  # (another start may look at a lock file in the instant between its making and its taking)
            self.owner = "p" + String(getpid()) + "-" + new_key("k")
            if self.lock.take(self.lock_path(self.owner)):
                return
        _ = unlink(self.lock_path(self.owner))
        self.owner = "n" + String(getpid()) + "-" + new_key("k")

    def lock_path(self, owner: String, space: String = "") -> String:
        return self.dir + "/unsaved-" + (space if space != "" else self.space) + "." + owner + ".lock"

    def _new_file(mut self, id: Int) -> HeldFile:
        """The next file of document `id` (its path "" when there is no folder)."""
        self.claim()
        self.seq += 1
        return HeldFile(id, self.seq, (self.dir + "/unsaved-" + self.space + "-" + String(id) + "-" + String(self.seq) + "." + self.owner + ".json") if self.dir != "" else String(""))

    def _store(mut self, u: Unsaved, jobs: Bool) -> Int:
        """A file with `u`, in place of the ones it had (jobs: those of a save's thread too, which is over); its number (0: it
        couldn't be written, the ones it had stay)."""
        if self.dir == "":
            return 0
        var f = self._new_file(u.id)
        var over = List[String]()
        var olds = List[String]()
        for k in range(len(self.files)):
            if self.files[k].id == u.id:
                over.append(file_name(self.files[k].path))
                if jobs or not self.files[k].job:
                    olds.append(self.files[k].path)
        if not self.disk.write(f.path, unsaved_text(u, over)):
            return 0
        var seq = f.seq
        self._settle(f.path, olds^)
        self.files.append(f^)
        return seq

    def _clear(mut self, id: Int, upto: Int):
        """Document `id`'s files go, now (upto > 0: only its own up to that number, and the ones taken over): the earliest first,
        so that none is ever left without the one that stands for it."""
        var k = 0
        while k < len(self.files):
            if self.files[k].id == id and (upto == 0 or self.files[k].seq <= upto):
                self.disk.remove(self.files.pop(k).path)
            else:
                k += 1

    def _settle(mut self, path: String, var olds: List[String]):
        """`path` to be settled, and then `olds` to go (one of them still waiting for its own settle needs none)."""
        for k in range(len(self.syncs) - 1, -1, -1):
            if self.syncs[k].path in olds:
                var s = self.syncs.pop(k)
                for o in s.olds:
                    if o not in olds:
                        olds.append(o)
        self.syncs.append(Settle(path, olds^))
        if not self.disk.inline:
            self.sync(False)

    def settle_next(mut self):
        """(tests, inline) The next file that waits is settled."""
        if len(self.syncs) > 0:
            var s = self.syncs.pop(0)
            _ = self.disk.settle(s)
            self._settled(s)

    def _settled(mut self, s: Settle):
        """What a settle removed isn't listed any more."""
        for o in s.olds:
            if file_exists(o) or file_exists(new_name(o)):
                continue
            for k in range(len(self.files) - 1, -1, -1):
                if self.files[k].path == o:
                    _ = self.files.pop(k)
            for e in range(len(self.extra_files)):
                for k in range(len(self.extra_files[e]) - 1, -1, -1):
                    if self.extra_files[e][k] == o:
                        _ = self.extra_files[e].pop(k)

    def sync(mut self, wait: Bool):
        """The files written are settled, on a thread (wait: before this returns; a window closing)."""
        while True:
            if self.disk.inline:
                while wait and len(self.syncs) > 0:
                    self.settle_next()
                return
            if self.syncer:
                if self.syncer.value().poll() == JOB_RUNNING:
                    if not wait:
                        return
                    _ = usleep(100)
                    continue
                var done = self.syncer.take()
                try:
                    _ = done.result()
                except:
                    pass
                for s in self.settling.copy():
                    self._settled(s)
                self.settling.clear()
            if len(self.syncs) == 0:
                return
            self.settling.clear()
            swap(self.settling, self.syncs)
            self.syncer = start_ui_job(SettleJob(self.settling.copy()))

    # ------------------------------------------------ what is held

    def find(self, id: Int) -> Int:
        for i in range(len(self.items)):
            if self.items[i].id == id:
                return i
        return -1

    def put(mut self, var u: Unsaved) -> Bool:
        """Held; True when it is on disk too."""
        var ok = self._store(u, True) > 0
        var i = self.find(u.id)
        if i >= 0:
            self.items[i] = u^
        else:
            self.items.append(u^)
        return ok

    def spill(mut self, u: Unsaved) -> Int:
        """A save that waits its turn behind one a locked file holds up: on disk meanwhile; its number (0: it isn't)."""
        return self._store(u, False)

    def job_file(mut self, id: Int) -> HeldFile:
        """A file a save's own thread may write its edits to while it waits for a locked file (RowSaver): nobody else writes
        there. It goes with the document's others, or when the save lands (landed)."""
        var f = self._new_file(id)
        f.job = True
        if f.path != "":
            self.files.append(f.copy())
        return f^

    def landed(mut self, id: Int, upto: Int):
        """A save of it landed, a newer one is on its way: what stood for versions up to number `upto` goes."""
        var i = self.find(id)
        if i >= 0:
            _ = self.items.pop(i)
        self._clear(id, upto)

    def drop(mut self, id: Int):
        """It landed (or the person gave it up)."""
        var i = self.find(id)
        if i >= 0:
            _ = self.items.pop(i)
        self._clear(id, 0)

    def extra_done(mut self, i: Int):
        """extras[i] is a document of its own now."""
        _ = self.extras.pop(i)
        for path in self.extra_files.pop(i):
            self.disk.remove(path)

    # ------------------------------------------------ a start

    def space_in(self, name: String) -> String:
        """Which of this outbox's spaces a file of the folder is of ("": none)."""
        if name.startswith("unsaved-" + self.space + "-") or name.startswith("unsaved-" + self.space + "."):
            return self.space
        for s in self.also:
            if name.startswith("unsaved-" + s + "-") or name.startswith("unsaved-" + s + "."):
                return s
        return ""

    def gone(self, owner: String, mut lock: FileLock, space: String) -> Bool:
        """Whether `owner` is no more (its lock is then ours, in `lock`)."""
        if owner.startswith("n"):
            var dash = owner.find("-")
            try:
                var pid = Int(String(owner[byte = 1 : max(dash, 1)]))
                return pid != getpid() and kill(pid, 0) != 0
            except:
                return False
        return lock.take(self.lock_path(owner, space))

    def load(mut self):
        """What earlier sessions left: the versions of owners that are gone, theirs to this outbox now."""
        if self.dir == "":
            return
        self.claim()
        if not self.disk.step():
            return
        var names = List[String]()
        try:
            for name in listdir(self.dir):
                names.append(String(name))
        except e:
            print("SaveOutbox: " + self.dir + ": " + String(e), flush=True)
            return
        # whose names are there, and which of them are gone (their locks held from here on)
        var owners = Dict[String, Bool]()
        for n in names:
            var space = self.space_in(n)
            if space == "":
                continue
            var head = "unsaved-" + space
            var owner: String
            if n.startswith(head + "-") and n.endswith(".json"):
                owner = _owner_of(settled_name(n))
            elif n.startswith(head + ".") and n.endswith(".lock"):
                owner = String(n[byte = head.byte_length() + 1 : n.byte_length() - 5])
            else:
                continue
            var whose = space + "." + owner
            if owner == self.owner or whose in owners:
                continue
            var lock = ArcPointer(FileLock())
            var is_gone = self.gone(owner, lock[], space)
            owners[whose] = is_gone
            if is_gone and lock[].held():
                self.taken.append(lock^)
        # (the folder again: an owner found gone may have written its last file since it was read; none of theirs is now)
        names.clear()
        try:
            for name in listdir(self.dir):
                names.append(String(name))
        except:
            return
        var found = List[HeldVersion]()
        var over = List[String]()  # what a later file stands for
        var by = List[String]()  # (that file)
        var left = Dict[String, Bool]()  # the gone owners that have files
        for name in names:
            var space = self.space_in(name)
            if space == "" or not name.startswith("unsaved-" + space + "-") or not name.endswith(".json"):
                continue
            var n = settled_name(name)
            var owner = space + "." + _owner_of(n)
            if owner not in owners or not owners.get(owner, False):
                continue
            left[owner] = True
            var full = self.dir + "/" + n
            if self._has(full) or (n != name and file_exists(full)):
                continue
            try:
                var t: String
                with open(self.dir + "/" + name, "r") as f:
                    t = f.read()
                if not unsaved_whole(t) and (n != name or t.find(SUM_MARK) >= 0):  # (a settled one of before sums has none)
                    print("SaveOutbox: " + name + " is torn (the power went while it was written): left alone", flush=True)
                    continue
                var j = Json.parse(t)
                var u = Unsaved(j.number(j.get(0, "id"), -1), j.text(j.get(0, "kind")), j.number(j.get(0, "revision"), -1), j.text(j.get(0, "content")),
                                j.text(j.get(0, "body")), j.text(j.get(0, "why")), j.flag(j.get(0, "conflict")),
                                DocBase(j.number(j.get(0, "revision"), -1), "", j.number(j.get(0, "base"), 0)), j.text(j.get(0, "of")))
                if u.id < 0 or u.content == "":
                    continue
                for k in range(j.size(j.get(0, "over"))):
                    over.append(j.text(j.at(j.get(0, "over"), k)))
                    by.append(full)
                var seq = _seq_of(n)
                # (invariant 4: of one window, the highest number; its earlier files with it)
                var at = -1
                for k in range(len(found)):
                    if found[k].owner == owner and found[k].held.id == u.id:
                        at = k
                if at < 0:
                    found.append(HeldVersion(u^, owner, seq, full))
                    at = len(found) - 1
                elif seq > found[at].seq:
                    found[at].held = u^
                    found[at].seq = seq
                    found[at].path = full
                found[at].files.append(full)
            except e:
                print("SaveOutbox: " + name + ": " + String(e), flush=True)
        for k in range(len(found) - 1, -1, -1):  # (invariant 2: a later file of another window stands for these: they go with its settle)
            var at = -1
            for q in range(len(over)):
                if over[q] == file_name(found[k].path):
                    at = q
            if at < 0:
                continue
            var keeper = -1
            for q in range(len(found)):
                if q != k and (by[at] in found[q].files or by[at] in found[q].olds):
                    keeper = q
            if keeper < 0:
                continue
            found[keeper].olds.extend(found[k].files.copy())
            found[keeper].olds.extend(found[k].olds.copy())
            _ = found.pop(k)
        for k in range(len(found)):
            for path in found[k].files:  # (invariant 4: the newest of a window holds its earlier ones)
                if path != found[k].path:
                    found[k].olds.append(path)
            var files = found[k].olds.copy()  # (in the order they go)
            files.append(found[k].path)
            var have = self.find(found[k].held.id)
            if have >= 0 and found[k].held.revision <= self.items[have].revision:
                self.extras.append(found[k].held.copy())
                self.extra_files.append(files.copy())
            else:
                if have >= 0:  # (invariant 4: the later one is the document's)
                    var mine = List[String]()
                    var q = 0
                    while q < len(self.files):
                        if self.files[q].id == found[k].held.id:
                            mine.append(self.files.pop(q).path)
                        else:
                            q += 1
                    self.extras.append(self.items[have].copy())
                    self.extra_files.append(mine^)
                    self.items[have] = found[k].held.copy()
                else:
                    self.items.append(found[k].held.copy())
                for path in files:
                    self.files.append(HeldFile(found[k].held.id, 0, path))
            if len(found[k].olds) > 0 or not file_exists(found[k].path):
                self._settle(found[k].path, found[k].olds.copy())
        # (a gone owner's name goes with its last file)
        for e in owners.items():
            if e.value and not left.get(e.key, False):
                if self.disk.step():
                    _ = unlink(self.dir + "/unsaved-" + e.key + ".lock")

    def _has(self, path: String) -> Bool:
        """A file this outbox has already (load() a second time)."""
        for k in range(len(self.files)):
            if self.files[k].path == path:
                return True
        for k in range(len(self.extra_files)):
            if path in self.extra_files[k]:
                return True
        return False


struct SettleJob(JobBody):
    """Held files settled, on a thread; how many were."""
    comptime Out = Int
    var which: List[Settle]

    def __init__(out self, var which: List[Settle]):
        self.which = which^

    def run(mut self, ctl: JobCtl) raises -> Int:
        var n = 0
        var disk = HeldDisk()
        for s in self.which:
            n += 1 if disk.settle(s) else 0
        return n


def _owner_of(name: String) -> String:
    """A held file's owner, from its name ("" for one from before owners): unsaved-<space>-<id>-<number>.<owner>.json"""
    var stem = String(name[byte = 0 : name.byte_length() - 5])
    var dot = stem.rfind(".")
    return String(stem[byte = dot + 1 :]) if dot >= 0 else String("")


def _seq_of(name: String) -> Int:
    """Its number (0 when it has none)."""
    var dot = name.find(".")
    var stem = String(name[byte = 0 : dot if dot >= 0 else name.byte_length()])
    var dash = stem.rfind("-")
    try:
        return Int(String(stem[byte = dash + 1 :])) if stem.count("-") >= 3 else 0
    except:
        return 0


struct KeptDocs[T: Movable & Deinitable](Movable):
    """Documents an app already parsed, kept by (id, revision): opening one again whose row still has that revision
    reuses it instead of reading and parsing its text again (D-7934). Least recently kept goes first beyond `cap`."""

    var ids: List[Int]
    var revs: List[Int]
    var bases: List[DocBase]  # (the row each was left as: kept with it)
    var docs: List[Self.T]
    var cap: Int

    def __init__(out self, cap: Int = 4):
        self.ids = List[Int]()
        self.bases = List[DocBase]()
        self.revs = List[Int]()
        self.docs = List[Self.T]()
        self.cap = cap

    def find(self, id: Int, revision: Int) -> Int:
        for i in range(len(self.ids)):
            if self.ids[i] == id and self.revs[i] == revision:
                return i
        return -1

    def take(mut self, at: Int) -> Self.T:
        """Hands back kept document `at` (it leaves the store; its base is bases[at], to be taken first)."""
        _ = self.ids.pop(at)
        _ = self.bases.pop(at)
        _ = self.revs.pop(at)
        return self.docs.pop(at)

    def keep(mut self, id: Int, revision: Int, var doc: Self.T):
        """doc kept; what it replaces or pushes out is freed here (keep_out hands it back instead)."""
        _ = self.keep_out(id, revision, doc^)

    def keep_out(mut self, id: Int, revision: Int, var doc: Self.T, var base: DocBase = DocBase()) -> List[Self.T]:
        """doc kept; what it replaced or pushed out, for the caller to let go when it likes (mojoui.letgo: a big document's
        end takes milliseconds)."""
        var out = List[Self.T]()
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                out.append(self.take(i))
                break
        if len(self.ids) >= self.cap:
            out.append(self.take(0))
        self.ids.append(id)
        self.revs.append(revision)
        self.bases.append(base^)
        self.docs.append(doc^)
        return out^

    def clear(mut self):
        self.ids.clear()
        self.revs.clear()
        self.bases.clear()
        self.docs.clear()
