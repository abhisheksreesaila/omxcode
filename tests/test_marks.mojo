# mojoui.marks: a dot in a hue, a signal dot (k wraps), a status in a tone (live: ringed), an icon in a hue.
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
from mojoui.marks import HueDot, SignalDot, StatusMark, HueIcon, QUIET, GOOD, WARN, BAD, INFO


def main() raises:
    assert_equal(SignalDot(6).nodes[0].name, "signal-dot-1")
    assert_equal(HueDot(9).nodes[0].name, "hue-dot-8")
    var st = StatusMark("200", BAD, mono=True)
    assert_equal(tags(st)[0], "status-mark")
    assert_equal(tags(st)[1], "status-dot-bad")
    assert_equal(tags(st)[2], "status-mono-bad")
    assert_equal(StatusMark("Running", GOOD, live=True).nodes[1].name, "status-dot-live-good")
    var look = omxqua(False).look.copy()
    var dot = SignalDot(2)
    resolve_layout(dot, look)
    assert_equal(dot.nodes[0].w, 9)
    covered([st.copy(), StatusMark("idle"), StatusMark("working", WARN), StatusMark("needs porting", INFO), HueDot(0), HueDot(7), SignalDot(5),
             HueIcon("gauge", 15, 1), HueIcon("box", 15, 0)])
    print("marks: ok")
