# mojoui.fields: the search box (its key hint), the outlined field (its label is the placeholder), the help line, filter
# chips (k sends on_tap + k), a short field.
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
from mojoui.fields import SearchField, OutlinedField, FieldHelp, FieldWithHelp, FilterChips, ShortField


def main() raises:
    var f = OutlinedField("qw", "Search models", on_change=7, on_submit=8)
    var fi = first(f, FIELD)
    assert_equal(f.nodes[fi].hint, "Search models")
    assert_equal(f.nodes[fi].msg, 7)
    assert_equal(f.nodes[fi].msg2, 8)
    var chips = FilterChips(["All", "Fits", "Needs porting"], 1, 40)
    assert_equal(chips.nodes[chips.nodes[0].children[1]].name, "filter-chip-on")
    assert_equal(chips.nodes[chips.nodes[0].children[2]].msg, 42)
    var s = SearchField("", "Search 3 models", 41, key="/")
    assert_equal(texts(s)[len(texts(s)) - 1], "/")
    var short = ShortField("", "App name", 5)
    var look = omxqua(False).look.copy()
    resolve_layout(short, look)
    assert_equal(short.nodes[0].w, 260)
    covered([f.copy(), FieldHelp("help"), FieldWithHelp(f.copy(), "help"), chips.copy(), s.copy(), short.copy(), ShortField("", "x", 1, compact=True)])
    print("fields: ok")
