# mojoui.livetiles: live tiles on one Canvas (goal 77 M7b, D-7782): tiles of five sizes on an exact 4 x 3 grid, sized by
# importance, that change size like water (each glides to its new place while its surface grows or shrinks; the words are
# laid out at the final size from the first frame and faded in, never stretched), press in, drag to reorder and resize by a
# corner grip. One drawing serves GTK, the web host and the Mac: every host only shows the Canvas's pixels.
#
#   var tiles = LiveTiles()
#   var t = Tile("traffic", hx("#15803D"), "Traffic", "Leave by 8:05", "Bridge is slow", icon="car")
#   t.faces.append(Face("26 min to school", "via the river road")); t.why = "you leave in 20 minutes"; t.actions = [...]
#   tiles.set_tiles(list)                 # most urgent first; a tile with `big` makes the layout [xl, w, w]; call again
#                                         # whenever importance or contents change: what moved glides there (water)
#   Canvas(id, tiles.version, on_gesture=G, on_frame=F).grow().fill()
#   update: G -> tiles.gesture(event.number, event.x, event.y)       (PRESS, PAN, RELEASE, TAP)
#           F -> _ = tiles.frame(event.number)                        (microseconds; True while something moves)
#           for r in tiles.take_results(): r.kind = TAPPED | ACTION (r.text = the action) | REORDERED (r.text = the ids in
#                                          the new order, comma-separated) | RESIZED (r.text = "s", "w", "l", "xl")
#   draw:   tiles.draw(surface, TileLook.of(palette), font)          (fills the canvas with look.ground first)
#   tiles.parts(card, canvas_tag)  -> List[Part]   each tile pointable by its head and id (mojoui.pointer area parts);
#   tiles.spots(card, canvas_tag)                  ...and reported as moving spots every draw, so the ring follows a glide
#   tiles.layout() -> TileLayout   ids shown, their sizes and cells, the ids that did not fit (the caller shows them
#                                  elsewhere) and the empty cells (a user's size can leave holes; reported, not hidden)
#   tiles.charm_anchors()          where each tile's charm hangs now (a charm this module does not draw itself: M7e's)
#   tiles.record()                 one line per tile as last drawn: its surface and its words' box (a proof's evidence)
#   tiles.reset()                  forget the user's order and sizes
#
# The pure layout (preset, pack, cell_box, press_amount) has no Canvas in it: tests/test_livetiles.mojo calls it directly.
# Presets by tile count keep the grid full: 6 = l w w w s s, 5 = l w w w w, 4 = l l w w, 3 = xl w w, 2 = xl band, 1 = xl;
# packing is CSS grid-auto-flow: dense, in order. More than 6 tiles (3 with a big one): the rest are reported as overflow.
# Motion: the water spring (k 150, c 19.5: about 2 % overshoot, settled in ~0.7 s) moves a tile's rect; the press is
# omxqua's (0.90 for <= 48 pt, 0.955 for <= 260 pt, else 0.975, back on the fast spring k 380 c 30); faces turn every
# 6.5 s on a slow spring that does not overshoot. Reduced motion (set_reduced, or a still Surface): everything lands at once.

from mojoui.canvas import Surface
from mojoui.clock import now_ns
from mojoui.draw import rect, line, circle, with_alpha, soft_shadow, gradient_rect
from mojoui.geometry import put_spot
from mojoui.pointer import Part, area_part, part_name
from mojoui.spring import Spring
from mojoui.text import Font, MEDIUM, REGULAR, CENTRE
from mojoui.theme import Palette, Shadow, mix, rgba
from mojoui.tiling import Rect
from mojoui.view import PAN, TAP, PRESS, RELEASE

comptime TILE_S = 0  # 1 x 1
comptime TILE_W = 1  # 2 x 1
comptime TILE_L = 2  # 2 x 2
comptime TILE_XL = 3  # 4 x 2
comptime TILE_BAND = 4  # 4 x 1
comptime SIZE_AUTO = -1  # the preset's size

comptime COLS = 4
comptime ROWS = 3
comptime GAP = 12.0  # points between tiles
comptime PAD = 14.0  # points from the canvas's edge to the grid (room for the shadows)
comptime RADIUS = 22.0
comptime WATER_K = 150.0
comptime WATER_C = 19.5
comptime FAST_K = 380.0  # omxqua's --oq-spring-fast
comptime FAST_C = 30.0
comptime SLOW_K = 90.0  # a face turning over: critical (c = 2 sqrt k), no overshoot
comptime SLOW_C = 19.0
comptime FACE_MS = 6500
comptime DRAG_START = 7.0  # points the pointer moves before a press becomes a drag
comptime SWAP_MS = 160  # a dragged tile passes over another at most this often
comptime GRIP = 30.0  # the corner grip's square, points
comptime LIFT = 1.04
comptime FADE_FROM = 0.3  # the words stay clear until this far into the water's time

# results (TileResult.kind)
comptime TAPPED = 1
comptime ACTION = 2
comptime REORDERED = 3
comptime RESIZED = 4

# what the pointer is doing
comptime _IDLE = 0
comptime _PRESSING = 1
comptime _DRAGGING = 2
comptime _RESIZING = 3


# ------------------------------------------------------------------------------------------------ the pure layout


def size_cols(size: Int) -> Int:
    return 1 if size == TILE_S else (2 if size == TILE_W or size == TILE_L else 4)


def size_rows(size: Int) -> Int:
    return 2 if size == TILE_L or size == TILE_XL else 1


def size_name(size: Int) -> String:
    if size == TILE_S:
        return "s"
    if size == TILE_W:
        return "w"
    if size == TILE_L:
        return "l"
    if size == TILE_XL:
        return "xl"
    return "band"


def preset(n: Int) -> List[Int]:
    """The sizes that fill the 4 x 3 grid exactly for n tiles (n > 6: the first six)."""
    if n <= 0:
        return List[Int]()
    if n == 1:
        return [TILE_XL]
    if n == 2:
        return [TILE_XL, TILE_BAND]
    if n == 3:
        return [TILE_XL, TILE_W, TILE_W]
    if n == 4:
        return [TILE_L, TILE_L, TILE_W, TILE_W]
    if n == 5:
        return [TILE_L, TILE_W, TILE_W, TILE_W, TILE_W]
    return [TILE_L, TILE_W, TILE_W, TILE_W, TILE_S, TILE_S]


@fieldwise_init
struct Packing(Copyable, Movable):
    var cells: List[Rect]  # in grid cells; one per size given (w = 0 where it did not fit)
    var fits: List[Bool]
    var holes: Int  # cells left empty


def pack(sizes: List[Int]) -> Packing:
    """CSS grid-auto-flow: dense on 4 x 3: each tile, in order, takes the first place (row by row) where it fits."""
    var used = List[Bool](length=COLS * ROWS, fill=False)
    var cells = List[Rect]()
    var fits = List[Bool]()
    var filled = 0
    for i in range(len(sizes)):
        var cw = size_cols(sizes[i])
        var rh = size_rows(sizes[i])
        var placed = False
        for r in range(ROWS - rh + 1):
            for c in range(COLS - cw + 1):
                var free = True
                for dr in range(rh):
                    for dc in range(cw):
                        if used[(r + dr) * COLS + c + dc]:
                            free = False
                if free:
                    for dr in range(rh):
                        for dc in range(cw):
                            used[(r + dr) * COLS + c + dc] = True
                    cells.append(Rect(c, r, cw, rh))
                    filled += cw * rh
                    placed = True
                    break
            if placed:
                break
        if not placed:
            cells.append(Rect(0, 0, 0, 0))
        fits.append(placed)
    return Packing(cells^, fits^, COLS * ROWS - filled)


@fieldwise_init
struct Box(Copyable, Movable, ImplicitlyCopyable):
    var x: Float64
    var y: Float64
    var w: Float64
    var h: Float64

    def has(self, px: Float64, py: Float64) -> Bool:
        return self.x <= px < self.x + self.w and self.y <= py < self.y + self.h


def cell_box(c: Rect, width: Float64, height: Float64) -> Box:
    """A cell rect's box in points on a canvas width x height (the grid inset by PAD, GAP between cells)."""
    var cw = (width - 2 * PAD - Float64(COLS - 1) * GAP) / Float64(COLS)
    var ch = (height - 2 * PAD - Float64(ROWS - 1) * GAP) / Float64(ROWS)
    return Box(PAD + Float64(c.x) * (cw + GAP), PAD + Float64(c.y) * (ch + GAP),
               Float64(c.w) * cw + Float64(c.w - 1) * GAP, Float64(c.h) * ch + Float64(c.h - 1) * GAP)


def press_amount(width: Float64) -> Float64:
    """omxqua's press by size (omxqua.js): small things squash more, big things less."""
    return 0.9 if width <= 48 else (0.955 if width <= 260 else 0.975)


def snap_size(w: Float64, h: Float64, width: Float64, height: Float64) -> Int:
    """The size a grip drag snaps to: s, w, l or xl, whichever cell count is nearest to a w x h box."""
    var cw = (width - 2 * PAD - Float64(COLS - 1) * GAP) / Float64(COLS)
    var ch = (height - 2 * PAD - Float64(ROWS - 1) * GAP) / Float64(ROWS)
    var cx = max(1.0, (w + GAP) / (cw + GAP))
    var cy = max(1.0, (h + GAP) / (ch + GAP))
    var best = TILE_S
    var bd = 1e9
    for s in [TILE_S, TILE_W, TILE_L, TILE_XL]:
        var d = abs(Float64(size_cols(s)) - cx) + abs(Float64(size_rows(s)) - cy)
        if d < bd:
            bd = d
            best = s
    return best


def water_ms() -> Int:
    """How long the water spring takes to settle a unit move (the words' fade runs over this): ~0.7 s."""
    var s = Spring(0.0, WATER_K, WATER_C)
    s.to(1.0)
    var us = 0
    while s.step(4167) and us < 3_000_000:
        us += 4167
    return us // 1000


def fade_at(ms: Float64, total_ms: Float64) -> Float64:
    """The words' opacity this far into a size change: clear until FADE_FROM of the way, then easing out to 1."""
    var t = ms / max(total_ms, 1.0)
    if t <= FADE_FROM:
        return 0.0
    var u = min((t - FADE_FROM) / (1.0 - FADE_FROM), 1.0)
    return 1.0 - (1.0 - u) * (1.0 - u)


# ------------------------------------------------------------------------------------------------ the model


@fieldwise_init
struct Face(Copyable, Movable):
    var big: String
    var sub: String


struct Tile(Copyable, Movable):
    """One tile. `color` is its kind's colour (the icon square, the wash, the why chip); `icon`: car, cloud, todo, cal,
    gift, cam, timer, plane, home or "" (the head's first letter); `faces` turn over one at a time; `why` and `actions` show
    on a large tile; `big` asks for the 3-tile xl layout; `size` a fixed size (SIZE_AUTO: the preset's); `charm` a drawing
    that hangs on its top edge ("pin" is built in; others are the caller's, at charm_anchors())."""

    var id: String
    var color: UInt32
    var icon: String
    var head: String
    var faces: List[Face]
    var why: String
    var actions: List[String]
    var big: Bool
    var size: Int
    var charm: String

    def __init__(out self, id: String, color: UInt32, head: String, big_line: String, sub_line: String, icon: String = ""):
        self.id = id
        self.color = color
        self.icon = icon
        self.head = head
        self.faces = [Face(big_line, sub_line)]
        self.why = ""
        self.actions = List[String]()
        self.big = False
        self.size = SIZE_AUTO
        self.charm = ""


@fieldwise_init
struct TileResult(Copyable, Movable):
    var kind: Int
    var id: String
    var text: String


@fieldwise_init
struct TileLayout(Copyable, Movable):
    var ids: List[String]  # shown, in order
    var sizes: List[Int]
    var cells: List[Rect]
    var overflow: List[String]  # did not fit: the caller shows them elsewhere
    var holes: Int
    var urgent: String  # the tile shown as the urgent one (its why chip), "" none


struct TileLook(Copyable, Movable):
    """Colours and shadows: from the theme's Palette (card, ink, ink2, page as the ground, line); the shadows are the
    Counter family's (gitaway's sh2 for a tile, sh3 for a large one, a lifted one while dragged) unless a theme sets them."""

    var dark: Bool
    var ground: UInt32
    var card: UInt32
    var ink: UInt32
    var ink2: UInt32
    var line: UInt32
    var rest: List[Shadow]
    var raised: List[Shadow]
    var lifted: List[Shadow]

    def __init__(out self, dark: Bool, ground: UInt32, card: UInt32, ink: UInt32, ink2: UInt32, line: UInt32):
        self.dark = dark
        self.ground = ground
        self.card = card
        self.ink = ink
        self.ink2 = ink2
        self.line = line
        if dark:
            self.rest = [Shadow(1, 0, 0, rgba(255, 255, 255, 13), True), Shadow(8, 24, 0, rgba(0, 0, 0, 140), False)]
            self.raised = [Shadow(1, 0, 0, rgba(255, 255, 255, 15), True), Shadow(30, 70, -20, rgba(0, 0, 0, 204), False)]
            self.lifted = [Shadow(24, 60, 0, rgba(0, 0, 0, 160), False)]
        else:
            self.rest = [Shadow(2, 4, 0, rgba(0, 0, 0, 13), False), Shadow(14, 32, -16, rgba(0, 0, 0, 64), False)]
            self.raised = [Shadow(2, 4, 0, rgba(0, 0, 0, 10), False), Shadow(30, 60, -28, rgba(0, 0, 0, 71), False)]
            self.lifted = [Shadow(24, 60, 0, rgba(0, 0, 0, 77), False)]

    @staticmethod
    def of(p: Palette) -> TileLook:
        return TileLook(p.dark, p.page, p.card, p.ink, p.ink2, p.line)


struct _Anim(Copyable, Movable):
    """One shown tile's motion: from -> to on the water spring (p 0 -> 1), its words' fade, press, lift and face."""

    var id: String
    var fr: Box
    var to: Box
    var p: Spring
    var fade_us: Int  # time since its size changed; -1: no fade running
    var press: Spring
    var press_amt: Float64
    var lift: Spring
    var face: Spring
    var face_wait_us: Int

    def __init__(out self, id: String, at: Box, order: Int):
        self.id = id
        self.fr = at
        self.to = at
        self.p = Spring(1.0, WATER_K, WATER_C)
        self.fade_us = -1
        self.press = Spring(1.0, FAST_K, FAST_C)
        self.press_amt = 1.0
        self.lift = Spring(1.0, FAST_K, FAST_C)
        self.face = Spring(0.0, SLOW_K, SLOW_C)
        self.face_wait_us = FACE_MS * 1000 + order * 700_000

    def cur(self) -> Box:
        var q = self.p.value
        return Box(self.fr.x + (self.to.x - self.fr.x) * q, self.fr.y + (self.to.y - self.fr.y) * q,
                   self.fr.w + (self.to.w - self.fr.w) * q, self.fr.h + (self.to.h - self.fr.h) * q)


def _same(a: Box, b: Box) -> Bool:
    return abs(a.x - b.x) < 0.5 and abs(a.y - b.y) < 0.5 and abs(a.w - b.w) < 0.5 and abs(a.h - b.h) < 0.5


def _f1(v: Float64) -> String:
    var n = Int(abs(v) * 10.0 + 0.5)
    return ("-" if v < 0 and n > 0 else "") + String(n // 10) + "." + String(n % 10)


struct LiveTiles(Movable):
    var tiles: List[Tile]
    var version: Int  # put it in the Canvas: it moves on whenever the picture changes
    var width: Float64  # the canvas, points (from the last draw)
    var height: Float64
    var reduced: Bool
    var user_order: List[String]
    var user_ids: List[String]  # sizes the user chose with the grip
    var user_sizes: List[Int]
    var lead_off: String  # the urgent tile the user moved out of the lead (it leads again when importance changes)
    var anims: List[_Anim]
    var results: List[TileResult]
    var selected: String
    var water_us: Int
    var clock_us: Int  # time from frame events (the proof's timeline)
    # the pointer
    var mode: Int
    var active: String
    var sx: Float64
    var sy: Float64
    var px: Float64
    var py: Float64
    var ox: Float64
    var oy: Float64
    var start: Box
    var last_over: String
    var last_swap_ns: Int
    var resized: Bool
    # the last drawing (hit tests, the record)
    var drawn_ids: List[String]
    var drawn_surf: List[Box]
    var drawn_text: List[Box]
    var drawn_op: List[Float64]
    var drawn_font: List[Float64]
    var pill_ids: List[String]
    var pill_text: List[String]
    var pill_box: List[Box]
    var spot_card: String
    var spot_inside: String

    def __init__(out self):
        self.tiles = List[Tile]()
        self.version = 1
        self.width = 0
        self.height = 0
        self.reduced = False
        self.user_order = List[String]()
        self.user_ids = List[String]()
        self.user_sizes = List[Int]()
        self.lead_off = ""
        self.anims = List[_Anim]()
        self.results = List[TileResult]()
        self.selected = ""
        self.water_us = water_ms() * 1000
        self.clock_us = 0
        self.mode = _IDLE
        self.active = ""
        self.sx = 0
        self.sy = 0
        self.px = 0
        self.py = 0
        self.ox = 0
        self.oy = 0
        self.start = Box(0, 0, 0, 0)
        self.last_over = ""
        self.last_swap_ns = 0
        self.resized = False
        self.drawn_ids = List[String]()
        self.drawn_surf = List[Box]()
        self.drawn_text = List[Box]()
        self.drawn_op = List[Float64]()
        self.drawn_font = List[Float64]()
        self.pill_ids = List[String]()
        self.pill_text = List[String]()
        self.pill_box = List[Box]()
        self.spot_card = ""
        self.spot_inside = ""

    # ---------------------------------------------------------------- feeding it

    def set_tiles(mut self, tiles: List[Tile]):
        """The tiles, most urgent first. What changed place or size glides there."""
        self.tiles = tiles.copy()
        self._retarget(False)

    def set_area(mut self, width: Float64, height: Float64):
        """The canvas's size in points (draw() sets it; a test or a caller before the first draw may)."""
        if abs(width - self.width) > 0.5 or abs(height - self.height) > 0.5:
            self.width = width
            self.height = height
            self._retarget(True)

    def set_reduced(mut self, reduced: Bool):
        self.reduced = reduced

    def reset(mut self):
        """Forget the user's order and sizes (the presets again)."""
        self.user_order.clear()
        self.user_ids.clear()
        self.user_sizes.clear()
        self.lead_off = ""
        self._retarget(False)

    def user_size(self, id: String) -> Int:
        for i in range(len(self.user_ids)):
            if self.user_ids[i] == id:
                return self.user_sizes[i]
        return SIZE_AUTO

    def set_user_size(mut self, id: String, size: Int):
        for i in range(len(self.user_ids)):
            if self.user_ids[i] == id:
                self.user_sizes[i] = size
                self._retarget(False)
                return
        self.user_ids.append(id)
        self.user_sizes.append(size)
        self._retarget(False)

    def take_results(mut self) -> List[TileResult]:
        var out = self.results.copy()
        self.results.clear()
        return out^

    # ---------------------------------------------------------------- the layout

    def _index(self, id: String) -> Int:
        for i in range(len(self.tiles)):
            if self.tiles[i].id == id:
                return i
        return -1

    def layout(self) -> TileLayout:
        var n = len(self.tiles)
        var order = List[Int]()
        var bigi = -1
        for i in range(n):
            if self.tiles[i].big and bigi < 0:
                bigi = i
        if bigi >= 0:
            order.append(bigi)
        for i in range(n):
            if i != bigi:
                order.append(i)
        var keep_lead = True
        if len(self.user_order) > 0 and n > 0:
            var lead = order[0]
            keep_lead = self.tiles[lead].id != self.lead_off
            var rest = List[Int]()
            var keys = List[Int]()
            for j in range(len(order)):
                if keep_lead and j == 0:
                    continue
                var at = 1000 + j
                for u in range(len(self.user_order)):
                    if self.user_order[u] == self.tiles[order[j]].id:
                        at = u
                rest.append(order[j])
                keys.append(at)
            for a in range(1, len(rest)):  # (stable insertion sort by the user's position)
                var b = a
                while b > 0 and keys[b - 1] > keys[b]:
                    var tk = keys[b]
                    keys[b] = keys[b - 1]
                    keys[b - 1] = tk
                    var tr = rest[b]
                    rest[b] = rest[b - 1]
                    rest[b - 1] = tr
                    b -= 1
            var again = List[Int]()
            if keep_lead:
                again.append(lead)
            for r in rest:
                again.append(r)
            order = again^
        var limit = 3 if bigi >= 0 else 6
        var shown = List[Int]()
        var overflow = List[String]()
        for j in range(len(order)):
            if j < limit:
                shown.append(order[j])
            else:
                overflow.append(self.tiles[order[j]].id)
        var pre = preset(len(shown))
        var sizes = List[Int]()
        for j in range(len(shown)):
            var t = shown[j]
            var s = self.user_size(self.tiles[t].id)
            if s == SIZE_AUTO:
                s = self.tiles[t].size
            if s == SIZE_AUTO:
                s = TILE_XL if t == bigi else pre[j]
            sizes.append(s)
        var pk = pack(sizes)
        var ids = List[String]()
        var out_sizes = List[Int]()
        var cells = List[Rect]()
        for j in range(len(shown)):
            if pk.fits[j]:
                ids.append(self.tiles[shown[j]].id)
                out_sizes.append(sizes[j])
                cells.append(pk.cells[j])
            else:
                overflow.append(self.tiles[shown[j]].id)
        var urgent = String("")
        if len(ids) > 0 and len(shown) > 0 and keep_lead and ids[0] == self.tiles[shown[0]].id:
            var t0 = shown[0]
            if self.user_size(ids[0]) == SIZE_AUTO and self.tiles[t0].why != "" and (out_sizes[0] == TILE_L or out_sizes[0] == TILE_XL):
                urgent = ids[0]
        return TileLayout(ids^, out_sizes^, cells^, overflow^, pk.holes, urgent)

    def target_of(self, id: String) -> Box:
        for a in self.anims:
            if a.id == id:
                return a.to
        return Box(0, 0, 0, 0)

    def box_of(self, id: String) -> Box:
        """Where the tile is now (mid-glide too), points."""
        for a in self.anims:
            if a.id == id:
                return a.cur()
        return Box(0, 0, 0, 0)

    def _retarget(mut self, snap: Bool):
        var lay = self.layout()
        var out = List[_Anim]()
        for j in range(len(lay.ids)):
            var id = lay.ids[j]
            var to = cell_box(lay.cells[j], self.width, self.height)
            var found = -1
            for k in range(len(self.anims)):
                if self.anims[k].id == id:
                    found = k
            if found < 0:
                var a = _Anim(id, to, j)
                if not snap and not self.reduced and self.width > 0:
                    a.fade_us = 0
                out.append(a^)
                continue
            var a = self.anims[found].copy()
            if snap or self.reduced or self.width <= 0:
                a.fr = to
                a.to = to
                a.p.snap(1.0)
                a.fade_us = -1
            elif not _same(a.to, to):
                var resized = abs(a.to.w - to.w) > 1 or abs(a.to.h - to.h) > 1
                a.fr = a.cur()
                a.to = to
                a.p = Spring(0.0, WATER_K, WATER_C)
                a.p.to(1.0)
                if resized:
                    a.fade_us = 0
            out.append(a^)
        self.anims = out^
        self.version += 1

    # ---------------------------------------------------------------- time

    def moving(self) -> Bool:
        if self.mode == _DRAGGING:
            return True
        for a in self.anims:
            if a.p.moving() or a.press.moving() or a.lift.moving() or a.face.moving() or a.fade_us >= 0:
                return True
        return False

    def frame(mut self, microseconds: Int) -> Bool:
        """One display frame (a Canvas's on_frame: event.number). True when the picture changed (version moved on)."""
        var us = max(microseconds, 0)
        self.clock_us += us
        var changed = False
        var reduced = self.reduced
        var water = self.water_us
        var idle = self.mode == _IDLE
        for k in range(len(self.anims)):
            var ti = self._index(self.anims[k].id)
            var multi = ti >= 0 and len(self.tiles[ti].faces) > 1 and idle
            ref a = self.anims[k]
            if a.p.moving():
                _ = a.p.step(us)
                changed = True
            if a.press.moving():
                _ = a.press.step(us)
                changed = True
            if a.lift.moving():
                _ = a.lift.step(us)
                changed = True
            if a.face.moving():
                _ = a.face.step(us)
                changed = True
            if a.fade_us >= 0:
                a.fade_us += us
                if a.fade_us >= water:
                    a.fade_us = -1
                changed = True
            if multi:
                a.face_wait_us -= us
                if a.face_wait_us <= 0:
                    a.face_wait_us = FACE_MS * 1000
                    if reduced:
                        a.face.snap(a.face.target + 1.0)
                    else:
                        a.face.to(a.face.target + 1.0)
                    changed = True
        if self.mode == _DRAGGING:
            changed = True
        if changed:
            self.version += 1
        return changed

    # ---------------------------------------------------------------- the pointer

    def _hit(self, x: Float64, y: Float64, skip: String = "") -> String:
        for k in range(len(self.anims) - 1, -1, -1):
            if self.anims[k].id != skip and self.anims[k].cur().has(x, y):
                return self.anims[k].id
        return ""

    def _over(self, x: Float64, y: Float64, skip: String) -> String:
        for a in self.anims:
            if a.id != skip and a.to.has(x, y):
                return a.id
        return ""

    def _anim(self, id: String) -> Int:
        for k in range(len(self.anims)):
            if self.anims[k].id == id:
                return k
        return -1

    def gesture(mut self, kind: Int, x: Float64, y: Float64):
        """A Canvas gesture (event.number, event.x, event.y in points): PRESS, PAN, RELEASE, TAP."""
        if kind == PRESS:
            var id = self._hit(x, y)
            self.sx = x
            self.sy = y
            self.px = x
            self.py = y
            self.active = id
            self.selected = id
            if id == "":
                self.mode = _IDLE
                self.version += 1
                return
            var k = self._anim(id)
            var b = self.anims[k].cur()
            if x >= b.x + b.w - GRIP and y >= b.y + b.h - GRIP:
                self.mode = _RESIZING
                self.start = b
                self.resized = False
            else:
                self.mode = _PRESSING
                self.anims[k].press_amt = press_amount(b.w)
                if not self.reduced:
                    self.anims[k].press.to(self.anims[k].press_amt)
            self.version += 1
        elif kind == PAN:
            self.px = x
            self.py = y
            if self.mode == _PRESSING and abs(x - self.sx) + abs(y - self.sy) >= DRAG_START:
                var k = self._anim(self.active)
                if k >= 0:
                    self.mode = _DRAGGING
                    var b = self.anims[k].cur()
                    self.ox = self.sx - b.x
                    self.oy = self.sy - b.y
                    self.anims[k].press.to(1.0)
                    if self.reduced:
                        self.anims[k].lift.snap(LIFT)
                    else:
                        self.anims[k].lift.to(LIFT)
                    self.last_over = ""
                    self.last_swap_ns = 0
            if self.mode == _DRAGGING:
                self._drag_over(x, y)
            elif self.mode == _RESIZING:
                var size = snap_size(self.start.w + x - self.sx, self.start.h + y - self.sy, self.width, self.height)
                var lay = self.layout()
                var now = SIZE_AUTO
                for j in range(len(lay.ids)):
                    if lay.ids[j] == self.active:
                        now = lay.sizes[j]
                if size != now:
                    var who = self.active.copy()
                    self.set_user_size(who, size)
                    self.resized = True
                    self.results.append(TileResult(RESIZED, who, size_name(size)))
            self.version += 1
        elif kind == RELEASE or kind == TAP:
            var k = self._anim(self.active)
            if self.mode == _DRAGGING and k >= 0:
                var b = self.anims[k].cur()
                var dropped = Box(self.px - self.ox, self.py - self.oy, b.w, b.h)
                self.anims[k].fr = dropped
                self.anims[k].p = Spring(0.0 if not self.reduced else 1.0, WATER_K, WATER_C)
                self.anims[k].p.to(1.0)
                self.anims[k].lift.to(1.0)
                if self.reduced:
                    self.anims[k].lift.snap(1.0)
                var order = String("")
                var lay = self.layout()
                for j in range(len(lay.ids)):
                    order += ("," if j > 0 else "") + lay.ids[j]
                self.results.append(TileResult(REORDERED, self.active, order))
            elif self.mode == _PRESSING and k >= 0:
                self.anims[k].press.to(1.0)
                var who = self.active.copy()
                self._tapped(x, y, who)
            elif self.mode == _IDLE and kind == TAP:
                var id = self._hit(x, y)
                self.selected = id
                if id != "":
                    self._tapped(x, y, id)
            self.mode = _IDLE
            self.active = ""
            self.version += 1

    def _tapped(mut self, x: Float64, y: Float64, id: String):
        for i in range(len(self.pill_ids)):
            if self.pill_ids[i] == id and self.pill_box[i].has(x, y):
                self.results.append(TileResult(ACTION, id, self.pill_text[i]))
                return
        self.results.append(TileResult(TAPPED, id, ""))

    def _drag_over(mut self, x: Float64, y: Float64):
        var over = self._over(x, y, self.active)
        if over == "":
            self.last_over = ""
            return
        var now = now_ns()
        if over == self.last_over or now - self.last_swap_ns < SWAP_MS * 1_000_000:
            return
        self.last_over = over
        self.last_swap_ns = now
        var lay = self.layout()
        var ids = lay.ids.copy()
        var ti = -1
        var oi = -1
        for j in range(len(ids)):
            if ids[j] == self.active:
                ti = j
            if ids[j] == over:
                oi = j
        if ti < 0 or oi < 0:
            return
        var lead = ids[0]
        var moved = ids.pop(ti)
        ids.insert(oi, moved)  # (before `over` when it was earlier; after it when later: over's old index after the pop)
        var order = ids.copy()
        for o in lay.overflow:
            order.append(o)
        self.user_order = order^
        if ids[0] != lead:
            self.lead_off = lead
        self._retarget(False)

    # ---------------------------------------------------------------- the pointer's parts

    def parts(self, card: String, inside: String) -> List[Part]:
        """Each shown tile as a pointer part card + "." + part_name(id), named by its head and id, a box in the canvas
        tagged `inside` (its picture is the canvas itself, in points)."""
        var out = List[Part]()
        var lay = self.layout()
        for j in range(len(lay.ids)):
            var ti = self._index(lay.ids[j])
            var b = cell_box(lay.cells[j], self.width, self.height)
            var names = List[String]()
            if ti >= 0 and self.tiles[ti].head != "":
                names.append(self.tiles[ti].head)
            names.append(lay.ids[j])
            out.append(area_part(card, part_name(lay.ids[j]), names, inside, b.x, b.y, b.x + b.w, b.y + b.h,
                                 Int(max(self.width, 1.0)), Int(max(self.height, 1.0))))
        return out^

    def spots(mut self, card: String, inside: String):
        """Report every tile as a moving spot (mojoui.geometry.put_spot) on each draw, so the ring follows a glide."""
        self.spot_card = card
        self.spot_inside = inside

    def charm_anchors(self) -> List[Tuple[String, String, Float64, Float64]]:
        """(id, charm, x, y): where each tile's charm hangs now (its top edge, near the right), points."""
        var out = List[Tuple[String, String, Float64, Float64]]()
        for i in range(len(self.drawn_ids)):
            var ti = self._index(self.drawn_ids[i])
            if ti >= 0 and self.tiles[ti].charm != "":
                var b = self.drawn_surf[i]
                out.append((self.drawn_ids[i], self.tiles[ti].charm, b.x + b.w - 34.0, b.y))
        return out^

    def record(self) -> String:
        """The last drawing, one line a tile: id surface(x y w h) words(x y w h) opacity font-size (points)."""
        var out = String("")
        for i in range(len(self.drawn_ids)):
            var s = self.drawn_surf[i]
            var t = self.drawn_text[i]
            out += (self.drawn_ids[i] + " " + _f1(s.x) + " " + _f1(s.y) + " " + _f1(s.w) + " " + _f1(s.h) + " " + _f1(t.x) + " "
                    + _f1(t.y) + " " + _f1(t.w) + " " + _f1(t.h) + " " + _f1(self.drawn_op[i] * 100.0) + " " + _f1(self.drawn_font[i]) + "\n")
        return out

    # ---------------------------------------------------------------- drawing

    def draw(mut self, mut s: Surface, look: TileLook, font: Font):
        var k = s.scale
        self.set_area(Float64(s.width) / k, Float64(s.height) / k)
        s.fill(look.ground)
        var still = s.still or self.reduced
        var lay = self.layout()
        self.drawn_ids.clear()
        self.drawn_surf.clear()
        self.drawn_text.clear()
        self.drawn_op.clear()
        self.drawn_font.clear()
        self.pill_ids.clear()
        self.pill_text.clear()
        self.pill_box.clear()
        # painter's order: growing tiles under shrinking ones (as the prototype's z-index), the dragged one on top
        var order = List[Int]()
        for pass_ in range(3):
            for i in range(len(self.anims)):
                ref a = self.anims[i]
                var dragged = self.mode == _DRAGGING and a.id == self.active
                var grows = a.to.w * a.to.h > a.fr.w * a.fr.h + 1.0 and a.p.moving()
                var which = 2 if dragged else (0 if grows else 1)
                if which == pass_:
                    order.append(i)
        for i in order:
            var a = self.anims[i].copy()
            var ti = self._index(a.id)
            if ti < 0:
                continue
            var size = TILE_S
            for j in range(len(lay.ids)):
                if lay.ids[j] == a.id:
                    size = lay.sizes[j]
            var surf = a.to if still else a.cur()
            var lifted = self.mode == _DRAGGING and a.id == self.active
            if lifted:
                surf = Box(self.px - self.ox, self.py - self.oy, surf.w, surf.h)
            var op = 1.0
            if not still and a.fade_us >= 0:
                op = fade_at(Float64(a.fade_us) / 1000.0, Float64(self.water_us) / 1000.0)
            var q = 1.0 if still else a.press.value * a.lift.value
            var darken = 0.0
            if not still and a.press_amt < 1.0:
                darken = 0.10 * min(max((1.0 - a.press.value) / (1.0 - a.press_amt), 0.0), 1.0)
            var face = 0.0 if still else a.face.value
            if still:
                face = a.face.target
            var tile = self.tiles[ti].copy()
            self._tile(s, look, font, tile, size, surf, Box(surf.x, surf.y, a.to.w, a.to.h), op, q, darken, face,
                       lay.urgent == a.id, lifted)
            if self.spot_card != "":
                put_spot(self.spot_card + "." + part_name(a.id), self.spot_inside, surf.x, surf.y, surf.w, surf.h)

    def _tile(mut self, mut s: Surface, look: TileLook, font: Font, t: Tile, size: Int, surf: Box, text: Box, op: Float64, q: Float64,
              darken: Float64, face: Float64, urgent: Bool, lifted: Bool):
        var k = s.scale
        # the press / lift scale about the surface's centre (uniform: the words scale with it, never stretch)
        var cx = surf.x + surf.w / 2
        var cy = surf.y + surf.h / 2
        var sb = Box(cx + (surf.x - cx) * q, cy + (surf.y - cy) * q, surf.w * q, surf.h * q)
        var large = size == TILE_L or size == TILE_XL
        var shadows = look.lifted.copy() if lifted else (look.raised.copy() if large else look.rest.copy())
        for sh in shadows:
            if not sh.inset:
                soft_shadow(s, sb.x * k, sb.y * k, sb.w * k, sb.h * k, RADIUS * q * k, sh, k)
        if large:
            gradient_rect(s, sb.x * k, sb.y * k, sb.w * k, sb.h * k, RADIUS * q * k, mix(look.card, t.color, 0.13), look.card, 160.0, 0.58)
        else:
            rect(s, sb.x * k, sb.y * k, sb.w * k, sb.h * k, look.card, RADIUS * q * k)
        for sh in shadows:
            if sh.inset:
                soft_shadow(s, sb.x * k, sb.y * k, sb.w * k, sb.h * k, RADIUS * q * k, sh, k)
        if darken > 0.0:
            rect(s, sb.x * k, sb.y * k, sb.w * k, sb.h * k, with_alpha(look.ink, darken), RADIUS * q * k)
        # the words: laid out in the FINAL box (text.w x text.h), from the surface's corner, faded in
        var big_pt = 19.0 if size == TILE_S else (22.0 if size == TILE_W else (32.0 if size == TILE_L else (44.0 if size == TILE_XL else 24.0)))
        var sub_pt = 13.0 if size == TILE_S else (13.5 if size == TILE_W else (16.0 if size == TILE_L else (18.0 if size == TILE_XL else 14.0)))
        self.drawn_ids.append(t.id)
        self.drawn_surf.append(surf)
        self.drawn_text.append(text)
        self.drawn_op.append(op)
        self.drawn_font.append(big_pt)
        var pad = 14.0 if size == TILE_S else 16.0
        if op > 0.01:
            var X = _Xf(cx, cy, q, k)
            # the icon square and the head
            var ix = text.x + pad
            var iy = text.y + pad
            rect(s, X.x(ix), X.y(iy), X.n(22.0), X.n(22.0), with_alpha(t.color, op), X.n(7.0))
            _glyph(s, font, t.icon, t.head, X.x(ix), X.y(iy), X.n(22.0), with_alpha(rgba(255, 255, 255), op))
            var head = _fit(font, t.head.upper(), X.n(11.0), MEDIUM, X.n(text.w - 2 * pad - 30.0))
            font.draw(s, head, X.x(ix + 30.0), X.y(iy + 15.5), X.n(11.0), with_alpha(look.ink2, op), MEDIUM)
            # from the bottom: the actions, the why chip, the face
            var yb = text.y + text.h - pad
            var inner = text.w - 2 * pad
            if large and len(t.actions) > 0:
                var ax = text.x + pad
                for n in range(min(len(t.actions), 2)):
                    var label = t.actions[n]
                    var w = font.measure(label, X.n(13.5), MEDIUM) / X.n(1.0) + 28.0
                    if ax + w > text.x + text.w - pad:
                        break
                    var fill = look.ink if n == 0 else look.line
                    var ink = look.card if n == 0 else look.ink
                    rect(s, X.x(ax), X.y(yb - 36.0), X.n(w), X.n(36.0), with_alpha(fill, op), X.n(18.0))
                    font.draw(s, label, X.x(ax + w / 2), X.y(yb - 13.0), X.n(13.5), with_alpha(ink, op), MEDIUM, CENTRE)
                    self.pill_ids.append(t.id)
                    self.pill_text.append(label)
                    self.pill_box.append(Box(cx + (ax - cx) * q, cy + (yb - 36.0 - cy) * q, w * q, 36.0 * q))
                    ax += w + 8.0
                yb -= 46.0
            if urgent and t.why != "":
                var chip = "Bigger now: " + t.why
                var cw = min(font.measure(chip, X.n(12.0), MEDIUM) / X.n(1.0) + 20.0, inner)
                var chip_fill = mix(look.card, t.color, 0.28 if look.dark else 0.13)
                var chip_ink = mix(t.color, rgba(255, 255, 255), 0.45) if look.dark else t.color
                rect(s, X.x(text.x + pad), X.y(yb - 24.0), X.n(cw), X.n(24.0), with_alpha(chip_fill, op), X.n(12.0))
                font.draw(s, _fit(font, chip, X.n(12.0), MEDIUM, X.n(cw - 20.0)), X.x(text.x + pad + 10.0), X.y(yb - 7.5), X.n(12.0),
                          with_alpha(chip_ink, op), MEDIUM)
                yb -= 32.0
            var top = text.y + pad + 28.0
            var body = max(yb - top, 1.0)
            var nf = len(t.faces)
            var f0 = Int(face) if face >= 0 else 0
            for step in range(2):
                var idx = f0 + step
                var off = Float64(idx) - face  # body heights below where it rests
                if abs(off) >= 1.0 or nf == 0:
                    continue
                var fa = op * (1.0 - abs(off))
                if fa <= 0.01:
                    continue
                ref fc = t.faces[idx % nf]
                var lines_sub = _wrap(font, fc.sub, X.n(sub_pt), REGULAR, X.n(inner), 2)
                var max_big = 2 if size != TILE_BAND else 1
                var lines_big = _wrap(font, fc.big, X.n(big_pt), MEDIUM, X.n(inner), max_big)
                var dy = off * body
                var y = yb + dy - Float64(len(lines_sub)) * sub_pt * 1.3
                for li in range(len(lines_sub)):
                    font.draw(s, lines_sub[li], X.x(text.x + pad), X.y(y + sub_pt * (1.0 + 1.3 * Float64(li)) - sub_pt * 0.25), X.n(sub_pt),
                              with_alpha(look.ink2, fa))
                y -= 4.0 + Float64(len(lines_big)) * big_pt * 1.1
                for li in range(len(lines_big)):
                    font.draw(s, lines_big[li], X.x(text.x + pad), X.y(y + big_pt * (0.9 + 1.1 * Float64(li))), X.n(big_pt),
                              with_alpha(look.ink, fa), MEDIUM)
        # the corner grip on the selected tile
        if t.id == self.selected and not lifted:
            var gx = sb.x + sb.w - 12.0
            var gy = sb.y + sb.h - 12.0
            var g = with_alpha(look.ink2, 0.75)
            line(s, (gx - 7.0) * k, gy * k, gx * k, (gy - 7.0) * k, 2.2 * k, g)
            line(s, (gx - 2.5) * k, gy * k, gx * k, (gy - 2.5) * k, 2.2 * k, g)
        # a charm on its top edge (built in: "pin"; others are the caller's, at charm_anchors())
        if t.charm == "pin":
            var px = sb.x + sb.w - 34.0
            line(s, px * k, sb.y * k, px * k, (sb.y + 9.0) * k, 1.6 * k, rgba(120, 120, 128))
            circle(s, px * k, (sb.y - 2.0) * k, 7.0 * k, rgba(229, 72, 77))
            circle(s, (px - 2.0) * k, (sb.y - 4.0) * k, 2.2 * k, rgba(255, 255, 255, 150))


struct _Xf(Copyable, Movable):
    """Points -> pixels about a centre scaled by q (the press): x(), y() positions, n() lengths."""

    var cx: Float64
    var cy: Float64
    var q: Float64
    var k: Float64

    def __init__(out self, cx: Float64, cy: Float64, q: Float64, k: Float64):
        self.cx = cx
        self.cy = cy
        self.q = q
        self.k = k

    def x(self, v: Float64) -> Float64:
        return (self.cx + (v - self.cx) * self.q) * self.k

    def y(self, v: Float64) -> Float64:
        return (self.cy + (v - self.cy) * self.q) * self.k

    def n(self, v: Float64) -> Float64:
        return v * self.q * self.k


def _fit(font: Font, text: String, size: Float64, weight: Int, max_px: Float64) -> String:
    """`text` cut with an ellipsis to fit max_px."""
    if font.measure(text, size, weight) <= max_px:
        return text
    var chars = List[String]()
    for c in text.codepoints():
        chars.append(String(c))
    while len(chars) > 0:
        _ = chars.pop()
        var t = String("")
        for c in chars:
            t += c
        t = String(t.rstrip()) + "…"
        if font.measure(t, size, weight) <= max_px:
            return t
    return ""


def _wrap(font: Font, text: String, size: Float64, weight: Int, max_px: Float64, max_lines: Int) -> List[String]:
    """Greedy word wrap to max_px; the last allowed line ends in an ellipsis when words are left over."""
    var out = List[String]()
    var cur = String("")
    var words = text.split(" ")
    for i in range(len(words)):
        var w = String(words[i])
        var trial = w if cur == "" else cur + " " + w
        if font.measure(trial, size, weight) <= max_px or cur == "":
            cur = trial
        else:
            out.append(cur)
            cur = w
            if len(out) == max_lines:
                break
    if len(out) < max_lines and cur != "":
        out.append(cur)
    elif len(out) == max_lines and cur != "":
        out[max_lines - 1] = _fit(font, out[max_lines - 1] + " " + cur, size, weight, max_px)
    for i in range(len(out)):
        out[i] = _fit(font, out[i], size, weight, max_px)
    return out^


def _glyph(mut s: Surface, font: Font, icon: String, head: String, x: Float64, y: Float64, n: Float64, c: UInt32):
    """A small white glyph in an icon square at (x, y), n pixels a side."""
    var u = n / 22.0
    var w = 1.6 * u
    var mx = x + n / 2
    var my = y + n / 2
    if icon == "car":
        rect(s, x + 5 * u, y + 9 * u, 12 * u, 6 * u, c, 2 * u)
        rect(s, x + 7 * u, y + 6 * u, 8 * u, 4 * u, c, 1.5 * u)
        circle(s, x + 8 * u, y + 15.5 * u, 1.6 * u, c)
        circle(s, x + 14 * u, y + 15.5 * u, 1.6 * u, c)
    elif icon == "cloud":
        circle(s, x + 9 * u, y + 11 * u, 3.5 * u, c)
        circle(s, x + 13 * u, y + 10 * u, 4 * u, c)
        rect(s, x + 6 * u, y + 11 * u, 11 * u, 4 * u, c, 2 * u)
    elif icon == "todo":
        line(s, x + 6 * u, y + 11 * u, x + 9.5 * u, y + 14.5 * u, w, c)
        line(s, x + 9.5 * u, y + 14.5 * u, x + 16 * u, y + 7.5 * u, w, c)
    elif icon == "cal":
        rect(s, x + 5.5 * u, y + 6.5 * u, 11 * u, 3.5 * u, c, 1.5 * u)
        line(s, x + 6.3 * u, y + 9 * u, x + 6.3 * u, y + 16 * u, w, c)
        line(s, x + 15.7 * u, y + 9 * u, x + 15.7 * u, y + 16 * u, w, c)
        line(s, x + 6.3 * u, y + 16 * u, x + 15.7 * u, y + 16 * u, w, c)
        line(s, x + 8 * u, y + 5 * u, x + 8 * u, y + 7.5 * u, w, c)
        line(s, x + 14 * u, y + 5 * u, x + 14 * u, y + 7.5 * u, w, c)
    elif icon == "gift":
        rect(s, x + 5.5 * u, y + 9 * u, 11 * u, 8 * u, c, 1.5 * u)
        line(s, x + 11 * u, y + 6 * u, x + 11 * u, y + 17 * u, w, c)
        circle(s, x + 9 * u, y + 7 * u, 1.8 * u, c)
        circle(s, x + 13 * u, y + 7 * u, 1.8 * u, c)
    elif icon == "cam":
        circle(s, mx, my, 5.5 * u, c)
        circle(s, mx, my, 2.2 * u, rgba(0, 0, 0, 90))
    elif icon == "timer":
        circle(s, mx, my + u, 6 * u, c)
        line(s, mx, my + u, mx, my - 2.5 * u, w, rgba(0, 0, 0, 110))
        line(s, mx, y + 4 * u, mx, y + 6 * u, w, c)
    elif icon == "plane":
        line(s, x + 6 * u, y + 15 * u, x + 16 * u, y + 7 * u, 2.2 * u, c)
        line(s, x + 9 * u, y + 8 * u, x + 13 * u, y + 13 * u, 2.0 * u, c)
    elif icon == "home":
        line(s, x + 5.5 * u, y + 11 * u, mx, y + 5.5 * u, w, c)
        line(s, mx, y + 5.5 * u, x + 16.5 * u, y + 11 * u, w, c)
        rect(s, x + 7.5 * u, y + 10.5 * u, 7 * u, 6.5 * u, c, 1 * u)
    else:
        var first = String("")
        for ch in head.codepoints():
            first = String(ch)
            break
        font.draw(s, first.upper(), mx, y + 15.5 * u, 12.0 * u, c, MEDIUM, CENTRE)
