# mojoui.skin (goal 79): a skin as a theme: the tokens Personal Note's web skins define (Paper, Night, Crayon), the
# colours its chrome derives from them (color-mix in sRGB, as CSS does), its faces, radii and shadow scale. Components
# (mojoui.notesshell, mojoui.pagesheet, mojoui.omnibar…) read only these, so a new skin is one more constructor.
#
#   var sk = skin_named("paper")          # paper (default) | night | crayon
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
        if self.name == "night":
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


def _shadows(a: Float64, b: Float64, c: Float64, r: Int, g: Int, bl: Int) -> Tuple[List[Shadow], List[Shadow], List[Shadow]]:
    var s1 = List[Shadow]()
    s1.append(Shadow(0, 1, 2, 0, rgba(r, g, bl, 15)))
    s1.append(Shadow(0, 0, 0, 1, rgba(r, g, bl, Int(a * 255 + 0.5))))
    var s2 = List[Shadow]()
    s2.append(Shadow(0, 6, 18, 0, rgba(r, g, bl, 26)))
    s2.append(Shadow(0, 0, 0, 1, rgba(r, g, bl, Int(b * 255 + 0.5))))
    var s3 = List[Shadow]()
    s3.append(Shadow(0, 18, 48, 0, rgba(r, g, bl, 46)))
    s3.append(Shadow(0, 0, 0, 1, rgba(r, g, bl, Int(c * 255 + 0.5))))
    return (s1^, s2^, s3^)


def paper_skin() -> Skin:
    var s = Skin("paper")
    s.desk = hexc("#ece7dd")
    s.desk_dot = rgba(60, 45, 20, 26)  # .10
    s.panel = hexc("#fffdf8")
    s.edge = hexc("#e2dbcd")
    s.ink = hexc("#1f1b16")
    s.ink_soft = hexc("#4a443b")
    s.muted = hexc("#6b6357")
    s.line = hexc("#e2dbcd")
    s.accent = hexc("#1f1b16")
    s.accent_ink = hexc("#fffdf8")
    s.c1 = hexc("#ffd66b")
    s.c2 = hexc("#9fe0c0")
    s.c3 = hexc("#a9cfff")
    s.c4 = hexc("#cdb8ff")
    s.c5 = hexc("#ff9c85")
    s.danger = hexc("#b93a27")
    s.paper = hexc("#fbfaf5")
    s.page_radius = 4
    s.display = "Bricolage Grotesque"
    s.display_weight = 700
    s.title_track = -0.02
    s.radius = 14
    s.radius_control = 8
    s.state = rgba(31, 27, 22)
    s.swatch = hexc("#1f1b16")
    var sh = _shadows(0.05, 0.055, 0.06, 20, 16, 10)
    s.shadow1 = sh[0].copy()
    s.shadow2 = sh[1].copy()
    s.shadow3 = sh[2].copy()
    s.scrim = rgba(12, 10, 8, 82)
    s.locked = hexc("#6a46c9")  # (skins.css --sk-secure, -soft, -line)
    s.locked_soft = hexc("#efe9fb")
    s.locked_line = hexc("#d9cdf6")
    s.derive()
    return s^


def crayon_skin() -> Skin:
    var s = Skin("crayon")
    s.desk = hexc("#f2f2f7")
    s.desk_dot = rgba(0, 0, 40, 18)  # .07
    s.panel = hexc("#ffffff")
    s.edge = hexc("#e3e3ea")
    s.ink = hexc("#111114")
    s.ink_soft = hexc("#3a3a42")
    s.muted = hexc("#6e6e78")
    s.line = hexc("#e6e6ec")
    s.accent = hexc("#2f6fe0")
    s.accent_ink = hexc("#ffffff")
    s.c1 = hexc("#ffd60a")
    s.c2 = hexc("#30d158")
    s.c3 = hexc("#64b5ff")
    s.c4 = hexc("#bf5af2")
    s.c5 = hexc("#ff6b3d")
    s.danger = hexc("#d6391f")
    s.paper = hexc("#ffffff")
    s.page_radius = 10
    s.display = "Bricolage Grotesque"
    s.display_weight = 700
    s.title_track = -0.035
    s.radius = 18
    s.radius_control = 10
    s.state = rgba(17, 17, 20)
    s.swatch = hexc("#2f6fe0")
    var sh = _shadows(0.05, 0.055, 0.06, 10, 14, 40)
    s.shadow1 = sh[0].copy()
    s.shadow2 = sh[1].copy()
    s.shadow3 = sh[2].copy()
    s.scrim = rgba(12, 10, 8, 82)
    s.locked = hexc("#6a46c9")  # (skins.css --sk-secure, -soft, -line)
    s.locked_soft = hexc("#efe9fb")
    s.locked_line = hexc("#d9cdf6")
    s.derive()
    return s^


def night_skin() -> Skin:
    var s = Skin("night")
    s.dark = True
    s.desk = hexc("#0d1015")
    s.desk_dot = rgba(160, 190, 255, 18)  # .07
    s.panel = hexc("#171c24")
    s.edge = hexc("#232a35")
    s.ink = hexc("#eceff4")
    s.ink_soft = hexc("#b9c1cd")
    s.muted = hexc("#7d8796")
    s.line = hexc("#262e3a")
    s.accent = hexc("#7ee7c8")
    s.accent_ink = hexc("#07261d")
    s.c1 = hexc("#ffc877")
    s.c2 = hexc("#7ee7c8")
    s.c3 = hexc("#9db4ff")
    s.c4 = hexc("#d3a6ff")
    s.c5 = hexc("#ff8fb1")
    s.danger = hexc("#ff8fb1")
    s.paper = hexc("#fbfaf5")
    s.page_radius = 6
    s.display = "Instrument Serif"
    s.display_weight = 400
    s.display_italic = True
    s.title_track = -0.01
    s.radius = 14
    s.radius_control = 8
    s.state = rgba(236, 239, 244)
    s.swatch = hexc("#1b2130")
    s.shadow1.append(Shadow(0, 1, 2, 0, rgba(0, 0, 0, 128)))
    s.shadow2.append(Shadow(0, 6, 18, 0, rgba(0, 0, 0, 115)))
    s.shadow2.append(Shadow(0, 0, 0, 1, rgba(236, 239, 244, 13)))
    s.shadow3.append(Shadow(0, 18, 48, 0, rgba(0, 0, 0, 153)))
    s.shadow3.append(Shadow(0, 0, 0, 1, rgba(236, 239, 244, 15)))
    s.scrim = rgba(0, 0, 0, 140)
    s.locked = hexc("#c3a8ff")
    s.locked_soft = rgba(195, 168, 255, 33)
    s.locked_line = rgba(195, 168, 255, 82)
    s.derive()
    return s^


def skin_named(name: String) -> Skin:
    if name == "night":
        return night_skin()
    if name == "crayon":
        return crayon_skin()
    return paper_skin()
