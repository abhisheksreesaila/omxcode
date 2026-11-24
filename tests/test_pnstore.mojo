# pnote's notes file (examples/pnote/pnstore.mojo): made with Personal Note's schema where there is none; notes made,
# filed and deleted with the search index and the change log in step, all or nothing. CPU only.
#   pixi run mojo run -I . -I vendor -I examples/pnote tests/test_pnstore.mojo [a Personal Note database, whose columns are compared]
from std.sys import argv
from std.testing import assert_equal, assert_true
from mojoui.libc import unlink
from mojoui.sqlite import Database
from pnstore import make_notes_file, make_note, drop_note, file_note, hex_id, has_notes


def columns(db: Database, table: String) raises -> String:
    var out = String("")
    var q = db.prepare("SELECT name, type, \"notnull\", IFNULL(dflt_value, ''), pk FROM pragma_table_info('" + table + "') ORDER BY name")
    while q.step():
        out += q.text(0) + " " + q.text(1) + " " + String(q.int(2)) + " " + q.text(3) + " " + String(q.int(4)) + "\n"
    return out


def main() raises:
    _ = unlink("build/test_pnstore3.db")
    var other = Database("build/test_pnstore3.db")
    other.exec("CREATE TABLE customers(id INTEGER)")
    var refused = False
    try:
        make_notes_file(other)
    except:
        refused = True
    assert_true(refused and other.count("SELECT COUNT(*) FROM sqlite_master") == 1, "another program's database is left alone")
    var path = String("build/test_pnstore.db")
    for x in ["", "-wal", "-shm"]:
        _ = unlink(path + String(x))
    var db = Database(path)
    assert_true(not has_notes(db), "nothing yet")
    make_notes_file(db)
    make_notes_file(db)  # (again: left as it is)
    assert_equal(db.count("SELECT COUNT(*) FROM notebooks"), 1)
    assert_equal(db.one_text("SELECT name FROM notebooks"), "My Notes")
    assert_equal(db.count("SELECT sequence FROM workspace_state"), 1)
    assert_equal(hex_id("res_").byte_length(), 36)
    assert_true(hex_id("res_") != hex_id("res_"), "ids differ")
    var a = make_note(db, "canvas", "", 0)
    var b = make_note(db, "page", "Plans", 1)
    var m = make_note(db, "mindmap", "Map", 0)
    assert_true(a.id > 0 and b.id > 0 and m.id > 0, a.message + b.message + m.message)
    assert_equal(db.one_text("SELECT title FROM notes WHERE id = " + String(a.id)), "Untitled note")
    assert_equal(db.count("SELECT notebook_id IS NULL FROM notes WHERE id = " + String(a.id)), 1)
    assert_equal(db.count("SELECT notebook_id FROM notes WHERE id = " + String(b.id)), 1)
    assert_equal(db.one_text("SELECT content_format FROM notes WHERE id = " + String(a.id)), "json-canvas")
    assert_equal(db.one_text("SELECT body FROM note_search WHERE note_id = " + String(m.id)), "Central idea")
    assert_equal(db.count("SELECT COUNT(*) FROM note_search WHERE note_search MATCH 'plans'"), 1)
    assert_equal(db.count("SELECT sequence FROM workspace_state"), 4)
    assert_equal(db.one_text("SELECT change_type || resource_kind || revision FROM workspace_changes WHERE sequence = 4"), "creatednote1")
    # a notebook that isn't there: the Inbox, as the web's
    var n = make_note(db, "page", "x", 99)
    assert_equal(db.count("SELECT notebook_id IS NULL FROM notes WHERE id = " + String(n.id)), 1)
    # filed, on its revision only
    var r = file_note(db, a.id, 1, 1)
    assert_true(r.ok() and r.revision == 2, r.message)
    assert_equal(db.count("SELECT notebook_id FROM notes WHERE id = " + String(a.id)), 1)
    var stale = file_note(db, a.id, 1, 0)
    assert_true(not stale.ok(), "another app moved it on: refused")
    assert_equal(db.count("SELECT notebook_id FROM notes WHERE id = " + String(a.id)), 1)
    r = file_note(db, a.id, 2, 0)
    assert_equal(db.count("SELECT notebook_id IS NULL FROM notes WHERE id = " + String(a.id)), 1)
    # deleted, with its index and a change; a follow-up that fails deletes nothing
    var seq = db.count("SELECT sequence FROM workspace_state")
    assert_equal(drop_note(db, b.id), "")
    assert_equal(db.count("SELECT COUNT(*) FROM notes WHERE id = " + String(b.id)), 0)
    assert_equal(db.count("SELECT COUNT(*) FROM note_search WHERE note_id = " + String(b.id)), 0)
    assert_equal(db.count("SELECT sequence FROM workspace_state"), seq + 1)
    assert_equal(db.one_text("SELECT change_type || revision FROM workspace_changes WHERE sequence = " + String(seq + 1)), "deleted2")
    assert_equal(drop_note(db, b.id), "gone")
    assert_equal(db.count("SELECT sequence FROM workspace_state"), seq + 1)  # (a row already gone changes nothing)
    db.exec("DROP TABLE agent_edits")
    assert_true(drop_note(db, m.id) != "", "a follow-up failed")
    assert_equal(db.count("SELECT COUNT(*) FROM notes WHERE id = " + String(m.id)), 1)
    assert_equal(db.count("SELECT COUNT(*) FROM note_search WHERE note_id = " + String(m.id)), 1)
    if len(argv()) > 1:  # (against a file the web app made: the same columns everywhere)
        var pn = Database(String(argv()[1]), read_only=True)
        var fresh_path = String("build/test_pnstore2.db")
        for x in ["", "-wal", "-shm"]:
            _ = unlink(fresh_path + String(x))
        var fresh = Database(fresh_path)
        make_notes_file(fresh)
        for t in ["notes", "notebooks", "workspace_state", "workspace_changes", "agent_activity", "agent_edits", "secure_keys", "note_embeddings", "mindmap_reminders", "x_posts", "x_notebook"]:
            assert_equal(columns(fresh, String(t)), columns(pn, String(t)), String(t))
        print("   the same columns as " + String(argv()[1]))
    print("pnstore: ok")
