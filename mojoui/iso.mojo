# mojoui.iso: how something works, as a small isometric diagram (goal 77 M4). Three to six blocks drawn as simple isometric
# boxes (a top and two shaded sides, tinted by kind from the theme's data colours), a label over each, arrows on the ground
# between them with short labels, numbered step badges on the blocks, and the steps listed under the drawing. No 3D engine:
# a fixed 30-degree projection, filled polygons, painter's order by depth.
#
#   IsoDiagram.parse(json, node)        the genui `Iso` component's data (blocks, links, steps), references resolved by id or label
#   iso_problem(json, node) -> String   why the data can't be drawn ("" when it can): a link or step naming no block (genui's validator)
#   d.parts(card, inside) -> List[Part] every block a pointable part named by its label (mojoui.pointer.names_for), found as a box in
#                                       the canvas tagged `inside` (mojoui.pointer.area_part): "the compressor" moves the ring to it
#   draw_iso(surface, d, palette, font, focus, q, was, q_was, step)   the drawing, fitted and centred in the canvas; block `focus` is
#                                       lifted by q (0..1), `was` sinks back by q_was, step `step`'s badge is drawn larger
#   explain_ui(args) -> String          the explain tool's arguments (title, blocks, links, steps) as render_ui's {"ui": Card(Iso)}
#   walk_text(d) -> String              the order the blocks are walked through ("1 Compressor, 2 Outdoor coil, ..."), for the tool result
#
# Layout: a block's layer is the longest path to it along the links (links that close a loop are left out of the count), blocks of
# one layer stand in rows across it (ordered by where the blocks that feed them stand); layers run down-right, rows down-left, the
# classic isometric grid. Everything is laid out in the drawing's own units (`width` x `height`) and drawn as large as fits, so a
# block's box in those units is also where the pointer finds it.

from std.math import sqrt
from mojoui.canvas import Surface
from mojoui.draw import line, polygon, rect, circle, with_alpha
from mojoui.json import Json, json_string, J_OBJECT, J_STRING
from mojoui.pointer import Part, area_part, names_for, part_name, norm
from mojoui.text import Font, MEDIUM, CENTRE
from mojoui.theme import Palette, mix, rgba
from mojoui.utf8 import head

comptime ISO_KINDS: List[String] = ["process", "device", "store", "person", "place", "energy", "thing"]
comptime MAX_BLOCKS = 6
comptime MAX_LINKS = 10
comptime MAX_STEPS = 8
comptime SPACING = 140.0  # ground units between layers and between rows
comptime HALF = 30.0  # half a block's footprint side
comptime TALL = 34.0  # a block's height
comptime LIFT = 10.0  # how far a pointed-at block rises
comptime LABEL = 20.0  # a block's label (drawing units: about 11 pt on a phone's card)
comptime LINK_LABEL = 15.0
comptime LANE = 46.0  # a bent link's lane: this far in front of the front-most block, the next one 24 further
comptime BADGE = 9.0  # a step badge's radius
comptime MARGIN = 10.0
comptime C30 = 0.8660254037844386  # cos 30°: ground x and y as the screen sees them
comptime LIFT_MS = 220  # a block rises (or sinks back) in this long


def kind_index(kind: String) -> Int:
    var k = String(norm(kind).strip())
    var kinds = materialize[ISO_KINDS]()
    for i in range(len(kinds)):
        if kinds[i] == k:
            return i
    return len(kinds) - 1  # (anything else is a "thing")


def _letters(s: String) -> Int:
    var n = 0
    for _ in s.codepoints():
        n += 1
    return n


def _guess_width(s: String, size: Float64) -> Float64:
    """A label's width without a font (the layout is made before anything is drawn): Inter's letters average a little over half
    their size."""
    return 0.58 * size * Float64(_letters(s))


@fieldwise_init
struct IsoBlock(Copyable, Movable):
    var label: String
    var id: String
    var kind: Int
    var layer: Int
    var row: Int
    var gx: Float64  # where it stands on the ground
    var gy: Float64


@fieldwise_init
struct IsoLink(Copyable, Movable):
    var a: Int
    var b: Int
    var label: String
    var lane: Float64  # 0: straight, from top edge to top edge; else the ground y of the lane it bends along, in front of the
                       # blocks (a loop back, or a link that skips a layer and would cross the blocks between)


@fieldwise_init
struct IsoStep(Copyable, Movable):
    var block: Int
    var text: String


def _visit(v: Int, links: List[IsoLink], mut state: List[Int], mut back: List[Bool]):
    """Depth first along the links: a link to a block still being visited closes a loop (it is left out of the layering)."""
    state[v] = 1
    for e in range(len(links)):
        if links[e].a == v:
            var w = links[e].b
            if state[w] == 1:
                back[e] = True
            elif state[w] == 0:
                _visit(w, links, state, back)
    state[v] = 2


struct IsoDiagram(Copyable, Movable):
    var blocks: List[IsoBlock]
    var links: List[IsoLink]
    var steps: List[IsoStep]
    var unknown: List[String]  # references (a link's end, a step's block) that named no block, as written
    var left: Float64  # the drawing's ground-projected corner (the units' origin is (left, top))
    var top: Float64
    var width: Int  # the drawing's size in its own units
    var height: Int

    def __init__(out self):
        self.blocks = List[IsoBlock]()
        self.links = List[IsoLink]()
        self.steps = List[IsoStep]()
        self.unknown = List[String]()
        self.left = 0.0
        self.top = 0.0
        self.width = 1
        self.height = 1

    @staticmethod
    def parse(j: Json, n: Int) -> IsoDiagram:
        var d = IsoDiagram()
        var bs = j.get(n, "blocks")
        for i in range(j.size(bs)):
            if len(d.blocks) >= MAX_BLOCKS:
                break
            var b = j.at(bs, i)
            var label = String(j.text(j.get(b, "label")).strip())
            if label == "":
                continue
            d.blocks.append(IsoBlock(label, String(j.text(j.get(b, "id")).strip()), kind_index(j.text(j.get(b, "kind"))), 0, 0, 0.0, 0.0))
        var ls = j.get(n, "links")
        for i in range(min(j.size(ls), MAX_LINKS)):
            var l = j.at(ls, i)
            var a = d.find(j.text(j.get(l, "from")))
            var b = d.find(j.text(j.get(l, "to")))
            if a < 0:
                d.unknown.append(j.text(j.get(l, "from")))
            if b < 0:
                d.unknown.append(j.text(j.get(l, "to")))
            if a < 0 or b < 0 or a == b:
                continue
            var dup = False
            for ref k in d.links:
                dup = dup or (k.a == a and k.b == b)
            if not dup:
                d.links.append(IsoLink(a, b, String(j.text(j.get(l, "label")).strip()), 0.0))
        var ss = j.get(n, "steps")
        for i in range(min(j.size(ss), MAX_STEPS)):
            var s = j.at(ss, i)
            var b = d.find(j.text(j.get(s, "block")))
            if b < 0:
                d.unknown.append(j.text(j.get(s, "block")))
                continue
            d.steps.append(IsoStep(b, String(j.text(j.get(s, "text")).strip())))
        d.layout()
        return d^

    def find(self, ref_text: String) -> Int:
        """The block a link or step names: by its id, its label (any case, any punctuation), or a label said inside it ("the
        compressor" names Compressor) or it inside a label; -1 when none."""
        var want = norm(ref_text)
        if String(want.strip()) == "":
            return -1
        for i in range(len(self.blocks)):
            if (self.blocks[i].id != "" and norm(self.blocks[i].id) == want) or norm(self.blocks[i].label) == want:
                return i
        for i in range(len(self.blocks)):
            if want.find(norm(self.blocks[i].label)) >= 0:
                return i
        for i in range(len(self.blocks)):
            if norm(self.blocks[i].label).find(want) >= 0:
                return i
        return -1

    def layout(mut self):
        var n = len(self.blocks)
        if n == 0:
            return
        var back = List[Bool](length=len(self.links), fill=False)
        var state = List[Int](length=n, fill=0)
        var fed = List[Bool](length=n, fill=False)
        for ref l in self.links:
            fed[l.b] = True
        for v in range(n):  # (from the blocks nothing feeds first, so a loop is cut where it closes, not where it starts)
            if not fed[v] and state[v] == 0:
                _visit(v, self.links, state, back)
        for v in range(n):
            if state[v] == 0:
                _visit(v, self.links, state, back)
        if len(self.links) == 0:  # (nothing linked: the blocks in a line, in the order given)
            for v in range(n):
                self.blocks[v].layer = v
        else:
            for _ in range(n):
                for e in range(len(self.links)):
                    if not back[e]:
                        var a = self.links[e].a
                        var b = self.links[e].b
                        self.blocks[b].layer = max(self.blocks[b].layer, self.blocks[a].layer + 1)
        var layers = 0
        for ref b in self.blocks:
            layers = max(layers, b.layer + 1)
        for L in range(layers):  # rows: by where the blocks feeding each one stand (ties in the order given)
            var members = List[Int]()
            var keys = List[Float64]()
            for v in range(n):
                if self.blocks[v].layer != L:
                    continue
                var total = 0.0
                var count = 0
                for e in range(len(self.links)):
                    if not back[e] and self.links[e].b == v and self.blocks[self.links[e].a].layer < L:
                        total += Float64(self.blocks[self.links[e].a].row)
                        count += 1
                members.append(v)
                keys.append(total / Float64(count) if count > 0 else Float64(v) * 0.001)
            for i in range(1, len(members)):
                var k = i
                while k > 0 and keys[k] < keys[k - 1]:
                    var t = keys[k]
                    keys[k] = keys[k - 1]
                    keys[k - 1] = t
                    var m = members[k]
                    members[k] = members[k - 1]
                    members[k - 1] = m
                    k -= 1
            var m = len(members)
            for r in range(m):
                ref b = self.blocks[members[r]]
                b.row = r
                b.gx = Float64(L) * SPACING
                b.gy = (Float64(r) - Float64(m - 1) / 2.0) * SPACING
        # links that would cross other blocks (a loop back, a skipped layer, rows apart) bend along lanes in front of them all
        var front = -1e30
        for ref b in self.blocks:
            front = max(front, b.gy)
        var lanes = 0
        for e in range(len(self.links)):
            ref a = self.blocks[self.links[e].a]
            ref b = self.blocks[self.links[e].b]
            var step = b.layer - a.layer
            if back[e] or step > 1 or step < 0 or (step == 0 and abs(b.row - a.row) > 1):
                self.links[e].lane = front + HALF + LANE + 24.0 * Float64(lanes)
                lanes += 1
        # the drawing's extent: every block with its label and badges, every link and its label
        var x0 = 1e30
        var y0 = 1e30
        var x1 = -1e30
        var y1 = -1e30
        for ref b in self.blocks:
            var px = (b.gx - b.gy) * C30
            var py = (b.gx + b.gy) * 0.5
            var half_w = max(2.0 * HALF * C30, _guess_width(b.label, LABEL) / 2.0 + 8.0)
            x0 = min(x0, px - half_w)
            x1 = max(x1, px + half_w)
            y0 = min(y0, py - TALL - HALF - LIFT - 10.0 - LABEL * 1.5)
            y1 = max(y1, py + HALF + 6.0)
        self.left = 0.0
        self.top = 0.0
        for e in range(len(self.links)):
            var path = self.path(e)
            for i in range(len(path) // 2):
                x0 = min(x0, path[2 * i] - 6.0)
                x1 = max(x1, path[2 * i] + 6.0)
                y0 = min(y0, path[2 * i + 1] - 6.0)
                y1 = max(y1, path[2 * i + 1] + 6.0)
            if self.links[e].label != "":
                var m = self.middle(path)
                var hw = _guess_width(self.links[e].label, LINK_LABEL) / 2.0 + 6.0
                x0 = min(x0, m[0] - hw)
                x1 = max(x1, m[0] + hw)
                y0 = min(y0, m[1] - LINK_LABEL)
                y1 = max(y1, m[1] + LINK_LABEL)
        self.left = x0 - MARGIN
        self.top = y0 - MARGIN
        self.width = Int(x1 - x0 + 2.0 * MARGIN + 0.5)
        self.height = Int(y1 - y0 + 2.0 * MARGIN + 0.5)

    def at(self, i: Int) -> Tuple[Float64, Float64]:
        """Block i's footprint centre on the ground, in the drawing's units."""
        ref b = self.blocks[i]
        return ((b.gx - b.gy) * C30 - self.left, (b.gx + b.gy) * 0.5 - self.top)

    def project(self, gx: Float64, gy: Float64, z: Float64) -> Tuple[Float64, Float64]:
        return ((gx - gy) * C30 - self.left, (gx + gy) * 0.5 - z - self.top)

    def path(self, e: Int, lift_a: Float64 = 0.0, lift_b: Float64 = 0.0) -> List[Float64]:
        """Link e as a line in the drawing's units (x, y interleaved), from block a's edge to block b's: straight in the plane
        of the blocks' tops, or bent along its lane on the ground in front of every block (nothing can hide either)."""
        ref l = self.links[e]
        ref a = self.blocks[l.a]
        ref b = self.blocks[l.b]
        var out = List[Float64]()
        if l.lane != 0.0:
            for pt in [self.project(a.gx, a.gy + HALF + 8.0, 0.0), self.project(a.gx, l.lane, 0.0), self.project(b.gx, l.lane, 0.0),
                       self.project(b.gx, b.gy + HALF + 8.0, 0.0)]:
                out.append(pt[0])
                out.append(pt[1])
            return out^
        var dx = b.gx - a.gx
        var dy = b.gy - a.gy
        var length = sqrt(dx * dx + dy * dy)
        if length < 1.0:
            return out^
        dx /= length
        dy /= length
        var reach = HALF / max(abs(dx), abs(dy)) + 7.0
        var side = 0.0
        for ref o in self.links:  # (a link straight back the other way runs beside this one, not on it)
            if o.a == l.b and o.b == l.a and o.lane == 0.0:
                side = 7.0
        var p0 = self.project(a.gx + dx * reach - dy * side, a.gy + dy * reach + dx * side, TALL + lift_a)
        var p1 = self.project(b.gx - dx * reach - dy * side, b.gy - dy * reach + dx * side, TALL + lift_b)
        out.append(p0[0])
        out.append(p0[1])
        out.append(p1[0])
        out.append(p1[1])
        return out^

    def middle(self, path: List[Float64]) -> Tuple[Float64, Float64]:
        """Where a link's label goes: beside the middle of its middle segment."""
        var n = len(path) // 2
        if n < 2:
            return (-1.0, -1.0)
        var i = (n - 2) // 2
        var ux = path[2 * i + 2] - path[2 * i]
        var uy = path[2 * i + 3] - path[2 * i + 1]
        var ul = sqrt(ux * ux + uy * uy)
        var px = 0.0
        var py = 0.0
        if ul > 0.0:  # (beside the line, on its lower side: the blocks' labels stand above the blocks)
            px = -uy / ul
            py = ux / ul
            if py < 0.0:
                px = -px
                py = -py
        return ((path[2 * i] + path[2 * i + 2]) / 2.0 + px * 13.0, (path[2 * i + 1] + path[2 * i + 3]) / 2.0 + py * 13.0)

    def box(self, i: Int) -> List[Float64]:
        """Block i's box in the drawing's units [x0, y0, x1, y1]: the block and the room it rises into."""
        var c = self.at(i)
        var hw = 2.0 * HALF * C30
        return [c[0] - hw - 3.0, c[1] - TALL - HALF - LIFT - 3.0, c[0] + hw + 3.0, c[1] + HALF + 3.0]

    def labels(self) -> List[String]:
        var out = List[String]()
        for ref b in self.blocks:
            out.append(b.label)
        return out^

    def part_of(self, i: Int) -> String:
        """Block i's part name ("outdoor-coil"), unique on the card (a repeated label gets its number)."""
        var name = part_name(self.blocks[i].label)
        for k in range(i):
            if part_name(self.blocks[k].label) == name:
                return name + "-" + String(i + 1)
        return name

    def block_of(self, part: String) -> Int:
        for i in range(len(self.blocks)):
            if self.part_of(i) == part:
                return i
        return -1

    def parts(self, card: String, inside: String) -> List[Part]:
        """Every block, named by its label (all of it, or a word of it no other label has), as a box in the canvas `inside`."""
        var out = List[Part]()
        var labels = self.labels()
        for i in range(len(self.blocks)):
            var b = self.box(i)
            out.append(area_part(card, self.part_of(i), names_for(self.blocks[i].label, labels), inside, b[0], b[1], b[2], b[3], self.width, self.height))
        return out^


def iso_problem(j: Json, n: Int) -> String:
    """Why an Iso can't be drawn as given ("" when it can): a link or a step that names no block (each must name one by its label)."""
    var d = IsoDiagram.parse(j, n)
    if len(d.unknown) == 0:
        return ""
    var names = String("")
    for ref b in d.blocks:
        names += (", " if names != "" else "") + b.label
    return "Iso's link or step names " + json_string(d.unknown[0]) + ", which is not one of its blocks (" + names + "): name a block by its label"


def walk_text(d: IsoDiagram) -> String:
    """The steps as the blocks they happen at: "1 Compressor, 2 Outdoor coil, 3 Expansion valve"."""
    var out = String("")
    for i in range(len(d.steps)):
        out += (", " if i > 0 else "") + String(i + 1) + " " + d.blocks[d.steps[i].block].label
    return out^


# ---------------------------------------------------------------------------------------------------------------------
# the explain tool's arguments as a card
# ---------------------------------------------------------------------------------------------------------------------

def _field(j: Json, node: Int, key: String, most: Int) -> String:
    var v = j.get(node, key)
    if v < 0 or j.kind(v) != J_STRING:
        return ""
    return ',"' + key + '":' + json_string(head(String(j.text(v).strip()), most))


def explain_ui(args: String) -> String:
    """The explain tool's arguments ({title, blocks: [{label, kind}], links: [{from, to, label}], steps: [{block, text}]}) as
    render_ui's arguments: a Card titled with the title, holding the Iso. Only the props the Iso knows are kept, labels are cut to
    their limits and a kind it doesn't know becomes "thing", so a model's small slips don't cost it another try. Not JSON: ""."""
    var j: Json
    try:
        j = Json.parse(args)
    except:
        return ""
    if j.kind(0) != J_OBJECT:
        return ""
    var kinds = materialize[ISO_KINDS]()
    var blocks = String("")
    var bs = j.get(0, "blocks")
    for i in range(min(j.size(bs), MAX_BLOCKS)):
        var b = j.at(bs, i)
        var label = b if j.kind(b) == J_STRING else j.get(b, "label")  # (a bare label is a block too)
        var k = kinds[kind_index(j.text(j.get(b, "kind")))]
        blocks += ("," if i > 0 else "") + '{"label":' + json_string(head(String(j.text(label).strip()), 32)) + ',"kind":"' + k + '"' + _field(j, b, "id", 40) + "}"
    var links = String("")
    var ls = j.get(0, "links")
    for i in range(min(j.size(ls), MAX_LINKS)):
        var l = j.at(ls, i)
        links += ("," if i > 0 else "") + '{"from":' + json_string(head(j.text(j.get(l, "from")), 40)) + ',"to":' + json_string(head(j.text(j.get(l, "to")), 40)) + _field(j, l, "label", 28) + "}"
    var steps = String("")
    var ss = j.get(0, "steps")
    for i in range(min(j.size(ss), MAX_STEPS)):
        var s = j.at(ss, i)
        steps += ("," if i > 0 else "") + '{"block":' + json_string(head(j.text(j.get(s, "block")), 40)) + ',"text":' + json_string(head(String(j.text(j.get(s, "text")).strip()), 140)) + "}"
    var title = head(String(j.text(j.get(0, "title"), j.text(j.get(0, "topic"))).strip()), 200)
    var iso = '{"component":"Iso","blocks":[' + blocks + '],"links":[' + links + '],"steps":[' + steps + "]}"
    return '{"ui":{"component":"Card"' + ((',"title":' + json_string(title)) if title != "" else String("")) + ',"children":[' + iso + "]}}"


# ---------------------------------------------------------------------------------------------------------------------
# drawing
# ---------------------------------------------------------------------------------------------------------------------

def _ease(q: Float64) -> Float64:
    var t = min(max(q, 0.0), 1.0)
    return 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t)


comptime KIND_HUES: List[Int] = [2, 7, 3, 4, 5, 1, 6]  # process, device, store, person, place, energy, thing: the theme's data colours
                                                        # after its first (the first is the accent, which the ring and badges wear)


def block_colour(p: Palette, kind: Int) -> UInt32:
    var hues = materialize[KIND_HUES]()
    return p.data(hues[min(max(kind, 0), len(hues) - 1)])


def _arrow(mut s: Surface, path: List[Float64], colour: UInt32, ox: Float64, oy: Float64, k: Float64):
    """A line through the path's points (drawing units) with a head at its end."""
    var n = len(path) // 2
    if n < 2:
        return
    var ex = path[2 * n - 2]
    var ey = path[2 * n - 1]
    var ux = ex - path[2 * n - 4]
    var uy = ey - path[2 * n - 3]
    var ul = sqrt(ux * ux + uy * uy)
    if ul < 1.0:
        return
    ux /= ul
    uy /= ul
    var hx = ex - ux * 10.0
    var hy = ey - uy * 10.0
    for i in range(n - 1):
        var x1 = path[2 * i + 2] if i < n - 2 else hx
        var y1 = path[2 * i + 3] if i < n - 2 else hy
        line(s, ox + path[2 * i] * k, oy + path[2 * i + 1] * k, ox + x1 * k, oy + y1 * k, 2.4 * k, colour)
    polygon(s, [ex, ey, hx - uy * 6.0, hy + ux * 6.0, hx + uy * 6.0, hy - ux * 6.0], colour, ox, oy, k)


def draw_iso(mut s: Surface, d: IsoDiagram, p: Palette, font: Font, focus: Int = -1, q: Float64 = 1.0, was: Int = -1,
             q_was: Float64 = 1.0, step: Int = -1):
    """The diagram as large as fits, centred: the arrows on the ground, the blocks back to front, then the link labels, the block
    labels and the step badges over everything. Block `focus` rises by q (0..1, eased), `was` sinks back by q_was."""
    s.fill(p.card)
    if len(d.blocks) == 0 or d.width <= 0 or d.height <= 0:
        return
    var k = min(Float64(s.width) / Float64(d.width), Float64(s.height) / Float64(d.height))
    var ox = (Float64(s.width) - Float64(d.width) * k) / 2.0
    var oy = (Float64(s.height) - Float64(d.height) * k) / 2.0
    var black = rgba(0, 0, 0)
    var white = rgba(255, 255, 255)
    var arrow = mix(p.card, p.ink, 0.42)
    var lifts = List[Float64](length=len(d.blocks), fill=0.0)
    if was >= 0 and was < len(d.blocks) and was != focus:
        lifts[was] = LIFT * (1.0 - _ease(q_was))
    if focus >= 0 and focus < len(d.blocks):
        lifts[focus] = LIFT * _ease(q)
    var paths = List[List[Float64]]()
    for e in range(len(d.links)):
        paths.append(d.path(e, lifts[d.links[e].a], lifts[d.links[e].b]))
    for e in range(len(d.links)):  # the bent links first: on the ground, in front of every block, so nothing hides them
        if d.links[e].lane != 0.0:
            _arrow(s, paths[e], arrow, ox, oy, k)
    # the blocks, back to front
    var order = List[Int]()
    for i in range(len(d.blocks)):
        order.append(i)
    for i in range(1, len(order)):
        var j = i
        while j > 0:
            ref x = d.blocks[order[j]]
            ref y = d.blocks[order[j - 1]]
            if x.gx + x.gy < y.gx + y.gy or (x.gx + x.gy == y.gx + y.gy and x.gx < y.gx):
                var t = order[j]
                order[j] = order[j - 1]
                order[j - 1] = t
                j -= 1
            else:
                break
    var shade = with_alpha(black, 0.30 if p.dark else 0.11)
    for i in order:
        ref b = d.blocks[i]
        var c = block_colour(p, b.kind)
        var top = mix(c, white, 0.10 if p.dark else 0.24)
        var right = mix(c, black, 0.26)
        var z0 = lifts[i]
        var z1 = z0 + TALL
        var h = HALF
        var sh = HALF + 4.0 - z0 * 0.15  # (the shadow stays on the ground and tightens as the block rises)
        var g0 = d.project(b.gx - sh + 4.0, b.gy + sh + 4.0, 0.0)
        var g1 = d.project(b.gx + sh + 4.0, b.gy + sh + 4.0, 0.0)
        var g2 = d.project(b.gx + sh + 4.0, b.gy - sh + 4.0, 0.0)
        var g3 = d.project(b.gx - sh + 4.0, b.gy - sh + 4.0, 0.0)
        polygon(s, [g0[0], g0[1], g1[0], g1[1], g2[0], g2[1], g3[0], g3[1]], shade, ox, oy, k)
        var l0 = d.project(b.gx - h, b.gy + h, z0)  # left corner
        var b0 = d.project(b.gx + h, b.gy + h, z0)  # front corner
        var r0 = d.project(b.gx + h, b.gy - h, z0)  # right corner
        var l1 = d.project(b.gx - h, b.gy + h, z1)
        var b1 = d.project(b.gx + h, b.gy + h, z1)
        var r1 = d.project(b.gx + h, b.gy - h, z1)
        var t1 = d.project(b.gx - h, b.gy - h, z1)  # back corner (only the top shows it)
        polygon(s, [l0[0], l0[1], b0[0], b0[1], b1[0], b1[1], l1[0], l1[1]], c, ox, oy, k)
        polygon(s, [b0[0], b0[1], r0[0], r0[1], r1[0], r1[1], b1[0], b1[1]], right, ox, oy, k)
        polygon(s, [l1[0], l1[1], b1[0], b1[1], r1[0], r1[1], t1[0], t1[1]], top, ox, oy, k)
        var edge = with_alpha(white, 0.55 if not p.dark else 0.30)
        line(s, ox + l1[0] * k, oy + l1[1] * k, ox + b1[0] * k, oy + b1[1] * k, 1.2 * k, edge)
        line(s, ox + b1[0] * k, oy + b1[1] * k, ox + r1[0] * k, oy + r1[1] * k, 1.2 * k, edge)
        line(s, ox + b1[0] * k, oy + b1[1] * k, ox + b0[0] * k, oy + b0[1] * k, 1.0 * k, with_alpha(white, 0.25 if not p.dark else 0.15))
    for e in range(len(d.links)):  # the straight links, in the plane of the tops: over the ground, under nothing
        if d.links[e].lane == 0.0:
            _arrow(s, paths[e], arrow, ox, oy, k)
    # the links' labels
    var pill = with_alpha(p.card, 0.92)
    for e in range(len(d.links)):
        var m = d.middle(paths[e])
        if d.links[e].label == "" or m[0] < 0.0:
            continue
        var size = LINK_LABEL * k
        var w = font.measure(d.links[e].label, size) + 10.0 * k
        var cx = ox + m[0] * k
        var cy = oy + m[1] * k
        rect(s, cx - w / 2.0, cy - size * 0.8, w, size * 1.6, pill, size * 0.8)
        font.draw(s, d.links[e].label, cx, cy + size * 0.35, size, p.ink2, align=CENTRE)
    # the blocks' labels, then the step badges on their tops
    for i in range(len(d.blocks)):
        ref b = d.blocks[i]
        var c = d.at(i)
        var size = LABEL * k
        var w = font.measure(b.label, size, MEDIUM) + 12.0 * k
        var base = oy + (c[1] - TALL - HALF - lifts[i] - 10.0) * k
        var cx = ox + c[0] * k
        rect(s, cx - w / 2.0, base - size * 1.05, w, size * 1.45, pill, size * 0.7)
        font.draw(s, b.label, cx, base, size, p.ink, MEDIUM, CENTRE)
    for i in range(len(d.blocks)):
        var mine = List[Int]()
        for st in range(len(d.steps)):
            if d.steps[st].block == i:
                mine.append(st)
        var c = d.at(i)
        for m in range(len(mine)):
            var big = mine[m] == step
            var r = BADGE * (1.25 if big else 1.0) * k
            var bx = ox + (c[0] + (Float64(m) - Float64(len(mine) - 1) / 2.0) * BADGE * 2.4) * k
            var by = oy + (c[1] - TALL - lifts[i]) * k
            if big:
                circle(s, bx, by, r + 4.0 * k, with_alpha(p.accent, 0.28))
            circle(s, bx, by, r, p.accent)
            var size = (12.0 if big else 11.0) * k
            font.draw(s, String(mine[m] + 1), bx, by + size * 0.36, size, p.accent_ink, MEDIUM, CENTRE)
