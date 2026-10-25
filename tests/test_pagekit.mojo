# mojoui.pagekit and mojoui.beacon: each piece wears its role; taps send their messages; the roles a theme gets cover
# every tag the pieces set.
from std.testing import assert_equal, assert_true
from mojoui import TEXT, BUTTON, CANVAS
from mojoui.pagekit import (PageHeader, GroupItem, HueDot, StatTile, TabStrip, SegButtons, FlatButton, Fact, FactText, SourceLine, NameButton,
    HashMark, QuietAction, Strong, QuietText, BrandName, Mark, Rule, PlaceLink, CardHead, CardFoot, BareCard, Panel, MonoLine, StateWord, page_roles,
    card_roles, more_roles, search_roles, SearchField, SmallButton, MonoStrong, ListRow, small_roles)
from mojoui.beacon import Beacon, Ring, beacon_roles
from mojoui.canvas import Surface
from mojoui.theme import Palette
from mojoui.view import View
from themes.omxqua import omxqua_palette


def tags(v: View) -> List[String]:
    var out = List[String]()
    for n in v.nodes:
        if n.name != "":
            out.append(n.name)
    return out^


def main() raises:
    var p = omxqua_palette(False)
    var roles = List[String]()
    for s in page_roles(p, "Geist Mono") + card_roles(p, "Geist Mono") + more_roles(p, "Geist Mono") + search_roles(p) + small_roles(p, "Geist Mono") + beacon_roles(p, "Geist Mono", p.good):
        roles.append(s.role)
    var tabs = TabStrip(["Overview", "Benchmark"], ["box", "gauge"], 1, 310)
    assert_equal(tabs.nodes[tabs.nodes[0].children[1]].msg, 311)
    assert_equal(tabs.nodes[tabs.nodes[0].children[1]].name, "tab-on")
    var seg = SegButtons(["List", "Cards"], ["list", "layout-grid"], 0, 42)
    assert_equal(seg.nodes[seg.nodes[0].children[1]].msg, 43)
    var row = GroupItem(HueDot(7), "Running", "1", 51, on=True)
    assert_equal(row.nodes[0].name, "group-item-on")
    var tile = StatTile("Requests", "101", "", "last 5 minutes")
    assert_equal(tile.nodes[tile.nodes[0].children[0]].text, "REQUESTS")
    var views: List[View] = [PageHeader("layout-grid", "My models", "3", "3 models", [SourceLine("mxc ls")]), row.copy(), tile.copy(), tabs.copy(), seg.copy(),
                             FlatButton("Stop", 1, "square", filled=True), FlatButton("Remove", 2, "trash-2", danger=True), Fact("Source", FactText("hf")),
                             NameButton("qwen", 3), HashMark(), QuietAction("Edit labels", 4), Strong("2 selected"), QuietText("x"), BrandName("omxconsole", 5),
                             Mark("omx"), Rule(), PlaceLink("Keys", "key-round", 6, here=True), PlaceLink("Gateway", "route", 7), CardHead("History", "1 run"),
                             CardFoot("mxc bench", note=True), Panel([MonoLine("a"), MonoLine("b", quiet=True)]), StateWord("Running", True), StateWord("Idle", False),
                             HueDot(0), HueDot(1), HueDot(2), HueDot(3), HueDot(4), HueDot(5), HueDot(6), Beacon("Pulling helper-7b", "35%", 0, 35), Beacon("1 running", "158 tok/s", live=True),
                             SearchField("", "Search", 41), BareCard([MonoLine("x")]), SmallButton("Run again", 9, "rotate-cw", filled=True), SmallButton("Copy", 10), MonoStrong("42 ms"),
                             ListRow([MonoLine("Oct 25")], on=True), ListRow([MonoLine("Oct 24")])]
    var framework_only: List[String] = ["pill", "badge", "dot", "bare-card"]  # (bare-card: the theme's card with no padding)  # (set by mojoui.chip, styled by the theme's console roles)
    for v in views:
        for t in tags(v):
            var known = t in framework_only or t == "beacon-ring"
            for r in roles:
                if r == t:
                    known = True
            assert_true(known, "no role for tag " + t)
    var b = Beacon("Pulling helper-7b", "35%", 0, 35)
    assert_equal(b.nodes[b.nodes[0].children[0]].kind, CANVAS)
    assert_equal(b.nodes[b.nodes[0].children[1]].text, "Pulling helper-7b")
    # the ring: 35 % of its arc in the accent, from the top, clockwise; the rest the track
    var px = List[UInt32](length=40 * 40, fill=0)
    var s = Surface(Int(px.unsafe_ptr()), 40, 40, 2.0)
    Ring.themed(35, 0xFF00FF00).draw(s)
    var top = s.get(21, 4)  # (just right of the top: the arc starts there, clockwise)
    var left = s.get(4, 20)  # (the left, at 75 %: still the track over the pill)
    assert_true((top >> 8) & 255 > 180 and top & 255 < 60, "the arc isn't at the top")
    assert_true((left >> 8) & 255 < 120, "the arc reaches 75 %: " + hex(Int(left)) + " top " + hex(Int(top)))
    _ = px[0]
    print("pagekit: ok")
