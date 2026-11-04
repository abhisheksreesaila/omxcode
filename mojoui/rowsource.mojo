# mojoui.rowsource: a DataGrid source over plain rows of text (goal 48): a small table handed over as data (an agent's
# render_ui, a test, a preview) without an engine. Read-only; numbers right-aligned.
#
#   var rows = Rows(["city", "trips"], [False, True])
#   rows.add(["Lisbon", "12"])
#   grid.draw(surface, rows, font, palette)

from mojoui.datagrid import GridSource


struct Rows(Copyable, Movable, GridSource):
    var names: List[String]
    var numeric: List[Bool]
    var cells: List[String]  # row-major: row r, column c at r * len(names) + c

    def __init__(out self, var names: List[String], var numeric: List[Bool]):
        self.names = names^
        self.numeric = numeric^
        while len(self.numeric) < len(self.names):
            self.numeric.append(False)
        self.cells = List[String]()

    def add(mut self, row: List[String]):
        """One row (missing cells blank, extra ones dropped)."""
        for c in range(len(self.names)):
            self.cells.append(row[c] if c < len(row) else String(""))

    def grid_rows(self) -> Int:
        return len(self.cells) // max(len(self.names), 1)

    def grid_alive(self, row: Int) -> Bool:
        return True

    def grid_columns(self) -> Int:
        return len(self.names)

    def grid_name(self, c: Int) -> String:
        return self.names[c]

    def grid_numeric(self, c: Int) -> Bool:
        return self.numeric[c]

    def grid_editable(self, c: Int) -> Bool:
        return False

    def grid_formula(self, c: Int) -> Bool:
        return False

    def grid_text(self, c: Int, row: Int) -> String:
        var i = row * len(self.names) + c
        return self.cells[i] if i >= 0 and i < len(self.cells) else String("")

    def grid_type_width(self, c: Int) -> Float64:
        if self.numeric[c]:
            return 90.0
        var longest = 4
        for r in range(min(self.grid_rows(), 200)):
            longest = max(longest, self.grid_text(c, r).byte_length())
        return Float64(min(longest, 32)) * 7.5 + 20.0

    def grid_badge(self, c: Int) -> String:
        return "#" if self.numeric[c] else "Aa"

    def grid_edited(self, c: Int, row: Int) -> Bool:
        return False
