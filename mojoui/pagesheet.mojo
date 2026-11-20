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
struct Seg(Copyable, Movable):
    var text: String
    var style: TextStyle
    var color: UInt32
    var lh: Float64  # the line-height its inline box asks for


struct PageSheet(Movable):
    var lines: List[String]
    var caret_line: Int  # -1: no caret drawn
    var scroll: Float64

    def __init__(out self):
        self.lines = List[String]()
        self.caret_line = -1
        self.scroll = 0

    def set_markdown(mut self, md: String):
        self.lines.clear()
        for l in md.split("\n"):
            self.lines.append(String(l))
        # CodeMirror keeps the text's last newline as an empty last line
        self.caret_line = len(self.lines) - 1

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

    def draw[P: Painter](self, mut p: P, mut bx: Boxes, x0: Float64, y0: Float64, x1: Float64, y1: Float64, k: Float64, emoji: String,
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
        # the sheet (behind the toolbar)
        var paper_y = top + 44 + 14 - 16
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
            var segs = self.segments(self.lines[li])
            var lb = self.line_box(segs)
            var base = ty + lb[1]
            var x = tx
            for ref s in segs:
                p.run(s.style, s.text, x, base, s.color, ALIGN_LEFT)
                x += measure(s.style, s.text)
            if li == self.caret_line:
                p.rect(tx - 0.59, ty + 4, 2, 20, PAGE_INK, 0)
            ty += lb[0]
        # the toolbar, sticky at the desk's top
        self._toolbar(p, bx, sx, max(top, dy), stage_w, mode_draw)
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
                var on = (g == 0 and ((bi == 0) != mode_draw))
                draw_bordered(p, bxp, y + 6, bw, 32, 8, PAGE_INK if on else PAGE_PAPER, PAGE_INK if on else PAGE_LINE)
                var lx = bxp + 11
                if g == 1 and bi < 3:
                    p.circle(lx + 5, y + 6 + 16, 5, swatch[bi])
                    lx += 16
                text_normal(p, st, groups[g][bi], lx, y + 6 + 8.5, PAGE_PAPER if on else PAGE_INK)
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
