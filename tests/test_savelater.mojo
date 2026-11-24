# A note's row saved on a thread of its own (mojoui.rowsaver; pnote): edits while it is being written, another note opened, the
# app closed, another app's save first, a locked file, the change feed; for a page, a canvas and a map. No window.
#   pixi run mojo run -I . -I vendor -I examples/pnote tests/test_savelater.mojo
from std.os import setenv
from std.testing import assert_true, assert_equal
from mojoui import libc
from mojoui.libc import unlink
from mojoui.files import private_dir
from mojoui.scene import Scene
from mojoui.sqlite import Database
from mojoui.docstore import RowSave, text_arg, SAVED, CONFLICT, FAILED, clock_us
from mojoui.rowsaver import RowSaver
from webshell import WebShell

comptime DB = "build/test_savelater.db"


def fresh(name: String) raises:
    for x in ["", "-wal", "-shm"]:
        _ = unlink(name + String(x))


def typed(mut s: WebShell, words: String):
    for c in words.graphemes():
        _ = s.key(String(c), 0)


def text(sql: String) raises -> String:
    var db = Database(DB)
    var q = db.prepare(sql)
    return q.text(0) if q.step() else String("")


def count(sql: String) raises -> Int:
    return Database(DB).count(sql)


def due(mut s: WebShell):
    """The timer's tick once the save is due."""
    s.saver.due_us = clock_us() - 1
    _ = s.tick()


def settle(mut s: WebShell):
    var by = clock_us() + 10_000_000
    while s.saving() and clock_us() < by:
        _ = s.tick()
        _ = libc.usleep(500)


def generic() raises:
    """RowSaver alone: the outcome once, a conflict, a file that isn't there."""
    var path = String("build/test_rowsaver.db")
    fresh(path)
    var db = Database(path)
    db.exec("PRAGMA journal_mode=WAL; CREATE TABLE t(id INTEGER PRIMARY KEY, rev INTEGER, body TEXT); INSERT INTO t VALUES (1, 1, 'a')")
    var w = RowSaver()
    assert_true(not w.busy() and not w.done(True), "nothing to have")
    var s = RowSave("t", "id", 1, "rev", 1)
    s.set("body", text_arg("b" * 3_000_000))
    var t0 = clock_us()
    w.start(path, s^)
    assert_true(clock_us() - t0 < 20_000 and w.busy(), "it doesn't wait")
    var got = w.done(True)
    assert_true(Bool(got) and got.value().result.status == SAVED and got.value().result.revision == 2 and got.value().hash != 0, "saved")
    assert_true(not w.busy() and not w.done(True), "once")
    assert_equal(db.count("SELECT length(body) FROM t"), 3_000_000)
    var stale = RowSave("t", "id", 1, "rev", 1)
    stale.set("body", text_arg("c"))
    w.start(path, stale^)
    assert_equal(w.done(True).value().result.status, CONFLICT)
    assert_equal(db.count("SELECT length(body) FROM t"), 3_000_000)
    var lost = RowSave("t", "id", 1, "rev", 2)
    lost.set("nothere", text_arg("c"))
    w.start(path, lost^)
    var bad = w.done(True)
    assert_true(bad.value().result.status == FAILED and bad.value().result.message != "", "why")
    print("   RowSaver: saved, conflict, failed")


def page() raises:
    var s = WebShell(DB, "paper")
    s.create("page", "One")
    var id = s.current
    typed(s, "first")
    _ = s.refresh()  # (the first look learns where the feed is)
    var rev = count("SELECT revision FROM notes WHERE id = " + String(id))
    due(s)
    assert_true(s.saving() and not s.saver.pending(), "on its thread")
    typed(s, " second")  # (while it is written)
    assert_true(s.saver.pending(), "the next save waits its turn")
    var by = clock_us() + 10_000_000
    while count("SELECT revision FROM notes WHERE id = " + String(id)) == rev and clock_us() < by:
        _ = libc.usleep(500)
    s.saver.done()  # (nothing pending that would hold the feed off)
    assert_true(s.saving() and not s.refresh() and s.page.markdown() == "first second" and s.current == id, "our own save, written but not taken yet, isn't another app's")
    s.save_page()
    settle(s)
    assert_equal(count("SELECT revision FROM notes WHERE id = " + String(id)), rev + 1)
    assert_true("first" in text("SELECT content FROM notes WHERE id = " + String(id)), "the first words")
    assert_true(not s.refresh() and s.page.markdown() == "first second" and s.doc.may_edit(), "the page goes on")
    due(s)
    settle(s)
    assert_true("first second" in text("SELECT content FROM notes WHERE id = " + String(id)), "and the rest")
    assert_equal(count("SELECT revision FROM notes WHERE id = " + String(id)), rev + 2)
    assert_equal(text("SELECT body FROM note_search WHERE note_id = " + String(id)), "first second")
    # another note opened while it is written; and back
    typed(s, " third")
    due(s)
    s.create("page", "Two")
    assert_true(not s.saving(), "it landed first")
    typed(s, "two")
    s.open(id)
    assert_equal(s.page.markdown(), "first second third")
    assert_true(s.doc.may_edit() and s.save_state == "", s.save_detail)
    # the app closed while it is written, with more typed since
    _ = s.key("End", 2)
    typed(s, " fourth")
    due(s)
    typed(s, " fifth")
    s.close()
    assert_true("first second third fourth fifth" in text("SELECT content FROM notes WHERE id = " + String(id)), "all of it, closing")
    print("   a page: edits meanwhile, another note, closing")


def conflict() raises:
    """Another app's save gets there first: told, held, a copy; nothing of theirs overwritten."""
    var s = WebShell(DB, "paper")
    s.create("page", "Shared")
    typed(s, "mine")
    s.flush()
    var id = s.current
    var db = Database(DB)
    db.exec("UPDATE notes SET content = replace(content, 'mine', 'theirs'), revision = revision + 1 WHERE id = " + String(id))
    typed(s, " more")
    due(s)
    settle(s)
    assert_true(s.save_state != "" and s.outbox.find(id) >= 0, "told and held")
    assert_true("theirs" in text("SELECT content FROM notes WHERE id = " + String(id)), "theirs stands")
    s.save_copy()
    assert_true(s.page.markdown() == "mine more" and s.save_state == "", "a copy")
    s.close()
    print("   a conflict: told, held, copied")


def locked() raises:
    """Another connection writing for a while: the window goes on, the save lands when it can."""
    var s = WebShell(DB, "paper")
    s.create("page", "Locked")
    var id = s.current
    s.flush()
    var other = Database(DB)
    other.exec("BEGIN IMMEDIATE")
    typed(s, "patient")
    var t0 = clock_us()
    due(s)
    for _ in range(20):
        _ = s.tick()
    assert_true(clock_us() - t0 < 100_000 and s.saving(), "nothing waits: " + String(clock_us() - t0) + " us")
    other.exec("ROLLBACK")
    settle(s)
    assert_true("patient" in text("SELECT content FROM notes WHERE id = " + String(id)) and s.save_state == "", "landed")
    s.close()
    print("   a locked file: the window doesn't wait")


def board_and_map() raises:
    var s = WebShell(DB, "paper")
    s.create("canvas", "Board")
    var id = s.current
    var sc = Scene(1440, 900, 1.0)
    s.paint(sc, 1440, 900, 1.0)
    s.tools.tool = "sticky"
    _ = s.press(700, 400)
    _ = s.release(700, 400)
    _ = s.tap(700, 400)
    typed(s, "kept")
    s.end_writing()
    due(s)
    assert_true(s.saving(), "on its thread")
    s.board.edit().begin_gesture(0)
    s.board.edit().select(s.board.edit().objs[0].id, False)
    s.board.edit().move_by(5, 5)
    s.board.edit().end_gesture()
    s.tools.changed = True
    s.save_canvas()
    settle(s)
    assert_true(s.board.edit().unsaved(), "the move since isn't saved yet")
    assert_true(s.saver.pending(), "and will be")
    due(s)
    settle(s)
    assert_true(not s.board.edit().unsaved() and "kept" in text("SELECT content FROM notes WHERE id = " + String(id)), "both")
    s.create("mindmap", "Map")
    var mid = s.current
    _ = s.key("Tab", 0)
    typed(s, "Leaf")
    _ = s.key("Enter", 0)
    due(s)
    settle(s)
    assert_true("Leaf" in text("SELECT content FROM notes WHERE id = " + String(mid)), "the map")
    s.close()
    print("   a canvas (its edits since stay unsaved) and a map")


def main() raises:
    _ = private_dir("build/test_savelater_cfg")
    _ = setenv("OMX_CONFIG", "build/test_savelater_cfg")
    _ = unlink("build/test_savelater_cfg/settings.txt")
    fresh(DB)
    generic()
    page()
    conflict()
    locked()
    board_and_map()
    print("savelater: ok")
