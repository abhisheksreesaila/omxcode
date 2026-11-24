# mojoui.buzanmap (goal 79): a Tony Buzan mind map drawn the way Personal Note's web map draws it, as a generic view of
# any tree of topics: organic one-bend branches as tapered ribbons in each branch's colour (width falls with depth and is
# capped by the bend), ideas on white cards with a coloured edge, the central topic as a filled card with a soft
# highlight, the dashed selection ring and the four add handles, on a dotted sheet. The geometry is the web's own
# (geometry.js: attach, branchGeometry, ribbonOutline; layout.js: card sizes), so a map saved by either looks the same.
#
#   var m = BuzanMap(); m.add(-1, "The book", 0, 0, color); m.add(0, "Characters", 280, -130, color2) …
#   m.draw(p, bx, x0, y0, w, h, zoom, sk)        # the view centred on the map's origin

from std.math import sqrt, tanh, pow, sin, cos, exp
from mojoui.scene import Painter, stroke_outline
from mojoui.graphemes import next_grapheme
from mojoui.skin import Skin, Shadow, with_alpha, hexc
from mojoui.fonttext import TextStyle, measure, line_metrics, ALIGN_CENTER
from mojoui.notesshell import Boxes, draw_lifted, draw_shadows, draw_bordered, draw_radial_steps
from mojoui.canvas import rgba
from mojoui.history import History, Snapshot
from mojoui.shared import new_key
from mojoui.jsonpatch import Change, patched, members, elements, find_member, part
from mojoui.json import Json, json_string
from mojoui.textedit import now_ms
from mojoui.wordsedit import WordsEdit
from mojoui.strokeicon import draw_icon
from mojoui.mapmarks import Frame, Curve, TopicLook, look_of, branch_between, curve_mid, seed_of, pencil_outline, due_chip, local_now, icon_path, DayTime, DUE_TODAY, DUE_OVER

comptime SERIF = "Source Serif 4"
comptime SHEET: UInt32 = 0xFFEFF6F8  # #f8f6ef
comptime CARD: UInt32 = 0xFFFAFEFF  # #fffefa
comptime LABEL: UInt32 = 0xFF252A29  # #292a25
comptime RING: UInt32 = 0xBF737C24  # #247c73 at .75


@fieldwise_init
struct Topic(Copyable, Movable):
    var parent: Int  # index, -1: the central topic
    var text: String
    var x: Float64
    var y: Float64
    var color: UInt32
    var id: String  # the document's id ("" for one made here before it is saved)
    var font_size: Float64  # 0: the map's default for its depth
    var bold: Bool
    var font: String  # "hand" (Source Serif 4) | "clean" (IBM Plex Sans), "" none given
    var extra: String  # the document's other members of this idea ("due":…,"done":…), written back as they came (D-7927)

    var look: TopicLook  # what `extra` says of how it looks

    def words(self) -> String:
        """What the idea says: its emoji, then its words (model.js displayText)."""
        return self.look.emoji + " " + self.text if self.look.emoji != "" else String(self.text)


@fieldwise_init
struct MapState(Copyable, Movable):
    """A map's ideas and which is selected (an undo step's before and after)."""
    var topics: List[Topic]
    var selected: Int


comptime BRANCH_COLORS: List[String] = ["#ef684b", "#efad28", "#65ae4f", "#2d9c91", "#3d8fe8", "#8c67cf", "#d85da8", "#5e6570"]


struct MapLayout(Movable):
    """An idea's words, icons and box (layout.js layoutNode)."""
    var lines: List[String]
    var widths: List[Float64]
    var step: Float64
    var icons: List[String]
    var icon: Float64  # an icon's size
    var lead: Float64  # the icons' room before the words
    var trail: Float64  # the pill's after them
    var chip: String
    var chip_state: Int
    var chip_w: Float64
    var text_w: Float64
    var w: Float64
    var h: Float64

    def __init__(out self):
        self.lines = List[String]()
        self.widths = List[Float64]()
        self.step = 0
        self.icons = List[String]()
        self.icon = 0
        self.lead = 0
        self.trail = 0
        self.chip = ""
        self.chip_state = 0
        self.chip_w = 0
        self.text_w = 0
        self.w = 0
        self.h = 0


def chip_style() -> TextStyle:
    var st = TextStyle("IBM Plex Sans", 600, False, 11)
    st.exact = True
    return st


struct BuzanMap(Movable):
    var topics: List[Topic]
    var selected: Int
    var editing: Int  # the idea whose words are being written (-1: none)
    var pen: WordsEdit  # its words, in the box over it (the web's .mindmap-node-editor)
    var pen_scroll: Float64  # how far the writing box is scrolled sideways (map units)
    var edit_text: String  # what it says now
    var edit_all: Bool  # its words are all selected (typing replaces them), as the web's editor opens
    var edit_caret: Tuple[Float64, Float64, Float64, Float64]  # where its caret was drawn (an input method's window), x -1: nowhere
    var made: Int  # ideas made here (for their ids)
    var now: DayTime  # what due dates are measured from (year 0: the clock)
    var frozen: Bool  # the view's bounds are the ones the map opened with (adding ideas never re-fits it)
    var bounds: Tuple[Float64, Float64, Float64, Float64]
    var cam: Tuple[Float64, Float64, Float64]  # the view a person zoomed or panned to: scale, x, y (screen px of the map's origin)
    var pinned: Bool  # cam is the view; else the map fits the room it has
    var past: History[Snapshot[MapState]]  # undo and redo
    var drag: Int  # the pointer's: -1 none, -2 pans the sheet, else the idea it moves
    var drag_dx: Float64  # from the pointer to the idea's centre (map units); a pan: where the view was
    var drag_dy: Float64
    var drag_sx: Float64  # where it went down (screen)
    var drag_sy: Float64
    var drag_moved: Bool
    var before: MapState  # the map as the gesture or the writing began

    def __init__(out self):
        self.topics = List[Topic]()
        self.selected = 0
        self.editing = -1
        self.pen = WordsEdit()
        self.pen_scroll = 0
        self.edit_text = ""
        self.edit_all = False
        self.edit_caret = (-1.0, 0.0, 0.0, 0.0)
        self.made = 0
        self.now = DayTime(0, 0, 0, 0, 0)
        self.frozen = False
        self.bounds = (0.0, 0.0, 0.0, 0.0)
        self.cam = (1.0, 0.0, 0.0)
        self.pinned = False
        self.past = History[Snapshot[MapState]](cap=100)
        self.drag = -1
        self.drag_dx = 0
        self.drag_dy = 0
        self.drag_sx = 0
        self.drag_sy = 0
        self.drag_moved = False
        self.before = MapState(List[Topic](), 0)

    # ------------------------------------------------ the view

    def view(self, w: Float64, h: Float64, padding: Float64 = 80) -> Tuple[Float64, Float64, Float64]:
        """(scale, x, y): the map fitted, or where a person put it."""
        return self.cam if self.pinned else self.fit(w, h, padding)

    def zoom_at(mut self, scale: Float64, x: Float64, y: Float64, w: Float64, h: Float64):
        """Another scale (kept from 25 % to 220 %), the map unit under (x, y) staying there."""
        var v = self.view(w, h)
        var sc = min(2.2, max(0.25, scale))
        self.cam = (sc, x - (x - v[1]) / v[0] * sc, y - (y - v[2]) / v[0] * sc)
        self.pinned = True

    def fit_again(mut self):
        """The whole map in view (the rail's Fit, the zoom island's number)."""
        self.pinned = False
        self.frozen = False
        self.freeze()

    def hit(self, x: Float64, y: Float64, w: Float64, h: Float64) -> Int:
        """The idea at (x, y) in the map's box (the one drawn last wins); -1: none."""
        var v = self.view(w, h)
        var mx = (x - v[1]) / v[0]
        var my = (y - v[2]) / v[0]
        for i in range(len(self.topics) - 1, -1, -1):
            if self.hidden(i):
                continue
            var f = self.frame(i)
            if f.pin:  # (its words lie on its branch)
                var m = curve_mid(self.branch_of(i))
                f.x = m[0]
                f.y = m[1] - f.hh
            if mx >= f.x - f.hw and mx <= f.x + f.hw and my >= f.y - f.hh and my <= f.y + f.hh:
                return i
        return -1

    # ------------------------------------------------ the pointer, in the map's box

    def press(mut self, x: Float64, y: Float64, w: Float64, h: Float64):
        """Down on an idea: selects it, and a drag moves it; on the sheet: a drag pans."""
        var i = self.hit(x, y, w, h)
        var v = self.view(w, h)
        self.drag_sx = x
        self.drag_sy = y
        self.drag_moved = False
        if i >= 0:
            self.before = self.state()
            self.drag = i
            self.drag_dx = self.topics[i].x - (x - v[1]) / v[0]
            self.drag_dy = self.topics[i].y - (y - v[2]) / v[0]
            self.selected = i
        else:
            self.drag = -2
            self.drag_dx = v[1]
            self.drag_dy = v[2]
            self.cam = v

    def drag_to(mut self, x: Float64, y: Float64, w: Float64, h: Float64) -> Bool:
        """The pointer moved with the button down; True when something did. (An idea moves by itself, its branches follow
        it: the web's; its children stay where they are.)"""
        if self.drag == -1:
            return False
        var far = sqrt((x - self.drag_sx) * (x - self.drag_sx) + (y - self.drag_sy) * (y - self.drag_sy))
        if not self.drag_moved and far <= (7.0 if self.drag >= 0 else 4.0):
            return False
        self.drag_moved = True
        if self.drag == -2:
            self.cam = (self.cam[0], self.drag_dx + x - self.drag_sx, self.drag_dy + y - self.drag_sy)
            self.pinned = True
            return True
        var v = self.view(w, h)
        self.topics[self.drag].x = (x - v[1]) / v[0] + self.drag_dx
        self.topics[self.drag].y = (y - v[2]) / v[0] + self.drag_dy
        return True

    def release(mut self) -> Bool:
        """Up: True when an idea was moved (one undo step)."""
        var d = self.drag
        self.drag = -1
        if d >= 0 and self.drag_moved:
            self.record()
            return True
        if d == -2 and not self.drag_moved:  # (a click on the sheet selects nothing)
            self.selected = -1
        return False

    # ------------------------------------------------ undo

    def state(self) -> MapState:
        return MapState(self.topics.copy(), self.selected)

    def record(mut self):
        """What changed since `before` is an undo step."""
        self.past.push(Snapshot[MapState](0, self.before.copy(), self.state()), 0)

    def _restore(mut self, st: MapState):
        self.editing = -1
        self.topics = st.topics.copy()
        self.selected = st.selected

    def undo(mut self) -> Bool:
        var e = self.past.undo()
        if not e:
            return False
        self._restore(e.value().before)
        return True

    def redo(mut self) -> Bool:
        var e = self.past.redo()
        if not e:
            return False
        self._restore(e.value().after)
        return True

    def delete_selected(mut self) -> Bool:
        """The selected idea and everything under it, gone; its parent is selected. The central one stays."""
        if self.selected < 0 or self.selected >= len(self.topics) or self.topics[self.selected].parent < 0:
            return False
        self.before = self.state()
        var parent = self.topics[self.selected].parent
        var gone = List[Bool](length=len(self.topics), fill=False)
        gone[self.selected] = True
        var more = True
        while more:
            more = False
            for i in range(len(self.topics)):
                var pa = self.topics[i].parent
                if not gone[i] and pa >= 0 and gone[pa]:
                    gone[i] = True
                    more = True
        var at = List[Int]()  # where each kept one goes
        var n = 0
        for i in range(len(self.topics)):
            at.append(-1 if gone[i] else n)
            n += 0 if gone[i] else 1
        var kept = List[Topic]()
        for i in range(len(self.topics)):
            if not gone[i]:
                var t = self.topics[i].copy()
                t.parent = at[t.parent] if t.parent >= 0 else t.parent
                kept.append(t^)
        self.topics = kept^
        self.selected = at[parent]
        self.record()
        return True

    def add(mut self, parent: Int, text: String, x: Float64, y: Float64, color: UInt32, id: String = "", font_size: Float64 = 0,
            bold: Bool = False, font: String = "", extra: String = "") -> Int:
        self.topics.append(Topic(parent, text, x, y, color, id, font_size, bold, font, extra, look_of(extra)))
        return len(self.topics) - 1

    def children(self, i: Int) -> Int:
        var n = 0
        for ref t in self.topics:
            if t.parent == i:
                n += 1
        return n

    def add_idea(mut self, sibling: Bool) -> Int:
        """A new idea from the selected one, as model.js makeNode places it: a child (or a sibling, beside it under its
        parent), on the root's alternating sides or its parent's side, a step further out by depth, a row below the
        others; a new main branch takes the next branch colour. It is selected and opens for writing ("New idea" selected).
        Returns its index (-1: none)."""
        if self.selected < 0 or self.selected >= len(self.topics):
            return -1
        self.before = self.state()
        var parent = self.selected
        if sibling and self.topics[parent].parent >= 0:
            parent = self.topics[parent].parent
        var sibs = self.children(parent)
        var root = self.topics[parent].parent < 0
        var side = (-1.0 if sibs % 2 == 1 else 1.0) if root else (1.0 if self.topics[parent].x >= 0 else -1.0)
        if not root and self.topics[parent].x == 0:
            side = 1.0
        var depth = self.depth(parent) + 1
        var position = Float64(sibs) - Float64(sibs - 1) / 2
        var color = hexc(materialize[BRANCH_COLORS]()[sibs % 8]) if root else self.topics[parent].color
        self.made += 1
        var font = self.topics[parent].font if self.topics[parent].font != "" else String("hand")
        var i = self.add(parent, "New idea", self.topics[parent].x + side * max(190.0, 330.0 - Float64(depth) * 55),
                         self.topics[parent].y + position * 76, color, new_key("node-"), max(15.0, 25.0 - Float64(depth) * 3), depth == 1, font)
        self.selected = i
        self.record()
        self.begin_edit(i)
        return i

    def begin_edit(mut self, i: Int):
        """Opens an idea's words for writing, all of them selected, in the lines its box shows."""
        if i < 0 or i >= len(self.topics):
            return
        self.before = self.state()
        self.editing = i
        var lines = wrap_text(self.topics[i].words())
        var shown = String(" ".join(lines))
        var own = String("\n".join(lines)) if shown == self.topics[i].text else String(self.topics[i].text)
        var b = self.edit_box(i)
        self.pen.centered = True
        self.pen.wrap = False
        self.pen.begin(own, self.edit_style(i), b[2] - 20)
        self.pen.ed.select_all()
        self.pen_scroll = 0
        self._edited()

    def _edited(mut self):
        self.edit_text = self.pen.text()
        var a = self.pen.ed.sel_start()
        var b = self.pen.ed.sel_end()
        var last = len(self.pen.ed.paras) - 1
        self.edit_all = self.edit_text != "" and a.para == 0 and a.byte == 0 and b.para == last and b.byte == self.pen.ed.paras[last].byte_length()

    def edit_key(mut self, name: String, mods: Int) -> Int:
        """A key while an idea is being written: 0 not its key, 1 used, 2 Enter (kept), 3 Escape (dropped)."""
        if self.editing < 0:
            return 0
        if name == "Enter" or name == "Return":
            var t = String(" ".join(self.pen.text().split()))
            if t != "" and t != self.topics[self.editing].text:
                self.topics[self.editing].text = t
                self.record()
            self._edit_over()
            return 2
        if name == "Escape":
            self._edit_over()
            return 3
        var r = self.pen.key(name, mods, now_ms())
        self._edited()
        return 1 if r != 0 else 0

    def _edit_over(mut self):
        self.editing = -1
        self.pen.preedit = ""
        self.pen.release()
        self.edit_caret = (-1.0, 0.0, 0.0, 0.0)

    def edit_insert(mut self, words: String):
        """Words from an input method or a paste into the idea being written."""
        self.pen.preedit = ""
        self.pen.insert(words, now_ms())
        self._edited()

    def edit_style(self, i: Int) -> TextStyle:
        ref t = self.topics[i]
        var st = TextStyle("IBM Plex Sans" if t.font == "clean" else SERIF, 700 if t.bold else 500, t.look.italic, self.idea_size(i))
        st.exact = True
        return st

    def edit_box(self, i: Int) -> Tuple[Float64, Float64, Float64, Float64]:
        """The writing box of idea i in map units: left, top, width, height (over its card, at least 100 × 38 on screen at 100 %)."""
        var s = self.card_size(i)
        return (self.topics[i].x - s[0] / 2, self.topics[i].y - s[1] / 2, s[0], s[1])

    def edit_at(mut self, x: Float64, y: Float64, w: Float64, h: Float64) -> Tuple[Float64, Float64, Bool]:
        """(x, y) of the map's box in the writing box's words, and whether it is in the box."""
        var v = self.view(w, h)
        var b = self.edit_box(self.editing)
        var bw = max(100.0, b[2] * v[0])
        var bh = max(38.0, b[3] * v[0])
        var px = x - (v[1] + b[0] * v[0])
        var py = y - (v[2] + b[1] * v[0])
        self.pen.lay()
        var step = self.line_step(self.editing)
        return ((px - 10) / v[0] + self.pen_scroll, (py - 2 - (bh - Float64(len(self.pen.lines)) * step * v[0]) / 2) / v[0], px >= 0 and py >= 0 and px <= bw and py <= bh)

    def edit_press(mut self, x: Float64, y: Float64, w: Float64, h: Float64, extend: Bool, word: Bool) -> Bool:
        """Down in the box of the idea being written: the caret there, or the word (a double click). False: not in it."""
        if self.editing < 0:
            return False
        var e = self.edit_at(x, y, w, h)
        if not e[2]:
            return False
        if word:
            self.pen.select_word(e[0], e[1], self.line_step(self.editing))
        else:
            self.pen.press(e[0], e[1], self.line_step(self.editing), extend)
        self._edited()
        return True

    def edit_drag(mut self, x: Float64, y: Float64, w: Float64, h: Float64) -> Bool:
        """The selection drawn out to (x, y)."""
        if self.editing < 0 or not self.pen.ed.dragging:
            return False
        var e = self.edit_at(x, y, w, h)
        self.pen.drag(e[0], e[1], self.line_step(self.editing))
        self._edited()
        return True

    def freeze(mut self):
        """Keeps the bounds the map has now as the ones its view fits (the web fits a map once, as it opens)."""
        var minx = 1e18
        var miny = 1e18
        var maxx = -1e18
        var maxy = -1e18
        for i in range(len(self.topics)):
            if self.hidden(i):
                continue
            var f = self.frame(i)
            var rx = max(120.0, f.hw + 40)
            var ry = max(120.0, f.hh + 40)
            minx = min(minx, f.x - rx)
            miny = min(miny, f.y - ry)
            maxx = max(maxx, f.x + rx)
            maxy = max(maxy, f.y + ry)
        self.bounds = (minx, miny, maxx, maxy)
        self.frozen = True

    def depth(self, i: Int) -> Int:
        var d = 0
        var j = i
        while self.topics[j].parent >= 0:
            j = self.topics[j].parent
            d += 1
        return d

    def layout(self, i: Int) -> MapLayout:
        """layout.js layoutNode: the words wrapped past 28 letters (a branch's in capitals), the icons before them, the due
        date's pill after them; the box: the root max(180, all + 50) × 76, an idea max(58, all) + 26 × (its size + 20), and a
        line's step for each line more."""
        ref t = self.topics[i]
        var st = self.label_style(i)
        st.size = self.idea_size(i)
        var branch = t.look.branch and t.parent >= 0
        var l = MapLayout()
        l.lines = wrap_text(t.words().upper() if branch else t.words())
        l.step = self.line_step(i)
        for x in l.lines:
            l.widths.append(measure(st, x))
            l.text_w = max(l.text_w, l.widths[len(l.widths) - 1])
        l.icons = t.look.shown_icons()
        l.icon = Float64(Int(st.size * 0.9 + 0.5))
        l.lead = Float64(len(l.icons)) * (l.icon + 4)
        if t.look.due != "" and not t.look.done:
            var c = due_chip(t.look.due, self.now if self.now.year > 0 else local_now())
            if c[0] != "":
                l.chip = c[0]
                l.chip_state = c[1]
                l.chip_w = Float64(Int(measure(chip_style(), c[0]) + 14 + 0.5))
                l.trail = l.chip_w + 6
        var all = l.lead + l.text_w + l.trail
        var more = Float64(len(l.lines) - 1) * l.step
        if t.parent < 0:
            l.w = max(180.0, all + 50)
            l.h = 76 + more
        else:
            l.w = max(58.0, all) + 26
            l.h = st.size + 20 + more
        return l^

    def card_size(self, i: Int) -> Tuple[Float64, Float64]:
        var l = self.layout(i)
        return (l.w, l.h)

    def hidden(self, i: Int) -> Bool:
        """Under an idea folded away (the web's collapsed)."""
        var k = self.topics[i].parent
        while k >= 0:
            if self.topics[k].look.collapsed:
                return True
            k = self.topics[k].parent
        return False

    def under(self, i: Int) -> Int:
        """How many ideas are under idea i, at every level."""
        var n = 0
        for k in range(len(self.topics)):
            var u = self.topics[k].parent
            while u >= 0:
                if u == i:
                    n += 1
                    break
                u = self.topics[u].parent
        return n

    def tasks(self) -> List[Int]:
        """For each idea: how many of the to-dos under it are done, and how many there are (taskCounts), two numbers each."""
        var out = List[Int](length=2 * len(self.topics), fill=0)
        for k in range(len(self.topics)):
            ref l = self.topics[k].look
            if not l.done and "todo" not in l.icons:
                continue
            var u = self.topics[k].parent
            while u >= 0:
                out[2 * u] += 1 if l.done else 0
                out[2 * u + 1] += 1
                u = self.topics[u].parent
        return out^

    def branch_of(self, i: Int) -> Curve:
        """Where idea i's branch runs (from its parent)."""
        ref t = self.topics[i]
        return branch_between(self.frame(t.parent), self.frame(i), t.look.curve, t.look.anchors, t.look.source, t.look.target)

    def label_style(self, i: Int) -> TextStyle:
        """The type an idea's words are drawn (and measured) in."""
        ref t = self.topics[i]
        var clean = t.font == "clean" and t.parent >= 0  # (the root is always in the serif: style.css .map-root-label)
        var st = TextStyle("IBM Plex Sans" if clean else SERIF, 700 if t.parent < 0 else (500 if clean else 600), t.look.italic, self.idea_size(i))
        st.exact = True
        return st

    def line_step(self, i: Int) -> Float64:
        return Float64(Int(self.idea_size(i) * 1.2 + 0.5))

    def idea_size(self, i: Int) -> Float64:
        """An idea's words: its own size, else 20 (model.js normalizeDocument: Number(node.fontSize) || 20, the root's too;
        the weight stays 600: style.css's .map-node-label beats the SVG attribute, D-7943)."""
        return self.topics[i].font_size if self.topics[i].font_size > 0 else 20.0

    def frame(self, i: Int) -> Frame:
        var s = self.card_size(i)
        var f = Frame(self.topics[i].x, self.topics[i].y, s[0] / 2, s[1] / 2)
        f.pin = self.topics[i].look.branch and self.topics[i].parent >= 0
        return f

    def fit(self, w: Float64, h: Float64, padding: Float64) -> Tuple[Float64, Float64, Float64]:
        """renderer.js fit(): (scale, x, y) showing every topic (each reaching at least 120 around it); the bounds kept
        by freeze() when there are some."""
        if self.frozen:
            var b = self.bounds
            var sc0 = min(1.35, max(0.45, min((w - padding * 2) / (b[2] - b[0]), (h - padding * 2) / (b[3] - b[1]))))
            return (sc0, w / 2 - (b[0] + b[2]) / 2 * sc0, h / 2 - (b[1] + b[3]) / 2 * sc0)
        var minx = 1e18
        var miny = 1e18
        var maxx = -1e18
        var maxy = -1e18
        for i in range(len(self.topics)):
            if self.hidden(i):
                continue
            var f = self.frame(i)
            var rx = max(120.0, f.hw + 40)
            var ry = max(120.0, f.hh + 40)
            minx = min(minx, f.x - rx)
            miny = min(miny, f.y - ry)
            maxx = max(maxx, f.x + rx)
            maxy = max(maxy, f.y + ry)
        var sc = min(1.35, max(0.45, min((w - padding * 2) / (maxx - minx), (h - padding * 2) / (maxy - miny))))
        return (sc, w / 2 - (minx + maxx) / 2 * sc, h / 2 - (miny + maxy) / 2 * sc)

    def draw[P: Painter](mut self, mut p: P, mut bx: Boxes, x0: Float64, y0: Float64, w: Float64, h: Float64, zoom_in: Float64, sk: Skin, label: String):
        draw_shadows(p, x0, y0, w, h, sk.radius, sk.shadow1, 0.3 * sk.radius + 1)
        draw_radial_steps(p, x0, y0, w, h, 0.48, 0.44, CARD, SHEET, 0.74, sk.radius)  # (.mindmap-stage's background)
        bx.add("map.host", x0, y0, w, h)
        bx.add("map.canvas", x0, y0, w, h)
        bx.add("map.named:" + label, x0, y0, w, h)
        p.push_clip(x0, y0, w, h)
        var fv = self.view(w, h)
        var zoom = fv[0] if zoom_in <= 0 else zoom_in
        var cx = x0 + fv[1]
        var cy = y0 + fv[2]
        # the dot pattern: a dot every 28 map units at (1, 1)
        var dot = with_alpha(hexc("#66736f"), 0.24)
        var step = 28 * zoom
        var gx = cx + (Float64(Int((x0 - cx) / step) - 1) * 28 + 1) * zoom
        while gx < x0 + w:
            var gy = cy + (Float64(Int((y0 - cy) / step) - 1) * 28 + 1) * zoom
            while gy < y0 + h:
                p.circle(gx, gy, zoom, dot)
                gy += step
            gx += step
        # branches under the cards
        for i in range(len(self.topics)):
            var par = self.topics[i].parent
            if par < 0 or self.hidden(i):
                continue
            var d = Float64(self.depth(i))
            var start = max(5.0, 34 / pow(d, 0.82))
            var end = max(3.0, 8 / pow(d, 0.88))
            var g = self.branch_of(i)
            var pts = ribbon_outline(g, start, end, 36)
            for j in range(len(pts) // 2):
                pts[2 * j] = cx + pts[2 * j] * zoom
                pts[2 * j + 1] = cy + pts[2 * j + 1] * zoom
            p.polygon(pts, self.topics[i].color)
        # the selected idea's branch controls (renderer.js renderBranchControls, D-7936): a dotted guide along the branch's
        # centre line (#fffefa, 2 wide, dashes 2 and 5, .8) and its curve's two anchors at t 1/3 and 2/3 (r 6 in its colour,
        # a 2.5 #fffefa ring, the node shadow: 0 5 blur 7 #382f28 at .15)
        var sel = self.selected
        if sel >= 0 and sel < len(self.topics) and self.topics[sel].parent >= 0:
            var g = self.branch_of(sel)
            var guide = with_alpha(hexc("#fffefa"), 0.8)
            var px0 = g.sx
            var py0 = g.sy
            var walked = 0.0  # along the curve, map units
            var on = True
            var mark_x = px0
            var mark_y = py0
            for q in range(1, 241):
                var t = Float64(q) / 240
                var qx = _axis(g.sx, g.ax, g.bx, g.ex, t, 0)
                var qy = _axis(g.sy, g.ay, g.by, g.ey, t, 0)
                walked += sqrt((qx - px0) * (qx - px0) + (qy - py0) * (qy - py0))
                if on and walked >= 2:
                    p.line(cx + mark_x * zoom, cy + mark_y * zoom, cx + qx * zoom, cy + qy * zoom, 2 * zoom, guide)
                    on = False
                    walked = 0
                elif not on and walked >= 5:
                    on = True
                    walked = 0
                    mark_x = qx
                    mark_y = qy
                px0 = qx
                py0 = qy
            for k in range(2):
                var t = 1.0 / 3.0 if k == 0 else 2.0 / 3.0
                var hx = cx + _axis(g.sx, g.ax, g.bx, g.ex, t, 0) * zoom
                var hy = cy + _axis(g.sy, g.ay, g.by, g.ey, t, 0) * zoom
                var r = 6 * zoom
                _drop_disc(p, hx, hy, r + 1.25 * zoom, 5 * zoom, 7 * zoom, 1.6 * r)
                p.circle(hx, hy, r + 1.25 * zoom, hexc("#fffefa"))
                p.circle(hx, hy, r - 1.25 * zoom, self.topics[sel].color)
                bx.add("map.anchor:" + self.topics[sel].text, hx - 18 * zoom, hy - 18 * zoom, 36 * zoom, 36 * zoom)
        # cards and words
        var tasks = self.tasks()
        for i in range(len(self.topics)):
            if self.hidden(i):
                continue
            ref t = self.topics[i]
            var root = t.parent < 0
            var branch = t.look.branch and not root
            var l = self.layout(i)
            var w2 = l.w * zoom
            var h2 = l.h * zoom
            var lx = cx + t.x * zoom - w2 / 2
            var ly = cy + t.y * zoom - h2 / 2
            var st = self.label_style(i)
            st.size *= zoom
            var n = len(l.lines)
            var size = self.idea_size(i)
            # where the words stand (renderer.js labelPlace): a box's middle, or resting on the middle of its branch
            var lab_x = t.x
            var lab_y = t.y + 1
            if branch:
                var m = curve_mid(self.branch_of(i))
                lab_x = m[0]
                lab_y = m[1] - 5
            var row0 = lab_y - Float64(n - 1) * l.step - size * 0.32 if branch else lab_y - Float64(n - 1) * l.step / 2  # (the first line's middle)
            var ex = 0.5 * 0.52 if st.family == "IBM Plex Sans" else 0.5 * 0.475  # (dominant-baseline: middle: half an x-height)
            var base0 = lab_y - Float64(n - 1) * l.step if branch else row0 + ex * size
            if branch:
                bx.add("map.idea:" + t.text, cx + (lab_x - l.w / 2) * zoom, cy + (lab_y - l.h + 5) * zoom, w2, h2)
            elif root:
                # the group's box reaches the add handles: 18 beyond the card plus a handle's 17 hit circle
                var reach_x = (l.w / 2 + 18 + 17.33) * zoom
                var reach_y = (l.h / 2 + 18 + 17.33) * zoom
                bx.add("map.idea:" + t.text, cx + t.x * zoom - reach_x, cy + t.y * zoom - reach_y, 2 * reach_x, 2 * reach_y)
            else:
                bx.add("map.idea:" + t.text, lx - 5 * zoom, ly - 5 * zoom, w2 + 10 * zoom, h2 + 10 * zoom)  # (the group holds its hidden selection rect)
            if i == self.editing:
                continue  # (the box it is written in goes over all of them, below)
            if t.look.image:  # (its picture's place: 88 × 68 in a white frame, above the card; the picture itself isn't decoded here)
                var ix = cx + (t.x + (-45.0 if root else (-2.0 if t.x >= 0 else -88.0))) * zoom
                var iy = cy + (t.y - (132.0 if root else 102.0)) * zoom
                _drop(p, ix, iy, 88 * zoom, 68 * zoom, 0, 5 * zoom, 14 * zoom, 26 * zoom, 20 * zoom)
                p.rect(ix - 4 * zoom, iy - 4 * zoom, 96 * zoom, 76 * zoom, rgba(255, 255, 255), 6 * zoom)
                p.rect(ix, iy, 88 * zoom, 68 * zoom, hexc("#e6e1d5"), 2 * zoom)
                draw_icon(p, "image", ix + 32 * zoom, iy + 22 * zoom, 24 * zoom, 1.6, with_alpha(LABEL, 0.45))
            if root:
                # (filter url(#mindmap-node-shadow): 0 5 and σ 7, #382f28 at .15, inside the filter's region: 30 % past the card)
                _drop(p, lx, ly, w2, h2, 20 * zoom, 5 * zoom, 14 * zoom, 0.3 * w2, 0.3 * h2)
                p.rect(lx, ly, w2, h2, t.color, 20 * zoom)
                _smile(p, cx + t.x * zoom, cy + t.y * zoom, l.w, l.h, zoom)
            elif not branch:
                var sh = List[Shadow]()
                sh.append(Shadow(0, 3, 7, 0, rgba(57, 48, 37, 20)))
                draw_shadows(p, lx, ly, w2, h2, 6 * zoom, sh)
                draw_bordered(p, lx - 1, ly - 1, w2 + 2, h2 + 2, 6 * zoom + 1, CARD, t.color, 2)
            var mid = cx + (lab_x + (l.lead - l.trail) / 2) * zoom
            var color = rgba(255, 255, 255) if root else LABEL
            if t.look.done:
                color = with_alpha(color, 0.55)
            for q in range(n):
                var by = cy + (base0 + Float64(q) * l.step) * zoom
                if branch:  # (paint-order: stroke: the sheet's colour round the letters, so they read over a branch)
                    var halo = with_alpha(rgba(255, 255, 255), 0.96) if i == self.selected else with_alpha(SHEET, 0.86)
                    _halo(p, st, l.lines[q], mid, by, (2.5 if i == self.selected else 2.0) * zoom, halo)
                p.run(st, l.lines[q], mid, by, color, ALIGN_CENTER)
            if t.look.done:  # (the pencil through its words: .8 of #4a4d52)
                var seed_id = t.id if t.id != "" else t.text
                for q in range(n):
                    var half = l.widths[q] / 2
                    var ox = lab_x + (l.lead - l.trail) / 2
                    var pts = pencil_outline(ox - half - 4, ox + half + 4, row0 + Float64(q) * l.step, seed_of(seed_id + String(q)))
                    for z in range(0, len(pts), 2):
                        pts[z] = cx + pts[z] * zoom
                        pts[z + 1] = cy + pts[z + 1] * zoom
                    p.polygon(pts, with_alpha(hexc("#4a4d52"), 0.8))
            var block = lab_x - (l.lead + l.text_w + l.trail) / 2
            for q in range(len(l.icons)):
                draw_icon(p, icon_path(l.icons[q]), cx + (block + Float64(q) * (l.icon + 4)) * zoom, cy + (row0 - l.icon / 2) * zoom, l.icon * zoom, 1.6, rgba(255, 255, 255) if root else t.color)
            if l.chip != "":
                var fill = hexc("#fde7b0") if l.chip_state == DUE_TODAY else (hexc("#fbd3cd") if l.chip_state == DUE_OVER else CARD)
                var ink = hexc("#7a4f00") if l.chip_state == DUE_TODAY else (hexc("#9c2418") if l.chip_state == DUE_OVER else hexc("#746f65"))
                var edge = hexc("#e0a526") if l.chip_state == DUE_TODAY else (hexc("#e0675a") if l.chip_state == DUE_OVER else hexc("#cfc8ba"))
                var chx = cx + (block + l.lead + l.text_w + l.trail - l.chip_w) * zoom
                draw_bordered(p, chx - 0.5 * zoom, cy + (row0 - 10.5) * zoom, (l.chip_w + 1) * zoom, 21 * zoom, 10.5 * zoom, fill, edge, zoom)
                var cst = chip_style()
                cst.size *= zoom
                p.run(cst, l.chip, chx + l.chip_w / 2 * zoom, cy + (row0 + 11 * 0.349) * zoom, ink, ALIGN_CENTER)  # (dominant-baseline: central)
                bx.add("map.due:" + l.chip, chx, cy + (row0 - 10) * zoom, l.chip_w * zoom, 20 * zoom)
            # its badges: to-dos done, ideas folded away, a vote
            var box_l = lab_x - l.w / 2 if branch else t.x - l.w / 2
            var box_t = lab_y - l.h + 5 if branch else t.y - l.h / 2
            if tasks[2 * i + 1] > 0:
                var all_done = tasks[2 * i] == tasks[2 * i + 1]
                var words = String(tasks[2 * i]) + "/" + String(tasks[2 * i + 1])
                var bw = 22.0 if all_done else Float64(words.byte_length()) * 6.6 + 12
                var bxx = cx + box_l * zoom
                var byy = cy + box_t * zoom
                draw_bordered(p, bxx - (bw / 2 + 0.75) * zoom, byy - 9.75 * zoom, (bw + 1.5) * zoom, 19.5 * zoom, 9.75 * zoom, hexc("#2f8f5b") if all_done else CARD, hexc("#2f8f5b") if all_done else t.color, 1.5 * zoom)
                if all_done:
                    p.polygon(stroke_outline([bxx - 4.5 * zoom, byy + 0.5 * zoom, bxx - 1.5 * zoom, byy + 3.5 * zoom, bxx + 4.5 * zoom, byy - 3 * zoom], 2 * zoom), rgba(255, 255, 255))
                else:
                    var bst = TextStyle("IBM Plex Mono", 700, False, 10.5 * zoom)
                    bst.exact = True
                    p.run(bst, words, bxx, byy + 10.5 * 0.349 * zoom, hexc("#4d504a"), ALIGN_CENTER)
                bx.add("map.tasks:" + words, bxx - bw / 2 * zoom, byy - 9 * zoom, bw * zoom, 18 * zoom)
            if t.look.collapsed and self.under(i) > 0:
                var count = String(self.under(i))
                var ox = cx + (t.x + (0.0 if root else (10.0 if t.x >= 0 else -10.0))) * zoom
                var oy = cy + (t.y + 18) * zoom
                p.circle(ox, oy, 12 * zoom, t.color)
                p.circle(ox, oy, 10 * zoom, CARD)
                var bst = TextStyle("IBM Plex Sans", 700, False, 10 * zoom)
                bst.exact = True
                p.run(bst, count, ox, oy + 10 * 0.349 * zoom, t.color, ALIGN_CENTER)
                bx.add("map.folded:" + count, ox - 11 * zoom, oy - 11 * zoom, 22 * zoom, 22 * zoom)
            if t.look.vote != "":
                var vx = cx + (t.x + l.w / 2 - 4) * zoom if root else cx + (lab_x + l.w / 2) * zoom
                var vy = cy + (t.y - l.h / 2) * zoom if not branch else cy + (lab_y - l.h / 2) * zoom
                p.circle(vx, vy, 14 * zoom, t.color)
                p.circle(vx, vy, 12 * zoom, CARD)
                var est = TextStyle("emoji", 400, False, 15 * zoom)
                est.exact = True
                p.run(est, "👍" if t.look.vote == "up" else "👎", vx, vy + zoom + 15 * 0.36 * zoom, rgba(0, 0, 0), ALIGN_CENTER)
                bx.add("map.vote:" + t.look.vote, vx - 13 * zoom, vy - 13 * zoom, 26 * zoom, 26 * zoom)
        # the selection: dashed ring and four add handles (gone while the idea is written: .map-node.editing)
        if self.selected >= 0 and self.selected < len(self.topics) and self.selected != self.editing and not self.hidden(self.selected):
            ref t = self.topics[self.selected]
            var s = self.card_size(self.selected)
            var root = t.parent < 0
            var branch = t.look.branch and not root
            var pad = 7.0 if root else 5.0
            if branch:
                var m = curve_mid(self.branch_of(self.selected))
                _dashed_rect(p, cx + (m[0] - s[0] / 2) * zoom, cy + (m[1] - 5 - s[1] + 5) * zoom, s[0] * zoom, s[1] * zoom, 5 * zoom, 1.5 * zoom, 4 * zoom)
            else:
                _dashed_rect(p, cx + (t.x - s[0] / 2 - pad) * zoom, cy + (t.y - s[1] / 2 - pad) * zoom, (s[0] + 2 * pad) * zoom, (s[1] + 2 * pad) * zoom,
                             (24.0 if root else 9.0) * zoom, 1.5 * zoom, 4 * zoom)
            var hx: List[Float64] = [0, s[0] / 2 + 18, 0, -(s[0] / 2 + 18)]
            var hy: List[Float64] = [-(s[1] / 2 + 18), 0, s[1] / 2 + 18, 0]
            var names: List[String] = ["top", "right", "bottom", "left"]
            var only = -1  # (a branch's words have one handle, outward)
            if branch:
                only = 1 if t.x >= self.topics[t.parent].x else 3
                hx = [0, 22, 0, -22]
                hy = [0, 5, 0, 5]
            for k in range(4):
                if only >= 0 and k != only:
                    continue
                var ax = cx + (t.x + hx[k]) * zoom
                var ay = cy + (t.y + hy[k]) * zoom
                _drop_disc(p, ax, ay, 8.25 * zoom, 5 * zoom, 7 * zoom, 11.2 * zoom)
                p.circle(ax, ay, 8.25 * zoom, CARD)  # (r 7, stroked 2.5 in the card colour)
                p.circle(ax, ay, 5.75 * zoom, t.color)
                p.circle(ax, ay, 2 * zoom, CARD)
                bx.add("map.add-branch:" + names[k], ax - 17 * zoom, ay - 17 * zoom, 34 * zoom, 34 * zoom)
        if self.editing >= 0 and self.editing < len(self.topics):
            # the box the idea is written in (.mindmap-node-editor), over its card
            var i = self.editing
            var b = self.edit_box(i)
            var ex0 = cx + b[0] * zoom
            var ey0 = cy + b[1] * zoom
            var ew = max(100.0, b[2] * zoom)
            var eh = max(38.0, b[3] * zoom)
            var sh = List[Shadow]()
            sh.append(Shadow(0, 5, 16, 0, rgba(57, 48, 37, 38)))
            draw_shadows(p, ex0, ey0, ew, eh, 6, sh)
            draw_bordered(p, ex0, ey0, ew, eh, 6, CARD, self.topics[i].color, 2)
            bx.add("map.editor", ex0, ey0, ew, eh)
            self.pen.style = self.edit_style(i)
            self.pen.width = (ew - 20) / zoom
            self.pen.lay()
            var step = self.line_step(i)
            var top = ey0 + 2 + (eh - Float64(len(self.pen.lines)) * step * zoom) / 2
            var m = line_metrics(self.pen.style)
            self.pen_scroll = self.pen.follow(self.pen_scroll, step)
            var px0 = ex0 + 10 - self.pen_scroll * zoom
            p.push_clip(ex0 + 2, ey0 + 2, ew - 4, eh - 4)
            self.pen.paint(p, px0, top, step, (step - Float64(m.ascent + m.descent)) / 2 + Float64(m.ascent), zoom, LABEL, True)
            p.pop_clip()
            var c = self.pen.caret_at(step)
            self.edit_caret = (px0 + c[0] * zoom, top + c[1] * zoom, 1.5, step * zoom)
        p.pop_clip()


def _drop[P: Painter](mut p: P, x: Float64, y: Float64, w: Float64, h: Float64, r: Float64, dy: Float64, blur: Float64, past_x: Float64, past_y: Float64):
    """An SVG drop shadow (#382f28 at .15) cut where its filter's region ends, past_x and past_y outside the box."""
    var sh = List[Shadow]()
    sh.append(Shadow(0, dy, blur, 0, rgba(56, 47, 40, 38)))
    p.push_clip(x - past_x, y - past_y, w + 2 * past_x, h + 2 * past_y)
    draw_shadows(p, x, y, w, h, r, sh)
    p.pop_clip()


def disc_shadow(r: Float64, sigma: Float64, at: Float64) -> Float64:
    """How dark a disc of radius r blurred by a Gaussian is, `at` from its middle (1: all of the shadow's colour). A shadow
    as wide as its disc never gets there: 8 px blurred by 7 is 0.5 in the middle."""
    var sum = 0.0
    comptime N = 24
    for i in range(N):  # (the disc in rings: a ring at u adds u/σ² · e^(−(u²+at²)/2σ²) · I0(u·at/σ²))
        var u = r * (Float64(i) + 0.5) / N
        var z = u * at / (sigma * sigma)
        var term = 1.0
        var bessel = 1.0
        for k in range(1, 16):
            term *= (z / 2) * (z / 2) / Float64(k * k)
            bessel += term
        sum += u / (sigma * sigma) * exp(-(u * u + at * at) / (2 * sigma * sigma)) * bessel * r / N
    return sum


def _drop_disc[P: Painter](mut p: P, x: Float64, y: Float64, r: Float64, dy: Float64, sigma: Float64, past: Float64):
    """The same drop shadow under a disc, cut to a square `past` around its middle."""
    p.push_clip(x - past, y - past, 2 * past, 2 * past)
    var far = past * 1.4143 + dy
    comptime N = 14
    comptime SIDES = 40
    # (rings that don't overlap, each at its own darkness: thin layers over each other round away on an 8-bit screen)
    for j in range(N):
        var r1 = far * Float64(j + 1) / N
        var r0 = far * Float64(j) / N
        var pts = List[Float64]()
        for q in range(SIDES + 1):
            var a = 6.283185307179586 * Float64(q) / SIDES
            pts.append(x + r1 * cos(a))
            pts.append(y + dy + r1 * sin(a))
        if j > 0:
            for q in range(SIDES, -1, -1):
                var a = 6.283185307179586 * Float64(q) / SIDES
                pts.append(x + r0 * cos(a))
                pts.append(y + dy + r0 * sin(a))
        p.polygon(pts, with_alpha(rgba(56, 47, 40), 0.15 * disc_shadow(r, sigma, (r0 + r1) / 2)))
    p.pop_clip()


def wrap_text(text: String, limit: Int = 28) -> List[String]:
    """layout.js wrapText: broken at word ends past `limit` letters (UTF-16 units, as JavaScript counts), a longer word cut."""
    var lines = List[String]()
    var line = String("")
    var line_n = 0
    for wd in text.split():
        var word = String(wd)
        var n = utf16_len(word)
        while n > limit:
            if line != "":
                lines.append(line)
                line = ""
                line_n = 0
            var cut = 0
            var units = 0
            while cut < word.byte_length():
                var next = next_grapheme(word, cut)  # (whole characters; JavaScript would cut one in two)
                var u = utf16_len(String(word[byte=cut:next]))
                if units + u > limit and cut > 0:
                    break
                units += u
                cut = next
            lines.append(String(word[byte=0:cut]))
            var rest = String(word[byte=cut:word.byte_length()])
            word = rest
            n = utf16_len(word)
            if n == 0:
                break
        if n == 0:
            continue
        if line != "" and line_n + 1 + n > limit:
            lines.append(line)
            line = word
            line_n = n
        elif line != "":
            line += " " + word
            line_n += 1 + n
        else:
            line = word
            line_n = n
    if line != "":
        lines.append(line)
    if len(lines) == 0:
        lines.append("")
    return lines^


def utf16_len(s: String) -> Int:
    var n = 0
    for b in s.as_bytes():
        if (b & 0xC0) != 0x80:
            n += 2 if b >= 0xF0 else 1
    return n


def _halo[P: Painter](mut p: P, st: TextStyle, words: String, x: Float64, base: Float64, r: Float64, color: UInt32):
    """Words' outline in a colour of their own, r wide all round (an SVG text stroke painted first)."""
    var solid = with_alpha(color, 1.0)
    comptime N = 12
    for q in range(N):
        var a = 6.283185307179586 * Float64(q) / N
        p.run(st, words, x + r * cos(a), base + r * sin(a), solid, ALIGN_CENTER)


def _smile[P: Painter](mut p: P, cx: Float64, cy: Float64, w: Float64, h: Float64, z: Float64):
    """The root card's highlight: a quadratic from the lower left to the lower right, white at .23, 5 wide."""
    var x0 = -w / 2 + 18
    var y0 = h / 2 - 14
    var qx = 0.0
    var qy = h / 2 - 4
    var x1 = w / 2 - 18
    var y1 = h / 2 - 18
    var pts = List[Float64]()
    comptime N = 24
    for i in range(N + 1):
        var t = Float64(i) / N
        var u = 1 - t
        pts.append(cx + (u * u * x0 + 2 * u * t * qx + t * t * x1) * z)
        pts.append(cy + (u * u * y0 + 2 * u * t * qy + t * t * y1) * z)
    p.polygon(stroke_outline(pts, 5 * z), rgba(255, 255, 255, 59))


def _dashed_rect[P: Painter](mut p: P, x: Float64, y: Float64, w: Float64, h: Float64, r: Float64, sw: Float64, dash: Float64):
    """A rounded rect's outline in dashes (dash on, dash off), as SVG draws it: from the top side's left end, clockwise
    through the corners' arcs."""
    var arc = r * 1.5707963267948966
    var runs: List[Float64] = [w - 2 * r, arc, h - 2 * r, arc, w - 2 * r, arc, h - 2 * r, arc]
    var total = 0.0
    for v in runs:
        total += v
    var t = 0.0
    while t < total:
        var t1 = min(t + dash, total)
        # (each dash one polygon with square ends, as a CSS dash; bent in pieces round a corner)
        var pieces = 1 if r == 0 else max(1, Int((t1 - t) / 2 + 0.999))
        var out = List[Float64]()
        var back = List[Float64]()
        for k in range(pieces + 1):
            var u = t + (t1 - t) * Float64(k) / Float64(pieces)
            var c = _round_at(x, y, w, h, r, runs, u)
            var a = _round_at(x, y, w, h, r, runs, max(u - 0.5, 0.0))
            var b = _round_at(x, y, w, h, r, runs, min(u + 0.5, total))
            var l = sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]))
            var nx = -(b[1] - a[1]) / l * sw / 2
            var ny = (b[0] - a[0]) / l * sw / 2
            out.append(c[0] + nx)
            out.append(c[1] + ny)
            back.append(c[0] - nx)
            back.append(c[1] - ny)
        for k in range(pieces, -1, -1):
            out.append(back[2 * k])
            out.append(back[2 * k + 1])
        p.polygon(out, RING)
        t += 2 * dash


def _round_at(x: Float64, y: Float64, w: Float64, h: Float64, r: Float64, runs: List[Float64], at: Float64) -> Tuple[Float64, Float64]:
    """The point `at` px along a rounded rect's outline (runs: its eight pieces' lengths)."""
    var t = at
    var k = 0
    while k < 7 and t > runs[k]:
        t -= runs[k]
        k += 1
    if k == 0:
        return (x + r + t, y)
    if k == 2:
        return (x + w, y + r + t)
    if k == 4:
        return (x + w - r - t, y + h)
    if k == 6:
        return (x, y + h - r - t)
    var a = t / r if r > 0 else 0.0
    if k == 1:
        return (x + w - r + r * sin(a), y + r - r * cos(a))
    if k == 3:
        return (x + w - r + r * cos(a), y + h - r + r * sin(a))
    if k == 5:
        return (x + r - r * sin(a), y + h - r + r * cos(a))
    return (x + r - r * cos(a), y + r - r * sin(a))


def branch_geometry(parent: Frame, child: Frame, curve: Float64 = 78) -> Curve:
    """A branch with no sides or anchors of its own (mapmarks.branch_between)."""
    return branch_between(parent, child, curve)


def _axis(a: Float64, b: Float64, c: Float64, d: Float64, t: Float64, order: Int) -> Float64:
    var u = 1 - t
    if order == 0:
        return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d
    if order == 1:
        return 3 * (u * u * (b - a) + 2 * u * t * (c - b) + t * t * (d - c))
    return 6 * (u * (c - 2 * b + a) + t * (d - 2 * c + b))


def ribbon_outline(g: Curve, start: Float64, end: Float64, samples: Int) -> List[Float64]:
    """geometry.js ribbonOutline: the centre line offset along its normal, the width falling from start to end and never
    wider than the bend allows (1.8 / curvature); the outline as x, y pairs (one side out, the other back)."""
    var left = List[Float64]()
    var right = List[Float64]()
    var previous = 1e18
    for i in range(samples + 1):
        var t = Float64(i) / Float64(samples)
        var px = _axis(g.sx, g.ax, g.bx, g.ex, t, 0)
        var py = _axis(g.sy, g.ay, g.by, g.ey, t, 0)
        var dx = _axis(g.sx, g.ax, g.bx, g.ex, t, 1)
        var dy = _axis(g.sy, g.ay, g.by, g.ey, t, 1)
        var speed = sqrt(dx * dx + dy * dy)
        var curvature = abs(dx * _axis(g.sy, g.ay, g.by, g.ey, t, 2) - dy * _axis(g.sx, g.ax, g.bx, g.ex, t, 2)) / (speed * speed * speed)
        var cap = 1.8 / curvature if curvature > 0 else 1e18
        previous = min(start + (end - start) * t, max(end, cap), previous)
        var nx = (-dy / speed) * previous / 2
        var ny = (dx / speed) * previous / 2
        left.append(px + nx)
        left.append(py + ny)
        right.append(px - nx)
        right.append(py - ny)
    var out = left^
    var i = samples
    while i >= 0:
        out.append(right[2 * i])
        out.append(right[2 * i + 1])
        i -= 1
    return out^


def draw_minimap[P: Painter](m: BuzanMap, mut p: P, mut bx: Boxes, x: Float64, y: Float64, view_w: Float64, view_h: Float64, sk: Skin):
    """The map's overview (170 × 102, padded 6): every topic as a dot in its colour and the visible part as a teal frame,
    in a 220 × 130 box fitted into it (editor.js updateMinimap)."""
    p.rect(x, y, 170, 102, sk.panel, sk.radius_control)  # (the surface, no edge, no shadow: workspace-theme.css)
    bx.add("map.overview", x, y, 170, 102)
    var vs = min(158.0 / 220, 90.0 / 130)
    var ox = x + 6 + (158 - 220 * vs) / 2
    var oy = y + 6 + (90 - 130 * vs) / 2
    var minx = 1e18
    var miny = 1e18
    var maxx = -1e18
    var maxy = -1e18
    for i in range(len(m.topics)):
        if m.hidden(i):
            continue
        var f = m.frame(i)
        var rx = max(120.0, f.hw + 40)
        var ry = max(120.0, f.hh + 40)
        minx = min(minx, f.x - rx)
        miny = min(miny, f.y - ry)
        maxx = max(maxx, f.x + rx)
        maxy = max(maxy, f.y + ry)
    var sc = min(200 / max(1.0, maxx - minx), 110 / max(1.0, maxy - miny))
    var offx = 110 - (minx + maxx) / 2 * sc
    var offy = 65 - (miny + maxy) / 2 * sc
    var fv = m.view(view_w, view_h)
    var vx = (-fv[1] / fv[0]) * sc + offx
    var vy = (-fv[2] / fv[0]) * sc + offy
    var vw = view_w / fv[0] * sc
    var vh = view_h / fv[0] * sc
    var teal = hexc("#247c73")
    p.push_clip(x + 6, y + 6, 158, 90)  # (the drawing's own box)
    p.rect(ox + vx * vs, oy + vy * vs, vw * vs, vh * vs, teal, 0)
    var sw = 1.5 * vs
    p.rect(ox + vx * vs + sw / 2, oy + vy * vs + sw / 2, vw * vs - sw, vh * vs - sw, sk.panel, 0)
    p.rect(ox + vx * vs + sw / 2, oy + vy * vs + sw / 2, vw * vs - sw, vh * vs - sw, with_alpha(teal, 0.05), 0)
    for i in range(len(m.topics)):
        ref t = m.topics[i]
        p.circle(ox + (t.x * sc + offx) * vs, oy + (t.y * sc + offy) * vs, (4.0 if t.parent < 0 else 2.0) * vs, t.color)
    p.pop_clip()


def map_json(m: BuzanMap, title: String, root_id: String) -> String:
    """The map as Personal Note stores it ({version, title, rootId, nodes: [{id, parentId, text, x, y, color, …}]})."""
    var out = '{"version":1,"title":' + json_string(title) + ',"rootId":' + json_string(root_id) + ',"nodes":['
    for i in range(len(m.topics)):
        ref t = m.topics[i]
        if i > 0:
            out += ","
        var pid = String("null") if t.parent < 0 else json_string(m.topics[t.parent].id)
        out += '{"id":' + json_string(t.id) + ',"parentId":' + pid + ',"text":' + json_string(t.text) + ',"x":' + _jnum(t.x) + ',"y":' + _jnum(t.y)
        out += ',"color":"' + _hexs(t.color) + '"'
        if t.font_size > 0:
            out += ',"fontSize":' + _jnum(t.font_size) + ',"bold":' + ("true" if t.bold else "false")
        if t.font != "":
            out += ',"font":' + json_string(t.font)
            if t.extra.find('"presentation":') < 0:
                out += ',"presentation":"box","curve":78'
        if t.extra != "":
            out += "," + t.extra
        out += "}"
    return out + "]}"


def _topic_json(m: BuzanMap, i: Int) -> String:
    """An idea made here as the document stores one."""
    ref t = m.topics[i]
    var pid = String("null") if t.parent < 0 else json_string(m.topics[t.parent].id)
    var out = '{"id":' + json_string(t.id) + ',"parentId":' + pid + ',"text":' + json_string(t.text) + ',"x":' + _jnum(t.x) + ',"y":' + _jnum(t.y)
    out += ',"color":"' + _hexs(t.color) + '"'
    if t.font_size > 0:
        out += ',"fontSize":' + _jnum(t.font_size) + ',"bold":' + ("true" if t.bold else "false")
    if t.font != "":
        out += ',"font":' + json_string(t.font)
        if t.extra.find('"presentation":') < 0:
            out += ',"presentation":"box","curve":78'
    if t.extra != "":
        out += "," + t.extra
    return out + "}"


def map_json_from(m: BuzanMap, source: String, title: String, root_id: String) raises -> String:
    """The map as it is saved when it was read from `source` (review 3): that text with what was edited changed: an idea
    nobody touched is its own text (due times, pictures, keys nobody here knows, their order), an edited one has the
    members it changed replaced, one made here is appended, one deleted is gone; every other top-level member as it was."""
    if source == "":
        return map_json(m, title, root_id)
    var j = Json.parse(source)
    var ms = members(source, 0, source.byte_length())
    var n = find_member(ms, "nodes")
    if n < 0:
        return map_json(m, title, root_id)
    var spans = elements(source, ms[n].start, ms[n].end)
    var at = Dict[String, Int]()
    var nodes = j.get(0, "nodes")
    for q in range(j.size(nodes)):
        at[j.text(j.get(j.at(nodes, q), "id"))] = q
    var out = List[String]()
    for i in range(len(m.topics)):
        ref t = m.topics[i]
        var q = at.get(t.id, -1)
        if q < 0:
            out.append(_topic_json(m, i))
            continue
        var nd = j.at(nodes, q)
        var raw = part(source, spans[q].start, spans[q].end)
        var ch = List[Change]()
        var pid = String("") if t.parent < 0 else m.topics[t.parent].id
        var had = j.text(j.get(nd, "parentId"))
        if had != pid and not (pid == "" and had not in at):  # (an orphan's parent, whoever that was, stays written)
            ch.append(Change("parentId", "null" if pid == "" else json_string(pid)))
        if j.text(j.get(nd, "text")) != t.text:
            ch.append(Change("text", json_string(t.text)))
        if j.real(j.get(nd, "x")) != t.x:
            ch.append(Change("x", _jnum(t.x)))
        if j.real(j.get(nd, "y")) != t.y:
            ch.append(Change("y", _jnum(t.y)))
        if hexc(j.text(j.get(nd, "color"), "#3d8fe8")) != t.color:
            ch.append(Change("color", '"' + _hexs(t.color) + '"'))
        if j.real(j.get(nd, "fontSize"), 0) != t.font_size:
            ch.append(Change("fontSize", _jnum(t.font_size)))
        if j.flag(j.get(nd, "bold")) != t.bold:
            ch.append(Change("bold", "true" if t.bold else "false"))
        if j.text(j.get(nd, "font")) != t.font:
            ch.append(Change("font", json_string(t.font)))
        out.append(patched(raw, ch))
    # (as it stands: the very text, spaces and all)
    var same = len(out) == len(spans)
    if same:
        for q in range(len(spans)):
            if out[q] != part(source, spans[q].start, spans[q].end):
                same = False
                break
    if same:
        return source
    var ch = List[Change]()
    ch.append(Change("nodes", "[" + ",".join(out) + "]"))
    if j.text(j.get(0, "rootId"), "root") != root_id:
        ch.append(Change("rootId", json_string(root_id)))
    return patched(source, ch)


def node_extra(j: Json, node: Int) -> String:
    """The members of a stored idea that BuzanMap doesn't model (due, done, image, presentation, …) as `"k":v,…`, so a
    save writes back what another app put there instead of dropping it."""
    var out = String("")
    var known_keys: List[String] = ["id", "parentId", "text", "x", "y", "color", "fontSize", "bold", "font"]
    for i in range(j.size(node)):
        var k = j.key(node, i)
        var known = False
        for ref kk in known_keys:
            if kk == k:
                known = True
        if known:
            continue
        if out != "":
            out += ","
        out += json_string(k) + ":" + j.dump(j.at(node, i))
    return out^


def _jnum(v: Float64) -> String:
    if v == Float64(Int(v)):
        return String(Int(v))
    return String(v)


def _hexs(c: UInt32) -> String:
    var digits = "0123456789abcdef"
    var out = String("#")
    for sh in [0, 8, 16]:
        var v = Int((c >> UInt32(sh)) & 0xFF)
        out += String(digits[byte=v // 16:v // 16 + 1]) + String(digits[byte=v % 16:v % 16 + 1])
    return out^


def map_text(m: BuzanMap) -> String:
    """What a search index should hold for a map: every idea's words, space-joined, in stored order (D-7927)."""
    var out = String("")
    for i in range(len(m.topics)):
        if i > 0:
            out += " "
        out += m.topics[i].text
    return out^
