# mojoui.textedit: a native multi-line text editor (goal 74 M2, D-7402). No toolkit text widget and no JS: the text is
# kept, wrapped, hit-tested and painted by mojoui, through any Painter (the CPU surface, a Scene for the GPU presenter
# and for agents and tests). One implementation on every host; the host only sends keys and pointer events.
#
#   var ed = TextEdit("Hello\nworld")
#   ed.resize(600, 400)                         # the box, in points
#   ed.key("x", 0, now_ms)                      # a typed character or a web key name ("Enter", "ArrowLeft", …) + mods
#   ed.press(x, y, shift); ed.drag_to(x, y)     # the pointer, in the box's points
#   ed.paint(painter, font, x0, y0, PlainStyler()) # only the visible lines are laid out and drawn
#
# A paragraph is a line of the text (split at "\n"). How a paragraph looks comes from a Styler: its spans (size, weight,
# colour, slant, hidden), indent, spacing and a block (a quote's bar, a code block's tint). mojoui.mdedit is a Styler
# that draws Markdown; PlainStyler draws plain text. Layout is per paragraph and lazy: a 1,000,000-character text opens
# without wrapping anything; paragraphs are wrapped when they come into view or an edit touches them.
#
# Positions are (paragraph, byte) pairs (Pos). Every edit is one replace() of a range by a text, kept in the history
# (mojoui.history) as the removed and inserted texts, so typing a word is one undo step.

from std.time import perf_counter_ns
from mojoui.graphemes import prev_grapheme, next_grapheme, erase_start, typed_text
from mojoui.text import Font, Face, REGULAR, MEDIUM, MONO, MONO_BOLD, LEFT
from mojoui.scene import Painter
from mojoui.history import History, Undoable

comptime SHIFT = 1
comptime CTRL = 2
comptime ALT = 4

comptime BLOCK_NONE = 0
comptime BLOCK_QUOTE = 1
comptime BLOCK_CODE = 2
comptime BLOCK_RULE = 3

comptime EDIT_TYPE = 1
comptime EDIT_DELETE = 2
comptime EDIT_OTHER = 3


@fieldwise_init
struct Pos(Copyable, Movable, Equatable, ImplicitlyCopyable):
    var para: Int
    var byte: Int

    def __eq__(self, other: Self) -> Bool:
        return self.para == other.para and self.byte == other.byte

    def before(self, other: Self) -> Bool:
        return self.para < other.para or (self.para == other.para and self.byte < other.byte)


@fieldwise_init
struct StyleSpan(Copyable, Movable):
    """Bytes [start, end) of a paragraph drawn one way. hidden: not drawn and takes no room (a Markdown mark off the
    caret's line). role: a name for agents and tests ("h1", "bold", "code", "mark", "link")."""

    var start: Int
    var end: Int
    var size: Float64
    var weight: Int
    var color: UInt32
    var slant: Float64
    var hidden: Bool
    var back: UInt32  # a tint behind the text (inline code), 0: none
    var underline: Bool
    var strike: Bool
    var role: String


def plain_span(start: Int, end: Int, size: Float64, color: UInt32, role: String = "text") -> StyleSpan:
    return StyleSpan(start, end, size, REGULAR, color, 0.0, False, 0, False, False, role)


struct ParaLook(Copyable, Movable):
    """How one paragraph looks. spans cover the paragraph's bytes in order (gaps are drawn with the first span's look)."""

    var spans: List[StyleSpan]
    var indent: Float64  # every line starts this far in
    var before: Float64  # room above the paragraph
    var after: Float64  # room below it
    var gap: Float64  # line height = the line's biggest size × gap
    var block: Int  # BLOCK_*
    var block_color: UInt32
    var marker: String  # drawn in the indent before the first line ("•", "1.", "☐", "☑"); "" none
    var marker_color: UInt32
    var marker_back: UInt32  # an open task box's inside (the page's colour)
    var marker_role: String  # "bullet", "number", "task", "done"
    var role: String  # the paragraph's kind for agents and tests ("p", "h1", "li", "task", "quote", "code", "rule")

    def __init__(out self, size: Float64, color: UInt32, length: Int):
        self.spans = [plain_span(0, length, size, color)]
        self.indent = 0
        self.before = 0
        self.after = 0
        self.gap = 1.45
        self.block = BLOCK_NONE
        self.block_color = 0
        self.marker = ""
        self.marker_color = color
        self.marker_back = 0xFFFFFFFF
        self.marker_role = ""
        self.role = "p"


trait Styler:
    def look(self, text: String, index: Int, caret_here: Bool) -> ParaLook:
        """How paragraph `index` (its text) looks; caret_here: the caret (or the selection) is in it."""
        ...

    def version(self) -> Int:
        """Changes when every paragraph's look may have changed (a theme, a size): cached layouts are dropped."""
        ...


struct PlainStyler(Styler, Copyable, Movable):
    var size: Float64
    var color: UInt32

    def __init__(out self, size: Float64 = 15, color: UInt32 = 0xFF26221E):
        self.size = size
        self.color = color

    def look(self, text: String, index: Int, caret_here: Bool) -> ParaLook:
        return ParaLook(self.size, self.color, text.byte_length())

    def version(self) -> Int:
        return 0


# ---------------------------------------------------------------- measuring


def face_for(font: Font, weight: Int) -> Int:
    return 3 if weight == MONO else (4 if weight == MONO_BOLD else (1 if weight == MEDIUM else 0))


def adv(font: Font, weight: Int, code: Int, size: Float64) -> Float64:
    """The advance of one codepoint at size px in the face that draws `weight`."""
    var f = face_for(font, weight)
    if f == 3:
        return _adv(font.mono, code, size)
    if f == 4:
        return _adv(font.mono_bold, code, size)
    if f == 1:
        return _adv(font.medium, code, size)
    return _adv(font.regular, code, size)


def _adv(face: Face, code: Int, size: Float64) -> Float64:
    var g = face.find(code)
    if g < 0:
        return 0
    return face.glyphs[g].advance * size / face.size


def utf8_len(b: UInt8) -> Int:
    var v = Int(b)
    if v < 0x80:
        return 1
    if v < 0xE0:
        return 2
    if v < 0xF0:
        return 3
    return 4


def decode_at(text: String, i: Int) -> Int:
    """The codepoint starting at byte i."""
    var bytes = text.as_bytes()
    var b0 = Int(bytes[i])
    if b0 < 0x80:
        return b0
    var n = utf8_len(bytes[i])
    if n == 2 and i + 1 < len(bytes):
        return ((b0 & 0x1F) << 6) | (Int(bytes[i + 1]) & 0x3F)
    if n == 3 and i + 2 < len(bytes):
        return ((b0 & 0x0F) << 12) | ((Int(bytes[i + 1]) & 0x3F) << 6) | (Int(bytes[i + 2]) & 0x3F)
    if i + 3 < len(bytes):
        return ((b0 & 0x07) << 18) | ((Int(bytes[i + 1]) & 0x3F) << 12) | ((Int(bytes[i + 2]) & 0x3F) << 6) | (Int(bytes[i + 3]) & 0x3F)
    return 0xFFFD


def is_word_byte(b: UInt8) -> Bool:
    var c = Int(b)
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c >= 0x80


# ---------------------------------------------------------------- layout


struct Laid(Copyable, Movable):
    """One paragraph's layout at one width: its lines (first byte of each), each line's height and baseline, its height."""

    var valid: Bool
    var width: Float64
    var look: ParaLook
    var starts: List[Int]
    var tops: List[Float64]  # each line's top, from the paragraph's top
    var heights: List[Float64]
    var ascents: List[Float64]  # baseline = top + ascent
    var height: Float64
    var caret_here: Bool

    def __init__(out self):
        self.valid = False
        self.width = 0
        self.look = ParaLook(15, 0, 0)
        self.starts = List[Int]()
        self.tops = List[Float64]()
        self.heights = List[Float64]()
        self.ascents = List[Float64]()
        self.height = 0
        self.caret_here = False


def span_at(look: ParaLook, byte: Int) -> Int:
    """The span holding byte (the last one starting at or before it); 0 when none does."""
    var k = 0
    for i in range(len(look.spans)):
        if look.spans[i].start <= byte:
            k = i
        else:
            break
    return k


# ---------------------------------------------------------------- the edit (one undo step)


struct TextChange(Undoable):
    """The bytes from `start` that were `removed` became `inserted`; the caret was at `caret_before`, then `caret_after`."""

    var kind: Int
    var start: Pos
    var removed: String
    var inserted: String
    var caret_before: Pos
    var caret_after: Pos

    def __init__(out self, kind: Int, start: Pos, removed: String, inserted: String, caret_before: Pos, caret_after: Pos):
        self.kind = kind
        self.start = start
        self.removed = removed
        self.inserted = inserted
        self.caret_before = caret_before
        self.caret_after = caret_after

    def __copyinit__(out self, other: Self):
        self.kind = other.kind
        self.start = other.start
        self.removed = other.removed
        self.inserted = other.inserted
        self.caret_before = other.caret_before
        self.caret_after = other.caret_after

    def merge(mut self, later: Self) -> Bool:
        if later.kind != self.kind:
            return False
        if self.kind == EDIT_TYPE:  # typing on: the later text starts where this one ended (one paragraph, no Enter)
            if later.removed != "" or self.removed != "" or later.inserted.find("\n") >= 0 or self.inserted.find("\n") >= 0:
                return False
            if later.start.para != self.start.para or later.start.byte != self.start.byte + self.inserted.byte_length():
                return False
            if later.inserted == " " and not self.inserted.endswith(" "):  # (a space ends a word: the next word is its own step)
                self.inserted += later.inserted
                self.caret_after = later.caret_after
                return True
            if self.inserted.endswith(" "):
                return False
            self.inserted += later.inserted
            self.caret_after = later.caret_after
            return True
        if self.kind == EDIT_DELETE:  # backspacing on: the later removal ends where this one started
            if later.inserted != "" or self.inserted != "" or later.start.para != self.start.para:
                return False
            if later.start.byte + later.removed.byte_length() == self.start.byte:
                self.removed = later.removed + self.removed
                self.start = later.start
                self.caret_after = later.caret_after
                return True
            if later.start.byte == self.start.byte:  # (Delete forward)
                self.removed += later.removed
                self.caret_after = later.caret_after
                return True
            return False
        return False


# ---------------------------------------------------------------- the editor


struct TextEdit(Movable):
    var paras: List[String]
    var laid: List[Laid]
    var caret: Pos
    var anchor: Pos  # the selection runs from anchor to caret (none when they're equal)
    var goal_x: Float64  # up/down keep this x (-1: take the caret's)
    var width: Float64  # the box, points
    var height: Float64
    var pad_x: Float64
    var pad_y: Float64
    var top_para: Int  # the first paragraph in view
    var top_off: Float64  # how far its top is above the box's top (≥ 0)
    var history: History[TextChange]
    var version: Int  # the text's version (every edit)
    var view_version: Int  # what's shown (an edit, a caret move, a scroll)
    var styler_version: Int
    var focused: Bool
    var dragging: Bool
    var caret_color: UInt32
    var select_color: UInt32
    var read_only: Bool
    var est_char_w: Float64  # a paragraph not laid out yet is guessed from its length
    var clip: String  # the editor's clipboard: Ctrl+C / Ctrl+X put the selection here, Ctrl+V inserts it
    var clip_version: Int  # bumped on every copy: an app shows it with mojoui.overlays.Clipboard(clip, clip_version),
    # which puts it on the system clipboard (pasting from the system clipboard needs a host read: debt, D-7427)

    def __init__(out self, text: String = ""):
        self.paras = List[String]()
        self.laid = List[Laid]()
        self.caret = Pos(0, 0)
        self.anchor = Pos(0, 0)
        self.goal_x = -1
        self.width = 600
        self.height = 400
        self.pad_x = 16
        self.pad_y = 12
        self.top_para = 0
        self.top_off = 0
        self.history = History[TextChange](cap=2000, window_ms=1500)
        self.version = 0
        self.view_version = 0
        self.styler_version = -1
        self.focused = True
        self.dragging = False
        self.caret_color = 0xFFEB6325  # (rgba little-endian: a blue caret)
        self.select_color = 0x40EB6325
        self.read_only = False
        self.est_char_w = 7.5
        self.clip = ""
        self.clip_version = 0
        self.set_text(text)

    # ------------------------------------------------ text

    def set_text(mut self, text: String):
        self.paras = List[String]()
        var bytes = text.as_bytes()
        var start = 0
        for i in range(len(bytes)):
            if bytes[i] == 10:
                self.paras.append(String(text[byte=start:i]))
                start = i + 1
        self.paras.append(String(text[byte = start : len(bytes)]))
        self.laid = List[Laid](capacity=len(self.paras))
        for _ in range(len(self.paras)):
            self.laid.append(Laid())
        self.caret = Pos(0, 0)
        self.anchor = Pos(0, 0)
        self.top_para = 0
        self.top_off = 0
        self.history.clear()
        self.version += 1
        self.view_version += 1

    def text(self) -> String:
        var out = String()
        for i in range(len(self.paras)):
            if i > 0:
                out += "\n"
            out += self.paras[i]
        return out^

    def chars(self) -> Int:
        """Bytes in the text, newlines counted."""
        var n = len(self.paras) - 1
        for ref p in self.paras:
            n += p.byte_length()
        return n

    def text_between(self, a: Pos, b: Pos) -> String:
        if a.para == b.para:
            return String(self.paras[a.para][byte = a.byte : b.byte])
        var out = String(self.paras[a.para][byte = a.byte :])
        for i in range(a.para + 1, b.para):
            out += "\n" + self.paras[i]
        out += "\n" + String(self.paras[b.para][byte = 0 : b.byte])
        return out^

    def clamp(self, p: Pos) -> Pos:
        var para = min(max(p.para, 0), len(self.paras) - 1)
        return Pos(para, min(max(p.byte, 0), self.paras[para].byte_length()))

    def replace_raw(mut self, var a: Pos, var b: Pos, text: String) -> Pos:
        """Bytes a..b become text (which may hold newlines). Returns where the inserted text ends. No history."""
        var head = String(self.paras[a.para][byte = 0 : a.byte])
        var tail = String(self.paras[b.para][byte = b.byte :])
        var pieces = List[String]()
        var bytes = text.as_bytes()
        var start = 0
        for i in range(len(bytes)):
            if bytes[i] == 10:
                pieces.append(String(text[byte=start:i]))
                start = i + 1
        pieces.append(String(text[byte = start : len(bytes)]))
        var last = len(pieces) - 1
        var end = Pos(a.para + last, (head.byte_length() if last == 0 else 0) + pieces[last].byte_length())
        pieces[0] = head + pieces[0]
        pieces[last] = pieces[last] + tail
        var removed = b.para - a.para + 1
        if removed == len(pieces):  # (the common case: same count; no list shifting)
            for k in range(len(pieces)):
                self.paras[a.para + k] = pieces[k]
                self.laid[a.para + k].valid = False
        else:  # (paragraphs come or go: the ones after shift in place, moved, not copied)
            var keep = min(removed, len(pieces))
            for k in range(keep):
                self.paras[a.para + k] = pieces[k]
                self.laid[a.para + k] = Laid()
            if len(pieces) > removed:
                for k in range(removed, len(pieces)):
                    self.paras.insert(a.para + k, pieces[k])
                    self.laid.insert(a.para + k, Laid())
            else:
                for _ in range(removed - len(pieces)):
                    _ = self.paras.pop(a.para + keep)
                    _ = self.laid.pop(a.para + keep)
            if self.top_para >= len(self.paras):
                self.top_para = len(self.paras) - 1
                self.top_off = 0
        self.version += 1
        self.view_version += 1
        return end

    def replace(mut self, var a: Pos, var b: Pos, text: String, kind: Int, now_ms: Int):
        """An edit the person made: a..b becomes text, the caret lands after it, and it's one (mergeable) undo step."""
        if self.read_only:
            return
        var removed = self.text_between(a, b)
        var before = self.caret
        var end = self.replace_raw(a, b, text)
        self.caret = end
        self.anchor = end
        self.goal_x = -1
        self.history.push(TextChange(kind, a, removed, text, before, end), now_ms, kind != EDIT_OTHER)
        self.reveal()

    def undo(mut self) -> Bool:
        var s = self.history.undo()
        if not s:
            return False
        var c = s.value().copy()
        var end_ins = self.end_of(c.start, c.inserted)
        _ = self.replace_raw(c.start, end_ins, c.removed)
        self.caret = self.clamp(c.caret_before)
        self.anchor = self.caret
        self.reveal()
        return True

    def redo(mut self) -> Bool:
        var s = self.history.redo()
        if not s:
            return False
        var c = s.value().copy()
        var end_rem = self.end_of(c.start, c.removed)
        _ = self.replace_raw(c.start, end_rem, c.inserted)
        self.caret = self.clamp(c.caret_after)
        self.anchor = self.caret
        self.reveal()
        return True

    def end_of(self, start: Pos, text: String) -> Pos:
        """Where text inserted at start would end."""
        var lines = 0
        var last_start = 0
        var bytes = text.as_bytes()
        for i in range(len(bytes)):
            if bytes[i] == 10:
                lines += 1
                last_start = i + 1
        if lines == 0:
            return Pos(start.para, start.byte + len(bytes))
        return Pos(start.para + lines, len(bytes) - last_start)

    # ------------------------------------------------ selection

    def has_selection(self) -> Bool:
        return not (self.caret == self.anchor)

    def sel_start(self) -> Pos:
        return self.anchor if self.anchor.before(self.caret) else self.caret

    def sel_end(self) -> Pos:
        return self.caret if self.anchor.before(self.caret) else self.anchor

    def selected_text(self) -> String:
        return self.text_between(self.sel_start(), self.sel_end())

    def select_all(mut self):
        self.anchor = Pos(0, 0)
        var last = len(self.paras) - 1
        self.caret = Pos(last, self.paras[last].byte_length())
        self.view_version += 1

    def insert(mut self, text: String, now_ms: Int):
        var kind = EDIT_TYPE if text.byte_length() <= 4 and text != "\n" else EDIT_OTHER
        if self.has_selection():
            kind = EDIT_OTHER
        self.replace(self.sel_start(), self.sel_end(), text, kind, now_ms)

    def cut(mut self, now_ms: Int) -> String:
        var t = self.selected_text()
        if t != "":
            self.replace(self.sel_start(), self.sel_end(), "", EDIT_OTHER, now_ms)
        return t^

    # ------------------------------------------------ moving

    def prev_char(self, p: Pos) -> Pos:
        if p.byte == 0:
            return Pos(p.para - 1, self.paras[p.para - 1].byte_length()) if p.para > 0 else p
        return Pos(p.para, prev_grapheme(self.paras[p.para], p.byte))

    def next_char(self, p: Pos) -> Pos:
        var n = self.paras[p.para].byte_length()
        if p.byte >= n:
            return Pos(p.para + 1, 0) if p.para + 1 < len(self.paras) else p
        return Pos(p.para, next_grapheme(self.paras[p.para], p.byte))

    def prev_word(self, p: Pos) -> Pos:
        if p.byte == 0:
            return self.prev_char(p)
        var b = self.paras[p.para].as_bytes()
        var i = p.byte
        while i > 0 and not is_word_byte(b[i - 1]):
            i -= 1
        while i > 0 and is_word_byte(b[i - 1]):
            i -= 1
        return Pos(p.para, i)

    def next_word(self, p: Pos) -> Pos:
        var b = self.paras[p.para].as_bytes()
        if p.byte >= len(b):
            return self.next_char(p)
        var i = p.byte
        while i < len(b) and not is_word_byte(b[i]):
            i += 1
        while i < len(b) and is_word_byte(b[i]):
            i += 1
        return Pos(p.para, i)

    def move_to(mut self, p: Pos, extend: Bool, keep_goal: Bool = False):
        self.caret = self.clamp(p)
        if not extend:
            self.anchor = self.caret
        if not keep_goal:
            self.goal_x = -1
        self.history.seal()
        self.view_version += 1
        self.reveal()

    # ------------------------------------------------ keys

    def key(mut self, name: String, mods: Int, now_ms: Int, font: Font, styler: Some[Styler]) -> Bool:
        """A key press: a typed character, or a web key name. True when the editor used it."""
        var shift = (mods & SHIFT) != 0
        if (mods & (CTRL | ALT)) == 0:
            if name == "ArrowUp" or name == "ArrowDown":
                self.vertical(1 if name == "ArrowDown" else -1, shift, font, styler)
                return True
            if name == "PageUp" or name == "PageDown":
                var lines = max(Int(self.height / 22) - 1, 1)
                for _ in range(lines):
                    self.vertical(1 if name == "PageDown" else -1, shift, font, styler)
                return True
            if name == "Home" or name == "End":
                self.line_edge(name == "End", shift, font, styler)
                return True
        return self.edit_key(name, mods, now_ms)

    def edit_key(mut self, name: String, mods: Int, now_ms: Int) -> Bool:
        """The keys that need no layout (everything but up, down, page up and down, and a line's edges): for an editor
        that lays its text out itself (mojoui.pagesheet). True when it was used."""
        var shift = (mods & SHIFT) != 0
        var ctrl = (mods & CTRL) != 0
        var alt = (mods & ALT) != 0
        if alt and not ctrl:  # (Option on a Mac: by words)
            if name == "ArrowLeft":
                self.move_to(self.prev_word(self.caret), shift)
                return True
            if name == "ArrowRight":
                self.move_to(self.next_word(self.caret), shift)
                return True
            if name == "Backspace":
                if not self.has_selection():
                    self.anchor = self.prev_word(self.caret)
                self.replace(self.sel_start(), self.sel_end(), "", EDIT_OTHER, now_ms)
                return True
        if ctrl:
            if name == "c" or name == "C":
                if self.has_selection():
                    self.clip = self.selected_text()
                    self.clip_version += 1
                return True
            if name == "x" or name == "X":
                if self.has_selection():
                    self.clip = self.cut(now_ms)
                    self.clip_version += 1
                return True
            if name == "v" or name == "V":
                if self.clip == "":
                    return False  # (nothing of ours to paste: the key goes on, so a host's system paste can take it, D-7427)
                var pasted = self.clip
                self.replace(self.sel_start(), self.sel_end(), pasted, EDIT_OTHER, now_ms)
                return True
            if name == "a" or name == "A":
                self.select_all()
                return True
            if name == "z" or name == "Z":
                if shift or name == "Z":
                    return self.redo()
                return self.undo()
            if name == "y":
                return self.redo()
            if name == "ArrowLeft":
                self.move_to(self.prev_word(self.caret), shift)
                return True
            if name == "ArrowRight":
                self.move_to(self.next_word(self.caret), shift)
                return True
            if name == "Home":
                self.move_to(Pos(0, 0), shift)
                return True
            if name == "End":
                var last = len(self.paras) - 1
                self.move_to(Pos(last, self.paras[last].byte_length()), shift)
                return True
            if name == "Backspace":
                if not self.has_selection():
                    self.anchor = self.prev_word(self.caret)
                self.replace(self.sel_start(), self.sel_end(), "", EDIT_OTHER, now_ms)
                return True
            if name == "Delete":
                if not self.has_selection():
                    self.anchor = self.next_word(self.caret)
                self.replace(self.sel_start(), self.sel_end(), "", EDIT_OTHER, now_ms)
                return True
            return False
        if name == "ArrowLeft":
            if self.has_selection() and not shift:
                self.move_to(self.sel_start(), False)
            else:
                self.move_to(self.prev_char(self.caret), shift)
            return True
        if name == "ArrowRight":
            if self.has_selection() and not shift:
                self.move_to(self.sel_end(), False)
            else:
                self.move_to(self.next_char(self.caret), shift)
            return True
        if name == "Backspace":
            if self.has_selection():
                self.replace(self.sel_start(), self.sel_end(), "", EDIT_OTHER, now_ms)
            elif not (self.caret == Pos(0, 0)):
                var p = self.prev_char(self.caret)
                if self.caret.byte > 0:
                    p = Pos(self.caret.para, erase_start(self.paras[self.caret.para], self.caret.byte))
                self.replace(p, self.caret, "", EDIT_DELETE, now_ms)
            return True
        if name == "Delete":
            if self.has_selection():
                self.replace(self.sel_start(), self.sel_end(), "", EDIT_OTHER, now_ms)
            else:
                var p = self.next_char(self.caret)
                if not (p == self.caret):
                    self.replace(self.caret, p, "", EDIT_DELETE, now_ms)
            return True
        if name == "Enter":
            self.insert("\n", now_ms)
            return True
        if name == "Tab":
            self.insert("    ", now_ms)
            return True
        if typed_text(name) and not alt:  # (a character, of however many code points; Alt+letter is a shortcut)
            self.insert(name, now_ms)
            return True
        return False

    # ------------------------------------------------ layout

    def resize(mut self, w: Float64, h: Float64):
        if w != self.width:
            for i in range(len(self.laid)):
                self.laid[i].valid = False
        self.width = w
        self.height = h
        self.view_version += 1

    def content_width(self) -> Float64:
        return max(self.width - 2 * self.pad_x, 40.0)

    def caret_in(self, i: Int) -> Bool:
        var a = self.sel_start()
        var b = self.sel_end()
        return self.focused and a.para <= i and i <= b.para

    def lay(mut self, i: Int, font: Font, styler: Some[Styler]):
        """Wrap paragraph i at the content width (cached: only when its text, the width, the styler or whether the caret
        is in it changed)."""
        var here = self.caret_in(i)
        if styler.version() != self.styler_version:
            self.styler_version = styler.version()
            for k in range(len(self.laid)):
                self.laid[k].valid = False
        ref l = self.laid[i]
        if l.valid and l.caret_here == here and l.width == self.content_width():
            return
        var look = styler.look(self.paras[i], i, here)
        var text = self.paras[i]
        var bytes = text.as_bytes()
        var avail = self.content_width() - look.indent
        var starts = List[Int]()
        var heights = List[Float64]()
        var ascents = List[Float64]()
        var tops = List[Float64]()
        starts.append(0)
        var x = 0.0
        var line_size = 0.0
        var last_break = -1  # byte after the last space on this line
        var width_at_break = 0.0
        var si = 0
        var i_b = 0
        var n = len(bytes)
        while i_b < n:
            while si + 1 < len(look.spans) and look.spans[si + 1].start <= i_b:
                si += 1
            ref sp = look.spans[si]
            var cl = utf8_len(bytes[i_b])
            if not sp.hidden:
                var w = adv(font, sp.weight, decode_at(text, i_b), sp.size)
                line_size = max(line_size, sp.size)
                if x + w > avail and x > 0:
                    if last_break > starts[len(starts) - 1]:
                        starts.append(last_break)
                        x = x - width_at_break
                    else:
                        starts.append(i_b)
                        x = 0
                    last_break = -1
                x += w
                if bytes[i_b] == 32:
                    last_break = i_b + 1
                    width_at_break = x
            i_b += cl
        # heights: each line's biggest visible size
        var top = look.before
        for k in range(len(starts)):
            var a = starts[k]
            var b = starts[k + 1] if k + 1 < len(starts) else n
            var big = 0.0
            for s in look.spans:
                if not s.hidden and s.start < max(b, a + 1) and s.end > a:
                    big = max(big, s.size)
            if big == 0:
                big = look.spans[0].size if len(look.spans) > 0 else 15
            var h = big * look.gap
            tops.append(top)
            heights.append(h)
            ascents.append((h - big) / 2 + big * 0.8)
            top += h
        l.valid = True
        l.width = self.content_width()
        l.caret_here = here
        l.starts = starts^
        l.heights = heights^
        l.ascents = ascents^
        l.tops = tops^
        l.height = top + look.after
        l.look = look^

    def para_height(self, i: Int) -> Float64:
        if self.laid[i].valid:
            return self.laid[i].height
        var per_line = max(Int(self.content_width() / self.est_char_w), 10)
        return Float64(max((self.paras[i].byte_length() + per_line - 1) // per_line, 1)) * 22.0

    def x_in_line(self, i: Int, line: Int, byte: Int, font: Font) -> Float64:
        """The x (from the content's left) of byte in paragraph i's line (laid out)."""
        ref l = self.laid[i]
        var bytes = self.paras[i].as_bytes()
        var x = l.look.indent
        var b = l.starts[line]
        var si = span_at(l.look, b)
        while b < byte and b < len(bytes):
            while si + 1 < len(l.look.spans) and l.look.spans[si + 1].start <= b:
                si += 1
            ref sp = l.look.spans[si]
            if not sp.hidden:
                x += adv(font, sp.weight, decode_at(self.paras[i], b), sp.size)
            b += utf8_len(bytes[b])
        return x

    def line_of(self, i: Int, byte: Int) -> Int:
        ref l = self.laid[i]
        var line = 0
        for k in range(len(l.starts)):
            if l.starts[k] <= byte:
                line = k
        return line

    def byte_at_x(self, i: Int, line: Int, x: Float64, font: Font) -> Int:
        """The byte nearest x on paragraph i's line."""
        ref l = self.laid[i]
        var bytes = self.paras[i].as_bytes()
        var end = l.starts[line + 1] if line + 1 < len(l.starts) else len(bytes)
        var b = l.starts[line]
        var pen = l.look.indent
        var si = span_at(l.look, b)
        while b < end:
            while si + 1 < len(l.look.spans) and l.look.spans[si + 1].start <= b:
                si += 1
            ref sp = l.look.spans[si]
            var w = 0.0 if sp.hidden else adv(font, sp.weight, decode_at(self.paras[i], b), sp.size)
            if w > 0 and x < pen + w / 2:
                return b
            pen += w
            b += utf8_len(bytes[b])
        # (a wrapped line ends before its last space: the caret stays on the line)
        if line + 1 < len(l.starts) and end > l.starts[line] and bytes[end - 1] == 32:
            return end - 1
        return end

    # ------------------------------------------------ where things are (box points)

    def para_top(mut self, i: Int, font: Font, styler: Some[Styler]) -> Float64:
        """Paragraph i's top in the box (may be off screen). Lays out the paragraphs between the top one and i."""
        var y = self.pad_y - self.top_off
        if i >= self.top_para:
            for k in range(self.top_para, i):
                self.lay(k, font, styler)
                y += self.laid[k].height
                if y > self.height * 4:
                    return y + 1e6  # (far below)
        else:
            var k = self.top_para - 1
            while k >= i:
                self.lay(k, font, styler)
                y -= self.laid[k].height
                if y < -self.height * 4:
                    return y - 1e6
                k -= 1
        return y

    def caret_box(mut self, font: Font, styler: Some[Styler]) -> Tuple[Float64, Float64, Float64]:
        """(x, top, height) of the caret in the box."""
        var i = self.caret.para
        self.lay(i, font, styler)
        var line = self.line_of(i, self.caret.byte)
        var y = self.para_top(i, font, styler)
        ref l = self.laid[i]
        var x = self.pad_x + self.x_in_line(i, line, self.caret.byte, font)
        return (x, y + l.tops[line], l.heights[line])

    def hit(mut self, x: Float64, y_in: Float64, font: Font, styler: Some[Styler]) -> Pos:
        """The position under (x, y) in the box."""
        var top = self.pad_y - self.top_off
        var i = self.top_para
        var y = max(y_in, top)  # (above the first line: on it)
        while i < len(self.paras):
            self.lay(i, font, styler)
            ref l = self.laid[i]
            if y < top + l.height or i == len(self.paras) - 1:
                var line = 0
                for k in range(len(l.starts)):
                    if y - top >= l.tops[k]:
                        line = k
                return Pos(i, self.byte_at_x(i, line, x - self.pad_x, font))
            top += l.height
            i += 1
        return Pos(len(self.paras) - 1, self.paras[len(self.paras) - 1].byte_length())

    def press(mut self, x: Float64, y: Float64, extend: Bool, font: Font, styler: Some[Styler]):
        self.focused = True
        var p = self.hit(x, y, font, styler)
        self.move_to(p, extend)
        self.dragging = True

    def drag_to(mut self, x: Float64, y: Float64, font: Font, styler: Some[Styler]):
        if not self.dragging:
            return
        var p = self.hit(x, y, font, styler)
        self.caret = p
        self.view_version += 1

    def release(mut self):
        self.dragging = False

    def select_word(mut self, x: Float64, y: Float64, font: Font, styler: Some[Styler]):
        var p = self.hit(x, y, font, styler)
        var a = self.prev_word(self.next_char(p)) if p.byte < self.paras[p.para].byte_length() else self.prev_word(p)
        var b = self.next_word(a)
        self.anchor = a
        self.caret = b
        self.view_version += 1

    # ------------------------------------------------ vertical moves and scrolling

    def vertical(mut self, dir: Int, extend: Bool, font: Font, styler: Some[Styler]):
        var i = self.caret.para
        self.lay(i, font, styler)
        var line = self.line_of(i, self.caret.byte)
        if self.goal_x < 0:
            self.goal_x = self.x_in_line(i, line, self.caret.byte, font)
        var gx = self.goal_x
        var target: Pos
        if dir > 0:
            if line + 1 < len(self.laid[i].starts):
                target = Pos(i, self.byte_at_x(i, line + 1, gx, font))
            elif i + 1 < len(self.paras):
                self.lay(i + 1, font, styler)
                target = Pos(i + 1, self.byte_at_x(i + 1, 0, gx, font))
            else:
                target = Pos(i, self.paras[i].byte_length())
        else:
            if line > 0:
                target = Pos(i, self.byte_at_x(i, line - 1, gx, font))
            elif i > 0:
                self.lay(i - 1, font, styler)
                target = Pos(i - 1, self.byte_at_x(i - 1, len(self.laid[i - 1].starts) - 1, gx, font))
            else:
                target = Pos(0, 0)
        self.move_to(target, extend, keep_goal=True)

    def line_edge(mut self, end: Bool, extend: Bool, font: Font, styler: Some[Styler]):
        var i = self.caret.para
        self.lay(i, font, styler)
        var line = self.line_of(i, self.caret.byte)
        ref l = self.laid[i]
        var b = l.starts[line]
        if end:
            b = l.starts[line + 1] - 1 if line + 1 < len(l.starts) else self.paras[i].byte_length()
        self.move_to(Pos(i, b), extend)

    def reveal(mut self):
        """After the caret moved: bring its paragraph into view (exact placement happens in paint, which knows the font)."""
        if self.caret.para < self.top_para:
            self.top_para = self.caret.para
            self.top_off = 0
        self.view_version += 1

    def scroll_by(mut self, dy: Float64, font: Font, styler: Some[Styler]):
        """Moves the view dy points down (negative: up)."""
        self.top_off += dy
        while self.top_off < 0 and self.top_para > 0:
            self.top_para -= 1
            self.lay(self.top_para, font, styler)
            self.top_off += self.laid[self.top_para].height
        if self.top_off < 0:
            self.top_off = 0
        while self.top_para < len(self.paras) - 1:
            self.lay(self.top_para, font, styler)
            var h = self.laid[self.top_para].height
            if self.top_off < h:
                break
            self.top_off -= h
            self.top_para += 1
        self.view_version += 1

    def keep_caret_visible(mut self, font: Font, styler: Some[Styler]):
        """The caret's line inside the box (scrolls the least)."""
        var i = self.caret.para
        if i < self.top_para:
            self.top_para = i
            self.top_off = 0
        var cb = self.caret_box(font, styler)
        if cb[1] < 0:
            self.scroll_by(cb[1] - self.pad_y, font, styler)
        elif cb[1] + cb[2] > self.height:
            if cb[1] > self.height * 3:  # (far below: start the view at the caret's paragraph, then back off)
                self.top_para = i
                self.top_off = 0
                cb = self.caret_box(font, styler)
            self.scroll_by(cb[1] + cb[2] - self.height + self.pad_y, font, styler)

    # ------------------------------------------------ painting

    def paint[P: Painter](mut self, mut p: P, font: Font, x0: Float64, y0: Float64, styler: Some[Styler], notes: Bool = False):
        """The visible lines at (x0, y0) in the painter's units: blocks, markers, selection, text, caret."""
        if self.focused:
            self.keep_caret_visible(font, styler)
        var sa = self.sel_start()
        var sb = self.sel_end()
        var sel = self.has_selection()
        var y = y0 + self.pad_y - self.top_off
        var bottom = y0 + self.height
        var i = self.top_para
        p.push_clip(x0, y0, self.width, self.height)
        while i < len(self.paras) and y < bottom:
            self.lay(i, font, styler)
            ref l = self.laid[i]
            var bytes = self.paras[i].as_bytes()
            var left = x0 + self.pad_x
            if l.look.block == BLOCK_CODE:
                p.rect(left - 6, y, self.content_width() + 12, l.height, l.look.block_color, 4)
            elif l.look.block == BLOCK_QUOTE:
                p.rect(left + 2, y + l.look.before, 3, l.height - l.look.before - l.look.after, l.look.block_color, 1.5)
            elif l.look.block == BLOCK_RULE and len(l.starts) > 0:
                p.rect(left, y + l.tops[0] + l.heights[0] / 2, self.content_width(), 1, l.look.block_color, 0)
            if l.look.marker_role != "" and len(l.starts) > 0:
                var msize = l.look.spans[0].size if len(l.look.spans) > 0 else 15
                var mid = y + l.tops[0] + l.heights[0] / 2
                var mx = left + l.look.indent - msize * 1.1
                var mc = l.look.marker_color
                if l.look.marker_role == "bullet":
                    p.circle(mx + msize * 0.35, mid, msize * 0.17, mc)
                elif l.look.marker_role == "task" or l.look.marker_role == "done":
                    var bs = msize * 0.95
                    var bx = mx - msize * 0.1
                    var by = mid - bs / 2
                    if l.look.marker_role == "done":
                        p.rect(bx, by, bs, bs, mc, 3.5)
                        p.line(bx + bs * 0.24, by + bs * 0.52, bx + bs * 0.43, by + bs * 0.72, 1.8, 0xFFFFFFFF)
                        p.line(bx + bs * 0.43, by + bs * 0.72, bx + bs * 0.78, by + bs * 0.3, 1.8, 0xFFFFFFFF)
                    else:
                        p.rect(bx, by, bs, bs, mc, 3.5)
                        p.rect(bx + 1.5, by + 1.5, bs - 3, bs - 3, l.look.marker_back, 2.5)
                else:
                    p.text(font, l.look.marker, mx - msize * 0.4, y + l.tops[0] + l.ascents[0], msize, mc, REGULAR, LEFT, 0)
                if notes:
                    p.note("marker " + l.look.marker_role + " " + String(i))
            for line in range(len(l.starts)):
                var a = l.starts[line]
                var b = l.starts[line + 1] if line + 1 < len(l.starts) else len(bytes)
                var ly = y + l.tops[line]
                if ly > bottom:
                    break
                if ly + l.heights[line] < y0:
                    continue
                var base = ly + l.ascents[line]
                # selection
                if sel and sa.para <= i and i <= sb.para:
                    var from_b = a if (i > sa.para or sa.byte <= a) else sa.byte
                    var to_b = b if (i < sb.para or sb.byte >= b) else sb.byte
                    if from_b < to_b or (i < sb.para and line == len(l.starts) - 1):
                        var xa = self.x_in_line(i, line, max(from_b, a), font)
                        var xb = self.x_in_line(i, line, min(to_b, b), font) + (6.0 if i < sb.para and line == len(l.starts) - 1 else 0.0)
                        if xb > xa:
                            p.rect(left + xa, ly, xb - xa, l.heights[line], self.select_color, 2)
                # text, run by run
                var pen = left + l.look.indent
                var si = span_at(l.look, a)
                var cur = a
                while cur < b:
                    while si + 1 < len(l.look.spans) and l.look.spans[si + 1].start <= cur:
                        si += 1
                    ref sp = l.look.spans[si]
                    var run_end = b
                    if si + 1 < len(l.look.spans):
                        run_end = min(b, l.look.spans[si + 1].start)
                    run_end = min(run_end, max(sp.end, cur + 1)) if sp.end > cur else run_end
                    if run_end <= cur:
                        run_end = b
                    if not sp.hidden:
                        var t = String(self.paras[i][byte=cur:run_end])
                        var w = 0.0
                        var k = cur
                        while k < run_end:
                            w += adv(font, sp.weight, decode_at(self.paras[i], k), sp.size)
                            k += utf8_len(bytes[k])
                        if sp.back != 0:
                            p.rect(pen - 2, ly + 2, w + 4, l.heights[line] - 4, sp.back, 3)
                        p.text(font, t, pen, base, sp.size, sp.color, sp.weight, LEFT, sp.slant)
                        if notes:
                            p.note("run " + l.look.role + " " + sp.role + " " + t)
                        if sp.underline:
                            p.rect(pen, base + 2, w, 1, sp.color, 0)
                        if sp.strike:
                            p.rect(pen, base - sp.size * 0.3, w, 1.2, sp.color, 0)
                        pen += w
                    elif notes:
                        p.note("hidden " + sp.role + " " + String(self.paras[i][byte=cur:run_end]))
                    cur = run_end
            # caret
            if self.focused and not sel and self.caret.para == i:
                var line = self.line_of(i, self.caret.byte)
                var cx = left + self.x_in_line(i, line, self.caret.byte, font)
                p.rect(cx - 0.75, y + l.tops[line] + 2, 1.5, l.heights[line] - 4, self.caret_color, 0.75)
                if notes:
                    p.note("caret " + String(i) + " " + String(self.caret.byte))
            y += l.height
            i += 1
        p.pop_clip()

    def scroll_fraction(self) -> Float64:
        """Roughly how far down the view is (0 to 1), for a scroll bar."""
        if len(self.paras) <= 1:
            return 0
        return Float64(self.top_para) / Float64(len(self.paras) - 1)


def now_ms() -> Int:
    return Int(perf_counter_ns() // 1_000_000)
