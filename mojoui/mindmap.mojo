# mojoui.mindmap: a natively drawn mind map (goal 74 M5): a root in the middle, first-level topics balanced to its right
# and left, deeper topics following their side; tapered curved branches drawn as filled polygons; keys like XMind and
# Personal Note (Tab child, Enter sibling, F2 or typing edits, Delete, arrows, Space collapses, ctrl+z / ctrl+shift+z);
# undo through mojoui.history; an indented outline as its text form. No JS, no toolkit widget: a topic being edited is
# a mojoui.textedit TextEdit painted inside its pill. Painted through any Painter (a Scene for GPU hosts, agents, tests).
#
#   var m = MindMap("Groceries")
#   _ = m.key("Tab", 0, now_ms, font)        # a child of the focused topic, being edited
#   _ = m.key("M", 0, now_ms, font) …        # typed into it
#   _ = m.key("Enter", 0, now_ms, font)      # committed: one undo step (the new topic and its words)
#   m.paint(painter, font, MapView(cx, cy, 1.0))   # the root's centre lands at (cx, cy); zoom 1
#   var id = m.hit(x, y)                     # the topic under a pointer (screen points, the last painted view), or -1
#   var s = m.to_text(); m.from_text(s)      # an indented outline, one topic per line, flags kept
#
# Layout is a tidy tree per side: a topic's box comes from its text (wrapped at max_text_w, measured with the same
# rule the TextEdit uses, so a topic doesn't jump when edited); every topic owns a horizontal band as tall as its
# subtree; sibling bands are stacked with v_gap between them and a topic's children sit h_gap beyond its outer edge,
# inside its band. Bands of siblings don't meet and children are always further out than their parent, so no two
# visible boxes overlap (tests/test_mindmap checks it on 500 random topics). A collapsed topic's subtree takes no room.

from mojoui.text import Font, REGULAR, MEDIUM, LEFT, CENTRE
from mojoui.scene import Painter
from mojoui.history import History, Snapshot
from mojoui.textedit import TextEdit, Styler, ParaLook, StyleSpan, Pos, adv, decode_at, utf8_len, SHIFT, CTRL, ALT
from mojoui.canvas import rgba

comptime RIGHT_SIDE = 1
comptime LEFT_SIDE = -1
comptime DONE_NONE = 0  # no checkbox
comptime DONE_OPEN = 1  # a task, not done
comptime DONE_YES = 2  # a task, done

comptime STEP_ADD = 1  # Snapshot kinds (merging needs equal kinds; the map never coalesces, so these are labels)
comptime STEP_TEXT = 2
comptime STEP_DELETE = 3
comptime STEP_TOGGLE = 4
comptime STEP_OTHER = 5


@fieldwise_init
struct MapNode(Copyable, Movable):
    """One topic. `id` is its index in MapModel.nodes and never changes; a deleted topic stays as a tombstone."""

    var id: Int
    var parent: Int  # -1: the root
    var children: List[Int]  # in order (top to bottom on their side)
    var text: String
    var collapsed: Bool
    var done: Int  # DONE_*
    var color: UInt32  # 0: the branch's palette colour
    var side: Int  # first-level topics: RIGHT_SIDE or LEFT_SIDE (deeper topics follow their first-level ancestor)
    var alive: Bool


struct MapModel(Copyable, Movable):
    """The tree and the focused topic: everything an undo step puts back."""

    var nodes: List[MapNode]
    var focus: Int

    def __init__(out self, root_text: String):
        self.nodes = List[MapNode]()
        self.nodes.append(MapNode(0, -1, List[Int](), root_text, False, DONE_NONE, 0, RIGHT_SIDE, True))
        self.focus = 0

    def count(self) -> Int:
        var n = 0
        for ref nd in self.nodes:
            if nd.alive:
                n += 1
        return n

    def subtree_count(self, id: Int) -> Int:
        var n = 1
        for c in self.nodes[id].children:
            n += self.subtree_count(c)
        return n

    def depth(self, id: Int) -> Int:
        var d = 0
        var i = id
        while self.nodes[i].parent >= 0:
            i = self.nodes[i].parent
            d += 1
        return d

    def first_level(self, id: Int) -> Int:
        """The first-level ancestor of id (itself when it is one; -1 for the root)."""
        if id == 0:
            return -1
        var i = id
        while self.nodes[i].parent != 0:
            i = self.nodes[i].parent
        return i

    def side_of(self, id: Int) -> Int:
        """Which side id is drawn on (0 for the root)."""
        var f = self.first_level(id)
        return 0 if f < 0 else self.nodes[f].side

    def index_in_parent(self, id: Int) -> Int:
        var p = self.nodes[id].parent
        if p < 0:
            return -1
        for k in range(len(self.nodes[p].children)):
            if self.nodes[p].children[k] == id:
                return k
        return -1

    def balanced_side(self) -> Int:
        """The side a new first-level topic goes to: the one with fewer topics (the right on a tie)."""
        var r = 0
        var l = 0
        for c in self.nodes[0].children:
            if self.nodes[c].side == RIGHT_SIDE:
                r += self.subtree_count(c)
            else:
                l += self.subtree_count(c)
        return RIGHT_SIDE if r <= l else LEFT_SIDE

    def insert(mut self, parent: Int, at: Int, text: String) -> Int:
        """A new topic under `parent` at child position `at` (-1: last). Returns its id."""
        var id = len(self.nodes)
        var side = self.balanced_side() if parent == 0 else RIGHT_SIDE
        self.nodes.append(MapNode(id, parent, List[Int](), text, False, DONE_NONE, 0, side, True))
        var n = len(self.nodes[parent].children)
        var pos = n if at < 0 or at > n else at
        self.nodes[parent].children.insert(pos, id)
        return id

    def remove(mut self, id: Int):
        """Removes id and its subtree (tombstones; the root can't go)."""
        if id <= 0:
            return
        var p = self.nodes[id].parent
        var k = self.index_in_parent(id)
        if k >= 0:
            _ = self.nodes[p].children.pop(k)
        self._bury(id)

    def _bury(mut self, id: Int):
        self.nodes[id].alive = False
        for c in self.nodes[id].children.copy():
            self._bury(c)


struct NodeStyler(Styler, Copyable, Movable):
    """How a topic being edited looks in its TextEdit: one size, weight and colour (matches the painted label)."""

    var size: Float64
    var weight: Int
    var color: UInt32

    def __init__(out self, size: Float64, weight: Int, color: UInt32):
        self.size = size
        self.weight = weight
        self.color = color

    def look(self, text: String, index: Int, caret_here: Bool) -> ParaLook:
        var l = ParaLook(self.size, self.color, text.byte_length())
        l.spans[0].weight = self.weight
        return l^

    def version(self) -> Int:
        return Int(self.size * 100) + self.weight


@fieldwise_init
struct MapView(Copyable, Movable, ImplicitlyCopyable):
    """Where the map is shown: the root's centre lands at (dx, dy) and everything is scaled by k."""

    var dx: Float64
    var dy: Float64
    var k: Float64


struct MapStyle(Copyable, Movable):
    """Colours and sizes (a theme sets these; the defaults are Liquid light)."""

    var ink: UInt32
    var muted: UInt32
    var card: UInt32
    var root_fill: UInt32
    var root_ink: UInt32
    var focus: UInt32
    var badge_ink: UInt32
    var palette: List[UInt32]
    var root_size: Float64
    var first_size: Float64
    var size: Float64
    var pad_x: Float64
    var pad_y: Float64
    var max_text_w: Float64
    var min_text_w: Float64
    var h_gap: Float64
    var v_gap: Float64

    def __init__(out self):
        self.ink = rgba(0x1F, 0x24, 0x2B)
        self.muted = rgba(0x8A, 0x92, 0x9C)
        self.card = rgba(0xFF, 0xFF, 0xFF)
        self.root_fill = rgba(0x1F, 0x24, 0x2B)
        self.root_ink = rgba(0xFF, 0xFF, 0xFF)
        self.focus = rgba(0x3C, 0xC4, 0xCF)
        self.badge_ink = rgba(0xFF, 0xFF, 0xFF)
        self.palette = [
            rgba(0x3C, 0x8D, 0xEF), rgba(0xF2, 0x7A, 0x4B), rgba(0x2F, 0xB3, 0x7B), rgba(0xB0, 0x6C, 0xE8),
            rgba(0xE8, 0xB4, 0x2F), rgba(0xE5, 0x5A, 0x8C), rgba(0x2A, 0xB5, 0xC2), rgba(0x7A, 0x86, 0x99),
        ]
        self.root_size = 20
        self.first_size = 16
        self.size = 14
        self.pad_x = 14
        self.pad_y = 7
        self.max_text_w = 200
        self.min_text_w = 24
        self.h_gap = 44
        self.v_gap = 12


struct NodeBox(Copyable, Movable):
    """A topic's laid-out box (map coordinates: the root's centre is (0, 0)) and its wrapped lines (cached by text)."""

    var x: Float64
    var y: Float64
    var w: Float64
    var h: Float64
    var band: Float64  # the subtree's height
    var visible: Bool
    var side: Int
    var color: UInt32
    var depth: Int
    var text: String  # what `lines` were wrapped from
    var size: Float64
    var lines: List[String]
    var text_w: Float64
    var valid: Bool

    def __init__(out self):
        self.x = 0
        self.y = 0
        self.w = 0
        self.h = 0
        self.band = 0
        self.visible = False
        self.side = 0
        self.color = 0
        self.depth = 0
        self.text = ""
        self.size = 0
        self.lines = List[String]()
        self.text_w = 0
        self.valid = False

    def cx(self) -> Float64:
        return self.x + self.w / 2

    def cy(self) -> Float64:
        return self.y + self.h / 2


def line_height(size: Float64) -> Float64:
    return size * 1.45  # (TextEdit's ParaLook gap)


def wrap(font: Font, text: String, size: Float64, weight: Int, avail: Float64, mut out: List[String]) -> Float64:
    """Wraps `text` at `avail` the way TextEdit.lay does (break at the last space, or mid-word when a word is too long;
    "\n" starts a paragraph). Appends the lines to `out`; returns the widest line's width."""
    var widest = 0.0
    var bytes = text.as_bytes()
    var n = len(bytes)
    var start = 0
    while True:
        var para_end = start
        while para_end < n and bytes[para_end] != 10:
            para_end += 1
        var line_start = start
        var x = 0.0
        var last_break = -1
        var width_at_break = 0.0
        var i = start
        while i < para_end:
            var cl = utf8_len(bytes[i])
            var w = adv(font, weight, decode_at(text, i), size)
            if x + w > avail and x > 0:
                if last_break > line_start:
                    out.append(String(text[byte=line_start:last_break]))
                    widest = max(widest, width_at_break)
                    line_start = last_break
                    x = x - width_at_break
                else:
                    out.append(String(text[byte=line_start:i]))
                    widest = max(widest, x)
                    line_start = i
                    x = 0
                last_break = -1
            x += w
            if bytes[i] == 32:
                last_break = i + 1
                width_at_break = x
            i += cl
        out.append(String(text[byte=line_start:para_end]))
        widest = max(widest, x)
        if para_end >= n:
            break
        start = para_end + 1
    return widest


def _escape(text: String) -> String:
    var out = String()
    for ch in text.codepoint_slices():
        var c = String(ch)
        if c == "\\":
            out += "\\\\"
        elif c == "\n":
            out += "\\n"
        else:
            out += c
    return out^


def _unescape(text: String) -> String:
    var out = String()
    var esc = False
    for ch in text.codepoint_slices():
        var c = String(ch)
        if esc:
            out += "\n" if c == "n" else c
            esc = False
        elif c == "\\":
            esc = True
        else:
            out += c
    return out^


def _hex8(v: UInt32) -> String:
    var digits = "0123456789abcdef"
    var out = String()
    for k in range(8):
        var d = Int((v >> UInt32((7 - k) * 4)) & 15)
        out += String(digits[byte=d : d + 1])
    return out^


def _parse_hex(s: String) -> UInt32:
    var v: UInt32 = 0
    for b in s.as_bytes():
        var c = Int(b)
        var d = 0
        if c >= 48 and c <= 57:
            d = c - 48
        elif c >= 97 and c <= 102:
            d = c - 87
        elif c >= 65 and c <= 70:
            d = c - 55
        v = (v << 4) | UInt32(d)
    return v


def _printable(name: String) -> Bool:
    var b = name.as_bytes()
    return len(b) > 0 and len(b) == utf8_len(b[0]) and Int(b[0]) >= 32 and Int(b[0]) != 127


struct MindMap(Movable):
    var model: MapModel
    var boxes: List[NodeBox]  # by id
    var history: History[Snapshot[MapModel]]
    var style: MapStyle
    var view: MapView  # the last painted view (hit tests use it)
    var dirty: Bool  # the layout must be redone
    var editing: Int  # the topic being edited, or -1
    var edit_new: Bool  # it was made for this edit (Escape on it while empty removes it)
    var edit_before: MapModel  # the model before the edit (or before the new topic): the undo step's "before"
    var ed: TextEdit
    var last_tap_ms: Int
    var last_tap_id: Int
    var version: Int  # changes on every change of the model, the focus or the edit (a host redraws)

    def __init__(out self, root_text: String = "Central topic"):
        self.model = MapModel(root_text)
        self.boxes = List[NodeBox]()
        self.history = History[Snapshot[MapModel]](cap=500)
        self.style = MapStyle()
        self.view = MapView(0, 0, 1)
        self.dirty = True
        self.editing = -1
        self.edit_new = False
        self.edit_before = self.model.copy()
        self.ed = TextEdit("")
        self.last_tap_ms = -1_000_000
        self.last_tap_id = -1
        self.version = 0

    # ------------------------------------------------ reading

    def nodes(self) -> Int:
        return self.model.count()

    def visible_nodes(mut self) -> Int:
        var n = 0
        for id in range(len(self.model.nodes)):
            if self.is_visible(id):
                n += 1
        return n

    def is_visible(self, id: Int) -> Bool:
        if id < 0 or id >= len(self.model.nodes) or not self.model.nodes[id].alive:
            return False
        var p = self.model.nodes[id].parent
        while p >= 0:
            if self.model.nodes[p].collapsed:
                return False
            p = self.model.nodes[p].parent
        return True

    def focus(self) -> Int:
        return self.model.focus

    def text_of(self, id: Int) -> String:
        if id == self.editing:
            return self.ed.text()
        return self.model.nodes[id].text

    def children(self, id: Int) -> List[Int]:
        return self.model.nodes[id].children.copy()

    def parent(self, id: Int) -> Int:
        return self.model.nodes[id].parent

    def side(self, id: Int) -> Int:
        return self.model.side_of(id)

    def hidden_count(self, id: Int) -> Int:
        """Topics under id (all of them, shown or not)."""
        return self.model.subtree_count(id) - 1

    # ------------------------------------------------ changing (each is one undo step)

    def _changed(mut self):
        self.dirty = True
        self.version += 1

    def _push(mut self, kind: Int, var before: MapModel, now_ms: Int):
        self.history.push(Snapshot[MapModel](kind, before^, self.model.copy()), now_ms)
        self._changed()

    def add_child(mut self, parent: Int, text: String, now_ms: Int = 0) -> Int:
        self.commit(now_ms)
        var before = self.model.copy()
        var id = self.model.insert(parent, -1, text)
        self.model.focus = id
        self._push(STEP_ADD, before^, now_ms)
        return id

    def add_sibling(mut self, after: Int, text: String, now_ms: Int = 0) -> Int:
        """A topic right after `after` (on the root: a child)."""
        if after == 0:
            return self.add_child(0, text, now_ms)
        self.commit(now_ms)
        var before = self.model.copy()
        var p = self.model.nodes[after].parent
        var id = self.model.insert(p, self.model.index_in_parent(after) + 1, text)
        if p == 0:
            self.model.nodes[id].side = self.model.nodes[after].side
        self.model.focus = id
        self._push(STEP_ADD, before^, now_ms)
        return id

    def remove(mut self, id: Int, now_ms: Int = 0):
        """Deletes id's subtree (not the root); the focus goes to the previous sibling on its side, else the parent."""
        if id <= 0 or not self.model.nodes[id].alive:
            return
        self.commit(now_ms)
        var before = self.model.copy()
        var p = self.model.nodes[id].parent
        var k = self.model.index_in_parent(id)
        var next_focus = p
        var side = self.model.side_of(id)
        var j = k - 1
        while j >= 0:  # the previous sibling on the same side
            var sib = self.model.nodes[p].children[j]
            if self.model.side_of(sib) == side:
                next_focus = sib
                break
            j -= 1
        self.model.remove(id)
        if not self.model.nodes[self.model.focus].alive or self.model.focus == id:
            self.model.focus = next_focus
        self._push(STEP_DELETE, before^, now_ms)

    def set_text(mut self, id: Int, text: String, now_ms: Int = 0):
        if self.model.nodes[id].text == text:
            return
        var before = self.model.copy()
        self.model.nodes[id].text = text
        self._push(STEP_TEXT, before^, now_ms)

    def toggle(mut self, id: Int, now_ms: Int = 0):
        """Collapses or expands id (a topic without children has nothing to fold)."""
        if len(self.model.nodes[id].children) == 0:
            return
        var before = self.model.copy()
        self.model.nodes[id].collapsed = not self.model.nodes[id].collapsed
        self._push(STEP_TOGGLE, before^, now_ms)

    def set_done(mut self, id: Int, done: Int, now_ms: Int = 0):
        var before = self.model.copy()
        self.model.nodes[id].done = done
        self._push(STEP_OTHER, before^, now_ms)

    def set_color(mut self, id: Int, color: UInt32, now_ms: Int = 0):
        var before = self.model.copy()
        self.model.nodes[id].color = color
        self._push(STEP_OTHER, before^, now_ms)

    def set_focus(mut self, id: Int):
        if id >= 0 and id < len(self.model.nodes) and self.model.nodes[id].alive and id != self.model.focus:
            self.model.focus = id
            self.version += 1

    def undo(mut self) -> Bool:
        self.commit(0)
        var s = self.history.undo()
        if not s:
            return False
        self.model = s.value().before.copy()
        self._changed()
        return True

    def redo(mut self) -> Bool:
        self.commit(0)
        var s = self.history.redo()
        if not s:
            return False
        self.model = s.value().after.copy()
        self._changed()
        return True

    # ------------------------------------------------ editing a topic's words

    def _styler(self, id: Int) -> NodeStyler:
        var d = self.model.depth(id)
        if d == 0:
            return NodeStyler(self.style.root_size, MEDIUM, self.style.root_ink)
        if d == 1:
            return NodeStyler(self.style.first_size, MEDIUM, self.style.ink)
        return NodeStyler(self.style.size, REGULAR, self.style.ink)

    def start_edit(mut self, id: Int, replace: Bool = False, is_new: Bool = False, before: Optional[MapModel] = None):
        """Edits id's words in a TextEdit (replace: start empty; is_new: the topic was made for this edit)."""
        self.commit(0)
        self.model.focus = id
        self.editing = id
        self.edit_new = is_new
        if before:
            self.edit_before = before.value().copy()
        else:
            self.edit_before = self.model.copy()
        self.ed = TextEdit("" if replace else self.model.nodes[id].text)
        var last = len(self.ed.paras) - 1
        self.ed.move_to(Pos(last, self.ed.paras[last].byte_length()), False)
        self.ed.pad_x = self.style.pad_x
        self.ed.pad_y = self.style.pad_y
        self._changed()

    def commit(mut self, now_ms: Int):
        """Ends the edit, keeping its words: one undo step (the new topic and its words together)."""
        if self.editing < 0:
            return
        var id = self.editing
        var text = self.ed.text()
        self.editing = -1
        self.model.nodes[id].text = text
        if self.edit_new or text != self.edit_before.nodes[id].text:
            var before = self.edit_before.copy()
            self._push(STEP_TEXT, before^, now_ms)
        else:
            self._changed()

    def cancel(mut self):
        """Ends the edit dropping its words; a new topic is removed (nothing goes in the history)."""
        if self.editing < 0:
            return
        self.editing = -1
        self.model = self.edit_before.copy()
        self._changed()

    def _new_then_edit(mut self, parent: Int, at: Int, now_ms: Int):
        self.commit(now_ms)
        var before = self.model.copy()
        var id = self.model.insert(parent, at, "")
        if parent == 0 and at >= 0:
            var after = self.model.nodes[0].children[at - 1] if at > 0 else -1
            if after >= 0:
                self.model.nodes[id].side = self.model.nodes[after].side
        self.start_edit(id, False, True, before^)

    # ------------------------------------------------ keys and pointer

    def key(mut self, name: String, mods: Int, now_ms: Int, font: Font) -> Bool:
        """A key press (web key names, or the typed character). True when the map used it."""
        var ctrl = (mods & CTRL) != 0
        var shift = (mods & SHIFT) != 0
        if self.editing >= 0:
            if name == "Enter" and not shift:
                self.commit(now_ms)
                return True
            if name == "Escape":
                if self.edit_new and self.ed.text() == "":
                    self.cancel()
                else:
                    self.commit(now_ms)
                return True
            if name == "Tab":
                var id = self.editing
                self.commit(now_ms)
                self._new_then_edit(id, -1, now_ms)
                return True
            var st = self._styler(self.editing)
            var used = self.ed.key(name, mods, now_ms, font, st)
            if used:
                self._changed()
            return used
        self.layout(font)
        var f = self.model.focus
        if ctrl:
            if name == "z" or name == "Z":
                return self.redo() if (shift or name == "Z") else self.undo()
            if name == "y" or name == "Y":
                return self.redo()
            return False
        if name == "Tab":
            self._new_then_edit(f, -1, now_ms)
            return True
        if name == "Enter":
            if f == 0:
                self._new_then_edit(0, -1, now_ms)
            else:
                self._new_then_edit(self.model.nodes[f].parent, self.model.index_in_parent(f) + 1, now_ms)
            return True
        if name == "F2":
            self.start_edit(f)
            return True
        if name == "Delete" or name == "Backspace":
            if f == 0:
                return False
            self.remove(f, now_ms)
            return True
        if name == " " or name == "Space":
            if len(self.model.nodes[f].children) == 0:
                return False
            self.toggle(f, now_ms)
            return True
        if name == "ArrowLeft" or name == "ArrowRight":
            return self._move_side(LEFT_SIDE if name == "ArrowLeft" else RIGHT_SIDE)
        if name == "ArrowUp" or name == "ArrowDown":
            return self._move_vertical(-1 if name == "ArrowUp" else 1)
        if (mods & ALT) == 0 and _printable(name):
            self.start_edit(f, True)
            var st = self._styler(f)
            _ = self.ed.key(name, mods, now_ms, font, st)
            return True
        return False

    def _nearest_child(self, id: Int, side: Int) -> Int:
        """id's shown child (on `side` for the root) closest to id's middle, or -1."""
        if self.model.nodes[id].collapsed:
            return -1
        var best = -1
        var best_d = 1e300
        var cy = self.boxes[id].cy()
        for c in self.model.nodes[id].children:
            if id == 0 and self.model.nodes[c].side != side:
                continue
            var d = abs(self.boxes[c].cy() - cy)
            if d < best_d:
                best_d = d
                best = c
        return best

    def _move_side(mut self, dir: Int) -> Bool:
        var f = self.model.focus
        var s = self.model.side_of(f)
        var to: Int
        if f == 0:
            to = self._nearest_child(0, dir)
        elif s == dir:
            to = self._nearest_child(f, dir)
        else:
            to = self.model.nodes[f].parent
        if to < 0:
            return False
        self.set_focus(to)
        return True

    def _move_vertical(mut self, dir: Int) -> Bool:
        var f = self.model.focus
        if f != 0:
            var p = self.model.nodes[f].parent
            var s = self.model.side_of(f)
            var sibs = List[Int]()
            for c in self.model.nodes[p].children:
                if self.model.side_of(c) == s:
                    sibs.append(c)
            for k in range(len(sibs)):
                if sibs[k] == f:
                    var j = k + dir
                    if j >= 0 and j < len(sibs):
                        self.set_focus(sibs[j])
                        return True
        # no sibling that way: the nearest shown topic above (below), favouring the same column
        var fx = self.boxes[f].cx()
        var fy = self.boxes[f].cy()
        var best = -1
        var best_d = 1e300
        for id in range(len(self.model.nodes)):
            if id == f or not self.boxes[id].visible:
                continue
            var dy = (self.boxes[id].cy() - fy) * Float64(dir)
            if dy <= 1:
                continue
            var dx = self.boxes[id].cx() - fx
            var d = dy * dy + 4 * dx * dx
            if d < best_d:
                best_d = d
                best = id
        if best < 0:
            return False
        self.set_focus(best)
        return True

    def hit(self, x: Float64, y: Float64) -> Int:
        """The shown topic under (x, y) in screen points (through the last painted view), or -1."""
        var mx = (x - self.view.dx) / self.view.k
        var my = (y - self.view.dy) / self.view.k
        for id in range(len(self.boxes)):
            ref b = self.boxes[id]
            if b.visible and mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h:
                return id
        return -1

    def tap(mut self, x: Float64, y: Float64, now_ms: Int, font: Font) -> Bool:
        """A tap focuses the topic under it; a second tap on it within 400 ms edits it; a tap elsewhere ends an edit."""
        self.layout(font)
        var id = self.hit(x, y)
        if self.editing >= 0 and id != self.editing:
            self.commit(now_ms)
        if id < 0:
            self.last_tap_id = -1
            return False
        if id == self.editing:
            var b = self.boxes[id].copy()
            var st = self._styler(id)
            self.ed.press((x - self.view.dx) / self.view.k - b.x, (y - self.view.dy) / self.view.k - b.y, False, font, st)
            self.version += 1
            return True
        if id == self.last_tap_id and now_ms - self.last_tap_ms <= 400:
            self.start_edit(id)
            self.last_tap_id = -1
            return True
        self.set_focus(id)
        self.last_tap_id = id
        self.last_tap_ms = now_ms
        return True

    # ------------------------------------------------ layout

    def layout(mut self, font: Font):
        """Boxes for every shown topic (cached wrapping; only when something changed)."""
        if not self.dirty:
            return
        self.dirty = False
        while len(self.boxes) < len(self.model.nodes):
            self.boxes.append(NodeBox())
        while len(self.boxes) > len(self.model.nodes):
            _ = self.boxes.pop()
        for id in range(len(self.boxes)):
            self.boxes[id].visible = False
        self._measure(0, 0, font)
        ref root = self.boxes[0]
        root.x = -root.w / 2
        root.y = -root.h / 2
        root.visible = True
        root.side = 0
        root.depth = 0
        root.color = self.style.root_fill
        if self.model.nodes[0].collapsed:
            return
        for side in [RIGHT_SIDE, LEFT_SIDE]:
            var total = 0.0
            var any = False
            for c in self.model.nodes[0].children:
                if self.model.nodes[c].side == side:
                    if any:
                        total += self.style.v_gap
                    total += self.boxes[c].band
                    any = True
            var top = -total / 2
            var k = 0
            var edge = self.boxes[0].x + self.boxes[0].w if side == RIGHT_SIDE else self.boxes[0].x
            var pal = len(self.style.palette)
            for i in range(len(self.model.nodes[0].children)):
                var c = self.model.nodes[0].children[i]
                if self.model.nodes[c].side != side:
                    continue
                var col = self.model.nodes[c].color
                if col == 0:
                    col = self.style.palette[i % pal]
                self._place(c, edge, top, side, col, 1)
                top += self.boxes[c].band + self.style.v_gap
                k += 1

    def _measure(mut self, id: Int, depth: Int, font: Font):
        """id's box size and its subtree's band height (children first)."""
        var text = self.text_of(id)
        var st = self._styler(id)
        ref b = self.boxes[id]
        if not b.valid or b.text != text or b.size != st.size:
            b.lines.clear()
            b.text_w = wrap(font, text, st.size, st.weight, self.style.max_text_w, b.lines)
            b.text = text
            b.size = st.size
            b.valid = True
        var extra = 18.0 if self.model.nodes[id].done != DONE_NONE else 0.0
        b.w = max(b.text_w, self.style.min_text_w) + 2 * self.style.pad_x + extra
        b.h = Float64(len(b.lines)) * line_height(st.size) + 2 * self.style.pad_y
        b.depth = depth
        var kids = 0.0
        if not self.model.nodes[id].collapsed:
            var first = True
            for c in self.model.nodes[id].children.copy():
                self._measure(c, depth + 1, font)
                if not first:
                    kids += self.style.v_gap
                kids += self.boxes[c].band
                first = False
        self.boxes[id].band = max(self.boxes[id].h, kids)

    def _place(mut self, id: Int, edge: Float64, top: Float64, side: Int, color: UInt32, depth: Int):
        """Puts id in the band starting at `top`, h_gap beyond the parent's outer `edge`, then its children."""
        ref b = self.boxes[id]
        b.visible = True
        b.side = side
        b.depth = depth
        b.color = self.model.nodes[id].color if self.model.nodes[id].color != 0 else color
        var cy = top + b.band / 2
        b.y = cy - b.h / 2
        b.x = edge + self.style.h_gap if side == RIGHT_SIDE else edge - self.style.h_gap - b.w
        var outer = b.x + b.w if side == RIGHT_SIDE else b.x
        var col = b.color
        if self.model.nodes[id].collapsed or len(self.model.nodes[id].children) == 0:
            return
        var kids = 0.0
        var first = True
        for c in self.model.nodes[id].children:
            if not first:
                kids += self.style.v_gap
            kids += self.boxes[c].band
            first = False
        var t = cy - kids / 2
        for c in self.model.nodes[id].children.copy():
            self._place(c, outer, t, side, col, depth + 1)
            t += self.boxes[c].band + self.style.v_gap

    # ------------------------------------------------ drawing

    def _branch[P: Painter](self, mut p: P, parent: Int, child: Int):
        """A tapered cubic from the parent's outer side to the child's inner side, as one filled polygon."""
        ref a = self.boxes[parent]
        ref b = self.boxes[child]
        var s = Float64(b.side)
        var x0 = a.cx() if parent == 0 else (a.x + a.w if b.side == RIGHT_SIDE else a.x)
        var y0 = a.cy()
        var x3 = b.x if b.side == RIGHT_SIDE else b.x + b.w
        var y3 = b.cy()
        var dx = x3 - x0
        var x1 = x0 + dx * 0.5
        var x2 = x3 - dx * 0.5
        var w0 = 7.0 if parent == 0 else max(5.0 - Float64(b.depth - 2) * 1.0, 2.0)
        var w1 = 1.6
        comptime N = 18
        var left = List[Float64](capacity=2 * (N + 1))
        var right = List[Float64](capacity=2 * (N + 1))
        for i in range(N + 1):
            var t = Float64(i) / Float64(N)
            var u = 1 - t
            var x = u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3
            var y = u * u * u * y0 + 3 * u * u * t * y0 + 3 * u * t * t * y3 + t * t * t * y3
            var tx = 3 * u * u * (x1 - x0) + 6 * u * t * (x2 - x1) + 3 * t * t * (x3 - x2)
            var ty = 6 * u * t * (y3 - y0)
            var len = (tx * tx + ty * ty) ** 0.5
            if len < 1e-9:
                tx = s
                ty = 0
                len = 1
            var half = (w0 + (w1 - w0) * t) / 2
            var nx = -ty / len * half
            var ny = tx / len * half
            left.append(x + nx)
            left.append(y + ny)
            right.append(x - nx)
            right.append(y - ny)
        var pts = left^
        var i = N
        while i >= 0:
            pts.append(right[2 * i])
            pts.append(right[2 * i + 1])
            i -= 1
        p.polygon(pts, b.color)

    def paint[P: Painter](mut self, mut p: P, font: Font, view: MapView):
        """The map in its own layer, moved and scaled by `view`: branches, then topics (notes for agents and tests:
        "branch <parent>-><child>" on each branch polygon, "node <id> <text>" on each topic's pill)."""
        self.layout(font)
        self.view = view
        p.begin_layer("mindmap")
        p.layer_transform(view.dx, view.dy, view.k)
        for id in range(1, len(self.boxes)):
            if self.boxes[id].visible:
                var par = self.model.nodes[id].parent
                self._branch(p, par, id)
                p.note("branch " + String(par) + "->" + String(id))
        for id in range(len(self.boxes)):
            if self.boxes[id].visible:
                self._node(p, font, id)

    def _node[P: Painter](mut self, mut p: P, font: Font, id: Int):
        var b = self.boxes[id].copy()
        ref nd = self.model.nodes[id]
        var st = self._styler(id)
        var r = min(b.h / 2, 12.0) if id != 0 else b.h / 2
        if id == self.model.focus:
            p.rect(b.x - 3, b.y - 3, b.w + 6, b.h + 6, self.style.focus, r + 3)
        var fill = self.style.root_fill if id == 0 else self.style.card
        p.rect(b.x, b.y, b.w, b.h, fill, r)
        p.note("node " + String(id) + " " + self.text_of(id))
        if id != 0:
            # the branch's colour as a soft edge under a first-level pill, a thin underline under deeper ones
            if b.depth == 1:
                p.rect(b.x, b.y + b.h - 3, b.w, 3, b.color, 1.5)
            else:
                p.rect(b.x + r / 2, b.y + b.h - 2, b.w - r, 1.5, b.color, 0.75)
        var tx = b.x + self.style.pad_x
        if nd.done != DONE_NONE:
            var cx = tx + 6
            var cy = b.cy()
            p.circle(cx, cy, 6, b.color)
            if nd.done == DONE_OPEN:
                p.circle(cx, cy, 4.5, fill)
            else:
                p.line(cx - 3, cy, cx - 1, cy + 2.5, 1.6, self.style.card)
                p.line(cx - 1, cy + 2.5, cx + 3.2, cy - 2.5, 1.6, self.style.card)
            tx += 18
        if id == self.editing:
            self.ed.resize(self.style.max_text_w + 2 * self.style.pad_x, b.h)
            self.ed.paint(p, font, tx - self.style.pad_x, b.y, st)
        else:
            var ink = st.color
            if nd.done == DONE_YES:
                ink = self.style.muted
            var lh = line_height(st.size)
            var y = b.y + self.style.pad_y
            for ref line in b.lines:
                p.text(font, line, tx, y + (lh - st.size) / 2 + st.size * 0.8, st.size, ink, st.weight, LEFT, 0)
                y += lh
        if nd.collapsed and len(nd.children) > 0:
            var n = self.hidden_count(id)
            var label = String(n)
            var bw = max(18.0, font.measure(label, 11, MEDIUM) + 10)
            var bx = b.x + b.w + 6 if b.side != LEFT_SIDE else b.x - 6 - bw
            if id == 0:
                bx = b.x + b.w + 6
            p.rect(bx, b.cy() - 9, bw, 18, b.color, 9)
            p.text(font, label, bx + bw / 2, b.cy() + 4, 11, self.style.badge_ink, MEDIUM, CENTRE, 0)
            p.note("collapsed " + String(id) + " " + label)

    # ------------------------------------------------ text form

    def to_text(self) -> String:
        """An indented outline: two spaces per level, flags, a space, the words ("\\n" and "\\\\" escaped).
        Flags: "-" for none, else c (collapsed), o / x (a task, open / done), L (left side), #aabbggrr (a colour)."""
        var out = String()
        self._line(0, 0, out)
        return out^

    def _line(self, id: Int, depth: Int, mut out: String):
        ref nd = self.model.nodes[id]
        for _ in range(depth):
            out += "  "
        var flags = String()
        if nd.collapsed:
            flags += "c"
        if nd.done == DONE_OPEN:
            flags += "o"
        elif nd.done == DONE_YES:
            flags += "x"
        if depth == 1 and nd.side == LEFT_SIDE:
            flags += "L"
        if nd.color != 0:
            flags += "#" + _hex8(nd.color)
        out += (flags if flags != "" else "-") + " " + _escape(nd.text) + "\n"
        for c in nd.children:
            self._line(c, depth + 1, out)

    def from_text(mut self, text: String):
        """Replaces the map with an outline from to_text (the history starts empty; the root is focused)."""
        self.editing = -1
        var m = MapModel("")
        var stack = List[Int]()  # the last topic at each depth
        var first = True
        var bytes = text.as_bytes()
        var start = 0
        var n = len(bytes)
        while start < n:
            var end = start
            while end < n and bytes[end] != 10:
                end += 1
            var line = String(text[byte=start:end])
            start = end + 1
            var lb = line.as_bytes()
            var sp = 0
            while sp < len(lb) and lb[sp] == 32:
                sp += 1
            if sp >= len(lb):
                continue
            var depth = sp // 2
            var fe = sp
            while fe < len(lb) and lb[fe] != 32:
                fe += 1
            var flags = String(line[byte=sp:fe])
            var words = _unescape(String(line[byte = min(fe + 1, len(lb)) : len(lb)]))
            var id = 0
            if first:
                m.nodes[0].text = words
                first = False
                stack.append(0)
            else:
                depth = max(1, min(depth, len(stack)))
                var parent = stack[depth - 1]
                id = m.insert(parent, -1, words)
                m.nodes[id].side = RIGHT_SIDE
                while len(stack) > depth:
                    _ = stack.pop()
                stack.append(id)
            var fb = flags.as_bytes()
            var k = 0
            while k < len(fb):
                var c = Int(fb[k])
                if c == 99:  # c
                    m.nodes[id].collapsed = True
                elif c == 111:  # o
                    m.nodes[id].done = DONE_OPEN
                elif c == 120:  # x
                    m.nodes[id].done = DONE_YES
                elif c == 76:  # L
                    m.nodes[id].side = LEFT_SIDE
                elif c == 35 and k + 8 < len(fb):  # #aabbggrr
                    m.nodes[id].color = _parse_hex(String(flags[byte = k + 1 : k + 9]))
                    k += 8
                k += 1
        self.model = m^
        self.boxes.clear()
        self.history.clear()
        self._changed()

    def clear_history(mut self):
        self.history.clear()
