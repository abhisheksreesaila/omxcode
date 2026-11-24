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
    CAPTION, HEADLINE, CENTER, START, END, PAN, ZOOM, TAP, HOVER, IME_COMMIT, IME_PREEDIT, PASTE, WHEEL, PRESS, RELEASE, DOUBLE, KEY, CTRL, SHIFT, PLAIN,
    PROMINENT, SUBTLE, TOOL, TOOL_ON, NO_MSG,
)
from mojoui.sidebar import Sidebar, SidebarHead, SidebarItem
from mojoui.overlays import Clipboard
from mojoui.canvas import rgba
from mojoui.effects import Every
from mojoui.scene import Scene, SurfacePainter, Painter
from mojoui.text import Font
from mojoui.sqlite import Database, fts_prefix_query
from mojoui.shared import environment, make_dir
from mojoui.files import config_dir
from mojoui.geometry import rect_of
from mojoui.theme import Theme
from mojoui.mdedit import MdEdit
from mojoui.textedit import now_ms
from mojoui.objectlayer import ObjectLayer, import_fabric, import_json_canvas, TEXT, STICKY, RECT, INK, CONNECTOR, H_ROTATE
from mojoui.mindmap import MindMap, MapCamera
from mojoui.ink import Stroke
from mojoui.maths import cos, sin
from mojoui.gpu2d_backend import backend_name, turn_off_gpu2d
from themes.liquid import liquid
from webshell import WebShell
from pnstore import default_notes_file
from mojoui.files import read_setting
from mojoui.fonttext_check import fontcheck
from mojoui.glyphwarm import WARM_TICK_MS

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
comptime WARM_TICK = 11  # (D-8002: glyphs readied while nothing happens)
comptime FEED_TICK = 12  # the notes file looked at for what another app did
comptime FEED_TICK_MS = 2000
comptime SAVE_TICK = 10  # the web look's save debounce (mojoui.docstore.SaveTimer)

comptime PAGE = 0
comptime CANVAS = 1
comptime MAP = 2

comptime PAPER: UInt32 = 0xFFFCFAF8

# canvas tools
comptime T_SELECT = 0
comptime T_TEXT = 1
comptime T_STICKY = 2
comptime T_RECT = 3
comptime T_PEN = 4
comptime T_HAND = 5
# what a drag on the canvas does
comptime D_NONE = 0
comptime D_MOVE = 1
comptime D_HANDLE = 2
comptime D_MARQUEE = 3
comptime D_PAN = 4
comptime D_INK = 5


def tool_name(t: Int) -> String:
    var names: List[String] = ["select", "text", "sticky", "rect", "pen", "hand"]
    return names[t]


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


def whiteboard_layer(n: Int) -> ObjectLayer:
    """The judged whiteboard (goal 75): n pressure strokes of 101 points each, wandering lines seeded like goal 40's Sketch
    bench, across about two screens of page."""
    var l = ObjectLayer()
    var s = UInt32(40)
    var colours: List[UInt32] = [rgba(28, 30, 38), rgba(37, 99, 235), rgba(220, 38, 38)]
    for k in range(n):
        var r = List[Float64]()
        for _ in range(4):
            s ^= s << 13
            s ^= s >> 17
            s ^= s << 5
            r.append(Float64(s >> 8) / 16777216.0)
        var st = Stroke(3.5, colours[k % 3])
        var x = 40.0 + r[0] * 2400.0
        var y = 40.0 + r[1] * 1500.0
        var a = r[2] * 6.283
        for i in range(101):
            st.add(x, y, 0.25 + 0.7 * Float64(i if i < 50 else 100 - i) / 50.0)
            a += (r[3] - 0.5) * 0.04 + 0.05 * sin(Float64(i) * 0.15)
            x += 1.6 * cos(a)
            y += 1.6 * sin(a)
        st.seal()
        _ = l.add_ink(st)
    l.history.clear()
    return l^


def scene_map(n: Int) -> MindMap:
    """The judged mind map (goal 75): n topics, eight main branches, seeded words."""
    var words: List[String] = ["Plan", "Ideas", "Budget", "Garden", "Trip", "Reading", "Health", "Work", "milk", "eggs",
                               "flights", "hotel", "notes", "draft", "review", "launch", "seeds", "soil", "run", "sleep"]
    var m = MindMap("Life plan")
    var ids = List[Int]()
    ids.append(0)
    var s = UInt32(9)
    for k in range(n - 1):
        s ^= s << 13
        s ^= s >> 17
        s ^= s << 5
        var parent = 0 if k < 8 else ids[1 + Int(s % UInt32(len(ids) - 1))]
        var text = words[Int((s >> 5) % UInt32(len(words)))] + (" " + words[Int((s >> 11) % UInt32(len(words)))] if s % 3 == 0 else "")
        ids.append(m.add_child(parent, text, 0))
    m.balance(0)  # (main branches spread evenly left and right, D-7523)
    m.settle()
    m.clear_history()
    return m^


def layer_stats(l: ObjectLayer) -> String:
    var ink = l.count_kind(INK)
    var conn = l.count_kind(CONNECTOR)
    return ("chars=0 objects=" + String(l.count() - ink - conn) + " connectors=" + String(conn) + " strokes=" + String(ink)
            + " nodes=0")


struct Row(Copyable, Movable):
    var id: Int
    var kind: Int
    var title: String

    def __init__(out self, id: Int, kind: Int, title: String):
        self.id = id
        self.kind = kind
        self.title = title


struct Main(App):
    comptime GPU_2D = True  # (a note's canvas asks for the GPU 2D renderer when a canvas note opens, on any screen, D-7562)
    var db: Optional[Database]
    var problem: String
    var gpu: Bool  # the note's canvas asks for the GPU 2D renderer (Canvas(…).gpu()); PNOTE_GPU=0: GSK nodes (the baseline)
    var gpu_told: Bool  # the `PNOTE GPU:` line is out (the first draw: by then the host knows which renderer it has)
    var rows: List[Row]  # every note, newest first
    var shown: List[Int]  # rows shown in the list (the search's hits)
    var query: String
    var open_id: Int  # 0: none
    var open_kind: Int
    var page: MdEdit
    var layer: ObjectLayer
    var map: MindMap
    var tool: Int
    var drag: Int
    var handle: Int
    var made_on_press: Bool
    var wet: Stroke
    var cam_x: Float64  # the canvas's view: the page point at the top-left, and the zoom
    var cam_y: Float64
    var zoom: Float64
    var mx0: Float64  # a marquee's corners (page points)
    var my0: Float64
    var mx1: Float64
    var my1: Float64
    var map_cam: MapCamera  # where the map is looked at (pan, zoom around the pointer: mojoui.mindmap's camera)
    var scale: Float64  # the canvas's pixels per point (the last paint's)
    var font: Font
    var version: Int
    var palette: Bool
    var palette_text: String
    var said: String
    var box_w: Float64
    var box_h: Float64
    var web: List[WebShell]  # goal 79: the web app's look on Personal Note's own database (PNOTE_DB); empty: goal 74's look
    var boxes_path: String

    def __init__(out self):
        self.db = None
        self.problem = ""
        self.gpu = environment("PNOTE_GPU", "1") != "0"
        if not self.gpu:
            turn_off_gpu2d()  # (the baseline: GTK's own renderer, though Main declares GPU_2D)
        self.gpu_told = False
        self.rows = List[Row]()
        self.shown = List[Int]()
        self.query = ""
        self.open_id = 0
        self.open_kind = PAGE
        self.page = MdEdit("", 16)
        self.layer = ObjectLayer()
        self.map = MindMap("Central topic")
        self.tool = T_SELECT
        self.drag = D_NONE
        self.handle = -1
        self.made_on_press = False
        self.wet = Stroke(3, 0xFF262222)
        self.cam_x = 0
        self.cam_y = 0
        self.zoom = 1
        self.mx0 = 0
        self.my0 = 0
        self.mx1 = 0
        self.my1 = 0
        self.map_cam = MapCamera()
        self.scale = 1
        self.font = Font()
        self.version = 0
        self.palette = False
        self.palette_text = ""
        self.said = ""
        self.box_w = 800
        self.box_h = 600
        self.web = List[WebShell]()
        self.boxes_path = environment("PNOTE_BOXES", "")
        if environment("PNOTE_FONTCHECK", "") != "":  # (goal 79 M1 on the Mac: test_fonttext's lines from the app itself)
            try:
                _ = fontcheck(environment("FONTTEXT_REF", ""), environment("FONTTEXT_FIXTURE", ""), Float64(environment("FONTTEXT_DPR", "2")))
            except e:
                print("fonttext: FAIL " + String(e), flush=True)
        var pn_db = environment("PNOTE_DB", "")
        if pn_db == "" and environment("PNOTE_DIR", "") + environment("PNOTE_SCENE", "") + environment("PNOTE_IMPORT", "") + environment("PNOTE_PAGE_CHARS", "") == "":
            pn_db = default_notes_file()  # (a person starting the app: this look, notes of its own)
        if pn_db != "":
            # (D-7907) the web look runs on a Personal Note database; goal 74/75's contract (PNOTE_DIR, its own store, the
            # judged scenes) keeps goal 74's look so their checks still prove the editors and the GPU path
            self.web.append(WebShell(pn_db, read_setting("pnote", "skin", environment("PNOTE_SKIN", "paper"))))
            if len(self.web[0].notes) > 0:
                var first = environment("PNOTE_FIRST", "")  # (the race: start on another note, D-7951)
                var start_id = self.web[0].notes[0].id
                try:
                    if first != "" and self.web[0].note_index(Int(first)) >= 0:
                        start_id = Int(first)
                except:
                    pass
                self.web[0].open(start_id)
            elif self.web[0].problem == "":
                self.web[0].create("canvas")  # (no note yet: one to start on, as the web makes)
            print("PNOTE WEB: " + String(len(self.web[0].notes)) + " notes from " + pn_db, flush=True)
            return
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
            var imp = environment("PNOTE_IMPORT", "")
            var scene = environment("PNOTE_SCENE", "")
            if not self.gpu:
                print("PNOTE GPU: cpu (PNOTE_GPU=0)", flush=True)
                self.gpu_told = True
            if scene == "whiteboard":
                var l = whiteboard_layer(1000)
                self.new_note(CANVAS, l.save_text())
                self.tool = T_PEN
            elif scene == "mindmap":
                self.new_note(MAP, scene_map(300).to_text())
            elif scene == "canvas" and imp != "":
                var f = open(imp, "r")
                var json = f.read()
                f.close()
                var l = import_json_canvas(json) if json.find('"nodes"') >= 0 and json.find('"objects"') < 0 else import_fabric(json, self.font)
                self.new_note(CANVAS, l.save_text())
                self.tool = T_HAND
            elif imp != "":
                var f = open(imp, "r")
                var json = f.read()
                f.close()
                var l = import_fabric(json, self.font)
                self.new_note(CANVAS, l.save_text())
                self.tool = T_HAND
            elif chars > 0:
                var page_text = seeded_page(chars)
                var t_open = now_ms()
                self.new_note(PAGE, page_text)
                print("PNOTE OPEN: ms=" + String(now_ms() - t_open) + " chars=" + String(self.page.ed.chars()) + " (stored in SQLite and opened in the editor)", flush=True)
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

    def hovers(self) -> Bool:
        return len(self.web) > 0

    def caret(self, canvas: Int) -> Tuple[Float64, Float64, Float64, Float64]:
        if len(self.web) > 0:
            return self.web[0].caret()
        return (-1.0, 0.0, 0.0, 0.0)

    def window_size(self) -> Tuple[Int, Int]:
        if len(self.web) > 0:
            return (1440, 900)
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
        if kind == CANVAS:
            var l = ObjectLayer()
            try:
                if body != "":
                    l.load_text(body)
            except:
                pass
            return layer_stats(l)
        var m = MindMap("Central topic")
        if body != "":
            m.from_text(body)
        return "chars=0 objects=0 connectors=0 strokes=0 nodes=" + String(m.nodes())

    def live_stats(self) -> String:
        """The open note's counts, read from its component (no serialising: a 1M-character page costs nothing here)."""
        if self.open_kind == PAGE:
            return "chars=" + String(self.page.ed.chars()) + " objects=0 connectors=0 strokes=0 nodes=0"
        if self.open_kind == CANVAS:
            return layer_stats(self.layer)
        return "chars=0 objects=0 connectors=0 strokes=0 nodes=" + String(self.map.nodes())

    def current_body(self) -> String:
        if self.open_kind == PAGE:
            return self.page.ed.text()
        if self.open_kind == CANVAS:
            return self.layer.save_text()
        return self.map.to_text()

    def current_title(self) -> String:
        if self.open_kind == PAGE:
            var first = String(self.page.ed.paras[0].strip()) if len(self.page.ed.paras) > 0 else ""
            while first.startswith("#"):
                var cut = String(first[byte=1:])
                first = cut
            var trimmed = String(first.strip())
            first = trimmed
            return first if first != "" else "Untitled page"
        if self.open_kind == CANVAS:
            for i in range(self.layer.count()):
                ref o = self.layer.objs[i]
                if (o.kind == TEXT or o.kind == STICKY) and String(o.text.strip()) != "":
                    var nl = o.text.find("\n")
                    return String(o.text[byte=:nl]) if nl > 0 else o.text
            return "Untitled canvas"
        return self.map.text_of(0) if self.map.nodes() > 0 else "Untitled map"

    def save(mut self):
        if self.open_id == 0 or not self.db:
            return
        if self.open_kind == CANVAS and not self.layer.unsaved():
            return  # (D-7926: a canvas unchanged since it was read or written isn't written again)
        try:
            var st = self.db.value().prepare("UPDATE notes SET title = ?, body = ?, updated = ? WHERE id = ?")
            var title = self.current_title()
            st.bind(1, title)
            st.bind(2, self.current_body())
            st.bind(3, now_ms())
            st.bind(4, self.open_id)
            st.run()
            if self.open_kind == CANVAS:
                self.layer.mark_saved()
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
        elif kind == CANVAS:
            self.layer = ObjectLayer()
            try:
                if body != "":
                    self.layer.load_text(body)
            except e:
                print("PNOTE ERROR: canvas: " + String(e), flush=True)
            self.cam_x = 0
            self.cam_y = 0
            self.zoom = 1
            self.tool = T_SELECT
        else:
            self.map = MindMap("Central topic")
            if body != "":
                self.map.from_text(body)
            self.map_cam.reset()
        self.version += 1

    def every(self) -> List[Every]:
        if len(self.web) > 0 and self.web[0].waiting():
            return [Every(self.web[0].saver.tick_ms() if self.web[0].saver.pending() else 500, SAVE_TICK)]
        if len(self.web) > 0 and self.web[0].readying():
            return [Every(WARM_TICK_MS, WARM_TICK)]
        if len(self.web) > 0:
            return [Every(FEED_TICK_MS, FEED_TICK)]
        return List[Every]()

    def draws_after_closing(self) -> Bool:
        return len(self.web) > 0

    def closing(mut self):
        if len(self.web) > 0:
            self.web[0].close()
            _ = self.web[0].warm.save()
            print("PNOTE QUIT: saved", flush=True)
            return
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
            elif self.open_kind == CANVAS:
                self.canvas_key(e.text, mods, t)
            else:
                _ = self.map.key(e.text, mods, t, self.font)
            self.version += 1
            return
        if self.open_kind == CANVAS:
            self.canvas_gesture(e, t)
            self.version += 1
            return
        if self.open_kind == MAP:
            if kind == TAP:
                _ = self.map.tap(e.x * self.scale, e.y * self.scale, t, self.font)
            else:
                _ = self.map_cam.gesture(e)  # (PAN, WHEEL, ZOOM around the pointer)
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

    def page_xy(self, x: Float64, y: Float64) -> Tuple[Float64, Float64]:
        return (self.cam_x + x / self.zoom, self.cam_y + y / self.zoom)

    def make_at(mut self, x: Float64, y: Float64):
        """The text, sticky or rectangle tool's object, centred at (x, y) on screen; a text or sticky starts editing."""
        var p = self.page_xy(x, y)
        var id = -1
        if self.tool == T_TEXT:
            id = self.layer.add_text(p[0] - 110, p[1] - 22, 220, 44, "", 18)
        elif self.tool == T_STICKY:
            id = self.layer.add_sticky(p[0] - 80, p[1] - 80, 160, "")
        elif self.tool == T_RECT:
            id = self.layer.add_rect(p[0] - 90, p[1] - 55, 180, 110, rgba(37, 99, 235, 38), rgba(37, 99, 235), 2, 8)
        if id >= 0:
            self.layer.select(id)
            if self.tool != T_RECT:
                _ = self.layer.begin_text_edit(id)
        self.tool = T_SELECT

    def canvas_key(mut self, name: String, mods: Int, t: Int):
        if self.layer.editing >= 0:
            if name == "Escape":
                self.layer.end_text_edit()
            else:
                _ = self.layer.text_key(name, mods, t, self.font)
            return
        var ctrl = (mods & CTRL) != 0
        var shift = (mods & SHIFT) != 0
        if ctrl:
            if name == "z" or name == "Z":
                if shift or name == "Z":
                    _ = self.layer.redo()
                else:
                    _ = self.layer.undo()
            elif name == "a" or name == "A":
                self.layer.select_all()
            elif name == "d":
                self.layer.duplicate_selection()
            return
        if name == "v":
            self.tool = T_SELECT
        elif name == "t":
            self.tool = T_TEXT
        elif name == "s":
            self.tool = T_STICKY
        elif name == "r":
            self.tool = T_RECT
        elif name == "p":
            self.tool = T_PEN
        elif name == "h":
            self.tool = T_HAND
        elif name == "c":  # (connect the two picked objects that aren't ink or arrows, in the order they were picked)
            var ends = List[Int]()
            for id in self.layer.selected:
                var k = self.layer.get(id).kind
                if k != INK and k != CONNECTOR:
                    ends.append(id)
            if len(ends) == 2:
                _ = self.layer.add_connector(ends[0], ends[1])
        elif name == "Delete" or name == "Backspace":
            self.layer.delete_selection()
        elif name == "Escape":
            self.layer.clear_selection()
        elif name == "ArrowLeft":
            self.layer.nudge(-1, 0, shift)
        elif name == "ArrowRight":
            self.layer.nudge(1, 0, shift)
        elif name == "ArrowUp":
            self.layer.nudge(0, -1, shift)
        elif name == "ArrowDown":
            self.layer.nudge(0, 1, shift)
        elif name == "]":
            self.layer.bring_to_front()
        elif name == "[":
            self.layer.send_to_back()
        elif name == "Enter" and len(self.layer.selected) == 1:
            _ = self.layer.begin_text_edit(self.layer.selected[0])

    def canvas_gesture(mut self, e: Event, t: Int):
        var kind = e.number
        if kind == ZOOM:
            var z = min(max(self.zoom * e.zoom, 0.1), 8.0)
            var before = self.page_xy(e.x, e.y)
            self.zoom = z
            self.cam_x = before[0] - e.x / z
            self.cam_y = before[1] - e.y / z
            return
        if kind == WHEEL:
            self.cam_x -= e.dx / self.zoom
            self.cam_y -= e.dy / self.zoom
            return
        var p = self.page_xy(e.x, e.y)
        if kind == PRESS:
            self.made_on_press = False
            if self.layer.editing >= 0:
                self.layer.end_text_edit()
            if self.tool == T_TEXT or self.tool == T_STICKY or self.tool == T_RECT:
                self.make_at(e.x, e.y)
                self.made_on_press = True
                self.drag = D_NONE
            elif self.tool == T_PEN:
                self.wet = Stroke(3, rgba(38, 34, 34))
                self.wet.add(p[0], p[1], e.pressure)
                self.drag = D_INK
            elif self.tool == T_HAND:
                self.drag = D_PAN
            else:
                var h = self.layer.handle_at(p[0], p[1], self.zoom)
                if h >= 0:
                    self.handle = h
                    self.layer.begin_gesture()
                    self.drag = D_HANDLE
                else:
                    var id = self.layer.hit_test(p[0], p[1], 4 / self.zoom)
                    if id >= 0:
                        if not self.layer.is_selected(id):
                            self.layer.select(id, False)
                        self.layer.begin_gesture()
                        self.drag = D_MOVE
                    else:
                        self.layer.clear_selection()
                        self.mx0 = p[0]
                        self.my0 = p[1]
                        self.mx1 = p[0]
                        self.my1 = p[1]
                        self.drag = D_MARQUEE
            return
        if kind == PAN:
            if self.drag == D_PAN:
                self.cam_x -= e.dx / self.zoom
                self.cam_y -= e.dy / self.zoom
            elif self.drag == D_INK:
                self.wet.add(p[0], p[1], e.pressure)
            elif self.drag == D_MOVE:
                self.layer.move_by(e.dx / self.zoom, e.dy / self.zoom)
            elif self.drag == D_HANDLE:
                if self.handle == H_ROTATE:
                    self.layer.rotate_towards(p[0], p[1])
                else:
                    self.layer.resize_handle(self.handle, p[0], p[1])
            elif self.drag == D_MARQUEE:
                self.mx1 = p[0]
                self.my1 = p[1]
            return
        if kind == RELEASE:
            if self.drag == D_INK and self.wet.points() > 0:
                self.wet.seal()
                _ = self.layer.add_ink(self.wet)
            elif self.drag == D_MOVE or self.drag == D_HANDLE:
                self.layer.end_gesture()
            elif self.drag == D_MARQUEE:
                self.layer.marquee(min(self.mx0, self.mx1), min(self.my0, self.my1), max(self.mx0, self.mx1), max(self.my0, self.my1))
            self.drag = D_NONE
            return
        if kind == TAP:
            if self.made_on_press:
                self.made_on_press = False
                return
            if self.tool == T_TEXT or self.tool == T_STICKY or self.tool == T_RECT:
                self.make_at(e.x, e.y)
            elif self.tool == T_SELECT:
                if self.layer.editing >= 0:
                    self.layer.end_text_edit()
                _ = self.layer.click(p[0], p[1], False)
            return
        if kind == DOUBLE:
            var id = self.layer.hit_test(p[0], p[1], 4 / self.zoom)
            if id >= 0:
                _ = self.layer.begin_text_edit(id)

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
        if len(self.web) > 0:
            if m == SAVE_TICK:
                if self.web[0].tick():
                    self.version += 1
                return
            if m == FEED_TICK:  # (another app on the same notes file)
                if self.web[0].refresh():
                    self.version += 1
                return
            if m == WARM_TICK:
                self.web[0].ready_step()
                return
            self.web[0].warm.touch()
            if m == GESTURE and event.number == HOVER:
                if self.web[0].hover(event.x, event.y):
                    self.version += 1
                return
            if m == GESTURE and event.number == KEY:
                if self.web[0].key(event.text, Int(event.dx)):
                    self.version += 1
                return
            if m == GESTURE and (event.number == IME_COMMIT or event.number == PASTE):
                if self.web[0].text_in("paste" if event.number == PASTE else "ime", event.text):
                    self.version += 1
                return
            if m == GESTURE and event.number == IME_PREEDIT:
                if self.web[0].preedit(event.text, event.x, event.y, event.dx, event.dy):
                    self.version += 1
                return
            if m == GESTURE and event.number == TAP:
                if self.web[0].tap(event.x, event.y, Int(event.dx)):
                    self.version += 1
            elif m == GESTURE and event.number == DOUBLE:
                if self.web[0].double(event.x, event.y):
                    self.version += 1
            elif m == GESTURE and event.number == PRESS:
                if self.web[0].press(event.x, event.y):
                    self.version += 1
            elif m == GESTURE and event.number == PAN:
                if self.web[0].pan(event.x, event.y):
                    self.version += 1
            elif m == GESTURE and event.number == RELEASE:
                if self.web[0].release(event.x, event.y):
                    self.version += 1
            elif m == GESTURE and event.number == WHEEL:
                if self.web[0].wheel(event.x, event.y, event.dx, event.dy):
                    self.version += 1
            elif m == GESTURE and event.number == ZOOM:
                if self.web[0].zoom(event.x, event.y, event.zoom):
                    self.version += 1
            return
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

    def bench(mut self, canvas: Int, name: String) -> Tuple[Float64, Float64]:
        """Benchmark hooks (goal 79's race, the GTK framebench): where to drag one object or 40 (selected here), a history
        for undoredo, and a fresh open of the note for open. Points on the note's canvas. The web look: switch (the
        next note), omnibar (open/close), openall (a note of each kind in turn)."""
        if len(self.web) > 0:
            self.version += 1
            self.web[0].warm.touch()
            return self.web[0].bench(name)
        if self.open_kind != CANVAS:
            return (-1.0, -1.0)
        if name == "bench:pan" or name == "bench:zoom":
            self.tool = T_HAND
            return (-1.0, -1.0)
        if name == "bench:draw" or name == "bench:finish":
            self.layer.clear_selection()
            self.tool = T_PEN
            return (-1.0, -1.0)
        if name == "bench:type":  # (a text box being edited in the middle of the view, as the web's typing step types into one)
            self.tool = T_TEXT
            self.make_at(self.box_w / 2, self.box_h / 2)
            return (-1.0, -1.0)
        if name == "bench:reopen":
            var id = self.open_id
            self.save()
            self.open(id)
            self.version += 1
            return (-1.0, -1.0)
        self.tool = T_SELECT
        # objects inside the view, away from its edges (benchmark-f034's visibleObjects rule)
        var w = self.box_w
        var h = self.box_h
        var ids = List[Int]()
        var cx = List[Float64]()
        var cy = List[Float64]()
        for ref o in self.layer.objs:
            if o.kind == INK or o.kind == CONNECTOR or o.locked:
                continue
            var sx = (o.x - self.cam_x) * self.zoom
            var sy = (o.y - self.cam_y) * self.zoom
            var sw = o.w * self.zoom
            var sh = o.h * self.zoom
            if sx > 40 and sy > 40 and sx + sw < w - 80 and sy + sh < h - 80 and sw > 12 and sh > 12:
                ids.append(o.id)
                cx.append(sx + sw / 2)
                cy.append(sy + sh / 2)
        if len(ids) == 0:
            return (-1.0, -1.0)
        if name == "bench:dragone" or name == "bench:undoredo":
            var k = len(ids) // 2
            self.layer.select(ids[k], False)
            if name == "bench:undoredo":  # (thirty separate moves to walk back and forth)
                for m in range(min(30, len(ids))):
                    self.layer.select(ids[m], False)
                    self.layer.move_by(6, 4)
                return (-1.0, -1.0)
            return (cx[k], cy[k])
        if name == "bench:drag40":
            self.layer.clear_selection()
            for m in range(min(40, len(ids))):
                self.layer.select(ids[m], True)
            return (cx[0], cy[0])
        return (-1.0, -1.0)

    def view(self) -> View:
        if len(self.web) > 0:
            var desk = Canvas(0, self.version, on_gesture=GESTURE, keys=True, scroll_pans=True).gpu().grow().fill().tag("desk")
            if self.web[0].clip_version > 0:  # (something was copied: the hosts put it on the system clipboard)
                return HStack(desk^, Clipboard(self.web[0].clip, self.web[0].clip_version), spacing=0).grow().fill()
            return desk^
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
        if self.open_kind == CANVAS:
            bar.append(Text(tool_name(self.tool) + " · " + String(Int(self.zoom * 100 + 0.5)) + "%", CAPTION))
        bar.append(Text(kind_name(self.open_kind), CAPTION))
        var main = VStack(
            HStack(bar^, spacing=8).fill().align(CENTER).padding(8, 16).tag("notebar"),
            self.note_canvas(),
            spacing=0,
        ).grow().fill()
        var column = VStack(Sidebar(side^), Spacer(), spacing=0).width(280).fill().align(START).padding(8, 8).tag("side")
        var body = HStack(column^, main^, Clipboard(self.page.ed.clip, self.page.ed.clip_version), spacing=0).grow().fill()
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

    def note_canvas(self) -> View:
        var c = Canvas(0, self.version, on_gesture=GESTURE, keys=True, scroll_pans=True)
        if self.gpu:
            c = c^.gpu()
        return c^.grow().fill().tag("note")

    def tell_gpu(mut self):
        """`PNOTE GPU: <backend> …` once, at the first draw (the host has chosen its renderer by then)."""
        if self.gpu_told:
            return
        self.gpu_told = True
        var name = backend_name()
        print("PNOTE GPU: " + (name if name != "" else String("cpu (this host has no GPU 2D renderer)")), flush=True)

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
        elif self.open_kind == CANVAS:
            self.scale = k
            self.layer.paint(p, self.font, self.cam_x, self.cam_y, w / self.zoom, h / self.zoom, self.zoom * k)
            p.begin_layer("wet")
            p.layer_transform(-self.cam_x * self.zoom * k, -self.cam_y * self.zoom * k, self.zoom * k)
            if self.drag == D_INK and self.wet.points() > 0:
                p.polygon(self.wet.outline(), self.wet.color)
            if self.drag == D_MARQUEE:
                var x0 = min(self.mx0, self.mx1)
                var y0 = min(self.my0, self.my1)
                p.rect(x0, y0, abs(self.mx1 - self.mx0), abs(self.my1 - self.my0), rgba(37, 99, 235, 30), 2)
        else:
            self.scale = k
            self.map.paint(p, self.font, self.map_cam.view(w, h, k))

    def write_boxes(self):
        if self.boxes_path == "" or len(self.web) == 0:
            return
        try:
            with open(self.boxes_path, "w") as f:
                f.write(self.web[0].boxes.json())
        except:
            pass

    def draw_scene(mut self, canvas: Int, mut scene: Scene) -> Bool:
        self.tell_gpu()
        var k = scene.scale()
        if len(self.web) > 0:
            self.web[0].paint(scene, Float64(scene.width()) / k, Float64(scene.height()) / k, k)
            self.write_boxes()
            return True
        self.paint(scene, Float64(scene.width()) / k, Float64(scene.height()) / k)
        return True

    def draw(mut self, canvas: Int, mut surface: Surface):
        self.tell_gpu()
        var sp = SurfacePainter(Surface(surface.address, surface.width, surface.height, surface.scale))
        if len(self.web) > 0:
            self.web[0].paint(sp, Float64(surface.width) / surface.scale, Float64(surface.height) / surface.scale, surface.scale)
            self.write_boxes()
            return
        self.paint(sp, Float64(surface.width) / surface.scale, Float64(surface.height) / surface.scale)
