# mojoui.activity: the strip's view (a canvas that fills its width, asks for frames only with on_frame) and its drawing
# (the track in the palette's raised colour, the bar in its accent, sliding STEP pixels a frame and wrapping).
from std.testing import assert_equal, assert_true
from mojoui.view import CANVAS, NO_MSG
from mojoui.canvas import Surface
from mojoui.theme import Palette
from mojoui.activity import ActivityStrip, Strip, STRIP_H, STEP


def main() raises:
    var v = ActivityStrip(3, 7, on_frame=9)
    assert_equal(v.nodes[0].kind, CANVAS)
    assert_equal(v.nodes[0].h, STRIP_H)
    assert_true(v.nodes[0].fills)
    assert_equal(v.nodes[0].msg2, 9)  # (every display frame sends it)
    assert_equal(v.nodes[0].style, 3)
    assert_equal(v.nodes[0].value, 7)
    var still = ActivityStrip(3, 7)
    assert_equal(still.nodes[0].h, STRIP_H)
    assert_equal(still.nodes[0].msg2, NO_MSG)
    var pal = Palette.plain()
    var buf = List[UInt32](length=80 * 4, fill=0)
    var s = Surface(Int(buf.unsafe_ptr()), 80, 4, 1.0)
    var a = Strip(5, pal)  # bar 10 wide at 5 * 6 - 10 = 20
    assert_equal(a.bar_x(80), 5 * STEP - 10)
    a.draw(s)
    assert_equal(s.get(19, 0), pal.raised)
    assert_equal(s.get(20, 0), pal.accent)
    assert_equal(s.get(29, 3), pal.accent)
    assert_equal(s.get(30, 3), pal.raised)
    assert_equal(Strip(0, pal).bar_x(80), -10)  # (sliding in)
    assert_equal(Strip(15, pal).bar_x(80), -10)  # (90 px a lap: back at the start)
    Strip(0, pal).draw(s)
    assert_equal(s.get(0, 0), pal.raised)
    _ = len(buf)
    print("activity: ok")
