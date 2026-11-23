# Liquid's selected bottom tab (owner, 2026-11-22: "rectangular, a subtle highlight indicates the active one", no pill):
# one tint on every host. The Mac draws liquid_look's sheet-tabs-button-on role; GTK and the web draw liquid_css's and the
# web rule; all three wear tab_tint, square-ish corners, no shadow, in light and dark.
#   pixi run mojo build -I . tests/test_liquid_tabs.mojo -o build/test_liquid_tabs && build/test_liquid_tabs
from std.testing import assert_true, assert_equal
from mojoui.look import css_color
from themes.liquid import liquid, liquid_palette, tab_tint


def check(dark: Bool) raises:
    var t = liquid(liquid_palette(dark))
    var tint = css_color(tab_tint(t.palette))
    var k = t.look.surface("sheet-tabs-button-on")
    assert_true(k >= 0, "the Mac's role for the selected tab")
    assert_equal(t.look.surfaces[k].fill, tab_tint(t.palette))
    assert_true(t.look.surfaces[k].radius_top <= 8, "a rectangle, not a pill")
    assert_equal(len(t.look.surfaces[k].shadows), 0)
    assert_true(t.gtk_css.find(".mui-tag-sheet-tabs button:not(.flat) { background: " + tint + ";") >= 0, "GTK wears the tint")
    assert_true(t.gtk_css.find(".mui-tag-sheet-tabs button { border-radius: 999px") < 0, "no GTK pill")
    assert_true(t.web_css.find("[data-tag=sheet-tabs] button:not(.subtle) { background: " + tint + ";") >= 0, "the web wears the tint")
    assert_true(t.web_css.find("[data-tag=sheet-tabs] button { border-radius: 999px") < 0, "no web pill")
    print("TABS: " + ("dark" if dark else "light") + " " + tint + " PASS")


def main() raises:
    check(False)
    check(True)
