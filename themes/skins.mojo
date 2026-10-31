# The skins as mojoui themes (D-149, docs/design/universal/): the same tokens on every platform, Inter for words and
# JetBrains Mono for figures, flat controls, a chrome band for the toolbar and bars. Ledger (light, teal), Graphite
# (mid-dark omxqua: tonal surfaces, the green accent, every region in a 1 px hairline: goal 41, D-1174), Blueprint
# (light with a navy band). Liquid (themes/liquid.mojo) builds on these rules.
#
#   def theme(self) -> Theme: return ledger()                     (or ledger(ledger_palette().with_accent(green)))
#   bordered(id, pal): any skin with a hairline around every region (mojoui.regions: sidebar, toolbar, sheet, inspector,
#   status bar, each card), as graphite has it

from mojoui.canvas import rgba
from mojoui.text import REGULAR, MEDIUM
from mojoui.theme import Palette, Theme, hx, mix, hex_of
from mojoui.theme import Look, Surface, TypeScale, Controls, Segments, band, words


def ledger_palette() -> Palette:
    """Light and classic: a white sheet, quiet grey chrome, one deep teal accent (the default)."""
    return Palette(False, hx("#eef0f3"), hx("#ffffff"), hx("#f0f2f5"), hx("#1b1f24"), hx("#3d434c"), hx("#6b7380"),
                   hx("#e1e4e8"), hx("#c9ced6"), hx("#0e7c86"), hx("#ffffff"), mix(hx("#ffffff"), hx("#0e7c86"), 0.45), hx("#e3f2f3"),
                   hx("#6a4fd6"), hx("#1f8a4c"), hx("#c8364c"), hx("#b7791f"), REGULAR, MEDIUM, [hx("#0e7c86"), hx("#e8833a"), hx("#5b5fc7"), hx("#d6455d"), hx("#2e9e5b"), hx("#b8892d"), hx("#7a8594"), hx("#c45cb5")], hx("#f5f6f8"), hx("#1b1f24"), hx("#e1e4e8"))


def graphite_palette() -> Palette:
    """Mid-dark omxqua (owner, goal 41: "has to follow omxqua"): opaque tonal surfaces a step apart (page #23262b, panels
    and cards #2a2e34, raised #33383f, the sheet a step below at SHEET), a #464d57 hairline, omxqua's green #3ccf6e as
    the one accent, its semantic tones (ok #3ccf6e, warn #f5a524, bad #f2555a, info #52a9ff) and its data palette."""
    var card = hx("#2a2e34")
    var accent = hx("#3ccf6e")
    return Palette(True, hx("#23262b"), card, hx("#33383f"), hx("#e6e8eb"), hx("#c3c8cf"), hx("#98a1ac"),
                   hx("#464d57"), hx("#59616c"), accent, hx("#0d2416"), mix(card, accent, 0.45), mix(card, accent, 0.16),
                   hx("#52a9ff"), hx("#3ccf6e"), hx("#f2555a"), hx("#f5a524"), REGULAR, MEDIUM, [hx("#3aa0ff"), hx("#8b7bff"), hx("#2bc3ad"), hx("#ff8a3d"), hx("#f2555a"), hx("#e0b400"), hx("#98a1ac"), hx("#d86fc9")], hx("#2a2e34"), hx("#e6e8eb"), hx("#464d57"))


comptime SHEET = "#1e2125"  # graphite's sheet (the Board behind the cards): a step below the page, as omxqua's surface-0


def blueprint_palette() -> Palette:
    """Light with a navy band over a white sheet, blue accent."""
    return Palette(False, hx("#f3f5f9"), hx("#ffffff"), hx("#f1f4f9"), hx("#111827"), hx("#374151"), hx("#6b7280"),
                   hx("#e0e5ee"), hx("#c5cede"), hx("#2f6fed"), hx("#ffffff"), mix(hx("#ffffff"), hx("#2f6fed"), 0.45), hx("#e5eefe"),
                   hx("#7b3fe4"), hx("#138a52"), hx("#d23f57"), hx("#b7791f"), REGULAR, MEDIUM, [hx("#2f6fed"), hx("#f08c2e"), hx("#13a39a"), hx("#d9485f"), hx("#7b61ff"), hx("#b8892d"), hx("#7a8594"), hx("#c45cb5")], hx("#14213d"), hx("#e8edf7"), hx("#2a3a63"))


def skin_css(p: Palette, cls: String) -> String:
    """omxplorer's skins for GTK (D-149): one look from the palette's tokens (the same values as the web's CSS),
    Inter for words, JetBrains Mono for figures, flat controls, a chrome band for the toolbar and bars."""
    var page = hex_of(p.page)
    var card = hex_of(p.card)
    var raised = hex_of(p.raised)
    var ink = hex_of(p.ink)
    var ink2 = hex_of(p.ink2)
    var ink3 = hex_of(p.ink3)
    var line = hex_of(p.line)
    var strong = hex_of(p.line_strong)
    var accent = hex_of(p.accent)
    var wash = hex_of(p.accent_wash)
    var on_accent = hex_of(p.accent_ink)
    var chrome = hex_of(p.chrome)
    var chrome_ink = hex_of(p.chrome_ink)
    var chrome_line = hex_of(p.chrome_line)
    var w = "window." + cls + " "
    var shadow = String("0 4px 16px rgba(16,24,40,.12), 0 1px 3px rgba(16,24,40,.08)") if not p.dark else String("0 6px 20px rgba(0,0,0,.55), 0 0 0 1px #34363b")
    return (
        ":root { --accent-bg-color: " + accent + "; --accent-color: " + accent + "; --accent-fg-color: " + on_accent + "; }\n"
        + w + "{ background-color: " + page + "; color: " + ink2 + "; font-family: 'Inter', sans-serif; font-size: 13px; }\n"
        + w + "label { color: " + ink2 + "; }\n"
        + w + "label.title-1, " + w + "label.title-4 { color: " + ink + "; font-weight: 600; letter-spacing: -0.2px; }\n"
        + w + "label.title-1 { font-size: 20px; font-weight: 700; } " + w + "label.title-4 { font-size: 15px; }\n"
        + w + "label.caption { font-size: 12px; color: " + ink3 + "; } " + w + ".dim-label { opacity: 1; }\n"
        + w + ".mui-card { background-color: " + card + "; border-radius: 6px; padding: 12px 14px; box-shadow: inset 0 0 0 1px " + line + "; }\n"
        + w + "label.mui-tone-warn { color: " + hex_of(p.warn) + "; } " + w + "label.mui-tone-good { color: " + hex_of(p.good) + "; }\n"
        + w + "label.mui-tone-strong { color: " + ink + "; font-weight: 600; } " + w + "label.mui-tone-accent { color: " + accent + "; }\n"
        + w + ".mui-card.mui-warn { background-color: " + hex_of(mix(p.card, p.warn, 0.09)) + "; box-shadow: inset 0 0 0 1px " + hex_of(mix(p.card, p.warn, 0.35)) + "; }\n"
        + w + ".mui-card.mui-good { background-color: " + hex_of(mix(p.card, p.good, 0.08)) + "; box-shadow: inset 0 0 0 1px " + hex_of(mix(p.card, p.good, 0.30)) + "; }\n"
        + w + ".mui-island { background-color: " + card + "; border-radius: 6px; padding: 6px 10px; min-height: 32px; box-shadow: inset 0 0 0 1px " + line + ", " + shadow + "; }\n"
        + w + ".mui-board { background-color: " + page + "; }\n"
        # the chrome band: toolbar, sheet tabs, status bar (tagged views)
        + w + ".mui-tag-formula-bar entry { font-family: 'JetBrains Mono', monospace; font-size: 12.5px; }\n"
        + w + ".mui-tag-toolbar label, " + w + ".mui-tag-toolbar button { color: " + chrome_ink + "; }\n"
        # buttons: secondary with a hairline, primary filled, quiet ones flat; hover raised, pressed washed
        + w + "button { padding: 2px 14px; font-weight: 500; background: " + card + "; color: " + ink + "; box-shadow: inset 0 0 0 1px " + strong + "; }\n"
        + w + "button:hover { background: " + raised + "; }\n"
        + w + "button:active { background: " + wash + "; }\n"
        + w + "button:focus-visible { outline: 2px solid " + accent + "; outline-offset: 1px; }\n"
        + w + "button.flat { background: transparent; box-shadow: none; color: " + ink2 + "; }\n"
        + w + "button.flat:hover { background: " + raised + "; color: " + ink + "; }\n"
        + w + "button.image-button { min-width: 30px; padding: 2px 6px; }\n"
        + w + "button label, " + w + "button image { color: inherit; }\n"
        + w + "button.suggested-action { background: " + accent + "; color: " + on_accent + "; box-shadow: none; font-weight: 600; }\n"
        + w + "button.suggested-action:hover { background: " + hex_of(mix(p.accent, rgba(0, 0, 0), 0.14)) + "; }\n"
        # (a primary button in the chrome band keeps its text on the accent: the band's ink above out-ranks "inherit")
        + w + ".mui-tag-toolbar button.suggested-action, " + w + ".mui-tag-toolbar button.suggested-action label { color: " + on_accent + "; }\n"
        # a sentence's words (mojoui.sentence): inline, in the accent, a dotted underline, a wash on hover; the glue between them in the ink
        + w + "button.mui-token { padding: 0 1px; min-height: 0; min-width: 0; margin: 0; border-radius: 5px; background: transparent; box-shadow: none; }\n"
        + w + "button.mui-token:hover { background: " + hex_of(mix(p.card, p.data(0), 0.12)) + "; }\n"  # (the words wear the chart's colour, not the mode's tint: a red word reads as an error)
        + w + "button.mui-token label { color: " + hex_of(p.data(0)) + "; font-weight: 600; font-size: 15px; text-decoration-line: underline; text-decoration-color: " + hex_of(mix(p.card, p.data(0), 0.45)) + "; }\n"
        + "@keyframes mui-token-lit { from { background-color: " + hex_of(mix(p.card, p.data(0), 0.30)) + "; } to { background-color: transparent; } }\n"
        + w + "button.mui-token-lit { animation: mui-token-lit 1400ms ease-out; }\n"
        + w + "button.destructive-action { background: " + hex_of(p.bad) + "; color: #ffffff; box-shadow: none; font-weight: 600; }\n"
        + w + "button.mui-tool { padding: 4px 6px; }\n"
        + w + "button.mui-tool:hover { background: " + hex_of(mix(p.chrome, p.chrome_ink, 0.08)) + "; }\n"
        + w + "button.mui-tool-on { background: " + wash + "; color: " + accent + "; }\n"
        + w + "button.mui-tool-on label, " + w + "button.mui-tool-on image { color: " + accent + "; }\n"
        # fields and choices: hairline, accent ring on focus
        + w + "entry, " + w + "textview, " + w + "dropdown > button { background: " + card + "; color: " + ink + "; box-shadow: inset 0 0 0 1px " + strong + "; }\n"
        + w + "entry:focus-within { box-shadow: inset 0 0 0 1px " + accent + ", 0 0 0 3px " + hex_of(mix(p.card, p.accent, 0.18)) + "; outline: none; }\n"
        + w + "textview text { background: " + card + "; color: " + ink + "; }\n"
        + w + "dropdown > button { padding: 2px 8px; font-weight: 400; }\n"
        + w + "popover > contents, popover.menu > contents { background: " + card + "; color: " + ink + "; border-radius: 6px; box-shadow: inset 0 0 0 1px " + line + ", " + shadow + "; }\n"
        + w + "scrollbar slider { min-width: 6px; min-height: 6px; background-color: " + strong + "; border-radius: 3px; }\n"
        + w + "entry.mui-cell-editor { border-radius: 0; box-shadow: inset 0 0 0 2px " + accent + "; background: " + card + "; }\n"
        + w + "toggle-group { background: transparent; }\n"
        + w + "toggle-group > toggle { border-radius: 4px; min-height: 26px; padding: 0 10px; color: " + ink2 + "; }\n"
        + w + "toggle-group > toggle:checked { background: " + accent + "; color: " + on_accent + "; font-weight: 600; }\n"
        + w + ".mui-tag-sheet-tabs toggle-group > toggle:checked { background: " + card + "; color: " + ink + "; box-shadow: inset 0 2px " + accent + "; border-radius: 0; }\n"
        + w + "checkbutton check, " + w + "checkbutton radio { border-radius: 3px; border: 1.5px solid " + strong + "; background: " + card + "; min-width: 15px; min-height: 15px; -gtk-icon-size: 12px; }\n"
        + w + "checkbutton radio { border-radius: 50%; }\n"
        + w + "checkbutton check:checked, " + w + "checkbutton radio:checked { background: " + accent + "; border-color: " + accent + "; color: " + on_accent + "; }\n"
        + w + "switch { background: " + strong + "; } " + w + "switch:checked { background: " + accent + "; }\n"
        + w + ".mui-menubar { background: " + chrome + "; }\n"
        + w + "menubutton.mui-menu > button { min-height: 24px; padding: 2px 9px; font-size: 12.5px; font-weight: 400; color: " + chrome_ink + "; border-radius: 4px; background: transparent; box-shadow: none; }\n"
        + w + "menubutton.mui-menu > button:checked, " + w + "menubutton.mui-menu > button:hover { background: " + hex_of(mix(p.chrome, p.chrome_ink, 0.08)) + "; }\n"
        + w + "menubutton.mui-menu arrow { -gtk-icon-size: 0; min-width: 0; min-height: 0; margin: 0; }\n"
        + "popover.mui-menu-popover > contents { padding: 4px; min-width: 260px; }\n"
        + "popover.mui-menu-popover button.mui-menu-item { min-height: 28px; padding: 0 10px; border-radius: 4px; font-size: 12.5px; font-weight: 400; color: " + ink + "; }\n"
        + "popover.mui-menu-popover button.mui-menu-item:hover { background: " + wash + "; }\n"
        + "popover.mui-menu-popover button.mui-menu-item image { color: " + ink3 + "; -gtk-icon-size: 15px; }\n"
        + "popover.mui-menu-popover button.mui-menu-item:hover image { color: " + accent + "; }\n"
        + "popover.mui-menu-popover button.mui-danger, popover.mui-menu-popover button.mui-danger image { color: " + hex_of(p.bad) + "; }\n"
        + "popover.mui-menu-popover label.mui-menu-key { color: " + ink3 + "; font-family: 'JetBrains Mono', monospace; font-size: 11px; margin-left: 24px; }\n"
        + "popover.mui-menu-popover label.mui-menu-label { color: " + ink3 + "; font-size: 10.5px; font-weight: 600; letter-spacing: .8px; padding: 6px 10px 4px; }\n"
        + "popover.mui-menu-popover separator.mui-menu-sep { margin: 4px 6px; background: " + line + "; }\n"
        # a submenu row is a menubutton: its inner button must look exactly like a plain item (no hairline, same type)
        + "popover.mui-menu-popover menubutton > button { min-height: 28px; padding: 0 10px; border-radius: 4px; font-size: 12.5px; font-weight: 400; color: " + ink + "; background: transparent; box-shadow: none; }\n"
        + "popover.mui-menu-popover menubutton > button:hover, popover.mui-menu-popover menubutton > button:checked { background: " + wash + "; }\n"
        + "popover.mui-menu-popover menubutton > button image { color: " + ink3 + "; -gtk-icon-size: 15px; }\n"
        + "popover.mui-menu-popover menubutton arrow { -gtk-icon-size: 0; min-width: 0; min-height: 0; margin: 0; }\n"
        + "dialog.mui-dialog-surface, " + w + "dialog, dialog > sheet { border-radius: 8px; }\n"
        + ".mui-dialog { background: " + card + "; color: " + ink + "; border-radius: 8px; }\n"
        + ".mui-dialog-head { padding: 14px 16px 14px 20px; border-bottom: 1px solid " + line + "; }\n"
        + ".mui-dialog-body { padding: 16px 20px; }\n"
        + ".mui-dialog label { color: " + ink2 + "; } .mui-dialog label.title-4 { color: " + ink + "; font-weight: 600; font-size: 15px; }\n"
        + "popover.mui-popover-surface > contents { padding: 12px 14px; min-width: 260px; }\n"
        + "toast { background: " + ink + "; color: " + card + "; border-radius: 6px; font-family: 'Inter', sans-serif; font-size: 12.5px; }\n"
        + "toast label, toast button { color: " + card + "; } toast button.flat { color: " + hex_of(mix(p.accent, p.card, 0.55)) + "; font-weight: 600; }\n"
        + "tooltip { background: " + ink + "; color: " + card + "; border-radius: 4px; padding: 6px 10px; font-family: 'Inter', sans-serif; font-size: 12px; }\n"
        + "tooltip > * { color: " + card + "; }\n"
    )


# omxplorer's skins (designs 3–5, D-149): the palette's tokens as CSS variables (set per page from the Mojo
# module), Inter for words, JetBrains Mono for figures, flat controls, a chrome band for the toolbar and bars.
# The same rules as the GTK skin (skin_css in gtk.mojo). The fonts are the app's own (/static/fonts, D-155).
comptime SKIN_WEB = """
@font-face { font-family: Inter; font-weight: 400; src: url(/static/fonts/Inter-Regular.ttf) format("truetype"); }
@font-face { font-family: Inter; font-weight: 500; src: url(/static/fonts/Inter-Medium.ttf) format("truetype"); }
@font-face { font-family: Inter; font-weight: 600; src: url(/static/fonts/Inter-SemiBold.ttf) format("truetype"); }
@font-face { font-family: "JetBrains Mono"; font-weight: 400; src: url(/static/fonts/JetBrainsMono-Regular.ttf) format("truetype"); }
@font-face { font-family: "JetBrains Mono"; font-weight: 700; src: url(/static/fonts/JetBrainsMono-Bold.ttf) format("truetype"); }
body.skin { background: var(--o-page); color: var(--o-ink2); --accent: var(--o-accent); --line: var(--o-line); --muted: var(--o-ink3);
  --surface: var(--o-raised); --danger: var(--o-bad); font: 13px/18px Inter, sans-serif; }
body.skin .num, body.skin .mono { font-family: "JetBrains Mono", monospace; font-variant-numeric: tabular-nums; }
body.skin .text { text-align: left; color: var(--o-ink2); }
body.skin .text.title, body.skin .text.headline { color: var(--o-ink); font-weight: 600; letter-spacing: -0.2px; }
body.skin .text.title { font-size: 20px; line-height: 26px; font-weight: 700; } body.skin .text.headline { font-size: 15px; line-height: 20px; }
body.skin .text.caption { font-size: 12px; line-height: 16px; color: var(--o-ink3); }
body.skin .text.tone-warn { color: var(--o-warn); } body.skin .text.tone-good { color: var(--o-good); }
body.skin .text.tone-strong { color: var(--o-ink); font-weight: 600; } body.skin .text.tone-accent { color: var(--o-accent); }
body.skin button { padding: 3px 14px; font-weight: 500; background: var(--o-card);
  color: var(--o-ink); border: 1px solid var(--o-strong); transition: background .12s; font-family: inherit; }
body.skin button:hover { filter: none; background: var(--o-raised); }
body.skin button:active { transform: none; background: var(--o-wash); }
body.skin button:focus-visible { outline: 2px solid var(--o-accent); outline-offset: 1px; }
body.skin button.prominent { background: var(--o-accent); border-color: transparent; color: var(--o-on-accent); font-weight: 600; }
body.skin button.prominent:hover { background: color-mix(in srgb, var(--o-accent) 86%, #000); }
body.skin button.destructive { background: var(--o-bad); border-color: transparent; color: #fff; font-weight: 600; }
body.skin button.subtle { background: transparent; border-color: transparent; color: var(--o-ink2); }
body.skin button.subtle:hover { background: var(--o-raised); color: var(--o-ink); }
body.skin button.token { padding: 0 1px; min-height: 0; border: 0; border-radius: 5px; background: transparent; color: var(--o-data); font-size: 15px; font-weight: 600;
  text-decoration: underline dotted color-mix(in srgb, var(--o-data) 55%, transparent); text-decoration-thickness: 1.5px; text-underline-offset: 3px; }
body.skin button.token:hover { background: color-mix(in srgb, var(--o-data) 12%, transparent); }
@keyframes token-lit { from { background: color-mix(in srgb, var(--o-data) 30%, transparent); } to { background: transparent; } }
body.skin button.token.lit { animation: token-lit 1.4s ease-out; }
body.skin label.picker.subtle:not(.tool):not(.icon-only) { padding: 3px 14px; min-height: 30px; border-radius: 6px; box-sizing: border-box; color: var(--o-ink2); }
body.skin label.picker.subtle:not(.tool):hover { background: var(--o-raised); color: var(--o-ink); }
body.skin button.icon-only { padding: 3px 6px; min-width: 30px; justify-content: center; }
body.skin label.picker:not(.tool):not(.subtle) { border: 1px solid var(--o-strong); border-radius: 6px; padding: 3px 14px; min-height: 30px; box-sizing: border-box; color: var(--o-ink); background: var(--o-card); }
body.skin label.picker.prominent:not(.tool):not(.subtle) { background: var(--o-accent); color: var(--o-on-accent); border-color: transparent; font-weight: 600; }
body.skin button.tool, body.skin label.picker.tool { color: var(--o-chrome-ink); }
body.skin button.tool:hover, body.skin label.picker.tool:hover { background: color-mix(in srgb, var(--o-chrome-ink) 8%, var(--o-chrome)); }
body.skin button.tool.on, body.skin button.icon-only.on { background: var(--o-wash); color: var(--o-accent); }
body.skin select, body.skin input[type=text], body.skin input[type=date], body.skin textarea {
  border: 1px solid var(--o-strong); background: var(--o-card); color: var(--o-ink); font: inherit; padding: 3px 8px; }
body.skin input[type=text]:focus, body.skin textarea:focus, body.skin select:focus { outline: none; border-color: var(--o-accent);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--o-accent) 18%, transparent); }
body.skin .vstack.card { background: var(--o-card); border-radius: 6px; padding: 12px 14px; box-sizing: border-box; box-shadow: inset 0 0 0 1px var(--o-line); }
body.skin .vstack.card.warn { background: color-mix(in srgb, var(--o-warn) 9%, var(--o-card)); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--o-warn) 35%, var(--o-card)); }
body.skin .vstack.card.good { background: color-mix(in srgb, var(--o-good) 8%, var(--o-card)); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--o-good) 30%, var(--o-card)); }
body.skin .island > * { background: var(--o-card); border-radius: 6px; padding: 6px 10px; min-height: 32px; align-items: center;
  box-shadow: inset 0 0 0 1px var(--o-line), var(--o-shadow); }
body.skin .board { background-color: var(--o-page); }
body.skin .board > .object::after { border-color: var(--o-strong); }
body.skin .canvas { background: transparent; }
body.skin hr { border-top-color: var(--o-line); }
body.skin input.cell-editor { border-radius: 0; border: 2px solid var(--o-accent); background: var(--o-card); min-height: 0; }
body.skin ::-webkit-scrollbar { width: 10px; height: 10px; } body.skin ::-webkit-scrollbar-thumb { background: var(--o-strong); border-radius: 5px; }
body.skin ::-webkit-scrollbar-track { background: transparent; }
body.skin .segmented, body.skin .tabs { background: transparent; padding: 0; gap: 0; border: 1px solid var(--o-line); border-radius: 6px; overflow: hidden; }
body.skin .segmented span, body.skin .tabs span { min-height: 26px; padding: 0 10px; border-radius: 0; font-weight: 400; color: var(--o-ink2); font-size: 12px; }
body.skin .segmented input:checked + span, body.skin .tabs input:checked + span { background: var(--o-accent); color: var(--o-on-accent); font-weight: 600; box-shadow: none; }
body.skin [data-tag=toolbar] .text, body.skin [data-tag=toolbar] button { color: var(--o-chrome-ink); }
body.skin [data-tag=toolbar] button.prominent, body.skin [data-tag=toolbar] button.prominent .text { color: var(--o-on-accent); }
body.skin [data-tag=sheet-tabs] .tabs { border: 0; border-radius: 0; }
body.skin [data-tag=sheet-tabs] .tabs input:checked + span { background: var(--o-card); color: var(--o-ink); box-shadow: inset 0 2px var(--o-accent); }
body.skin [data-tag=formula-bar] input[type=text] { font-family: "JetBrains Mono", monospace; font-size: 12.5px; }
body.skin label.toggle input, body.skin .radio input { accent-color: var(--o-accent); }
body.skin dialog.alert, body.skin .lazylist { background: var(--o-card); color: var(--o-ink); border-radius: 8px; }
body.skin .dialog, body.skin .popover { background: var(--o-card); color: var(--o-ink); }
body.skin .dialog-layer .scrim { background: color-mix(in srgb, var(--o-ink) 32%, transparent); }
body.skin .dialog-head { border-bottom-color: var(--o-line); } body.skin .dialog-head h3, body.skin .popover-title { color: var(--o-ink); }
body.skin .popover { box-shadow: var(--o-shadow), 0 0 0 1px var(--o-line); }
body.skin .toast { background: var(--o-ink); color: var(--o-card); } body.skin .toast .toast-close { color: var(--o-card); }
body.skin .toast-action { color: color-mix(in srgb, var(--o-accent) 55%, var(--o-card)); }
body.skin .menubar { background: var(--o-chrome); } body.skin .menu-title { color: var(--o-chrome-ink); border: 0; background: transparent; min-height: 0; padding: 4px 9px; box-shadow: none; }
body.skin .menu.open > .menu-title { background: color-mix(in srgb, var(--o-chrome-ink) 8%, var(--o-chrome)); }
body.skin .menu > .menu-items { background: var(--o-card); color: var(--o-ink); box-shadow: var(--o-shadow), 0 0 0 1px var(--o-line); }
body.skin .mi:hover:not([disabled]) { background: var(--o-wash); } body.skin .mi:hover:not([disabled]) svg { color: var(--o-accent); opacity: 1; }
body.skin .mi.danger, body.skin .mi.danger svg { color: var(--o-bad); } body.skin .mi .mi-key { color: var(--o-ink3); opacity: 1; }
body.skin .menu-label { color: var(--o-ink3); opacity: 1; } body.skin .menu-sep { border-top-color: var(--o-line); }
body.skin .hstack > hr { border-left-color: var(--o-line); }
"""


def bordered_css(p: Palette, cls: String, sheet: UInt32) -> String:
    """GTK: a 1 px hairline around the sheet (a Board's scroller) and every card on it (its objects), one soft shadow
    under a card, the sheet a tone of its own. The shells' roles (toolbar, status bar, sidebar, inspector) get theirs from
    the look (bordered_look)."""
    var w = "window." + cls + " "
    var line = hex_of(p.line)
    return (w + ".mui-board-scroll { border: 1px solid " + line + "; border-radius: 8px; background-color: " + hex_of(sheet) + "; }\n"
            + w + ".mui-board { background-color: transparent; }\n"
            + w + ".mui-board > * { border: 1px solid " + line + "; border-radius: 6px; }\n"
            + w + ".mui-board > .mui-card { box-shadow: 0 6px 18px rgba(0,0,0,.35); }\n"
            + w + ".mui-tag-inspector { box-shadow: none; border: 1px solid " + line + "; }\n")


def bordered_web(p: Palette, cls: String, sheet: UInt32) -> String:
    """The web's same rules (bordered_css), under body.<cls>."""
    var b = "body." + cls + " "
    var line = hex_of(p.line)
    return (b + ".board-scroll { border: 1px solid " + line + "; border-radius: 8px; background-color: " + hex_of(sheet) + "; box-sizing: border-box; }\n"
            + b + ".board { background-color: transparent; }\n"
            + b + ".board > .object:not([data-tag=cell-editor]) { border: 1px solid " + line + "; border-radius: 6px; box-shadow: 0 6px 18px rgba(0,0,0,.35); }\n"
            + b + ".board > .object > .vstack.card { box-shadow: none; border-radius: 5px; }\n"
            + b + "[data-tag=inspector] { box-shadow: none; border: 1px solid " + line + "; }\n")


def outlined(var s: Surface, line: UInt32) -> Surface:
    """A surface ringed by a 1 px hairline on every side (over its top or bottom line)."""
    s.outline = line
    s.outline_w = 1
    s.line_top = 0
    s.line_bottom = 0
    return s^


def bordered_look(p: Palette) -> Look:
    """skin_look with the shells' regions ringed: the toolbar, the status bar and the sidebar (a rail) in the chrome's
    fill with a hairline all round."""
    var look = skin_look(p)
    for k in range(len(look.surfaces)):
        if look.surfaces[k].role == "toolbar" or look.surfaces[k].role == "status-bar":
            look.surfaces[k] = outlined(look.surfaces[k].copy(), p.line)
    look.surfaces.append(outlined(band("sidebar", p.chrome, 0, 0), p.line))
    return look^


def skin_look(p: Palette) -> Look:
    """The skins' shapes as values: the chrome is a band (a fill and a hairline) across the window, figures in JetBrains
    Mono, square-ish 6 pt corners."""
    var status = band("status-bar", p.chrome, p.chrome_line, 0)
    status.font, status.font_size, status.ink = "JetBrains Mono", 12, p.ink3
    var surfaces: List[Surface] = [band("toolbar", p.chrome, 0, p.chrome_line), status^, band("sheet-tabs", p.chrome, 0, 0), band("formula-bar", p.card, 0, p.line),
                                   words("sentence-line", 15, 600, p.ink)]
    return Look(TypeScale("Inter", "JetBrains Mono", 13, 12, 15, 20, 11, False, 0), Controls(64, 58, 6, 11, 34, 10, 6, 12, 34, 6, 16, 6, 4, 30, 14, 8, 0, 0, 0, 0, 32), surfaces^,
                Segments(0, 6, 0, p.line, 26, 10, 4, 13, 400, p.ink2, p.accent, p.accent_ink, 600, False))  # (the sheets' toggle-group rules say the same: D-300)


def skin(id: String, pal: Palette) -> Theme:
    """A skin over its palette: `id` names its CSS class (window.<id> on GTK; body.skin.<id> on the web). Graphite is
    bordered (every region in a hairline)."""
    if id == "graphite":
        return bordered(id, pal, hx(SHEET))
    return Theme(id, "skin " + id, pal.copy(), skin_css(pal, id), String(SKIN_WEB), pal.ink2, pal.accent_ink, True, skin_look(pal))


def ledger() -> Theme:
    return skin("ledger", ledger_palette())


def ledger(pal: Palette) -> Theme:
    return skin("ledger", pal)


def bordered(id: String, pal: Palette, sheet: UInt32) -> Theme:
    """A skin with every region in a hairline (bordered_css, bordered_web, bordered_look) and the sheet in `sheet`."""
    return Theme(id, "skin " + id, pal.copy(), skin_css(pal, id) + bordered_css(pal, id, sheet), String(SKIN_WEB) + bordered_web(pal, id, sheet),
                 pal.ink2, pal.accent_ink, True, bordered_look(pal))


def graphite() -> Theme:
    return bordered("graphite", graphite_palette(), hx(SHEET))


def graphite(pal: Palette) -> Theme:
    return bordered("graphite", pal, hx(SHEET))


def blueprint() -> Theme:
    return skin("blueprint", blueprint_palette())


def blueprint(pal: Palette) -> Theme:
    return skin("blueprint", pal)
