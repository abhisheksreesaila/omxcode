# mojoui.header: the page header (square, title, count, sub line, tools), pill tabs with hues (k sends on_tap + k), the
# segmented buttons (icons only when compact), the filter bar, the tab header and its compact column, a sub-header.
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
from mojoui.header import PageHeader, IconSquare, FilterBar, PillTabs, SegmentButtons, ActionGroup, TabHeader, SubHeader, ToolRow, hued
from mojoui.view import Text, Button


def main() raises:
    var h = PageHeader("layout-grid", "My models", "3", "3 models", [Text("$ mxc ls")])
    assert_equal(h.nodes[0].name, "page-header")
    assert_true(tagged(h, "page-title") > 0 and tagged(h, "pill") > 0 and tagged(h, "page-tools") > 0)
    var tabs = PillTabs(["Overview", "Logs"], ["box", "scroll-text"], 1, 310, [2, 0])
    assert_equal(tabs.nodes[tabs.nodes[0].children[0]].name, "tab-2")
    assert_equal(tabs.nodes[tabs.nodes[0].children[1]].name, "tab-on")
    assert_equal(tabs.nodes[tabs.nodes[0].children[1]].msg, 311)
    assert_equal(PillTabs(["A"], ["box"], 0, 1, fill=True).nodes[0].name, "pill-tabs-fill")
    var seg = SegmentButtons(["List", "Cards"], ["list", "layout-grid"], 0, 42, icons_only=True)
    assert_equal(seg.nodes[seg.nodes[0].children[0]].name, "segment-icon-on")
    assert_equal(seg.nodes[seg.nodes[0].children[1]].msg, 43)
    assert_equal(IconSquare("lock", tone=1).nodes[0].name, "icon-square-tone-1")
    assert_equal(IconSquare("x", hue=3).nodes[0].name, "icon-square-3")
    assert_equal(hued("flat", 8), "flat-8")
    var th = TabHeader(tabs.copy(), ActionGroup([Button("Stop", 1)]), compact=True)
    assert_equal(th.nodes[0].name, "tab-header-compact")
    covered([h.copy(), tabs.copy(), seg.copy(), SegmentButtons(["a", "b"], [], 1, 1), FilterBar([Text("x")]), th.copy(),
             TabHeader(tabs.copy(), ActionGroup([Button("Stop", 1)], fill=True)), SubHeader("qwen · max serve", [Button("Copy", 1)]), ToolRow([Text("x")]),
             IconSquare("x"), IconSquare("x", tone=3)])
    print("header: ok")
