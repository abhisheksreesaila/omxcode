# mojoui.markdown (goal 33 M4, D-355): the small, safe markdown of the OMX Console's notebook, as views.
# A port of blade-notebook.js's parser (mxconsole/console): headings, paragraphs, lists, fenced code, and inline
# **bold**, *italic*, `code` and [text](http-url). Anything else stays text: there is no HTML, a `<script>` is just
# words, and only absolute http(s) URLs become links. Every bound is the original's (a run of at most 500 characters,
# a URL of at most 2,000, a text of at most 200,000), so the parser is linear whatever it's given.
#
#   Markdown(cell_source)                        # the view: a VStack of blocks, each tagged with its role (md-h1, md-p…)
#   var blocks = parse_markdown(cell_source)     # the data: Block(kind, level, spans, items, code, lang)
#   var toc = chapters(sources, is_markdown)     # a notebook's chapters: headings of levels 1–2 (any level if none)
#
# Inline styling is flattened into Runs (mojoui.paragraph.Run: text + bold/italic/code/link flags) rather than a tree.
# Every paragraph, heading and list item is one mojoui.paragraph.Paragraph: its runs wear roles (md-strong, md-code…)
# and the HOST wraps them, as the browser wraps the original's <p> (D-471). The look comes from roles (markdown_roles()).

from mojoui.view import View, Text, VStack, HStack, Card, BODY, HEADLINE, TONE_STRONG, START, CENTER, END
from mojoui.theme import Palette, Surface, Shadow
from mojoui.canvas import rgba
from mojoui.codeblock import CodeText
from mojoui.paragraph import Run, Paragraph

comptime MD_P = 0  # a paragraph: spans
comptime MD_HEADING = 1  # level 1–6: spans
comptime MD_UL = 2  # items
comptime MD_OL = 3  # items
comptime MD_CODE = 4  # a fenced code block: code, lang

comptime MAX_MD = 200000  # a notebook cell is never this big; the rest is dropped rather than parsed
comptime MAX_RUN = 500  # the longest `code`, **bold**, *italic* or [link text]
comptime MAX_URL = 2000


def nbsp() -> String:
    """U+00A0: a space a host never collapses (the edges of an inline piece: "Pipeline:" + " text-generation")."""
    return chr(0xA0)


@fieldwise_init
struct Block(Copyable, Movable, Writable):
    """One block: a paragraph or heading (spans), a list (items, each its spans) or a fenced code block (code, lang)."""

    var kind: Int
    var level: Int  # a heading's 1–6
    var spans: List[Run]
    var items: List[List[Run]]
    var code: String
    var lang: String

    def __init__(out self, kind: Int, level: Int, var spans: List[Run]):
        self = Self(kind, level, spans^, List[List[Run]](), "", "")

    def write_to(self, mut writer: Some[Writer]):
        writer.write("Block(", self.kind, ", level=", self.level, ", spans=", len(self.spans), ", items=", len(self.items), ")")


@fieldwise_init
struct Chapter(Copyable, Movable):
    var title: String
    var level: Int
    var cell: Int  # the index of the cell holding the heading


# ---------- characters (ASCII rules, as JavaScript's \s and \w without the u flag) ----------

def _space(c: Byte) -> Bool:
    return c == 32 or (c >= 9 and c <= 13)


def _word(c: Byte) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95


def _chars(text: String, start: Int, end: Int) -> Int:
    """Characters (code points) in text[byte=start:end]: the bounds count characters, not bytes."""
    var b = text.as_bytes()
    var n = 0
    for i in range(start, end):
        if (b[i] & 0xC0) != 0x80:
            n += 1
    return n


def _cut(text: String, start: Int, end: Int) -> String:
    return String(text[byte = start : end])


def _trim(text: String) -> String:
    var b = text.as_bytes()
    var s = 0
    var e = len(b)
    while s < e and _space(b[s]):
        s += 1
    while e > s and _space(b[e - 1]):
        e -= 1
    return _cut(text, s, e)


def _trim_end(text: String) -> String:
    var b = text.as_bytes()
    var e = len(b)
    while e > 0 and _space(b[e - 1]):
        e -= 1
    return _cut(text, 0, e)


def _blank(line: String) -> Bool:
    for c in line.as_bytes():
        if not _space(c):
            return False
    return True


def _limit(text: String) -> String:
    """The first MAX_MD bytes, cut at a character's edge."""
    var n = text.byte_length()
    if n <= MAX_MD:
        return text
    var b = text.as_bytes()
    var e = MAX_MD
    while e > 0 and (b[e] & 0xC0) == 0x80:
        e -= 1
    return _cut(text, 0, e)


# ---------- links ----------

def safe_url(url: String) -> String:
    """`url` if it is an absolute http:// or https:// URL with a host, "" otherwise (javascript:, data:, relative,
    a space inside: none of them become links). Written as the browser writes it: "HTTPS://E.com" → "https://e.com/"."""
    var b = url.as_bytes()
    var low = String("")
    for i in range(min(len(b), 8)):
        var c = b[i]
        low += chr(Int(c + 32 if c >= 65 and c <= 90 else c))
    var start = 7 if low.startswith("http://") else (8 if low.startswith("https://") else -1)
    if start < 0 or start >= len(b) or b[start] == 47 or b[start] == 63 or b[start] == 35:  # (no host: "http:///x")
        return ""
    for c in b:
        if _space(c) or c < 32 or c == 127 or c == 60 or c == 62 or c == 34 or c == 92:  # (no spaces, controls, < > " \)
            return ""
    var e = start  # as the browser's URL writes it (u.href): scheme and host in lower case, "/" for an empty path
    while e < len(b) and b[e] != 47 and b[e] != 63 and b[e] != 35:
        e += 1
    var head = String("")
    for i in range(e):
        var c = b[i]
        head += chr(Int(c + 32 if c >= 65 and c <= 90 else c))
    return head + ("/" if e == len(b) or b[e] != 47 else "") + _cut(url, e, len(b))


# ---------- inline ----------

def _push(mut out: List[Run], var span: Run):
    """Adds a run, merged into the one before when it looks the same (never code: each `code` stays its own)."""
    if span.text == "":
        return
    if len(out) > 0 and not span.code and not out[len(out) - 1].code and out[len(out) - 1].same_look(span):
        out[len(out) - 1].text += span.text
        return
    out.append(span^)


def _upto(text: String, start: Int, stop: Byte) -> Int:
    """The first index from `start` holding `stop` or a newline (the end if none)."""
    var b = text.as_bytes()
    var j = start
    while j < len(b) and b[j] != stop and b[j] != 10:
        j += 1
    return j


def _inline(text: String, bold: Bool, italic: Bool, href: String, mut out: List[Run]):
    var b = text.as_bytes()
    var n = len(b)
    var last = 0
    var i = 0
    while i < n:
        var c = b[i]
        var end = -1  # where the match ends (exclusive)
        var cs = 0  # its content
        var ce = 0
        var what = 0  # 1 code, 2 bold, 3 italic, 4 link
        var us = 0  # a link's URL
        var ue = 0
        if c == 96:  # `code`
            var j = _upto(text, i + 1, 96)
            if j < n and b[j] == 96 and 1 <= _chars(text, i + 1, j) <= MAX_RUN:
                end, cs, ce, what = j + 1, i + 1, j, 1
        elif c == 42:  # **bold**, then *italic*
            if i + 1 < n and b[i + 1] == 42:
                var j = _upto(text, i + 2, 42)
                if j + 1 < n and b[j] == 42 and b[j + 1] == 42 and 1 <= _chars(text, i + 2, j) <= MAX_RUN:
                    end, cs, ce, what = j + 2, i + 2, j, 2
            if what == 0 and i + 1 < n and not _space(b[i + 1]) and b[i + 1] != 42:
                var j = _upto(text, i + 1, 42)
                if j < n and b[j] == 42 and _chars(text, i + 1, j) <= MAX_RUN:
                    end, cs, ce, what = j + 1, i + 1, j, 3
        elif c == 95 and (i == 0 or not _word(b[i - 1])):  # __bold__, then _italic_ (not inside a word: snake_case stays)
            if i + 1 < n and b[i + 1] == 95:
                var j = _upto(text, i + 2, 95)
                if (j + 1 < n and b[j] == 95 and b[j + 1] == 95 and 1 <= _chars(text, i + 2, j) <= MAX_RUN
                        and (j + 2 >= n or not _word(b[j + 2]))):
                    end, cs, ce, what = j + 2, i + 2, j, 2
            if what == 0 and i + 1 < n and not _space(b[i + 1]) and b[i + 1] != 95:
                var j = _upto(text, i + 1, 95)
                if j < n and b[j] == 95 and _chars(text, i + 1, j) <= MAX_RUN and (j + 1 >= n or not _word(b[j + 1])):
                    end, cs, ce, what = j + 1, i + 1, j, 3
        elif c == 91:  # [text](url)
            var j = _upto(text, i + 1, 93)
            if j + 1 < n and b[j] == 93 and b[j + 1] == 40 and 1 <= _chars(text, i + 1, j) <= MAX_RUN:
                var k = j + 2
                while k < n and b[k] != 41 and not _space(b[k]):
                    k += 1
                if k < n and b[k] == 41 and 1 <= _chars(text, j + 2, k) <= MAX_URL:
                    end, cs, ce, us, ue, what = k + 1, i + 1, j, j + 2, k, 4
        if what == 0:
            i += 1
            continue
        if i > last:
            _push(out, Run(_cut(text, last, i), bold, italic, False, href))
        var inner = _cut(text, cs, ce)
        if what == 1:
            _push(out, Run(inner, bold, italic, True, href))
        elif what == 2:
            _inline(inner, True, italic, href, out)
        elif what == 3:
            _inline(inner, bold, True, href, out)
        else:
            var url = safe_url(_cut(text, us, ue))
            if url != "":
                _inline(inner, bold, italic, url, out)
            else:  # javascript:, data:, relative: shown as the text it was, not a link
                _push(out, Run(_cut(text, i, end), bold, italic, False, href))
        last = end
        i = end
    if last < n:
        _push(out, Run(_cut(text, last, n), bold, italic, False, href))


def parse_inline(text: String) -> List[Run]:
    """Inline markdown to runs: **bold** (or __bold__), *italic* (or _italic_), `code`, [text](http-url). Everything
    else stays text."""
    var out = List[Run]()
    _inline(_limit(text), False, False, "", out)
    return out^


def plain_text(spans: List[Run]) -> String:
    var out = String("")
    for s in spans:
        out += s.text
    return out^


# ---------- blocks ----------

def _fence(line: String, mut marker: String, mut lang: String) -> Bool:
    """^\\s*(```+|~~~+)\\s*([\\w+.-]*)\\s*$"""
    var b = line.as_bytes()
    var n = len(b)
    var i = 0
    while i < n and _space(b[i]):
        i += 1
    if i >= n or (b[i] != 96 and b[i] != 126):
        return False
    var c = b[i]
    var s = i
    while i < n and b[i] == c:
        i += 1
    if i - s < 3:
        return False
    var ms = s
    var me = i
    while i < n and _space(b[i]):
        i += 1
    var ls = i
    while i < n and (_word(b[i]) or b[i] == 43 or b[i] == 46 or b[i] == 45):
        i += 1
    var le = i
    while i < n and _space(b[i]):
        i += 1
    if i != n:
        return False
    marker = _cut(line, ms, me)
    lang = _cut(line, ls, le)
    return True


def _closes(line: String, marker: String) -> Bool:
    var t = _trim(line)
    if not t.startswith(marker):
        return False
    for c in t.as_bytes():
        if c != 96 and c != 126:
            return False
    return True


def _heading(line: String, mut text: String) -> Int:
    """^(#{1,6})\\s+(.*)$: the level (0: not a heading); `text` is what follows, its closing #s dropped."""
    var b = line.as_bytes()
    var n = len(b)
    var r = 0
    while r < n and b[r] == 35:
        r += 1
    if r < 1 or r > 6 or r >= n or not _space(b[r]):
        return 0
    var i = r
    while i < n and _space(b[i]):
        i += 1
    var t = _trim_end(_cut(line, i, n))
    var tb = t.as_bytes()  # headText: "Title ##" reads "Title"
    var e = len(tb)
    var h = e
    while h > 0 and tb[h - 1] == 35:
        h -= 1
    if h < e and h > 0 and _space(tb[h - 1]):
        var k = h
        while k > 0 and _space(tb[k - 1]):
            k -= 1
        t = _cut(t, 0, k)
    text = t
    return r


def _item(line: String, mut text: String) -> Int:
    """^\\s*([-*+]|\\d+[.)])\\s+(.*)$: 1 a bullet, 2 a numbered item, 0 neither."""
    var b = line.as_bytes()
    var n = len(b)
    var i = 0
    while i < n and _space(b[i]):
        i += 1
    if i >= n:
        return 0
    var kind = 0
    if b[i] == 45 or b[i] == 42 or b[i] == 43:
        kind = 1
        i += 1
    elif b[i] >= 48 and b[i] <= 57:
        while i < n and b[i] >= 48 and b[i] <= 57:
            i += 1
        if i >= n or (b[i] != 46 and b[i] != 41):
            return 0
        kind = 2
        i += 1
    else:
        return 0
    if i >= n or not _space(b[i]):
        return 0
    while i < n and _space(b[i]):
        i += 1
    text = _cut(line, i, n)
    return kind


def _indented(line: String) -> Bool:
    """^\\s+\\S"""
    var b = line.as_bytes()
    var i = 0
    while i < len(b) and _space(b[i]):
        i += 1
    return i > 0 and i < len(b)


def parse_markdown(src: String) -> List[Block]:
    """Block markdown to blocks: headings, paragraphs, lists, fenced code (an unclosed fence runs to the end).
    Anything else is a paragraph's text."""
    var norm = _limit(src).replace("\r\n", "\n").replace("\r", "\n")
    var lines = List[String]()
    for part in norm.split("\n"):
        lines.append(String(part))
    var out = List[Block]()
    var i = 0
    var marker = String("")
    var lang = String("")
    var text = String("")
    while i < len(lines):
        var line = lines[i]
        if _blank(line):
            i += 1
            continue
        if _fence(line, marker, lang):
            var body = String("")
            var first = True
            i += 1
            while i < len(lines) and not _closes(lines[i], marker):
                body += ("" if first else "\n") + lines[i]
                first = False
                i += 1
            i += 1  # the closing fence
            out.append(Block(MD_CODE, 0, List[Run](), List[List[Run]](), body, lang))
            continue
        var level = _heading(line, text)
        if level > 0:
            out.append(Block(MD_HEADING, level, parse_inline(text)))
            i += 1
            continue
        var kind = _item(line, text)
        if kind > 0:
            var items = List[String]()
            while i < len(lines):
                var k = _item(lines[i], text)
                if k > 0 and k == kind:
                    items.append(text)
                    i += 1
                elif not _blank(lines[i]) and _indented(lines[i]) and len(items) > 0:
                    items[len(items) - 1] += " " + _trim(lines[i])
                    i += 1
                else:
                    break
            var parsed = List[List[Run]]()
            for it in items:
                parsed.append(parse_inline(it))
            out.append(Block(MD_OL if kind == 2 else MD_UL, 0, List[Run](), parsed^, "", ""))
            continue
        var para = String("")
        var count = 0
        while i < len(lines) and not _blank(lines[i]) and not _fence(lines[i], marker, lang) and _heading(lines[i], text) == 0 and not (count > 0 and _item(lines[i], text) > 0):
            para += (" " if count > 0 else "") + _trim(lines[i])
            count += 1
            i += 1
        out.append(Block(MD_P, 0, parse_inline(para)))
    return out^


def chapters(sources: List[String], is_markdown: List[Bool]) -> List[Chapter]:
    """A notebook's chapters from its markdown cells' headings: levels 1 and 2, or any level when it has none of
    those; untitled headings are left out."""
    var all = List[Chapter]()
    for cell in range(len(sources)):
        if cell >= len(is_markdown) or not is_markdown[cell]:
            continue
        for b in parse_markdown(sources[cell]):
            if b.kind == MD_HEADING:
                all.append(Chapter(_trim(plain_text(b.spans)), b.level, cell))
    var top = False
    for c in all:
        if c.level <= 2:
            top = True
    var out = List[Chapter]()
    for c in all:
        if (not top or c.level <= 2) and c.title != "":
            out.append(c.copy())
    return out^


# ---------- views ----------

comptime GAP_HEADING = 8  # blade-notebook.css: h margin 0 0 8px; p, ul, ol, pre 0 0 10px; li 3px
comptime GAP_BLOCK = 10
comptime GAP_ITEM = 3
comptime BULLET_W = 22  # ul, ol: padding-left 22px


def role_of(span: Run, plain_role: String) -> String:
    """The role (tag) an inline piece wears: md-code, md-code-link, md-link, md-strong, md-em, or the block's own."""
    if span.code:
        return "md-code-link" if span.href != "" else "md-code"
    if span.href != "":
        return "md-link"
    if span.bold:
        return "md-strong"
    if span.italic:
        return "md-em"
    return plain_role


def _runs_view(spans: List[Run], style: Int, role: String, on_link: Int) -> View:
    """The runs as one Paragraph wearing `role`, each run its own role (role_of); the host wraps the words."""
    var runs = List[Run]()
    for p in spans:
        var r = p.copy()
        r.role = role_of(p, role)
        runs.append(r^)
    if len(runs) == 0:
        runs.append(Run("", False, False, False, "", role))
    return Paragraph(runs, role=role, on_link=on_link, style=style).fill()


def _gap(points: Int) -> View:
    return VStack(List[View](), spacing=0).height(points).tag("md-gap")


def code_block(code: String, lang: String) -> View:
    """A fenced code block: CodeBlock's lines (CodeText: mono, indents kept) without its Copy button, as the notebook's
    pre has none."""
    return Card(CodeText(code).tag("md-pre-text"), spacing=0).padding(12, 14).fill().tag("md-pre")


def markdown_view(blocks: List[Block], tag: String = "markdown", on_link: Int = 0) -> View:
    """Blocks as views, each tagged with its role: md-h1…md-h6, md-p, md-ul / md-ol (rows md-li beside md-bullet),
    md-pre; inline pieces md-strong, md-em, md-code, md-link, md-code-link; md-gap after each block (its margin)."""
    var items = List[View]()
    for b in blocks:
        if b.kind == MD_HEADING:
            items.append(_runs_view(b.spans, HEADLINE, "md-h" + String(b.level), on_link))
            items.append(_gap(GAP_HEADING))
        elif b.kind == MD_P:
            items.append(_runs_view(b.spans, BODY, "md-p", on_link))
            items.append(_gap(GAP_BLOCK))
        elif b.kind == MD_UL or b.kind == MD_OL:
            var rows = List[View]()
            for k in range(len(b.items)):
                var mark = "•" if b.kind == MD_UL else String(k + 1) + "."
                rows.append(HStack(Text(mark).width(BULLET_W).tag("md-bullet"),
                                   _runs_view(b.items[k], BODY, "md-li", on_link).grow(), spacing=0).align(START).tag("md-item"))
            items.append(VStack(rows^, spacing=GAP_ITEM).align(START).tag("md-ul" if b.kind == MD_UL else "md-ol"))
            items.append(_gap(GAP_BLOCK))
        else:
            items.append(code_block(b.code, b.lang))
            items.append(_gap(GAP_BLOCK))
    return VStack(items^, spacing=0).align(START).tag(tag)


def Markdown(text: String, tag: String = "markdown", on_link: Int = 0) -> View:
    """Markdown text as views (parse_markdown, then markdown_view). Safe: never HTML, links only to http(s). A link's
    tap sends on_link (event.text = its href); with none the host opens it in the browser."""
    return markdown_view(parse_markdown(text), tag, on_link)


# ---------- the look (blade-notebook.css's .nb-md), for a theme to add to its Look's surfaces ----------

def text_role(role: String, size: Float64, weight: Int, ink: UInt32, font: String = "", tracking: Float64 = 0,
              line_height: Float64 = 0, fill: UInt32 = 0, radius: Int = -1, pad_v: Int = -1, pad_h: Int = -1, max_chars: Int = 0) -> Surface:
    """A role for words, optionally on a small filled shape (inline code), optionally at most `max_chars` wide."""
    return Surface(role, fill, radius, radius, -1, -1, -1, pad_v, pad_h, pad_v, List[Shadow](), 0, 0, 0, -1, font, size, ink,
                   weight, tracking, line_height, 0, 0, False, max_chars=max_chars)


def markdown_roles(p: Palette, mono: String) -> List[Surface]:
    """.nb-md's values: body 14/1.6 in ink-2; headings 650 in the ink, -.015em, 1.3 (20, 17, 15, 14…); strong and links
    in the ink; inline code 12.5 mono on the state layer at .07, corners 4, 1×5 padding; pre on the code colours
    (#0b0b0d / #e4e4e7), corners 12, 12×14 padding; paragraphs and lists at most 72 characters wide. Not carried by a Surface: italics, a link's underline."""
    var wash = rgba(237, 237, 239, 18) if p.dark else rgba(11, 11, 13, 18)  # rgb(var(--oq-state) / .07)
    var out: List[Surface] = [
        text_role("md-h1", 20, 650, p.ink, "", -0.3, 26),
        text_role("md-h2", 17, 650, p.ink, "", -0.255, 22.1),
        text_role("md-h3", 15, 650, p.ink, "", -0.225, 19.5),
        text_role("md-h4", 14, 650, p.ink, "", -0.21, 18.2),
        text_role("md-h5", 14, 650, p.ink, "", -0.21, 18.2),
        text_role("md-h6", 14, 650, p.ink, "", -0.21, 18.2),
        text_role("md-p", 14, 0, p.ink2, "", 0, 22.4, max_chars=72),  # (p, ul, ol: max-width 72ch)
        text_role("md-ul", 0, 0, 0, max_chars=72),
        text_role("md-ol", 0, 0, 0, max_chars=72),
        text_role("md-li", 14, 0, p.ink2, "", 0, 22.4),
        text_role("md-bullet", 14, 0, p.ink2, "", 0, 22.4),
        text_role("md-em", 14, 0, p.ink2, "", 0, 22.4),
        text_role("md-strong", 14, 700, p.ink, "", 0, 22.4),
        text_role("md-link", 14, 0, p.ink, "", 0, 22.4),
        text_role("md-code", 12.5, 0, p.ink, mono, 0, 20, wash, 4, 1, 5),  # (its line 1.6 of its own 12.5: 20, so it never heightens the paragraph's 22.4 line)
        text_role("md-code-link", 12.5, 0, p.ink, mono, 0, 20, wash, 4, 1, 5),
        text_role("md-pre", 0, 0, 0, "", 0, 0, rgba(11, 11, 13), 12, 12, 14),
        text_role("md-pre-text", 12.5, 0, rgba(228, 228, 231), mono, 0, 22.4),
    ]
    return out^
