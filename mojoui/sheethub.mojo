# mojoui.sheethub: a Hub of MX frame sheets (goal 48 M5): datasets an app holds, named by its agent's UI and never
# sent. A chart's numbers are MX frame's group-by (Sheet.totals: the GPU copy when there is one); a grid draws the
# sheet a screenful at a time, whatever its size.
#
#   var hub = SheetHub()
#   hub.add("orders", Sheet(table^.share(), True))
#   var chat = AgentChat[SheetHub](url, …); chat.set_hub(hub^)

from std.memory import ArcPointer
from mojoui.datahub import Hub, Grouped
from mojoui.datagrid import DataGrid
from mojoui.sheet import Sheet, TEXT
from mojoui.numformat import grouped
from mojoui.json import json_string
from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.theme import Palette
from mojoui.app import Event
from omxcore import col


struct SheetHub(Hub):
    var names: List[String]
    var sheets: List[ArcPointer[Sheet]]  # (copies of the hub share the sheets)

    def __init__(out self):
        self.names = List[String]()
        self.sheets = List[ArcPointer[Sheet]]()

    def add(mut self, name: String, var sheet: Sheet):
        self.names.append(name)
        self.sheets.append(ArcPointer(sheet^))

    def find(self, name: String) -> Int:
        for k in range(len(self.names)):
            if self.names[k] == name:
                return k
        return -1

    def names_text(self) -> String:
        var out = String("")
        for nm in self.names:
            out += (", " if out.byte_length() > 0 else "") + nm
        return out if out.byte_length() > 0 else String("none")

    def name(self, k: Int) -> String:
        return self.names[k]

    def rows(self, k: Int) -> Int:
        return self.sheets[k][].rows()

    def describe(self) -> String:
        var out = String("[")
        for k in range(len(self.names)):
            ref sh = self.sheets[k][]
            var cols = String("[")
            for c in range(sh.columns()):
                cols += ("," if c > 0 else "") + '{"name":' + json_string(sh.name(c)) + ',"kind":"' + ("text" if sh.kind(c) == TEXT else "number") + '"}'
            out += ("," if k > 0 else "") + '{"name":' + json_string(self.names[k]) + ',"rows":' + String(sh.rows()) + ',"columns":' + cols + "]}"
        return out + "]"

    def group(self, k: Int, group_by: String, value: String, how: String, top: Int) -> Grouped:
        var none = List[String]()
        ref sh = self.sheets[k][]
        var g = sh.index(group_by)
        var v = sh.index(value) if value.byte_length() > 0 else -1
        if g < 0 or sh.kind(g) != TEXT:
            return Grouped(none^, List[Float64](), "", "group_by must be a text column of " + json_string(self.names[k]))
        if v < 0 and how != "count":
            return Grouped(none^, List[Float64](), "", "value must be a number column of " + json_string(self.names[k]) + " (or combine: count)")
        if v >= 0 and sh.kind(v) == TEXT:
            return Grouped(none^, List[Float64](), "", "value must be a number column, not the text column " + json_string(value))
        var groups = sh.word_count(g)
        try:
            var sums = sh.totals(v if v >= 0 else g, col(sh.name(g)), groups)
            var scale = 1.0
            if v >= 0:
                for _ in range(sh.scale(v)):
                    scale *= 10.0
            var labels = List[String]()
            var values = List[Float64]()
            for i in range(groups):
                if sums.counts[i] == 0:
                    continue
                var x = Float64(sums.counts[i]) if how == "count" else (Float64(sums.sums[i]) / scale if how == "sum" else Float64(sums.sums[i]) / scale / Float64(max(sums.present[i], 1)))
                labels.append(sh.text_of(g, Int64(i)))
                values.append(x)
            var order = List[Int]()  # (largest first: a handful of groups, a plain sort)
            for i in range(len(values)):
                order.append(i)
            for a in range(len(order)):
                for b in range(a + 1, len(order)):
                    if values[order[b]] > values[order[a]]:
                        var t = order[a]
                        order[a] = order[b]
                        order[b] = t
            var ls = List[String]()
            var vs = List[Float64]()
            for i in range(min(top, len(order))):
                ls.append(labels[order[i]])
                vs.append(values[order[i]])
            var tenths = Int(sums.milliseconds * 10.0 + 0.5)
            var note = grouped(sh.rows()) + " rows · " + String(tenths // 10) + "." + String(tenths % 10) + " ms on the " + ("GPU" if sums.on_gpu else "CPU")
            return Grouped(ls^, vs^, note, "")
        except e:
            return Grouped(none^, List[Float64](), "", "the dataset couldn't be read: " + String(e))

    def draw_grid(self, k: Int, mut grid: DataGrid, mut s: Surface, font: Font, p: Palette):
        grid.draw(s, self.sheets[k][], font, p)

    def handle_grid(self, k: Int, mut grid: DataGrid, e: Event, font: Font, p: Palette):
        _ = grid.handle(e, self.sheets[k][], font, p)
