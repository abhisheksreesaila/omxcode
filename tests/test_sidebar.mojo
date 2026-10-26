# mojoui.sidebar: heads (a quiet word, a tail), rows (icon, dot or #; on, quiet), the column's width from the look; compact:
# chips, the plain heads left out.
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
from mojoui.sidebar import Sidebar, SidebarHead, SidebarItem
from mojoui.view import Button


def main() raises:
    var on = SidebarItem("All models", "3", 50, on=True, icon="box")
    assert_equal(on.nodes[0].name, "sidebar-item-on")
    assert_equal(on.nodes[tagged(on, "sidebar-label")].msg, 50)
    assert_equal(SidebarItem("Running", "1", 51, dot=7).nodes[1].name, "sidebar-dot")
    assert_true(tagged(SidebarItem("work", "2", 52, hash=True), "sidebar-hash") > 0)
    assert_equal(SidebarItem("New label", "", 53, icon="plus", quiet=True).nodes[0].name, "sidebar-item-quiet")
    var col = Sidebar([SidebarHead("Show"), on.copy(), SidebarHead("Kind", "· automatic"), SidebarHead("Your labels", tail=[Button("Edit labels", 4)])])
    assert_equal(len(col.nodes[0].children), 4)
    var look = omxqua(False).look.copy()
    resolve_layout(col, look)
    assert_equal(col.nodes[0].w, 227)
    var row = Sidebar([SidebarHead("Show", compact=True), SidebarItem("All", "3", 50, on=True, icon="box", compact=True),
                       SidebarHead("Your labels", tail=[Button("Edit labels", 4)], compact=True)], compact=True)
    assert_equal(row.nodes[0].name, "sidebar-compact")
    assert_equal(len(row.nodes[0].children), 2)  # (the plain head left out)
    assert_equal(first(SidebarItem("All", "3", 50, icon="box", compact=True), ICON), -1)  # (no icon on a chip)
    covered([col.copy(), row.copy(), SidebarItem("x", "", 1, quiet=True, compact=True), SidebarItem("y", "1", 2, compact=True)])
    print("sidebar: ok")
