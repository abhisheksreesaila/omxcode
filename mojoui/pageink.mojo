# mojoui.pageink (goal 79, docs/goals/79-gaps.md 28): the ink of a page of words, as Personal Note keeps it (ADR 0003): a mark
# is a stroke anchored to a word ([pos, end) in the Markdown) with its corner's place relative to that word's first
# character. The words it is on are followed through every edit; a mark whose word is deleted goes with it and comes back
# when the text does (undo). What a document held is written back as it was, with only the positions an edit moved changed;
# in the document a position counts UTF-16 units (the web's), here bytes.
#
#   var ink = PageInk(); ink.load(content, markdown)
#   ink.follow(new_markdown)                 # after every edit
#   ink.save(content) → the content.ink value as JSON text

from mojoui.json import Json, J_NUMBER, json_string
from mojoui.jsonpatch import Change, patched, patched_in, member_text, elements, part
from mojoui.shared import new_key


def utf16_at(text: String, byte: Int) -> Int:
    """How many UTF-16 units come before byte `byte`."""
    var n = 0
    var b = text.as_bytes()
    for i in range(min(byte, len(b))):
        var c = Int(b[i])
        if (c & 0xC0) != 0x80:
            n += 2 if c >= 0xF0 else 1
    return n


def byte_at_utf16(text: String, units: Int) -> Int:
    """The byte where UTF-16 unit `units` begins (the text's end when past it)."""
    var n = 0
    var b = text.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if (c & 0xC0) != 0x80:
            if n >= units:
                return i
            n += 2 if c >= 0xF0 else 1
    return len(b)


@fieldwise_init
struct PageMark(Copyable, Movable):
    var tool: String  # pen | red | highlight
    var points: List[Float64]  # x, y, …, from the mark's own top left
    var pos: Int  # the word it is on: bytes of the Markdown; -1: none (loose ink, kept and not drawn)
    var end: Int
    var dx: Float64  # its top left from the word's first character's box (a margin mark: from the column's left)
    var dy: Float64
    var margin: Bool
    var exact: String  # the word, as it was
    var source: String  # the document's own text for it ("" : made here)
    var pos0: Int  # where the document says it is (bytes), to know whether an edit moved it
    var end0: Int
    var key: String


@fieldwise_init
struct LostMark(Copyable, Movable):
    var mark: PageMark
    var at: Int  # where it was in the list
    var text: UInt64  # the text it was on (its hash): that text again, and it is back


@fieldwise_init
struct PageDrawing(Copyable, Movable):
    """A drawing block of the document (not drawn here): its text, and the positions an edit moves."""
    var source: String
    var pos: Int
    var pos0: Int
    var link: Int  # -1: none
    var link_end: Int
    var link0: Int
    var link_end0: Int


def _hash(s: String) -> UInt64:
    var h: UInt64 = 14695981039346656037
    for b in s.as_bytes():
        h = (h ^ UInt64(b)) * 1099511628211
    return h


struct PageInk(Movable):
    var marks: List[PageMark]
    var lost: List[LostMark]
    var drawings: List[PageDrawing]
    var text: String  # the Markdown the positions are in
    var loaded: Bool  # a document's ink was read into this (else a save only adds to what the document has)

    def __init__(out self):
        self.marks = List[PageMark]()
        self.lost = List[LostMark]()
        self.drawings = List[PageDrawing]()
        self.text = ""
        self.loaded = False

    def load(mut self, content: String, markdown: String) raises:
        """The ink of a page's content (JSON), over its Markdown."""
        self.marks.clear()
        self.lost.clear()
        self.drawings.clear()
        self.text = markdown
        self.loaded = True
        var ink = member_text(content, "ink")
        if not ink.startswith("{"):
            return
        var list = member_text(ink, "marks")
        if list.startswith("["):
            for e in elements(list, 0, list.byte_length()):
                var raw = part(list, e.start, e.end)
                var j = Json.parse(raw)
                var a = j.get(0, "anchor")
                var m = PageMark(j.text(j.get(0, "tool"), "pen"), List[Float64](), -1, -1, j.real(j.get(0, "dx")), j.real(j.get(0, "dy")), j.flag(j.get(0, "margin")), "", raw, -1, -1, "")
                var pts = j.get(0, "points")
                for k in range(j.size(pts)):
                    var pt = j.at(pts, k)
                    if j.size(pt) >= 2:
                        m.points.append(j.real(j.at(pt, 0)))
                        m.points.append(j.real(j.at(pt, 1)))
                if j.kind(j.get(a, "pos")) == J_NUMBER:
                    m.exact = j.text(j.get(j.get(a, "quote"), "exact"))
                    var u = Int(j.real(j.get(a, "pos")))
                    m.pos = byte_at_utf16(markdown, u)
                    m.end = byte_at_utf16(markdown, Int(j.real(j.get(a, "end")))) if j.kind(j.get(a, "end")) == J_NUMBER else min(m.pos + m.exact.byte_length(), markdown.byte_length())
                    m.pos0 = m.pos
                    m.end0 = m.end
                self.marks.append(m^)
        list = member_text(ink, "drawings")
        if list.startswith("["):
            for e in elements(list, 0, list.byte_length()):
                var raw = part(list, e.start, e.end)
                var j = Json.parse(raw)
                var p = -1
                if j.kind(j.get(0, "pos")) == J_NUMBER:
                    p = byte_at_utf16(markdown, Int(j.real(j.get(0, "pos"))))
                var l = j.get(0, "link")
                var la = -1
                var le = -1
                if l >= 0 and j.kind(j.get(l, "pos")) == J_NUMBER and j.kind(j.get(l, "end")) == J_NUMBER:
                    la = byte_at_utf16(markdown, Int(j.real(j.get(l, "pos"))))
                    le = byte_at_utf16(markdown, Int(j.real(j.get(l, "end"))))
                self.drawings.append(PageDrawing(raw, p, p, la, le, la, le))

    def follow(mut self, now: String):
        """The text is `now`: every position moves with the words it is on (what changed is taken to be the one stretch
        between the common start and the common end)."""
        if now == self.text:
            return
        if len(self.marks) == 0 and len(self.lost) == 0 and len(self.drawings) == 0:
            self.text = now
            return
        var a = self.text.as_bytes()
        var b = now.as_bytes()
        var n = min(len(a), len(b))
        var f = 0
        while f < n and a[f] == b[f]:
            f += 1
        var k = 0
        while k < n - f and a[len(a) - 1 - k] == b[len(b) - 1 - k]:
            k += 1
        var t = len(a) - k  # [f, t) became `ins` bytes
        var ins = len(b) - k - f
        var was = _hash(self.text)
        var kept = List[PageMark]()
        for i in range(len(self.marks)):
            var m = self.marks[i].copy()
            if m.pos >= 0:
                var p2 = _map(m.pos, f, t, ins, 1)
                var e2 = _map(m.end, f, t, ins, -1)
                if m.end > m.pos and e2 <= p2:
                    self.lost.append(LostMark(m^, i, was))
                    continue
                m.pos = p2
                m.end = max(e2, p2)
            kept.append(m^)
        self.marks = kept^
        for i in range(len(self.drawings)):
            if self.drawings[i].pos >= 0:
                self.drawings[i].pos = _map(self.drawings[i].pos, f, t, ins, -1)
            if self.drawings[i].link >= 0:
                var p2 = _map(self.drawings[i].link, f, t, ins, 1)
                self.drawings[i].link_end = max(_map(self.drawings[i].link_end, f, t, ins, -1), p2)
                self.drawings[i].link = p2
        self.text = now
        var h = _hash(now)
        var i = len(self.lost) - 1
        while i >= 0:  # (the text a mark went with is back: so is the mark)
            if self.lost[i].text == h:
                var l = self.lost.pop(i)
                self.marks.insert(min(l.at, len(self.marks)), l.mark.copy())
            i -= 1

    def erase(mut self, i: Int) -> PageMark:
        return self.marks.pop(i)

    def marks_json(self) raises -> String:
        """The marks as a document keeps them."""
        var out = String("")
        for ref m in self.marks:
            if out != "":
                out += ","
            if m.source != "":
                if m.pos >= 0 and (m.pos != m.pos0 or m.end != m.end0):
                    out += patched_in(m.source, "anchor", [Change("pos", String(utf16_at(self.text, m.pos))), Change("end", String(utf16_at(self.text, m.end)))])
                else:
                    out += m.source
                continue
            out += '{"id":' + json_string(m.key) + ',"tool":"' + m.tool + '","points":['
            for k in range(0, len(m.points), 2):
                out += ("," if k > 0 else "") + "[" + _num(m.points[k]) + "," + _num(m.points[k + 1]) + "]"
            out += '],"anchor":{"pos":' + String(utf16_at(self.text, m.pos)) + ',"end":' + String(utf16_at(self.text, m.end)) + ',"quote":{"exact":' + json_string(m.exact) + "}}"
            out += ',"dx":' + _num(m.dx) + ',"dy":' + _num(m.dy) + (',"margin":true' if m.margin else "") + "}"
        return "[" + out + "]"

    def drawings_json(self) raises -> String:
        var out = String("")
        for ref d in self.drawings:
            var raw = d.source
            if d.pos >= 0 and d.pos != d.pos0:
                raw = patched(raw, [Change("pos", String(utf16_at(self.text, d.pos)))])
            if d.link >= 0 and (d.link != d.link0 or d.link_end != d.link_end0):
                raw = patched_in(raw, "link", [Change("pos", String(utf16_at(self.text, d.link))), Change("end", String(utf16_at(self.text, d.link_end)))])
            out += ("," if out != "" else "") + raw
        return "[" + out + "]"

    def changed(self) -> Bool:
        """The marks or drawings aren't as the document holds them."""
        for ref m in self.marks:
            if m.source == "" or m.pos != m.pos0 or m.end != m.end0:
                return True
        for ref d in self.drawings:
            if d.pos != d.pos0 or d.link != d.link0 or d.link_end != d.link_end0:
                return True
        return False

    def save(self, content: String) raises -> String:
        """`content` (a page's JSON) with this ink: untouched when nothing here changed or went."""
        var ink = member_text(content, "ink")
        var had = 0
        var list = member_text(ink, "marks") if ink.startswith("{") else String("")
        if list.startswith("["):
            had = len(elements(list, 0, list.byte_length()))
        if not self.loaded:  # (never read here: nothing of it may go)
            if len(self.marks) == 0:
                return content
            var inner = String(list[byte=1:list.byte_length() - 1].strip()) if list.startswith("[") else String("")
            var ours = self.marks_json()
            if not ink.startswith("{"):
                ink = '{"marks":[],"drawings":[]}'
            return patched(content, [Change("ink", patched(ink, [Change("marks", "[" + inner + ("," if inner != "" else "") + String(ours[byte=1:]))]))])
        if not self.changed() and had == len(self.marks):
            return content
        if not ink.startswith("{"):
            ink = '{"marks":[],"drawings":[]}'
        var ch: List[Change] = [Change("marks", self.marks_json())]
        if len(self.drawings) > 0:
            ch.append(Change("drawings", self.drawings_json()))
        return patched(content, [Change("ink", patched(ink, ch))])

    def add(mut self, tool: String, var points: List[Float64], pos: Int, end: Int, dx: Float64, dy: Float64):
        var exact = String(self.text[byte=pos:end]) if end <= self.text.byte_length() and pos <= end else String("")
        self.marks.append(PageMark(tool, points^, pos, end, dx, dy, False, exact, "", -1, -1, new_key("m-")))


def _map(p: Int, f: Int, t: Int, ins: Int, assoc: Int) -> Int:
    """CodeMirror's mapPos for one change: bytes [f, t) became `ins` bytes."""
    if p < f or (p == f and (t > f or assoc < 0)):
        return p
    if p >= t:
        return p + ins - (t - f)
    return f if assoc < 0 else f + ins


def _num(v: Float64) -> String:
    if v == Float64(Int(v)):
        return String(Int(v))
    return String(v)
