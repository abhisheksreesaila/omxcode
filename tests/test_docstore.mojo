# mojoui.docstore on its own (goal 79, D-7927): a row saved with its revision, a conflict when another writer moved it on
# (nothing written, the follow-ups not run), the debounce's timing. Not tied to any app: a made-up "docs" table.
#   pixi run mojo run -I . tests/test_docstore.mojo        → "docstore: ok"
from mojoui.sqlite import Database
from mojoui.docstore import KeptDocs, let_go, SaveTimer, RowSave, save_row, row_revision, text_arg, int_arg, SAVED, CONFLICT
from std.os import remove
from std.time import sleep
from std.memory import Pointer
from std.testing import assert_true, assert_equal
from std.os.path import exists


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error("docstore: FAIL " + what)


struct Counted(Movable):
    """Counts its own end in a cell the test owns."""
    var cell: Int

    def __init__(out self, cell: Int):
        self.cell = cell

    def __deinit__(deinit self):
        Pointer[Int, MutUntrackedOrigin](unsafe_from_address=self.cell)[] += 1


def ended(cell: Int, n: Int) -> Int:
    var total = 0
    for i in range(n):
        total += Pointer[Int, MutUntrackedOrigin](unsafe_from_address=cell + 8 * i)[]
    return total


def test_let_go() raises:
    """(D-8015) let_go and KeptDocs' evictions end a document exactly once, soon, on whichever thread (each has a cell of
    its own: the threads share none)."""
    var ends = List[Int](length=8, fill=0)
    var cell = Int(ends.unsafe_ptr())
    let_go(Counted(cell))
    var kept = KeptDocs[Counted](2)
    for i in range(6):
        kept.keep(i, 1, Counted(cell + 8 * (1 + i)))  # (four evicted)
    kept.keep(5, 2, Counted(cell + 56))  # (the same id again: the one kept before goes)
    for _ in range(2000):
        if ended(cell, 8) >= 6:
            break
        sleep(0.001)
    sleep(0.02)
    assert_equal(ended(cell, 8), 6)
    assert_true(kept.find(5, 2) >= 0 and kept.find(4, 1) >= 0 and kept.find(3, 1) < 0, "the two newest stay")
    kept.clear()
    for i in range(8):
        assert_equal(ends[i], 1)
    _ = len(ends)


def main() raises:
    test_let_go()
    var path = "build/test_docstore.db"
    if exists(path):
        remove(path)
    var db = Database(path)
    db.exec("CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT, revision INTEGER NOT NULL DEFAULT 1, updated_at TEXT)")
    db.exec("CREATE TABLE log (doc INTEGER, revision INTEGER)")
    db.exec("INSERT INTO docs (id, body, revision) VALUES (1, 'first', 1)")

    # a save on the revision the editor saw: written, revision + 1, the follow-up in the same transaction, the stamp read back
    var s = RowSave("docs", "id", 1, "revision", 1)
    s.set("body", text_arg("second"))
    s.stamp("updated_at")
    s.read_back("updated_at")
    s.then("INSERT INTO log (doc, revision) SELECT id, revision FROM docs WHERE id = ?", [int_arg(1)])
    var r = save_row(db, s)
    check(r.status == SAVED and r.revision == 2, "first save: status " + String(r.status) + " rev " + String(r.revision) + " " + r.message)
    check(r.value.byte_length() == 19, "the stamp read back: '" + r.value + "'")
    check(db.count("SELECT count(*) FROM log WHERE revision = 2") == 1, "the follow-up ran")

    # another writer (the web app) saves revision 3 behind our back
    db.exec("UPDATE docs SET body = 'theirs', revision = 3 WHERE id = 1")
    var s2 = RowSave("docs", "id", 1, "revision", 2)  # (we still think it's 2)
    s2.set("body", text_arg("ours"))
    s2.then("INSERT INTO log (doc, revision) VALUES (?, ?)", [int_arg(1), int_arg(99)])
    var r2 = save_row(db, s2)
    check(r2.status == CONFLICT, "a stale revision must conflict, got " + String(r2.status))
    check(r2.message == "Resource revision does not match", "the web's words: " + r2.message)
    check(db.one_text("SELECT body FROM docs WHERE id = 1") == "theirs", "the newer edit was overwritten")
    check(db.count("SELECT count(*) FROM log WHERE revision = 99") == 0, "a conflict ran its follow-ups")
    check(row_revision(db, "docs", "id", 1, "revision") == 3, "revision read")
    # saving again on the revision now held works (the transaction was closed properly)
    var s3 = RowSave("docs", "id", 1, "revision", 3)
    s3.set("body", text_arg("merged"))
    check(save_row(db, s3).revision == 4, "save after a conflict")

    # the debounce: one write after the last of a burst of edits
    var t = SaveTimer(650)
    check(not t.pending() and not t.due(0), "idle timer")
    t.touch(1_000_000)
    check(t.pending() and not t.due(1_600_000), "not due before 650 ms")
    t.touch(1_500_000)  # another keystroke pushes it back
    check(not t.due(2_100_000), "pushed back by a later edit")
    check(t.due(2_150_000), "due 650 ms after the last edit")
    t.done()
    check(not t.pending(), "done")
    check(t.tick_ms() == 65 and SaveTimer(50).tick_ms() == 10, "tick")
    # kept documents: reused only at the revision they were parsed at; the oldest goes beyond the cap
    var kept = KeptDocs[String](2)
    kept.keep(1, 5, "doc one at 5")
    kept.keep(2, 3, "doc two at 3")
    check(kept.find(1, 5) == 0 and kept.find(1, 6) == -1, "found only at its revision")
    var d = kept.take(kept.find(1, 5))
    check(d == "doc one at 5" and kept.find(1, 5) == -1, "taken out")
    kept.keep(1, 6, "doc one at 6")
    kept.keep(3, 1, "doc three")
    check(kept.find(2, 3) == -1 and kept.find(1, 6) >= 0 and kept.find(3, 1) >= 0, "the oldest went beyond the cap")
    kept.keep(1, 7, "doc one at 7")
    check(kept.find(1, 6) == -1 and kept.find(1, 7) >= 0, "a newer revision replaces the older one")
    print("docstore: ok")
