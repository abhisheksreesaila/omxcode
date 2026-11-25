# Review round 4 (goal 79, continuation 22): ways words were lost, each held to "never, and never without a word".
#   pixi run mojo build -I . -I vendor -I examples/pnote tests/test_review4.mojo && ./test_review4
from std.os import setenv, listdir
from std.testing import assert_true, assert_equal
from mojoui import libc
from mojoui.libc import unlink
from mojoui.files import private_dir, private_write
from mojoui.scene import Scene
from mojoui.sqlite import Database
from mojoui.docstore import clock_us
from webshell import WebShell

comptime DB = "build/test_review4.db"
comptime CFG = "build/test_review4_cfg"


def fresh() raises:
    for x in ["", "-wal", "-shm"]:
        _ = unlink(String(DB) + String(x))
    try:
        for f in listdir(CFG + "/unsaved"):
            _ = unlink(CFG + "/unsaved/" + String(f))
    except:
        pass


def held() raises -> String:
    var t = String("")
    for f in listdir(CFG + "/unsaved"):
        if String(f).endswith(".json"):
            with open(CFG + "/unsaved/" + String(f), "r") as h:
                t += h.read()
    return t


def typed(mut s: WebShell, words: String):
    for c in words.graphemes():
        _ = s.key(String(c), 0)


def committed(mut s: WebShell, words: String):
    for c in words.codepoint_slices():
        _ = s.text_in("commit", String(c))


def all_words() raises -> String:
    var db = Database(DB)
    var q = db.prepare("SELECT body, title FROM note_search")
    var s = String("")
    while q.step():
        s += "[" + q.text(1) + ": " + q.text(0) + "]"
    return s


def due(mut s: WebShell):
    s.saver.due_us = clock_us() - 1
    _ = s.tick()


def settle(mut s: WebShell, ms: Int = 10_000):
    var by = clock_us() + ms * 1000
    while s.saving() and clock_us() < by:
        _ = s.tick()
        _ = libc.usleep(500)


def two_windows() raises:
    fresh()
    var s = WebShell(DB, "paper")
    s.create("page", "Both")
    var id = s.current
    s.flush()
    var t = WebShell(DB, "paper")
    t.open(id)
    typed(s, "s-words")
    typed(t, "t-words")
    due(s)
    settle(s)
    due(t)
    settle(t)
    assert_true(t.save_state != "" and "t-words" in held(), "the loser's are held")
    typed(s, " more")
    due(s)
    settle(s)
    assert_true("t-words" in held(), "the other window's next save leaves them")
    assert_true(t.may_close(), "held on disk: may close")
    t.close()
    _ = t^
    s.close()
    _ = s^
    var u = WebShell(DB, "paper")
    u.open(id)
    assert_true(u.outbox.find(id) >= 0 and "t-words" in u.page.markdown() and u.save_state != "", "the next start has them")
    u.save_copy()
    assert_true("t-words" in all_words() and "s-words more" in all_words(), all_words())
    u.close()
    print("   two windows")


def own_warning() raises:
    fresh()
    var s = WebShell(DB, "paper")
    s.create("page", "A")
    var a = s.current
    s.create("page", "B")
    var b = s.current
    s.open(a)
    s.flush()
    var other = Database(DB)
    typed(s, "mine")
    other.exec("UPDATE notes SET revision = revision + 1, content = json_set(content, '$.theirs', revision) WHERE id = " + String(a))
    due(s)
    settle(s)
    assert_true(s.save_state != "", "A's is told")
    s.open(b)
    typed(s, "bee")
    s.open(a)
    settle(s)
    assert_true(s.save_state != "" and s.outbox.find(a) >= 0, "B's save doesn't take A's warning away")
    s.open(b)
    typed(s, "cee")
    other.exec("UPDATE notes SET revision = revision + 1, content = json_set(content, '$.theirs', revision) WHERE id = " + String(b))
    s.create("page", "C")
    settle(s)
    assert_true(s.save_state == "" and "“B”" in s.toast, "B's failure isn't said of C: " + s.toast)
    s.rename("Later")
    s.close()
    print("   a warning is its own note's")


def gone_in_flight() raises:
    fresh()
    var s = WebShell(DB, "paper")
    s.create("page", "Going")
    var id = s.current
    typed(s, "start")
    s.flush()
    _ = s.refresh()
    var other = Database(DB)
    other.exec("BEGIN IMMEDIATE")
    typed(s, " saved-words")
    due(s)
    _ = libc.usleep(150_000)
    typed(s, " typed-after")
    other.exec("DELETE FROM note_search WHERE note_id = " + String(id) + "; DELETE FROM notes WHERE id = " + String(id) + "; UPDATE workspace_state SET sequence = sequence + 1 WHERE id = 1; COMMIT")
    settle(s)
    assert_true("typed-after" in s.page.markdown(), "still on screen")
    s.close()
    assert_true("saved-words typed-after" in all_words(), "and in the file: " + all_words())
    print("   deleted elsewhere while its save is in flight")


def new_text() raises:
    fresh()
    var s = WebShell(DB, "paper")
    s.create("canvas", "D")
    var id = s.current
    assert_equal(s.tools.editing, -2, "Quick note opens for writing")
    committed(s, "brand new")
    assert_true(s.saver.pending(), "typing is to be saved")
    due(s)
    settle(s)
    assert_true("brand new" in all_words() and s.tools.editing == -2, "in the file while it is written")
    s.export_backup()
    var one = s.toast
    s.export_backup()
    assert_true(s.toast.startswith("Backed up") and s.toast != one, "two in one second: " + s.toast)
    committed(s, " words")
    due(s)
    settle(s)
    assert_true("brand new words" in all_words(), all_words())
    var undo0 = s.board.edit().can_undo()
    assert_true(not undo0, "no undo step yet: the board hasn't changed")
    _ = s.key("Escape", 0)
    assert_equal(len(s.board.edit().objs), 1, "one text")
    var name = s.board.edit().objs[0].key
    due(s)
    settle(s)
    var q = Database(DB).prepare("SELECT content FROM notes WHERE id = " + String(id))
    assert_true(q.step() and name in q.text(0) and q.text(0).count("brand new words") == 1, "once, under the name it was saved as")
    s.delete_note()
    s.undo_delete()
    assert_true("brand new words" in all_words())
    # written, deleted and undone before any save
    s.create("canvas", "E")
    committed(s, "not saved yet")
    s.delete_note()
    s.undo_delete()
    s.close()
    assert_true("not saved yet" in all_words(), "delete and Undo keep it: " + all_words())
    # taken back: gone from the file too
    var t = WebShell(DB, "paper")
    t.create("canvas", "F")
    committed(t, "oops")
    due(t)
    settle(t)
    assert_true("oops" in all_words())
    for _ in range(4):
        _ = t.key("BackSpace", 0)
    _ = t.key("Escape", 0)
    due(t)
    settle(t)
    t.close()
    assert_true(not ("oops" in all_words()), "words taken back aren't kept")
    # a kept view never stands for a file whose words it doesn't show
    var v = WebShell(DB, "paper")
    v.create("canvas", "G")
    committed(v, "half")
    due(v)
    settle(v)
    assert_true(not v.look.keep_note.endswith(String(v.board.text_hash)) or v.board.text_hash == 0, v.look.keep_note)
    assert_equal(v.content_hash, 1)
    v.close()
    print("   a new text is saved as it is written")


def locked_file() raises:
    fresh()
    var s = WebShell(DB, "paper")
    s.create("page", "A")
    var a = s.current
    s.create("page", "B")
    var b = s.current
    s.open(a)
    s.flush()
    var lock = Database(DB)
    lock.exec("BEGIN IMMEDIATE")
    typed(s, "first")
    due(s)
    _ = libc.usleep(300_000)
    typed(s, " second")
    due(s)
    s.open(b)
    typed(s, "words of B")
    due(s)
    _ = libc.usleep(400_000)
    due(s)
    var h = held()
    assert_true("first second" in h and "words of B" in h, "a kill now loses nothing: " + h)
    lock.exec("ROLLBACK")
    settle(s)
    assert_true("first second" in all_words() and "words of B" in all_words(), all_words())
    assert_equal(held(), "", "nothing held once all landed")
    # a kill while they wait: the next start has the newest of each
    lock.exec("BEGIN IMMEDIATE")
    s.open(a)
    typed(s, " third")
    due(s)
    _ = libc.usleep(300_000)
    typed(s, " fourth")
    due(s)
    _ = libc.usleep(400_000)
    due(s)
    var n = 0
    for f in listdir(CFG + "/unsaved"):
        if String(f).endswith(".json"):
            n += 1
    assert_equal(n, 2, "the one being written and the one waiting")
    lock.exec("ROLLBACK")
    settle(s)
    # three waiting at the close: one wait, all held
    var ids = List[Int]()
    for k in range(3):
        s.create("page", "N" + String(k))
        ids.append(s.current)
    s.flush()
    lock.exec("BEGIN IMMEDIATE")
    for k in range(3):
        s.open(ids[k])
        typed(s, "w" + String(k))
    var t0 = clock_us()
    assert_true(s.may_close(), "may close: all on disk")
    assert_true(clock_us() - t0 < 6_000_000, "took " + String((clock_us() - t0) // 1000) + " ms")
    h = held()
    assert_true("w0" in h and "w1" in h and "w2" in h, h)
    lock.exec("ROLLBACK")
    s.close()
    print("   a locked file")


def locked_note() raises:
    fresh()
    var s = WebShell(DB, "paper")
    s.create("page", "S")
    var id = s.current
    s.flush()
    _ = s.refresh()
    typed(s, "unsaved words")
    var o = Database(DB)
    o.exec("UPDATE notes SET secure = 1, content = '{}', revision = revision + 1 WHERE id = " + String(id) + "; UPDATE workspace_state SET sequence = sequence + 1 WHERE id = 1")
    _ = s.refresh()
    due(s)
    settle(s)
    s.flush()
    assert_true(s.save_state != "" and "unsaved words" in held(), "said, and held: '" + s.save_state + "' " + held())
    s.save_copy()
    assert_true("unsaved words" in all_words(), "a copy keeps them")
    s.close()
    print("   locked in another app")


def hands_down() raises:
    fresh()
    var s = WebShell(DB, "paper")
    s.create("canvas", "C")
    var id = s.current
    s.flush()
    var sc = Scene(1440, 900, 1.0)
    s.paint(sc, 1440, 900, 1.0)
    _ = s.key("Escape", 0)
    s.tools.tool = "pen"
    _ = s.refresh()
    _ = s.press(600, 400)
    for k in range(10):
        _ = s.pan(600 + Float64(k) * 10, 400)
    var o = Database(DB)
    o.exec("UPDATE notes SET revision = revision + 1, content = json_set(content, '$.theirs', revision) WHERE id = " + String(id) + "; UPDATE workspace_state SET sequence = sequence + 1 WHERE id = 1")
    assert_true(not s.refresh(), "not while the pen is down")
    for k in range(10):
        _ = s.pan(700 + Float64(k) * 10, 400)
    _ = s.release(800, 400)
    assert_equal(len(s.board.edit().objs), 1, "the stroke is there")
    s.close()
    # a change of its notebook only: what is open stays, its undo too
    fresh()
    var t = WebShell(DB, "paper")
    t.create("page", "P")
    id = t.current
    typed(t, "some words")
    t.flush()
    _ = t.refresh()
    _ = t.key("ArrowLeft", 0)
    var at = t.page.ed.caret.byte
    o = Database(DB)
    o.exec("INSERT INTO notebooks (name, color, category) VALUES ('Z', '#ff0000', 'projects')")
    o.exec("UPDATE notes SET notebook_id = (SELECT max(id) FROM notebooks), revision = revision + 1 WHERE id = " + String(id) + "; UPDATE workspace_state SET sequence = sequence + 1 WHERE id = 1")
    assert_true(t.refresh())
    assert_true(t.page.ed.caret.byte == at and t.page.ed.history.can_undo(), "the caret and undo stay")
    typed(t, "X")
    t.flush()
    assert_true(t.save_state == "" and "some wordXs" in all_words(), all_words())
    t.close()
    print("   hands down; another notebook")


def grid_of(id: Int) raises -> String:
    var q = Database(DB).prepare("SELECT json_extract(content, '$.pn.page.columns') || 'x' || json_extract(content, '$.pn.page.rows') FROM notes WHERE id = " + String(id))
    return q.text(0) if q.step() else String("")


def paper() raises:
    """(MUST 6) The paper grows as words and objects reach its edges, can be scrolled to, is saved so, and folds back."""
    fresh()
    var s = WebShell(DB, "paper")
    s.create("canvas", "Long")
    var id = s.current
    var sc = Scene(1440, 900, 1.0)
    s.paint(sc, 1440, 900, 1.0)
    for k in range(62):
        committed(s, "line " + String(k))
        _ = s.key("Return", 0)
    s.paint(sc, 1440, 900, 1.0)
    assert_true(s.rows >= 2 and s.cols == 1, "grew while typed: " + String(s.cols) + "x" + String(s.rows))
    var low = s.view.y
    for _ in range(100):
        _ = s.wheel(700, 500, 0, -120)
    assert_true(s.view.y < low - 1000, "its lower pages can be brought on screen: " + String(s.view.y))
    _ = s.key("Escape", 0)
    var rows = s.rows
    s.flush()
    assert_equal(grid_of(id), "1x" + String(rows))
    s.close()
    var t = WebShell(DB, "paper")
    t.open(id)
    t.paint(sc, 1440, 900, 1.0)
    _ = t.board.edit()
    t.paint(sc, 1440, 900, 1.0)
    assert_true(t.rows == rows, "opens so")
    _ = t.key("Escape", 0)
    ref layer = t.board.edit()
    var a = layer.add_sticky(100, 100, 200, "note")
    layer.select(a)
    layer.move_by(900, 0)
    t.tools.changed = True
    t.save_canvas()
    assert_equal(t.cols, 2)
    t.flush()
    assert_equal(grid_of(id), "2x" + String(rows), "a read document's grid is patched")
    _ = t.board.edit().undo()
    t.tools.changed = True
    t.save_canvas()
    assert_equal(t.cols, 1, "folds back")
    var vx = t.view.x
    t.board.edit().select(a)
    t.board.edit().move_by(-200, 0)
    t.tools.changed = True
    t.save_canvas()
    assert_true(t.cols == 2 and t.view.x < vx, "a page on the left: the view goes with it")
    t.flush()
    assert_equal(grid_of(id), "2x" + String(rows))
    t.close()
    print("   the paper grows and folds back")


def rings() raises:
    """A map whose parents go round in a ring, name themselves or have no id: opens, draws, saves, exports."""
    fresh()
    var s = WebShell(DB, "paper")
    s.create("mindmap", "Ring")
    var id = s.current
    s.flush()
    var o = Database(DB)
    for nodes in ['[{"id":"root","parentId":null,"text":"R","x":0,"y":0},{"id":"a","parentId":"b","text":"A","x":200,"y":0},{"id":"b","parentId":"a","text":"B","x":300,"y":60},{"id":"c","parentId":"c","text":"C","x":0,"y":200},{"text":"no id","x":-200,"y":0},{"id":"d","parentId":"b","text":"D","x":10,"y":10}]']:
        o.exec("UPDATE notes SET content = '{\"schemaVersion\":1,\"rootId\":\"root\",\"nodes\":" + String(nodes) + "}', revision = revision + 1 WHERE id = " + String(id))
    s.close()
    var t = WebShell(DB, "paper")
    t.open(id)
    var sc = Scene(1440, 900, 1.0)
    var t0 = clock_us()
    t.paint(sc, 1440, 900, 1.0)
    assert_true(clock_us() - t0 < 2_000_000, "drawn")
    assert_equal(len(t.map.topics), 6)
    _ = t.key("Tab", 0)
    typed(t, "new")
    _ = t.key("Return", 0)
    t.flush()
    t.export_markdown()
    t.close()
    print("   a ring of ideas")


def main() raises:
    _ = private_dir(CFG)
    _ = setenv("OMX_CONFIG", CFG)
    _ = setenv("OMX_EXPORTS", "build/test_review4_exports")
    two_windows()
    own_warning()
    gone_in_flight()
    new_text()
    locked_file()
    locked_note()
    hands_down()
    paper()
    rings()
    print("review4: ok")
