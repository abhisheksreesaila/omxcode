# mojoui.buzanmap (goal 79): a Tony Buzan mind map drawn the way Personal Note's web map draws it, as a generic view of
# any tree of topics: organic one-bend branches as tapered ribbons in each branch's colour (width falls with depth and is
# capped by the bend), ideas on white cards with a coloured edge, the central topic as a filled card with a soft
# highlight, the dashed selection ring and the four add handles, on a dotted sheet. The geometry is the web's own
# (geometry.js: attach, branchGeometry, ribbonOutline; layout.js: card sizes), so a map saved by either looks the same.
#
#   var m = BuzanMap(); m.add(-1, "The book", 0, 0, color); m.add(0, "Characters", 280, -130, color2) …
#   m.draw(p, bx, x0, y0, w, h, zoom, sk)        # the view centred on the map's origin

from std.math import sqrt, tanh, pow
from mojoui.graphemes import without_last, typed_text
from mojoui.scene import Painter
from mojoui.skin import Skin, Shadow, with_alpha, hexc
from mojoui.fonttext import TextStyle, measure, ALIGN_CENTER
from mojoui.notesshell import Boxes, draw_lifted, draw_shadows, draw_bordered, draw_radial_steps
from mojoui.canvas import rgba
from mojoui.shared import new_key
from mojoui.jsonpatch import Change, patched, members, elements, find_member, part
from mojoui.json import Json, json_string

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


comptime BRANCH_COLORS: List[String] = ["#ef684b", "#efad28", "#65ae4f", "#2d9c91", "#3d8fe8", "#8c67cf", "#d85da8", "#5e6570"]


@fieldwise_init
struct Frame(ImplicitlyCopyable, Movable):
    var x: Float64
    var y: Float64
    var hw: Float64
    var hh: Float64


struct BuzanMap(Movable):
    var topics: List[Topic]
    var selected: Int
    var editing: Int  # the idea whose words are being written (-1: none)
    var edit_text: String
    var edit_all: Bool  # its words are all selected (typing replaces them), as the web's editor opens
    var made: Int  # ideas made here (for their ids)
    var frozen: Bool  # the view's bounds are the ones the map opened with (adding ideas never re-fits it)
    var bounds: Tuple[Float64, Float64, Float64, Float64]

    def __init__(out self):
        self.topics = List[Topic]()
        self.selected = 0
        self.editing = -1
        self.edit_text = ""
        self.edit_all = False
        self.made = 0
        self.frozen = False
        self.bounds = (0.0, 0.0, 0.0, 0.0)

    def add(mut self, parent: Int, text: String, x: Float64, y: Float64, color: UInt32, id: String = "", font_size: Float64 = 0,
            bold: Bool = False, font: String = "", extra: String = "") -> Int:
        self.topics.append(Topic(parent, text, x, y, color, id, font_size, bold, font, extra))
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
        self.begin_edit(i)
        return i

    def begin_edit(mut self, i: Int):
        if i < 0 or i >= len(self.topics):
            return
        self.editing = i
        self.edit_text = self.topics[i].text
        self.edit_all = True

    def edit_key(mut self, name: String, mods: Int) -> Int:
        """A key while an idea is being written: 0 not its key, 1 the words changed, 2 Enter (kept), 3 Escape (dropped)."""
        if self.editing < 0:
            return 0
        if name == "Enter":
            var t = String(" ".join(self.edit_text.split()))
            if t != "":
                self.topics[self.editing].text = t
            self.editing = -1
            return 2
        if name == "Escape":
            self.editing = -1
            return 3
        if (mods & 2) != 0:
            if name == "a" or name == "A":
                self.edit_all = True
                return 1
            return 0
        if name == "Backspace":
            if self.edit_all:
                self.edit_text = ""
            else:
                self.edit_text = without_last(self.edit_text)
            self.edit_all = False
            return 1
        if typed_text(name):
            if self.edit_all:
                self.edit_text = ""
                self.edit_all = False
            self.edit_text += name
            return 1
        return 0

    def freeze(mut self):
        """Keeps the bounds the map has now as the ones its view fits (the web fits a map once, as it opens)."""
        var minx = 1e18
        var miny = 1e18
        var maxx = -1e18
        var maxy = -1e18
        for i in range(len(self.topics)):
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

    def card_size(self, i: Int) -> Tuple[Float64, Float64]:
        """layout.js: the root max(180, words + 50) × 76; an idea max(58, words) + 26 × (20 + 20)."""
        if self.topics[i].parent < 0:
            var st = TextStyle(SERIF, 700, False, 28)
            st.exact = True
            return (max(180.0, measure(st, self.topics[i].text) + 50), 76.0)
        var size = self.idea_size(i)
        var st = TextStyle(SERIF, 600, False, size)
        st.exact = True
        return (max(58.0, measure(st, self.topics[i].text)) + 26, size + 20)

    def idea_size(self, i: Int) -> Float64:
        """An idea's words: its own size (makeNode's by depth for a new one), else 20 (layout.js: node.fontSize || 20;
        the weight stays 600: style.css's .map-node-label beats the SVG attribute, D-7943)."""
        return self.topics[i].font_size if self.topics[i].font_size > 0 else 20.0

    def frame(self, i: Int) -> Frame:
        var s = self.card_size(i)
        return Frame(self.topics[i].x, self.topics[i].y, s[0] / 2, s[1] / 2)

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
            var f = self.frame(i)
            var rx = max(120.0, f.hw + 40)
            var ry = max(120.0, f.hh + 40)
            minx = min(minx, f.x - rx)
            miny = min(miny, f.y - ry)
            maxx = max(maxx, f.x + rx)
            maxy = max(maxy, f.y + ry)
        var sc = min(1.35, max(0.45, min((w - padding * 2) / (maxx - minx), (h - padding * 2) / (maxy - miny))))
        return (sc, w / 2 - (minx + maxx) / 2 * sc, h / 2 - (miny + maxy) / 2 * sc)

    def draw[P: Painter](self, mut p: P, mut bx: Boxes, x0: Float64, y0: Float64, w: Float64, h: Float64, zoom_in: Float64, sk: Skin, label: String):
        draw_shadows(p, x0, y0, w, h, sk.radius, sk.shadow1, 0.3 * sk.radius + 1)
        draw_radial_steps(p, x0, y0, w, h, 0.48, 0.44, CARD, SHEET, 0.74, sk.radius)  # (.mindmap-stage's background)
        bx.add("map.host", x0, y0, w, h)
        bx.add("map.canvas", x0, y0, w, h)
        bx.add("map.named:" + label, x0, y0, w, h)
        p.push_clip(x0, y0, w, h)
        var fv = self.fit(w, h, 80)
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
            if par < 0:
                continue
            var d = Float64(self.depth(i))
            var start = max(5.0, 34 / pow(d, 0.82))
            var end = max(3.0, 8 / pow(d, 0.88))
            var g = branch_geometry(self.frame(par), self.frame(i))
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
            var g = branch_geometry(self.frame(self.topics[sel].parent), self.frame(sel))
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
                var sh = List[Shadow]()
                sh.append(Shadow(0, 5 * zoom, 14 * zoom, 0, rgba(56, 47, 40, 38)))
                draw_shadows(p, hx - r - 1.25 * zoom, hy - r - 1.25 * zoom, 2 * r + 2.5 * zoom, 2 * r + 2.5 * zoom, r + 1.25 * zoom, sh)
                p.circle(hx, hy, r + 1.25 * zoom, hexc("#fffefa"))
                p.circle(hx, hy, r - 1.25 * zoom, self.topics[sel].color)
                bx.add("map.anchor:" + self.topics[sel].text, hx - 18 * zoom, hy - 18 * zoom, 36 * zoom, 36 * zoom)
        # cards and words
        for i in range(len(self.topics)):
            ref t = self.topics[i]
            var s = self.card_size(i)
            var w2 = s[0] * zoom
            var h2 = s[1] * zoom
            var lx = cx + t.x * zoom - w2 / 2
            var ly = cy + t.y * zoom - h2 / 2
            if t.parent < 0:
                var sh = List[Shadow]()
                sh.append(Shadow(0, 4, 10, 0, rgba(57, 48, 37, 30)))
                draw_shadows(p, lx, ly, w2, h2, 20 * zoom, sh)
                p.rect(lx, ly, w2, h2, t.color, 20 * zoom)
                _smile(p, cx + t.x * zoom, cy + t.y * zoom, s[0], s[1], zoom)
                # (Chromium draws the root's words at 20 px though layout.js sizes the card from a 28 px measure:
                # measured from the reference, 88 px wide at 102 %; D-7912)
                var st = TextStyle(SERIF, 700, False, 20 * zoom)
                st.exact = True
                p.run(st, t.text, cx + t.x * zoom, cy + (t.y + 1) * zoom + _mid(20) * zoom, rgba(255, 255, 255), ALIGN_CENTER)
                # the group's box reaches the add handles: 18 beyond the card plus a handle's 17 hit circle
                var reach_x = (s[0] / 2 + 18 + 17.33) * zoom
                var reach_y = (s[1] / 2 + 18 + 17.33) * zoom
                bx.add("map.idea:" + t.text, cx + t.x * zoom - reach_x, cy + t.y * zoom - reach_y, 2 * reach_x, 2 * reach_y)
            else:
                var sh = List[Shadow]()
                sh.append(Shadow(0, 3, 7, 0, rgba(57, 48, 37, 20)))
                draw_shadows(p, lx, ly, w2, h2, 6 * zoom, sh)
                draw_bordered(p, lx - 1, ly - 1, w2 + 2, h2 + 2, 6 * zoom + 1, CARD, t.color, 2)
                var size = self.idea_size(i)
                var st = TextStyle(SERIF, 600, False, size * zoom)
                st.exact = True
                var words = self.edit_text if i == self.editing else t.text
                if i == self.editing and self.edit_all:
                    var ww = measure(st, words)
                    p.rect(cx + t.x * zoom - ww / 2, cy + (t.y - 11 * size / 20) * zoom, ww, 22 * size / 20 * zoom, with_alpha(hexc("#3d8fe8"), 0.25), 0)
                p.run(st, words, cx + t.x * zoom, cy + (t.y + 1) * zoom + _mid(size) * zoom, LABEL, ALIGN_CENTER)
                bx.add("map.idea:" + t.text, lx - 5 * zoom, ly - 5 * zoom, w2 + 10 * zoom, h2 + 10 * zoom)  # (the group holds its hidden selection rect)
        # the selection: dashed ring and four add handles
        if self.selected >= 0 and self.selected < len(self.topics):
            ref t = self.topics[self.selected]
            var s = self.card_size(self.selected)
            var root = t.parent < 0
            var pad = 7.0 if root else 5.0
            _dashed_rect(p, cx + (t.x - s[0] / 2 - pad) * zoom, cy + (t.y - s[1] / 2 - pad) * zoom, (s[0] + 2 * pad) * zoom, (s[1] + 2 * pad) * zoom,
                         (24.0 if root else 9.0) * zoom, 1.5 * zoom, 4 * zoom)
            var hx: List[Float64] = [0, s[0] / 2 + 18, 0, -(s[0] / 2 + 18)]
            var hy: List[Float64] = [-(s[1] / 2 + 18), 0, s[1] / 2 + 18, 0]
            var names: List[String] = ["top", "right", "bottom", "left"]
            for k in range(4):
                var ax = cx + (t.x + hx[k]) * zoom
                var ay = cy + (t.y + hy[k]) * zoom
                p.circle(ax, ay, 8.25 * zoom, CARD)  # (r 7, stroked 2.5 in the card colour)
                p.circle(ax, ay, 5.75 * zoom, t.color)
                p.circle(ax, ay, 2 * zoom, CARD)
                bx.add("map.add-branch:" + names[k], ax - 17 * zoom, ay - 17 * zoom, 34 * zoom, 34 * zoom)
        p.pop_clip()


def _mid(size: Float64) -> Float64:
    """dominant-baseline: middle puts the middle of the x-height on y: the baseline sits half an x-height below
    (Source Serif 4's x-height is .475 em)."""
    return 0.475 * size / 2


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
    var left = List[Float64]()
    var right = List[Float64]()
    for i in range(N + 1):
        var t = Float64(i) / N
        var u = 1 - t
        var x = u * u * x0 + 2 * u * t * qx + t * t * x1
        var y = u * u * y0 + 2 * u * t * qy + t * t * y1
        var dx = 2 * u * (qx - x0) + 2 * t * (x1 - qx)
        var dy = 2 * u * (qy - y0) + 2 * t * (y1 - qy)
        var l = sqrt(dx * dx + dy * dy)
        left.append(cx + (x - dy / l * 2.5) * z)
        left.append(cy + (y + dx / l * 2.5) * z)
        right.append(cx + (x + dy / l * 2.5) * z)
        right.append(cy + (y - dx / l * 2.5) * z)
    for i in range(N + 1):
        pts.append(left[2 * i])
        pts.append(left[2 * i + 1])
    for i in range(N, -1, -1):
        pts.append(right[2 * i])
        pts.append(right[2 * i + 1])
    p.polygon(pts, rgba(255, 255, 255, 59))
    p.circle(cx + x0 * z, cy + y0 * z, 2.5 * z, rgba(255, 255, 255, 59))
    p.circle(cx + x1 * z, cy + y1 * z, 2.5 * z, rgba(255, 255, 255, 59))


def _dashed_rect[P: Painter](mut p: P, x: Float64, y: Float64, w: Float64, h: Float64, r: Float64, sw: Float64, dash: Float64):
    """A rounded rect's outline in dashes (dash on, dash off), straight sides only (the corners' arcs left open)."""
    var segs = List[Float64]()
    # top, bottom, left, right sides between the corner arcs
    var sides: List[List[Float64]] = [[x + r, y, x + w - r, y], [x + r, y + h, x + w - r, y + h], [x, y + r, x, y + h - r], [x + w, y + r, x + w, y + h - r]]
    for s in sides:
        var dx = s[2] - s[0]
        var dy = s[3] - s[1]
        var l = sqrt(dx * dx + dy * dy)
        var t = 0.0
        while t < l:
            var t1 = min(l, t + dash)
            p.line(s[0] + dx * t / l, s[1] + dy * t / l, s[0] + dx * t1 / l, s[1] + dy * t1 / l, sw, RING)
            t += 2 * dash
    _ = segs


@fieldwise_init
struct Curve(ImplicitlyCopyable, Movable):
    var sx: Float64
    var sy: Float64
    var ax: Float64
    var ay: Float64
    var bx: Float64
    var by: Float64
    var ex: Float64
    var ey: Float64


def _attach(f: Frame, tx: Float64, ty: Float64, inset: Float64) -> Tuple[Float64, Float64]:
    var dx = tx - f.x
    var dy = ty - f.y
    var length = sqrt(dx * dx + dy * dy)
    if length == 0:
        length = 1
    var t = min(f.hw / (abs(dx) if abs(dx) > 0 else 1e-9), f.hh / (abs(dy) if abs(dy) > 0 else 1e-9))
    var reach = (t * length - min(inset, 0.6 * t * length)) / length
    return (f.x + dx * reach, f.y + dy * reach)


def branch_geometry(parent: Frame, child: Frame, curve: Float64 = 78) -> Curve:
    """geometry.js branchGeometry (no saved ports or anchors): both control points on one side of the chord."""
    var s = _attach(parent, child.x, child.y, 30)
    var e = _attach(child, parent.x, parent.y, 2)
    var dx = e[0] - s[0]
    var dy = e[1] - s[1]
    var length = sqrt(dx * dx + dy * dy)
    if length == 0:
        length = 1
    var cxn = dx / length
    var side = tanh(2.2 * cxn) * (0.04 + (curve / 100) * 0.26)
    # lerpAnchor at t .3 and .7, offset n = side along the chord's normal
    var ax = s[0] + dx * 0.3 - dy * side
    var ay = s[1] + dy * 0.3 + dx * side
    var bx = s[0] + dx * 0.7 - dy * side
    var by = s[1] + dy * 0.7 + dx * side
    return Curve(s[0], s[1], ax, ay, bx, by, e[0], e[1])


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
    if sk.dark:  # (a dark skin's controls: the surface, a line for an edge, no shadow: workspace-theme.css)
        p.rect(x, y, 170, 102, sk.line, 6)
        p.rect(x + 1, y + 1, 168, 100, sk.panel, 5)
    else:
        draw_lifted(p, x, y, 170, 102, 6, sk.shadow1, hexc("#fffffc"))
    bx.add("map.overview", x, y, 170, 102)
    var vs = min(158.0 / 220, 90.0 / 130)
    var ox = x + 6 + (158 - 220 * vs) / 2
    var oy = y + 6 + (90 - 130 * vs) / 2
    var minx = 1e18
    var miny = 1e18
    var maxx = -1e18
    var maxy = -1e18
    for i in range(len(m.topics)):
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
    var fv = m.fit(view_w, view_h, 80)
    var vx = (-fv[1] / fv[0]) * sc + offx
    var vy = (-fv[2] / fv[0]) * sc + offy
    var vw = view_w / fv[0] * sc
    var vh = view_h / fv[0] * sc
    var teal = hexc("#247c73")
    p.rect(ox + vx * vs, oy + vy * vs, vw * vs, vh * vs, teal, 0)
    var sw = 1.5 * vs
    p.rect(ox + vx * vs + sw / 2, oy + vy * vs + sw / 2, vw * vs - sw, vh * vs - sw, hexc("#fffffc"), 0)
    p.rect(ox + vx * vs + sw / 2, oy + vy * vs + sw / 2, vw * vs - sw, vh * vs - sw, with_alpha(teal, 0.05), 0)
    for i in range(len(m.topics)):
        ref t = m.topics[i]
        p.circle(ox + (t.x * sc + offx) * vs, oy + (t.y * sc + offy) * vs, (4.0 if t.parent < 0 else 2.0) * vs, t.color)


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
