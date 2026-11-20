# pnote's web look (goal 79): Personal Note's own database (its SQLite schema: notes, notebooks), drawn with the web
# app's chrome from mojoui's generic pieces (mojoui.notesshell, mojoui.pagesheet, mojoui.skin, mojoui.fonttext). This
# file only composes them: which note is open, whether the notes panel shows, where the islands sit, what a tap hits.

from std.collections import Dict
from mojoui.scene import Painter
from mojoui.sqlite import Database
from mojoui.json import Json, json_string
from mojoui.skin import Skin, mix, with_alpha
from pnlook import pn_names, pn_panel, pn_skin_cards, skin_named, canvas_dock_items
from mojoui.notesshell import (
    Boxes, NotesPanel, PanelNote, PanelNotebook, draw_desk, draw_round_button, draw_title_island, draw_shadows, text_normal,
)
from mojoui.pagesheet import PageSheet
from mojoui.buzanmap import BuzanMap, draw_minimap, map_json
from mojoui.omnibar import Omnibar, OmniGroup, OmniRow, OmniPill, word_match, relative_time, short_date, utc_epoch
from mojoui.shared import environment
from mojoui.files import write_setting
from mojoui.islandcard import IslandCard, CardTile
from mojoui.settingswin import SettingsWindow, SettingsPage, skin_cards
from std.ffi import external_call
from mojoui.notesshell import draw_tool_dock, draw_zoom_island, draw_hint
from mojoui.canvas import rgba
from mojoui.skin import hexc
from mojoui.objectlayer import ObjectLayer, import_json_canvas, import_json_canvas_doc, export_json_canvas, TEXT, STICKY, CH_MOVE
from mojoui.pagedesk import BoardTools
from mojoui.notesshell import draw_selection_bar, DockItem
from mojoui.pagedesk import DeskView, BoardLook, opening_view, draw_page_chrome, PAGE_W, PAGE_H
from mojoui.notesshell import draw_dock, dock_height, draw_history_island, draw_page_zoom, draw_locked_cover
from mojoui.docstore import KeptDocs, SaveTimer, RowSave, SqlArg, save_row, text_arg, int_arg, clock_us, SAVED, CONFLICT
from mojoui.objectlayer import reading_text
from mojoui.buzanmap import map_text, node_extra

comptime S_PAGE = 0
comptime S_CANVAS = 1
comptime S_MAP = 2


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
    var board: ObjectLayer  # the open canvas note's objects
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
    var dbs: List[Database]  # the open connection (one, kept)
    var saver: SaveTimer  # the web's save debounce (save-flush.js: 650 ms after the last edit)
    var save_state: String  # "" saved, else the island's error ("Couldn’t save")
    var save_detail: String
    var save_kind: String  # what the pending save writes: page | canvas | mindmap ("" nothing)
    var kept: KeptDocs[ObjectLayer]  # canvases already parsed, by (note, revision) (D-7934)
    var kept_pages: Dict[Int, Int]  # a kept canvas's page grid (columns × 1000 + rows), by note
    var cold_opens: Bool  # (the race's cold-open row: nothing kept is reused)

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
        self.board = ObjectLayer()
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
        self.dbs = List[Database]()
        self.saver = SaveTimer(650)
        self.save_state = ""
        self.save_detail = ""
        self.save_kind = ""
        self.kept = KeptDocs[ObjectLayer](4)
        self.kept_pages = Dict[Int, Int]()
        self.cold_opens = False
        try:
            self.dbs.append(Database(db_path))
            self.load()
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
            self.notes.append(NoteRec(st.int(0), st.text(7), st.text(8), title, kind, "" if secure else st.text(3), st.int(4), emoji, tint, own, st.int(9), secure))
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

    def read_row(mut self, i: Int, with_content: Bool = True):
        """One note's row from the file again (the web fetches a note when it opens it): its content, revision and
        secure flag, so an edit another app saved is what opens and what the next save builds on."""
        if len(self.dbs) == 0:
            return
        try:
            var q = self.dbs[0].prepare("SELECT " + ("content" if with_content else "''") + ", revision, secure, title, updated_at FROM notes WHERE id = ?")
            q.bind(1, self.notes[i].id)
            if q.step():
                self.notes[i].secure = q.int(2) != 0
                if with_content:
                    self.notes[i].content = "" if self.notes[i].secure else q.text(0)
                self.notes[i].revision = q.int(1)
                self.notes[i].title = q.text(3)
                self.notes[i].updated = q.text(4)
        except e:
            print("PNOTE ERROR: read note: " + String(e), flush=True)

    def locked(self) -> Bool:
        """The open note is a secure one (shown locked: nothing here reads or writes its words)."""
        var i = self.note_index(self.current)
        return i >= 0 and self.notes[i].secure

    def note_index(self, id: Int) -> Int:
        for i in range(len(self.notes)):
            if self.notes[i].id == id:
                return i
        return -1

    def open(mut self, id: Int):
        var i = self.note_index(id)
        if i < 0:
            return
        self.flush()  # (the outgoing note's pending edits land first, as the web's settleOutgoingNote)
        var out_i = self.note_index(self.current)
        if out_i >= 0 and self.notes[out_i].kind == "canvas" and not self.notes[out_i].secure and self.board.unsaved() == False:
            var moving = ObjectLayer()
            swap(moving, self.board)
            self.kept.keep(self.notes[out_i].id, self.notes[out_i].revision, moving^)  # (the canvas just left, kept parsed)
            self.kept_pages[self.notes[out_i].id] = self.cols * 1000 + self.rows
        i = self.note_index(id)
        self.read_row(i, False)
        var at = -1 if self.cold_opens else self.kept.find(id, self.notes[i].revision)
        if self.notes[i].kind == "canvas" and not self.notes[i].secure and at >= 0:
            # the file still holds the revision this canvas was parsed at: reuse it (D-7934), nothing read or parsed
            self.current = id
            self.panel.active = id
            self.board = self.kept.take(at)
            var grid = self.kept_pages.get(id, 1001)
            self.cols = grid // 1000
            self.rows = grid % 1000
            self.view_set = False
            self.tools = BoardTools()
            self.sticky_look()
            return
        self.read_row(i, True)
        self.current = id
        self.panel.active = id
        ref n = self.notes[i]
        if n.secure:  # (its content column is a placeholder: never shown, never edited, never saved)
            self.page.set_markdown("")
            self.board = ObjectLayer()
            self.map = BuzanMap()
            return
        if n.kind == "page":
            var md = String("")
            try:
                var j = Json.parse(n.content)
                md = j.text(j.get(0, "markdown"))
            except:
                md = ""
            self.page.set_markdown(md)
        elif n.kind == "canvas":
            self.view_set = False
            self.cols = 1
            self.rows = 1
            try:
                var j = Json.parse(n.content)  # (parsed once: the objects and the page grid, D-7941)
                self.board = import_json_canvas_doc(j)
                self.board.set_connector_gap(6)
                self.board.mark_saved()  # (what the file holds: unchanged until edited)
                self.tools = BoardTools()
                self.sticky_look()
                var pg = j.get(j.get(0, "pn"), "page")
                self.cols = max(1, Int(j.real(j.get(pg, "columns"), 1)))
                self.rows = max(1, Int(j.real(j.get(pg, "rows"), 1)))
            except e:
                print("PNOTE ERROR: canvas: " + String(e), flush=True)
                self.board = ObjectLayer()
        elif n.kind == "mindmap":
            self.map = BuzanMap()
            try:
                var j = Json.parse(n.content)
                var nodes = j.get(0, "nodes")
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
                    _ = self.map.add(par, j.text(j.get(nd, "text")), j.real(j.get(nd, "x")), j.real(j.get(nd, "y")), hexc(j.text(j.get(nd, "color"), "#3d8fe8")),
                                     ids[q], j.real(j.get(nd, "fontSize"), 0), j.flag(j.get(nd, "bold")), j.text(j.get(nd, "font")), node_extra(j, nd))
                self.map_root = j.text(j.get(0, "rootId"), "root")
                self.map.selected = 0
                for r in range(len(ids)):
                    if ids[r] == self.map_root:
                        self.map.selected = r
                self.map.freeze()
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
        self.boxes.clear()
        self.boxes.add("#app", 0, 0, w, h)
        p.begin_layer("shell")
        p.layer_transform(0, 0, k)
        draw_desk(p, w, h, k, self.sk)
        self.win_w = w
        self.win_h = h
        var left = 296.0 if self.sidebar else 0.0
        var i = self.note_index(self.current)
        if i >= 0 and self.notes[i].kind == "canvas" and not self.notes[i].secure:
            # the board under every island: the page frame (screen px), the objects (a layer in page px), then the chrome
            if not self.view_set:
                self.view = opening_view(w, h, Float64(self.cols) * PAGE_W, Float64(self.rows) * PAGE_H)
                self.view_set = True
            draw_page_chrome(p, self.boxes, self.view, w, h, self.cols, self.rows, PAGE_W, PAGE_H, k, self.sk)
            self.look.paint(p, self.board, self.view, w, h, k, self.tools.lifted(self.board))
            self.tools.paint_overlay(p, self.look, self.board, self.view, k)
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
            if n.kind == "mindmap" and not n.secure:
                var mw = w - left - 4 - 12
                var mh = h - 66 - 12
                self.map.draw(p, self.boxes, left + 4, 66, mw, mh, 0, self.sk, n.title)
                var fv = self.map.fit(mw, mh, 80)
                draw_minimap(self.map, p, self.boxes, left + 4 + mw - 16 - 170, 66 + mh - 72 - 102, mw, mh, self.sk)
                draw_tool_dock(p, self.boxes, w - 72, (h - 410) / 2, ["Add image", "Import JSON", "Export JSON", "Export PNG", "", "Undo", "Redo", "", "Clean up layout", "Fit map"],
                               ["image-plus", "folder-open", "braces", "image-down", "", "undo-2", "redo-2", "", "wand-sparkles", "scan"], k, self.sk, "#mindmap-rail-actions")
                draw_zoom_island(p, self.boxes, left + 4 + mw - 16 - 132, 66 + mh - 16 - 42, Int(fv[0] * 100 + 0.5), k, self.sk)
                draw_hint(p, self.boxes, left + 4 + mw / 2, 66 + mh - 18 - 28, "Drag an anchor to draw. Hold an idea to switch Box or Branch.", self.sk)
            if n.kind == "canvas" and not n.secure:
                self.boxes.add("#paper", left, 0, w - left, h)
                self.boxes.add("#leafer-host", left, 0, w - left, h)
                self.boxes.add("#note-input", left, 0, w - left, h)
                var items = canvas_dock_items(hexc("#20201e"))
                var active = self.dock_name()
                if active == "#dock-more":  # (a tool from the flyout shows in its place)
                    items[8].icon = "circle cx=5.5 cy=18.5 r=2|circle cx=18.5 cy=5.5 r=2|path d=M7.5 16.5c4-1 3-8 9-9"
                draw_dock(p, self.boxes, w - 72, 72 + (h - 144 - dock_height(items)) / 2, items, active, k, self.sk, "#dock-canvas")
                if len(self.board.selected) > 0 and self.tools.editing == -1:
                    _ = draw_selection_bar(p, self.boxes, left + (w - left) / 2, 64, ["Back", "Forward", "Lock", "Link to words", "Delete"], k, self.sk)
                draw_history_island(p, self.boxes, left + 16, h - 16 - 48, k, self.sk)
                draw_page_zoom(p, self.boxes, w - 16, h - 16 - 48, Int(self.view.scale * 100 + 0.5), k, self.sk)
            if n.kind == "page" and not n.secure:
                self.page.draw(p, self.boxes, left + 4, 66, w - 12, h - 12, k, n.emoji, self.sk.tint(n.tint), self.sk.radius)
        if self.save_state != "":  # (the web puts a failed save in its island: "Couldn’t save", the reason, Retry)
            draw_hint(p, self.boxes, left + (w - left) / 2, h - 18 - 28 - 40, self.save_state + " · " + self.save_detail, self.sk)
        self.paint_overlays(p, w, h, k)

    def paint_overlays[P: Painter](mut self, mut p: P, w: Float64, h: Float64, k: Float64):
        var i = self.note_index(self.current)
        if self.card_open and i >= 0:
            ref c = self.card
            c.status = "Saved on this device" if self.save_state == "" else self.save_state
            c.status_dot = self.sk.c2
            c.place = "Inbox"
            c.wide_id = "#share-focus"
            c.wide_label = "Focus"
            c.wide_icon = "focus"
            c.wide_key = "Ctrl ."
            c.tiles.clear()
            var ids: List[String] = ["#share-print", "#share-png", "#share-backup", "#share-markdown", "#share-vault", "#share-icon", "#share-link", "#share-props", "#top-properties", "#clear-note"]
            var labels: List[String] = ["Print", "Picture", "Backup", "Markdown", "Obsidian", "Icon", "Link note", "Properties", "Settings", "Clear all"]
            var icons: List[String] = ["printer", "image-down", "archive", "file-down", "folder-down", "wand-sparkles", "link", "file-text", "sliders-horizontal", "eraser"]
            for t in range(len(ids)):
                c.tiles.append(CardTile(ids[t], labels[t], icons[t], t == 9))
            c.draw(p, self.boxes, (296.0 if self.sidebar else 0.0) + 16, w - 16, k, self.sk)
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

    def now(self) -> Int:
        """The clock (PNOTE_NOW: a fixed UTC time, for comparing with a reference shot then)."""
        var fixed = environment("PNOTE_NOW", "")
        if fixed != "":
            return utc_epoch(fixed)
        return Int(external_call["time", Int](0))

    def search(mut self):
        """The omnibar's groups for the query: notes and actions with a word starting with it (the web's word search)."""
        var notes = List[OmniRow]()
        var first = -1
        self.hits.clear()
        for i in range(len(self.notes)):
            ref n = self.notes[i]
            if self.omni.query == "" or word_match(n.title, self.omni.query):
                self.hits.append(n.id)
                if first < 0:
                    first = i
                notes.append(OmniRow(n.emoji, "", self.sk.tint(n.tint), n.title, "Page" if n.kind == "page" else ("Canvas" if n.kind == "canvas" else "Mind map"),
                                     "Inbox", self.sk.ink, relative_time(n.updated, self.now())))
        var acts = List[OmniRow]()
        var names: List[String] = ["New page", "New canvas", "New mind map", "Link to a note…", "Open settings", "Switch skin"]
        var icons: List[String] = ["file-pen", "file-text", "git-fork", "link", "sliders-horizontal", "palette"]
        for i in range(len(names)):
            if self.omni.query != "" and word_match(names[i], self.omni.query):
                acts.append(OmniRow("", icons[i], 0, names[i], "", "", 0, ""))
        self.omni.pills.clear()
        self.omni.pills.append(OmniPill("All", ""))
        self.omni.pills.append(OmniPill("Notes", String(len(notes))))
        self.omni.pills.append(OmniPill("Notebooks", "0"))
        self.omni.pills.append(OmniPill("Actions", String(len(acts))))
        self.omni.groups.clear()
        self.omni.groups.append(OmniGroup("Notes", notes^))
        self.omni.groups.append(OmniGroup("Actions", acts^))
        self.omni.selected = 0
        if first >= 0:
            ref n = self.notes[first]
            self.omni.preview_kind = "Page" if n.kind == "page" else ("Canvas" if n.kind == "canvas" else "Mind map")
            self.omni.preview_edited = relative_time(n.updated, self.now())
            self.omni.preview_created = short_date(n.created)

    def save_page(mut self):
        """An edit on the open page: saved later, as the web does (queueSave: 650 ms after the last edit)."""
        self.queue_save("page")

    def queue_save(mut self, kind: String):
        var i = self.note_index(self.current)
        if i < 0 or self.notes[i].kind != kind or self.notes[i].secure:
            return
        self.save_kind = kind
        self.saver.touch(clock_us())

    def tick(mut self) -> Bool:
        """The save timer's tick (App.every while a save is pending): writes it once it is due. True when the screen
        changes (a failed save shows)."""
        if not self.saver.due(clock_us()):
            return False
        var before = self.save_state
        self.flush()
        return self.save_state != before

    def flush(mut self):
        """Writes the pending save now (a due timer, another note opening, the app closing)."""
        if not self.saver.pending():
            return
        self.saver.done()
        var kind = self.save_kind
        self.save_kind = ""
        var i = self.note_index(self.current)
        if i < 0 or self.notes[i].kind != kind:
            return
        if kind == "page":
            var md = self.page.markdown()
            var ink = String('{"marks":[],"drawings":[]}')
            try:
                var j = Json.parse(self.notes[i].content)
                var node = j.get(0, "ink")
                if node >= 0:
                    ink = j.dump(node)
            except:
                pass
            if len(self.page.marks) > 0:
                ink = self.page.ink_json()
            # (page_note.page_text: a page's search body is its Markdown itself)
            self.save_note(i, '{"version":1,"markdown":' + json_string(md) + ',"ink":' + ink + "}", md)
        elif kind == "canvas":
            self.save_note(i, export_json_canvas(self.board, self.cols, self.rows), reading_text(self.board))
            if self.save_state == "":
                self.board.mark_saved()
        elif kind == "mindmap":
            self.save_note(i, map_json(self.map, self.notes[i].title, self.map_root), map_text(self.map))

    def save_note(mut self, i: Int, content: String, body: String):
        """One note's new content into Personal Note's schema as its API saves it (services.save_note): only on the
        revision this copy holds (another app saved first: nothing is written and the island says so), with the change
        log, the search index and, for a map, its reminders kept in step, in one transaction. Then that one row is
        updated in memory and moves to the top of the list; nothing else is read again."""
        if self.notes[i].secure or len(self.dbs) == 0:
            print("PNOTE SAVE: refused (secure note " + String(self.notes[i].id) + ")", flush=True)
            return
        var id = self.notes[i].id
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
        self.landed(i, r.status, r.revision, r.value, r.message)
        if r.status == SAVED:
            self.notes[i].content = content

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

    def log_change(self, mut s: RowSave, id: Int):
        """Personal Note's workspace change feed (record_change): the sequence moves on, a row for this revision."""
        s.then("UPDATE workspace_state SET sequence = sequence + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 1", List[SqlArg]())
        s.then("INSERT INTO workspace_changes (sequence, resource_kind, resource_id, revision, change_type) SELECT (SELECT sequence FROM workspace_state WHERE id = 1), 'note', resource_id, revision, 'updated' FROM notes WHERE id = ?",
               [int_arg(id)])

    def text_in(mut self, kind: String, text: String) -> Bool:
        """An input method's commit or a paste into the open page."""
        var i = self.note_index(self.current)
        if i < 0 or self.notes[i].kind != "page" or self.notes[i].secure or self.searching or self.card_open or self.settings_open:
            return False
        self.page.insert(text)
        self.save_page()
        return True

    def preedit(mut self, text: String, cx: Float64, cy: Float64, cw: Float64, ch: Float64) -> Bool:
        var i = self.note_index(self.current)
        if i < 0 or self.notes[i].kind != "page" or self.notes[i].secure:
            return False
        self.page.preedit = text
        if text != "":
            var r = self.page.caret_rect
            print("PNOTE IME: preedit=\"" + text + "\" underline=1 caret=" + String(r[0]) + "," + String(r[1]) + " cursor_location=" + String(cx) + "," + String(cy) + "," + String(cw) + "," + String(ch), flush=True)
        return True

    def key(mut self, name: String, mods: Int) -> Bool:
        var mi = self.note_index(self.current)
        if mi >= 0 and self.notes[mi].kind == "mindmap" and not self.notes[mi].secure and not self.searching and not self.card_open and not self.settings_open:
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
        if self.on_canvas():
            var r = self.tools.key(name, mods, self.board, self.view, self.win_w, self.win_h, self.cols, self.rows)
            if r and (mods & 2) != 0 and (name == "z" or name == "Z" or name == "y"):  # (an undo or redo by key, as by the island)
                self.tools.hug_routes(self.board, self.look)
            self.save_canvas()
            if r:
                return True
        var ni = self.note_index(self.current)
        if not self.searching and not self.card_open and not self.settings_open and ni >= 0 and self.notes[ni].kind == "page" and not self.notes[ni].secure:
            if self.page.draw_mode:
                if name == "Escape":
                    self.page.draw_mode = False
                    return True
                return False
            if name == "End" and (mods & 2) != 0:
                self.page.caret_end()
                return True
            if name == "Home":
                self.page.caret_home()
                return True
            if name == "End":
                self.page.caret_line_end()
                return True
            if name == "ArrowLeft":
                self.page.caret_left()
                return True
            if name == "ArrowRight":
                self.page.caret_right()
                return True
            if name == "Delete":
                self.page.delete_forward()
                self.save_page()
                return True
            if name == "Return" or name == "Enter":
                self.page.newline()
                self.save_page()
                return True
            if name == "BackSpace" or name == "Backspace":
                self.page.backspace()
                self.save_page()
                return True
            if (mods & 2) == 0 and name.byte_length() >= 1 and (name.byte_length() == 1 or Int(name.as_bytes()[0]) >= 0x80) and name != "Escape":
                self.page.insert(name)
                self.save_page()
                return True
            return False
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
            return False
        if name == "Enter":
            if self.omni.selected >= 0 and self.omni.selected < len(self.hits):
                var id = self.hits[self.omni.selected]
                self.searching = False
                self.open(id)
            return True
        if name == "ArrowDown" or name == "ArrowUp":
            var n = len(self.hits)
            if n > 0:
                self.omni.selected = (self.omni.selected + (1 if name == "ArrowDown" else n - 1)) % n
            return True
        if name == "Escape":
            self.searching = False
            self.card_open = False
        elif name == "Backspace":
            var b = self.omni.query.as_bytes()
            if len(b) > 0:
                var cut = String(self.omni.query[byte=0:len(b) - 1])
                self.omni.query = cut
                self.search()
        elif name.byte_length() == 1 or (name.byte_length() > 1 and Int(name.as_bytes()[0]) >= 0x80):
            self.omni.query += name
            self.search()
        else:
            return False
        return True

    def caret(self) -> Tuple[Float64, Float64, Float64, Float64]:
        var i = self.note_index(self.current)
        if i < 0 or self.notes[i].kind != "page":
            return (-1.0, 0.0, 0.0, 0.0)
        return self.page.caret_rect

    def bench(mut self, name: String) -> Tuple[Float64, Float64]:
        """The race's app steps (the GTK host's framebench and its note steps): switch to the next note, open or close the
        omnibar, open a note of each kind in turn; on an open canvas, Personal Note's benchmark steps through the same
        board the person uses (pagedesk.BoardTools): pan with the hand, pen, a text box written in the middle of the
        window, an object (or 40 selected) to drag, thirty moves to undo and redo, and a fresh open of the note."""
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
        if not self.on_canvas():
            return (-1.0, -1.0)
        var w = self.win_w
        var h = self.win_h
        if name == "bench:pan" or name == "bench:zoom":
            self.tools.set_tool("hand", self.board, self.view, w, h, self.cols, self.rows)
        elif name == "bench:zoom30" or name == "bench:zoom100":  # (benchmark-f034's "zoomed out to 30%" and "at 100%"; the
            # host presses before it readies a pan, so the hand is picked here)
            self.tools.set_tool("hand", self.board, self.view, w, h, self.cols, self.rows)
            self.view = self.view.zoomed_at(0.3 if name == "bench:zoom30" else 1.0, w / 2, h / 2)
        elif name == "bench:redo":  # (the undos before it made the history)
            pass
        elif name == "bench:draw" or name == "bench:finish":
            self.board.clear_selection()
            self.tools.set_tool("pen", self.board, self.view, w, h, self.cols, self.rows)
        elif name == "bench:type":
            self.tools.set_tool("text", self.board, self.view, w, h, self.cols, self.rows)
            _ = self.tools.tap(w / 2, h / 2, self.board, self.view, w, h)
        elif name == "bench:reopen":
            self.open(self.current)
        elif name == "bench:coldopens" or name == "bench:keptopens":  # (the race's two open rows)
            self.cold_opens = name == "bench:coldopens"
            self.kept.clear()
        elif name == "bench:dragone" or name == "bench:undoredo" or name == "bench:undo" or name == "bench:drag40":
            self.tools.set_tool("select", self.board, self.view, w, h, self.cols, self.rows)
            var vis = self.tools.visible_objects(self.board, self.view, w, h)
            if len(vis) == 0:
                return (-1.0, -1.0)
            self.board.clear_selection()
            if name == "bench:drag40":
                for m in range(min(40, len(vis))):
                    self.board.select(self.board.objs[vis[m]].id, True)
                var o0 = self.board.objs[vis[0]].copy()
                var c0 = self.view.to_screen(o0.x + o0.w / 2, o0.y + o0.h / 2)
                return (c0[0], c0[1])
            var k = len(vis) // 2
            if name == "bench:undoredo" or name == "bench:undo":  # (thirty separate moves, each its own undo step, to walk back and forth)
                for m in range(min(30, len(vis))):
                    self.board.select(self.board.objs[vis[m]].id, False)
                    self.board.begin_gesture(CH_MOVE)
                    self.board.move_by(6, 4)
                    self.board.end_gesture()
                self.tools.changed = True
                self.save_canvas()
                return (-1.0, -1.0)
            var o = self.board.objs[vis[k]].copy()
            self.board.select(o.id, False)
            var c = self.view.to_screen(o.x + o.w / 2, o.y + o.h / 2)
            return (c[0], c[1])
        return (-1.0, -1.0)

    def wheel(mut self, x: Float64, y: Float64, dx: Float64, dy: Float64) -> Bool:
        """A wheel or touchpad scroll: on a canvas the view moves (the web's wheel pan)."""
        if not self.on_canvas():
            return False
        self.view = self.tools.scroll(self.view, dx, dy, self.win_w, self.win_h, self.cols, self.rows)
        return True

    def zoom(mut self, x: Float64, y: Float64, factor: Float64) -> Bool:
        """A pinch or Ctrl+wheel: on a canvas the view zooms about the pointer."""
        if not self.on_canvas():
            return False
        self.view = self.tools.zoom_at(self.view, factor, x, y, self.win_w, self.win_h, self.cols, self.rows)
        return True

    # ------------------------------------------------ input

    def press(mut self, x: Float64, y: Float64) -> Bool:
        """The pointer went down (a drag may follow)."""
        self.title_focus = False  # (a click moves the focus: the ring goes)
        if self.on_canvas():
            if self.boxes.hit_any(x, y, ["[Canvas tools]", "#history-island", "#zoom-control", "#selection-bar", "#island", "#toggle-sidebar", "#search-button"]) != "":
                return False
            return self.tools.press(x, y, self.board, self.view)
        var ni = self.note_index(self.current)
        if ni >= 0 and self.notes[ni].kind == "page" and not self.notes[ni].secure and self.page.draw_mode and not self.searching and not self.card_open:
            if self.boxes.hit_any(x, y, [".page-paper"]) != "" and self.boxes.hit_any(x, y, ["[Page tools]", ".page-draw-hint"]) == "":
                self.page.mark_press(x, y)
                return True
        return False

    def pan(mut self, x: Float64, y: Float64) -> Bool:
        if self.on_canvas():
            return self.tools.pan(x, y, self.board, self.view)  # (the hand tool moves self.view)
        if len(self.page.wet) > 0:
            self.page.mark_move(x, y)
            return True
        return False

    def release(mut self, x: Float64, y: Float64) -> Bool:
        if self.on_canvas():
            var r = self.tools.release(x, y, self.board, self.view)
            self.save_canvas()
            return r
        if len(self.page.wet) > 0:
            if self.page.mark_release():
                self.save_page()
            return True
        return False

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
        return i >= 0 and self.notes[i].kind == "canvas" and not self.notes[i].secure and not self.searching and not self.card_open and not self.settings_open

    def canvas_tap(mut self, x: Float64, y: Float64) -> Bool:
        """A tap on a canvas note: the dock, the history and zoom islands, else the board's tool."""
        var hit = self.boxes.hit_any(x, y, ["[Select]", "[Text]", "[Pen]", "[Stroke eraser]", "[Shape]", "[Sticky note]", "#undo", "#redo",
                                            "#zoom-in", "#zoom-out", "#zoom-fit", "#zoom-value", "#dock-more", "#ink-options-trigger", "#voice-button",
                                            "#selection-bar", "[Canvas tools]", "#history-island", "#zoom-control"])
        var names: List[String] = ["[Select]", "[Text]", "[Pen]", "[Stroke eraser]", "[Shape]", "[Sticky note]"]
        var tools: List[String] = ["select", "text", "pen", "eraser", "shape", "sticky"]
        for t in range(len(names)):
            if hit == names[t]:
                self.tools.set_tool(tools[t], self.board, self.view, self.win_w, self.win_h, self.cols, self.rows)
                return True
        if hit == "#undo":
            self.tools.undo(self.board)
            self.tools.hug_routes(self.board, self.look)
        elif hit == "#redo":
            self.tools.redo(self.board)
            self.tools.hug_routes(self.board, self.look)
        elif hit == "#zoom-in" or hit == "#zoom-out":
            self.view = self.tools.zoom_step(self.view, 1 if hit == "#zoom-in" else -1, self.win_w, self.win_h, self.cols, self.rows)
        elif hit == "#zoom-fit":
            self.view = opening_view(self.win_w, self.win_h, Float64(self.cols) * PAGE_W, Float64(self.rows) * PAGE_H)
        elif hit == "":
            if not self.tools.tap(x, y, self.board, self.view, self.win_w, self.win_h):
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
        if self.notes[i].secure:
            print("PNOTE SAVE: refused (secure note " + String(self.notes[i].id) + ")", flush=True)
            return
        self.flush()
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
            self.notes[i].title = t
            if not self.notes[i].icon_set:
                self.notes[i].emoji = guess_emoji(t, self.notes[i].kind)
                self.notes[i].tint = tint_of(self.notes[i].emoji)
        self.landed(i, r.status, r.revision, r.value, r.message)

    def hover(mut self, x: Float64, y: Float64) -> Bool:
        """The pointer moved; True when a hover state changes (only then the screen redraws)."""
        var before = self.boxes.hit_any(self.px, self.py, ["#toggle-sidebar", "#search-button"])
        self.px = x
        self.py = y
        return self.boxes.hit_any(x, y, ["#toggle-sidebar", "#search-button"]) != before

    def tap(mut self, x: Float64, y: Float64) -> Bool:
        """A tap at (x, y) layout px; True when it changed something."""
        self.title_focus = False
        var hit = self.boxes.hit_any(x, y, ["#toggle-sidebar", "#search-button", "row:", "[Crayon skin]", "[Paper skin]", "[Night skin]", ".sec-head", "#share-button"])
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
            var ch = self.boxes.hit_any(x, y, ["#top-properties", "#note-title"])
            if ch == "#note-title":
                self.card.editing = True
                self.card.all_selected = False
                return True
            self.card_open = False
            self.card.editing = False
            if ch == "#top-properties":
                self.settings_open = True
            return True
        if hit == "#share-button":
            self.card_open = True
            self.card.title = self.notes[self.note_index(self.current)].title if self.note_index(self.current) >= 0 else String("")
            self.card.editing = False
            return True
        if hit == "#search-button":
            self.searching = True
            self.omni.query = ""
            self.search()
            return True
        if hit == "#toggle-sidebar":
            self.sidebar = not self.sidebar
            return True
        if hit.startswith("row:"):
            for ref n in self.notes:
                if hit == "row:" + n.emoji + " " + n.title:
                    self.open(n.id)
                    return True
        if hit.startswith(".sec-head"):
            var at = 0
            if hit != ".sec-head":
                try:
                    at = Int(String(hit[byte=10:])) - 1
                except:
                    at = -1
            self.panel.toggle_shelf(at)
            return True
        if self.on_canvas() and hit == "" and (not self.sidebar or self.boxes.hit_any(x, y, ["#sidebar"]) == ""):
            return self.canvas_tap(x, y)
        var ni = self.note_index(self.current)
        if ni >= 0 and self.notes[ni].kind == "page" and not self.notes[ni].secure and not self.searching:
            var tool = self.boxes.hit_any(x, y, [".page-tool:"])
            if tool == ".page-tool:Draw" or tool == ".page-tool:Pen":
                self.page.draw_mode = True
                return True
            if tool == ".page-tool:Write":
                self.page.draw_mode = False
                return True
            if tool == "" and not self.page.draw_mode and self.page.tap(x, y):
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
