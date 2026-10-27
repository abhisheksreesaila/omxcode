# mojoui.theme: the vocabulary a theme speaks, not any theme. A Palette is the colours (and canvas font weights) drawn
# views use, so a canvas (a grid, a chart) matches the controls around it; a Theme is what an app hands its hosts:
# a name (CSS classes), a palette, a GTK style sheet and a web style sheet. Themes themselves (this repo's,
# yours) live outside the framework (`themes/` in this repo, D-260); an app that names none gets each
# platform's own look (Theme.native()).

from mojoui.canvas import rgba
from mojoui.text import REGULAR, MEDIUM


def hex_rgba(text: String, fallback: UInt32) -> UInt32:
    """ "#7aa2f7" → rgba (fallback if it doesn't parse)."""
    var t = String(text.strip())
    if t.startswith("#"):
        var rest = String(t[byte=1:])
        t = rest
    if t.byte_length() != 6:
        return fallback
    var v = 0
    for c in t.codepoint_slices():
        var o = ord(c)
        var d: Int
        if 48 <= o <= 57:
            d = o - 48
        elif 97 <= o <= 102:
            d = o - 87
        elif 65 <= o <= 70:
            d = o - 55
        else:
            return fallback
        v = v * 16 + d
    return rgba((v >> 16) & 255, (v >> 8) & 255, v & 255)


def mix(a: UInt32, b: UInt32, t: Float64) -> UInt32:
    """a blended toward b by t (0 = a, 1 = b), opaque."""
    var out = UInt32(255) << 24
    for shift in [0, 8, 16]:
        var x = Float64(Int((a >> UInt32(shift)) & 255))
        var y = Float64(Int((b >> UInt32(shift)) & 255))
        out |= UInt32(Int(x + (y - x) * t + 0.5) & 255) << UInt32(shift)
    return out


def hex_of(c: UInt32) -> String:
    """rgba → "#rrggbb" (for CSS)."""
    var digits = "0123456789abcdef"
    var out = String("#")
    for shift in [0, 8, 16]:
        var v = Int((c >> UInt32(shift)) & 255)
        out += String(digits[byte = v // 16]) + String(digits[byte = v % 16])
    return out


def hx(text: StringLiteral) -> UInt32:
    """A design token ("#0e7c86") as a colour."""
    return hex_rgba(String(text), 0)


def luminance(c: UInt32) -> Float64:
    """Relative brightness 0–1 (rough: for light vs dark)."""
    var r = Float64(Int(c & 255))
    var g = Float64(Int((c >> 8) & 255))
    var b = Float64(Int((c >> 16) & 255))
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0


comptime PLAIN_SERIES: List[UInt32] = [rgba(15, 108, 189), rgba(42, 160, 164), rgba(147, 115, 192), rgba(202, 80, 16), rgba(87, 129, 27),
                                      rgba(227, 0, 140), rgba(58, 150, 221), rgba(174, 140, 0)]


@fieldwise_init
struct Palette(Copyable, Movable):
    var dark: Bool
    var page: UInt32  # behind everything
    var card: UInt32  # panels (and canvases)
    var raised: UInt32  # headers, tracks: a step off the card
    var ink: UInt32  # text
    var ink2: UInt32  # secondary text
    var ink3: UInt32  # quiet text (row numbers, dimmed bars)
    var line: UInt32  # gridlines
    var line_strong: UInt32
    var accent: UInt32
    var accent_ink: UInt32  # text on the accent
    var accent_tint: UInt32  # dimmed bars
    var accent_wash: UInt32  # selection background
    var formula: UInt32  # formula columns' text
    var good: UInt32
    var bad: UInt32
    var warn: UInt32  # findings that ask for attention
    var regular: Int  # canvas text weights (Inter or JetBrains Mono)
    var medium: Int
    var series: List[UInt32]  # a chart's series colours, the first first (a theme's own; colour-blind safe where it can)
    var chrome: UInt32  # the window's band: title bar, toolbar, bottom bar (the page colour unless a theme says otherwise)
    var chrome_ink: UInt32
    var chrome_line: UInt32

    def __init__(out self, dark: Bool, page: UInt32, card: UInt32, raised: UInt32, ink: UInt32, ink2: UInt32, ink3: UInt32,
                 line: UInt32, line_strong: UInt32, accent: UInt32, accent_ink: UInt32, accent_tint: UInt32, accent_wash: UInt32,
                 formula: UInt32, good: UInt32, bad: UInt32, warn: UInt32, regular: Int, medium: Int):
        """A palette whose chrome is its page, with the default series (light: plain's; dark: the accent first)."""
        var series = materialize[PLAIN_SERIES]() if not dark else [accent, rgba(68, 157, 171), rgba(173, 142, 230), rgba(224, 175, 104), rgba(158, 206, 106),
                                                                    rgba(247, 118, 142), rgba(13, 185, 215), rgba(235, 146, 123)]
        self = Self(dark, page, card, raised, ink, ink2, ink3, line, line_strong, accent, accent_ink, accent_tint, accent_wash,
                    formula, good, bad, warn, regular, medium, series^, page, ink, line)

    @staticmethod
    def plain() -> Palette:
        """The framework's own neutral palette (light greys, one blue): what drawn views use when the app names no theme."""
        return Palette(False, rgba(245, 245, 245), rgba(255, 255, 255), rgba(250, 250, 250), rgba(36, 36, 36), rgba(97, 97, 97),
                       rgba(140, 140, 140), rgba(235, 235, 235), rgba(209, 209, 209), rgba(15, 108, 189), rgba(255, 255, 255),
                       rgba(199, 224, 244), rgba(235, 243, 252), rgba(17, 94, 163), rgba(16, 124, 16), rgba(197, 15, 31),
                       rgba(234, 88, 12), REGULAR, MEDIUM)

    @staticmethod
    def plain_dark() -> Palette:
        """The plain palette for a system in dark mode (the platform's own dark greys, a lighter blue)."""
        return Palette(True, hx("#1e1e1e"), hx("#262626"), hx("#303030"), hx("#ffffff"), hx("#deddda"), hx("#a8a6a2"),
                       hx("#363636"), hx("#4a4a4a"), hx("#78aeed"), hx("#1e1e1e"), mix(hx("#262626"), hx("#78aeed"), 0.40),
                       mix(hx("#262626"), hx("#78aeed"), 0.16), hx("#dc8add"), hx("#8ff0a4"), hx("#ff7b63"), hx("#f8e45c"), REGULAR, MEDIUM)

    def with_accent(self, accent: UInt32) -> Palette:
        """The same palette with another accent (0: unchanged): a mode's tint (an app's sheet green, its report red)."""
        if accent == 0:
            return self.copy()
        var p = self.copy()
        p.accent = accent
        p.accent_tint = mix(p.card, accent, 0.40)
        p.accent_wash = mix(p.card, accent, 0.10)
        return p^

    def data(self, i: Int) -> UInt32:
        """The i-th series colour."""
        return self.series[i % len(self.series)] if len(self.series) > 0 else self.accent


# ---- a look: the shapes and type every host draws (mojoui/look.mojo writes GTK's and the web's rules from it) ----

@fieldwise_init
struct Shadow(Copyable, Movable):
    """One shadow (CSS box-shadow, a CALayer's shadow): offset down, blur, spread, its colour (alpha in the top byte);
    `inset`: drawn inside the edge (a glass panel's top highlight)."""

    var y: Int
    var blur: Int
    var spread: Int
    var color: UInt32
    var inset: Bool


comptime HEIGHT_AUTO = -2  # Surface.height: as tall as its content (a name to tap in a table: no control height)


struct Surface(Copyable, Movable):
    """How a framework role's panel looks: `role` is the tag its component sets ("toolbar", "inspector", "tile").
    Sizes in points; -1: the component's own. `fill` 0: no fill of its own. `blur`: a backdrop blur where the host has
    one (the web, the Mac's visual effect view). `font`/`font_size`/`ink`: its text, "" / 0 for the body's."""

    var role: String
    var fill: UInt32
    var radius_top: Int
    var radius_bottom: Int
    var margin_top: Int
    var margin_x: Int
    var margin_bottom: Int
    var pad_top: Int
    var pad_x: Int
    var pad_bottom: Int
    var shadows: List[Shadow]
    var line_top: UInt32  # a 1 pt line along its top edge (0: none)
    var line_bottom: UInt32
    var blur: Int
    var min_height: Int
    var font: String
    var font_size: Float64
    var ink: UInt32
    var font_weight: Int  # its text's weight (400, 500, 600; 0 for the body's)
    var tracking: Float64  # its text's letter spacing in points (0: none)
    var line_height: Float64  # its text's line height (0: the font's)
    var outline: UInt32  # a border of its own (0: none), `outline_w` wide, dashed or solid (the add tile's dashes)
    var outline_w: Int
    var dashed: Bool
    # (goal 33 M7, D-410: what the console's pieces needed beyond the above, each optional; -1 / 0: the component's own)
    var pad_left: Int  # its leading and trailing padding when they differ from pad_x (the Beacon's 0 16 0 12)
    var pad_right: Int
    var gap: Int  # the space between its children, over the stack's own
    var height: Int  # a fixed height (HEIGHT_AUTO: its content's, over a control's own)
    var icon_size: Int  # the icons inside it: their size (below 0: none shown), stroke width and colour (Lucide's 24-unit stroke)
    var icon_stroke: Float64
    var icon_ink: UInt32
    var text_align: Int  # its text's alignment (START, CENTER, END of mojoui.view)
    var width: Int  # a fixed width (a sidebar, a key column)
    var max_width: Int  # the most it is wide, centred in what it is given (a column of text on a wide window)
    var column_gap: Int  # a grid's space between its columns when it differs from its rows' (gap)
    var scrolls_x: Bool  # a row that stays one line and scrolls sideways (a phone's chip row)
    var inline_flow: Bool  # its children flow as words in a paragraph (a button at the end of a sentence), `gap` before each
    var one_line: Bool  # a row whose items never wrap onto a second line (they shrink instead)
    var shrinks: Bool  # its width gives way when its row is short of room (a filter field on a phone)
    var shares: Bool  # it takes an equal share of its row, never less than its own width (flex 1, a phone.s tabs and verbs)
    var breaks_words: Bool  # a word too long for its line breaks anywhere (CSS's overflow-wrap: anywhere; a long config key)
    var items_shrink: Bool  # its items give way with it, below their content, what overflows cut (a chip keeps its border, its words cut)
    var whole_width: Bool  # its width is its content's in whole pixels, as a script that sizes it from scrollWidth (omxqua's Beacon); GTK and the Mac lay out in whole points already
    var block_flow: Bool  # its children follow block flow: each a full-width block, apart by their own roles' margins (which collapse), not by a gap (a CSS block box; GTK: a box with no spacing, the margins its children's)
    var joins_row: Bool  # its parts become its row's own items (CSS display: contents; a foot's "$" and words beside its tail); other hosts keep it whole
    var ends_row: Bool  # it sits at its row's end, the free room before it (CSS margin-left: auto; GTK expands it to the end)
    var max_chars: Int  # its measure: lines at most this many characters long (CSS's ch: the width of "0"; 0: no limit, D-472)

    def __init__(out self, role: String, fill: UInt32, radius_top: Int, radius_bottom: Int, margin_top: Int, margin_x: Int,
                 margin_bottom: Int, pad_top: Int, pad_x: Int, pad_bottom: Int, var shadows: List[Shadow], line_top: UInt32,
                 line_bottom: UInt32, blur: Int, min_height: Int, font: String, font_size: Float64, ink: UInt32, font_weight: Int,
                 tracking: Float64, line_height: Float64, outline: UInt32, outline_w: Int, dashed: Bool, pad_left: Int = -1,
                 pad_right: Int = -1, gap: Int = -1, height: Int = 0, icon_size: Int = 0, icon_stroke: Float64 = 0,
                 icon_ink: UInt32 = 0, text_align: Int = 0, width: Int = 0, max_width: Int = 0, column_gap: Int = -1, scrolls_x: Bool = False, shares: Bool = False, shrinks: Bool = False, one_line: Bool = False, inline_flow: Bool = False, max_chars: Int = 0, breaks_words: Bool = False, items_shrink: Bool = False, whole_width: Bool = False, block_flow: Bool = False, joins_row: Bool = False, ends_row: Bool = False):
        """Every field in order (the first 24 as they always were); line_height below 0: the font's normal line."""
        self.role = role
        self.fill = fill
        self.radius_top = radius_top
        self.radius_bottom = radius_bottom
        self.margin_top = margin_top
        self.margin_x = margin_x
        self.margin_bottom = margin_bottom
        self.pad_top = pad_top
        self.pad_x = pad_x
        self.pad_bottom = pad_bottom
        self.shadows = shadows^
        self.line_top = line_top
        self.line_bottom = line_bottom
        self.blur = blur
        self.min_height = min_height
        self.font = font
        self.font_size = font_size
        self.ink = ink
        self.font_weight = font_weight
        self.tracking = tracking
        self.line_height = line_height
        self.outline = outline
        self.outline_w = outline_w
        self.dashed = dashed
        self.pad_left = pad_left
        self.pad_right = pad_right
        self.gap = gap
        self.height = height
        self.icon_size = icon_size
        self.icon_stroke = icon_stroke
        self.icon_ink = icon_ink
        self.text_align = text_align
        self.width = width
        self.max_width = max_width
        self.column_gap = column_gap
        self.scrolls_x = scrolls_x
        self.shares = shares
        self.shrinks = shrinks
        self.one_line = one_line
        self.inline_flow = inline_flow
        self.max_chars = max_chars
        self.breaks_words = breaks_words
        self.items_shrink = items_shrink
        self.whole_width = whole_width
        self.block_flow = block_flow
        self.joins_row = joins_row
        self.ends_row = ends_row


@fieldwise_init
struct TypeScale(Copyable, Movable):
    """The theme's font and its sizes (points): body text, a caption, a headline, a title, a section's small caps title."""

    var family: String  # "Inter"; "" for the platform's
    var mono: String  # figures in a status bar or a formula ("JetBrains Mono"); "" for the family
    var body: Float64
    var caption: Float64
    var headline: Float64
    var title: Float64
    var section: Float64
    var tabular: Bool  # figures all one width ("tnum": columns of numbers line up)
    var line: Float64  # a line's height as a share of its text's size (CSS's unitless line-height: 1.45); 0: the font's own


@fieldwise_init
struct Controls(Copyable, Movable):
    """The controls' sizes (points): a tool (icon over its title), an inline tool (its title beside the icon), an icon
    button, a push button, a field; their corners (999: a pill) and their titles' sizes."""

    var tool_w: Int
    var tool_h: Int
    var tool_radius: Int
    var tool_font: Float64
    var inline_h: Int
    var inline_pad: Int
    var inline_radius: Int
    var inline_font: Float64
    var icon: Int  # an icon button's side
    var icon_radius: Int
    var glyph: Int  # an icon's own size inside a button
    var button_radius: Int
    var field_radius: Int
    var control_h: Int  # a push button's, a field's and a dropdown's height (0: the host's own)
    var button_pad: Int  # a push button's title from its sides (GTK and the web: their sheets' padding; Apple hosts read this)
    var field_pad: Int  # a field's text from its sides
    var button_font: Float64  # a push button's title size (0: the body's; omxqua's .btn: .95em)
    var button_weight: Int  # its weight (0: the host's own)
    var divider_gap: Int  # a Divider's room above and below it in a column (0: the host's own: the web's hr 4 px, the Mac's 4 pt, GTK none; below 0: none on every host, D-490)
    var divider_side: Int  # its room either side where it stands up in a row (0: the host's own: the web's 6 px, the Mac's 6 pt, GTK none; below 0: none)
    var icon_w: Int  # an icon button's width where the theme's sheet draws it narrower than its side (0: its side, `icon`): the skins' web sheet gives it 1 + 6 + its 18 px icon + 6 + 1 = 32 (D-558)


# The web host draws a button's icon at 18 px (mojoui/hosts/web.py); a host that sizes a tool by its parts reserves the same
# room, so an inline tool is as wide as the web's (D-558)
comptime BUTTON_ICON = 18


@fieldwise_init
struct Segments(Copyable, Movable):
    """A segmented control's (and tabs') look: a track holding the segments, the chosen one filled. `h` 0: the host's own."""

    var track: UInt32  # the track's fill (alpha in the top byte; 0: none)
    var track_radius: Int
    var track_pad: Int  # the segments from the track's edge
    var ring: UInt32  # a hairline around the track (0: none)
    var h: Int  # a segment's height
    var pad: Int  # its title from its sides
    var radius: Int
    var font_size: Float64
    var weight: Int
    var ink: UInt32
    var on_fill: UInt32  # the chosen segment
    var on_ink: UInt32
    var on_weight: Int
    var on_shadow: Bool  # a soft shadow under the chosen one (a white thumb)

    @staticmethod
    def none() -> Segments:
        return Segments(0, 0, 0, 0, 0, 0, 0, 13, 400, 0, 0, 0, 400, False)


@fieldwise_init
struct Motion(Copyable, Movable):
    """How a press feels: the control shrinks to `press_scale` while held and springs back over `press_ms` on `spring`
    (a CSS easing: omxqua's linear() spring); `ease`: the same feel where a host has no linear() (GTK: a cubic-bezier).
    press_scale 0: the host's own press."""

    var press_scale: Float64
    var press_ms: Int
    var spring: String
    var ease: String

    @staticmethod
    def none() -> Motion:
        return Motion(0, 0, "", "")


def default_space() -> List[Int]:
    """The spacing scale with no theme's own: SPACE_XXS … SPACE_XXL of mojoui.view, in points (D-412)."""
    return [2, 4, 8, 12, 16, 24, 32]


struct Look(Copyable, Movable):
    var type: TypeScale
    var controls: Controls
    var surfaces: List[Surface]
    var segments: Segments
    var motion: Motion  # the press (omxqua's spring); Motion.none(): the host's own
    var space: List[Int]  # the spacing scale (SPACE_XXS … SPACE_XXL, mojoui.view): what an app's spacing and padding tokens become

    def __init__(out self, type: TypeScale, controls: Controls, var surfaces: List[Surface], segments: Segments):
        self = Look(type, controls, surfaces^, segments, Motion.none())

    def __init__(out self, type: TypeScale, controls: Controls, var surfaces: List[Surface], segments: Segments, motion: Motion,
                 var space: List[Int] = default_space()):
        self.type = type.copy()
        self.controls = controls.copy()
        self.surfaces = surfaces^
        self.segments = segments.copy()
        self.motion = motion.copy()
        self.space = space^

    @staticmethod
    def none() -> Look:
        """No look of the theme's own: each host's defaults (and no rules written)."""
        return Look(TypeScale("", "", 13, 11, 15, 26, 11, False, 0), Controls(0, 0, 0, 11, 0, 0, 0, 12, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), [], Segments.none())

    def is_none(self) -> Bool:
        return len(self.surfaces) == 0 and self.controls.tool_w == 0

    def surface(self, role: String) -> Int:
        """The index of `role`'s surface, -1 if the look has none."""
        for k in range(len(self.surfaces)):
            if self.surfaces[k].role == role:
                return k
        return -1


def glass(role: String, radius_top: Int, radius_bottom: Int, margin_top: Int, margin_x: Int, margin_bottom: Int, pad: Int) -> Surface:
    """A translucent white panel with a rim, a top highlight and a soft shadow (floating islands)."""
    var shadows: List[Shadow] = [Shadow(1, 0, 0, rgba(255, 255, 255, 230), True), Shadow(0, 0, 1, rgba(255, 255, 255, 191), False),
                                 Shadow(8, 32, 0, rgba(15, 23, 42, 26), False), Shadow(1, 2, 0, rgba(15, 23, 42, 15), False)]
    return Surface(role, rgba(255, 255, 255, 158), radius_top, radius_bottom, margin_top, margin_x, margin_bottom, pad, pad, pad,
                   shadows^, 0, 0, 24, -1, "", 0, 0, 0, 0, 0, 0, 0, False)


def solid(role: String, radius: Int, pad_top: Int, pad_x: Int, pad_bottom: Int) -> Surface:
    """An opaque white card with a hairline ring and a faint shadow (the content: a table, a tile)."""
    var shadows: List[Shadow] = [Shadow(0, 0, 1, rgba(15, 23, 42, 18), False), Shadow(1, 3, 0, rgba(15, 23, 42, 13), False)]
    return Surface(role, rgba(255, 255, 255), radius, radius, -1, -1, -1, pad_top, pad_x, pad_bottom, shadows^, 0, 0, 0, -1, "", 0, 0, 0, 0, 0, 0, 0, False)


def band(role: String, fill: UInt32, line_top: UInt32, line_bottom: UInt32) -> Surface:
    """A full-width strip in the window's chrome (the skins' toolbar and status bar): a fill and a hairline."""
    return Surface(role, fill, 0, 0, -1, -1, -1, -1, -1, -1, [], line_top, line_bottom, 0, -1, "", 0, 0, 0, 0, 0, 0, 0, False)


def words(role: String, size: Float64, weight: Int, ink: UInt32, tracking: Float64 = 0) -> Surface:
    """A role whose look is its text only (a chart's sentence: 15 pt, semibold, in the ink); no panel of its own."""
    return Surface(role, 0, -1, -1, -1, -1, -1, -1, -1, -1, [], 0, 0, 0, -1, "", size, ink, weight, tracking, 0, 0, 0, False)


def chip(role: String, fill: UInt32, ring: UInt32, size: Float64, ink: UInt32, radius: Int, pad_v: Int, pad_h: Int) -> Surface:
    """A small filled shape with its text (a KPI's note, a stat card): a fill, a hairline ring inside its edge, corners."""
    var shadows: List[Shadow] = [Shadow(0, 0, 1, ring, True)] if ring != 0 else []
    return Surface(role, fill, radius, radius, -1, -1, -1, pad_v, pad_h, pad_v, shadows^, 0, 0, 0, -1, "", size, ink, 0, 0, 0, 0, 0, False)


def slot(role: String, outline: UInt32, radius: Int, min_height: Int, ink: UInt32) -> Surface:
    """An empty place for something to come (the Report's add tile): no fill, a dashed outline, its text quiet."""
    return Surface(role, 0, radius, radius, -1, -1, -1, -1, -1, -1, [], 0, 0, 0, min_height, "", 0, ink, 0, 0, 0, outline, 2, True)



@fieldwise_init
struct Theme(Copyable, Movable):
    """What an app hands its hosts (App.theme()): hosts apply it as given and know no theme by name."""
    var id: String  # a short name ("" native): DESIGN lines, the icons' cache folder
    var classes: String  # CSS classes on the GTK window and the web page's body (space-separated)
    var palette: Palette  # drawn views; the web page's --o-* variables; Apple hosts' tints when paint_native
    var gtk_css: String  # a GTK style sheet (over libadwaita), rules scoped to `window.<class>`
    var web_css: String  # a web style sheet, rules scoped to `body.<class>`, reading the palette's --o-* variables
    var icon_ink: UInt32  # the icons' ink, and on filled (accent) buttons
    var icon_on_accent: UInt32
    var paint_native: Bool  # Apple hosts: colour their native controls with the palette and set Inter (a skin), else system colours
    var look: Look  # the type scale, control sizes and surfaces every host draws (mojoui/look.mojo); GTK and the web write their rules from it

    @staticmethod
    def native(dark: Bool = False) -> Theme:
        """No theme: each platform's own look (libadwaita, the system's web font and colours, AppKit, UIKit); drawn views
        take the plain palette, dark when the system is (App.appearance)."""
        return Theme("", "", Palette.plain_dark() if dark else Palette.plain(), "", "", rgba(66, 66, 66), rgba(255, 255, 255), False, Look.none())

    def key(self) -> String:
        """Changes whenever what hosts show would (the theme, its palette's accent, page, error tone and light or dark, its
        style sheets): hosts restyle then. (A sheet edited in place to the same length goes unnoticed: change its id too.)"""
        return (self.id + hex_of(self.palette.accent) + hex_of(self.palette.page) + hex_of(self.palette.bad) + ("d" if self.palette.dark else "l")
                + String(self.gtk_css.byte_length()) + "/" + String(self.web_css.byte_length()) + "/" + String(len(self.look.surfaces)))


def palette_css(p: Palette) -> String:
    """A palette as a page's CSS variables (the vocabulary every web theme reads): the web host's page and GTK's
    WebComponent views (goal 34 M3)."""
    var shadow = "0 6px 20px rgba(0,0,0,.55), 0 0 0 1px #34363b" if p.dark else "0 4px 16px rgba(16,24,40,.12), 0 1px 3px rgba(16,24,40,.08)"
    return ("body {--o-page: " + hex_of(p.page) + ";--o-card: " + hex_of(p.card) + ";--o-raised: " + hex_of(p.raised)
            + ";--o-ink: " + hex_of(p.ink) + ";--o-ink2: " + hex_of(p.ink2) + ";--o-ink3: " + hex_of(p.ink3) + ";--o-line: " + hex_of(p.line)
            + ";--o-strong: " + hex_of(p.line_strong) + ";--o-accent: " + hex_of(p.accent) + ";--o-on-accent: " + hex_of(p.accent_ink)
            + ";--o-wash: " + hex_of(p.accent_wash) + ";--o-bad: " + hex_of(p.bad) + ";--o-good: " + hex_of(p.good) + ";--o-warn: " + hex_of(p.warn)
            + ";--o-formula: " + hex_of(p.formula) + ";--o-chrome: " + hex_of(p.chrome) + ";--o-chrome-ink: " + hex_of(p.chrome_ink)
            + ";--o-chrome-line: " + hex_of(p.chrome_line) + ";--o-tint: " + hex_of(p.accent_tint) + ";--o-data: " + hex_of(p.data(0)) + ";--o-shadow: " + shadow + ";"
            + ("color-scheme: dark;" if p.dark else "color-scheme: light;") + "}")
