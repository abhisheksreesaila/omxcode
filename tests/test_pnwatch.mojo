# pnote's live updates (goal 82 M7), no window: another writer (an agent's own SQLite connection, as the web's CLI is) changes
# the notes file; pnote hears it by a file event (mojoui.filewatch), not a poll, and shows it within 300 ms. A deletion there,
# under edits here not saved yet, stays a deletion: the save meets the other's and merges (mojoui.merge3); edits that touch the
# very object the other changed or deleted are held as a conflict (said), and nothing of theirs is written over.
#   pixi run mojo build -I . -I vendor -I examples/pnote tests/test_pnwatch.mojo -o build/test_pnwatch && build/test_pnwatch
from std.os import setenv, listdir
from std.testing import assert_true, assert_equal
from mojoui import libc
from mojoui.libc import unlink
from mojoui.files import private_dir
from mojoui.sqlite import Database
from mojoui.docstore import clock_us
from mojoui.clock import now_ns
from mojoui.objectlayer import TEXT
from webshell import WebShell

comptime DB = "build/test_pnwatch.db"
comptime CFG = "build/test_pnwatch_cfg"


def fresh() raises:
    for x in ["", "-wal", "-shm"]:
        _ = unlink(String(DB) + String(x))
    try:
        for f in listdir(String(CFG) + "/unsaved"):
            _ = unlink(String(CFG) + "/unsaved/" + String(f))
    except:
        pass


def held() raises -> Int:
    var n = 0
    try:
        for f in listdir(String(CFG) + "/unsaved"):
            if String(f).endswith(".json"):
                n += 1
    except:
        pass
    return n


def row(id: Int) raises -> String:
    var db = Database(DB)
    var q = db.prepare("SELECT content FROM notes WHERE id = ?")
    q.bind(1, id)
    return q.text(0) if q.step() else String("")


def other(sql: String, id: Int) raises:
    """Another writer's change of note `id`, as the web's API makes one: the row, its revision, the change feed, one
    transaction."""
    var db = Database(DB)
    db.exec("BEGIN IMMEDIATE")
    var q = db.prepare(sql)
    q.bind(1, id)
    _ = q.step()
    db.exec("UPDATE notes SET revision = revision + 1 WHERE id = " + String(id))
    db.exec("UPDATE workspace_state SET sequence = sequence + 1 WHERE id = 1; COMMIT")


def settle(mut s: WebShell, ms: Int = 12_000):
    var by = clock_us() + ms * 1000
    while (s.saving() or s.saver.pending()) and clock_us() < by:
        s.saver.due_us = min(s.saver.due_us, clock_us())
        _ = s.tick()
        _ = libc.usleep(300)


def heard(mut s: WebShell, before: Int, ms: Int = 1000) -> Int:
    """µs until the watcher saw a write after `before` (-1: not within ms)."""
    var t0 = now_ns()
    while now_ns() - t0 < ms * 1_000_000:
        if s.watch.count() > before:
            return (now_ns() - t0) // 1000
        _ = libc.usleep(200)
    return -1


def canvas_words(mut s: WebShell) -> List[String]:
    var out = List[String]()
    for ref o in s.board.layer.objs:
        if o.kind == TEXT:
            out.append(String(o.text.strip()))
    return out^


def new_text(mut s: WebShell, x: Float64, y: Float64, word: String):
    _ = s.key("Escape", 0)
    s.tools.begin_text(x, y)
    _ = s.text_in("commit", word)
    _ = s.key("Escape", 0)


def wait_watch(mut s: WebShell) raises:
    var t = now_ns()
    while not s.watch.ready() and now_ns() - t < 2_000_000_000:
        _ = libc.usleep(1000)
    assert_true(s.watch.ready(), "the notes file is watched: " + s.watch.why())


def shown_fast() raises -> Int:
    """pnote idle on a canvas; another writer renames a note and adds words to the open canvas: the write is heard by a file
    event and the screen has it within 300 ms (no tick asked for it). The worst µs."""
    var s = WebShell(DB, "paper")
    wait_watch(s)
    s.create("canvas", "Board")
    var id = s.current
    new_text(s, 120, 120, "alpha")
    settle(s)
    _ = libc.usleep(100_000)
    _ = s.file_event()  # (our own saves' events, read: nothing changes)
    var worst = 0
    for k in range(5):
        var before = s.watch.count()
        var t0 = now_ns()
        var word = String("agent") + String(k)
        other("UPDATE notes SET content = json_insert(content, '$.nodes[#]', json_object('id', 'ag" + String(k) + "', 'type', 'text', 'text', '" + word + "', 'x', 300, 'y', " + String(100 + 60 * k) + ", 'width', 200, 'height', 50)) WHERE id = ?", id)
        assert_true(heard(s, before) >= 0, "heard")
        var shown = s.file_event()
        var us = (now_ns() - t0) // 1000
        assert_true(shown and word in canvas_words(s), "the agent's words on the screen: " + String(len(canvas_words(s))))
        worst = max(worst, us)
        _ = libc.usleep(50_000)
    s.close()
    print("   another writer's change on the screen within " + String(worst) + " us (worst of 5)", flush=True)
    return worst


def deletion_stays() raises:
    """Under words typed here and not saved yet, another writer deletes an object of the open canvas: the save meets theirs,
    merges, and the object is gone from the file and, once read again, from the screen; nothing typed here is lost."""
    var s = WebShell(DB, "paper")
    wait_watch(s)
    s.create("canvas", "Deletions")
    var id = s.current
    new_text(s, 120, 120, "alpha")
    new_text(s, 120, 220, "beta")
    new_text(s, 120, 320, "gamma")
    settle(s)
    assert_true(row(id).find("alpha") >= 0 and row(id).find("gamma") >= 0, "three texts in the file")
    new_text(s, 400, 120, "mine1")  # (not saved yet)
    assert_true(s.saver.pending(), "unsaved here")
    other("UPDATE notes SET content = json_remove(content, (SELECT '$.nodes[' || key || ']' FROM json_each(content, '$.nodes') WHERE json_extract(value, '$.text') LIKE '%beta%')) WHERE id = ?", id)
    assert_true(row(id).find("beta") < 0, "deleted there")
    _ = s.file_event()  # (heard while words wait here: the save comes first)
    settle(s)
    var r = row(id)
    assert_true(r.find("beta") < 0, "the deletion stays: " + r)
    assert_true(r.find("mine1") >= 0 and r.find("alpha") >= 0 and r.find("gamma") >= 0, "nothing typed here lost: " + r)
    assert_true(s.save_state == "" and held() == 0, "merged, not held: " + s.save_state + " " + s.save_detail)
    var t = now_ns()
    while now_ns() - t < 1_000_000_000 and "beta" in canvas_words(s):
        _ = s.tick()
        _ = s.file_event()
        _ = libc.usleep(2000)
    var w = canvas_words(s)
    assert_true("beta" not in w and "mine1" in w and "alpha" in w, "the screen read again: the deletion shown, the words kept")
    # typed again afterwards: still no beta
    new_text(s, 400, 220, "mine2")
    settle(s)
    r = row(id)
    assert_true(r.find("beta") < 0 and r.find("mine2") >= 0 and r.find("mine1") >= 0, "and after the next edit: " + r)
    # overlap: the other changes alpha's words, this window changes them too before its save: held, said; theirs stays
    _ = s.file_event()
    other("UPDATE notes SET content = (SELECT json_set(content, '$.nodes[' || key || '].text', 'alpha-theirs') FROM json_each(content, '$.nodes') WHERE json_extract(value, '$.text') LIKE '%alpha%') WHERE id = ?", id)
    var a = -1
    for ref o in s.board.edit().objs:
        if o.kind == TEXT and String(o.text.strip()) == "alpha":
            a = o.id
    assert_true(a >= 0, "alpha on the screen")
    s.tools.begin_words(s.board.edit(), a)
    _ = s.text_in("commit", " mine")
    _ = s.key("Escape", 0)
    settle(s)
    r = row(id)
    assert_true(r.find("alpha-theirs") >= 0 and r.find("alpha mine") < 0, "theirs isn't written over: " + r)
    assert_true(s.save_state != "" and held() >= 1, "held as a conflict and said")
    s.close()
    print("   a deletion elsewhere stays deleted under unsaved edits (merged); an overlap is held and said", flush=True)


def map_deletion() raises:
    """The same on a mind map: an idea deleted there, one added here before the save: merged, the deleted one stays gone."""
    var s = WebShell(DB, "paper")
    wait_watch(s)
    s.create("mindmap", "Mapped")
    var id = s.current
    for word in ["north", "south"]:
        _ = s.key("Tab", 0)
        for c in String(word).codepoint_slices():
            _ = s.key(String(c), 0)
        _ = s.key("Enter", 0)
    settle(s)
    assert_true(row(id).find("north") >= 0 and row(id).find("south") >= 0, "two ideas in the file: " + row(id))
    _ = s.key("Tab", 0)
    for c in String("east").codepoint_slices():
        _ = s.key(String(c), 0)
    _ = s.key("Enter", 0)
    other("UPDATE notes SET content = json_remove(content, (SELECT '$.nodes[' || key || ']' FROM json_each(content, '$.nodes') WHERE json_extract(value, '$.text') = 'north')) WHERE id = ?", id)
    settle(s)
    var r = row(id)
    assert_true(r.find("north") < 0 and r.find("east") >= 0 and r.find("south") >= 0, "the map: deleted stays deleted, added is kept: " + r)
    s.close()
    print("   a mind map: the same", flush=True)


def main() raises:
    _ = private_dir(CFG)
    _ = setenv("OMX_CONFIG", CFG)
    fresh()
    var worst = shown_fast()
    print("FACT pnwatch_shown_worst_ms " + String(Float64(worst) / 1000.0), flush=True)
    assert_true(worst <= 300_000, "within 300 ms")
    deletion_stays()
    map_deletion()
    print("pnwatch: ok", flush=True)
