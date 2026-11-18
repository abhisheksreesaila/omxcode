# mojoui.pointer: "she points" (goal 77 M1). A card names its parts (a tag the view carries, the words that name it); while a
# reply is spoken, each clause that names a part sends an AG-UI CUSTOM event `point` {card, part, at_ms}, timed to where in the
# clause's audio the name is said; a host shows it as a soft ring that a spring moves to the part's rect, with the part
# tinted, and the orb's eyes look at it. Any AG-UI client can follow the events; this file is the part every host shares.
#
#   Part(card, part, names, cue=False, weak=False)       one pointable part: its tag is card + "." + part (View.tag), `names` the
#                                                         words that name it, `cue` words that only hint at it ("means", "for example")
#   match_clause(clause, parts) -> List[Hit]              the parts the clause names, in the order spoken; Hit.at = how far into the
#                                                         clause (0…1) the name is said. Names beat cues (a clause about a stop is
#                                                         about the stop, not about a generic "is a"). A `weak` part (the word itself,
#                                                         which is said in passing) doesn't stop the cues from counting.
#   area_part(card, part, names, inside, x0, y0, x1, y1, w, h)   a part that is a box in a picture drawn fitted inside the view
#                                                         tagged `inside` (a camera card's boxes): no view of its own
#   names_for(label, others) -> List[String]              how speech may name a thing with a label: all of it, or a distinctive word of
#                                                         it no other label shares (maps and diagrams build their parts with it)
#   point_event(card, part, at_ms) -> String              the AG-UI CUSTOM event; parse_point(text) reads it back
#
#   Pointer: update(): pointer.go(card + "." + part)      draw(): pointer.draw(surface, palette)   view(): PointerView(canvas, pointer.version())
#            pointer.know(parts): the parts on screen (the same list the voice loop gets), so a box in a picture can be found
#   The ring lives on a clear Canvas over the whole page (put it in an Overlay, like mojoui.orb.RimView). Where the part is comes
#   from mojoui.geometry.rect_of (GTK; the web host reports the rects of the tagged views it shows). It follows the part when the part
#   moves (a scroll, a resize): the target is read again every frame. The part's tint and the ring are one drawing.

from std.math import sqrt, exp
from mojoui.canvas import Surface
from mojoui.clock import now_ns
from mojoui.draw import over, with_alpha
from mojoui.geometry import rect_of
from mojoui.json import Json, json_string, J_OBJECT
from mojoui.spring import Spring
from mojoui.theme import Palette
from mojoui.view import View, Canvas

comptime POINTER_TAG = "pointer"  # the layer's own tag: rects are measured from its corner
comptime HOLD_MS = 4500  # the ring stays this long after the last point, then fades
comptime RING_GAP = 5.0  # points between the part and its ring
comptime RING_WIDTH = 2.4  # points
comptime GLOW = 9.0  # points: the soft edge outside the ring


struct Part(Copyable, Movable):
    """One pointable part of a card: a view tagged tag(), or a box in a picture drawn inside a tagged view (`inside`)."""
    var card: String  # which card ("card2")
    var part: String  # which part ("meaning")
    var names: List[String]  # how speech names it
    var cue: Bool  # `names` are cue words ("means", "for example"): they count only where no part was named
    var weak: Bool  # named by its own text (the word itself), which is said in passing: cues still count after it
    var inside: String  # "": the part is its own view; else the tag of the view whose drawing holds it (a photo's canvas)
    var area: List[Float64]  # with `inside`: [x0, y0, x1, y1, width, height], the box in the picture's own pixels and the
                             # picture's size; the picture is drawn as large as fits, centred (mojoui.picture.draw_fitted)

    def __init__(out self, card: String, part: String, names: List[String], cue: Bool = False, weak: Bool = False):
        self.card = card
        self.part = part
        self.names = names.copy()
        self.cue = cue
        self.weak = weak
        self.inside = String("")
        self.area = List[Float64]()

    def tag(self) -> String:
        return self.card + "." + self.part


def part(card: String, name: String, names: List[String], cue: Bool = False, weak: Bool = False) -> Part:
    return Part(card, name, names.copy(), cue, weak)


def area_part(card: String, name: String, names: List[String], inside: String, x0: Float64, y0: Float64, x1: Float64, y1: Float64,
              width: Int, height: Int) -> Part:
    """A part that is a box in a picture: (x0, y0)-(x1, y1) in the picture's pixels, the picture width x height drawn fitted and
    centred in the view tagged `inside` (a camera card's boxes, a Sight's)."""
    var p = Part(card, name, names.copy())
    p.inside = inside
    p.area = [x0, y0, x1, y1, Float64(width), Float64(height)]
    return p^


def part_name(label: String) -> String:
    """A label as a part's name: lower case, words joined by "-" ("Water bottle" -> "water-bottle"): a tag has no spaces."""
    return String(norm(label).strip()).replace(" ", "-")


def fitted_rect(view: List[Float64], area: List[Float64]) -> List[Float64]:
    """Where an area part's box is: [x, y, w, h] in the units of `view` ([x, y, w, h] of the view that draws the picture fitted
    and centred); [] when either is malformed."""
    if len(view) < 4 or len(area) < 6 or area[4] <= 0.0 or area[5] <= 0.0:
        return List[Float64]()
    var k = min(view[2] / area[4], view[3] / area[5])
    var left = view[0] + (view[2] - area[4] * k) / 2.0
    var top = view[1] + (view[3] - area[5] * k) / 2.0
    return [left + area[0] * k, top + area[1] * k, (area[2] - area[0]) * k, (area[3] - area[1]) * k]


@fieldwise_init
struct Hit(Copyable, Movable):
    var card: String
    var part: String
    var at: Float64  # how far into the clause the name is said, 0…1

    def tag(self) -> String:
        return self.card + "." + self.part


def norm(s: String) -> String:
    """Lower case, every run of anything but letters and digits one space, a space at both ends (" the word ") so a name is
    found only as a whole word. Bytes above 127 (accents, other scripts) count as letters."""
    var bytes = List[UInt8]()
    bytes.append(32)
    var gap = True
    for b in s.as_bytes():
        var c = Int(b)
        if 65 <= c <= 90:
            c += 32
        if (97 <= c <= 122) or (48 <= c <= 57) or c >= 128:
            bytes.append(UInt8(c))
            gap = False
        elif not gap:
            bytes.append(32)
            gap = True
    if not gap:
        bytes.append(32)
    return String(unsafe_from_utf8=bytes)


def _find(text: String, name: String) -> Int:
    """The byte index of `name` in `text` (both normalised), or -1."""
    var t = text.as_bytes()
    var n = name.as_bytes()
    if len(n) == 0 or len(n) > len(t):
        return -1
    for i in range(len(t) - len(n) + 1):
        var ok = True
        for k in range(len(n)):
            if t[i + k] != n[k]:
                ok = False
                break
        if ok:
            return i
    return -1


def _longest_first(names: List[String]) -> List[String]:
    var out = names.copy()
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j].byte_length() > out[j - 1].byte_length():
            var tmp = out[j]
            out[j] = out[j - 1]
            out[j - 1] = tmp
            j -= 1
    return out^


def match_clause(clause: String, parts: List[Part]) -> List[Hit]:
    """The parts `clause` names, in the order spoken (omx-local's Pointer.match, ported). Names beat cues."""
    var text = norm(clause)
    var out = List[Hit]()
    if len(parts) == 0 or text.byte_length() < 3:
        return out^
    var starts = List[Int]()  # taken spans (start, end), so two parts never claim the same words
    var ends = List[Int]()
    var hit_part = List[Int]()
    var hit_pos = List[Int]()
    for cue_pass in range(2):
        for p in range(len(parts)):
            if parts[p].cue != (cue_pass == 1):
                continue
            for name in _longest_first(parts[p].names):
                var n = norm(name)
                if n.byte_length() < 4:  # (" x ": fewer than two letters)
                    continue
                var i = _find(text, n)
                if i < 0:
                    continue
                var j = i + 1
                var k = i + n.byte_length() - 1
                var clash = False
                for s in range(len(starts)):
                    if j < ends[s] and starts[s] < k:
                        clash = True
                if clash:
                    continue
                starts.append(j)
                ends.append(k)
                hit_part.append(p)
                hit_pos.append(j)
                break
        if cue_pass == 0:
            var strong = False
            for h in range(len(hit_part)):
                if not parts[hit_part[h]].weak and not parts[hit_part[h]].cue:
                    strong = True
            if strong:  # cue words only count where no part was named: a clause about a stop is about the stop
                break
    # in the order spoken, each part once
    var order = List[Int]()
    for h in range(len(hit_part)):
        order.append(h)
    for i in range(1, len(order)):
        var j = i
        while j > 0 and hit_pos[order[j]] < hit_pos[order[j - 1]]:
            var tmp = order[j]
            order[j] = order[j - 1]
            order[j - 1] = tmp
            j -= 1
    var seen = List[Int]()
    for h in order:
        var p = hit_part[h]
        var dup = False
        for q in seen:
            if q == p:
                dup = True
        if dup:
            continue
        seen.append(p)
        out.append(Hit(parts[p].card, parts[p].part, Float64(hit_pos[h]) / Float64(max(1, text.byte_length()))))
    return out^


comptime GENERIC_WORDS: List[String] = [
    "the", "a", "an", "of", "and", "in", "at", "on", "to", "de", "da", "do", "la", "le", "el", "tower", "museum", "park", "square",
    "street", "bridge", "palace", "church", "castle", "market", "beach", "station", "garden", "gardens", "old", "town", "city",
    "centre", "center", "national", "river", "lake", "hill", "district", "quarter", "monastery", "cathedral", "house", "hotel",
    "restaurant", "cafe",
]


def names_for(label: String, others: List[String]) -> List[String]:
    """How speech may name a thing: its full label, a distinctive word of it that no other label shares, and the label without
    a leading article."""
    var out = List[String]()
    out.append(label)
    var shared = List[String]()
    for o in others:
        if o != label:
            for w in String(norm(o).strip()).split(" "):
                shared.append(String(w))
    for w in String(norm(label).strip()).split(" "):
        var word = String(w)
        if word.byte_length() < 4:
            continue
        var generic = False
        for g in materialize[GENERIC_WORDS]():
            if g == word:
                generic = True
        var common = False
        for s in shared:
            if s == word:
                common = True
        if not generic and not common:
            out.append(word)
    var lower = label.lower()
    for article in ["the ", "a ", "an "]:
        if lower.startswith(article):
            out.append(String(label[byte = article.byte_length() :]))
    return out^


# ---------------------------------------------------------------------------------------------------------------------
# the AG-UI event
# ---------------------------------------------------------------------------------------------------------------------

def point_event(card: String, part: String, at_ms: Int) -> String:
    """The AG-UI CUSTOM event: {"type":"CUSTOM","name":"point","value":{"card","part","at_ms"}}. at_ms: where in the clause's
    audio the name is said (an AG-UI client that plays the audio itself shows the point then)."""
    return '{"type":"CUSTOM","name":"point","value":{"card":' + json_string(card) + ',"part":' + json_string(part) + ',"at_ms":' + String(at_ms) + "}}"


def parse_point(event: String) -> Optional[Hit]:
    """A CUSTOM `point` event as a Hit (at: at_ms / 1000, in seconds), or None when it isn't one."""
    try:
        var j = Json.parse(event)
        if j.kind(0) != J_OBJECT or j.text(j.get(0, "type")) != "CUSTOM" or j.text(j.get(0, "name")) != "point":
            return None
        var v = j.get(0, "value")
        if v < 0:
            return None
        return Hit(j.text(j.get(v, "card")), j.text(j.get(v, "part")), j.real(j.get(v, "at_ms")) / 1000.0)
    except:
        return None


# ---------------------------------------------------------------------------------------------------------------------
# the ring
# ---------------------------------------------------------------------------------------------------------------------

def _round_box(px: Float64, py: Float64, cx: Float64, cy: Float64, hw: Float64, hh: Float64, r: Float64) -> Float64:
    """Signed distance from (px, py) to a rounded box (negative inside)."""
    var qx = abs(px - cx) - (hw - r)
    var qy = abs(py - cy) - (hh - r)
    return sqrt(max(qx, 0.0) * max(qx, 0.0) + max(qy, 0.0) * max(qy, 0.0)) + min(max(qx, qy), 0.0) - r


struct Pointer(Movable):
    """What the pointer is doing: the part it was last sent to, the spring-moved rect of the ring, how visible it is. The app
    calls go() on a `point` event and draws it on the layer's canvas; the host's frames step the springs."""

    var tag: String  # the pointed-at view's tag ("" none)
    var cx: Spring  # the ring's rect in points from the layer's corner
    var cy: Spring
    var w: Spring
    var h: Spring
    var on: Spring  # 0…1: the ring's presence
    var stamp: Int  # moves on every go()/clear(): the canvas's version
    var until_ns: Int  # the ring fades after this
    var last_ns: Int
    var placed: Bool  # the rect has been placed once (the first appearance grows in from the target's middle)
    var pending: Bool  # a target is set and its rect hasn't been found yet
    var set_ns: Int  # when go() was called
    var shown_ns: Int  # when the ring was first drawn on the current target (0: not yet)
    var shown_stamp: Int
    var seen: Int  # how many times a ring has been shown (go() calls drawn)
    var rect: List[Float64]  # the target's rect as last found, in points from the layer's corner (empty: not found)
    var areas: List[Part]  # the parts on screen that are boxes in a picture (know()): found through the picture's view

    def __init__(out self):
        self.tag = ""
        self.cx = Spring(0.0, 260.0, 27.0)
        self.cy = Spring(0.0, 260.0, 27.0)
        self.w = Spring(0.0, 260.0, 27.0)
        self.h = Spring(0.0, 260.0, 27.0)
        self.on = Spring(0.0, 170.0, 26.0)
        self.stamp = 0
        self.until_ns = 0
        self.last_ns = 0
        self.placed = False
        self.pending = False
        self.set_ns = 0
        self.shown_ns = 0
        self.shown_stamp = -1
        self.seen = 0
        self.rect = List[Float64]()
        self.areas = List[Part]()

    def know(mut self, parts: List[Part]):
        """The parts on screen: those that are boxes in a picture are found through their picture's view."""
        self.areas = List[Part]()
        for p in parts:
            if p.inside != "":
                self.areas.append(p.copy())

    def where(self, tag: String) -> List[Float64]:
        """The part tagged `tag` in window points ([x, y, w, h]): its view's rect, or its box in its picture's view; [] unknown."""
        for a in self.areas:
            if a.tag() == tag:
                return fitted_rect(rect_of(a.inside), a.area)
        return rect_of(tag)

    def go(mut self, tag: String):
        """Point at the view tagged `tag` (a part's card + "." + part)."""
        self.tag = tag
        self.stamp += 1
        self.set_ns = now_ns()
        self.until_ns = self.set_ns + HOLD_MS * 1_000_000
        self.pending = True
        self.on.to(1.0)

    def clear(mut self):
        """Let go now: the ring fades."""
        if self.tag != "":
            self.until_ns = 0
            self.stamp += 1

    def version(self) -> Int:
        return self.stamp

    def active(self) -> Bool:
        """The ring is on screen or about to be (the orb's eyes follow it)."""
        return self.tag != "" and self.on.value > 0.02 and len(self.rect) == 4

    def shown(self) -> Bool:
        """The ring has been drawn on the current target."""
        return self.shown_stamp == self.stamp and self.shown_ns > 0

    def look(self, from_tag: String) -> Tuple[Float64, Float64, Float64]:
        """Which way the view tagged `from_tag` (the orb) looks to see the target: a unit vector (x, y) and how much (0…1,
        the ring's presence); (0, 0, 0) when nothing is pointed at or either rect is unknown."""
        if self.tag == "" or self.on.value < 0.02:
            return (0.0, 0.0, 0.0)
        var a = rect_of(from_tag)
        var b = self.where(self.tag)
        if len(a) < 4 or len(b) < 4:
            return (0.0, 0.0, 0.0)
        var dx = (b[0] + b[2] / 2.0) - (a[0] + a[2] / 2.0)
        var dy = (b[1] + b[3] / 2.0) - (a[1] + a[3] / 2.0)
        var d = sqrt(dx * dx + dy * dy)
        if d < 1.0:
            return (0.0, 0.0, self.on.value)
        return (dx / d, dy / d, self.on.value)

    def locate(mut self) -> Bool:
        """The target's rect from the host, in points from the layer's corner; False when the host can't say (the part isn't on
        screen: a card scrolled off, not built yet)."""
        var r = self.where(self.tag)
        if len(r) < 4:
            self.rect = List[Float64]()
            return False
        var origin = rect_of(POINTER_TAG)
        var ox = origin[0] if len(origin) >= 4 else 0.0
        var oy = origin[1] if len(origin) >= 4 else 0.0
        self.rect = [r[0] - ox, r[1] - oy, r[2], r[3]]
        return r[2] > 0.0 and r[3] > 0.0

    def draw(mut self, mut s: Surface, p: Palette):
        """The ring on a clear canvas: the part tinted, a ring a little way out, a soft glow beyond it. Springs step by the time
        since the last frame; asks for the next frame while anything moves or shows."""
        s.fill(0)
        var now = now_ns()
        var dt = Float64(now - self.last_ns) / 1e9 if self.last_ns > 0 else 0.016
        self.last_ns = now
        if self.tag == "":
            return
        if now > self.until_ns:
            self.on.to(0.0)
        var found = self.locate() if self.on.target > 0.0 or self.on.value > 0.01 else False
        var us = Int(dt * 1e6)
        if found:
            var r = self.rect.copy()
            if not self.placed or self.on.value < 0.02:  # (first appearance: it grows out of the target's middle)
                self.cx.snap(r[0] + r[2] / 2.0)
                self.cy.snap(r[1] + r[3] / 2.0)
                self.w.snap(r[2] * 0.6)
                self.h.snap(r[3] * 0.6)
                self.placed = True
            self.cx.to(r[0] + r[2] / 2.0)
            self.cy.to(r[1] + r[3] / 2.0)
            self.w.to(r[2])
            self.h.to(r[3])
            if s.still:
                self.cx.snap(r[0] + r[2] / 2.0)
                self.cy.snap(r[1] + r[3] / 2.0)
                self.w.snap(r[2])
                self.h.snap(r[3])
                self.on.snap(self.on.target)
        var moving = self.cx.step(us)
        moving = self.cy.step(us) or moving
        moving = self.w.step(us) or moving
        moving = self.h.step(us) or moving
        moving = self.on.step(us) or moving
        if found and self.on.value > 0.04:
            if self.shown_stamp != self.stamp:
                self.shown_stamp = self.stamp
                self.shown_ns = now
                self.seen += 1
            self.paint(s, p)
        if moving or found or self.pending:
            s.again = self.on.value > 0.004 or self.on.target > 0.0
        if found:
            self.pending = False
        elif now - self.set_ns > 2_500_000_000:
            self.pending = False  # (the part never appeared: stop asking)
        if self.on.target == 0.0 and self.on.value <= 0.004:
            self.tag = ""
            self.placed = False

    def paint(self, mut s: Surface, p: Palette):
        var k = s.scale
        var a = self.on.value
        var cx = self.cx.value * k
        var cy = self.cy.value * k
        var hw = max(self.w.value * k / 2.0, 4.0)
        var hh = max(self.h.value * k / 2.0, 4.0)
        var gap = RING_GAP * k
        var radius = min(min(hw, hh), 14.0 * k)
        var reach = gap + GLOW * k + 2.0 * k
        var x0 = max(Int(cx - hw - reach), 0)
        var x1 = min(Int(cx + hw + reach) + 1, s.width)
        var y0 = max(Int(cy - hh - reach), 0)
        var y1 = min(Int(cy + hh + reach) + 1, s.height)
        var tint = with_alpha(p.accent, 0.13 * a)
        var ring = with_alpha(p.accent, 0.92 * a)
        var glow = with_alpha(p.accent, 0.30 * a)
        var half = RING_WIDTH * k / 2.0
        var soft = GLOW * k
        for py in range(y0, y1):
            for px in range(x0, x1):
                var d = _round_box(Float64(px) + 0.5, Float64(py) + 0.5, cx, cy, hw, hh, radius)
                var at = s.pixels().unsafe_offset(py * s.width + px)
                var v = at[]
                if d < 0.0:
                    v = over(v, tint, min(1.0, -d + 0.5))
                var off = d - (gap + radius * 0.0)
                if off > -soft and off < soft:
                    v = over(v, glow, exp(-(off * off) / (soft * soft * 0.35)))
                var cov = half + 0.5 - abs(off)
                if cov > 0.0:
                    v = over(v, ring, min(cov, 1.0))
                at[] = v


def PointerView(canvas: Int, version: Int) -> View:
    """The ring's Canvas, over the whole page (put it in an Overlay after the page): presses go through to the page."""
    return Canvas(canvas, version).passthrough().fill().grow().tag(POINTER_TAG)
