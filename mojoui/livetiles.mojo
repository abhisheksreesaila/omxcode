# mojoui.livetiles: live tiles on one Canvas (goal 77 M7b, D-7782): tiles of five sizes on an exact 4 x 3 grid, sized by
# importance, that change size like water (each glides to its new place while its surface grows or shrinks; the words are
# laid out at the final size from the first frame and faded in, never stretched), press in, drag to reorder and resize by a
# corner grip. One drawing serves GTK, the web host and the Mac: every host only shows the Canvas's pixels.
#
#   var tiles = LiveTiles()
#   var t = Tile("traffic", 0, "Traffic", "Leave by 8:05", "Bridge is slow", icon="car"); t.tint = "green"   (a palette tint)
#   t.faces.append(Face("26 min to school", "via the river road")); t.why = "you leave in 20 minutes"; t.actions = [...]
#   tiles.set_tiles(list)                 # most urgent first; a tile with `big` makes the layout [xl, w, w]; call again
#                                         # whenever importance or contents change: what moved glides there (water)
#   Canvas(id, tiles.version, on_gesture=G, on_frame=F).grow().fill()
#   update: G -> tiles.gesture(event.number, event.x, event.y)       (PRESS, PAN, RELEASE, TAP)
#           F -> _ = tiles.frame(event.number)                        (microseconds; True while something moves)
#           for r in tiles.take_results(): r.kind = TAPPED | ACTION (r.text = the action) | REORDERED (r.text = the ids in
#                                          the new order, comma-separated) | RESIZED (r.text = "s", "w", "l", "xl") |
#                                          DROPPED (let go over a drop zone: r.text = its name; the caller takes the tile)
#   tiles.drop_zone("pinned", Box(…))  a place outside the grid (canvas points; a side column) a tile can be dragged onto;
#                                      tiles.hover_zone names the one a dragged tile is over (light it up)
#   tiles.set_columns(2)               a phone: two columns of 112 pt rows (compact_height() says how tall the canvas is)
#   draw:   tiles.draw(surface, TileLook.of(palette), font)          (fills the canvas with look.ground first; a tile's
#           tint, its Lucide icon (mojoui.vector) and its charm (mojoui.charms) all take their colours from the palette)
#   tiles.parts(card, canvas_tag)  -> List[Part]   each tile pointable by its head and id (mojoui.pointer area parts);
#   tiles.spots(card, canvas_tag)                  ...and reported as moving spots every draw, so the ring follows a glide
#   tiles.layout() -> TileLayout   ids shown, their sizes and cells, the ids that did not fit (the caller shows them
#                                  elsewhere) and the empty cells (a user's size can leave holes; reported, not hidden)
#   tiles.charms()                 each charm as drawn: id, charm, its box (mojoui.charms draws it on the tile's top edge)
#   tiles.record()                 one line per tile as last drawn: its surface and its words' box (a proof's evidence)
#   tiles.reset()                  forget the user's order and sizes
#   tiles.focus(id)                the pointer is on this tile ("" none): it rises a little, the one before sinks back
#
# The pure layout (preset, pack, cell_box, press_amount) has no Canvas in it: tests/test_livetiles.mojo calls it directly.
# Presets by tile count keep the grid full: 6 = l w w w s s, 5 = l w w w w, 4 = l l w w, 3 = xl w w, 2 = xl band, 1 = full;
# packing is CSS grid-auto-flow: dense, in order. More than 6 tiles (3 with a big one): the rest are reported as overflow.
# Motion: the water spring (k 150, c 19.5: about 2 % overshoot, settled in ~0.7 s) moves a tile's rect; a tile that joins grows
# in from nothing about its centre and one that leaves shrinks to nothing, both on the same spring (D-8413: a Stage going roomy
# or compact reflows by itself, no crossfade); the press is
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
from mojoui.vector import draw_icon
from mojoui.charms import draw_charm, charm_moves, charm_box, charm_top, palette_family

comptime TILE_S = 0  # 1 x 1
comptime TILE_W = 1  # 2 x 1
comptime TILE_L = 2  # 2 x 2
comptime TILE_XL = 3  # 4 x 2
comptime TILE_BAND = 4  # 4 x 1
comptime TILE_FULL = 5  # 4 x 3: a lone tile fills the grid
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
comptime FOCUS_LIFT = 1.025  # a tile the pointer is on rises this much (goal 77 M7c, as an Iso block rises: D-7755)
comptime FADE_FROM = 0.3  # the words stay clear until this far into the water's time
comptime MIN_AREA = 64.0  # a canvas smaller than this (points, either side) isn't laid out yet: draw() leaves the tiles where they are
comptime ROW_COMPACT = 112.0  # a phone's rows, points (two columns; the page scrolls: the prototype's grid-auto-rows)
comptime COMPACT_ROWS = 64  # (rows a phone's grid may use: no tile set comes near it)

# results (TileResult.kind)
comptime TAPPED = 1
comptime ACTION = 2
comptime REORDERED = 3
comptime RESIZED = 4
comptime DROPPED = 5  # let go over a caller's drop zone outside the grid (r.text = the zone's name): the caller takes the tile

# what the pointer is doing
comptime _IDLE = 0
comptime _PRESSING = 1
comptime _DRAGGING = 2
comptime _RESIZING = 3


# ------------------------------------------------------------------------------------------------ the pure layout


def size_cols(size: Int) -> Int:
    return 1 if size == TILE_S else (2 if size == TILE_W or size == TILE_L else 4)


def size_rows(size: Int) -> Int:
    return 3 if size == TILE_FULL else (2 if size == TILE_L or size == TILE_XL else 1)


def is_large(size: Int) -> Bool:
    """l, xl and full: the sizes that show a why chip and actions, on the raised shadow."""
    return size == TILE_L or size == TILE_XL or size == TILE_FULL


def size_name(size: Int) -> String:
    if size == TILE_S:
        return "s"
    if size == TILE_W:
        return "w"
    if size == TILE_L:
        return "l"
    if size == TILE_XL:
        return "xl"
    if size == TILE_FULL:
        return "full"
    return "band"


def preset(n: Int) -> List[Int]:
    """The sizes that fill the 4 x 3 grid exactly for n tiles (n > 6: the first six)."""
    if n <= 0:
        return List[Int]()
    if n == 1:
        return [TILE_FULL]
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
    return pack_grid(sizes, COLS, ROWS)


def preset_compact(n: Int) -> List[Int]:
    """A phone's two columns (rows as many as needed): the first large (2 x 2), the rest a row each (w), six as the desktop's
    l w w w s s; every count fills its rows exactly."""
    var out = List[Int]()
    if n <= 0:
        return out^
    if n >= 6:
        return [TILE_L, TILE_W, TILE_W, TILE_W, TILE_S, TILE_S]
    out.append(TILE_L)
    for _ in range(n - 1):
        out.append(TILE_W)
    return out^


def compact_size(size: Int) -> Int:
    """A size on a phone's two columns: xl and full are large (2 x 2), a band is a row (w)."""
    if size == TILE_XL or size == TILE_FULL:
        return TILE_L
    if size == TILE_BAND:
        return TILE_W
    return size


def compact_box(c: Rect, width: Float64) -> Box:
    """A cell rect's box on a phone's two columns of ROW_COMPACT rows, width points wide."""
    var cw = (width - 2 * PAD - GAP) / 2.0
    return Box(PAD + Float64(c.x) * (cw + GAP), PAD + Float64(c.y) * (ROW_COMPACT + GAP),
               Float64(c.w) * cw + Float64(c.w - 1) * GAP, Float64(c.h) * ROW_COMPACT + Float64(c.h - 1) * GAP)


def compact_rows_height(rows: Int) -> Int:
    """The canvas height (points) a phone's grid of `rows` rows needs."""
    return Int(2 * PAD + Float64(rows) * ROW_COMPACT + Float64(max(rows - 1, 0)) * GAP + 0.5)


def pack_grid(sizes: List[Int], cols: Int, rows: Int) -> Packing:
    """Dense packing on a cols x rows grid (holes: the empty cells of the rows the tiles use)."""
    var used = List[Bool](length=cols * rows, fill=False)
    var cells = List[Rect]()
    var fits = List[Bool]()
    var filled = 0
    for i in range(len(sizes)):
        var cw = size_cols(sizes[i])
        var rh = size_rows(sizes[i])
        var placed = False
        for r in range(rows - rh + 1):
            for c in range(cols - cw + 1):
                var free = True
                for dr in range(rh):
                    for dc in range(cw):
                        if used[(r + dr) * cols + c + dc]:
                            free = False
                if free:
                    for dr in range(rh):
                        for dc in range(cw):
                            used[(r + dr) * cols + c + dc] = True
                    cells.append(Rect(c, r, cw, rh))
                    filled += cw * rh
                    placed = True
                    break
            if placed:
                break
        if not placed:
            cells.append(Rect(0, 0, 0, 0))
        fits.append(placed)
    var span = rows
    if rows > 3:  # (a phone's open-ended grid: only the rows in use count)
        span = 0
        for k in range(len(cells)):
            if fits[k]:
                span = max(span, cells[k].y + cells[k].h)
    return Packing(cells^, fits^, cols * span - filled)


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


# ------------------------------------------------------------------------------------------------ tints and icons


def tint_names() -> List[String]:
    """The named tints a tile may wear (an agent names one; the theme's palette says what it looks like)."""
    return ["green", "blue", "orange", "red", "purple", "indigo", "slate", "teal", "amber", "pink"]


def tint_colour(name: String, p: Palette) -> UInt32:
    """A named tint in this palette: the palette's own colour nearest that hue (its data colours, good, bad, warn), so a
    tile stays on the theme in light and night; slate (and an unknown name) is the palette's quiet ink."""
    var hue = -1.0
    if name == "green":
        hue = 140.0
    elif name == "blue":
        hue = 205.0
    elif name == "orange":
        hue = 24.0
    elif name == "red":
        hue = 357.0
    elif name == "purple":
        hue = 275.0
    elif name == "indigo":
        hue = 240.0
    elif name == "teal":
        hue = 172.0
    elif name == "amber":
        hue = 42.0
    elif name == "pink":
        hue = 335.0
    if hue < 0:
        return p.ink2
    return palette_family(p, hue)


def tile_icon(name: String) -> String:
    """A tile's icon as mojoui's Lucide name (a few short names an agent may send are taken as their Lucide icon)."""
    if name == "todo":
        return "list-todo"
    if name == "cal":
        return "calendar"
    if name == "cam":
        return "camera"
    if name == "photo" or name == "photos":
        return "image"
    if name == "word":
        return "book-open"
    if name == "spark":
        return "sparkles"
    if name == "bowl" or name == "feast":
        return "utensils"
    if name == "map":
        return "map-pin"
    if name == "rain":
        return "cloud-rain"
    if name == "school":
        return "backpack"
    return name


# ------------------------------------------------------------------------------------------------ the model


@fieldwise_init
struct Face(Copyable, Movable):
    var big: String
    var sub: String


struct Tile(Copyable, Movable):
    """One tile. `color` is its kind's colour (the icon square, the wash, the why chip), or `tint` names one the palette
    gives (tint_names()); `icon`: a mojoui Lucide icon (car, cloud, list-todo, calendar, gift, camera, timer, plane, home, …;
    tile_icon() takes a few short names) or "" (the head's first letter); `faces` turn over one at a time; `why` and
    `actions` show on a large tile; `big` asks for the 3-tile xl layout; `size` a fixed size (SIZE_AUTO: the preset's);
    `charm` a drawing that hangs on its top edge (mojoui.charms: bag, pennant, hat, umbrella, tag, turkey, pin)."""

    var id: String
    var color: UInt32
    var tint: String
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
        self.tint = ""
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
    var palette: Palette  # named tints and charms take their colours from it

    def __init__(out self, dark: Bool, ground: UInt32, card: UInt32, ink: UInt32, ink2: UInt32, line: UInt32, palette: Palette = Palette.plain()):
        self.dark = dark
        self.palette = palette.copy()
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
        return TileLook(p.dark, p.page, p.card, p.ink, p.ink2, p.line, p)

    @staticmethod
    def on(p: Palette, ground: UInt32) -> TileLook:
        """The palette's look on another ground (the Stage's tiles stand on its panel, not on the page)."""
        return TileLook(p.dark, ground, p.card, p.ink, p.ink2, p.line, p)

    def colour(self, t: Tile) -> UInt32:
        """A tile's colour: its tint in this palette, else its own colour."""
        return tint_colour(t.tint, self.palette) if t.tint != "" else t.color

    def glyph(self) -> UInt32:
        """Ink on a tile's coloured icon square: the palette's lightest."""
        return self.ink if self.dark else self.card


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
    var charm: String  # the charm it wears ("" none) and its arrival (0 -> 1: drops in and fades in)
    var charm_in: Spring
    var grow: Spring  # its size about its centre: 1 at rest; 0 -> 1 as it joins, 1 -> 0 as it leaves (water)
    var size: Int  # the size it was last drawn at (a tile leaving keeps its words' sizes)

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
        self.charm = ""
        self.charm_in = Spring(1.0, FAST_K, FAST_C)
        self.grow = Spring(1.0, WATER_K, WATER_C)
        self.size = TILE_S

    def cur(self) -> Box:
        var q = self.p.value
        return Box(self.fr.x + (self.to.x - self.fr.x) * q, self.fr.y + (self.to.y - self.fr.y) * q,
                   self.fr.w + (self.to.w - self.fr.w) * q, self.fr.h + (self.to.h - self.fr.h) * q)


def _water(fr: Box, to: Box, start: Float64) -> Spring:
    """A tile's water progress from `fr` to `to` (0 -> 1, k 150 c 19.5), at rest once every side is within 0.5 pt of its
    end: the spring's unit tolerance would let a 700 pt move jump 1.4 pt at the end."""
    var far = max(max(abs(to.x - fr.x), abs(to.y - fr.y)), max(abs(to.w - fr.w), abs(to.h - fr.h)))
    var sp = Spring(start, WATER_K, WATER_C, rest=min(0.002, 0.5 / max(far, 1.0)))
    sp.to(1.0)
    return sp^


def _tile_named(tiles: List[Tile], id: String) -> List[Tile]:
    """The tile called `id` ([] when there is none)."""
    var out = List[Tile]()
    for t in tiles:
        if t.id == id:
            out.append(t.copy())
            break
    return out^


def _lead(tiles: List[Tile]) -> String:
    """The tile importance puts first: the first `big` one, else the first."""
    for t in tiles:
        if t.big:
            return t.id
    return tiles[0].id if len(tiles) > 0 else String("")


def _same(a: Box, b: Box) -> Bool:
    return abs(a.x - b.x) < 0.5 and abs(a.y - b.y) < 0.5 and abs(a.w - b.w) < 0.5 and abs(a.h - b.h) < 0.5


def _f1(v: Float64) -> String:
    var n = Int(abs(v) * 10.0 + 0.5)
    return ("-" if v < 0 and n > 0 else "") + String(n // 10) + "." + String(n % 10)


struct LiveTiles(Copyable, Movable):
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
    var cols: Int  # 4 (the 4 x 3 grid) or 2 (a phone: two columns of ROW_COMPACT rows, as many as the tiles need)
    var zone_names: List[String]  # places outside the grid a tile can be dropped on (drop_zone), in canvas points
    var zone_boxes: List[Box]
    var hover_zone: String  # the zone a dragged tile is over now ("" none): a caller may mark it
    var leaving: List[_Anim]  # tiles that left the grid, shrinking away (drawn under the rest; no hit tests, not in the record)
    var leaving_tiles: List[Tile]  # what each of them shows
    var prev_tiles: List[Tile]  # the tiles before the last set_tiles (a tile that leaves is drawn from here)
    var taken: String  # the tile last dropped on a zone (it went with the pointer: no shrinking away in its old cell)

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
        self.cols = COLS
        self.zone_names = List[String]()
        self.zone_boxes = List[Box]()
        self.hover_zone = ""
        self.leaving = List[_Anim]()
        self.leaving_tiles = List[Tile]()
        self.prev_tiles = List[Tile]()
        self.taken = ""

    # ---------------------------------------------------------------- feeding it

    def set_tiles(mut self, tiles: List[Tile]):
        """The tiles, most urgent first. What changed place or size glides there. A tile that becomes the lead (a promote:
        another first tile, or another `big` one) forgets the size and place the person gave it, so it is the large tile
        again; what the person chose for tiles that are gone is forgotten (a tile added again starts fresh)."""
        var was = _lead(self.tiles)
        self.prev_tiles = self.tiles.copy()
        self.tiles = tiles.copy()
        self._prune()
        var now = _lead(self.tiles)
        if now != "" and now != was:
            self._forget(now)
            self.lead_off = ""
        self._retarget(False)

    def _prune(mut self):
        """Forget the user's sizes and order for ids that are no longer tiles."""
        var ids = List[String]()
        var sizes = List[Int]()
        for i in range(len(self.user_ids)):
            if self._index(self.user_ids[i]) >= 0:
                ids.append(self.user_ids[i])
                sizes.append(self.user_sizes[i])
        self.user_ids = ids^
        self.user_sizes = sizes^
        var order = List[String]()
        for id in self.user_order:
            if self._index(id) >= 0:
                order.append(id)
        self.user_order = order^

    def _forget(mut self, id: String):
        """Forget the size and the place the person gave tile `id`."""
        var ids = List[String]()
        var sizes = List[Int]()
        for i in range(len(self.user_ids)):
            if self.user_ids[i] != id:
                ids.append(self.user_ids[i])
                sizes.append(self.user_sizes[i])
        self.user_ids = ids^
        self.user_sizes = sizes^
        var order = List[String]()
        for o in self.user_order:
            if o != id:
                order.append(o)
        self.user_order = order^

    def set_area(mut self, width: Float64, height: Float64):
        """The canvas's size in points (draw() sets it; a test or a caller before the first draw may)."""
        if abs(width - self.width) > 0.5 or abs(height - self.height) > 0.5:
            self.width = width
            self.height = height
            self._retarget(True)

    def set_reduced(mut self, reduced: Bool):
        self.reduced = reduced

    def set_columns(mut self, cols: Int):
        """4: the 4 x 3 grid; 2: a phone's two columns of 112 pt rows (sizes: xl and full become l, a band w; the presets
        fill whole rows; the canvas is compact_height() high and the page scrolls). The tiles move there at once."""
        var n = 2 if cols <= 2 else COLS
        if n != self.cols:
            self.cols = n
            self._retarget(True)

    def compact_height(self) -> Int:
        """The canvas height (points) the tiles need on a phone's two columns (whatever the grid shows now)."""
        var lay = self._layout_in(2)
        var rows = 0
        for c in lay.cells:
            rows = max(rows, c.y + c.h)
        return compact_rows_height(max(rows, 1))

    def drop_zone(mut self, name: String, box: Box):
        """A place outside the grid (canvas points: it may lie beyond the canvas, as a side column does) where letting go of
        a dragged tile gives a DROPPED result (r.text = name) instead of a new order: the caller takes the tile (pins it)."""
        for i in range(len(self.zone_names)):
            if self.zone_names[i] == name:
                self.zone_boxes[i] = box
                return
        self.zone_names.append(name)
        self.zone_boxes.append(box)

    def _zone_at(self, x: Float64, y: Float64) -> String:
        for i in range(len(self.zone_names)):
            if self.zone_boxes[i].has(x, y):
                return self.zone_names[i]
        return ""

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

    def focus(mut self, id: String):
        """The pointer is on tile `id` ("" on none): it rises a little (FOCUS_LIFT on the fast spring), the others go back."""
        for k in range(len(self.anims)):
            if self.mode == _DRAGGING and self.anims[k].id == self.active:
                continue
            var want = FOCUS_LIFT if self.anims[k].id == id and id != "" else 1.0
            if abs(self.anims[k].lift.target - want) < 1e-6:
                continue
            if self.reduced:
                self.anims[k].lift.snap(want)
            else:
                self.anims[k].lift.to(want)
            self.version += 1

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
        """What the grid shows now (its columns: set_columns)."""
        return self._layout_in(self.cols)

    def _layout_in(self, cols: Int) -> TileLayout:
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
        var pre = preset(len(shown)) if cols == COLS else preset_compact(len(shown))
        var sizes = List[Int]()
        for j in range(len(shown)):
            var t = shown[j]
            var s = self.user_size(self.tiles[t].id)
            if s == SIZE_AUTO:
                s = self.tiles[t].size
            if s == SIZE_AUTO:
                s = TILE_XL if t == bigi and len(shown) > 1 else pre[j]
            if cols != COLS:
                s = compact_size(s)
            sizes.append(s)
        var pk = pack(sizes) if cols == COLS else pack_grid(sizes, 2, COMPACT_ROWS)
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
            if self.user_size(ids[0]) == SIZE_AUTO and self.tiles[t0].why != "" and is_large(out_sizes[0]):
                urgent = ids[0]
        return TileLayout(ids^, out_sizes^, cells^, overflow^, pk.holes, urgent)

    def _cell(self, c: Rect) -> Box:
        """A cell rect's box on this canvas (the 4 x 3 grid, or a phone's two columns)."""
        return cell_box(c, self.width, self.height) if self.cols == COLS else compact_box(c, self.width)

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
            var to = self._cell(lay.cells[j])
            var found = -1
            for k in range(len(self.anims)):
                if self.anims[k].id == id:
                    found = k
            if found < 0:
                var a = _Anim(id, to, j)
                if not snap and not self.reduced and self.width > 0 and len(self.anims) > 0:  # (a tile joining: it grows in)
                    a.fade_us = 0
                    a.grow = _water(Box(0, 0, 0, 0), Box(0, 0, 1, 1), 0.0)
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
                a.p = _water(a.fr, to, 0.0)
                if resized:
                    a.fade_us = 0
            out.append(a^)
        var animate = not snap and not self.reduced and self.width > 0
        for k in range(len(self.anims)):  # (a tile that leaves the grid shrinks away where it is)
            var stays = False
            for o in out:
                if o.id == self.anims[k].id:
                    stays = True
            if stays or not animate or self.anims[k].id == self.taken:
                continue
            var t = _tile_named(self.tiles, self.anims[k].id)
            if len(t) == 0:
                t = _tile_named(self.prev_tiles, self.anims[k].id)
            if len(t) == 0:
                continue
            var g = self.anims[k].copy()
            var here = g.cur()
            g.fr = here
            g.to = here
            g.p.snap(1.0)
            g.fade_us = -1
            g.grow = _water(Box(0, 0, 0, 0), Box(0, 0, 1, 1), 1.0)
            g.grow.snap(min(max(self.anims[k].grow.value, 0.0), 1.0))
            g.grow.to(0.0)
            self.leaving.append(g^)
            self.leaving_tiles.append(t[0].copy())
        if not animate:
            self.leaving.clear()
            self.leaving_tiles.clear()
        for k in range(len(out)):  # (a charm that changes drops in on the fast spring)
            var ti = self._index(out[k].id)
            var want = self.tiles[ti].charm if ti >= 0 else String("")
            if want != out[k].charm:
                out[k].charm = want
                out[k].charm_in = Spring(1.0 if (snap or self.reduced or self.width <= 0) else 0.0, FAST_K, FAST_C)
                out[k].charm_in.to(1.0)
        self.anims = out^
        self.version += 1

    # ---------------------------------------------------------------- time

    def moving(self) -> Bool:
        if self.mode == _DRAGGING or len(self.leaving) > 0:
            return True
        for a in self.anims:
            if a.p.moving() or a.press.moving() or a.lift.moving() or a.face.moving() or a.fade_us >= 0 or a.charm_in.moving() or a.grow.moving():
                return True
        return False

    def swinging(self) -> Bool:
        """A shown tile wears a charm that swings or flaps (a canvas keeps drawing while one shows, unless motion is reduced)."""
        if self.reduced:
            return False
        for a in self.anims:
            if a.charm != "" and charm_moves(a.charm):
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
            if a.charm_in.moving():
                _ = a.charm_in.step(us)
                changed = True
            if a.grow.moving():
                _ = a.grow.step(us)
                changed = True
            if a.charm != "" and not reduced and charm_moves(a.charm):
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
        var k2 = 0
        while k2 < len(self.leaving):  # (gone once it has shrunk away)
            _ = self.leaving[k2].grow.step(us)
            changed = True
            if self.leaving[k2].grow.value <= 0.01 or reduced:
                _ = self.leaving.pop(k2)
                _ = self.leaving_tiles.pop(k2)
            else:
                k2 += 1
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
            var was_selected = id != "" and id == self.selected
            self.selected = id
            if id == "":
                self.mode = _IDLE
                self.version += 1
                return
            var k = self._anim(id)
            var b = self.anims[k].cur()
            # the corner grip is live only where it is drawn (the selected tile) and never over an action pill
            if was_selected and x >= b.x + b.w - GRIP and y >= b.y + b.h - GRIP and not self._on_pill(id, x, y):
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
                var hz = self._zone_at(x, y)
                if hz != self.hover_zone:
                    self.hover_zone = hz
                self._drag_over(x, y)
            elif self.mode == _RESIZING and (self._anim(self.active) < 0 or self._index(self.active) < 0):
                self.mode = _IDLE  # (the tile went while it was being resized: a patch removed it)
            elif self.mode == _RESIZING:
                var size = snap_size(self.start.w + x - self.sx, self.start.h + y - self.sy, self.width, self.height)
                if self.cols != COLS:  # (a phone: s, w or l by the two columns' cells)
                    var cwc = (self.width - 2 * PAD - GAP) / 2.0
                    var cx = (self.start.w + x - self.sx + GAP) / (cwc + GAP)
                    var cy = (self.start.h + y - self.sy + GAP) / (ROW_COMPACT + GAP)
                    size = TILE_S if cx < 1.5 else (TILE_W if cy < 1.5 else TILE_L)
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
                self.anims[k].p = _water(dropped, self.anims[k].to, 0.0 if not self.reduced else 1.0)
                self.anims[k].lift.to(1.0)
                if self.reduced:
                    self.anims[k].lift.snap(1.0)
                var zone = self._zone_at(self.px, self.py)
                self.hover_zone = ""
                if zone != "":  # (let go over a drop zone: the caller takes it; if it doesn't, the tile glides home)
                    self.results.append(TileResult(DROPPED, self.active, zone))
                    self.taken = self.active  # (the caller takes it: it leaves the grid without shrinking back in its cell)
                else:
                    var order = String("")
                    var lay = self.layout()
                    for j in range(len(lay.ids)):
                        order += ("," if j > 0 else "") + lay.ids[j]
                    self.results.append(TileResult(REORDERED, self.active, order))
            elif self.mode == _PRESSING and k >= 0:
                self.anims[k].press.to(1.0)
                var who = self.active.copy()
                self._tapped(x, y, who)
            elif self.mode == _RESIZING and not self.resized and k >= 0:  # (the grip pressed and let go without moving: a tap)
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

    def _on_pill(self, id: String, x: Float64, y: Float64) -> Bool:
        for i in range(len(self.pill_ids)):
            if self.pill_ids[i] == id and self.pill_box[i].has(x, y):
                return True
        return False

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
            var b = self._cell(lay.cells[j])
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

    def charms(self) -> String:
        """The charms as last drawn, one line each: id charm x y w h (its box in points, unturned) — a proof's evidence."""
        var out = String("")
        for i in range(len(self.drawn_ids)):
            var ti = self._index(self.drawn_ids[i])
            if ti >= 0 and self.tiles[ti].charm != "":
                var b = self.drawn_surf[i]
                var c = charm_box(self.tiles[ti].charm)
                if c.w <= 0:
                    continue
                out += (self.drawn_ids[i] + " " + self.tiles[ti].charm + " " + _f1(b.x + b.w - c.right - c.w) + " " + _f1(b.y + charm_top(self.tiles[ti].charm, b.y)) + " "
                        + _f1(c.w) + " " + _f1(c.h) + "\n")
        return out

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
        s.fill(look.ground)
        if Float64(s.width) / k < MIN_AREA or Float64(s.height) / k < MIN_AREA:
            return  # (a canvas not laid out yet: the web host can ask a 1 x 1 frame of a canvas it just rebuilt; taking that size
            # would snap every tile to a degenerate grid and back, killing the water motion. As StageTV, D-6713)
        self.set_area(Float64(s.width) / k, Float64(s.height) / k)
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
        if not still:
            for i in range(len(self.leaving)):  # (shrinking away, under the rest; kept out of the hit tests and the record)
                var g = self.leaving[i].copy()
                var gq = min(max(g.grow.value, 0.0), 1.0)
                if gq <= 0.01:
                    continue
                var size = g.size
                var n_ids = len(self.drawn_ids)
                var n_pills = len(self.pill_ids)
                var gt = self.leaving_tiles[i].copy()
                self._tile(s, look, font, gt, size, g.to, g.to, min(max(gq * 2.0 - 1.0, 0.0), 1.0), gq, 0.0,
                           g.face.value, False, False)
                self.drawn_ids.resize(n_ids, String(""))
                self.drawn_surf.resize(n_ids, Box(0, 0, 0, 0))
                self.drawn_text.resize(n_ids, Box(0, 0, 0, 0))
                self.drawn_op.resize(n_ids, 0.0)
                self.drawn_font.resize(n_ids, 0.0)
                self.pill_ids.resize(n_pills, String(""))
                self.pill_text.resize(n_pills, String(""))
                self.pill_box.resize(n_pills, Box(0, 0, 0, 0))
        for i in order:
            var a = self.anims[i].copy()
            var ti = self._index(a.id)
            if ti < 0:
                continue
            var size = TILE_S
            for j in range(len(lay.ids)):
                if lay.ids[j] == a.id:
                    size = lay.sizes[j]
            self.anims[i].size = size
            var surf = a.to if still else a.cur()
            var lifted = self.mode == _DRAGGING and a.id == self.active
            if lifted:
                surf = Box(self.px - self.ox, self.py - self.oy, surf.w, surf.h)
            var op = 1.0
            if not still and a.fade_us >= 0:
                op = fade_at(Float64(a.fade_us) / 1000.0, Float64(self.water_us) / 1000.0)
            var q = 1.0 if still else a.press.value * a.lift.value * min(max(a.grow.value, 0.0), 1.2)
            if q <= 0.01:
                continue
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
        # the charms over every tile (one hangs above its tile's top edge, over the gap and the tile above), each as its tile
        # is drawn now: dropping in when it is new, swinging or flapping on the frame clock unless motion is reduced
        for i in range(len(self.drawn_ids)):
            var ka = self._anim(self.drawn_ids[i])
            if ka < 0 or self.anims[ka].charm == "":
                continue
            var b = self.drawn_surf[i]
            var v = 1.0 if still else self.anims[ka].charm_in.value
            var drop = (1.0 - v) * 26.0
            _ = draw_charm(s, self.anims[ka].charm, (b.x + b.w) * k, (b.y - drop) * k, k, look.palette, font,
                           self.clock_us // 1000, still, min(max(v * 1.4, 0.0), 1.0) * self.drawn_op[i], room=b.y)

    def _tile(mut self, mut s: Surface, look: TileLook, font: Font, t: Tile, size: Int, surf: Box, text: Box, op: Float64, q: Float64,
              darken: Float64, face: Float64, urgent: Bool, lifted: Bool):
        var k = s.scale
        # the press / lift scale about the surface's centre (uniform: the words scale with it, never stretch)
        var cx = surf.x + surf.w / 2
        var cy = surf.y + surf.h / 2
        var sb = Box(cx + (surf.x - cx) * q, cy + (surf.y - cy) * q, surf.w * q, surf.h * q)
        var large = is_large(size)
        var shadows = look.lifted.copy() if lifted else (look.raised.copy() if large else look.rest.copy())
        for sh in shadows:
            if not sh.inset:
                soft_shadow(s, sb.x * k, sb.y * k, sb.w * k, sb.h * k, RADIUS * q * k, sh, k)
        var hue = look.colour(t)
        if large:
            gradient_rect(s, sb.x * k, sb.y * k, sb.w * k, sb.h * k, RADIUS * q * k, mix(look.card, hue, 0.13), look.card, 160.0, 0.58)
        else:
            rect(s, sb.x * k, sb.y * k, sb.w * k, sb.h * k, look.card, RADIUS * q * k)
        for sh in shadows:
            if sh.inset:
                soft_shadow(s, sb.x * k, sb.y * k, sb.w * k, sb.h * k, RADIUS * q * k, sh, k)
        if darken > 0.0:
            rect(s, sb.x * k, sb.y * k, sb.w * k, sb.h * k, with_alpha(look.ink, darken), RADIUS * q * k)
        # the words: laid out in the FINAL box (text.w x text.h), from the surface's corner, faded in
        var big_pt = 19.0 if size == TILE_S else (22.0 if size == TILE_W else (32.0 if size == TILE_L else (44.0 if size == TILE_XL or size == TILE_FULL else 24.0)))
        var sub_pt = 13.0 if size == TILE_S else (13.5 if size == TILE_W else (16.0 if size == TILE_L else (18.0 if size == TILE_XL or size == TILE_FULL else 14.0)))
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
            rect(s, X.x(ix), X.y(iy), X.n(22.0), X.n(22.0), with_alpha(hue, op), X.n(7.0))
            if not draw_icon(s, tile_icon(t.icon), X.x(ix + 4.0), X.y(iy + 4.0), X.n(14.0), with_alpha(look.glyph(), op)):
                _letter(s, font, t.head, X.x(ix), X.y(iy), X.n(22.0), with_alpha(look.glyph(), op))
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
                var chip_fill = mix(look.card, hue, 0.28 if look.dark else 0.13)
                var chip_ink = mix(hue, look.ink, 0.45) if look.dark else hue
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


comptime TEXT_CAP = 240  # characters a tile's line is ever measured with (a face is at most 120: genui's limit)


def _fit(font: Font, text: String, size: Float64, weight: Int, max_px: Float64) -> String:
    """`text` cut with an ellipsis to fit max_px: the longest prefix that fits, found by halving (O(n log n) measuring,
    not one measure per dropped character)."""
    if font.measure(text, size, weight) <= max_px:
        return text
    var chars = List[String]()
    for c in text.codepoints():
        chars.append(String(c))
        if len(chars) >= TEXT_CAP:
            break
    var lo = 0  # prefixes of lo characters fit (0 always "fits": "")
    var hi = len(chars)  # ... of hi do not (or are the whole, which didn't)
    while hi - lo > 1:
        var mid = (lo + hi) // 2
        if font.measure(_prefix(chars, mid), size, weight) <= max_px:
            lo = mid
        else:
            hi = mid
    return _prefix(chars, lo) if lo > 0 else String("")


def _prefix(chars: List[String], n: Int) -> String:
    """The first n characters, trailing spaces dropped, and an ellipsis."""
    var t = String("")
    for i in range(min(n, len(chars))):
        t += chars[i]
    return String(t.rstrip()) + "…"


def _wrap(font: Font, text: String, size: Float64, weight: Int, max_px: Float64, max_lines: Int) -> List[String]:
    """Greedy word wrap to max_px; the last allowed line ends in an ellipsis when words are left over."""
    var out = List[String]()
    var cur = String("")
    var words = text.split(" ")
    for i in range(min(len(words), TEXT_CAP // 3)):  # (what could never show is never measured)
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


def _letter(mut s: Surface, font: Font, head: String, x: Float64, y: Float64, n: Float64, c: UInt32):
    """The head's first letter in an icon square at (x, y), n pixels a side (a tile whose icon isn't a Lucide name)."""
    var first = String("")
    for ch in head.codepoints():
        first = String(ch)
        break
    font.draw(s, first.upper(), x + n / 2, y + n * 15.5 / 22.0, n * 12.0 / 22.0, c, MEDIUM, CENTRE)
