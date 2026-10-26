# mojoui.lists: the split view (compact: stacked), the count line and its hint, the list body, an empty line, a card grid,
# the selection bar, a name cell (signal dot, the name to tap, its second line), a cell stack; chip rows and the tag
# editor (✕ k sends on_remove + k).
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
from mojoui.lists import SplitView, ListCount, ListBody, ListEmpty, CardGrid, SelectionBar, NameCell, CellStack, PageColumn, MainAside
from mojoui.chip import ChipRow, Chip, TagEditor
from mojoui.view import Text


def main() raises:
    var cell = NameCell("qwen2.5-0.5b", 70, "Qwen/Qwen2.5-0.5B-Instruct", signal=1)
    assert_equal(cell.nodes[tagged(cell, "name-link")].msg, 70)
    assert_true(tagged(cell, "signal-dot-1") > 0 and tagged(cell, "name-cell-sub") > 0)
    assert_equal(len(ListCount("All models · 3").nodes[0].children), 1)
    assert_equal(len(ListCount("All models · 3", "tick models").nodes[0].children), 3)
    var tags_ = TagEditor(["favorites", "work"], 330, "label", 352)
    assert_equal(tags_.nodes[tagged(tags_, "tag-add")].msg, 352)
    var x = 0
    for n in tags_.nodes:
        if n.name == "tag-remove":
            x += 1
            assert_equal(n.msg, 330 + x - 1)
    assert_equal(x, 2)
    assert_equal(SplitView(Text("side"), Text("main"), compact=True).nodes[0].name, "split-view-compact")
    covered([SplitView(Text("side"), Text("main")), ListBody(Text("t")), ListBody(Text("t"), compact=True), ListEmpty("Nothing"), CardGrid([Text("c")], 4),
             SelectionBar([Text("2 selected")]), cell.copy(), CellStack([Text("a")]), ChipRow([Chip("Chat", 1)]), tags_.copy(), PageColumn([Text("x")]),
             PageColumn([Text("x")], compact=True), MainAside(Text("m"), Text("a")), MainAside(Text("m"), Text("a"), aside_wide=True), MainAside(Text("m"), Text("a"), compact=True)],
            ["side", "main"])
    print("lists: ok")
