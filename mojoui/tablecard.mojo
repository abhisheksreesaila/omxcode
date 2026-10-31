# mojoui.tablecard: tables as cards on a page (goal 39 M7). A generic component: omxplorer puts a second table (a file
# opened beside the first, a query's answer) on its sheet's Board beside its own table, charts and video cards; any app with
# a Board can. Each card has the sheet objects' chrome: a title bar (the table's name, its size, Export CSV, close; drag it
# to move the card) over a DataGrid (scroll, select, fit a column) of its own. Each card owns a block of messages and one
# canvas, allocated when it is added.
#
#   var tables = TableCards(msg_base=4100, canvas_base=230, most=8)  # messages 4100 … 4100 + 8·TABLE_MESSAGES, canvases 230 … 237
#   var k = tables.add("shipments", sheet^, x, y, w, h, font, pal)   # raises when the page is full
#   update():   if tables.update(event, font, pal, folder): …        # True when the event was a card's: tables.export_asked / .closed / .selected / .acted say what
#   tables.adopt(card^, x, y, w, h)                                  # a card made off the UI thread (mojoui.tablejobs: a file, a query's answer)
#   Export CSV asks (tables.export_asked = k, tables.export_path): the app writes it with mojoui.tablejobs.TableWork.export
#   tables.cards[k].act_with("Flight plan", "route", "flight-plan", "…")  # one quiet action in its title bar (tables.acted = k when tapped)
#   view():     tables.view(k, version).at(c.x, c.y).width(c.w).height(c.h)
#   draw():     if tables.draws(canvas): tables.draw(canvas, surface, font, palette)
#   describe(): tables.describe(canvas, first, count)                # its rows as tab-separated text, for an agent
#
# SQL over the page: every table is a source by its SQL name (sql_name: "warehouse.mp4 · detections" → detections), so
#   var catalog = Catalog(); tables.add_to(catalog); var answer = query_table(catalog, "SELECT … FROM shipments WHERE …")
# runs on omxcore's SQL (joins, subqueries, IN / NOT IN, CTEs) and the answer can be a card of its own.

from mojoui.app import Event
from mojoui.canvas import Surface
from mojoui.charts import grouped
from mojoui.datagrid import DataGrid, GRID_SELECTED, GRID_HEADER_DRAG, GRID_HEADER_DROP
from mojoui.sheet import Sheet, TEXT
from mojoui.text import Font
from mojoui.theme import Palette
from mojoui.view import View, Text, Button, Canvas, HStack, Spacer, Card, HEADLINE, CAPTION, ICON_ONLY, SUBTLE, CENTER, TONE_ACCENT
from omxcore import Catalog, Table, sql
from mojoui.sqlname import sql_name  # (kept importable from here; links.mojo needs it without omxcore)

comptime TABLE_MESSAGES = 4  # a card's block: its grid's gestures (0), Export CSV (1), close (2), its action (3)
comptime TC_GRID = 0
comptime TC_EXPORT = 1
comptime TC_CLOSE = 2
comptime TC_ACTION = 3
comptime TABLE_HEAD_H = 36  # the title bar (the drag handle), as sheet objects have it
comptime GRID_LEFT = 16  # where a card's grid starts inside it (the card's padding; the title bar and its gap above)
comptime GRID_TOP = 16 + TABLE_HEAD_H + 4


def query_table(mut catalog: Catalog, text: String) raises -> Table:
    """The answer of a SQL query over the catalog's tables, as a table (raises with the engine's message, which names the
    place in the text: "SQL error at line 1, column 21: …")."""
    var r = sql(catalog, text)
    return r.take_table()


struct TableCard(Movable):
    """One card: its name, its table and grid, where it sits, its slot, and a line saying where it came from."""

    var name: String
    var sheet: Sheet
    var grid: DataGrid
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var slot: Int
    var note: String  # where it came from ("from shipments.csv", "a query"), shown under the title ("": none)
    var action: String  # one quiet action in its title bar ("": none): its label, icon, tag (an agent's tool) and tooltip
    var action_icon: String
    var action_tag: String
    var action_tip: String

    def __init__(out self, name: String, var sheet: Sheet, slot: Int, x: Int, y: Int, w: Int, h: Int, font: Font, pal: Palette):
        self.name = name
        self.sheet = sheet^
        self.grid = DataGrid()
        self.grid.drag_headers = True  # (a header dragged out is a column carried to another card: mojoui.linkdrag)
        self.grid.prepare(self.sheet, font, pal)
        var small = self.sheet.rows() <= 5000  # (a small table's numbers read whole too: 52.0101265, not 52.010…)
        for c in range(self.sheet.stored()):  # (words read whole: a text column is as wide as its longest)
            if self.sheet.kind(c) == TEXT or small:
                self.grid.fit(c, self.sheet, font, pal)
        self.slot = slot
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.note = ""
        self.action = ""
        self.action_icon = ""
        self.action_tag = ""
        self.action_tip = ""

    def act_with(mut self, label: String, icon: String, tag: String, tip: String):
        """Its one quiet action (beside Export CSV): tables.acted says when it was tapped."""
        self.action = label
        self.action_icon = icon
        self.action_tag = tag
        self.action_tip = tip

    def facts(self) -> String:
        """Its size, in a few words: "23 rows · 5 columns"."""
        var rows = self.sheet.rows()
        var cols = self.sheet.columns()
        return grouped(rows) + (" row" if rows == 1 else " rows") + " · " + String(cols) + (" column" if cols == 1 else " columns")


struct TableCards(Movable, Sized):
    """The tables on a page besides its own, each with its own messages and canvas."""

    var cards: List[TableCard]
    var msg_base: Int
    var canvas_base: Int
    var most: Int
    var closed: Int  # the card the last update() removed (its index then), else -1
    var exported: String  # the file the last update() wrote (Export CSV), else ""
    var selected: Int  # the card whose grid selected a cell in the last update() (its grid's cur_row, cur_col), else -1
    var problem: String  # why the last export failed, else ""
    var acted: Int  # the card whose action the last update() was, else -1
    var export_asked: Int  # the card whose Export CSV the last update() was (export_path: where it goes), else -1
    var export_path: String
    var dragged: Int  # the card whose column header the last update() dragged (GRID_HEADER_DRAG) or let go (GRID_HEADER_DROP), else -1
    var drag_state: Int  # which of the two
    var drag_column: String  # the column carried
    var drag_x: Float64  # the pointer, in the page's (the Board's) coordinates
    var drag_y: Float64

    def __init__(out self, msg_base: Int, canvas_base: Int, most: Int = 8):
        self.cards = List[TableCard]()
        self.msg_base = msg_base
        self.canvas_base = canvas_base
        self.most = most
        self.closed = -1
        self.exported = ""
        self.selected = -1
        self.problem = ""
        self.acted = -1
        self.export_asked = -1
        self.export_path = ""
        self.dragged = -1
        self.drag_state = 0
        self.drag_column = ""
        self.drag_x = 0
        self.drag_y = 0

    def __len__(self) -> Int:
        return len(self.cards)

    def _free_slot(self) -> Int:
        for s in range(self.most):
            var used = False
            for k in range(len(self.cards)):
                if self.cards[k].slot == s:
                    used = True
            if not used:
                return s
        return -1

    def add(mut self, name: String, var sheet: Sheet, x: Int, y: Int, w: Int, h: Int, font: Font, pal: Palette) raises -> Int:
        """A card for the table at (x, y), w × h points; its index. A name already on the page is replaced (a query run
        again under the same name answers in the same card, where it was)."""
        var at = self.find(name)
        if at >= 0:
            var slot = self.cards[at].slot
            var px = self.cards[at].x
            var py = self.cards[at].y
            var pw = self.cards[at].w
            var ph = self.cards[at].h
            self.cards[at] = TableCard(name, sheet^, slot, px, py, pw, ph, font, pal)
            return at
        var slot = self._free_slot()
        if slot < 0:
            raise Error("A page holds up to " + String(self.most) + " extra tables: close one first")
        self.cards.append(TableCard(name, sheet^, slot, x, y, w, h, font, pal))
        return len(self.cards) - 1

    def adopt(mut self, var card: TableCard, x: Int, y: Int, w: Int, h: Int) raises -> Int:
        """A card made elsewhere (a job: mojoui.tablejobs) put on the page at (x, y), w × h points; its index. A name
        already on the page is replaced where it was, as add() does."""
        var at = self.find(card.name)
        if at >= 0:
            card.slot = self.cards[at].slot
            card.x = self.cards[at].x
            card.y = self.cards[at].y
            card.w = self.cards[at].w
            card.h = self.cards[at].h
            self.cards[at] = card^
            return at
        var slot = self._free_slot()
        if slot < 0:
            raise Error("A page holds up to " + String(self.most) + " extra tables: close one first")
        card.slot = slot
        card.x = x
        card.y = y
        card.w = w
        card.h = h
        self.cards.append(card^)
        return len(self.cards) - 1

    def find(self, name: String) -> Int:
        """The card called `name` (or whose SQL name it is), else -1."""
        for k in range(len(self.cards)):
            if self.cards[k].name == name or self.sql_name_of(k) == name:
                return k
        return -1

    def sql_name_of(self, k: Int, page_name: String = "") -> String:
        """Card k's SQL name, unique on the page: the first card with a name keeps it, a later one (or one that shares
        the page's own table's name, `page_name`) gets _2, _3… so a query never reads the wrong table and Export CSV
        never writes over another card's file."""
        var base = sql_name(self.cards[k].name)
        var n = 1
        if page_name != "" and sql_name(page_name) == base:
            n += 1
        for j in range(k):
            if sql_name(self.cards[j].name) == base:
                n += 1
        return base if n == 1 else base + "_" + String(n)

    def remove(mut self, k: Int):
        if 0 <= k < len(self.cards):
            _ = self.cards.pop(k)

    def clear(mut self):
        self.cards = List[TableCard]()

    def msg(self, k: Int) -> Int:
        return self.msg_base + self.cards[k].slot * TABLE_MESSAGES

    def canvas(self, k: Int) -> Int:
        return self.canvas_base + self.cards[k].slot

    def owns(self, message: Int) -> Bool:
        return self.msg_base <= message < self.msg_base + self.most * TABLE_MESSAGES

    def add_to(self, mut catalog: Catalog, page_name: String = "") raises:
        """Every card's table as a SQL source, by its unique SQL name (sql_name_of; edits included)."""
        for k in range(len(self.cards)):
            catalog.add_frame(self.sql_name_of(k, page_name), self.cards[k].sheet.frame)

    def query(self, text: String, page_name: String, page: Sheet) raises -> Sheet:
        """A SQL query over every card's table and the page's own table (`page`, as `page_name`; "": left out): its
        answer as a sheet."""
        var catalog = Catalog()
        var page_sql = String("")
        if page_name != "" and self.find(page_name) < 0:
            page_sql = page_name
            catalog.add_frame(sql_name(page_name), page.frame)
        self.add_to(catalog, page_sql)
        return Sheet(query_table(catalog, text).share(), False)

    def update(mut self, event: Event, font: Font, pal: Palette, folder: String) -> Bool:
        """True when `event` was a card's: its grid scrolled or selected (selected = its index), Export CSV wrote
        <folder>/<sql name>.csv (exported = the path; problem when it failed), or its close removed it (closed)."""
        self.closed = -1
        self.exported = ""
        self.selected = -1
        self.problem = ""
        self.acted = -1
        self.export_asked = -1
        self.dragged = -1
        if not self.owns(event.message):
            return False
        for k in range(len(self.cards)):
            var m0 = self.msg(k)
            if m0 <= event.message < m0 + TABLE_MESSAGES:
                var which = event.message - m0
                if which == TC_GRID:
                    ref c = self.cards[k]
                    var r = c.grid.handle(event, c.sheet, font, pal)
                    if r == GRID_SELECTED:
                        self.selected = k
                    elif r == GRID_HEADER_DRAG or r == GRID_HEADER_DROP:
                        self.dragged = k
                        self.drag_state = r
                        self.drag_column = c.sheet.grid_name(c.grid.drag_col)
                        self.drag_x = Float64(c.x + GRID_LEFT) + event.x
                        self.drag_y = Float64(c.y + GRID_TOP) + event.y
                elif which == TC_EXPORT:  # (asked here, written by the app's job: a million rows take a second)
                    self.export_asked = k
                    self.export_path = folder + "/" + self.sql_name_of(k) + ".csv"
                elif which == TC_CLOSE:
                    self.remove(k)
                    self.closed = k
                elif which == TC_ACTION and self.cards[k].action != "":
                    self.acted = k
                return True
        return True  # (a card closed since: its late gestures are dropped)

    def _card_of_canvas(self, canvas: Int) -> Int:
        for k in range(len(self.cards)):
            if self.canvas(k) == canvas:
                return k
        return -1

    def draws(self, canvas: Int) -> Bool:
        return self._card_of_canvas(canvas) >= 0

    def draw(mut self, canvas: Int, mut s: Surface, font: Font, pal: Palette):
        var k = self._card_of_canvas(canvas)
        if k >= 0:
            ref c = self.cards[k]
            c.grid.draw(s, c.sheet, font, pal)

    def spot(self, canvas: Int, name: String) -> Tuple[Float64, Float64]:
        """Where column `name`'s header is on card `canvas`'s grid (App.spot), else (-1, -1)."""
        var k = self._card_of_canvas(canvas)
        if k < 0:
            return (-1.0, -1.0)
        return self.cards[k].grid.header_spot(name, self.cards[k].sheet)

    def describe(self, canvas: Int, first: Int, count: Int) -> String:
        """Card `canvas`'s rows for an agent: its name, then the header and `count` rows from `first` (0: 25), tab-separated."""
        var k = self._card_of_canvas(canvas)
        if k < 0:
            return ""
        ref c = self.cards[k]
        var out = c.name + " (" + c.facts() + ")\n"
        var cols = c.sheet.grid_columns()
        for col in range(cols):
            out += ("\t" if col > 0 else "") + c.sheet.grid_name(col)
        var n = count if count > 0 else 25
        var i = first
        var got = 0
        while got < n:
            var r = c.grid.shown_row(i, c.sheet)
            if r < 0:
                break
            i += 1
            if not c.sheet.grid_alive(r):
                continue
            out += "\n"
            for col in range(cols):
                out += ("\t" if col > 0 else "") + c.sheet.grid_text(col, r)
            got += 1
        return out^

    def view(self, k: Int, version: Int) -> View:
        """Card k: its title bar (name, where it came from, its size, Export CSV, close) over its grid, filling the card."""
        ref c = self.cards[k]
        var name = self.sql_name_of(k)
        var rows = c.sheet.rows()
        var parts = List[View]()
        parts.append(Text(c.name, HEADLINE).tag("table-title").tooltip(c.facts() + (" · " + c.note if c.note != "" else String(""))))
        parts.append(Text(grouped(rows) + (" row" if rows == 1 else " rows"), CAPTION).tone(TONE_ACCENT))  # (as the sheet's own table says it)
        parts.append(Spacer())
        if c.note != "" and c.w >= 560:  # (where it came from, when there's room: else in the title's tooltip)
            parts.append(Text(c.note, CAPTION))
        if c.action != "":
            parts.append(Button(c.action, self.msg(k) + TC_ACTION, SUBTLE, icon=c.action_icon).tag(c.action_tag).tooltip(c.action_tip))
        parts.append(Button("Export CSV", self.msg(k) + TC_EXPORT, SUBTLE, icon="download").tag("export-" + name.replace("_", "-"))
                     .tooltip("Save " + c.name + " as " + name + ".csv in your documents"))
        parts.append(Button("Remove", self.msg(k) + TC_CLOSE, ICON_ONLY, icon="close").tag("close-" + name.replace("_", "-")).tooltip("Close " + c.name))
        var head = HStack(parts^, spacing=8).fill().align(CENTER).height(TABLE_HEAD_H)
        var grid = Canvas(self.canvas(k), version + c.grid.version, on_gesture=self.msg(k) + TC_GRID, keys=True).fill().grow().tag("table-" + name.replace("_", "-"))
        grid = grid^.label("Table " + c.name + ", " + c.facts())  # (a drawn grid: its name for a screen reader)
        return Card(head^, grid^, spacing=4)
