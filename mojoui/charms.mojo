# mojoui.charms: small drawings that hang on a card for an occasion (goal 77 M7e): a school bag that swings, a pennant that
# flaps ("GO!"), a party hat, an umbrella, a luggage tag ("LIS") that swings, a turkey peeking over the edge, and a pin.
# Drawn in code (mojoui.vector, after the owner-approved Stage prototype's SVGs, docs/goals/77/stage-prototype.html CHARMS),
# every colour taken from the theme's Palette, so a charm sits in any theme, light or night.
#
#   charm_names() -> the six occasion charms (and "pin": a pinned card's)
#   charm_box(name) -> CharmBox   its size in points and where it hangs from a card's top-right corner (the prototype's CSS)
#   draw_charm(surface, name, x, y, scale, palette, font, t_ms=0, still=False, alpha=1)
#       x, y: the card's top-right corner in pixels; scale: pixels per point; t_ms: a clock for the swing and the flap;
#       still (reduced motion): at rest. False for an unknown name.
#   charm_moves(name) -> True for the ones that swing or flap (a canvas keeps asking for frames while one shows)

from std.math import cos, sin, pi
from mojoui.canvas import Surface
from mojoui.draw import with_alpha
from mojoui.text import Font, MEDIUM, CENTRE
from mojoui.theme import Palette, mix
from mojoui.vector import Vector, parse_svg, draw_vector

comptime _BAG = (
    "<svg viewBox='0 0 58 84'><path d='M29 0 V12' stroke='@0' stroke-width='2' fill='none'/>"
    "<path d='M19 22 Q19 8 29 8 Q39 8 39 22' fill='none' stroke='@1' stroke-width='5'/>"
    "<rect x='6' y='18' width='46' height='62' rx='14' fill='@2'/><rect x='12' y='46' width='34' height='26' rx='8' fill='@3'/>"
    "<path d='M14 46 h30' stroke='@4' stroke-width='2' fill='none'/>"
    "<rect x='40' y='6' width='6' height='26' rx='2' fill='@5' transform='rotate(14 43 19)'/>"
    "<path d='M41 4 l3 -4 3 4z' fill='@6' transform='rotate(14 43 19)'/><circle cx='20' cy='30' r='3' fill='@7'/></svg>"
)
comptime _PENNANT = (
    "<svg viewBox='0 0 82 50'><rect x='0' y='0' width='4' height='50' rx='2' fill='@0'/><path d='M4 4 L80 18 L4 34Z' fill='@1'/>"
    "<path d='M4 4 L80 18 L4 12Z' fill='@2'/></svg>"
)
comptime _HAT = (
    "<svg viewBox='0 0 48 58'><path d='M24 4 L44 54 H4Z' fill='@0'/><path d='M14 30 L34 30 M10 42 L38 42' stroke='@1' stroke-width='5' fill='none'/>"
    "<circle cx='24' cy='5' r='6' fill='@2'/><rect x='2' y='52' width='44' height='6' rx='3' fill='@3'/></svg>"
)
comptime _UMBRELLA = (
    "<svg viewBox='0 0 62 62'><path d='M4 28 Q31 -6 58 28 Q51 22 44 28 Q38 22 31 28 Q24 22 18 28 Q11 22 4 28Z' fill='@0'/>"
    "<path d='M31 28 V52 Q31 58 25 58 Q20 58 20 53' fill='none' stroke='@1' stroke-width='3'/>"
    "<path d='M10 38 l-2 6 M50 40 l-2 6 M40 50 l-2 6' stroke='@2' stroke-width='3' fill='none'/></svg>"
)
comptime _TAG = (
    "<svg viewBox='0 0 40 74'><path d='M20 0 V18' stroke='@0' stroke-width='2' fill='none'/><rect x='4' y='18' width='32' height='54' rx='7' fill='@1'/>"
    "<circle cx='20' cy='27' r='4' fill='@2'/><rect x='10' y='38' width='20' height='4' rx='2' fill='@2' opacity='.85'/>"
    "<rect x='10' y='47' width='14' height='4' rx='2' fill='@2' opacity='.85'/></svg>"
)
comptime _TURKEY = (
    "<svg viewBox='0 0 96 62'>"
    "<ellipse cx='48' cy='34' rx='9' ry='30' fill='@0' transform='rotate(-62 48 52)'/>"
    "<ellipse cx='48' cy='34' rx='9' ry='30' fill='@1' transform='rotate(-37 48 52)'/>"
    "<ellipse cx='48' cy='34' rx='9' ry='30' fill='@2' transform='rotate(-12 48 52)'/>"
    "<ellipse cx='48' cy='34' rx='9' ry='30' fill='@3' transform='rotate(13 48 52)'/>"
    "<ellipse cx='48' cy='34' rx='9' ry='30' fill='@1' transform='rotate(38 48 52)'/>"
    "<ellipse cx='48' cy='34' rx='9' ry='30' fill='@0' transform='rotate(63 48 52)'/>"
    "<circle cx='48' cy='44' r='16' fill='@4'/><circle cx='48' cy='28' r='10' fill='@5'/><circle cx='44' cy='26' r='2' fill='@6'/>"
    "<circle cx='52' cy='26' r='2' fill='@6'/><path d='M46 31 l2 4 2-4z' fill='@2'/><path d='M49 32 q3 4 0 8' fill='@3'/></svg>"
)
comptime _PIN = (
    "<svg viewBox='0 0 20 24'><path d='M10 9 V20' stroke='@1' stroke-width='1.6' fill='none'/><circle cx='10' cy='8' r='7' fill='@0'/>"
    "<circle cx='8' cy='6' r='2.2' fill='@2' opacity='.6'/></svg>"
)


def charm_names() -> List[String]:
    """The six occasion charms, then the pin."""
    return ["bag", "pennant", "hat", "umbrella", "tag", "turkey", "pin"]


@fieldwise_init
struct CharmBox(Copyable, Movable, ImplicitlyCopyable):
    """A charm's box in points (w x h) and where it hangs: `top` from the card's top edge (negative: above it), `right`
    from its right edge; its rest angle, and how it moves (`swing` degrees either side, or a flap between rest and
    rest + swing, every `period_ms`) about (px, py), a point in the drawing's own units."""

    var w: Float64
    var h: Float64
    var top: Float64
    var right: Float64
    var rest: Float64
    var swing: Float64
    var flap: Bool
    var period_ms: Float64
    var px: Float64
    var py: Float64


def charm_box(name: String) -> CharmBox:
    """The prototype's .charm.<name> rules (size, top, right, rotate, transform-origin, its swing or flap keyframes)."""
    if name == "bag":  # swing 3.4 s, -7deg..7deg about its top middle
        return CharmBox(78, 113, -26, 20, 0, 7, False, 3400, 29, 0)
    if name == "tag":  # swing 3 s
        return CharmBox(54, 100, -20, 26, 0, 7, False, 3000, 20, 0)
    if name == "pennant":  # flap 1.6 s, -12deg..-5deg about its bottom left
        return CharmBox(116, 70, -22, 22, -12, 7, True, 1600, 0, 50)
    if name == "hat":
        return CharmBox(66, 80, -40, 18, 16, 0, False, 0, 24, 29)
    if name == "umbrella":
        return CharmBox(84, 84, -34, 16, 10, 0, False, 0, 31, 31)
    if name == "turkey":
        return CharmBox(134, 86, -52, 26, 0, 0, False, 0, 48, 31)
    if name == "pin":
        return CharmBox(20, 24, -10, 24, 0, 0, False, 0, 10, 8)
    return CharmBox(0, 0, 0, 0, 0, 0, False, 0, 0, 0)


def charm_top(name: String, room: Float64) -> Float64:
    """Where a charm's box starts above its card's top edge (points, negative is above), given `room` above the card."""
    return max(charm_box(name).top, -room)


def charm_moves(name: String) -> Bool:
    return charm_box(name).swing > 0.0


def _svg(name: String) -> String:
    if name == "bag":
        return _BAG
    if name == "pennant":
        return _PENNANT
    if name == "hat":
        return _HAT
    if name == "umbrella":
        return _UMBRELLA
    if name == "tag":
        return _TAG
    if name == "turkey":
        return _TURKEY
    if name == "pin":
        return _PIN
    return ""


def charm_colours(name: String, p: Palette) -> List[UInt32]:
    """The drawing's '@N' colours from the palette: its data colours by family (nearest hue), deepened toward the
    palette's darkest or lifted toward its lightest for shading."""
    var light = p.ink if p.dark else p.card
    var deep = p.card if p.dark else p.ink
    var blue = _family(p, 205.0)
    var gold = _family(p, 45.0)
    var orange = _family(p, 22.0)
    var red = _family(p, 357.0)
    var violet = _family(p, 270.0)
    var green = p.good
    if name == "bag":
        return [p.ink2, mix(blue, deep, 0.45), blue, mix(blue, deep, 0.18), mix(blue, light, 0.55), mix(gold, light, 0.3),
                mix(gold, orange, 0.5), mix(blue, light, 0.72)]
    if name == "pennant":
        return [mix(orange, deep, 0.55), green, mix(green, light, 0.28), light]
    if name == "hat":
        return [violet, mix(gold, light, 0.45), mix(red, light, 0.38), mix(violet, deep, 0.3)]
    if name == "umbrella":
        return [blue, mix(p.ink2, deep, 0.3), mix(blue, light, 0.5)]
    if name == "tag":
        return [p.ink2, mix(gold, orange, 0.45), light]
    if name == "turkey":
        return [mix(orange, deep, 0.3), orange, mix(gold, orange, 0.4), red, mix(orange, deep, 0.62), mix(orange, deep, 0.5), light]
    if name == "pin":
        return [p.bad, p.ink2, light]
    return List[UInt32]()


def _hue(c: UInt32) -> Tuple[Float64, Float64]:
    """(hue in degrees, saturation 0-1) of an rgba() colour."""
    var r = Float64(Int(c & 0xFF)) / 255.0
    var g = Float64(Int((c >> 8) & 0xFF)) / 255.0
    var b = Float64(Int((c >> 16) & 0xFF)) / 255.0
    var mx = max(r, max(g, b))
    var mn = min(r, min(g, b))
    var d = mx - mn
    if d < 1e-6:
        return (0.0, 0.0)
    var h: Float64
    if mx == r:
        h = 60.0 * ((g - b) / d)
    elif mx == g:
        h = 60.0 * ((b - r) / d + 2.0)
    else:
        h = 60.0 * ((r - g) / d + 4.0)
    if h < 0:
        h += 360.0
    return (h, d / mx if mx > 0 else 0.0)


def _family(p: Palette, want: Float64) -> UInt32:
    """The palette's colour (its data colours, then good, bad, warn) nearest to hue `want`: a theme's own blue, red, gold."""
    var best = p.accent
    var bd = 1e9
    var cands = p.series.copy()
    cands.append(p.good)
    cands.append(p.bad)
    cands.append(p.warn)
    for c in cands:
        var hs = _hue(c)
        if hs[1] < 0.25:
            continue
        var d = abs(hs[0] - want)
        d = min(d, 360.0 - d)
        if d < bd:
            bd = d
            best = c
    return best


def palette_family(p: Palette, hue: Float64) -> UInt32:
    """The palette's own colour nearest to `hue` degrees (0 red, 120 green, 210 blue, 270 violet): for drawings and named
    tints that must stay on the theme's palette."""
    return _family(p, hue)


def charm_angle(name: String, t_ms: Int, still: Bool) -> Float64:
    """Its angle now: the rest angle, plus the swing (ease-in-out, back and forth) or the flap."""
    var b = charm_box(name)
    if b.swing <= 0.0:
        return b.rest
    if still:
        return b.rest + (b.swing / 2.0 if b.flap else 0.0)
    var t = Float64(t_ms % Int(2.0 * b.period_ms)) / b.period_ms  # 0 .. 2
    if t > 1.0:
        t = 2.0 - t
    var e = 0.5 - 0.5 * cos(pi * t)  # (alternate, ease-in-out)
    if b.flap:
        return b.rest + b.swing * e
    return -b.swing + 2.0 * b.swing * e


def draw_charm(mut s: Surface, name: String, x: Float64, y: Float64, scale: Float64, p: Palette, font: Font, t_ms: Int = 0,
               still: Bool = False, alpha: Float64 = 1.0, room: Float64 = 1e9) -> Bool:
    """Charm `name` hanging from a card whose top-right corner is pixel (x, y), at `scale` pixels a point, coloured from
    `p`; it swings or flaps on `t_ms` unless `still`; `alpha` fades it (its arrival); `room`: the points above the card's
    edge it may rise into (a card near its canvas's top: the charm hangs lower rather than being cut). False: no such charm."""
    var svg = _svg(name)
    if svg == "":
        return False
    var v = parse_svg(svg)
    var b = charm_box(name)
    var k = scale * b.w / v.w  # pixels per drawing unit
    var ox = x - (b.right + b.w) * scale  # the box's top-left, pixels
    var oy = y + max(b.top, -room) * scale
    var a = charm_angle(name, t_ms, still)
    var cols = charm_colours(name, p)
    draw_vector(s, v, ox, oy, k, cols, p.ink2, a, b.px, b.py, alpha)
    # the words (SVG <text> in the prototype): placed where the turned drawing puts them
    if name == "pennant":
        _label(s, font, "GO!", ox, oy, k, a, b.px, b.py, 24.0 + 9.0, 24.0, 12.0, cols[3], alpha)
    elif name == "tag":
        _label(s, font, "LIS", ox, oy, k, a, b.px, b.py, 20.0, 66.0, 10.0, cols[2], alpha)
    return True


def _label(mut s: Surface, font: Font, text: String, ox: Float64, oy: Float64, k: Float64, angle: Float64, px: Float64, py: Float64,
           ux: Float64, uy: Float64, size: Float64, colour: UInt32, alpha: Float64):
    var a = angle * pi / 180.0
    var dx = ux - px
    var dy = uy - py
    var x = ox + (px + dx * cos(a) - dy * sin(a)) * k
    var y = oy + (py + dx * sin(a) + dy * cos(a)) * k
    font.draw(s, text, x, y, size * k, with_alpha(colour, alpha), MEDIUM, CENTRE)
