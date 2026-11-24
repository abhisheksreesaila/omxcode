# Review 3, MUST 3 and SHOULD 7, the generic pieces: OpenDoc (a document that wasn't read whole is never edited, saved or
# kept), OpenBoard's failed opens (a job that fails, a text that isn't a canvas, another app's format: an empty read-only
# board that can't be taken as a document), the board tools on one, and SaveOutbox (edits that couldn't be written survive a
# switch, a restart, and are dropped when they land). opendoc: ok
from std.os import stat, getenv, listdir
from std.testing import assert_true, assert_equal
from std.time import sleep
from mojoui.libc import unlink
from mojoui.files import private_dir, file_exists
from mojoui.sqlite import Database
from mojoui.docstore import OpenDoc, SaveOutbox, Unsaved, unsaved_text, DOC_FAILED
from mojoui.canvasload import OpenBoard, SqlText, text_hash
from mojoui.objectlayer import ObjectLayer, import_json_canvas, export_json_canvas
from mojoui.pagedesk import BoardTools, DeskView


def gate() raises:
    var d = OpenDoc()
    assert_true(not d.may_edit() and not d.may_save(1, 1) and not d.may_keep(1), "nothing open")
    d.begin(1)
    assert_true(d.loading() and not d.may_edit() and not d.may_save(1, 1) and not d.may_keep(1), "loading")
    d.ready(2, 5)
    assert_true(not d.may_edit(), "another document's answer")
    d.ready(1, 5)
    assert_true(d.may_edit() and d.may_save(1, 5) and d.may_keep(1), "read")
    assert_true(not d.may_save(1, 6) and not d.may_save(2, 5), "another revision, another row")
    d.saved(6)
    assert_true(d.may_save(1, 6) and not d.may_save(1, 5), "saved: the next builds on it")
    d.begin(3)
    d.failed(3, "")
    assert_true(d.is_failed() and d.problem != "" and not d.may_edit() and not d.may_save(3, -1) and not d.may_keep(3), "failed")
    d.ready(3, 1)
    d.saved(1)
    assert_true(d.is_failed(), "a late answer doesn't unfail it")
    d.begin(3)
    d.ready(3, 2)
    d.failed(4, "someone else's")
    assert_true(d.may_save(3, 2), "retried")


def failed_boards() raises:
    var path = getenv("TMPDIR", "/tmp") + "/mojoui-opendoc.db"
    _ = unlink(path)
    var db = Database(path)
    db.exec("CREATE TABLE notes (id INTEGER PRIMARY KEY, content TEXT)")
    db.exec("INSERT INTO notes VALUES (1, '{\"nodes\":[{\"id\":\"a\",\"type\":\"text\",\"x\":0,\"y\":0,\"width\":90,\"height\":40,\"text\":\"t\"}],\"edges\":[],\"pn\":{\"page\":{\"columns\":3,\"rows\":2}}}')")
    db.exec("INSERT INTO notes VALUES (2, '{\"objects\":[]}'), (3, 'not json'), (4, ''), (5, '{\"nodes\":[')")
    var sql = "SELECT content FROM notes WHERE id = ?"
    for id in [2, 3, 4, 5, 999]:  # (another format, not JSON, nothing, cut off, no such row)
        var b = OpenBoard()
        b.open_later(SqlText(path, sql, id), 0, 0, 1440, 900, 6)
        for _ in range(400):
            if not b.step(0, 0, 1440, 900, 500):
                break
            sleep(0.002)
        assert_true(b.broken and b.problem != "", "note " + String(id) + " failed")
        assert_true(not b.keepable(), "nothing to keep")
        assert_true(b.layer.read_only and len(b.layer.objs) == 0 and not b.layer.unsaved(), "read-only and empty")
        var tools = BoardTools()
        var v = DeskView(0, 0, 1)
        for tool in ["text", "sticky", "pen", "select", "shape"]:
            tools.tool = String(tool)
            _ = tools.press(100, 100, b.layer, v)
            _ = tools.pan(150, 150, b.layer, v)
            _ = tools.release(150, 150, b.layer, v)
            _ = tools.tap(200, 200, b.layer, v, 1440, 900)
            for k in ["a", "Enter", "Delete", "Backspace", "v"]:
                _ = tools.key(String(k), 0, b.layer, v, 1440, 900, 1, 1)
        assert_true(len(b.layer.objs) == 0 and not b.layer.unsaved(), "the tools refuse it")
        # the same board opens the next document well
        b.open_later(SqlText(path, sql, 1), 0, 0, 1440, 900, 6)
        for _ in range(400):
            if not b.step(0, 0, 1440, 900, 500):
                break
            sleep(0.002)
        assert_true(not b.broken and b.problem == "" and b.keepable() and not b.layer.read_only, "the next one opens")
        assert_equal(len(b.layer.objs), 1)
        var page = b.member("pn")
        assert_equal(page.number(page.get(page.get(0, "page"), "columns")), 3, "its page grid, read from it")
        assert_true(b.text_hash != 0 and b.text_hash == text_hash(export_json_canvas(b.layer)), "a fingerprint of its text")
    for bad in ["{\"objects\":[]}", "{}", "{\"nodes\":{}}", "[1]"]:
        var raised = False
        try:
            _ = import_json_canvas(String(bad))
        except:
            raised = True
        assert_true(raised, "not a canvas: " + String(bad))
    assert_true(text_hash("") != 0 and text_hash("a") != text_hash("b") and text_hash("12345678") != text_hash("12345679"), "fingerprints")


def outbox() raises:
    var dir = getenv("TMPDIR", "/tmp") + "/mojoui-outbox"
    assert_true(private_dir(dir))
    var big = String("é \"q\" \n") * 1000
    var o = SaveOutbox(dir, "s1")
    for id in [3, 4, 9]:
        o.drop(id)
    assert_true(o.put(Unsaved(3, "page", 7, "{\"markdown\":\"" + "x" + "\"}", "x", "database is locked", False)), "on disk")
    assert_true(o.put(Unsaved(4, "canvas", 2, big, "b", "Resource revision does not match", True)))
    assert_equal(Int(stat(o.path(3)).st_mode) & 0o777, 0o600)
    var again = SaveOutbox(dir, "s1")  # (the next start)
    again.load()
    assert_equal(len(again.items), 2)
    var i = again.find(4)
    assert_true(i >= 0 and again.items[i].conflict and again.items[i].content == big and again.items[i].revision == 2 and again.items[i].kind == "canvas", "as it was")
    var other = SaveOutbox(dir, "s2")  # (another database)
    other.load()
    assert_equal(len(other.items), 0)
    _ = again.put(Unsaved(3, "page", 8, "newer", "n", "disk full", False))
    assert_equal(len(again.items), 2)
    again.drop(3)
    var third = SaveOutbox(dir, "s1")
    third.load()
    assert_true(len(third.items) == 1 and third.find(3) < 0 and third.find(4) >= 0, "landed: gone")
    third.drop(4)
    var nowhere = SaveOutbox("/proc/nowhere", "s")
    assert_true(not nowhere.put(Unsaved(1, "page", 1, "c", "b", "w", False)), "no folder: said")
    assert_equal(len(nowhere.items), 1, "held in memory all the same")


def two_windows() raises:
    """(review 4, MUST 1) Two windows on one folder: neither removes or takes over what the other holds while it lives; a window
    that ended leaves its edits to the next start; two versions of one document are both kept; a broken file hides no other."""
    var dir = getenv("TMPDIR", "/tmp") + "/mojoui-outbox2"
    assert_true(private_dir(dir))
    for n in listdir(dir):
        _ = unlink(dir + "/" + String(n))
    var a = SaveOutbox(dir, "s")
    var b = SaveOutbox(dir, "s")
    a.load()
    b.load()
    assert_true(a.put(Unsaved(5, "page", 3, "a's words", "", "conflict", True)))
    assert_true(b.put(Unsaved(5, "page", 4, "b's words", "", "locked", False)))
    b.drop(5)  # (b's save landed)
    var c = SaveOutbox(dir, "s")
    c.load()
    assert_equal(len(c.items), 0, "a lives: its file isn't another's to take")
    with open(a.path(5), "r") as f:
        assert_true("a's words" in f.read(), "nor to remove")
    assert_true(b.put(Unsaved(5, "page", 4, "b's again", "", "locked", False)))
    assert_true(b.put(Unsaved(6, "page", 1, "b's other", "", "locked", False)))
    b.drop(77)
    var bp = b.path(6)
    _ = a^  # (both end, however they end)
    _ = b^
    with open(dir + "/unsaved-s-1.p1-gone.json", "w") as f:
        f.write("{not json")
    with open(dir + "/unsaved-s-8.json", "w") as f:  # (an older version's name)
        f.write(unsaved_text(Unsaved(8, "page", 1, "older", "", "", False)))
    var d = SaveOutbox(dir, "s")
    d.load()
    assert_true(d.find(6) >= 0 and d.find(8) >= 0, "the gone ones' edits are found")
    assert_true(d.items[d.find(5)].content == "b's again" and len(d.extras) == 1 and d.extras[0].content == "a's words", "both versions")
    var e = SaveOutbox(dir, "s")
    e.load()
    assert_equal(len(e.items) + len(e.extras), 0, "d lives")
    d.extra_done(0)
    for id in [5, 6, 8]:
        d.drop(id)
    _ = d^
    _ = e^
    _ = c^
    var f2 = SaveOutbox(dir, "s")
    f2.load()
    assert_equal(len(f2.items) + len(f2.extras), 0)
    var left = 0
    for n in listdir(dir):
        if String(n).endswith(".lock"):
            left += 1
    assert_true(left <= 2 and not file_exists(bp), "names of the gone don't pile up: " + String(left))


def main() raises:
    two_windows()
    gate()
    failed_boards()
    outbox()
    print("opendoc: ok")
