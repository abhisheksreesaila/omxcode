# mojoui.buttons: flat pills (filled, danger, a hued icon, square), the loud one (compact: its icon), small pills in four
# looks (dimmed send nothing, armed only for danger), quiet actions, a name link, a link, Back, a row of buttons.
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
from mojoui.buttons import FlatButton, PrimaryButton, SmallButton, TextAction, NameLink, LinkButton, BackButton, ButtonRow, TONAL, FILL, TEXT as TEXT_LOOK, DANGER


def main() raises:
    assert_equal(FlatButton("Restart", 321, "rotate-cw", hue=8).nodes[0].name, "flat-8")
    assert_equal(FlatButton("Stop", 320, "square", filled=True).nodes[0].name, "flat-fill")
    var rev = SmallButton("Revoke", 6100, "trash-2", DANGER)
    assert_equal(rev.nodes[0].name, "small-danger")
    assert_equal(rev.nodes[0].msg, 6100)
    assert_equal(SmallButton("Click again", 6100, "trash-2", DANGER, armed=True).nodes[0].name, "small-danger-armed")
    var off = SmallButton("Revoke", 6101, "trash-2", DANGER, off=True)
    assert_equal(off.nodes[0].name, "small-danger-off")
    assert_equal(off.nodes[0].msg, NO_MSG)
    assert_equal(SmallButton("Rotate", 1, "rotate-cw", TONAL, armed=True).nodes[0].name, "small-tonal")
    var back = BackButton(5)
    assert_equal(back.nodes[0].hint, "back")
    var look = omxqua(False).look.copy()
    resolve_layout(back, look)
    assert_equal(back.nodes[0].w, 76)
    covered([FlatButton("a", 1), FlatButton("b", 2, danger=True), FlatButton("Copy", 3, "copy", square=True), PrimaryButton("Add", 4, "plus"),
             PrimaryButton("Add", 4, "plus", compact=True), rev.copy(), off.copy(), SmallButton("a", 1, "", FILL), SmallButton("b", 2, "", TEXT_LOOK),
             SmallButton("c", 3, "", FILL, off=True), SmallButton("d", 4, "", TEXT_LOOK, off=True), SmallButton("e", 5, "", TONAL, off=True),
             TextAction("Edit labels", 6), NameLink("qwen", 7), LinkButton("manage keys", 8), back.copy(), ButtonRow([rev.copy()])])
    print("buttons: ok")
