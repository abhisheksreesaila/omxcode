# mojoui.boardlook: how a Board's children stand while something is shown about the page (goal 41 M8), and the small
# floating pieces of the link UI (mojoui.linkdrag, mojoui.peek), written from any theme's palette so every app gets them.
#
#   Board(items, w, h, tones=[BOARD_DIM, BOARD_LIFT, …])     a child's tone: dimmed (grey, a little smaller, never
#                                                            blurred), lifted (accent ring, one soft shadow), held, a
#                                                            drop target; hosts ease between them (a spring when it
#                                                            opens, a quick fade when it settles back)
#   Text("shipment_id", CAPTION).tag("link-ghost")           the column being dragged, at the pointer
#   VStack(…).tag("link-confirm")                            the "Link these?" panel beside the drop target
#   Text("shipment_id = code", CAPTION).tag("peek-label")    a ghost line's label pill
#
# GTK reads board_gtk_css (classes mui-tone-dim … on the child's widget, mui-tag-<role> on tagged views), the web
# board_web_css (data-tone on the Board object, data-tag on tagged views). omxqua: opaque tonal surfaces, one soft
# shadow, the one accent; no glass, no blur.

from mojoui.look import css_color
from mojoui.theme import Palette

comptime SPRING_DEFAULT = "cubic-bezier(0.22, 1, 0.36, 1)"  # (Liquid's spring: a calm ease-out that settles, no bounce; a theme's Look.motion.ease wins)


def _shade(p: Palette, alpha: Float64) -> String:
    """A shadow's colour from the palette's mode: as asked on a dark page, about a third of it on a light one (one soft
    shadow, omxqua; Liquid's light mode stays airy)."""
    var a = alpha if p.dark else alpha * 0.35
    return "rgba(0,0,0," + String(Float64(Int(a * 100.0 + 0.5)) / 100.0) + ")"


def _a(c: UInt32, alpha: Float64) -> UInt32:
    return (c & 0x00FFFFFF) | (UInt32(Int(alpha * 255.0 + 0.5)) << 24)


def board_gtk_css(p: Palette, scope: String, ease: String = "") -> String:
    """GTK's rules; `ease`: the theme's own curve (Look.motion.ease), else SPRING."""
    var SPRING = ease if ease != "" else String(SPRING_DEFAULT)
    var ac = css_color(p.accent)
    var line = css_color(p.line)
    var raised = css_color(p.raised)
    var ink = css_color(p.ink)
    var ink3 = css_color(p.ink3)
    var out = String("")
    out += scope + ".mui-board > * { transition: opacity 200ms ease, filter 200ms ease, transform 220ms ease, box-shadow 220ms ease; }\n"
    out += (scope + ".mui-board > .mui-tone-dim { opacity: 0.42; filter: grayscale(0.75); transform: scale(0.97); "
            + "transition: opacity 280ms ease, filter 280ms ease, transform 420ms " + SPRING + "; }\n")
    out += (scope + ".mui-board > .mui-tone-lift { box-shadow: 0 0 0 1px " + css_color(_a(p.accent, 0.55)) + ", 0 12px 30px " + _shade(p, 0.5) + "; "
            + "transform: scale(1.015); transition: transform 420ms " + SPRING + ", box-shadow 300ms ease; }\n")
    out += (scope + ".mui-board > .mui-tone-source { box-shadow: 0 0 0 2px " + ac + ", 0 16px 40px " + _shade(p, 0.6) + "; "
            + "transform: scale(1.03); transition: transform 420ms " + SPRING + ", box-shadow 300ms ease; }\n")
    out += scope + ".mui-board > .mui-tone-target { box-shadow: 0 0 0 2px " + ac + ", 0 6px 18px " + _shade(p, 0.35) + "; }\n"
    # the link UI's floating pieces
    out += (scope + ".mui-tag-link-ghost { background: " + raised + "; color: " + ac + "; font-weight: 600; font-size: 11px; "
            + "padding: 4px 9px; border-radius: 7px; box-shadow: inset 0 0 0 1px " + ac + ", 0 8px 20px " + _shade(p, 0.5) + "; }\n")
    out += (scope + ".mui-tag-link-confirm, " + scope + ".mui-tag-link-columns { background: " + raised + "; border-radius: 11px; padding: 11px 12px; "
            + "box-shadow: inset 0 0 0 1px " + line + ", 0 12px 30px " + _shade(p, 0.5) + "; }\n")
    out += scope + ".mui-tag-link-columns { border-radius: 9px; padding: 7px 9px; }\n"
    out += (scope + ".mui-tag-link-end { background: " + css_color(p.card) + "; color: " + ink + "; border-radius: 6px; padding: 2px 7px; "
            + "box-shadow: inset 0 0 0 1px " + line + "; font-size: 11.5px; }\n")
    out += scope + ".mui-tag-link-meter trough { min-height: 5px; border-radius: 3px; background: " + css_color(p.line) + "; }\n"
    out += scope + ".mui-tag-link-meter progress { min-height: 5px; border-radius: 3px; background: " + ac + "; }\n"
    out += (scope + ".mui-tag-peek-label { background: " + raised + "; color: " + ink + "; font-weight: 600; font-size: 10.5px; padding: 2px 8px; "
            + "border-radius: 7px; box-shadow: inset 0 0 0 1px " + css_color(_a(p.accent, 0.6)) + "; animation: mui-peek-arrive 300ms " + SPRING + "; }\n")
    out += "@keyframes mui-peek-arrive { from { opacity: 0; transform: scale(0.85); } to { opacity: 1; transform: none; } }\n"
    out += (scope + ".mui-tag-link-kind { color: " + ink3 + "; font-size: 10px; border-radius: 5px; padding: 0 5px; box-shadow: inset 0 0 0 1px "
            + line + "; }\n")
    out += (scope + ".mui-tag-link-row { background: " + css_color(p.card) + "; border-radius: 8px; padding: 7px 8px; box-shadow: inset 0 0 0 1px "
            + line + "; }\n")
    out += scope + ".mui-tag-link-suggested { box-shadow: none; border: 1px dashed " + line + "; }\n"
    return out^


def board_web_css(p: Palette, scope: String, ease: String = "") -> String:
    """The web's rules; `ease`: the theme's own curve (Look.motion.spring), else SPRING."""
    var SPRING = ease if ease != "" else String(SPRING_DEFAULT)
    var ac = css_color(p.accent)
    var line = css_color(p.line)
    var raised = css_color(p.raised)
    var ink = css_color(p.ink)
    var ink3 = css_color(p.ink3)
    var out = String("")
    out += scope + ".board > .object { transition: opacity .2s ease, filter .2s ease, transform .22s ease, box-shadow .22s ease; }\n"
    out += (scope + ".board > .object[data-tone='1'] { opacity: .42; filter: grayscale(.75); transform: scale(.97); "
            + "transition: opacity .28s ease, filter .28s ease, transform .42s " + SPRING + "; }\n")
    out += (scope + ".board > .object[data-tone='2'] { z-index: 6; box-shadow: 0 0 0 1px " + css_color(_a(p.accent, 0.55))
            + ", 0 12px 30px " + _shade(p, .5) + "; transform: scale(1.015); transition: transform .42s " + SPRING + ", box-shadow .3s; }\n")
    out += (scope + ".board > .object[data-tone='3'] { z-index: 7; box-shadow: 0 0 0 2px " + ac + ", 0 16px 40px " + _shade(p, .6) + "; "
            + "transform: scale(1.03); transition: transform .42s " + SPRING + ", box-shadow .3s; }\n")
    out += scope + ".board > .object[data-tone='4'] { box-shadow: 0 0 0 2px " + ac + ", 0 6px 18px " + _shade(p, .35) + "; }\n"
    out += scope + ".board > .object[data-tag^=link-], " + scope + ".board > .object[data-tag^=peek-] { z-index: 8; overflow: visible; }\n"
    out += scope + ".board > .object[data-tag^=link-]::after, " + scope + ".board > .object[data-tag^=peek-]::after { display: none; }\n"
    out += scope + ".board > .object[data-tag=peek-lines] { z-index: 5; pointer-events: none; }\n"
    out += (scope + ":not(.object)[data-tag=link-ghost] { background: " + raised + "; color: " + ac + "; font-weight: 600; font-size: 11px; padding: 4px 9px; "
            + "border-radius: 7px; box-shadow: inset 0 0 0 1px " + ac + ", 0 8px 20px " + _shade(p, .5) + "; pointer-events: none; }\n")
    out += (scope + ":not(.object)[data-tag=link-confirm], " + scope + ":not(.object)[data-tag=link-columns] { background: " + raised + "; border-radius: 11px; padding: 11px 12px; "
            + "box-shadow: inset 0 0 0 1px " + line + ", 0 12px 30px " + _shade(p, .5) + "; box-sizing: border-box; }\n")
    out += scope + ":not(.object)[data-tag=link-columns] { border-radius: 9px; padding: 7px 9px; }\n"
    out += (scope + ":not(.object)[data-tag=link-end] { background: " + css_color(p.card) + "; color: " + ink + "; border-radius: 6px; padding: 2px 7px; "
            + "box-shadow: inset 0 0 0 1px " + line + "; font-size: 11.5px; }\n")
    out += scope + ":not(.object)[data-tag=link-meter] { accent-color: " + ac + "; height: 5px; }\n"
    out += (scope + ":not(.object)[data-tag=peek-label] { background: " + raised + "; color: " + ink + "; font-weight: 600; font-size: 10.5px; padding: 2px 8px; "
            + "border-radius: 7px; box-shadow: inset 0 0 0 1px " + css_color(_a(p.accent, 0.6)) + "; white-space: nowrap; animation: mui-peek-arrive .3s "
            + SPRING + "; pointer-events: none; }\n")
    out += "@keyframes mui-peek-arrive { from { opacity: 0; transform: scale(.85); } to { opacity: 1; transform: none; } }\n"
    out += (scope + ":not(.object)[data-tag=link-kind] { color: " + ink3 + "; font-size: 10px; border-radius: 5px; padding: 0 5px; box-shadow: inset 0 0 0 1px "
            + line + "; }\n")
    out += (scope + ":not(.object)[data-tag=link-row] { background: " + css_color(p.card) + "; border-radius: 8px; padding: 7px 8px; box-shadow: inset 0 0 0 1px "
            + line + "; box-sizing: border-box; }\n")
    out += scope + ":not(.object)[data-tag=link-suggested] { box-shadow: none; border: 1px dashed " + line + "; }\n"
    out += "@media (prefers-reduced-motion: reduce) { " + scope + ".board > .object { transition: none !important; } }\n"
    return out^
