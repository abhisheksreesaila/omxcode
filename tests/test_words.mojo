# mojoui.words: lines in the theme's voices; a command line with its faint $; command lines one under another.
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
from mojoui.words import QuietText, Strong, MonoLine, MonoStrong, MonoText, CommandLine, CommandLines, ErrorLine, WarnLine


def main() raises:
    var c = CommandLine("mxc ls")
    assert_equal(texts(c)[0], "$")
    assert_equal(texts(c)[1], "mxc ls")
    assert_equal(len(CommandLines(["mxc stop a", "mxc rm a"]).nodes[0].children), 2)
    assert_equal(MonoLine("x", quiet=True).nodes[0].name, "mono-faint")
    covered([QuietText("a"), Strong("b"), MonoLine("c"), MonoLine("d", quiet=True), MonoStrong("e"), MonoText("f"), c.copy(), CommandLines(["x"]),
             ErrorLine("g"), WarnLine("h")])
    print("words: ok")
