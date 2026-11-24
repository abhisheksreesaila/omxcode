# mojoui.objectlayer: free objects on an infinite canvas (goal 74 M4): text boxes, stickies, rectangles, ellipses,
# pictures, pressure ink and connectors, drawn natively through any Painter. Generic: no app in here. Personal Note's
# canvas is the first user; anything with a whiteboard can drop it in.
#
#   var ol = ObjectLayer()
#   var a = ol.add_rect(100, 100, 200, 120, 0x2610C8F0, 0xFF4A6FB0)
#   var t = ol.add_text(400, 100, 260, 60, "Ship the export", 18, INK)
#   _ = ol.add_connector(a, t)                   # attached to the nearest side midpoints, re-routed when either moves
#   var hit = ol.hit_test(px, py)                # page points: the caller converts from the screen (its pan/zoom)
#   ol.select(hit, shift)                        # shift toggles
#   ol.begin_gesture(); ol.move_by(dx, dy) ...; ol.end_gesture()   # a drag is ONE undo step
#   ol.paint(painter, font, vx, vy, vw, vh, k)   # only what meets the view, in z order, plus selection and handles
#   _ = ol.undo(); _ = ol.redo()
#
# Every change goes through one pattern: an operation `_touch`es an object (its state before is kept) before it changes
# it, and `_commit` makes one undo step of whatever was touched (each object before and after, or absent). A gesture
# holds the step open until it ends. So any operation, however many objects and connectors it reaches, is exactly one
# undo step, and undo puts back exact copies (a canonical `dump()` compares equal).
#
# Rotation turns a shape's outline, its hit area and its handles. The Painter has no rotate, so text and pictures inside
# a turned box are drawn upright (D-74xx).
#
# Culling and hit tests use a uniform grid over the objects' boxes, rebuilt lazily after a change (O(n), well under a
# millisecond for Personal Note's 645-object note).

from std.math import sqrt, cos, sin, floor, ceil

from mojoui.shared import serial, new_key
from mojoui.canvassource import CanvasSource
from mojoui.jsonpatch import Change as Patch, patched, patched_in, member_text
from mojoui.scene import Painter
from mojoui.ink import Stroke
from mojoui.history import History, Undoable
from mojoui.textedit import TextEdit, PlainStyler, Styler, Pos
from mojoui.text import Font, REGULAR, LEFT
from mojoui.json import Json, J_OBJECT, J_ARRAY, J_STRING, J_NUMBER, json_string

comptime TEXT = 1
comptime STICKY = 2
comptime RECT = 3
comptime ELLIPSE = 4
comptime PICTURE = 5
comptime INK = 6
comptime CONNECTOR = 7

comptime H_NW = 0  # resize handles, clockwise from the top-left; H_ROTATE turns
comptime H_N = 1
comptime H_NE = 2
comptime H_E = 3
comptime H_SE = 4
comptime H_S = 5
comptime H_SW = 6
comptime H_W = 7
comptime H_ROTATE = 8

comptime MIN_SIZE = 8.0  # the smallest a box resizes to (page points)
comptime CELL = 256.0  # the grid's cell (page points)
comptime TILE = 512.0  # culling snaps the view out to this, so a small pan keeps the objects layer (host cache)
comptime PI = 3.141592653589793
comptime TEXT_PAD = 8.0

comptime SEL_COLOR = 0xFFEB6325  # (0xAABBGGRR: the editor's blue)
comptime HANDLE_FILL = 0xFFFFFFFF

comptime CH_ADD = 1
comptime CH_MOVE = 2
comptime CH_NUDGE = 3
comptime CH_RESIZE = 4
comptime CH_ROTATE = 5
comptime CH_Z = 6
comptime CH_LOCK = 7
comptime CH_DELETE = 8
comptime CH_DUPLICATE = 9
comptime CH_TEXT = 10
comptime CH_GESTURE = 11
comptime CH_STYLE = 12


def kind_name(kind: Int) -> String:
    if kind == TEXT:
        return "text"
    if kind == STICKY:
        return "sticky"
    if kind == RECT:
        return "rect"
    if kind == ELLIPSE:
        return "ellipse"
    if kind == PICTURE:
        return "picture"
    if kind == INK:
        return "ink"
    if kind == CONNECTOR:
        return "connector"
    return "?"


def atan2_(y: Float64, x: Float64) -> Float64:
    """atan2 without libm's (the Mac stub doesn't list it): octant reduction and a minimax polynomial (≈1e-7 rad)."""
    var ax = abs(x)
    var ay = abs(y)
    if ax == 0 and ay == 0:
        return 0
    var a = min(ax, ay) / max(ax, ay)
    # atan(a) for a in [0, 1]: reduce to [0, tan(pi/12)] by atan(a) = pi/6 + atan((a·√3 - 1) / (a + √3))
    var off = 0.0
    if a > 0.2679491924311227:
        a = (a * 1.7320508075688772 - 1) / (a + 1.7320508075688772)
        off = PI / 6
    var s = a * a
    var r = off + a * (1 - s * (1.0 / 3 - s * (1.0 / 5 - s * (1.0 / 7 - s * (1.0 / 9 - s / 11)))))
    if ay > ax:
        r = PI / 2 - r
    if x < 0:
        r = PI - r
    if y < 0:
        r = -r
    return r


def parse_color(text: String, default: UInt32) -> UInt32:
    """'#rgb', '#rrggbb', 'rgb(r,g,b)' or 'rgba(r,g,b,a)' as 0xAABBGGRR; `default` for anything else (null, names)."""
    var b = text.as_bytes()
    var n = len(b)
    if n == 0:
        return default
    if b[0] == 35:  # '#'
        var digits = List[Int]()
        for i in range(1, n):
            var c = Int(b[i])
            if c >= 48 and c <= 57:
                digits.append(c - 48)
            elif c >= 97 and c <= 102:
                digits.append(c - 87)
            elif c >= 65 and c <= 70:
                digits.append(c - 55)
            else:
                return default
        var r: Int
        var g: Int
        var bl: Int
        if len(digits) == 3:
            r = digits[0] * 17
            g = digits[1] * 17
            bl = digits[2] * 17
        elif len(digits) == 6:
            r = digits[0] * 16 + digits[1]
            g = digits[2] * 16 + digits[3]
            bl = digits[4] * 16 + digits[5]
        else:
            return default
        return UInt32(0xFF000000) | UInt32(bl << 16) | UInt32(g << 8) | UInt32(r)
    if n > 4 and b[0] == 114:  # 'r': rgb( / rgba(
        var nums = List[Float64]()
        var cur = 0.0
        var frac = 0.0
        var seen = False
        for i in range(n):
            var c = Int(b[i])
            if c >= 48 and c <= 57:
                if frac > 0:
                    cur += Float64(c - 48) * frac
                    frac /= 10
                else:
                    cur = cur * 10 + Float64(c - 48)
                seen = True
            elif c == 46:
                frac = 0.1
                seen = True
            elif c == 44 or c == 41:
                if seen:
                    nums.append(cur)
                cur = 0
                frac = 0
                seen = False
        if len(nums) < 3:
            return default
        var a = 255
        if len(nums) >= 4:
            a = Int(min(max(nums[3], 0.0), 1.0) * 255 + 0.5)
        var r = Int(min(nums[0], 255.0))
        var g = Int(min(nums[1], 255.0))
        var bl = Int(min(nums[2], 255.0))
        return UInt32(a << 24) | UInt32(bl << 16) | UInt32(g << 8) | UInt32(r)
    return default


struct Obj(Copyable, Movable):
    """One object. x, y, w, h: its box before rotation (page points); rot turns it about the box's centre."""

    var id: Int
    var kind: Int
    var x: Float64
    var y: Float64
    var w: Float64
    var h: Float64
    var rot: Float64
    var z: Int
    var locked: Bool
    var color: UInt32  # fill (shapes, sticky), text colour (text), ink and connector colour
    var line: UInt32  # outline (shapes; 0: none)
    var line_width: Float64
    var radius: Float64
    var text: String  # TEXT, STICKY
    var size: Float64  # font size
    var rev: Int  # the text's revision (unique per layer: an editor built from it is still good while it matches)
    var pixels: List[UInt32]  # PICTURE
    var pw: Int
    var ph: Int
    var stroke: Stroke  # INK, in page points (moves with the box)
    var from_id: Int  # CONNECTOR: the ends (-1: a free end at fx, fy)
    var to_id: Int
    var fx: Float64
    var fy: Float64
    var ax: Float64  # CONNECTOR: the routed ends
    var ay: Float64
    var bx: Float64
    var by: Float64
    # type (TEXT, STICKY), as a document stores it (goal 79): a face, a line height (× size, 0: the painter's own),
    # padding inside the box, and a sticky's word colour; a painter that has no faces (goal 74's) ignores them
    var family: String
    var line_height: Float64
    var pad: Float64
    var ink: UInt32
    var head_end: Bool  # CONNECTOR: an arrowhead at its end (the default) or none
    var weight: Int  # TEXT, STICKY: the face's weight
    var markdown: Bool  # TEXT: its words are Markdown (laid out in CSS line boxes), else plain
    var key: String  # the document's own id for it (a JSON Canvas node's), "" for one made here
    var src_doc: Int  # the CanvasSource it was read from (its id; 0: made here) and its place there: node src_at, or edge src_at − nodes
    var src_at: Int

    def __init__(out self, id: Int, kind: Int, x: Float64, y: Float64, w: Float64, h: Float64, color: UInt32):
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.rot = 0
        self.z = 0
        self.locked = False
        self.color = color
        self.line = 0
        self.line_width = 2
        self.radius = 0
        self.text = ""
        self.size = 16
        self.rev = 0
        self.pixels = List[UInt32]()
        self.pw = 0
        self.ph = 0
        self.stroke = Stroke(2, color)
        self.from_id = -1
        self.to_id = -1
        self.fx = 0
        self.fy = 0
        self.ax = 0
        self.ay = 0
        self.bx = 0
        self.by = 0
        self.family = ""
        self.line_height = 0
        self.pad = 0
        self.ink = 0xFF222222
        self.head_end = True
        self.src_doc = 0
        self.src_at = -1
        self.weight = 400
        self.markdown = False
        self.key = ""

    def cx(self) -> Float64:
        return self.x + self.w / 2

    def cy(self) -> Float64:
        return self.y + self.h / 2

    def to_page(self, lx: Float64, ly: Float64) -> Tuple[Float64, Float64]:
        """A point in the box's own frame (relative to its centre, unturned) on the page."""
        var c = cos(self.rot)
        var s = sin(self.rot)
        return (self.cx() + lx * c - ly * s, self.cy() + lx * s + ly * c)

    def to_local(self, px: Float64, py: Float64) -> Tuple[Float64, Float64]:
        """A page point in the box's own frame (relative to its centre, unturned)."""
        var c = cos(self.rot)
        var s = sin(self.rot)
        var dx = px - self.cx()
        var dy = py - self.cy()
        return (dx * c + dy * s, -dx * s + dy * c)

    def bounds(self) -> Tuple[Float64, Float64, Float64, Float64]:
        """The axis-aligned box around what it draws (x0, y0, x1, y1)."""
        if self.kind == CONNECTOR:
            var pad = self.line_width + 8
            return (min(self.ax, self.bx) - pad, min(self.ay, self.by) - pad, max(self.ax, self.bx) + pad, max(self.ay, self.by) + pad)
        var pad = self.stroke.width / 2 + 1 if self.kind == INK else self.line_width / 2
        var hw = self.w / 2 + pad
        var hh = self.h / 2 + pad
        if self.rot == 0:
            return (self.cx() - hw, self.cy() - hh, self.cx() + hw, self.cy() + hh)
        var c = abs(cos(self.rot))
        var s = abs(sin(self.rot))
        var ex = hw * c + hh * s
        var ey = hw * s + hh * c
        return (self.cx() - ex, self.cy() - ey, self.cx() + ex, self.cy() + ey)

    def dump(self) -> String:
        """Every field that matters, as one canonical line (tests compare these)."""
        var s = String(self.id) + " " + kind_name(self.kind) + " " + String(self.x) + "," + String(self.y) + "," + String(self.w) + ","
        s += String(self.h) + " r" + String(self.rot) + " z" + String(self.z) + (" L" if self.locked else " -") + " c" + String(self.color)
        s += " l" + String(self.line) + "/" + String(self.line_width) + " rad" + String(self.radius)
        if self.kind == TEXT or self.kind == STICKY:
            s += " s" + String(self.size) + " [" + self.text + "]"
        elif self.kind == PICTURE:
            var sum = 0
            for p in self.pixels:
                sum = (sum * 31 + Int(p)) % 1000000007
            s += " px" + String(self.pw) + "x" + String(self.ph) + "#" + String(sum)
        elif self.kind == INK:
            s += " ink" + String(self.stroke.points()) + "w" + String(self.stroke.width)
            for i in range(self.stroke.points()):
                s += ";" + String(self.stroke.xs[i]) + "," + String(self.stroke.ys[i]) + "," + String(self.stroke.ps[i])
        elif self.kind == CONNECTOR:
            s += " " + String(self.from_id) + "->" + String(self.to_id) + " f" + String(self.fx) + "," + String(self.fy)
            s += " a" + String(self.ax) + "," + String(self.ay) + " b" + String(self.bx) + "," + String(self.by)
        return s^


struct Change(Undoable):
    """One undo step: the objects it touched, each before and after (absent: created or deleted)."""

    var kind: Int
    var ids: List[Int]
    var before: List[Optional[Obj]]
    var after: List[Optional[Obj]]

    def __init__(out self, kind: Int):
        self.kind = kind
        self.ids = List[Int]()
        self.before = List[Optional[Obj]]()
        self.after = List[Optional[Obj]]()

    def merge(mut self, later: Self) -> Bool:
        return False  # (gestures hold one step open instead of merging many)


struct ObjectLayer(Movable):
    var doc: Int  # which document this is (a process-wide serial, never shared): its versions and ids mean something only with it
    var read_only: Bool  # (review 3) a document that couldn't be read: editing tools refuse it
    var src: CanvasSource  # (review 3) the document's own text, when it was read from one: what wasn't edited is saved as it was
    var adopted: Dict[Int, Bool]  # ids of its document that became objects (or joined a delete made while it was opening)
    var touched: Dict[Int, Bool]  # objects that may differ from their source (edited, undone, re-routed: compared at a save)
    var objs: List[Obj]
    var pos_of: Dict[Int, Int]  # id → index in objs
    var next_id: Int
    var z_top: Int
    var z_bottom: Int
    var rev_counter: Int
    var selected: List[Int]  # ids, in the order they were picked
    var history: History[Change]
    var chg_ids: List[Int]  # (D-7978) every object change by id, with the version it is part of; the last version made
    var chg_vers: List[Int]  # by a change that named no object; objects named since the last version
    var unlogged_ver: Int
    var logged_n: Int
    var adopt_ids: List[Int]  # (D-7960) objects adopted (adopt_as), with the version after each, and the version
    var adopt_vers: List[Int]  # after the last change that wasn't an adoption: adoptions(since) answers from them
    var edit_ver: Int
    var adopting: Bool
    var version: Int  # every change to the objects (the objects layer's version)
    var sel_version: Int
    # the open step
    var txn: Change
    var txn_open: Bool
    var gesture: Bool
    var gesture_kind: Int
    # gesture memory (resize and rotate work from where the gesture began)
    var g_obj: Obj
    var g_handle: Int
    var g_dx: Float64
    var g_dy: Float64
    # text editing
    var editing: Int  # the id being edited, -1 none
    var ed_ids: Dict[Int, Int]  # id → editor slot
    var editors: List[TextEdit]
    var ed_rev: List[Int]
    var ed_w: List[Float64]
    var ed_h: List[Float64]
    # the grid
    var dirty: Bool
    var bx0: List[Float64]
    var by0: List[Float64]
    var bx1: List[Float64]
    var by1: List[Float64]
    var rank: List[Int]  # z order of objs[i] (0: bottom)
    var gx0: Float64
    var gy0: Float64
    var cell: Float64
    var gnx: Int
    var gny: Int
    var cell_start: List[Int]  # CSR: cell c's entries are cell_items[cell_start[c] : cell_start[c+1]]
    var cell_items: List[Int]
    var stamp: List[Int]
    var stamp_now: Int
    # (D-7940) a grid built for these objects (ids and z by index) stays when only boxes moved: the moved ones are
    # `loose` (scanned by every query, besides the grid, whose stale entries are filtered by the current boxes)
    var route_w: Dict[Int, Float64]  # (D-7943) an object's width for connector routing when it isn't its box's (a text
    # drawn from its document hugs its words: Personal Note's Leafer text after an undo)
    var built_id: List[Int]
    var built_z: List[Int]
    var loose: List[Int]
    var is_loose: List[Bool]
    # how connectors meet their ends: -1 at the nearest side midpoints (goal 74), ≥ 0 where the line between the two
    # centres leaves each box, pulled back by this gap (Fabric's and Personal Note's rule: connectorEndpoints)
    var connector_gap: Float64
    var select_on_undo: Bool  # an undo or redo selects what it changed (D-7935; off: goal 74's editors keep their selection rule)
    var saved_version: Int  # the version the document had when it was last loaded or saved (-1: never): unchanged since, no save is needed

    def __init__(out self):
        self.doc = serial()
        self.read_only = False
        self.src = CanvasSource()
        self.touched = Dict[Int, Bool]()
        self.adopted = Dict[Int, Bool]()
        self.objs = List[Obj]()
        self.pos_of = Dict[Int, Int]()
        self.next_id = 1
        self.z_top = 0
        self.z_bottom = 0
        self.rev_counter = 0
        self.selected = List[Int]()
        self.history = History[Change](cap=100000, window_ms=0)
        self.adopt_ids = List[Int]()
        self.chg_ids = List[Int]()
        self.chg_vers = List[Int]()
        self.unlogged_ver = 0
        self.logged_n = 0
        self.adopt_vers = List[Int]()
        self.edit_ver = 0
        self.adopting = False
        self.version = 0
        self.sel_version = 0
        self.txn = Change(0)
        self.txn_open = False
        self.gesture = False
        self.gesture_kind = 0
        self.g_obj = Obj(0, 0, 0, 0, 0, 0, 0)
        self.g_handle = -1
        self.g_dx = 0
        self.g_dy = 0
        self.editing = -1
        self.ed_ids = Dict[Int, Int]()
        self.editors = List[TextEdit]()
        self.ed_rev = List[Int]()
        self.ed_w = List[Float64]()
        self.ed_h = List[Float64]()
        self.dirty = True
        self.bx0 = List[Float64]()
        self.by0 = List[Float64]()
        self.bx1 = List[Float64]()
        self.by1 = List[Float64]()
        self.rank = List[Int]()
        self.gx0 = 0
        self.gy0 = 0
        self.cell = CELL
        self.gnx = 0
        self.gny = 0
        self.cell_start = List[Int]()
        self.cell_items = List[Int]()
        self.stamp = List[Int]()
        self.stamp_now = 0
        self.route_w = Dict[Int, Float64]()
        self.built_id = List[Int]()
        self.built_z = List[Int]()
        self.loose = List[Int]()
        self.is_loose = List[Bool]()
        self.connector_gap = -1
        self.saved_version = -1
        self.select_on_undo = False

    # ------------------------------------------------ looking up

    def count(self) -> Int:
        return len(self.objs)

    def count_kind(self, kind: Int) -> Int:
        var n = 0
        for ref o in self.objs:
            if o.kind == kind:
                n += 1
        return n

    def has(self, id: Int) -> Bool:
        return id in self.pos_of

    def index(self, id: Int) -> Int:
        """objs index of an id, -1 when it's gone."""
        var p = self.pos_of.get(id)
        return p.value() if p else -1

    def get(self, id: Int) -> Obj:
        """A copy of object `id` (it must exist)."""
        return self.objs[self.index(id)].copy()

    def is_selected(self, id: Int) -> Bool:
        for s in self.selected:
            if s == id:
                return True
        return False

    def dump(self) -> String:
        """All objects, one canonical line each, by id: two layers dump equal exactly when they hold the same objects."""
        var ids = List[Int]()
        for ref o in self.objs:
            ids.append(o.id)
        sort(ids)
        var s = String()
        for id in ids:
            s += self.objs[self.index(id)].dump() + "\n"
        return s^

    # ------------------------------------------------ the undo step

    def _log(mut self, id: Int):
        """(D-7978) Object `id` changes in the version about to be made: changes_since() names it."""
        self.touched[id] = True
        self.chg_ids.append(id)
        self.chg_vers.append(self.version + 1)
        self.logged_n += 1
        if len(self.chg_ids) > 100000:  # (the oldest half goes; a question from before them can't be answered)
            var half = len(self.chg_ids) // 2
            self.unlogged_ver = max(self.unlogged_ver, self.chg_vers[half - 1])
            var ids2 = List[Int](capacity=len(self.chg_ids) - half)
            var vers2 = List[Int](capacity=len(self.chg_ids) - half)
            for q in range(half, len(self.chg_ids)):
                ids2.append(self.chg_ids[q])
                vers2.append(self.chg_vers[q])
            self.chg_ids = ids2^
            self.chg_vers = vers2^

    def was_object(self, id: Int) -> Bool:
        """(review 3) Id `id` of the document it was read from was an object here (one that isn't now was deleted)."""
        return id in self.adopted

    def node_moved(self, p: Int) -> Bool:
        """Object objs[p] isn't where (or as big as) its document had it."""
        ref o = self.objs[p]
        if o.src_doc != self.src.id or o.src_at < 0 or not self.src.ok or o.src_at >= len(self.src.ns) or o.id != o.src_at + 1:
            return True  # (made here)
        if not (o.id in self.touched):
            return False
        try:
            var j = Json.parse(self.src.node(o.src_at))
            var was = Obj(0, RECT, 0, 0, 0, 0, 0)
            if canvas_node_obj(j, 0, was):
                return was.x != o.x or was.y != o.y or was.w != o.w or was.h != o.h
        except:
            pass
        return True

    def changes_since(self, since: Int) -> Optional[List[Int]]:
        """(D-7978) The ids changed since version `since` (made, changed, re-routed, removed or adopted) when every change
        since then named its objects, else None (something changed unnamed: compare everything). Ids may repeat."""
        if self.unlogged_ver > since or since > self.version:
            return None
        var out = List[Int]()
        var q = len(self.chg_vers) - 1
        while q >= 0 and self.chg_vers[q] > since:
            q -= 1
        for r in range(q + 1, len(self.chg_ids)):
            out.append(self.chg_ids[r])
        return out^

    def _touch(mut self, id: Int):
        """Before object `id` changes (or is created): keep its state before, once per step."""
        self._log(id)
        if not self.txn_open:
            self.txn = Change(self.gesture_kind if self.gesture else 0)
            self.txn_open = True
        for t in self.txn.ids:
            if t == id:
                return
        self.txn.ids.append(id)
        var p = self.index(id)
        if p >= 0:
            self.txn.before.append(Optional[Obj](self.objs[p].copy()))
        else:
            self.txn.before.append(Optional[Obj](None))

    def _commit(mut self, kind: Int):
        """Ends the step (unless a gesture holds it open): each touched object's state after; nothing changed, no step."""
        if self.gesture or not self.txn_open:
            return
        self.txn_open = False
        var ch = Change(kind)
        var any = False
        for k in range(len(self.txn.ids)):
            var id = self.txn.ids[k]
            var p = self.index(id)
            var after = Optional[Obj](self.objs[p].copy()) if p >= 0 else Optional[Obj](None)
            ref before = self.txn.before[k]
            var same = False
            var hb = Bool(before)
            var ha = Bool(after)
            if not hb and not ha:
                same = True
            elif hb and ha:
                same = before.value().dump() == after.value().dump()
            if same:
                continue
            any = True
            ch.ids.append(id)
            ch.before.append(before.copy())
            ch.after.append(after^)
        self.txn = Change(0)
        if any:
            self.history.push(ch^, 0)

    def begin_gesture(mut self, kind: Int = CH_GESTURE):
        """A drag starts: every change until end_gesture is one undo step."""
        self._commit(0)
        self.gesture = True
        self.gesture_kind = kind
        self.g_handle = -1
        self.g_dx = 0
        self.g_dy = 0

    def end_gesture(mut self):
        self.gesture = False
        self._commit(self.gesture_kind)
        self.g_handle = -1

    def _put(mut self, id: Int, state: Optional[Obj]):
        """Object `id` becomes `state` (absent: removed). For undo and redo."""
        self._log(id)
        var p = self.index(id)
        if state:
            if p >= 0:
                self.objs[p] = state.value().copy()
            else:
                self.pos_of[id] = len(self.objs)
                self.objs.append(state.value().copy())
        elif p >= 0:
            self._remove_at(p)

    def undo(mut self) -> Bool:
        if self.editing >= 0:
            self.end_text_edit()
        if self.gesture:
            self.end_gesture()
        var s = self.history.undo()
        if not s:
            return False
        ref ch = s.value()
        for k in range(len(ch.ids) - 1, -1, -1):
            self._put(ch.ids[k], ch.before[k])
        self._after_history(ch.ids)
        return True

    def redo(mut self) -> Bool:
        if self.editing >= 0:
            self.end_text_edit()
        var s = self.history.redo()
        if not s:
            return False
        ref ch = s.value()
        for k in range(len(ch.ids)):
            self._put(ch.ids[k], ch.after[k])
        self._after_history(ch.ids)
        return True

    def can_undo(self) -> Bool:
        return self.history.can_undo()

    def can_redo(self) -> Bool:
        return self.history.can_redo()

    def _after_history(mut self, ids: List[Int]):
        """After an undo or redo: connectors follow the objects they join again (one brought back by the step included,
        D-7935); with select_on_undo, what the step changed and still exists is selected (a whiteboard's rule: you
        see what came back)."""
        for c in range(len(self.objs)):
            if self.objs[c].kind == CONNECTOR:
                self._route(c)
        self._changed()
        self._prune_selection()
        if self.select_on_undo:
            self.selected.clear()
            for id in ids:
                var q = self.index(id)
                if q >= 0 and self.objs[q].kind != CONNECTOR:
                    self.selected.append(id)

    def _changed(mut self):
        self.version += 1
        self.dirty = True
        if not self.adopting:
            self.edit_ver = self.version
            if self.logged_n == 0:
                self.unlogged_ver = self.version  # (D-7978: a change that named no object: changes_since() can't answer)
        self.logged_n = 0

    def adoptions(self, since: Int) -> Optional[List[Int]]:
        """(D-7960) The ids adopted since version `since` when every change since then was an adoption (a progressive
        open filling in), else None (something else changed: compare everything). A drawing that kept a snapshot of
        the layer at `since` damages only these."""
        if self.edit_ver > since or since > self.version:
            return None
        var out = List[Int]()
        var q = len(self.adopt_vers) - 1
        while q >= 0 and self.adopt_vers[q] > since:
            q -= 1
        for r in range(q + 1, len(self.adopt_ids)):
            out.append(self.adopt_ids[r])
        return out^

    def _prune_selection(mut self):
        var keep = List[Int]()
        for s in self.selected:
            var p = self.index(s)
            if p >= 0 and not self.objs[p].locked:
                keep.append(s)
        if len(keep) != len(self.selected):
            self.selected = keep^
            self.sel_version += 1

    def _remove_at(mut self, p: Int):
        var last = len(self.objs) - 1
        var id = self.objs[p].id
        self._log(id)
        if p != last:
            self.objs.swap_elements(p, last)
            self.pos_of[self.objs[p].id] = p
        _ = self.objs.pop()
        try:
            _ = self.pos_of.pop(id)
        except:
            pass

    # ------------------------------------------------ making objects

    def _new(mut self, var o: Obj) -> Int:
        o.id = self.next_id
        self.next_id += 1
        self.z_top += 1
        o.z = self.z_top
        o.key = new_key("obj-")  # (its own name in any document, whatever ids it already holds: a layer id is given again after a reload)
        var id = o.id
        self._touch(id)
        self.pos_of[id] = len(self.objs)
        self.objs.append(o^)
        if self.objs[len(self.objs) - 1].kind == CONNECTOR:
            self._route(len(self.objs) - 1)
        self._changed()
        return id

    def _next_rev(mut self) -> Int:
        self.rev_counter += 1
        return self.rev_counter

    def add_text(mut self, x: Float64, y: Float64, w: Float64, h: Float64, text: String, size: Float64 = 16, color: UInt32 = 0xFF222222) -> Int:
        var o = Obj(0, TEXT, x, y, w, h, color)
        o.text = text
        o.size = size
        o.rev = self._next_rev()
        o.line_width = 0
        var id = self._new(o^)
        self._commit(CH_ADD)
        return id

    def add_sticky(mut self, x: Float64, y: Float64, side: Float64, text: String, color: UInt32 = 0xFF9DE8FF, size: Float64 = 16) -> Int:
        var o = Obj(0, STICKY, x, y, side, side, color)
        o.text = text
        o.size = size
        o.rev = self._next_rev()
        o.radius = 4
        o.line_width = 0
        var id = self._new(o^)
        self._commit(CH_ADD)
        return id

    def add_rect(mut self, x: Float64, y: Float64, w: Float64, h: Float64, fill: UInt32, line: UInt32 = 0, line_width: Float64 = 2, radius: Float64 = 0) -> Int:
        var o = Obj(0, RECT, x, y, w, h, fill)
        o.line = line
        o.line_width = line_width if line != 0 else 0
        o.radius = radius
        var id = self._new(o^)
        self._commit(CH_ADD)
        return id

    def add_ellipse(mut self, x: Float64, y: Float64, w: Float64, h: Float64, fill: UInt32, line: UInt32 = 0, line_width: Float64 = 2) -> Int:
        var o = Obj(0, ELLIPSE, x, y, w, h, fill)
        o.line = line
        o.line_width = line_width if line != 0 else 0
        var id = self._new(o^)
        self._commit(CH_ADD)
        return id

    def add_picture(mut self, x: Float64, y: Float64, w: Float64, h: Float64, pixels: List[UInt32], pw: Int, ph: Int) -> Int:
        var o = Obj(0, PICTURE, x, y, w, h, 0)
        o.pixels = pixels.copy()
        o.pw = pw
        o.ph = ph
        o.line_width = 0
        var id = self._new(o^)
        self._commit(CH_ADD)
        return id

    def add_ink(mut self, stroke: Stroke) -> Int:
        """A finished pen stroke (page points). Its box is its points' bounds; the outline is sealed once."""
        var o = Obj(0, INK, stroke.x0, stroke.y0, max(stroke.x1 - stroke.x0, 0.0), max(stroke.y1 - stroke.y0, 0.0), stroke.color)
        o.stroke = stroke.copy()
        o.stroke.seal()
        o.line_width = 0
        var id = self._new(o^)
        self._commit(CH_ADD)
        return id

    def add_connector(mut self, from_id: Int, to_id: Int, color: UInt32 = 0xFF332222, width: Float64 = 2) -> Int:
        """A connector from one object to another (-1 if an end isn't there)."""
        if not self.has(from_id) or not self.has(to_id) or from_id == to_id:
            return -1
        var o = Obj(0, CONNECTOR, 0, 0, 0, 0, color)
        o.from_id = from_id
        o.to_id = to_id
        o.line_width = width
        var id = self._new(o^)
        self._commit(CH_ADD)
        return id

    def add_connector_to_point(mut self, from_id: Int, fx: Float64, fy: Float64, color: UInt32 = 0xFF332222, width: Float64 = 2) -> Int:
        """A connector from an object to a free end point."""
        if not self.has(from_id):
            return -1
        var o = Obj(0, CONNECTOR, 0, 0, 0, 0, color)
        o.from_id = from_id
        o.fx = fx
        o.fy = fy
        o.line_width = width
        var id = self._new(o^)
        self._commit(CH_ADD)
        return id

    # ------------------------------------------------ connectors

    def _mid(self, p: Int, side: Int) -> Tuple[Float64, Float64]:
        """The midpoint of side 0 top, 1 right, 2 bottom, 3 left of objs[p], turned with it."""
        ref o = self.objs[p]
        if side == 0:
            return o.to_page(0, -o.h / 2)
        if side == 1:
            return o.to_page(o.w / 2, 0)
        if side == 2:
            return o.to_page(0, o.h / 2)
        return o.to_page(-o.w / 2, 0)

    def _route(mut self, c: Int):
        """Connector objs[c] routed again (_route_ends); the change log names it only when that moved it (D-7999: an undo
        routes every connector of the board, and named hundreds that stayed where they were)."""
        ref o0 = self.objs[c]
        var was = (o0.ax, o0.ay, o0.bx, o0.by)
        var box = (o0.x, o0.y, o0.w, o0.h)
        self._route_ends(c)
        ref o = self.objs[c]
        if (o.ax != was[0] or o.ay != was[1] or o.bx != was[2] or o.by != was[3] or o.x != box[0] or o.y != box[1] or o.w != box[2] or o.h != box[3]):
            self._log(o.id)

    def _route_ends(mut self, c: Int):
        """Connector objs[c]: its ends at the nearest pair of side midpoints (or the side nearest its free end)."""
        var fp = self.index(self.objs[c].from_id)
        var tp = self.index(self.objs[c].to_id)
        if fp < 0:
            return
        if self.connector_gap >= 0 and tp >= 0:
            self._route_centres(c, fp, tp)
            return
        var best = 1e300
        var ax = 0.0
        var ay = 0.0
        var bx = self.objs[c].fx
        var by = self.objs[c].fy
        for i in range(4):
            var a = self._mid(fp, i)
            if tp >= 0:
                for j in range(4):
                    var b = self._mid(tp, j)
                    var d = (a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1])
                    if d < best:
                        best = d
                        ax = a[0]
                        ay = a[1]
                        bx = b[0]
                        by = b[1]
            else:
                var d = (a[0] - bx) * (a[0] - bx) + (a[1] - by) * (a[1] - by)
                if d < best:
                    best = d
                    ax = a[0]
                    ay = a[1]
        ref o = self.objs[c]
        o.ax = ax
        o.ay = ay
        o.bx = bx
        o.by = by
        o.x = min(ax, bx)
        o.y = min(ay, by)
        o.w = abs(bx - ax)
        o.h = abs(by - ay)

    def _route_bounds(self, p: Int) -> Tuple[Float64, Float64, Float64, Float64]:
        """The box a connector routes to: the object's bounds, or (unturned) its routing width when one is set."""
        var w = self.route_w.get(self.objs[p].id, -1.0)
        if w < 0 or self.objs[p].rot != 0:
            return self.objs[p].bounds()
        ref o = self.objs[p]
        return (o.x, o.y, o.x + w, o.y + o.h)

    def route_widths(mut self, widths: Dict[Int, Float64]):
        """Routing widths for these objects (by id), then every connector routed again."""
        for e in widths.items():
            self.route_w[e.key] = e.value
        for c in range(len(self.objs)):
            if self.objs[c].kind == CONNECTOR:
                self._route(c)
        self._changed()

    def _route_centres(mut self, c: Int, fp: Int, tp: Int):
        """The centre-ray rule: each end where the line between the two boxes' centres leaves that box (its bounds as
        turned), pulled back along the line by connector_gap; too short (< 6) or overlapping: no line (ends equal)."""
        var a = self._route_bounds(fp)
        var b = self._route_bounds(tp)
        var acx = (a[0] + a[2]) / 2
        var acy = (a[1] + a[3]) / 2
        var bcx = (b[0] + b[2]) / 2
        var bcy = (b[1] + b[3]) / 2
        var dx = bcx - acx
        var dy = bcy - acy
        var dist = sqrt(dx * dx + dy * dy)
        ref o = self.objs[c]
        if dist < 1e-6:
            o.ax = acx
            o.ay = acy
            o.bx = acx
            o.by = acy
            return
        var ux = dx / dist
        var uy = dy / dist
        var sa = 1.0 / max(abs(dx) / max((a[2] - a[0]) / 2, 1e-6), abs(dy) / max((a[3] - a[1]) / 2, 1e-6), 1e-9)
        var sb = 1.0 / max(abs(dx) / max((b[2] - b[0]) / 2, 1e-6), abs(dy) / max((b[3] - b[1]) / 2, 1e-6), 1e-9)
        var g = self.connector_gap
        var sx = acx + dx * sa + ux * g
        var sy = acy + dy * sa + uy * g
        var ex = bcx - dx * sb - ux * g
        var ey = bcy - dy * sb - uy * g
        if (ex - sx) * ux + (ey - sy) * uy < 6:
            ex = sx
            ey = sy
        o.ax = sx
        o.ay = sy
        o.bx = ex
        o.by = ey
        o.x = min(sx, ex)
        o.y = min(sy, ey)
        o.w = abs(ex - sx)
        o.h = abs(ey - sy)

    def set_words(mut self, id: Int, text: String):
        """A text's or a sticky's words (in the open step: inside a gesture they join it)."""
        var p = self.index(id)
        if p < 0:
            return
        self._touch(id)
        self.objs[p].text = text
        self.objs[p].rev = self._next_rev()
        self._changed()
        self._commit(CH_TEXT)

    def set_height(mut self, id: Int, h: Float64):
        """A box's height, for the words it holds (in the open step)."""
        var p = self.index(id)
        if p < 0 or self.objs[p].h == h:
            return
        self._touch(id)
        self.objs[p].h = h
        self.objs[p].rev = self._next_rev()
        self._changed()
        self._commit(CH_TEXT)

    def restyle(mut self, id: Int, family: String, size: Float64, line_height: Float64, weight: Int, markdown: Bool, ink: UInt32):
        """A text's or a sticky's type, as a document gives it."""
        var p = self.index(id)
        if p < 0:
            return
        self._touch(id)
        ref o = self.objs[p]
        o.family = family
        o.size = size
        o.line_height = line_height
        o.weight = weight
        o.markdown = markdown
        o.ink = ink
        o.rev = self._next_rev()
        self._changed()
        self._commit(CH_STYLE)

    def set_connector_gap(mut self, gap: Float64):
        """Chooses how connectors meet their ends (see connector_gap) and routes every connector again (no undo step:
        a document's rule, set as it opens)."""
        self.connector_gap = gap
        for c in range(len(self.objs)):
            if self.objs[c].kind == CONNECTOR:
                self._route(c)
        self.version += 1
        self.dirty = True

    def _reroute(mut self, moved: List[Int]):
        """Every connector with an end among `moved` (touched first, so the step keeps its route before)."""
        if len(moved) == 0:
            return
        for c in range(len(self.objs)):
            if self.objs[c].kind != CONNECTOR:
                continue
            var hit = False
            for m in moved:
                if self.objs[c].from_id == m or self.objs[c].to_id == m or self.objs[c].id == m:
                    hit = True
                    break
            if hit:
                self._touch(self.objs[c].id)
                self._route(c)

    def connectors_of(self, id: Int) -> List[Int]:
        var out = List[Int]()
        for ref o in self.objs:
            if o.kind == CONNECTOR and (o.from_id == id or o.to_id == id):
                out.append(o.id)
        return out^

    # ------------------------------------------------ the grid

    def _rebuild(mut self):
        if not self.dirty:
            return
        self.dirty = False
        var n = len(self.objs)
        # (D-7940) the same objects in the same order and stacking, only boxes moved (a drag, an edit, an undo of a move):
        # the boxes refreshed, the moved objects loose, the grid kept
        if n > 0 and n == len(self.built_id) and len(self.bx0) == n:
            var same = True
            var moved = List[Int]()
            for i in range(n):
                ref o = self.objs[i]
                if o.id != self.built_id[i] or o.z != self.built_z[i]:
                    same = False
                    break
                var b = o.bounds()
                if b[0] != self.bx0[i] or b[1] != self.by0[i] or b[2] != self.bx1[i] or b[3] != self.by1[i]:
                    self.bx0[i] = b[0]
                    self.by0[i] = b[1]
                    self.bx1[i] = b[2]
                    self.by1[i] = b[3]
                    moved.append(i)
            if same and len(self.loose) + len(moved) <= 1024:
                for i in moved:
                    if not self.is_loose[i]:
                        self.is_loose[i] = True
                        self.loose.append(i)
                return
        self.loose = List[Int]()
        self.is_loose = List[Bool](length=n, fill=False)
        self.built_id = List[Int](capacity=n)
        self.built_z = List[Int](capacity=n)
        for ref o in self.objs:
            self.built_id.append(o.id)
            self.built_z.append(o.z)
        self.bx0 = List[Float64](capacity=n)
        self.by0 = List[Float64](capacity=n)
        self.bx1 = List[Float64](capacity=n)
        self.by1 = List[Float64](capacity=n)
        var x0 = 1e300
        var y0 = 1e300
        var x1 = -1e300
        var y1 = -1e300
        for ref o in self.objs:
            var b = o.bounds()
            self.bx0.append(b[0])
            self.by0.append(b[1])
            self.bx1.append(b[2])
            self.by1.append(b[3])
            x0 = min(x0, b[0])
            y0 = min(y0, b[1])
            x1 = max(x1, b[2])
            y1 = max(y1, b[3])
        # z ranks
        var keys = List[Int](capacity=n)
        var zmin = 0
        for ref o in self.objs:
            zmin = min(zmin, o.z)
        for i in range(n):
            keys.append((self.objs[i].z - zmin) * (n + 1) + i)
        sort(keys)
        self.rank = List[Int](length=n, fill=0)
        for r in range(n):
            self.rank[keys[r] % (n + 1)] = r
        self.stamp = List[Int](length=n, fill=0)
        self.stamp_now = 0
        if n == 0:
            self.gnx = 0
            self.gny = 0
            self.cell_start = List[Int]()
            self.cell_items = List[Int]()
            return
        self.cell = CELL
        while ((x1 - x0) / self.cell + 1) * ((y1 - y0) / self.cell + 1) > 65536:
            self.cell *= 2
        self.gx0 = floor(x0 / self.cell) * self.cell
        self.gy0 = floor(y0 / self.cell) * self.cell
        self.gnx = Int((x1 - self.gx0) / self.cell) + 1
        self.gny = Int((y1 - self.gy0) / self.cell) + 1
        var cells = self.gnx * self.gny
        var counts = List[Int](length=cells + 1, fill=0)
        for i in range(n):
            var r = self._cells(self.bx0[i], self.by0[i], self.bx1[i], self.by1[i])
            for cy in range(r[1], r[3] + 1):
                for cx in range(r[0], r[2] + 1):
                    counts[cy * self.gnx + cx + 1] += 1
        for c in range(cells):
            counts[c + 1] += counts[c]
        self.cell_items = List[Int](length=counts[cells], fill=0)
        var fillp = counts.copy()
        for i in range(n):
            var r = self._cells(self.bx0[i], self.by0[i], self.bx1[i], self.by1[i])
            for cy in range(r[1], r[3] + 1):
                for cx in range(r[0], r[2] + 1):
                    var c = cy * self.gnx + cx
                    self.cell_items[fillp[c]] = i
                    fillp[c] += 1
        self.cell_start = counts^

    def rank_of(mut self, p: Int) -> Int:
        """objs[p]'s place in the stacking order (0: bottom)."""
        self._rebuild()
        return self.rank[p]

    def _cells(self, x0: Float64, y0: Float64, x1: Float64, y1: Float64) -> Tuple[Int, Int, Int, Int]:
        """The grid cells a box covers (clamped to the grid): cx0, cy0, cx1, cy1 (empty when cx0 > cx1)."""
        var a = Int(floor((x0 - self.gx0) / self.cell))
        var b = Int(floor((y0 - self.gy0) / self.cell))
        var c = Int(floor((x1 - self.gx0) / self.cell))
        var d = Int(floor((y1 - self.gy0) / self.cell))
        return (max(a, 0), max(b, 0), min(c, self.gnx - 1), min(d, self.gny - 1))

    def query(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64) -> List[Int]:
        """objs indices whose boxes meet the rect, bottom to top."""
        self._rebuild()
        var out = List[Int]()
        if self.gnx == 0:
            return out^
        self.stamp_now += 1
        var r = self._cells(x0, y0, x1, y1)
        var ranks = List[Int]()
        for cy in range(r[1], r[3] + 1):
            for cx in range(r[0], r[2] + 1):
                var c = cy * self.gnx + cx
                for k in range(self.cell_start[c], self.cell_start[c + 1]):
                    var i = self.cell_items[k]
                    if self.stamp[i] == self.stamp_now:
                        continue
                    self.stamp[i] = self.stamp_now
                    if self.bx1[i] < x0 or self.bx0[i] > x1 or self.by1[i] < y0 or self.by0[i] > y1:
                        continue
                    ranks.append(self.rank[i] * (len(self.objs) + 1) + i)
        for i in self.loose:  # (D-7940: moved since the grid was built)
            if self.stamp[i] == self.stamp_now:
                continue
            self.stamp[i] = self.stamp_now
            if self.bx1[i] < x0 or self.bx0[i] > x1 or self.by1[i] < y0 or self.by0[i] > y1:
                continue
            ranks.append(self.rank[i] * (len(self.objs) + 1) + i)
        sort(ranks)
        for k in ranks:
            out.append(k % (len(self.objs) + 1))
        return out^

    # ------------------------------------------------ hit tests

    def _hits(self, p: Int, px: Float64, py: Float64, slop: Float64) -> Bool:
        ref o = self.objs[p]
        if o.kind == CONNECTOR:
            var dx = o.bx - o.ax
            var dy = o.by - o.ay
            var l2 = dx * dx + dy * dy
            var t = 0.0 if l2 == 0 else min(max(((px - o.ax) * dx + (py - o.ay) * dy) / l2, 0.0), 1.0)
            var ex = px - (o.ax + t * dx)
            var ey = py - (o.ay + t * dy)
            var reach = max(o.line_width / 2 + slop, 5.0)
            return ex * ex + ey * ey <= reach * reach
        var l = o.to_local(px, py)
        var hw = o.w / 2
        var hh = o.h / 2
        if o.kind == INK:
            return o.stroke.hits(o.cx() + l[0], o.cy() + l[1], slop)  # (the unturned page point: ink keeps its points unturned)
        if o.kind == ELLIPSE:
            var ex = l[0] / max(hw + slop, 1e-9)
            var ey = l[1] / max(hh + slop, 1e-9)
            return ex * ex + ey * ey <= 1
        return abs(l[0]) <= hw + slop and abs(l[1]) <= hh + slop

    def hit_test(mut self, px: Float64, py: Float64, slop: Float64 = 0) -> Int:
        """The id of the topmost unlocked object under the page point, or -1."""
        var cand = self.query(px - slop, py - slop, px + slop, py + slop)
        for k in range(len(cand) - 1, -1, -1):
            var p = cand[k]
            if self.objs[p].locked:
                continue
            if self._hits(p, px, py, slop):
                return self.objs[p].id
        return -1

    def hit_locked(mut self, px: Float64, py: Float64) -> Int:
        """The topmost locked object under the point (to unlock it), or -1."""
        var cand = self.query(px, py, px, py)
        for k in range(len(cand) - 1, -1, -1):
            var p = cand[k]
            if self.objs[p].locked and self._hits(p, px, py, 0):
                return self.objs[p].id
        return -1

    # ------------------------------------------------ selection (not undo steps)

    def select(mut self, id: Int, shift: Bool = False):
        """Pick `id`: alone, or (shift) toggled in the selection. -1 without shift clears."""
        var p = self.index(id)
        if p < 0 or self.objs[p].locked:
            if not shift:
                self.clear_selection()
            return
        if shift:
            for k in range(len(self.selected)):
                if self.selected[k] == id:
                    _ = self.selected.pop(k)
                    self.sel_version += 1
                    return
            self.selected.append(id)
        else:
            self.selected = [id]
        self.sel_version += 1

    def click(mut self, px: Float64, py: Float64, shift: Bool = False) -> Int:
        """A tap at a page point: hit test, then select (shift toggles). Returns the id hit (-1: none)."""
        var id = self.hit_test(px, py, 2)
        if id >= 0 and not shift and self.is_selected(id):
            return id  # (a press on the selection keeps it, to drag it)
        self.select(id, shift)
        return id

    def marquee(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64, shift: Bool = False):
        """Select the unlocked objects wholly inside the rect (shift: add to the selection)."""
        var ax = min(x0, x1)
        var ay = min(y0, y1)
        var bx = max(x0, x1)
        var by = max(y0, y1)
        if not shift:
            self.selected = List[Int]()
        for p in self.query(ax, ay, bx, by):
            ref o = self.objs[p]
            if o.locked:
                continue
            var b = o.bounds()
            if o.kind == CONNECTOR:
                b = (min(o.ax, o.bx), min(o.ay, o.by), max(o.ax, o.bx), max(o.ay, o.by))
            elif o.kind != INK:
                var hw = o.w / 2
                var hh = o.h / 2
                var c = abs(cos(o.rot))
                var s = abs(sin(o.rot))
                var ex = hw * c + hh * s
                var ey = hw * s + hh * c
                b = (o.cx() - ex, o.cy() - ey, o.cx() + ex, o.cy() + ey)
            if b[0] >= ax and b[1] >= ay and b[2] <= bx and b[3] <= by and not self.is_selected(o.id):
                self.selected.append(o.id)
        self.sel_version += 1

    def select_all(mut self):
        self.selected = List[Int]()
        for ref o in self.objs:
            if not o.locked:
                self.selected.append(o.id)
        self.sel_version += 1

    def clear_selection(mut self):
        if len(self.selected) > 0:
            self.selected = List[Int]()
            self.sel_version += 1

    # ------------------------------------------------ moving, resizing, turning

    def _set_frame(mut self, p: Int, nx: Float64, ny: Float64, w_in: Float64, h_in: Float64):
        """objs[p]'s box becomes (nx, ny, nw, nh); ink points follow (moved, or scaled within the box)."""
        var nw = w_in
        var nh = h_in
        ref o = self.objs[p]
        if o.kind == INK:
            var sx = nw / o.w if o.w > 0 else 1.0
            var sy = nh / o.h if o.h > 0 else 1.0
            if sx == 1 and sy == 1:
                var dx = nx - o.x
                var dy = ny - o.y
                for i in range(len(o.stroke.xs)):
                    o.stroke.xs[i] += dx
                    o.stroke.ys[i] += dy
                for i in range(0, len(o.stroke.shape), 2):
                    o.stroke.shape[i] += dx
                    o.stroke.shape[i + 1] += dy
                o.stroke.x0 += dx
                o.stroke.x1 += dx
                o.stroke.y0 += dy
                o.stroke.y1 += dy
            else:
                var x0 = 1e300
                var y0 = 1e300
                var x1 = -1e300
                var y1 = -1e300
                for i in range(len(o.stroke.xs)):
                    o.stroke.xs[i] = nx + (o.stroke.xs[i] - o.x) * sx
                    o.stroke.ys[i] = ny + (o.stroke.ys[i] - o.y) * sy
                    x0 = min(x0, o.stroke.xs[i])
                    y0 = min(y0, o.stroke.ys[i])
                    x1 = max(x1, o.stroke.xs[i])
                    y1 = max(y1, o.stroke.ys[i])
                o.stroke.x0 = x0
                o.stroke.y0 = y0
                o.stroke.x1 = x1
                o.stroke.y1 = y1
                o.stroke.sealed = False
                o.stroke.seal()
                if o.w == 0:
                    nw = 0
                if o.h == 0:
                    nh = 0
        o.x = nx
        o.y = ny
        o.w = nw
        o.h = nh

    def _move_ids(mut self, ids: List[Int], dx: Float64, dy: Float64):
        var moved = List[Int]()
        for id in ids:
            var p = self.index(id)
            if p < 0 or self.objs[p].locked:
                continue
            self._touch(id)
            if self.objs[p].kind == CONNECTOR:
                if self.objs[p].to_id < 0:  # (a free end moves with it; attached ends follow their objects)
                    self.objs[p].fx += dx
                    self.objs[p].fy += dy
            else:
                self._set_frame(p, self.objs[p].x + dx, self.objs[p].y + dy, self.objs[p].w, self.objs[p].h)
            moved.append(id)
        self._reroute(moved)
        self._changed()

    def move_by(mut self, dx: Float64, dy: Float64):
        """The selection moves by (dx, dy) page points: one undo step (inside a gesture: part of the gesture's step)."""
        self._move_ids(self.selected.copy(), dx, dy)
        self.g_dx += dx
        self.g_dy += dy
        self._commit(CH_MOVE)

    def nudge(mut self, dir_x: Int, dir_y: Int, shift: Bool = False):
        """An arrow key: 1 point (shift: 10) in the direction (-1, 0, 1 each)."""
        var step = 10.0 if shift else 1.0
        self._move_ids(self.selected.copy(), Float64(dir_x) * step, Float64(dir_y) * step)
        self._commit(CH_NUDGE)

    def move_object(mut self, id: Int, x: Float64, y: Float64):
        """Object `id`'s box to (x, y): one undo step."""
        var p = self.index(id)
        if p < 0:
            return
        self._move_ids([id], x - self.objs[p].x, y - self.objs[p].y)
        self._commit(CH_MOVE)

    def _single(self) -> Int:
        """objs index of the one selected box (not a connector), or -1."""
        if len(self.selected) != 1:
            return -1
        var p = self.index(self.selected[0])
        if p < 0 or self.objs[p].kind == CONNECTOR:
            return -1
        return p

    def handle_point(self, p: Int, h: Int, k: Float64 = 1) -> Tuple[Float64, Float64]:
        """Where handle h of objs[p] sits on the page (k: the zoom, so the rotate handle keeps its screen distance)."""
        ref o = self.objs[p]
        if h == H_ROTATE:
            return o.to_page(0, -o.h / 2 - 24 / k)
        var sx = [-1, 0, 1, 1, 1, 0, -1, -1][h]
        var sy = [-1, -1, -1, 0, 1, 1, 1, 0][h]
        return o.to_page(Float64(sx) * o.w / 2, Float64(sy) * o.h / 2)

    def handle_at(self, px: Float64, py: Float64, k: Float64 = 1) -> Int:
        """Which handle of the single selected box is under the page point (H_NW … H_W, H_ROTATE), or -1."""
        var p = self._single()
        if p < 0:
            return -1
        var reach = 6.0 / k
        for h in range(9):
            var q = self.handle_point(p, h, k)
            if abs(px - q[0]) <= reach and abs(py - q[1]) <= reach:
                return h
        return -1

    def resize_handle(mut self, h: Int, px: Float64, py: Float64):
        """Drag handle h of the single selected box to a page point: the opposite corner (or side) stays where it is;
        never smaller than MIN_SIZE. In a gesture each call works from the box as the gesture began."""
        var p = self._single()
        if p < 0 or h < 0 or h > 7:
            return
        if self.gesture and self.g_handle == -1:
            self.g_obj = self.objs[p].copy()
            self.g_handle = h
        var o = self.g_obj.copy() if self.gesture else self.objs[p].copy()
        var sx = Float64([-1, 0, 1, 1, 1, 0, -1, -1][h])
        var sy = Float64([-1, -1, -1, 0, 1, 1, 1, 0][h])
        var anchor = o.to_page(-sx * o.w / 2, -sy * o.h / 2)
        var c = cos(o.rot)
        var s = sin(o.rot)
        var dx = px - anchor[0]
        var dy = py - anchor[1]
        var lx = dx * c + dy * s
        var ly = -dx * s + dy * c
        var nw = max(sx * lx, MIN_SIZE) if sx != 0 else o.w
        var nh = max(sy * ly, MIN_SIZE) if sy != 0 else o.h
        var ox = sx * nw / 2
        var oy = sy * nh / 2
        var ncx = anchor[0] + ox * c - oy * s
        var ncy = anchor[1] + ox * s + oy * c
        self._touch(self.objs[p].id)
        if self.gesture:  # (back to where the gesture began, then to the new box: ink scales from its first shape)
            self.objs[p] = self.g_obj.copy()
        self._set_frame(p, ncx - nw / 2, ncy - nh / 2, nw, nh)
        self._reroute([self.objs[p].id])
        self._changed()
        self._commit(CH_RESIZE)

    def rotate_towards(mut self, px: Float64, py: Float64):
        """The rotate handle dragged to a page point: the single selected box turns so its top faces it."""
        var p = self._single()
        if p < 0:
            return
        ref o = self.objs[p]
        self.set_rotation(o.id, atan2_(py - o.cy(), px - o.cx()) + PI / 2)

    def set_rotation(mut self, id: Int, radians: Float64):
        var p = self.index(id)
        if p < 0 or self.objs[p].kind == CONNECTOR:
            return
        self._touch(id)
        self.objs[p].rot = radians
        self._reroute([id])
        self._changed()
        self._commit(CH_ROTATE)

    # ------------------------------------------------ z order, lock, delete, duplicate

    def _order(self) -> List[Int]:
        """objs indices bottom to top."""
        var n = len(self.objs)
        var zmin = 0
        for ref o in self.objs:
            zmin = min(zmin, o.z)
        var keys = List[Int](capacity=n)
        for i in range(n):
            keys.append((self.objs[i].z - zmin) * (n + 1) + i)
        sort(keys)
        var out = List[Int](capacity=n)
        for k in keys:
            out.append(k % (n + 1))
        return out^

    def bring_to_front(mut self):
        for p in self._order():
            if self.is_selected(self.objs[p].id):
                self._touch(self.objs[p].id)
                self.z_top += 1
                self.objs[p].z = self.z_top
        self._changed()
        self._commit(CH_Z)

    def send_to_back(mut self):
        var order = self._order()
        for k in range(len(order) - 1, -1, -1):
            var p = order[k]
            if self.is_selected(self.objs[p].id):
                self._touch(self.objs[p].id)
                self.z_bottom -= 1
                self.objs[p].z = self.z_bottom
        self._changed()
        self._commit(CH_Z)

    def _swap_z(mut self, a: Int, b: Int):
        self._touch(self.objs[a].id)
        self._touch(self.objs[b].id)
        var z = self.objs[a].z
        self.objs[a].z = self.objs[b].z
        self.objs[b].z = z

    def bring_forward(mut self):
        """Each selected object one place up (past the next unselected object above it)."""
        var order = self._order()
        for k in range(len(order) - 2, -1, -1):
            if self.is_selected(self.objs[order[k]].id) and not self.is_selected(self.objs[order[k + 1]].id):
                self._swap_z(order[k], order[k + 1])
                order.swap_elements(k, k + 1)
        self._changed()
        self._commit(CH_Z)

    def send_backward(mut self):
        var order = self._order()
        for k in range(1, len(order)):
            if self.is_selected(self.objs[order[k]].id) and not self.is_selected(self.objs[order[k - 1]].id):
                self._swap_z(order[k], order[k - 1])
                order.swap_elements(k, k - 1)
        self._changed()
        self._commit(CH_Z)

    def z_rank(mut self, id: Int) -> Int:
        """Object `id`'s place in the z order (0: bottom)."""
        self._rebuild()
        return self.rank[self.index(id)]

    def set_locked(mut self, id: Int, locked: Bool):
        var p = self.index(id)
        if p < 0:
            return
        self._touch(id)
        self.objs[p].locked = locked
        self._changed()
        self._commit(CH_LOCK)
        self._prune_selection()

    def lock_selection(mut self):
        """The selection is locked (visible, but no click or marquee picks it) and let go."""
        for id in self.selected.copy():
            var p = self.index(id)
            if p >= 0:
                self._touch(id)
                self.objs[p].locked = True
        self._changed()
        self._commit(CH_LOCK)
        self._prune_selection()

    def unlock_all(mut self):
        for i in range(len(self.objs)):
            if self.objs[i].locked:
                self._touch(self.objs[i].id)
                self.objs[i].locked = False
        self._changed()
        self._commit(CH_LOCK)

    def _delete_ids(mut self, ids: List[Int]):
        var gone = List[Int]()
        for id in ids:
            if self.has(id):
                gone.append(id)
        for ref c in self.objs:  # (connectors that lose an end go too)
            if c.kind == CONNECTOR:
                for g in gone:
                    if c.from_id == g or c.to_id == g:
                        gone.append(c.id)
                        break
        for id in gone:
            var p = self.index(id)
            if p >= 0:
                self._touch(id)
                self._remove_at(p)
        self._changed()

    def delete_selection(mut self):
        if self.editing >= 0:
            self.end_text_edit()
        self._delete_ids(self.selected.copy())
        self._commit(CH_DELETE)
        self.selected = List[Int]()
        self.sel_version += 1

    def delete(mut self, id: Int):
        self._delete_ids([id])
        self._commit(CH_DELETE)
        self._prune_selection()

    def duplicate_selection(mut self, offset: Float64 = 16):
        """Copies of the selection, offset; connectors between two copied objects are copied too. The copies become the
        selection."""
        var mapping = Dict[Int, Int]()
        var copies = List[Int]()
        for id in self.selected.copy():
            var p = self.index(id)
            if p < 0 or self.objs[p].kind == CONNECTOR:
                continue
            var o = self.objs[p].copy()
            if o.kind == INK:
                o.stroke.sealed = False  # (re-sealed after the move below)
            if o.kind == TEXT or o.kind == STICKY:
                o.rev = self._next_rev()
            var nid = self._new(o^)
            var q = self.index(nid)
            var ref_o = self.objs[q].copy()
            self._set_frame(q, ref_o.x + offset, ref_o.y + offset, ref_o.w, ref_o.h)
            if self.objs[q].kind == INK:
                self.objs[q].stroke.seal()
            mapping[id] = nid
            copies.append(nid)
        var conns = List[Int]()
        for ref c in self.objs:
            if c.kind == CONNECTOR:
                conns.append(c.id)
        for cid in conns:
            var c = self.objs[self.index(cid)].copy()
            var f = mapping.get(c.from_id)
            var t = mapping.get(c.to_id)
            if Bool(f) and (Bool(t) or c.to_id < 0):
                c.from_id = f.value()
                if t:
                    c.to_id = t.value()
                else:
                    c.fx += offset
                    c.fy += offset
                copies.append(self._new(c^))
        self._commit(CH_DUPLICATE)
        self.selected = copies^
        self.sel_version += 1

    def set_color(mut self, id: Int, color: UInt32):
        var p = self.index(id)
        if p < 0:
            return
        self._touch(id)
        self.objs[p].color = color
        if self.objs[p].kind == INK:
            self.objs[p].stroke.color = color
        self._changed()
        self._commit(CH_STYLE)

    # ------------------------------------------------ text

    def _editor(mut self, p: Int) -> Int:
        """The editor slot for objs[p] (TEXT or STICKY), rebuilt when the text or the box changed."""
        ref o = self.objs[p]
        var slot = self.ed_ids.get(o.id)
        var s: Int
        if slot:
            s = slot.value()
        else:
            s = len(self.editors)
            var ed = TextEdit(o.text)
            ed.pad_x = TEXT_PAD
            ed.pad_y = TEXT_PAD
            ed.focused = False
            self.editors.append(ed^)
            self.ed_rev.append(o.rev)
            self.ed_w.append(-1)
            self.ed_h.append(-1)
            self.ed_ids[o.id] = s
        if self.ed_rev[s] != o.rev:
            self.editors[s].set_text(o.text)
            self.ed_rev[s] = o.rev
        if self.ed_w[s] != o.w or self.ed_h[s] != o.h:
            self.editors[s].resize(o.w, o.h)
            self.ed_w[s] = o.w
            self.ed_h[s] = o.h
        return s

    def begin_text_edit(mut self, id: Int) -> Bool:
        """Keys go to object `id`'s text until end_text_edit; the whole edit is one undo step."""
        var p = self.index(id)
        if p < 0 or (self.objs[p].kind != TEXT and self.objs[p].kind != STICKY) or self.objs[p].locked:
            return False
        if self.editing >= 0:
            self.end_text_edit()
        self._commit(0)
        self.editing = id
        var s = self._editor(p)
        self.editors[s].focused = True
        self.editors[s].history.clear()
        var last = len(self.editors[s].paras) - 1
        self.editors[s].move_to(Pos(last, self.editors[s].paras[last].byte_length()), False)
        self.version += 1
        return True

    def text_key(mut self, name: String, mods: Int, now_ms: Int, font: Font) -> Bool:
        """A key for the box being edited (inside, undo is the editor's own). False when nothing is being edited."""
        if self.editing < 0:
            return False
        var p = self.index(self.editing)
        if p < 0:
            self.editing = -1
            return False
        var s = self._editor(p)
        var st = PlainStyler(self.objs[p].size, self.objs[p].color if self.objs[p].kind == TEXT else 0xFF222222)
        var used = self.editors[s].key(name, mods, now_ms, font, st)
        self.version += 1
        return used

    def editor_text(mut self) -> String:
        """The text in the box being edited, as typed so far."""
        if self.editing < 0:
            return ""
        return self.editors[self._editor(self.index(self.editing))].text()

    def end_text_edit(mut self):
        """Stop editing: the box takes the editor's text (and grows to fit it): one undo step if it changed."""
        if self.editing < 0:
            return
        var id = self.editing
        self.editing = -1
        var p = self.index(id)
        if p < 0:
            return
        var s = self._editor(p)
        var text = self.editors[s].text()
        self.editors[s].focused = False
        if text != self.objs[p].text:
            self._touch(id)
            self.objs[p].text = text
            self.objs[p].rev = self._next_rev()
            self.ed_rev[s] = self.objs[p].rev
            var lines = 1
            for b in text.as_bytes():
                if b == 10:
                    lines += 1
            var need = Float64(lines) * self.objs[p].size * 1.45 + 2 * TEXT_PAD
            if self.objs[p].kind == TEXT and need > self.objs[p].h:
                self.objs[p].h = need
            self._reroute([id])
            self._changed()
            self._commit(CH_TEXT)
        self.version += 1

    # ------------------------------------------------ painting

    def _poly_box(self, ref o: Obj, var pts: List[Float64]) -> List[Float64]:
        """Local points (around the centre) turned and placed on the page."""
        var c = cos(o.rot)
        var s = sin(o.rot)
        var cx = o.cx()
        var cy = o.cy()
        for i in range(0, len(pts), 2):
            var lx = pts[i]
            var ly = pts[i + 1]
            pts[i] = cx + lx * c - ly * s
            pts[i + 1] = cy + lx * s + ly * c
        return pts^

    def _corners(self, ref o: Obj) -> List[Float64]:
        var hw = o.w / 2
        var hh = o.h / 2
        return self._poly_box(o, [-hw, -hh, hw, -hh, hw, hh, -hw, hh])

    def _outline[P: Painter](self, mut p: P, pts: List[Float64], width: Float64, color: UInt32):
        var n = len(pts) // 2
        for i in range(n):
            var j = (i + 1) % n
            p.line(pts[2 * i], pts[2 * i + 1], pts[2 * j], pts[2 * j + 1], width, color)

    def _ellipse_pts(self, ref o: Obj) -> List[Float64]:
        var pts = List[Float64](capacity=96)
        for i in range(48):
            var a = 2 * PI * Float64(i) / 48
            pts.append(cos(a) * o.w / 2)
            pts.append(sin(a) * o.h / 2)
        return self._poly_box(o, pts^)

    def _paint_obj[P: Painter, S: Styler](mut self, mut p: P, font: Font, i: Int, styler: S, own_style: Bool):
        if self.paint_shape(p, i):
            return
        var kind = self.objs[i].kind
        var id = self.objs[i].id
        if kind == TEXT or kind == STICKY:
            if kind == STICKY:
                ref o = self.objs[i]
                if o.rot == 0:
                    p.rect(o.x + 2, o.y + 3, o.w, o.h, 0x18000000, o.radius)  # (a soft shadow)
                    p.rect(o.x, o.y, o.w, o.h, o.color, o.radius)
                else:
                    p.polygon(self._corners(o), o.color)
            var s = self._editor(i)
            var x = self.objs[i].x
            var y = self.objs[i].y
            if own_style:
                var ps = PlainStyler(self.objs[i].size, self.objs[i].color if kind == TEXT else 0xFF222222)
                self.editors[s].paint(p, font, x, y, ps)
            else:
                self.editors[s].paint(p, font, x, y, styler)
            p.note("object " + kind_name(kind) + " " + String(id))

    def paint_shape[P: Painter](mut self, mut p: P, i: Int) -> Bool:
        """objs[i] in page points when it is a shape, a picture, ink or a connector (anything without words); False
        for a text or a sticky, which a painter with its own type draws (mojoui.pagedesk)."""
        var kind = self.objs[i].kind
        var id = self.objs[i].id
        if kind == RECT:
            ref o = self.objs[i]
            if o.rot == 0:
                p.rect(o.x, o.y, o.w, o.h, o.color, o.radius)
            else:
                p.polygon(self._corners(o), o.color)
            p.note("object rect " + String(id))
            if o.line != 0 and o.line_width > 0:
                self._outline(p, self._corners(o), o.line_width, o.line)
        elif kind == ELLIPSE:
            ref o = self.objs[i]
            var pts = self._ellipse_pts(o)
            p.polygon(pts, o.color)
            p.note("object ellipse " + String(id))
            if o.line != 0 and o.line_width > 0:
                self._outline(p, pts, o.line_width, o.line)
        elif kind == INK:
            if not self.objs[i].stroke.sealed:
                self.objs[i].stroke.seal()
            ref q = self.objs[i]
            if q.rot == 0:
                p.polygon(q.stroke.shape, q.stroke.color)
            else:
                var c = cos(q.rot)
                var s = sin(q.rot)
                var cx = q.cx()
                var cy = q.cy()
                var pts = List[Float64](capacity=len(q.stroke.shape))
                for k in range(0, len(q.stroke.shape), 2):
                    var lx = q.stroke.shape[k] - cx
                    var ly = q.stroke.shape[k + 1] - cy
                    pts.append(cx + lx * c - ly * s)
                    pts.append(cy + lx * s + ly * c)
                p.polygon(pts, q.stroke.color)
            p.note("object ink " + String(id))
        elif kind == PICTURE:
            ref o = self.objs[i]
            p.image(o.pixels, o.pw, o.ph, o.x, o.y, o.w, o.h)
            p.note("object picture " + String(id))
        elif kind == CONNECTOR:
            ref o = self.objs[i]
            p.line(o.ax, o.ay, o.bx, o.by, o.line_width, o.color)
            p.note("object connector " + String(id))
            var dx = o.bx - o.ax
            var dy = o.by - o.ay
            var l = sqrt(dx * dx + dy * dy)
            if l > 1e-6:
                var ux = dx / l
                var uy = dy / l
                var head = 6 + o.line_width * 2.5
                var bx = o.bx - ux * head
                var by = o.by - uy * head
                p.polygon([o.bx, o.by, bx - uy * head * 0.5, by + ux * head * 0.5, bx + uy * head * 0.5, by - ux * head * 0.5], o.color)
        else:
            return False
        return True

    def _paint_all[P: Painter, S: Styler](mut self, mut p: P, font: Font, vx: Float64, vy: Float64, vw: Float64, vh: Float64, k: Float64,
                                          styler: S, own_style: Bool):
        # the objects layer: culled to the view snapped out to TILE, so a small pan keeps the same picture (version)
        var tx0 = floor(vx / TILE) * TILE
        var ty0 = floor(vy / TILE) * TILE
        var tx1 = ceil((vx + vw) / TILE) * TILE
        var ty1 = ceil((vy + vh) / TILE) * TILE
        p.begin_layer("objects")
        var ev = 0
        if self.editing >= 0:
            var ep = self.index(self.editing)
            if ep >= 0:
                ev = self.editors[self._editor(ep)].view_version
        var v = (self.doc * 15485863 * 4099 + self.version * 1000003 + Int(tx0 / TILE) * 7919 + Int(ty0 / TILE) * 104729 + Int(tx1 / TILE) * 31 + Int(ty1 / TILE) * 131 + ev * 17) & 0x3FFFFFFFFFFFFFFF
        p.layer_version(v)
        p.layer_transform(-vx * k, -vy * k, k)
        for i in self.query(tx0, ty0, tx1, ty1):
            self._paint_obj(p, font, i, styler, own_style)
        # the selection layer: outlines and handles (few items: the host compares them)
        p.begin_layer("selection")
        p.layer_transform(-vx * k, -vy * k, k)
        var lw = 1.5 / k
        for id in self.selected:
            var q = self.index(id)
            if q < 0:
                continue
            ref o = self.objs[q]
            if o.kind == CONNECTOR:
                p.line(o.ax, o.ay, o.bx, o.by, o.line_width + 4 / k, 0x60EB6325)
            else:
                self._outline(p, self._corners(o), lw, SEL_COLOR)
            p.note("selected " + String(id))
        var single = self._single()
        if single >= 0:
            var r = 4.0 / k
            var top = self.handle_point(single, H_N, k)
            var rot = self.handle_point(single, H_ROTATE, k)
            p.line(top[0], top[1], rot[0], rot[1], lw, SEL_COLOR)
            for h in range(9):
                var q = self.handle_point(single, h, k)
                p.rect(q[0] - r - lw, q[1] - r - lw, 2 * (r + lw), 2 * (r + lw), SEL_COLOR, 1 / k if h != H_ROTATE else r + lw)
                p.rect(q[0] - r, q[1] - r, 2 * r, 2 * r, HANDLE_FILL, 1 / k if h != H_ROTATE else r)
                p.note("handle " + String(h))

    def paint[P: Painter](mut self, mut p: P, font: Font, vx: Float64, vy: Float64, vw: Float64, vh: Float64, k: Float64 = 1):
        """The objects meeting the view (vx, vy, vw, vh in page points) in z order, then the selection and its handles;
        both layers shown through (page - (vx, vy)) · k. Text boxes draw with their own size and colour."""
        self._paint_all(p, font, vx, vy, vw, vh, k, PlainStyler(), True)

    def paint_styled[P: Painter, S: Styler](mut self, mut p: P, font: Font, vx: Float64, vy: Float64, vw: Float64, vh: Float64, k: Float64,
                                            styler: S):
        """As paint, every text box drawn with `styler` (Markdown, a theme)."""
        self._paint_all(p, font, vx, vy, vw, vh, k, styler, False)

    # ------------------------------------------------ building without undo (importers)

    def save_text(self) -> String:
        """The objects as text, one per line in z order (pictures keep their box, not their pixels: debt, D-7423).
        Fields are tab-separated; a text's newlines and backslashes are escaped; an INK line ends with its points."""
        var order = List[Int]()
        for i in range(len(self.objs)):
            order.append(i)
        for a in range(1, len(order)):  # (insertion sort by z: objects are mostly in order already)
            var k = order[a]
            var b = a - 1
            while b >= 0 and self.objs[order[b]].z > self.objs[k].z:
                order[b + 1] = order[b]
                b -= 1
            order[b + 1] = k
        var out = String("objectlayer 1\n")
        for i in order:
            ref o = self.objs[i]
            out += String(o.id) + "\t" + String(o.kind) + "\t" + String(o.x) + "\t" + String(o.y) + "\t" + String(o.w) + "\t" + String(o.h)
            out += "\t" + String(o.rot) + "\t" + String(o.z) + "\t" + ("1" if o.locked else "0") + "\t" + String(Int(o.color)) + "\t" + String(Int(o.line))
            out += "\t" + String(o.line_width) + "\t" + String(o.radius) + "\t" + String(o.size) + "\t" + String(o.from_id) + "\t" + String(o.to_id)
            out += "\t" + String(o.fx) + "\t" + String(o.fy) + "\t" + String(o.stroke.width) + "\t"
            if o.kind == INK:
                for j in range(o.stroke.points()):
                    if j > 0:
                        out += " "
                    out += String(o.stroke.xs[j]) + "," + String(o.stroke.ys[j]) + "," + String(o.stroke.ps[j])
            out += "\t" + o.text.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t") + "\n"
        return out^

    def load_text(mut self, text: String) raises:
        """Replaces the objects with save_text's (ids are new; connectors keep their ends); no undo step. The layer is
        then saved as it is (mark_saved)."""
        self._load_text(text)
        self.mark_saved()

    def _load_text(mut self, text: String) raises:
        self.objs = List[Obj]()
        self.pos_of = Dict[Int, Int]()
        self.selected = List[Int]()
        self.history.clear()
        var new_of = Dict[Int, Int]()
        var conns = List[Obj]()
        var zs = Dict[Int, Int]()  # new id → saved z
        var lines = text.split("\n")
        for li in range(1, len(lines)):
            var line = String(lines[li])
            if line == "":
                continue
            var f = line.split("\t")
            if len(f) != 21:
                raise Error("objectlayer: line " + String(li + 1) + " has " + String(len(f)) + " fields, not 21")
            var kind = Int(String(f[1]))
            var o = Obj(-1, kind, Float64(String(f[2])), Float64(String(f[3])), Float64(String(f[4])), Float64(String(f[5])), UInt32(Int(String(f[9]))))
            o.rot = Float64(String(f[6]))
            o.locked = String(f[8]) == "1"
            o.line = UInt32(Int(String(f[10])))
            o.line_width = Float64(String(f[11]))
            o.radius = Float64(String(f[12]))
            o.size = Float64(String(f[13]))
            o.from_id = Int(String(f[14]))
            o.to_id = Int(String(f[15]))
            o.fx = Float64(String(f[16]))
            o.fy = Float64(String(f[17]))
            var raw = String(f[20])
            var t = String()
            var esc = False
            for ch in raw.codepoint_slices():
                if esc:
                    t += "\n" if ch == "n" else ("\t" if ch == "t" else String(ch))
                    esc = False
                elif ch == "\\":
                    esc = True
                else:
                    t += String(ch)
            o.text = t
            if kind == INK:
                var st = Stroke(Float64(String(f[18])), o.color)
                for pt in String(f[19]).split(" "):
                    var v = String(pt).split(",")
                    if len(v) == 3:
                        st.add(Float64(String(v[0])), Float64(String(v[1])), Float64(String(v[2])))
                st.seal()
                o.stroke = st^
            var old = Int(String(f[0]))
            var z = Int(String(f[7]))
            if kind == CONNECTOR:
                o.z = z
                conns.append(o^)
            else:
                var nid = self.adopt(o^)
                new_of[old] = nid
                zs[nid] = z
        for ref c in conns:
            var o = c.copy()
            o.from_id = new_of.get(o.from_id, -1) if o.from_id >= 0 else -1
            o.to_id = new_of.get(o.to_id, -1) if o.to_id >= 0 else -1
            var z = o.z
            var nid = self.adopt(o^)
            zs[nid] = z
        var lo = 0
        var hi = 0
        for i in range(len(self.objs)):
            var z = zs.get(self.objs[i].id, self.objs[i].z)
            self.objs[i].z = z
            lo = min(lo, z) if i > 0 else z
            hi = max(hi, z) if i > 0 else z
        self.z_top = hi
        self.z_bottom = lo
        self._changed()

    def unsaved(self) -> Bool:
        """The document changed since it was last loaded or saved (mark_saved)."""
        return self.version != self.saved_version

    def mark_saved(mut self):
        self.saved_version = self.version

    def adopt(mut self, var o: Obj) -> Int:
        """An object as it is (an importer's): a new id and the top z, no undo step."""
        o.id = self.next_id
        self.next_id += 1
        self.z_top += 1
        o.z = self.z_top
        if o.kind == TEXT or o.kind == STICKY:
            o.rev = self._next_rev()
        var id = o.id
        self.pos_of[id] = len(self.objs)
        self.objs.append(o^)
        if self.objs[len(self.objs) - 1].kind == CONNECTOR:
            self._route(len(self.objs) - 1)
        self._changed()
        return id


    def reserve_ids(mut self, n: Int):
        """(D-7959) Ids and z 1…n belong to a document still being adopted (adopt_as): objects made meanwhile get ids and
        z above them, as they would after the whole import."""
        self.next_id = max(self.next_id, n + 1)
        self.z_top = max(self.z_top, n)

    def adopt_deleted(mut self, var o: Obj, id: Int, z: Int, ends: List[Int]) -> Bool:
        """(D-7959) A document's connector arriving after an edit deleted one of its ends (a progressive open): had it
        been there, the delete would have taken it too. It goes into that step (the earliest one in the history that
        deleted an end) as deleted there, restored after its ends by an undo. False when no step in the history
        deleted an end (it is dropped, as the delete would have dropped it)."""
        o.id = id
        o.z = z
        o.src_at = id - 1
        o.src_doc = self.src.id
        self.adopted[id] = True
        self.next_id = max(self.next_id, id + 1)
        self.z_top = max(self.z_top, z)
        for c in range(len(self.history.done)):
            var hit = False
            ref ch = self.history.done[c]
            for k in range(len(ch.ids)):
                if ch.ids[k] in ends and ch.before[k] and not ch.after[k]:
                    hit = True
                    break
            if not hit:
                continue
            # (first in the step: an undo puts the step's objects back last to first, so its ends are back before it)
            ch.ids.insert(0, id)
            ch.before.insert(0, Optional[Obj](o^))
            ch.after.insert(0, Optional[Obj](None))
            return True
        return False

    def adopt_as(mut self, var o: Obj, id: Int, z: Int) -> Int:
        """An object as it is with the id and z its document gives it (an importer's: a JSON Canvas node's index), no
        undo step; later objects get ids and z above every one given so far."""
        o.id = id
        o.z = z
        o.src_at = id - 1
        o.src_doc = self.src.id
        self.adopted[id] = True
        self.next_id = max(self.next_id, id + 1)
        self.z_top = max(self.z_top, z)
        if o.kind == TEXT or o.kind == STICKY:
            o.rev = self._next_rev()
        self.pos_of[id] = len(self.objs)
        self.objs.append(o^)
        var was = id in self.touched
        self._log(id)
        if not was:  # (as its document has it)
            try:
                _ = self.touched.pop(id)
            except:
                pass
        self.adopting = True
        if self.objs[len(self.objs) - 1].kind == CONNECTOR:
            self._route(len(self.objs) - 1)
        self._changed()
        self.adopting = False
        self.adopt_ids.append(id)
        self.adopt_vers.append(self.version)
        return id

    def order_by_z(mut self):
        """objs in stacking order (bottom first), as a layer built in that order has them (a progressive open adopts
        out of order)."""
        var keys = List[Int](capacity=len(self.objs))
        var zmin = 0
        for ref o in self.objs:
            zmin = min(zmin, o.z)
        var n = len(self.objs)
        for i in range(n):
            keys.append((self.objs[i].z - zmin) * (n + 1) + i)
        sort(keys)
        var sorted_in = True
        for r in range(n):
            if keys[r] % (n + 1) != r:
                sorted_in = False
                break
        if sorted_in:
            return
        var dest = List[Int](length=n, fill=0)  # (objs[i] goes to dest[i]: cycles of swaps, nothing copied)
        for r in range(n):
            dest[keys[r] % (n + 1)] = r
        for i in range(n):
            while dest[i] != i:
                var d = dest[i]
                self.objs.swap_elements(i, d)
                dest[i] = dest[d]
                dest[d] = d
        self.pos_of = Dict[Int, Int]()
        for i in range(n):
            self.pos_of[self.objs[i].id] = i
        self.dirty = True

def text_box(font: Font, text: String, size: Float64) -> Tuple[Float64, Float64]:
    """A text box that fits `text` unwrapped at `size`: width, height (with TEXT_PAD all round)."""
    var w = 0.0
    var lines = 0
    var start = 0
    var bytes = text.as_bytes()
    for i in range(len(bytes) + 1):
        if i == len(bytes) or bytes[i] == 10:
            w = max(w, font.measure(String(text[byte=start:i]), size))
            lines += 1
            start = i + 1
    return (ceil(w) + 2 * TEXT_PAD + 4, Float64(lines) * size * 1.45 + 2 * TEXT_PAD)


def import_fabric(json_text: String) raises -> ObjectLayer:
    """Personal Note's canvas (Fabric-style JSON: {version, objects: [IText, Path, Rect, Connector, …]}) as an object
    layer. Unknown types are skipped; connectors attach by the Rects' semanticIds."""
    var font = Font()
    return import_fabric(json_text, font)


def import_fabric(json_text: String, font: Font) raises -> ObjectLayer:
    var j = Json.parse(json_text)
    var ol = ObjectLayer()
    var objs = j.get(0, "objects")
    if j.kind(objs) != J_ARRAY:
        raise Error("import_fabric: no objects array")
    var by_semantic = Dict[String, Int]()
    var pending = List[Int]()  # connector nodes, attached once every Rect is in
    for i in range(j.size(objs)):
        var n = j.at(objs, i)
        var t = j.text(j.get(n, "type"))
        if t == "IText" or t == "Textbox" or t == "Text":
            var text = j.text(j.get(n, "text"))
            var size = j.real(j.get(n, "fontSize"), 16)
            var box = text_box(font, text, size)
            var o = Obj(0, TEXT, j.real(j.get(n, "left")), j.real(j.get(n, "top")), box[0], box[1], parse_color(j.text(j.get(n, "fill")), 0xFF222222))
            o.text = text
            o.size = size
            o.line_width = 0
            o.rot = j.real(j.get(n, "angle")) * PI / 180
            _ = ol.adopt(o^)
        elif t == "Path":
            var path = j.get(n, "path")
            var s = Stroke(j.real(j.get(n, "strokeWidth"), 2), parse_color(j.text(j.get(n, "stroke")), 0xFF332222))
            for k in range(j.size(path)):
                var cmd = j.at(path, k)
                var m = j.size(cmd)
                if m >= 3:  # (the last pair of every command is where the pen got to: M x y, L x y, Q cx cy x y, C …)
                    s.add(j.real(j.at(cmd, m - 2)), j.real(j.at(cmd, m - 1)), 1.0)
            if s.points() == 0:
                continue
            s.seal()
            var o = Obj(0, INK, s.x0, s.y0, s.x1 - s.x0, s.y1 - s.y0, s.color)
            o.stroke = s^
            o.line_width = 0
            _ = ol.adopt(o^)
        elif t == "Rect" or t == "Ellipse" or t == "Circle":
            var w = j.real(j.get(n, "width")) * j.real(j.get(n, "scaleX"), 1)
            var h = j.real(j.get(n, "height")) * j.real(j.get(n, "scaleY"), 1)
            if t == "Circle":
                w = 2 * j.real(j.get(n, "radius"))
                h = w
            elif t == "Ellipse":
                w = 2 * j.real(j.get(n, "rx"))
                h = 2 * j.real(j.get(n, "ry"))
            var o = Obj(0, RECT if t == "Rect" else ELLIPSE, j.real(j.get(n, "left")), j.real(j.get(n, "top")), w, h,
                        parse_color(j.text(j.get(n, "fill")), 0))
            o.line = parse_color(j.text(j.get(n, "stroke")), 0)
            o.line_width = j.real(j.get(n, "strokeWidth"), 1) if o.line != 0 else 0
            o.radius = j.real(j.get(n, "rx")) if t == "Rect" else 0
            o.rot = j.real(j.get(n, "angle")) * PI / 180
            var id = ol.adopt(o^)
            var sem = j.text(j.get(n, "semanticId"))
            if sem != "":
                by_semantic[sem] = id
        elif t == "Connector":
            pending.append(n)
    for n in pending:
        var f = by_semantic.get(j.text(j.get(n, "fromId")))
        var to = by_semantic.get(j.text(j.get(n, "toId")))
        if not Bool(f) or not Bool(to):
            continue
        var o = Obj(0, CONNECTOR, 0, 0, 0, 0, parse_color(j.text(j.get(n, "color")), 0xFF332222))
        o.from_id = f.value()
        o.to_id = to.value()
        o.line_width = j.real(j.get(n, "lineWidth"), 2)
        _ = ol.adopt(o^)
    return ol^


def _canvas_color(c: String, fallback: UInt32) -> UInt32:
    """A JSON Canvas colour: a preset "1"–"6" (red, orange, yellow, green, cyan, purple, as Obsidian draws them) or
    "#rrggbb"."""
    var presets: List[UInt32] = [0xFF4F4AFB, 0xFF3C9DFF, 0xFF6CDCE0, 0xFF62C96E, 0xFFD3C35A, 0xFFD87AA8]
    if c.byte_length() == 1:
        var d = Int(c.as_bytes()[0]) - 49
        if d >= 0 and d < 6:
            return presets[d]
    if c.byte_length() == 7 and c.startswith("#"):
        var v = 0
        for i in range(1, 7):
            var ch = Int(c.as_bytes()[i])
            v = v * 16 + (ch - 48 if ch <= 57 else (ch - 87 if ch >= 97 else ch - 55))
        return UInt32(0xFF000000) | UInt32((v >> 16) & 255) | (UInt32((v >> 8) & 255) << 8) | (UInt32(v & 255) << 16)
    return fallback


def import_json_canvas(json_text: String) raises -> ObjectLayer:
    """A JSON Canvas 1.0 document (jsoncanvas.org: {nodes, edges}, with Personal Note's `pn` extras) as an object layer:
    a coloured text node is a sticky (pn.type "sticky" too), a plain one a text box (pn.style.fontSize), a file node a
    placeholder card, an edge a connector between the nodes it names. Goal 79: the fixture's canvas and PN's 5,000-object
    stress note."""
    var j = Json.parse(json_text)
    return import_json_canvas_doc(j, json_text)


def _placeholder_name(j: Json, n: Int, kind: String, pk: String) -> String:
    """What a node that isn't drawn says on its card: its file's name, its address, its label, else its kind."""
    var name = j.text(j.get(n, "label"))
    if name == "":
        var file = j.text(j.get(n, "file"))
        if file != "" and not file.startswith("data:"):
            var cut = file.split("/")
            name = String(cut[len(cut) - 1])
    if name == "":
        name = j.text(j.get(n, "url"))
    if name == "":
        name = pk if pk != "" else kind
    return name if name.byte_length() <= 120 else String("…")


def canvas_node_obj(j: Json, n: Int, mut o: Obj) -> Bool:
    """One JSON Canvas node (j's node n) as the object import_json_canvas makes of it, written into `o`, not yet in a
    layer (no id, z or text revision: ObjectLayer.adopt gives them). False for a node it makes nothing of. Touches nothing shared: a
    progressive open (mojoui.canvasload) builds objects on every core with it."""
    var kind = j.text(j.get(n, "type"))
    var x = j.real(j.get(n, "x"))
    var y = j.real(j.get(n, "y"))
    var w = j.real(j.get(n, "width"), 200)
    var h = j.real(j.get(n, "height"), 100)
    var pn = j.get(n, "pn")
    var color = j.text(j.get(n, "color"))
    var made = False
    var own = j.text(j.get(pn, "type"))
    if kind == "text" and (own == "" or own == "text" or own == "sticky"):
        var style = j.get(pn, "style")
        var size = j.real(j.get(style, "fontSize"), 16)
        var ink = _canvas_color(j.text(j.get(style, "color")), 0xFF222222)
        if color != "" or j.text(j.get(pn, "type")) == "sticky":
            o = Obj(0, STICKY, x, y, w, w, _canvas_color(color, 0xFF9DE8FF))  # (as add_sticky: a square, then its height)
            o.radius = 4
            o.h = h
            o.ink = ink
        else:
            o = Obj(0, TEXT, x, y, w, h, ink)  # (as add_text)
        o.text = j.text(j.get(n, "text"))
        o.size = size
        o.line_width = 0
        o.family = j.text(j.get(style, "fontFamily"))
        o.line_height = j.real(j.get(style, "lineHeight"), 0)
        o.weight = Int(j.real(j.get(style, "fontWeight"), 400))
        o.markdown = j.text(j.get(pn, "format")) == "markdown"
        made = True
    elif kind == "file" and j.text(j.get(pn, "type")) == "ink" and j.text(j.get(pn, "kind"), "stroke") == "stroke":
        # a pen stroke: Personal Note keeps its path (M/L/Q commands, relative to the box) in pn
        var g = j.get(pn, "geometry")
        var gx = j.real(j.get(g, "x"), x)
        var gy = j.real(j.get(g, "y"), y)
        var ink = _canvas_color(j.text(j.get(pn, "color")), 0xFF1E2020)
        var alpha = j.real(j.get(pn, "alpha"), 1)  # (the highlighter's)
        if alpha > 0 and alpha < 1:
            ink = (ink & 0xFFFFFF) | (UInt32(Int(alpha * 255 + 0.5)) << 24)
        var st = Stroke(j.real(j.get(pn, "width"), 3), ink)
        var path = j.get(pn, "path")
        for c in range(j.size(path)):
            var cmd = j.at(path, c)
            var k = j.size(cmd)
            if k >= 3:
                st.add(gx + j.real(j.at(cmd, k - 2)), gy + j.real(j.at(cmd, k - 1)), 0.5)
        if st.points() > 0:  # (as add_ink: its box is its points' bounds, the outline sealed once)
            o = Obj(0, INK, st.x0, st.y0, max(st.x1 - st.x0, 0.0), max(st.y1 - st.y0, 0.0), st.color)
            o.stroke = st.copy()
            o.stroke.seal()
            o.line_width = 0
            made = True
    if not made and j.kind(n) == J_OBJECT:
        # (what isn't drawn as itself: a picture, a file, a link, a group, a shape, a kind this program has never heard of:
        # a plain card with its name, that moves; the rest of the node stays as its document has it)
        var pk = j.text(j.get(pn, "type"))
        if pk == "shape":  # (Personal Note's rectangle or circle)
            o = Obj(0, ELLIPSE if j.text(j.get(pn, "kind")) == "circle" else RECT, x, y, w, h, parse_color(j.text(j.get(pn, "fill")), 0))
            o.line = parse_color(j.text(j.get(pn, "stroke")), 0)
            o.line_width = j.real(j.get(pn, "strokeWidth"), 1) if o.line != 0 else 0
            o.radius = j.real(j.get(pn, "cornerRadius"), 0)
            if o.line == 0 and (o.color >> 24) == 0:  # (neither: still something to see and to hold)
                o.line = 0xFFD4D8DC
                o.line_width = 1
        else:
            o = Obj(0, RECT, x, y, w, h, UInt32(0x40F0F2F4) if kind == "group" else UInt32(0xFFF0F2F4))  # (as add_rect: a placeholder card)
            o.line = 0xFFD4D8DC
            o.line_width = 1
            o.radius = 6
            o.text = _placeholder_name(j, n, kind, pk)
        made = True
    if made:
        o.key = j.text(j.get(n, "id"))
    return made


def canvas_edge_obj(j: Json, e: Int) -> Tuple[String, String, Obj]:
    """One JSON Canvas edge: the node ids it joins and its connector (ends unset: the layer's ids go in from_id, to_id)."""
    var o = Obj(0, CONNECTOR, 0, 0, 0, 0, _canvas_color(j.text(j.get(e, "color")), 0xFF332222))
    o.line_width = j.real(j.get(j.get(e, "pn"), "lineWidth"), 2)
    var heads = j.get(j.get(e, "pn"), "arrowheads")
    if heads >= 0:
        o.head_end = j.flag(j.get(heads, "end"), True)
    o.key = j.text(j.get(e, "id"))
    return (j.text(j.get(e, "fromNode")), j.text(j.get(e, "toNode")), o^)


def import_json_canvas_doc(j: Json, text: String = "") raises -> ObjectLayer:
    """import_json_canvas from a document already parsed (an app reading other fields of it parses it once; `text`: what it
    was parsed from, kept so a save writes back what isn't edited; without it a save writes only what is drawn). A node's
    id and z are its index + 1 and an edge's come after every node's (mojoui.canvasload opens the same text a part at a
    time to the same layer)."""
    var ol = ObjectLayer()
    if text != "":
        ol.src = CanvasSource.of(text)
    var nodes = j.get(0, "nodes")
    if j.kind(nodes) != J_ARRAY:  # (another app's format, or nothing: an empty board here would be saved over it)
        raise Error("not a JSON Canvas document (it has no nodes)")
    var count = j.size(nodes)
    ol.reserve_ids(count + j.size(j.get(0, "edges")))
    var ids = Dict[String, Int]()
    for i in range(count):
        var o = Obj(0, RECT, 0, 0, 0, 0, 0)
        if canvas_node_obj(j, j.at(nodes, i), o):
            var key = o.key
            ids[key] = ol.adopt_as(o^, i + 1, i + 1)
    var edges = j.get(0, "edges")
    for i in range(j.size(edges)):
        var r = canvas_edge_obj(j, j.at(edges, i))
        var a = ids.get(r[0], -1)
        var b = ids.get(r[1], -1)
        if a >= 0 and b >= 0 and a != b:
            var c = r[2].copy()
            c.from_id = a
            c.to_id = b
            _ = ol.adopt_as(c^, count + i + 1, count + i + 1)
    ol.history.clear()
    return ol^


def _hex(c: UInt32) -> String:
    var digits = "0123456789abcdef"
    var out = String("#")
    for sh in [0, 8, 16]:
        var v = Int((c >> UInt32(sh)) & 0xFF)
        out += String(digits[byte=v // 16:v // 16 + 1]) + String(digits[byte=v % 16:v % 16 + 1])
    return out^


def _jn(v: Float64) -> String:
    if v == Float64(Int(v)):
        return String(Int(v))
    return String(v)


def _geometry(x: Float64, y: Float64, w: Float64, h: Float64, rot: Float64) -> String:
    return ('{"x":' + _jn(x) + ',"y":' + _jn(y) + ',"width":' + _jn(w) + ',"height":' + _jn(h) + ',"rotation":' + _jn(rot * 180 / PI)
            + ',"scaleX":1,"scaleY":1,"flipX":false,"flipY":false,"skewX":0,"skewY":0}')


def node_key(ref o: Obj) -> String:
    """The document id of an object: its own, or one made from its layer id (stable while the layer lives)."""
    return o.key if o.key != "" else "obj-" + String(o.id)


def _made_node(ref o: Obj, key: String) -> String:
    """A node for an object made here ("" for a kind that isn't one)."""
    if o.kind == TEXT or o.kind == STICKY:
        var style = '{"fontFamily":' + json_string(o.family) + ',"fontSize":' + _jn(o.size)
        if o.weight != 400:
            style += ',"fontWeight":' + String(o.weight)
        style += ',"lineHeight":' + _jn(o.line_height if o.line_height > 0 else 1.16)
        if o.kind == TEXT:
            style += ',"padding":8'
        style += ',"color":"' + _hex(o.color if o.kind == TEXT else o.ink) + '"}'
        var node = ('{"id":' + json_string(key) + ',"type":"text","x":' + _jn(Float64(Int(o.x + 0.5))) + ',"y":' + _jn(Float64(Int(o.y + 0.5)))
                    + ',"width":' + _jn(Float64(Int(o.w + 0.5))) + ',"height":' + _jn(Float64(Int(o.h + 0.5))) + ',"text":' + json_string(o.text))
        if o.kind == STICKY:
            node += ',"color":"' + _hex(o.color) + '"'
        node += ',"pn":{"type":"' + ("sticky" if o.kind == STICKY else "text") + '","geometry":' + _geometry(o.x, o.y, o.w, o.h, o.rot) + ',"style":' + style + ',"extras":{}'
        if o.kind == STICKY:
            node += ',"color":"' + _hex(o.color) + '"'
        else:
            node += ',"mode":"box"' + (',"format":"markdown"' if o.markdown else "")
        return node + "}}"
    elif o.kind == INK:
        ref st = o.stroke
        var path = String("[")
        for k in range(len(st.xs)):
            if k > 0:
                path += ","
            path += '["' + ("M" if k == 0 else "L") + '",' + _jn(st.xs[k] - o.x) + "," + _jn(st.ys[k] - o.y) + "]"
        path += "]"
        return ('{"id":' + json_string(key) + ',"type":"file","x":' + _jn(Float64(Int(o.x + 0.5))) + ',"y":' + _jn(Float64(Int(o.y + 0.5)))
                     + ',"width":' + _jn(Float64(Int(o.w + 0.5))) + ',"height":' + _jn(Float64(Int(o.h + 0.5))) + ',"file":"","pn":{"type":"ink","geometry":'
                     + _geometry(o.x, o.y, o.w, o.h, o.rot) + ',"opacity":1,"visible":true,"strokeUniform":false,"blend":"source-over","extras":{},"kind":"stroke","tool":"' + ("pen" if (st.color >> 24) == 0xFF else "highlight") + '","width":'
                     + _jn(st.width) + ',"cap":"round","join":"round","color":"' + _hex(st.color) + '"' + ((',"alpha":' + _jn(Float64(Int(Float64(st.color >> 24) / 255 * 10000 + 0.5)) / 10000)) if (st.color >> 24) != 0xFF else String("")) + ',"path":' + path + "}}")
    elif o.kind == RECT and o.line == 0:  # (a shape made here: text-ops.js newShape)
        var fill = _hex(o.color)
        return ('{"id":' + json_string(key) + ',"type":"file","x":' + _jn(Float64(Int(o.x + 0.5))) + ',"y":' + _jn(Float64(Int(o.y + 0.5)))
                + ',"width":' + _jn(Float64(Int(o.w + 0.5))) + ',"height":' + _jn(Float64(Int(o.h + 0.5))) + ',"file":"","pn":{"type":"shape","geometry":'
                + _geometry(o.x, o.y, o.w, o.h, o.rot) + ',"kind":"rect","fill":"' + fill + '","cornerRadius":' + _jn(o.radius) + ',"cornerRadiusY":' + _jn(o.radius) + ',"strokeWidth":0,"extras":{}}}')
    return ""


def _made_edge(layer: ObjectLayer, ref o: Obj, key: String) -> String:
    """An edge for a connector made here ("" when an end is gone)."""
    if o.kind == CONNECTOR and o.from_id >= 0 and o.to_id >= 0:
        var a = layer.index(o.from_id)
        var b = layer.index(o.to_id)
        if a < 0 or b < 0:
            return ""
        return ('{"id":' + json_string(key) + ',"fromNode":' + json_string(node_key(layer.objs[a])) + ',"toNode":' + json_string(node_key(layer.objs[b]))
                     + ',"color":"' + _hex(o.color) + '","pn":{"type":"connector","geometry":' + _geometry(min(o.ax, o.bx), min(o.ay, o.by), max(abs(o.bx - o.ax), 1.0), max(abs(o.by - o.ay), 1.0), 0)
                     + ',"color":"' + _hex(o.color) + '","lineWidth":' + _jn(o.line_width) + ',"reverseX":' + ("true" if o.bx < o.ax else "false")
                     + ',"reverseY":' + ("true" if o.by < o.ay else "false") + ',"arrowheads":{"start":false,"end":' + ("true" if o.head_end else "false") + '},"extras":{}}}')
    return ""


def objects_json_canvas(layer: ObjectLayer, columns: Int = 1, rows: Int = 1, page_w: Float64 = 860, page_h: Float64 = 1080) -> String:
    """The layer's own objects (nothing of the document they were read from: export_json_canvas is what saves one) as a JSON Canvas 1.0 document with Personal Note's `pn` extras (the inverse of import_json_canvas): a
    text box or a sticky is a text node (a sticky with its colour), a pen stroke a file node whose pn holds its path (the
    derived SVG left to the app that wants one: "file": ""), a connector an edge; the page grid in pn.page."""
    var nodes = List[String]()
    var edges = List[String]()
    for i in layer._order():
        ref o = layer.objs[i]
        if o.kind == CONNECTOR:
            var e = _made_edge(layer, o, node_key(o))
            if e != "":
                edges.append(e)
        else:
            var n = _made_node(o, node_key(o))
            if n != "":
                nodes.append(n)
    return ('{"nodes":[' + ",".join(nodes) + '],"edges":[' + ",".join(edges) + '],"pn":{"schemaVersion":1,"page":{"columns":' + String(columns)
            + ',"rows":' + String(rows) + '},"grid":{"width":' + _jn(page_w) + ',"height":' + _jn(page_h) + "}}}")


def export_json_canvas(layer: ObjectLayer, columns: Int = 1, rows: Int = 1, page_w: Float64 = 860, page_h: Float64 = 1080) -> String:
    """The board as a JSON Canvas 1.0 document, to save (the inverse of import_json_canvas). A board read from a document
    is that document with what was edited changed (review 3): every node, edge and top-level member that wasn't is its own
    text, in its own order, kinds and keys nobody here knows included; an edited node has only the members it changed
    replaced; one made here is appended, one deleted is gone with its edges. Unedited, it is the very text. The page grid
    is the document's own (columns, rows, page_w, page_h: for a board made here: objects_json_canvas)."""
    if not layer.src.ok:
        return objects_json_canvas(layer, columns, rows, page_w, page_h)
    ref src = layer.src
    var count = len(src.ns)
    var nodes = List[String]()
    var node_at = List[Int]()  # each item's place in the document (-1: made here)
    var edges = List[String]()
    var edge_at = List[Int]()
    var used = List[Bool](length=count + len(src.es), fill=False)
    var same = True  # nothing differs
    var last = -1
    var last_edge = -1
    for i in layer._order():
        ref o = layer.objs[i]
        var mine = o.src_doc == src.id and o.src_at >= 0
        if o.kind == CONNECTOR:
            var e = o.src_at - count if mine else -1
            if e >= 0 and e < len(src.es) and not used[count + e]:
                var raw = src.edge(e)
                var out = raw
                if o.id in layer.touched:
                    out = _edge_patched(layer, o, raw)
                if out != raw or e < last_edge:
                    same = False
                last_edge = max(last_edge, e)
                used[count + e] = True
                edges.append(out)
                edge_at.append(e)
            else:
                var made = _made_edge(layer, o, node_key(o))
                if made != "":
                    same = False
                    edges.append(made)
                    edge_at.append(-1)
            continue
        if mine and o.src_at < count and not used[o.src_at] and o.id == o.src_at + 1:
            var raw = src.node(o.src_at)
            var out = raw
            if o.id in layer.touched:
                out = _node_patched(o, raw)
            if out != raw or o.src_at < last:
                same = False
            last = max(last, o.src_at)
            used[o.src_at] = True
            nodes.append(out)
            node_at.append(o.src_at)
            continue
        same = False
        if mine and o.src_at < count:  # (a copy of one of its nodes: its text, under its own id)
            var out = _node_patched(o, src.node(o.src_at))
            try:
                out = patched(out, [Patch("id", json_string(node_key(o)))])
            except:
                pass
            nodes.append(out)
            node_at.append(-1)
            continue
        var made = _made_node(o, node_key(o))
        if made != "":
            nodes.append(made)
            node_at.append(-1)
    # what made no object stays (its node isn't an object, an edge whose end isn't a node): deleted objects don't, nor
    # edges that end at one
    var gone = Dict[String, Bool]()
    var j = Json()
    for i in range(count):
        if used[i]:
            continue
        var raw = src.node(i)
        if layer.was_object(i + 1):
            same = False
            try:
                j = Json.parse(raw)
                gone[j.text(j.get(0, "id"))] = True
            except:
                pass
            continue
        _insert_at(nodes, node_at, raw, i)
    for e in range(len(src.es)):
        if used[count + e]:
            continue
        if layer.was_object(count + e + 1):
            same = False
            continue
        var raw = src.edge(e)
        if len(gone) > 0:
            try:
                j = Json.parse(raw)
                if j.text(j.get(0, "fromNode")) in gone or j.text(j.get(0, "toNode")) in gone:
                    same = False
                    continue
            except:
                pass
        _insert_at(edges, edge_at, raw, e)
    if same:
        return src.text
    var all_nodes = "[" + ",".join(nodes) + "]"
    var all_edges = "[" + ",".join(edges) + "]"
    var t = src.text.byte_length()
    if src.edges_at < 0:
        if len(edges) == 0:
            return String(src.text[byte=0:src.nodes_at]) + all_nodes + String(src.text[byte=src.nodes_end:t])
        return String(src.text[byte=0:src.nodes_at]) + all_nodes + ',"edges":' + all_edges + String(src.text[byte=src.nodes_end:t])
    if len(edges) == 0 and len(src.es) == 0:
        all_edges = String(src.text[byte=src.edges_at:src.edges_end])
    if src.nodes_at < src.edges_at:
        return (String(src.text[byte=0:src.nodes_at]) + all_nodes + String(src.text[byte=src.nodes_end:src.edges_at]) + all_edges
                + String(src.text[byte=src.edges_end:t]))
    return (String(src.text[byte=0:src.edges_at]) + all_edges + String(src.text[byte=src.edges_end:src.nodes_at]) + all_nodes
            + String(src.text[byte=src.nodes_end:t]))


def _insert_at(mut items: List[String], mut at: List[Int], raw: String, i: Int):
    """Document item i, which made no object, put back after the one that stood before it (or first)."""
    var best = -1
    var pos = 0
    for q in range(len(at)):
        if at[q] >= 0 and at[q] < i and at[q] >= best:
            best = at[q]
            pos = q + 1
    items.insert(pos, raw)
    at.insert(pos, i)


def _whole(v: Float64) -> String:
    """A coordinate as JSON Canvas has them: whole page px, the nearest."""
    return String(Int(floor(v + 0.5)))


def _moved_number(j: Json, n: Int, key: String, by: Float64, default: Float64, whole: Bool) -> String:
    """Member `key`, a number, changed by `by`: whole when it was (or when a missing one is to be), else as it comes."""
    var m = j.get(n, key)
    var v = j.real(m, default) + by
    if (m >= 0 and j.is_whole(m) and whole) or (m < 0 and whole):
        return _whole(v)
    return _jn(v)


def _node_patched(ref o: Obj, raw: String) -> String:
    """Node `raw` as object `o` has it now: the members whose meaning changed since it was read replaced, the others its own
    (geometry both in the node and in pn.geometry, as Personal Note keeps it)."""
    try:
        var j = Json.parse(raw)
        var was = Obj(0, RECT, 0, 0, 0, 0, 0)
        if not canvas_node_obj(j, 0, was) or was.kind != o.kind:
            return raw
        var top = List[Patch]()
        var geo = List[Patch]()
        var pn = List[Patch]()
        var style = List[Patch]()
        var pnode = j.get(0, "pn")
        var g = j.get(pnode, "geometry")
        var dx = o.x - was.x
        var dy = o.y - was.y
        var dw = o.w - was.w
        var dh = o.h - was.h
        if abs(dx) > 1e-9:
            top.append(Patch("x", _moved_number(j, 0, "x", dx, 0, True)))
            if g >= 0:
                geo.append(Patch("x", _moved_number(j, g, "x", dx, was.x, False)))
        if abs(dy) > 1e-9:
            top.append(Patch("y", _moved_number(j, 0, "y", dy, 0, True)))
            if g >= 0:
                geo.append(Patch("y", _moved_number(j, g, "y", dy, was.y, False)))
        if abs(dw) > 1e-9:
            top.append(Patch("width", _moved_number(j, 0, "width", dw, was.w, True)))
            if g >= 0:
                var sx = j.real(j.get(g, "scaleX"), 1)
                geo.append(Patch("width", _moved_number(j, g, "width", dw / (sx if abs(sx) > 1e-9 else 1.0), was.w, False)))
        if abs(dh) > 1e-9:
            top.append(Patch("height", _moved_number(j, 0, "height", dh, was.h, True)))
            if g >= 0:
                var sy = j.real(j.get(g, "scaleY"), 1)
                geo.append(Patch("height", _moved_number(j, g, "height", dh / (sy if abs(sy) > 1e-9 else 1.0), was.h, False)))
        if abs(o.rot - was.rot) > 1e-9 and (g >= 0 or pnode >= 0):
            geo.append(Patch("rotation", _moved_number(j, g, "rotation", (o.rot - was.rot) * 180 / PI, 0, False)))
        if o.kind == TEXT or o.kind == STICKY:
            if o.text != was.text:
                top.append(Patch("text", json_string(o.text)))
            if o.family != was.family:
                style.append(Patch("fontFamily", json_string(o.family)))
            if o.size != was.size:
                style.append(Patch("fontSize", _jn(o.size)))
            if o.weight != was.weight:
                style.append(Patch("fontWeight", String(o.weight)))
            if o.line_height != was.line_height:
                style.append(Patch("lineHeight", _jn(o.line_height if o.line_height > 0 else 1.16)))
            if o.kind == TEXT and o.color != was.color:
                style.append(Patch("color", '"' + _hex(o.color) + '"'))
            if o.kind == STICKY and o.ink != was.ink:
                style.append(Patch("color", '"' + _hex(o.ink) + '"'))
            if o.kind == STICKY and o.color != was.color:
                top.append(Patch("color", '"' + _hex(o.color) + '"'))
                if j.get(pnode, "color") >= 0:
                    pn.append(Patch("color", '"' + _hex(o.color) + '"'))
            if o.markdown != was.markdown:
                pn.append(Patch("format", '"markdown"' if o.markdown else String("")))
        elif o.kind == INK:
            var differs = len(o.stroke.xs) != len(was.stroke.xs)
            for k in range(len(o.stroke.xs)):
                if differs or abs((o.stroke.xs[k] - o.x) - (was.stroke.xs[k] - was.x)) > 1e-6 or abs((o.stroke.ys[k] - o.y) - (was.stroke.ys[k] - was.y)) > 1e-6:
                    differs = True
                    break
            if differs:
                var path = String("[")
                for k in range(len(o.stroke.xs)):
                    path += ("," if k > 0 else "") + '["' + ("M" if k == 0 else "L") + '",' + _jn(o.stroke.xs[k] - o.x) + "," + _jn(o.stroke.ys[k] - o.y) + "]"
                pn.append(Patch("path", path + "]"))
                geo.clear()  # (its points are relative to its geometry: that is its box now)
                geo += [Patch("x", _jn(o.x)), Patch("y", _jn(o.y)), Patch("width", _jn(o.w)), Patch("height", _jn(o.h))]
            if o.stroke.color != was.stroke.color:
                pn.append(Patch("color", '"' + _hex(o.stroke.color) + '"'))
            if o.stroke.width != was.stroke.width:
                pn.append(Patch("width", _jn(o.stroke.width)))
        elif o.kind == ELLIPSE and (abs(dw) > 1e-9 or abs(dh) > 1e-9) and j.get(pnode, "radius") >= 0:
            pn.append(Patch("radius", _jn(min(o.w, o.h) / 2)))
        var out = patched(raw, top)
        if len(geo) + len(style) + len(pn) > 0:
            var inner = member_text(out, "pn")
            if not inner.startswith("{"):
                inner = "{}"
            inner = patched_in(inner, "geometry", geo)
            inner = patched_in(inner, "style", style)
            inner = patched(inner, pn)
            out = patched(out, [Patch("pn", inner)])
        return out
    except:
        return raw


def _edge_patched(layer: ObjectLayer, ref o: Obj, raw: String) -> String:
    """Edge `raw` as connector `o` has it now. Where its ends are drawn (pn.geometry) is written again only when an end was
    moved or resized."""
    try:
        var j = Json.parse(raw)
        var r = canvas_edge_obj(j, 0)
        ref was = r[2]
        var top = List[Patch]()
        var pn = List[Patch]()
        var pnode = j.get(0, "pn")
        var a = layer.index(o.from_id)
        var b = layer.index(o.to_id)
        if a < 0 or b < 0:
            return raw
        if node_key(layer.objs[a]) != r[0]:
            top.append(Patch("fromNode", json_string(node_key(layer.objs[a]))))
        if node_key(layer.objs[b]) != r[1]:
            top.append(Patch("toNode", json_string(node_key(layer.objs[b]))))
        if o.color != was.color:
            top.append(Patch("color", '"' + _hex(o.color) + '"'))
            if j.get(pnode, "color") >= 0:
                pn.append(Patch("color", '"' + _hex(o.color) + '"'))
        if o.line_width != was.line_width:
            pn.append(Patch("lineWidth", _jn(o.line_width)))
        var heads = List[Patch]()
        if o.head_end != was.head_end:
            heads.append(Patch("end", "true" if o.head_end else "false"))
        var geo = List[Patch]()
        if j.get(pnode, "geometry") >= 0 and (layer.node_moved(a) or layer.node_moved(b)):
            geo += [Patch("x", _jn(min(o.ax, o.bx))), Patch("y", _jn(min(o.ay, o.by))), Patch("width", _jn(max(abs(o.bx - o.ax), 1.0))), Patch("height", _jn(max(abs(o.by - o.ay), 1.0)))]
            if j.get(pnode, "reverseX") >= 0:
                pn.append(Patch("reverseX", "true" if o.bx < o.ax else "false"))
            if j.get(pnode, "reverseY") >= 0:
                pn.append(Patch("reverseY", "true" if o.by < o.ay else "false"))
        var out = patched(raw, top)
        if len(geo) + len(pn) + len(heads) > 0:
            var inner = member_text(out, "pn")
            if not inner.startswith("{"):
                inner = "{}"
            inner = patched_in(inner, "geometry", geo)
            inner = patched_in(inner, "arrowheads", heads)
            inner = patched(inner, pn)
            out = patched(out, [Patch("pn", inner)])
        return out
    except:
        return raw


def reading_text(layer: ObjectLayer) -> String:
    """What a search index should hold for a board: the words of its text boxes and stickies in reading order (top edge
    first, then left edge; ties keep stacking order), each stripped, blank-line separated (D-7927)."""
    var idx = List[Int]()
    for i in range(len(layer.objs)):
        ref o = layer.objs[i]
        if (o.kind == TEXT or o.kind == STICKY) and String(o.text.strip()) != "":
            idx.append(i)
    # a stable insertion sort by (y, x): boards hold hundreds of words at most where this runs (a save)
    for a in range(1, len(idx)):
        var v = idx[a]
        var b = a - 1
        while b >= 0 and (layer.objs[idx[b]].y > layer.objs[v].y or (layer.objs[idx[b]].y == layer.objs[v].y and layer.objs[idx[b]].x > layer.objs[v].x)):
            idx[b + 1] = idx[b]
            b -= 1
        idx[b + 1] = v
    var out = String("")
    for a in range(len(idx)):
        if a > 0:
            out += "\n\n"
        out += String(layer.objs[idx[a]].text.strip())
    return out^
