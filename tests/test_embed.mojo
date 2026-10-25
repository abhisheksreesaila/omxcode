# mojoui.embed: a WebFrame holds its URL, its version, its height, the browser's URL (hint) and the stand-in child.
from std.testing import assert_equal, assert_true, assert_false
from mojoui import Text, VStack, EMBED
from mojoui.embed import WebFrame
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
    print("embed: ok")
