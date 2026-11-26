# mojoui.ribbon on its own (goal 76 M1): the tab row, the bands, captions, tags, the selected tab, compact mode,
# hidden bands that stay reachable, and an Inspector's close button.
#   pixi run mojo run -I . tests/test_ribbon.mojo
from std.testing import assert_equal, assert_true

from mojoui import View, BUTTON, TEXT, TOOL, TOOL_ON
from mojoui.view import ICON_ONLY, ICON_ON, DIVIDER, PLAIN, SUBTLE, CAPTION, Text, Button, HStack, Dropdown
from mojoui.ribbon import (Ribbon, RibbonTab, RibbonGroup, RibbonTool, ribbon_tab, ribbon_group, ribbon_tool, ribbon_picker,
                           ribbon_toggle, tab_of, ribbon_messages, RIBBON_BAND_H, RIBBON_BAND_COMPACT_H)
from mojoui.inspector import Inspector, Section
from mojoui.diff import diff


def find(v: View, tag: String) -> Int:
    for i in range(len(v.nodes)):
        if v.nodes[i].name == tag:
            return i
    return -1


def find_text(v: View, kind: Int, text: String) -> Int:
    for i in range(len(v.nodes)):
        if v.nodes[i].kind == kind and v.nodes[i].text == text:
            return i
    return -1


def tagged(v: View, tag: String) -> List[Int]:
    var out = List[Int]()
    for i in range(len(v.nodes)):
        if v.nodes[i].name == tag:
            out.append(i)
    return out^


def under(v: View, root: Int, i: Int) -> Bool:
    """Whether node i is root or inside it."""
    if i == root:
        return True
    for c in v.nodes[root].children:
        if under(v, c, i):
            return True
    return False


def shown(v: View, i: Int) -> Bool:
    """Node i and none of its parents hidden."""
    for k in range(len(v.nodes)):
        if v.nodes[k].hidden and under(v, k, i):
            return False
    return True


comptime ON_TAB = 100
comptime SAVE = 1
comptime UNDO = 2
comptime BOLD = 3
comptime PICK_TABLE = 4
comptime CHART = 5
comptime LINKS = 6
comptime TILES_OF = 7


def tabs(bold: Bool) -> List[RibbonTab]:
    var home = ribbon_tab("Home", [ribbon_group("Clipboard", [ribbon_tool("Save", "save", SAVE, "Save the document (Ctrl+S)"), ribbon_tool("Undo", "undo", UNDO)]),
                                   ribbon_group("Font", [ribbon_toggle("Bold", "bold", BOLD, bold, "Bold (Ctrl+B)")])])
    var insert = ribbon_tab("Insert", [ribbon_group("From a file", [ribbon_picker("Table", "table", PICK_TABLE, ".csv,.parquet", tag="insert-table")]),
                                       ribbon_group("Make", [ribbon_tool("Chart", "chart-bar", CHART)]),
                                       ribbon_group("Connect", [ribbon_tool("Links", "share", LINKS)])])
    var view = ribbon_tab("View", [ribbon_group("Panels", [ribbon_tool("Links", "share", LINKS, on=True)])])
    var report = ribbon_tab("Report", [ribbon_group("Tiles", [], [Dropdown(["a", "b"], 0, TILES_OF).tag("tiles-of")])], contextual=True)
    return [home^, insert^, view^, report^]


def main() raises:
    var t = tabs(True)
    var r = Ribbon(t, 1, ON_TAB, leading=[Text("app").tag("app-mark")], trailing=[Text("island").tag("island")])
    assert_equal(r.nodes[0].name, "ribbon")
    # the tab row: the mark leading, the tab names, the island trailing (tagged "menubar": the role an app bar had)
    var head = find(r, "menubar")
    assert_true(head > 0 and under(r, head, find(r, "app-mark")) and under(r, head, find(r, "island")) and under(r, head, find(r, "ribbon-tabs")))
    var names = r.nodes[find(r, "ribbon-tabs")].children.copy()
    assert_equal(len(names), 4)
    assert_equal(r.nodes[names[0]].text, "Home")
    assert_equal(r.nodes[names[1]].name, "ribbon-tab-insert")
    assert_equal(r.nodes[names[1]].msg, ON_TAB + 1)
    assert_equal(r.nodes[names[1]].style, PLAIN)  # (the selected tab stands out)
    assert_equal(r.nodes[names[0]].style, SUBTLE)
    assert_true(r.nodes[names[3]].tip.find("shown while") >= 0)  # (the contextual tab says so)
    # one band per tab ("toolbar"), only the selected one shown
    var bands = tagged(r, "toolbar")
    assert_equal(len(bands), 4)
    for k in range(4):
        assert_equal(r.nodes[bands[k]].hidden, k != 1)
        assert_equal(r.nodes[bands[k]].h, RIBBON_BAND_H)
    # groups captioned under their tools, a divider between two groups
    var groups = tagged(r, "ribbon-group")
    assert_equal(len(groups), 2 + 3 + 1 + 1)
    var captions = tagged(r, "ribbon-caption")
    assert_equal(len(captions), 7)
    assert_equal(r.nodes[captions[2]].text, "From a file")
    assert_equal(r.nodes[captions[2]].style, CAPTION)
    var dividers = 0
    for c in r.nodes[bands[1]].children:
        if r.nodes[c].kind == DIVIDER:
            dividers += 1
    assert_equal(dividers, 2)
    # tools: icon over title, a picker keeps its types and tag, a toggle pressed while on, the tooltip
    var save = find_text(r, BUTTON, "Save")
    assert_equal(r.nodes[save].style, TOOL)
    assert_equal(r.nodes[save].tip, "Save the document (Ctrl+S)")
    var pick = find(r, "insert-table")
    assert_true(pick > 0 and r.nodes[pick].msg2 != 0 and r.nodes[pick].options[0] == ".csv,.parquet" and r.nodes[pick].msg2 == PICK_TABLE)
    assert_true(shown(r, pick))  # (Insert is selected)
    var bold = find(r, "bold")
    assert_equal(r.nodes[bold].style, ICON_ON)
    var off = Ribbon(tabs(False), 1, ON_TAB)
    assert_equal(off.nodes[find(off, "bold")].style, ICON_ONLY)
    assert_equal(r.nodes[find(r, "tiles-of")].msg, TILES_OF)  # (a group's own views)
    # every tool of every tab is in the tree (hidden ones too: D-7601), so agents and test steps reach them
    assert_true(not shown(r, save) and save > 0)
    var links = 0
    for n in r.nodes:
        if n.kind == BUTTON and n.msg == LINKS:
            links += 1
    assert_equal(links, 2)  # (Links on Insert and on View)
    assert_equal(r.nodes[find_text(r, BUTTON, "Chart")].style, TOOL)
    # switching tabs only shows another band: the same nodes, the bands laid out again
    var r0 = Ribbon(t, 0, ON_TAB)
    var r1 = Ribbon(t, 1, ON_TAB)
    assert_equal(len(r0.nodes), len(r1.nodes))
    assert_true(shown(r0, find_text(r0, BUTTON, "Save")) and not shown(r1, find_text(r1, BUTTON, "Save")))
    var d = diff(r0, r1)
    assert_true(d.rebuild and d.partial)  # (only the parts that changed: two bands, two tab buttons' styles)
    assert_equal(d.kept[0], 0)
    # compact: icons only, titles as tooltips (the host's icon-only button), no captions, a lower band
    var c = Ribbon(t, 1, ON_TAB, compact=True)
    assert_equal(len(tagged(c, "ribbon-caption")), 0)
    assert_equal(c.nodes[find_text(c, BUTTON, "Chart")].style, ICON_ONLY)
    assert_equal(c.nodes[find(c, "insert-table")].style, ICON_ONLY)
    assert_equal(c.nodes[tagged(c, "toolbar")[0]].h, RIBBON_BAND_COMPACT_H)
    # helpers: the tab of a tool, every message
    assert_equal(tab_of(t, CHART), 1)
    assert_equal(tab_of(t, LINKS), 1)
    assert_equal(tab_of(t, 999), -1)
    var msgs = ribbon_messages(t)
    assert_equal(len(msgs), 7)
    # an Inspector with on_close: a ✕ tagged panel-close at its head
    var insp = Inspector(["Links"], 0, NO_TAB, [Section("Links", [Text("none")])], 300, on_close=42)
    var x = find(insp, "panel-close")
    assert_true(x > 0 and insp.nodes[x].msg == 42 and insp.nodes[x].style == ICON_ONLY)
    assert_equal(find(Inspector(["Links"], 0, NO_TAB, [Section("Links", [Text("none")])], 300), "panel-close"), -1)
    print("ribbon: ok")


comptime NO_TAB = 0
