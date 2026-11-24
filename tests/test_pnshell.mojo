# Review 3 in the app itself (pnote's WebShell, no window, scratch databases in Personal Note's schema): two canvases switched
# show their own objects; a note that can't be read (a job that fails, broken content, another format, a locked database, a
# vanished row) shows its problem and a Retry, takes no edit, writes nothing, isn't kept; the search field with é; a canvas
# with kinds this app can't draw keeps them through an edit; a save that fails or meets a conflict is held through a switch
# and a restart and lands on Retry; kept views' folders and names; secure notes. pnshell: ok
from std.os import stat, listdir, getenv, setenv
from std.testing import assert_true, assert_equal
from std.time import sleep
from mojoui.libc import unlink
from mojoui.files import private_dir
from mojoui.scene import Scene
from mojoui.sqlite import Database
from mojoui.json import Json
from mojoui.canvasload import SqlText
from mojoui.canvasload import text_hash
from mojoui.viewsnap import SnapWriter, SnapKey, renderer_id, set_renderer_id
from mojoui.pagedesk import opening_view, PAGE_W, PAGE_H, snap_px
from webshell import WebShell


def canvas(n: Int, word: String) -> String:
    var s = String('{"nodes":[')
    for i in range(n):
        s += ("," if i > 0 else "") + '{"id":"n' + String(i) + '","type":"text","x":' + String(40 + (i % 4) * 260) + ',"y":' + String(40 + (i // 4) * 160) + ',"width":200,"height":80,"text":"' + word + " " + String(i) + '"}'
    return s + '],"edges":[],"pn":{"schemaVersion":1,"page":{"columns":1,"rows":1}}}'


comptime ODD = '{"nodes":[{"id":"a","type":"text","x":100,"y":100,"width":200,"height":80,"text":"hi"},{"id":"img","type":"file","file":"pics/cat.png","x":400,"y":100,"width":300,"height":200,"pn":{"type":"image","geometry":{"x":400.5,"y":100,"width":300,"height":200},"style":{"opacity":0.5}}},{"id":"l","type":"link","url":"https://example.org","x":100,"y":400,"width":200,"height":100}],"edges":[{"id":"e1","fromNode":"a","toNode":"img","label":"uses","fromSide":"right","toSide":"left"}],"pn":{"page":{"columns":2,"rows":1,"paper":"dots"},"future":{"keep":"me"}},"other":"top level"}'
comptime MAP = '{"version":1,"title":"M","rootId":"root","nodes":[{"id":"root","parentId":null,"text":"Book","x":0,"y":0,"color":"#3d8fe8","due":"2026-12-01"}],"keep":[1]}'
comptime PAGE = '{"version":1,"markdown":"one\\ntwo","ink":{"marks":[{"id":"w"}],"drawings":[]},"keep":2}'


def make(path: String) raises:
    _ = unlink(path)
    var db = Database(path)
    db.exec("CREATE TABLE notes(id INTEGER PRIMARY KEY,resource_id TEXT,revision INTEGER NOT NULL DEFAULT 1,note_type TEXT,content_format TEXT DEFAULT '',title TEXT,content TEXT,page_state TEXT DEFAULT '{}',created_at TEXT DEFAULT '2026-11-01 00:00:00',updated_at TEXT DEFAULT '2026-11-01 00:00:00',notebook_id INTEGER,secure INTEGER DEFAULT 0,icon TEXT DEFAULT '',icon_tint INTEGER DEFAULT 0)")
    db.exec("CREATE TABLE notebooks(id INTEGER PRIMARY KEY,name TEXT,color TEXT,category TEXT,updated_at TEXT)")
    db.exec("CREATE TABLE workspace_state(id INTEGER PRIMARY KEY, sequence INTEGER, updated_at TEXT)")
    db.exec("INSERT INTO workspace_state VALUES(1,0,'')")
    db.exec("CREATE TABLE workspace_changes(sequence INTEGER, resource_kind TEXT, resource_id TEXT, revision INTEGER, change_type TEXT)")
    db.exec("CREATE TABLE note_search(note_id INTEGER,title TEXT,body TEXT)")
    db.exec("CREATE TABLE mindmap_reminders(note_id INTEGER,node_id TEXT,label TEXT,due TEXT)")
    var rows: List[Tuple[String, String, String]] = [("Canvas A", "canvas", canvas(5, "AAA")), ("Canvas B", "canvas", canvas(5, "BEE")), ("Canvas C", "canvas", canvas(9, "SEE")), ("Odd", "canvas", String(ODD)),
                                                     ("Page", "page", String(PAGE)), ("Map", "mindmap", String(MAP)), ("Broken canvas", "canvas", "{\"nodes\":["), ("Fabric", "canvas", "{\"objects\":[]}"),
                                                     ("Broken page", "page", "{\"nope\":1}"), ("Broken map", "mindmap", "[]"), ("Empty canvas", "canvas", ""), ("Strange", "spreadsheet", "{}")]
    for r in range(len(rows)):
        var st = db.prepare("INSERT INTO notes(id,resource_id,note_type,title,content) VALUES(?,?,?,?,?)")
        st.bind(1, r + 1)
        st.bind(2, "r" + String(r + 1))
        st.bind(3, rows[r][1])
        st.bind(4, rows[r][0])
        st.bind(5, rows[r][2])
        _ = st.step()


def row(path: String, id: Int) raises -> Tuple[Int, String]:
    var db = Database(path)
    var q = db.prepare("SELECT revision, content FROM notes WHERE id = ?")
    q.bind(1, id)
    assert_true(q.step(), "row")
    return (q.int(0), q.text(1))


def paint(mut s: WebShell, n: Int = 4) raises -> Scene:
    var sc = Scene(1440, 900, 1.0)
    for _ in range(n):
        sc = Scene(1440, 900, 1.0)
        s.paint(sc, 1440, 900, 1.0)
        sleep(0.002)
    return sc^


def words(sc: Scene, layer: String = "") -> String:
    var out = String("")
    for i in range(sc.layers()):
        if layer == "" or sc.layer_keys[i] == layer:
            var span = sc.layer_range(i)
            for op in range(span[0], span[1]):
                if Int(sc.text_of[op]) >= 0:
                    out += String(sc.texts[Int(sc.text_of[op])]) + "|"
    return out


def switches(path: String) raises:
    var s = WebShell(path, "paper")
    for id in [1, 2, 3, 1, 2]:
        s.open(id)
        var w = words(paint(s, 6), "board")
        var mine = ["AAA", "BEE", "SEE"][id - 1]
        for other in ["AAA", "BEE", "SEE"]:
            assert_true((w.find(String(other)) >= 0) == (String(other) == mine), "note " + String(id) + " shows its own: " + w)
    print("   switches: own objects")


def box(s: WebShell, name: String) raises -> Tuple[Float64, Float64]:
    for i in range(len(s.boxes.names) - 1, -1, -1):
        if s.boxes.names[i] == name:
            return (s.boxes.r[4 * i], s.boxes.r[4 * i + 1])
    raise Error("no box " + name)


def poke(mut s: WebShell) raises:
    """Everything a person might do to a note's body."""
    for k in ["a", "é", "Enter", "Backspace", "Delete", "Tab", "F2", "v", "t", "z"]:
        _ = s.key(String(k), 0)
    _ = s.key("z", 2)
    _ = s.key("Escape", 0)
    for tool in ["[Sticky note]", "[Text]", "[Pen]", "[Select]"]:
        s.tools.tool = "sticky" if String(tool) == "[Sticky note]" else ("text" if String(tool) == "[Text]" else ("pen" if String(tool) == "[Pen]" else "select"))
        _ = s.press(500, 400)
        _ = s.pan(540, 420)
        _ = s.release(540, 420)
        _ = s.tap(500, 400)
        _ = s.key("x", 0)
        _ = s.key("Escape", 0)
    _ = s.text_in("commit", "pasted words")
    s.save_map()
    s.save_page()
    s.queue_save("canvas")
    s.flush()


def failures(path: String) raises:
    for id in [7, 8, 9, 10, 11, 12]:
        var before = row(path, id)
        var s = WebShell(path, "paper")
        s.open(id)
        var w = words(paint(s))
        assert_true(s.doc.is_failed(), "note " + String(id) + " failed")
        assert_true(w.find("couldn’t be opened") >= 0 and w.find("Retry") >= 0, "it says so: " + String(id))
        poke(s)
        s.open(1)
        s.open(id)
        poke(s)
        s.flush()
        var after = row(path, id)
        assert_true(before[0] == after[0] and before[1] == after[1], "note " + String(id) + ": nothing written")
        assert_equal(s.kept.find(id, before[0]), -1, "not kept")
    # a deferred open's job fails (the reviewer's probe)
    var s = WebShell(path, "paper")
    s.open(1)
    _ = paint(s)
    var before = row(path, 1)
    s.doc.begin(1)
    s.board.open_later(SqlText(path, "SELECT content FROM notes WHERE id = ? AND secure = 0", 999), 0, 0, 1440, 900, 6)
    for _ in range(100):
        _ = paint(s, 1)
        if s.doc.is_failed():
            break
    assert_true(s.doc.is_failed(), "the job's failure")
    poke(s)
    var after = row(path, 1)
    assert_true(before[0] == after[0] and before[1] == after[1], "nothing written over a note whose open failed")
    _ = paint(s)
    var hit = box(s, "#open-retry")
    assert_true(s.tap(hit[0] + 5, hit[1] + 5), "Retry")
    assert_true(words(paint(s, 6), "board").find("AAA 3") >= 0 and s.doc.may_edit(), "Retry opens it")
    # edits made before a deferred open has landed (and then fails): refused
    s.doc.begin(1)
    s.board.open_later(SqlText(path, "SELECT content FROM notes WHERE id = ? AND secure = 0", 999), 0, 0, 1440, 900, 6)
    poke(s)
    after = row(path, 1)
    assert_true(before[0] == after[0] and before[1] == after[1], "nor before it had landed")
    # a row that vanished
    var db = Database(path)
    db.exec("INSERT INTO notes(id,note_type,title,content) VALUES(50,'page','Gone','{\"markdown\":\"x\"}')")
    var g = WebShell(path, "paper")
    db.exec("DELETE FROM notes WHERE id = 50")
    g.open(50)
    assert_true(g.doc.is_failed(), "a vanished row")
    poke(g)
    # a database another program holds (a reader can't read in exclusive mode)
    var busy = WebShell(path, "paper")
    var lock = Database(path)
    lock.exec("PRAGMA locking_mode = EXCLUSIVE")
    lock.exec("BEGIN EXCLUSIVE")
    busy.open(5)
    assert_true(busy.doc.is_failed(), "a busy database")
    poke(busy)
    lock.exec("ROLLBACK")
    lock.exec("PRAGMA locking_mode = NORMAL")
    var q = lock.prepare("SELECT COUNT(*) FROM notes")
    _ = q.step()
    var after5 = row(path, 5)
    assert_equal(after5[1], String(PAGE), "nothing written")
    busy.open(5)
    assert_true(busy.doc.may_edit() and busy.page.markdown() == "one\ntwo", "free again: opens")
    print("   failures: shown, read-only, nothing written, Retry opens")


def odd_kinds(path: String) raises:
    var s = WebShell(path, "paper")
    s.open(4)
    _ = paint(s, 6)
    ref l = s.board.edit()
    var id = -1
    for ref o in l.objs:
        if o.key == "a":
            id = o.id
    l.select(id, False)
    l.begin_gesture(1)
    l.move_by(20, 30)
    l.end_gesture()
    s.queue_save("canvas")
    s.flush()
    assert_equal(s.save_state, "")
    var t = row(path, 4)[1]
    assert_equal(t, String(ODD).replace('"id":"a","type":"text","x":100,"y":100', '"id":"a","type":"text","x":120,"y":130'), "only the moved one, only its x and y")
    assert_true(t.find('"columns":2') >= 0, "its own page grid")
    # a page and a map keep what they had
    s.open(5)
    s.page.caret_end()
    s.page.insert("!")
    s.save_page()
    s.flush()
    assert_equal(row(path, 5)[1], String(PAGE).replace("two", "two!"))
    s.open(6)
    s.map.topics[0].text = "Book two"
    s.save_map()
    s.flush()
    assert_equal(row(path, 6)[1], String(MAP).replace('"Book"', '"Book two"'))
    print("   odd kinds: kept")


def held(path: String) raises:
    var s = WebShell(path, "paper")
    s.open(5)
    var at = row(path, 5)
    s.page.caret_end()
    s.page.insert(" HELD")
    s.save_page()
    var lock = Database(path)
    lock.exec("BEGIN IMMEDIATE")  # (readers go on; nobody else can write)
    s.open(1)  # (the switch starts the save on its thread: it waits for the file)
    assert_true(s.saving(), "on its way")
    assert_equal(row(path, 5)[1], at[1], "not written")
    s.open(5)
    assert_true(s.page.markdown().endswith(" HELD") and s.doc.may_edit(), "the edits are what opens")
    s.open(1)
    s.writer.give_up()  # (as after a minute, or closing)
    s.land_save(True)
    assert_true(s.outbox.find(5) >= 0, "held")
    assert_equal(row(path, 5)[1], at[1], "not written")
    s.open(5)
    assert_true(s.page.markdown().endswith(" HELD") and s.save_state != "", "the edits are what opens, and it says so: " + s.save_state)
    assert_true(words(paint(s)).find("Retry") >= 0, "with a Retry")
    var s2 = WebShell(path, "paper")  # (a restart meanwhile)
    s2.open(5)
    assert_true(s2.page.markdown().endswith(" HELD"), "after a restart too")
    lock.exec("ROLLBACK")
    _ = paint(s2)
    var hit = box(s2, "#save-retry")
    assert_true(s2.tap(hit[0] + 5, hit[1] + 5), "Retry")
    assert_equal(s2.save_state, "", "landed: " + s2.save_detail)
    var now = row(path, 5)
    assert_true(now[0] == at[0] + 1 and now[1] == String(at[1]).replace("two!", "two! HELD"), "written once: " + now[1])
    var s3 = WebShell(path, "paper")
    assert_equal(s3.outbox.find(5), -1, "nothing held any more")
    # a conflict: another program saved first
    s3.open(6)
    s3.map.topics[0].text = "Mine"
    s3.save_map()
    var db = Database(path)
    db.exec("UPDATE notes SET content = replace(content, 'Book two', 'Theirs'), revision = revision + 1 WHERE id = 6")
    s3.flush()
    assert_true(s3.save_state != "" and s3.outbox.find(6) >= 0, "a conflict is held")
    assert_true(row(path, 6)[1].find("Theirs") >= 0, "theirs is untouched")
    s3.open(1)
    s3.open(6)
    assert_equal(s3.map.topics[0].text, "Mine", "mine is what opens, until I decide")
    s3.outbox.drop(6)
    s3.open(6)
    assert_equal(s3.map.topics[0].text, "Theirs")
    print("   held saves: through a switch and a restart, landed on Retry; a conflict writes nothing")


def pictures(path: String, other: String) raises:
    var a = WebShell(path, "paper")
    var b = WebShell(other, "paper")
    assert_true(a.snap_dir != "" and b.snap_dir != "" and a.snap_dir != b.snap_dir, "a folder for each notes file")
    assert_true(a.snap_tag(0) != b.snap_tag(0), "and a name")
    assert_equal(Int(stat(a.snap_dir).st_mode) & 0o777, 0o700)
    # a kept picture of a note that is locked or deleted goes; others stay
    for id in [1, 2, 3]:
        with open(a.snap_path(id), "w") as f:
            f.write("picture")
    var db = Database(path)
    db.exec("UPDATE notes SET secure = 1 WHERE id = 2")
    db.exec("DELETE FROM notes WHERE id = 3")
    var c = WebShell(path, "paper")
    var left = List[String]()
    for n in listdir(c.snap_dir):
        if String(n).endswith(".snap"):
            left.append(String(n))
    assert_true("note-1.snap" in left and "note-2.snap" not in left and "note-3.snap" not in left, "locked and deleted notes' pictures are gone")
    # locked while the app runs
    db.exec("UPDATE notes SET secure = 1 WHERE id = 1")
    c.open(1)
    assert_true(c.locked() and not c.doc.may_edit(), "locked")
    for n in listdir(c.snap_dir):
        assert_true(String(n) != "note-1.snap", "its picture went as it was locked")
    poke(c)
    # the notes file itself is gone: its pictures go
    with open(b.snap_path(1), "w") as f:
        f.write("picture")
    var bdir = b.snap_dir
    _ = unlink(other)
    var d = WebShell(path, "paper")
    for n in listdir(bdir):
        assert_true(not String(n).endswith(".snap"), "a gone file's pictures go")
    _ = d.current
    print("   kept pictures: private, per file, gone with their notes")


def keep(mut s: WebShell, id: Int, note: String, cols: Int, rows: Int) raises:
    """A kept view of note `id` as the renderer would have written it (its key right, its note as given)."""
    var i = s.note_index(id)
    _ = s.read_row(i, False)
    var v = opening_view(1440, 900, Float64(cols) * PAGE_W, Float64(rows) * PAGE_H)
    var key = SnapKey(s.snap_tag(i), renderer_id(), s.look.build, v.scale, snap_px(v.x), snap_px(v.y), 1440, 900)
    var w = SnapWriter(s.snap_path(id), key, note)
    w.add(0, 0, 0, 0, 0, 0, 0)
    assert_true(w.finish(), "kept")
    assert_equal(Int(stat(s.snap_path(id)).st_mode) & 0o777, 0o600)


def kept_views(path: String) raises:
    """(MUST 4) A deferred open shows a kept view first; the page grid and the text are the document's as soon as it is in."""
    set_renderer_id(7)
    var s = WebShell(path, "paper")
    s.open(5)
    _ = paint(s)
    for wrong in [True, False]:
        # (the odd canvas: two columns by one row)
        var text = row(path, 4)[1]
        keep(s, 4, "grid=3x2;" + ("12345" if wrong else String(text_hash(text))), 3, 2)
        s.kept.clear()
        s.open(4)
        assert_true(s.doc.loading() and s.cols == 3 and s.rows == 2, "deferred: the kept view's own grid, to lay it out")
        assert_true(not s.doc.may_save(4, s.notes[s.note_index(4)].revision), "nothing may be saved yet")
        _ = paint(s, 1)
        for _ in range(200):
            if not s.doc.loading():
                break
            _ = paint(s, 1)
        assert_true(s.doc.may_edit(), "in")
        assert_true(s.cols == 2 and s.rows == 1, "its own grid")
        var there = False
        for n in listdir(s.snap_dir):
            if String(n) == "note-4.snap":
                there = True
        assert_equal(there, not wrong, "a view of another text is gone; one of this text stays")
        ref l = s.board.edit()
        l.select(l.objs[0].id, False)
        l.begin_gesture(1)
        l.move_by(1, 1)
        l.end_gesture()
        s.queue_save("canvas")
        s.flush()
        var t = row(path, 4)[1]
        assert_true(t.find('"columns":2') >= 0 and t.find('"columns":3') < 0 and t.find('"paper":"dots"') >= 0, "a grid from a kept view is never written")
        s.open(5)
    # another app saves between the key's look and the read: what opens is what it saved
    var rev = row(path, 4)
    keep(s, 4, "grid=2x1;" + String(text_hash(rev[1])), 2, 1)
    s.kept.clear()
    s.open(4)
    var db = Database(path)
    db.exec("UPDATE notes SET content = replace(content, '\"hi\"', '\"theirs\"'), revision = revision + 1 WHERE id = 4")
    for _ in range(300):
        _ = paint(s, 1)
        if s.doc.may_edit():
            break
    var w = words(paint(s, 6), "board")
    assert_true(w.find("theirs") >= 0 and s.doc.revision == rev[0] + 1, "what the other app saved: " + w)
    set_renderer_id(0)
    print("   kept views: the document's own grid and text")


def search(path: String) raises:
    var s = WebShell(path, "paper")
    s.searching = True
    s.omni.query = ""
    s.search()
    for k in ["é", "é", "👩‍👩‍👧", "漢"]:
        _ = s.key(String(k), 0)
    for _ in range(6):
        _ = s.key("Backspace", 0)
    assert_equal(s.omni.query, "")
    print("   search: é and Backspace")


def main() raises:
    var tmp = getenv("TMPDIR", "/tmp") + "/pnshell-test"
    _ = private_dir(tmp)
    _ = setenv("OMX_CONFIG", tmp + "/cfg", True)
    _ = setenv("PNOTE_SNAPS", tmp + "/snaps", True)
    _ = private_dir(tmp + "/cfg")
    var path = tmp + "/notes.db"
    var other = tmp + "/other.db"
    make(path)
    make(other)
    var clean = WebShell(path, "paper")
    for id in range(1, 60):
        clean.outbox.drop(id)
    switches(path)
    search(path)
    failures(path)
    odd_kinds(path)
    kept_views(path)
    held(path)
    pictures(path, other)
    print("pnshell: ok")
