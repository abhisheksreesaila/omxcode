# Liquid as a mojoui theme (docs/design/liquid.md, D-225): controls on glass islands over a soft backdrop, the
# content solid white, one type scale, calm motion. On top of the skins' rules (themes/skins.mojo).
#
#   def theme(self) -> Theme: return liquid()                     (or liquid(liquid_palette().with_accent(indigo)))

from mojoui.canvas import rgba
from mojoui.text import REGULAR, MEDIUM
from mojoui.theme import Palette, Theme, hx, mix, hex_of
from mojoui.theme import Look, Surface, Shadow, TypeScale, Controls, Segments, glass, solid, words, chip, slot
from themes.skins import skin_css, SKIN_WEB


def liquid_look(p: Palette) -> Look:
    """Liquid's shapes as values (every host draws them): glass islands for the chrome (the header, the toolbar, the
    inspector, the bottom strip), solid white cards for the content, Inter on one scale (11 12 13 15 17 22 34)."""
    var tabs = glass("sheet-tabs", 14, 0, 0, 10, 0, -1)
    var status = glass("status-bar", 0, 14, 0, 10, 10, -1)
    status.shadows = [Shadow(8, 20, 0, rgba(15, 23, 42, 15), False)]
    status.font, status.font_size, status.ink = "Inter", 12, p.ink3
    var header = glass("menubar", 12, 12, 8, 10, 0, -1)
    header.min_height = 34
    var bar = Surface("formula-bar", 0, -1, -1, 0, 10, 0, -1, -1, -1, [], 0, 0, 0, -1, "", 0, 0, 0, 0, 0, 0, 0, False)  # (on the backdrop: no panel)
    # an inspector row (a label, its control) as tall as a control, whichever control it holds: the Mac's checkbox (16 pt) and
    # switch rows sat closer than GTK's and the web's (2026-10-25)
    var row = Surface("inspector-row", 0, -1, -1, -1, -1, -1, -1, -1, -1, [], 0, 0, 0, 30, "", 0, 0, 0, 0, 0, 0, 0, False)
    var surfaces: List[Surface] = [header^, row^, glass("toolbar", 18, 18, 0, 10, 0, 6), glass("inspector", 18, 18, -1, -1, -1, 10), tabs^, status^, bar^,
                                   solid("table", 16, 10, 12, 12), solid("tile", 16, 16, 18, 16), words("sentence-line", 15, 600, p.ink),
                                   words("section-title", 0, 600, 0, 0.5), words("stat-value", 15, 600, p.ink), words("kpi-fact", 12, 0, p.ink3),
                                   chip("stat-card", p.raised, p.line_strong, 0, 0, 12, -1, -1), chip("kpi-note", p.raised, p.line, 12, p.ink2, 999, 2, 10),
                                   slot("add-tile", p.line_strong, 16, 120, p.ink3)]
    var value = words("kpi-value", 34, 600, 0, -0.8)  # (a Report tile's figure: GTK's and the web's title-1 in a tile)
    value.line_height = 40
    surfaces.append(value^)
    return Look(TypeScale("Inter", "", 13, 12, 15, 22, 11, True, 0), Controls(62, 52, 12, 11, 34, 10, 10, 12, 34, 10, 16, 999, 10, 30, 14, 8, 0, 0, 0, 0), surfaces^,
                Segments(rgba(15, 23, 42, 15), 999, 3, 0, 24, 12, 999, 12, 500, p.ink3, rgba(255, 255, 255), p.ink, 500, True))  # (the sheet's toggle-group rules say the same: D-300)


def liquid_palette() -> Palette:
    """Liquid, light (docs/design/liquid.md): a white sheet, glass islands over a soft cool backdrop, teal (the default).
    The chrome is the glass as it looks over the backdrop (GTK can't blur what's behind a widget)."""
    return Palette(False, hx("#e9eef4"), hx("#ffffff"), hx("#f6f8fb"), hx("#0f172a"), hx("#334155"), hx("#64748b"),
                   hx("#edf0f4"), hx("#d9dee6"), hx("#0e7c86"), hx("#ffffff"), mix(hx("#ffffff"), hx("#0e7c86"), 0.40), hx("#e6f2f3"),
                   hx("#6a4fd6"), hx("#16a34a"), hx("#dc2626"), hx("#d97706"), REGULAR, MEDIUM, [hx("#0e7c86"), hx("#f59e0b"), hx("#6366f1"), hx("#ec4899"), hx("#22c55e"), hx("#a16207"), hx("#64748b"), hx("#c026d3")], hx("#f7f9fc"), hx("#334155"), hx("#ffffff"))


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
    var glass = String("background-color: rgba(255,255,255,0.62); box-shadow: inset 0 1px rgba(255,255,255,0.9), 0 0 0 1px rgba(255,255,255,0.75), 0 8px 32px rgba(15,23,42,0.10), 0 1px 2px rgba(15,23,42,0.06);")
    var solid = String("background-color: #ffffff; box-shadow: 0 0 0 1px rgba(15,23,42,0.07), 0 1px 3px rgba(15,23,42,0.05);")
    var hover = String("rgba(15,23,42,0.06)")
    var spring = String("cubic-bezier(0.22, 1, 0.36, 1)")  # calm ease-out, no overshoot (goal 25 M5: macOS settles, it doesn't bounce)
    return (
        "@keyframes liquid-arrive { from { opacity: 0; transform: scale(0.98) translateY(-4px); } to { opacity: 1; transform: none; } }\n"
        + "@keyframes liquid-rise { from { opacity: 0; transform: translateY(10px) scale(0.985); } to { opacity: 1; transform: none; } }\n"
        + "@keyframes liquid-land { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } }\n"
        # the backdrop, and type: Inter, one scale
        + w + "{ background-color: #e9eef4; background-image: linear-gradient(180deg, #eef2f7, #e4e9f1); color: " + body + "; font-size: 13px; }\n"
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
        + w + "button.suggested-action { box-shadow: 0 1px 2px " + hex_of(p.accent_tint) + ", inset 0 1px rgba(255,255,255,0.18); }\n"
        # the formula bar: a field on the backdrop
        + w + ".mui-tag-formula-bar entry { font-size: 13px; }\n"
        + w + "entry, " + w + "dropdown > button { font-size: 13px; }\n"
        # content: solid white cards (the table, charts, pivots, report tiles), 16 px corners
        + w + ".mui-card { border-radius: 16px; " + solid + " }\n"
        + w + ".mui-tag-tile { animation: liquid-land 320ms cubic-bezier(0.22, 1, 0.36, 1); transition: box-shadow 150ms " + spring + "; }\n"
        + w + ".mui-tag-tile:hover { box-shadow: 0 0 0 1px rgba(15,23,42,0.07), 0 10px 30px rgba(15,23,42,0.10); }\n"
        # a tile's or an object's ✕ shows on hover (or keyboard focus) only: a report reads as a report (goal 26 M0)
        + w + ".mui-tag-tile button, " + w + ".mui-tag-chart-tile button.image-button, " + w + ".mui-board .mui-card button.image-button { opacity: 0; transition: opacity 150ms " + spring + "; }\n"
        + w + ".mui-tag-tile:hover button, " + w + ".mui-tag-chart-tile:hover button.image-button, " + w + ".mui-board .mui-card:hover button.image-button, "
        + w + ".mui-tag-tile:focus-within button, " + w + ".mui-tag-chart-tile:focus-within button.image-button, " + w + ".mui-tag-tile button:focus-visible, " + w + ".mui-tag-chart-tile button:focus-visible, " + w + ".mui-board .mui-card button:focus-visible { opacity: 1; }\n"
        + w + "label.title-1.mui-tone-accent, " + w + "label.title-4.mui-tone-accent { color: " + accent + "; }\n"
        # the bottom strip: tabs as pills, live figures
        + w + ".mui-tag-sheet-tabs button { border-radius: 999px; padding: 2px 14px; font-weight: 500; }\n"
        + w + ".mui-tag-sheet-tabs button:not(.flat) { background: #ffffff; color: " + ink + "; box-shadow: 0 1px 3px rgba(15,23,42,0.12); }\n"
        # segmented controls: a soft track and a white thumb
        + w + "toggle-group { background: rgba(15,23,42,0.06); border-radius: 999px; padding: 3px; }\n"
        + w + "toggle-group > toggle { border-radius: 999px; min-height: 24px; padding: 0 12px; font-size: 12px; font-weight: 500; color: " + ink2 + "; transition: background 150ms " + spring + "; }\n"
        + w + "toggle-group > toggle:checked { background: #ffffff; color: " + ink + "; font-weight: 500; box-shadow: 0 1px 3px rgba(15,23,42,0.12), 0 0 0 1px rgba(15,23,42,0.04); }\n"
        # menus and popovers: one glass panel arriving on a spring; rows one height and one type; a submenu solid
        + "popover.mui-menu-popover > contents, popover.mui-popover-surface > contents { border-radius: 14px; padding: 6px; background-color: rgba(255,255,255,0.94);"
        + " box-shadow: inset 0 1px rgba(255,255,255,0.9), 0 0 0 1px rgba(15,23,42,0.08), 0 12px 40px rgba(15,23,42,0.16); }\n"
        + "window.liquid popover.mui-menu-popover > contents, window.liquid popover.mui-popover-surface > contents { animation: liquid-arrive 200ms cubic-bezier(0.22, 1, 0.36, 1); }\n"
        + "window.liquid popover.mui-menu-popover button.mui-menu-item, window.liquid popover.mui-menu-popover menubutton > button { min-height: 30px; padding: 0 10px; border-radius: 8px; font-size: 13px; font-weight: 400; color: " + ink + "; }\n"
        + "window.liquid popover.mui-menu-popover button.mui-menu-item:hover, window.liquid popover.mui-menu-popover menubutton > button:hover, window.liquid popover.mui-menu-popover menubutton > button:checked { background: " + accent + "; color: #ffffff; }\n"
        + "window.liquid popover.mui-menu-popover button.mui-menu-item:hover image, window.liquid popover.mui-menu-popover button.mui-menu-item:hover label,"
        + " window.liquid popover.mui-menu-popover menubutton > button:hover image, window.liquid popover.mui-menu-popover menubutton > button:hover label { color: #ffffff; }\n"
        + "window.liquid popover.mui-menu-popover label.mui-menu-key { font-family: 'Inter', sans-serif; font-size: 12px; color: " + hex_of(mix(p.ink3, rgba(255, 255, 255), 0.3)) + "; }\n"
        + "window.liquid popover.mui-menu-popover label.mui-menu-label { font-size: 11px; }\n"
        + "window.liquid popover.mui-menu-popover separator.mui-menu-sep { margin: 5px 8px; background: " + line + "; }\n"
        # dialogs: a white sheet rising on a spring over a dimmed window
        + "window.liquid dialog > sheet, window.liquid dialog.mui-dialog-surface, .mui-dialog { border-radius: 20px; }\n"
        + "window.liquid dialog > sheet { animation: liquid-rise 300ms cubic-bezier(0.22, 1, 0.36, 1); box-shadow: 0 40px 100px rgba(15,23,42,0.30), 0 0 0 1px rgba(15,23,42,0.07); }\n"
        + "window.liquid .mui-dialog-head label { font-size: 17px; font-weight: 600; color: " + ink + "; }\n"
        # an inspector page slides in from the right (its header and every section after it)
        + "@keyframes liquid-page { from { opacity: 0; transform: translateX(24px); } to { opacity: 1; transform: none; } }\n"
        + "window.liquid .mui-tag-inspector-page, window.liquid .mui-tag-inspector-page ~ * { animation: liquid-page 280ms cubic-bezier(0.22, 1, 0.36, 1); }\n"
        + "window.liquid dimming { background-color: rgba(15,23,42,0.18); }\n"
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
  background: linear-gradient(180deg, #eef2f7, #e4e9f1) fixed; font: 13px/18px Inter, sans-serif; }
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
body.liquid .menu.open > .menu-title, body.liquid .menu-title:hover { background: rgba(15,23,42,.06); color: var(--o-ink); }
body.liquid button.tool, body.liquid label.picker.tool { font-weight: 500; color: var(--o-ink2);
  transition: background 150ms var(--sp-snappy), transform 150ms var(--sp-snappy); }
body.liquid button.tool:hover, body.liquid label.picker.tool:hover { background: rgba(15,23,42,.06); }
body.liquid button.tool:active, body.liquid button:active { transform: scale(.97); }
body.liquid button.tool.on, body.liquid button.icon-only.on { background: var(--o-wash); color: var(--o-accent); }
body.liquid button { transition: background 150ms var(--sp-snappy), box-shadow 150ms var(--sp-snappy), transform 150ms var(--sp-snappy); }
body.liquid button.icon-only { border-radius: 10px; }
body.liquid button.prominent { box-shadow: 0 1px 2px var(--o-tint), inset 0 1px rgba(255,255,255,.18); }
body.liquid [data-tag=formula-bar] input[type=text] { font-size: 13px; }
body.liquid .vstack.card { background: #fff; border-radius: 16px; box-shadow: var(--solid-shadow); }
body.liquid [data-tag=tile] { animation: liquid-land 320ms var(--sp-bouncy) both;
  transition: box-shadow 150ms var(--sp-snappy), transform 150ms var(--sp-snappy); }
body.liquid [data-tag=tile]:hover { box-shadow: 0 0 0 1px rgba(15,23,42,.07), 0 10px 30px rgba(15,23,42,.10); transform: translateY(-2px); }
body.liquid [data-tag=tile] button, body.liquid [data-tag=chart-tile] button.icon-only, body.liquid .board > .object button.icon-only { opacity: 0; transition: opacity 150ms var(--sp-snappy); }
body.liquid [data-tag=tile]:hover button, body.liquid [data-tag=chart-tile]:hover button.icon-only, body.liquid .board > .object:hover button.icon-only,
body.liquid [data-tag=tile] button:focus-visible, body.liquid [data-tag=chart-tile] button:focus-visible, body.liquid .board > .object button:focus-visible { opacity: 1; }
@media (pointer: coarse) { body.liquid [data-tag=tile] button, body.liquid [data-tag=chart-tile] button.icon-only, body.liquid .board > .object button.icon-only { opacity: .6; } }
body.liquid [data-tag=sheet-tabs] button { border-radius: 999px; padding: 2px 14px; }
body.liquid .segmented, body.liquid .tabs { background: rgba(15,23,42,.06); border: 0; border-radius: 999px; padding: 3px; overflow: visible; }
body.liquid .segmented span, body.liquid .tabs span { border-radius: 999px; min-height: 24px; padding: 0 12px; font-weight: 500; transition: background 150ms var(--sp-snappy); }
body.liquid .segmented input:checked + span, body.liquid .tabs input:checked + span { background: #fff; color: var(--o-ink); font-weight: 500;
  box-shadow: 0 1px 3px rgba(15,23,42,.12), 0 0 0 1px rgba(15,23,42,.04); }
body.liquid .menu > .menu-items, body.liquid .popover { border-radius: 14px; padding: 6px; background: rgba(255,255,255,.84);
  -webkit-backdrop-filter: var(--glass-fx); backdrop-filter: var(--glass-fx); box-shadow: inset 0 1px rgba(255,255,255,.9), 0 0 0 1px rgba(15,23,42,.08), 0 12px 40px rgba(15,23,42,.16);
  transform-origin: top left; animation: liquid-arrive 200ms var(--sp-bouncy) both; }
body.liquid .menu.sub > .menu-items { background: #fff; -webkit-backdrop-filter: none; backdrop-filter: none; }
body.liquid .mi { height: 30px; border-radius: 8px; font-size: 13px; color: var(--o-ink); transition: background 150ms var(--sp-snappy); }
body.liquid .mi:hover:not([disabled]) { background: var(--o-accent); color: #fff; } body.liquid .mi:hover:not([disabled]) svg, body.liquid .mi:hover:not([disabled]) .mi-key { color: #fff; }
body.liquid .mi .mi-key { font-family: Inter, sans-serif; font-size: 12px; }
body.liquid .dialog { border-radius: 20px; box-shadow: 0 40px 100px rgba(15,23,42,.30), 0 0 0 1px rgba(15,23,42,.07); animation: liquid-rise 300ms var(--sp-bouncy) both; }
body.liquid .dialog-layer .scrim { background: rgba(15,23,42,.18); -webkit-backdrop-filter: blur(6px); backdrop-filter: blur(6px); }
body.liquid .dialog-head h3 { font-size: 17px; }
body.liquid .toast { border-radius: 999px; animation: liquid-rise 300ms var(--sp-bouncy) both; }
@media (prefers-reduced-motion: reduce) { body.liquid *, body.liquid *::before, body.liquid *::after { animation: none !important; transition-duration: 0.01ms !important; } }
@keyframes liquid-page { from { opacity: 0; transform: translateX(24px); } to { opacity: 1; transform: none; } }
body.liquid [data-tag=inspector-page], body.liquid [data-tag=inspector-page] ~ * { animation: liquid-page 280ms cubic-bezier(.22, 1, .36, 1) both; }  /* (an arrival, not hover feedback) */
"""


def liquid() -> Theme:
    return liquid(liquid_palette())


def liquid(pal: Palette) -> Theme:
    return Theme("liquid", "skin liquid", pal.copy(), skin_css(pal, "liquid") + liquid_css(pal), String(SKIN_WEB) + String(LIQUID_WEB),
                 pal.ink2, pal.accent_ink, True, liquid_look(pal))
