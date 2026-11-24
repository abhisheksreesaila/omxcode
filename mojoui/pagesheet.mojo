# mojoui.pagesheet (goal 79): a page note drawn the way Personal Note's web page looks: an ivory sheet on a warm desk
# inside a rounded host, the Write/Draw toolbar floating over its top edge, the note's emoji tile, and the Markdown text
# with its marks shown quietly (CodeMirror's look: Literata 18/1.65, Bricolage headings, marks in the markup colour,
# quotes muted italic, code in Geist Mono at .9em). Line boxes follow CSS (half-leading floored, heights in 1/64 px).
#
# The text is kept by mojoui.textedit's TextEdit (selection, words, undo); this lays it out itself: a line of Markdown
# wraps at the sheet's width where the browser wraps it (mojoui.linebreak's rules, then a word is cut anywhere), only the
# lines in view are drawn, the page scrolls and keeps the caret in view.
#
#   var page = PageSheet(); page.set_markdown(md)
#   page.draw(p, bx, x0, y0, x1, y1, k, emoji, tint)
#   page.key("ArrowDown", SHIFT, now_ms())   # 0 not a key of the page's, 1 used, 2 used and the text changed
#   page.press(x, y, shift); page.drag(x, y); page.select_word(x, y); page.select_para(x, y); page.wheel(dy)
#   page.ed.clip, page.ed.clip_version       # what was copied: show overlays.Clipboard(clip, clip_version)

from mojoui.graphemes import prev_grapheme, next_grapheme
from mojoui.linebreak import browser_breaks
from mojoui.textedit import TextEdit, Pos, SHIFT, CTRL, ALT, EDIT_OTHER, now_ms, decode_at, is_word_byte
from mojoui.scene import Painter
from mojoui.skin import Skin, Shadow, mix, with_alpha, hexc
from mojoui.fonttext import TextStyle, measure, line_metrics, ALIGN_LEFT, ALIGN_CENTER
from mojoui.notesshell import Boxes, draw_lifted, draw_bordered, draw_emoji_tile, text_at, text_normal
from mojoui.canvas import rgba
from mojoui.jsonpatch import Change, patched
from mojoui.pageink import PageInk, PageMark
from mojoui.json import Json, json_string

comptime PAGE_DESK: UInt32 = 0xFFDAE4E9  # #e9e4da
comptime PAGE_PAPER: UInt32 = 0xFFF8FDFF  # #fffdf8
comptime PAGE_INK: UInt32 = 0xFF161B1F  # #1f1b16
comptime PAGE_MUTED: UInt32 = 0xFF57636B  # #6b6357
comptime PAGE_LINE: UInt32 = 0xFFCDDBE2  # #e2dbcd
comptime PAGE_SELECTION: UInt32 = 0x2EE06F2F  # rgba(47, 111, 224, .18)
comptime PAGE_FAINT: UInt32 = 0xFF889AA3  # #a39a88
comptime PAGE_MARKUP: UInt32 = 0xFFA6B2B9  # #b9b2a6
comptime TEXT_FACE = "Literata"
comptime DISPLAY_FACE = "Bricolage Grotesque"
comptime UI_FACE = "Figtree"
comptime MONO_FACE = "Geist Mono"
comptime BODY = 18.0


def lu(v: Float64) -> Float64:
    """A length as Blink keeps it: whole 64ths of a px (floored)."""
    return Float64(Int(v * 64)) / 64


@fieldwise_init
struct InkStep(Copyable, Movable):
    """One undo step of the ink: the marks it took away (with where they were) or the one it made (gone empty), after
    `depth` steps of the words."""
    var depth: Int
    var made: List[PageMark]
    var gone: List[PageMark]
    var gone_at: List[Int]


@fieldwise_init
struct Seg(Copyable, Movable):
    var text: String
    var style: TextStyle
    var color: UInt32
    var lh: Float64  # the line-height its inline box asks for


@fieldwise_init
struct VLine(Copyable, Movable, ImplicitlyCopyable):
    """A line as it is shown: the bytes [start, end) of its paragraph, its top under the paragraph's, height, baseline."""
    var start: Int
    var end: Int
    var top: Float64
    var height: Float64
    var base: Float64


struct ParaLay(Copyable, Movable):
    """A paragraph (a line of the Markdown) laid out: its words and width then, its pieces and the lines they wrap into."""
    var text: String
    var width: Float64
    var segs: List[Seg]
    var lines: List[VLine]
    var height: Float64

    def __init__(out self):
        self.text = ""
        self.width = -1
        self.segs = List[Seg]()
        self.lines = List[VLine]()
        self.height = 0


struct PageSheet(Movable):
    var ed: TextEdit  # the text, caret, selection and undo
    var show_caret: Bool
    var at_end: Bool  # the caret stands at the end of its shown line (after End, a click), not at the next one's start
    var goal_x: Float64  # up and down keep this x (-1: the caret's)
    var laid: List[ParaLay]
    var tops: List[Float64]  # where the last draw put each paragraph (layout px)
    var content_h: Float64  # the desk's content and the room it has, at the last draw
    var view_h: Float64
    var view_top: Float64
    var before_press: Pos  # the selection's start before the last press (a Shift+click reaches from it)
    var follow: Bool  # the next draw scrolls the caret into view
    var ink: PageInk  # the marks on the words, the document's and the ones made here
    var ink_done: List[InkStep]  # (one history for words and ink)
    var ink_undone: List[InkStep]
    var tool: String  # in Draw: pen | red | highlight | eraser
    var sweep: List[PageMark]  # what the eraser's drag has taken so far, and from where
    var sweep_at: List[Int]
    var erasing: Bool
    var preedit: String  # an input method's composition, shown at the caret, underlined (not in the text)
    var caret_rect: Tuple[Float64, Float64, Float64, Float64]  # where the caret was last drawn (layout px)
    var scroll: Float64
    # where the last draw put the text (for a tap's caret): its left and width; the paper's origin
    var text_x: Float64
    var text_w: Float64
    var paper_x: Float64
    var paper_y: Float64
    var draw_mode: Bool  # Draw (a press on the page makes a pen mark) or Write
    var wet: List[Float64]  # the mark being drawn (layout px), empty: none

    def __init__(out self):
        self.ed = TextEdit()
        self.show_caret = True
        self.at_end = False
        self.goal_x = -1
        self.laid = List[ParaLay]()
        self.tops = List[Float64]()
        self.content_h = 0
        self.view_h = 0
        self.view_top = 0
        self.follow = False
        self.before_press = Pos(0, 0)
        self.ink = PageInk()
        self.ink_done = List[InkStep]()
        self.ink_undone = List[InkStep]()
        self.tool = "pen"
        self.sweep = List[PageMark]()
        self.sweep_at = List[Int]()
        self.erasing = False
        self.preedit = ""
        self.caret_rect = (-1.0, 0.0, 0.0, 0.0)
        self.scroll = 0
        self.text_x = 0
        self.text_w = 640
        self.paper_x = 0
        self.paper_y = 0
        self.draw_mode = False
        self.wet = List[Float64]()

    def set_markdown(mut self, md: String):
        """Another text: the caret at its end (CodeMirror keeps the text's last newline as an empty last line), nothing
        selected, nothing to undo, at the top."""
        self.ed.set_text(md)
        self.caret_end()
        self.ed.history.clear()
        self.preedit = ""
        self.scroll = 0
        self.follow = False
        self.ink = PageInk()
        self.ink.text = md
        self.ink_done.clear()
        self.ink_undone.clear()

    def load_ink(mut self, content: String) raises:
        """The ink a page's content (JSON) holds, over the Markdown set."""
        self.ink.load(content, self.markdown())

    def markdown(self) -> String:
        return self.ed.text()

    # ------------------------------------------------ editing (goal 79 M5: typed keys, input-method commits, pastes)

    def key(mut self, name: String, mods: Int, now: Int) -> Int:
        """A key press (a typed character or a web key name; SHIFT 1, CTRL 2, ALT 4): 0 not the page's, 1 used, 2 used and
        the text or ink changed. Ctrl+V isn't taken: the host's paste comes as text (insert)."""
        var shift = (mods & SHIFT) != 0
        var ctrl = (mods & CTRL) != 0
        var alt = (mods & ALT) != 0
        var plain = not ctrl and not alt
        var version = self.ed.version
        if plain and (name == "ArrowUp" or name == "ArrowDown"):
            self.vertical(1 if name == "ArrowDown" else -1, shift)
            return 1
        if plain and (name == "PageUp" or name == "PageDown"):
            for _ in range(max(Int((self.view_h - 60) / 30), 1)):
                self.vertical(1 if name == "PageDown" else -1, shift)
            return 1
        if plain and (name == "Home" or name == "End"):
            self.line_edge(name == "End", shift)
            return 1
        if plain and name == "Tab":
            self.indent(-1 if shift else 1, now)
            return 2 if self.ed.version != version else 1
        if ctrl and (name == "v" or name == "V"):
            return 0
        if ctrl and (name == "z" or name == "Z" or name == "y" or name == "Y"):
            if name == "y" or name == "Y" or shift or name == "Z":
                return 2 if self.redo() else 1
            return 2 if self.undo() else 1
        var r = self.ed.edit_key("Enter" if name == "Return" else ("Backspace" if name == "BackSpace" else name), mods, now)
        if not r:
            return 0
        self.at_end = False
        self.goal_x = -1
        if not (ctrl and (name == "c" or name == "C" or name == "a" or name == "A")):
            self.follow = True
        if self.ed.version != version:
            self.ink_undone.clear()
            self.ink.follow(self.markdown())
            return 2
        return 1

    def undo(mut self) -> Bool:
        """The last step back: words or ink, whichever came last (the web keeps one history for both)."""
        var n = len(self.ed.history.done)
        if len(self.ink_done) > 0 and self.ink_done[len(self.ink_done) - 1].depth >= n:
            var st = self.ink_done.pop()
            for ref m in st.made:
                self._drop_mark(m.key)
            for k in range(len(st.gone) - 1, -1, -1):
                self.ink.marks.insert(min(st.gone_at[k], len(self.ink.marks)), st.gone[k].copy())
            self.ink_undone.append(st^)
            return True
        self.follow = True
        var r = self.ed.undo()
        self.ink.follow(self.markdown())
        return r

    def redo(mut self) -> Bool:
        var n = len(self.ed.history.done)
        if len(self.ink_undone) > 0 and self.ink_undone[len(self.ink_undone) - 1].depth == n:
            var st = self.ink_undone.pop()
            for k in range(len(st.gone)):
                var at = self._mark_like(st.gone[k])
                if at >= 0:
                    _ = self.ink.marks.pop(at)
            for ref m in st.made:
                self.ink.marks.append(m.copy())
            self.ink_done.append(st^)
            return True
        self.follow = True
        var r = self.ed.redo()
        self.ink.follow(self.markdown())
        return r

    def _drop_mark(mut self, key: String):
        for i in range(len(self.ink.marks)):
            if self.ink.marks[i].source == "" and self.ink.marks[i].key == key:
                _ = self.ink.marks.pop(i)
                return

    def _mark_like(self, m: PageMark) -> Int:
        for i in range(len(self.ink.marks)):
            if self.ink.marks[i].key == m.key and self.ink.marks[i].source == m.source:
                return i
        return -1

    def _ink_step(mut self, var made: List[PageMark], var gone: List[PageMark], var gone_at: List[Int]):
        self.ed.history.seal()
        self.ed.history.undone.clear()
        self.ink_undone.clear()
        self.ink_done.append(InkStep(len(self.ed.history.done), made^, gone^, gone_at^))

    def indent(mut self, dir: Int, now: Int):
        """Tab: two spaces before each line of the selection (the caret's line), Shift+Tab takes them away again
        (CodeMirror's indentWithTab)."""
        var a = self.ed.sel_start()
        var b = self.ed.sel_end()
        var had = self.ed.has_selection()
        var caret = self.ed.caret
        var anchor = self.ed.anchor
        var out = String("")
        var last = b.para
        if had and b.byte == 0 and b.para > a.para:  # (a selection that only touches the next line's start leaves it)
            last -= 1
        var changed = False
        for i in range(a.para, last + 1):
            ref l = self.ed.paras[i]
            if i > a.para:
                out += "\n"
            var by = 0
            if dir > 0:
                by = 2 if (l.byte_length() > 0 or not had) else 0
                out += String("  ") if by > 0 else String("")
                out += l
            else:
                while by < 2 and by < l.byte_length() and l.as_bytes()[by] == 32:
                    by += 1
                out += String(l[byte=by:])
                by = -by
            changed = changed or by != 0
            if caret.para == i:
                caret.byte = max(caret.byte + by, 0)
            if anchor.para == i:
                anchor.byte = max(anchor.byte + by, 0)
        if not changed:
            return
        self.ed.replace(Pos(a.para, 0), Pos(last, self.ed.paras[last].byte_length()), out, EDIT_OTHER, now)
        self.ed.caret = self.ed.clamp(caret)
        self.ed.anchor = self.ed.clamp(anchor)
        self.follow = True
        self.ink.follow(self.markdown())

    def caret_home(mut self):
        self.ed.move_to(Pos(self.ed.caret.para, 0), False)
        self.at_end = False

    def caret_line_end(mut self):
        self.ed.move_to(Pos(self.ed.caret.para, self.ed.paras[self.ed.caret.para].byte_length()), False)

    def caret_left(mut self):
        self.ed.move_to(self.ed.prev_char(self.ed.caret), False)
        self.at_end = False

    def caret_right(mut self):
        self.ed.move_to(self.ed.next_char(self.ed.caret), False)
        self.at_end = False

    def delete_forward(mut self):
        """Delete: the character after the caret (at a line's end, the next line joins it)."""
        _ = self.key("Delete", 0, now_ms())

    # ------------------------------------------------ layout

    def lay(mut self, i: Int) -> Float64:
        """Paragraph i's layout, made again when its words (the composition in them) or the width changed; its height."""
        var words = self.shown_text(i)
        while len(self.laid) < len(self.ed.paras):
            self.laid.append(ParaLay())
        while len(self.laid) > len(self.ed.paras):
            _ = self.laid.pop()
        if self.laid[i].width == self.text_w and self.laid[i].text == words:
            return self.laid[i].height
        var pl = ParaLay()
        pl.segs = self.segments(words)
        pl.width = self.text_w
        var cuts = self.wrap(words, pl.segs)
        var y = 0.0
        for c in range(len(cuts) - 1):
            var lb = self.line_box(self.part(pl.segs, cuts[c], cuts[c + 1]))
            pl.lines.append(VLine(cuts[c], cuts[c + 1], y, lb[0], lb[1]))
            y += lb[0]
        pl.height = y
        pl.text = words^
        self.laid[i] = pl^
        return y

    def shown_text(self, i: Int) -> String:
        """Paragraph i with the input method's composition at the caret."""
        if self.preedit != "" and i == self.ed.caret.para:
            ref l = self.ed.paras[i]
            return String(l[byte=0:self.ed.caret.byte]) + self.preedit + String(l[byte=self.ed.caret.byte:])
        return self.ed.paras[i]

    def part(self, segs: List[Seg], a: Int, b: Int) -> List[Seg]:
        """The pieces of bytes [a, b)."""
        var out = List[Seg]()
        var off = 0
        for ref s in segs:
            var n = s.text.byte_length()
            var x0 = max(a - off, 0)
            var x1 = min(b - off, n)
            if x1 > x0 or (n == 0 and off >= a and off <= b):
                out.append(Seg(String(s.text[byte=x0:x1]), s.style, s.color, s.lh))
            off += n
        return out^

    def width_of(self, segs: List[Seg], a: Int, b: Int) -> Float64:
        var w = 0.0
        var off = 0
        for ref s in segs:
            var n = s.text.byte_length()
            var x0 = max(a - off, 0)
            var x1 = min(b - off, n)
            if x1 > x0:
                w += measure(s.style, String(s.text[byte=x0:x1]))
            off += n
            if off >= b:
                break
        return w

    def wrap(self, words: String, segs: List[Seg]) -> List[Int]:
        """Where the shown lines start, and the end: the browser's `white-space: break-spaces; overflow-wrap: anywhere`
        (CodeMirror's lineWrapping): a line may end after a space, or where Chrome breaks; what is still too long is cut
        at a character."""
        var cuts: List[Int] = [0]
        var n = words.byte_length()
        if n == 0 or self.width_of(segs, 0, n) <= self.text_w:
            cuts.append(n)
            return cuts^
        var start = 0  # this shown line's
        var fits = 0  # the last place it may end
        var i = 0
        var before = 0
        var x = 0
        while i < n:
            var e = next_grapheme(words, i)
            var y = decode_at(words, i)
            if i > start and x != 0 and _may_break(before, x, y):
                if self.width_of(segs, start, i) <= self.text_w:
                    fits = i
                else:
                    if fits <= start:
                        fits = self._cut(words, segs, start, i)
                    cuts.append(fits)
                    start = fits
                    # (what is left up to i may itself be too long: cut on)
                    while self.width_of(segs, start, i) > self.text_w:
                        start = self._cut(words, segs, start, i)
                        cuts.append(start)
                    fits = i
            before = x
            x = y
            i = e
        while self.width_of(segs, start, n) > self.text_w:
            if fits > start:
                start = fits
            else:
                start = self._cut(words, segs, start, n)
            cuts.append(start)
        cuts.append(n)
        return cuts^

    def _cut(self, words: String, segs: List[Seg], start: Int, end: Int) -> Int:
        """The last character boundary of [start, end) that still fits the width (at least one character)."""
        var best = next_grapheme(words, start)
        var i = best
        while i < end:
            i = next_grapheme(words, i)
            if self.width_of(segs, start, i) > self.text_w:
                break
            best = i
        return best

    def vline_of(mut self, p: Pos, at_end: Bool) -> Int:
        """The shown line position p is on; at a wrap, the next one unless at_end."""
        _ = self.lay(p.para)
        ref ls = self.laid[p.para].lines
        for k in range(len(ls)):
            if p.byte < ls[k].end or k == len(ls) - 1 or (p.byte == ls[k].end and at_end):
                return k
        return 0

    def x_at(mut self, para: Int, vline: Int, byte: Int) -> Float64:
        """A position's x, from the text's left."""
        _ = self.lay(para)
        return self.width_of(self.laid[para].segs, self.laid[para].lines[vline].start, byte)

    def byte_at(mut self, para: Int, vline: Int, x: Float64) -> Int:
        """The character boundary of a shown line nearest x (from the text's left)."""
        _ = self.lay(para)
        var l = self.laid[para].lines[vline]
        var words = self.laid[para].text
        var best = l.start
        var best_d = abs(x)
        var i = l.start
        while i < l.end:
            i = next_grapheme(words, i)
            var d = abs(x - self.width_of(self.laid[para].segs, l.start, i))
            if d < best_d:
                best_d = d
                best = i
            elif d > best_d + 60:
                break
        return best

    def vertical(mut self, dir: Int, extend: Bool):
        """Up or down a shown line, at the x it started from; past the first or last line: the text's start or end."""
        var p = self.ed.caret
        var k = self.vline_of(p, self.at_end)
        if self.goal_x < 0:
            self.goal_x = self.x_at(p.para, k, p.byte)
        var para = p.para
        var v = k + dir
        if v < 0:
            para -= 1
            if para >= 0:
                _ = self.lay(para)
                v = len(self.laid[para].lines) - 1
        elif v >= len(self.laid[p.para].lines):
            para += 1
            v = 0
        var goal = self.goal_x
        if para < 0 or para >= len(self.ed.paras):
            var last = len(self.ed.paras) - 1
            self.ed.move_to(Pos(0, 0) if para < 0 else Pos(last, self.ed.paras[last].byte_length()), extend)
            self.at_end = False
        else:
            var b = self.byte_at(para, v, goal)
            self.ed.move_to(Pos(para, b), extend)
            self.at_end = b == self.laid[para].lines[v].end
            self.goal_x = goal
        self.follow = True

    def line_edge(mut self, end: Bool, extend: Bool):
        """Home and End: the shown line's edge."""
        var p = self.ed.caret
        var at = self.vline_of(p, self.at_end)
        var l = self.laid[p.para].lines[at]
        self.ed.move_to(Pos(p.para, l.end if end else l.start), extend)
        self.at_end = end
        self.goal_x = -1
        self.follow = True

    # ------------------------------------------------ the pointer (layout px, as the last draw laid it out)

    def hit(mut self, x: Float64, y: Float64) -> Tuple[Pos, Bool]:
        """The position nearest (x, y), and whether it stands at its shown line's end."""
        if len(self.tops) == 0:
            return (Pos(0, 0), False)
        var para = 0
        while para + 1 < len(self.tops) and para + 1 < len(self.ed.paras) and y >= self.tops[para + 1]:
            para += 1
        _ = self.lay(para)
        var v = 0
        while v + 1 < len(self.laid[para].lines) and y >= self.tops[para] + self.laid[para].lines[v + 1].top:
            v += 1
        var b = self.byte_at(para, v, x - self.text_x)
        if self.preedit != "":  # (a press while composing: the composition isn't text yet)
            b = min(b, self.ed.paras[para].byte_length())
        return (Pos(para, b), b == self.laid[para].lines[v].end)

    def on_words(mut self, x: Float64, y: Float64) -> Bool:
        """(x, y) is on a shown line with words, from 6 px before them to 28 px past them: the web's onText (a press there
        types; elsewhere it starts a mark)."""
        for para in range(min(len(self.tops), len(self.ed.paras))):
            var ph = self.lay(para)
            if y < self.tops[para] or y >= self.tops[para] + ph:
                continue
            for ref l in self.laid[para].lines:
                var t = self.tops[para] + l.top
                if y >= t and y < t + l.height:
                    return l.end > l.start and x >= self.text_x - 6 and x <= self.text_x + self.width_of(self.laid[para].segs, l.start, l.end) + 28
        return False

    def tap(mut self, x: Float64, y: Float64) -> Bool:
        """A tap on the text: the caret at the nearest character boundary of the shown line under it. False when the tap is
        not on a line's words (the web starts a mark there)."""
        var r = self.press(x, y, False)
        self.ed.dragging = False
        return r

    def extend_tap(mut self, x: Float64, y: Float64) -> Bool:
        """A Shift+click (its press already moved the caret): the selection from where it was before that press."""
        var from_ = self.before_press
        if not self.tap(x, y):
            return False
        self.ed.anchor = self.ed.clamp(from_)
        return True

    def press(mut self, x: Float64, y: Float64, extend: Bool) -> Bool:
        """The pointer went down on the words: the caret there (Shift: the selection reaches there). drag follows."""
        if not self.on_words(x, y):
            return False
        var h = self.hit(x, y)
        self.before_press = self.ed.anchor
        self.ed.move_to(h[0], extend)
        self.at_end = h[1]
        self.goal_x = -1
        self.ed.dragging = True
        return True

    def drag(mut self, x: Float64, y: Float64) -> Bool:
        if not self.ed.dragging:
            return False
        var h = self.hit(x, y)
        self.ed.move_to(h[0], True)
        self.at_end = h[1]
        self.follow = True
        return True

    def release(mut self) -> Bool:
        var was = self.ed.dragging
        self.ed.dragging = False
        return was

    def select_word(mut self, x: Float64, y: Float64) -> Bool:
        """A double click: the word under it."""
        if not self.on_words(x, y):
            return False
        var p = self.hit(x, y)[0]
        var b = self.ed.paras[p.para].as_bytes()
        var a = p.byte
        var e = p.byte
        while a > 0 and is_word_byte(b[a - 1]):
            a -= 1
        while e < len(b) and is_word_byte(b[e]):
            e += 1
        if a == e:  # (not in a word: the one character after it)
            e = next_grapheme(self.ed.paras[p.para], e) if e < len(b) else e
        self.ed.move_to(Pos(p.para, a), False)
        self.ed.move_to(Pos(p.para, e), True)
        self.at_end = False
        return True

    def select_para(mut self, x: Float64, y: Float64) -> Bool:
        """A triple click: the line of Markdown under it."""
        if not self.on_words(x, y):
            return False
        var p = self.hit(x, y)[0]
        self.ed.move_to(Pos(p.para, 0), False)
        self.ed.move_to(Pos(p.para, self.ed.paras[p.para].byte_length()), True)
        return True

    def wheel(mut self, dy: Float64) -> Bool:
        """The page scrolled by dy px (down: positive); True when it moved."""
        var was = self.scroll
        self.scroll = min(max(self.scroll + dy, 0), max(self.content_h - self.view_h, 0))
        return self.scroll != was

    # ------------------------------------------------ Draw mode: pen marks over the page (the web's ink layer)

    def mark_press(mut self, x: Float64, y: Float64):
        self.wet.clear()
        self.erasing = self.tool == "eraser"
        if self.erasing:
            self.sweep.clear()
            self.sweep_at.clear()
            self._erase_at(x, y)
            return
        self.wet.append(x)
        self.wet.append(y)

    def mark_move(mut self, x: Float64, y: Float64):
        if self.erasing:
            self._erase_at(x, y)
        elif len(self.wet) > 0:
            self.wet.append(x)
            self.wet.append(y)

    def marking(self) -> Bool:
        """A mark is being drawn, or erased."""
        return self.erasing or len(self.wet) > 0

    def mark_release(mut self) -> Bool:
        """The mark being drawn becomes a mark of the page (anchored to the word nearest its start), or what the eraser
        took is gone, one undo step; True when the ink changed."""
        if self.erasing:
            self.erasing = False
            if len(self.sweep) == 0:
                return False
            self._ink_step(List[PageMark](), self.sweep.copy(), self.sweep_at.copy())
            self.sweep.clear()
            self.sweep_at.clear()
            return True
        if len(self.wet) < 4:
            self.wet.clear()
            return False
        # (ink-state.js: points from the stroke's own top-left; (dx, dy) puts that corner relative to the box of the first
        # character of the word under the mark)
        var x0 = self.wet[0]
        var y0 = self.wet[1]
        for i in range(0, len(self.wet), 2):
            x0 = min(x0, self.wet[i])
            y0 = min(y0, self.wet[i + 1])
        var pts = List[Float64]()
        for i in range(0, len(self.wet), 2):
            pts.append(Float64(Int((self.wet[i] - x0) * 10 + (0.5 if self.wet[i] >= x0 else -0.5))) / 10)
            pts.append(Float64(Int((self.wet[i + 1] - y0) * 10 + (0.5 if self.wet[i + 1] >= y0 else -0.5))) / 10)
        var anchor = self._nearest_word(self.wet[0], self.wet[1], x0, y0)
        self.ink.text = self.markdown()
        self.ink.add(self.tool, pts^, anchor[0], anchor[1], anchor[2], anchor[3])
        self._ink_step([self.ink.marks[len(self.ink.marks) - 1].copy()], List[PageMark](), List[Int]())
        self.wet.clear()
        return True

    def _erase_at(mut self, x: Float64, y: Float64):
        """The marks with a point within 12 px of (x, y), taken."""
        var i = len(self.ink.marks) - 1
        while i >= 0:
            var o = self.mark_origin(i)
            if o[2]:
                ref pts = self.ink.marks[i].points
                for k in range(0, len(pts), 2):
                    var dx = o[0] + pts[k] - x
                    var dy = o[1] + pts[k + 1] - y
                    if dx * dx + dy * dy < 144:
                        self.sweep.append(self.ink.erase(i))
                        self.sweep_at.append(i)
                        break
            i -= 1

    def mark_origin(mut self, i: Int) -> Tuple[Float64, Float64, Bool]:
        """Where mark i's top left is (layout px, as the last draw laid the page out); False: it is on no word here."""
        var pos = self.ink.marks[i].pos
        if pos < 0 or len(self.tops) == 0:
            return (0.0, 0.0, False)
        var base = 0
        for para in range(min(len(self.tops), len(self.ed.paras))):
            var n = self.ed.paras[para].byte_length()
            if pos <= base + n:
                var byte = pos - base
                var v = self.vline_of(Pos(para, byte), False)
                var l = self.laid[para].lines[v]
                var x = self.text_x + (0.0 if self.ink.marks[i].margin else self.width_of(self.laid[para].segs, l.start, byte))
                return (x + self.ink.marks[i].dx, self.tops[para] + l.top + self._char_top(para, v, byte) + self.ink.marks[i].dy, True)
            base += n + 1
        return (0.0, 0.0, False)

    def _char_top(self, para: Int, v: Int, byte: Int) -> Float64:
        """How far under a shown line's top a character's own box begins (its face's ascent above the baseline), which is
        what the web measures a mark's place from."""
        var l = self.laid[para].lines[v]
        var off = 0
        var st = TextStyle(TEXT_FACE, 400, False, BODY)
        for ref s in self.laid[para].segs:
            var n = s.text.byte_length()
            if byte >= off and byte < off + n:
                st = s.style
                break
            off += n
        return l.base - Float64(line_metrics(st).ascent)

    def _nearest_word(self, x: Float64, y: Float64, cx: Float64, cy: Float64) -> Tuple[Int, Int, Float64, Float64]:
        """(start, end) of the word whose box is nearest (x, y), as offsets into the Markdown, and (cx, cy) from the box of
        its first character (its left, its line's top)."""
        var best = (0, 0, 0.0, 0.0)
        var best_d = 1e300
        var base = 0
        for para in range(min(len(self.tops), len(self.ed.paras))):
            if para < len(self.laid):
                for vi in range(len(self.laid[para].lines)):
                    var l = self.laid[para].lines[vi]
                    var top = self.tops[para] + l.top
                    var ly = top + l.height / 2
                    var px = self.text_x
                    var off = l.start
                    for ref sg in self.part(self.laid[para].segs, l.start, l.end):
                        var wx = px
                        var woff = off
                        for wd in sg.text.split(" "):
                            var w = String(wd)
                            var ww = measure(sg.style, w)
                            if w.byte_length() > 0:
                                var at = max(wx, min(x, wx + ww))
                                var d = (x - at) * (x - at) + (y - ly) * (y - ly)
                                if d < best_d:
                                    best_d = d
                                    best = (base + woff, base + woff + w.byte_length(), cx - wx, cy - top - self._char_top(para, vi, woff))
                            wx += ww + measure(sg.style, " ")
                            woff += w.byte_length() + 1
                        px += measure(sg.style, sg.text)
                        off += sg.text.byte_length()
            base += self.ed.paras[para].byte_length() + 1
        return best

    def page_json(self, source: String) raises -> String:
        """The page as it is saved when it was read from `source` (review 3): that text with its markdown replaced, when it
        changed, and the marks made here added after the ones it had; every other member (its other ink, keys nobody here
        knows) as it was. A page made here: the web's shape."""
        var md = self.markdown()
        if source == "":
            return self.ink.save('{"version":1,"markdown":' + json_string(md) + ',"ink":{"marks":[],"drawings":[]}}')
        var j = Json.parse(source)
        var out = source
        if j.get(0, "markdown") < 0 or j.text(j.get(0, "markdown")) != md:
            out = patched(out, [Change("markdown", json_string(md))])
        return self.ink.save(out)

    def caret_end(mut self):
        var last = len(self.ed.paras) - 1
        self.ed.move_to(Pos(last, self.ed.paras[last].byte_length()), False)
        self.at_end = False
        self.goal_x = -1

    def insert(mut self, text: String):
        """Text at the caret, over the selection (a newline in it splits the line); the caret ends after it."""
        self.ed.insert(text, now_ms())
        self.at_end = False
        self.goal_x = -1
        self.follow = True
        self.ink_undone.clear()
        self.ink.follow(self.markdown())

    def newline(mut self):
        self.insert("\n")

    def backspace(mut self):
        _ = self.key("Backspace", 0, now_ms())

    def segments(self, line: String) -> List[Seg]:
        """A Markdown line as styled pieces (headings, list and quote marks, bold, italic, inline code)."""
        var out = List[Seg]()
        var body = TextStyle(TEXT_FACE, 400, False, BODY)
        var lh = BODY * 1.65
        var b = line.as_bytes()
        var n = len(b)
        # headings
        var hashes = 0
        while hashes < n and b[hashes] == 35:
            hashes += 1
        if hashes > 0 and hashes <= 6 and hashes < n and b[hashes] == 32:
            var size = BODY * (1.9 if hashes == 1 else (1.4 if hashes == 2 else (1.15 if hashes == 3 else 1.0)))
            var hst = TextStyle(DISPLAY_FACE, 700, False, size)
            var hlh = size * 1.25 if hashes == 1 else size * 1.65
            out.append(Seg(String(line[byte=0:hashes + 1]), hst, PAGE_MARKUP, hlh))
            out.append(Seg(String(line[byte=hashes + 1:]), hst, PAGE_INK, hlh))
            return out^
        var i = 0
        var base = body
        var base_color = PAGE_INK
        if n >= 2 and b[0] == 62 and b[1] == 32:  # quote
            base = TextStyle(TEXT_FACE, 400, True, BODY)
            base_color = PAGE_MUTED
            out.append(Seg(">", base, PAGE_MARKUP, lh))
            i = 1
        elif n >= 2 and (b[0] == 45 or b[0] == 42) and b[1] == 32:  # bullet
            out.append(Seg(String(line[byte=0:1]), body, PAGE_MARKUP, lh))
            i = 1
        else:
            var d = 0
            while d < n and b[d] >= 48 and b[d] <= 57:
                d += 1
            if d > 0 and d + 1 < n and b[d] == 46 and b[d + 1] == 32:
                out.append(Seg(String(line[byte=0:d + 1]), body, PAGE_MARKUP, lh))
                i = d + 1
        # inline: **bold**, *italic*, `code`
        var start = i
        while i < n:
            if b[i] == 42 and i + 1 < n and b[i + 1] == 42:
                var close = line.find("**", i + 2)
                if close > i + 2:
                    if i > start:
                        out.append(Seg(String(line[byte=start:i]), base, base_color, lh))
                    var bold = TextStyle(TEXT_FACE, 700, base.italic, BODY)
                    out.append(Seg("**", bold, PAGE_MARKUP, lh))
                    out.append(Seg(String(line[byte=i + 2:close]), bold, base_color, lh))
                    out.append(Seg("**", bold, PAGE_MARKUP, lh))
                    i = close + 2
                    start = i
                    continue
            if b[i] == 42:
                var close = line.find("*", i + 1)
                if close > i + 1:
                    if i > start:
                        out.append(Seg(String(line[byte=start:i]), base, base_color, lh))
                    var it = TextStyle(TEXT_FACE, base.weight, True, BODY)
                    out.append(Seg("*", it, PAGE_MARKUP, lh))
                    out.append(Seg(String(line[byte=i + 1:close]), it, base_color, lh))
                    out.append(Seg("*", it, PAGE_MARKUP, lh))
                    i = close + 1
                    start = i
                    continue
            if b[i] == 96:
                var close = line.find("`", i + 1)
                if close > i:
                    if i > start:
                        out.append(Seg(String(line[byte=start:i]), base, base_color, lh))
                    var mono = TextStyle(MONO_FACE, 400, False, BODY * 0.9)
                    out.append(Seg("`", mono, PAGE_MARKUP, lh))
                    out.append(Seg(String(line[byte=i + 1:close]), mono, base_color, lh))
                    out.append(Seg("`", mono, PAGE_MARKUP, lh))
                    i = close + 1
                    start = i
                    continue
            i += 1
        if start < n:
            out.append(Seg(String(line[byte=start:n]), base, base_color, lh))
        return out^

    def line_box(self, segs: List[Seg]) -> Tuple[Float64, Float64]:
        """(height, baseline from the top) of a line box holding the strut and these pieces."""
        var body = TextStyle(TEXT_FACE, 400, False, BODY)
        var above = _above(body, BODY * 1.65)
        var below = lu(BODY * 1.65) - above
        for ref s in segs:
            var a = _above(s.style, s.lh)
            above = max(above, a)
            below = max(below, lu(s.lh) - a)
        return (lu(above + below), above)

    def draw[P: Painter](mut self, mut p: P, mut bx: Boxes, x0: Float64, y0: Float64, x1: Float64, y1: Float64, k: Float64, emoji: String,
                         tint: UInt32, radius: Float64, mode_draw: Bool = False):
        """The page host filling (x0, y0)–(x1, y1) (its border inside), the desk, toolbar, sheet and text."""
        var w = x1 - x0
        var h = y1 - y0
        draw_bordered(p, x0, y0, w, h, radius, PAGE_DESK, PAGE_LINE)
        bx.add("page.host", x0, y0, w, h)
        var dx = x0 + 1
        var dy = y0 + 1
        var dw = w - 2
        var dh = h - 2
        bx.add("page.desk", dx, dy, dw, dh)
        p.push_clip(dx, dy, dw, dh)
        var stage_w = min(860.0, dw - 32)
        var sx = dx + 16 + (dw - 32 - stage_w) / 2
        self.text_w = stage_w - 220
        var text_h = self._text_height()
        # the sheet (behind the toolbar); in Draw a hint sits under the toolbar and the sheet moves down by its height
        var sheet_at = 28.0 + 44 + 14 - 16 + (27.0 if self.draw_mode else 0.0)
        var paper_h = max(1080.0, text_h + 96 + 360)
        self.content_h = sheet_at + paper_h + 120
        self.view_h = dh
        self.view_top = dy
        if self.follow:  # (the caret moved: scrolled into view, clear of the toolbar)
            self.follow = False
            var at = self._caret_at()
            var cy = sheet_at + 96 + at[0]
            if cy + at[1] + 24 > self.scroll + dh:
                self.scroll = cy + at[1] + 24 - dh
            elif cy - 72 < self.scroll:
                self.scroll = cy - 72
        self.scroll = min(max(self.scroll, 0), max(self.content_h - dh, 0))
        var top = dy + 28 - self.scroll
        var paper_y = dy + sheet_at - self.scroll
        var paper_shadow = List[Shadow]()
        paper_shadow.append(Shadow(0, 1, 0, 0, rgba(31, 27, 22, 15)))
        paper_shadow.append(Shadow(0, 18, 40, -18, rgba(60, 40, 10, 89)))
        draw_lifted(p, sx, paper_y, stage_w, paper_h, 3, paper_shadow, PAGE_PAPER)
        bx.add("page.paper", sx, paper_y, stage_w, paper_h)
        var sheet = 1
        while Float64(sheet) * 1080 < paper_h:  # (where paper would break)
            var my = paper_y + Float64(sheet) * 1080
            if my > dy - 30 and my < dy + dh:
                var dash = sx
                while dash < sx + stage_w:
                    p.rect(dash, my, min(3.0, sx + stage_w - dash), 1, PAGE_LINE, 0)
                    dash += 6
                var mst = TextStyle(UI_FACE, 500, False, 11)
                mst.letter_spacing = 0.66
                var words = "PAGE " + String(sheet + 1)
                text_normal(p, mst, words, sx + stage_w - 14 - measure(mst, words), my + 5, PAGE_FAINT)
            sheet += 1
        if emoji != "":
            draw_emoji_tile(p, emoji, sx + 110, paper_y + 18, 64, 18, 38, mix(tint, 36, PAGE_PAPER))
            bx.add("page.icon", sx + 110, paper_y + 18, 64, 64)
        # the text
        var tx = sx + 110
        var ty = paper_y + 96
        self.text_x = tx
        self.paper_x = sx
        self.paper_y = paper_y
        self.tops.clear()
        var tw = self.text_w
        var joined = String("")
        for ref l in self.ed.paras:
            joined += l
            if joined.byte_length() > 400:
                break
        var name = String(" ".join(String(joined).split()))
        var cps = String("")
        var n = 0
        for c in name.codepoints():
            if n >= 40:
                break
            cps += String(c)
            n += 1
        bx.add("page.editor:" + cps, tx, ty, tw, text_h)
        var sel0 = self.ed.sel_start()
        var sel1 = self.ed.sel_end()
        var selected = self.ed.has_selection() and self.preedit == "" and not self.draw_mode
        var caret = self.ed.caret
        var pre_at = caret.byte if self.preedit != "" else -1
        var at_y = ty
        for para in range(len(self.ed.paras)):
            self.tops.append(at_y)
            at_y += self.lay(para)
        for i in range(len(self.ink.marks)):  # (the highlighter under the words: the web multiplies it over them)
            if self.ink.marks[i].tool == "highlight":
                self._draw_mark(p, i)
        for para in range(len(self.ed.paras)):
            var ph = self.lay(para)
            if ty + ph < dy - 8 and caret.para != para or ty > dy + dh + 8 and caret.para != para:  # (out of view)
                ty += ph
                continue
            var caret_byte = caret.byte + self.preedit.byte_length()
            var caret_v = self.vline_of(Pos(para, caret_byte), self.at_end) if caret.para == para else -1
            for v in range(len(self.laid[para].lines)):
                var l = self.laid[para].lines[v]
                var ly = ty + l.top
                var base = ly + l.base
                ref segs = self.laid[para].segs
                if selected and para >= sel0.para and para <= sel1.para:
                    var from_ = sel0.byte if para == sel0.para else 0
                    var to = sel1.byte if para == sel1.para else self.laid[para].text.byte_length() + 1
                    if from_ <= l.end and to >= l.start and (from_ < l.end or to > l.end or l.start == l.end):
                        var x0_ = tx + (self.width_of(segs, l.start, from_) if from_ > l.start else 0.0)
                        var x1_ = tx + tw if to > l.end else tx + self.width_of(segs, l.start, to)
                        if x1_ > x0_:
                            p.rect(x0_, ly, x1_ - x0_, l.height, PAGE_SELECTION, 0)
                var x = tx
                for ref s in self.part(segs, l.start, l.end):
                    p.run(s.style, s.text, x, base, s.color, ALIGN_LEFT)
                    x += measure(s.style, s.text)
                if pre_at >= 0 and caret.para == para:  # (the composition, underlined as input methods show it)
                    var a = max(pre_at, l.start)
                    var e = min(pre_at + self.preedit.byte_length(), l.end)
                    if e > a:
                        var pre_x0 = tx + self.width_of(segs, l.start, a)
                        p.rect(pre_x0, base + 2, tx + self.width_of(segs, l.start, e) - pre_x0, 1.5, PAGE_INK, 0)
                if v == caret_v and self.show_caret and not self.draw_mode:
                    var caret_x = tx + self.width_of(segs, l.start, caret_byte)
                    var cx = (caret_x - 0.59) if caret_x > tx else tx - 0.59
                    p.rect(cx, ly + 4, 2, 20, PAGE_INK, 0)
                    self.caret_rect = (cx, ly + 4, 2.0, 20.0)
            ty += ph
        # the marks, over the words
        for i in range(len(self.ink.marks)):
            if self.ink.marks[i].tool != "highlight":
                self._draw_mark(p, i)
        if len(self.wet) >= 4:
            var rel = List[Float64]()
            for i in range(0, len(self.wet), 2):
                rel.append(self.wet[i] - self.wet[0])
                rel.append(self.wet[i + 1] - self.wet[1])
            var look = tool_look(self.tool)
            if self.tool == "highlight":
                _smooth(p, self.wet[0], self.wet[1], rel, look[1], look[0])
            else:
                _polyline(p, self.wet[0], self.wet[1], rel, look[1], look[0])
        # the toolbar, sticky at the desk's top
        self._toolbar(p, bx, sx, max(top, dy), stage_w, mode_draw or self.draw_mode)
        if self.draw_mode:
            var hst = TextStyle(UI_FACE, 400, False, 12.5)
            var words = String("Drawing. Press Esc or Write to type again.")
            var hw = measure(hst, words) + 28
            var hx = sx + (stage_w - hw) / 2
            var hy = max(top, dy) + 44 + 8
            p.rect(hx, hy, hw, 27, PAGE_INK, 13.5)
            text_normal(p, hst, words, hx + 14, hy + 6, PAGE_PAPER)
            bx.add("page.draw-hint", hx, hy, hw, 27)
        p.pop_clip()

    def _draw_mark[P: Painter](mut self, mut p: P, i: Int):
        var o = self.mark_origin(i)
        if not o[2]:
            return
        var look = tool_look(self.ink.marks[i].tool)
        if self.ink.marks[i].tool == "highlight":
            _smooth(p, o[0], o[1], self.ink.marks[i].points, look[1], look[0])
        else:
            _polyline(p, o[0], o[1], self.ink.marks[i].points, look[1], look[0])

    def _text_height(mut self) -> Float64:
        var h = 0.0
        for para in range(len(self.ed.paras)):
            h += self.lay(para)
        return h

    def _caret_at(mut self) -> Tuple[Float64, Float64]:
        """The caret's shown line: its top under the text's, and its height."""
        var y = 0.0
        for para in range(self.ed.caret.para):
            y += self.lay(para)
        var v = self.vline_of(Pos(self.ed.caret.para, self.ed.caret.byte + self.preedit.byte_length()), self.at_end)
        var l = self.laid[self.ed.caret.para].lines[v]
        return (y + l.top, l.height)

    def _toolbar[P: Painter](self, mut p: P, mut bx: Boxes, sx: Float64, y: Float64, stage_w: Float64, mode_draw: Bool):
        var st = TextStyle(UI_FACE, 500, False, 13)
        var groups = List[List[String]]()
        groups.append(["Write", "Draw"])
        groups.append(["Pen", "Red", "Highlighter", "Eraser"])
        groups.append(["Rectangle", "Ellipse", "Text"])
        var swatch: List[UInt32] = [hexc("#1d3f9e"), hexc("#d23b26"), hexc("#ffd400")]
        var tools: List[String] = ["pen", "red", "highlight", "eraser"]
        var group_names: List[String] = ["page.group:Mode", "page.group:Ink", "page.group:Shapes and text"]
        # widths first (max-content), then centred
        var widths = List[List[Float64]]()
        var total = 16.0
        for g in range(3):
            var ws = List[Float64]()
            for bi in range(len(groups[g])):
                var bw = 22 + measure(st, groups[g][bi]) + (16.0 if g == 1 and bi < 3 else 0.0)
                ws.append(bw)
                total += bw + (4.0 if bi > 0 else 0.0)
            widths.append(ws^)
        total += 14 * 3  # (the web's toolbar has a fourth, empty item: one more 14 px gap after the shapes, measured)
        var x = sx + (stage_w - total) / 2
        draw_lifted(p, x, y, total, 44, 12, _shadow2(), PAGE_PAPER)
        bx.add("page.tools", x, y, total, 44)
        var bxp = x + 8
        for g in range(3):
            var gx = bxp
            for bi in range(len(groups[g])):
                if bi > 0:
                    bxp += 4
                var bw = widths[g][bi]
                var on = (g == 0 and ((bi == 0) != mode_draw)) or (g == 1 and mode_draw and tools[bi] == self.tool)
                draw_bordered(p, bxp, y + 6, bw, 32, 8, PAGE_INK if on else PAGE_PAPER, PAGE_INK if on else PAGE_LINE)
                var lx = bxp + 11
                if g == 1 and bi < 3:
                    p.circle(lx + 5, y + 6 + 16, 5, swatch[bi])
                    lx += 16
                text_normal(p, st, groups[g][bi], lx, y + 6 + 8.5, PAGE_PAPER if on else PAGE_INK)
                bx.add("page.tool:" + groups[g][bi], bxp, y + 6, bw, 32)
                bxp += bw
            bx.add(group_names[g], gx, y + 6, bxp - gx, 32)
            bxp += 14


def _may_break(before: Int, x: Int, y: Int) -> Bool:
    """A line may end between characters x and y (before: the one before x): after a space, where Chrome breaks printable
    ASCII, and between ideographs and kana (not before their closing marks)."""
    if x == 32 or x == 9:
        return True
    if y == 32 or y == 9:
        return False
    if x < 128 and y < 128:
        return browser_breaks(before, x, y)
    if x == 0x2014 or x == 0x2013 or x == 0x200B:  # (after a dash)
        return y != 0x2014
    if y == 0x2014:  # (an em dash may start a line)
        return True
    if y == 0x3001 or y == 0x3002 or y == 0x300D or y == 0x300F or y == 0xFF09 or y == 0xFF0C or y == 0xFF1A or y == 0xFF01 or y == 0xFF1F or y == 0x30FC or y == 0x3063 or y == 0x30C3:
        return False
    if x == 0x300C or x == 0x300E or x == 0xFF08:
        return False
    return _ideograph(x) or _ideograph(y)


def _ideograph(c: Int) -> Bool:
    return (0x2E80 <= c <= 0x9FFF) or (0xAC00 <= c <= 0xD7A3) or (0xF900 <= c <= 0xFAFF) or (0xFF00 <= c <= 0xFFEF) or (0x1F300 <= c <= 0x1FAFF) or (0x20000 <= c <= 0x3FFFF)


def _shadow2() -> List[Shadow]:
    var s = List[Shadow]()
    s.append(Shadow(0, 6, 18, 0, rgba(20, 16, 10, 26)))
    s.append(Shadow(0, 0, 0, 1, rgba(20, 16, 10, 14)))
    return s^


def _above(st: TextStyle, lh: Float64) -> Float64:
    """How far above its baseline an inline box of this style and line-height reaches (half-leading floored + ascent)."""
    var m = line_metrics(st)
    var half = (lu(lh) - Float64(m.ascent + m.descent)) / 2
    var hf = Float64(Int(half)) if half >= 0 else -Float64(Int(-half + 0.999999))
    return hf + Float64(m.ascent)


def _polyline[P: Painter](mut p: P, x0: Float64, y0: Float64, pts: List[Float64], width: Float64, color: UInt32):
    """A stroke through points (relative to (x0, y0)) with round caps and joins."""
    for i in range(0, len(pts) - 2, 2):
        p.line(x0 + pts[i], y0 + pts[i + 1], x0 + pts[i + 2], y0 + pts[i + 3], width, color)
    for i in range(0, len(pts), 2):
        p.circle(x0 + pts[i], y0 + pts[i + 1], width / 2, color)


def tool_look(tool: String) -> Tuple[UInt32, Float64]:
    """A pen's colour and width (strokes.js TOOLS)."""
    if tool == "red":
        return (hexc("#d23b26"), 2.6)
    if tool == "highlight":
        return (with_alpha(hexc("#ffd400"), 0.38), 16.0)
    return (hexc("#1d3f9e"), 2.4)


def _smooth[P: Painter](mut p: P, x0: Float64, y0: Float64, pts: List[Float64], width: Float64, color: UInt32):
    """A translucent stroke: one op, so it doesn't darken where it crosses itself."""
    var abs_pts = List[Float64](capacity=len(pts))
    for i in range(0, len(pts) - 1, 2):
        abs_pts.append(x0 + pts[i])
        abs_pts.append(y0 + pts[i + 1])
    p.stroke(abs_pts, width, color)

