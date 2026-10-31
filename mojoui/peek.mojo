# mojoui.peek: hold a card to see what it's linked to (goal 41 M8, the approved prototype "hold"): everything unrelated
# steps back (dimmed, grey, a little smaller: omxqua dims, never blurs), the linked cards rise with a spring, and ghost
# lines curve from the held card to each, labelled with the columns they share (dotted for cards showing the same
# table: an implicit link). Letting go settles it all back.
#
#   var peek = Peek(canvas=40, on_frame=7700)                          # its overlay canvas and frame message
#   on Board(on_hold=…) "hold":    peek.show(cards[k].name, cards, links)   (cards: mojoui.linkdrag.DropCard, the page's)
#   on "release":                  peek.close()
#   update(): if event.message == 7700 and peek.step(event.number) == done → print(peek.done_line())
#   view():   tones[i] = peek.tone(i); Board items += peek.views()     (the curves' canvas, click-through, and the labels)
#   draw():   if canvas == peek.canvas: peek.draw(surface, palette)
#   peek.line(): "PEEK: lit=[dock.mp4, dock.mp4 · detections] dim=[forklift_log] lines=2"

from mojoui.canvas import Surface
from mojoui.draw import line as stroke, with_alpha
from mojoui.links import Links, LINK_KEY, LINK_TIME
from mojoui.linkdrag import DropCard
from mojoui.spring import Spring
from mojoui.theme import Palette, mix
from mojoui.view import View, Text, Canvas, CAPTION, BOARD_PLAIN, BOARD_DIM, BOARD_LIFT, BOARD_SOURCE

comptime PEEK_MARGIN = 48  # the curves' canvas reaches this far past the cards it joins (a curve bows out)


@fieldwise_init
struct PeekLine(Copyable, Movable, ImplicitlyCopyable):
    var to: Int  # the card (an index into the peek's cards)
    var label: String  # "shipment_id = code"
    var kind: String  # "key", "time +3.4 s", or "" (the same table: dotted)
    var named: Bool  # the card the link names (not a card that only shows its table): its line carries the label


struct Peek(Movable):
    var canvas: Int
    var on_frame: Int
    var open: Bool  # held: the view is open
    var shown: Bool  # open, or settling back after the release
    var held: Int  # the held card (an index into cards), -1 none
    var cards: List[DropCard]
    var lit: List[Bool]  # per card
    var lines: List[PeekLine]
    var spring: Spring  # the lines drawing in (0 → 1) and fading out (→ 0)
    var version: Int
    var settled: Bool  # the last step() put it back to rest (closed)

    def __init__(out self, canvas: Int, on_frame: Int):
        self.canvas = canvas
        self.on_frame = on_frame
        self.open = False
        self.shown = False
        self.held = -1
        self.cards = List[DropCard]()
        self.lit = List[Bool]()
        self.lines = List[PeekLine]()
        self.spring = Spring(0.0)
        self.version = 0
        self.settled = False

    def show(mut self, name: String, cards: List[DropCard], links: Links):
        """Card `name` held: it, the cards its links reach (and cards showing a linked table), the rest stepping back."""
        self.cards = cards.copy()
        self.held = -1
        for k in range(len(cards)):
            if cards[k].name == name:
                self.held = k
        self.lit = List[Bool](length=len(cards), fill=False)
        self.lines = List[PeekLine]()
        if self.held < 0:
            return
        var me = self.cards[self.held]
        var mine = me.table if me.table != "" else me.name
        for k in range(len(cards)):  # cards showing the same table: linked already (dotted)
            ref c = cards[k]
            var theirs = c.table if c.table != "" else c.name
            if k != self.held and theirs == mine:
                self._join(k, "same table", "", True)
        for l in links.items:
            var a_mine = l.a.card == me.name or l.a.table_name() == mine
            var b_mine = l.b.card == me.name or l.b.table_name() == mine
            if not (a_mine or b_mine):
                continue
            var here = l.a if a_mine else l.b
            var there = l.b if a_mine else l.a
            var said = here.column + (" ≈ " if l.kind == LINK_TIME else " = ") + there.column
            var kind = String("key") if l.kind == LINK_KEY else ("time " + ("+" if l.offset >= 0 else "") + _short(l.offset) + " s" if l.kind == LINK_TIME else String("place"))
            for k in range(len(cards)):
                ref c = cards[k]
                var theirs = c.table if c.table != "" else c.name
                if k != self.held and (c.name == there.card or theirs == there.table_name()):
                    self._join(k, said, kind, c.name == there.card)
        self.open = True
        self.shown = True
        self.settled = False
        self.spring.to(1.0)
        self.version += 1

    def _join(mut self, k: Int, label: String, kind: String, named: Bool):
        for ln in self.lines:
            if ln.to == k and ln.label == label:
                return
        self.lit[k] = True
        self.lines.append(PeekLine(k, label, kind, named))

    def pilled(self, i: Int) -> Bool:
        """Line i carries a label pill: one pill per link, on the line to the card the link names; a line to a card that
        only shows that table (a video's rows card, a folder's documents) is drawn but not labelled again."""
        ref ln = self.lines[i]
        if ln.named or ln.kind == "":
            return True
        for j in range(len(self.lines)):
            if j != i and self.lines[j].label == ln.label and self.lines[j].kind == ln.kind and (self.lines[j].named or j < i):
                return False
        return True

    def close(mut self):
        """Let go: the lines fade and the cards settle back (step() says when it's done)."""
        if not self.open:
            return
        self.open = False
        self.spring.to(0.0)
        self.version += 1

    def step(mut self, microseconds: Int) -> Bool:
        """One display frame; True while it still moves. Sets `settled` on the frame it comes back to rest closed."""
        self.settled = False
        if not self.shown:
            return False
        var moving = self.spring.step(microseconds)
        self.version += 1
        if not moving and not self.open:
            self.shown = False
            self.held = -1
            self.settled = True
        return moving

    def animating(self) -> Bool:
        return self.shown and (self.spring.moving() or not self.open)

    def tone(self, board_index: Int) -> Int:
        """A Board child's tone while the view is open: the held card, its linked cards lifted, the other cards dimmed
        (what isn't a card, the page's floating pieces, stays as it is)."""
        if not self.open or self.held < 0:
            return BOARD_PLAIN
        for k in range(len(self.cards)):
            if self.cards[k].index == board_index:
                if k == self.held:
                    return BOARD_SOURCE
                return BOARD_LIFT if self.lit[k] else BOARD_DIM
        return BOARD_PLAIN

    def names(self, lit: Bool) -> List[String]:
        var out = List[String]()
        for k in range(len(self.cards)):
            if k != self.held and self.lit[k] == lit:
                out.append(self.cards[k].name)
        return out^

    def line(self) -> String:
        """"PEEK: lit=[dock.mp4] dim=[forklift_log] lines=1" (the check's trace)."""
        return "PEEK: lit=[" + ", ".join(self.names(True)) + "] dim=[" + ", ".join(self.names(False)) + "] lines=" + String(len(self.lines))

    def say(self) -> String:
        """What the status bar says while it's open: "shipments: 1 link + same-table cards"."""
        if self.held < 0:
            return ""
        var keys = 0  # (links, not lines: a link to a video reaches its rows' card too)
        var same = False
        var said = List[String]()
        for ln in self.lines:
            if ln.kind == "":
                same = True
            elif ln.label + ln.kind not in said:
                said.append(ln.label + ln.kind)
                keys += 1
        if keys == 0 and not same:
            return self.cards[self.held].name + " isn't linked to anything yet: drag a column onto another card to link it"
        return self.cards[self.held].name + ": " + String(keys) + (" link" if keys == 1 else " links") + (" + same-table cards" if same else "")

    # ---------- the picture ----------

    def _box(self) -> Tuple[Int, Int, Int, Int]:
        """The curves' canvas, in the Board's coordinates: around the held card and every lit one."""
        ref h = self.cards[self.held]
        var x0 = h.x
        var y0 = h.y
        var x1 = h.x + h.w
        var y1 = h.y + h.h
        for ln in self.lines:
            ref c = self.cards[ln.to]
            x0 = min(x0, c.x)
            y0 = min(y0, c.y)
            x1 = max(x1, c.x + c.w)
            y1 = max(y1, c.y + c.h)
        x0 = max(x0 - PEEK_MARGIN, 0)
        y0 = max(y0 - PEEK_MARGIN, 0)
        return (x0, y0, x1 + PEEK_MARGIN - x0, y1 + PEEK_MARGIN - y0)

    def _ends(self, ln: PeekLine) -> Tuple[Float64, Float64, Float64, Float64, Float64, Float64]:
        """A line's start (the held card's edge toward it), its bend and its end (its card's edge), Board coordinates."""
        var a = _edge(self.cards[self.held], self.cards[ln.to])
        var b = _edge(self.cards[ln.to], self.cards[self.held])
        var mx = (a[0] + b[0]) / 2
        var my = (a[1] + b[1]) / 2 - 24
        return (a[0], a[1], mx, my, b[0], b[1])

    def views(self) -> List[View]:
        """Board items while it shows (last, above the cards): the curves' canvas (presses go through it) and a label pill
        at the middle of each link's curve (pilled: once per link)."""
        var out = List[View]()
        if not self.shown or self.held < 0 or len(self.lines) == 0:
            return out^
        var box = self._box()
        out.append(Canvas(self.canvas, self.version, on_frame=self.on_frame if self.animating() else 0).passthrough()
                   .tag("peek-lines").label("Lines from " + self.cards[self.held].name + " to what it's linked to")
                   .at(box[0], box[1]).width(box[2]).height(box[3]))
        if self.open:
            for i in range(len(self.lines)):
                if not self.pilled(i):
                    continue
                ref ln = self.lines[i]
                var e = self._ends(ln)
                var text = ln.label + ("  " + ln.kind if ln.kind != "" else String(""))
                var w = 26 + 7 * len(text.codepoints())
                var mx = 0.25 * e[0] + 0.5 * e[2] + 0.25 * e[4]  # (the curve's middle)
                var my = 0.25 * e[1] + 0.5 * e[3] + 0.25 * e[5]
                out.append(Text(text, CAPTION).tag("peek-label").at(Int(mx) - w // 2, Int(my) - 11).width(w).height(22))
        return out^

    def draw(mut self, mut s: Surface, pal: Palette):
        """The curves on a clear canvas (what's under it shows), drawn in as the spring opens, faded as it closes."""
        s.fill(0)
        if self.held < 0 or len(self.lines) == 0:
            return
        var box = self._box()
        var k = s.scale
        var p = min(max(self.spring.value, 0.0), 1.2)
        var reach = min(p, 1.0)  # (how far along each curve is drawn)
        var fade = min(p, 1.0) if not self.open else 1.0
        for ln in self.lines:
            var e = self._ends(ln)
            var dotted = ln.kind == ""
            var color = with_alpha(mix(pal.page, pal.accent, 0.5 if dotted else 0.85), fade)  # (opaque on the way: overlapping segments never bead)
            comptime N = 48
            var px = (e[0] - Float64(box[0])) * k
            var py = (e[1] - Float64(box[1])) * k
            for i in range(1, N + 1):
                var t = Float64(i) / Float64(N)
                if t > reach + 1e-9:
                    break
                var u = 1.0 - t
                var x = (u * u * e[0] + 2 * u * t * e[2] + t * t * e[4] - Float64(box[0])) * k
                var y = (u * u * e[1] + 2 * u * t * e[3] + t * t * e[5] - Float64(box[1])) * k
                if not dotted or i % 2 == 0:
                    stroke(s, px, py, x, y, 1.6 * k, color, clear=True)
                px = x
                py = y


def _edge(a: DropCard, b: DropCard) -> Tuple[Float64, Float64]:
    """Where the line from a's middle toward b's middle leaves a's rectangle."""
    var ax = Float64(a.x) + Float64(a.w) / 2
    var ay = Float64(a.y) + Float64(a.h) / 2
    var dx = Float64(b.x) + Float64(b.w) / 2 - ax
    var dy = Float64(b.y) + Float64(b.h) / 2 - ay
    var hw = Float64(a.w) / 2
    var hh = Float64(a.h) / 2
    var t = min(hw / abs(dx) if abs(dx) > 0 else 1e9, hh / abs(dy) if abs(dy) > 0 else 1e9)
    return (ax + dx * t, ay + dy * t)


def _short(v: Float64) -> String:
    var r = Float64(Int(abs(v) * 10.0 + 0.5)) / 10.0
    var s = String(Int(r))
    var tenth = Int((r - Float64(Int(r))) * 10.0 + 0.5)
    if tenth > 0:
        s += "." + String(tenth)
    return ("-" + s) if v < 0 else s
