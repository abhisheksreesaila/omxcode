# A page board edited as a person does it (goal 79, docs/goals/79-gaps.md 30, 32, 33, 35, 37, 59–61): keys on the selection,
# order, lock, marquee and Shift+click, the shape tool, the highlighter, the eraser that splits strokes, words written in place
# (caret, selection, up and down, copy, an input method, wrapping, the box's height), a double click; what is made here
# written and read back. No display.
#   pixi run mojo run -I . -I vendor tests/test_boardedit.mojo

from std.testing import assert_equal, assert_true
from mojoui.objectlayer import ObjectLayer, TEXT, STICKY, RECT, INK, export_json_canvas, import_json_canvas
from mojoui.pagedesk import BoardTools, DeskView, BoardLook, erase_at, polyline
from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.ink import Stroke
from mojoui.wordsedit import WordsEdit
from mojoui.fonttext import TextStyle, measure, line_metrics, baseline_in, css_weight, declare_face, engine
from mojoui.textedit import Pos
from mojoui.scene import Scene

comptime W: Float64 = 1440
comptime H: Float64 = 900


struct Board(Movable):
    var t: BoardTools
    var l: ObjectLayer
    var v: DeskView
    var look: BoardLook

    def __init__(out self):
        self.t = BoardTools()
        self.l = ObjectLayer()
        self.v = DeskView(0, 0, 1)
        self.look = BoardLook()

    def key(mut self, name: String, mods: Int = 0) -> Bool:
        return self.t.key(name, mods, self.l, self.v, W, H, 1, 1)

    def click(mut self, x: Float64, y: Float64, mods: Int = 0):
        _ = self.t.press(x, y, self.l, self.v)
        _ = self.t.release(x, y, self.l, self.v)
        _ = self.t.tap(x, y, self.l, self.v, W, H, mods)

    def drag(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64, n: Int = 10):
        _ = self.t.press(x0, y0, self.l, self.v)
        for i in range(1, n + 1):
            _ = self.t.pan(x0 + (x1 - x0) * Float64(i) / Float64(n), y0 + (y1 - y0) * Float64(i) / Float64(n), self.l, self.v)
        _ = self.t.release(x1, y1, self.l, self.v)

    def tool(mut self, name: String):
        self.t.set_tool(name, self.l, self.v, W, H, 1, 1)
        self.v = DeskView(0, 0, 1)  # (a drawing tool opens the page up: back, so a screen px is a page px here)

    def type(mut self, words: String):
        for c in words.graphemes():
            _ = self.key(String(c))

    def paint(mut self) -> Scene:
        var sc = Scene(1440, 900, 1.0)
        self.t.paint_overlay(sc, self.look, self.l, self.v, 1)
        return sc^


def selection() raises:
    var b = Board()
    var a = b.l.add_rect(100, 100, 50, 50, 0xFF0000FF)
    var c = b.l.add_rect(200, 100, 50, 50, 0xFF00FF00)
    var d = b.l.add_rect(600, 600, 50, 50, 0xFF00FF00)
    b.tool("select")
    b.click(125, 125)
    assert_true(b.l.selected == [a], "a click")
    b.click(225, 125, 1)
    assert_equal(len(b.l.selected), 2)
    b.click(225, 125, 1)
    assert_true(b.l.selected == [a], "Shift+click again takes it away")
    b.drag(80, 80, 300, 200)
    assert_equal(len(b.l.selected), 2)  # a marquee: what is wholly in it
    _ = b.t.press(700, 80, b.l, b.v)
    _ = b.t.pan(660, 120, b.l, b.v)
    assert_true(len(b.paint().kinds) > 0, "the marquee is drawn")
    _ = b.t.release(660, 120, b.l, b.v)
    assert_equal(len(b.l.selected), 0)
    assert_true(b.key("a", 2) and len(b.l.selected) == 3, "Ctrl+A")
    b.click(125, 125)
    assert_true(b.key("ArrowRight") and b.l.objs[b.l.index(a)].x == 101 and b.key("ArrowDown", 1) and b.l.objs[b.l.index(a)].y == 110, "nudges: 1, Shift 10")
    b.t.changed = False
    assert_true(b.key("]", 2) and b.t.changed and b.l.z_rank(a) == 1, "forward")
    assert_true(b.key("}", 3) and b.l.z_rank(a) == 2, "to the front (Shift+] is })")
    assert_true(b.key("[", 2) and b.l.z_rank(a) == 1 and b.key("{", 3) and b.l.z_rank(a) == 0, "and back")
    assert_true(b.key("Escape") and len(b.l.selected) == 0, "Escape lets go")
    b.click(125, 125)
    assert_true(b.key("L", 3) and b.l.objs[b.l.index(a)].locked and len(b.l.selected) == 0, "Ctrl+Shift+L locks")
    assert_true(b.key("z", 2) and not b.l.objs[b.l.index(a)].locked and b.key("y", 2) and b.l.objs[b.l.index(a)].locked, "Ctrl+Y does it again")
    b.l.clear_selection()
    b.tool("pen")
    _ = b.key("Escape")
    assert_equal(b.t.tool, "text")
    _ = b.key("Escape")
    assert_equal(b.t.tool, "select")
    _ = d
    _ = c


def making() raises:
    var b = Board()
    b.tool("shape")
    b.click(500, 400)
    assert_equal(len(b.l.objs), 1)
    assert_true(b.l.objs[0].kind == RECT and b.l.objs[0].x == 360 and b.l.objs[0].w == 280 and b.l.objs[0].radius == 28 and b.t.tool == "select", "a shape where clicked, then the arrow")
    b.tool("highlight")
    b.drag(100, 100, 300, 120)
    assert_true(b.l.objs[1].kind == INK and (b.l.objs[1].stroke.color >> 24) == 0x55, "a translucent stroke")
    var text = export_json_canvas(b.l, 1, 1)
    assert_true(text.find('"tool":"highlight"') >= 0 and text.find('"alpha":0.3333') >= 0 and text.find('"type":"shape"') >= 0 and text.find('"cornerRadius":28') >= 0, text)
    var back = import_json_canvas(text)
    assert_equal(len(back.objs), 2)
    for k in range(2):
        if back.objs[k].kind == INK:
            assert_equal(Int(back.objs[k].stroke.color), Int(b.l.objs[1].stroke.color))
        else:
            assert_true(back.objs[k].kind == RECT and back.objs[k].color == b.l.objs[0].color and back.objs[k].radius == 28, "the shape again")


def erasing() raises:
    var b = Board()
    b.tool("pen")
    b.drag(100, 300, 500, 300, 80)
    b.drag(100, 500, 500, 500, 80)
    assert_equal(len(b.l.objs), 2)
    b.tool("eraser")
    b.t.changed = False
    b.drag(300, 100, 300, 700, 3)  # (a fast drag across both: no gaps)
    assert_true(b.t.changed, "erased")
    assert_equal(len(b.l.objs), 4)  # each in two
    for ref o in b.l.objs:
        assert_true(o.x + o.w < 300 - 13 or o.x > 300 + 13, "nothing within the eraser's reach")
    _ = b.key("z", 2)
    assert_equal(len(b.l.objs), 2)  # one undo step
    _ = b.key("y", 2)
    assert_equal(len(b.l.objs), 4)
    b.t.changed = False
    b.drag(50, 50, 60, 60)
    assert_true(not b.t.changed and len(b.l.objs) == 4, "nothing there: nothing changed")
    var r = b.l.add_rect(700, 300, 50, 50, 0xFF0000FF)
    b.drag(690, 320, 760, 320)
    assert_true(b.l.has(r), "only ink")
    # a fast stroke has few points: erased where the eraser crosses its line, between them
    var f = Board()
    f.tool("pen")
    f.drag(100, 300, 500, 300, 2)
    f.tool("eraser")
    f.drag(400, 250, 400, 350, 4)
    assert_true(len(f.l.objs) == 2 and f.l.objs[0].stroke.xs[len(f.l.objs[0].stroke.xs) - 1] < 400, "in two")
    # placing and drawing tools let the selection go (the web's setTool)
    f.l.select_all()
    f.tool("pen")
    assert_equal(len(f.l.selected), 0)
    # a translucent stroke is one polygon, so it doesn't darken where it crosses itself
    var sc = Scene(400, 200, 1.0)
    polyline(sc, 0, 0, [10.0, 100.0, 200.0, 100.0, 60.0, 100.0, 300.0, 120.0], 20, 0x553FA0D6)
    assert_true(len(sc.kinds) == 1 and Int(sc.kinds[0]) == 9, "one polygon")
    var px = List[UInt32](length=400 * 200, fill=0xFFFFFFFF)
    var s = Surface(Int(px.unsafe_ptr()), 400, 200, 1.0)
    var font = Font()
    sc.raster(s, font)
    var once = px[100 * 400 + 30]  # (under one pass, under three: the same)
    assert_true(once != 0xFFFFFFFF, "drawn")
    for x in range(30, 190):
        assert_equal(px[100 * 400 + x], once)


def words() raises:
    var b = Board()
    b.click(100, 100)  # (the text tool)
    b.type("one two")
    _ = b.key("Enter")
    b.type("three")
    assert_equal(b.t.words.text(), "one two\nthree")
    _ = b.key("ArrowUp")
    _ = b.key("Home")
    b.type("X")
    assert_equal(b.t.words.text(), "Xone two\nthree")
    _ = b.key("ArrowRight", 3)  # by a word, selecting
    assert_equal(b.t.words.ed.selected_text(), "one")
    _ = b.key("c", 2)
    assert_equal(b.t.words.ed.clip, "one")
    assert_true(b.t.text_in("PASTED\nin", b.l), "a paste, over the selection")
    assert_equal(b.t.words.text(), "XPASTED\nin two\nthree")
    b.t.words.preedit = "かな"
    _ = b.paint()
    assert_equal(b.t.words.text(), "XPASTED\nin two\nthree")
    assert_true(b.t.text_in("仮名", b.l) and b.t.words.preedit == "", "committed")
    _ = b.key("z", 2)
    assert_equal(b.t.words.text(), "XPASTED\nin two\nthree")
    _ = b.key("Escape")
    assert_equal(len(b.l.objs), 1)
    var id = b.l.objs[0].id
    var row = 34.8
    assert_true(b.l.objs[0].text == "XPASTED\nin two\nthree" and abs(b.l.objs[0].h - 3 * row) < 0.01, "three lines high: " + String(b.l.objs[0].h))
    # a double click writes on it again; a click in it places the caret, a double click a word
    b.tool("select")
    assert_true(b.t.edit_at(120, 110, b.l, b.v, W, H) and b.t.editing == id, "double click")
    assert_true(b.t.words.ed.caret.para == 2, "the caret at the end")
    b.click(102, 110)
    assert_true(b.t.editing == id and b.t.words.ed.caret.para == 0 and b.t.words.ed.caret.byte == 0, "the caret where clicked")
    b.drag(102, 110, 400, 110 + 2 * row)
    assert_equal(b.t.words.ed.selected_text(), "XPASTED\nin two\nthree")
    assert_true(b.t.edit_at(120, 110, b.l, b.v, W, H), "a word")
    assert_equal(b.t.words.ed.selected_text(), "XPASTED")
    assert_true(len(b.paint().kinds) > 4, "drawn")
    b.type("Z")
    assert_equal(b.l.objs[0].text, "Z\nin two\nthree")
    _ = b.key("Enter", 2)  # (Ctrl+Enter)
    assert_true(b.t.editing == -1, "ended")
    _ = b.key("z", 2)
    assert_equal(b.l.objs[0].text, "XPASTED\nin two\nthree")  # one step
    # a sticky wraps; its height is its own
    b.tool("sticky")
    b.click(900, 400)
    var s = b.t.editing
    b.type("many words that do not fit on one line of a sticky")
    b.t.words.lay()
    assert_true(len(b.t.words.lines) > 2, "wraps")
    var lines = b.look.lines(b.l.objs[b.l.index(s)], 240 - 44)
    assert_equal(len(lines), len(b.t.words.lines))  # as the board breaks them
    for k in range(len(lines)):
        var l = b.t.words.lines[k]
        assert_equal(lines[k], String(b.t.words.ed.paras[l.para][byte=l.start:l.end]))
    _ = b.key("ArrowUp")
    _ = b.key("ArrowUp")
    var at = b.t.words.ed.caret.byte
    _ = b.key("ArrowDown")
    assert_true(b.t.words.ed.caret.byte > at, "by shown lines")
    _ = b.key("Escape")
    assert_equal(b.l.objs[b.l.index(s)].h, 200)
    # on the empty page: a new text; on a locked one: nothing
    var n = len(b.l.objs)
    b.tool("select")
    assert_true(b.t.edit_at(100, 800, b.l, b.v, W, H) and b.t.editing == -2, "a new text")
    b.type("made")
    _ = b.key("Escape")
    assert_equal(len(b.l.objs), n + 1)
    b.l.set_locked(s, True)
    b.tool("select")
    assert_true(b.t.edit_at(900, 400, b.l, b.v, W, H) and b.t.editing == -2, "a locked one is the page")
    _ = b.key("Escape")
    b.l.read_only = True
    assert_true(not b.t.edit_at(120, 110, b.l, b.v, W, H) and not b.t.text_in("x", b.l), "read-only takes nothing")


def lines_breaks() raises:
    var w = WordsEdit()
    var st = TextStyle("Geist", 400, False, 16)
    w.begin("", st, 120)
    w.lay()
    assert_equal(len(w.lines), 1)
    w.begin("word " * 12 + "\n\nend", st, 120)
    w.lay()
    var paras = 0
    for k in range(len(w.lines)):
        paras = max(paras, w.lines[k].para)
        assert_true(w.lines[k].end >= w.lines[k].start, "spans")
    assert_equal(paras, 2)
    for k in range(len(w.lines)):  # every position is on one line, and back
        var l = w.lines[k]
        for byte in range(l.start, l.end + 1):
            var at = w.line_of(Pos(l.para, byte), byte == l.end and l.end > l.start)
            assert_true(at == k, "line of " + String(l.para) + ":" + String(byte) + " is " + String(at) + " not " + String(k))


def handles() raises:
    var b = Board()
    var r = b.l.add_rect(200, 200, 100, 60, 0xFF0000FF)
    b.tool("select")
    b.click(250, 230)
    _ = b.paint()
    assert_equal(len(b.t.handles), 15)
    b.t.changed = False
    b.drag(300, 260, 360, 300)  # the bottom right corner
    var q = b.l.index(r)
    assert_true(abs(b.l.objs[q].w - 160) < 0.01 and abs(b.l.objs[q].h - 100) < 0.01 and b.l.objs[q].x == 200 and b.t.changed, "resized from its other corner")
    _ = b.paint()
    b.drag(200, 200, 220, 210)
    assert_true(abs(b.l.objs[q].x - 220) < 0.01 and abs(b.l.objs[q].w - 140) < 0.01, "and from the top left")
    _ = b.key("z", 2)
    _ = b.key("z", 2)
    assert_true(b.l.objs[q].w == 100 and b.l.objs[q].h == 60, "a step each")
    _ = b.paint()
    b.drag(250, 200 - 28, 250 + 200, 230)  # the knob, to the right
    assert_true(abs(b.l.objs[q].rot - 1.5707963) < 0.01, "turned: " + String(b.l.objs[q].rot))
    _ = b.key("z", 2)
    b.t.changed = False
    _ = b.paint()
    b.click(300, 260)  # a click on a handle moves nothing
    assert_true(b.l.objs[q].w == 100 and not b.t.changed, "nothing")


def families() raises:
    """A text the web made names its faces as CSS does, its weight in words."""
    var mono = measure(TextStyle("Geist Mono", 400, False, 24), "Words on the board")
    assert_equal(measure(TextStyle('"Geist Mono", monospace', 400, False, 24), "Words on the board"), mono)
    assert_equal(measure(TextStyle("Nobody's Face, 'Geist Mono'", 400, False, 24), "Words on the board"), mono)
    assert_equal(measure(TextStyle("monospace", 400, False, 24), "Words on the board"), mono)
    assert_true(measure(TextStyle("Geist", 400, False, 24), "Words on the board") != mono, "another face")
    assert_equal(measure(TextStyle("sans-serif", 400, False, 24), "Words"), measure(TextStyle("Geist", 400, False, 24), "Words"))
    # only the faces a page declares: the nearest weight by CSS's rule, one optical size
    var have: List[Int] = [400, 600]
    assert_equal(css_weight(700, Span(have)), 600)
    assert_equal(css_weight(500, Span(have)), 400)
    assert_equal(css_weight(600, Span(have)), 600)
    assert_equal(css_weight(300, Span(have)), 400)
    var some: List[Int] = [300, 500, 700]
    assert_equal(css_weight(400, Span(some)), 500)
    assert_equal(css_weight(450, Span(some)), 500)
    assert_equal(css_weight(600, Span(some)), 700)
    assert_equal(css_weight(200, Span(some)), 300)
    var bold = TextStyle("Source Serif 4", 700, False, 60)
    bold.exact = True
    var wide = measure(bold, "Central idea")
    declare_face("Source Serif 4", False, [400, 600], 24)
    var semi = TextStyle("Source Serif 4", 600, False, 60)
    semi.exact = True
    assert_true(measure(TextStyle("Source Serif 4", 700, False, 61), "Central idea") != wide, "(another size: not from a cache)")
    assert_equal(engine()[].as_declared(engine()[].pick("Source Serif 4", 700, False), 700, 60)[0], 600)
    assert_equal(engine()[].as_declared(engine()[].pick("Source Serif 4", 700, False), 700, 60)[1], 24)
    # an emoji sits in the middle of its line (a bitmap face's metrics are its strike's: 0 drew every note's emoji 8 px high
    # on Linux, in every compare picture since M2, under the checker's bars)
    var e = TextStyle("emoji", 400, False, 38)
    var m = line_metrics(e)
    assert_true(m.ascent > 25 and m.descent > 3, "its own metrics")
    var base = baseline_in(0, 38, e)
    assert_true(base > 28 and base < 36, "in the middle: " + String(base))
    var doc = String('{"nodes":[{"id":"t","type":"text","x":0,"y":0,"width":300,"height":60,"text":"Hi","pn":{"type":"text","geometry":{"x":0,"y":0,"width":300,"height":60},"style":{"fontWeight":"bold","fontFamily":"\\"Geist Mono\\", monospace","fontSize":24,"lineHeight":1.45,"padding":8,"color":"#20201e"},"mode":"box","format":"markdown"}}],"edges":[]}')
    var l = import_json_canvas(doc)
    assert_true(l.objs[0].weight == 700 and l.objs[0].family == '"Geist Mono", monospace', "read")
    l.select_all()
    l.move_by(10, 0)
    var out = export_json_canvas(l, 1, 1)
    assert_true(out.find('"fontWeight":"bold","fontFamily":"\\"Geist Mono\\", monospace"') >= 0, "written as it was: " + out)


def main() raises:
    families()
    handles()
    selection()
    making()
    erasing()
    words()
    lines_breaks()
    print("boardedit: ok")
