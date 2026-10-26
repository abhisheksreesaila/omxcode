# mojoui.meter: a meter (clamped bar, bad), a usage bar over its figures and its drawing (this, others, free), a chart row.
from std.testing import assert_equal, assert_true
from mojoui.view import TEXT, BUTTON, ICON, CANVAS, PROGRESS, SCROLL, FIELD, TABLE, CLIPBOARD
from mojoui.view import View, NO_MSG
from mojoui.look import resolve_layout
from themes.omxqua import omxqua


def tags(v: View) -> List[String]:
    var out = List[String]()
    for n in v.nodes:
        if n.name != "":
            out.append(n.name)
    return out^


def first(v: View, kind: Int) -> Int:
    for k in range(len(v.nodes)):
        if v.nodes[k].kind == kind:
            return k
    return -1


def texts(v: View) -> List[String]:
    var out = List[String]()
    for n in v.nodes:
        if n.kind == TEXT or n.kind == BUTTON:
            out.append(n.text)
    return out^


def tagged(v: View, name: String) -> Int:
    for k in range(len(v.nodes)):
        if v.nodes[k].name == name:
            return k
    return -1


def covered(views: List[View], skip: List[String] = []) raises:
    """Every tag the views set has a role in omxqua's look (the theme gives every part its look)."""
    var look = omxqua(False).look.copy()
    for v in views:
        for t in tags(v):
            if t in skip:
                continue
            assert_true(look.surface(t) >= 0, "no role for tag " + t)
from mojoui.meter import Meter, UsageBar, Usage, ChartRow
from mojoui.canvas import Surface
from mojoui.view import Text


def main() raises:
    var m = Meter("needs", 140, True, "~9 GB")
    var pi = first(m, PROGRESS)
    assert_equal(m.nodes[pi].value, 100)
    assert_equal(m.nodes[pi].name, "meter-bar-bad")
    var u = UsageBar(7, 31, ["this 3.1 GB", "others 0 GB", "free 14.9 GB of 24 GB"])
    assert_equal(u.nodes[first(u, CANVAS)].name, "usage-bar")
    var look = omxqua(False).look.copy()
    var pal = omxqua(False).palette.copy()
    var px = List[UInt32](length=100 * 10, fill=0)
    var s = Surface(Int(px.unsafe_ptr()), 100, 10, 1.0)
    var usage = Usage.themed(0.25, 0.25, look, pal)
    usage.draw(s)
    assert_equal(s.get(10, 5), pal.ink3)  # (the others first, faint)
    assert_equal(s.get(35, 5), usage.color)  # (then this one, in its signal colour)
    _ = px[0]
    var c = ChartRow(1, "qwen", Text("[bar]"), "158 tok/s", strong=True, figure_strong=True)
    covered([m.copy(), Meter("RTX", 50, False, "4 GB"), u.copy(), c.copy()], ["[bar]"])
    print("meter: ok")
