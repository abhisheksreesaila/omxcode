# Omarchy as a mojoui theme: the person's current Omarchy colours (~/.local/state/omarchy/current/theme/colors.toml,
# Tokyo Night when there's none), JetBrains Mono, flat controls with hairline borders.
#
#   def theme(self) -> Theme: return omarchy()

from mojoui.canvas import rgba
from mojoui.text import MONO, MONO_BOLD
from mojoui.shared import environment
from mojoui.theme import Palette, Theme, hex_rgba, mix, hex_of, luminance
from mojoui.theme import Look, TypeScale, Controls, Segments
from std.sys import CompilationTarget

comptime OMARCHY_COLORS = "/.local/state/omarchy/current/theme/colors.toml"


def lookup(keys: List[String], vals: List[String], name: String, fallback: String) -> UInt32:
    for i in range(len(keys)):
        if keys[i] == name:
            return hex_rgba(vals[i], hex_rgba(fallback, 0))
    return hex_rgba(fallback, 0)


def derived(keys: List[String], vals: List[String], name: String, otherwise: UInt32) -> UInt32:
    """The theme's colour for `name`, or `otherwise` (derived from its background and foreground)."""
    for i in range(len(keys)):
        if keys[i] == name:
            return hex_rgba(vals[i], otherwise)
    return otherwise


def _read_omarchy(mut keys: List[String], mut vals: List[String]):
    """Reads ~/.local/state/omarchy/current/theme/colors.toml as key=value lines (Linux only: the iPad and Mac hosts
    never see an Omarchy theme, and file IO doesn't compile for their targets)."""
    comptime if CompilationTarget.is_linux():
        try:
            with open(environment("HOME", ".") + OMARCHY_COLORS, "r") as f:
                for line in f.read().split("\n"):
                    var text = String(line.strip())
                    var eq = text.find("=")
                    if text.startswith("#") or eq < 0:
                        continue
                    # the value: a quoted string, or the first word (either way a trailing # comment is dropped)
                    var value = String(String(text[byte=eq + 1:]).strip())
                    if value.startswith('"') or value.startswith("'"):
                        var quote = String(value[byte=0:1])
                        var end = value.find(quote, 1)
                        var inner = String(value[byte=1:end]) if end > 0 else String(value[byte=1:])
                        value = inner
                    else:
                        var space = value.find(" ")
                        if space > 0:
                            var word = String(value[byte=0:space])
                            value = word
                    keys.append(String(String(text[byte=0:eq]).strip()))
                    vals.append(value)
        except:
            pass


def omarchy_palette() -> Palette:
    """The current Omarchy theme's colours (Tokyo Night if the file isn't there)."""
    var keys = List[String]()
    var vals = List[String]()
    _read_omarchy(keys, vals)

    # Missing keys are derived from the two every theme has (background, foreground), so a partial theme
    # still reads well; light or dark comes from `mode`, else from how bright the background is.
    var bg = lookup(keys, vals, "background", "#1a1b26")
    var fg = lookup(keys, vals, "foreground", "#a9b1d6")
    var dark = luminance(bg) < 0.5
    for i in range(len(keys)):
        if keys[i] == "mode":
            dark = vals[i] != "light"
    var toward = rgba(0, 0, 0) if dark else rgba(255, 255, 255)
    var away = rgba(255, 255, 255) if dark else rgba(0, 0, 0)
    var page = derived(keys, vals, "dark_background", mix(bg, toward, 0.25))
    var raised = derived(keys, vals, "lighter_background", mix(bg, fg, 0.08))
    var ink = derived(keys, vals, "bright_foreground", mix(fg, away, 0.25))
    # no theme file at all: Tokyo Night's own blue (a partial file still derives its accent from its colours)
    var fallback_accent = rgba(122, 162, 247) if len(keys) == 0 else mix(fg, rgba(64, 128, 255), 0.6)
    var accent = derived(keys, vals, "accent", derived(keys, vals, "blue", fallback_accent))
    var quiet = mix(derived(keys, vals, "dark_foreground", mix(fg, bg, 0.45)), fg, 0.5)  # captions: ≥ 4.5:1 on the card
    return Palette(dark, page, bg, raised, ink, fg, quiet, mix(bg, fg, 0.10), mix(bg, fg, 0.22),
                   accent, bg, mix(bg, accent, 0.35), mix(bg, accent, 0.16), derived(keys, vals, "magenta", mix(fg, rgba(173, 142, 230), 0.6)),
                   derived(keys, vals, "green", rgba(158, 206, 106)), derived(keys, vals, "red", rgba(247, 118, 142)),
                   derived(keys, vals, "orange", derived(keys, vals, "yellow", rgba(255, 158, 100))), MONO, MONO_BOLD)


def omarchy_css(p: Palette) -> String:
    """The Omarchy skin for GTK, from the person's theme colours: flat, hairline borders, JetBrains Mono."""
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
    return (
        ":root { --accent-bg-color: " + accent + "; --accent-color: " + accent + "; --accent-fg-color: " + on_accent + "; }\n"
        + "window.omarchy { background-color: " + page + "; color: " + ink2 + "; font-family: 'JetBrainsMono Nerd Font', 'JetBrains Mono', monospace; font-size: 13px; }\n"
        + "window.omarchy label { color: " + ink2 + "; }\n"
        + "window.omarchy label.title-1, window.omarchy label.title-4 { color: " + ink + "; font-weight: 700; }\n"
        + "window.omarchy label.title-1 { font-size: 18px; } window.omarchy label.title-4 { font-size: 13px; }\n"
        + "window.omarchy label.caption { font-size: 11px; color: " + ink3 + "; }\n"
        + "window.omarchy .dim-label { opacity: 1; }\n"
        + "window.omarchy .mui-card { background-color: " + card + "; border-radius: 4px; padding: 12px 14px; box-shadow: inset 0 0 0 1px " + line + "; }\n"
        + "window.omarchy label.mui-tone-warn { color: " + hex_of(p.warn) + "; } window.omarchy label.mui-tone-good { color: " + hex_of(p.good) + "; }\n"
        + "window.omarchy label.mui-tone-strong { color: " + ink + "; font-weight: 700; } window.omarchy label.mui-tone-accent { color: " + accent + "; }\n"
        + "window.omarchy .mui-card.mui-warn { background-color: " + hex_of(mix(p.card, p.warn, 0.12)) + "; box-shadow: inset 0 0 0 1px " + hex_of(mix(p.card, p.warn, 0.55)) + "; }\n"
        + "window.omarchy .mui-card.mui-good { background-color: " + hex_of(mix(p.card, p.good, 0.10)) + "; box-shadow: inset 0 0 0 1px " + hex_of(mix(p.card, p.good, 0.50)) + "; }\n"
        + "window.omarchy .mui-island { background-color: " + card + "; border-radius: 4px; padding: 6px 10px; min-height: 32px; box-shadow: inset 0 0 0 1px " + strong + ", 0 6px 18px rgba(0,0,0,.35); }\n"
        + "window.omarchy .mui-board { background-color: " + page + "; background-image: radial-gradient(circle, " + line + " 1px, transparent 1.5px); background-size: 24px 24px; }\n"
        + "window.omarchy button { border-radius: 3px; min-height: 28px; padding: 2px 10px; font-weight: 500; background: transparent; color: " + ink + "; box-shadow: inset 0 0 0 1px " + strong + "; }\n"
        + "window.omarchy button:hover { background: " + raised + "; }\n"
        + "window.omarchy button:active { background: " + wash + "; }\n"
        + "window.omarchy button.flat { box-shadow: none; color: " + ink2 + "; }\n"
        + "window.omarchy button.flat:hover { background: " + raised + "; color: " + ink + "; }\n"
        + "window.omarchy button.image-button { min-width: 28px; padding: 2px 6px; }\n"
        + "window.omarchy button label, window.omarchy button image { color: inherit; }\n"
        + "window.omarchy button.suggested-action { background: " + accent + "; color: " + on_accent + "; box-shadow: none; font-weight: 700; }\n"
        + "window.omarchy button.suggested-action:hover { background: " + hex_of(mix(p.accent, p.ink, 0.2)) + "; }\n"
        + "window.omarchy entry, window.omarchy textview, window.omarchy dropdown > button { border-radius: 3px; background: " + page + "; color: " + ink + "; box-shadow: inset 0 0 0 1px " + strong + "; }\n"
        + "window.omarchy entry:focus-within { box-shadow: inset 0 0 0 1px " + accent + "; outline: none; }\n"
        + "window.omarchy textview text { background: " + page + "; color: " + ink + "; }\n"
        + "window.omarchy dropdown > button { min-height: 28px; padding: 2px 8px; }\n"
        + "window.omarchy popover > contents { background: " + card + "; color: " + ink + "; box-shadow: inset 0 0 0 1px " + strong + "; }\n"
        + "window.omarchy scrollbar slider { min-width: 6px; min-height: 6px; background-color: " + strong + "; border-radius: 3px; }\n"
        + "window.omarchy entry.mui-cell-editor { border-radius: 0; box-shadow: inset 0 0 0 2px " + accent + "; background: " + card + "; }\n"
        + "window.omarchy button.mui-tool { min-width: 58px; min-height: 48px; padding: 4px 6px; border-radius: 6px; }\n"
        + "window.omarchy button.mui-tool-on { background: " + raised + "; color: " + accent + "; }\n"
        + "window.omarchy label.mui-tool-label { font-size: 11px; }\n"
    )


# Omarchy (design 2): the person's Omarchy theme (variables set per page from the Mojo palette),
# JetBrains Mono, flat controls with hairline borders; the same rules as the GTK skin.
comptime OMARCHY_WEB = """
body.omarchy { background: var(--o-page); color: var(--o-ink2); --accent: var(--o-accent); --line: var(--o-line); --muted: var(--o-ink3);
  --surface: var(--o-raised); --danger: var(--o-bad);
  font: 13px/18px "JetBrainsMono Nerd Font", "JetBrains Mono", ui-monospace, monospace; }
body.omarchy .text { text-align: left; color: var(--o-ink2); }
body.omarchy .text.title, body.omarchy .text.headline { color: var(--o-ink); font-weight: 700; letter-spacing: 0; }
body.omarchy .text.title { font-size: 18px; line-height: 24px; } body.omarchy .text.headline { font-size: 13px; line-height: 18px; }
body.omarchy .text.caption { font-size: 11px; line-height: 15px; color: var(--o-ink3); }
body.omarchy button { border-radius: 3px; min-height: 28px; padding: 3px 10px; font-weight: 500; background: transparent;
  color: var(--o-ink); border: 1px solid var(--o-strong); transition: background .1s; }
body.omarchy button:hover { filter: none; background: var(--o-raised); }
body.omarchy button:active { transform: none; background: var(--o-wash); }
body.omarchy button.prominent { background: var(--o-accent); border-color: transparent; color: var(--o-on-accent); font-weight: 700; }
body.omarchy button.subtle { border-color: transparent; color: var(--o-ink2); }
body.omarchy button.subtle:hover { background: var(--o-raised); color: var(--o-ink); }
body.omarchy button.icon-only { padding: 3px 5px; min-width: 28px; justify-content: center; }
body.omarchy label.picker:not(.tool):not(.subtle) { border: 1px solid var(--o-strong); border-radius: 3px; padding: 3px 10px; min-height: 28px; box-sizing: border-box; color: var(--o-ink); }
body.omarchy label.picker.prominent { background: var(--o-accent); color: var(--o-on-accent); border-color: transparent; font-weight: 700; }
body.omarchy button.tool { border-radius: 6px; } body.omarchy button.tool.on, body.omarchy button.icon-only.on { background: var(--o-raised); color: var(--o-accent); }
body.omarchy select, body.omarchy input[type=text], body.omarchy input[type=date], body.omarchy textarea { border-radius: 3px; min-height: 28px;
  border: 1px solid var(--o-strong); background: var(--o-page); color: var(--o-ink); font: inherit; }
body.omarchy select { padding: 2px 4px; }
body.omarchy input[type=text]:focus, body.omarchy textarea:focus, body.omarchy select:focus { outline: none; border-color: var(--o-accent); }
body.omarchy .vstack.card { background: var(--o-card); border-radius: 4px; padding: 12px 14px; box-sizing: border-box; box-shadow: inset 0 0 0 1px var(--o-line); }
body.omarchy .text.tone-warn { color: var(--o-warn); } body.omarchy .text.tone-good { color: var(--o-good); }
body.omarchy .text.tone-strong { color: var(--o-ink); font-weight: 700; } body.omarchy .text.tone-accent { color: var(--o-accent); }
body.fluent .text.tone-warn { color: #EA580C; } body.fluent .text.tone-good { color: #0F766E; }
body.fluent .text.tone-strong { font-weight: 700; } body.fluent .text.tone-accent { color: #0F6CBD; }
body.omarchy .vstack.card.warn { background: color-mix(in srgb, var(--o-warn) 12%, var(--o-card)); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--o-warn) 55%, var(--o-card)); }
body.omarchy .vstack.card.good { background: color-mix(in srgb, var(--o-good) 10%, var(--o-card)); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--o-good) 50%, var(--o-card)); }
body.fluent .vstack.card.warn { background: #FFF7ED; box-shadow: inset 0 0 0 1px #FED7AA; }
body.fluent .vstack.card.good { background: #F0FDF4; box-shadow: inset 0 0 0 1px #BBF7D0; }
body.omarchy .island > * { background: var(--o-card); border-radius: 4px; padding: 6px 10px; min-height: 32px; align-items: center;
  box-shadow: inset 0 0 0 1px var(--o-strong), 0 6px 18px rgba(0,0,0,.35); }
body.omarchy .board { background-color: var(--o-page); background-image: radial-gradient(circle, var(--o-line) 1px, transparent 1.5px);
  background-size: 24px 24px; }
body.omarchy .board > .object::after { border-color: var(--o-strong); }
body.omarchy .canvas { background: transparent; }
body.omarchy hr { border-top-color: var(--o-line); }
body.omarchy input.cell-editor, body.fluent input.cell-editor { border-radius: 0; border: 2px solid var(--o-accent); background: var(--o-card); min-height: 0; }
body.omarchy ::-webkit-scrollbar { width: 10px; height: 10px; } body.omarchy ::-webkit-scrollbar-thumb { background: var(--o-strong); border-radius: 5px; }
body.omarchy ::-webkit-scrollbar-track { background: transparent; }
body.omarchy .hstack > hr { border-left-color: var(--o-line); }
"""


def omarchy() -> Theme:
    var pal = omarchy_palette()
    return Theme("omarchy", "omarchy", pal.copy(), omarchy_css(pal), String(OMARCHY_WEB), pal.ink2, pal.accent_ink, False, omarchy_look())


def omarchy_look() -> Look:
    """Omarchy's type as values (JetBrains Mono throughout, 13 / 11 / 13 / 18); its chrome is flat (no surfaces of
    its own), so GTK and the web write no rules from it yet."""
    return Look(TypeScale("JetBrains Mono", "JetBrains Mono", 13, 11, 13, 18, 11), Controls(0, 0, 0, 11, 0, 0, 0, 12, 0, 0, 16, 0, 0, 0, 0, 0), [], Segments.none())
