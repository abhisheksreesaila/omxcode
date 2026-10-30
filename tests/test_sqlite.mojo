# mojoui.sqlite (goal 42 M0): a file opens (and reopens with its rows); values round-trip through prepared statements
# (text with quotes and emoji, ints, floats, NULL); a rolled-back transaction leaves nothing and a committed one stays;
# bad SQL raises with SQLite's own message and the connection still works; an FTS5 table finds a prefix query.
#   pixi run mojo run -I . tests/test_sqlite.mojo
from std.testing import assert_true, assert_equal
from std.os import remove
from std.os.path import exists

from mojoui.sqlite import Database, fts_prefix_query
from mojoui.shared import environment


def fresh(name: String) raises -> String:
    var path = environment("TMPDIR", "/tmp") + "/mojoui-test-" + name + ".db"
    for suffix in ["", "-wal", "-shm", "-journal"]:
        if exists(path + suffix):
            remove(path + suffix)
    return path


def make(path: String) raises:
    var db = Database(path)
    db.exec("CREATE TABLE t(id INTEGER PRIMARY KEY, s TEXT, n INTEGER, f REAL, z TEXT)")
    db.exec("INSERT INTO t(s) VALUES ('kept')")
    assert_equal(db.last_id(), 1)


def count_in(path: String, sql: String) raises -> Int:
    """A query's count through a connection of its own (closed when it returns)."""
    var db = Database(path)
    return db.count(sql)


def main() raises:
    var path = fresh("sqlite")
    # open: made if missing, rows survive a reopen
    make(path)
    assert_true(exists(path))
    assert_equal(count_in(path, "SELECT count(*) FROM t"), 1)
    print("sqlite open: ok")

    var db = Database(path)
    # bind: every kind of value, and back
    var text = String("It's \"quoted\"; DROP TABLE t; -- 🍋 naïve 日本語")
    var ins = db.prepare("INSERT INTO t(s, n, f, z) VALUES (?, ?, ?, ?)")
    ins.bind(1, text)
    ins.bind(2, -9007199254740993)
    ins.bind(3, 3.25)
    ins.bind_null(4)
    ins.run()
    var id = db.last_id()
    ins.bind(1, "second")  # (the statement is reused after run's reset)
    ins.bind(2, 7)
    ins.bind(3, -0.5)
    ins.bind(4, "z")
    ins.run()
    var q = db.prepare("SELECT s, n, f, z FROM t WHERE id = ?")
    q.bind(1, id)
    assert_true(q.step())
    assert_equal(q.text(0), text)
    assert_equal(q.int(1), -9007199254740993)
    assert_equal(q.float(2), 3.25)
    assert_true(q.is_null(3))
    assert_true(not q.is_null(0))
    assert_equal(q.columns(), 4)
    assert_true(not q.step())
    q.reset()
    q.bind(1, id + 1)
    assert_true(q.step())
    assert_equal(q.text(0), "second")
    assert_equal(q.text(3), "z")
    assert_equal(db.count("SELECT count(*) FROM t"), 3)
    print("sqlite bind: ok")

    # tx: rollback leaves nothing, commit stays
    db.begin()
    db.exec("INSERT INTO t(s) VALUES ('gone')")
    assert_equal(db.count("SELECT count(*) FROM t WHERE s = 'gone'"), 1)
    db.rollback()
    assert_equal(db.count("SELECT count(*) FROM t WHERE s = 'gone'"), 0)
    db.begin()
    var many = db.prepare("INSERT INTO t(s) VALUES (?)")
    for i in range(100):
        many.bind(1, "row " + String(i))
        many.run()
    db.commit()
    assert_equal(count_in(path, "SELECT count(*) FROM t WHERE s LIKE 'row %'"), 100)  # (another connection sees the commit)
    print("sqlite tx: ok")

    # error: SQLite's message, the connection still usable
    var raised = String("")
    try:
        db.exec("SELEC * FROM t")
    except e:
        raised = String(e)
    assert_true("syntax error" in raised, raised)
    var raised2 = String("")
    try:
        var bad = db.prepare("SELECT nope FROM t")
        _ = bad.step()
    except e:
        raised2 = String(e)
    assert_true("no such column: nope" in raised2, raised2)
    var raised3 = String("")
    try:
        db.exec("CREATE TABLE u(k TEXT UNIQUE)")
        var u = db.prepare("INSERT INTO u VALUES (?)")
        u.bind(1, "a")
        u.run()
        u.bind(1, "a")
        u.run()
    except e:
        raised3 = String(e)
    assert_true("UNIQUE constraint failed" in raised3, raised3)
    assert_equal(db.count("SELECT count(*) FROM t"), 103)  # (still usable)
    var raised4 = String("")
    try:
        _ = Database("/nonexistent-dir/x.db")
    except e:
        raised4 = String(e)
    assert_true("can't open" in raised4, raised4)
    print("sqlite error: ok")

    # fts5: a prefix query, kept in step by triggers
    db.exec("CREATE TABLE notes(id INTEGER PRIMARY KEY, title TEXT, body TEXT)")
    db.exec("CREATE VIRTUAL TABLE notes_fts USING fts5(title, body, content='notes', content_rowid='id')")
    db.exec("CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END")
    db.exec("CREATE TRIGGER notes_ad AFTER DELETE ON notes BEGIN INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body); END")
    var add = db.prepare("INSERT INTO notes(title, body) VALUES (?, ?)")
    for pair in [("Trip plan", "flights to Lisbon in May"), ("Groceries", "milk, eggs and 🍋 lemons"), ("Lisbon trams", "line 28")]:
        add.bind(1, pair[0])
        add.bind(2, pair[1])
        add.run()
    var find = db.prepare("SELECT n.title FROM notes_fts JOIN notes n ON n.id = notes_fts.rowid WHERE notes_fts MATCH ? ORDER BY rank")
    find.bind(1, "lisb*")
    var found = List[String]()
    while find.step():
        found.append(find.text(0))
    assert_equal(len(found), 2)
    db.exec("DELETE FROM notes WHERE title = 'Lisbon trams'")
    find.reset()
    find.bind(1, "lisb*")
    var after = 0
    while find.step():
        after += 1
    assert_equal(after, 1)
    find.reset()
    find.bind(1, "lemon*")
    assert_true(find.step())
    assert_equal(find.text(0), "Groceries")
    assert_equal(fts_prefix_query("  lisb  tr "), '"lisb"* "tr"*')
    assert_equal(fts_prefix_query("   "), "")
    for typed in ['say "hi', "NEAR(a b)", "-x", "title:lisb", "AND OR"]:  # (FTS5 syntax is text to find, never an error)
        find.reset()
        find.bind(1, fts_prefix_query(typed))
        while find.step():
            pass
    find.reset()
    find.bind(1, fts_prefix_query("lisb fli"))
    assert_true(find.step())
    assert_equal(find.text(0), "Trip plan")
    print("sqlite fts5: ok")
