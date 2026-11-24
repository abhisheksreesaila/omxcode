# Whole notes in pnote (docs/goals/79-gaps.md 2–7, 9, 46–48, 57, 58): a fresh file, Quick note by the button and Alt+N, new
# kinds and a "New note" row from the search, two notes with one name, deleting with Undo and for good, filing, the panel's
# list scrolled and a notebook opened, the search's groups, clicks and filters, words inside notes; Clear all. No window.
#   pixi run mojo run -I . -I vendor -I examples/pnote tests/test_pnnotes.mojo
from std.os import setenv
from std.testing import assert_true, assert_equal
from mojoui.libc import unlink
from mojoui.files import private_dir
from mojoui.scene import Scene
from mojoui.sqlite import Database
from mojoui.docstore import clock_us
from webshell import WebShell, fts_words
from pnstore import default_notes_file

comptime DB = "build/test_pnnotes.db"
comptime W: Float64 = 1440
comptime H: Float64 = 900


def fresh() raises:
    for x in ["", "-wal", "-shm"]:
        _ = unlink(String(DB) + String(x))


def paint(mut s: WebShell) raises:
    var sc = Scene(1440, 900, 1.0)
    s.paint(sc, W, H, 1.0)


def at(s: WebShell, name: String) raises -> Tuple[Float64, Float64]:
    for i in range(len(s.boxes.names) - 1, -1, -1):
        if s.boxes.names[i] == name:
            return (s.boxes.r[4 * i] + s.boxes.r[4 * i + 2] / 2, s.boxes.r[4 * i + 1] + s.boxes.r[4 * i + 3] / 2)
    raise Error("no box " + name)


def tap(mut s: WebShell, name: String) raises:
    paint(s)
    var p = at(s, name)
    _ = s.press(p[0], p[1])
    _ = s.release(p[0], p[1])
    assert_true(s.tap(p[0], p[1]), "tap " + name)
    paint(s)


def row_tap(mut s: WebShell, id: Int) raises -> Bool:
    paint(s)
    for k in range(0, len(s.panel.hits), 6):
        if Int(s.panel.hits[k]) == 0 and Int(s.panel.hits[k + 1]) == id:
            return s.tap(s.panel.hits[k + 2] + 40, s.panel.hits[k + 3] + 10)
    return False


def count(sql: String) raises -> Int:
    return Database(DB).count(sql)


def typed(mut s: WebShell, words: String):
    for c in words.graphemes():
        _ = s.key(String(c), 0)


def default_file() raises:
    _ = setenv("OMX_DATA", "build/test_pnnotes_data")
    for x in ["", "-wal", "-shm"]:
        _ = unlink("build/test_pnnotes_data/notes.db" + String(x))
    assert_equal(default_notes_file(), "build/test_pnnotes_data/notes.db")
    var s = WebShell(default_notes_file(), "paper")
    assert_true(s.problem == "" and len(s.notes) == 0 and len(s.panel.notebooks) == 1, s.problem)
    s.create("canvas")
    s.close()
    var t = WebShell(default_notes_file(), "paper")
    assert_true(len(t.notes) == 1, "there the next time")
    print("   the default notes file")


def fresh_file() raises:
    var s = WebShell(DB, "paper")
    assert_equal(s.problem, "")
    assert_equal(len(s.notes), 0)
    assert_equal(len(s.panel.notebooks), 1)
    paint(s)
    s.sidebar = True
    tap(s, "#rail-new-note")
    assert_equal(len(s.notes), 1)
    assert_true(s.notes[0].kind == "canvas" and s.notes[0].title == "Untitled note" and s.notes[0].notebook == 0, "a canvas in the Inbox")
    assert_true(s.current == s.notes[0].id and s.doc.may_edit(), "opened")
    assert_true(s.tools.editing == -2 and s.view.scale == 1, "an empty canvas opens for writing, at 100 % (the web's startWriting)")
    assert_true(not s.key("n", 4) and len(s.notes) == 1, "Alt+N waits while words are typed, as the web's")
    _ = s.key("Escape", 0)
    assert_true(s.key("n", 4), "Alt+N")
    assert_equal(len(s.notes), 2)
    assert_equal(count("SELECT COUNT(*) FROM note_search"), 2)
    # two notes with one name: each row opens its own
    var ids = [s.notes[0].id, s.notes[1].id]
    for id in [ids[1], ids[0], ids[1]]:
        assert_true(row_tap(s, id), "its row")
        assert_equal(s.current, id)
    print("   a fresh file; Quick note; same names")


def search() raises:
    var s = WebShell(DB, "paper")
    paint(s)
    assert_true(s.key("k", 2) and s.searching, "Ctrl+K")
    paint(s)
    assert_equal(s.omni.groups[0].title, "Recent")
    assert_true(s.key("k", 2) and not s.searching, "and again closes")
    _ = s.key("k", 2)
    typed(s, "new pa")
    paint(s)
    assert_equal(s.omni_kind[s.omni.selected], 2)
    assert_true(s.key("Enter", 0), "run it")
    assert_true(not s.searching and s.notes[0].kind == "page" and s.current == s.notes[0].id, "a new page, opened")
    typed(s, "The zebra crossed at dawn")
    s.flush()
    var page = s.current
    _ = s.key("k", 2)
    typed(s, "new mind")
    _ = s.key("Enter", 0)
    assert_equal(s.notes[0].kind, "mindmap")
    _ = s.key("k", 2)
    typed(s, "zebra")  # a word inside a note
    paint(s)
    assert_equal(s.omni.groups[0].title, "In your words")
    assert_true(s.omni.groups[0].rows[0].sub.find("zebra") >= 0, s.omni.groups[0].rows[0].sub)
    tap(s, "#omni-row-0")
    assert_true(not s.searching and s.current == page, "a click opens it")
    _ = s.key("k", 2)
    typed(s, "My Plan Nobody Has")  # nothing: a New note row
    paint(s)
    assert_equal(s.omni_kind[0], 3)
    _ = s.key("Enter", 0)
    assert_equal(s.notes[0].title, "My Plan Nobody Has")
    _ = s.key("k", 2)
    typed(s, "my")  # notes and a notebook; the filter pills
    paint(s)
    assert_equal(len(s.omni.groups), 2)
    tap(s, ".omni-chip:Notebooks 1")
    assert_true(len(s.omni.groups) == 1 and s.omni.groups[0].title == "Notebooks", "filtered")
    _ = s.key("Enter", 0)
    assert_true(s.sidebar and not s.searching and s.panel.notebooks[0].id in s.panel.open_books, "a notebook shows in the panel")
    _ = s.key("k", 2)
    paint(s)
    assert_true(s.tap(20, 880) and not s.searching, "a click outside closes it, and reaches nothing under it")
    _ = s.key("k", 2)
    _ = s.key("Escape", 0)
    assert_true(not s.searching and s.sidebar, "Escape: the search first")
    _ = s.key("Escape", 0)
    _ = s.key("Escape", 0)
    assert_true(not s.sidebar, "then the panel")
    for k in range(12):  # (more rows than fit: the selected one is in view)
        s.create("page", "Many rows " + String(k))
    _ = s.key("k", 2)
    typed(s, "many rows")
    for _ in range(7):
        _ = s.key("ArrowDown", 0)
    paint(s)
    var p = at(s, "#omni-row-7")
    var l = at(s, "#search-results")
    assert_true(p[1] > l[1] - 160 and p[1] < l[1] + 160, "in view")
    _ = s.key("Escape", 0)
    s.create("page", "İstanbul’dan ẞ notlar")  # (letters whose lower case is longer or shorter: marked or not, never cut)
    for q in ["i", "ist", "ß", "notlar", "İ", "’"]:
        _ = s.key("k", 2)
        typed(s, String(q))
        paint(s)
        _ = s.key("Escape", 0)
    var w = fts_words("naïve-word \"OR\" x_1")
    assert_equal(len(w), 4)
    s.close()
    print("   search: groups, words inside, filters, clicks, New note")


def deleting() raises:
    var s = WebShell(DB, "paper")
    s.open(s.notes[0].id)
    paint(s)
    var n = len(s.notes)
    var id = s.current
    var title = s.notes[s.note_index(id)].title
    tap(s, "#share-button")
    tap(s, "#share-props")
    assert_true(s.props_open, "properties")
    tap(s, "#delete-note")
    assert_equal(len(s.notes), n - 1)
    assert_true(s.current != id and s.toast == "Note deleted", "gone from the list, the next one open")
    assert_equal(count("SELECT COUNT(*) FROM notes WHERE id = " + String(id)), 1)  # (its row waits for Undo)
    tap(s, "#toast-action")
    assert_equal(len(s.notes), n)
    assert_true(s.current == id and s.notes[s.note_index(id)].title == title and s.toast == "", "back, opened")
    s.delete_note()
    s.toast_until = clock_us() - 1
    assert_true(s.tick(), "the toast goes")
    assert_equal(count("SELECT COUNT(*) FROM notes WHERE id = " + String(id)), 0)
    assert_equal(count("SELECT COUNT(*) FROM note_search WHERE note_id = " + String(id)), 0)
    var second = s.current
    s.delete_note()
    s.open(s.notes[1].id)  # another note opened: made for good
    assert_equal(count("SELECT COUNT(*) FROM notes WHERE id = " + String(second)), 0)
    var third = s.current
    s.delete_note()
    s.close()  # the app closed
    assert_equal(count("SELECT COUNT(*) FROM notes WHERE id = " + String(third)), 0)
    # a file that can't be written: the note comes back
    var t = WebShell(DB, "paper")
    t.open(t.notes[0].id)
    var fourth = t.current
    t.delete_note()
    Database(DB).exec("ALTER TABLE agent_edits RENAME TO agent_edits_away")
    t.hide_toast()
    assert_true(t.note_index(fourth) >= 0 and t.toast.startswith("Couldn’t delete"), t.toast)
    Database(DB).exec("ALTER TABLE agent_edits_away RENAME TO agent_edits")
    # an edit made just before is saved first, and deleting the last note makes a new one
    while len(t.notes) > 1:
        t.delete_note()
    t.delete_note()
    assert_true(len(t.notes) == 1 and t.notes[0].title == "Untitled note" and t.current == t.notes[0].id, "never none")
    t.close()
    print("   deleting: Undo, the toast's end, another note, closing, a failure")


def filing() raises:
    var s = WebShell(DB, "paper")
    s.sidebar = True
    s.open(s.notes[0].id)
    paint(s)
    tap(s, "#share-button")
    tap(s, "#share-props")
    tap(s, "#notebook-picker")
    tap(s, "[Move to 1]")
    var id = s.current
    assert_equal(count("SELECT notebook_id FROM notes WHERE id = " + String(id)), 1)
    assert_equal(s.panel.notebooks[0].count, 1)
    assert_true(1 in s.panel.open_books, "its notebook opens to it")
    s.props_open = False
    assert_true(row_tap(s, id), "its row under the notebook")
    assert_true(s.editable(), "still the open note, at its new revision")
    s.tools.tool = "sticky"
    _ = s.press(700, 400)
    _ = s.release(700, 400)
    _ = s.tap(700, 400)
    s.flush()
    assert_equal(s.save_state, "")
    paint(s)
    var p = (0.0, 0.0)
    for k in range(0, len(s.panel.hits), 6):
        if Int(s.panel.hits[k]) == 1:
            p = (s.panel.hits[k + 2] + 60, s.panel.hits[k + 3] + 10)
    assert_true(s.tap(p[0], p[1]) and len(s.panel.open_books) == 0, "a click folds the notebook")
    s.move_note(0)
    assert_equal(count("SELECT notebook_id IS NULL FROM notes WHERE id = " + String(id)), 1)
    # another app moved the row on: refused, said so, nothing written
    Database(DB).exec("UPDATE notes SET revision = revision + 1 WHERE id = " + String(id))
    s.move_note(1)
    assert_true(s.toast.startswith("Couldn’t move"), s.toast)
    assert_equal(count("SELECT notebook_id IS NULL FROM notes WHERE id = " + String(id)), 1)
    s.close()
    print("   filing")


def long_list() raises:
    var s = WebShell(DB, "paper")
    for k in range(60):
        s.create("canvas", "A rather long title for a note that cannot fit its row " + String(k))
    s.sidebar = True
    paint(s)
    assert_true(s.panel.scroll_max > 0, "more than fits")
    var last = s.notes[len(s.notes) - 1].id
    assert_true(not row_tap(s, last), "its row is out of view")
    assert_true(s.wheel(100, 400, 0, 1e6), "scrolls")
    assert_true(row_tap(s, last) and s.current == last, "and is there now")
    paint(s)
    var f = at(s, ".sidebar-footer")
    assert_true(s.panel.hit(100, f[1], 0) == -1, "rows under the footer take nothing")
    assert_true(s.tap(at(s, "[Night skin]")[0], at(s, "[Night skin]")[1]) and s.panel.skin_name == "night", "the footer's dots still do")
    s.set_skin("paper")
    s.close()
    print("   a long list")


def clearing() raises:
    var s = WebShell(DB, "paper")
    s.create("page", "To clear")
    typed(s, "words")
    paint(s)
    tap(s, "#share-button")
    tap(s, "#clear-note")
    assert_equal(s.page.markdown(), "")
    tap(s, "#toast-action")
    assert_equal(s.page.markdown(), "words")
    s.close()
    assert_equal(count("SELECT content LIKE '%words%' FROM notes WHERE id = " + String(s.current)), 1)
    print("   clear all")


def opens_for_writing() raises:
    """main.js openCanvasView, startWriting, moveWithCentre: a canvas of writing opens at 100 % at its topmost text with the
    caret at its end; looking isn't an edit; the panel keeps the middle in the middle."""
    var s = WebShell(DB, "paper")
    s.create("canvas", "Writing")
    paint(s)
    for w in ["A", " ", "b"]:
        _ = s.text_in("ime", String(w))
    _ = s.key("Escape", 0)
    _ = s.tap(700, 700)
    for w in ["l", "o", "w"]:
        _ = s.text_in("ime", String(w))
    _ = s.key("Escape", 0)
    s.flush()
    var id = s.current
    var rev = count("SELECT revision FROM notes WHERE id = " + String(id))
    s.create("page", "Between")
    for again in range(2):  # (kept parsed, then read anew)
        if again == 1:
            s = WebShell(DB, "paper")
            paint(s)
        s.open(id)
        paint(s)
        assert_true(s.view.scale == 1 and s.tools.editing >= 0 and s.tools.words.text() == "A b", "the topmost text: " + s.tools.words.text())
        var at = s.tools.words_caret(s.board.layer, s.view)
        assert_true(at[1] > 100 and at[1] < 140, "32 px under the islands: " + String(at[1]))
        s.open(s.notes[1].id if s.notes[0].id == id else s.notes[0].id)  # (looked at, left)
        assert_equal(count("SELECT revision FROM notes WHERE id = " + String(id)), rev)
    s.open(id)
    for w in ["!", "?"]:
        _ = s.text_in("ime", String(w))
    s.create("page", "Elsewhere")
    assert_equal(count("SELECT content LIKE '%A b!?%' FROM notes WHERE id = " + String(id)), 1)  # (typed at once, saved on leaving)
    s.open(id)
    paint(s)
    var x = s.view.x
    s.set_sidebar(True)
    assert_true(s.view.x > x and s.view.x < x + 149, "moves with its room's middle, clear of the tools")
    s.set_sidebar(False)
    assert_true(abs(s.view.x - x) < 1e-6, "and back")
    s.close()
    print("   a canvas opens for writing")


def input_method() raises:
    """What the platform's input method commits (every key typed on a real window comes this way): spaces kept, a pasted
    line break a space, over what is selected."""
    var s = WebShell(DB, "paper")
    s.create("page", "Typed")
    for w in ["a", " ", "b", "\n"]:
        _ = s.text_in("ime", String(w))
    assert_equal(s.page.markdown(), "a b\n")
    s.open_search()
    for w in ["n", "e", "w", " ", "p"]:
        assert_true(s.text_in("ime", String(w)), "typed")
    assert_equal(s.omni.query, "new p")
    assert_true(s.omni_kind[0] == 2, "New page")
    _ = s.text_in("paste", "a\nb")
    assert_equal(s.omni.query, "new pa b")
    s.searching = False
    s.card_open = True
    s.card.editing = True
    s.card.title = "old"
    s.card.all_selected = True
    for w in ["T", "w", "o", " ", "w"]:
        _ = s.text_in("ime", String(w))
    assert_equal(s.card.title, "Two w")
    s.card_open = False
    s.card.editing = False
    s.sidebar = True
    s.panel.naming = 0
    s.panel.naming_text = ""
    for w in ["N", " ", "é"]:
        assert_true(s.text_in("ime", String(w)), "naming")
    assert_equal(s.panel.naming_text, "N é")
    s.panel.naming = -1
    s.create("mindmap", "Ideas")
    s.map.begin_edit(0)
    for w in ["B", "i", "g", " ", "i"]:
        _ = s.text_in("ime", String(w))
    assert_equal(s.map.edit_text, "Big i")
    _ = s.map.edit_key("Escape", 0)
    s.create("canvas", "Words")
    paint(s)
    _ = s.tap(600, 300)
    for w in ["B", " ", "i"]:
        _ = s.text_in("ime", String(w))
    assert_equal(s.tools.words.text(), "B i")
    s.close()
    print("   the input method's commits")


def over_the_board() raises:
    """What lies over a canvas takes the pointer: the properties card, the toast."""
    var s = WebShell(DB, "paper")
    s.create("canvas", "Board")
    paint(s)
    s.tools.tool = "pen"
    s.props_open = True
    paint(s)
    var p = at(s, "#note-popover")
    for k in range(5):
        if k == 0:
            _ = s.press(p[0], p[1] + 10)
        _ = s.pan(p[0] + Float64(k) * 9, p[1] + 10)
    _ = s.release(p[0] + 40, p[1] + 10)
    s.props_open = False
    s.say("A word", "Undo", 0)
    paint(s)
    p = at(s, "#toast")
    _ = s.press(p[0] - 30, p[1])
    _ = s.pan(p[0], p[1])
    _ = s.pan(p[0] + 30, p[1])
    _ = s.release(p[0] + 30, p[1])
    assert_equal(len(s.board.edit().objs), 0)
    s.hide_toast()
    _ = s.press(600, 400)
    _ = s.pan(620, 420)
    _ = s.pan(660, 430)
    _ = s.release(660, 430)
    assert_equal(len(s.board.edit().objs), 1)
    s.close()
    print("   what lies over the board")


def another_app() raises:
    """The web, or a second window, on the same file."""
    var s = WebShell(DB, "paper")
    s.create("page", "Shared")
    typed(s, "mine")
    s.flush()
    var id = s.current
    assert_true(not s.refresh(), "the first look only learns where the feed is")
    assert_true(not s.refresh(), "nothing new")
    var t = WebShell(DB, "paper")
    t.open(id)
    _ = t.key("End", 2)
    typed(t, " and theirs")
    t.flush()
    t.create("page", "Made there")
    assert_true(s.refresh(), "seen")
    assert_equal(s.page.markdown(), "mine and theirs")
    assert_true(s.notes[0].title == "Made there" and s.current == id and s.doc.may_edit(), "its new note listed; the open note still open")
    typed(s, "!")
    s.flush()
    assert_equal(s.save_state, "")  # (on the new revision)
    # both edit: the second is told, its edits are held, and go into a copy of their own
    t.open(id)
    _ = t.key("End", 2)
    typed(t, " T")
    t.flush()
    typed(s, " S")
    assert_true(not s.refresh() or s.page.markdown().endswith(" S"), "an edit under way isn't replaced")
    s.flush()
    assert_true(s.save_state != "", "told")
    paint(s)
    typed(s, " and more")  # (typed after it was told: in the copy too)
    tap(s, "#save-copy")
    assert_true(s.notes[0].title == "Shared (my copy)" and s.page.markdown().endswith(" S and more") and s.save_state == "", "a copy, opened")
    s.open(id)
    assert_true(s.page.markdown().endswith(" T") and s.doc.may_edit(), "the note is the other's")
    assert_equal(s.outbox.find(id), -1)
    # deleted there while open here
    _ = s.refresh()
    t.open(id)
    t.delete_note()
    t.close()
    assert_true(s.refresh() and s.doc.is_failed() and s.note_index(id) < 0, "said so")
    paint(s)
    typed(s, "x")
    s.close()
    assert_equal(count("SELECT COUNT(*) FROM notes WHERE id = " + String(id)), 0)
    print("   another app on the same file")


def notebooks() raises:
    var s = WebShell(DB, "paper")
    s.sidebar = True
    paint(s)
    s.panel.inbox_open = False
    paint(s)
    var p = at(s, ".sec-head@2")  # Projects
    _ = s.hover(p[0], p[1])
    paint(s)
    var plus = (0.0, 0.0)
    for k in range(0, len(s.panel.hits), 6):
        if Int(s.panel.hits[k]) == 2:
            plus = (s.panel.hits[k + 2] + 8, s.panel.hits[k + 3] + 8)
    assert_true(plus[0] > 0, "drawn: " + String(p[0]) + "," + String(p[1]) + " list " + String(s.panel.list_y0) + " scroll " + String(s.panel.scroll_max))
    assert_true(s.tap(plus[0], plus[1]) and s.panel.naming == 0, "its +")
    typed(s, "Alpß")
    _ = s.key("Backspace", 0)
    typed(s, "s")
    paint(s)
    var n = len(s.panel.notebooks)
    assert_true(s.key("Enter", 0) and len(s.panel.notebooks) == n + 1 and s.panel.notebooks[0].name == "Alps", "made")
    assert_equal(count("SELECT COUNT(*) FROM notebooks WHERE name = 'Alps' AND category = 'projects' AND resource_id LIKE 'res_%'"), 1)
    s.panel.naming = 0
    s.panel.naming_text = "x"
    assert_true(s.key("Escape", 0) and s.panel.naming == -1 and len(s.panel.notebooks) == n + 1, "Escape: none")
    tap(s, ".sec-head@3")  # (a fold and an opened notebook are there at the next start)
    s.panel.open_books = List[Int]()
    s.panel.toggle_book(s.panel.notebooks[0].id)
    s.remember_folds()
    s.close()
    var t = WebShell(DB, "paper")
    assert_true(not t.panel.open_shelves[1] and s.panel.notebooks[0].id in t.panel.open_books, "remembered")
    print("   a new notebook; folds remembered")


def selected() raises:
    """The notebook of the open note is marked (the web's selectedNotebookId): opening, filing, choosing and making one mark it."""
    var s = WebShell(DB, "paper")
    s.sidebar = True
    s.open(s.notes[0].id)
    paint(s)
    s.move_note(0)
    assert_equal(s.panel.selected, 0, "the Inbox: none")
    s.move_note(1)
    assert_equal(s.panel.selected, 1, "filed")
    s.create("page")
    assert_equal(s.panel.selected, 0, "a new page is in the Inbox")
    var filed = 0
    for ref n in s.notes:
        if n.notebook == 1:
            filed = n.id
    s.open(filed)
    assert_equal(s.panel.selected, 1, "opened")
    s.act("new-note")
    assert_equal(s.notes[s.note_index(s.current)].notebook, 1, "New note goes in the marked notebook")
    s.act("quick-note")
    assert_equal(s.notes[s.note_index(s.current)].notebook, 0, "Quick note in the Inbox")
    s.panel.naming = 0
    s.panel.naming_text = "Marked"
    s.name_notebook()
    var b = s.panel.notebooks[0].id
    assert_true(s.panel.selected == b and b in s.panel.open_books, "a notebook just made")
    s.delete_book(b)
    assert_equal(s.panel.selected, 0, "and deleted")
    s.panel.open_books = List[Int]()
    s.remember_folds()
    s.open(filed)
    s.close()
    var t = WebShell(DB, "paper")
    assert_true(1 in t.panel.open_books, "a notebook opened by its note stays open after a restart")


def place(s: WebShell, kind: Int, id: Int) raises -> Tuple[Float64, Float64]:
    for k in range(0, len(s.panel.hits), 6):
        if Int(s.panel.hits[k]) == kind and Int(s.panel.hits[k + 1]) == id:
            return (s.panel.hits[k + 2] + s.panel.hits[k + 4] / 2, s.panel.hits[k + 3] + s.panel.hits[k + 5] / 2)
    raise Error("no hit " + String(kind) + " " + String(id))


def pointing() raises:
    """A row under the pointer answers it (and asks for a redraw): its wash, a notebook's + and … over its count; nothing
    while something lies over the panel."""
    var s = WebShell(DB, "paper")
    s.sidebar = True
    s.open(s.notes[0].id)
    paint(s)
    var n = place(s, 1, 1)
    _ = s.hover(5, 5)
    assert_true(s.hover(n[0], n[1]), "a redraw")
    paint(s)
    assert_true(not s.hover(n[0] + 1, n[1]), "none while on the same row")
    var plus = place(s, 5, 1)
    _ = place(s, 4, 1)
    var before = len(s.notes)
    assert_true(s.tap(plus[0], plus[1]) and len(s.notes) == before + 1, "its + makes a note")
    assert_equal(s.notes[s.note_index(s.current)].notebook, 1, "in that notebook")
    s.searching = True
    paint(s)
    var quiet = True
    for k in range(0, len(s.panel.hits), 6):
        if Int(s.panel.hits[k]) == 4:
            quiet = False
    assert_true(quiet and not s.panel.under(n[0] - 4, n[1] - 4, 8, 8), "nothing while the search lies over it")
    s.searching = False


def dragging_and_notebooks() raises:
    var s = WebShell(DB, "paper")
    s.open(s.notes[0].id)
    while len(s.notes) > 4:  # (a short list, every row in view)
        s.delete_note()
    s.commit_delete()
    s.panel.inbox_open = True
    for k in range(len(s.panel.open_shelves)):
        s.panel.open_shelves[k] = True
    s.sidebar = True
    s.open(s.notes[0].id)
    paint(s)
    var other = s.notes[2].id  # (not the open one)
    var book = s.panel.notebooks[0].id
    var a = place(s, 0, other)
    var b = place(s, 1, book)
    _ = s.press(a[0], a[1])
    assert_true(s.pan(a[0] + 20, a[1] + 20), "lifted")
    _ = s.pan(b[0], b[1])
    paint(s)
    assert_true(s.release(b[0], b[1]) and s.tap(b[0], b[1]), "dropped")
    assert_equal(count("SELECT notebook_id FROM notes WHERE id = " + String(other)), book)
    assert_true(s.notes[s.note_index(other)].notebook == book and book in s.panel.open_books and s.current != other, "filed, shown there, not opened")
    s.dropped_us = -1_000_000
    s.open(other)
    assert_true(s.doc.may_edit(), "opens at its new revision")
    paint(s)
    # the open note, back to the Inbox; a drop on nothing changes nothing; a click still opens
    a = place(s, 0, other)
    b = place(s, 3, 0)
    _ = s.press(a[0], a[1])
    _ = s.pan(a[0], a[1] - 30)
    _ = s.pan(b[0], b[1])
    _ = s.release(b[0], b[1])
    assert_equal(count("SELECT notebook_id IS NULL FROM notes WHERE id = " + String(other)), 1)
    paint(s)
    a = place(s, 0, other)
    _ = s.press(a[0], a[1])
    _ = s.pan(900, 500)
    _ = s.release(900, 500)
    assert_equal(count("SELECT notebook_id IS NULL FROM notes WHERE id = " + String(other)), 1)
    s.dropped_us = -1_000_000
    assert_true(row_tap(s, s.notes[1].id), "a click opens")
    # a notebook's card: renamed, moved to another shelf, deleted with its notes back in the Inbox
    s.file_at(other, book)
    paint(s)
    b = place(s, 1, book)
    _ = s.hover(b[0], b[1])
    paint(s)
    var e = place(s, 4, book)
    assert_true(s.tap(e[0], e[1]) and s.book_card == book, "its pencil")
    tap(s, "#rename-notebook")
    s.panel.naming_text = ""
    typed(s, "Renamed é")
    assert_true(s.key("Enter", 0), "named")
    assert_equal(count("SELECT COUNT(*) FROM notebooks WHERE name = 'Renamed é'"), 1)
    s.book_card = book
    paint(s)
    tap(s, "#notebook-picker")
    tap(s, "[Move to 1]")
    assert_equal(count("SELECT COUNT(*) FROM notebooks WHERE category = 'areas' AND id = " + String(book)), 1)
    var rev = count("SELECT revision FROM notes WHERE id = " + String(other))
    s.open(other)
    s.book_card = book
    paint(s)
    tap(s, "#delete-note")
    assert_true(s.book_index(book) < 0 and s.notes[s.note_index(other)].notebook == 0 and count("SELECT COUNT(*) FROM notebooks WHERE id = " + String(book)) == 0, "gone")
    assert_true(count("SELECT notebook_id IS NULL FROM notes WHERE id = " + String(other)) == 1 and count("SELECT revision FROM notes WHERE id = " + String(other)) == rev + 1, "its notes back in the Inbox, a revision on")
    assert_true(s.notes[s.note_index(other)].revision == rev + 1 and s.doc.revision == rev + 1, "and known here: the open note can still be saved")
    assert_equal(count("SELECT COUNT(*) FROM workspace_changes WHERE change_type = 'deleted' AND resource_kind = 'notebook'"), 1)
    s.close()
    print("   dragging rows; a notebook renamed, moved, deleted")


def main() raises:
    _ = private_dir("build/test_pnnotes_cfg")
    _ = setenv("OMX_CONFIG", "build/test_pnnotes_cfg")
    _ = unlink("build/test_pnnotes_cfg/settings.txt")  # (folds a run before remembered)
    default_file()
    fresh()
    fresh_file()
    search()
    deleting()
    filing()
    long_list()
    clearing()
    opens_for_writing()
    input_method()
    over_the_board()
    another_app()
    notebooks()
    dragging_and_notebooks()
    selected()
    pointing()
    print("pnnotes: ok")
