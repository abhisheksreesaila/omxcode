# What a save builds on (review 6, M1): the whole shell, one or two windows, against another app on the same notes file that adds,
# deletes and puts earlier texts back (ABA). Every word is its own. Two properties, after every step:
#  - nothing of theirs is silently undone: what a write of ours takes out of the row it replaces is what a person deleted here, what
#    it puts in is what was typed here and nobody has deleted since;
#  - no word of ours is lost: typed here, deleted by nobody, it is in a note, held, or in a copy.
#   pixi run mojo build -I . -I vendor -I examples/pnote tests/test_docbase.mojo -o build/test_docbase && build/test_docbase [seeds [first]]
from std.os import setenv, getenv, listdir
from std.sys import argv
from std.testing import assert_true, assert_equal
from mojoui import libc
from mojoui.libc import unlink, rename
from mojoui.files import private_dir
from mojoui.scene import Scene
from mojoui.sqlite import Database
from mojoui.textedit import Pos
from mojoui.docstore import clock_us
from webshell import WebShell

comptime DIR = "build/docbase"
comptime DB = DIR + "/notes.db"


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
        for f in listdir(DIR + "/unsaved"):
            _ = unlink(DIR + "/unsaved/" + String(f))
    except:
        pass


def words_in(text: String) -> List[String]:
    """Words are n<seed>x<number>z (ours) and o… (theirs): found wherever they stand."""
    var out = List[String]()
    var b = text.as_bytes()
    var i = 0
    while i < len(b):
        if b[i] == 110 or b[i] == 111:  # n, o
            var k = i + 1
            while k < len(b) and b[k] >= 48 and b[k] <= 57:
                k += 1
            if k > i + 1 and k < len(b) and b[k] == 120:
                var m = k + 1
                while m < len(b) and b[m] >= 48 and b[m] <= 57:
                    m += 1
                if m > k + 1 and m < len(b) and b[m] == 122:
                    var w = String(text[byte = i : m + 1])
                    if w not in out:
                        out.append(w)
                    i = m
        i += 1
    return out^


struct Row(Copyable, Movable):
    var text: String
    var words: List[String]

    def __init__(out self, text: String):
        self.text = text
        self.words = words_in(text)


struct World(Movable):
    var db: Database
    var last: Dict[Int, Row]  # what each row held when last looked at
    var past: Dict[Int, List[String]]  # texts it has had
    var typed: List[String]  # here, anywhere
    var cut: List[String]  # deleted here
    var gone: List[String]  # and taken out of the row by a write of ours (one on its way when it was deleted may put it there first)
    var theirs_cut: List[String]  # deleted (or put back to a text without it) there
    var seed: Int
    var log: String
    var writes: Int

    def __init__(out self, seed: Int) raises:
        self.db = Database(DB)
        self.last = Dict[Int, Row]()
        self.past = Dict[Int, List[String]]()
        self.typed = List[String]()
        self.cut = List[String]()
        self.gone = List[String]()
        self.theirs_cut = List[String]()
        self.seed = seed
        self.log = ""
        self.writes = 0

    def rows(self) raises -> Dict[Int, String]:
        var out = Dict[Int, String]()
        var db = self.db.copy()
        var q = db.prepare("SELECT id, content FROM notes")
        while q.step():
            out[q.int(0)] = q.text(1)
        return out^

    def observe(mut self, ours: Bool) raises:
        """The rows since last time: changed by us, or (ours off) by the other app just now."""
        var now = self.rows()
        for e in now.items():
            var id = e.key
            if id not in self.last:
                self.last[id] = Row(e.value)
                self.past[id] = [e.value]
                continue
            if self.last[id].text == e.value:
                continue
            var row = Row(e.value)
            var had = self.last[id].words.copy()
            for w in had:
                if w in row.words:
                    continue
                if ours:
                    assert_true(w in self.cut, self.why("a write here took out " + w + " of note " + String(id) + ", which nobody deleted here"))
                    self.gone.append(w)
                elif w not in self.theirs_cut:
                    self.theirs_cut.append(w)
            for w in row.words:
                if w in had:
                    continue
                if ours:
                    assert_true(w in self.typed, self.why("a write here put in " + w + " of note " + String(id) + ", which isn't ours"))
                    assert_true(w not in self.theirs_cut, self.why("a write here put back " + w + " in note " + String(id) + ", which the other app had deleted"))
                    assert_true(w not in self.gone, self.why("a write here put back " + w + " in note " + String(id) + ", which was deleted here"))
                else:
                    for k in range(len(self.theirs_cut) - 1, -1, -1):
                        if self.theirs_cut[k] == w:
                            _ = self.theirs_cut.pop(k)
            if ours:
                self.writes += 1
            self.past[id].append(e.value)
            self.last[id] = row^

    def why(self, what: String) -> String:
        return "seed " + String(self.seed) + ": " + what + "\n" + self.log

    def note(mut self, what: String):
        self.log += "  " + what + "\n"


def held() raises -> String:
    var t = String("")
    for f in listdir(DIR + "/unsaved"):
        if String(f).endswith(".json"):
            with open(DIR + "/unsaved/" + String(f), "r") as h:
                t += h.read()
    return t


def add_word(mut s: WebShell, word: String) raises -> Bool:
    var i = s.note_index(s.current)
    if i < 0 or not s.editable() or s.notes[i].secure:
        return False
    if s.notes[i].kind == "page":
        s.page.caret_end()
        return s.text_in("commit", " " + word)
    s.tools.begin_text(120, 120 + Float64(len(s.board.edit().objs)) * 40)
    var ok = s.text_in("commit", word)
    _ = s.key("Escape", 0)
    return ok


def cut_word(mut s: WebShell, which: Int) raises -> String:
    """One of the words on the screen deleted; "": none."""
    var i = s.note_index(s.current)
    if i < 0 or not s.editable() or s.notes[i].secure:
        return ""
    if s.notes[i].kind == "page":
        var md = s.page.markdown()
        var ws = words_in(md)
        if len(ws) == 0 or len(s.page.ed.paras) != 1:
            return ""
        var w = ws[which % len(ws)]
        var at = s.page.ed.paras[0].find(w)
        if at < 0:
            return ""
        s.page.ed.move_to(Pos(0, at), False)
        s.page.ed.move_to(Pos(0, at + w.byte_length()), True)
        _ = s.key("Delete", 0)
        return w if w not in s.page.markdown() else String("")
    s.tools.set_tool("select", s.board.edit(), s.view, 1440, 900, s.cols, s.rows)
    var ids = List[Int]()
    var names = List[String]()
    for ref o in s.board.edit().objs:
        var ws = words_in(o.text)
        if len(ws) == 1:
            ids.append(o.id)
            names.append(ws[0])
    if len(ids) == 0:
        return ""
    s.board.edit().selected = [ids[which % len(ids)]]
    _ = s.key("Delete", 0)
    for ref o in s.board.edit().objs:
        if o.id == ids[which % len(ids)]:
            return ""
    return names[which % len(ids)]


def let_save(mut s: WebShell):
    var by = clock_us() + 3_000_000
    while (s.saving() or s.saver.pending()) and clock_us() < by:
        s.saver.due_us = min(s.saver.due_us, clock_us())
        _ = s.tick()
        _ = libc.usleep(200)


def theirs(mut w: World, mut r: Rng, n: Int) raises:
    """The other app's save: an addition, a deletion, an earlier text put back, the same text again, its picture names."""
    var ids = List[Int]()
    for e in w.last.items():
        ids.append(e.key)
    if len(ids) == 0:
        return
    var id = ids[r.next(len(ids))]
    w.db.exec("BEGIN IMMEDIATE")
    w.observe(True)  # (what was written since, is ours)
    var text: String
    if id in w.last:
        text = w.last[id].text
    else:
        w.db.exec("COMMIT")
        return
    var page = '"markdown"' in text and '"nodes"' not in text
    var k = r.next(5)
    var sql = String("")
    var what = String("")
    if k == 0:
        var word = "o" + String(w.seed) + "x" + String(n) + "z"
        what = "adds " + word
        if page:
            sql = "json_set(content, '$.markdown', json_extract(content, '$.markdown') || ' " + word + "')"
        else:
            sql = "json_insert(content, '$.nodes[#]', json('{\"id\":\"" + word + "\",\"type\":\"text\",\"x\":40,\"y\":40,\"width\":200,\"height\":40,\"text\":\"" + word + "\",\"pn\":{\"type\":\"text\"}}'))"
    elif k == 1 and len(w.last[id].words) > 0:
        var word = w.last[id].words[r.next(len(w.last[id].words))]
        what = "deletes " + word
        if page:
            sql = "replace(content, ' " + word + "', '')"
        else:
            sql = "json_set(content, '$.nodes', (SELECT json_group_array(json(value)) FROM json_each(content, '$.nodes') WHERE instr(value, '" + word + "') = 0))"
    elif k == 2 or k == 1:
        what = "puts an earlier text back"
        var p = w.past[id].copy()
        var old = p[r.next(len(p))]
        var st = w.db.prepare("UPDATE notes SET revision = revision + 1, content = ? WHERE id = ?")
        st.bind(1, old)
        st.bind(2, id)
        _ = st.step()
        st = w.db.prepare("SELECT 1")
    elif k == 3:
        what = "writes it again"
        sql = "content"
    else:
        what = "puts its picture names in"
        sql = "replace(content, '\"file\":\"\"', '\"file\":\"" + String("0123456789abcdef") * 4 + ".svg\"')"
    if sql != "":
        w.db.exec("UPDATE notes SET revision = revision + 1, content = " + sql + " WHERE id = " + String(id))
    w.db.exec("UPDATE workspace_state SET sequence = sequence + 1 WHERE id = 1; COMMIT")
    w.note("other app " + what + " in note " + String(id))
    w.observe(False)


def run(seed: Int, steps: Int) raises -> Int:
    fresh()
    var r = Rng(seed)
    var w = World(seed)
    var ws = List[WebShell]()
    ws.append(WebShell(DB, "paper"))
    for kind in ["page", "canvas", "canvas"]:
        ws[0].create(String(kind))
        ws[0].flush()
    var sc = Scene(1440, 900, 1.0)
    ws[0].paint(sc, 1440, 900, 1.0)
    var n = 0
    w.observe(True)
    for step in range(steps):
        var k = r.next(100)
        if len(ws) == 0 or (k < 4 and len(ws) < 2):
            ws.append(WebShell(DB, "paper"))
            var s2 = Scene(1440, 900, 1.0)
            ws[len(ws) - 1].paint(s2, 1440, 900, 1.0)
            w.note("a window opens")
            continue
        var i = r.next(len(ws))
        ref s = ws[i]
        var name = "window " + String(i)
        if k < 26:
            n += 1
            var word = "n" + String(seed) + "x" + String(n) + "z"
            w.typed.append(word)  # (before it can be written)
            w.note(name + " types " + word + " in note " + String(s.current))
            if not add_word(s, word):
                _ = w.typed.pop()
        elif k < 36:
            var word = cut_word(s, r.next(7))
            if word != "":
                w.cut.append(word)
                w.note(name + " deletes " + word + " in note " + String(s.current))
        elif k < 43:  # (saves on their way, one behind the other: none waited for)
            for q in range(2):
                n += 1
                var word = "n" + String(seed) + "x" + String(n) + "z"
                w.typed.append(word)
                w.note(name + " types " + word + " in note " + String(s.current) + ", its save on its way")
                if not add_word(s, word):
                    _ = w.typed.pop()
                s.saver.due_us = min(s.saver.due_us, clock_us())
                _ = s.tick()
                if q == 0 and r.next(2) == 0:
                    theirs(w, r, 2000 + step)
        elif k < 52:
            let_save(s)
            w.note(name + " saves: '" + s.save_state + "'")
        elif k < 66:
            s.open(s.notes[r.next(len(s.notes))].id)
            w.note(name + " opens note " + String(s.current))
        elif k < 76:
            var c = s.refresh()
            w.note(name + " reads the feed: " + String(c))
        elif k < 94:
            theirs(w, r, 1000 + step)
        elif k < 96:
            s.retry_save()
            w.note(name + " retries")
        elif k < 98:
            if s.outbox.find(s.current) >= 0 and not s.saving():
                s.save_copy()
                w.note(name + " saves a copy")
        else:
            if s.may_close():
                s.close()
                var gone = ws.pop(i)
                _ = gone^
                w.note(name + " closes")
        w.observe(True)
    while len(ws) > 0:
        assert_true(ws[0].may_close(), w.why("closes"))
        ws[0].close()
        var gone = ws.pop(0)
        _ = gone^
    _ = libc.usleep(20_000)
    w.observe(True)
    var last = WebShell(DB, "paper")  # (the next start opens all of it)
    for q in range(len(last.notes)):
        last.open(last.notes[q].id)
    last.close()
    _ = last^
    w.observe(True)
    var kept = held()
    for e in w.rows().items():
        kept += e.value
    for t in w.typed:
        if t not in w.cut and t not in w.theirs_cut:
            assert_true(t in kept, w.why("the word " + t + " is nowhere"))
    return w.writes


def canvas_word(mut s: WebShell, word: String) raises:
    s.tools.begin_text(200, 200 + Float64(len(s.board.edit().objs)) * 60)
    assert_true(s.text_in("commit", word))
    _ = s.key("Escape", 0)


def row_text(id: Int) raises -> String:
    var db = Database(DB)
    var q = db.prepare("SELECT content FROM notes WHERE id = " + String(id))
    return q.text(0) if q.step() else String("")


def put(id: Int, text: String) raises:
    var o = Database(DB)
    var st = o.prepare("UPDATE notes SET revision = revision + 1, content = ? WHERE id = ?")
    st.bind(1, text)
    st.bind(2, id)
    _ = st.step()
    o.exec("UPDATE workspace_state SET sequence = sequence + 1 WHERE id = 1")


def left_and_back() raises:
    """The reviewer's q1_base: saved, left, come back to (kept parsed), the other app puts the text back as first read: with a
    look at the feed (the addition is gone here too) and without (the next save is a conflict). Never: written back."""
    for leave in [False, True]:
        for feed in [True, False]:
            fresh()
            var s = WebShell(DB, "paper")
            s.create("page", "P")
            var p = s.current
            s.flush()
            s.create("canvas", "C")
            var c = s.current
            canvas_word(s, "first")
            s.flush()
            s.close()
            var t = WebShell(DB, "paper")
            t.open(c)
            var sc = Scene(1440, 900, 1.0)
            t.paint(sc, 1440, 900, 1.0)
            _ = t.refresh()
            var before = row_text(c)
            canvas_word(t, "SECOND")
            let_save(t)
            assert_true("SECOND" in row_text(c))
            if leave:
                t.open(p)
                t.open(c)
                _ = t.key("Escape", 0)  # (it opens for writing: a note being written on isn't read again, its save meets the conflict)
            assert_true(t.doc.base.text == row_text(c), "what it builds on is the row, also left and come back to")
            put(c, before)
            if feed:
                _ = t.refresh()
                for ref o in t.board.edit().objs:
                    assert_true(o.text != "SECOND", "their deletion shows here")
            canvas_word(t, "third")
            let_save(t)
            var now = row_text(c)
            assert_true("SECOND" not in now, "their deletion stays (leave " + String(leave) + ", feed " + String(feed) + "): " + now)
            if feed:
                assert_true("third" in now and t.save_state == "", "and ours is saved")
            else:
                assert_true("third" not in now and "third" in held() and t.save_state != "", "a conflict, said and held")
            t.close()
    print("   left and back, their deletion stays")


def other_files() raises:
    """(review 6, SHOULD 1) Held edits are of one notes file: another put in its place isn't given them; moved, it has them."""
    fresh()
    var s = WebShell(DB, "paper")
    s.create("page", "P")
    var p = s.current
    _ = s.text_in("commit", "base")
    s.flush()
    put(p, row_text(p).replace("base", "theirs"))
    _ = s.text_in("commit", " heldwords")
    let_save(s)
    assert_true("heldwords" in held() and s.save_state != "")
    s.close()
    _ = s^
    for x in ["", "-wal", "-shm"]:
        _ = unlink(DIR + "/moved.db" + String(x))
        _ = rename(String(DB) + String(x), DIR + "/moved.db" + String(x))
    var other = WebShell(DB, "paper")  # (another file at the old place, with a note of the same number and revision)
    other.create("page", "Q")
    _ = other.text_in("commit", "its own")
    other.flush()
    assert_true(len(other.outbox.items) == 0, "not given to another file")
    other.open(other.notes[0].id)
    assert_true("heldwords" not in other.page.markdown() and "heldwords" in held())
    other.close()
    _ = other^
    var moved = WebShell(DIR + "/moved.db", "paper")
    assert_true(len(moved.outbox.items) == 1 and "heldwords" in moved.outbox.items[0].content, "the moved file has them")
    moved.open(p)
    assert_true("heldwords" in moved.page.markdown() and moved.save_state != "")
    moved.close()
    _ = moved^
    # a copy that went its own way: the revision is only the same number
    fresh()
    var a = WebShell(DB, "paper")
    a.create("page", "P")
    p = a.current
    _ = a.text_in("commit", "base")
    a.flush()
    var lock = Database(DB, busy_ms=20)
    lock.exec("BEGIN IMMEDIATE")
    _ = a.text_in("commit", " heldwords")
    a.flush()
    lock.exec("ROLLBACK")
    assert_true("heldwords" in held(), "held: the file was locked")
    _ = a^
    var o = Database(DB)
    var st = o.prepare("UPDATE notes SET content = replace(content, 'base', 'another') WHERE id = ?")  # (the same revision)
    st.bind(1, p)
    _ = st.step()
    var b = WebShell(DB, "paper")
    b.open(p)
    assert_true("heldwords" in b.page.markdown() and b.save_state != "")
    b.retry_save()
    assert_true("another" in row_text(p) and "heldwords" not in row_text(p) and "heldwords" in held(), "held, not written over the other's words")
    b.close()
    print("   held edits: not another file's, the moved one's, not over a copy's own words")


def main() raises:
    _ = private_dir(DIR)
    _ = setenv("OMX_CONFIG", DIR)
    if getenv("DOCBASE_MODEL_ONLY") != "1":
        left_and_back()
        other_files()
    var args = argv()
    var seeds = Int(String(args[1])) if len(args) > 1 else 40
    var first = Int(String(args[2])) if len(args) > 2 else 1
    var writes = 0
    for seed in range(first, first + seeds):
        writes += run(seed, 120)
    print("   ", seeds, "seeds,", writes, "writes of ours, each explained")
    print("docbase: ok")
