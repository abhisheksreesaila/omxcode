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
        var up = db.prepare(s.sql())
        var at = 1
        for ref v in s.vals:
            _bind(up, at, v)
            at += 1
        up.bind(at, s.expected + 1)
        up.bind(at + 1, s.id)
        up.bind(at + 2, s.expected)
        _ = up.step()
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
        db.commit()
        return SaveResult(SAVED, s.expected + 1, value, "")
    except e:
        _undo(db)
        return SaveResult(FAILED, s.expected, "", String(e))


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
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                _ = self.take(i)
                break
        if len(self.ids) >= self.cap:
            _ = self.take(0)
        self.ids.append(id)
        self.revs.append(revision)
        self.docs.append(doc^)

    def clear(mut self):
        self.ids.clear()
        self.revs.clear()
        self.docs.clear()
