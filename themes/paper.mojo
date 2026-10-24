# Paper: the smallest complete mojoui theme, and the one to copy when you write your own (D-260). Warm paper, black
# ink, one terracotta accent, hairlines instead of shadows. Nothing in mojoui/ knows it exists: an app picks it with
#
#   def theme(self) -> Theme: return paper()
#
# A theme is four things: a palette (drawn views: grids, charts), CSS classes for the window or page, a GTK style
# sheet (rules under `window.<class>`, over libadwaita) and a web style sheet (rules under `body.<class>`, reading the
# palette's --o-* variables, which the web host sets from the palette).

from mojoui.canvas import rgba
from mojoui.text import REGULAR, MEDIUM
from mojoui.theme import Palette, Theme, hx, mix, hex_of
from mojoui.theme import Look


def paper_palette() -> Palette:
    var p = Palette(False, hx("#f4efe6"), hx("#fffcf6"), hx("#f8f3ea"), hx("#1d1a16"), hx("#46403a"), hx("#6f675d"),
                   hx("#e6dccd"), hx("#cfc3b1"), hx("#a8461f"), hx("#fffcf6"), mix(hx("#fffcf6"), hx("#a8461f"), 0.40), hx("#f6e6dc"),
                   hx("#5b4a9e"), hx("#2f7d4f"), hx("#b3261e"), hx("#a36a00"), REGULAR, MEDIUM)
    p.series = [hx("#a8461f"), hx("#3f6f8f"), hx("#c49a3c"), hx("#5e7d4a"), hx("#7d5a8c"), hx("#b7745a"), hx("#6d6a63"), hx("#3d8a80")]  # (inks, not neons)
    return p^


def paper_gtk(p: Palette) -> String:
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
    return (
        ":root { --accent-bg-color: " + accent + "; --accent-color: " + accent + "; --accent-fg-color: " + card + "; }\n"
        + "window.paper { background-color: " + page + "; color: " + ink2 + "; font-family: Inter, sans-serif; font-size: 14px; }\n"
        + "window.paper label.title-1 { color: " + ink + "; font-size: 26px; font-weight: 600; letter-spacing: -0.02em; }\n"
        + "window.paper label.title-4 { color: " + ink + "; font-size: 15px; font-weight: 600; }\n"
        + "window.paper label.caption { color: " + ink3 + "; font-size: 12px; }\n"
        + "window.paper label.mui-tone-accent { color: " + accent + "; } window.paper label.mui-tone-good { color: " + hex_of(p.good) + "; }\n"
        + "window.paper label.mui-tone-warn { color: " + hex_of(p.warn) + "; } window.paper label.mui-tone-strong { color: " + ink + "; font-weight: 600; }\n"
        + "window.paper .mui-card { background-color: " + card + "; border-radius: 6px; padding: 14px 16px; box-shadow: inset 0 0 0 1px " + line + "; }\n"
        + "window.paper .mui-card.mui-warn { background-color: " + hex_of(mix(p.card, p.warn, 0.08)) + "; }\n"
        + "window.paper .mui-card.mui-good { background-color: " + hex_of(mix(p.card, p.good, 0.08)) + "; }\n"
        + "window.paper button { border-radius: 4px; min-height: 32px; padding: 2px 14px; font-weight: 500; background: " + card + "; color: " + ink + "; box-shadow: inset 0 0 0 1px " + strong + "; transition: background 150ms ease-out; }\n"
        + "window.paper button:hover { background: " + raised + "; }\n"
        + "window.paper button:active { background: " + wash + "; }\n"
        + "window.paper button.suggested-action { background: " + accent + "; color: " + card + "; box-shadow: none; }\n"
        + "window.paper button.suggested-action:hover { background: " + hex_of(mix(p.accent, p.ink, 0.15)) + "; }\n"
        + "window.paper button.flat { background: transparent; box-shadow: none; color: " + ink2 + "; }\n"
        + "window.paper button.flat:hover { background: " + raised + "; color: " + ink + "; }\n"
        + "window.paper entry, window.paper dropdown > button { border-radius: 4px; background: " + card + "; color: " + ink + "; box-shadow: inset 0 0 0 1px " + strong + "; }\n"
        + "window.paper entry:focus-within { box-shadow: inset 0 0 0 2px " + accent + "; outline: none; }\n"
        + "window.paper switch:checked, window.paper checkbutton check:checked { background-color: " + accent + "; }\n"
        + "window.paper togglebutton:checked, window.paper button.toggle:checked { background: " + ink + "; color: " + card + "; }\n"
        + "window.paper progressbar progress { background-color: " + accent + "; }\n"
        + "window.paper separator { background-color: " + line + "; }\n"
    )


comptime PAPER_WEB = """
body.paper { background: var(--o-page); color: var(--o-ink2); --accent: var(--o-accent); --line: var(--o-line); --muted: var(--o-ink3);
  --surface: var(--o-raised); --danger: var(--o-bad); font: 14px/20px Inter, sans-serif; }
body.paper .text.title { color: var(--o-ink); font-size: 26px; line-height: 32px; font-weight: 600; letter-spacing: -0.02em; }
body.paper .text.headline { color: var(--o-ink); font-size: 15px; font-weight: 600; }
body.paper .text.caption { color: var(--o-ink3); font-size: 12px; }
body.paper .text.tone-accent { color: var(--o-accent); } body.paper .text.tone-good { color: var(--o-good); }
body.paper .text.tone-warn { color: var(--o-warn); } body.paper .text.tone-strong { color: var(--o-ink); font-weight: 600; }
body.paper .card { background: var(--o-card); border-radius: 6px; box-shadow: inset 0 0 0 1px var(--o-line); border: 0; }
body.paper button { border-radius: 4px; min-height: 32px; padding: 2px 14px; font-weight: 500; background: var(--o-card); color: var(--o-ink);
  border: 1px solid var(--o-strong); transition: background 150ms ease-out; font-family: inherit; }
body.paper button:hover { background: var(--o-raised); filter: none; }
body.paper button:active { background: var(--o-wash); transform: none; }
body.paper button.prominent { background: var(--o-accent); color: var(--o-card); border-color: transparent; }
body.paper button.subtle { background: transparent; border-color: transparent; color: var(--o-ink2); }
body.paper input[type=text], body.paper select { border-radius: 4px; border: 1px solid var(--o-strong); background: var(--o-card); color: var(--o-ink); min-height: 32px; }
body.paper input[type=text]:focus { outline: 2px solid var(--o-accent); outline-offset: -1px; }
body.paper .segmented { background: var(--o-raised); border-radius: 6px; }
body.paper .segmented input:checked + span { background: var(--o-ink); color: var(--o-card); }
body.paper progress { accent-color: var(--o-accent); }
"""


def paper() -> Theme:
    var pal = paper_palette()
    return Theme("paper", "paper", pal.copy(), paper_gtk(pal), String(PAPER_WEB), pal.ink2, pal.card, False, Look.none())
