# mojoui.embed: a WebFrame holds its URL, its version, its height, the browser's URL (hint) and the stand-in child.
from std.testing import assert_equal, assert_true, assert_false
from mojoui import Text, VStack, EMBED
from mojoui.embed import WebFrame, is_web_url
from mojoui.diff import diff, SET_VALUE


def main() raises:
    var f = WebFrame("http://127.0.0.1:8888/doc/tree/q.ipynb", 1, Text("Opened in your browser"), height=640,
                     open_url="http://127.0.0.1:8888/lab/tree/q.ipynb")
    assert_equal(f.nodes[0].kind, EMBED)
    assert_equal(f.nodes[0].text, "http://127.0.0.1:8888/doc/tree/q.ipynb")
    assert_equal(f.nodes[0].hint, "http://127.0.0.1:8888/lab/tree/q.ipynb")
    assert_equal(f.nodes[0].value, 1)
    assert_equal(f.nodes[0].size, 640)
    assert_equal(f.nodes[f.nodes[0].children[0]].text, "Opened in your browser")
    var a = VStack(WebFrame("http://a", 1, Text("s")))
    var b = VStack(WebFrame("http://a", 2, Text("s")))
    var d = diff(a, b)
    assert_false(d.rebuild)  # (opened again: the version is a patch)
    assert_equal(d.patches[0].op, SET_VALUE)
    assert_true(diff(a, VStack(WebFrame("http://b", 1, Text("s")))).rebuild)  # (another page: built again)
    # what a host opens or frames: http and https with a host only (D-576)
    for ok in ["http://127.0.0.1:8888/lab", "https://example.com", "HTTPS://Example.com/a?b#c", "http://h"]:
        assert_true(is_web_url(ok), ok)
    for bad in ["javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,x", "file:///etc/passwd", "vscode://x", "", "http://",
                "https:///path", "http://?q", " http://a", "http://a b", "http://a\nb", "http://a\x7f", "//example.com", "mailto:a@b"]:
        assert_false(is_web_url(bad), bad)
    # the web's sandbox: nothing asked, no options; tokens asked for travel in options[0] (the host allowlists them, D-606)
    assert_equal(len(f.nodes[0].options), 0)
    var asked = WebFrame("http://127.0.0.1:8888/lab", 1, Text("s"), sandbox="allow-same-origin")
    assert_equal(asked.nodes[0].options[0], "allow-same-origin")
    # its permissions travel in options[1] (none asked: no options[1]; the web host allowlists them, D-617)
    assert_equal(len(asked.nodes[0].options), 1)
    var clip = WebFrame("http://127.0.0.1:8888/lab", 1, Text("s"), allow="clipboard-read")
    assert_equal(clip.nodes[0].options[0], "")
    assert_equal(clip.nodes[0].options[1], "clipboard-read")
    print("embed: ok")
