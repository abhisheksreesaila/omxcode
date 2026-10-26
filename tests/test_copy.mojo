# mojoui.copy: a copy row (the tag in capitals; an icon button, or a text one), a labeled value with its link, a code
# panel (its copy button says copied, its Clipboard holds the code), a secret (with its Copy).
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
from mojoui.copy import CopyRow, LabeledValue, CodePanel, SecretField



def main() raises:
    var row = CopyRow("https · lan", "https://box.local:8443/v1", 6403, "Copy")
    assert_equal(texts(row)[0], "HTTPS · LAN")
    assert_equal(row.nodes[tagged(row, "copy-text")].msg, 6403)
    assert_true(tagged(CopyRow("local", "http://x", 1), "copy-icon") > 0)
    var lv = LabeledValue("API key", "$MXC_API_KEY", "manage keys", 351)
    assert_equal(lv.nodes[tagged(lv, "link")].msg, 351)
    var code = CodePanel("curl x", 326, copies=2, copied=True)
    assert_equal(code.nodes[tagged(code, "code-panel-copy")].text, "copied")
    var ci = first(code, CLIPBOARD)
    assert_equal(code.nodes[ci].text, "curl x")
    assert_equal(code.nodes[ci].value, 2)
    var sec = SecretField("mst-abc", "Copy", 9)
    assert_equal(sec.nodes[0].name, "secret-row")
    covered([row.copy(), CopyRow("local", "x", 1), lv.copy(), LabeledValue("a", "b"), code.copy(), sec.copy(), SecretField("mst-abc")], ["secret-row"])
    print("copy: ok")
