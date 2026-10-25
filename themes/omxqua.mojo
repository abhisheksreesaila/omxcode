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
from mojoui.look import css_color, surface_rule, px, fpx
from themes.skins import skin_css, SKIN_WEB

# ---- tokens.css, the root (both modes) and the Developer family ----
comptime FONT = "Geist"  # --oq-font
comptime FONT_MONO = "Geist Mono"  # --oq-font-mono
comptime TEXT = 14.0  # the console's body (blades.css: body 14px; --oq-text 13.5 is the family's, the console sets 14)
comptime TITLE = 28.0  # --oq-title
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
    """The Developer family's colours (.oq-family-dev.oq-light / .oq-night). omxqua has two inks: ink-2 is also the quiet
    text; line-2 is the quiet hairline (gridlines, row rules), line the strong one (fields, badges, headers)."""
    var p: Palette
    if dark:
        p = Palette(True, hx("#0b0b0d"), hx("#151518"), hx("#1d1d21"), hx("#ededef"), hx("#a9a9b1"), hx("#a9a9b1"),
                    hx("#202025"), hx("#2a2a30"), hx("#ededef"), hx("#0b0b0d"), mix(hx("#151518"), hx("#ededef"), 0.40), mix(hx("#151518"), hx("#ededef"), 0.08),
                    hx("#8b7bff"), hx("#3ccf6e"), hx("#f2555a"), hx("#f5a524"), REGULAR, MEDIUM,
                    [hx("#8b7bff"), hx("#3aa0ff"), hx("#2bc3ad"), hx("#ff8a3d"), hx("#f2555a"), hx("#e0b400")], hx("#0b0b0d"), hx("#ededef"), hx("#202025"))
    else:
        p = Palette(False, hx("#eeeef1"), hx("#ffffff"), hx("#ffffff"), hx("#0b0b0d"), hx("#5b5b63"), hx("#5b5b63"),
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
    return Look(TypeScale(FONT, FONT_MONO, TEXT, 12.5, 14.28, TITLE, 11, False),
                Controls(0, 0, 0, 11, 0, 0, 0, 12, TARGET, RADIUS_FULL, 16, RADIUS_FULL, RADIUS_IN, TARGET, 16, 12), surfaces^,
                Segments(p.page, RADIUS_FULL, 3, p.line_strong, TARGET - 8, 14, RADIUS_FULL, 12.6, 500, p.ink2, surface_2(p), p.ink, 500, True),  # (.seg2)
                Motion(PRESS_SCALE, SPRING_FAST_MS, String(SPRING_FAST), String(EASE_IN)))


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
        + b + "button { height: " + px(c.control_h) + "; padding: 0 " + px(c.button_pad) + "; font-weight: 550; font-size: 0.95em; border: 0; color: " + ink + "; background: " + s2 + "; box-shadow: " + sh1 + "; }\n"
        + b + "button:hover { filter: none; background: " + s2 + "; background-image: linear-gradient(" + hover + ", " + hover + "); }\n"
        + b + "button:focus-visible, " + b + "input:focus-visible { outline: 2px solid " + accent + "; outline-offset: 2px; }\n"
        + b + "button.prominent { background: " + accent + "; color: " + on + "; box-shadow: " + sh1 + "; font-weight: 550; }\n"
        + b + "button.prominent:hover { background: " + accent + "; background-image: none; box-shadow: " + sh2 + "; }\n"
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
        + b + "button:active { transform: none; } }\n"
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
        + w + "label.title-1 { font-size: " + fpx(t.title) + "; font-weight: 650; letter-spacing: -0.98px; color: " + ink + "; }\n"
        + w + "label.title-4 { font-size: " + fpx(t.headline) + "; font-weight: 600; letter-spacing: -0.14px; color: " + ink + "; }\n"
        + w + "label.caption { font-size: " + fpx(t.caption) + "; color: " + ink2 + "; }\n"
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
        + w + "checkbutton check { min-width: 18px; min-height: 18px; border-radius: 5px; border: 0; background: transparent; box-shadow: inset 0 0 0 1.5px " + ink2 + "; }\n"
        + w + "checkbutton check:checked { background: " + accent + "; box-shadow: none; color: " + on + "; }\n"
        + w + "toggle-group { background: " + hex_of(g.track) + "; box-shadow: inset 0 0 0 1px " + hex_of(g.ring) + "; border-radius: " + px(g.track_radius) + "; padding: " + px(g.track_pad) + "; }\n"
        + w + "toggle-group > toggle { min-height: " + px(g.h) + "; padding: 0 " + px(g.pad) + "; border-radius: " + px(g.radius) + "; font-size: " + fpx(g.font_size) + "; font-weight: " + String(g.weight)
        + "; color: " + hex_of(g.ink) + "; background: transparent; box-shadow: none; }\n"
        + w + "toggle-group > toggle:checked { background: " + hex_of(g.on_fill) + "; color: " + hex_of(g.on_ink) + "; font-weight: " + String(g.on_weight) + "; box-shadow: " + sh1 + "; }\n"
        + w + "progressbar trough { min-height: 8px; border-radius: 4px; background: " + line + "; } " + w + "progressbar progress { min-height: 8px; border-radius: 4px; background: " + accent + "; }\n"
        + w + "separator { background: " + line2 + "; }\n"
        + w + "popover > contents, " + w + "popover.menu > contents { background: " + s2 + "; color: " + ink + "; border-radius: 14px; box-shadow: " + sh3 + "; }\n"
        + "popover.mui-menu-popover button.mui-menu-item { border-radius: 8px; } popover.mui-menu-popover button.mui-menu-item:hover { background: " + hover + "; }\n"
        + "toast { background: " + s2 + "; color: " + ink + "; border-radius: 12px; font-family: '" + t.family + "', sans-serif; }\n"
        + "toast label, toast button { color: " + ink + "; }\n"
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
