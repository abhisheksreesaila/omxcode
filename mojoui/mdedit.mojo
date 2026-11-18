# mojoui.mdedit: Markdown drawn and edited natively (goal 74 M3). The text stays plain Markdown in a mojoui.textedit
# TextEdit; MdStyler tells the editor how each paragraph looks: headings big, **bold**, *italic*, `code`, [links](url),
# ~~strike~~, bullet and numbered lists, task boxes, > quotes, ``` code blocks and --- rules. The marks (#, **, `, - [ ])
# are hidden except on the caret's paragraph, where they show so they can be edited (live preview, as Obsidian and
# Personal Note do). A click on a task box ticks it (one undo step).
#
#   var md = MdEdit("# Groceries\n- [ ] milk")
#   md.ed.resize(w, h)
#   md.key(name, mods, now_ms, font); md.press(x, y, shift, font)
#   md.paint(painter, font, x0, y0)

from mojoui.textedit import (
    TextEdit, Styler, ParaLook, StyleSpan, Pos, BLOCK_NONE, BLOCK_QUOTE, BLOCK_CODE, BLOCK_RULE, EDIT_OTHER,
)
from mojoui.text import Font, REGULAR, MEDIUM, MONO
from mojoui.scene import Painter
from mojoui.canvas import rgba

comptime FENCE_NONE = 0
comptime FENCE_LINE = 1  # a ``` line
comptime FENCE_BODY = 2  # inside a code block


def _starts(text: String, at: Int, with_: String) -> Bool:
    var b = text.as_bytes()
    var w = with_.as_bytes()
    if at + len(w) > len(b):
        return False
    for i in range(len(w)):
        if b[at + i] != w[i]:
            return False
    return True


def _find(text: String, at: Int, what: String) -> Int:
    var b = text.as_bytes()
    var w = what.as_bytes()
    var i = at
    while i + len(w) <= len(b):
        var ok = True
        for k in range(len(w)):
            if b[i + k] != w[k]:
                ok = False
                break
        if ok:
            return i
        i += 1
    return -1


struct MdStyler(Styler, Copyable, Movable):
    var size: Float64
    var text_color: UInt32
    var muted: UInt32  # the marks when shown, done tasks
    var accent: UInt32  # links, task boxes, bullets
    var code_back: UInt32
    var quote_bar: UInt32
    var page: UInt32
    var fence: List[Int]  # per paragraph: FENCE_*
    var ver: Int

    def __init__(out self, size: Float64 = 16):
        self.size = size
        self.text_color = rgba(34, 32, 30)
        self.muted = rgba(150, 144, 138)
        self.accent = rgba(37, 99, 235)
        self.code_back = rgba(243, 240, 236)
        self.quote_bar = rgba(208, 200, 190)
        self.page = rgba(255, 255, 255)
        self.fence = List[Int]()
        self.ver = 0

    def version(self) -> Int:
        return self.ver

    def span(self, a: Int, b: Int, size: Float64, weight: Int, color: UInt32, role: String, hidden: Bool = False,
             slant: Float64 = 0, back: UInt32 = 0, underline: Bool = False, strike: Bool = False) -> StyleSpan:
        return StyleSpan(a, b, size, weight, color, slant, hidden, back, underline, strike, role)

    def mark(self, a: Int, b: Int, size: Float64, shown: Bool) -> StyleSpan:
        return StyleSpan(a, b, size, REGULAR, self.muted, 0, not shown, 0, False, False, "mark")

    def inline(self, text: String, start: Int, size: Float64, weight: Int, color: UInt32, shown: Bool, mut out: List[StyleSpan],
               strike_all: Bool = False):
        """Spans for text[start:] with inline styles; the delimiters are marks (hidden unless shown)."""
        var b = text.as_bytes()
        var n = len(b)
        var bold = False
        var italic = False
        var strike = strike_all
        var run_start = start
        var i = start

        @parameter
        def flush(upto: Int):
            if upto > run_start:
                var w = MEDIUM if (bold or weight == MEDIUM) else weight
                var role = "bold" if bold else ("italic" if italic else ("strike" if strike and not strike_all else "text"))
                out.append(self.span(run_start, upto, size, w, color, role, False, 0.2 if italic else 0.0, 0, False, strike))

        while i < n:
            var c = Int(b[i])
            if c == 96:  # ` code
                var close = _find(text, i + 1, "`")
                if close > i + 1:
                    flush(i)
                    out.append(self.mark(i, i + 1, size, shown))
                    out.append(self.span(i + 1, close, size * 0.92, MONO, color, "code", False, 0, self.code_back))
                    out.append(self.mark(close, close + 1, size, shown))
                    i = close + 1
                    run_start = i
                    continue
            elif c == 42 and i + 1 < n and Int(b[i + 1]) == 42:  # ** bold
                if bold or _find(text, i + 2, "**") > i + 2:
                    flush(i)
                    out.append(self.mark(i, i + 2, size, shown))
                    bold = not bold
                    i += 2
                    run_start = i
                    continue
            elif (c == 42 or c == 95) and i + 1 < n and Int(b[i + 1]) != 32:  # *italic* _italic_
                var d = String(text[byte = i : i + 1])
                if italic or _find(text, i + 1, d) > i + 1:
                    flush(i)
                    out.append(self.mark(i, i + 1, size, shown))
                    italic = not italic
                    i += 1
                    run_start = i
                    continue
            elif italic and (c == 42 or c == 95):  # (closing italic before a space)
                flush(i)
                out.append(self.mark(i, i + 1, size, shown))
                italic = False
                i += 1
                run_start = i
                continue
            elif c == 126 and i + 1 < n and Int(b[i + 1]) == 126:  # ~~ strike
                if strike or _find(text, i + 2, "~~") > i + 2:
                    flush(i)
                    out.append(self.mark(i, i + 2, size, shown))
                    strike = not strike
                    i += 2
                    run_start = i
                    continue
            elif c == 91:  # [text](url)
                var mid = _find(text, i + 1, "](")
                var close = _find(text, mid + 2, ")") if mid > i else -1
                if mid > i and close > mid:
                    flush(i)
                    out.append(self.mark(i, i + 1, size, shown))
                    out.append(self.span(i + 1, mid, size, weight, self.accent, "link", False, 0, 0, True))
                    out.append(self.mark(mid, close + 1, size, shown))
                    i = close + 1
                    run_start = i
                    continue
            i += 1
        flush(n)

    def look(self, text: String, index: Int, caret_here: Bool) -> ParaLook:
        var n = text.byte_length()
        var look = ParaLook(self.size, self.text_color, n)
        look.spans = List[StyleSpan]()
        look.marker_back = self.page
        var f = self.fence[index] if index < len(self.fence) else FENCE_NONE
        if f != FENCE_NONE:
            look.block = BLOCK_CODE
            look.block_color = self.code_back
            look.role = "code"
            look.gap = 1.5
            look.indent = 6
            if f == FENCE_LINE:
                look.spans.append(self.span(0, n, self.size * 0.8, MONO, self.muted, "mark", not caret_here))
            else:
                look.spans.append(self.span(0, n, self.size * 0.9, MONO, self.text_color, "code"))
            return look^
        var b = text.as_bytes()
        # leading spaces: nesting for lists
        var lead = 0
        while lead < n and b[lead] == 32:
            lead += 1
        var level = lead // 2
        # heading
        var h = 0
        while h < n and h < 6 and b[h] == 35:
            h += 1
        if h > 0 and h < n and b[h] == 32:
            var sizes: List[Float64] = [1.9, 1.5, 1.25, 1.1, 1.0, 0.95]
            var sz = self.size * sizes[h - 1]
            look.role = "h" + String(h)
            look.before = sz * (0.5 if h <= 2 else 0.3)
            look.after = sz * 0.15
            look.gap = 1.3
            look.spans.append(self.mark(0, h + 1, sz, caret_here))
            self.inline(text, h + 1, sz, MEDIUM, self.text_color, caret_here, look.spans)
            return look^
        # rule
        var t = String(text.strip())
        if t == "---" or t == "***" or t == "___":
            look.block = BLOCK_RULE
            look.block_color = self.quote_bar
            look.role = "rule"
            look.spans.append(self.mark(0, n, self.size, caret_here))
            return look^
        # quote
        if _starts(text, 0, "> "):
            look.block = BLOCK_QUOTE
            look.block_color = self.quote_bar
            look.indent = 16
            look.role = "quote"
            look.spans.append(self.mark(0, 2, self.size, caret_here))
            self.inline(text, 2, self.size, REGULAR, self.muted, caret_here, look.spans)
            return look^
        # task / bullet / numbered
        if lead + 1 < n and (b[lead] == 45 or b[lead] == 42 or b[lead] == 43) and b[lead + 1] == 32:
            var indent = 26.0 + 22.0 * Float64(level)
            if _starts(text, lead + 2, "[ ] ") or _starts(text, lead + 2, "[x] ") or _starts(text, lead + 2, "[X] "):
                var done = b[lead + 3] != 32
                look.role = "task"
                look.spans.append(self.mark(0, lead + 6, self.size, caret_here))
                self.inline(text, lead + 6, self.size, REGULAR, self.muted if done else self.text_color, caret_here, look.spans, done)
                if not caret_here:
                    look.indent = indent
                    look.marker_role = "done" if done else "task"
                    look.marker_color = self.accent if not done else self.muted
                return look^
            look.role = "li"
            look.spans.append(self.mark(0, lead + 2, self.size, caret_here))
            self.inline(text, lead + 2, self.size, REGULAR, self.text_color, caret_here, look.spans)
            if not caret_here:
                look.indent = indent
                look.marker_role = "bullet"
                look.marker_color = self.muted
            return look^
        var d = lead
        while d < n and b[d] >= 48 and b[d] <= 57:
            d += 1
        if d > lead and d + 1 < n and b[d] == 46 and b[d + 1] == 32:
            look.role = "ol"
            look.spans.append(self.mark(0, d + 2, self.size, caret_here))
            self.inline(text, d + 2, self.size, REGULAR, self.text_color, caret_here, look.spans)
            if not caret_here:
                look.indent = 26.0 + 22.0 * Float64(level)
                look.marker_role = "number"
                look.marker = String(text[byte = lead : d + 1])
                look.marker_color = self.muted
            return look^
        look.role = "p"
        look.after = self.size * 0.35
        self.inline(text, 0, self.size, REGULAR, self.text_color, caret_here, look.spans)
        if len(look.spans) == 0:
            look.spans.append(self.span(0, n, self.size, REGULAR, self.text_color, "text"))
        return look^


struct MdEdit(Movable):
    """A TextEdit that shows its text as Markdown."""

    var ed: TextEdit
    var st: MdStyler
    var fenced_at: Int  # the text version the fences were found for

    def __init__(out self, text: String = "", size: Float64 = 16):
        self.ed = TextEdit(text)
        self.st = MdStyler(size)
        self.fenced_at = -1
        self.sync()

    def sync(mut self):
        """Find the code blocks again after an edit (a ``` line can open or close one far away)."""
        if self.fenced_at == self.ed.version:
            return
        self.fenced_at = self.ed.version
        var fence = List[Int](capacity=len(self.ed.paras))
        var inside = False
        for ref p in self.ed.paras:
            if _starts(p, 0, "```"):
                fence.append(FENCE_LINE)
                inside = not inside
            else:
                fence.append(FENCE_BODY if inside else FENCE_NONE)
        var changed = len(fence) != len(self.st.fence)
        if not changed:
            for i in range(len(fence)):
                if fence[i] != self.st.fence[i]:
                    changed = True
                    break
        if changed:
            self.st.fence = fence^
            self.st.ver += 1

    def key(mut self, name: String, mods: Int, now_ms: Int, font: Font) -> Bool:
        self.sync()
        var used = self.ed.key(name, mods, now_ms, font, self.st)
        if used and name == "Enter" and mods == 0:
            self.continue_list(now_ms)
        self.sync()
        return used

    def continue_list(mut self, now_ms: Int):
        """Enter in a list item starts the next item ("- ", "- [ ] ", "2. "); Enter on an empty item ends the list."""
        var i = self.ed.caret.para
        if i == 0:
            return
        var prev = self.ed.paras[i - 1]
        var b = prev.as_bytes()
        var lead = 0
        while lead < len(b) and b[lead] == 32:
            lead += 1
        var prefix = String()
        if lead + 1 < len(b) and (b[lead] == 45 or b[lead] == 42) and b[lead + 1] == 32:
            prefix = String(prev[byte = 0 : lead + 2])
            if _starts(prev, lead + 2, "[ ] ") or _starts(prev, lead + 2, "[x] "):
                prefix += "[ ] "
        else:
            var d = lead
            while d < len(b) and b[d] >= 48 and b[d] <= 57:
                d += 1
            if d > lead and d + 1 < len(b) and b[d] == 46 and b[d + 1] == 32:
                try:
                    prefix = String(prev[byte=0:lead]) + String(Int(String(prev[byte=lead:d])) + 1) + ". "
                except:
                    prefix = ""
        if prefix == "":
            return
        if prev.byte_length() == prefix.byte_length() or String(prev.strip()) == String(prefix.strip()):
            # (an empty item: the list ends; the empty item's text goes)
            self.ed.replace(Pos(i - 1, 0), Pos(i, 0), "", EDIT_OTHER, now_ms)
            return
        if self.ed.caret.byte == 0:
            self.ed.insert(prefix, now_ms)

    def press(mut self, x: Float64, y: Float64, shift: Bool, font: Font) -> Bool:
        """A click: on a task box it ticks the task (True); elsewhere it places the caret."""
        self.sync()
        var p = self.ed.hit(x, y, font, self.st)
        ref l = self.ed.laid[p.para]
        if (l.look.marker_role == "task" or l.look.marker_role == "done") and x < self.ed.pad_x + l.look.indent:
            self.toggle_task(p.para)
            return True
        self.ed.press(x, y, shift, font, self.st)
        return False

    def toggle_task(mut self, i: Int):
        var text = self.ed.paras[i]
        var b = text.as_bytes()
        var lead = 0
        while lead < len(b) and b[lead] == 32:
            lead += 1
        var at = lead + 3  # (the character inside "[ ]")
        if at >= len(b):
            return
        var now = "x" if b[at] == 32 else " "
        var keep_caret = self.ed.caret
        var keep_anchor = self.ed.anchor
        self.ed.replace(Pos(i, at), Pos(i, at + 1), now, EDIT_OTHER, 0)
        self.ed.caret = keep_caret
        self.ed.anchor = keep_anchor
        self.sync()

    def paint[P: Painter](mut self, mut p: P, font: Font, x0: Float64, y0: Float64, notes: Bool = False):
        self.sync()
        self.ed.paint(p, font, x0, y0, self.st, notes)
