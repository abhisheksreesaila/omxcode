# Liquid's depth and legibility (goal 73 M3, D-7320, D-7321): the canvas a clear step off the cards (light: darker; dark: the
# cards lifted lighter than the canvas) and every text colour at least 4.5:1 (WCAG AA) on the cards, the canvas (both ends
# of its gradient) and the docked chrome. Prints one `CONTRAST:` line per pair (docs/goals/73/m3.py reads them).
#   pixi run mojo build -I . tests/test_liquid_contrast.mojo -o build/test_liquid_contrast && build/test_liquid_contrast
from std.testing import assert_true
from mojoui.theme import Palette, hx, hex_of, mix
from themes.liquid import liquid_palette, liquid_dark_palette, LIGHT_TOP, LIGHT_BOTTOM, WHITE


def channel(c: UInt32, shift: Int) -> Float64:
    var v = Float64(Int((c >> UInt32(shift)) & 255)) / 255.0
    return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4


def lum(c: UInt32) -> Float64:
    return 0.2126 * channel(c, 0) + 0.7152 * channel(c, 8) + 0.0722 * channel(c, 16)


def contrast(a: UInt32, b: UInt32) -> Float64:
    return (max(lum(a), lum(b)) + 0.05) / (min(lum(a), lum(b)) + 0.05)


def lstar(c: UInt32) -> Float64:
    var y = lum(c)
    return 116.0 * (y ** (1.0 / 3.0)) - 16.0 if y > 0.008856 else 903.3 * y


def check(mode: String, text_name: String, text: UInt32, bg_name: String, bg: UInt32) raises:
    var r = contrast(text, bg)
    print("CONTRAST: " + mode + " " + text_name + " " + hex_of(text) + " on " + bg_name + " " + hex_of(bg) + " = " + String(Float64(Int(r * 100.0)) / 100.0))
    assert_true(r >= 4.5, mode + ": " + text_name + " on " + bg_name + " is " + String(r) + ":1, AA wants 4.5")


def texts_on(mode: String, p: Palette, canvases: List[UInt32], names: List[String]) raises:
    for i in range(len(canvases)):
        check(mode, "ink", p.ink, names[i], canvases[i])
        check(mode, "ink2", p.ink2, names[i], canvases[i])
        check(mode, "ink3", p.ink3, names[i], canvases[i])
    check(mode, "accent", p.accent, "card", p.card)
    check(mode, "ink3", p.ink3, "raised", p.raised)
    check(mode, "chrome_ink", p.chrome_ink, "chrome", p.chrome)


def main() raises:
    var light = liquid_palette()
    var dark = liquid_dark_palette()
    var black = hx("#000000")
    texts_on("light", light, [light.card, light.page, hx(LIGHT_TOP), hx(LIGHT_BOTTOM), light.chrome],
             ["card", "canvas", "canvas-top", "canvas-bottom", "chrome"])
    texts_on("dark", dark, [dark.card, dark.page, mix(dark.page, WHITE, 0.03), mix(dark.page, black, 0.08), dark.chrome],
             ["card", "canvas", "canvas-top", "canvas-bottom", "chrome"])
    # the step: a card is at least 4 L* off the canvas, light cards the lighter one's opposite (darker canvas), dark cards lighter
    var ls = lstar(light.card) - lstar(light.page)
    var ds = lstar(dark.card) - lstar(dark.page)
    print("STEP: light card " + String(Int(lstar(light.card))) + " canvas " + String(Int(lstar(light.page))) + " dL*=" + String(Int(ls)))
    print("STEP: dark card " + String(Int(lstar(dark.card))) + " canvas " + String(Int(lstar(dark.page))) + " dL*=" + String(Int(ds)))
    assert_true(ls >= 8.0, "light: the canvas is a clear step darker than the cards")
    assert_true(ds >= 5.0, "dark: the cards stand lighter than the canvas")
    print("OK")
