# pnote's web look (goal 79): Personal Note's own database (its SQLite schema: notes, notebooks), drawn with the web
# app's chrome from mojoui's generic pieces (mojoui.notesshell, mojoui.pagesheet, mojoui.skin, mojoui.fonttext). This
# file only composes them: which note is open, whether the notes panel shows, where the islands sit, what a tap hits.

from mojoui.scene import Painter
from mojoui.sqlite import Database
from mojoui.json import Json, json_string
from mojoui.skin import Skin, skin_named, mix, with_alpha
from mojoui.notesshell import (
    Boxes, NotesPanel, PanelNote, PanelNotebook, draw_desk, draw_round_button, draw_title_island, draw_shadows, text_normal,
)
from mojoui.pagesheet import PageSheet
from mojoui.buzanmap import BuzanMap, draw_minimap
from mojoui.omnibar import Omnibar, OmniGroup, OmniRow, OmniPill, word_match, relative_time, short_date, utc_epoch
from mojoui.shared import environment
from mojoui.islandcard import IslandCard, CardTile
from mojoui.settingswin import SettingsWindow, SettingsPage, skin_cards
from std.ffi import external_call
from mojoui.notesshell import draw_tool_dock, draw_zoom_island, draw_hint
from mojoui.canvas import rgba
from mojoui.skin import hexc
from mojoui.objectlayer import ObjectLayer, import_json_canvas
from mojoui.pagedesk import DeskView, BoardLook, opening_view, draw_page_chrome, PAGE_W, PAGE_H
from mojoui.notesshell import draw_dock, dock_height, canvas_dock_items, draw_history_island, draw_page_zoom

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

    def __init__(out self, db_path: String, skin: String):
        self.db_path = db_path
        self.notes = List[NoteRec]()
        self.panel = NotesPanel()
        self.panel.skin_name = skin
        self.page = PageSheet()
        self.map = BuzanMap()
        self.sk = skin_named(skin)
        self.current = 0
        self.sidebar = False  # (the web opens with the notes panel closed)
        self.boxes = Boxes()
        self.problem = ""
        self.px = -1
        self.py = -1
        self.bench_kind = 0
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
        try:
            self.load()
        except e:
            self.problem = String(e)
            print("PNOTE ERROR: " + self.problem, flush=True)

    def load(mut self) raises:
        var db = Database(self.db_path)
        self.notes.clear()
        var st = db.prepare("SELECT id, title, note_type, content, IFNULL(notebook_id, 0), icon, icon_tint, created_at, updated_at FROM notes ORDER BY updated_at DESC, id DESC")
        while st.step():
            var title = st.text(1)
            var kind = st.text(2)
            var emoji = st.text(5)
            var tint = st.int(6)
            var own = emoji != ""
            if emoji == "":
                emoji = guess_emoji(title, kind)
                tint = tint_of(emoji)
            self.notes.append(NoteRec(st.int(0), st.text(7), st.text(8), title, kind, st.text(3), st.int(4), emoji, tint, own))
        self.panel.notes.clear()
        for ref n in self.notes:
            self.panel.notes.append(PanelNote(n.id, n.title, n.kind, n.emoji, n.tint, n.notebook))
        self.panel.notebooks.clear()
        var nb = db.prepare("SELECT id, name, color, category, (SELECT COUNT(*) FROM notes WHERE notebook_id = notebooks.id) FROM notebooks ORDER BY updated_at DESC, id ASC")
        while nb.step():
            self.panel.notebooks.append(PanelNotebook(nb.int(0), nb.text(1), hexc(nb.text(2)), nb.text(3), notebook_icon(nb.text(1)), nb.int(4)))

    def note_index(self, id: Int) -> Int:
        for i in range(len(self.notes)):
            if self.notes[i].id == id:
                return i
        return -1

    def open(mut self, id: Int):
        var i = self.note_index(id)
        if i < 0:
            return
        self.current = id
        self.panel.active = id
        ref n = self.notes[i]
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
                self.board = import_json_canvas(n.content)
                self.board.set_connector_gap(6)
                var j = Json.parse(n.content)
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
                    _ = self.map.add(par, j.text(j.get(nd, "text")), j.real(j.get(nd, "x")), j.real(j.get(nd, "y")), hexc(j.text(j.get(nd, "color"), "#3d8fe8")))
                self.map.selected = 0
            except:
                pass

    def set_skin(mut self, name: String):
        self.sk = skin_named(name)
        self.panel.skin_name = name

    # ------------------------------------------------ drawing

    def paint[P: Painter](mut self, mut p: P, w: Float64, h: Float64, k: Float64):
        self.boxes.clear()
        self.boxes.add("#app", 0, 0, w, h)
        p.begin_layer("shell")
        p.layer_transform(0, 0, k)
        draw_desk(p, w, h, k, self.sk)
        var left = 296.0 if self.sidebar else 0.0
        var i = self.note_index(self.current)
        if i >= 0 and self.notes[i].kind == "canvas":
            # the board under every island: the page frame (screen px), the objects (a layer in page px), then the chrome
            if not self.view_set:
                self.view = opening_view(w, h, Float64(self.cols) * PAGE_W, Float64(self.rows) * PAGE_H)
                self.view_set = True
            draw_page_chrome(p, self.boxes, self.view, w, h, self.cols, self.rows, PAGE_W, PAGE_H, k, self.sk)
            self.look.paint(p, self.board, self.view, w, h, k)
            p.begin_layer("chrome")
            p.layer_transform(0, 0, k)
        if self.sidebar:
            self.panel.draw(p, self.boxes, k, self.sk, h)
        draw_round_button(p, self.boxes, "#toggle-sidebar", 16, 16, "panel-left", k, self.sk, self.sk.toggle_on if self.sidebar else self.sk.panel,
                          44, not self.sidebar and not self.searching and not self.settings_open and _in(self.px, self.py, 16, 16, 44))
        draw_round_button(p, self.boxes, "#search-button", w - 60, 16, "search", k, self.sk, self.sk.panel, 44, not self.searching and not self.settings_open and _in(self.px, self.py, w - 60, 16, 44))  # (an overlay takes the pointer)
        if i >= 0:
            ref n = self.notes[i]
            var island_emoji = n.emoji if n.kind != "page" else String("")
            if not self.card_open:
                draw_title_island(p, self.boxes, left + 16, w - 16, n.title, island_emoji, self.sk.tint(n.tint), k, self.sk, n.emoji)
            self.boxes.add("#workspace", left, 0, w - left, h)
            if n.kind == "mindmap":
                var mw = w - left - 4 - 12
                var mh = h - 66 - 12
                self.map.draw(p, self.boxes, left + 4, 66, mw, mh, 0, self.sk, n.title)
                var fv = self.map.fit(mw, mh, 80)
                draw_minimap(self.map, p, self.boxes, left + 4 + mw - 16 - 170, 66 + mh - 72 - 102, mw, mh, self.sk)
                draw_tool_dock(p, self.boxes, w - 72, (h - 410) / 2, ["Add image", "Import JSON", "Export JSON", "Export PNG", "", "Undo", "Redo", "", "Clean up layout", "Fit map"],
                               ["image-plus", "folder-open", "braces", "image-down", "", "undo-2", "redo-2", "", "wand-sparkles", "scan"], k, self.sk, "#mindmap-rail-actions")
                draw_zoom_island(p, self.boxes, left + 4 + mw - 16 - 132, 66 + mh - 16 - 42, Int(fv[0] * 100 + 0.5), k, self.sk)
                draw_hint(p, self.boxes, left + 4 + mw / 2, 66 + mh - 18 - 28, "Drag an anchor to draw. Hold an idea to switch Box or Branch.", self.sk)
            if n.kind == "canvas":
                self.boxes.add("#paper", left, 0, w - left, h)
                self.boxes.add("#leafer-host", left, 0, w - left, h)
                self.boxes.add("#note-input", left, 0, w - left, h)
                var items = canvas_dock_items(hexc("#20201e"))
                draw_dock(p, self.boxes, w - 72, 72 + (h - 144 - dock_height(items)) / 2, items, self.tool, k, self.sk, "#dock-canvas")
                draw_history_island(p, self.boxes, left + 16, h - 16 - 48, k, self.sk)
                draw_page_zoom(p, self.boxes, w - 16, h - 16 - 48, Int(self.view.scale * 100 + 0.5), k, self.sk)
            if n.kind == "page" and not False:
                self.page.draw(p, self.boxes, left + 4, 66, w - 12, h - 12, k, n.emoji, self.sk.tint(n.tint), self.sk.radius)
        self.paint_overlays(p, w, h, k)

    def paint_overlays[P: Painter](mut self, mut p: P, w: Float64, h: Float64, k: Float64):
        var i = self.note_index(self.current)
        if self.card_open and i >= 0:
            ref c = self.card
            c.status = "Saved on this device"
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
            skin_cards(p, self.boxes, body[0], body[1], body[2], k, self.sk, self.panel.skin_name)

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
        for i in range(len(self.notes)):
            ref n = self.notes[i]
            if self.omni.query == "" or word_match(n.title, self.omni.query):
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
        """The open page's Markdown into Personal Note's own schema, as its API saves a note: the content JSON (ink kept),
        a new revision, updated_at, the workspace change log, and the search index."""
        var i = self.note_index(self.current)
        if i < 0 or self.notes[i].kind != "page":
            return
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
        var content = '{"version":1,"markdown":' + json_string(md) + ',"ink":' + ink + "}"
        try:
            var db = Database(self.db_path)
            db.exec("BEGIN")
            var up = db.prepare("UPDATE notes SET content = ?, revision = revision + 1, updated_at = CURRENT_TIMESTAMP WHERE id = ?")
            up.bind(1, content)
            up.bind(2, self.notes[i].id)
            _ = up.step()
            var seq = db.prepare("UPDATE workspace_state SET sequence = sequence + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 1")
            _ = seq.step()
            var ch = db.prepare("INSERT INTO workspace_changes (sequence, resource_kind, resource_id, revision, change_type) SELECT (SELECT sequence FROM workspace_state WHERE id = 1), 'note', resource_id, revision, 'updated' FROM notes WHERE id = ?")
            ch.bind(1, self.notes[i].id)
            _ = ch.step()
            var del_ = db.prepare("DELETE FROM note_search WHERE note_id = ?")
            del_.bind(1, self.notes[i].id)
            _ = del_.step()
            var ins = db.prepare("INSERT INTO note_search (note_id, title, body) VALUES (?, ?, ?)")
            ins.bind(1, self.notes[i].id)
            ins.bind(2, self.notes[i].title)
            ins.bind(3, md)
            _ = ins.step()
            db.exec("COMMIT")
            self.notes[i].content = content
        except e:
            print("PNOTE ERROR: save: " + String(e), flush=True)
        self.reload()

    def text_in(mut self, kind: String, text: String) -> Bool:
        """An input method's commit or a paste into the open page."""
        var i = self.note_index(self.current)
        if i < 0 or self.notes[i].kind != "page" or self.searching or self.card_open or self.settings_open:
            return False
        self.page.insert(text)
        self.save_page()
        return True

    def preedit(mut self, text: String, cx: Float64, cy: Float64, cw: Float64, ch: Float64) -> Bool:
        var i = self.note_index(self.current)
        if i < 0 or self.notes[i].kind != "page":
            return False
        self.page.preedit = text
        if text != "":
            var r = self.page.caret_rect
            print("PNOTE IME: preedit=\"" + text + "\" underline=1 caret=" + String(r[0]) + "," + String(r[1]) + " cursor_location=" + String(cx) + "," + String(cy) + "," + String(cw) + "," + String(ch), flush=True)
        return True

    def key(mut self, name: String, mods: Int) -> Bool:
        var ni = self.note_index(self.current)
        if not self.searching and not self.card_open and not self.settings_open and ni >= 0 and self.notes[ni].kind == "page":
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
            return r != 0
        if (self.card_open or self.settings_open) and name == "Escape":
            self.card_open = False
            self.settings_open = False
            return True
        if not self.searching:
            return False
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
        """The race's app steps: switch to the next note, open or close the omnibar, open a note of each kind in turn."""
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
                if n.kind == kinds[at]:
                    self.open(n.id)
                    break
        return (-1.0, -1.0)

    # ------------------------------------------------ input

    def press(mut self, x: Float64, y: Float64) -> Bool:
        """The pointer went down (a drag may follow)."""
        var ni = self.note_index(self.current)
        if ni >= 0 and self.notes[ni].kind == "page" and self.page.draw_mode and not self.searching and not self.card_open:
            if self.boxes.hit_any(x, y, [".page-paper"]) != "" and self.boxes.hit_any(x, y, ["[Page tools]", ".page-draw-hint"]) == "":
                self.page.mark_press(x, y)
                return True
        return False

    def pan(mut self, x: Float64, y: Float64) -> Bool:
        if len(self.page.wet) > 0:
            self.page.mark_move(x, y)
            return True
        return False

    def release(mut self, x: Float64, y: Float64) -> Bool:
        if len(self.page.wet) > 0:
            if self.page.mark_release():
                self.save_page()
            return True
        return False

    def rename(mut self, title: String):
        """The open note's new name, saved as the web's API saves one (title, revision, change log, search index); its
        guessed icon follows the new name."""
        var i = self.note_index(self.current)
        var t = String(title.strip())
        if i < 0 or t == "" or t == self.notes[i].title:
            return
        try:
            var db = Database(self.db_path)
            db.exec("BEGIN")
            var up = db.prepare("UPDATE notes SET title = ?, revision = revision + 1, updated_at = CURRENT_TIMESTAMP WHERE id = ?")
            up.bind(1, t)
            up.bind(2, self.notes[i].id)
            _ = up.step()
            self._log_change(db, self.notes[i].id)
            var fts = db.prepare("UPDATE note_search SET title = ? WHERE note_id = ?")
            fts.bind(1, t)
            fts.bind(2, self.notes[i].id)
            _ = fts.step()
            db.exec("COMMIT")
        except e:
            print("PNOTE ERROR: rename: " + String(e), flush=True)
        self.reload()

    def _log_change(self, mut db: Database, id: Int) raises:
        var seq = db.prepare("UPDATE workspace_state SET sequence = sequence + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 1")
        _ = seq.step()
        var ch = db.prepare("INSERT INTO workspace_changes (sequence, resource_kind, resource_id, revision, change_type) SELECT (SELECT sequence FROM workspace_state WHERE id = 1), 'note', resource_id, revision, 'updated' FROM notes WHERE id = ?")
        ch.bind(1, id)
        _ = ch.step()

    def reload(mut self):
        """The notes again from the database (newest first, as the panel lists them), the open note kept."""
        try:
            self.load()
        except e:
            print("PNOTE ERROR: reload: " + String(e), flush=True)

    def hover(mut self, x: Float64, y: Float64) -> Bool:
        """The pointer moved; True when a hover state changes (only then the screen redraws)."""
        var before = self.boxes.hit_any(self.px, self.py, ["#toggle-sidebar", "#search-button"])
        self.px = x
        self.py = y
        return self.boxes.hit_any(x, y, ["#toggle-sidebar", "#search-button"]) != before

    def tap(mut self, x: Float64, y: Float64) -> Bool:
        """A tap at (x, y) layout px; True when it changed something."""
        var hit = self.boxes.hit_any(x, y, ["#toggle-sidebar", "#search-button", "row:", "[Crayon skin]", "[Paper skin]", "[Night skin]", ".sec-head", "#share-button"])
        if self.settings_open:
            var sh = self.boxes.hit_any(x, y, [".sw-skin:", "#close-properties"])
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
        var ni = self.note_index(self.current)
        if ni >= 0 and self.notes[ni].kind == "page" and not self.searching:
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
