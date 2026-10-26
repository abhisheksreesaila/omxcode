# mojoui.shell: the bar, the brand, the rule, nav links with hues, the folded ⋯, the page card and the frame; the look's
# spacing scale and its roles' sizes land on the views (mojoui.look.resolve_layout), as every host then sees them.
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
from mojoui.shell import AppBar, Brand, BarRule, NavLink, NavLinks, NavMore, PageCard, Shell, is_compact
from mojoui.view import Text, HStack, Spacer, SPACE_S
from mojoui.beacon import Beacon, Ring
from mojoui.canvas import Surface


def main() raises:
    var link = NavLink("Keys", "key-round", 35, here=True, hue=3)
    assert_equal(link.nodes[0].name, "nav-link-here-3")
    assert_equal(link.nodes[0].msg, 35)
    assert_equal(NavLink("Settings", "sliders-horizontal", 38).nodes[0].name, "nav-link")
    var brand = Brand("omx", "omxconsole", 2)
    assert_equal(texts(brand)[0], "omx")
    assert_equal(brand.nodes[brand.nodes[0].children[1]].msg, 2)
    assert_equal(len(Brand("omx", "", 2).nodes[0].children), 1)  # (compact: the mark alone)
    var bar = AppBar([brand.copy(), BarRule(), Spacer(), NavLinks([link.copy()])])
    var page = PageCard([Text("x")])
    var shell = Shell(bar.copy(), page.copy())
    assert_true(tagged(shell, "page-frame") > 0)
    assert_true(tagged(Shell(bar.copy(), page.copy(), compact=True), "page-frame-compact") > 0)
    assert_true(is_compact(390) and not is_compact(1440))
    covered([shell.copy(), NavMore("More", 9), AppBar([Text("a")], compact=True), NavLink("Gateway", "route", 36, hue=2)])
    # the runtime's pass: the bar takes its height and spacing, the rule's line its size, a token its points
    var look = omxqua(False).look.copy()
    resolve_layout(shell, look)
    var b = tagged(shell, "app-bar")
    assert_equal(shell.nodes[b].h, 60)
    assert_equal(shell.nodes[b].spacing, 6)
    var line = tagged(shell, "bar-rule-line")
    assert_equal(shell.nodes[line].w, 1)
    assert_equal(shell.nodes[line].h, 22)
    var t = HStack(Text("a"), Text("b"), spacing=SPACE_S).padding(SPACE_S, SPACE_S)
    resolve_layout(t, look)
    assert_equal(t.nodes[0].spacing, look.space[2])
    assert_equal(t.nodes[0].pad_h, look.space[2])
    # the Beacon in its slot: a ring for a job (a canvas the app paints with a Ring), the label, the value
    var bc = Beacon("Pulling helper-7b", "35%", 0, 35)
    assert_equal(bc.nodes[0].name, "beacon-slot")
    assert_equal(bc.nodes[first(bc, CANVAS)].name, "beacon-ring")
    assert_equal(texts(bc)[0], "Pulling helper-7b")
    assert_equal(Beacon("1 running", "158 tok/s", live=True, compact=True).nodes[0].name, "beacon-slot-compact")
    covered([bc.copy(), Beacon("1 running", "158 tok/s", live=True)])
    var px = List[UInt32](length=40 * 40, fill=0)
    var surf = Surface(Int(px.unsafe_ptr()), 40, 40, 2.0)
    Ring.themed(35, look).draw(surf)  # (the arc in the look's live colour, from the top, clockwise)
    var top = surf.get(21, 4)
    var left = surf.get(4, 20)
    assert_true((top >> 8) & 255 > 150, "the arc isn't at the top")
    assert_true((left >> 8) & 255 < 120, "the arc reaches 75 %")
    _ = px[0]
    print("shell: ok")
