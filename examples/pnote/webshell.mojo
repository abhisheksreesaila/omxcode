# pnote's web look (goal 79): Personal Note's own database (its SQLite schema: notes, notebooks), drawn with the web
# app's chrome from mojoui's generic pieces (mojoui.notesshell, mojoui.pagesheet, mojoui.skin, mojoui.fonttext). This
# file only composes them: which note is open, whether the notes panel shows, where the islands sit, what a tap hits.

from std.collections import Dict
from std.math import floor, ceil
from std.os import getenv, stat
from mojoui.scene import Painter, Scene, KeptPaint
from mojoui.sqlite import Database
from mojoui.json import Json, json_string
from mojoui.skin import Skin, mix, with_alpha
from pnlook import pn_warm_styles, pn_names, pn_panel, pn_skin_cards, skin_named, canvas_dock_items, canvas_more_items, ink_colors, pn_actions
from mojoui.notesshell import (
    Boxes, NotesPanel, PanelNote, PanelNotebook, draw_desk, draw_round_button, draw_title_island, draw_shadows, text_normal,
)
from mojoui.pagesheet import PageSheet
from mojoui.buzanmap import BuzanMap, draw_minimap, map_json_from
from mojoui.omnibar import Omnibar, OmniGroup, OmniRow, OmniPill, relative_time, short_date, utc_epoch
from mojoui.shared import environment
from mojoui.textedit import now_ms
from mojoui.files import write_setting, read_setting
from mojoui.islandcard import IslandCard, CardTile
from mojoui.settingswin import SettingsWindow, SettingsPage, skin_cards
from std.ffi import external_call
from mojoui.notesshell import draw_tool_dock, draw_zoom_island, draw_hint
from mojoui.canvas import rgba
from mojoui.skin import hexc
from mojoui.objectlayer import ObjectLayer, import_json_canvas, import_json_canvas_doc, export_json_canvas, TEXT, STICKY, CH_MOVE
from mojoui.pagedesk import BoardTools, T_BOX
from mojoui.notesshell import draw_selection_bar, DockItem
from mojoui.pagedesk import DeskView, BoardLook, opening_view, draw_page_chrome, PAGE_W, PAGE_H
from mojoui.notesshell import draw_dock, dock_height, draw_history_island, draw_page_zoom, draw_locked_cover
from mojoui.docstore import KeptDocs, SaveTimer, RowSave, SqlArg, save_row, text_arg, int_arg, clock_us, SAVED, CONFLICT
from pnstore import make_notes_file, make_note, drop_note, file_note, make_notebook, change_notebook, drop_notebook
from mojoui.keycaps import keycap, device_name
from mojoui.fonttext import engine
from mojoui.glyphwarm import GlyphWarm
from mojoui.scenewarm import SceneWarm
from mojoui.objectlayer import reading_text
from mojoui.canvasload import OpenBoard, SqlText, skim
from mojoui.files import config_dir
from mojoui.viewsnap import snap_dir_ready, expect_snapshots, snap_forget, fnv
from mojoui.graphemes import typed_text
from mojoui.files import private_dir, private_write, file_exists
from mojoui.notesshell import draw_problem, draw_pill_button, draw_dock_flyout, draw_ink_options, draw_toast, PropsCard, PropsRow
from mojoui.libc import unlink
from mojoui.docstore import OpenDoc, SaveOutbox, Unsaved, row_revision
from mojoui.canvasload import text_hash
from mojoui.json import J_ARRAY, J_STRING
from mojoui.snapahead import snap_ahead
from mojoui.letgo import let_go
from std.os import listdir
from mojoui.framebudget import FrameBudget
from mojoui.pagedesk import board_rect, BOARD_REACH
from mojoui.buzanmap import map_text, node_extra

comptime S_PAGE = 0
comptime S_CANVAS = 1
comptime S_MAP = 2


def read_page_grid(text: String) -> Tuple[Int, Int]:
    """A JSON Canvas's pn.page grid (columns, rows), read from its top-level "pn" member alone (mojoui.canvasload's skim):
    the whole document isn't parsed. (1, 1) when absent."""
    var sk = skim(Int(text.unsafe_ptr()), text.byte_length())
    for ref m in sk.members:
        if m.key == "pn" and m.end > m.start:
            try:
                var pn = Json.parse_bytes(Int(text.unsafe_ptr()) + m.start, m.end - m.start)
                var pg = pn.get(0, "page")
                return (max(1, Int(pn.real(pn.get(pg, "columns"), 1))), max(1, Int(pn.real(pn.get(pg, "rows"), 1))))
            except:
                pass
    return (1, 1)


def grid_note(cols: Int, rows: Int) -> String:
    """A canvas's page grid as kept in its view snapshot's note (D-7956)."""
    return "grid=" + String(cols) + "x" + String(rows)


def parse_grid(note: String) -> Tuple[Int, Int]:
    """grid_note's (columns, rows); (0, 0) when the note isn't one."""
    if not note.startswith("grid="):
        return (0, 0)
    var end = note.find(";")
    var parts = String(note[byte=5:end if end > 0 else note.byte_length()]).split("x")
    if len(parts) != 2:
        return (0, 0)
    try:
        return (max(1, Int(String(parts[0]))), max(1, Int(String(parts[1]))))
    except:
        return (0, 0)


def parse_hash(note: String) -> Int:
    """The fingerprint of the text a kept view was kept of (after grid_note's part; 0: none)."""
    var at = note.find(";")
    if at < 0:
        return 0
    try:
        return Int(String(note[byte=at + 1:]))
    except:
        return 0


comptime LOAD_SLICE_MIN_US = 250  # (D-7957) the least a slice gets (the open still ends: every frame takes a node at least)
comptime FRAME_WORK_US = 3000  # (D-7957) the app's own share of an 8.3 ms frame (the renderer, GPU and compositor the rest)
comptime LOAD_SLICE_US = 500  # (D-7969) the most a progressive open's slice takes a frame: A/B 1500 / 700 / 400 µs: frames during p95 ~11 / ~7 / ~4 ms, complete ~200 / ~450 / ~700 ms (the web: ~1,150)


def guess_emoji(title: String, kind: String) -> String:
    """note_icon.py's guess: the first word it knows, else the kind's default."""
    var table: List[List[String]] = [
        ["✈️", "trip trips travel flight flights holiday vacation lisbon paris"],
        ["🛒", "grocery groceries shopping shop"],
        ["🚀", "startup launch pitch rocket"],
        ["🗓️", "weekly week review calendar schedule planning plan agenda"],
        ["💡", "idea ideas brainstorm inspiration"],
        ["📚", "reading books book library study"],
        ["💼", "work job career office business meeting meetings client"],
        ["💰", "money budget finance finances taxes expenses invoice"],
        ["🍳", "recipe recipes cooking food meal meals dinner"],
        ["🏃", "workout fitness gym run running exercise health"],
        ["🎵", "music song songs playlist"],
        ["🎬", "movie movies film films"],
        ["📷", "photo photos photography camera"],
        ["🏠", "home house chores garden family"],
        ["❤️", "love wedding date dates"],
        ["💻", "code coding programming dev software bug bugs"],
        ["🎓", "school class course courses learning university homework"],
        ["🐾", "pet pets dog cat"],
        ["🚗", "car cars driving"],
        ["✅", "todo todos checklist tasks task"],
        ["🔖", "bookmark bookmarks links link"],
        ["🧪", "experiment experiments lab research"],
        ["📝", "journal diary draft"],
        ["🎯", "goal goals okr okrs target"],
    ]
    var words = title.lower().replace(",", " ").replace(".", " ").split(" ")
    for w in words:
        var word = String(w)
        if word == "":
            continue
        for row in table:
            for cand in row[1].split(" "):
                if String(cand) == word:
                    return row[0]
    if kind == "page":
        return "📄"
    if kind == "canvas":
        return "🎨"
    return "🧠"


def tint_of(emoji: String) -> Int:
    var s = 0
    for c in emoji.codepoints():
        s += Int(c.to_u32())
    return s % 5 + 1


def notebook_icon(name: String) -> String:
    var n = name.lower()
    if "travel" in n or "trip" in n:
        return "plane"
    return ""


def page_markdown(content: String) raises -> String:
    """A page's words (a content that isn't a page's raises: an empty page would be saved over it)."""
    var j = Json.parse(content)
    var m = j.get(0, "markdown")
    if j.kind(m) != J_STRING:
        raise Error("not a page (it has no markdown)")
    return j.text(m)


def read_map(content: String, mut map: BuzanMap) raises -> String:
    """A mind-map note's ideas read into `map` (empty); its root's id. A content that isn't a map's raises."""
    var j = Json.parse(content)
    var nodes = j.get(0, "nodes")
    if j.kind(nodes) != J_ARRAY:
        raise Error("not a mind map (it has no ideas)")
    var ids = List[String]()
    for q in range(j.size(nodes)):
        ids.append(j.text(j.get(j.at(nodes, q), "id")))
    for q in range(j.size(nodes)):
        var nd = j.at(nodes, q)
        var pid = j.text(j.get(nd, "parentId"))
        var par = -1
        for r in range(len(ids)):
            if ids[r] == pid:
                par = r
        _ = map.add(par, j.text(j.get(nd, "text")), j.real(j.get(nd, "x")), j.real(j.get(nd, "y")), hexc(j.text(j.get(nd, "color"), "#3d8fe8")),
                    ids[q], j.real(j.get(nd, "fontSize"), 0), j.flag(j.get(nd, "bold")), j.text(j.get(nd, "font")), node_extra(j, nd))
    var root = j.text(j.get(0, "rootId"), "root")
    map.selected = 0
    for r in range(len(ids)):
        if ids[r] == root:
            map.selected = r
    map.freeze()
    return root


comptime TOAST_UNDELETE = 1
comptime TOAST_UNCLEAR = 2


def has_all(text: String, tokens: List[String]) -> Bool:
    var t = text.lower()
    for k in tokens:
        if t.find(k) < 0:
            return False
    return True


def fts_words(q: String) -> List[String]:
    """The words of what was typed (letters, digits and _ ; services.WORD_PATTERN), for the search index."""
    var out = List[String]()
    var cur = String("")
    for c in q.codepoint_slices():
        var b = c.as_bytes()
        var word = len(b) > 1 or (b[0] >= 48 and b[0] <= 57) or (b[0] >= 65 and b[0] <= 90) or (b[0] >= 97 and b[0] <= 122) or b[0] == 95
        if word:
            cur += String(c)
        elif cur != "":
            out.append(cur)
            cur = ""
    if cur != "":
        out.append(cur)
    return out^


@fieldwise_init
struct NoteRec(Copyable, Movable):
    var id: Int
    var created: String
    var updated: String
    var title: String
    var kind: String
    var content: String
    var notebook: Int
    var emoji: String
    var tint: Int
    var icon_set: Bool  # the note has its own icon (else it is guessed from the title, as note_icon.py does)
    var revision: Int  # the revision this copy was read or last saved at (saves carry it: D-7927)
    var secure: Bool  # a secure note: its words are only sealed; the native app shows it locked and never writes it
    var bytes: Int  # the content's size in the file when last read (what a kept view's name includes)


comptime WARM_OMNI = -1
comptime WARM_CARD = -2
comptime WARM_SETTINGS = -3
comptime WARM_NOTES = 12  # the newest pages and maps readied ahead
comptime WARM_NOTE_BYTES = 65536


struct WebShell(Movable):
    var db_path: String
    var notes: List[NoteRec]
    var panel: NotesPanel
    var page: PageSheet
    var map: BuzanMap
    var sk: Skin
    var current: Int  # note id, 0: none
    var sidebar: Bool
    var boxes: Boxes
    var problem: String
    var searching: Bool
    var card_open: Bool
    var settings_open: Bool
    var omni: Omnibar
    var bench_kind: Int
    var title_focus: Bool  # the title island's button has the keyboard focus (a rename just ended by Enter)
    var px: Float64  # where the pointer is (HOVER), -1: away
    var py: Float64
    var board: OpenBoard  # the open canvas and its progressive open (D-7952): .layer to paint, .edit() to change  # the open canvas note's objects
    var look: BoardLook
    var view: DeskView
    var view_set: Bool
    var cols: Int
    var rows: Int
    var tool: String
    var card: IslandCard
    var tools: BoardTools
    var map_root: String
    var hits: List[Int]  # the omnibar's note rows, as note ids
    var win_w: Float64  # the window's size (layout px) at the last paint
    var win_h: Float64
    var win_k: Float64  # the device scale at the last paint (0: not painted yet)
    var budget: FrameBudget  # (D-7957) the open's slices sized by what the rest of the frame cost
    var warm: GlyphWarm  # (D-8002) the glyphs drawn last time and the look's own styles, readied while nothing happens
    var warm_styles: Bool
    var cold_trace: Bool
    var cold_images: Int
    var cold_shaped: Int
    var frame: KeptPaint  # (D-8024) the canvas's page frame
    var desk: KeptPaint  # (D-8013) the desk's dots, replayed while the window and the skin hold
    var screens: SceneWarm  # (D-8011) the screen being readied
    var to_ready: List[Int]  # the screens still to ready, last first: a note's id, or WARM_OMNI/WARM_CARD/WARM_SETTINGS
    var ready_k: Float64  # the device scale they're readied for (0: not asked yet)
    var doc: OpenDoc  # (review 3) which note is open and whether it was read: what may be edited, kept and saved
    var outbox: SaveOutbox  # edits that couldn't be written, until they land
    var page_src: String  # the open page's or map's content as it was read (a save changes it in place)
    var content_hash: Int  # the open canvas's text's fingerprint (0: not read yet), and the one its kept view was kept of
    var kept_hash: Int
    var opening_rev: Int  # the revision a deferred open began at
    var db_id: String  # the notes file: its path's hash and its inode
    var snap_dir: String  # (D-7956) where each canvas's last view is kept ("": nowhere, MOJOUI_SNAP=0 or no folder)
    var dbs: List[Database]  # the open connection (one, kept)
    var saver: SaveTimer  # the web's save debounce (save-flush.js: 650 ms after the last edit)
    var save_state: String  # "" saved, else the island's error ("Couldn’t save")
    var save_detail: String
    var save_kind: String  # what the pending save writes: page | canvas | mindmap ("" nothing)
    var kept: KeptDocs[ObjectLayer]  # canvases already parsed, by (note, revision) (D-7934)
    var kept_pages: Dict[Int, Int]  # a kept canvas's page grid (columns × 1000 + rows), by note
    var cold_opens: Bool  # (the race's cold-open row: nothing kept is reused)
    var omni_kind: List[Int]  # the omnibar's rows, in order: 0 a note, 1 a notebook, 2 an action, 3 "New note" with the words
    var omni_id: List[Int]  # their note or notebook, or the action's place in pn_actions()
    var toast: String  # the message at the bottom ("" : none), its action, what that does, and when it goes
    var toast_action: String
    var toast_does: Int  # TOAST_UNDELETE | TOAST_UNCLEAR
    var toast_until: Int
    var gone: List[NoteRec]  # the note just deleted, until its toast goes (Undo brings it back); then its row is deleted
    var gone_at: Int
    var props_open: Bool
    var props: PropsCard
    var flyout: Bool  # the canvas dock's more tools, or its colours and widths, are open
    var ink_options: Bool
    var dropped_us: Int  # when a row's drag last ended (the tap that may follow it opens nothing)
    var book_card: Int  # the notebook whose card is open (-1: none)
    var known_seq: Int  # the notes file's change feed, as last seen (-1: not yet)
    var clip: String  # what was copied last, and how many times something was
    var clip_version: Int
    var words_clips: Int
    var words_at: Tuple[Float64, Float64, Float64, Float64]  # the caret of the canvas words being written, on screen
    var doubled_us: Int  # when the last double click came (one more soon after selects the line)
    var bench_note: Int  # (the race's cold opens) the canvas they open, from another note's (D-7951)

    def __init__(out self, db_path: String, skin: String):
        self.db_path = db_path
        self.notes = List[NoteRec]()
        self.panel = NotesPanel(pn_panel())
        self.panel.skin_name = skin
        self.page = PageSheet()
        self.map = BuzanMap()
        self.sk = skin_named(skin)
        self.current = 0
        self.sidebar = False  # (the web opens with the notes panel closed)
        self.boxes = Boxes()
        pn_names(self.boxes)  # (the web app's names for the framework's boxes: the checker compares box for box)
        self.problem = ""
        self.px = -1
        self.py = -1
        self.bench_kind = 0
        self.title_focus = False
        self.searching = False
        self.card_open = False
        self.settings_open = False
        self.omni = Omnibar()
        self.board = OpenBoard()
        self.look = BoardLook()
        self.view = DeskView(0, 0, 1)
        self.view_set = False
        self.cols = 1
        self.rows = 1
        self.tool = "[Text]"
        self.card = IslandCard()
        self.tools = BoardTools()
        self.map_root = "root"
        self.hits = List[Int]()
        self.win_w = 1440
        self.win_h = 900
        self.win_k = 0
        self.warm = GlyphWarm(config_dir("pnote") + "/glyphs.txt")
        self.warm_styles = False
        self.cold_trace = getenv("MOJOUI_COLD_TRACE") == "1"
        self.cold_images = 0
        self.cold_shaped = 0
        self.frame = KeptPaint(4)
        self.desk = KeptPaint(3)
        self.screens = SceneWarm()
        self.to_ready = List[Int]()
        self.ready_k = 0
        self.doc = OpenDoc()
        self.page_src = ""
        self.content_hash = 0
        self.kept_hash = 0
        self.opening_rev = -1
        self.db_id = String(fnv(db_path))
        try:
            self.db_id += "-" + String(Int(stat(db_path).st_ino))
        except:
            pass
        var held_in = config_dir("pnote") + "/unsaved"
        self.outbox = SaveOutbox(held_in if private_dir(held_in) else String(""), String(fnv(db_path)))
        self.outbox.load()
        self.snap_dir = ""
        self.budget = FrameBudget(FRAME_WORK_US)
        if getenv("MOJOUI_SNAP") != "0":
            var root = environment("PNOTE_SNAPS", config_dir("pnote") + "/snaps")
            var d = root + "/" + self.db_id  # (a folder for each notes file: two files' notes share no picture)
            if private_dir(root) and snap_dir_ready(d):
                self.snap_dir = d
                _ = private_write(d + "/of.txt", db_path)
                try:
                    for f in listdir(d):
                        if String(f).endswith(".snap"):
                            expect_snapshots()  # (D-7961: the renderer readies a restore after the first screen)
                            break
                except:
                    pass
        self.dbs = List[Database]()
        self.saver = SaveTimer(650)
        self.save_state = ""
        self.save_detail = ""
        self.save_kind = ""
        self.kept = KeptDocs[ObjectLayer](4)
        self.kept_pages = Dict[Int, Int]()
        self.cold_opens = False
        self.bench_note = -1
        self.doubled_us = -1_000_000
        self.known_seq = -1
        self.dropped_us = -1_000_000
        self.book_card = -1
        self.flyout = False
        self.ink_options = False
        self.clip = ""
        self.clip_version = 0
        self.words_clips = 0
        self.words_at = (-1.0, 0.0, 0.0, 0.0)
        self.omni_kind = List[Int]()
        self.omni_id = List[Int]()
        self.toast = ""
        self.toast_action = ""
        self.toast_does = 0
        self.toast_until = 0
        self.gone = List[NoteRec]()
        self.gone_at = 0
        self.props_open = False
        self.props = PropsCard()
        try:
            self.dbs.append(Database(db_path))
            make_notes_file(self.dbs[0])  # (an empty file: Personal Note's tables; one that has them is left as it is)
            self.dbs[0].map_reads()  # (a 12 MB canvas row copied from mapped pages, not read 4 KB at a time)
            self.load()
            self.recall_folds()
            self.forget_pictures()
        except e:
            self.problem = String(e)
            print("PNOTE ERROR: " + self.problem, flush=True)

    def load(mut self) raises:
        var db = self.dbs[0].copy()  # (a copy shares the connection)
        self.notes.clear()
        var st = db.prepare("SELECT id, title, note_type, content, IFNULL(notebook_id, 0), icon, icon_tint, created_at, updated_at, revision, secure FROM notes ORDER BY updated_at DESC, id DESC")
        while st.step():
            var title = st.text(1)
            var kind = st.text(2)
            var emoji = st.text(5)
            var tint = st.int(6)
            var own = emoji != ""
            if emoji == "":
                emoji = guess_emoji(title, kind)
                tint = tint_of(emoji)
            var secure = st.int(10) != 0
            self.notes.append(NoteRec(st.int(0), st.text(7), st.text(8), title, kind, "" if secure else st.text(3), st.int(4), emoji, tint, own, st.int(9), secure, 0))
        self.list_notes()
        self.panel.notebooks.clear()
        var nb = db.prepare("SELECT id, name, color, category, (SELECT COUNT(*) FROM notes WHERE notebook_id = notebooks.id) FROM notebooks ORDER BY updated_at DESC, id ASC")
        while nb.step():
            self.panel.notebooks.append(PanelNotebook(nb.int(0), nb.text(1), hexc(nb.text(2)), nb.text(3), notebook_icon(nb.text(1)), nb.int(4)))

    def list_notes(mut self):
        """The panel's rows from the notes in memory (newest first)."""
        self.panel.notes.clear()
        for ref n in self.notes:
            self.panel.notes.append(PanelNote(n.id, n.title, n.kind, n.emoji, n.tint, n.notebook))

    def read_row(mut self, i: Int, with_content: Bool = True) -> String:
        """One note's row from the file again (the web fetches a note when it opens it): its content, revision and secure
        flag, so an edit another app saved is what opens and what the next save builds on. "" or why it couldn't be read
        (then nothing here changed: what it knew of the row may be old)."""
        if len(self.dbs) == 0:
            return self.problem if self.problem != "" else String("the notes file isn't open")
        try:
            var q = self.dbs[0].prepare("SELECT " + ("content" if with_content else "''") + ", revision, secure, title, updated_at, IFNULL(octet_length(content), 0) FROM notes WHERE id = ?")
            q.bind(1, self.notes[i].id)
            if not q.step():
                return "this note isn't in the file any more"
            self.notes[i].secure = q.int(2) != 0
            if with_content:
                self.notes[i].content = "" if self.notes[i].secure else q.text(0)
            self.notes[i].revision = q.int(1)
            self.notes[i].title = q.text(3)
            self.notes[i].updated = q.text(4)
            self.notes[i].bytes = q.int(5)
            return ""
        except e:
            print("PNOTE ERROR: read note " + String(self.notes[i].id) + ": " + String(e), flush=True)
            return String(e)

    def locked(self) -> Bool:
        """The open note is a secure one (shown locked: nothing here reads or writes its words)."""
        var i = self.note_index(self.current)
        return i >= 0 and self.notes[i].secure

    def note_index(self, id: Int) -> Int:
        for i in range(len(self.notes)):
            if self.notes[i].id == id:
                return i
        return -1

    def near_rect(self, x: Float64, y: Float64) -> Tuple[Float64, Float64, Float64, Float64]:
        """The page rect round a pointer (window px) the board tools read: a hit test's tolerance and a handle's reach."""
        var pt = self.view.to_page(x, y)
        var m = 24.0 / max(self.view.scale, 0.01)
        return (pt[0] - m, pt[1] - m, pt[0] + m, pt[1] + m)

    def view_rect(self) -> Tuple[Float64, Float64, Float64, Float64]:
        return board_rect(self.view, self.win_w, self.win_h)

    def settle_open(mut self):
        """A deferred open that has landed: the document read (its own page grid, its own text's fingerprint against the kept
        view's) or failed. Nothing to do while it is still being read, or when nothing is opening."""
        if not self.doc.loading() or self.board.pending():
            return
        var i = self.note_index(self.doc.id)
        if i < 0 or self.notes[i].kind != "canvas":
            return
        if self.board.broken:
            var bad = self.board.problem
            self.open_failed(bad)
            return
        var why = self.read_row(i, False)
        if why == "" and self.notes[i].revision != self.opening_rev:  # (another app saved while it was being read: read it again)
            self.doc.begin(-1)
            self.open(self.notes[i].id)
            return
        if why != "":
            self.open_failed(why)
            return
        if self.look.keep_path != "" and self.kept_hash != 0 and self.kept_hash != self.board.text_hash:
            # (the kept view isn't of this text, whatever its key says: gone, from the screen and the disk)
            print("PNOTE: a kept view wasn't of this note's text: dropped", flush=True)
            _ = unlink(self.look.keep_path)
            self.look.keep_path = ""
            self.look.keep_tag = ""
        self.content_hash = self.board.text_hash
        var page = self.board.member("pn")
        var g = page.get(page.get(0, "page"), "columns")
        var cols = max(1, Int(page.real(g, 1)))
        var rows = max(1, Int(page.real(page.get(page.get(0, "page"), "rows"), 1)))
        if cols != self.cols or rows != self.rows:  # (its grid is the document's own)
            self.cols = cols
            self.rows = rows
            self.view = opening_view(self.win_w, self.win_h, Float64(cols) * PAGE_W, Float64(rows) * PAGE_H)
        self.look.keep_note = grid_note(self.cols, self.rows) + ";" + String(self.content_hash)
        self.doc.ready(self.doc.id, self.notes[i].revision)

    def open_failed(mut self, why: String):
        """The open note couldn't be read: shown as that, with a Retry; nothing of the empty screen can be edited, kept or
        saved (OpenDoc, OpenBoard.fail)."""
        print("PNOTE ERROR: open note " + String(self.doc.id) + ": " + why, flush=True)
        self.doc.failed(self.doc.id, why)
        self.board.fail(why)
        self.page.set_markdown("")
        self.map = BuzanMap()
        self.tools = BoardTools()
        self.look.keep_path = ""
        self.look.keep_tag = ""
        self.look.keep_hold = False
        self.saver.done()
        self.save_kind = ""

    def open(mut self, id: Int):
        var i = self.note_index(id)
        if i < 0:
            return
        if len(self.gone) > 0 and id != self.current:  # (another note opens: the held delete is made)
            self.commit_delete()
            i = self.note_index(id)
            if i < 0:
                return
        self.props_open = False
        var t_open = clock_us()
        var trace = getenv("MOJOUI_LOAD_TRACE") == "1"
        self.settle_open()
        self.flush()  # (the outgoing note's pending edits land first, as the web's settleOutgoingNote; one that can't be written is held: SaveOutbox)
        var out_i = self.note_index(self.current)
        if (out_i >= 0 and self.notes[out_i].kind == "canvas" and not self.notes[out_i].secure and self.doc.may_keep(self.current) and self.outbox.find(self.current) < 0
                and self.board.edit().unsaved() == False and self.board.keepable()):
            var moving = self.board.take()  # (the outgoing canvas, whole, kept parsed)
            let_go(self.kept.keep_out(self.notes[out_i].id, self.notes[out_i].revision, moving^))  # (the canvas just left, kept parsed)
            self.kept_pages[self.notes[out_i].id] = self.cols * 1000 + self.rows
        i = self.note_index(id)
        if trace:
            print("OPEN: outgoing " + String(clock_us() - t_open) + " us", flush=True)
        self.doc.begin(id)
        self.current = id
        self.panel.active = id
        self.save_state = ""
        self.save_detail = ""
        self.look.keep_path = ""  # (D-7956: the note's own file below, a canvas only)
        self.look.keep_tag = ""
        self.look.keep_hold = False
        self.look.keep_note = ""
        self.kept_hash = 0
        self.content_hash = 0
        self.page_src = ""
        var was_secure = self.notes[i].secure
        var why = self.read_row(i, False)
        if why != "":
            self.open_failed(why)
            return
        if self.notes[i].secure:  # (its content column is a placeholder: never shown, never edited, never saved; nothing of it kept on disk)
            if not was_secure:
                _ = unlink(self.snap_path(id))
            self.page.set_markdown("")
            self.board.set(ObjectLayer())
            self.board.layer.read_only = True
            self.map = BuzanMap()
            return
        var held = self.outbox.find(id)  # (edits of it that couldn't be written: they are what opens, with why and a Retry)
        var at = -1 if self.cold_opens or held >= 0 else self.kept.find(id, self.notes[i].revision)
        if self.notes[i].kind == "canvas" and at >= 0:
            # the file still holds the revision this canvas was parsed at: reuse it (D-7934), nothing read or parsed
            self.board.set(self.kept.take(at))
            var grid = self.kept_pages.get(id, 1001)
            self.cols = grid // 1000
            self.rows = grid % 1000
            self.view_set = False
            self.tools = BoardTools()
            self.sticky_look()
            self.doc.ready(id, self.notes[i].revision)
            return
        if self.notes[i].kind == "canvas" and self.snap_dir != "" and held < 0:
            var path = self.snap_path(id)
            var tag = self.snap_tag(i)
            var head = self.look.kept_head(path)  # (the file's head, read once)
            var note = self.look.head_note(head, tag)
            var grid = parse_grid(note)
            if grid[0] > 0:  # (its last view is kept: the page grid from it, the view laid out, the key asked)
                var view = opening_view(self.win_w, self.win_h, Float64(grid[0]) * PAGE_W, Float64(grid[1]) * PAGE_H)
                if self.win_k > 0 and self.look.head_shows(head, tag, view, self.win_w, self.win_h, self.win_k):
                    snap_ahead(path)  # (read while this frame is laid out: D-8015)
                    # the deferred open: the kept view shows this frame, the row is read, skimmed and the view's nodes
                    # parsed on a job thread (OpenBoard.open_later); the board loads underneath, held until they're in. The
                    # grid is the document's as soon as it is in (settle_open), and nothing is saved from this one
                    self.cols = grid[0]
                    self.rows = grid[1]
                    self.kept_hash = parse_hash(note)
                    self.opening_rev = self.notes[i].revision
                    self.view = view
                    self.view_set = True
                    self.tools = BoardTools()
                    self.sticky_look()
                    self.look.keep_path = path
                    self.look.keep_tag = tag
                    self.look.keep_note = note
                    self.look.keep_hold = True
                    var r = self.view_rect()
                    self.board.open_later(SqlText(self.db_path, "SELECT content FROM notes WHERE id = ? AND secure = 0", id), r[0], r[1], r[2], r[3], 6)
                    if trace:
                        print("OPEN: deferred (kept view) " + String(clock_us() - t_open) + " us", flush=True)
                    return
        var content = String("")
        var revision = self.notes[i].revision
        if held >= 0:
            content = self.outbox.items[held].content
            revision = self.outbox.items[held].revision
            self.notes[i].revision = revision  # (what its edits build on)
            self.save_state = "Couldn’t save"
            self.save_detail = self.outbox.items[held].why
        else:
            why = self.read_row(i, True)
            if why == "" and self.notes[i].secure:
                why = "this note was locked just now"
            if why != "":
                self.open_failed(why)
                return
            revision = self.notes[i].revision
            swap(content, self.notes[i].content)  # (the open document holds its text; the note's copy isn't read again)
        if trace:
            print("OPEN: rows read " + String(clock_us() - t_open) + " us", flush=True)
        var kind = self.notes[i].kind
        try:
            if kind == "page":
                var words = page_markdown(content)
                self.page = PageSheet()
                self.page.set_markdown(words)
                self.page.load_ink(content)
                self.page_src = content^
            elif kind == "canvas":
                self.open_canvas(i, content^, held >= 0)
            elif kind == "mindmap":
                self.map = BuzanMap()
                self.map_root = read_map(content, self.map)
                self.page_src = content^
            else:
                raise Error("a kind of note this app doesn't know (" + kind + ")")
        except e:
            self.open_failed(String(e))
            return
        if trace:
            print("OPEN: first slice " + String(clock_us() - t_open) + " us", flush=True)
        self.doc.ready(id, revision)

    def open_canvas(mut self, i: Int, var text: String, held: Bool) raises:
        """A canvas note from its text: (D-7944) progressively: the document skimmed, the page grid read, the nodes the
        opening view shows parsed now (every core), the rest a slice a frame (paint); anything that changes or reads all
        of it goes through OpenBoard.edit(). One the skim can't open is imported whole (and raises when it isn't a canvas)."""
        var id = self.notes[i].id
        if text == "":
            raise Error("the note is empty")
        # (the page grid first: the opening view, and so the first slice, depend on it)
        var grid = read_page_grid(text)
        self.cols = grid[0]
        self.rows = grid[1]
        self.tools = BoardTools()
        self.sticky_look()
        self.view = opening_view(self.win_w, self.win_h, Float64(self.cols) * PAGE_W, Float64(self.rows) * PAGE_H)
        self.view_set = True
        self.content_hash = text_hash(text)
        var r = self.view_rect()
        var back = self.board.open(text^, r[0], r[1], r[2], r[3], 6)
        if back != "":
            var j = Json.parse(back)  # (parsed once: the objects and the page grid, D-7941)
            var layer = import_json_canvas_doc(j, back)
            layer.set_connector_gap(6)
            layer.mark_saved()  # (what the file holds: unchanged until edited)
            self.board.set(layer^)
        if held:  # (edits that aren't in the file: not "saved")
            self.board.edit().saved_version = -1
        elif self.snap_dir != "":  # (its view kept once it settles, for the next open: D-7956)
            self.look.keep_path = self.snap_path(id)
            self.look.keep_tag = self.snap_tag(i)
            self.look.keep_note = grid_note(self.cols, self.rows) + ";" + String(self.content_hash)

    def snap_path(self, id: Int) -> String:
        return self.snap_dir + "/note-" + String(id) + ".snap" if self.snap_dir != "" else String("")

    def snap_tag(self, i: Int) -> String:
        """What a canvas's kept view depends on besides the view (the renderer adds zoom, view, size, GPU, build): the notes
        file (its path and inode: the folder too is this file's own), the note, its revision, when and how big it was saved,
        the skin. A copy or a restored backup of the file has another inode or another row; and whatever the key says, the
        text's own fingerprint, kept with the view, is compared when the text is in (settle_open)."""
        ref n = self.notes[i]
        return "pnote;db=" + self.db_id + ";note=" + String(n.id) + ";rev=" + String(n.revision) + ";at=" + n.updated + ";bytes=" + String(n.bytes) + ";skin=" + self.panel.skin_name

    def forget_pictures(mut self):
        """Kept views of notes that were deleted or locked since, and of notes files that are gone: removed from the disk."""
        if self.snap_dir == "":
            return
        var keep = List[String]()
        for ref n in self.notes:
            if n.kind == "canvas" and not n.secure:
                keep.append("note-" + String(n.id) + ".snap")
        _ = snap_forget(self.snap_dir, keep)
        var root = String(self.snap_dir[byte=0:self.snap_dir.rfind("/")])
        try:
            for f in listdir(root):  # (one folder per notes file, each naming it; a picture straight in here is an older build's)
                var name = String(f)
                if name.endswith(".snap") or name.endswith(".tmp"):
                    _ = unlink(root + "/" + name)
                    continue
                var path = String("")
                try:
                    with open(root + "/" + name + "/of.txt", "r") as g:
                        path = String(g.read().strip())
                except:
                    continue
                if path != "" and not file_exists(path):
                    _ = snap_forget(root + "/" + name, List[String]())
        except:
            pass

    def set_skin(mut self, name: String):
        self.sk = skin_named(name)
        self.panel.skin_name = name
        self.sticky_look()
        write_setting("pnote", "skin", name)  # (the web keeps it in localStorage: it survives a reload)

    def sticky_look(mut self):
        """New stickies in the skin's first colour, their words a deep shade of it (objects.js stickyInk: each channel × .16)."""
        var f = self.sk.c1
        self.tools.sticky_fill = f
        var r = Int(Float64(Int(f & 0xFF)) * 0.16 + 0.5)
        var g = Int(Float64(Int((f >> 8) & 0xFF)) * 0.16 + 0.5)
        var b = Int(Float64(Int((f >> 16) & 0xFF)) * 0.16 + 0.5)
        self.tools.sticky_ink = rgba(r, g, b)

    # ------------------------------------------------ drawing

    def paint[P: Painter](mut self, mut p: P, w: Float64, h: Float64, k: Float64):
        self.budget.begin()  # (D-7957: what this frame's own work costs sets the next open slice)
        if self.cold_trace:  # (MOJOUI_COLD_TRACE=1, diagnosis: first-time work since the last paint: glyphs rastered, runs shaped)
            var e = engine()
            print("COLD: note " + String(self.current) + " since the last paint: glyph images " + String(len(e[].image_of) - self.cold_images) + ", runs shaped " + String(e[].shapings - self.cold_shaped)
                  + ", chrome replays " + String(self.frame.replays) + " draws " + String(self.frame.draws), flush=True)
            self.cold_images = len(e[].image_of)
            self.cold_shaped = e[].shapings
        self._paint(p, w, h, k)
        self.budget.end()

    def _paint[P: Painter](mut self, mut p: P, w: Float64, h: Float64, k: Float64):
        self.boxes.clear()
        self.boxes.add("#app", 0, 0, w, h)
        var cover = List[Float64]()  # (the opaque page or map host drawn over the desk, inside its rounded corners)
        var ci = self.note_index(self.current)
        if ci >= 0 and self.notes[ci].kind != "canvas" and not self.notes[ci].secure and not self.doc.is_failed():
            var m = self.sk.radius + 1
            cover = [(296.0 if self.sidebar else 0.0) + 4 + m, 66 + m, w - 12 - m, h - 12 - m]
        if self.desk.begin(p, "desk", self.panel.skin_name + "|" + String(w) + "|" + String(h) + "|" + String(k) + "|" + (String(cover[0]) if len(cover) == 4 else String("")), k):
            draw_desk(p, w, h, k, self.sk, cover)
            self.desk.end(p)
        p.begin_layer("shell")
        p.layer_transform(0, 0, k)
        self.win_w = w
        self.win_h = h
        self.win_k = k
        if not self.warm_styles:
            self.warm_styles = True
            for st in pn_warm_styles():
                self.warm.add_ascii(st, k)
        var left = 296.0 if self.sidebar else 0.0
        var i = self.note_index(self.current)
        if i >= 0 and self.notes[i].kind == "canvas" and not self.notes[i].secure and not self.doc.is_failed():
            # the board under every island: the page frame (screen px), the objects (a layer in page px), then the chrome
            if not self.view_set:
                self.view = opening_view(w, h, Float64(self.cols) * PAGE_W, Float64(self.rows) * PAGE_H)
                self.view_set = True
            draw_page_chrome(p, self.boxes, self.view, w, h, self.cols, self.rows, PAGE_W, PAGE_H, k, self.sk, self.frame)
            var r = self.view_rect()
            if self.board.loading():  # (D-7944: a slice of the rest of the board this frame, the view's part first)
                var ts = clock_us()
                var more = self.board.step(r[0], r[1], r[2], r[3], self.budget.slice_us(LOAD_SLICE_MIN_US, LOAD_SLICE_US))
                self.budget.spent(clock_us() - ts)
                if more:
                    p.set_again()
            self.settle_open()  # (a deferred open that has landed: read, or failed)
            self.look.reach = 0 if self.board.loading() else BOARD_REACH
            if self.look.keep_path != "":  # (D-7956) the kept view: shown while the view's nodes load, kept again when settled
                self.look.keep_hold = self.board.holding(r[0], r[1], r[2], r[3])
                var still = len(self.tools.lifted(self.board.layer)) == 0 and not self.board.layer.unsaved() and self.save_kind == ""  # (a selection is drawn above the board: its pixels unchanged)
                if still and self.look.keep_tag == "" and not self.board.loading():
                    self.look.keep_tag = self.snap_tag(i)  # (saved again: its revision moved on)
                elif not still:
                    self.look.keep_tag = ""
            self.look.paint(p, self.board.layer, self.view, w, h, k, self.tools.lifted(self.board.layer))
            self.tools.paint_overlay(p, self.look, self.board.layer, self.view, k)
            if self.tools.editing != -1:
                self.words_at = self.tools.words_caret(self.board.layer, self.view)
            p.begin_layer("chrome")
            p.layer_transform(0, 0, k)
        if i >= 0 and self.notes[i].secure:  # (the web's cover sits in the workspace, under the islands and the panel)
            draw_locked_cover(p, self.boxes, left, 0, w - left, h, self.notes[i].title, "Locked note", "Secure note · not in the native app yet", k, self.sk)
        if self.sidebar:
            self.panel.draw(p, self.boxes, k, self.sk, h)
        draw_round_button(p, self.boxes, "#toggle-sidebar", 16, 16, "panel-left", k, self.sk, self.sk.toggle_on if self.sidebar else self.sk.panel,
                          44, not self.sidebar and not self.searching and not self.settings_open and _in(self.px, self.py, 16, 16, 44))
        draw_round_button(p, self.boxes, "#search-button", w - 60, 16, "search", k, self.sk, self.sk.panel, 44, not self.searching and not self.settings_open and _in(self.px, self.py, w - 60, 16, 44))  # (an overlay takes the pointer)
        if i >= 0:
            ref n = self.notes[i]
            var island_emoji = n.emoji if n.kind != "page" else String("")
            if not self.card_open:
                draw_title_island(p, self.boxes, left + 16, w - 16, n.title, island_emoji, self.sk.tint(n.tint), k, self.sk, n.emoji, self.title_focus)
            self.boxes.add("#workspace", left, 0, w - left, h)
            if self.doc.is_failed():
                draw_problem(p, self.boxes, left, 0, w - left, h, "This note couldn’t be opened", self.doc.problem + " Nothing in it has been changed.", "Retry", "#open-retry", self.sk)
            elif n.kind == "mindmap" and not n.secure:
                var mw = w - left - 4 - 12
                var mh = h - 66 - 12
                self.map.draw(p, self.boxes, left + 4, 66, mw, mh, 0, self.sk, n.title)
                var fv = self.map.view(mw, mh)
                draw_minimap(self.map, p, self.boxes, left + 4 + mw - 16 - 170, 66 + mh - 72 - 102, mw, mh, self.sk)
                draw_tool_dock(p, self.boxes, w - 72, (h - 410) / 2, ["Add image", "Import JSON", "Export JSON", "Export PNG", "", "Undo", "Redo", "", "Clean up layout", "Fit map"],
                               ["image-plus", "folder-open", "braces", "image-down", "", "undo-2", "redo-2", "", "wand-sparkles", "scan"], k, self.sk, "#mindmap-rail-actions")
                draw_zoom_island(p, self.boxes, left + 4 + mw - 16 - 132, 66 + mh - 16 - 42, Int(fv[0] * 100 + 0.5), k, self.sk)
                draw_hint(p, self.boxes, left + 4 + mw / 2, 66 + mh - 18 - 28, "Drag an anchor to draw. Hold an idea to switch Box or Branch.", self.sk)
            if n.kind == "canvas" and not n.secure and not self.doc.is_failed():
                self.boxes.add("#paper", left, 0, w - left, h)
                self.boxes.add("#leafer-host", left, 0, w - left, h)
                self.boxes.add("#note-input", left, 0, w - left, h)
                var items = canvas_dock_items(self.tools.pen_color)
                var active = self.dock_name()
                if active == "#dock-more":  # (a tool from the flyout shows in its place)
                    items[8].icon = "circle cx=5.5 cy=18.5 r=2|circle cx=18.5 cy=5.5 r=2|path d=M7.5 16.5c4-1 3-8 9-9"
                draw_dock(p, self.boxes, w - 72, 72 + (h - 144 - dock_height(items)) / 2, items, active, k, self.sk, "#dock-canvas")
                if len(self.board.layer.selected) > 0 and self.tools.editing == -1:
                    _ = draw_selection_bar(p, self.boxes, left + (w - left) / 2, 64, ["Back", "Forward", "Lock", "Link to words", "Delete"], k, self.sk)
                var dock_y = 72 + (h - 144 - dock_height(items)) / 2
                if self.flyout:
                    draw_dock_flyout(p, self.boxes, w - 72 - 18, dock_y + dock_height(items) - 190, canvas_more_items(), active if self.tools.tool != "highlight" else String("[Highlighter]"), k, self.sk)
                elif self.ink_options:
                    var pen = self.tools.tool == "pen"
                    var marker = self.tools.tool == "highlight"
                    var widths = List[Float64]()
                    if pen:
                        widths = [1.0, 3.0, 6.0, 10.0]
                    elif marker:
                        widths = [10.0, 20.0, 32.0, 48.0]
                    draw_ink_options(p, self.boxes, w - 72 - 18, dock_y + 150, "Colors" if len(widths) == 0 else "Colors and widths", ink_colors(), self.tools.pen_color, widths,
                                     self.tools.pen_width if pen else self.tools.marker_width, self.sk)
                draw_history_island(p, self.boxes, left + 16, h - 16 - 48, k, self.sk)
                draw_page_zoom(p, self.boxes, w - 16, h - 16 - 48, Int(self.view.scale * 100 + 0.5), k, self.sk)
            if n.kind == "page" and not n.secure and not self.doc.is_failed():
                self.page.draw(p, self.boxes, left + 4, 66, w - 12, h - 12, k, n.emoji, self.sk.tint(n.tint), self.sk.radius)
        if self.save_state != "":  # (the web puts a failed save in its island: "Couldn’t save", the reason, Retry)
            draw_hint(p, self.boxes, left + (w - left) / 2, h - 18 - 28 - 40, self.save_state + " · " + self.save_detail, self.sk)
            var held_at = self.outbox.find(self.current)
            if held_at >= 0 and self.outbox.items[held_at].conflict:  # (another app saved first: these edits can't go on top of its)
                draw_pill_button(p, self.boxes, "#save-copy", left + (w - left) / 2, h - 18 - 28 - 40 + 34, "Save a copy", self.sk)
            else:
                draw_pill_button(p, self.boxes, "#save-retry", left + (w - left) / 2, h - 18 - 28 - 40 + 34, "Retry", self.sk)
        self.paint_overlays(p, w, h, k)

    def paint_overlays[P: Painter](mut self, mut p: P, w: Float64, h: Float64, k: Float64):
        var i = self.note_index(self.current)
        if (self.card_open and i >= 0) or self.searching or self.settings_open or self.toast != "" or (self.props_open and i >= 0) or self.book_card >= 0:  # (a layer of their own: opening one leaves the shell's batches as they are)
            p.begin_layer("overlay")
            p.layer_transform(0, 0, k)
        if self.card_open and i >= 0:
            ref c = self.card
            c.status = "Saved on this " + device_name() if self.save_state == "" else self.save_state
            c.status_dot = self.sk.c2
            c.place = "Inbox"
            for ref nb in self.panel.notebooks:
                if nb.id == self.notes[i].notebook:
                    c.place = nb.name
            c.wide_id = "#share-focus"
            c.wide_label = "Focus"
            c.wide_icon = "focus"
            c.wide_key = keycap(".")
            c.tiles.clear()
            var ids: List[String] = ["#share-print", "#share-png", "#share-backup", "#share-markdown", "#share-vault", "#share-icon", "#share-link", "#share-props", "#top-properties", "#clear-note"]
            var labels: List[String] = ["Print", "Picture", "Backup", "Markdown", "Obsidian", "Icon", "Link note", "Properties", "Settings", "Clear all"]
            var icons: List[String] = ["printer", "image-down", "archive", "file-down", "folder-down", "wand-sparkles", "link", "file-text", "sliders-horizontal", "eraser"]
            for t in range(len(ids)):
                c.tiles.append(CardTile(ids[t], labels[t], icons[t], t == 9))
            c.draw(p, self.boxes, (296.0 if self.sidebar else 0.0) + 16, w - 16, k, self.sk)
        var bi = self.book_index(self.book_card)
        if bi >= 0:
            ref pc = self.props
            pc.label = "Shelf"
            pc.places.clear()
            pc.place_colors.clear()
            for k_ in range(len(self.panel.cfg.shelves)):
                pc.places.append(self.panel.cfg.shelves[k_].label)
                pc.place_colors.append(self.panel.notebooks[bi].color)
                if self.panel.cfg.shelves[k_].key == self.panel.notebooks[bi].category:
                    pc.place = k_
            pc.facts = [PropsRow(self.panel.notebooks[bi].name, String(self.panel.notebooks[bi].count) + (" note" if self.panel.notebooks[bi].count == 1 else " notes"))]
            pc.rename_label = "Rename"
            pc.danger_label = "Delete notebook"
            pc.draw(p, self.boxes, 296 + 16 + 160, 120, k, self.sk)
        elif self.props_open and i >= 0:
            ref pc = self.props
            pc.label = "Notebook"
            pc.rename_label = ""
            pc.places = ["Inbox"]
            pc.place_colors = [UInt32(0)]
            pc.place = 0
            for k_ in range(len(self.panel.notebooks)):
                pc.places.append(self.panel.notebooks[k_].name)
                pc.place_colors.append(self.panel.notebooks[k_].color)
                if self.panel.notebooks[k_].id == self.notes[i].notebook:
                    pc.place = k_ + 1
            pc.facts = [PropsRow("Page" if self.notes[i].kind == "page" else ("Canvas" if self.notes[i].kind == "canvas" else "Mind map"), "Expands automatically"), PropsRow("Storage", "On this device")]
            pc.danger_label = "Delete note"
            pc.draw(p, self.boxes, (296.0 if self.sidebar else 0.0) / 2 + w / 2, 72, k, self.sk)
        if self.toast != "":
            _ = draw_toast(p, self.boxes, w / 2, h - 96, self.toast, self.toast_action, self.sk)
        if self.searching:
            self.omni.draw(p, self.boxes, w, h, k, self.sk)
        if self.settings_open:
            var sw = SettingsWindow()
            var g1 = List[SettingsPage]()
            g1.append(SettingsPage("Appearance", "sun", "How Personal Note looks. A skin applies at once.", ("Paper" if self.panel.skin_name == "paper" else ("Night" if self.panel.skin_name == "night" else "Crayon"))))
            g1.append(SettingsPage("Writing", "pen-line", "Fonts and sizes for what you write.", "Mono · 24"))
            var g2 = List[SettingsPage]()
            g2.append(SettingsPage("AI", "sparkles", "Not in the native app yet.", "Claude Code"))
            g2.append(SettingsPage("Plugins", "layout-grid", "Not in the native app yet.", "3 on"))
            g2.append(SettingsPage("Voice", "mic", "Not in the native app yet.", "Not installed"))
            g2.append(SettingsPage("Search by meaning", "globe", "Not in the native app yet.", "Not installed"))
            g2.append(SettingsPage("X bookmarks", "bookmark", "Not in the native app yet.", "Not connected"))
            var g3 = List[SettingsPage]()
            g3.append(SettingsPage("Locked notes", "lock", "Not in the native app yet.", ""))
            g3.append(SettingsPage("Advanced", "gauge", "Not in the native app yet.", ""))
            sw.groups.append(g1^)
            sw.groups.append(g2^)
            sw.groups.append(g3^)
            var body = sw.draw(p, self.boxes, w, h, k, self.sk)
            var cards = pn_skin_cards()
            skin_cards(p, self.boxes, body[0], body[1], body[2], k, self.sk, self.panel.skin_name, cards[0], cards[1])

    def readying(self) -> Bool:
        """Something is left to ready while nothing happens (the glyphs drawn last time, the screens likely next)."""
        return self.warm.more() or (getenv("MOJOUI_SCENEWARM") != "0" and (self.win_k <= 0 or self.ready_k != self.win_k or self.screens.more() or len(self.to_ready) > 0))

    def ready_step(mut self):
        """An idle tick: ≤ 4 ms of glyphs, then a screen's painting (one) or ≤ 4 ms of its text; nothing for 300 ms after
        input. The overlays first, then the newest pages and mind maps: what their first frame would otherwise pay for."""
        if self.warm.more():
            _ = self.warm.idle_step(4000)
            return
        if not self.warm.quiet() or self.win_k <= 0 or getenv("MOJOUI_SCENEWARM") == "0":
            return
        if self.ready_k != self.win_k:
            self.ready_k = self.win_k
            self.to_ready.clear()
            var notes = List[Int]()
            for ref n in self.notes:
                if not n.secure and n.id != self.current and (n.kind == "canvas" or n.content.byte_length() <= WARM_NOTE_BYTES) and len(notes) < WARM_NOTES:
                    notes.append(n.id)
            for q in range(len(notes)):
                self.to_ready.append(notes[len(notes) - 1 - q])
            self.to_ready += [WARM_SETTINGS, WARM_CARD, WARM_OMNI]
        if self.screens.more():
            _ = self.screens.step(4000)
        elif len(self.to_ready) > 0:
            self.screens.take(self.unseen(self.to_ready.pop()))
        if not self.readying() and getenv("MOJOUI_GLYPHWARM_LOG") == "1":
            print("SCENEWARM: " + String(self.screens.runs) + " runs ready in " + String(self.screens.ms) + " ms", flush=True)

    def unseen(mut self, what: Int) -> Scene:
        """A screen painted into a scene nobody shows; the app's state as it was after."""
        var sc = Scene(Int(self.win_w * self.win_k + 0.5), Int(self.win_h * self.win_k + 0.5), self.win_k)
        sc.begin_layer("shell")
        sc.layer_transform(0, 0, self.win_k)
        var bx = Boxes()
        swap(bx, self.boxes)
        var id = self.current
        if what == WARM_OMNI or what == WARM_CARD or what == WARM_SETTINGS:
            var was: List[Bool] = [self.searching, self.card_open, self.settings_open]
            self.card_open = what == WARM_CARD
            self.settings_open = what == WARM_SETTINGS
            self.searching = what == WARM_OMNI and not was[0]
            if self.searching:
                self.omni.query = ""
                self.search()
            self.paint_overlays(sc, self.win_w, self.win_h, self.win_k)
            self.searching = was[0]
            self.card_open = was[1]
            self.settings_open = was[2]
        else:
            var i = self.note_index(what)
            if i >= 0 and not self.notes[i].secure and not self.searching and not self.settings_open and not self.card_open:
                self.current = what
                var doc = OpenDoc()  # (painted as if open: nothing of it can be edited or saved from here)
                doc.begin(what)
                doc.ready(what, self.notes[i].revision)
                swap(doc, self.doc)
                if self.notes[i].kind == "page":
                    var pg = PageSheet()
                    try:
                        pg.set_markdown(page_markdown(self.notes[i].content))
                    except:
                        pass
                    swap(pg, self.page)
                    self._paint(sc, self.win_w, self.win_h, self.win_k)
                    swap(pg, self.page)
                elif self.notes[i].kind == "canvas":
                    self._unseen_board(sc, i)
                else:
                    var mp = BuzanMap()
                    try:
                        _ = read_map(self.notes[i].content, mp)
                    except:
                        pass
                    swap(mp, self.map)
                    self._paint(sc, self.win_w, self.win_h, self.win_k)
                    swap(mp, self.map)
                swap(doc, self.doc)
        self.current = id
        swap(bx, self.boxes)
        return sc^

    def _unseen_board(mut self, mut sc: Scene, i: Int):
        """Canvas note i painted at its opening view into sc, on a board, look and tools of its own."""
        var bd = OpenBoard()
        var cols = 1
        var rows = 1
        if self.notes[i].content.byte_length() <= WARM_NOTE_BYTES:
            try:
                var j = Json.parse(self.notes[i].content)
                bd.set(import_json_canvas_doc(j, ""))
                bd.layer.set_connector_gap(6)
                var pg = j.get(j.get(0, "pn"), "page")
                cols = max(1, Int(j.real(j.get(pg, "columns"), 1)))
                rows = max(1, Int(j.real(j.get(pg, "rows"), 1)))
            except:
                pass
        else:  # (a big board: its frame, dock and labels alone, at the page grid its kept view remembers: its first frame is that view)
            var grid = parse_grid(self.look.kept_note(self.snap_path(self.notes[i].id), self.snap_tag(i)))
            cols = max(1, grid[0])
            rows = max(1, grid[1])
        var look = BoardLook()
        var tools = BoardTools()
        var view = self.view
        var view_set = self.view_set
        self.view_set = False
        swap(bd, self.board)
        swap(look, self.look)
        swap(tools, self.tools)
        swap(cols, self.cols)
        swap(rows, self.rows)
        self._paint(sc, self.win_w, self.win_h, self.win_k)
        swap(bd, self.board)
        swap(look, self.look)
        swap(tools, self.tools)
        swap(cols, self.cols)
        swap(rows, self.rows)
        self.view = view
        self.view_set = view_set

    def now(self) -> Int:
        """The clock (PNOTE_NOW: a fixed UTC time, for comparing with a reference shot then)."""
        var fixed = environment("PNOTE_NOW", "")
        if fixed != "":
            return utc_epoch(fixed)
        return Int(external_call["time", Int](0))

    def search(mut self):
        """The omnibar's groups for the query, as the web's omnibar builds them: notes whose title holds every word, notes
        whose words do (the search index), notebooks, actions; nothing typed: the recent notes and the actions; nothing
        found: a "New note" row with the words."""
        var o = self.omni.pill
        var q = String(self.omni.query.strip())
        var tokens = List[String]()
        for t in q.lower().split(" "):
            if String(t) != "":
                tokens.append(String(t))
        self.omni_kind.clear()
        self.omni_id.clear()
        self.hits.clear()
        var notes = List[OmniRow]()
        var note_ids = List[Int]()
        var words = List[OmniRow]()
        var word_ids = List[Int]()
        var books = List[OmniRow]()
        var book_ids = List[Int]()
        var acts = List[OmniRow]()
        var act_ids = List[Int]()
        if len(tokens) == 0:
            for i in range(min(len(self.notes), 8 if o == 1 else 4)):
                notes.append(self.note_row(i, ""))
                note_ids.append(self.notes[i].id)
        else:
            var sn_id = List[Int]()
            var sn = List[String]()
            self.word_hits(q, sn_id, sn)
            for i in range(len(self.notes)):
                if len(notes) < 8 and has_all(self.notes[i].title, tokens):
                    var ex = String("")
                    for k in range(len(sn_id)):
                        if sn_id[k] == self.notes[i].id and not self.notes[i].secure:
                            ex = sn[k]
                    notes.append(self.note_row(i, ex))
                    note_ids.append(self.notes[i].id)
            for k in range(len(sn_id)):
                var i = self.note_index(sn_id[k])
                if i < 0 or sn_id[k] in note_ids:
                    continue
                if sn[k] != "" and not self.notes[i].secure:
                    words.append(self.note_row(i, sn[k]))
                    word_ids.append(sn_id[k])
                else:
                    notes.append(self.note_row(i, ""))
                    note_ids.append(sn_id[k])
        for ref nb in self.panel.notebooks:
            if len(tokens) == 0 and o != 2 or not has_all(nb.name, tokens):
                continue
            books.append(OmniRow("", "book", nb.color, nb.name, "Notebook · " + String(nb.count) + (" note" if nb.count == 1 else " notes"), "", 0, ""))
            book_ids.append(nb.id)
        var actions = pn_actions()
        for a in range(len(actions)):
            if has_all(actions[a].title + " " + actions[a].keywords, tokens) and (len(tokens) > 0 or o == 3 or actions[a].top):
                acts.append(OmniRow("", actions[a].icon, 0, actions[a].title, "", "", 0, ""))
                act_ids.append(a)
        self.omni.pills.clear()
        self.omni.pills.append(OmniPill("All", ""))
        self.omni.pills.append(OmniPill("Notes", String(len(notes) + len(words)) if q != "" else String("")))
        self.omni.pills.append(OmniPill("Notebooks", String(len(books)) if q != "" else String("")))
        self.omni.pills.append(OmniPill("Actions", String(len(acts)) if q != "" else String("")))
        self.omni.groups.clear()
        if o == 0 or o == 1:
            self._group("Notes" if q != "" else "Recent", notes, note_ids, 0)
            self._group("In your words", words, word_ids, 0)
        if o == 0 or o == 2:
            self._group("Notebooks", books, book_ids, 1)
        if o == 0 or o == 3:
            self._group("Actions", acts, act_ids, 2)
        for k in range(len(self.omni_kind)):
            if self.omni_kind[k] == 0:
                self.hits.append(self.omni_id[k])
        self.omni.none_words = ""
        if len(self.omni_kind) == 0:
            self.omni.none_words = "Nothing matches “" + q + "”" if q != "" else String("Nothing here yet")
            self.omni.none_sub = "Secure notes match by title only."
            if q != "" and (o == 0 or o == 1):
                self._group("", [OmniRow("", "plus", 0, "New note “" + q + "”", "", "", 0, "")], [0], 3)
        self.omni.selected = 0
        self.omni_facts()

    def _group(mut self, title: String, rows: List[OmniRow], ids: List[Int], kind: Int):
        if len(rows) == 0:
            return
        self.omni.groups.append(OmniGroup(title, rows.copy()))
        for id in ids:
            self.omni_kind.append(kind)
            self.omni_id.append(id)

    def note_row(self, i: Int, excerpt: String) -> OmniRow:
        ref n = self.notes[i]
        var place = String("Inbox")
        var dot = self.sk.accent if n.notebook != 0 else self.sk.ink
        for ref nb in self.panel.notebooks:
            if nb.id == n.notebook:
                place = nb.name
                dot = nb.color
        var sub = excerpt
        if sub == "":
            sub = "Page" if n.kind == "page" else ("Canvas" if n.kind == "canvas" else "Mind map")
        return OmniRow(n.emoji if not n.secure else String("🔒"), "", self.sk.tint(n.tint), n.title, sub if not n.secure else String("Secure note · not in the native app yet"), place, dot,
                       relative_time(n.updated, self.now()))

    def word_hits(mut self, q: String, mut ids: List[Int], mut excerpts: List[String]):
        """The notes whose words hold every typed word (services.search: FTS5, best first, 30 at most), with a piece of the
        text around them ("" when only the title matched)."""
        if len(self.dbs) == 0:
            return
        var match_ = String("")
        for t in fts_words(q):
            match_ += ("" if match_ == "" else " AND ") + '"' + t + '"'
        if match_ == "":
            return
        try:
            var st = self.dbs[0].prepare("SELECT CAST(note_search.note_id AS INTEGER), snippet(note_search, 2, '', '', ' … ', 18) FROM note_search JOIN notes ON notes.id = CAST(note_search.note_id AS INTEGER) WHERE note_search MATCH ? ORDER BY bm25(note_search), notes.updated_at DESC LIMIT 30")
            st.bind(1, match_)
            while st.step():
                ids.append(st.int(0))
                excerpts.append(" ".join(st.text(1).split()))
        except e:
            print("PNOTE ERROR: search: " + String(e), flush=True)

    def omni_facts(mut self):
        """The preview's facts for the selected row."""
        var k = self.omni.selected
        self.omni.preview_kind = ""
        if k >= 0 and k < len(self.omni_kind) and self.omni_kind[k] == 0:
            var i = self.note_index(self.omni_id[k])
            if i >= 0:
                ref n = self.notes[i]
                self.omni.preview_kind = "Page" if n.kind == "page" else ("Canvas" if n.kind == "canvas" else "Mind map")
                self.omni.preview_edited = relative_time(n.updated, self.now())
                self.omni.preview_created = short_date(n.created)

    def run_row(mut self, k: Int):
        """The omnibar's row k chosen (Enter, a click)."""
        if k < 0 or k >= len(self.omni_kind):
            return
        var kind = self.omni_kind[k]
        var id = self.omni_id[k]
        self.searching = False
        if kind == 0:
            self.open(id)
        elif kind == 1:  # (a notebook: shown in the panel, opened)
            self.sidebar = True
            self.panel.reveal_book(id)
        elif kind == 3:
            self.create("canvas", String(self.omni.query.strip()))
        else:
            self.act(pn_actions()[id].id)

    def act(mut self, id: String):
        if id == "new-note" or id == "quick-note":
            self.create("canvas")
        elif id == "new-page":
            self.create("page")
        elif id == "new-map":
            self.create("mindmap")
        elif id == "settings":
            self.settings_open = True
        elif id.startswith("skin-"):
            self.set_skin(String(id[byte=5:]))
        else:
            self.say("Not in the native app yet")

    # ------------------------------------------------ whole notes: made, filed, deleted (as Personal Note's API does)

    def create(mut self, kind: String, title: String = "", notebook: Int = 0):
        """A new note, opened (the web's createNote: no notebook named, so the Inbox)."""
        if len(self.dbs) == 0:
            return
        self.settle_open()
        self.flush()
        var name = title if title != "" else String("Untitled note")
        var made = make_note(self.dbs[0], kind, name, notebook)
        if made.id == 0:
            self.say("Couldn’t make a note: " + made.message)
            return
        self.add_record(made.id, kind, name)
        self.open(made.id)
        self.panel.scroll = 0
        if kind == "page":
            self.page.caret_end()
        print("PNOTE NEW: " + kind + " " + String(made.id), flush=True)

    def delete_note(mut self):
        """The open note deleted: gone from the list at once, its row when the toast goes (Undo, 8 s), another note opens or
        the app closes (the web's deleteActiveNote)."""
        var i = self.note_index(self.current)
        if i < 0 or len(self.dbs) == 0:
            return
        if self.notes[i].secure:
            self.say("Secure notes aren’t in the native app yet")
            return
        self.commit_delete()
        self.settle_open()
        self.flush()
        i = self.note_index(self.current)
        var id = self.current
        self.gone_at = i
        self.gone = [self.notes.pop(i)]
        self.current = 0
        self.doc.begin(0)
        self.list_notes()
        var held = self.gone.copy()
        self.gone = List[NoteRec]()  # (opening the next note would delete the row for good)
        if len(self.notes) == 0:
            self.create("canvas")
        else:
            self.open(self.notes[0].id)
        self.gone = held^
        self.say("Note deleted", "Undo", TOAST_UNDELETE)
        print("PNOTE DELETE: note " + String(id) + " (held for Undo)", flush=True)

    def undo_delete(mut self):
        if len(self.gone) == 0:
            return
        var rec = self.gone.pop()
        var id = rec.id
        self.notes.insert(min(self.gone_at, len(self.notes)), rec^)
        self.list_notes()
        self.hide_toast()
        self.open(id)

    def commit_delete(mut self):
        """The held delete, for real."""
        if len(self.gone) == 0:
            return
        var rec = self.gone.pop()
        var why = drop_note(self.dbs[0], rec.id)
        if why != "" and why != "gone":
            print("PNOTE DELETE: failed note " + String(rec.id) + ": " + why, flush=True)
            self.notes.insert(min(self.gone_at, len(self.notes)), rec^)
            self.list_notes()
            self.say("Couldn’t delete it: " + why)
            return
        self.outbox.drop(rec.id)
        if self.snap_dir != "":
            _ = unlink(self.snap_path(rec.id))
        print("PNOTE DELETE: note " + String(rec.id), flush=True)
        if self.toast_does == TOAST_UNDELETE:
            self.toast = ""
            self.toast_action = ""
            self.toast_does = 0

    def save_copy(mut self):
        """Edits another app's save stands in the way of, saved as a note of their own; the note itself is then what the
        other app saved."""
        if self.saver.pending():  # (what was typed since the last try: into what is held)
            self.flush()
        var at = self.outbox.find(self.current)
        var i = self.note_index(self.current)
        if at < 0 or i < 0 or len(self.dbs) == 0:
            return
        var u = self.outbox.items[at].copy()
        var title = self.notes[i].title + " (my copy)"
        var made = make_note(self.dbs[0], u.kind, title, self.notes[i].notebook, u.content, u.body)
        if made.id == 0:
            self.say("Couldn’t save a copy: " + made.message)
            return
        self.saver.done()
        self.save_kind = ""
        self.outbox.drop(u.id)
        self.doc.begin(0)  # (what is on screen is in the copy: nothing of it is saved or kept as the note's own)
        self.current = 0
        self.add_record(made.id, u.kind, title)
        self.open(made.id)
        self.say("Saved as “" + title + "”")
        print("PNOTE COPY: note " + String(u.id) + " -> " + String(made.id), flush=True)

    def add_record(mut self, id: Int, kind: String, title: String):
        """A note just made in the file, listed first."""
        var rec = NoteRec(id, "", "", title, kind, "", 0, "", 1, False, 1, False, 0)
        try:
            var q = self.dbs[0].prepare("SELECT created_at, updated_at, revision, IFNULL(octet_length(content), 0), IFNULL(notebook_id, 0) FROM notes WHERE id = ?")
            q.bind(1, id)
            if q.step():
                rec.created = q.text(0)
                rec.updated = q.text(1)
                rec.revision = q.int(2)
                rec.bytes = q.int(3)
                rec.notebook = q.int(4)
        except:
            pass
        rec.emoji = guess_emoji(title, kind)
        rec.tint = tint_of(rec.emoji)
        self.notes.insert(0, rec^)
        self.panel_counts()
        self.list_notes()

    def refresh(mut self) -> Bool:
        """What another app did to the notes file since (its change feed's sequence moved on): the list read again; the
        open note, when its row moved on and nothing here is unsaved, opened again. True when the screen changes."""
        if len(self.dbs) == 0:
            return False
        try:
            var seq = self.dbs[0].count("SELECT sequence FROM workspace_state WHERE id = 1")
            if seq == self.known_seq:
                return False
            var first = self.known_seq < 0
            self.known_seq = seq
            if first:
                return False
            var rows = Dict[Int, Int]()  # id → revision
            var fresh = List[NoteRec]()
            var changed = False
            var q = self.dbs[0].prepare("SELECT id, title, note_type, IFNULL(notebook_id, 0), icon, icon_tint, created_at, updated_at, revision, secure, IFNULL(octet_length(content), 0) FROM notes ORDER BY updated_at DESC, id DESC")
            while q.step():
                var id = q.int(0)
                if len(self.gone) > 0 and self.gone[0].id == id:  # (deleted here, its row waiting for the toast)
                    continue
                var emoji = q.text(4)
                var tint = q.int(5)
                var own = emoji != ""
                if not own:
                    emoji = guess_emoji(q.text(1), q.text(2))
                    tint = tint_of(emoji)
                rows[id] = q.int(8)
                var rec = NoteRec(id, q.text(6), q.text(7), q.text(1), q.text(2), "", q.int(3), emoji, tint, own, q.int(8), q.int(9) != 0, q.int(10))
                var i = self.note_index(id)
                if i < 0 or self.notes[i].revision != rec.revision or self.notes[i].title != rec.title or self.notes[i].notebook != rec.notebook:
                    changed = True
                if i >= 0 and self.outbox.find(id) >= 0:  # (edits held at an older revision: they keep building on it)
                    rec.revision = self.notes[i].revision
                if i >= 0 and id == self.current and (self.saver.pending() or self.tools.editing != -1 or self.map.editing >= 0 or self.page.marking() or self.page.preedit != ""):
                    rec.revision = self.notes[i].revision  # (being edited: the save will meet the other's and say so)
                fresh.append(rec^)
            if len(fresh) != len(self.notes):
                changed = True
            if not changed:
                return False
            var cur = self.current
            var was = self.doc.revision
            self.notes = fresh^
            self.panel.notebooks.clear()
            var nb = self.dbs[0].prepare("SELECT id, name, color, category, (SELECT COUNT(*) FROM notes WHERE notebook_id = notebooks.id) FROM notebooks ORDER BY updated_at DESC, id ASC")
            while nb.step():
                self.panel.notebooks.append(PanelNotebook(nb.int(0), nb.text(1), hexc(nb.text(2)), nb.text(3), notebook_icon(nb.text(1)), nb.int(4)))
            self.list_notes()
            var i = self.note_index(cur)
            if i < 0:  # (deleted there)
                if cur != 0 and self.doc.may_edit():
                    self.doc.begin(cur)
                    self.doc.failed(cur, "This note was deleted in another app.")
            elif self.doc.may_edit() and self.notes[i].revision != was and self.outbox.find(cur) < 0 and not self.notes[i].secure:
                var scroll = self.page.scroll
                var view = self.view
                self.saver.done()
                self.save_kind = ""
                self.current = 0  # (nothing here is unsaved: what the file holds, shown)
                self.doc.begin(0)
                self.open(cur)
                self.page.scroll = scroll
                if self.notes[i].kind == "canvas" and self.view_set:
                    self.view = view
            print("PNOTE FEED: read again at " + String(seq), flush=True)
            return True
        except e:
            return False

    def remember_folds(mut self):
        """Which shelves are folded and which notebooks open, for the next start (in this app's own settings)."""
        var s = String("1" if self.panel.inbox_open else "0")
        for o in self.panel.open_shelves:
            s += "1" if o else "0"
        write_setting("pnote", "shelves-" + String(fnv(self.db_path)), s)
        var b = String("")
        for id in self.panel.open_books:
            b += ("," if b != "" else "") + String(id)
        write_setting("pnote", "books-" + String(fnv(self.db_path)), b)

    def recall_folds(mut self):
        var s = read_setting("pnote", "shelves-" + String(fnv(self.db_path)), "")
        if s.byte_length() == 1 + len(self.panel.open_shelves):
            self.panel.inbox_open = s.as_bytes()[0] == 49
            for i in range(len(self.panel.open_shelves)):
                self.panel.open_shelves[i] = s.as_bytes()[i + 1] == 49
        for p in read_setting("pnote", "books-" + String(fnv(self.db_path)), "").split(","):
            try:
                self.panel.open_books.append(Int(String(p)))
            except:
                pass

    def name_notebook(mut self):
        """The new notebook's name is written: made, on its shelf."""
        var at = self.panel.naming
        var name = String(self.panel.naming_text.strip())
        self.panel.naming = -1
        if self.panel.renaming >= 0:
            var b = self.panel.renaming
            self.panel.renaming = -1
            var k = self.book_index(b)
            if k >= 0 and name != "" and name != self.panel.notebooks[k].name:
                var category = self.panel.notebooks[k].category
                self.change_book(b, name, category)
            return
        if at < 0 or name == "" or len(self.dbs) == 0:
            return
        var shelf = self.panel.cfg.shelves[at].key
        var made = make_notebook(self.dbs[0], name, shelf)
        if made.id == 0:
            self.say("Couldn’t make it: " + made.message)
            return
        self.panel.notebooks.insert(0, PanelNotebook(made.id, name, hexc("#B86B4B"), shelf, notebook_icon(name), 0))

    def move_note(mut self, notebook: Int):
        """The open note filed into a notebook (0: the Inbox)."""
        var i = self.note_index(self.current)
        if i < 0 or len(self.dbs) == 0 or self.notes[i].notebook == notebook:
            return
        self.settle_open()
        self.flush()
        i = self.note_index(self.current)
        if self.outbox.find(self.current) >= 0 or self.doc.loading():
            self.say("Couldn’t move it. Try again.")
            return
        var r = file_note(self.dbs[0], self.current, self.notes[i].revision, notebook)
        if r.status != SAVED:
            self.say("Couldn’t move it. Try again.")
            return
        self.doc.saved(r.revision)
        self.notes[i].revision = r.revision
        self.notes[i].updated = r.value
        self.notes[i].notebook = notebook
        self.panel_counts()
        var rec = self.notes.pop(i)
        self.notes.insert(0, rec^)
        self.list_notes()
        self.panel.reveal(self.current)

    def file_at(mut self, id: Int, notebook: Int):
        """A note dragged onto a notebook (0: the Inbox)."""
        var i = self.note_index(id)
        if i < 0 or self.notes[i].notebook == notebook:
            return
        if id == self.current:
            self.move_note(notebook)
            return
        if self.outbox.find(id) >= 0:
            self.say("Couldn’t move it. Try again.")
            return
        var rev = row_revision(self.dbs[0], "notes", "id", id, "revision")
        var r = file_note(self.dbs[0], id, rev, notebook)
        if r.status != SAVED:
            self.say("Couldn’t move it. Try again.")
            return
        i = self.note_index(id)
        self.notes[i].revision = r.revision
        self.notes[i].updated = r.value
        self.notes[i].notebook = notebook
        self.panel_counts()
        var rec = self.notes.pop(i)
        self.notes.insert(0, rec^)
        self.list_notes()
        self.panel.reveal(id)

    def book_index(self, id: Int) -> Int:
        for k in range(len(self.panel.notebooks)):
            if self.panel.notebooks[k].id == id:
                return k
        return -1

    def change_book(mut self, id: Int, name: String, category: String):
        var k = self.book_index(id)
        if k < 0 or len(self.dbs) == 0:
            return
        var why = change_notebook(self.dbs[0], id, name, category)
        if why != "":
            self.say("Couldn’t change it: " + why)
            return
        self.panel.notebooks[k].name = name
        self.panel.notebooks[k].category = category
        self.panel.notebooks[k].icon = notebook_icon(name)
        self.panel.reveal_book(id)

    def delete_book(mut self, id: Int):
        """A notebook deleted, its notes back in the Inbox."""
        var k = self.book_index(id)
        if k < 0 or len(self.dbs) == 0:
            return
        self.settle_open()
        self.flush()
        var why = drop_notebook(self.dbs[0], id)
        if why != "":
            self.say("Couldn’t delete it: " + why)
            return
        _ = self.panel.notebooks.pop(k)
        for i in range(len(self.notes)):
            if self.notes[i].notebook == id:
                self.notes[i].notebook = 0
                self.notes[i].revision += 1
                if self.notes[i].id == self.current:
                    self.doc.saved(self.notes[i].revision)
        self.list_notes()
        self.say("Notebook deleted. Its notes are in the Inbox.")

    def panel_counts(mut self):
        for k in range(len(self.panel.notebooks)):
            var n = 0
            for ref x in self.notes:
                if x.notebook == self.panel.notebooks[k].id:
                    n += 1
            self.panel.notebooks[k].count = n

    def clear_all(mut self):
        """The open note emptied, one undoable step (the web's Clear all)."""
        var i = self.note_index(self.current)
        if i < 0 or self.notes[i].secure or not self.editable():
            return
        if self.notes[i].kind == "page":
            if self.page.markdown() == "":
                return
            self.page.ed.select_all()
            _ = self.page.key("Delete", 0, now_ms())
            self.save_page()
        elif self.notes[i].kind == "canvas":
            ref layer = self.board.edit()
            layer.select_all()
            if len(layer.selected) == 0:
                return
            layer.delete_selection()
            self.tools.changed = True
            self.save_canvas()
        else:
            return
        self.say("Cleared", "Undo", TOAST_UNCLEAR)

    def say(mut self, words: String, action: String = "", does: Int = 0):
        if does != TOAST_UNDELETE:
            self.commit_delete()
        self.toast = words
        self.toast_action = action
        self.toast_does = does
        self.toast_until = clock_us() + 8_000_000

    def hide_toast(mut self):
        self.toast = ""
        self.toast_action = ""
        self.toast_does = 0
        self.commit_delete()

    def run_toast(mut self):
        var does = self.toast_does
        if does == TOAST_UNDELETE:
            self.undo_delete()
            return
        self.hide_toast()
        if does == TOAST_UNCLEAR:
            var i = self.note_index(self.current)
            if i >= 0 and self.notes[i].kind == "page":
                _ = self.page.undo()
                self.save_page()
            elif i >= 0 and self.notes[i].kind == "canvas" and self.editable():
                self.tools.undo(self.board.edit())
                self.save_canvas()

    def waiting(self) -> Bool:
        """Something has to happen later without input: a save, a toast to go (App.every)."""
        return self.saver.pending() or self.toast != ""

    def save_page(mut self):
        """An edit on the open page: saved later, as the web does (queueSave: 650 ms after the last edit)."""
        self.queue_save("page")

    def queue_save(mut self, kind: String):
        var i = self.note_index(self.current)
        if i < 0 or self.notes[i].kind != kind or self.notes[i].secure or not self.doc.may_edit():
            return
        self.save_kind = kind
        self.saver.touch(clock_us())

    def tick(mut self) -> Bool:
        """The save timer's tick (App.every while a save is pending): writes it once it is due. True when the screen
        changes (a failed save shows)."""
        if self.toast != "" and clock_us() > self.toast_until:
            self.hide_toast()
            return True
        if not self.saver.due(clock_us()):
            return False
        var before = self.save_state
        self.flush()
        return self.save_state != before

    def close(mut self):
        """The app closing: the held delete and the pending save are made."""
        self.commit_delete()
        self.flush()

    def flush(mut self):
        """Writes the pending save now (a due timer, another note opening, the app closing)."""
        if not self.saver.pending():
            return
        self.saver.done()
        var kind = self.save_kind
        self.save_kind = ""
        self.settle_open()
        var i = self.note_index(self.current)
        if i < 0 or self.notes[i].kind != kind or self.notes[i].secure:
            return
        if not self.doc.may_save(self.current, self.notes[i].revision):  # (never a screen that isn't this row's document, read whole)
            print("PNOTE SAVE: refused (note " + String(self.current) + " isn't open and read)", flush=True)
            return
        var content = String("")
        var body = String("")
        try:
            if kind == "page":
                content = self.page.page_json(self.page_src)
                body = self.page.markdown()  # (page_note.page_text: a page's search body is its Markdown itself)
            elif kind == "canvas":
                ref layer = self.board.edit()
                content = export_json_canvas(layer, self.cols, self.rows)
                body = reading_text(layer)
            elif kind == "mindmap":
                content = map_json_from(self.map, self.page_src, self.notes[i].title, self.map_root)
                body = map_text(self.map)
        except e:
            self.save_state = "Couldn’t save"
            self.save_detail = String(e)
            print("PNOTE SAVE: failed note " + String(self.current) + ": " + String(e), flush=True)
            return
        if self.save_note(i, content, body) and kind == "canvas":
            self.board.edit().mark_saved()
            self.content_hash = text_hash(content)
            self.look.keep_note = grid_note(self.cols, self.rows) + ";" + String(self.content_hash)

    def retry_save(mut self):
        """The island's Retry: the held edits of the open note, again."""
        var i = self.note_index(self.current)
        if i < 0 or self.outbox.find(self.current) < 0 or not self.doc.may_edit():
            return
        self.save_kind = self.notes[i].kind
        self.saver.touch(clock_us())
        self.flush()

    def save_note(mut self, i: Int, content: String, body: String) -> Bool:
        """One note's new content into Personal Note's schema as its API saves it (services.save_note): only on the
        revision this copy holds (another app saved first: nothing is written and the island says so), with the change
        log, the search index and, for a map, its reminders kept in step, in one transaction. Then that one row is
        updated in memory and moves to the top of the list; nothing else is read again. What couldn't be written is held
        (SaveOutbox: on disk at once), opens in place of the row until it lands, and is tried again by Retry or the next
        edit. True when it landed."""
        var id = self.notes[i].id
        if self.notes[i].secure or len(self.dbs) == 0:
            print("PNOTE SAVE: refused (secure note " + String(id) + ")", flush=True)
            return False
        var s = RowSave("notes", "id", id, "revision", self.notes[i].revision)
        s.set("content", text_arg(content))
        s.stamp("updated_at")
        s.read_back("updated_at")
        self.log_change(s, id)
        s.then("DELETE FROM note_search WHERE note_id = ?", [int_arg(id)])
        s.then("INSERT INTO note_search (note_id, title, body) VALUES (?, ?, ?)", [int_arg(id), text_arg(self.notes[i].title), text_arg(body)])
        if self.notes[i].kind == "mindmap":
            # (services.sync_reminders: the native app never changes a due time, so an idea deleted here loses its
            # reminder and a renamed one carries its new words; fired marks stay, as the web keeps them for an unchanged time)
            s.then("DELETE FROM mindmap_reminders WHERE note_id = ?1 AND node_id NOT IN (SELECT json_extract(value, '$.id') FROM json_each(?2, '$.nodes'))",
                   [int_arg(id), text_arg(content)])
            s.then("UPDATE mindmap_reminders SET label = COALESCE((SELECT substr(trim(COALESCE(json_extract(value, '$.text'), ''), ' ' || char(9, 10, 13)), 1, 200) FROM json_each(?2, '$.nodes') WHERE json_extract(value, '$.id') = mindmap_reminders.node_id), label) WHERE note_id = ?1",
                   [int_arg(id), text_arg(content)])
        var r = save_row(self.dbs[0], s)
        if r.status == SAVED:
            self.doc.saved(r.revision)
            self.outbox.drop(id)
            self.notes[i].bytes = content.byte_length()
        else:
            if not self.outbox.put(Unsaved(id, self.notes[i].kind, self.notes[i].revision, content, body, r.message, r.status == CONFLICT)):
                print("PNOTE SAVE: the edits of note " + String(id) + " are held in memory only", flush=True)
        self.landed(i, r.status, r.revision, r.value, r.message)
        return r.status == SAVED

    def landed(mut self, i: Int, status: Int, revision: Int, stamp: String, message: String):
        """A save's outcome: saved → this copy takes the new revision and time and goes to the top; a conflict or a
        failure → the island says "Couldn’t save" with why (the web's setSaveState), the edits stay on screen."""
        if status == SAVED:
            self.notes[i].revision = revision
            self.notes[i].updated = stamp
            self.save_state = ""
            self.save_detail = ""
            var rec = self.notes.pop(i)
            self.notes.insert(0, rec^)
            self.list_notes()
        else:
            self.save_state = "Couldn’t save"
            self.save_detail = message
            print("PNOTE SAVE: " + ("conflict" if status == CONFLICT else "failed") + " note " + String(self.notes[i].id) + " at revision " + String(self.notes[i].revision) + ": " + message, flush=True)

    def editable(mut self) -> Bool:
        """The open note was read and may be edited (a deferred open is waited for: what it needs of the view)."""
        if self.doc.loading() and self.board.pending() and not self.board.wait(250):
            return False  # (still being read: no edit yet)
        self.settle_open()
        return self.doc.may_edit()

    def log_change(self, mut s: RowSave, id: Int):
        """Personal Note's workspace change feed (record_change): the sequence moves on, a row for this revision."""
        s.then("UPDATE workspace_state SET sequence = sequence + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 1", List[SqlArg]())
        s.then("INSERT INTO workspace_changes (sequence, resource_kind, resource_id, revision, change_type) SELECT (SELECT sequence FROM workspace_state WHERE id = 1), 'note', resource_id, revision, 'updated' FROM notes WHERE id = ?",
               [int_arg(id)])

    def text_in(mut self, kind: String, text: String) -> Bool:
        """An input method's commit or a paste: into the open page, the canvas words or the idea being written, the search."""
        var i = self.note_index(self.current)
        if self.searching:
            self.omni.query += " ".join(text.split())
            self.search()
            return True
        if self.card_open and self.card.editing:
            if self.card.all_selected:
                self.card.title = ""
                self.card.all_selected = False
            self.card.title += " ".join(text.split())
            return True
        if i < 0 or self.notes[i].secure or self.card_open or self.settings_open or not self.editable():
            return False
        if self.notes[i].kind == "page":
            if self.page.draw_mode:
                return False
            self.page.insert(text)
            self.save_page()
            return True
        if self.notes[i].kind == "canvas" and self.tools.editing != -1:
            _ = self.tools.text_in(text, self.board.edit())
            return True
        if self.notes[i].kind == "mindmap" and self.map.editing >= 0:
            if self.map.edit_all:
                self.map.edit_text = ""
                self.map.edit_all = False
            self.map.edit_text += " ".join(text.split())
            return True
        return False

    def preedit(mut self, text: String, cx: Float64, cy: Float64, cw: Float64, ch: Float64) -> Bool:
        var i = self.note_index(self.current)
        if self.on_canvas() and self.tools.editing != -1:
            self.tools.words.preedit = text
            return True
        if i < 0 or self.notes[i].kind != "page" or self.notes[i].secure or not self.doc.may_edit():
            return False
        self.page.preedit = text
        if text != "":
            var r = self.page.caret_rect
            print("PNOTE IME: preedit=\"" + text + "\" underline=1 caret=" + String(r[0]) + "," + String(r[1]) + " cursor_location=" + String(cx) + "," + String(cy) + "," + String(cw) + "," + String(ch), flush=True)
        return True

    def key(mut self, name: String, mods: Int) -> Bool:
        if self.panel.naming >= 0 and self.sidebar:
            var r = self.panel.name_key(name, mods)
            if r == 2:
                self.name_notebook()
            if r != 0:
                return True
        if (mods & 2) != 0 and (name == "k" or name == "K"):
            if self.searching:
                self.searching = False
            else:
                self.open_search()
            return True
        if (mods & 4) != 0 and (mods & 2) == 0 and (name == "n" or name == "N") and not self.searching and not self.card.editing and not self.settings_open and not self.typing():
            self.create("canvas")
            return True
        if self.book_card >= 0 and name == "Escape":
            self.book_card = -1
            return True
        if self.props_open and name == "Escape":
            if self.props.menu_open:
                self.props.menu_open = False
            else:
                self.props_open = False
            return True
        var mi = self.note_index(self.current)
        if mi >= 0 and self.notes[mi].kind == "mindmap" and self.doc.may_edit() and not self.notes[mi].secure and not self.searching and not self.card_open and not self.settings_open:
            if self.map.editing >= 0:
                var r = self.map.edit_key(name, mods)
                if r == 2:
                    self.save_map()
                return r != 0
            if name == "Tab" or name == "Enter":
                if self.map.add_idea(name == "Enter") >= 0:
                    self.save_map()
                return True
            if name == "F2":
                self.map.begin_edit(self.map.selected)
                return True
            if (mods & 2) == 0 and (name == "Delete" or name == "Backspace"):
                if self.map.delete_selected():
                    self.save_map()
                return True
            if (mods & 2) != 0 and (name == "z" or name == "Z" or name == "y" or name == "Y"):
                var back = (name == "z" or name == "Z") and (mods & 1) == 0
                if (self.map.undo() if back else self.map.redo()):
                    self.save_map()
                return True
        if self.on_canvas() and self.editable():
            var r = self.tools.key(name, mods, self.board.edit(), self.view, self.win_w, self.win_h, self.cols, self.rows)
            if r and (mods & 2) != 0 and (name == "z" or name == "Z" or name == "y"):  # (an undo or redo by key, as by the island)
                self.tools.hug_routes(self.board.edit(), self.look)
            self.save_canvas()
            if self.tools.words.ed.clip_version != self.words_clips:
                self.words_clips = self.tools.words.ed.clip_version
                self.copied(String(self.tools.words.ed.clip))
            if r:
                return True
        var ni = self.note_index(self.current)
        if not self.searching and not self.card_open and not self.settings_open and ni >= 0 and self.notes[ni].kind == "page" and not self.notes[ni].secure and self.doc.may_edit():
            if self.page.draw_mode:
                if (mods & 2) != 0 and (name == "z" or name == "Z" or name == "y" or name == "Y"):
                    if self.page.key(name, mods, now_ms()) == 2:
                        self.save_page()
                    return True
                if name == "Escape":
                    self.page.draw_mode = False
                    return True
                return False
            var clips = self.page.ed.clip_version
            var r = self.page.key(name, mods, now_ms())
            if self.page.ed.clip_version != clips:
                self.copied(String(self.page.ed.clip))
            if r == 2:
                self.save_page()
            if r == 0 and name == "Escape" and self.sidebar:
                self.sidebar = False
                return True
            return r != 0
        if self.card_open and self.card.editing:
            var r = self.card.title_key(name, mods)
            if r == 2:
                var t = self.card.title.copy()
                self.rename(t)
                self.card_open = False
                self.title_focus = True  # (Enter gives the focus back to the island's button: the web shows its ring)
            return r != 0
        if (self.card_open or self.settings_open) and name == "Escape":
            self.card_open = False
            self.settings_open = False
            return True
        if not self.searching:
            if name == "Escape" and self.sidebar:
                self.sidebar = False
                return True
            return False
        if name == "Enter":
            self.run_row(self.omni.selected)
            return True
        if name == "ArrowDown" or name == "ArrowUp":
            self.omni.move(1 if name == "ArrowDown" else -1)
            self.omni_facts()
            return True
        if name == "Escape":
            self.searching = False
            self.card_open = False
        elif self.omni.query_key(name, mods):
            self.search()
        else:
            return False
        return True

    def copied(mut self, words: String):
        """Words copied here: for the system's clipboard (the app shows mojoui.overlays.Clipboard(clip, clip_version))."""
        self.clip = words
        self.clip_version += 1

    def open_search(mut self):
        self.searching = True
        self.card_open = False
        self.props_open = False
        self.omni.query = ""
        self.omni.pill = 0
        self.search()

    def typing(self) -> Bool:
        """Words are being typed into a canvas text, or an idea."""
        return (self.on_canvas() and self.tools.editing != -1) or self.map.editing >= 0

    def caret(self) -> Tuple[Float64, Float64, Float64, Float64]:
        var i = self.note_index(self.current)
        if i >= 0 and self.notes[i].kind == "canvas" and self.tools.editing != -1:
            return self.words_at
        if i < 0 or self.notes[i].kind != "page":
            return (-1.0, 0.0, 0.0, 0.0)
        return self.page.caret_rect

    def bench(mut self, name: String) -> Tuple[Float64, Float64]:
        """The race's app steps (the GTK host's framebench and its note steps): switch to the next note, open or close the
        omnibar, open a note of each kind in turn; on an open canvas, Personal Note's benchmark steps through the same
        board the person uses (pagedesk.BoardTools): pan with the hand, pen, a text box written in the middle of the
        window, an object (or 40 selected) to drag, thirty moves to undo and redo, and a fresh open of the note.
        bench:loading answers (1, nodes left) while an open is still coming in, else (0, 0)."""
        if name == "bench:loading":
            if self.board.loading():
                return (1.0, Float64(self.board.left()))
            return (0.0, 0.0)
        if name == "bench:switch":
            var i = self.note_index(self.current)
            self.open(self.notes[(i + 1) % len(self.notes)].id)
        elif name == "bench:omnibar":
            self.searching = not self.searching
            if self.searching:
                self.omni.query = ""
                self.search()
        elif name == "bench:openall":
            var kinds: List[String] = ["page", "canvas", "mindmap"]
            var at = self.bench_kind % 3
            self.bench_kind += 1
            for ref n in self.notes:
                if n.kind == kinds[at] and not n.secure:
                    self.open(n.id)
                    break
        if name == "bench:reopen":
            self.open(self.bench_note if self.bench_note >= 0 else self.current)
            return (-1.0, -1.0)
        if name == "bench:coldopens" or name == "bench:keptopens":  # (the race's two open rows)
            self.cold_opens = name == "bench:coldopens"
            self.kept.clear()
            if self.bench_note < 0:  # (the race's canvas: the open one, else the newest canvas, as when the app starts on
                # another note for its first open, PNOTE_FIRST)
                var ci_ = self.note_index(self.current)
                if ci_ >= 0 and self.notes[ci_].kind == "canvas":
                    self.bench_note = self.current
                else:
                    for ref n in self.notes:
                        if n.kind == "canvas" and not n.secure:
                            self.bench_note = n.id
                            break
            if self.cold_opens:  # (the first timed open comes from another note, as a person switching to it)
                for ref n in self.notes:
                    if n.kind != "canvas" and not n.secure:
                        self.open(n.id)
                        break
            return (-1.0, -1.0)
        if not self.on_canvas():
            return (-1.0, -1.0)
        if name == "bench:openspot":  # (framebench openpress: an object the board shows while it is still coming in, read
            # without finishing it; the press then goes through the app's own route, which does)
            var vis = self.tools.visible_objects(self.board.layer, self.view, self.win_w, self.win_h)
            if len(vis) == 0:
                return (-1.0, -1.0)
            ref o = self.board.layer.objs[vis[len(vis) // 2]]
            var c = self.view.to_screen(o.x + o.w / 2, o.y + o.h / 2)
            return (c[0], c[1])
        if name != "bench:reopen" and name != "bench:coldopens" and name != "bench:keptopens" and name != "bench:open":
            self.board.finish()  # (every other step reads or changes the whole board)
        var w = self.win_w
        var h = self.win_h
        if name == "bench:pan" or name == "bench:zoom":
            self.tools.set_tool("hand", self.board.layer, self.view, w, h, self.cols, self.rows)
        elif name == "bench:zoom30" or name == "bench:zoom100":  # (benchmark-f034's "zoomed out to 30%" and "at 100%"; the
            # host presses before it readies a pan, so the hand is picked here)
            self.tools.set_tool("hand", self.board.layer, self.view, w, h, self.cols, self.rows)
            self.view = self.view.zoomed_at(0.3 if name == "bench:zoom30" else 1.0, w / 2, h / 2)
        elif name == "bench:redo":  # (the undos before it made the history)
            pass
        elif name == "bench:draw" or name == "bench:finish":
            self.board.layer.clear_selection()
            self.tools.set_tool("pen", self.board.layer, self.view, w, h, self.cols, self.rows)
        elif name == "bench:type":
            self.tools.set_tool("text", self.board.layer, self.view, w, h, self.cols, self.rows)
            _ = self.tools.tap(w / 2, h / 2, self.board.layer, self.view, w, h)
        elif name == "bench:dragone" or name == "bench:undoredo" or name == "bench:undo" or name == "bench:drag40":
            self.tools.set_tool("select", self.board.layer, self.view, w, h, self.cols, self.rows)
            var vis = self.tools.visible_objects(self.board.layer, self.view, w, h)
            if len(vis) == 0:
                return (-1.0, -1.0)
            self.board.layer.clear_selection()
            if name == "bench:drag40":
                for m in range(min(40, len(vis))):
                    self.board.layer.select(self.board.layer.objs[vis[m]].id, True)
                var o0 = self.board.layer.objs[vis[0]].copy()
                var c0 = self.view.to_screen(o0.x + o0.w / 2, o0.y + o0.h / 2)
                return (c0[0], c0[1])
            var k = len(vis) // 2
            if name == "bench:undoredo" or name == "bench:undo":  # (thirty separate moves, each its own undo step, to walk back and forth)
                for m in range(min(30, len(vis))):
                    self.board.layer.select(self.board.layer.objs[vis[m]].id, False)
                    self.board.layer.begin_gesture(CH_MOVE)
                    self.board.layer.move_by(6, 4)
                    self.board.layer.end_gesture()
                self.tools.changed = True
                self.save_canvas()
                return (-1.0, -1.0)
            var o = self.board.layer.objs[vis[k]].copy()
            self.board.layer.select(o.id, False)
            var c = self.view.to_screen(o.x + o.w / 2, o.y + o.h / 2)
            return (c[0], c[1])
        return (-1.0, -1.0)

    def wheel(mut self, x: Float64, y: Float64, dx: Float64, dy: Float64) -> Bool:
        """A wheel or touchpad scroll: on a canvas the view moves (the web's wheel pan)."""
        if self.sidebar and not self.searching and not self.settings_open and self.boxes.hit_any(x, y, ["#sidebar"]) != "":
            return self.panel.wheel(dy)
        if self.on_map():
            var b = self.map_box()
            var v = self.map.view(b[2], b[3])
            self.map.zoom_at(v[0] * (0.9 if dy > 0 else 1.1), x - b[0], y - b[1], b[2], b[3])
            return True
        if not self.on_canvas():
            var i = self.note_index(self.current)
            if i >= 0 and self.notes[i].kind == "page" and not self.notes[i].secure and not self.searching and not self.card_open and not self.settings_open and (
                    not self.sidebar or self.boxes.hit_any(x, y, ["#sidebar"]) == ""):
                return self.page.wheel(dy)
            return False
        self.view = self.tools.scroll(self.view, dx, dy, self.win_w, self.win_h, self.cols, self.rows)
        return True

    def zoom(mut self, x: Float64, y: Float64, factor: Float64) -> Bool:
        """A pinch or Ctrl+wheel: on a canvas the view zooms about the pointer."""
        if self.on_map():
            var b = self.map_box()
            var v = self.map.view(b[2], b[3])
            self.map.zoom_at(v[0] * factor, x - b[0], y - b[1], b[2], b[3])
            return True
        if not self.on_canvas():
            return False
        self.view = self.tools.zoom_at(self.view, factor, x, y, self.win_w, self.win_h, self.cols, self.rows)
        return True

    # ------------------------------------------------ input

    def press(mut self, x: Float64, y: Float64) -> Bool:
        """The pointer went down (a drag may follow)."""
        if self.toast != "" and self.boxes.hit_any(x, y, ["#toast"]) != "":
            return False
        if self.sidebar and not self.searching and not self.settings_open and not self.props_open and not self.card_open and self.boxes.hit_any(x, y, ["#sidebar"]) != "":
            _ = self.panel.press(x, y)
            return False
        self.title_focus = False  # (a click moves the focus: the ring goes)
        if self.on_canvas():
            if self.boxes.hit_any(x, y, ["[Canvas tools]", "#history-island", "#zoom-control", "#selection-bar", "#island", "#toggle-sidebar", "#search-button", "#dock-flyout", "#ink-options-popover"]) != "":
                return False  # (the chrome: nothing of the board read, an open keeps coming in)
            if self.tools.tool == "hand":  # (the hand only moves the view)
                return self.tools.press(x, y, self.board.layer, self.view)
            if not self.editable():
                return False
            if self.tools.tool == "eraser":  # (an edit along a path: the whole board)
                return self.tools.press(x, y, self.board.edit(), self.view)
            var r = self.near_rect(x, y)  # (D-7959: the tools hit-test at the pointer: only what lies there must be in)
            return self.tools.press(x, y, self.board.near(r[0], r[1], r[2], r[3]), self.view)
        if self.on_map():
            if self.boxes.hit_any(x, y, ["#sidebar", "#island", "#toggle-sidebar", "#search-button", "[Zoom controls]", "#mindmap-rail-actions", "[Map overview]", "[Add branch from "]) != "":
                return False
            if self.map.editing >= 0:  # (a click elsewhere keeps the words)
                _ = self.map.edit_key("Enter", 0)
                self.save_map()
            var b = self.map_box()
            self.map.press(x - b[0], y - b[1], b[2], b[3])
            return True
        var ni = self.note_index(self.current)
        if ni >= 0 and self.notes[ni].kind == "page" and not self.notes[ni].secure and self.page.draw_mode and self.doc.may_edit() and not self.searching and not self.card_open:
            if self.boxes.hit_any(x, y, [".page-paper"]) != "" and self.boxes.hit_any(x, y, ["[Page tools]", ".page-draw-hint"]) == "":
                self.page.mark_press(x, y)
                return True
        elif self.writing() and self.boxes.hit_any(x, y, [".page-tool:", "#sidebar", "#island", "#toggle-sidebar", "#search-button"]) == "":
            return self.page.press(x, y, False)
        return False

    def on_map(self) -> Bool:
        var i = self.note_index(self.current)
        return (i >= 0 and self.notes[i].kind == "mindmap" and not self.notes[i].secure and self.doc.may_edit() and not self.searching and not self.card_open
                and not self.settings_open and not self.props_open)

    def map_box(self) -> Tuple[Float64, Float64, Float64, Float64]:
        """Where the map lies in the window: left, top, width, height."""
        var left = 296.0 if self.sidebar else 0.0
        return (left + 4, 66.0, self.win_w - left - 4 - 12, self.win_h - 66 - 12)

    def map_tap(mut self, x: Float64, y: Float64) -> Bool:
        """The map's own buttons: the rail's undo, redo and Fit, the zoom island, the selected idea's four add handles."""
        var b = self.map_box()
        var hit = self.boxes.hit_any(x, y, ["[Undo]", "[Redo]", "[Fit map]", "[Zoom out]", "[Zoom in]", ".mindmap-zoom-label:", "[Add branch from ", "[Add image]", "[Import JSON]", "[Export JSON]", "[Export PNG]", "[Clean up layout]"])
        if hit == "":
            return False
        var v = self.map.view(b[2], b[3])
        if hit.startswith("[Undo]"):
            if self.map.undo():
                self.save_map()
        elif hit.startswith("[Redo]"):
            if self.map.redo():
                self.save_map()
        elif hit.startswith("[Fit map]") or hit.startswith(".mindmap-zoom-label:"):
            self.map.fit_again()
        elif hit == "[Zoom in]" or hit == "[Zoom out]":
            self.map.zoom_at(v[0] * (1.15 if hit == "[Zoom in]" else 1 / 1.15), b[2] / 2, b[3] / 2, b[2], b[3])
        elif hit.startswith("[Add branch from "):
            if self.map.add_idea(False) >= 0:
                self.save_map()
        else:
            self.say("Not in the native app yet")
        return True

    def writing(self) -> Bool:
        """The open note is a page, readable, in Write mode, nothing over it."""
        var i = self.note_index(self.current)
        return (i >= 0 and self.notes[i].kind == "page" and not self.notes[i].secure and self.doc.may_edit() and not self.page.draw_mode
                and not self.searching and not self.card_open and not self.settings_open and not self.props_open)

    def double(mut self, x: Float64, y: Float64) -> Bool:
        """A double click: on a page's words, the word; a click more soon after, the line."""
        if self.on_canvas() and self.boxes.hit_any(x, y, ["[Canvas tools]", "#history-island", "#zoom-control", "#selection-bar", "#island", "#toggle-sidebar", "#search-button", "#sidebar"]) == "":
            if not self.editable():
                return False
            var r = self.tools.edit_at(x, y, self.board.edit(), self.view, self.win_w, self.win_h)
            self.save_canvas()
            return r
        if self.on_map() and self.boxes.hit_any(x, y, ["#sidebar", "#island", "#toggle-sidebar", "#search-button", "[Zoom controls]", "#mindmap-rail-actions"]) == "":
            var b = self.map_box()
            var t = self.map.hit(x - b[0], y - b[1], b[2], b[3])
            if t < 0:
                return False
            self.map.selected = t
            self.map.begin_edit(t)
            return True
        if not self.writing() or self.boxes.hit_any(x, y, [".page-tool:", "#sidebar", "#island", "#toggle-sidebar", "#search-button"]) != "":
            return False
        self.doubled_us = clock_us()
        return self.page.select_word(x, y)

    def pan(mut self, x: Float64, y: Float64) -> Bool:
        if self.panel.drag_id >= 0:
            return self.panel.drag(x, y)
        if self.on_canvas():
            if self.tools.tool == "hand":
                return self.tools.pan(x, y, self.board.layer, self.view)  # (the hand tool moves self.view)
            if not self.editable():
                return False
            var r = self.near_rect(x, y)
            return self.tools.pan(x, y, self.board.near(r[0], r[1], r[2], r[3]), self.view)
        if self.on_map():
            var b = self.map_box()
            return self.map.drag_to(x - b[0], y - b[1], b[2], b[3])
        if self.page.marking():
            self.page.mark_move(x, y)
            return True
        return self.page.drag(x, y)

    def release(mut self, x: Float64, y: Float64) -> Bool:
        if self.panel.drag_id >= 0:
            var was = self.panel.dragging
            var d = self.panel.release(x, y)
            if d[0] >= 0:
                self.file_at(d[0], d[1])
            self.dropped_us = clock_us() if was else self.dropped_us
            return was
        if self.on_canvas():
            if self.tools.tool != "hand" and not self.editable():
                return False
            if self.tools.drag == T_BOX:  # (a marquee selects whatever lies in it: the whole board)
                var r = self.tools.release(x, y, self.board.edit(), self.view)
                self.save_canvas()
                return r
            var vr = self.near_rect(x, y)
            var r = self.tools.release(x, y, self.board.layer, self.view) if self.tools.tool == "hand" else self.tools.release(x, y, self.board.near(vr[0], vr[1], vr[2], vr[3]), self.view)
            self.save_canvas()
            return r
        if self.map.drag != -1:
            if self.map.release():
                self.save_map()
            return True
        if self.page.marking():
            if self.page.mark_release():
                self.save_page()
            return True
        return self.page.release()

    def dock_name(self) -> String:
        var t = self.tools.tool
        if t == "select":
            return "[Select]"
        if t == "text":
            return "[Text]"
        if t == "pen":
            return "[Pen]"
        if t == "eraser":
            return "[Stroke eraser]"
        if t == "shape":
            return "[Shape]"
        if t == "sticky":
            return "[Sticky note]"
        return "#dock-more"

    def on_canvas(self) -> Bool:
        var i = self.note_index(self.current)
        return (i >= 0 and self.notes[i].kind == "canvas" and not self.notes[i].secure and not self.doc.is_failed() and not self.searching and not self.card_open
                and not self.settings_open and not self.props_open and self.book_card < 0)

    def canvas_tap(mut self, x: Float64, y: Float64, mods: Int = 0) -> Bool:
        """A tap on a canvas note: the dock, the history and zoom islands, else the board's tool (an edit: the whole board
        first, D-7952)."""
        var hit = self.boxes.hit_any(x, y, ["[Select]", "[Text]", "[Pen]", "[Stroke eraser]", "[Shape]", "[Sticky note]", "#undo", "#redo",
                                            "#zoom-in", "#zoom-out", "#zoom-fit", "#zoom-value", "#dock-more", "#ink-options-trigger", "#voice-button",
                                            "#selection-bar", "[Canvas tools]", "#history-island", "#zoom-control"])
        var more = self.boxes.hit_any(x, y, ["[Hand]", "[Highlighter]", "[Connect]", "ink-color:", "ink-width:", "#dock-flyout", "#ink-options-popover"])
        if more != "":
            if more == "[Hand]" or more == "[Highlighter]" or more == "[Connect]":
                self.tools.set_tool("hand" if more == "[Hand]" else ("highlight" if more == "[Highlighter]" else "connect"), self.board.layer, self.view, self.win_w, self.win_h, self.cols, self.rows)
                self.flyout = False
            elif more.startswith("ink-color:") or more.startswith("ink-width:"):
                try:
                    var n = Int(String(more[byte=10:]))
                    if more.startswith("ink-color:"):
                        var c = ink_colors()[n]
                        self.tools.pen_color = c
                        self.tools.text_color = c
                        self.tools.line_color = c
                        self.tools.marker_color = (c & 0xFFFFFF) | 0x55000000
                    elif self.tools.tool == "highlight":
                        self.tools.marker_width = [10.0, 20.0, 32.0, 48.0][n]
                    else:
                        self.tools.pen_width = [1.0, 3.0, 6.0, 10.0][n]
                except:
                    pass
            return True
        if hit == "#dock-more" or hit == "#ink-options-trigger":
            self.flyout = not self.flyout if hit == "#dock-more" else False
            self.ink_options = not self.ink_options if hit == "#ink-options-trigger" else False
            return True
        self.flyout = False
        self.ink_options = False
        if hit.startswith("#selection-bar"):
            if not self.editable():
                return False
            var at = self.boxes.hit_any(x, y, [".selection-bar:"])
            ref layer = self.board.edit()
            if at.endswith(":Back") or at.endswith(":Forward"):
                self.tools.order(layer, 1 if at.endswith(":Forward") else -1, False)
            elif at.endswith(":Lock"):
                layer.lock_selection()
                self.tools.changed = True
            elif at.endswith(":Delete"):
                layer.delete_selection()
                self.tools.changed = True
            elif at != "":
                self.say("Not in the native app yet")
            self.save_canvas()
            return True
        if hit == "#zoom-value":
            self.view = self.tools.zoom_at(self.view, 1.0 / self.view.scale, self.win_w / 2, self.win_h / 2, self.win_w, self.win_h, self.cols, self.rows)
            return True
        if hit == "#voice-button":
            self.say("Not in the native app yet")
            return True
        var names: List[String] = ["[Select]", "[Text]", "[Pen]", "[Stroke eraser]", "[Shape]", "[Sticky note]"]
        var tools: List[String] = ["select", "text", "pen", "eraser", "shape", "sticky"]
        for t in range(len(names)):
            if hit == names[t]:
                self.tools.set_tool(tools[t], self.board.layer, self.view, self.win_w, self.win_h, self.cols, self.rows)
                return True
        if (hit == "#undo" or hit == "#redo") and not self.editable():
            return False
        if hit == "#undo":
            self.tools.undo(self.board.edit())
            self.tools.hug_routes(self.board.edit(), self.look)
        elif hit == "#redo":
            self.tools.redo(self.board.edit())
            self.tools.hug_routes(self.board.edit(), self.look)
        elif hit == "#zoom-in" or hit == "#zoom-out":
            self.view = self.tools.zoom_step(self.view, 1 if hit == "#zoom-in" else -1, self.win_w, self.win_h, self.cols, self.rows)
        elif hit == "#zoom-fit":
            self.view = opening_view(self.win_w, self.win_h, Float64(self.cols) * PAGE_W, Float64(self.rows) * PAGE_H)
        elif hit == "":
            if not self.editable():
                return False
            var vr = self.near_rect(x, y)
            if not self.tools.tap(x, y, self.board.near(vr[0], vr[1], vr[2], vr[3]), self.view, self.win_w, self.win_h, mods):
                return False
        self.save_canvas()
        return True

    def save_canvas(mut self):
        """The board changed: a save queued (JSON Canvas with its pn extras, written by flush)."""
        if not self.tools.changed:
            return
        self.tools.changed = False
        self.queue_save("canvas")

    def save_map(mut self):
        self.queue_save("mindmap")

    def rename(mut self, title: String):
        """The open note's new name, saved as the web's API saves one (title on its revision, change log, search
        index); its guessed icon follows the new name. Pending edits land first. A secure note is never renamed here."""
        var i = self.note_index(self.current)
        var t = String(title.strip())
        if i < 0 or t == "" or t == self.notes[i].title:
            return
        if self.notes[i].secure or not self.editable():
            print("PNOTE SAVE: refused (note " + String(self.notes[i].id) + ": secure, or not read)", flush=True)
            return
        self.flush()
        if self.outbox.find(self.current) >= 0:  # (its edits haven't landed: a new name now would move its revision from under them)
            return
        i = self.note_index(self.current)
        var id = self.notes[i].id
        var s = RowSave("notes", "id", id, "revision", self.notes[i].revision)
        s.set("title", text_arg(t))
        s.stamp("updated_at")
        s.read_back("updated_at")
        self.log_change(s, id)
        s.then("UPDATE note_search SET title = ? WHERE note_id = ?", [text_arg(t), int_arg(id)])
        var r = save_row(self.dbs[0], s)
        if r.status == SAVED:
            self.doc.saved(r.revision)
            self.notes[i].title = t
            if not self.notes[i].icon_set:
                self.notes[i].emoji = guess_emoji(t, self.notes[i].kind)
                self.notes[i].tint = tint_of(self.notes[i].emoji)
        self.landed(i, r.status, r.revision, r.value, r.message)

    def hover(mut self, x: Float64, y: Float64) -> Bool:
        """The pointer moved; True when a hover state changes (only then the screen redraws)."""
        var before = self.boxes.hit_any(self.px, self.py, ["#toggle-sidebar", "#search-button", ".sec-head"])
        self.px = x
        self.py = y
        self.panel.px = x
        self.panel.py = y
        return self.boxes.hit_any(x, y, ["#toggle-sidebar", "#search-button", ".sec-head"]) != before

    def tap(mut self, x: Float64, y: Float64, mods: Int = 0) -> Bool:
        """A tap at (x, y) layout px; True when it changed something."""
        self.title_focus = False
        var hit = self.boxes.hit_any(x, y, ["#toggle-sidebar", "#search-button", "row:", "[Crayon skin]", "[Paper skin]", "[Night skin]", ".sec-head", "#share-button", "#open-retry", "#save-retry", "#save-copy", "#rail-new-note", ".nav-row:"])
        if self.toast != "" and self.boxes.hit_any(x, y, ["#toast"]) != "":
            if self.boxes.hit_any(x, y, ["#toast-action"]) != "":
                self.run_toast()
            return True
        if self.searching:
            var sh = self.boxes.hit_any(x, y, ["#omni-row-", ".omni-chip:", "#search-close", "[Search or jump to]"])
            if sh.startswith("#omni-row-"):
                try:
                    self.run_row(Int(String(sh[byte=10:])))
                except:
                    pass
            elif sh.startswith(".omni-chip:"):
                var pills: List[String] = [".omni-chip:All", ".omni-chip:Notes", ".omni-chip:Notebooks", ".omni-chip:Actions"]
                for n in range(4):
                    if sh == pills[n] or sh.startswith(pills[n] + " "):
                        self.omni.pill = n
                self.search()
            elif sh != "[Search or jump to]":  # (the Esc button, or outside it)
                self.searching = False
            return True
        if self.book_card >= 0:
            var ph = self.boxes.hit_any(x, y, ["[Move to ", "#notebook-picker", "#delete-note", "#rename-notebook", "#note-popover"])
            var b = self.book_card
            var k = self.book_index(b)
            if ph.startswith("[Move to ") and k >= 0:
                try:
                    var n = Int(String(ph[byte=9:].removesuffix("]")))
                    var name = self.panel.notebooks[k].name
                    self.book_card = -1
                    self.props.menu_open = False
                    self.change_book(b, name, String(self.panel.cfg.shelves[n].key))
                except:
                    pass
            elif ph == "#notebook-picker":
                self.props.menu_open = not self.props.menu_open
            elif ph == "#rename-notebook" and k >= 0:
                self.book_card = -1
                for q in range(len(self.panel.cfg.shelves)):
                    if self.panel.cfg.shelves[q].key == self.panel.notebooks[k].category:
                        self.panel.naming = q
                self.panel.naming_text = self.panel.notebooks[k].name
                self.panel.renaming = b
            elif ph == "#delete-note":
                self.book_card = -1
                self.delete_book(b)
            elif ph == "":
                self.book_card = -1
            else:
                self.props.menu_open = False
            return True
        if clock_us() - self.dropped_us < 200_000:  # (the end of a row's drag)
            return True
        if self.props_open:
            var ph = self.boxes.hit_any(x, y, ["[Move to ", "#notebook-picker", "#delete-note", "#note-popover"])
            if ph.startswith("[Move to "):
                try:
                    var n = Int(String(ph[byte=9:].removesuffix("]")))
                    self.props.menu_open = False
                    self.move_note(0 if n == 0 else self.panel.notebooks[n - 1].id)
                except:
                    pass
            elif ph == "#notebook-picker":
                self.props.menu_open = not self.props.menu_open
            elif ph == "#delete-note":
                self.props_open = False
                self.delete_note()
            elif ph == "":
                self.props_open = False
            else:
                self.props.menu_open = False
            return True
        if self.settings_open:
            var sh = self.boxes.hit_any(x, y, [".sw-skin", "#close-properties"])
            if sh == "#close-properties":
                self.settings_open = False
            elif sh.startswith(".sw-skin"):
                var names: List[String] = ["crayon", "paper", "night"]
                var at = 0 if sh == ".sw-skin" else (1 if sh == ".sw-skin@2" else 2)
                self.set_skin(names[at])
            return True
        if self.card_open:
            var ch = self.boxes.hit_any(x, y, ["#top-properties", "#note-title", "#share-props", "#share-focus", "#clear-note", "#share-print", "#share-png", "#share-backup", "#share-markdown", "#share-vault", "#share-icon", "#share-link", "#island"])
            if ch == "#note-title":
                self.card.editing = True
                self.card.all_selected = False
                return True
            if ch == "#island":  # (inside the card, on nothing)
                return True
            self.card_open = False
            self.card.editing = False
            if ch == "#top-properties":
                self.settings_open = True
            elif ch == "#share-props":
                self.props_open = True
                self.props.menu_open = False
            elif ch == "#clear-note":
                self.clear_all()
            elif ch.startswith("#share-"):
                self.say("Not in the native app yet")
            return True
        if hit == "#open-retry":
            var again = self.current
            self.open(again)
            return True
        if hit == "#save-copy":
            self.save_copy()
            return True
        if hit == "#save-retry":
            self.retry_save()
            return True
        if hit == "#share-button":
            self.card_open = True
            self.card.title = self.notes[self.note_index(self.current)].title if self.note_index(self.current) >= 0 else String("")
            self.card.editing = False
            return True
        if hit == "#search-button":
            self.open_search()
            return True
        if hit == "#rail-new-note":
            self.create("canvas")
            return True
        if hit == "#toggle-sidebar":
            self.sidebar = not self.sidebar
            return True
        if hit.startswith("row:"):
            var id = self.panel.hit(x, y, 0)
            if id >= 0:
                self.open(id)
                return True
        if hit.startswith(".sec-head") and (y < self.panel.list_y0 or y >= self.panel.list_y1):
            return True  # (a shelf's head scrolled out from under the footer: nothing there)
        if hit.startswith(".sec-head"):
            var at = self.panel.add_at(x, y)
            if at >= 0:
                self.panel.naming = at
                self.panel.renaming = -1
                self.panel.naming_text = ""
                self.panel.open_shelves[at] = True
                return True
        if hit.startswith(".nav-row:") and self.panel.edit_at(x, y) >= 0:
            self.book_card = self.panel.edit_at(x, y)
            self.props.menu_open = False
            return True
        if hit.startswith(".nav-row:"):
            var id = self.panel.hit(x, y, 1)
            if id >= 0:
                self.panel.toggle_book(id)
                self.remember_folds()
                return True
        if hit.startswith(".sec-head"):
            var at = 0
            if hit != ".sec-head":
                try:
                    at = Int(String(hit[byte=10:])) - 1
                except:
                    at = -1
            self.panel.toggle_shelf(at)
            self.remember_folds()
            return True
        if self.on_map() and hit == "" and (not self.sidebar or self.boxes.hit_any(x, y, ["#sidebar"]) == ""):
            return self.map_tap(x, y)
        if self.on_canvas() and hit == "" and (not self.sidebar or self.boxes.hit_any(x, y, ["#sidebar"]) == ""):
            return self.canvas_tap(x, y, mods)
        var ni = self.note_index(self.current)
        if ni >= 0 and self.notes[ni].kind == "page" and not self.notes[ni].secure and self.doc.may_edit() and not self.searching:
            var tool = self.boxes.hit_any(x, y, [".page-tool:"])
            if tool == ".page-tool:Draw":
                self.page.draw_mode = True
                return True
            if tool == ".page-tool:Pen" or tool == ".page-tool:Red" or tool == ".page-tool:Highlighter" or tool == ".page-tool:Eraser":
                self.page.tool = "pen" if tool.endswith("Pen") else ("red" if tool.endswith("Red") else ("highlight" if tool.endswith("Highlighter") else "eraser"))
                self.page.draw_mode = True
                return True
            if tool == ".page-tool:Write":
                self.page.draw_mode = False
                if self.page.tool == "eraser":
                    self.page.tool = "pen"
                return True
            if tool != "":
                self.say("Not in the native app yet")
                return True
            if tool == "" and not self.page.draw_mode and (not self.sidebar or self.boxes.hit_any(x, y, ["#sidebar"]) == ""):
                if (mods & 1) != 0:
                    if self.page.extend_tap(x, y):
                        return True
                elif clock_us() - self.doubled_us < 400_000 and self.page.select_para(x, y):
                    return True
                elif self.page.tap(x, y):
                    return True
        if hit == "[Crayon skin]":
            self.set_skin("crayon")
            return True
        if hit == "[Paper skin]":
            self.set_skin("paper")
            return True
        if hit == "[Night skin]":
            self.set_skin("night")
            return True
        return False


def _in(x: Float64, y: Float64, bx: Float64, by: Float64, size: Float64) -> Bool:
    """Inside a round button of this size (a circle, as the browser's hit test of a border-radius 50 % box)."""
    var dx = x - (bx + size / 2)
    var dy = y - (by + size / 2)
    return dx * dx + dy * dy <= size * size / 4
