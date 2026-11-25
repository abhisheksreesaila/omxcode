# No word a person typed is lost (review 5): the whole shell against a simple model. Several windows on one notes file, pages,
# canvases and maps; words typed (each one its own), notes switched, made, deleted and undone, the file locked by another program,
# another app's saves (the web's echo, its picture names, a real change, a deletion), windows killed at any moment or closed. The
# property: a word typed more than one save's delay and a tick before the kill is, at the end, in a note, in a held file, or was
# offered as a copy (a note of its own); a word in a window that closes is always. Then the next start can open everything.
#   pixi run mojo build -I . -I vendor -I examples/pnote tests/test_wordsafe.mojo -o build/test_wordsafe && build/test_wordsafe [seeds [the first one]]
from std.os import setenv, getenv, listdir
from std.sys import argv
from std.testing import assert_true, assert_equal
from mojoui import libc
from mojoui.libc import unlink
from mojoui.files import private_dir
from mojoui.sqlite import Database
from mojoui.docstore import clock_us
from mojoui.canvassource import undecorated
from webshell import WebShell

comptime DB = "wordsafe/notes.db"  # (under the folder it is run in: several at once)
comptime CFG = "wordsafe"


struct Rng:
    var s: UInt64

    def __init__(out self, seed: Int):
        self.s = UInt64(seed) * 2654435761 + 88172645463325252

    def next(mut self, n: Int) -> Int:
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return Int((self.s >> 11) % UInt64(n))


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


def in_file() raises -> String:
    var db = Database(DB)
    var q = db.prepare("SELECT content FROM notes")
    var t = String("")
    while q.step():
        t += q.text(0) + "\n"
    return t


def settle(mut s: WebShell, ms: Int = 12_000):
    var by = clock_us() + ms * 1000
    while (s.saving() or s.saver.pending()) and clock_us() < by:
        s.saver.due_us = min(s.saver.due_us, clock_us())
        _ = s.tick()
        _ = libc.usleep(300)


def type_word(mut s: WebShell, word: String) raises -> Bool:
    """A word at the end of what is open; False when it can't be written on."""
    var i = s.note_index(s.current)
    if i < 0 or not s.editable() or s.notes[i].secure:
        return False
    var kind = s.notes[i].kind
    if kind == "page":
        s.page.caret_end()
        return s.text_in("commit", " " + word)
    if kind == "canvas":
        if s.tools.editing == -1:
            if len(s.board.edit().objs) == 0 or word.byte_length() % 2 == 0:
                s.tools.begin_text(120, 120 + Float64(len(s.board.edit().objs)) * 40)
            else:
                var t = -1
                for k in range(len(s.board.edit().objs)):
                    if s.board.edit().objs[k].kind == 1:
                        t = s.board.edit().objs[k].id
                if t < 0:
                    s.tools.begin_text(120, 120)
                else:
                    s.tools.begin_words(s.board.edit(), t)
        return s.text_in("commit", " " + word)
    if kind == "mindmap":
        _ = s.key("Tab", 0)
        for c in word.codepoint_slices():
            _ = s.key(String(c), 0)
        _ = s.key("Enter", 0)
        return True
    return False


struct Win(Movable):
    var shell: WebShell
    var typed: List[String]  # words, since the last time this window had saved everything it had

    def __init__(out self):
        self.shell = WebShell(DB, "paper")
        self.typed = List[String]()


def let_save(mut w: Win):
    """A save's delay and a tick: what was typed is written, held, spilled or on its thread (and spilled after a moment)."""
    for _ in range(3):
        w.shell.saver.due_us = min(w.shell.saver.due_us, clock_us())
        _ = w.shell.tick()
        _ = libc.usleep(400)
    if w.shell.saving():  # (a file that stays locked: the waiting ones reach the disk after 0.3 s, the thread's after 0.1)
        var by = clock_us() + 450_000
        while w.shell.saving() and clock_us() < by:
            _ = w.shell.tick()
            _ = libc.usleep(2000)


def run(seed: Int) raises -> Int:
    var trace = getenv("WORDSAFE_TRACE") == "1"
    fresh()
    var r = Rng(seed)
    var ws = List[Win]()
    var all = List[String]()  # words promised
    var lock = List[Database]()
    var n = 0
    var other = Database(DB)
    for step in range(70):
        var k = r.next(100)
        if trace:
            print("step", step, "k", k, "windows", len(ws), "locked", len(lock), "promised", len(all), flush=True)
        if len(ws) == 0 or (k < 8 and len(ws) < 3):
            if len(lock) > 0:
                lock[0].exec("ROLLBACK")
                lock.clear()
            ws.append(Win())
            if len(ws[len(ws) - 1].shell.notes) < 3:
                ws[len(ws) - 1].shell.create(String("page") if r.next(2) == 0 else (String("canvas") if r.next(2) == 0 else String("mindmap")))
            continue
        var i = r.next(len(ws))
        if len(ws[i].shell.notes) == 0:  # (every note deleted elsewhere)
            ws[i].shell.create("page")
            continue
        if k < 45:
            n += 1
            var word = "w" + String(seed) + "x" + String(n) + "z"
            if type_word(ws[i].shell, word):
                ws[i].typed.append(word)
                if trace:
                    print("  typed", word, "in note", ws[i].shell.current, "window", i, flush=True)
            if r.next(2) == 0:
                let_save(ws[i])
                for t in ws[i].typed:
                    all.append(t)
                ws[i].typed.clear()
        elif k < 55:
            ref s = ws[i].shell
            s.open(s.notes[r.next(len(s.notes))].id)
            if trace:
                print("  window", i, "opens", s.current, flush=True)
        elif k < 60:
            ws[i].shell.create(String("page") if r.next(2) == 0 else (String("canvas") if r.next(2) == 0 else String("mindmap")))
        elif k < 63 and len(ws[i].shell.notes) > 1:
            ws[i].shell.delete_note()
            ws[i].shell.undo_delete()
        elif k < 70:
            _ = ws[i].shell.refresh()
        elif k < 77:
            if len(lock) == 0:
                try:
                    lock.append(Database(DB, busy_ms=20))
                    lock[0].exec("BEGIN IMMEDIATE")
                except:
                    lock.clear()
            else:
                lock[0].exec("ROLLBACK")
                lock.clear()
        elif k < 86 and len(lock) == 0:
            # another app: the web's echo, or a real change (its own word, which must stay too)
            ref s = ws[i].shell
            var id = s.notes[r.next(len(s.notes))].id
            try:
                if r.next(2) == 0:
                    other.exec("UPDATE notes SET revision = revision + 1 WHERE id = " + String(id) + "; UPDATE workspace_state SET sequence = sequence + 1 WHERE id = 1")
                else:
                    n += 1
                    var word = "o" + String(seed) + "x" + String(n) + "z"
                    other.exec("UPDATE notes SET revision = revision + 1, content = json_set(content, '$." + word + "', 1) WHERE id = " + String(id)
                               + "; UPDATE workspace_state SET sequence = sequence + 1 WHERE id = 1")
                    if word in in_file():  # (the note may be gone in the file)
                        all.append(word)
                    if trace:
                        print("  another app's", word, "in note", id, flush=True)
            except:
                pass
        elif k < 90 and len(lock) == 0:
            ref s = ws[i].shell
            var id = s.notes[r.next(len(s.notes))].id  # (deleted in another app; its words there are its to delete: only what isn't in the file is ours to keep)
            try:
                other.exec("BEGIN IMMEDIATE")  # (what is deleted is what was read)
                var q = other.prepare("SELECT content FROM notes WHERE id = " + String(id))
                var text = q.text(0) if q.step() else String("")
                q = other.prepare("SELECT 1")
                other.exec("DELETE FROM note_search WHERE note_id = " + String(id) + "; DELETE FROM notes WHERE id = " + String(id)
                           + "; UPDATE workspace_state SET sequence = sequence + 1 WHERE id = 1; COMMIT")
                if trace:
                    print("  deleted elsewhere: note", id, "its words", text[byte=0:min(200, text.byte_length())], flush=True)
                for t in range(len(all) - 1, -1, -1):
                    if all[t] in text:
                        _ = all.pop(t)
                for q2 in range(len(ws)):
                    for t in range(len(ws[q2].typed) - 1, -1, -1):
                        if ws[q2].typed[t] in text:
                            _ = ws[q2].typed.pop(t)
            except:
                try:
                    other.exec("ROLLBACK")
                except:
                    pass
        elif k < 94:
            if trace:
                print("  kill window", i, "with unpromised", len(ws[i].typed), "current", ws[i].shell.current, flush=True)
            # killed, now: what was promised is on disk; the rest of its words may be
            var w = ws.pop(i)
            _ = w^
        else:
            if len(lock) > 0 and r.next(2) == 0:
                lock[0].exec("ROLLBACK")
                lock.clear()
            if ws[i].shell.may_close():
                for t in ws[i].typed:
                    all.append(t)
                ws[i].shell.close()
                var w = ws.pop(i)
                _ = w^
    if len(lock) > 0:
        lock[0].exec("ROLLBACK")
        lock.clear()
    while len(ws) > 0:
        assert_true(ws[0].shell.may_close(), "seed " + String(seed) + ": closes")
        for t in ws[0].typed:
            all.append(t)
        ws[0].shell.close()
        var w = ws.pop(0)
        _ = w^
    _ = libc.usleep(20_000)
    var kept = in_file() + held()
    for t in all:
        assert_true(t in kept, "seed " + String(seed) + ": the word " + t + " is nowhere")
    # the next start opens everything, and nothing goes missing in it
    var last = WebShell(DB, "paper")
    for q in range(len(last.notes)):
        last.open(last.notes[q].id)
    last.close()
    _ = last^
    kept = in_file() + held()
    for t in all:
        assert_true(t in kept, "seed " + String(seed) + ": the word " + t + " went missing at the next start")
    return len(all)


def echoes() raises:
    """(review 5, SHOULD 1) The web open on the same canvas writes every save of ours again: not a conflict."""
    fresh()
    var hexes = String("0123456789abcdef") * 4
    var dec = '{"nodes":[{"id":"a","type":"file","x":1,"y":2,"width":3,"height":4,"file":"' + hexes + '.svg","pn":{"type":"ink","geometry":{}}},{"id":"b","type":"file","x":1,"y":2,"width":3,"height":4,"file":"' + hexes + '.svg","pn":{"type":"image"}}],"edges":[]}'
    var plain = undecorated(dec)
    assert_true('"file":"","pn":{"type":"ink"' in plain and hexes + '.svg","pn":{"type":"image"' in plain, "an image's own file stays: " + plain)
    assert_equal(undecorated(plain), plain)
    var s = WebShell(DB, "paper")
    s.create("canvas", "Board")
    var id = s.current
    s.flush()
    _ = s.refresh()
    var o = Database(DB)
    for k in range(6):
        assert_true(type_word(s, "word" + String(k)))
        _ = s.key("Escape", 0)
        s.saver.due_us = clock_us() - 1
        _ = s.tick()
        settle(s)
        assert_equal(s.save_state, "", "saved")
        if k % 2 == 0:  # (byte for byte again)
            o.exec("UPDATE notes SET revision = revision + 1 WHERE id = " + String(id) + "; UPDATE workspace_state SET sequence = sequence + 1 WHERE id = 1")
        if k == 3:
            var c = s.board.edit().can_undo()
            _ = s.refresh()
            assert_true(s.board.edit().can_undo() == c and c, "the feed: not opened again, its undo stays")
    assert_true("word5" in in_file() and s.outbox.find(id) < 0, "all in the file")
    # the web's picture names
    s.tools.set_tool("pen", s.board.edit(), s.view, 1440, 900, s.cols, s.rows)
    _ = s.press(600, 400)
    for k in range(12):
        _ = s.pan(600 + Float64(k) * 9, 400 + Float64(k % 3))
    _ = s.release(700, 400)
    settle(s)
    o.exec("UPDATE notes SET revision = revision + 1, content = replace(content, '\"file\":\"\"', '\"file\":\"" + hexes + ".svg\"') WHERE id = " + String(id) + "; UPDATE workspace_state SET sequence = sequence + 1 WHERE id = 1")
    assert_true(type_word(s, "afterink"))
    _ = s.key("Escape", 0)
    settle(s)
    assert_true(s.save_state == "" and "afterink" in in_file(), "its picture names aren't a clash: " + s.save_state)
    # a word of the web's is
    o.exec("UPDATE notes SET revision = revision + 1, content = json_set(content, '$.theirs', 1) WHERE id = " + String(id))
    assert_true(type_word(s, "clash"))
    _ = s.key("Escape", 0)
    settle(s)
    assert_true(s.save_state != "" and "clash" in held() and "theirs" in in_file(), "a real clash is held, theirs stays")
    s.close()
    print("   the web's echo, its picture names, a real clash")


def main() raises:
    _ = private_dir(CFG)
    _ = setenv("OMX_CONFIG", CFG)
    echoes()
    var args = argv()
    var seeds = Int(String(args[1])) if len(args) > 1 else 25
    var words = 0
    var first = Int(String(args[2])) if len(args) > 2 else 1
    for seed in range(first, first + seeds):
        words += run(seed)
    print("   ", seeds, "seeds,", words, "words promised, none lost")
    print("wordsafe: ok")
