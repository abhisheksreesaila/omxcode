# mojoui.results: a result row (badge in its hue, the name to tap, the quiet line, a mark and a figure), suggestions.
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
from mojoui.results import ResultRow, SourceBadge, SuggestionTile, SuggestionRow
from mojoui.marks import StatusMark, GOOD
from mojoui.view import Text


def main() raises:
    var row = ResultRow("MAX", 3, "qwen2.5-0.5b", 100, "Qwen/Qwen2.5-0.5B-Instruct · 1 GB", StatusMark("fits", GOOD), "~2.2 GB VRAM")
    assert_equal(row.nodes[0].name, "result-row")
    assert_equal(row.nodes[1].name, "source-badge-3")
    assert_equal(row.nodes[tagged(row, "result-name")].msg, 100)
    var t = texts(row)
    assert_equal(t[1], "qwen2.5-0.5b")
    assert_equal(t[3], "fits")
    assert_equal(t[4], "~2.2 GB VRAM")
    assert_equal(len(texts(ResultRow("HF", 4, "a/b", 1, "", StatusMark("size unknown"), ""))), 3)
    var look = omxqua(False).look.copy()
    resolve_layout(row, look)
    assert_equal(row.nodes[1].w, 52)
    covered([row.copy(), SourceBadge("HF", 4), SuggestionRow([SuggestionTile([Text("a")])])])
    print("results: ok")
