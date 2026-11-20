# mojoui.pagesheet (goal 79): a page note drawn the way Personal Note's web page looks: an ivory sheet on a warm desk
# inside a rounded host, the Write/Draw toolbar floating over its top edge, the note's emoji tile, and the Markdown text
# with its marks shown quietly (CodeMirror's look: Literata 18/1.65, Bricolage headings, marks in the markup colour,
# quotes muted italic, code in Geist Mono at .9em). Line boxes follow CSS (half-leading floored, heights in 1/64 px).
#
#   var page = PageSheet(); page.set_markdown(md)
#   page.draw(p, bx, x0, y0, x1, y1, k, emoji, tint)

from mojoui.scene import Painter
from mojoui.skin import Skin, Shadow, mix, with_alpha, hexc
from mojoui.fonttext import TextStyle, measure, line_metrics, ALIGN_LEFT, ALIGN_CENTER
from mojoui.notesshell import Boxes, draw_shadows, draw_bordered, draw_emoji_tile, text_at, text_normal
from mojoui.canvas import rgba
from mojoui.json import json_string

comptime PAGE_DESK: UInt32 = 0xFFDAE4E9  # #e9e4da
comptime PAGE_PAPER: UInt32 = 0xFFF8FDFF  # #fffdf8
comptime PAGE_INK: UInt32 = 0xFF161B1F  # #1f1b16
comptime PAGE_MUTED: UInt32 = 0xFF57636B  # #6b6357
comptime PAGE_LINE: UInt32 = 0xFFCDDBE2  # #e2dbcd
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
struct PageMark(Copyable, Movable):
    """A pen mark drawn over the page (the web's ink.marks): its points relative to its start (x0, y0), both in the paper's
    own px; the tool's colour and width; the word it is anchored to (a char range of the Markdown) and its offset."""
    var x0: Float64
    var y0: Float64
    var points: List[Float64]
    var color: UInt32
    var width: Float64
    var tool: String
    var pos: Int
    var end: Int
    var dx: Float64
    var dy: Float64


@fieldwise_init
struct Seg(Copyable, Movable):
    var text: String
    var style: TextStyle
    var color: UInt32
    var lh: Float64  # the line-height its inline box asks for


struct PageSheet(Movable):
    var lines: List[String]
    var caret_line: Int  # -1: no caret drawn
    var caret_col: Int  # byte column in its line
    var preedit: String  # an input method's composition, shown at the caret, underlined (not in the text)
    var caret_rect: Tuple[Float64, Float64, Float64, Float64]  # where the caret was last drawn (layout px)
    var scroll: Float64
    # where the last draw put each line (for a tap's caret): top, height; the text's left; the paper's origin
    var line_top: List[Float64]
    var line_h: List[Float64]
    var text_x: Float64
    var paper_x: Float64
    var paper_y: Float64
    var draw_mode: Bool  # Draw (a press on the page makes a pen mark) or Write
    var marks: List[PageMark]
    var wet: List[Float64]  # the mark being drawn (layout px), empty: none

    def __init__(out self):
        self.lines = List[String]()
        self.caret_line = -1
        self.caret_col = 0
        self.preedit = ""
        self.caret_rect = (-1.0, 0.0, 0.0, 0.0)
        self.scroll = 0
        self.line_top = List[Float64]()
        self.line_h = List[Float64]()
        self.text_x = 0
        self.paper_x = 0
        self.paper_y = 0
        self.draw_mode = False
        self.marks = List[PageMark]()
        self.wet = List[Float64]()

    def set_markdown(mut self, md: String):
        self.lines.clear()
        for l in md.split("\n"):
            self.lines.append(String(l))
        # CodeMirror keeps the text's last newline as an empty last line
        self.caret_line = len(self.lines) - 1
        self.caret_col = self.lines[self.caret_line].byte_length()
        self.preedit = ""

    def markdown(self) -> String:
        return "\n".join(self.lines)

    # ------------------------------------------------ editing (goal 79 M5: typed keys, input-method commits, pastes)

    def caret_home(mut self):
        self.caret_col = 0

    def caret_line_end(mut self):
        self.caret_col = self.lines[self.caret_line].byte_length()

    def caret_left(mut self):
        if self.caret_col > 0:
            var b = self.lines[self.caret_line].as_bytes()
            var at = self.caret_col - 1
            while at > 0 and (Int(b[at]) & 0xC0) == 0x80:
                at -= 1
            self.caret_col = at
        elif self.caret_line > 0:
            self.caret_line -= 1
            self.caret_col = self.lines[self.caret_line].byte_length()

    def caret_right(mut self):
        var b = self.lines[self.caret_line].as_bytes()
        if self.caret_col < len(b):
            var at = self.caret_col + 1
            while at < len(b) and (Int(b[at]) & 0xC0) == 0x80:
                at += 1
            self.caret_col = at
        elif self.caret_line + 1 < len(self.lines):
            self.caret_line += 1
            self.caret_col = 0

    def delete_forward(mut self):
        """Delete: the character after the caret (at a line's end, the next line joins it)."""
        var n = self.lines[self.caret_line].byte_length()
        if self.caret_col >= n and self.caret_line + 1 >= len(self.lines):
            return
        self.caret_right()
        self.backspace()

    def tap(mut self, x: Float64, y: Float64) -> Bool:
        """A tap on the text: the caret at the nearest character boundary of the line under it (as the last draw laid it
        out). False when the tap is not on a line (the web starts a mark there)."""
        for li in range(len(self.line_top)):
            if y >= self.line_top[li] and y < self.line_top[li] + self.line_h[li]:
                var segs = self.segments(self.lines[li])
                var px = self.text_x
                var off = 0
                var best = 0
                var best_d = abs(x - px)
                for ref sg in segs:
                    var acc = String("")
                    var k = 0
                    for c in sg.text.codepoint_slices():
                        acc += String(c)
                        k += String(c).byte_length()
                        var cx = px + measure(sg.style, acc)
                        if abs(x - cx) < best_d:
                            best_d = abs(x - cx)
                            best = off + k
                    px += measure(sg.style, sg.text)
                    off += sg.text.byte_length()
                # (the web's onText: a press types only on a line with words, from 6 px before them to 28 px past them;
                # elsewhere it starts a mark)
                if self.lines[li].byte_length() == 0 or x < self.text_x - 6 or x > px + 28:
                    return False
                self.caret_line = li
                self.caret_col = best
                return True
        return False

    # ------------------------------------------------ Draw mode: pen marks over the page (the web's ink layer)

    def mark_press(mut self, x: Float64, y: Float64):
        self.wet.clear()
        self.wet.append(x)
        self.wet.append(y)

    def mark_move(mut self, x: Float64, y: Float64):
        if len(self.wet) > 0:
            self.wet.append(x)
            self.wet.append(y)

    def mark_release(mut self) -> Bool:
        """The mark being drawn becomes a mark of the page (anchored to the word nearest its start); True when it had
        length."""
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
        self.marks.append(PageMark(x0 - self.paper_x, y0 - self.paper_y, pts^, hexc("#1d3f9e"), 2.4, "pen", anchor[0], anchor[1],
                                   anchor[2], anchor[3]))
        self.wet.clear()
        return True

    def _nearest_word(self, x: Float64, y: Float64, cx: Float64, cy: Float64) -> Tuple[Int, Int, Float64, Float64]:
        """(start, end) of the word whose box is nearest (x, y), as offsets into the Markdown, and (cx, cy) from the box of
        its first character (its left, its line's top)."""
        var best = (0, 0, 0.0, 0.0)
        var best_d = 1e300
        var base = 0
        for li in range(len(self.line_top)):
            if li >= len(self.lines):
                break
            var segs = self.segments(self.lines[li])
            var px = self.text_x
            var off = 0
            var ly = self.line_top[li] + self.line_h[li] / 2
            for ref sg in segs:
                var words = sg.text.split(" ")
                var wx = px
                var woff = off
                for wd in words:
                    var w = String(wd)
                    var ww = measure(sg.style, w)
                    if w.byte_length() > 0:
                        var cx = max(wx, min(x, wx + ww))
                        var d = (x - cx) * (x - cx) + (y - ly) * (y - ly)
                        if d < best_d:
                            best_d = d
                            best = (base + woff, base + woff + w.byte_length(), cx - wx, cy - self.line_top[li])
                    wx += ww + measure(sg.style, " ")
                    woff += w.byte_length() + 1
                px += measure(sg.style, sg.text)
                off += sg.text.byte_length()
            base += self.lines[li].byte_length() + 1
        return best

    def ink_json(self) -> String:
        """The marks as the web stores them in a page's content.ink ({marks, drawings})."""
        var out = String('{"marks":[')
        for i in range(len(self.marks)):
            ref m = self.marks[i]
            if i > 0:
                out += ","
            out += '{"id":"m' + String(i) + "-" + String(Int(m.x0)) + String(Int(m.y0)) + '","tool":"' + m.tool + '","points":['
            for k in range(0, len(m.points), 2):
                if k > 0:
                    out += ","
                out += "[" + _num(m.points[k]) + "," + _num(m.points[k + 1]) + "]"
            var md = self.markdown()
            var exact = String(md[byte=m.pos:m.end]) if m.end <= md.byte_length() else String("")
            out += '],"anchor":{"pos":' + String(m.pos) + ',"end":' + String(m.end) + ',"quote":{"exact":' + json_string(exact) + "}}"
            out += ',"dx":' + _num(m.dx) + ',"dy":' + _num(m.dy) + "}"
        return out + '],"drawings":[]}'

    def caret_end(mut self):
        self.caret_line = len(self.lines) - 1
        self.caret_col = self.lines[self.caret_line].byte_length()

    def insert(mut self, text: String):
        """Text at the caret (a newline in it splits the line); the caret ends after it."""
        var parts = text.split("\n")
        for i in range(len(parts)):
            if i > 0:
                self.newline()
            var part = String(parts[i])
            ref l = self.lines[self.caret_line]
            var before = String(l[byte=0:self.caret_col])
            var after = String(l[byte=self.caret_col:])
            self.lines[self.caret_line] = before + part + after
            self.caret_col += part.byte_length()

    def newline(mut self):
        ref l = self.lines[self.caret_line]
        var before = String(l[byte=0:self.caret_col])
        var after = String(l[byte=self.caret_col:])
        self.lines[self.caret_line] = before
        self.lines.insert(self.caret_line + 1, after)
        self.caret_line += 1
        self.caret_col = 0

    def backspace(mut self):
        if self.caret_col > 0:
            ref l = self.lines[self.caret_line]
            var b = l.as_bytes()
            var at = self.caret_col - 1
            while at > 0 and (Int(b[at]) & 0xC0) == 0x80:  # (a whole UTF-8 character)
                at -= 1
            self.lines[self.caret_line] = String(l[byte=0:at]) + String(l[byte=self.caret_col:])
            self.caret_col = at
        elif self.caret_line > 0:
            var col = self.lines[self.caret_line - 1].byte_length()
            self.lines[self.caret_line - 1] = self.lines[self.caret_line - 1] + self.lines[self.caret_line]
            _ = self.lines.pop(self.caret_line)
            self.caret_line -= 1
            self.caret_col = col

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
        bx.add("#page-host", x0, y0, w, h)
        var dx = x0 + 1
        var dy = y0 + 1
        var dw = w - 2
        var dh = h - 2
        bx.add(".page-desk", dx, dy, dw, dh)
        p.push_clip(dx, dy, dw, dh)
        var stage_w = min(860.0, dw - 32)
        var sx = dx + 16 + (dw - 32 - stage_w) / 2
        var top = dy + 28 - self.scroll
        # the sheet (behind the toolbar); in Draw a hint sits under the toolbar and the sheet moves down by its height
        var paper_y = top + 44 + 14 - 16 + (27.0 if self.draw_mode else 0.0)
        var paper_h = max(1080.0, self._text_height() + 96 + 360)
        var paper_shadow = List[Shadow]()
        paper_shadow.append(Shadow(0, 1, 0, 0, rgba(31, 27, 22, 15)))
        paper_shadow.append(Shadow(0, 18, 40, -18, rgba(60, 40, 10, 89)))
        draw_shadows(p, sx, paper_y, stage_w, paper_h, 3, paper_shadow)
        p.rect(sx, paper_y, stage_w, paper_h, PAGE_PAPER, 3)
        bx.add(".page-paper", sx, paper_y, stage_w, paper_h)
        if emoji != "":
            draw_emoji_tile(p, emoji, sx + 110, paper_y + 18, 64, 18, 38, mix(tint, 36, PAGE_PAPER))
            bx.add("[Change icon]", sx + 110, paper_y + 18, 64, 64)
        # the text
        var tx = sx + 110
        var ty = paper_y + 96
        self.text_x = tx
        self.paper_x = sx
        self.paper_y = paper_y
        self.line_top.clear()
        self.line_h.clear()
        var tw = stage_w - 220
        var joined = String("")
        for ref l in self.lines:
            joined += l
        var name = String(" ".join(String(joined).split()))
        var cps = String("")
        var n = 0
        for c in name.codepoints():
            if n >= 40:
                break
            cps += String(c)
            n += 1
        bx.add(".page-editor:" + cps, tx, ty, tw, self._text_height())
        for li in range(len(self.lines)):
            var shown = self.lines[li]
            var pre_at = -1
            if li == self.caret_line and self.preedit != "":
                shown = String(shown[byte=0:self.caret_col]) + self.preedit + String(shown[byte=self.caret_col:])
                pre_at = self.caret_col
            var segs = self.segments(shown)
            var lb = self.line_box(segs)
            self.line_top.append(ty)
            self.line_h.append(lb[0])
            var base = ty + lb[1]
            var x = tx
            var off = 0
            var caret_x = tx
            var pre_x0 = -1.0
            var pre_x1 = -1.0
            var caret_col = self.caret_col + self.preedit.byte_length() if li == self.caret_line else -1
            for ref s in segs:
                var n = s.text.byte_length()
                if caret_col >= off and caret_col <= off + n:
                    caret_x = x + measure(s.style, String(s.text[byte=0:caret_col - off]))
                if pre_at >= 0:
                    var e = pre_at + self.preedit.byte_length()
                    if pre_at >= off and pre_at <= off + n and pre_x0 < 0:
                        pre_x0 = x + measure(s.style, String(s.text[byte=0:pre_at - off]))
                    if e >= off and e <= off + n:
                        pre_x1 = x + measure(s.style, String(s.text[byte=0:e - off]))
                p.run(s.style, s.text, x, base, s.color, ALIGN_LEFT)
                x += measure(s.style, s.text)
                off += n
            if pre_x0 >= 0 and pre_x1 > pre_x0:  # (the composition, underlined as input methods show it)
                p.rect(pre_x0, base + 2, pre_x1 - pre_x0, 1.5, PAGE_INK, 0)
            if li == self.caret_line and not self.draw_mode:
                var cx = (caret_x - 0.59) if caret_x > tx else tx - 0.59
                p.rect(cx, ty + 4, 2, 20, PAGE_INK, 0)
                self.caret_rect = (cx, ty + 4, 2.0, 20.0)
            ty += lb[0]
        # the marks, over the words
        for ref m in self.marks:
            _polyline(p, sx + m.x0, paper_y + m.y0, m.points, m.width, m.color)
        if len(self.wet) >= 4:
            var rel = List[Float64]()
            for i in range(0, len(self.wet), 2):
                rel.append(self.wet[i] - self.wet[0])
                rel.append(self.wet[i + 1] - self.wet[1])
            _polyline(p, self.wet[0], self.wet[1], rel, 2.4, hexc("#1d3f9e"))
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
            bx.add(".page-draw-hint", hx, hy, hw, 27)
        p.pop_clip()

    def _text_height(self) -> Float64:
        var h = 0.0
        for li in range(len(self.lines)):
            h += self.line_box(self.segments(self.lines[li]))[0]
        return h

    def _toolbar[P: Painter](self, mut p: P, mut bx: Boxes, sx: Float64, y: Float64, stage_w: Float64, mode_draw: Bool):
        var st = TextStyle(UI_FACE, 500, False, 13)
        var groups = List[List[String]]()
        groups.append(["Write", "Draw"])
        groups.append(["Pen", "Red", "Highlighter", "Eraser"])
        groups.append(["Rectangle", "Ellipse", "Text"])
        var swatch: List[UInt32] = [hexc("#1d3f9e"), hexc("#d23b26"), hexc("#ffd400")]
        var group_names: List[String] = ["[Mode]", "[Ink]", "[Shapes and text]"]
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
        draw_shadows(p, x, y, total, 44, 12, _shadow2())
        p.rect(x, y, total, 44, PAGE_PAPER, 12)
        bx.add("[Page tools]", x, y, total, 44)
        var bxp = x + 8
        for g in range(3):
            var gx = bxp
            for bi in range(len(groups[g])):
                if bi > 0:
                    bxp += 4
                var bw = widths[g][bi]
                var on = (g == 0 and ((bi == 0) != mode_draw)) or (g == 1 and bi == 0 and mode_draw)
                draw_bordered(p, bxp, y + 6, bw, 32, 8, PAGE_INK if on else PAGE_PAPER, PAGE_INK if on else PAGE_LINE)
                var lx = bxp + 11
                if g == 1 and bi < 3:
                    p.circle(lx + 5, y + 6 + 16, 5, swatch[bi])
                    lx += 16
                text_normal(p, st, groups[g][bi], lx, y + 6 + 8.5, PAGE_PAPER if on else PAGE_INK)
                bx.add(".page-tool:" + groups[g][bi], bxp, y + 6, bw, 32)
                bxp += bw
            bx.add(group_names[g], gx, y + 6, bxp - gx, 32)
            bxp += 14


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


def _num(v: Float64) -> String:
    if v == Float64(Int(v)):
        return String(Int(v))
    return String(v)

