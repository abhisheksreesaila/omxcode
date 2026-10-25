# mojoui.look (goal 32 M1): a look's surfaces become the same rules on GTK and the web; a theme's look is what its old
# hand-written rules said (Liquid's toolbar: glass, 18 px corners, 10 px in from the sides, 6 px inside).
#   scripts/mxbuild.sh -I . tests/test_look.mojo -o build/test_look && build/test_look
from std.testing import assert_equal, assert_true, assert_false
from mojoui.theme import Look
from mojoui.look import look_gtk_css, look_web_css, css_color
from mojoui.canvas import rgba
from themes.liquid import liquid
from themes.skins import ledger
from themes.omarchy import omarchy


def main() raises:
    assert_equal(css_color(rgba(255, 255, 255, 158)), "rgba(255,255,255,0.62)")
    assert_equal(css_color(rgba(15, 23, 42, 15)), "rgba(15,23,42,0.06)")
    assert_equal(css_color(rgba(14, 124, 134)), "rgb(14,124,134)")
    var l = liquid()
    var k = l.look.surface("toolbar")
    assert_true(k >= 0, "Liquid has a toolbar surface")
    assert_equal(l.look.surfaces[k].radius_top, 18)
    var gtk = look_gtk_css(l.look, "window.liquid ")
    var web = look_web_css(l.look, "body.liquid ")
    assert_true("window.liquid .mui-tag-toolbar { background: rgba(255,255,255,0.62); border-radius: 18px; margin: 0 10px 0; padding: 6px;" in gtk, gtk)
    assert_true("body.liquid [data-tag=toolbar] { background: rgba(255,255,255,0.62); border-radius: 18px; margin: 0 10px 0; padding: 6px; box-sizing: border-box;" in web, web)
    assert_true("backdrop-filter: blur(24px)" in web and "backdrop-filter" not in gtk, "the blur is the web's alone")
    assert_true("border-radius: 0 0 14px 14px" in gtk, "the status bar's bottom corners")
    assert_true("window.liquid .mui-tag-status-bar label, window.liquid label.mui-tag-status-bar { font-family: 'Inter', sans-serif; font-size: 12px;" in gtk, gtk)
    # a Board object wears its content's role: the content inside fills it with no second card (the web drew two)
    assert_true("body.liquid .board > .object[data-tag=table] > [data-tag=table] { background: none; box-shadow: none;" in web, web)
    assert_true("body.liquid label.toggle { min-height: 30px; }" in web, "the toggle row is a control's height, not the 48 px touch row")
    assert_true("window.liquid .mui-tag-inspector-row {" in gtk and "min-height: 30px" in gtk, "an inspector row is as tall as a control")
    assert_true("body.liquid button.tool.inline, body.liquid label.picker.tool.inline { min-width: 0; min-height: 34px; padding: 0 10px; border-radius: 10px; font-size: 12px; }" in web, web)
    var g = look_gtk_css(ledger().look, "window.ledger ")
    assert_true("font-family: 'JetBrains Mono', monospace" in g, "the skins' figures are mono")
    assert_true("border-bottom: 1px solid" in g, "the skins' toolbar band has a hairline")
    assert_equal(look_gtk_css(omarchy().look, "window.omarchy "), "", "Omarchy's look has no surfaces yet: no rules")
    assert_true(Look.none().is_none())
    print("LOOK TESTS PASSED")
