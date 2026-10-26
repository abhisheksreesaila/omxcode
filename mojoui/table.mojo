# mojoui.table: rows and columns that size to their content, as a list of models or keys reads (the console's model
# table, omxqua's .tbl). A real table on the web (<table>: the browser's own column widths, D-340), a GtkGrid on GTK, rows
# of stacks on the Mac. Its header cells wear the framework role "table-head" and its body cells "table-cell" (themes
# give them type, padding and rules; tag="table-head" and tag="table-cell" are those roles), a selected row the
# theme's selection tint.
#
#   Table(["Model", "Size"], [Text("qwen"), Text("988 MB"), Text("llama"), Text("2.5 GB")], align="LR",
#         ticked=self.ticked, on_tick=TICK, on_tick_all=TICK_ALL)

from mojoui.view import View, Text, TableGrid, NO_MSG
from mojoui.overlays import Checkbox

comptime HEAD_ROLE = "table-head"  # the header's cells (tag="table-head")
comptime CELL_ROLE = "table-cell"  # the body's cells (tag="table-cell")


def capitals(s: String) -> String:
    """ASCII letters in capitals (a header reads MODEL, omxqua's .tbl th: text-transform uppercase)."""
    var out = String("")
    for c in s.codepoint_slices():
        var o = ord(c)
        out += chr(o - 32) if 97 <= o <= 122 else String(c)
    return out


def Table(columns: List[String], cells: List[View], align: String = "", ticked: List[Bool] = [], on_tick: Int = NO_MSG,
          on_tick_all: Int = NO_MSG, selected: List[Bool] = [], dense: Bool = False, fit: String = "", compact: Bool = False) -> View:
    """A table: `columns` are the header's titles (shown in capitals), `cells` the body row by row, len(columns) a row
    (a short last row is filled with blanks). `align`: one letter per column, L or R (R: figures, right-aligned, mono).
    With `on_tick`: a first column of tick boxes; row r's sends on_tick + r (event.number = 1 ticked, 0 not), tagged
    "tick-<r>"; the header's box (tagged "tick-all") sends on_tick_all and is ticked when every row is. Ticked rows
    are shown selected; without ticks, `selected` says which rows are. `dense`: the dense cells (roles table-dense-head,
    table-dense-cell over the plain ones), each on one line cut at the theme's widest (role table-cut's width); `fit`:
    one letter per column: C (the default) cut there, W its cells wrap, N a name over a second line (cut at role
    table-cut-name's width, the cells snug to the rules: role table-dense-snug); `compact`: a dense table on a phone
    (roles table-dense-compact-head, table-dense-compact-cell over the dense ones; table-cut-compact, table-cut-name-compact)."""
    var ticks = on_tick != NO_MSG
    var n = len(columns)
    var rows = (len(cells) + n - 1) // n if n > 0 else 0
    var all: List[View] = []
    var a = String("")
    if ticks:
        var every = rows > 0
        for r in range(rows):
            if r >= len(ticked) or not ticked[r]:
                every = False
        all.append(Checkbox("", every, on_tick_all).tag("tick-all"))
        a += "L"
    for k in range(n):
        all.append(Text(capitals(columns[k])))
        a += String(align[byte=k]) if k < align.byte_length() else String("L")
    var limits: List[String] = []
    if dense:
        if ticks:
            limits.append("T")  # (the tick column: as narrow as its box)
        for k in range(n):
            var f = String(fit[byte=k]) if k < fit.byte_length() else String("C")
            limits.append(f if f == "W" or f == "N" else String("C"))  # (the runtime puts the theme's widths in: mojoui.look.resolve_layout)
    var mask = String("")
    for r in range(rows):
        var on = (r < len(ticked) and ticked[r]) if ticks else (r < len(selected) and selected[r])
        mask += "1" if on else "0"
        if ticks:
            all.append(Checkbox("", r < len(ticked) and ticked[r], on_tick + r).tag("tick-" + String(r)))
        for k in range(n):
            var i = r * n + k
            all.append(cells[i].copy() if i < len(cells) else Text(""))
    return TableGrid(all^, n + (1 if ticks else 0), a, mask, dense, limits^, compact=compact and dense)
