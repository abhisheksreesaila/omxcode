# mojoui.skin (goal 79): a skin as a theme: a set of tokens (desk, panel, ink, accent, five tints, faces, radii, a
# shadow scale) and the colours chrome derives from them (color-mix in sRGB, as CSS does). Components
# (mojoui.notesshell, mojoui.pagesheet, mojoui.omnibar…) read only these. The skins themselves belong to the app (D-7928:
# Personal Note's Paper, Night and Crayon live in examples/pnote/pnlook.mojo): an app fills a Skin("name") and calls derive().
#
#   var sk = Skin("mine"); sk.panel = hexc("#ffffff"); …; sk.derive()
#   p.rect(x, y, w, h, sk.panel, sk.radius)

from mojoui.canvas import rgba


def hexc(s: String, alpha: Float64 = 1.0) -> UInt32:
    """#rrggbb → our colour (0xAABBGGRR)."""
    var b = s.as_bytes()
    var v = 0
    for i in range(1, len(b)):
        var c = Int(b[i])
        var d = c - 48 if c <= 57 else (c - 87 if c >= 97 else c - 55)
        v = v * 16 + d
    return rgba((v >> 16) & 255, (v >> 8) & 255, v & 255, Int(alpha * 255 + 0.5))


def with_alpha(c: UInt32, alpha: Float64) -> UInt32:
    return (c & 0x00FFFFFF) | (UInt32(Int(alpha * 255 + 0.5)) << 24)


def _ch(c: UInt32, i: Int) -> Float64:
    return Float64(Int((c >> UInt32(i * 8)) & 0xFF))


def mix(a: UInt32, pct_a: Float64, b: UInt32) -> UInt32:
    """CSS color-mix(in srgb, a pct_a, b) for opaque colours: each channel a·p + b·(1 − p), rounded."""
    var p = pct_a / 100.0
    var r = _ch(a, 0) * p + _ch(b, 0) * (1 - p)
    var g = _ch(a, 1) * p + _ch(b, 1) * (1 - p)
    var bl = _ch(a, 2) * p + _ch(b, 2) * (1 - p)
    var al = _ch(a, 3) * p + _ch(b, 3) * (1 - p)
    return rgba(Int(r + 0.5), Int(g + 0.5), Int(bl + 0.5), Int(al + 0.5))


def over(top: UInt32, bottom: UInt32) -> UInt32:
    """An opaque bottom with a translucent top on it (what a state layer over a panel shows)."""
    var a = _ch(top, 3) / 255.0
    return rgba(Int(_ch(top, 0) * a + _ch(bottom, 0) * (1 - a) + 0.5), Int(_ch(top, 1) * a + _ch(bottom, 1) * (1 - a) + 0.5),
                Int(_ch(top, 2) * a + _ch(bottom, 2) * (1 - a) + 0.5), 255)


@fieldwise_init
struct Shadow(ImplicitlyCopyable, Movable):
    """One CSS box-shadow: offset, blur radius, spread, colour (inset ones aren't drawn)."""
    var dx: Float64
    var dy: Float64
    var blur: Float64
    var spread: Float64
    var color: UInt32


struct Skin(Copyable, Movable):
    var name: String
    var dark: Bool
    var desk: UInt32
    var desk_dot: UInt32
    var panel: UInt32
    var edge: UInt32
    var ink: UInt32
    var ink_soft: UInt32
    var muted: UInt32
    var line: UInt32
    var accent: UInt32
    var accent_ink: UInt32
    var c1: UInt32
    var c2: UInt32
    var c3: UInt32
    var c4: UInt32
    var c5: UInt32
    var danger: UInt32
    var paper: UInt32
    var page_radius: Float64
    var display: String  # family
    var display_weight: Int
    var display_italic: Bool
    var title_track: Float64  # em
    var radius: Float64
    var radius_control: Float64
    var state: UInt32  # --oq-state as a colour (alpha applied by hover/pressed/accent_soft)
    var swatch: UInt32  # the skin's own dot in the switcher
    var shadow1: List[Shadow]
    var shadow2: List[Shadow]
    var shadow3: List[Shadow]
    # derived (skins.css / chrome.css)
    var ui_muted: UInt32
    var accent_fill: UInt32
    var accent_text: UInt32
    var hover: UInt32
    var pressed: UInt32
    var accent_soft: UInt32
    var surface_cool: UInt32
    var shelf: UInt32  # an open shelf's wash: ink at 3.5 %
    var toggle_on: UInt32  # the panel toggle while the panel is open
    var scrim: UInt32
    var accent_flat: Bool  # the accent is used as is for fills and words (a dark skin), else mixed toward the ink
    var locked: UInt32  # a locked (secure) document's colour, its soft wash, its line (0: derived from the accent)
    var locked_soft: UInt32
    var locked_line: UInt32

    def __init__(out self, name: String):
        self.name = name
        self.dark = False
        self.desk = 0
        self.desk_dot = 0
        self.panel = 0
        self.edge = 0
        self.ink = 0
        self.ink_soft = 0
        self.muted = 0
        self.line = 0
        self.accent = 0
        self.accent_ink = 0
        self.c1 = 0
        self.c2 = 0
        self.c3 = 0
        self.c4 = 0
        self.c5 = 0
        self.danger = 0
        self.paper = 0
        self.page_radius = 4
        self.display = "Bricolage Grotesque"
        self.display_weight = 700
        self.display_italic = False
        self.title_track = -0.02
        self.radius = 14
        self.radius_control = 8
        self.state = 0
        self.swatch = 0
        self.shadow1 = List[Shadow]()
        self.shadow2 = List[Shadow]()
        self.shadow3 = List[Shadow]()
        self.ui_muted = 0
        self.accent_fill = 0
        self.accent_text = 0
        self.hover = 0
        self.pressed = 0
        self.accent_soft = 0
        self.surface_cool = 0
        self.shelf = 0
        self.toggle_on = 0
        self.scrim = 0
        self.accent_flat = False
        self.locked = 0
        self.locked_soft = 0
        self.locked_line = 0

    def derive(mut self):
        if self.locked == 0:
            self.locked = self.accent
        if self.locked_soft == 0:
            self.locked_soft = mix(self.locked, 12, self.panel)
        if self.locked_line == 0:
            self.locked_line = mix(self.locked, 30, self.panel)
        self.ui_muted = mix(self.muted, 70, self.ink)
        if self.accent_flat:
            self.accent_fill = self.accent
            self.accent_text = self.accent
        else:
            self.accent_fill = mix(self.accent, 85, self.ink)
            self.accent_text = mix(self.accent, 65, self.ink)
        self.hover = with_alpha(self.state, 0.08)
        self.pressed = with_alpha(self.state, 0.12)
        self.accent_soft = with_alpha(self.state, 0.16)
        self.surface_cool = mix(self.ink, 6, self.panel)
        self.shelf = with_alpha(self.ink, 0.035)
        self.toggle_on = mix(self.panel, 87, self.ink)

    def tint(self, n: Int) -> UInt32:
        """--sk-c1 … --sk-c5."""
        if n == 1:
            return self.c1
        if n == 2:
            return self.c2
        if n == 3:
            return self.c3
        if n == 4:
            return self.c4
        return self.c5
