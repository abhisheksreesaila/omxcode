# mojoui.freeboard: a free canvas (goal 78). Cards sit anywhere at any size, as on a whiteboard or in Figma: each keeps
# its own x, y, w, h; moving or resizing one never moves or squeezes another (overlap is allowed, the dragged card on
# top). The canvas is as big as its cards plus a margin, at least the window, so dragging past the right or bottom edge
# grows it and the page scrolls both ways. Tiling (mojoui.boardtiles) stays as Tidy, on request.
#
#   var fb = FreeBoard()                                        # (min_w, min_h: the smallest a card is resized to)
#   rects = fb.sync(tags, rects, room_w, room_h)                # new cards go to the first free spot; the rest stay
#   rects[i] = fb.drag(i, handle, dx, dy, rects, snap)          # a live drag (every motion frame) and its end: the start
#                                                               # rects are kept from the first frame, so dx, dy are from
#                                                               # where the press began; soft snap within SNAP, guides
#   fb.end()                                                    # the drag let go: the guides go
#   var size = extent(rects, room_w, room_h)                    # the canvas: the cards plus MARGIN, at least the room
#   rects = tidy(rects, room_w, room_h)                         # the old dwindle layout, no overlap
#   FreeCanvas(items, rects, room_w, room_h, fb, on_move, on_resize, …)   # the Board, with its guides, zoom and focus ring
#
# Handles (handle_at): the four edges (EDGE points inside the card) and the four corners resize; the title band (HEADER)
# moves; anything else is the card's own. A host sends a free Board's drags live: the Board's on_move / on_resize with
# event.text = "live" on every motion frame and "" at the end (event.number = the card, event.y = handle + 100 when Alt
# is held: no snap, dx/dy from the press), "zoom" for Ctrl+wheel (event.zoom = the factor) and "view" when the page
# scrolls (event.x, y = the visible part's top-left on the canvas, dx, dy = its size; all in canvas points).

from mojoui.tiling import Rect, GAP
from mojoui.boardtiles import BoardTiles
from mojoui.view import View, Board, VStack, BOARD_PLAIN, BOARD_FOCUS, NO_MSG
from mojoui.menus import Menu, Item
from std.sys import CompilationTarget, is_defined

comptime HANDLE_NONE = -1
comptime HANDLE_SE = 0  # (0: the old bottom-right corner, so an older host's resize, which sends 0, reads as it always did)
comptime HANDLE_N = 1
comptime HANDLE_S = 2
comptime HANDLE_E = 3
comptime HANDLE_W = 4
comptime HANDLE_NE = 5
comptime HANDLE_NW = 6
comptime HANDLE_SW = 7
comptime HANDLE_MOVE = 8
comptime NO_SNAP = 100  # added to event.y by hosts while Alt is held: the drag doesn't snap
comptime FIRST_FRAME = 1000  # added to event.y by hosts on a drag's first motion frame: the drag starts afresh from the rects now

comptime EDGE = 6  # the band inside each edge that resizes (points)
comptime CORNER = 16  # a corner's square (the bottom-right one is the old grip's 24)
comptime GRIP_CORNER = 24
comptime HEADER = 44  # the title band that moves a card
comptime SNAP = 8  # an edge or a size within this many points of a neighbour's snaps to it (while dragging)
comptime MARGIN = 160  # the canvas reaches this far past the right-most and the bottom-most card
comptime MIN_W = 200
comptime MIN_H = 120
comptime GUIDES = 4  # guide lines a FreeCanvas carries (unused ones sit off the canvas)
comptime ZOOMS: List[Int] = [25, 33, 50, 67, 80, 100, 125, 150, 200]  # the zoom steps, in percent
comptime HOST_ZOOMS = CompilationTarget.is_linux() and not is_defined["MOJOUI_ANDROID"]()  # this build's host draws a free canvas zoomed (GTK and
# the web, both Linux builds; AppKit, UIKit and Android show it at 100 %: their zoom items are disabled and a saved zoom is read as 100)

comptime DIR_LEFT = 0
comptime DIR_RIGHT = 1
comptime DIR_UP = 2
comptime DIR_DOWN = 3

# The keys (Hyprland's own scheme, goal 78 M2): an app gives arrange_menu(base) to its menu bar (hidden is fine: its
# items lend their shortcuts) and hands event.message - base to FreeBoard.act. Every binding is on Super and on Alt,
# because Hyprland takes Super+arrows before an app sees them.
comptime ACT_FOCUS = 0  # + DIR_…: the nearest card that way gets the focus ring
comptime ACT_MOVE = 4  # + DIR_…: the focused card moves MOVE_STEP
comptime ACT_NUDGE = 8  # + DIR_…: NUDGE_STEP
comptime ACT_RESIZE = 12  # + DIR_…: right/down grow it MOVE_STEP, left/up shrink it
comptime ACT_FILL = 16  # it fills the visible window; again: back
comptime ACT_TIDY = 17  # every card tiled (tidy)
comptime ACT_ZOOM_OUT = 18
comptime ACT_ZOOM_IN = 19
comptime ACT_ZOOM_RESET = 20
comptime ACTS = 21
comptime MOVE_STEP = 32
comptime NUDGE_STEP = 8
comptime ARROWS: List[String] = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"]
comptime DIR_WORDS: List[String] = ["left", "right", "up", "down"]


def handle_at(w: Int, h: Int, lx: Int, ly: Int) -> Int:
    """What a press at lx, ly inside a w × h card does: a corner, an edge, the title band (move) or nothing (HANDLE_NONE:
    the card's own content)."""
    if lx < 0 or ly < 0 or lx >= w or ly >= h:
        return HANDLE_NONE
    if lx >= w - GRIP_CORNER and ly >= h - GRIP_CORNER:
        return HANDLE_SE
    var left = lx < CORNER
    var right = lx >= w - CORNER
    var top = ly < CORNER
    var bottom = ly >= h - CORNER
    if (left and top) and (lx < EDGE or ly < EDGE):
        return HANDLE_NW
    if (right and top) and (lx >= w - EDGE or ly < EDGE):
        return HANDLE_NE
    if (left and bottom) and (lx < EDGE or ly >= h - EDGE):
        return HANDLE_SW
    if ly < EDGE:
        return HANDLE_N
    if ly >= h - EDGE:
        return HANDLE_S
    if lx < EDGE:
        return HANDLE_W
    if lx >= w - EDGE:
        return HANDLE_E
    if ly < HEADER:
        return HANDLE_MOVE
    return HANDLE_NONE


def handle_cursor(handle: Int) -> String:
    """The pointer's shape over a handle (CSS cursor names, which GTK takes too); "" for none."""
    if handle == HANDLE_N or handle == HANDLE_S:
        return "ns-resize"
    if handle == HANDLE_E or handle == HANDLE_W:
        return "ew-resize"
    if handle == HANDLE_NE or handle == HANDLE_SW:
        return "nesw-resize"
    if handle == HANDLE_NW or handle == HANDLE_SE:
        return "nwse-resize"
    if handle == HANDLE_MOVE:
        return "move"
    return ""


def handle_point(handle: Int, w: Int, h: Int) -> Tuple[Int, Int]:
    """Where a hand presses to grab a handle of a w × h card (test steps), in the card's coordinates."""
    var e = EDGE // 2
    if handle == HANDLE_N:
        return (w // 2, e)
    if handle == HANDLE_S:
        return (w // 2, h - 1 - e)
    if handle == HANDLE_E:
        return (w - 1 - e, h // 2)
    if handle == HANDLE_W:
        return (e, h // 2)
    if handle == HANDLE_NE:
        return (w - 1 - e, e)
    if handle == HANDLE_NW:
        return (e, e)
    if handle == HANDLE_SW:
        return (e, h - 1 - e)
    if handle == HANDLE_SE:
        return (w - 8, h - 8)
    return (CORNER + 24, HEADER // 2)


def handle_name(handle: Int) -> String:
    var names: List[String] = ["se", "n", "s", "e", "w", "ne", "nw", "sw", "move"]
    return names[handle] if 0 <= handle < len(names) else String("none")


def handle_of(name: String) -> Int:
    var names: List[String] = ["se", "n", "s", "e", "w", "ne", "nw", "sw", "move"]
    for k in range(len(names)):
        if names[k] == name:
            return k
    return HANDLE_NONE


def _moves_left(handle: Int) -> Bool:
    return handle == HANDLE_W or handle == HANDLE_NW or handle == HANDLE_SW


def _moves_right(handle: Int) -> Bool:
    return handle == HANDLE_E or handle == HANDLE_NE or handle == HANDLE_SE


def _moves_top(handle: Int) -> Bool:
    return handle == HANDLE_N or handle == HANDLE_NE or handle == HANDLE_NW


def _moves_bottom(handle: Int) -> Bool:
    return handle == HANDLE_S or handle == HANDLE_SE or handle == HANDLE_SW


@fieldwise_init
struct _Snap(Copyable, Movable, ImplicitlyCopyable):
    var delta: Int  # how far the edge moves to land on the target
    var at: Int  # the target line
    var other: Int  # the card it lines up with (-1: none)


def _snap_edge(edge: Int, rects: List[Rect], i: Int, vertical: Bool, span_lo: Int, span_hi: Int) -> _Snap:
    """The nearest neighbour line within SNAP of `edge` (a left/right edge when vertical, else a top/bottom): another
    card's edges, or, for a card beside it (their spans across, span_lo..span_hi, overlap), GAP outside them (the
    tiling's gap, so cards placed side by side line up as Tidy would)."""
    var best = _Snap(SNAP + 1, 0, -1)
    for j in range(len(rects)):
        if j == i or rects[j].w <= 0:
            continue
        ref o = rects[j]
        var lo = o.x if vertical else o.y
        var hi = (o.x + o.w) if vertical else (o.y + o.h)
        var olo = o.y if vertical else o.x
        var ohi = (o.y + o.h) if vertical else (o.x + o.w)
        var targets: List[Int] = [lo, hi]
        if span_lo < ohi and olo < span_hi:
            targets.append(lo - GAP)
            targets.append(hi + GAP)
        for t in targets:
            var d = t - edge
            if abs(d) < abs(best.delta):
                best = _Snap(d, t, j)
    return best


def _guide_v(x: Int, a: Rect, b: Rect) -> Rect:
    var top = min(a.y, b.y)
    return Rect(x, top, 1, max(a.y + a.h, b.y + b.h) - top)


def _guide_h(y: Int, a: Rect, b: Rect) -> Rect:
    var left = min(a.x, b.x)
    return Rect(left, y, max(a.x + a.w, b.x + b.w) - left, 1)


def drag_rect(start: List[Rect], i: Int, handle: Int, dx: Int, dy: Int, snap: Bool, mut guides: List[Rect],
              min_w: Int = MIN_W, min_h: Int = MIN_H) -> Rect:
    """Card i's rect `dx, dy` after a press on `handle` (the rects as they were when the press began). A move keeps the
    size; a resize moves only the edges the handle holds, never under min_w × min_h, never past the canvas's top or left.
    With `snap`, a moving edge within SNAP of a neighbour's edge (or GAP outside it) lands on it, and a resized width or
    height within SNAP of another card's lands on it; `guides` gets a thin rect per line that snapped (to draw)."""
    guides = List[Rect]()
    if i < 0 or i >= len(start):
        return Rect(0, 0, 0, 0)
    var s = start[i]
    if handle == HANDLE_MOVE:
        var x = max(s.x + dx, 0)
        var y = max(s.y + dy, 0)
        if snap:
            var l = _snap_edge(x, start, i, True, y, y + s.h)
            var r = _snap_edge(x + s.w, start, i, True, y, y + s.h)
            var best_x = l if abs(l.delta) <= abs(r.delta) else r
            if best_x.other >= 0 and abs(best_x.delta) <= SNAP and x + best_x.delta >= 0:
                x += best_x.delta
                guides.append(_guide_v(best_x.at, Rect(x, y, s.w, s.h), start[best_x.other]))
            var t = _snap_edge(y, start, i, False, x, x + s.w)
            var b = _snap_edge(y + s.h, start, i, False, x, x + s.w)
            var best_y = t if abs(t.delta) <= abs(b.delta) else b
            if best_y.other >= 0 and abs(best_y.delta) <= SNAP and y + best_y.delta >= 0:
                y += best_y.delta
                guides.append(_guide_h(best_y.at, Rect(x, y, s.w, s.h), start[best_y.other]))
        return Rect(x, y, s.w, s.h)
    var left = s.x
    var right = s.x + s.w
    var top = s.y
    var bottom = s.y + s.h
    if _moves_left(handle):
        left = min(max(s.x + dx, 0), right - min_w)
    if _moves_right(handle):
        right = max(right + dx, left + min_w)
    if _moves_top(handle):
        top = min(max(s.y + dy, 0), bottom - min_h)
    if _moves_bottom(handle):
        bottom = max(bottom + dy, top + min_h)
    if snap:
        var snapped_x = False
        var snapped_y = False
        if _moves_left(handle) or _moves_right(handle):
            var edge = left if _moves_left(handle) else right
            var e = _snap_edge(edge, start, i, True, top, bottom)
            if e.other >= 0 and abs(e.delta) <= SNAP:
                var to = edge + e.delta
                if _moves_left(handle) and 0 <= to <= right - min_w:
                    left = to
                    snapped_x = True
                elif _moves_right(handle) and to >= left + min_w:
                    right = to
                    snapped_x = True
                if snapped_x:
                    guides.append(_guide_v(e.at, Rect(left, top, right - left, bottom - top), start[e.other]))
        if _moves_top(handle) or _moves_bottom(handle):
            var edge = top if _moves_top(handle) else bottom
            var e = _snap_edge(edge, start, i, False, left, right)
            if e.other >= 0 and abs(e.delta) <= SNAP:
                var to = edge + e.delta
                if _moves_top(handle) and 0 <= to <= bottom - min_h:
                    top = to
                    snapped_y = True
                elif _moves_bottom(handle) and to >= top + min_h:
                    bottom = to
                    snapped_y = True
                if snapped_y:
                    guides.append(_guide_h(e.at, Rect(left, top, right - left, bottom - top), start[e.other]))
        if not snapped_x and (_moves_left(handle) or _moves_right(handle)):  # (no edge to land on: an equal width)
            var w = right - left
            for j in range(len(start)):
                if j == i or start[j].w <= 0:
                    continue
                var d = start[j].w - w
                if d != 0 and abs(d) <= SNAP and start[j].w >= min_w:
                    if _moves_left(handle) and left - d >= 0:
                        left -= d
                    elif _moves_right(handle):
                        right += d
                    else:
                        continue
                    guides.append(Rect(start[j].x, start[j].y - 4, start[j].w, 1))  # (the two widths, marked alike)
                    guides.append(Rect(left, top - 4, right - left, 1))
                    break
        if not snapped_y and (_moves_top(handle) or _moves_bottom(handle)):  # (an equal height)
            var h = bottom - top
            for j in range(len(start)):
                if j == i or start[j].h <= 0:
                    continue
                var d = start[j].h - h
                if d != 0 and abs(d) <= SNAP and start[j].h >= min_h:
                    if _moves_top(handle) and top - d >= 0:
                        top -= d
                    elif _moves_bottom(handle):
                        bottom += d
                    else:
                        continue
                    guides.append(Rect(start[j].x - 4, start[j].y, 1, start[j].h))
                    guides.append(Rect(left - 4, top, 1, bottom - top))
                    break
    return Rect(left, top, right - left, bottom - top)


def extent(rects: List[Rect], room_w: Int, room_h: Int) -> Tuple[Int, Int]:
    """The canvas's size: the room (the window's part), or, once a card reaches past it, every card plus MARGIN that way
    (somewhere to drag on to); a card that fills the window exactly scrolls nothing."""
    var right = 0
    var bottom = 0
    for r in rects:
        if r.w > 0 and r.h > 0:
            right = max(right, r.x + r.w)
            bottom = max(bottom, r.y + r.h)
    return (right + MARGIN if right > room_w else room_w, bottom + MARGIN if bottom > room_h else room_h)


def overlaps(a: Rect, b: Rect, gap: Int = 0) -> Bool:
    return a.x < b.x + b.w + gap and b.x < a.x + a.w + gap and a.y < b.y + b.h + gap and b.y < a.y + a.h + gap


def first_free(rects: List[Rect], w: Int, h: Int, room_w: Int) -> Rect:
    """Where a new w × h card goes: right of the last card when it fits the room's width there without covering any
    other; else a new row under every card, at the left. Nothing already there moves or shrinks."""
    var placed = List[Rect]()
    for r in rects:
        if r.w > 0 and r.h > 0:
            placed.append(r)
    if len(placed) == 0:
        return Rect(0, 0, w, h)
    ref last = placed[len(placed) - 1]
    var beside = Rect(last.x + last.w + GAP, last.y, w, h)
    if beside.x + w <= room_w:
        var clear = True
        for r in placed:
            if overlaps(beside, r):
                clear = False
                break
        if clear:
            return beside
    var bottom = 0
    for r in placed:
        bottom = max(bottom, r.y + r.h)
    return Rect(0, bottom + GAP, w, h)


def tidy(rects: List[Rect], room_w: Int, room_h: Int, min_w: Int = 300, min_h: Int = 200) raises -> List[Rect]:
    """Every card tiled as mojoui.boardtiles tiles them (each new one splits the one before; a new row below when it
    would squeeze one under min_w × min_h): no overlap, nothing left over, in the cards' order."""
    var bt = BoardTiles(min_w, min_h)
    var tags = List[String]()
    var zero = List[Rect]()
    for k in range(len(rects)):
        tags.append("c" + String(k))
        zero.append(Rect(0, 0, 0, 0))
    return bt.sync(tags, zero, room_w, room_h)


def nearest(rects: List[Rect], i: Int, dir: Int) -> Int:
    """The card nearest card i in direction `dir` (DIR_LEFT …): its middle that way, scored by how far along plus twice
    how far across; -1 when none is that way."""
    if i < 0 or i >= len(rects):
        return 0 if len(rects) > 0 else -1
    var cx = rects[i].x + rects[i].w // 2
    var cy = rects[i].y + rects[i].h // 2
    var best = -1
    var best_score = 0
    for j in range(len(rects)):
        if j == i or rects[j].w <= 0:
            continue
        var ox = rects[j].x + rects[j].w // 2
        var oy = rects[j].y + rects[j].h // 2
        var along = 0
        var across = 0
        if dir == DIR_LEFT:
            along = cx - ox
            across = abs(oy - cy)
        elif dir == DIR_RIGHT:
            along = ox - cx
            across = abs(oy - cy)
        elif dir == DIR_UP:
            along = cy - oy
            across = abs(ox - cx)
        else:
            along = oy - cy
            across = abs(ox - cx)
        if along <= 0:
            continue
        var score = along + 2 * across
        if best < 0 or score < best_score:
            best = j
            best_score = score
    return best


def nudge(r: Rect, dir: Int, step: Int) -> Rect:
    """r moved `step` points one way (never past the canvas's top or left)."""
    if dir == DIR_LEFT:
        return Rect(max(r.x - step, 0), r.y, r.w, r.h)
    if dir == DIR_RIGHT:
        return Rect(r.x + step, r.y, r.w, r.h)
    if dir == DIR_UP:
        return Rect(r.x, max(r.y - step, 0), r.w, r.h)
    return Rect(r.x, r.y + step, r.w, r.h)


def grow(r: Rect, dir: Int, step: Int, min_w: Int = MIN_W, min_h: Int = MIN_H) -> Rect:
    """Right and down make r `step` wider or taller; left and up make it that much narrower or shorter (not under the
    minimum). Its top-left stays (Hyprland's resizeactive)."""
    if dir == DIR_RIGHT:
        return Rect(r.x, r.y, r.w + step, r.h)
    if dir == DIR_LEFT:
        return Rect(r.x, r.y, max(r.w - step, min(min_w, r.w)), r.h)
    if dir == DIR_DOWN:
        return Rect(r.x, r.y, r.w, r.h + step)
    return Rect(r.x, r.y, r.w, max(r.h - step, min(min_h, r.h)))


def zoom_step(z: Int, out_: Bool) -> Int:
    """The next zoom step out (smaller) or in from z percent (ZOOMS); at the end it stays."""
    var steps = materialize[ZOOMS]()
    if out_:
        var k = len(steps) - 1
        while k >= 0:
            if steps[k] < z:
                return steps[k]
            k -= 1
        return steps[0]
    for s in steps:
        if s > z:
            return s
    return steps[len(steps) - 1]


def zoom_by(z: Int, factor: Float64) -> Int:
    """z percent scaled by a wheel's or pinch's factor, kept between the first and last ZOOMS step (100 is sticky: a
    zoom that crosses it lands on it)."""
    var steps = materialize[ZOOMS]()
    var to = Int(Float64(z) * factor + 0.5)
    if (z < 100 < to) or (z > 100 > to):
        to = 100
    return max(steps[0], min(to, steps[len(steps) - 1]))


def zoom_to_fit(rects: List[Rect], room_w: Int, room_h: Int) -> Int:
    """The largest zoom step (at most 100) that shows every card in a room_w × room_h window."""
    var w = 1
    var h = 1
    for r in rects:
        w = max(w, r.x + r.w)
        h = max(h, r.y + r.h)
    var steps = materialize[ZOOMS]()
    var k = len(steps) - 1
    while k > 0:
        if steps[k] <= 100 and w * steps[k] <= room_w * 100 and h * steps[k] <= room_h * 100:
            return steps[k]
        k -= 1
    return steps[0]


def spec(zoom: Int) -> String:
    """A free Board's text (hosts read it): its cards held to their size (clips), placed freely, at `zoom` percent."""
    return "clips free z=" + String(zoom)


def board_zoom(text: String) -> Int:
    """The zoom a Board's text names (100 when none)."""
    var at = text.find("z=")
    if at < 0:
        return 100
    var end = at + 2
    var n = 0
    var digits = 0
    while end < text.byte_length():
        var c = Int(text.as_bytes()[end])
        if c < 48 or c > 57:
            break
        n = n * 10 + (c - 48)
        digits += 1
        end += 1
    return n if digits > 0 and n > 0 else 100


def is_free(text: String) -> Bool:
    return text.startswith("clips free")


struct FreeBoard(Copyable, Movable):
    """A free canvas's state beside the app's own rects: the drag in progress (the rects when it began), its guides,
    the zoom, the focused card, the rect a filled card goes back to, and the cards seen at the last sync."""

    var min_w: Int
    var min_h: Int
    var zoom: Int  # percent
    var focus: Int  # the focused card (its ring; the keys act on it), -1: none
    var dragging: Int  # the card being dragged, -1: none
    var start: List[Rect]  # every card's rect when the drag began
    var guides: List[Rect]  # the snap lines to draw now
    var filled: Int  # the card Fill made fill the window (-1: none)
    var was: Rect  # where it was before
    var seen: List[String]  # the tags at the last sync
    var view: Rect  # the visible part of the canvas (the host's "view" events), in canvas points

    def __init__(out self, min_w: Int = MIN_W, min_h: Int = MIN_H):
        self.min_w = min_w
        self.min_h = min_h
        self.zoom = 100
        self.focus = -1
        self.dragging = -1
        self.start = List[Rect]()
        self.guides = List[Rect]()
        self.filled = -1
        self.was = Rect(0, 0, 0, 0)
        self.seen = List[String]()
        self.view = Rect(0, 0, 0, 0)

    def sync(mut self, tags: List[String], rects: List[Rect], room_w: Int, room_h: Int, sizes: List[Rect] = []) -> List[Rect]:
        """Every card's rect after cards came or went: a card whose tag wasn't there at the last sync goes to the first
        free spot (first_free) at its own size (or sizes[i]'s w × h when it has none, or the minimum), the first card
        of an empty canvas fills the room; every other card stays exactly where it is."""
        var out = List[Rect]()
        for k in range(len(rects)):
            out.append(rects[k])
        for k in range(len(tags)):
            var known = False
            for t in self.seen:
                if t == tags[k]:
                    known = True
                    break
            if known and out[k].w > 0 and out[k].h > 0:
                continue
            var w = out[k].w
            var h = out[k].h
            if w < self.min_w or h < self.min_h:
                w = sizes[k].w if k < len(sizes) and sizes[k].w > 0 else max(w, self.min_w)
                h = sizes[k].h if k < len(sizes) and sizes[k].h > 0 else max(h, self.min_h)
            var before = List[Rect]()
            for j in range(len(out)):
                if j != k and (j < k or self._has(tags[j])):  # (the cards placed so far: old ones, and new ones before it)
                    before.append(out[j])
            if len(before) == 0 and k == 0:
                out[k] = Rect(0, 0, room_w if out[k].w <= 0 else w, room_h if out[k].h <= 0 else h)
            else:
                out[k] = first_free(before, w, h, room_w)
        self.seen = tags.copy()
        if self.focus >= len(tags):
            self.focus = len(tags) - 1
        if self.filled >= len(tags):
            self.filled = -1
        return out^

    def _has(self, tag: String) -> Bool:
        for t in self.seen:
            if t == tag:
                return True
        return False

    def on_drag(mut self, i: Int, moving: Bool, y: Float64, dx: Float64, dy: Float64, rects: List[Rect]) -> Rect:
        """A host's drag event for card i (its on_move: `moving`, else on_resize; event.y carries the handle, NO_SNAP and
        FIRST_FRAME; event.dx, dy from the press): its new rect (drag())."""
        var code = Int(y)
        return self.drag(i, HANDLE_MOVE if moving else code % 100, Int(dx), Int(dy), rects, code % 1000 < NO_SNAP, code >= FIRST_FRAME)

    def drag(mut self, i: Int, handle: Int, dx: Int, dy: Int, rects: List[Rect], snap: Bool = True, first: Bool = False) -> Rect:
        """Card i dragged by `handle` dx, dy from where the press began (the first call keeps every rect as it was then: a new
        card, a host's FIRST_FRAME or an end() before begin afresh); its new rect, the guides set. It becomes the focused card;
        a filled card dragged is no longer filled."""
        if first or self.dragging != i or len(self.start) != len(rects):
            self.dragging = i
            self.start = rects.copy()
        self.focus = i
        if self.filled == i:
            self.filled = -1
        var g = List[Rect]()
        var r = drag_rect(self.start, i, handle, dx, dy, snap, g, self.min_w, self.min_h)
        self.guides = g^
        return r

    def set_zoom(mut self, z: Int):
        """The zoom (a saved one, a wheel's): kept between the steps' ends; 100 where the host doesn't zoom (HOST_ZOOMS)."""
        var steps = materialize[ZOOMS]()
        self.zoom = max(steps[0], min(z, steps[len(steps) - 1])) if HOST_ZOOMS else 100

    def end(mut self):
        """The drag let go: the guides go."""
        self.dragging = -1
        self.start = List[Rect]()
        self.guides = List[Rect]()

    def fill(mut self, i: Int, rects: List[Rect], room_w: Int, room_h: Int) -> Rect:
        """Card i fills the visible part of the canvas (the last "view" event, else the room at the top-left); a second
        Fill puts it back where it was."""
        if i < 0 or i >= len(rects):
            return Rect(0, 0, 0, 0)
        if self.filled == i:
            self.filled = -1
            return self.was
        self.filled = i
        self.was = rects[i]
        var v = self.view if self.view.w > 0 and self.view.h > 0 else Rect(0, 0, room_w * 100 // max(self.zoom, 1), room_h * 100 // max(self.zoom, 1))
        return Rect(v.x, v.y, max(v.w - GAP, self.min_w), max(v.h - GAP, self.min_h))

    def act(mut self, act: Int, rects: List[Rect], room_w: Int, room_h: Int, tidy_w: Int = 300, tidy_h: Int = 200) -> List[Rect]:
        """A key's action (ACT_…, arrange_menu) on the focused card (none focused: the first): every card's rect after it
        (a focus change or a zoom moves nothing). Tidy tiles every card into the room (tidy_w × tidy_h each at least)."""
        var out = rects.copy()
        if len(out) == 0:
            return out^
        if self.focus < 0 or self.focus >= len(out):
            self.focus = 0
        var i = self.focus
        if act < ACT_MOVE:
            var j = nearest(out, i, act - ACT_FOCUS)
            if j >= 0:
                self.focus = j
        elif act < ACT_NUDGE:
            out[i] = nudge(out[i], act - ACT_MOVE, MOVE_STEP)
        elif act < ACT_RESIZE:
            out[i] = nudge(out[i], act - ACT_NUDGE, NUDGE_STEP)
        elif act < ACT_FILL:
            out[i] = grow(out[i], act - ACT_RESIZE, MOVE_STEP, self.min_w, self.min_h)
        elif act == ACT_FILL:
            out[i] = self.fill(i, out, room_w, room_h)
        elif act == ACT_TIDY:
            try:
                out = tidy(out, room_w, room_h, tidy_w, tidy_h)
            except:
                pass
            self.filled = -1
        elif act == ACT_ZOOM_OUT and HOST_ZOOMS:  # (a host that doesn't zoom keeps 100 %: Fill fits what it shows)
            self.zoom = zoom_step(self.zoom, True)
        elif act == ACT_ZOOM_IN and HOST_ZOOMS:
            self.zoom = zoom_step(self.zoom, False)
        elif act == ACT_ZOOM_RESET:
            self.zoom = 100
        if act >= ACT_MOVE and act < ACT_FILL and self.filled == i:
            self.filled = -1
        return out^

    def tones(self, count: Int, var tones: List[Int]) -> List[Int]:
        """`tones` (one per card, BOARD_PLAIN when none) with the focused card ringed (when it stands plain)."""
        while len(tones) < count:
            tones.append(BOARD_PLAIN)
        if 0 <= self.focus < len(tones) and tones[self.focus] == BOARD_PLAIN:
            tones[self.focus] = BOARD_FOCUS
        return tones^


def guide_views(guides: List[Rect]) -> List[View]:
    """GUIDES thin views for the snap lines (tag "board-guide"; the theme draws them in the accent, quietly): the ones
    not in use sit off the canvas, so the Board keeps the same children while a drag snaps and lets go."""
    var out = List[View]()
    for k in range(GUIDES):
        if k < len(guides):
            ref g = guides[k]
            out.append(VStack(spacing=0).at(g.x, g.y).width(max(g.w, 1)).height(max(g.h, 1)).tag("board-guide"))
        else:
            out.append(VStack(spacing=0).at(-40, -40).width(1).height(1).tag("board-guide"))
    return out^


def FreeCanvas(var items: List[View], rects: List[Rect], room_w: Int, room_h: Int, fb: FreeBoard, on_move: Int, on_resize: Int,
               reveal: Int = -1, reveal_count: Int = 0, var tones: List[Int] = [], on_hold: Int = NO_MSG) -> View:
    """A Board placing `items` freely (the first len(rects) are the cards, at rects; any after them float over the page
    as they are): as big as extent(), the focused card ringed, the snap guides on top, drawn at fb.zoom. Hosts send
    drags live (see the top of this file)."""
    var size = extent(rects, room_w, room_h)
    var all = fb.tones(len(items), tones^)
    for g in guide_views(fb.guides):
        items.append(g.copy())
        all.append(BOARD_PLAIN)
    var v = Board(items^, size[0], size[1], on_move=on_move, on_resize=on_resize, reveal=reveal, reveal_count=reveal_count,
                  tones=all, on_hold=on_hold, clips=True)
    v.nodes[0].text = spec(fb.zoom)
    return v^


def act_keys(act: Int) -> Tuple[String, String]:
    """An action's two shortcuts: Super's (Hyprland's scheme) and Alt's (the same where Hyprland keeps Super); the
    names as hosts write them ("Super+Ctrl+Shift+Alt+Key")."""
    var arrows = materialize[ARROWS]()
    if act < ACT_FILL:
        var a = arrows[act % 4]
        var kind = act // 4
        if kind == 0:
            return ("Super+" + a, "Alt+" + a)
        if kind == 1:
            return ("Super+Shift+" + a, "Shift+Alt+" + a)
        if kind == 2:
            return ("Super+Shift+Alt+" + a, "Ctrl+Shift+Alt+" + a)
        return ("Super+Ctrl+" + a, "Ctrl+Alt+" + a)
    if act == ACT_FILL:
        return ("Super+F", "Alt+F")
    if act == ACT_TIDY:
        return ("Super+T", "Alt+T")
    if act == ACT_ZOOM_OUT:
        return ("Ctrl+-", "")
    if act == ACT_ZOOM_IN:
        return ("Ctrl+=", "")
    return ("Ctrl+0", "")


def act_title(act: Int) -> String:
    var words = materialize[DIR_WORDS]()
    if act < ACT_FILL:
        var kind = act // 4
        var verbs: List[String] = ["Focus the card ", "Move the card ", "Nudge the card ", "Resize the card "]
        return verbs[kind] + words[act % 4]
    var rest: List[String] = ["Fill the window", "Tidy the cards", "Zoom out", "Zoom in", "Actual size"]
    return rest[act - ACT_FILL]


def arrange_menu(base: Int, disabled: Bool = False) -> View:
    """The canvas's keys as a menu ("Arrange"): each action twice, on Super and on Alt (message base + ACT_…). Hide it
    under a ribbon: the items still lend their shortcuts. The zoom items are disabled where the host doesn't zoom (HOST_ZOOMS)."""
    var items = List[View]()
    for act in range(ACTS):
        var keys = act_keys(act)
        var off = disabled or (act >= ACT_ZOOM_OUT and not HOST_ZOOMS)
        items.append(Item(act_title(act), base + act, shortcut=keys[0], disabled=off))
        if keys[1] != "":
            items.append(Item(act_title(act) + " (Alt)", base + act, shortcut=keys[1], disabled=off))
    return Menu("Arrange", items)
