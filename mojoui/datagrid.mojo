# mojoui.datagrid: a spreadsheet-style grid over any number of rows, drawn on a Canvas.
#
#   var grid = DataGrid()                                   # app state, one per table on screen
#   Canvas(id, version, on_gesture=GRID)                   # in view()
#   grid.draw(surface, source, font, palette)              # in draw()
#   var action = grid.handle(event, source, font, palette) # in update(): GRID_* tells the app what happened
#
# What it does on its own: virtual scrolling (only the rows on screen are read), a scroll bar (drag the
# thumb, click the track), cell and whole-column selection, a sort marker, column widths (drag a header's
# edge, double-click a header to fit), sideways scrolling, an in-place editor's placement, header
# histograms (when the app hands it the shapes), long text cut with "…". What it leaves to the app:
# the data (a GridSource), writing values and sorting (engine operations: the grid only shows them).

from mojoui.app import Event
from mojoui.view import View, TextField, TAP, PAN, ZOOM, PRESS, RELEASE, DOUBLE, KEY, SHIFT, CTRL, ALT
from mojoui.canvas import Surface
from mojoui.scene import Painter, SurfacePainter, Scene
from mojoui.text import Font, MONO, RIGHT, CENTRE, LEFT, REGULAR
from mojoui.cellstyle import CellStyle, swatch, fill_over, AUTO_ALIGN, ALIGN_LEFT, ALIGN_CENTRE, ALIGN_RIGHT, ITALIC_SLANT
from mojoui.draw import rect, hline, line, circle, with_alpha
from std.time import perf_counter_ns
from std.math import exp
from mojoui.theme import Palette, mix
from mojoui.maths import log2
from mojoui.charts import grouped

comptime GRID_ROW_H = 26.0
comptime GRID_HEADER_H = 30.0
comptime GRID_HISTOGRAM_H = 22.0  # extra header height when columns show their distributions
comptime GRID_GUTTER = 64.0
comptime GRID_BAR_W = 14.0

# what handle() reports
comptime GRID_NONE = 0
comptime GRID_REDRAW = 1  # only the grid's own state changed (scrolled, a drag, a width)
comptime GRID_SELECTED = 2  # a cell was selected (grid.cur_row, grid.cur_col)
comptime GRID_COLUMN = 3  # a whole column was selected (grid.cur_col)
comptime GRID_EDIT = 4  # the in-place editor opened over the selected cell
comptime GRID_READ_ONLY = 5  # a double click on a column that can't be edited (a formula)
comptime GRID_FITTED = 6  # a column was fitted (grid.cur_col is unchanged; grid.last_col is the column)
comptime GRID_RESIZED = 7  # a header edge drag ended (grid.last_col)
comptime GRID_TYPED = 8  # a character typed on a cell: the editor opened, starting from grid.typed (it replaces the value)
comptime GRID_CLEAR = 9  # Delete or Backspace on an editable cell: the app clears it
comptime GRID_CANCEL = 10  # Escape: the editor closed without writing
comptime GRID_COMMIT = 11  # Enter on a value being typed: write grid.typed into the cell (then call committed())


trait GridSource:
    """The data a DataGrid shows. Rows are numbered 0…grid_rows()-1; some may be gone (grid_alive)."""

    def grid_rows(self) -> Int:
        ...

    def grid_alive(self, row: Int) -> Bool:
        ...

    def grid_columns(self) -> Int:
        ...

    def grid_name(self, c: Int) -> String:
        ...

    def grid_numeric(self, c: Int) -> Bool:
        """Numbers are right-aligned."""
        ...

    def grid_editable(self, c: Int) -> Bool:
        """False for a column that can't be typed into (a formula's, or a read-only table's)."""
        ...

    def grid_formula(self, c: Int) -> Bool:
        """A computed column (drawn in the formula colour, marked ƒ). By default, any column that can't be typed into
        (a source with a read-only column that isn't a formula says so, as a streamed Sheet does)."""
        return not self.grid_editable(c)

    def grid_text(self, c: Int, row: Int) -> String:
        ...

    def grid_type_width(self, c: Int) -> Float64:
        """A sensible default width for the column's values (points)."""
        ...

    def grid_badge(self, c: Int) -> String:
        """The column's type, as the small badge beside its name: "#", "$", "0.0", "Aa", "date", "ƒx"."""
        ...

    def grid_style(self, c: Int, row: Int) -> CellStyle:
        """How cell (c, row) looks: bold, italic, underline, strikethrough, colours, alignment (mojoui.cellstyle)."""
        return CellStyle()

    def grid_edited(self, c: Int, row: Int) -> Bool:
        """True for a cell changed in this session (it gets a corner mark)."""
        ...


struct DataGrid(Copyable, Movable):
    var top: Int  # first shown row (an index into `order`, or a row number)
    var left: Float64  # scrolled sideways (points)
    var order: List[Int]  # the rows in shown order (a sort), or empty: natural order
    var sort_col: Int
    var sort_desc: Bool
    var cur_row: Int  # selection: a cell, or (cur_row -1) a whole column
    var cur_col: Int
    var anchor_row: Int  # a block of cells: from the anchor to (cur_row, cur_col); the anchor is the cell itself when it's one cell
    var anchor_col: Int
    var anchor_index: Int  # the anchor's display index, found once when a block starts (-1: not known yet)
    var dragging: Bool  # a press on a cell, then a drag: the block follows the pointer
    var browse: Bool  # read-only browsing (an import's preview): scrolling and its bar work, cells don't select
    var ring: List[Float64]  # the selection ring as drawn (x, y, w, h in points), gliding toward `ring_to`
    var ring_from: List[Float64]
    var ring_to: List[Float64]
    var ring_t0: Int  # when the glide began (ns)
    var ring_view: Tuple[Int, Float64]  # (top, left) when the ring was last placed: a scroll moves it at once, never glides
    var widths: List[Float64]  # per column, points (0 = its default)
    var min_widths: List[Float64]  # per column: its header's width (from prepare())
    var type_widths: List[Float64]  # per column: the source's default width for its values (from prepare())
    var histograms: List[List[Float64]]  # per column: bar heights 0–1 (empty: none drawn)
    var editing: Bool
    var typed: String  # what's been typed since a character opened the editor (GRID_TYPED)
    var typing: Bool  # the editor was opened by typing: the grid keeps the keyboard and the text (the editor echoes it)
    var then: String  # the key that ended the typing (GRID_COMMIT): where committed() moves
    var bar_drag: Bool
    var bar_grab: Float64
    var resize_col: Int
    var resize_x0: Float64
    var resize_w0: Float64
    var last_col: Int
    var pan: Float64
    var size: Tuple[Float64, Float64]  # the canvas in points (from the last draw)
    var version: Int  # bumped whenever the grid needs redrawing (add it into the Canvas version)

    def __init__(out self):
        self.top = 0
        self.left = 0
        self.order = List[Int]()
        self.sort_col = -1
        self.sort_desc = False
        self.cur_row = -1
        self.cur_col = -1
        self.anchor_row = -1
        self.anchor_col = -1
        self.anchor_index = -1
        self.dragging = False
        self.browse = False
        self.ring = List[Float64]()
        self.ring_from = List[Float64]()
        self.ring_to = List[Float64]()
        self.ring_t0 = 0
        self.ring_view = (0, 0.0)
        self.widths = List[Float64]()
        self.min_widths = List[Float64]()
        self.type_widths = List[Float64]()
        self.histograms = List[List[Float64]]()
        self.editing = False
        self.typed = ""
        self.typing = False
        self.then = "Enter"
        self.bar_drag = False
        self.bar_grab = 0
        self.resize_col = -1
        self.resize_x0 = 0
        self.resize_w0 = 0
        self.last_col = -1
        self.pan = 0
        self.size = (1200.0, 256.0)
        self.version = 1

    # ---------- geometry ----------

    def header_h(self) -> Float64:
        return GRID_HEADER_H + (GRID_HISTOGRAM_H if len(self.histograms) > 0 else 0.0)

    def prepare[S: GridSource](mut self, src: S, font: Font, pal: Palette):
        """Measures the headers (a column is never narrower than its name and its type badge). Cheap; call before
        using widths."""
        var n = src.grid_columns()
        if len(self.min_widths) == n:
            return
        self.min_widths = List[Float64](capacity=n)
        self.type_widths = List[Float64](capacity=n)
        for c in range(n):
            var name = src.grid_name(c) + ("ƒ " if src.grid_formula(c) else "")
            var badge = src.grid_badge(c)
            var badge_w = (font.measure(badge, 9.5, MONO) + 8 + 6 + 4) if badge != "" else 0.0  # (as draw() places it, and a little room)
            self.min_widths.append(font.measure(name, 12.5, pal.medium) + 26 + badge_w)
            self.type_widths.append(src.grid_type_width(c))  # (once: it may scan a dictionary)

    def col_width[S: GridSource](self, c: Int, src: S) -> Float64:
        if c < len(self.widths) and self.widths[c] > 0:
            return self.widths[c]
        var header = self.min_widths[c] if c < len(self.min_widths) else 0.0
        var typed = self.type_widths[c] if c < len(self.type_widths) else src.grid_type_width(c)
        return max(typed, header)

    def col_left[S: GridSource](self, c: Int, src: S) -> Float64:
        """Where column c starts (points), the sideways scroll applied."""
        var x = GRID_GUTTER - self.left
        for k in range(c):
            x += self.col_width(k, src)
        return x

    def columns_width[S: GridSource](self, src: S) -> Float64:
        var x = GRID_GUTTER
        for c in range(src.grid_columns()):
            x += self.col_width(c, src)
        return x

    def rows_in(self, h: Float64) -> Int:
        return max(Int((h - self.header_h()) / GRID_ROW_H), 1)

    def shown_count[S: GridSource](self, src: S) -> Int:
        return len(self.order) if len(self.order) > 0 else src.grid_rows()

    def shown_row[S: GridSource](self, i: Int, src: S) -> Int:
        """The row at display index i (sorted or natural order), or -1."""
        if len(self.order) > 0:
            return self.order[i] if 0 <= i < len(self.order) else -1
        return i if 0 <= i < src.grid_rows() else -1

    def screen_line[S: GridSource](self, row: Int, src: S) -> Int:
        """Which line on screen shows `row` (0 = the first under the header), or -1."""
        var i = self.top
        var seen = 0
        while seen < self.rows_in(self.size[1]):
            var r = self.shown_row(i, src)
            if r < 0:
                return -1
            i += 1
            if not src.grid_alive(r):
                continue
            if r == row:
                return seen
            seen += 1
        return -1

    def thumb[S: GridSource](self, h: Float64, src: S) -> Tuple[Float64, Float64]:
        """The scroll bar's thumb (top, height) in points for a grid h points tall."""
        var head = self.header_h()
        var track = h - head
        var count = max(self.shown_count(src), 1)
        var visible = min(self.rows_in(h), count)
        var size = max(track * Float64(visible) / Float64(count), 28.0)
        var span = max(count - visible, 1)
        return (head + (track - size) * Float64(min(self.top, span)) / Float64(span), size)

    def editor_place[S: GridSource](self, src: S) -> Tuple[Int, Int, Int]:
        """Where the in-place editor goes, in the canvas's points: (x, y, width) over the selected cell,
        or width 0 when it's closed or the cell isn't fully on screen."""
        if not self.editing or self.cur_row < 0 or self.cur_col < 0:
            return (0, 0, 0)
        var line_no = self.screen_line(self.cur_row, src)
        var x = self.col_left(self.cur_col, src)
        var w = self.col_width(self.cur_col, src)
        if line_no < 0 or x < GRID_GUTTER or x + w > self.size[0] - GRID_BAR_W:
            return (0, 0, 0)
        return (Int(x), Int(self.header_h()) + line_no * 26 - 2, Int(w))  # (26: GRID_ROW_H)

    def position_text[S: GridSource](self, src: S) -> String:
        """ "Rows 1–8 of 20,000,000" """
        var count = self.shown_count(src)
        return "Rows " + grouped(min(self.top + 1, count)) + "–" + grouped(min(self.top + self.rows_in(self.size[1]), count)) + " of " + grouped(count)

    # ---------- hit tests ----------

    def in_columns(self, x: Float64) -> Bool:
        return GRID_GUTTER <= x < self.size[0] - GRID_BAR_W

    def on_bar(self, x: Float64, y: Float64) -> Bool:
        return x >= self.size[0] - GRID_BAR_W and y >= self.header_h()

    def header_hit[S: GridSource](self, x: Float64, y: Float64, src: S) -> Int:
        if y >= self.header_h() or not self.in_columns(x):
            return -1
        var left = GRID_GUTTER - self.left
        for c in range(src.grid_columns()):
            var w = self.col_width(c, src)
            if left <= x < left + w:
                return c
            left += w
        return -1

    def edge_hit[S: GridSource](self, x: Float64, y: Float64, src: S) -> Int:
        """The column whose header's right edge is under (x, y) (5 pt either side), or -1."""
        if y >= self.header_h():
            return -1
        var edge = GRID_GUTTER - self.left
        for c in range(src.grid_columns()):
            edge += self.col_width(c, src)
            if abs(x - edge) <= 5 and edge > GRID_GUTTER:
                return c
        return -1

    def cell_hit[S: GridSource](self, x: Float64, y: Float64, src: S) -> Tuple[Int, Int]:
        """(row, column) under (x, y) in points, or (-1, -1). Only whole rows on screen count."""
        if y < self.header_h() or not self.in_columns(x):
            return (-1, -1)
        var line_no = Int((y - self.header_h()) / GRID_ROW_H)
        if line_no >= self.rows_in(self.size[1]):
            return (-1, -1)
        var i = self.top
        var seen = 0
        while True:
            var r = self.shown_row(i, src)
            if r < 0:
                return (-1, -1)
            i += 1
            if not src.grid_alive(r):
                continue
            if seen == line_no:
                var left = GRID_GUTTER - self.left
                for c in range(src.grid_columns()):
                    var w = self.col_width(c, src)
                    if left <= x < left + w:
                        return (r, c)
                    left += w
                return (r, -1)
            seen += 1

    # ---------- changes ----------

    def redraw(mut self):
        self.version += 1

    def select(mut self, row: Int, col: Int):
        self.cur_row = row
        self.cur_col = col
        self.anchor_row = row
        self.anchor_col = col
        self.anchor_index = -1
        self.editing = False
        self.typed = ""
        self.typing = False
        self.then = "Enter"
        self.redraw()

    def extend[S: GridSource](mut self, row: Int, col: Int, src: S):
        """Grows (or shrinks) the block to (row, col), keeping its anchor (its display index is found once, here)."""
        if self.anchor_row < 0 or self.anchor_col < 0:
            self.anchor_row = self.cur_row
            self.anchor_col = self.cur_col
        if self.anchor_index < 0:
            self.anchor_index = self.index_of(self.anchor_row, src)
        self.cur_row = row
        self.cur_col = col
        self.editing = False
        self.typing = False
        self.redraw()

    def has_block(self) -> Bool:
        """More than one cell selected."""
        return self.cur_row >= 0 and self.anchor_row >= 0 and (self.anchor_row != self.cur_row or self.anchor_col != self.cur_col)

    def block[S: GridSource](self, src: S) -> Tuple[Int, Int, Int, Int]:
        """The selected block as (first, last) display indices and (first, last) columns; one cell when there's no block;
        (-1, -1, -1, -1) when nothing (or a whole column) is selected."""
        if self.cur_row < 0 or self.cur_col < 0:
            return (-1, -1, -1, -1)
        var i1 = self.index_of(self.cur_row, src)
        if i1 < 0:
            return (-1, -1, -1, -1)
        var i0 = i1
        if self.has_block():
            i0 = self.anchor_index if self.anchor_index >= 0 and self.shown_row(self.anchor_index, src) == self.anchor_row else self.index_of(self.anchor_row, src)
        if i0 < 0:  # (the anchor's row went away: one cell)
            return (i1, i1, self.cur_col, self.cur_col)
        var c0 = self.anchor_col if self.has_block() else self.cur_col
        return (min(i0, i1), max(i0, i1), min(c0, self.cur_col), max(c0, self.cur_col))

    def block_size[S: GridSource](self, src: S) -> Int:
        """How many cells the block covers (display rows × columns; removed rows included): cheap, for caps."""
        var b = self.block(src)
        return 0 if b[0] < 0 else (b[1] - b[0] + 1) * (b[3] - b[2] + 1)

    def cancel_edit(mut self):
        """The editor closed without writing (its Escape, or anything else the app does meanwhile)."""
        self.editing = False
        self.typed = ""
        self.typing = False
        self.then = "Enter"
        self.redraw()

    def editor(self, value: String, on_submit: Int, on_cancel: Int) -> View:
        """The in-place editor's field (place it with editor_place()): Enter sends on_submit (event.text = the
        value), Escape on_cancel. Opened by typing, it starts from what was typed with the caret after it;
        opened by F2 or a double click, the value is selected (typing replaces it). While a value is being typed the
        grid keeps the keyboard (every key reaches it in order, however fast) and the field echoes grid.typed;
        a click in the field gives it the keyboard instead."""
        if self.typing:
            return TextField(self.typed, placeholder="Cell", on_submit=on_submit, on_cancel=on_cancel).echo().tag("cell-editor")
        return TextField(value, placeholder="Cell", on_submit=on_submit, on_cancel=on_cancel).focused().tag("cell-editor")

    def set_order(mut self, var order: List[Int], col: Int, descending: Bool):
        """Show the rows in this order (the engine's sort); col and descending set the header marker."""
        self.order = order^
        self.sort_col = col
        self.sort_desc = descending
        self.top = 0
        self.anchor_row = self.cur_row  # (a block's rows are scattered by a sort: it collapses to the cell)
        self.anchor_col = self.cur_col
        self.anchor_index = -1
        self.redraw()

    def clear_order(mut self):
        self.order = List[Int]()
        self.sort_col = -1
        self.anchor_row = self.cur_row
        self.anchor_col = self.cur_col
        self.anchor_index = -1
        self.redraw()

    def scroll_rows[S: GridSource](mut self, rows: Int, src: S):
        self.top = max(0, min(self.top + rows, max(self.shown_count(src) - 5, 0)))
        self.redraw()

    def scroll_to_thumb[S: GridSource](mut self, thumb_top: Float64, src: S):
        var h = self.size[1]
        var t = self.thumb(h, src)
        var room = max(h - self.header_h() - t[1], 1.0)
        var span = max(self.shown_count(src) - min(self.rows_in(h), self.shown_count(src)), 0)
        var f = min(max((thumb_top - self.header_h()) / room, 0.0), 1.0)
        var top = Int(f * Float64(span) + 0.5)
        if top != self.top:
            self.top = top
            self.redraw()

    def scroll_sideways[S: GridSource](mut self, dx: Float64, src: S):
        var most = max(self.columns_width(src) - (self.size[0] - GRID_BAR_W), 0.0)
        var left = min(max(self.left - dx, 0.0), most)
        if left != self.left:
            self.left = left
            self.redraw()

    def reveal_cell[S: GridSource](mut self, row: Int, col: Int, src: S):
        """Scrolls so the cell is fully on screen (rows and columns)."""
        if self.screen_line(row, src) < 0:
            var i = 0
            var shown = self.shown_count(src)
            if len(self.order) > 0:
                for k in range(len(self.order)):
                    if self.order[k] == row:
                        i = k
            else:
                i = row
            self.top = max(0, min(i - self.rows_in(self.size[1]) // 2, max(shown - 1, 0)))
        var x = self.col_left(col, src)
        var w = self.col_width(col, src)
        var room = self.size[0] - GRID_BAR_W
        if x < GRID_GUTTER:
            self.left -= GRID_GUTTER - x
        elif x + w > room:
            self.left += min(x + w - room, x - GRID_GUTTER)
        self.left = max(self.left, 0.0)
        self.redraw()

    def set_width(mut self, c: Int, w: Float64):
        while len(self.widths) <= c:
            self.widths.append(0)
        self.widths[c] = min(max(w, 40.0), 600.0)
        self.redraw()

    def fit[S: GridSource](mut self, c: Int, src: S, font: Font, pal: Palette):
        """Column c as wide as its header and the values around what's on screen (200 rows)."""
        var w = self.min_widths[c] + 8 if c < len(self.min_widths) else 60.0
        var i = max(self.top - 100, 0)
        var seen = 0
        while seen < 200:
            var r = self.shown_row(i, src)
            if r < 0:
                break
            i += 1
            if src.grid_alive(r):
                w = max(w, font.measure(src.grid_text(c, r), 13, pal.regular) + 18)
                seen += 1
        self.set_width(c, w)
        self.last_col = c

    def next_row[S: GridSource](self, row: Int, src: S) -> Int:
        """The row shown below `row` (skipping removed ones), or -1."""
        var line_no = self.screen_line(row, src)
        var i: Int
        if line_no >= 0:  # on screen: walk from the top (cheap even when sorted)
            i = self.top
            var seen = 0
            while seen <= line_no:
                var r = self.shown_row(i, src)
                i += 1
                if r >= 0 and src.grid_alive(r):
                    seen += 1
        else:
            i = row + 1 if len(self.order) == 0 else -1
            if i < 0:
                return -1
        while True:
            var r = self.shown_row(i, src)
            if r < 0:
                return -1
            if src.grid_alive(r):
                return r
            i += 1

    def committed[S: GridSource](mut self, src: S):
        """After the app wrote the editor's value: close it and move on as a spreadsheet does: down after Enter, right
        after Tab (left with Shift), along an arrow that ended the typing."""
        var how = self.then
        self.then = "Enter"
        var row = self.cur_row
        var col = self.cur_col
        self.editing = False
        if how == "Tab" or how == "ArrowRight":
            _ = self.move_to(row, min(col + 1, src.grid_columns() - 1), src)
        elif how == "ShiftTab" or how == "ArrowLeft":
            _ = self.move_to(row, max(col - 1, 0), src)
        elif how == "ArrowUp":
            _ = self.move_to(self.step_row(row, -1, src), col, src)
        else:
            var below = self.next_row(row, src)
            _ = self.move_to(below if below >= 0 else row, col, src)

    # ---------- events ----------

    def handle[S: GridSource](mut self, event: Event, src: S, font: Font, pal: Palette) -> Int:
        """A gesture on the grid's canvas. Returns GRID_*; the grid's own state is already updated."""
        self.prepare(src, font, pal)
        var head = self.header_h()
        if event.number == PRESS:
            self.editing = False
            self.typed = ""
            self.typing = False
            if self.edge_hit(event.x, event.y, src) >= 0:  # a header's edge: resize that column
                self.resize_col = self.edge_hit(event.x, event.y, src)
                self.resize_x0 = event.x
                self.resize_w0 = self.col_width(self.resize_col, src)
                self.bar_drag = False
                self.redraw()
                return GRID_REDRAW
            self.resize_col = -1
            var was = self.bar_drag
            self.bar_drag = self.on_bar(event.x, event.y)
            if self.bar_drag:
                var t = self.thumb(self.size[1], src)
                if t[0] <= event.y < t[0] + t[1]:
                    self.bar_grab = event.y - t[0]
                else:  # the track: the thumb jumps there, centred on the pointer
                    self.bar_grab = t[1] / 2
                    self.scroll_to_thumb(event.y - self.bar_grab, src)
                self.redraw()
                return GRID_REDRAW
            if was:
                self.redraw()
                return GRID_REDRAW
            if self.browse:  # (a preview: the press only scrolls, by the bar above or a drag below)
                return GRID_NONE
            if event.y >= head and self.in_columns(event.x):  # a press on a cell: a drag from here selects a block
                var at = self.cell_hit(event.x, event.y, src)
                if at[0] >= 0 and at[1] >= 0:
                    self.dragging = True
                    if Int(event.dx) & SHIFT == 0:  # (Shift held: the press extends the block instead, on TAP)
                        self.select(at[0], at[1])
                    return GRID_SELECTED
            return GRID_NONE
        if event.number == RELEASE:  # a drag ended: the thumb (or a column edge) lets go, a block stays
            var result = GRID_NONE
            self.dragging = False
            if self.resize_col >= 0:
                self.last_col = self.resize_col
                self.resize_col = -1
                result = GRID_RESIZED
            if self.bar_drag:
                self.bar_drag = False
                if result == GRID_NONE:
                    result = GRID_REDRAW
            self.redraw()
            return result
        if event.number == DOUBLE:
            if event.y < head:  # a header: fit the column to what's in it
                var c = self.header_hit(event.x, event.y, src)
                if c < 0:
                    c = self.edge_hit(event.x, event.y, src)
                if c >= 0:
                    self.fit(c, src, font, pal)
                    return GRID_FITTED
                return GRID_NONE
            if self.on_bar(event.x, event.y):
                return GRID_NONE
            var hit = self.cell_hit(event.x, event.y, src)
            if hit[0] < 0 or hit[1] < 0:
                return GRID_NONE
            self.select(hit[0], hit[1])
            if not src.grid_editable(hit[1]):
                return GRID_READ_ONLY
            self.reveal_cell(hit[0], hit[1], src)
            self.editing = True
            return GRID_EDIT
        if event.number == TAP:
            if self.resize_col >= 0:  # a click on an edge without a drag: nothing to resize
                self.resize_col = -1
                self.redraw()
            if self.on_bar(event.x, event.y):
                self.bar_drag = False
                self.redraw()
                return GRID_REDRAW
            if event.y < head:
                var c = self.header_hit(event.x, event.y, src)
                if c >= 0:  # a header: the whole column
                    self.select(-1, c)
                    return GRID_COLUMN
                return GRID_NONE
            var hit = self.cell_hit(event.x, event.y, src)
            if hit[0] >= 0 and hit[1] >= 0:
                if Int(event.dx) & SHIFT != 0 and self.cur_row >= 0:  # Shift+click: the block to here
                    self.extend(hit[0], hit[1], src)
                elif not self.has_block() or self.cur_row != hit[0] or self.cur_col != hit[1]:
                    self.select(hit[0], hit[1])
                return GRID_SELECTED
            return GRID_NONE
        if event.number == PAN:
            if self.dragging and self.resize_col < 0 and not self.bar_drag:  # a drag over cells: the block follows the pointer
                var at = self.cell_hit(min(max(event.x, GRID_GUTTER + 1), self.size[0] - GRID_BAR_W - 1), max(event.y, head + 1), src)
                if at[0] >= 0 and at[1] >= 0 and (at[0] != self.cur_row or at[1] != self.cur_col):
                    self.extend(at[0], at[1], src)
                    return GRID_SELECTED
                return GRID_NONE
            if self.resize_col >= 0:
                self.set_width(self.resize_col, self.resize_w0 + event.x - self.resize_x0)
            elif self.bar_drag:
                self.scroll_to_thumb(event.y - self.bar_grab, src)
            else:
                if event.dx != 0:
                    self.scroll_sideways(event.dx, src)
                self.pan -= event.dy / GRID_ROW_H
                var rows = Int(self.pan)  # whole rows; the remainder waits for the next motion
                self.pan -= Float64(rows)
                if rows != 0:
                    self.scroll_rows(rows, src)
            return GRID_REDRAW
        if event.number == ZOOM and event.zoom > 0:
            self.scroll_rows(Int(-log2(event.zoom) * 12.0), src)
            return GRID_REDRAW
        if event.number == KEY:
            return self.key(event.text, Int(event.dx), src)
        return GRID_NONE

    # ---------- keyboard ----------

    def index_of[S: GridSource](self, row: Int, src: S) -> Int:
        """The display index of `row` (its place in the sorted order), or -1."""
        if len(self.order) == 0:
            return row if 0 <= row < src.grid_rows() else -1
        var lo = max(self.top - 4 * self.rows_in(self.size[1]), 0)  # near the screen first (cheap), then everywhere
        for i in range(lo, min(lo + 8 * self.rows_in(self.size[1]), len(self.order))):
            if self.order[i] == row:
                return i
        for i in range(len(self.order)):
            if self.order[i] == row:
                return i
        return -1

    def step_row[S: GridSource](self, row: Int, by: Int, src: S) -> Int:
        """The row `by` living rows below (above, if negative) `row` in display order; stops at the ends."""
        var i = self.index_of(row, src)
        if i < 0:
            return row
        var best = row
        var left = abs(by)
        var d = 1 if by > 0 else -1
        while left > 0:
            i += d
            var r = self.shown_row(i, src)
            if r < 0:
                break
            if src.grid_alive(r):
                best = r
                left -= 1
        return best

    def edge_row[S: GridSource](self, last: Bool, src: S) -> Int:
        """The first (or last) living row in display order."""
        var n = self.shown_count(src)
        var i = n - 1 if last else 0
        while 0 <= i < n:
            var r = self.shown_row(i, src)
            if r >= 0 and src.grid_alive(r):
                return r
            i += -1 if last else 1
        return -1

    def first_on_screen[S: GridSource](self, src: S) -> Int:
        var i = self.top
        while True:
            var r = self.shown_row(i, src)
            if r < 0 or src.grid_alive(r):
                return r
            i += 1

    def keep_in_view[S: GridSource](mut self, row: Int, col: Int, src: S):
        """Scrolls the least that shows the cell: a row just off an edge scrolls by a row, not a screen."""
        if self.screen_line(row, src) < 0:
            var i = self.index_of(row, src)
            var lines = self.rows_in(self.size[1])
            if i >= 0 and i < self.top:
                self.top = i
            elif i >= 0:
                self.top = max(i - lines + 1, 0)
                while self.screen_line(row, src) < 0 and self.top < i:  # (removed rows above it take no line)
                    self.top += 1
        self.reveal_cell(row, col, src)

    def move_to[S: GridSource](mut self, row: Int, col: Int, src: S) -> Int:
        if row < 0:
            return GRID_NONE
        var c = min(max(col, 0), src.grid_columns() - 1)
        self.select(row, c)
        self.keep_in_view(row, c, src)
        return GRID_SELECTED

    def key[S: GridSource](mut self, name: String, mods: Int, src: S) -> Int:
        """A key the hosts sent (KEY): moves the selection, opens or closes the editor, or asks the app to clear."""
        var shift = (mods & SHIFT) != 0
        var ctrl = (mods & CTRL) != 0
        if name == "Escape":
            if self.editing:
                self.cancel_edit()
                return GRID_CANCEL
            return GRID_NONE
        var chars = 0
        for _ in name.codepoint_slices():
            chars += 1
        var printable = chars == 1 and not ctrl and (mods & ALT) == 0
        if self.editing and self.typing:  # a value being typed: Enter, Tab or an arrow writes it (and moves), Backspace takes a character off
            if name == "Enter" or name == "Tab" or name == "ArrowDown" or name == "ArrowUp" or name == "ArrowLeft" or name == "ArrowRight":
                self.then = "ShiftTab" if (name == "Tab" and shift) else ("ArrowUp" if (name == "Enter" and shift) else name)
                return GRID_COMMIT
            if name == "Backspace":
                var kept = String("")
                var n = 0
                for ch in self.typed.codepoint_slices():
                    n += 1
                var k = 0
                for ch in self.typed.codepoint_slices():
                    k += 1
                    if k < n:
                        kept += String(ch)
                self.typed = kept
                return GRID_TYPED
            if printable:
                self.typed += name
                return GRID_TYPED
            return GRID_NONE
        var moves = (name == "ArrowDown" or name == "ArrowUp" or name == "ArrowLeft" or name == "ArrowRight" or name == "Tab"
                     or name == "Enter" or name == "PageDown" or name == "PageUp" or name == "Home" or name == "End")
        if self.cur_col < 0:  # nothing selected: a movement key starts at the first cell on screen
            return self.move_to(self.first_on_screen(src), 0, src) if moves else GRID_NONE
        if self.cur_row < 0:  # a whole column: a movement key starts at its first row on screen
            return self.move_to(self.first_on_screen(src), self.cur_col, src) if moves else GRID_NONE
        var row = self.cur_row
        var col = self.cur_col
        var page = max(self.rows_in(self.size[1]) - 1, 1)
        if shift and (name == "ArrowDown" or name == "ArrowUp" or name == "ArrowLeft" or name == "ArrowRight"):  # Shift+arrows: the block grows
            var r = self.step_row(row, 1 if name == "ArrowDown" else (-1 if name == "ArrowUp" else 0), src) if name == "ArrowDown" or name == "ArrowUp" else row
            var c = min(max(col + (1 if name == "ArrowRight" else (-1 if name == "ArrowLeft" else 0)), 0), src.grid_columns() - 1)
            self.extend(r, c, src)
            self.keep_in_view(r, c, src)
            return GRID_SELECTED
        if name == "ArrowDown" or (name == "Enter" and not shift):
            return self.move_to(self.step_row(row, 1, src), col, src)
        if name == "ArrowUp" or (name == "Enter" and shift):
            return self.move_to(self.step_row(row, -1, src), col, src)
        if name == "ArrowRight" or (name == "Tab" and not shift):
            return self.move_to(row, col + 1, src)
        if name == "ArrowLeft" or (name == "Tab" and shift):
            return self.move_to(row, col - 1, src)
        if name == "PageDown":
            return self.move_to(self.step_row(row, page, src), col, src)
        if name == "PageUp":
            return self.move_to(self.step_row(row, -page, src), col, src)
        if name == "Home":
            return self.move_to(self.edge_row(False, src) if ctrl else row, 0, src)
        if name == "End":
            return self.move_to(self.edge_row(True, src) if ctrl else row, src.grid_columns() - 1, src)
        var editable = src.grid_editable(col)
        if name == "F2":
            if not editable:
                return GRID_READ_ONLY
            self.keep_in_view(row, col, src)
            self.typed = ""  # (F2: the value selected, typing replaces it)
            self.typing = False
            self.editing = True
            return GRID_EDIT
        if name == "Delete" or name == "Backspace":
            return GRID_CLEAR if editable else GRID_READ_ONLY
        if printable:
            if not editable:
                return GRID_READ_ONLY
            self.keep_in_view(row, col, src)
            self.typed = name
            self.typing = True
            self.editing = True
            return GRID_TYPED
        return GRID_NONE

    # ---------- drawing ----------

    def clip(self, text: String, room: Float64, size: Float64, weight: Int, font: Font) -> String:
        """text, cut with … to fit `room` pixels."""
        if weight == MONO and Float64(text.byte_length()) * 0.6 * size <= room:
            return text  # (JetBrains Mono: every glyph is 0.6 em wide: short text fits without measuring)
        if font.measure(text, size, weight) <= room:
            return text
        var out = String("")
        for ch in text.codepoint_slices():
            if font.measure(out + String(ch) + "…", size, weight) > room:
                break
            out += String(ch)
        return out + "…"

    def badge_x[S: GridSource](self, c: Int, src: S, font: Font) -> Float64:
        """Where column c's type badge starts (points): after its name."""
        var name = src.grid_name(c)
        if src.grid_formula(c):
            name = "ƒ " + name
        return self.col_left(c, src) + 8 + font.measure(name, 12.5) + 6

    def glide(mut self, var to: List[Float64], still: Bool = False) -> Bool:
        """Moves the drawn ring toward `to` (points) on a critically damped spring (~140 ms to settle). A scroll or the
        first ring jumps straight there. Returns whether it is still moving (draw again next frame)."""
        var view = (self.top, self.left)
        var now = Int(perf_counter_ns())
        if still or len(self.ring) != 4 or view[0] != self.ring_view[0] or view[1] != self.ring_view[1]:  # (less motion asked for: it jumps)
            self.ring = to.copy()
            self.ring_to = to^
            self.ring_view = view
            return False
        var same = True
        for j in range(4):
            if abs(to[j] - self.ring_to[j]) > 0.01:
                same = False
        if not same:  # a new target: glide from where the ring is now
            self.ring_from = self.ring.copy()
            self.ring_to = to^
            self.ring_t0 = now
        if len(self.ring_from) != 4:
            self.ring = self.ring_to.copy()
            return False
        var t = Float64(now - self.ring_t0) / 1e9
        var w = 38.0  # spring frequency (rad/s): settles within ~0.15 s, no overshoot
        var e = 1.0 - (1.0 + w * t) * exp(-w * t)
        var moving = e < 0.995
        for j in range(4):
            self.ring[j] = self.ring_from[j] + (self.ring_to[j] - self.ring_from[j]) * (e if moving else 1.0)
        if not moving:
            self.ring_from = List[Float64]()
        return moving

    def draw[S: GridSource](mut self, mut s: Surface, src: S, font: Font, p: Palette):
        """Paints into pixels (the reference, and hosts without a display-list path)."""
        var sp = SurfacePainter(Surface(s.address, s.width, s.height, s.scale))
        sp.s.still = s.still
        self.paint(sp, src, font, p)
        s.again = sp.s.again

    def draw_scene[S: GridSource](mut self, mut sc: Scene, src: S, font: Font, p: Palette):
        """Records the grid as a display list (goal 26): the cells, then the selection ring in a layer of its own."""
        self.paint(sc, src, font, p)

    def paint[S: GridSource, P: Painter](mut self, mut s: P, src: S, font: Font, p: Palette):
        """The grid, onto any Painter: pixels or a display list. Two layers: "cells" (everything that scrolls with the
        data) and "ring" (the selection ring, which moves on its own: a host keeps the cells when only it changed)."""
        self.prepare(src, font, p)
        var k = s.scale()
        self.size = (Float64(s.width()) / k, Float64(s.height()) / k)
        s.begin_layer("cells")
        s.fill(p.card)
        var w = Float64(s.width())
        var h = Float64(s.height())
        var head = self.header_h() * k
        var right = w - GRID_BAR_W * k  # the columns stop where the scroll bar starts
        var gut = GRID_GUTTER * k
        var col_pick = self.cur_col if self.cur_row < 0 else -1  # a whole column selected
        # every column's left edge and width, once per frame (pixels)
        var ncols = src.grid_columns()
        var lefts = List[Float64](capacity=ncols)
        var widths = List[Float64](capacity=ncols)
        var xpos = (GRID_GUTTER - self.left) * k
        for c in range(ncols):
            var cw = self.col_width(c, src) * k
            lefts.append(xpos)
            widths.append(cw)
            xpos += cw
        # header (and each column's distribution under its name)
        s.rect(0, 0, w, head, p.raised, 0)
        for c in range(ncols):
            var x = lefts[c]
            var cw = widths[c]
            if x >= right:
                break
            if x + cw <= gut:
                continue
            cw = min(cw, right - x)
            if c == col_pick:
                s.rect(x, 0, cw, h, p.accent_wash, 0)  # the column, tinted top to bottom
                s.rect(x, 0, cw, head, p.accent, 0)
            var name = src.grid_name(c)
            if src.grid_formula(c):
                name = "ƒ " + name
            var ink = p.accent_ink if c == col_pick else (p.accent if c == self.sort_col else p.ink2)
            var badge = src.grid_badge(c)
            var bw = (font.measure(badge, 9.5 * k, MONO) + 8 * k) if badge != "" else 0.0
            var shown_name = self.clip(name, cw - 26 * k - bw, 12.5 * k, p.medium, font)
            s.text(font, shown_name, x + 8 * k, 20 * k, 12.5 * k, ink, p.medium, LEFT, 0)
            if badge != "" and shown_name == name:  # the type badge, after the name (when the name fits whole)
                var bx = x + 8 * k + font.measure(name, 12.5 * k, p.medium) + 6 * k
                if bx + bw <= x + cw - 18 * k:
                    var badge_ink = p.accent_ink if c == col_pick else (p.formula if badge == "ƒx" else p.ink3)
                    s.rect(bx, 9 * k, bw, 14 * k, p.accent_ink if c == col_pick else p.line, 0)
                    s.rect(bx + 1, 9 * k + 1, bw - 2, 14 * k - 2, p.accent if c == col_pick else p.card, 0)
                    s.text(font, badge, bx + 4 * k, 19.5 * k, 9.5 * k, badge_ink, MONO, LEFT, 0)
            if c == self.sort_col:  # a small triangle (the font has no arrows): ▼ largest first, ▲ smallest first
                var ax = x + cw - 14 * k
                var ay = 15 * k
                var tint = p.accent_ink if c == col_pick else p.accent
                for r in range(Int(5 * k)):
                    var half = Float64(r) * 0.9
                    var yy = ay + (2.5 * k - Float64(r) if self.sort_desc else Float64(r) - 2.5 * k)  # widest row on top: ▼
                    s.rect(ax - half, yy, 2 * half + 1, 1, tint, 0)
            if c < len(self.histograms) and len(self.histograms[c]) > 0:
                ref bars = self.histograms[c]
                var n = len(bars)
                var bw = (cw - 16 * k) / Float64(n)
                var base_y = head - 5 * k
                var tall = (GRID_HISTOGRAM_H - 7) * k
                for b in range(n):
                    var bh = max(bars[b] * tall, 1.0 * k if bars[b] > 0 else 0.0)
                    s.rect(x + 8 * k + Float64(b) * bw, base_y - bh, max(bw - 1.5 * k, 1.0), bh, p.accent_ink if c == col_pick else p.accent_tint, 0)
            s.line(x + cw, 0, x + cw, h, 1, p.line)
            if c == self.resize_col:
                s.line(x + cw - 1, 0, x + cw - 1, h, 2, p.accent)  # the edge being dragged
        s.rect(0, 0, gut, head, p.raised, 0)  # (the gutter stays put when the grid scrolls sideways)
        s.rect(Float64(Int(0)), Float64(Int(head)), Float64(Int(w) - Int(0)), 1, p.line_strong, 0)
        var yes_no = List[Bool](capacity=ncols)  # columns of true/false: drawn as small pills, true green, false a quiet grey
        for c in range(ncols):
            yes_no.append(src.grid_badge(c) == "bool")
        # rows: the data only (the selection's wash, the gutter and the ring are layers of their own, so moving the
        # selection never touches the cells: a host keeps their nodes)
        var blk = self.block(src)  # the selected block (display indices, columns), or one cell
        var multi = self.has_block()
        var ring_top = -1.0  # the block's visible top and bottom (pixels), for the ring
        var ring_bottom = -1.0
        var row_ys = List[Float64]()  # each drawn row's top, its data row, and whether the selection covers it
        var row_ids = List[Int]()
        var row_sel = List[Bool]()
        var y = head
        var i = self.top
        var shown = 0
        while y < h and shown < 400:
            var row = self.shown_row(i, src)
            if row < 0:
                break
            var di = i  # this row's display index
            i += 1
            if not src.grid_alive(row):
                continue
            var base = y + 18 * k
            var in_rows = blk[0] <= di <= blk[1]
            if in_rows:
                if ring_top < 0:
                    ring_top = y
                ring_bottom = y + GRID_ROW_H * k
            row_ys.append(y)
            row_ids.append(row)
            row_sel.append(in_rows)
            for c in range(ncols):
                var x = lefts[c]
                var cw = widths[c]
                if x >= right:
                    break
                if x + cw <= gut:
                    continue
                cw = min(cw, right - x)
                var st = src.grid_style(c, row)
                var weight = p.medium if st.bold() else p.regular
                var room = cw - 16 * k - (3 * k if st.italic() else 0)
                var full = src.grid_text(c, row)
                var text = self.clip(full, room, 13 * k, weight, font)
                var color = p.formula if src.grid_formula(c) else p.ink  # (a read-only column that isn't a formula reads as data)
                if st.ink() > 0:
                    color = swatch(st.ink())
                if st.fill() > 0:
                    s.rect(x + 1, y + 1, cw - 1, GRID_ROW_H * k - 1, fill_over(p.card, st.fill()), 0)
                if src.grid_edited(c, row):  # changed this session: a small accent triangle in the corner
                    for r in range(Int(6 * k)):
                        s.rect(x + cw - 6 * k + Float64(r), y + Float64(r), 6 * k - Float64(r), 1, p.accent, 0)
                var align = st.align()
                if align == AUTO_ALIGN:
                    align = ALIGN_RIGHT if src.grid_numeric(c) else ALIGN_LEFT  # (numbers right, text left)
                var slant = ITALIC_SLANT if st.italic() else 0.0
                var tx = x + 8 * k  # where the text starts
                var needs_width = st.underline() or st.strike() or align != ALIGN_LEFT
                var tw = font.measure(text, 13 * k, weight) if needs_width else 0.0
                if align == ALIGN_CENTRE:
                    tx = x + (cw - tw) / 2
                elif align != ALIGN_LEFT:
                    tx = x + cw - 8 * k - tw - (3 * k if st.italic() else 0)
                if yes_no[c] and (text == "true" or text == "false") and st.ink() == 0:  # a yes/no pill
                    var good = text == "true"
                    var tone = p.good if good else p.ink3  # (false is quiet: a grey pill, not an alarm; D-996)
                    var pw = font.measure(text, 11.5 * k, p.medium) + 14 * k
                    var px = x + 8 * k if align == ALIGN_LEFT else (tx - 7 * k)
                    s.rect(px, y + 5 * k, pw, GRID_ROW_H * k - 10 * k, mix(p.card, tone, 0.12 if good else 0.08), (GRID_ROW_H * k - 10 * k) / 2)
                    s.text(font, text, px + 7 * k, base - 0.5 * k, 11.5 * k, tone, p.medium, LEFT, 0)
                    continue
                if text == "" and src.grid_numeric(c):  # an empty number: a faint dash where the figure would be
                    s.text(font, "–", x + cw - 16 * k, base, 13 * k, p.line_strong, p.regular, LEFT, 0)
                    continue
                var ax = tx  # (anchored where it's aligned: a host measuring with its own text engine lines it up there)
                var al = LEFT
                if align == ALIGN_CENTRE:
                    ax = x + cw / 2
                    al = CENTRE
                elif align != ALIGN_LEFT:
                    ax = x + cw - 8 * k - (3 * k if st.italic() else 0)
                    al = RIGHT
                var tight = text != full or (needs_width and tw > room - 3 * k)  # (another text engine's widths could spill a pixel or two: cut it to the cell)
                if tight:
                    s.push_clip(x + 1, y, cw - 2, GRID_ROW_H * k)
                s.text(font, text, ax, base, 13 * k, color, weight, al, slant)
                s.note("cell " + String(c) + " " + String(row))
                if st.bold():  # (Inter's medium is only a little heavier than regular: draw it again, a touch to the right)
                    s.text(font, text, ax + 0.6 * k, base, 13 * k, color, weight, al, slant)
                if tight:
                    s.pop_clip()
                if st.underline():
                    s.rect(tx, base + 2 * k, tw, max(1.0, k), color, 0)
                if st.strike():
                    s.rect(tx, base - 4.5 * k, tw, max(1.0, k), color, 0)
            y += GRID_ROW_H * k
            s.rect(Float64(Int(gut)), Float64(Int(y)), Float64(Int(right) - Int(gut)), 1, p.line, 0)
            shown += 1
        # the selection: a translucent wash over the cells it covers (the active cell stays clear), then the gutter
        s.begin_layer("selection")
        var wash = with_alpha(p.accent, 0.10)
        var span_l = max(lefts[blk[2]], gut) if 0 <= blk[2] < len(lefts) else gut
        var span_r = min(lefts[min(blk[3], len(lefts) - 1)] + widths[min(blk[3], len(lefts) - 1)], right) if 0 <= blk[2] < len(lefts) else right
        var act_l = -1.0
        var act_r = -1.0
        if 0 <= self.cur_col < len(lefts):
            act_l = max(lefts[self.cur_col], gut)
            act_r = min(lefts[self.cur_col] + widths[self.cur_col], right)
        for r in range(len(row_ys)):
            var ry = row_ys[r]
            var covered = (multi and row_sel[r]) or (not multi and row_ids[r] == self.cur_row)
            if covered:
                var l = span_l if multi else gut
                var rr = span_r if multi else right
                if row_ids[r] == self.cur_row and act_l >= 0 and act_l < rr and act_r > l:  # (around the active cell)
                    s.rect(l, ry + 1, act_l - l, GRID_ROW_H * k - 1, wash, 0)
                    s.rect(act_r, ry + 1, rr - act_r, GRID_ROW_H * k - 1, wash, 0)
                else:
                    s.rect(l, ry + 1, rr - l, GRID_ROW_H * k - 1, wash, 0)
            s.rect(0, ry, gut, GRID_ROW_H * k, p.accent_wash if row_sel[r] else p.card, 0)
            s.text(font, grouped(row_ids[r] + 1), (GRID_GUTTER - 10) * k, ry + 18 * k, 12 * k, p.accent if row_sel[r] else p.ink3, p.regular, RIGHT, 0)
            s.rect(0, Float64(Int(ry + GRID_ROW_H * k)), Float64(Int(gut)), 1, p.line, 0)
        s.line(gut, 0, gut, h, 1, p.line)
        s.begin_layer("ring")
        # the selection ring around the block (or the cell): it glides to where the selection went, on a spring
        if blk[2] >= 0 and ring_top >= 0 and blk[2] < len(lefts):
            var c1 = min(blk[3], len(lefts) - 1)
            var to: List[Float64] = [max(lefts[blk[2]], gut) / k, ring_top / k, (min(lefts[c1] + widths[c1], right) - max(lefts[blk[2]], gut)) / k, (ring_bottom - ring_top) / k]
            if self.glide(to^, s.still() or self.dragging):  # (a drag: the ring stays under the pointer; keys glide)
                s.set_again()  # mid-glide: the host draws the next frame too
            var rx = self.ring[0] * k
            var ry = self.ring[1] * k
            var rw = self.ring[2] * k
            var rh = self.ring[3] * k
            var t = 2 * k
            s.rect(rx, ry, rw, t, p.accent, 0)
            s.rect(rx, ry + rh - t, rw, t, p.accent, 0)
            s.rect(rx, ry, t, rh, p.accent, 0)
            s.rect(rx + rw - t, ry, t, rh, p.accent, 0)
            s.circle(rx + rw - 1, ry + rh - 1, 4 * k, p.card)  # the fill handle: a teal dot ringed in white
            s.circle(rx + rw - 1, ry + rh - 1, 3 * k, p.accent)
        else:
            self.ring = List[Float64]()
        # the scroll bar: a thin track, a thumb sized to the share of rows on screen (on top, as before the layers)
        s.begin_layer("bar")
        var t = self.thumb(h / k, src)
        s.rect(right, head, GRID_BAR_W * k, h - head, p.card, 0)
        s.rect(right + 3 * k, t[0] * k + 2 * k, (GRID_BAR_W - 6) * k, t[1] * k - 4 * k, p.ink3 if self.bar_drag else p.line_strong, 0)
