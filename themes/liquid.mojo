# Liquid as a mojoui theme (docs/design/liquid.md, D-225): controls on glass islands over a soft backdrop, the
# content solid white, one type scale, calm motion. On top of the skins' rules (themes/skins.mojo).
# Liquid dark (goal 41, D-1240): the same shapes, type and springs over its own deep cool palette (liquid_dark_palette): glass
# a lighter-than-backdrop tone with a faint top highlight and a 1 px hairline rim, cards solid with a hairline, one soft
# shadow; every glass, solid and hover value below comes from the palette (light keeps Liquid's own values).
#
#   def theme(self) -> Theme: return liquid()                     (or liquid(liquid_palette().with_accent(indigo)))
#   def appearance(mut self, dark: Bool): self.look = liquid(dark)   (Liquid dark when the system is)

from mojoui.canvas import rgba
from mojoui.text import REGULAR, MEDIUM
from mojoui.theme import Palette, Theme, hx, mix, hex_of
from mojoui.theme import Look, Surface, Shadow, TypeScale, Controls, Segments, glass, solid, words, chip, slot
from themes.skins import skin_css, SKIN_WEB


comptime WHITE: UInt32 = 0xFFFFFFFF


def alpha(c: UInt32, a: Int) -> UInt32:
    """c with its alpha set to a (0–255)."""
    return (c & 0x00FFFFFF) | (UInt32(a & 255) << 24)


def css_rgba(c: UInt32, a: Float64) -> String:
    """c as a CSS rgba() with alpha a (0–1)."""
    return ("rgba(" + String(Int(c & 255)) + "," + String(Int((c >> 8) & 255)) + "," + String(Int((c >> 16) & 255)) + ","
            + String(a) + ")")


def glass_fill(p: Palette) -> UInt32:
    """The glass's tone: light, translucent white; dark, a step lighter than the backdrop, slightly translucent."""
    return rgba(255, 255, 255, 158) if not p.dark else alpha(mix(p.page, WHITE, 0.07), 235)


def island(p: Palette, role: String, radius_top: Int, radius_bottom: Int, margin_top: Int, margin_x: Int, margin_bottom: Int, pad: Int) -> Surface:
    """A glass island (mojoui.theme.glass); dark: the lighter tone, a faint top highlight, a 1 px hairline rim, one soft shadow."""
    var s = glass(role, radius_top, radius_bottom, margin_top, margin_x, margin_bottom, pad)
    if p.dark:
        s.fill = glass_fill(p)
        s.shadows = [Shadow(1, 0, 0, rgba(255, 255, 255, 15), True), Shadow(8, 24, 0, rgba(0, 0, 0, 89), False)]
        s.outline = p.line
        s.outline_w = 1
    return s^


def card(p: Palette, role: String, radius: Int, pad_top: Int, pad_x: Int, pad_bottom: Int) -> Surface:
    """A solid content card (mojoui.theme.solid); dark: the palette's card with a 1 px hairline and one soft shadow."""
    var s = solid(role, radius, pad_top, pad_x, pad_bottom)
    if p.dark:
        s.fill = p.card
        s.shadows = [Shadow(1, 3, 0, rgba(0, 0, 0, 77), False)]
        s.outline = p.line
        s.outline_w = 1
    return s^


def liquid_look(p: Palette) -> Look:
    """Liquid's shapes as values (every host draws them): glass islands for the chrome (the header, the toolbar, the
    inspector, the bottom strip), solid white cards for the content, Inter on one scale (11 12 13 15 17 22 34)."""
    var tabs = island(p, "sheet-tabs", 14, 0, 0, 10, 0, -1)
    var status = island(p, "status-bar", 0, 14, 0, 10, 10, -1)
    status.shadows = [Shadow(8, 20, 0, rgba(15, 23, 42, 15), False)] if not p.dark else [Shadow(8, 20, 0, rgba(0, 0, 0, 77), False)]
    status.font, status.font_size, status.ink = "Inter", 12, p.ink3
    var header = island(p, "menubar", 12, 12, 8, 10, 0, -1)
    header.min_height = 34
    var bar = Surface("formula-bar", 0, -1, -1, 0, 10, 0, -1, -1, -1, [], 0, 0, 0, -1, "", 0, 0, 0, 0, 0, 0, 0, False)  # (on the backdrop: no panel)
    # an inspector row (a label, its control) as tall as a control, whichever control it holds: the Mac's checkbox (16 pt) and
    # switch rows sat closer than GTK's and the web's (2026-10-25)
    var row = Surface("inspector-row", 0, -1, -1, -1, -1, -1, -1, -1, -1, [], 0, 0, 0, 30, "", 0, 0, 0, 0, 0, 0, 0, False)
    var surfaces: List[Surface] = [header^, row^, island(p, "toolbar", 18 if not p.dark else 12, 18 if not p.dark else 12, 0, 10, 0, 6), island(p, "inspector", 18, 18, -1, -1, -1, 10), tabs^, status^, bar^,
                                   island(p, "sidebar", 12, 12, 0, 0, 0, -1),  # (the side rail, mojoui.sheetchrome.Rail: an island; dark rims it, 12 as the menu bar: an 18 pt corner on a 48 pt rail leaves no straight edge)
                                   card(p, "table", 16, 10, 12, 12), card(p, "tile", 16, 16, 18, 16), words("sentence-line", 15, 600, p.ink),
                                   words("section-title", 0, 600, 0, 0.5), words("stat-value", 15, 600, p.ink), words("kpi-fact", 12, 0, p.ink3),
                                   chip("stat-card", p.raised, p.line_strong, 0, 0, 12, -1, -1), chip("kpi-note", p.raised, p.line, 12, p.ink2, 999, 2, 10),
                                   slot("add-tile", p.line_strong, 16, 120, p.ink3)]
    var value = words("kpi-value", 34, 600, 0, -0.8)  # (a Report tile's figure: GTK's and the web's title-1 in a tile)
    value.line_height = 40
    surfaces.append(value^)
    return Look(TypeScale("Inter", "", 13, 12, 15, 22, 11, True, 0), Controls(62, 52, 12, 11, 34, 10, 10, 12, 34, 10, 16, 999, 10, 30, 14, 8, 0, 0, 0, 0, 32), surfaces^,
                Segments(rgba(15, 23, 42, 15) if not p.dark else rgba(255, 255, 255, 15), 999, 3, 0, 24, 12, 999, 12, 500, p.ink3,
                         rgba(255, 255, 255) if not p.dark else p.raised, p.ink, 500, True))  # (the sheet's toggle-group rules say the same: D-300)


def liquid_palette() -> Palette:
    """Liquid, light (docs/design/liquid.md): a white sheet, glass islands over a soft cool backdrop, teal (the default).
    The chrome is the glass as it looks over the backdrop (GTK can't blur what's behind a widget)."""
    return Palette(False, hx("#e9eef4"), hx("#ffffff"), hx("#f6f8fb"), hx("#0f172a"), hx("#334155"), hx("#64748b"),
                   hx("#edf0f4"), hx("#d9dee6"), hx("#0e7c86"), hx("#ffffff"), mix(hx("#ffffff"), hx("#0e7c86"), 0.40), hx("#e6f2f3"),
                   hx("#6a4fd6"), hx("#16a34a"), hx("#dc2626"), hx("#d97706"), REGULAR, MEDIUM, [hx("#0e7c86"), hx("#f59e0b"), hx("#6366f1"), hx("#ec4899"), hx("#22c55e"), hx("#a16207"), hx("#64748b"), hx("#c026d3")], hx("#f7f9fc"), hx("#334155"), hx("#ffffff"))


comptime DARK_PAGE = "#12151b"  # Liquid dark's backdrop: a deep, cool slate (its gradient runs a shade either side)


def liquid_dark_palette() -> Palette:
    """Liquid, dark (owner, 2026-10-30: "you can design a new liquid dark", D-1240): a deep cool backdrop #12151b, the
    glass islands a step lighter, solid content cards #1b1f27 (raised #252a34), crisp #323946 hairlines, ink #f1f4f9 /
    #c4cad6 / #8f98a8 (≥ 4.5:1 on the cards), Liquid's teal lifted for the dark (#3cc4cf; a mode's tint goes over it
    with dark_tint), its tones (ok #34d399, warn #fbbf24, bad #f87171, info #7aa7ff) and Liquid's data palette, lifted."""
    var card = hx("#1b1f27")
    var accent = hx("#3cc4cf")
    var page = hx(DARK_PAGE)
    return Palette(True, page, card, hx("#252a34"), hx("#f1f4f9"), hx("#c4cad6"), hx("#8f98a8"),
                   hx("#323946"), hx("#424a5a"), accent, hx("#04201f"), mix(card, accent, 0.45), mix(card, accent, 0.16),
                   hx("#7aa7ff"), hx("#34d399"), hx("#f87171"), hx("#fbbf24"), REGULAR, MEDIUM,
                   [hx("#3cc4cf"), hx("#fbbf24"), hx("#818cf8"), hx("#f472b6"), hx("#4ade80"), hx("#d4a85a"), hx("#94a3b8"), hx("#e879f9")],
                   mix(page, WHITE, 0.07), hx("#f1f4f9"), hx("#323946"))  # (the chrome: the glass's tone)


def liquid_palette(dark: Bool) -> Palette:
    """Liquid light or Liquid dark."""
    return liquid_dark_palette() if dark else liquid_palette()


def dark_tint(accent: UInt32) -> UInt32:
    """A light mode's tint made for Liquid dark: the same hue, lifted to a lightness that reads as text on the dark
    cards and under dark ink (HSL lightness ≥ 0.64, saturation ≥ 0.62); a tint already light stays as it is."""
    var r = Float64(Int(accent & 255)) / 255.0
    var g = Float64(Int((accent >> 8) & 255)) / 255.0
    var b = Float64(Int((accent >> 16) & 255)) / 255.0
    var hi = max(r, max(g, b))
    var lo = min(r, min(g, b))
    var l = (hi + lo) / 2.0
    if l >= 0.64:
        return accent
    var h = 0.0
    var sat = 0.0
    var d = hi - lo
    if d > 0:
        sat = d / (1.0 - abs(2.0 * l - 1.0))
        if hi == r:
            h = (g - b) / d
            if h < 0:
                h += 6.0
        elif hi == g:
            h = (b - r) / d + 2.0
        else:
            h = (r - g) / d + 4.0
    l = 0.64
    sat = max(sat, 0.62) if d > 0 else 0.0
    var c = (1.0 - abs(2.0 * l - 1.0)) * sat
    var hm = h - 2.0 * Float64(Int(h / 2.0))
    var x = c * (1.0 - abs(hm - 1.0))
    var rr = 0.0
    var gg = 0.0
    var bb = 0.0
    if h < 1:
        rr, gg = c, x
    elif h < 2:
        rr, gg = x, c
    elif h < 3:
        gg, bb = c, x
    elif h < 4:
        gg, bb = x, c
    elif h < 5:
        rr, bb = x, c
    else:
        rr, bb = c, x
    var m = l - c / 2.0
    return rgba(Int((rr + m) * 255.0 + 0.5), Int((gg + m) * 255.0 + 0.5), Int((bb + m) * 255.0 + 0.5))


def liquid_css(p: Palette) -> String:
    """omxplorer's Liquid skin for GTK (docs/design/liquid.md, D-225, D-227), on top of skin_css: the controls float on
    glass islands over a soft backdrop, the content is solid white, one type scale (11 12 13 15 17 22 34 px), springs.
    GTK can't blur what is behind a widget: glass is translucent white with a rim, a top highlight and a soft shadow.
    GTK CSS has no linear() easing: arrivals are keyframes with an overshoot, hover and press a springy cubic-bezier."""
    var ink = hex_of(p.ink)
    var body = hex_of(p.ink2)
    var ink2 = hex_of(p.ink3)
    var accent = hex_of(p.accent)
    var line = hex_of(p.line)
    var strong = hex_of(p.line_strong)
    var w = String("window.liquid ")
    var d = p.dark
    var on_accent = hex_of(p.accent_ink)
    var solid = String("background-color: #ffffff; box-shadow: 0 0 0 1px rgba(15,23,42,0.07), 0 1px 3px rgba(15,23,42,0.05);") if not d else (
        "background-color: " + hex_of(p.card) + "; box-shadow: 0 0 0 1px " + line + ", 0 1px 3px rgba(0,0,0,0.30);")
    var solid_hover = String("0 0 0 1px rgba(15,23,42,0.07), 0 10px 30px rgba(15,23,42,0.10)") if not d else ("0 0 0 1px " + strong + ", 0 10px 30px rgba(0,0,0,0.40)")
    var hover = String("rgba(15,23,42,0.06)") if not d else String("rgba(255,255,255,0.07)")
    var backdrop = String("background-color: #e9eef4; background-image: linear-gradient(180deg, #eef2f7, #e4e9f1);") if not d else (
        "background-color: " + hex_of(p.page) + "; background-image: linear-gradient(180deg, " + hex_of(mix(p.page, WHITE, 0.03)) + ", " + hex_of(mix(p.page, hx("#000000"), 0.08)) + ");")
    var thumb = String("background: #ffffff; color: ") if not d else ("background: " + hex_of(p.raised) + "; color: ")
    var thumb_shadow = String("0 1px 3px rgba(15,23,42,0.12), 0 0 0 1px rgba(15,23,42,0.04)") if not d else ("0 1px 3px rgba(0,0,0,0.35), 0 0 0 1px " + strong)
    var tab_on = String("background: #ffffff; color: " + ink + "; box-shadow: 0 1px 3px rgba(15,23,42,0.12);") if not d else (
        "background: " + hex_of(p.raised) + "; color: " + ink + "; box-shadow: 0 1px 3px rgba(0,0,0,0.35), inset 0 0 0 1px " + strong + ";")
    var pop = String("background-color: rgba(255,255,255,0.94); box-shadow: inset 0 1px rgba(255,255,255,0.9), 0 0 0 1px rgba(15,23,42,0.08), 0 12px 40px rgba(15,23,42,0.16);") if not d else (
        "background-color: " + css_rgba(mix(p.card, WHITE, 0.03), 0.97) + "; box-shadow: inset 0 1px rgba(255,255,255,0.06), 0 0 0 1px " + line + ", 0 12px 40px rgba(0,0,0,0.50);")
    var key_ink = hex_of(mix(p.ink3, rgba(255, 255, 255), 0.3)) if not d else ink2
    var dialog_shadow = String("0 40px 100px rgba(15,23,42,0.30), 0 0 0 1px rgba(15,23,42,0.07)") if not d else ("0 40px 100px rgba(0,0,0,0.55), 0 0 0 1px " + line)
    var dim = String("rgba(15,23,42,0.18)") if not d else String("rgba(0,0,0,0.45)")
    var track = String("rgba(15,23,42,0.06)") if not d else String("rgba(255,255,255,0.06)")
    var highlight = String("rgba(255,255,255,0.18)") if not d else String("rgba(255,255,255,0.10)")
    var spring = String("cubic-bezier(0.22, 1, 0.36, 1)")  # calm ease-out, no overshoot (goal 25 M5: macOS settles, it doesn't bounce)
    return (
        "@keyframes liquid-arrive { from { opacity: 0; transform: scale(0.98) translateY(-4px); } to { opacity: 1; transform: none; } }\n"
        + "@keyframes liquid-rise { from { opacity: 0; transform: translateY(10px) scale(0.985); } to { opacity: 1; transform: none; } }\n"
        + "@keyframes liquid-land { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } }\n"
        # the backdrop, and type: Inter, one scale
        + w + "{ " + backdrop + " color: " + body + "; font-size: 13px; }\n"
        + w + "label.title-1 { font-size: 22px; font-weight: 700; letter-spacing: -0.3px; color: " + ink + "; }\n"
        + w + "label.title-4 { font-size: 15px; font-weight: 600; color: " + ink + "; }\n"
        + w + "label.caption { font-size: 12px; color: " + ink2 + "; }\n"
        + w + ".mui-board { background-color: transparent; }\n"
        # the menu bar: one glass strip, one type
        + w + ".mui-tag-menubar .mui-menubar { background: transparent; }\n"
        + w + ".mui-tag-app-mark { font-size: 15px; font-weight: 700; color: " + ink + "; letter-spacing: -0.3px; margin-right: 4px; }\n"
        + w + ".mui-tag-add-tile image { color: " + ink2 + "; }\n"
        # the inspector's structure: hairlines between sections, small-caps titles (goal 26 M0: "it looked like without borders")
        + w + ".mui-tag-inspector separator { background: " + strong + "; min-height: 1px; margin: 2px 0; }\n"
        + w + "menubutton.mui-menu > button { font-size: 13px; padding: 3px 10px; border-radius: 8px; color: " + body + "; transition: background 150ms " + spring + "; }\n"
        + w + "menubutton.mui-menu > button:hover, " + w + "menubutton.mui-menu > button:checked { background: " + hover + "; color: " + ink + "; }\n"
        # the toolbar: one floating glass island; tools icon over label, a soft fill on hover, press scales
        + w + "button.mui-tool { font-weight: 500; color: " + body + "; background: transparent; box-shadow: none;"
        + " transition: background 150ms " + spring + ", transform 150ms " + spring + "; }\n"
        + w + "button.mui-tool:hover { background: " + hover + "; } " + w + "button.mui-tool:active { transform: scale(0.97); }\n"
        + w + "button.mui-tool-on, " + w + "button.mui-tool-on:hover { background: " + hex_of(p.accent_wash) + "; color: " + accent + "; }\n"
        + w + ".mui-tag-toolbar separator { margin: 10px 8px; background: " + strong + "; min-width: 1px; }\n"
        # every button: pills, springy hover and press
        + w + "button { font-size: 13px; transition: background 150ms " + spring + ", box-shadow 150ms " + spring + ", transform 150ms " + spring + "; }\n"
        + w + "button:active { transform: scale(0.97); }\n"
        + w + "button.image-button, " + w + "button.flat.image-button { border-radius: 10px; }\n"
        + w + "button.suggested-action { box-shadow: 0 1px 2px " + hex_of(p.accent_tint) + ", inset 0 1px " + highlight + "; }\n"
        # the formula bar: a field on the backdrop
        + w + ".mui-tag-formula-bar entry { font-size: 13px; }\n"
        + w + "entry, " + w + "dropdown > button { font-size: 13px; }\n"
        # content: solid white cards (the table, charts, pivots, report tiles), 16 px corners
        + w + ".mui-card { border-radius: 16px; " + solid + " }\n"
        + w + ".mui-tag-tile { animation: liquid-land 320ms cubic-bezier(0.22, 1, 0.36, 1); transition: box-shadow 150ms " + spring + "; }\n"
        + w + ".mui-tag-tile:hover { box-shadow: " + solid_hover + "; }\n"
        # a tile's or an object's ✕ shows on hover (or keyboard focus) only: a report reads as a report (goal 26 M0)
        + w + ".mui-tag-tile button, " + w + ".mui-tag-chart-tile button.image-button, " + w + ".mui-board .mui-card button.image-button { opacity: 0; transition: opacity 150ms " + spring + "; }\n"
        + w + ".mui-tag-tile:hover button, " + w + ".mui-tag-chart-tile:hover button.image-button, " + w + ".mui-board .mui-card:hover button.image-button, "
        + w + ".mui-tag-tile:focus-within button, " + w + ".mui-tag-chart-tile:focus-within button.image-button, " + w + ".mui-tag-tile button:focus-visible, " + w + ".mui-tag-chart-tile button:focus-visible, " + w + ".mui-board .mui-card button:focus-visible { opacity: 1; }\n"
        + w + ".mui-board .mui-card .mui-tag-player-controls button.image-button { opacity: 1; }\n"  # (a video card's play button is its main control: always shown, goal 39 M6)
        + w + "label.title-1.mui-tone-accent, " + w + "label.title-4.mui-tone-accent { color: " + accent + "; }\n"
        # the bottom strip: tabs as pills, live figures
        + w + ".mui-tag-sheet-tabs button { border-radius: 999px; padding: 2px 14px; font-weight: 500; }\n"
        + w + ".mui-tag-sheet-tabs button:not(.flat) { " + tab_on + " }\n"
        # segmented controls: a soft track and a white thumb
        + w + "toggle-group { background: " + track + "; border-radius: 999px; padding: 3px; }\n"
        + w + "toggle-group > toggle { border-radius: 999px; min-height: 24px; padding: 0 12px; font-size: 12px; font-weight: 500; color: " + ink2 + "; transition: background 150ms " + spring + "; }\n"
        + w + "toggle-group > toggle:checked { " + thumb + ink + "; font-weight: 500; box-shadow: " + thumb_shadow + "; }\n"
        # menus and popovers: one glass panel arriving on a spring; rows one height and one type; a submenu solid
        + "popover.mui-menu-popover > contents, popover.mui-popover-surface > contents { border-radius: 14px; padding: 6px; " + pop + " }\n"
        + "window.liquid popover.mui-menu-popover > contents, window.liquid popover.mui-popover-surface > contents { animation: liquid-arrive 200ms cubic-bezier(0.22, 1, 0.36, 1); }\n"
        + "window.liquid popover.mui-menu-popover button.mui-menu-item, window.liquid popover.mui-menu-popover menubutton > button { min-height: 30px; padding: 0 10px; border-radius: 8px; font-size: 13px; font-weight: 400; color: " + ink + "; }\n"
        + "window.liquid popover.mui-menu-popover button.mui-menu-item:hover, window.liquid popover.mui-menu-popover menubutton > button:hover, window.liquid popover.mui-menu-popover menubutton > button:checked { background: " + accent + "; color: " + on_accent + "; }\n"
        + "window.liquid popover.mui-menu-popover button.mui-menu-item:hover image, window.liquid popover.mui-menu-popover button.mui-menu-item:hover label,"
        + " window.liquid popover.mui-menu-popover menubutton > button:hover image, window.liquid popover.mui-menu-popover menubutton > button:hover label { color: " + on_accent + "; }\n"
        + "window.liquid popover.mui-menu-popover label.mui-menu-key { font-family: 'Inter', sans-serif; font-size: 12px; color: " + key_ink + "; }\n"
        + "window.liquid popover.mui-menu-popover label.mui-menu-label { font-size: 11px; }\n"
        + "window.liquid popover.mui-menu-popover separator.mui-menu-sep { margin: 5px 8px; background: " + line + "; }\n"
        # dialogs: a white sheet rising on a spring over a dimmed window
        + "window.liquid dialog > sheet, window.liquid dialog.mui-dialog-surface, .mui-dialog { border-radius: 20px; }\n"
        + "window.liquid dialog > sheet { animation: liquid-rise 300ms cubic-bezier(0.22, 1, 0.36, 1); box-shadow: " + dialog_shadow + "; }\n"
        + "window.liquid .mui-dialog-head label { font-size: 17px; font-weight: 600; color: " + ink + "; }\n"
        # an inspector page slides in from the right (its header and every section after it)
        + "@keyframes liquid-page { from { opacity: 0; transform: translateX(24px); } to { opacity: 1; transform: none; } }\n"
        + "window.liquid .mui-tag-inspector-page, window.liquid .mui-tag-inspector-page ~ * { animation: liquid-page 280ms cubic-bezier(0.22, 1, 0.36, 1); }\n"
        + "window.liquid dimming { background-color: " + dim + "; }\n"
        # toasts: a dark pill
        + "window.liquid toast { border-radius: 999px; animation: liquid-rise 300ms cubic-bezier(0.22, 1, 0.36, 1); }\n"
    )


# omxplorer's Liquid skin (design 6, docs/design/liquid.md, D-225): on top of SKIN_CSS. The same rules as liquid_css in
# gtk.mojo, plus what only a browser can do: a real backdrop blur on the glass and true spring curves (linear()).
comptime LIQUID_WEB = """
body.liquid { --sp-snappy: cubic-bezier(.22, 1, .36, 1);  /* calm ease-out, no overshoot (goal 25 M5) */
  --sp-bouncy: cubic-bezier(.22, 1, .36, 1);
  --glass-bg: rgba(255,255,255,.62); --glass-fx: blur(24px) saturate(1.6);
  --glass-shadow: inset 0 1px rgba(255,255,255,.9), 0 0 0 1px rgba(255,255,255,.75), 0 8px 32px rgba(15,23,42,.10), 0 1px 2px rgba(15,23,42,.06);
  --solid-shadow: 0 0 0 1px rgba(15,23,42,.07), 0 1px 3px rgba(15,23,42,.05);
  --l-backdrop: linear-gradient(180deg, #eef2f7, #e4e9f1); --l-hover: rgba(15,23,42,.06); --l-solid: #fff;
  --l-lift: 0 0 0 1px rgba(15,23,42,.07), 0 10px 30px rgba(15,23,42,.10); --l-hi: rgba(255,255,255,.18);
  --l-track: rgba(15,23,42,.06); --l-thumb: #fff; --l-thumb-shadow: 0 1px 3px rgba(15,23,42,.12), 0 0 0 1px rgba(15,23,42,.04);
  --l-pop: rgba(255,255,255,.84); --l-pop-shadow: inset 0 1px rgba(255,255,255,.9), 0 0 0 1px rgba(15,23,42,.08), 0 12px 40px rgba(15,23,42,.16);
  --l-sub: #fff; --l-on-accent: #fff; --l-dialog-shadow: 0 40px 100px rgba(15,23,42,.30), 0 0 0 1px rgba(15,23,42,.07); --l-scrim: rgba(15,23,42,.18);
  background: var(--l-backdrop) fixed; font: 13px/18px Inter, sans-serif; }
body.liquid .text.title { font-size: 22px; line-height: 28px; letter-spacing: -.3px; } body.liquid .text.caption { font-size: 12px; }
body.liquid .board { background: transparent; }
@keyframes liquid-arrive { from { opacity: 0; transform: scale(.98) translateY(-4px); } to { opacity: 1; transform: none; } }
@keyframes liquid-rise { from { opacity: 0; transform: translateY(10px) scale(.985); } to { opacity: 1; transform: none; } }
@keyframes liquid-land { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } }
body.liquid .menubar {
  background: var(--glass-bg); -webkit-backdrop-filter: var(--glass-fx); backdrop-filter: var(--glass-fx); box-shadow: var(--glass-shadow); border: 0; }
body.liquid .menubar { margin: 8px 10px 0; border-radius: 12px; min-height: 34px; }
body.liquid [data-tag=menubar] .menubar { margin: 0; background: transparent; box-shadow: none; -webkit-backdrop-filter: none; backdrop-filter: none; }
body.liquid [data-tag=app-mark] { font-size: 15px; font-weight: 700; color: var(--o-ink); letter-spacing: -.3px; }
body.liquid [data-tag=inspector] hr { border: 0; border-top: 1px solid var(--o-strong); margin: 2px 0; width: 100%; }
body.liquid .menu-title { font-size: 13px; padding: 4px 10px; border-radius: 8px; color: var(--o-ink2); transition: background 150ms var(--sp-snappy); }
body.liquid .menu.open > .menu-title, body.liquid .menu-title:hover { background: var(--l-hover); color: var(--o-ink); }
body.liquid button.tool, body.liquid label.picker.tool { font-weight: 500; color: var(--o-ink2);
  transition: background 150ms var(--sp-snappy), transform 150ms var(--sp-snappy); }
body.liquid button.tool:hover, body.liquid label.picker.tool:hover { background: var(--l-hover); }
body.liquid button.tool:active, body.liquid button:active { transform: scale(.97); }
body.liquid button.tool.on, body.liquid button.icon-only.on { background: var(--o-wash); color: var(--o-accent); }
body.liquid button { transition: background 150ms var(--sp-snappy), box-shadow 150ms var(--sp-snappy), transform 150ms var(--sp-snappy); }
body.liquid button.icon-only { border-radius: 10px; }
body.liquid button.prominent { box-shadow: 0 1px 2px var(--o-tint), inset 0 1px var(--l-hi); }
body.liquid [data-tag=formula-bar] input[type=text] { font-size: 13px; }
body.liquid .vstack.card { background: var(--l-solid); border-radius: 16px; box-shadow: var(--solid-shadow); }
body.liquid [data-tag=tile] { animation: liquid-land 320ms var(--sp-bouncy) both;
  transition: box-shadow 150ms var(--sp-snappy), transform 150ms var(--sp-snappy); }
body.liquid [data-tag=tile]:hover { box-shadow: var(--l-lift); transform: translateY(-2px); }
body.liquid [data-tag=tile] button, body.liquid [data-tag=chart-tile] button.icon-only, body.liquid .board > .object button.icon-only { opacity: 0; transition: opacity 150ms var(--sp-snappy); }
body.liquid [data-tag=tile]:hover button, body.liquid [data-tag=chart-tile]:hover button.icon-only, body.liquid .board > .object:hover button.icon-only,
body.liquid [data-tag=tile] button:focus-visible, body.liquid [data-tag=chart-tile] button:focus-visible, body.liquid .board > .object button:focus-visible { opacity: 1; }
body.liquid .board > .object [data-tag=player-controls] button.icon-only { opacity: 1; }
@media (pointer: coarse) { body.liquid [data-tag=tile] button, body.liquid [data-tag=chart-tile] button.icon-only, body.liquid .board > .object button.icon-only { opacity: .6; } }
body.liquid [data-tag=sheet-tabs] button { border-radius: 999px; padding: 2px 14px; }
body.liquid .segmented, body.liquid .tabs { background: var(--l-track); border: 0; border-radius: 999px; padding: 3px; overflow: visible; }
body.liquid .segmented span, body.liquid .tabs span { border-radius: 999px; min-height: 24px; padding: 0 12px; font-weight: 500; transition: background 150ms var(--sp-snappy); }
body.liquid .segmented input:checked + span, body.liquid .tabs input:checked + span { background: var(--l-thumb); color: var(--o-ink); font-weight: 500;
  box-shadow: var(--l-thumb-shadow); }
body.liquid .menu > .menu-items, body.liquid .popover { border-radius: 14px; padding: 6px; background: var(--l-pop);
  -webkit-backdrop-filter: var(--glass-fx); backdrop-filter: var(--glass-fx); box-shadow: var(--l-pop-shadow);
  transform-origin: top left; animation: liquid-arrive 200ms var(--sp-bouncy) both; }
body.liquid .menu.sub > .menu-items { background: var(--l-sub); -webkit-backdrop-filter: none; backdrop-filter: none; }
body.liquid .mi { height: 30px; border-radius: 8px; font-size: 13px; color: var(--o-ink); transition: background 150ms var(--sp-snappy); }
body.liquid .mi:hover:not([disabled]) { background: var(--o-accent); color: var(--l-on-accent); } body.liquid .mi:hover:not([disabled]) svg, body.liquid .mi:hover:not([disabled]) .mi-key { color: var(--l-on-accent); }
body.liquid .mi .mi-key { font-family: Inter, sans-serif; font-size: 12px; }
body.liquid .dialog { border-radius: 20px; box-shadow: var(--l-dialog-shadow); animation: liquid-rise 300ms var(--sp-bouncy) both; }
body.liquid .dialog-layer .scrim { background: var(--l-scrim); -webkit-backdrop-filter: blur(6px); backdrop-filter: blur(6px); }
body.liquid .dialog-head h3 { font-size: 17px; }
body.liquid .toast { border-radius: 999px; animation: liquid-rise 300ms var(--sp-bouncy) both; }
@media (prefers-reduced-motion: reduce) { body.liquid *, body.liquid *::before, body.liquid *::after { animation: none !important; transition-duration: 0.01ms !important; } }
@keyframes liquid-page { from { opacity: 0; transform: translateX(24px); } to { opacity: 1; transform: none; } }
body.liquid [data-tag=inspector-page], body.liquid [data-tag=inspector-page] ~ * { animation: liquid-page 280ms cubic-bezier(.22, 1, .36, 1) both; }  /* (an arrival, not hover feedback) */
"""


def liquid_dark_web(p: Palette) -> String:
    """Liquid dark on the web: LIQUID_WEB's tokens from the palette (after it, so they win), the sheet and every card on it
    in a 1 px hairline (the shells' regions get theirs from liquid_look)."""
    var line = hex_of(p.line)
    var strong = hex_of(p.line_strong)
    var b = String("body.liquid ")
    return ("body.liquid { color-scheme: dark; --glass-bg: " + css_rgba(glass_fill(p), 0.92) + "; --glass-shadow: inset 0 1px rgba(255,255,255,.06), 0 0 0 1px " + line + ", 0 8px 24px rgba(0,0,0,.35);"
            + " --solid-shadow: 0 0 0 1px " + line + ", 0 1px 3px rgba(0,0,0,.30);"
            + " --l-backdrop: linear-gradient(180deg, " + hex_of(mix(p.page, WHITE, 0.03)) + ", " + hex_of(mix(p.page, hx("#000000"), 0.08)) + ");"
            + " --l-hover: rgba(255,255,255,.07); --l-solid: " + hex_of(p.card) + "; --l-lift: 0 0 0 1px " + strong + ", 0 10px 30px rgba(0,0,0,.40); --l-hi: rgba(255,255,255,.10);"
            + " --l-track: rgba(255,255,255,.06); --l-thumb: " + hex_of(p.raised) + "; --l-thumb-shadow: 0 1px 3px rgba(0,0,0,.35), 0 0 0 1px " + strong + ";"
            + " --l-pop: " + css_rgba(mix(p.card, WHITE, 0.03), 0.92) + "; --l-pop-shadow: inset 0 1px rgba(255,255,255,.06), 0 0 0 1px " + line + ", 0 12px 40px rgba(0,0,0,.50);"
            + " --l-sub: " + hex_of(p.card) + "; --l-on-accent: " + hex_of(p.accent_ink) + "; --l-dialog-shadow: 0 40px 100px rgba(0,0,0,.55), 0 0 0 1px " + line + "; --l-scrim: rgba(0,0,0,.45); }\n"
            + b + ".board-scroll { border: 1px solid " + line + "; border-radius: 16px; background-color: " + hex_of(mix(p.page, hx("#000000"), 0.15)) + "; box-sizing: border-box; }\n"
            + b + ".board > .object:not([data-tag=cell-editor]) { border: 1px solid " + line + "; border-radius: 16px; box-shadow: 0 6px 18px rgba(0,0,0,.35); }\n"
            + b + ".board > .object > .vstack.card { box-shadow: none; border-radius: 15px; }\n"
            + b + ".dialog, " + b + ".popover { background: " + hex_of(p.card) + "; }\n")


def liquid_dark_gtk(p: Palette) -> String:
    """Liquid dark on GTK: the sheet (a Board's scroller) and every card on it in a 1 px hairline, one soft shadow."""
    var w = String("window.liquid ")
    var line = hex_of(p.line)
    return (w + ".mui-board-scroll { border: 1px solid " + line + "; border-radius: 16px; background-color: " + hex_of(mix(p.page, hx("#000000"), 0.15)) + "; }\n"
            + w + ".mui-board > * { border: 1px solid " + line + "; border-radius: 16px; }\n"
            + w + ".mui-board > .mui-card { box-shadow: 0 6px 18px rgba(0,0,0,.35); }\n")


def liquid() -> Theme:
    return liquid(liquid_palette())


def liquid(dark: Bool) -> Theme:
    """Liquid light or Liquid dark (an app's App.appearance(dark) hands it the system's)."""
    return liquid(liquid_palette(dark))


def liquid(pal: Palette) -> Theme:
    """Liquid over `pal`: dark when the palette is (liquid_dark_palette)."""
    var gtk = skin_css(pal, "liquid") + liquid_css(pal) + (liquid_dark_gtk(pal) if pal.dark else String(""))
    var web = String(SKIN_WEB) + String(LIQUID_WEB) + (liquid_dark_web(pal) if pal.dark else String(""))
    return Theme("liquid", "skin liquid", pal.copy(), gtk, web, pal.ink2, pal.accent_ink, True, liquid_look(pal))
