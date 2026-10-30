# mojoui.regions + the graphite skin (goal 41 M5): the framework's shells name the window's regions (a test, a screen
# reader's landmarks), and graphite rings every one of them in a hairline on mid-dark omxqua surfaces.
#   pixi run mojo run -I . tests/test_regions.mojo
# (The pixels are checked on the real app: scripts/check M5 runs omxplorer headless on GTK and the web.)
from std.testing import assert_equal, assert_true
from mojoui.view import View, VStack, HStack, Text, Button, Canvas, Card, Board, Spacer, HEADLINE, ICON_ONLY
from mojoui.sheetchrome import Toolbar, StatusBar, Rail, Tool
from mojoui.inspector import Inspector, Section
from mojoui.regions import regions, region_of
from mojoui.theme import Palette
from themes.skins import graphite, graphite_palette, ledger, SHEET
from mojoui.theme import hx


def lum(c: UInt32) -> Float64:
    """The check's luminance: Rec. 709 weights over the 0–1 channel values (RGBA, R in the low byte)."""
    var r = Float64(c & 0xFF) / 255.0
    var g = Float64((c >> 8) & 0xFF) / 255.0
    var b = Float64((c >> 16) & 0xFF) / 255.0
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def main() raises:
    # regions: the shells' roles, the board as the sheet, each titled board object as a card (the cell editor isn't one)
    var no_tools = List[Tool]()
    var cards: List[View] = [
        Card(Text("dock.mp4", HEADLINE), Canvas(1, 1)).at(0, 0).width(300).height(200).tag("video0"),
        VStack(HStack(Text("shipments", HEADLINE), Spacer()), Canvas(2, 1)).at(320, 0).width(300).height(200).tag("table"),
        Text("12.5").at(10, 10).width(80).height(30).tag("cell-editor"),
    ]
    var page = VStack(
        Toolbar(no_tools, [Tool("Chart", "chart-bar", 1, False, "")], no_tools),
        HStack(Rail([Button("Table", 2, ICON_ONLY, icon="table")]), Board(cards^, 700, 400).fill().grow(),
               Inspector(["Table", "Cell"], 0, 3, [Section("Table", [Text("Rows")])])),
        StatusBar(["Rows 14"]),
    )
    var names = String("")
    for r in regions(page):
        names += r.name + ";"
    assert_equal(names, "toolbar;sidebar;sheet;card:dock.mp4;card:shipments;inspector;status;")
    assert_equal(region_of("status-bar"), "status")
    assert_equal(region_of("grid"), "")
    print("regions: ok")

    # graphite: mid-dark surfaces (the check's page mean 0.10–0.30), the omxqua green, a hairline that steps ≥ 0.04 off
    # every surface it rings, the sheet a tone of its own; ledger keeps its look (no rings)
    var p = graphite_palette()
    assert_true(p.dark)
    assert_equal(p.accent, hx("#3ccf6e"))
    assert_equal(p.good, hx("#3ccf6e"))
    assert_equal(p.bad, hx("#f2555a"))
    assert_equal(p.warn, hx("#f5a524"))
    for c in [p.page, p.card, p.raised, p.chrome, hx(SHEET)]:
        assert_true(0.10 <= lum(c) <= 0.30, "a mid-dark surface")
        assert_true(abs(lum(p.line) - lum(c)) >= 0.04, "the hairline shows on every surface")
    var t = graphite()
    var ringed = 0
    for s in t.look.surfaces:
        if (s.role == "toolbar" or s.role == "status-bar" or s.role == "sidebar") and s.outline == p.line and s.outline_w == 1:
            ringed += 1
    assert_equal(ringed, 3)
    assert_true(t.gtk_css.find(".mui-board-scroll { border: 1px solid") >= 0 and t.gtk_css.find(".mui-board > * { border: 1px solid") >= 0, "GTK rings the sheet and its cards")
    assert_true(t.web_css.find(".board-scroll { border: 1px solid") >= 0 and t.web_css.find(".board > .object:not([data-tag=cell-editor]) { border: 1px solid") >= 0, "the web too")
    assert_true(ledger().gtk_css.find("mui-board-scroll") < 0, "ledger isn't bordered")
    print("graphite: ok")
