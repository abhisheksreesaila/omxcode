# mojoui.document: markdown and code cells, an outline (numbered, chapter k sends on_tap + k, its level), spec rows, the
# three-column layout (compact: one column, no outline).
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
            if t in skip or t.startswith("md-"):  # (mojoui.markdown's own parts)
                continue
            assert_true(look.surface(t) >= 0, "no role for tag " + t)
from mojoui.document import MarkdownCell, CodeCell, Outline, SpecRows, SpecTitle, DocLayout
from mojoui.view import Text


def main() raises:
    var o = Outline("Chapters", ["Intro", "Usage"], [1, 2], 400)
    assert_equal(texts(o)[0], "CHAPTERS")
    assert_true(tagged(o, "chapter-2") > 0)
    assert_equal(o.nodes[tagged(o, "chapter-2")].msg, 401)
    var code = CodeCell("[3]", "print(1)")
    assert_equal(texts(code)[0], "[3]")
    var spec = SpecRows(["hidden_size", "layers"], ["896", "24"])
    assert_equal(SpecTitle("Qwen2ForCausalLM").nodes[0].name, "spec-title")
    assert_equal(len(spec.nodes[0].children), 4)  # (a two-column grid: key, value, key, value)
    assert_equal(spec.nodes[0].options, ["52", "48"])  # (the keys' column 52 % of the width, as the original's th)
    var small = DocLayout(o.copy(), Text("cells"), Text("aside"), compact=True)
    assert_equal(first(small, TEXT) >= 0, True)
    for n in small.nodes:  # (compact: the cells alone, as the original hides its side panels and outline on a narrow page)
        assert_true(n.text != "aside" and n.text != "CHAPTERS")
    covered([MarkdownCell("# Hi"), code.copy(), o.copy(), spec.copy(), SpecTitle("x"), DocLayout(o.copy(), Text("cells"), Text("aside")),
             DocLayout(o.copy(), Text("cells"), Text("aside"), compact=True)], ["cells", "aside", "markdown", "md-h1", "md-p"])
    print("document: ok")
