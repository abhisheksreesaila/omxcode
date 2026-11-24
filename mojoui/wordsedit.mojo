# mojoui.wordsedit (goal 79, docs/goals/79-gaps.md 32): the words of one box edited in place (a canvas text, a sticky): caret,
# selection, words, copy and cut, undo, an input method's composition, up and down by shown lines, the pointer. The text is
# mojoui.textedit's TextEdit; the lines are broken as the board breaks them (at spaces, the space not drawn), so what is
# edited lies where it will stand. One type style for the whole box.
#
#   var w = WordsEdit(); w.begin("words", TextStyle(…), width)
#   w.key("ArrowDown", SHIFT, now_ms())           # 0 not a key of its, 1 used, 2 used and the words changed
#   w.press(x, y, row, shift); w.drag(x, y, row)  # relative to the words' top left, in the style's own px
#   w.paint(p, x, top, row, base, scale, style_on_screen, colour, words=True)

from mojoui.fonttext import TextStyle, measure
from mojoui.graphemes import next_grapheme
from mojoui.scene import Painter
from mojoui.textedit import TextEdit, Pos, SHIFT, CTRL, ALT, is_word_byte

comptime SELECTION: UInt32 = 0x59FF8B4D  # (a blue, 35 %)


@fieldwise_init
struct WordsLine(Copyable, Movable, ImplicitlyCopyable):
    """A shown line: the bytes [start, end) of its paragraph (the space it broke at belongs to none)."""
    var para: Int
    var start: Int
    var end: Int


struct WordsEdit(Movable):
    var ed: TextEdit
    var style: TextStyle
    var width: Float64
    var lines: List[WordsLine]
    var laid: Int  # the text's version the lines are of
    var preedit: String
    var goal_x: Float64
    var at_end: Bool
    var centered: Bool  # each line in the middle of the width
    var wrap: Bool  # lines broken at the width (False: a paragraph is a line however long)

    def __init__(out self):
        self.ed = TextEdit()
        self.style = TextStyle("Geist", 400, False, 16)
        self.width = 100
        self.lines = List[WordsLine]()
        self.laid = -1
        self.preedit = ""
        self.goal_x = -1
        self.at_end = False
        self.centered = False
        self.wrap = True

    def begin(mut self, words: String, style: TextStyle, width: Float64):
        """Starts editing: the caret at the end, nothing to undo."""
        var clip = self.ed.clip
        var clips = self.ed.clip_version
        self.ed.set_text(words)
        self.ed.clip = clip
        self.ed.clip_version = clips
        self.style = style
        self.width = width
        self.laid = -1
        self.preedit = ""
        var last = len(self.ed.paras) - 1
        self.ed.move_to(Pos(last, self.ed.paras[last].byte_length()), False)
        self.ed.history.clear()
        self.goal_x = -1
        self.at_end = False

    def text(self) -> String:
        return self.ed.text()

    def lay(mut self):
        """The shown lines: each paragraph broken at the last space that fits (BoardLook.lines' rule)."""
        if self.laid == self.ed.version:
            return
        self.laid = self.ed.version
        self.lines.clear()
        for para in range(len(self.ed.paras)):
            ref t = self.ed.paras[para]
            var start = 0
            var at = 0  # the end of the words taken onto this line
            var first = True
            var pos = 0
            for wd in t.split(" "):
                var n = String(wd).byte_length()
                var end = pos + n
                if self.wrap and not first and measure(self.style, String(t[byte=start:end])) > self.width + 0.01:
                    self.lines.append(WordsLine(para, start, at))
                    start = pos
                at = end
                first = False
                pos = end + 1
            self.lines.append(WordsLine(para, start, at))

    def line_of(mut self, p: Pos, at_end: Bool) -> Int:
        self.lay()
        var found = 0
        for k in range(len(self.lines)):
            if self.lines[k].para == p.para and (p.byte > self.lines[k].start or (p.byte == self.lines[k].start and not (at_end and p.byte > 0 and k > 0 and self.lines[k - 1].para == p.para and self.lines[k - 1].end == p.byte))):
                found = k
        for k in range(len(self.lines)):  # (a paragraph's first line, for its byte 0)
            if self.lines[k].para == p.para and found < k and self.lines[found].para != p.para:
                found = k
        return found

    def indent(self, k: Int) -> Float64:
        """How far in line k starts."""
        if not self.centered:
            return 0
        var l = self.lines[k]
        return (self.width - measure(self.style, String(self.ed.paras[l.para][byte=l.start:l.end]))) / 2

    def x_of(mut self, p: Pos, k: Int) -> Float64:
        var l = self.lines[k]
        return self.indent(k) + measure(self.style, String(self.ed.paras[l.para][byte=l.start:max(min(p.byte, l.end), l.start)]))

    def byte_at(mut self, k: Int, x_in: Float64) -> Int:
        var l = self.lines[k]
        var x = x_in - self.indent(k)
        var best = l.start
        var best_d = abs(x)
        var i = l.start
        while i < l.end:
            i = next_grapheme(self.ed.paras[l.para], i)
            var d = abs(x - measure(self.style, String(self.ed.paras[l.para][byte=l.start:i])))
            if d < best_d:
                best_d = d
                best = i
        return best

    def key(mut self, name: String, mods: Int, now: Int) -> Int:
        var shift = (mods & SHIFT) != 0
        var plain = (mods & (CTRL | ALT)) == 0
        var version = self.ed.version
        if plain and (name == "ArrowUp" or name == "ArrowDown"):
            self.vertical(1 if name == "ArrowDown" else -1, shift)
            return 1
        if plain and (name == "Home" or name == "End"):
            var c = self.ed.caret
            var k = self.line_of(c, self.at_end)
            var l = self.lines[k]
            self.ed.move_to(Pos(l.para, l.end if name == "End" else l.start), shift)
            self.at_end = name == "End"
            self.goal_x = -1
            return 1
        if name == "Tab" or ((mods & CTRL) != 0 and (name == "v" or name == "V")):  # (a paste comes from the host as text)
            return 0
        var r = self.ed.edit_key("Enter" if name == "Return" else ("Backspace" if name == "BackSpace" else name), mods, now)
        if not r:
            return 0
        self.at_end = False
        self.goal_x = -1
        return 2 if self.ed.version != version else 1

    def insert(mut self, words: String, now: Int):
        """Words from an input method or a paste, over the selection."""
        self.ed.insert(words, now)
        self.at_end = False
        self.goal_x = -1

    def vertical(mut self, dir: Int, extend: Bool):
        var p = self.ed.caret
        var k = self.line_of(p, self.at_end)
        if self.goal_x < 0:
            self.goal_x = self.x_of(p, k)
        var goal = self.goal_x
        var n = k + dir
        if n < 0 or n >= len(self.lines):
            var last = len(self.ed.paras) - 1
            self.ed.move_to(Pos(0, 0) if n < 0 else Pos(last, self.ed.paras[last].byte_length()), extend)
            return
        var b = self.byte_at(n, goal)
        self.ed.move_to(Pos(self.lines[n].para, b), extend)
        self.at_end = b == self.lines[n].end and b > self.lines[n].start
        self.goal_x = goal

    def hit(mut self, x: Float64, y: Float64, row: Float64) -> Pos:
        self.lay()
        var k = min(max(Int(y / row) if y > 0 else 0, 0), len(self.lines) - 1)
        var b = self.byte_at(k, x)
        self.at_end = b == self.lines[k].end and b > self.lines[k].start
        return Pos(self.lines[k].para, b)

    def press(mut self, x: Float64, y: Float64, row: Float64, extend: Bool):
        var p = self.hit(x, y, row)
        self.ed.move_to(p, extend)
        self.goal_x = -1
        self.ed.dragging = True

    def drag(mut self, x: Float64, y: Float64, row: Float64):
        if self.ed.dragging:
            var p = self.hit(x, y, row)
            self.ed.move_to(p, True)

    def release(mut self):
        self.ed.dragging = False

    def select_word(mut self, x: Float64, y: Float64, row: Float64):
        var p = self.hit(x, y, row)
        var b = self.ed.paras[p.para].as_bytes()
        var a = p.byte
        var e = p.byte
        while a > 0 and is_word_byte(b[a - 1]):
            a -= 1
        while e < len(b) and is_word_byte(b[e]):
            e += 1
        self.ed.move_to(Pos(p.para, a), False)
        self.ed.move_to(Pos(p.para, e), True)

    def caret_at(mut self, row: Float64) -> Tuple[Float64, Float64]:
        """The caret's left and its line's top, from the words' top left."""
        var c = self.ed.caret
        var k = self.line_of(c, self.at_end)
        return (self.x_of(c, k), Float64(k) * row)

    def paint[P: Painter](mut self, mut p: P, x: Float64, top: Float64, row: Float64, base: Float64, scale: Float64, color: UInt32, words: Bool):
        """The selection, the words (when nothing else draws them) and the caret, in screen px: the box's left and top there,
        `row` and `base` (a line's height and its first baseline under the top) in the style's px, times scale."""
        self.lay()
        var on = self.style
        on.size = self.style.size * scale
        var a = self.ed.sel_start()
        var b = self.ed.sel_end()
        if self.ed.has_selection():
            for k in range(len(self.lines)):
                var l = self.lines[k]
                if l.para < a.para or l.para > b.para:
                    continue
                var s = max(l.start, a.byte) if l.para == a.para else l.start
                var e = min(l.end, b.byte) if l.para == b.para else l.end
                if e < s or (e == s and l.end > l.start):
                    continue
                var x0 = measure(self.style, String(self.ed.paras[l.para][byte=l.start:s])) if s > l.start else 0.0
                var x1 = measure(self.style, String(self.ed.paras[l.para][byte=l.start:e])) if e > l.start else 0.0
                x0 += self.indent(k)
                x1 += self.indent(k)
                p.rect(x + x0 * scale, top + Float64(k) * row * scale, max((x1 - x0) * scale, 3), row * scale, SELECTION, 0)
        if words:
            for k in range(len(self.lines)):
                var l = self.lines[k]
                if l.end > l.start:
                    p.run(on, String(self.ed.paras[l.para][byte=l.start:l.end]), x + self.indent(k) * scale, top + (base + Float64(k) * row) * scale, color, 0)
        var c = self.caret_at(row)
        var cx = x + c[0] * scale
        if self.preedit != "":  # (an input method's composition at the caret, underlined)
            var w = measure(on, self.preedit)
            p.run(on, self.preedit, cx, top + (c[1] + base) * scale, color, 0)
            p.rect(cx, top + (c[1] + base) * scale + 2, w, 1.5, color, 0)
            cx += w
        p.rect(cx, top + c[1] * scale + 4 * scale, 1.5, (row - 8) * scale, color, 0)
