# omxqua as a mojoui theme (goal 33 M3, D-330): the owner's design language as the original console wears it
# (~/Projects/mxstudio/mxconsole/console/omxqua/src/tokens.css: `oq-root oq-family-dev oq-light|oq-night`, the
# Developer family, "Graphite"). Material texture: opaque tonal surfaces, one soft shadow, no glass, blur or
# gradients; Liquid motion: a press shrinks to 0.96 and springs back. Geist for words, Geist Mono for figures, one ink
# accent. Every value below is a token from tokens.css (named beside it); the Look carries them to every host.
#
#   def theme(self) -> Theme: return omxqua()            (omxqua(True) at night; follow App.appearance like the console)

from mojoui.canvas import rgba
from mojoui.text import REGULAR, MEDIUM
from mojoui.theme import Palette, Theme, hx, mix, hex_of
from mojoui.theme import Look, Surface, Shadow, TypeScale, Controls, Segments, Motion, solid, band, words, chip, slot
from mojoui.look import css_color, surface_rule, px, fpx, line_px
from themes.skins import skin_css, SKIN_WEB
from mojoui.markdown import markdown_roles
from mojoui.timeline import timeline_roles
from mojoui.logview import logpane_roles
from themes.omxqua_kit import kit_roles

# ---- tokens.css, the root (both modes) and the Developer family ----
comptime FONT = "Geist"  # --oq-font
comptime FONT_MONO = "Geist Mono"  # --oq-font-mono
comptime TEXT = 14.0  # the console's body (blades.css: body 14px; --oq-text 13.5 is the family's, the console sets 14)
comptime TITLE = 28.0  # --oq-title
comptime LINE = 1.45  # the console's body line height (blades.css: body 14px/1.45)
comptime RADIUS_XS = 4  # --oq-radius-xs: badges and tags
comptime RADIUS_IN = 10  # --oq-radius-in: inputs
comptime RADIUS_CARD = 12  # --oq-radius-card (.oq-family-dev)
comptime RADIUS_FULL = 999  # --oq-radius-full: pills = tappable
comptime TARGET = 34  # --oq-target (.oq-family-dev)
comptime PRESS_SCALE = 0.96  # --oq-press-scale
comptime SPRING_FAST_MS = 300  # --oq-spring-fast-dur
comptime SPRING_FAST = "linear(0, 0.02, 0.071, 0.142, 0.226, 0.316, 0.407, 0.494, 0.577, 0.653, 0.72, 0.78, 0.831, 0.875, 0.911, 0.94, 0.964, 0.983, 0.997, 1.007, 1.014, 1.019, 1.021, 1.023, 1.023, 1.022, 1.02, 1.018, 1.017, 1.014, 1.012, 1.01, 1.009, 1.007, 1.006, 1.004, 1.003, 1.002, 1.002, 1.001, 1)"  # --oq-spring-fast (k380 c30)
comptime EASE_IN = "cubic-bezier(0.2, 0, 0, 1)"  # --oq-ease-in (decelerate: arriving): GTK's stand-in for the spring


def alpha(a: Float64) -> Int:
    """A token's alpha (.045) as the byte a colour carries."""
    return Int(a * 255 + 0.5)


def state(dark: Bool, a: Float64) -> UInt32:
    """omxqua's state layer: rgb(var(--oq-state) / a) (.08 hover, .12 press, .16 selected)."""
    return rgba(237, 237, 239, alpha(a)) if dark else rgba(11, 11, 13, alpha(a))


def omxqua_palette(dark: Bool = False) -> Palette:
    """The Developer family's colours (.oq-family-dev.oq-light / .oq-night). omxqua's inks: ink, ink-2 (the quiet text) and
    ink-faint (ink3: the console's --faint, its faintest words: group heads, counts, hints); line-2 is the quiet hairline (gridlines, row rules), line the strong one (fields, badges, headers)."""
    var p: Palette
    if dark:
        p = Palette(True, hx("#0b0b0d"), hx("#151518"), hx("#1d1d21"), hx("#ededef"), hx("#a9a9b1"), hx("#3a3a40"),
                    hx("#202025"), hx("#2a2a30"), hx("#ededef"), hx("#0b0b0d"), mix(hx("#151518"), hx("#ededef"), 0.40), mix(hx("#151518"), hx("#ededef"), 0.08),
                    hx("#8b7bff"), hx("#3ccf6e"), hx("#f2555a"), hx("#f5a524"), REGULAR, MEDIUM,
                    [hx("#8b7bff"), hx("#3aa0ff"), hx("#2bc3ad"), hx("#ff8a3d"), hx("#f2555a"), hx("#e0b400")], hx("#0b0b0d"), hx("#ededef"), hx("#202025"))
    else:
        p = Palette(False, hx("#eeeef1"), hx("#ffffff"), hx("#ffffff"), hx("#0b0b0d"), hx("#5b5b63"), hx("#c9c9cf"),
                    hx("#efeff2"), hx("#e3e3e8"), hx("#0b0b0d"), hx("#ffffff"), mix(hx("#ffffff"), hx("#0b0b0d"), 0.40), mix(hx("#ffffff"), hx("#0b0b0d"), 0.08),
                    hx("#6d5cf0"), hx("#137036"), hx("#c01f25"), hx("#8f5400"), REGULAR, MEDIUM,
                    [hx("#6d5cf0"), hx("#0a7fe0"), hx("#0f9483"), hx("#e0661a"), hx("#d42a2f"), hx("#a88400")], hx("#eeeef1"), hx("#0b0b0d"), hx("#efeff2"))
    return p^


def surface_2(p: Palette) -> UInt32:
    """--oq-surface-2: islands, the chosen segment, a tonal button (the palette's raised)."""
    return p.raised


def shadow_1(dark: Bool) -> List[Shadow]:
    """--oq-shadow-1: the one soft shadow every card and pill wears."""
    if dark:
        return [Shadow(1, 0, 0, rgba(255, 255, 255, alpha(0.035)), True), Shadow(1, 2, 0, rgba(0, 0, 0, alpha(0.5)), False)]
    return [Shadow(1, 2, 0, rgba(20, 16, 10, alpha(0.06)), False), Shadow(0, 0, 1, rgba(20, 16, 10, alpha(0.045)), False)]


def shadow_2(dark: Bool) -> List[Shadow]:
    """--oq-shadow-2: the same scale one step up (a filled button under the pointer, an open menu)."""
    if dark:
        return [Shadow(1, 0, 0, rgba(255, 255, 255, alpha(0.04)), True), Shadow(6, 18, 0, rgba(0, 0, 0, alpha(0.45)), False)]
    return [Shadow(6, 18, 0, rgba(20, 16, 10, alpha(0.10)), False), Shadow(0, 0, 1, rgba(20, 16, 10, alpha(0.05)), False)]


def shadow_3(dark: Bool) -> List[Shadow]:
    """--oq-shadow-3: what floats (menus, popovers, dialogs, toasts)."""
    if dark:
        return [Shadow(1, 0, 0, rgba(255, 255, 255, alpha(0.05)), True), Shadow(18, 48, 0, rgba(0, 0, 0, alpha(0.6)), False)]
    return [Shadow(18, 48, 0, rgba(20, 16, 10, alpha(0.18)), False), Shadow(0, 0, 1, rgba(20, 16, 10, alpha(0.06)), False)]


def shadow_css(shadows: List[Shadow]) -> String:
    """A shadow list as CSS (the same writing mojoui.look uses: GTK and the web read it alike)."""
    var out = String("")
    for sh in shadows:
        out += (", " if out != "" else "") + ("inset " if sh.inset else "") + "0 " + px(sh.y) + " " + px(sh.blur) + (" " + px(sh.spread) if sh.spread != 0 else "") + " " + css_color(sh.color)
    return out if out != "" else String("none")


def card(var s: Surface, fill: UInt32, dark: Bool) -> Surface:
    """A solid() surface as an omxqua card: opaque `fill`, card corners, shadow-1 (.card)."""
    s.fill = fill
    s.radius_top, s.radius_bottom = RADIUS_CARD, RADIUS_CARD
    s.shadows = shadow_1(dark)
    return s^


def card_box(p: Palette) -> Surface:
    """A Card()'s own box (no role: every Card, the console's blades): the framework's writer turns it into a rule."""
    var name = String("card")
    return card(solid(name, RADIUS_CARD, -1, -1, -1), p.card, p.dark)


def box(role: String, fill: UInt32, radius: Int, pad_v: Int, pad_h: Int) -> Surface:
    """A plain box for a role: a fill (0: none), corners (-1: the component's), padding (-1: the component's)."""
    return Surface(role, fill, radius, radius, -1, -1, -1, pad_v, pad_h, pad_v, [], 0, 0, 0, -1, "", 0, 0, 0, 0, 0, 0, 0, False)


def tint(c: UInt32, a: Float64) -> UInt32:
    """`c` at alpha `a` (color-mix(in srgb, c a%, transparent))."""
    return (c & 0xFFFFFF) | (UInt32(alpha(a)) << 24)


comptime CODE = 0xFF0D0B0B  # --code: #0b0b0d in every mode (blades.css: the dark pane stays dark, like a terminal)
comptime CODE_TEXT = 0xFFE7E4E4  # --code-text: #e4e4e7


def console_surfaces(p: Palette) -> List[Surface]:
    """The console's pieces (goal 33 M4), from the original's CSS: omxqua's .tbl, .tag chips with a hue, .badge and
    .acc, the .count pill, .ox-code with its copy button, the Logs pane, the breadcrumb trail, an armed Confirm, .skel."""
    var dark = p.dark
    var out = List[Surface]()
    # .tbl th: 500 11px mono, ink-2, uppercase (the component writes capitals), .06em, 8px 16px, a line under
    var head = box("table-head", 0, -1, 8, 16)
    head.line_bottom, head.font, head.font_size, head.font_weight, head.ink, head.tracking = p.line_strong, FONT_MONO, 11, 500, p.ink2, 0.66
    head.line_height = -1
    out.append(head^)
    # .tbl td: 10px 16px, a line-2 rule under each row, .92em of the body
    var cell = box("table-cell", 0, -1, 10, 16)
    cell.line_bottom, cell.font_size = p.line, 12.88
    var picked = cell.copy()  # (.cx-tbl tr.sel td: the accent at 7 %)
    picked.role, picked.fill = "table-selected", mix(p.card, p.accent, 0.07)
    out.append(cell^)
    out.append(picked^)
    var dense_head = box("table-dense-head", 0, -1, 8, 10)  # (a dense table, the console's model list: .b-home .tbl th 8px 10px, td 12px 10px)
    dense_head.line_bottom = p.line_strong
    out.append(dense_head^)
    var dense_cell = box("table-dense-cell", 0, -1, 12, 10)
    dense_cell.line_bottom = p.line
    out.append(dense_cell^)
    var cut = box("table-cut", 0, -1, -1, -1)  # (.b-home .tbl td: max-width 260; .cx-tbl td.nm 220)
    cut.width = 260
    out.append(cut.copy())
    cut.role, cut.width = "table-cut-name", 220
    out.append(cut.copy())
    cut.role, cut.width = "table-cut-compact", 260  # (≤ 760: the name 190)
    out.append(cut.copy())
    cut.role, cut.width = "table-cut-name-compact", 140  # (library.css ≤ 760: .b-home .cx-tbl td.nm 140)
    out.append(cut.copy())
    cut.role, cut.width = "table-tick", 30  # (.cx-tbl .ck: 30, 46 on a phone; its box wins when wider)
    out.append(cut.copy())
    cut.role, cut.width = "table-tick-compact", 46
    out.append(cut^)
    var snug = box("table-dense-snug", 0, -1, 8, 10)  # (.b-home .tbl td.nm: 8px 10px)
    snug.line_bottom = p.line
    out.append(snug^)
    var ch = box("table-dense-compact-head", 0, -1, 8, 6)  # (≤ 760 .b-home .tbl th, td: 6px at the sides)
    ch.line_bottom = p.line_strong
    out.append(ch^)
    var cc = box("table-dense-compact-cell", 0, -1, 12, 6)
    cc.line_bottom = p.line
    out.append(cc^)
    var cs = box("table-dense-compact-snug", 0, -1, 8, 6)
    cs.line_bottom = p.line
    out.append(cs^)
    var num = words("table-num", 0, 0, 0)  # (.tbl .num: figures in the mono)
    num.font = FONT_MONO
    out.append(num^)
    # .tag: a quiet pill (500 11.5px, 3px 9px, the state layer at .06, ink-2); .tag.k: its hue on a 13 % tint of it
    var quiet = chip("chip", state(dark, 0.06), 0, 11.5, p.ink2, RADIUS_FULL, 3, 9)
    quiet.font_weight, quiet.line_height = 500, -1
    out.append(quiet^)
    var hues: List[String] = ["chip-1", "chip-2", "chip-3", "chip-4", "chip-5", "chip-6", "chip-8"]
    var chip_inks: List[UInt32] = [p.data(0), p.data(1), p.data(2), p.data(3), p.data(4), p.data(5), p.warn]
    for k in range(7):
        var c = chip(hues[k], tint(chip_inks[k], 0.13), 0, 11.5, chip_inks[k], RADIUS_FULL, 3, 9)
        c.font_weight, c.line_height = 500, -1
        out.append(c^)
    # .badge / .acc: 500 11px/1 mono, 4px 6px inside a 1px line (drawn inside: 5px 7px), radius-xs, surface-1, a tone
    var tones: List[String] = ["badge", "badge-ok", "badge-warn", "badge-bad"]
    var inks: List[UInt32] = [p.ink2, p.good, p.warn, p.bad]
    var dots: List[String] = ["dot", "dot-ok", "dot-warn", "dot-bad"]
    for k in range(4):
        var b = chip(tones[k], p.card, p.line_strong, 11, inks[k], RADIUS_XS, 5, 7)
        b.font, b.font_weight, b.line_height, b.one_line = FONT_MONO, 500, 11, True  # (.badge: nowrap)
        out.append(b^)
        out.append(box(dots[k], inks[k], 3, -1, -1))  # (.badge i: a 6px dot in the badge's colour)
    # .bh .count: 500 11px mono, ink-2, the state layer at .05, a pill, 2px 8px
    var pill = chip("pill", state(dark, 0.05), 0, 11, p.ink2, RADIUS_FULL, 2, 8)
    pill.font, pill.font_weight, pill.line_height, pill.tracking = FONT_MONO, 500, -1, -0.34  # (it sits in .bh .t: the title's -.02em of 17px)
    out.append(pill^)
    # .ox-code: --code, 12 corners, 14px 16px, 12px/1.65 mono in --code-text; its button white at .1, a small pill
    var code = box("code-block", CODE, 12, 14, 16)
    code.font, code.font_size, code.line_height, code.ink = FONT_MONO, 12, 19.8, CODE_TEXT
    out.append(code^)
    var copy = box("code-copy", rgba(255, 255, 255, alpha(0.1)), RADIUS_FULL, 0, 12)
    copy.font_size, copy.font_weight, copy.ink = 12.32, 550, CODE_TEXT
    out.append(copy^)
    # .lg-pane: --code, 11.5px/1.6 mono in --code-text, 10px 16px, the card's corners on top
    var log = box("log", CODE, -1, 10, 16)
    log.radius_top, log.radius_bottom = RADIUS_CARD, 0
    log.font, log.font_size, log.line_height, log.ink = FONT_MONO, 11.5, 18.4, CODE_TEXT
    out.append(log^)
    # .crumbs a: 550 13.5px ink-2, 4px 6px, 6 corners; .here: 600 13.5px ink (.mono: 13px Geist Mono)
    var crumb = box("crumb", 0, 6, 4, 6)
    crumb.font_size, crumb.font_weight, crumb.ink, crumb.line_height = 13.5, 550, p.ink2, -1
    out.append(crumb^)
    var here = box("crumb-here", 0, -1, 4, 6)
    here.font_size, here.font_weight, here.ink, here.line_height = 13.5, 600, p.ink, -1
    var here_mono = here.copy()
    here_mono.role, here_mono.font, here_mono.font_size = "crumb-here-mono", FONT_MONO, 13
    var here_c = here.copy()  # (≤ 760: the here alone, 15px)
    here_c.role, here_c.font_size = "crumb-here-compact", 15
    var here_cm = here_mono.copy()
    here_cm.role, here_cm.font_size = "crumb-here-compact-mono", 13  # (.crumbs .here.mono wins over the phone's 15)
    out.append(here^)
    out.append(here_mono^)
    out.append(here_c^)
    out.append(here_cm^)
    # .btn.danger.armed: the bad colour at 14 % behind it, 650, its ring kept
    var armed = chip("confirm-armed", mix(p.card, p.bad, 0.14), mix(p.card, p.bad, 0.40), 0, p.bad, RADIUS_FULL, -1, -1)
    armed.font_weight = 650
    out.append(armed^)
    # .skel: 12 high (the component's), 6 corners, line-2 (its shimmer is the sheets' own: keyframes)
    out.append(box("skeleton", p.line, 6, -1, -1))
    return out^


def omxqua_look(p: Palette) -> Look:
    """omxqua's shapes as values: Geist on the console's scale, 34 pt pill controls, 10 pt fields, 12 pt cards with
    shadow-1, mono labels, the seg2 segmented control and the press spring."""
    var dark = p.dark
    var status = band("status-bar", p.page, p.line, 0)  # (.src: a mono source line over a line-2 rule)
    status.font, status.font_size, status.ink = FONT_MONO, 11.5, p.ink2
    var bar = band("menubar", p.page, 0, 0)  # (.bar: the top bar sits on the canvas, 60 high, 14 in from the sides)
    bar.min_height, bar.pad_top, bar.pad_x, bar.pad_bottom = 60, 0, 14, 0
    var section = words("section-title", 11, 500, p.ink2, 0.66)  # (.tbl th, .menu .lab: 500 11px mono, .06em)
    section.font = FONT_MONO
    var value = words("kpi-value", 25.9, 600, p.ink, -0.91)  # (.stats b: 1.85em of 14, 600, -.035em, line-height 1.15)
    value.line_height = 29.8
    var fact = words("kpi-fact", 11.5, 0, p.ink2)  # (.stats span: 11.5px mono)
    fact.font = FONT_MONO
    var note = chip("kpi-note", p.card, p.line_strong, 11, p.ink2, RADIUS_XS, 4, 6)  # (.badge: 500 11px mono, 4px 6px, radius-xs, a line)
    note.font, note.font_weight = FONT_MONO, 500
    var surfaces: List[Surface] = [card(solid("tile", RADIUS_CARD, -1, -1, -1), p.card, dark), card(solid("table", RADIUS_CARD, -1, -1, -1), p.card, dark),
                                   card(solid("stat-card", RADIUS_CARD, -1, -1, -1), p.card, dark), card(solid("inspector", RADIUS_CARD, -1, -1, -1), p.card, dark),
                                   card(solid("toolbar", RADIUS_CARD, -1, -1, -1), surface_2(p), dark), status^, bar^, section^, value^, fact^,
                                   note^, slot("add-tile", p.line_strong, RADIUS_CARD, 120, p.ink2)]
    surfaces += kit_roles(p, FONT_MONO, shadow_1(dark), hx("#3ccf6e"))  # (mojoui's page components in the console's measures:
    # themes/omxqua_kit.mojo; first, so a leaf role inside a container has the last word; --oq-beacon-accent)
    surfaces += console_surfaces(p)
    surfaces += markdown_roles(p, FONT_MONO)  # (a notebook's markdown: blade-notebook.css's .nb-md)
    surfaces += timeline_roles(p, FONT_MONO)  # (Add a model's stages: blade-add.css's .stg)
    surfaces += logpane_roles(p, FONT_MONO, CODE, CODE_TEXT, RADIUS_CARD)  # (Add a model's live log: blade-add.css .sr)
    return Look(TypeScale(FONT, FONT_MONO, TEXT, 12.5, 14.28, TITLE, 11, False, LINE),
                Controls(0, 0, 0, 11, 0, 0, 0, 12, TARGET, RADIUS_FULL, 16, RADIUS_FULL, RADIUS_IN, TARGET, 16, 12, TEXT * 0.95, 550, -1, -1), surfaces^,  # (a Divider: no room on any host, as omxqua's web hr { margin: 0 }, D-490)
                Segments(p.page, RADIUS_FULL, 3, p.line_strong, TARGET - 8, 14, RADIUS_FULL, 12.6, 500, p.ink2, surface_2(p), p.ink, 500, True),  # (.seg2)
                Motion(PRESS_SCALE, SPRING_FAST_MS, String(SPRING_FAST), String(EASE_IN)), [2, 4, 8, 12, 16, 20, 24])  # (the spacing scale: SPACE_XXS … SPACE_XXL, --oq-space on the console's compact steps)


def fonts_web() -> String:
    """The app's own Geist and Geist Mono (SIL OFL, mojoui/hosts/static/fonts, D-155), one variable file each."""
    return ("@font-face { font-family: \"Geist\"; font-weight: 100 900; font-display: block; src: url(/static/fonts/Geist-Variable.ttf) format(\"truetype\"); }\n"
            + "@font-face { font-family: \"Geist Mono\"; font-weight: 100 900; font-display: block; src: url(/static/fonts/GeistMono-Variable.ttf) format(\"truetype\"); }\n")


def omxqua_web(p: Palette, look: Look, cls: String) -> String:
    """The web's rules beyond the Look's own (on top of the skins' base): the body's type, the controls (.btn, .input,
    .switch, .check, .seg2, .prog, .card), every value from the look and the palette."""
    var b = "body." + cls + " "
    var dark = p.dark
    var s0 = hex_of(p.page)
    var s1 = hex_of(p.card)
    var s2 = hex_of(surface_2(p))
    var ink = hex_of(p.ink)
    var ink2 = hex_of(p.ink2)
    var line = hex_of(p.line_strong)
    var line2 = hex_of(p.line)
    var accent = hex_of(p.accent)
    var on = hex_of(p.accent_ink)
    var sh1 = shadow_css(shadow_1(dark))
    var sh2 = shadow_css(shadow_2(dark))
    var sh3 = shadow_css(shadow_3(dark))
    var hover = css_color(state(dark, 0.08))
    var ring = hex_of(mix(p.card, p.accent, 0.22))
    var t = look.type.copy()
    var c = look.controls.copy()
    var g = look.segments.copy()
    var cardbox = card_box(p)
    return (
        fonts_web()
        + "body." + cls + " { background: " + s0 + "; color: " + ink + "; font: " + fpx(t.body) + "/1.45 \"" + t.family + "\", system-ui, sans-serif; -webkit-font-smoothing: antialiased; }\n"
        + b + ".num, " + b + ".mono, " + b + "[data-tag=formula-bar] input[type=text], " + b + ".mi .mi-key { font-family: \"" + t.mono + "\", ui-monospace, monospace; }\n"
        + b + ".text { color: " + ink + "; }\n"
        + b + ".text.title { font-size: " + fpx(t.title) + "; line-height: 1.1; font-weight: 650; letter-spacing: -0.035em; color: " + ink + "; }\n"
        + b + ".text.headline { font-size: " + fpx(t.headline) + "; line-height: 1.3; font-weight: 600; letter-spacing: -0.01em; color: " + ink + "; }\n"
        + b + ".text.caption { font-size: " + fpx(t.caption) + "; line-height: 1.4; color: " + ink2 + "; }\n"
        + b + ".text.tone-accent { color: " + accent + "; } " + b + ".text.tone-good { color: " + hex_of(p.good) + "; } " + b + ".text.tone-warn { color: " + hex_of(p.warn) + "; }\n"
        + b + ".text.tone-strong { color: " + ink + "; font-weight: 600; }\n"
        # cards: surface-1, card corners, shadow-1 (the framework's writer, from the same Surface the look's roles use)
        + b + ".vstack.card { " + surface_rule(cardbox, True) + "}\n"
        + b + ".vstack.card.warn { background: " + hex_of(mix(p.card, p.warn, 0.08)) + "; } " + b + ".vstack.card.good { background: " + hex_of(mix(p.card, p.good, 0.08)) + "; }\n"
        # buttons (.btn): pills a target high; tonal by default, the accent filled for the loud one, text for the quiet one
        + b + "button { height: " + px(c.control_h) + "; padding: 0 " + px(c.button_pad) + "; font-weight: 400; font-size: 1em; border: 0; color: " + ink + "; background: " + css_color(state(dark, 0.06)) + "; box-shadow: none; }\n"
        + b + "button:hover { filter: none; background-image: linear-gradient(" + hover + ", " + hover + "); }\n"
        + b + "button.with-icon { gap: 8px; } " + b + ".icon svg, " + b + "button svg { stroke-width: 1.6px; }\n"  # (.btn's 8 between icon and word; icons.js draws 1.6 wide)
        + b + "hr { margin: 0; }\n"
        + b + "button:focus-visible, " + b + "input:focus-visible { outline: 2px solid " + accent + "; outline-offset: 2px; }\n"
        + b + "button.prominent { background: " + accent + "; color: " + on + "; box-shadow: none; font-weight: 400; }\n"
        + b + "button.prominent:hover { background: " + accent + "; background-image: none; }\n"
        + b + "button.subtle { background: transparent; box-shadow: none; color: " + ink2 + "; }\n"
        + b + "button.destructive { background: transparent; color: " + hex_of(p.bad) + "; box-shadow: inset 0 0 0 1px " + hex_of(mix(p.card, p.bad, 0.40)) + "; }\n"
        + b + "button.icon-only { width: " + px(c.icon) + "; min-width: " + px(c.icon) + "; padding: 0; justify-content: center; border-radius: " + px(c.icon_radius) + "; }\n"
        + b + "button[disabled] { opacity: 0.45; pointer-events: none; }\n"
        # fields (.input): a line, field corners, the accent and a soft ring on focus
        + b + "input[type=text], " + b + "input[type=date], " + b + "select, " + b + "textarea { border: 1px solid " + line + "; background: " + s1 + "; color: " + ink
        + "; padding: 0 " + px(c.field_pad) + "; font: inherit; transition: box-shadow 150ms, border-color 150ms; }\n"
        + b + "input[type=text], " + b + "input[type=date], " + b + "select { height: " + px(c.control_h) + "; }\n"
        + b + "input[type=text]:focus, " + b + "textarea:focus, " + b + "select:focus { outline: none; border-color: " + accent + "; box-shadow: 0 0 0 3px " + ring + "; }\n"
        + b + "input::placeholder { color: " + ink2 + "; }\n"
        # toggles (.switch, .check): a 40 × 24 track with a white knob; an 18 pt box with 5 pt corners
        + b + "label.toggle { gap: 10px; font-size: 0.92em; }\n"
        + b + "label.toggle:not(.check) input { appearance: none; -webkit-appearance: none; width: 40px; height: 24px; margin: 0; border-radius: 999px; background: " + line
        + "; position: relative; flex: none; transition: background 200ms; cursor: pointer; }\n"
        + b + "label.toggle:not(.check) input::after { content: \"\"; position: absolute; left: 3px; top: 3px; width: 18px; height: 18px; border-radius: 9px; background: #ffffff;"
        + " box-shadow: 0 1px 2px rgba(0,0,0,0.3); transition: transform " + String(look.motion.press_ms) + "ms " + look.motion.spring + "; }\n"
        + b + "label.toggle:not(.check) input:checked { background: " + accent + "; }\n"
        + b + "label.toggle:not(.check) input:checked::after { transform: translateX(16px); background: " + on + "; }\n"
        + b + "label.toggle.check input { appearance: none; -webkit-appearance: none; width: 18px; height: 18px; margin: 0; border-radius: 5px; box-shadow: inset 0 0 0 1.5px " + ink2
        + "; display: inline-grid; place-items: center; flex: none; cursor: pointer; }\n"
        + b + "label.toggle.check input:checked { background: " + accent + "; box-shadow: none; }\n"
        + b + "label.toggle.check input:checked::after { content: \"\"; width: 9px; height: 5px; border-left: 2px solid " + on + "; border-bottom: 2px solid " + on + "; transform: rotate(-45deg) translate(1px, -1px); }\n"
        + b + ".radio input { accent-color: " + accent + "; }\n"
        # a table's tick boxes (library.css .cb): 22 pt, 7 corners, a 1.5 pt line; ticked, the accent
        + b + "table.table label.toggle.check input { width: 22px; height: 22px; border-radius: 7px; box-shadow: none; border: 1.5px solid " + line + "; }\n"
        + b + "[data-tag=beacon] { position: relative; z-index: 5; }\n"
        + b + "[data-tag=link] { text-decoration: underline; text-underline-offset: 2px; } " + "\n"  # (the Beacon's shadow over the page below it: .bar's z-index)
        + b + "table.table label.toggle.check input:checked { background: " + accent + "; box-shadow: none; }\n"
        + b + "table.table.compact label.toggle.check input { width: 26px; height: 26px; }\n"  # (≤ 760 .cb: 26)
        # the segmented control (.seg2): a surface-0 track ringed by a line, the chosen one surface-2 with shadow-1
        + b + ".segmented, " + b + ".tabs { background: " + hex_of(g.track) + "; box-shadow: inset 0 0 0 1px " + hex_of(g.ring) + "; border: 0; border-radius: " + px(g.track_radius)
        + "; padding: " + px(g.track_pad) + "; gap: 0; overflow: visible; }\n"
        + b + ".segmented span, " + b + ".tabs span { min-height: " + px(g.h) + "; padding: 0 " + px(g.pad) + "; border-radius: " + px(g.radius) + "; font-size: " + fpx(g.font_size)
        + "; font-weight: " + String(g.weight) + "; color: " + hex_of(g.ink) + "; transition: color 200ms; }\n"
        + b + ".segmented input:checked + span, " + b + ".tabs input:checked + span { background: " + hex_of(g.on_fill) + "; color: " + hex_of(g.on_ink) + "; font-weight: " + String(g.on_weight)
        + "; box-shadow: " + (sh1 if g.on_shadow else String("none")) + "; }\n"
        # progress (.prog): 8 high, a line track, the accent
        + b + "progress { appearance: none; -webkit-appearance: none; height: 8px; border: 0; border-radius: 4px; background: " + line + "; overflow: hidden; }\n"
        + b + "progress::-webkit-progress-bar { background: " + line + "; border-radius: 4px; } " + b + "progress::-webkit-progress-value { background: " + accent + "; border-radius: 4px; }\n"
        + b + "hr { border-top-color: " + line2 + "; } " + b + ".hstack > hr { border-left-color: " + line2 + "; }\n"
        # what floats: surface-2 (menus) or -3 (dialogs, toasts), shadow-3, menu corners, 8 pt rows
        + b + ".menu > .menu-items, " + b + ".popover { background: " + s2 + "; color: " + ink + "; border-radius: 14px; padding: 6px; box-shadow: " + sh3 + "; }\n"
        + b + ".mi { border-radius: 8px; font-size: 0.93em; color: " + ink + "; } " + b + ".mi:hover:not([disabled]) { background: " + hover + "; }\n"
        + b + ".dialog { background: " + s2 + "; color: " + ink + "; border-radius: " + px(RADIUS_CARD + 4) + "; box-shadow: " + sh3 + "; }\n"
        + b + ".dialog-layer .scrim { background: rgba(0,0,0,0.42); }\n"
        + b + ".toast { background: " + s2 + "; color: " + ink + "; border-radius: 12px; box-shadow: " + sh3 + "; } " + b + ".toast .toast-close { color: " + ink2 + "; }\n"
        + b + ".menubar { background: " + s0 + "; } " + b + ".menu-title { color: " + ink2 + "; border-radius: 10px; }\n"
        + b + ".menu.open > .menu-title, " + b + ".menu-title:hover { background: " + hover + "; color: " + ink + "; }\n"
        + "@media (prefers-reduced-motion: reduce) { " + b + "*, " + b + "*::before, " + b + "*::after { transition-duration: 150ms !important; animation-duration: 150ms !important; } "
        + b + "button:active { transform: none; } }\n"        # the skeleton's shimmer (.skel: line-2 → line → line-2 sliding across in 1.6 s); still when motion is off
        # mojoui.fields.SearchField: the field inside the tonal box loses its own chrome (library.css .psearch input)
        + b + "[data-tag=search-box] input[type=text] { border: 0; background: transparent; box-shadow: none; height: 46px; padding: 1px 2px; font-size: 15px; font-weight: 500; }\n"
        + b + "[data-tag=search-box] input[type=text]:focus { box-shadow: none; } " + b + "[data-tag=search-box] input::placeholder { color: " + hex_of(p.ink3) + "; }\n"
        + b + "[data-tag=search-box] .field { flex: 1; }\n"
        + b + "[data-tag=outlined-field] input[type=text] { border: 0; background: transparent; box-shadow: none; height: 44px; min-height: 0; padding: 0; font-size: " + fpx(t.body) + "; }\n"
        + b + "[data-tag=outlined-field] input[type=text]:focus { box-shadow: none; } " + b + "[data-tag=outlined-field]:focus-within { box-shadow: inset 0 0 0 2px " + accent + "; }\n"
        + b + ".text[data-tag=page-title], " + b + ".text[data-tag=page-sub], " + b + ".text[data-tag=result-meta], " + b + "[data-tag=result-name], "
        + b + ".text[data-tag=crumb-here], " + b + ".text[data-tag=crumb-here-mono], " + b + ".text[data-tag=crumb-here-compact], " + b + ".text[data-tag=crumb-here-compact-mono], "
        + b + ".text[data-tag=sub-header-text] "
        + "{ white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; max-width: 100%; }\n"  # (one line, cut with an ellipsis: .bh .t, .bh .s, .res .nm, .res .mt)
        + "body." + cls + " > #mojoui-root { min-width: 0; }\n"
        + b + "[data-tag=card-foot] { flex-wrap: nowrap; }\n"  # (.src: one row; its words wrap inside their own column)  # (the page is a grid item: a one-line text's full width mustn't widen it past the window)
        + b + "[data-tag=outlined-field] .field { flex: 1; } " + b + "[data-tag=outlined-field] input::placeholder { color: " + ink2 + "; }\n"
        + "@keyframes oq-skel { from { background-position: 100% 0; } to { background-position: -100% 0; } }\n"
        + b + "[data-tag=skeleton] { background-image: linear-gradient(90deg, " + line2 + ", " + line + ", " + line2 + "); background-size: 200% 100%; animation: oq-skel 1.6s linear infinite; }\n"
        + "@media (prefers-reduced-motion: reduce) { " + b + "[data-tag=skeleton] { animation: none; } }\n"
    )


def omxqua_gtk(p: Palette, look: Look, cls: String) -> String:
    """GTK's rules beyond the Look's own (on top of the skins' base): the same values on libadwaita's widgets."""
    var w = "window." + cls + " "
    var dark = p.dark
    var s0 = hex_of(p.page)
    var s1 = hex_of(p.card)
    var s2 = hex_of(surface_2(p))
    var ink = hex_of(p.ink)
    var ink2 = hex_of(p.ink2)
    var line = hex_of(p.line_strong)
    var line2 = hex_of(p.line)
    var accent = hex_of(p.accent)
    var on = hex_of(p.accent_ink)
    var sh1 = shadow_css(shadow_1(dark))
    var sh2 = shadow_css(shadow_2(dark))
    var sh3 = shadow_css(shadow_3(dark))
    var hover = css_color(state(dark, 0.08))
    var t = look.type.copy()
    var c = look.controls.copy()
    var g = look.segments.copy()
    return (
        ":root { --accent-bg-color: " + accent + "; --accent-color: " + accent + "; --accent-fg-color: " + on + "; }\n"
        + w + "{ background-color: " + s0 + "; color: " + ink + "; font-family: '" + t.family + "', sans-serif; font-size: " + fpx(t.body) + "; }\n"
        + w + "label { color: " + ink + "; }\n"
        + w + "label.title-1 { font-size: " + fpx(t.title) + "; line-height: " + line_px(t.title * 1.1) + "; font-weight: 650; letter-spacing: -0.98px; color: " + ink + "; }\n"
        + w + "label.title-4 { font-size: " + fpx(t.headline) + "; line-height: " + line_px(t.headline * 1.3) + "; font-weight: 600; letter-spacing: -0.14px; color: " + ink + "; }\n"
        + w + "label.caption { font-size: " + fpx(t.caption) + "; line-height: " + line_px(t.caption * 1.4) + "; color: " + ink2 + "; }\n"
        + w + "label.mui-tone-accent { color: " + accent + "; } " + w + "label.mui-tone-good { color: " + hex_of(p.good) + "; } " + w + "label.mui-tone-warn { color: " + hex_of(p.warn) + "; }\n"
        + w + ".mui-card { " + surface_rule(card_box(p), False) + "}\n"
        + w + ".mui-card.mui-warn { background: " + hex_of(mix(p.card, p.warn, 0.08)) + "; } " + w + ".mui-card.mui-good { background: " + hex_of(mix(p.card, p.good, 0.08)) + "; }\n"
        + w + ".mui-board { background-color: " + s0 + "; }\n"
        + w + ".mui-tag-formula-bar entry { font-family: '" + t.mono + "', monospace; }\n"
        + w + "button { min-height: " + px(c.control_h) + "; padding: 0 " + px(c.button_pad) + "; font-weight: 550; border-radius: " + px(c.button_radius) + "; background: " + s2 + "; color: " + ink + "; box-shadow: " + sh1 + "; }\n"
        + w + "button:hover { background-image: linear-gradient(" + hover + ", " + hover + "); background-color: " + s2 + "; }\n"
        + w + "button.suggested-action { background: " + accent + "; color: " + on + "; box-shadow: " + sh1 + "; font-weight: 550; }\n"
        + w + "button.suggested-action:hover { background-image: none; background-color: " + accent + "; box-shadow: " + sh2 + "; }\n"
        + w + "button.suggested-action label { color: " + on + "; }\n"
        + w + "button.flat { background: transparent; box-shadow: none; color: " + ink2 + "; } " + w + "button.flat label { color: " + ink2 + "; }\n"
        + w + "button.destructive-action { background: transparent; color: " + hex_of(p.bad) + "; box-shadow: inset 0 0 0 1px " + hex_of(mix(p.card, p.bad, 0.40)) + "; }\n"
        + w + "button.image-button { min-width: " + px(c.icon) + "; padding: 0; border-radius: " + px(c.icon_radius) + "; }\n"
        + w + "entry, " + w + "textview, " + w + "dropdown > button { min-height: " + px(c.control_h) + "; border-radius: " + px(c.field_radius) + "; background: " + s1 + "; color: " + ink
        + "; box-shadow: inset 0 0 0 1px " + line + "; padding: 0 " + px(c.field_pad) + "; font-weight: 400; background-image: none; }\n"
        + w + "entry:focus-within { box-shadow: inset 0 0 0 1px " + accent + ", 0 0 0 3px " + hex_of(mix(p.card, p.accent, 0.22)) + "; outline: none; }\n"
        + w + "switch { min-width: 40px; min-height: 24px; border-radius: 999px; background: " + line + "; padding: 0; border: 0; }\n"
        + w + "switch:checked { background: " + accent + "; } " + w + "switch slider { min-width: 18px; min-height: 18px; margin: 3px; border-radius: 9px; background: #ffffff; box-shadow: 0 1px 2px rgba(0,0,0,0.3); }\n"
        + w + "switch:checked slider { background: " + on + "; }\n"
        + w + "checkbutton check { min-width: 18px; min-height: 18px; padding: 0; border-radius: 5px; border: 0; background: transparent; box-shadow: inset 0 0 0 1.5px " + ink2 + "; }\n"
        + w + "checkbutton check:checked { background: " + accent + "; box-shadow: none; color: " + on + "; }\n"
        # a table's tick boxes, as the web's (library.css .cb): 22 pt, 7 corners, a 1.5 pt line, the box alone (no padding:
        # Adwaita's checkbutton and check have 3 px each; the web's input is its 18 or 22 px alone)
        + w + "grid.mui-table checkbutton { padding: 0; min-height: 0; } " + w + "grid.mui-table checkbutton check { min-width: 22px; min-height: 22px; margin: 0; border-radius: 7px; box-shadow: inset 0 0 0 1.5px " + line + "; }\n"
        + w + "grid.mui-table checkbutton check:checked { box-shadow: none; } " + w + "grid.mui-table-compact checkbutton check { min-width: 26px; min-height: 26px; }\n"
        + w + "toggle-group { background: " + hex_of(g.track) + "; box-shadow: inset 0 0 0 1px " + hex_of(g.ring) + "; border-radius: " + px(g.track_radius) + "; padding: " + px(g.track_pad) + "; }\n"
        + w + "toggle-group > toggle { min-height: " + px(g.h) + "; padding: 0 " + px(g.pad) + "; border-radius: " + px(g.radius) + "; font-size: " + fpx(g.font_size) + "; font-weight: " + String(g.weight)
        + "; color: " + hex_of(g.ink) + "; background: transparent; box-shadow: none; }\n"
        + w + "toggle-group > toggle:checked { background: " + hex_of(g.on_fill) + "; color: " + hex_of(g.on_ink) + "; font-weight: " + String(g.on_weight) + "; box-shadow: " + sh1 + "; }\n"
        + w + "progressbar trough { min-height: 8px; border-radius: 4px; background: " + line + "; } " + w + "progressbar progress { min-height: 8px; border-radius: 4px; background: " + accent + "; }\n"
        + w + "separator { background: " + line2 + "; }\n"
        + w + "popover > contents, " + w + "popover.menu > contents { background: " + s2 + "; color: " + ink + "; border-radius: 14px; box-shadow: " + sh3 + "; }\n"
        + "popover.mui-menu-popover button.mui-menu-item { border-radius: 8px; } popover.mui-menu-popover button.mui-menu-item:hover { background: " + hover + "; }\n"
        + w + ".mui-tag-search-box entry { background: transparent; box-shadow: none; min-height: 46px; padding: 0; font-size: 15px; }\n"
        + w + ".mui-tag-outlined-field entry { background: transparent; box-shadow: none; min-height: 44px; padding: 0; }\n"
        + "toast { background: " + s2 + "; color: " + ink + "; border-radius: 12px; font-family: '" + t.family + "', sans-serif; }\n"
        + "toast label, toast button { color: " + ink + "; }\n"        + "@keyframes mui-skel { from { background-position: 100% 0; } to { background-position: -100% 0; } }\n"
        + w + ".mui-tag-skeleton { background-image: linear-gradient(90deg, " + line2 + ", " + line + ", " + line2 + "); background-size: 200% 100%; animation: mui-skel 1.6s linear infinite; }\n"
    )


def omxqua(dark: Bool = False) -> Theme:
    """omxqua's Developer family, light or night. The id differs by mode (the web re-sends a style sheet only when its
    id or length changes); both carry the class `omxqua`."""
    var pal = omxqua_palette(dark)
    var look = omxqua_look(pal)
    var id = String("omxqua-dark") if dark else String("omxqua")
    var classes = "skin omxqua" + (" omxqua-dark" if dark else "")
    return Theme(id, classes, pal.copy(), skin_css(pal, id) + omxqua_gtk(pal, look, id), String(SKIN_WEB) + omxqua_web(pal, look, id),
                 pal.ink2, pal.accent_ink, True, look^)
