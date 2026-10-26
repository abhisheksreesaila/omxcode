# mojoui.panel: a card (head with a lead and a tail, body, foot, copy foot), a stack of cards, panels and their grid
# (compact: one column), stat tiles (label in capitals, the unit on the baseline), facts with key columns, list rows.
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
        if n.kind == TEXT or n.kind == BUTTON or n.kind == PARAGRAPH:
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
from mojoui.paragraph import runs_of
from mojoui.view import PARAGRAPH
from mojoui.panel import (Card, CardHead, CardBody, CardFoot, CopyFoot, CardNote, CardStack, CardColumn, TabBody, ListRow, ColumnRow, Panel, PanelTitle,
    PanelFoot, PanelRow, PanelGrid, StatTile, StatGrid, Fact, FactText, FactLink, FactList, LabeledRow, KEYS_NARROW, KEYS_WIDEST)
from mojoui.view import Text, Button, BASELINE


def main() raises:
    var head = CardHead("Secure", sub="HTTPS with a key", lead=[Text("[lock]")], tail=[Text("secure")])
    assert_equal(head.nodes[0].name, "card-head")
    assert_true(tagged(head, "card-sub") > 0)
    var foot = CopyFoot("mxc status", 6210)
    assert_equal(foot.nodes[foot.nodes[0].children[0]].text, "$ mxc status")
    assert_equal(foot.nodes[tagged(foot, "foot-copy")].msg, 6210)
    assert_equal(texts(CardFoot("kept here", note=True))[0], "↳ kept here")  # (one Paragraph: still its words whole, D-483)
    var marks = runs_of(foot.nodes[foot.nodes[0].children[0]])
    assert_equal(len(marks), 3)
    assert_equal(marks[0].role, "foot-mark")  # (the $ quieter than the words, .src::before opacity .6)
    assert_equal(marks[1].role, "foot-gap")  # (the space as wide as the look's gap)
    var tile = StatTile("Speed", "158", "tok/s", "decode, median")
    assert_equal(tile.nodes[tile.nodes[0].children[0]].text, "SPEED")
    assert_equal(tile.nodes[tagged(tile, "stat-number")].align_items, BASELINE)
    var grid = StatGrid([tile.copy(), tile.copy(), tile.copy()], columns=2)
    assert_equal(len(grid.nodes[0].children), 2)  # (rows of two)
    var fact = Fact("Certificate", FactText("a local CA"), KEYS_NARROW)
    assert_true(tagged(fact, "fact-key-narrow") > 0)
    var look = omxqua(False).look.copy()
    resolve_layout(fact, look)
    assert_equal(fact.nodes[tagged(fact, "fact-key-narrow")].w, look.surfaces[look.surface("fact-key-narrow")].width)
    var row = PanelRow([Panel([PanelTitle("gauge", "Right now", 1)]), Panel([PanelFoot("mxc status")])])
    assert_equal(row.nodes[0].name, "panel-row")
    assert_equal(PanelRow([Panel([Text("a")])], compact=True).nodes[0].name, "panel-column")
    covered([Card([head.copy(), CardBody([Text("x")]), foot.copy()]), CardNote("Loading…"), CardStack([Text("x")]), CardColumn([Text("x")]),
             TabBody(Text("head"), [Text("x")]), TabBody(Text("head"), [Text("x")], compact=True, tight=True), TabBody(Text("head"), [Text("x")], flush=True), ListRow([Text("x")], on=True), ColumnRow([Text("Oct 25"), Text("3 models")], Text("best")), ColumnRow([Text("Oct 25")], Text("best"), compact=True), CardBody([Text("a"), Text("b")], flow=True),
             PanelGrid([row.copy()]), PanelGrid([Text("x")], compact=True), grid.copy(), FactList([fact.copy(), Fact("x", FactLink("Security ›", 1), KEYS_WIDEST)]),
             LabeledRow("Linux", Text("sudo …")), LabeledRow("macOS", Text("Open …"), compact=True)], ["[lock]", "head"])
    print("panel: ok")
