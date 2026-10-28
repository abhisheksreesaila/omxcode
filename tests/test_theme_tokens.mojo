# The Look's tokens for JavaScript widgets (goal 34b M1b): theme_tokens(theme) is JSON data with the palette, the fonts,
# the corners and light or dark, the same values the theme draws with; tokens_css carries the fonts and corners as CSS
# variables. omxqua light and dark differ where they should and agree on the shapes.
from std.testing import assert_equal, assert_true, assert_false
from mojoui.json import Json
from mojoui.theme import Theme, theme_tokens, tokens_css, hex_of, card_radius
from themes.omxqua import omxqua


def check(t: Theme, dark: Bool) raises -> String:
    var j = Json.parse(theme_tokens(t))
    assert_equal(j.text(j.get(0, "id")), t.id)
    assert_equal(j.flag(j.get(0, "dark")), dark)
    var pal = j.get(0, "palette")
    assert_equal(j.text(j.get(pal, "card")), hex_of(t.palette.card))
    assert_equal(j.text(j.get(pal, "ink")), hex_of(t.palette.ink))
    assert_equal(j.text(j.get(pal, "ink2")), hex_of(t.palette.ink2))
    assert_equal(j.text(j.get(pal, "accent")), hex_of(t.palette.accent))
    var data = j.get(pal, "data")
    assert_equal(j.size(data), 6)
    assert_equal(j.text(j.at(data, 0)), hex_of(t.palette.data(0)))
    var font = j.get(0, "font")
    assert_equal(j.text(j.get(font, "family")), t.look.type.family)
    assert_true(j.real(j.get(font, "size")) > 0)
    var corners = j.get(0, "corners")
    assert_equal(j.number(j.get(corners, "card")), card_radius(t))
    assert_equal(j.number(j.get(corners, "field")), t.look.controls.field_radius)
    var css = tokens_css(t)
    for v in ["--o-font:", "--o-mono:", "--o-font-size:", "--o-radius-card: " + String(card_radius(t)) + "px", "--o-radius-field:"]:
        assert_true(v in css, v)
    assert_false("<" in css or "}" in css[byte=0:css.byte_length() - 1], css)  # (one rule: nothing closes it early)
    return j.text(j.get(pal, "card"))


def main() raises:
    var light = check(omxqua(False), False)
    var dark = check(omxqua(True), True)
    assert_true(light != dark)
    assert_true(card_radius(omxqua(False)) == card_radius(omxqua(True)))
    print("theme_tokens: ok")
