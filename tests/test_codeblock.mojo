# mojoui.codeblock: lines in order (indents kept), a Copy button that says Copied, a Clipboard holding the code.
from std.testing import assert_equal, assert_true
from mojoui import TEXT, BUTTON
from mojoui.view import CLIPBOARD
from mojoui.codeblock import CodeBlock, keep_spaces


def main() raises:
    var code = "curl http://127.0.0.1:11435/v1/chat/completions \\\n  -H 'Content-Type: application/json'"
    var v = CodeBlock(code, on_copy=7, copies=3)
    assert_equal(v.nodes[0].name, "code-block")
    var texts = List[String]()
    var button = -1
    var clip = -1
    for i in range(len(v.nodes)):
        if v.nodes[i].kind == TEXT:
            texts.append(v.nodes[i].text)
        if v.nodes[i].kind == BUTTON:
            button = i
        if v.nodes[i].kind == CLIPBOARD:
            clip = i
    assert_equal(len(texts), 2)
    assert_equal(texts[1], keep_spaces("  -H 'Content-Type: application/json'"))
    assert_true(texts[1].startswith(chr(160) + chr(160) + "-H"))  # (the indent survives reflowing)
    assert_equal(v.nodes[button].text, "Copy")
    assert_equal(v.nodes[button].msg, 7)
    assert_equal(v.nodes[button].hint, "copy")
    assert_equal(v.nodes[button].name, "code-copy")
    assert_equal(v.nodes[clip].text, code)
    assert_equal(v.nodes[clip].value, 3)
    var done = CodeBlock(code, on_copy=7, copies=4, copied=True)
    for n in done.nodes:
        if n.kind == BUTTON:
            assert_equal(n.text, "Copied")
    print("codeblock: ok")
