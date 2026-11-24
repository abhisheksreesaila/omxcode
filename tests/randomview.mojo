# Random screens for goal 81's "patched = fresh" tests (test_diff_random, test_gtk_random). A screen is a pure function of
# (seed, epoch): every choice (kind, text, size, order, presence…) keeps its base value most epochs and takes another in
# some, so two epochs of one seed differ as an app's screens do: a text here, a row gone there, two cards swapped.
from mojoui import *
from mojoui.view import TableGrid, ICON_ON
from mojoui.dragdrop import Draggable, DropTarget
from mojoui.paragraph import Run, Plain, Bold, Link, Paragraph


def mix(a: Int, b: Int) -> Int:
    var x = (UInt64(a) ^ (UInt64(b) * 0x9E3779B97F4A7C15)) + 0xD1B54A32D192ED03
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9
    x = (x ^ (x >> 27)) * 0x94D049BB133111EB
    return Int((x ^ (x >> 31)) & 0x7FFFFFFFFFFFFFFF)


struct Gen:
    var epoch: Int
    var level: Int  # 0: everything the diff knows; 1: what a headless GTK window can show without opening anything
    var tags: Int
    var budget: Int
    var calm: Int  # how many times rarer a change is

    def __init__(out self, epoch: Int, level: Int, calm: Int = 1):
        self.calm = calm
        self.epoch = epoch
        self.level = level
        self.tags = 0
        self.budget = 120

    def pick(self, path: Int, what: Int, n: Int, often: Int) -> Int:
        """0..n-1 for this choice: its base value, or in one epoch of `often` another one."""
        var p = mix(path, what)
        var e = mix(p, self.epoch + 1)
        if e % (often * self.calm) == 0:
            return mix(e, 7) % n
        return mix(p, 3) % n

    def words(self, path: Int, what: Int) -> String:
        var w = self.pick(path, what, 6, 6)
        return ["Alpha", "Beta two", "Gamma & <b>", "", "Délta é", "A longer line of words that may wrap"][w]

    def options(self, path: Int) -> List[String]:
        var out = List[String]()
        for k in range(2 + self.pick(path, 40, 3, 12)):
            out.append("Choice " + String(k))
        return out^

    def children(mut self, path: Int, depth: Int, most: Int) -> List[View]:
        var out = List[View]()
        var n = self.pick(path, 1, most + 1, 15)
        for s in range(n):
            if self.pick(path, 100 + s, 5, 8) == 0:  # gone
                continue
            out.append(self.view(mix(path, 1000 + s), depth + 1))
        if self.pick(path, 2, 8, 10) == 0 and len(out) > 1:  # reordered
            var a = self.pick(path, 3, len(out), 3)
            var b = self.pick(path, 4, len(out), 3)
            if a != b:
                var x = out.pop(a)
                out.insert(min(b, len(out)), x^)
        return out^

    def leaf(mut self, path: Int) -> View:
        var kind = self.pick(path, 10, 22, 14)
        var v = self.pick(path, 11, 101, 4)
        var msg = 1 + self.pick(path, 12, 5, 6)
        if kind <= 3:
            var t = Text(self.words(path, 13), self.pick(path, 14, 4, 12))
            if self.pick(path, 15, 4, 6) == 0:
                t = t^.tone(1 + self.pick(path, 16, 4, 5))
            return t^
        if kind <= 5:
            var styles: List[Int] = [PLAIN, PROMINENT, DESTRUCTIVE, SUBTLE, ICON_ONLY, TOOL, TOOL_ON, ICON_ON, TOOL_INLINE]
            var icons: List[String] = ["", "add", "search", "settings"]
            var st = styles[self.pick(path, 17, len(styles), 10)]
            var icon = icons[self.pick(path, 18, 4, 14)]
            if icon == "" and st >= ICON_ONLY:
                icon = "add"
            return Button(self.words(path, 13) + "!", msg, st, icon)
        if kind == 6:
            return TextField(self.words(path, 13), self.words(path, 19) if self.pick(path, 20, 3, 9) == 0 else String("hint"), msg, msg + 1 if self.pick(path, 21, 2, 20) == 0 else 0)
        if kind == 7:
            return Toggle(self.words(path, 13), v % 2 == 0, msg)
        if kind == 8:
            var o = self.options(path)
            return Dropdown(o, v % len(o), msg)
        if kind == 9:
            return Slider(v, msg)
        if kind == 10:
            return ProgressBar(v)
        if kind == 11:
            return Divider()
        if kind == 12:
            return Spacer()
        if kind == 13:
            var w = 2 + self.pick(path, 22, 2, 12)
            var px = List[UInt32](length=w * 2, fill=0xFF000000 | UInt32(v * 1000))
            return Image(px, w, 2, msg if self.pick(path, 23, 2, 20) == 0 else 0)
        if kind == 14:
            var o = self.options(path)
            return Segmented(o, v % len(o), msg)
        if kind == 15:
            var o = self.options(path)
            return Radio(o, v % len(o), msg)
        if kind == 16:
            return TextArea(self.words(path, 13), "hint", msg, 60 + 20 * self.pick(path, 24, 2, 12))
        if kind == 17:
            return DatePicker("2026-11-" + String(10 + v % 15), msg)
        if kind == 18:
            return Icon(["add", "search", "settings"][self.pick(path, 25, 3, 6)], 16 + 8 * self.pick(path, 26, 2, 12))
        if kind == 19:
            return LazyList(3 + v, 1 + self.pick(path, 27, 3, 12), msg, 120, 30)
        if kind == 20:
            var runs: List[Run] = [Plain(self.words(path, 13) + " "), Bold("bold")]
            if self.pick(path, 28, 2, 6) == 0:
                runs.append(Link("link", "https://example.com/" + String(v % 3)))
            return Paragraph(runs, on_link=msg)
        return Canvas(self.pick(path, 29, 2, 12), v, msg, on_frame=0, keys=self.pick(path, 30, 2, 15) == 0).width(60).height(40)

    def view(mut self, path: Int, depth: Int) -> View:
        self.budget -= 1
        var v: View
        var kind = self.pick(path, 50, 14, 18)
        if depth >= 4 or self.budget < 0 or (depth > 0 and kind < 5):
            v = self.leaf(path)
        elif kind <= 7:
            v = VStack(self.children(path, depth, 5), spacing=4 * self.pick(path, 51, 3, 12))
        elif kind == 8:
            var row = self.children(path, depth, 5)
            if self.pick(path, 49, 4, 5) == 0:  # (equal shares: every child grows)
                for k in range(len(row)):
                    row[k] = row[k].copy().grow()
            v = HStack(row, spacing=4 * self.pick(path, 51, 3, 12))
        elif kind == 9:
            v = Card(self.children(path, depth, 4), tone=self.pick(path, 52, 3, 8) + 1)
        elif kind == 10:
            v = Grid(self.children(path, depth, 6), 1 + self.pick(path, 53, 3, 10), fit=self.pick(path, 54, 2, 15) == 0)
        elif kind == 11:
            var inner = VStack(self.children(path, depth, 5))
            v = Scroll(inner, 80 + 40 * self.pick(path, 55, 2, 10))
        elif kind == 12:
            var items = List[View]()
            var kids = self.children(path, depth, 4)
            var tones = List[Int]()
            for k in range(len(kids)):
                items.append(kids[k].copy().at(10 * self.pick(path, 60 + k, 20, 3), 10 * self.pick(path, 70 + k, 20, 3)).width(80 + 10 * self.pick(path, 80 + k, 3, 4)).height(60))
                tones.append(self.pick(path, 90 + k, 5, 4) if self.pick(path, 89, 2, 4) == 0 else 0)
            v = Board(items, 400 + 50 * self.pick(path, 56, 2, 5), 300, 3, 4, tones=tones)
        else:
            var n = 1 + self.pick(path, 57, 3, 8)
            var cells = List[View]()
            for c in range(2):
                cells.append(Text("Head " + String(c)))
            var sel = String("")
            for r in range(n):
                sel += "1" if self.pick(path, 58 + r, 3, 3) == 0 else "0"
                for c in range(2):
                    cells.append(Text(self.words(mix(path, 500 + r * 2 + c), 13)))
            v = TableGrid(cells^, 2, "LR", sel)
        var layout = self.pick(path, 59, 12, 14)
        if layout == 0:
            v = v^.padding(2 * self.pick(path, 61, 4, 5))
        elif layout == 1:
            v = v^.width(100 + 20 * self.pick(path, 62, 4, 3))
        elif layout == 2:
            v = v^.max_width(120 + 20 * self.pick(path, 62, 4, 3))
        elif layout == 3:
            v = v^.grow()
        elif layout == 4:
            v = v^.fill()
        elif layout == 5:
            v = v^.height(40 + 10 * self.pick(path, 63, 4, 3))
        elif layout == 6:
            v = v^.align(START)
        elif layout == 7:
            v = v^.tooltip(self.words(path, 64))
        elif layout == 8 and (v.nodes[0].kind == VSTACK or v.nodes[0].kind == HSTACK):
            v = v^.justify(BETWEEN)
        if self.pick(path, 65, 3, 25) == 0:  # (a tag: often its own, sometimes one another view has too)
            v = v^.tag("t" + String(path % 97))
        return v^


def random_screen(seed: Int, epoch: Int, level: Int) -> View:
    var g = Gen(epoch, level, [1, 8, 30][seed % 3])
    var kids = List[View]()
    for s in range(6):
        if g.pick(mix(seed, 5), 200 + s, 6, 7) > 0:
            kids.append(g.view(mix(seed, 300 + s), 1))
    if level == 0:
        var extra = g.pick(mix(seed, 6), 1, 8, 4)
        if extra == 0:
            kids.append(Dialog(g.words(seed, 2), VStack(g.children(mix(seed, 7), 2, 3)), 9))
        elif extra == 1:
            kids.append(Toast(g.words(seed, 3) + ".", "Undo", 8, 9))
        elif extra == 2:
            kids.append(MenuBar([Menu("File", [Item(g.words(seed, 4) + "?", 5), Item("Close", 6, checked=g.pick(seed, 9, 2, 3) == 0)])]))
        elif extra == 3:
            kids.append(Draggable(Text(g.words(seed, 5)), g.words(seed, 6)))
        elif extra == 4:
            kids.append(DropTarget(Text(g.words(seed, 5)), 7))
        elif extra == 5:
            kids.append(NavBar(g.words(seed, 5), 4 if g.pick(seed, 8, 2, 4) == 0 else 0))
    return VStack(kids^).grow().fill()
