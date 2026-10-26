# mojoui.look (goal 32 M1): a look's surfaces become the same rules on GTK and the web; a theme's look is what its old
# hand-written rules said (Liquid's toolbar: glass, 18 px corners, 10 px in from the sides, 6 px inside).
#   scripts/mxbuild.sh -I . tests/test_look.mojo -o build/test_look && build/test_look
from std.testing import assert_equal, assert_true, assert_false
from mojoui.theme import Look, Surface
from mojoui.look import look_gtk_css, look_web_css, css_color, surface_rule, text_rule
from mojoui.canvas import rgba
from themes.liquid import liquid
from themes.skins import ledger
from themes.omarchy import omarchy
from themes.omxqua import omxqua


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
    assert_true("body.liquid [data-tag=toolbar], body.liquid button[data-tag=toolbar], body.liquid [data-role~=toolbar] { background: rgba(255,255,255,0.62); border-radius: 18px; margin: 0 10px 0; padding: 6px; box-sizing: border-box;" in web, web)
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
    # omxqua (goal 33 M3): the press is data; the web springs on omxqua's linear(), GTK on its ease-in; no other look presses
    var q = omxqua()
    assert_equal(q.look.motion.press_scale, 0.96)
    var qweb = look_web_css(q.look, "body.omxqua ")
    var qgtk = look_gtk_css(q.look, "window.omxqua ")
    assert_true("body.omxqua button:active, body.omxqua label.picker:active { transform: scale(0.96); }" in qweb, qweb)
    assert_true("transition: transform 300ms linear(0, 0.02, 0.071," in qweb, "the web takes the spring itself")
    assert_true("window.omxqua button:active { transform: scale(0.96); }" in qgtk and "300ms cubic-bezier(0.2, 0, 0, 1)" in qgtk, qgtk)
    assert_true("body.omxqua [data-tag=tile], body.omxqua button[data-tag=tile], body.omxqua [data-role~=tile] { background: rgb(255,255,255); border-radius: 12px; box-shadow: 0 1px 2px rgba(20,16,10,0.06), 0 0 0 1px rgba(20,16,10,0.04);" in qweb, qweb)
    assert_true("font-family: 'Geist Mono', monospace" in qweb, "mono labels")
    # a table's cells wear roles without being views (data-role, two at once: "table-cell table-num"); a tagged button's title wears its role's type
    assert_true("body.omxqua [data-tag=table-head], body.omxqua button[data-tag=table-head], body.omxqua [data-role~=table-head] { background: transparent; padding: 8px 16px;" in qweb, qweb)
    assert_true("body.omxqua button[data-tag=crumb], body.omxqua :where([data-role~=crumb]) .text, body.omxqua [data-role~=crumb] { font-size: 13.5px; font-weight: 550;" in qweb, qweb)
    assert_true("transform: scale" not in look_web_css(l.look, "body.liquid "), "Liquid's look has no press of its own")
    var night = omxqua(True)
    assert_equal(night.id, "omxqua-dark")
    assert_true("body.omxqua-dark { background: #0b0b0d;" in night.web_css, "night: surface-0")
    # goal 33 M7 (D-410): a surface's optional fields reach the web's and GTK's rules
    var s = Surface("probe", 0, -1, -1, -1, -1, -1, 0, 14, 0, [], 0, 0, 0, -1, "", 0, 0, 0, 0, -1, 0, 0, False, pad_left=12, pad_right=16, gap=10, height=40,
                    icon_size=15, icon_stroke=1.75, text_align=2, width=110, max_width=980, scrolls_x=True)
    var w = surface_rule(s, True)
    assert_true("padding: 0 16px 0 12px;" in w and "gap: 10px !important;" in w and "height: 40px; min-height: 40px;" in w, w)
    assert_true("width: 110px; min-width: 110px; flex-shrink: 0;" in w and "flex-wrap: nowrap; overflow-x: auto;" in w and "justify-content: center;" in w, w)
    assert_false("border-spacing" in surface_rule(s, False), "GTK takes a role's gap as the stack's spacing (resolve_layout), never border-spacing as well (D-464: it doubled)")
    assert_true("line-height: normal;" in text_rule(s, True) and "text-align: center;" in text_rule(s, True), text_rule(s, True))
    var probe = Look(Look.none().type, Look.none().controls, [s.copy()], Look.none().segments)
    var css = look_web_css(probe, "body.x ")
    assert_true("body.x [data-tag=probe] svg, body.x [data-role~=probe] svg { width: 15px; height: 15px; stroke-width: 1.75px; }" in css, css)
    # a role that gives way in a squeezed row (no width of its own: a status chip on a phone) gets its own rule; one-line
    # words are cut with an ellipsis, but a button wearing a one-line role keeps its width (D-475, D-478)
    var give = Surface("give", 0, -1, -1, -1, -1, -1, -1, -1, -1, [], 0, 0, 0, -1, "", 0, 0, 0, 0, 0, 0, 0, False, shrinks=True, items_shrink=True)
    var one = Surface("one", 0, 999, 999, -1, -1, -1, 0, 12, 0, [], 0, 0, 0, -1, "", 12, 0, 0, 0, 0, 0, 0, False, one_line=True)
    var sq = Look(Look.none().type, Look.none().controls, [give.copy(), one.copy()], Look.none().segments)
    var scss = look_web_css(sq, "body.x ")
    assert_true("body.x [data-tag=give], body.x button[data-tag=give], body.x [data-role~=give] { background: transparent; box-shadow: none; border: 0; min-width: 0 !important; flex-shrink: 1 !important; overflow: hidden; }" in scss, scss)
    assert_true("body.x [data-tag=one] .text, body.x .text[data-tag=one] { overflow: hidden; text-overflow: ellipsis; min-width: 0; }" in scss, scss)
    assert_true("body.x [data-tag=give] > * { min-width: 0; flex-shrink: 1; overflow: hidden; }" in scss, scss)
    assert_false("button[data-tag=one], body.x :where([data-role~=one]) .text, body.x [data-role~=one] { font-size: 12px; white-space: nowrap; overflow" in scss, "a one-line button keeps its width")
    var w1 = Surface("pillw", 0, -1, -1, -1, -1, -1, -1, -1, -1, [], 0, 0, 0, -1, "", 0, 0, 0, 0, 0, 0, 0, False, whole_width=True)
    var wcss = look_web_css(Look(Look.none().type, Look.none().controls, [w1.copy()], Look.none().segments), "body.x ")
    assert_true("--mojoui-whole-width: 1;" in wcss, wcss)  # (the web host's script sizes it to whole pixels, D-479)
    var fl = Surface("flowing", 0, -1, -1, -1, -1, -1, 0, 16, 14, [], 0, 0, 0, -1, "", 0, 0, 0, 0, 0, 0, 0, False, block_flow=True)
    assert_true("display: block;" in surface_rule(fl, True) and "display" not in surface_rule(fl, False), surface_rule(fl, True))  # (D-481)
    var lined = Surface("lined", 0, -1, -1, -1, -1, -1, -1, -1, -1, [], 0, 0, 0, -1, "", 11.5, 0, 0, 0, 18.4, 0, 0, False)
    assert_true("line-height: 1.6;" in text_rule(lined, True), text_rule(lined, True))  # (a number, as the original's CSS: D-482)
    print("LOOK TESTS PASSED")
