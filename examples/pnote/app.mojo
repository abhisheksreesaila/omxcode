# pnote (goal 74 M6): Personal Note's three kinds of note, built only from native mojoui components. A page note is
# Markdown edited in place (mojoui.mdedit); a canvas note is free objects, arrows and pressure ink (mojoui.objectlayer,
# mojoui.ink); a mind map is mojoui.mindmap. Notes live in SQLite with an FTS5 index (mojoui.sqlite); Ctrl+K opens a
# palette over notes and commands. Nothing here draws text or shapes by itself: the note's Canvas hands its Painter to
# the component.
#
#   scripts/build.sh pnote linux && build/pnote/linux/pnote
#
# Contract for checks (docs/goals/74-check.py): PNOTE_DIR, PNOTE_IMPORT, PNOTE_PAGE_CHARS; the PNOTE: and PNOTE NOTE:
# lines; canvas keys v t s r p c, ctrl+a, ctrl+z; map keys Tab, Enter, Escape; ctrl+k → the "Go to" field.

from mojoui import (
    App, Event, View, Surface, VStack, HStack, Text, Button, Canvas, Spacer, Divider, TextField, Overlay,
    CAPTION, HEADLINE, CENTER, START, END, PAN, ZOOM, TAP, WHEEL, PRESS, RELEASE, DOUBLE, KEY, CTRL, SHIFT, PLAIN,
    PROMINENT, SUBTLE, TOOL, TOOL_ON, NO_MSG,
)
from mojoui.sidebar import Sidebar, SidebarHead, SidebarItem
from mojoui.canvas import rgba
from mojoui.scene import Scene, SurfacePainter, Painter
from mojoui.text import Font
from mojoui.sqlite import Database, fts_prefix_query
from mojoui.shared import environment, make_dir
from mojoui.files import config_dir
from mojoui.geometry import rect_of
from mojoui.theme import Theme
from mojoui.mdedit import MdEdit
from mojoui.textedit import now_ms
from themes.liquid import liquid

comptime NEW_PAGE = 1
comptime NEW_CANVAS = 2
comptime NEW_MAP = 3
comptime OPEN0 = 1000  # + the row in the list
comptime SEARCH = 4
comptime GESTURE = 5
comptime PALETTE_TYPE = 6
comptime PALETTE_GO = 7
comptime PALETTE_CANCEL = 8
comptime DELETE_NOTE = 9

comptime PAGE = 0
comptime CANVAS = 1
comptime MAP = 2

comptime PAPER: UInt32 = 0xFFFCFAF8


def kind_name(k: Int) -> String:
    return "page" if k == PAGE else ("canvas" if k == CANVAS else "map")


def kind_of(name: String) -> Int:
    return PAGE if name == "page" else (CANVAS if name == "canvas" else MAP)


def open_db(path: String) raises -> Database:
    var db = Database(path)
    db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL")
    db.exec("""CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL DEFAULT '',
          body TEXT NOT NULL DEFAULT '', updated INTEGER NOT NULL DEFAULT 0);
        CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(title, body, content='notes', content_rowid='id');
        CREATE TRIGGER IF NOT EXISTS notes_ai AFTER INSERT ON notes BEGIN
          INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END;
        CREATE TRIGGER IF NOT EXISTS notes_ad AFTER DELETE ON notes BEGIN
          INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body); END;
        CREATE TRIGGER IF NOT EXISTS notes_au AFTER UPDATE ON notes BEGIN
          INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
          INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END;""")
    return db^


def seeded_page(n: Int) -> String:
    """n characters of Markdown that read like notes (seeded, the same every time)."""
    var words: List[String] = ["the", "note", "canvas", "mojo", "fast", "native", "editor", "ink", "page", "map", "a", "of",
                               "**bold**", "*soft*", "`code`"]
    var out = String("# A long page\n")
    var s = UInt32(11)
    var para = 0
    while out.byte_length() < n:
        s ^= s << 13
        s ^= s >> 17
        s ^= s << 5
        out += words[Int(s % UInt32(len(words)))]
        if s % 17 == 0:
            para += 1
            out += "\n" + ("- " if para % 5 == 0 else ("## Part " + String(para) + "\n" if para % 23 == 0 else ""))
        else:
            out += " "
    return out^


struct Row(Copyable, Movable):
    var id: Int
    var kind: Int
    var title: String

    def __init__(out self, id: Int, kind: Int, title: String):
        self.id = id
        self.kind = kind
        self.title = title


struct Main(App):
    var db: Optional[Database]
    var problem: String
    var rows: List[Row]  # every note, newest first
    var shown: List[Int]  # rows shown in the list (the search's hits)
    var query: String
    var open_id: Int  # 0: none
    var open_kind: Int
    var page: MdEdit
    var font: Font
    var version: Int
    var palette: Bool
    var palette_text: String
    var said: String
    var box_w: Float64
    var box_h: Float64

    def __init__(out self):
        self.db = None
        self.problem = ""
        self.rows = List[Row]()
        self.shown = List[Int]()
        self.query = ""
        self.open_id = 0
        self.open_kind = PAGE
        self.page = MdEdit("", 16)
        self.font = Font()
        self.version = 0
        self.palette = False
        self.palette_text = ""
        self.said = ""
        self.box_w = 800
        self.box_h = 600
        var dir = environment("PNOTE_DIR", "")
        if dir == "":
            dir = config_dir("pnote")
        try:
            make_dir(dir)
            self.db = open_db(dir + "/notes.db")
            self.load()
            for ref r in self.rows:
                print("PNOTE NOTE: " + kind_name(r.kind) + " " + r.title + " " + self.stats_of(r.id), flush=True)
            var chars = 0
            try:
                chars = Int(environment("PNOTE_PAGE_CHARS", "0"))
            except:
                chars = 0
            if chars > 0:
                self.new_note(PAGE, seeded_page(chars))
            elif len(self.rows) > 0:
                self.open(self.rows[0].id)
        except e:
            self.problem = String(e)
            print("PNOTE ERROR: " + self.problem, flush=True)
        self.report()

    def title(self) -> String:
        return "Personal Note"

    def theme(self) -> Theme:
        return liquid()

    def window_size(self) -> Tuple[Int, Int]:
        return (1280, 820)

    # ------------------------------------------------ storage

    def load(mut self) raises:
        self.rows = List[Row]()
        var st = self.db.value().prepare("SELECT id, kind, title FROM notes ORDER BY updated DESC, id DESC")
        while st.step():
            self.rows.append(Row(st.int(0), kind_of(st.text(1)), st.text(2)))
        self.search()

    def search(mut self) raises:
        self.shown = List[Int]()
        if String(self.query.strip()) == "":
            for i in range(len(self.rows)):
                self.shown.append(i)
            return
        var st = self.db.value().prepare("SELECT rowid FROM notes_fts WHERE notes_fts MATCH ? ORDER BY rank")
        st.bind(1, fts_prefix_query(self.query))
        while st.step():
            var id = st.int(0)
            for i in range(len(self.rows)):
                if self.rows[i].id == id:
                    self.shown.append(i)

    def body_of(self, id: Int) raises -> String:
        var st = self.db.value().prepare("SELECT body FROM notes WHERE id = ?")
        st.bind(1, id)
        if st.step():
            return st.text(0)
        return ""

    def stats_of(self, id: Int) -> String:
        """chars= objects= connectors= strokes= nodes= of a stored note (what a relaunch shows)."""
        try:
            var body = self.body_of(id)
            var k = PAGE
            for ref r in self.rows:
                if r.id == id:
                    k = r.kind
            return self.stats(k, body)
        except:
            return "chars=0 objects=0 connectors=0 strokes=0 nodes=0"

    def stats(self, kind: Int, body: String) -> String:
        if kind == PAGE:
            return "chars=" + String(body.byte_length()) + " objects=0 connectors=0 strokes=0 nodes=0"
        return "chars=0 objects=0 connectors=0 strokes=0 nodes=0"

    def live_stats(self) -> String:
        """The open note's counts, read from its component (no serialising: a 1M-character page costs nothing here)."""
        if self.open_kind == PAGE:
            return "chars=" + String(self.page.ed.chars()) + " objects=0 connectors=0 strokes=0 nodes=0"
        return "chars=0 objects=0 connectors=0 strokes=0 nodes=0"

    def current_body(self) -> String:
        if self.open_kind == PAGE:
            return self.page.ed.text()
        return ""

    def current_title(self) -> String:
        if self.open_kind == PAGE:
            var first = String(self.page.ed.paras[0].strip()) if len(self.page.ed.paras) > 0 else ""
            while first.startswith("#"):
                var cut = String(first[byte=1:])
                first = cut
            var trimmed = String(first.strip())
            first = trimmed
            return first if first != "" else "Untitled page"
        return "Untitled"

    def save(mut self):
        if self.open_id == 0 or not self.db:
            return
        try:
            var st = self.db.value().prepare("UPDATE notes SET title = ?, body = ?, updated = ? WHERE id = ?")
            var title = self.current_title()
            st.bind(1, title)
            st.bind(2, self.current_body())
            st.bind(3, now_ms())
            st.bind(4, self.open_id)
            st.run()
            for ref r in self.rows:
                if r.id == self.open_id:
                    r.title = title
        except e:
            print("PNOTE ERROR: save: " + String(e), flush=True)

    def new_note(mut self, kind: Int, body: String = ""):
        self.save()
        try:
            var st = self.db.value().prepare("INSERT INTO notes(kind, title, body, updated) VALUES (?, ?, ?, ?)")
            st.bind(1, kind_name(kind))
            st.bind(2, "Untitled")
            st.bind(3, body)
            st.bind(4, now_ms())
            st.run()
            var id = self.db.value().count("SELECT max(id) FROM notes")
            self.load()
            self.open(id)
            self.save()
            self.load()
        except e:
            print("PNOTE ERROR: new: " + String(e), flush=True)

    def open(mut self, id: Int):
        if id != self.open_id:
            self.save()
        var kind = PAGE
        for ref r in self.rows:
            if r.id == id:
                kind = r.kind
        var body = String()
        try:
            body = self.body_of(id)
        except:
            body = ""
        self.open_id = id
        self.open_kind = kind
        if kind == PAGE:
            self.page = MdEdit(body, 16)
            self.page.ed.resize(self.box_w, self.box_h)
            var last = len(self.page.ed.paras) - 1
            self.page.ed.caret = self.page.ed.clamp(self.page.ed.caret)
            if body == "":
                self.page.ed.caret.para = 0
            else:
                self.page.ed.caret.para = last
                self.page.ed.caret.byte = self.page.ed.paras[last].byte_length()
            self.page.ed.anchor = self.page.ed.caret
        self.version += 1

    def closing(mut self):
        self.save()
        print("PNOTE QUIT: saved; " + String(len(self.rows)) + " notes", flush=True)

    # ------------------------------------------------ reporting

    def report(mut self):
        var title = self.current_title() if self.open_id != 0 else "-"
        for ref r in self.rows:  # (the list shows the open note's title as it's typed)
            if r.id == self.open_id:
                r.title = title
        var line = ("PNOTE: note=" + title.replace(" ", "_") + " kind=" + kind_name(self.open_kind) + " notes=" + String(len(self.rows))
                    + " shown=" + String(len(self.shown)) + " " + self.live_stats())
        if line != self.said:
            self.said = line
            print(line, flush=True)

    # ------------------------------------------------ events

    def gesture(mut self, e: Event):
        var kind = e.number
        var t = now_ms()
        if kind == KEY:
            var mods = Int(e.dx)
            if (e.text == "k" or e.text == "K") and (mods & CTRL) != 0:
                self.palette = True
                self.palette_text = ""
                return
            if self.open_kind == PAGE:
                _ = self.page.key(e.text, mods, t, self.font)
            self.version += 1
            return
        if self.open_kind == PAGE:
            if kind == PRESS or kind == TAP:
                _ = self.page.press(e.x, e.y, False, self.font)
            elif kind == PAN:
                self.page.ed.drag_to(e.x, e.y, self.font, self.page.st)
            elif kind == RELEASE:
                self.page.ed.release()
            elif kind == DOUBLE:
                self.page.ed.select_word(e.x, e.y, self.font, self.page.st)
            elif kind == WHEEL:
                self.page.ed.focused = False  # (a scroll moves the view, not the caret)
                self.page.ed.scroll_by(e.dy * -1.0, self.font, self.page.st)
            self.version += 1

    def palette_hits(self) -> List[Int]:
        """Rows whose title holds the palette's text (case-insensitive), in list order."""
        var out = List[Int]()
        var q = self.palette_text.lower()
        for i in range(len(self.rows)):
            if q == "" or self.rows[i].title.lower().find(q) >= 0:
                out.append(i)
        return out^

    def update(mut self, event: Event):
        var m = event.message
        if m == GESTURE:
            self.gesture(event)
        elif m == NEW_PAGE:
            self.new_note(PAGE)
        elif m == NEW_CANVAS:
            self.new_note(CANVAS)
        elif m == NEW_MAP:
            self.new_note(MAP)
        elif m == SEARCH:
            self.save()
            self.query = event.text
            try:
                self.search()
            except e:
                print("PNOTE ERROR: search: " + String(e), flush=True)
        elif m == PALETTE_TYPE:
            self.palette_text = event.text
        elif m == PALETTE_GO:
            self.palette_text = event.text
            var hits = self.palette_hits()
            self.palette = False
            if self.palette_text.lower().startswith("new page"):
                self.new_note(PAGE)
            elif self.palette_text.lower().startswith("new canvas"):
                self.new_note(CANVAS)
            elif self.palette_text.lower().startswith("new map"):
                self.new_note(MAP)
            elif len(hits) > 0:
                self.open(self.rows[hits[0]].id)
        elif m == PALETTE_CANCEL:
            self.palette = False
        elif m >= OPEN0 and m < OPEN0 + len(self.rows):
            self.open(self.rows[m - OPEN0].id)
        self.report()

    # ------------------------------------------------ view

    def view(self) -> View:
        var side = List[View]()
        side.append(SidebarHead("Notes", String(len(self.rows))))
        side.append(TextField(self.query, "Search notes", on_change=SEARCH).fill().tag("search"))
        side.append(HStack(Button("New page", NEW_PAGE, SUBTLE, "file-text"), Button("New canvas", NEW_CANVAS, SUBTLE, "square"),
                           Button("New map", NEW_MAP, SUBTLE, "git-branch"), spacing=2).fill())
        for i in self.shown:
            ref r = self.rows[i]
            var icon = "file-text" if r.kind == PAGE else ("square" if r.kind == CANVAS else "git-branch")
            side.append(SidebarItem(r.title, "", OPEN0 + i, r.id == self.open_id, icon))
        var bar = List[View]()
        bar.append(Text(self.current_title() if self.open_id != 0 else "No note", HEADLINE))
        bar.append(Spacer())
        bar.append(Text(kind_name(self.open_kind), CAPTION))
        var main = VStack(
            HStack(bar^, spacing=8).fill().align(CENTER).padding(8, 16).tag("notebar"),
            Canvas(0, self.version, on_gesture=GESTURE, keys=True, scroll_pans=True).grow().fill().tag("note"),
            spacing=0,
        ).grow().fill()
        var column = VStack(Sidebar(side^), Spacer(), spacing=0).width(280).fill().align(START).padding(8, 8).tag("side")
        var body = HStack(column^, main^, spacing=0).grow().fill()
        if self.palette:
            var hits = self.palette_hits()
            var items = List[View]()
            items.append(TextField(self.palette_text, "Go to", on_change=PALETTE_TYPE, on_submit=PALETTE_GO, on_cancel=PALETTE_CANCEL).focused().fill().tag("palette-field"))
            var n = 0
            for i in hits:
                if n >= 8:
                    break
                items.append(Button(self.rows[i].title, OPEN0 + i, SUBTLE).fill())
                n += 1
            items.append(Text("New page · New canvas · New map", CAPTION))
            return Overlay(body^, VStack(items^, spacing=4).padding(12, 12).tag("palette").pin(CENTER, START))
        return body^

    # ------------------------------------------------ drawing

    def paint[P: Painter](mut self, mut p: P, w: Float64, h: Float64):
        var k = p.scale()
        p.begin_layer("paper")
        p.fill(PAPER)
        p.begin_layer("note")
        p.layer_transform(0, 0, k)
        if self.open_id == 0:
            return
        if self.open_kind == PAGE:
            var col = min(w, 860.0)
            self.page.ed.resize(col, h)
            self.box_w = col
            self.box_h = h
            self.page.paint(p, self.font, (w - col) / 2, 0)

    def draw_scene(mut self, canvas: Int, mut scene: Scene) -> Bool:
        var k = scene.scale()
        self.paint(scene, Float64(scene.width()) / k, Float64(scene.height()) / k)
        return True

    def draw(mut self, canvas: Int, mut surface: Surface):
        var sp = SurfacePainter(Surface(surface.address, surface.width, surface.height, surface.scale))
        self.paint(sp, Float64(surface.width) / surface.scale, Float64(surface.height) / surface.scale)
