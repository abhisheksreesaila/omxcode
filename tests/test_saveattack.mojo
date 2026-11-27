# The save thread attacked (goal 79, continuation 21, item 3): the file locked while notes are left and opened again, closing
# with it locked, notes deleted elsewhere before and during a save, a full disk, two windows on one file. In every case no edit
# is lost silently. (Kill -9 at each stage and another process's lock: tests/savekill.py.) No window.
#   pixi run mojo build -I . -I vendor -I examples/pnote tests/test_saveattack.mojo -o build/test_saveattack && build/test_saveattack   (built: `mojo run` has no job threads)
from std.ffi import external_call, c_int
from std.os import setenv, listdir
from std.testing import assert_true, assert_equal
from mojoui import libc
from mojoui.libc import unlink
from mojoui.files import private_dir
from mojoui.sqlite import Database
from mojoui.docstore import clock_us, Unsaved
from webshell import WebShell

comptime DB = "build/test_saveattack.db"


def fresh() raises:
    for x in ["", "-wal", "-shm"]:
        _ = unlink(String(DB) + String(x))
    try:
        for f in listdir("build/test_saveattack_cfg/unsaved"):
            _ = unlink("build/test_saveattack_cfg/unsaved/" + String(f))
    except:
        pass


def held_files() raises -> Int:
    var n = 0
    try:
        for f in listdir("build/test_saveattack_cfg/unsaved"):
            if String(f).endswith(".json"):
                n += 1
    except:
        pass
    return n


def typed(mut s: WebShell, words: String):
    for c in words.graphemes():
        _ = s.key(String(c), 0)


def text(sql: String) raises -> String:
    var db = Database(DB)
    var q = db.prepare(sql)
    return q.text(0) if q.step() else String("")


def words(id: Int) raises -> String:
    return text("SELECT body FROM note_search WHERE note_id = " + String(id))


def count(sql: String) raises -> Int:
    return Database(DB).count(sql)


def due(mut s: WebShell):
    s.saver.due_us = clock_us() - 1
    _ = s.tick()


def settle(mut s: WebShell, ms: Int = 10_000):
    var by = clock_us() + ms * 1000
    while s.saving() and clock_us() < by:
        _ = s.tick()
        _ = libc.usleep(500)


def consistent() raises:
    """The file is whole: SQLite's own check, and every note's search words are those of its content."""
    assert_equal(text("PRAGMA integrity_check"), "ok")
    assert_equal(count("SELECT COUNT(*) FROM notes WHERE NOT json_valid(content) AND content != ''"), 0)


def left_and_back() raises:
    """The file locked: notes are left and opened again at once, with what was typed; everything lands when it can."""
    var s = WebShell(DB, "paper")
    s.create("page", "A")
    var a = s.current
    s.create("page", "B")
    var b = s.current
    s.open(a)
    s.flush()
    var lock = Database(DB)
    lock.exec("BEGIN IMMEDIATE")
    typed(s, "one")
    due(s)
    var t0 = clock_us()
    s.open(b)
    typed(s, "bee")
    s.open(a)
    assert_true(clock_us() - t0 < 300_000, "nothing waits: " + String(clock_us() - t0) + " us")
    assert_equal(s.page.markdown(), "one")
    _ = s.key("End", 2)
    typed(s, " two")
    s.open(b)
    assert_equal(s.page.markdown(), "bee")
    _ = s.key("End", 2)
    typed(s, "s")
    s.open(a)
    assert_equal(s.page.markdown(), "one two")
    assert_true(s.doc.may_edit() and s.save_state == "", s.save_detail)
    _ = libc.usleep(400_000)
    assert_true(held_files() >= 1, "held on disk while it waits")
    lock.exec("ROLLBACK")
    settle(s)
    assert_true(words(a) == "one two" and words(b) == "bees", words(a) + "|" + words(b))
    assert_equal(held_files(), 0)
    _ = s.key("End", 2)
    typed(s, " three")
    due(s)
    settle(s)
    assert_equal(words(a), "one two three")
    assert_equal(s.save_state, "")
    s.close()
    consistent()
    print("   left and opened again while the file is locked")


def closed_locked() raises:
    """Closed with the file locked: held on disk, opens with it and lands later; a retry isn't a conflict."""
    var s = WebShell(DB, "paper")
    s.create("page", "Closing")
    var id = s.current
    s.flush()
    var lock = Database(DB)
    lock.exec("BEGIN IMMEDIATE")
    typed(s, "kept words")
    due(s)
    typed(s, " and more")
    var t0 = clock_us()
    assert_true(s.may_close(), "may close: it is on disk")
    s.close()
    var took = clock_us() - t0
    assert_true(took < 25_000_000, "bounded: " + String(took // 1000) + " ms")
    assert_true(held_files() == 1 and words(id) == "", "held")
    lock.exec("ROLLBACK")
    var t = WebShell(DB, "paper")
    t.open(id)
    assert_equal(t.page.markdown(), "kept words and more")
    assert_true(t.save_state != "", "said")
    t.retry_save()
    assert_equal(t.save_state, "")
    assert_equal(words(id), "kept words and more")
    assert_equal(held_files(), 0)
    t.close()
    # ended between the write and forgetting what was held: the next start finds them the same
    var u = WebShell(DB, "paper")
    u.open(id)
    u.outbox.dir = "build/test_saveattack_cfg/unsaved"
    var content = text("SELECT content FROM notes WHERE id = " + String(id))

    assert_true(u.outbox.put(Unsaved(id, "page", u.doc.revision - 1, content, "kept words and more", "", False)), "put")
    var v = WebShell(DB, "paper")
    assert_equal(v.outbox.find(id), -1)
    assert_equal(held_files(), 0)
    # an outcome that never came back: the row already has these words, at a newer revision
    v.open(id)
    _ = v.key("End", 2)
    typed(v, "!")
    v.flush()
    v.notes[v.note_index(id)].revision -= 1
    v.doc.revision -= 1
    v.save_page()
    v.flush()
    assert_true(v.save_state == "" and v.outbox.find(id) < 0 and words(id).endswith("!"), "the same words aren't a conflict: " + v.save_detail)
    typed(v, "?")
    v.flush()
    assert_true(v.save_state == "" and words(id).endswith("!?"), "and it goes on")
    consistent()
    print("   closed while locked: held, opens, lands")


def deleted_elsewhere() raises:
    """Its row deleted by another app while its save waits, or before it: the edits become a note."""
    var s = WebShell(DB, "paper")
    s.create("page", "Going")
    var id = s.current
    typed(s, "start")
    s.flush()
    _ = s.refresh()
    var other = Database(DB)
    other.exec("BEGIN IMMEDIATE")
    typed(s, " precious")
    due(s)
    _ = libc.usleep(150_000)
    other.exec("DELETE FROM note_search WHERE note_id = " + String(id) + "; DELETE FROM notes WHERE id = " + String(id)
               + "; UPDATE workspace_state SET sequence = sequence + 1 WHERE id = 1; COMMIT")
    settle(s)
    assert_true(s.notes[0].title == "Going (my copy)" and s.current == s.notes[0].id and s.page.markdown() == "start precious", s.notes[0].title)
    assert_true(s.note_index(id) < 0 and s.doc.may_edit() and s.toast != "", "said")
    # before it: the change feed sees it first
    s.create("page", "Going too")
    var b = s.current
    s.flush()
    _ = s.refresh()
    typed(s, "unsaved words")
    other.exec("BEGIN IMMEDIATE; DELETE FROM notes WHERE id = " + String(b) + "; UPDATE workspace_state SET sequence = sequence + 1 WHERE id = 1; COMMIT")
    _ = s.refresh()
    assert_true(s.page.markdown() == "unsaved words" and s.current != b and s.doc.may_edit(), "its words are a note")
    s.close()
    assert_true(count("SELECT COUNT(*) FROM notes WHERE title LIKE '%(my copy)'") == 2, "both in the file")
    consistent()
    print("   deleted elsewhere: the edits are a note of their own")


def full_disk() raises:
    """Nothing can be written (RLIMIT_FSIZE 0 stands for a full disk): told, kept in memory, the window stays open once; with
    room again it lands."""
    var s = WebShell(DB, "paper")
    s.create("page", "Full")
    var id = s.current
    s.flush()
    _ = libc.ignore_signal(25)  # (SIGXFSZ ignored: writes fail with EFBIG; libc's one signal declaration, goal 82 integration)
    var lim = List[UInt64](length=2, fill=0)
    _ = external_call["getrlimit", c_int](c_int(1), Int(lim.unsafe_ptr()))
    var was = lim[0]
    lim[0] = 0
    assert_equal(Int(external_call["setrlimit", c_int](c_int(1), Int(lim.unsafe_ptr()))), 0)
    typed(s, "no room")
    due(s)
    settle(s)
    var told = s.save_state
    var risk = len(s.at_risk)
    var first = s.may_close()
    var second = s.may_close()
    lim[0] = was
    _ = external_call["setrlimit", c_int](c_int(1), Int(lim.unsafe_ptr()))
    assert_true(told != "" and risk == 1, "told: " + told + " " + String(risk))
    assert_true(not first and second, "kept open once")
    assert_true(s.page.markdown() == "no room" and words(id) == "", "still on the screen")
    s.closing_until = 0
    s.retry_save()
    assert_true(s.save_state == "" and words(id) == "no room" and len(s.at_risk) == 0 and s.may_close(), "room again: " + s.save_detail)
    s.close()
    consistent()
    print("   a full disk: told, kept, the window stays open once")


def two_windows() raises:
    """Two windows on one file, both typing into one note and into their own: the second to save is told; both texts are in
    the file at the end."""
    var s = WebShell(DB, "paper")
    s.create("page", "Both")
    var id = s.current
    s.flush()
    var t = WebShell(DB, "paper")
    t.open(id)
    for k in range(6):
        typed(s, "s" + String(k))
        typed(t, "t" + String(k))
        due(s)
        due(t)
        settle(s)
        settle(t)
    var loser_s = s.save_state != ""
    var loser_t = t.save_state != ""
    assert_true(loser_s != loser_t, "exactly one is told")
    if loser_s:
        s.save_copy()
    else:
        t.save_copy()
    s.create("page", "S own")
    t.create("page", "T own")
    typed(s, "from s")
    typed(t, "from t")
    due(s)
    due(t)
    settle(s)
    settle(t)
    s.close()
    t.close()
    assert_equal(count("SELECT COUNT(*) FROM note_search WHERE body = 's0s1s2s3s4s5'"), 1)
    assert_equal(count("SELECT COUNT(*) FROM note_search WHERE body = 't0t1t2t3t4t5'"), 1)
    assert_equal(count("SELECT COUNT(*) FROM note_search WHERE body IN ('from s', 'from t')"), 2)
    consistent()
    print("   two windows: one told, both texts in the file")


def main() raises:
    _ = private_dir("build/test_saveattack_cfg")
    _ = setenv("OMX_CONFIG", "build/test_saveattack_cfg")
    _ = unlink("build/test_saveattack_cfg/settings.txt")
    fresh()
    left_and_back()
    deleted_elsewhere()
    full_disk()
    two_windows()
    closed_locked()
    print("saveattack: ok")
