# mojoui.buzanmap (goal 79): a Tony Buzan mind map drawn the way Personal Note's web map draws it, as a generic view of
# any tree of topics: organic one-bend branches as tapered ribbons in each branch's colour (width falls with depth and is
# capped by the bend), ideas on white cards with a coloured edge, the central topic as a filled card with a soft
# highlight, the dashed selection ring and the four add handles, on a dotted sheet. The geometry is the web's own
# (geometry.js: attach, branchGeometry, ribbonOutline; layout.js: card sizes), so a map saved by either looks the same.
#
#   var m = BuzanMap(); m.add(-1, "The book", 0, 0, color); m.add(0, "Characters", 280, -130, color2) …
#   m.draw(p, bx, x0, y0, w, h, zoom, sk)        # the view centred on the map's origin

from std.math import sqrt, tanh, pow
from mojoui.scene import Painter
from mojoui.skin import Skin, Shadow, with_alpha, hexc
from mojoui.fonttext import TextStyle, measure, ALIGN_CENTER
from mojoui.notesshell import Boxes, draw_shadows, draw_bordered, draw_radial_steps
from mojoui.canvas import rgba

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


@fieldwise_init
struct Frame(ImplicitlyCopyable, Movable):
    var x: Float64
    var y: Float64
    var hw: Float64
    var hh: Float64


struct BuzanMap(Movable):
    var topics: List[Topic]
    var selected: Int

    def __init__(out self):
        self.topics = List[Topic]()
        self.selected = 0

    def add(mut self, parent: Int, text: String, x: Float64, y: Float64, color: UInt32) -> Int:
        self.topics.append(Topic(parent, text, x, y, color))
        return len(self.topics) - 1

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
        var st = TextStyle(SERIF, 600, False, 20)
        st.exact = True
        return (max(58.0, measure(st, self.topics[i].text)) + 26, 40.0)

    def frame(self, i: Int) -> Frame:
        var s = self.card_size(i)
        return Frame(self.topics[i].x, self.topics[i].y, s[0] / 2, s[1] / 2)

    def fit(self, w: Float64, h: Float64, padding: Float64) -> Tuple[Float64, Float64, Float64]:
        """renderer.js fit(): (scale, x, y) showing every topic (each reaching at least 120 around it)."""
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
        draw_shadows(p, x0, y0, w, h, sk.radius, sk.shadow1)
        draw_radial_steps(p, x0, y0, w, h, 0.48, 0.44, CARD, SHEET, 0.74, sk.radius)  # (.mindmap-stage's background)
        bx.add("#mindmap-host", x0, y0, w, h)
        bx.add("[Mind map canvas]", x0, y0, w, h)
        bx.add("[" + label + " mind map]", x0, y0, w, h)
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
                bx.add("[" + t.text + "]", cx + t.x * zoom - reach_x, cy + t.y * zoom - reach_y, 2 * reach_x, 2 * reach_y)
            else:
                var sh = List[Shadow]()
                sh.append(Shadow(0, 3, 7, 0, rgba(57, 48, 37, 20)))
                draw_shadows(p, lx, ly, w2, h2, 6 * zoom, sh)
                draw_bordered(p, lx - 1, ly - 1, w2 + 2, h2 + 2, 6 * zoom + 1, CARD, t.color, 2)
                var st = TextStyle(SERIF, 600, False, 20 * zoom)
                st.exact = True
                p.run(st, t.text, cx + t.x * zoom, cy + (t.y + 1) * zoom + _mid(20) * zoom, LABEL, ALIGN_CENTER)
                bx.add("[" + t.text + "]", lx - 5 * zoom, ly - 5 * zoom, w2 + 10 * zoom, h2 + 10 * zoom)  # (the group holds its hidden selection rect)
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
                bx.add("[Add branch from " + names[k] + "]", ax - 17 * zoom, ay - 17 * zoom, 34 * zoom, 34 * zoom)
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
    draw_shadows(p, x, y, 170, 102, 6, sk.shadow1)
    p.rect(x, y, 170, 102, hexc("#fffffc"), 6)
    bx.add("[Map overview]", x, y, 170, 102)
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
