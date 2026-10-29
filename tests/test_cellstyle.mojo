# mojoui.cellstyle on a sheet (goal 21 M1): the grid draws each part of a cell's style (a fill, bold, italic,
# underline, strikethrough, a text colour, centred and right-aligned text) in the pixels; the sheet keeps a column's
# style and sparse cell overrides (a column's change reaches its overrides), Undo takes format changes and edits back
# in the order they were made, Clear formatting works on a cell and a column; a document keeps the styles (through a
# removed row before the styled cells and an added row after them) and the tabs' names.
#   scripts/mxbuild.sh tests/test_cellstyle.mojo -o build/test_cellstyle && build/test_cellstyle
from std.testing import assert_equal, assert_true, assert_false
from omxcore import Table, TEXT as MX_TEXT, DECIMAL as MX_DECIMAL
from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.theme import Palette
from themes.omarchy import omarchy_palette
from mojoui.datagrid import DataGrid
from mojoui.sheet import Sheet
from mojoui.numformat import ColumnFormat, CURRENCY
from mojoui.cellstyle import (CellStyle, BOLD, ITALIC, UNDERLINE, STRIKE, INK_MASK, FILL_MASK, ALIGN_MASK, ALL_PARTS, ink_bits,
                              fill_bits, align_bits, ALIGN_CENTRE, ALIGN_RIGHT, swatch, fill_over)
from mojoui.omxfile import save_omx, open_document
from mojoui.sheetpage import SheetObject
from mojoui.reportpage import ReportTile, ReportFilter
from mojoui.shared import make_dir

comptime RED = 1
comptime BLUE = 6
comptime W = 520
comptime H = 30 + 26 * 12


def table() raises -> Table:
    """12 rows of the same word and the same amount, so every row draws the same pixels unless its style differs."""
    var t = Table.empty()
    var name = t.add_column("name", MX_TEXT)
    var amount = t.add_column("amount", MX_DECIMAL, 2)
    _ = t.add_word(name, "Hello")
    for _ in range(12):
        t.append(name, 0)
        t.append(amount, 123456)
    return t^


struct Shot(Movable):
    """The grid drawn once; a cell's box and what its pixels show."""

    var px: List[UInt32]
    var card: UInt32
    var lefts: List[Int]
    var widths: List[Int]

    def __init__(out self, sheet: Sheet) raises:
        self.px = List[UInt32](length=W * H, fill=0)
        var s = Surface(Int(self.px.unsafe_ptr()), W, H, 1.0)
        var g = DataGrid()
        var pal = omarchy_palette()
        self.card = pal.card
        g.draw(s, sheet, Font(), pal)
        self.lefts = List[Int]()
        self.widths = List[Int]()
        for c in range(2):
            self.lefts.append(Int(g.col_left(c, sheet)))
            self.widths.append(Int(g.col_width(c, sheet)))

    def at(self, x: Int, y: Int) -> UInt32:
        return self.px[y * W + x] & 0x00FFFFFF

    def top(self, row: Int) -> Int:
        return 30 + row * 26  # (GRID_HEADER_H, GRID_ROW_H)

    def ink(self, c: Int, row: Int, bg: UInt32) -> Tuple[Int, Int, Int, Int]:
        """(pixels not the background, their leftmost x, their rightmost x, the middle x of the top half's ink minus
        the bottom half's ×10) inside cell (c, row), a pixel in from its edges."""
        var count = 0
        var lo = W
        var hi = -1
        var top_x = 0
        var top_n = 0
        var bottom_x = 0
        var bottom_n = 0
        var y0 = self.top(row) + 2
        var y1 = self.top(row) + 26 - 2
        for y in range(y0, y1):
            for x in range(self.lefts[c] + 2, self.lefts[c] + self.widths[c] - 2):
                if self.at(x, y) != (bg & 0x00FFFFFF):
                    count += 1
                    lo = min(lo, x)
                    hi = max(hi, x)
                    if y < self.top(row) + 11:
                        top_x += x
                        top_n += 1
                    elif y < self.top(row) + 18:
                        bottom_x += x
                        bottom_n += 1
        var lean = (top_x * 10 // max(top_n, 1)) - (bottom_x * 10 // max(bottom_n, 1))
        return (count, lo, hi, lean)

    def weight(self, c: Int, row: Int, bg: UInt32) -> Int:
        """How much ink cell (c, row) carries: the sum of every pixel's distance from the background (green)."""
        var total = 0
        var g0 = Int((bg >> 8) & 0xFF)
        for y in range(self.top(row) + 2, self.top(row) + 26 - 2):
            for x in range(self.lefts[c] + 2, self.lefts[c] + self.widths[c] - 2):
                total += abs(Int((self.at(x, y) >> 8) & 0xFF) - g0)
        return total

    def run(self, c: Int, row: Int, bg: UInt32) -> Int:
        """The longest unbroken stretch of ink across the cell on any of its lines (a rule drawn through the text)."""
        var best = 0
        for y in range(self.top(row) + 2, self.top(row) + 26 - 2):
            var n = 0
            for x in range(self.lefts[c] + 2, self.lefts[c] + self.widths[c] - 2):
                if self.at(x, y) != (bg & 0x00FFFFFF):
                    n += 1
                    best = max(best, n)
                else:
                    n = 0
        return best

    def has(self, c: Int, row: Int, color: UInt32) -> Bool:
        for y in range(self.top(row) + 2, self.top(row) + 26 - 2):
            for x in range(self.lefts[c] + 2, self.lefts[c] + self.widths[c] - 2):
                if self.at(x, y) == (color & 0x00FFFFFF):
                    return True
        return False

    def line_under(self, c: Int, row: Int, y: Int, bg: UInt32) -> Int:
        """How many pixels across the cell, on line y of the row, aren't the background."""
        var n = 0
        for x in range(self.lefts[c] + 2, self.lefts[c] + self.widths[c] - 2):
            if self.at(x, self.top(row) + y) != (bg & 0x00FFFFFF):
                n += 1
        return n


def main() raises:
    # ---- the pixels: row 0 is plain; each other row changes one part ----
    var sheet = Sheet(table().share(), False)
    sheet.restyle(0, 1, FILL_MASK, fill_bits(BLUE))
    sheet.restyle(0, 2, BOLD, BOLD)
    sheet.restyle(0, 3, ITALIC, ITALIC)
    sheet.restyle(0, 4, UNDERLINE, UNDERLINE)
    sheet.restyle(0, 5, STRIKE, STRIKE)
    sheet.restyle(0, 6, INK_MASK, ink_bits(RED))
    sheet.restyle(0, 7, ALIGN_MASK, align_bits(ALIGN_CENTRE))
    sheet.restyle(0, 8, ALIGN_MASK, align_bits(ALIGN_RIGHT))
    sheet.restyle(1, 9, ALIGN_MASK, align_bits(ALIGN_CENTRE))  # (a number, centred)
    var shot = Shot(sheet)
    var plain = shot.ink(0, 0, shot.card)
    assert_true(plain[0] > 20, "the plain cell shows its text")
    var fill = fill_over(shot.card, BLUE)
    assert_equal(shot.at(shot.lefts[0] + shot.widths[0] - 6, shot.top(1) + 4), fill & 0x00FFFFFF)  # (a corner: no text there)
    assert_equal(shot.at(shot.lefts[0] + shot.widths[0] - 6, shot.top(0) + 4), shot.card & 0x00FFFFFF)
    var bold = shot.weight(0, 2, shot.card)
    var regular = shot.weight(0, 0, shot.card)
    assert_true(bold > regular + regular // 5, "bold has more ink: " + String(bold) + " vs " + String(regular))
    var italic = shot.ink(0, 3, shot.card)
    assert_true(italic[3] > plain[3] + 8, "italic leans right at the top: " + String(italic[3]) + " vs " + String(plain[3]))
    var under = shot.line_under(0, 4, 20, shot.card)
    assert_true(under >= 25 and shot.line_under(0, 0, 20, shot.card) == 0, "underlined: " + String(under))
    var strike = shot.run(0, 5, shot.card)
    assert_true(strike >= 25 and shot.run(0, 0, shot.card) < 12, "struck through: " + String(strike) + " vs " + String(shot.run(0, 0, shot.card)))
    assert_true(shot.has(0, 6, swatch(RED)) and not shot.has(0, 0, swatch(RED)), "red text")
    var centred = shot.ink(0, 7, shot.card)
    var right = shot.ink(0, 8, shot.card)
    assert_true(centred[1] > plain[1] + 10 and right[1] > centred[1] + 10, "left < centred < right: " + String(plain[1]) + " " + String(centred[1]) + " " + String(right[1]))
    assert_true(right[2] >= shot.lefts[0] + shot.widths[0] - 12, "right-aligned text ends at the cell's right")
    var number = shot.ink(1, 0, shot.card)
    var number_centred = shot.ink(1, 9, shot.card)
    assert_true(number_centred[1] < number[1] - 5, "a centred number moves left from the right")
    print("PIXELS: fill, bold, italic, underline, strikethrough, red, centred and right drawn")

    # ---- the sheet: column styles reach overrides; Undo in order; Clear formatting ----
    var s = Sheet(table().share(), False)
    s.restyle(1, 3, BOLD, BOLD)
    assert_true(s.style_of(1, 3).bold() and not s.style_of(1, 2).bold())
    s.restyle(1, -1, FILL_MASK, fill_bits(BLUE))  # the column: its cells and the override
    assert_equal(s.style_of(1, 2).fill(), BLUE)
    assert_equal(s.style_of(1, 3).fill(), BLUE)
    assert_true(s.style_of(1, 3).bold())
    s.restyle(1, -1, BOLD, BOLD)  # the override is now the column's own: it goes
    assert_equal(len(s.cell_styles), 0)
    assert_true(s.undo())  # back: the override returns, the column isn't bold
    assert_equal(len(s.cell_styles), 1)
    assert_false(s.style_of(1, 2).bold())
    assert_true(s.style_of(1, 3).bold())
    s.set_text(1, 0, "5.00")  # an edit after the format changes...
    s.restyle(0, 0, ITALIC, ITALIC)  # ...and a format change after it
    assert_true(s.undo())
    assert_false(s.style_of(0, 0).italic())
    assert_equal(s.display(1, 0), "5.00")
    assert_true(s.undo())  # the edit
    assert_equal(s.display(1, 0), "1234.56")
    assert_true(s.undo())  # the column's fill
    assert_equal(s.style_of(1, 2).fill(), 0)
    assert_true(s.undo())  # the cell's bold
    assert_true(s.style_of(1, 3).plain())
    s.change_format(1, ColumnFormat(CURRENCY, -1, True, False, "$"))
    assert_equal(s.display(1, 0), "$1,234.56")
    s.restyle(1, -1, BOLD, BOLD)
    s.restyle(1, 4, INK_MASK, ink_bits(RED))
    s.clear_style(1, 4)  # the cell: plain, though its column is bold
    assert_true(s.style_of(1, 4).plain())
    s.clear_style(1, -1)  # the column: its style, its number format, its cells
    assert_true(s.style_of(1, 2).plain())
    assert_equal(s.display(1, 0), "1234.56")
    assert_equal(len(s.cell_styles), 0)
    assert_true(s.undo())  # one step back: bold and $ again
    assert_true(s.style_of(1, 2).bold())
    assert_equal(s.display(1, 0), "$1,234.56")
    print("SHEET: column styles reach their overrides; undo follows the order of changes; clear formatting")

    # ---- a document keeps them, and the tabs' names ----
    make_dir("build/cellstyle")
    var d = Sheet(table().share(), False)
    d.restyle(0, -1, BOLD, BOLD)
    d.restyle(1, 5, FILL_MASK | INK_MASK, fill_bits(BLUE) | ink_bits(RED))
    d.restyle(0, 11, ITALIC, ITALIC)
    d.frame.remove(2)  # (a removed row before the styled cells: they move up one when saved)
    var added = d.append()  # (and an added row, styled: saved after the table's own rows)
    d.set_text(0, added, "Hello")
    d.set_text(1, added, "1.00")
    d.restyle(1, added, UNDERLINE, UNDERLINE)
    var tabs: List[String] = ["Orders 2025", "Board view"]
    var path = "build/cellstyle/styled.omx"
    save_omx(path, d, List[SheetObject](), List[ReportTile](), ReportFilter(-1, 0), tabs)
    var objects = List[SheetObject]()
    var tiles = List[ReportTile]()
    var filter = ReportFilter(-1, 0)
    var names = List[String]()
    var back = open_document(path, objects, tiles, filter, names)
    assert_equal(back.rows(), 12)
    assert_true(back.column_style(0).bold())
    assert_equal(back.style_of(1, 4).fill(), BLUE)
    assert_equal(back.style_of(1, 4).ink(), RED)
    assert_true(back.style_of(1, 3).plain())
    assert_true(back.style_of(0, 10).italic() and back.style_of(0, 10).bold())
    assert_equal(back.display(1, 11), "1.00")  # (the added row, last)
    assert_true(back.style_of(1, 11).underline())
    assert_equal(len(back.cell_styles), 3)
    assert_equal(len(names), 2)
    assert_equal(names[0], "Orders 2025")
    assert_equal(names[1], "Board view")
    print("FILE: styles and tab names survive save and open")
    print("CELL STYLE TESTS PASSED")
