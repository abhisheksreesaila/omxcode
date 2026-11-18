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
# Layout is a tidy tree per side, packed by outline (goal 75 M4): a topic's box comes from its text (wrapped at
# max_text_w, measured with the same rule the TextEdit uses, so a topic doesn't jump when edited); its children sit a
# branch's reach beyond its outer edge, stacked top to bottom as close as their subtrees' outlines allow (a subtree's
# levels are compared with its neighbours' levels wherever they share columns, so a short sibling tucks under a big
# one's narrow outer levels), and the parent is centred on them. The root's main branches are balanced right and left
# and fan out: the middle ones reach further than the top and bottom ones. Siblings' outlines never meet and children
# are always further out than their parent, so no two visible boxes overlap (tests/test_mindmap checks it on 500
# random topics). A collapsed topic's subtree takes no room.
#
# The look is Tony Buzan's, after Personal Note's: one-bend organic branches drawn as ribbons that taper by depth
# (thick from the root, thin at the leaves), one colour per main branch, main topics on cards, deeper topics written
# on their branch (the branch runs on under the words; their children leave from its end), the root a strong rounded
# shape. Motion is Liquid: every topic has a shown place that glides to its laid-out place on a spring (mojoui.spring,
# ~250 ms, ~1 % overshoot); new topics grow out of their parent, removed or folded ones shrink into it and fade, and
# the branches follow the shown places every frame. paint() asks for frames (Painter.set_again) only while something
# moves; Painter.still() (less motion) jumps to the end. Time comes from the clock, or from step(dt_ms) (tests).

from mojoui.text import Font, REGULAR, MEDIUM, LEFT, CENTRE
from mojoui.scene import Painter
from mojoui.history import History, Snapshot
from mojoui.textedit import TextEdit, Styler, ParaLook, StyleSpan, Pos, adv, decode_at, utf8_len, SHIFT, CTRL, ALT
from mojoui.canvas import rgba
from mojoui.spring import Spring
from std.time import perf_counter_ns

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


comptime MOTION_STIFFNESS = 600.0  # ω ≈ 24.5/s …
comptime MOTION_DAMPING = 40.0  # … ζ ≈ 0.82: arrives in ~250 ms, overshoots ~1 % (≤ 8 % by test), at rest by 400 ms


struct MapStyle(Copyable, Movable):
    """Colours and sizes (a theme sets these; the defaults are Liquid light)."""

    var ink: UInt32
    var muted: UInt32
    var card: UInt32
    var root_fill: UInt32
    var root_ink: UInt32
    var focus: UInt32
    var badge_ink: UInt32
    var shadow: UInt32
    var palette: List[UInt32]
    var root_size: Float64
    var first_size: Float64
    var size: Float64
    var pad_x: Float64  # a main topic's card
    var pad_y: Float64
    var root_pad_x: Float64
    var root_pad_y: Float64
    var word_pad_x: Float64  # a topic written on its branch
    var word_pad_y: Float64
    var max_text_w: Float64
    var min_text_w: Float64
    var root_gap: Float64  # the main branches' reach
    var h_gap: Float64  # deeper branches' reach
    var v_gap: Float64  # between two subtrees' outlines
    var main_gap: Float64  # between two main branches' outlines
    var fan: Float64  # how much further the middle main branches reach than the top and bottom ones
    var trunk: Float64  # a main branch's width where it leaves the root
    var limb: Float64  # a branch's width where it reaches a main topic (deeper ones taper from it)

    def __init__(out self):
        self.ink = rgba(0x1F, 0x24, 0x2B)
        self.muted = rgba(0x8A, 0x92, 0x9C)
        self.card = rgba(0xFF, 0xFF, 0xFF)
        self.root_fill = rgba(0x1F, 0x24, 0x2B)
        self.root_ink = rgba(0xFF, 0xFF, 0xFF)
        self.focus = rgba(0x3C, 0xC4, 0xCF)
        self.badge_ink = rgba(0xFF, 0xFF, 0xFF)
        self.shadow = rgba(0x1F, 0x24, 0x2B, 0x22)
        self.palette = [
            rgba(0x3C, 0x8D, 0xEF), rgba(0xF2, 0x7A, 0x4B), rgba(0x2F, 0xB3, 0x7B), rgba(0xB0, 0x6C, 0xE8),
            rgba(0xE8, 0xB4, 0x2F), rgba(0xE5, 0x5A, 0x8C), rgba(0x2A, 0xB5, 0xC2), rgba(0x7A, 0x86, 0x99),
        ]
        self.root_size = 22
        self.first_size = 16
        self.size = 14
        self.pad_x = 14
        self.pad_y = 8
        self.root_pad_x = 24
        self.root_pad_y = 16
        self.word_pad_x = 6
        self.word_pad_y = 4
        self.max_text_w = 200
        self.min_text_w = 24
        self.root_gap = 72
        self.h_gap = 34
        self.v_gap = 6
        self.main_gap = 22
        self.fan = 160
        self.trunk = 18
        self.limb = 6.5


struct NodeBox(Copyable, Movable):
    """A topic's laid-out box (map coordinates: the root's centre is (0, 0)), its wrapped lines (cached by text), its
    subtree's outline (for packing) and its shown place (springs: where it is drawn while it glides)."""

    var x: Float64
    var y: Float64
    var w: Float64
    var h: Float64
    var band: Float64  # the subtree's height
    var visible: Bool
    var side: Int
    var color: UInt32
    var depth: Int
    var parent: Int  # (kept here too: a removed topic still knows where to shrink to)
    var text: String  # what `lines` were wrapped from
    var size: Float64
    var lines: List[String]
    var text_w: Float64
    var valid: Bool
    # the subtree's outline, one entry per level below it (0: itself), relative to its inner edge (u, outward) and
    # its middle (v): columns u0…u1 and rows top…bot
    var ou0: List[Float64]
    var ou1: List[Float64]
    var otop: List[Float64]
    var obot: List[Float64]
    var rel_v: Float64  # its middle below its parent's middle
    # motion: the shown middle and presence (0: not there, 1: fully there)
    var mx: Spring
    var my: Spring
    var mp: Spring
    var drawn: Bool  # it is on screen (visible, or leaving)
    var leaving: Bool  # removed or folded away: shrinking into its parent
    var moving: Bool
    # the branch into it, as last built (reused while its ends stay put)
    var rib: List[Float64]
    var rib_key: List[Float64]

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
        self.parent = -1
        self.text = ""
        self.size = 0
        self.lines = List[String]()
        self.text_w = 0
        self.valid = False
        self.ou0 = List[Float64]()
        self.ou1 = List[Float64]()
        self.otop = List[Float64]()
        self.obot = List[Float64]()
        self.rel_v = 0
        self.mx = Spring(0.0, MOTION_STIFFNESS, MOTION_DAMPING)
        self.my = Spring(0.0, MOTION_STIFFNESS, MOTION_DAMPING)
        self.mp = Spring(0.0, MOTION_STIFFNESS, MOTION_DAMPING)
        self.drawn = False
        self.leaving = False
        self.moving = False
        self.rib = List[Float64]()
        self.rib_key = List[Float64]()

    def cx(self) -> Float64:
        return self.x + self.w / 2

    def cy(self) -> Float64:
        return self.y + self.h / 2


@fieldwise_init
struct Shown(Copyable, Movable, ImplicitlyCopyable):
    """Where a topic is drawn this frame: its box (scaled by s about its middle) and its opacity a."""

    var x: Float64
    var y: Float64
    var w: Float64
    var h: Float64
    var s: Float64
    var a: Float64

    def cx(self) -> Float64:
        return self.x + self.w / 2

    def cy(self) -> Float64:
        return self.y + self.h / 2


def fade(c: UInt32, a: Float64) -> UInt32:
    """c with its alpha times a."""
    if a >= 0.999:
        return c
    var al = Float64(Int((c >> 24) & 0xFF)) * min(max(a, 0.0), 1.0)
    return (c & 0x00FFFFFF) | (UInt32(Int(al + 0.5)) << 24)


def mix(a: UInt32, b: UInt32, t: Float64) -> UInt32:
    """a → b by t, channel by channel."""
    var out: UInt32 = 0
    for k in range(4):
        var sh = UInt32(8 * k)
        var ca = Float64(Int((a >> sh) & 0xFF))
        var cb = Float64(Int((b >> sh) & 0xFF))
        out |= UInt32(Int(ca + (cb - ca) * t + 0.5) & 0xFF) << sh
    return out


def attach(x: Float64, y: Float64, w: Float64, h: Float64, tx: Float64, ty: Float64, inset: Float64) -> Tuple[Float64, Float64]:
    """Where a ray from the box's middle toward (tx, ty) leaves the box, moved `inset` back inside (Personal Note's
    attach): a branch leaves a box from the side facing its other end."""
    var cx = x + w / 2
    var cy = y + h / 2
    var dx = tx - cx
    var dy = ty - cy
    var length = (dx * dx + dy * dy) ** 0.5
    if length < 1e-9:
        return (cx, cy)
    var t = min((w / 2) / max(abs(dx), 1e-9), (h / 2) / max(abs(dy), 1e-9))
    var reach = (t * length - min(inset, 0.6 * t * length)) / length
    return (cx + dx * reach, cy + dy * reach)


def ribbon(sx: Float64, sy: Float64, ex: Float64, ey: Float64, d0x: Float64, d0y: Float64, w0: Float64, w1: Float64,
           lx: Float64, lw: Float64, mut pts: List[Float64]):
    """A branch's outline (x, y interleaved) into pts: one cubic from (sx, sy), leaving along (d0x, d0y), arriving at
    (ex, ey) level (one bend, both control points on the same side), its width falling from w0 to w1 and never wider
    than the bend allows; then, when lx != ex, straight on to (lx, ey) under a topic's words, w1 to lw."""
    comptime N = 20
    pts.clear()
    var dx = ex - sx
    var dy = ey - sy
    var chord = (dx * dx + dy * dy) ** 0.5
    var sg = 1.0 if dx >= 0 else -1.0
    var c1x = sx + d0x * 0.5 * chord
    var c1y = sy + d0y * 0.5 * chord
    var c2x = ex - sg * 0.45 * abs(dx)
    var c2y = ey
    var extra = 2 if lx != ex else 0
    var n = N + 1 + extra
    var right = List[Float64](capacity=2 * n)
    var prev = 1e300
    for i in range(N + 1):
        var t = Float64(i) / Float64(N)
        var u = 1 - t
        var x = u * u * u * sx + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * ex
        var y = u * u * u * sy + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * ey
        var tx = 3 * (u * u * (c1x - sx) + 2 * u * t * (c2x - c1x) + t * t * (ex - c2x))
        var ty = 3 * (u * u * (c1y - sy) + 2 * u * t * (c2y - c1y) + t * t * (ey - c2y))
        var ax = 6 * (u * (c2x - 2 * c1x + sx) + t * (ex - 2 * c2x + c1x))
        var ay = 6 * (u * (c2y - 2 * c1y + sy) + t * (ey - 2 * c2y + c1y))
        var speed = (tx * tx + ty * ty) ** 0.5
        if speed < 1e-9:
            tx = sg
            ty = 0
            speed = 1
        var curv = abs(tx * ay - ty * ax) / (speed * speed * speed)
        var room = max(w1, 1.8 / curv) if curv > 1e-9 else 1e300
        var w = min(min(w0 + (w1 - w0) * t, room), prev)
        prev = w
        var nx = -ty / speed * w / 2
        var ny = tx / speed * w / 2
        pts.append(x + nx)
        pts.append(y + ny)
        right.append(x - nx)
        right.append(y - ny)
    if extra > 0:
        var dir = 1.0 if lx > ex else -1.0
        for k in range(1, 3):
            var f = Float64(k) / 2.0
            var x = ex + (lx - ex) * f
            var hw = (w1 + (lw - w1) * f) / 2 * dir
            pts.append(x)
            pts.append(ey + hw)
            right.append(x)
            right.append(ey - hw)
    var i = n - 1
    while i >= 0:
        pts.append(right[2 * i])
        pts.append(right[2 * i + 1])
        i -= 1


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
    var laid_once: Bool  # topics met after the first layout grow in; the first layout's are simply there
    var manual: Bool  # time comes from step() (tests), not the clock
    var clock_ns: Int  # the clock at the last painted frame
    var animating: Bool  # something was still moving after the last frame

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
        self.laid_once = False
        self.manual = False
        self.clock_ns = 0
        self.animating = False

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

    def balance(mut self, now_ms: Int = 0):
        """Moves the main branches so both sides carry about as many topics (the biggest first, each to the lighter
        side), keeping their order: a map whose main branches were added before their topics reads round. One undo
        step (nothing when the sides don't change)."""
        var kids = self.model.nodes[0].children.copy()
        var order = List[Int]()
        for c in kids:
            var at = 0
            while at < len(order) and self.model.subtree_count(order[at]) >= self.model.subtree_count(c):
                at += 1
            order.insert(at, c)
        var r = 0
        var l = 0
        var sides = List[Int](length=len(self.model.nodes), fill=0)
        for c in order:
            var n = self.model.subtree_count(c)
            if r <= l:
                sides[c] = RIGHT_SIDE
                r += n
            else:
                sides[c] = LEFT_SIDE
                l += n
        var same = True
        for c in kids:
            if self.model.nodes[c].side != sides[c]:
                same = False
        if same:
            return
        self.commit(now_ms)
        var before = self.model.copy()
        for c in kids:
            self.model.nodes[c].side = sides[c]
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
        var d = self.model.depth(id)
        self.ed.pad_x = self._pad_x(d)
        self.ed.pad_y = self._pad_y(d)
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
        """The shown topic under (x, y) in screen points (through the last painted view), or -1. It tests laid-out
        places (where a gliding topic is going), so a tap during a ~250 ms glide lands on its destination."""
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

    def _pad_x(self, depth: Int) -> Float64:
        if depth == 0:
            return self.style.root_pad_x
        return self.style.pad_x if depth == 1 else self.style.word_pad_x

    def _pad_y(self, depth: Int) -> Float64:
        if depth == 0:
            return self.style.root_pad_y
        return self.style.pad_y if depth == 1 else self.style.word_pad_y

    def _gap(self, depth: Int) -> Float64:
        """How far beyond a topic at `depth` its children sit (their branches' reach)."""
        if depth == 0:
            return self.style.root_gap
        return self.style.h_gap + 10 if depth == 1 else self.style.h_gap

    def layout(mut self, font: Font):
        """Boxes for every shown topic (cached wrapping; only when something changed), then the springs aimed at them."""
        if not self.dirty:
            return
        self.dirty = False
        if len(self.boxes) == 0:
            self.laid_once = False  # (a fresh map, or the boxes thrown away: topics are simply there)
        while len(self.boxes) < len(self.model.nodes):
            self.boxes.append(NodeBox())
        # (boxes past the model's end are kept: a topic an undo took away still shrinks out)
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
        if not self.model.nodes[0].collapsed:
            for side in [RIGHT_SIDE, LEFT_SIDE]:
                self._lay_side(side)
        self._aim()

    def _lay_side(mut self, side: Int):
        """The root's main branches on one side: packed by outline, centred on the root, fanned (the middle ones reach
        further out than the top and bottom ones, so the map reads round, not as a column)."""
        var kids = List[Int]()
        var cols = List[UInt32]()
        var pal = len(self.style.palette)
        for i in range(len(self.model.nodes[0].children)):
            var c = self.model.nodes[0].children[i]
            if self.model.nodes[c].side == side:
                kids.append(c)
                var col = self.model.nodes[c].color
                cols.append(col if col != 0 else self.style.palette[i % pal])
        if len(kids) == 0:
            return
        var shifts = List[Float64](length=len(kids), fill=0.0)
        var au0 = List[Float64]()
        var au1 = List[Float64]()
        var at = List[Float64]()
        var ab = List[Float64]()
        var offs = self._pack(kids, shifts, self.style.main_gap, au0, au1, at, ab)
        var mid = (offs[0] + offs[len(offs) - 1]) / 2
        if len(kids) > 1:
            var reach = 1.0
            for k in range(len(kids)):
                reach = max(reach, abs(offs[k] - mid))
            var fan = min(self.style.fan, 0.3 * reach)
            for k in range(len(kids)):
                var f = (offs[k] - mid) / reach
                shifts[k] = fan * (1 - f * f)
            au0.clear()
            au1.clear()
            at.clear()
            ab.clear()
            offs = self._pack(kids, shifts, self.style.main_gap, au0, au1, at, ab)
            mid = (offs[0] + offs[len(offs) - 1]) / 2
        var edge = self.boxes[0].x + self.boxes[0].w if side == RIGHT_SIDE else self.boxes[0].x
        for k in range(len(kids)):
            var reach = self._gap(0) + shifts[k]
            var inner = edge + reach if side == RIGHT_SIDE else edge - reach
            self._place(kids[k], inner, offs[k] - mid, side, cols[k], 1)

    def _pack(mut self, kids: List[Int], shifts: List[Float64], gap: Float64, mut au0: List[Float64],
              mut au1: List[Float64], mut at: List[Float64], mut ab: List[Float64]) -> List[Float64]:
        """Stacks the subtrees of `kids` top to bottom (each moved shifts[k] outward) as close as their outlines allow:
        every level of the next subtree clears, by `gap`, every level stacked so far that shares columns with it.
        Returns each kid's middle (the first's at 0); the stacked outline is left in au0/au1/at/ab."""
        var offs = List[Float64](capacity=len(kids))
        for k in range(len(kids)):
            var c = kids[k]
            var e = shifts[k]
            var off = 0.0
            if k > 0:
                off = offs[k - 1]  # (never above the one before: the order stays)
                for j in range(len(self.boxes[c].ou0)):
                    var u0 = self.boxes[c].ou0[j] + e
                    var u1 = self.boxes[c].ou1[j] + e
                    var top = self.boxes[c].otop[j]
                    for i in range(len(au0)):
                        if au0[i] < u1 and u0 < au1[i]:
                            off = max(off, ab[i] + gap - top)
            offs.append(off)
            for j in range(len(self.boxes[c].ou0)):
                var u0 = self.boxes[c].ou0[j] + e
                var u1 = self.boxes[c].ou1[j] + e
                var top = self.boxes[c].otop[j] + off
                var bot = self.boxes[c].obot[j] + off
                if j < len(au0):
                    au0[j] = min(au0[j], u0)
                    au1[j] = max(au1[j], u1)
                    at[j] = min(at[j], top)
                    ab[j] = max(ab[j], bot)
                else:
                    au0.append(u0)
                    au1.append(u1)
                    at.append(top)
                    ab.append(bot)
        return offs^

    def _measure(mut self, id: Int, depth: Int, font: Font):
        """id's box size, then its children's, packed under it: its subtree's outline (children first)."""
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
        b.w = max(b.text_w, self.style.min_text_w) + 2 * self._pad_x(depth) + extra
        b.h = Float64(len(b.lines)) * line_height(st.size) + 2 * self._pad_y(depth)
        b.depth = depth
        b.parent = self.model.nodes[id].parent
        b.ou0.clear()
        b.ou1.clear()
        b.otop.clear()
        b.obot.clear()
        b.ou0.append(0)
        b.ou1.append(b.w)
        b.otop.append(-b.h / 2)
        b.obot.append(b.h / 2)
        b.band = b.h
        if self.model.nodes[id].collapsed or len(self.model.nodes[id].children) == 0:
            return
        var kids = self.model.nodes[id].children.copy()
        for c in kids:
            self._measure(c, depth + 1, font)
        if id == 0:
            return  # (the root's sides are laid out by _lay_side)
        var shifts = List[Float64](length=len(kids), fill=0.0)
        var au0 = List[Float64]()
        var au1 = List[Float64]()
        var at = List[Float64]()
        var ab = List[Float64]()
        var offs = self._pack(kids, shifts, self.style.v_gap, au0, au1, at, ab)
        var mid = (offs[0] + offs[len(offs) - 1]) / 2
        for k in range(len(kids)):
            self.boxes[kids[k]].rel_v = offs[k] - mid
        ref p = self.boxes[id]
        var reach = p.w + self._gap(depth)
        var lo = p.otop[0]
        var hi = p.obot[0]
        for i in range(len(au0)):
            p.ou0.append(au0[i] + reach)
            p.ou1.append(au1[i] + reach)
            p.otop.append(at[i] - mid)
            p.obot.append(ab[i] - mid)
            lo = min(lo, at[i] - mid)
            hi = max(hi, ab[i] - mid)
        p.band = hi - lo

    def _place(mut self, id: Int, inner: Float64, cy: Float64, side: Int, color: UInt32, depth: Int):
        """Puts id with its inner edge at `inner` and its middle at cy, then its children a branch's reach beyond."""
        ref b = self.boxes[id]
        b.visible = True
        b.side = side
        b.depth = depth
        b.color = self.model.nodes[id].color if self.model.nodes[id].color != 0 else color
        b.y = cy - b.h / 2
        b.x = inner if side == RIGHT_SIDE else inner - b.w
        var col = b.color
        var outer = b.x + b.w + self._gap(depth) if side == RIGHT_SIDE else b.x - self._gap(depth)
        if self.model.nodes[id].collapsed or len(self.model.nodes[id].children) == 0:
            return
        for c in self.model.nodes[id].children.copy():
            self._place(c, outer, cy + self.boxes[c].rel_v, side, col, depth + 1)

    # ------------------------------------------------ motion

    def _drawn_anchor(self, id: Int) -> Int:
        """The nearest ancestor of id already on screen (where a new topic grows from)."""
        var a = self.boxes[id].parent
        while a > 0 and not self.boxes[a].drawn:
            a = self.boxes[a].parent
        return max(a, 0)

    def _shown_anchor(self, id: Int) -> Int:
        """The nearest ancestor of id still laid out (where a leaving topic shrinks to)."""
        var a = self.boxes[id].parent
        while a > 0 and not self.boxes[a].visible:
            a = self.boxes[a].parent
        return max(a, 0)

    def _aim(mut self):
        """After a layout: each shown topic's springs aim at its box; new ones start at the parent they grow from;
        topics no longer shown aim at their nearest shown ancestor and fade."""
        var first = not self.laid_once
        self.laid_once = True
        for id in range(len(self.boxes)):
            if self.boxes[id].visible:
                var tx = self.boxes[id].cx()
                var ty = self.boxes[id].cy()
                if not self.boxes[id].drawn:
                    if first or id == 0:
                        self.boxes[id].mx.snap(tx)
                        self.boxes[id].my.snap(ty)
                        self.boxes[id].mp.snap(1)
                    else:
                        var a = self._drawn_anchor(id)
                        self.boxes[id].mx.snap(self.boxes[a].mx.value)
                        self.boxes[id].my.snap(self.boxes[a].my.value)
                        self.boxes[id].mp.snap(0)
                    self.boxes[id].drawn = True
                ref b = self.boxes[id]
                b.leaving = False
                b.mx.to(tx)
                b.my.to(ty)
                b.mp.to(1)
                b.moving = b.mx.value != tx or b.my.value != ty or b.mp.value != 1 or b.mx.velocity != 0 or b.my.velocity != 0
            elif self.boxes[id].drawn:
                var a = self._shown_anchor(id)
                var tx = self.boxes[a].cx()
                var ty = self.boxes[a].cy()
                ref b = self.boxes[id]
                b.leaving = True
                b.mx.to(tx)
                b.my.to(ty)
                b.mp.to(0)
                b.moving = True
        self.animating = self.moving()

    def moving(self) -> Bool:
        """Whether anything is still gliding, growing or fading."""
        for ref b in self.boxes:
            if b.moving:
                return True
        return False

    def step(mut self, dt_ms: Float64) -> Bool:
        """Moves every spring on by dt_ms of time and from now on takes time only from here (tests, recordings: the
        same steps give the same frames). True while something still moves."""
        self.manual = True
        return self._advance(dt_ms)

    def settle(mut self):
        """Everything at its end at once (less motion)."""
        for ref b in self.boxes:
            if b.drawn:
                b.mx.snap(b.mx.target)
                b.my.snap(b.my.target)
                b.mp.snap(b.mp.target)
                b.moving = False
                if b.leaving:
                    b.leaving = False
                    b.drawn = False
        self.animating = False

    def _advance(mut self, dt_ms: Float64) -> Bool:
        var us = Int(max(dt_ms, 0.0) * 1000)
        var any = False
        for ref b in self.boxes:
            if not b.moving:
                continue
            _ = b.mx.step(us)
            _ = b.my.step(us)
            _ = b.mp.step(us)
            # close enough is there (Spring's own rest test is finer than a pixel): no frames asked for nothing
            if abs(b.mx.value - b.mx.target) < 0.25 and abs(b.mx.velocity) < 6:
                b.mx.snap(b.mx.target)
            if abs(b.my.value - b.my.target) < 0.25 and abs(b.my.velocity) < 6:
                b.my.snap(b.my.target)
            if abs(b.mp.value - b.mp.target) < 0.004 and abs(b.mp.velocity) < 0.05:
                b.mp.snap(b.mp.target)
            b.moving = b.mx.velocity != 0 or b.my.velocity != 0 or b.mp.velocity != 0 or b.mx.value != b.mx.target or b.my.value != b.my.target or b.mp.value != b.mp.target
            if not b.moving and b.leaving:
                b.leaving = False
                b.drawn = False
            any = any or b.moving
        self.animating = any
        return any

    def shown_x(self, id: Int) -> Float64:
        """id's middle as drawn this frame (map coordinates)."""
        return self.boxes[id].mx.value

    def shown_y(self, id: Int) -> Float64:
        return self.boxes[id].my.value

    def presence(self, id: Int) -> Float64:
        """1 when id is fully there, 0 when gone (growing in or shrinking out in between)."""
        return self.boxes[id].mp.value if self.boxes[id].drawn else 0.0

    def _shown(self, id: Int) -> Shown:
        ref b = self.boxes[id]
        var a = min(max(b.mp.value, 0.0), 1.0)
        var s = 1.0 if a >= 0.999 else 0.45 + 0.55 * a
        var w = b.w * s
        var h = b.h * s
        return Shown(b.mx.value - w / 2, b.my.value - h / 2, w, h, s, a)

    # ------------------------------------------------ drawing

    def _branch[P: Painter](mut self, mut p: P, parent: Int, child: Int):
        """The branch into `child` from where it leaves `parent`, as one filled polygon: from the root's edge facing
        the child, a main topic's card edge facing it, or the end of a deeper topic's line; to a main topic's card
        edge, or a deeper topic's line, which it runs on under the words. Rebuilt only when its ends moved."""
        var a = self._shown(parent)
        var c = self._shown(child)
        var dp = self.boxes[parent].depth
        var dc = self.boxes[child].depth
        var side = self.boxes[child].side
        var right = side != LEFT_SIDE
        var ex: Float64
        var ey: Float64
        var lx: Float64
        if dc <= 1:
            ex = c.x + 1.5 * c.s if right else c.x + c.w - 1.5 * c.s  # (into the card's inner side)
            ey = c.cy()
            lx = ex
        else:
            ex = c.x if right else c.x + c.w
            ey = c.y + c.h - 1.5 * c.s
            lx = c.x + c.w if right else c.x
        var sx: Float64
        var sy: Float64
        var d0x: Float64
        var d0y: Float64
        var w0: Float64
        if dp == 0:
            # out of the root along a fan: the angle follows where the topic is shown, flattened, so main branches
            # spread round the root's edge instead of bundling at its top and bottom, and glide with their topics
            d0x = ex - a.cx()
            d0y = (ey - a.cy()) * 0.3
            if abs(d0y) > 1.5 * abs(d0x):
                d0y = 1.5 * abs(d0x) * (1.0 if d0y > 0 else -1.0)
            var s0 = attach(a.x, a.y, a.w, a.h, a.cx() + d0x * 100, a.cy() + d0y * 100, 14)
            sx = s0[0]
            sy = s0[1]
            w0 = self.style.trunk
        elif dp == 1:
            sx = a.x + a.w - 3 * a.s if right else a.x + 3 * a.s  # (from the card's outer side)
            sy = a.cy()
            d0x = 0.35 * (ex - sx)
            d0y = ey - sy
            w0 = self.style.limb * 0.85
        else:
            sx = a.x + a.w if right else a.x
            sy = a.y + a.h - 1.5 * a.s
            d0x = 0.35 * (ex - sx)
            d0y = ey - sy
            w0 = self._width_at(dp) * 0.8
        var dl = (d0x * d0x + d0y * d0y) ** 0.5
        if dl < 1e-9:
            d0x = 1.0 if right else -1.0
            d0y = 0
        else:
            d0x /= dl
            d0y /= dl
        var w1 = self._width_at(dc)
        var lw = w1 * 0.8
        w0 = max(w0 * c.s, w1)
        ref b = self.boxes[child]
        if len(b.rib_key) != 7 or b.rib_key[0] != sx or b.rib_key[1] != sy or b.rib_key[2] != ex or b.rib_key[3] != ey or b.rib_key[4] != lx or b.rib_key[5] != w0 or b.rib_key[6] != w1:
            ribbon(sx, sy, ex, ey, d0x, d0y, w0, w1, lx, lw, b.rib)
            b.rib_key = [sx, sy, ex, ey, lx, w0, w1]
        p.polygon(b.rib, fade(b.color, c.a))

    def _width_at(self, depth: Int) -> Float64:
        """A branch's width where it reaches a topic at `depth` (thick near the root, thin at the leaves)."""
        if depth <= 1:
            return self.style.limb
        return max(1.3, self.style.limb * (Float64(depth) ** -0.8))

    def paint[P: Painter](mut self, mut p: P, font: Font, view: MapView):
        """The map in its own layer, moved and scaled by `view`: branches, then topics, where they are shown this frame
        (notes for agents and tests: "branch <parent>-><child>" on each branch polygon, "node <id> <text>" on each
        shown topic, "leaving <id> <text>" on one fading out). Asks for the next frame while anything moves."""
        self.layout(font)
        self.view = view
        if p.still():
            self.settle()
        elif not self.manual:
            var now = Int(perf_counter_ns())
            var dt = 0.0
            if self.animating and self.clock_ns > 0:
                dt = min(Float64(now - self.clock_ns) / 1e6, 50.0)  # (a stalled frame is not skipped through)
            self.clock_ns = now
            _ = self._advance(dt)
        p.begin_layer("mindmap")
        p.layer_transform(view.dx, view.dy, view.k)
        for id in range(1, len(self.boxes)):
            if self.boxes[id].drawn:
                var par = self.boxes[id].parent
                if par < 0 or not self.boxes[par].drawn:
                    continue
                self._branch(p, par, id)
                if not self.boxes[id].leaving:
                    p.note("branch " + String(par) + "->" + String(id))
        for id in range(len(self.boxes)):
            if self.boxes[id].leaving:
                self._node(p, font, id)
        for id in range(len(self.boxes)):
            if self.boxes[id].drawn and not self.boxes[id].leaving:
                self._node(p, font, id)
        if self.animating:
            p.set_again()

    def _node[P: Painter](mut self, mut p: P, font: Font, id: Int):
        var f = self._shown(id)
        var depth = self.boxes[id].depth
        var color = self.boxes[id].color
        var leaving = self.boxes[id].leaving
        var alive = id < len(self.model.nodes) and not leaving
        var done = self.model.nodes[id].done if alive else DONE_NONE
        var collapsed = alive and self.model.nodes[id].collapsed and len(self.model.nodes[id].children) > 0
        var st = self._styler(id) if alive else NodeStyler(self.boxes[id].size, REGULAR if depth > 1 else MEDIUM, self.style.ink)
        var s = f.s
        var a = f.a
        var label = self.text_of(id) if alive else self.boxes[id].text
        var meaning = ("leaving " if leaving else "node ") + String(id) + " " + label
        var editing = id == self.editing
        var focused = alive and id == self.model.focus
        var ink = st.color
        if depth == 0:
            var r = min(f.h / 2, 18.0 * s)
            if focused:
                p.rect(f.x - 4, f.y - 4, f.w + 8, f.h + 8, fade(self.style.focus, a), r + 4)
            p.rect(f.x, f.y + 4 * s, f.w, f.h, fade(self.style.shadow, a), r)
            p.rect(f.x, f.y, f.w, f.h, fade(self.style.root_fill, a), r)
            p.note(meaning)
        elif depth == 1:
            var r = min(f.h / 2, 10.0 * s)
            if focused:
                p.rect(f.x - 4, f.y - 4, f.w + 8, f.h + 8, fade(self.style.focus, a), r + 4)
            p.rect(f.x, f.y + 2 * s, f.w, f.h, fade(self.style.shadow, a), r)
            p.rect(f.x, f.y, f.w, f.h, fade(color, a), r)
            var bw = 2.0 * s
            p.rect(f.x + bw, f.y + bw, f.w - 2 * bw, f.h - 2 * bw, fade(mix(self.style.card, color, 0.10), a), max(r - bw, 0.0))
            p.note(meaning)
        else:
            if focused:
                p.rect(f.x - 3, f.y - 2, f.w + 6, f.h + 1, fade(self.style.focus, a * 0.35), 6)
            if editing:
                p.rect(f.x, f.y, f.w, f.h - 2, self.style.card, 6)
            ink = mix(self.style.ink, color, 0.25)
        var px = self._pad_x(depth) * s
        var tx = f.x + px
        if done != DONE_NONE:
            var cx = tx + 6 * s
            var cy = f.cy()
            p.circle(cx, cy, 6 * s, fade(color, a))
            if done == DONE_OPEN:
                p.circle(cx, cy, 4.5 * s, self.style.card)
            else:
                p.line(cx - 3, cy, cx - 1, cy + 2.5, 1.6, self.style.card)
                p.line(cx - 1, cy + 2.5, cx + 3.2, cy - 2.5, 1.6, self.style.card)
            tx += 18 * s
        if editing:
            self.ed.resize(self.style.max_text_w + 2 * self._pad_x(depth), self.boxes[id].h)
            self.ed.paint(p, font, tx - px, f.y, st)
            if depth > 1:
                p.note(meaning)
        else:
            if done == DONE_YES:
                ink = self.style.muted
            var size = st.size * s
            var lh = line_height(st.size) * s
            var y = f.y + self._pad_y(depth) * s
            var n = len(self.boxes[id].lines)
            for k in range(n):
                var line = self.boxes[id].lines[k]
                if depth == 0:
                    p.text(font, line, f.cx(), y + (lh - size) / 2 + size * 0.8, size, fade(ink, a), st.weight, CENTRE, 0)
                else:
                    p.text(font, line, tx, y + (lh - size) / 2 + size * 0.8, size, fade(ink, a), st.weight, LEFT, 0)
                if k == 0 and depth > 1:
                    p.note(meaning)
                y += lh
        if collapsed:
            var n = self.hidden_count(id)
            var count = String(n)
            var bw = max(18.0, font.measure(count, 11, MEDIUM) + 10)
            var by = f.cy() if depth <= 1 else f.y + f.h - 1.5 * s
            var bx = f.x + f.w + 6 if self.boxes[id].side != LEFT_SIDE else f.x - 6 - bw
            if id == 0:
                bx = f.x + f.w + 6
            p.rect(bx, by - 9, bw, 18, fade(color, a), 9)
            p.text(font, count, bx + bw / 2, by + 4, 11, self.style.badge_ink, MEDIUM, CENTRE, 0)
            p.note("collapsed " + String(id) + " " + count)

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
