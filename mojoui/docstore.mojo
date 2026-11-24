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
from mojoui.files import private_write, FileLock
from mojoui.libc import unlink, usleep, getpid, kill, rename
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
    var problem: String

    def __init__(out self):
        self.id = -1
        self.state = DOC_NONE
        self.revision = -1
        self.problem = ""

    def begin(mut self, id: Int):
        self.id = id
        self.state = DOC_LOADING
        self.revision = -1
        self.problem = ""

    def ready(mut self, id: Int, revision: Int):
        """Read whole, at this revision (an answer for another document, or after a failure, changes nothing)."""
        if id == self.id and self.state == DOC_LOADING:
            self.state = DOC_READY
            self.revision = revision

    def failed(mut self, id: Int, why: String):
        if id == self.id:
            self.state = DOC_FAILED
            self.problem = why if why != "" else String("It couldn't be read.")

    def saved(mut self, revision: Int):
        if self.state == DOC_READY:
            self.revision = revision

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

    def __init__(out self, id: Int, kind: String, revision: Int, content: String, body: String, why: String, conflict: Bool):
        self.id = id
        self.kind = kind
        self.revision = revision
        self.content = content
        self.body = body
        self.why = why
        self.conflict = conflict


def unsaved_text(u: Unsaved) -> String:
    """A held save as its file has it (SaveOutbox.put, RowSaver while a locked file keeps it waiting)."""
    return ('{"id":' + String(u.id) + ',"kind":' + json_string(u.kind) + ',"revision":' + String(u.revision) + ',"conflict":' + ("true" if u.conflict else "false")
            + ',"why":' + json_string(u.why) + ',"body":' + json_string(u.body) + ',"content":' + json_string(u.content) + "}")


def _stage(name: String):
    """(tests: MOJOUI_SAVE_STAGE) The process stops here for a while, for something to be done to it at this very moment."""
    if getenv("MOJOUI_SAVE_STAGE") == name:
        print("STAGE: " + name, flush=True)
        _ = usleep(20_000_000)


struct SaveOutbox(Movable):
    """(review 3, SHOULD 7; review 4, MUST 1) Saves that failed or met a conflict, held until they land or the person drops
    them: in memory, and as files (0600, in a 0700 folder of the app's) written at once, so a switch, a quit or a crash
    loses nothing. One per document: a later failed save of it takes the place of the earlier. `space` names the store the
    ids belong to (two databases share no file).

    Several windows or processes share the folder. Each outbox's files carry its own name (`owner`), it alone removes them,
    and while it lives it holds a lock file of that name. load() takes over the files of owners that are gone (their lock can
    be taken); the living ones' are left alone. Two held versions of one document: one is `items`', the other in `extras`
    (what the app makes a document of its own from, then extra_done())."""

    var dir: String
    var space: String
    var owner: String
    var lock: FileLock
    var claimed: String  # the folder `owner` is claimed in
    var items: List[Unsaved]
    var extras: List[Unsaved]
    var extra_files: List[String]

    def __init__(out self, dir: String = "", space: String = ""):
        self.dir = dir
        self.space = space
        self.owner = ""
        self.lock = FileLock()
        self.claimed = ""
        self.items = List[Unsaved]()
        self.extras = List[Unsaved]()
        self.extra_files = List[String]()

    def __del__(deinit self):
        if len(self.items) == 0 and len(self.extras) == 0 and self.lock.held():  # (nothing of it left: its name neither)
            _ = unlink(self.lock.path)

    def claim(mut self):
        """This outbox's own name in its folder, and the lock that says it lives. Where files can't be locked the name says
        the process instead ("n<pid>-…")."""
        if self.dir == "" or self.claimed == self.dir:
            return
        self.claimed = self.dir
        for _ in range(8):  # (another start may look at a lock file in the instant between its making and its taking)
            self.owner = "p" + String(getpid()) + "-" + new_key("k")
            if self.lock.take(self.lock_path(self.owner)):
                return
        _ = unlink(self.lock_path(self.owner))
        self.owner = "n" + String(getpid()) + "-" + new_key("k")

    def lock_path(self, owner: String) -> String:
        return self.dir + "/unsaved-" + self.space + "." + owner + ".lock"

    def path(mut self, id: Int) -> String:
        """This outbox's file for document `id` ("": it has no folder)."""
        if self.dir == "":
            return ""
        self.claim()
        return self.dir + "/unsaved-" + self.space + "-" + String(id) + "." + self.owner + ".json"

    def find(self, id: Int) -> Int:
        for i in range(len(self.items)):
            if self.items[i].id == id:
                return i
        return -1

    def put(mut self, var u: Unsaved) -> Bool:
        """Held; True when it is on disk too."""
        var i = self.find(u.id)
        var text = unsaved_text(u)
        var id = u.id
        if i >= 0:
            self.items[i] = u^
        else:
            self.items.append(u^)
        if self.dir == "":
            return False
        return private_write(self.path(id), text)

    def drop(mut self, id: Int):
        """It landed (or the person gave it up)."""
        var i = self.find(id)
        if i >= 0:
            _ = self.items.pop(i)
        if self.dir != "" and self.claimed == self.dir:
            _ = unlink(self.path(id))

    def extra_done(mut self, i: Int):
        """extras[i] is a document of its own now."""
        _ = self.extras.pop(i)
        _ = unlink(self.extra_files.pop(i))

    def gone(self, owner: String, mut lock: FileLock) -> Bool:
        """Whether `owner` is no more (its lock is then ours, in `lock`)."""
        if owner == "":  # (a file from before owners)
            return True
        if owner.startswith("n"):
            var dash = owner.find("-")
            try:
                return kill(Int(String(owner[byte = 1 : max(dash, 1)])), 0) != 0
            except:
                return False
        return lock.take(self.lock_path(owner))

    def load(mut self):
        """What earlier sessions left: the files of owners that are gone, now this outbox's. One that can't be read stays where
        it is and hides no other."""
        if self.dir == "":
            return
        self.claim()
        var names = List[String]()
        try:
            for name in listdir(self.dir):
                names.append(String(name))
        except e:
            print("SaveOutbox: " + self.dir + ": " + String(e), flush=True)
            return
        sort(names)
        var start = "unsaved-" + self.space + "-"
        var asked = List[String]()  # the owners asked after, and whether each is gone
        var answer = List[Bool]()
        var locks = List[ArcPointer[FileLock]]()
        for n in names:
            if not n.startswith(start) or not n.endswith(".json"):
                continue
            var stem = String(n[byte = start.byte_length() : n.byte_length() - 5])  # <id>[x<k>][.<owner>]
            var dot = stem.find(".")
            var owner = String(stem[byte = dot + 1 :]) if dot >= 0 else String("")
            if owner == self.owner:
                continue
            var at = -1
            for k in range(len(asked)):
                if asked[k] == owner:
                    at = k
            if at < 0:
                var lock = ArcPointer(FileLock())
                at = len(asked)
                asked.append(owner)
                answer.append(self.gone(owner, lock[]))
                locks.append(lock^)
            if not answer[at]:
                continue
            var full = self.dir + "/" + n
            try:
                var t: String
                with open(full, "r") as f:
                    t = f.read()
                var j = Json.parse(t)
                var u = Unsaved(j.number(j.get(0, "id"), -1), j.text(j.get(0, "kind")), j.number(j.get(0, "revision"), -1), j.text(j.get(0, "content")),
                                j.text(j.get(0, "body")), j.text(j.get(0, "why")), j.flag(j.get(0, "conflict")))
                if u.id < 0 or u.content == "":
                    continue
                var have = self.find(u.id)
                if have < 0:
                    if rename(full, self.path(u.id)) == 0:
                        self.items.append(u^)
                    continue
                var mine = self.path(u.id)
                var spare = String(mine[byte = 0 : mine.find(".", mine.rfind("/"))]) + "x" + new_key("e") + "." + self.owner + ".json"
                if u.revision > self.items[have].revision:  # (the later one is the document's, the earlier the spare)
                    if rename(mine, spare) == 0 and rename(full, mine) == 0:
                        swap(u, self.items[have])
                        self.extras.append(u^)
                        self.extra_files.append(spare)
                elif rename(full, spare) == 0:
                    self.extras.append(u^)
                    self.extra_files.append(spare)
            except e:
                print("SaveOutbox: " + full + ": " + String(e), flush=True)
        for k in range(len(asked)):  # (a gone owner's name goes with its last file)
            if not answer[k] or asked[k] == "":
                continue
            var left = False
            try:
                for name in listdir(self.dir):
                    if String(name).endswith("." + asked[k] + ".json"):
                        left = True
            except:
                left = True
            if not left:
                _ = unlink(self.lock_path(asked[k]))


struct KeptDocs[T: Movable & Deinitable](Movable):
    """Documents an app already parsed, kept by (id, revision): opening one again whose row still has that revision
    reuses it instead of reading and parsing its text again (D-7934). Least recently kept goes first beyond `cap`."""

    var ids: List[Int]
    var revs: List[Int]
    var docs: List[Self.T]
    var cap: Int

    def __init__(out self, cap: Int = 4):
        self.ids = List[Int]()
        self.revs = List[Int]()
        self.docs = List[Self.T]()
        self.cap = cap

    def find(self, id: Int, revision: Int) -> Int:
        for i in range(len(self.ids)):
            if self.ids[i] == id and self.revs[i] == revision:
                return i
        return -1

    def take(mut self, at: Int) -> Self.T:
        """Hands back kept document `at` (it leaves the store)."""
        _ = self.ids.pop(at)
        _ = self.revs.pop(at)
        return self.docs.pop(at)

    def keep(mut self, id: Int, revision: Int, var doc: Self.T):
        """doc kept; what it replaces or pushes out is freed here (keep_out hands it back instead)."""
        _ = self.keep_out(id, revision, doc^)

    def keep_out(mut self, id: Int, revision: Int, var doc: Self.T) -> List[Self.T]:
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
        self.docs.append(doc^)
        return out^

    def clear(mut self):
        self.ids.clear()
        self.revs.clear()
        self.docs.clear()
