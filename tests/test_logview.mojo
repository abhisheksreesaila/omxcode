# mojoui.logview: a Scroll pinned to its end, one mono line per log line, an empty pane's note.
from std.testing import assert_equal, assert_true
from mojoui import TEXT, SCROLL
from mojoui.logview import LogView


def main() raises:
    var lines: List[String] = ["12:02:11.204 INFO: Starting server", "", "  indented"]
    var v = LogView(lines, height=240)
    assert_equal(v.nodes[0].kind, SCROLL)
    assert_equal(v.nodes[0].value, 1)  # pinned to its end
    assert_equal(v.nodes[0].size, 240)
    assert_equal(v.nodes[0].name, "log")
    var texts = List[String]()
    for n in v.nodes:
        if n.kind == TEXT:
            texts.append(n.text)
    assert_equal(len(texts), 3)
    assert_equal(texts[0], "12:02:11.204 INFO: Starting server")
    assert_equal(texts[1], chr(160))  # (an empty line keeps its height)
    assert_true(texts[2].startswith(chr(160) + chr(160)))
    var empty = LogView(List[String](), empty="No lines yet")
    var said = String("")
    for n in empty.nodes:
        if n.kind == TEXT:
            said = n.text
    assert_equal(said, "No lines yet")
    print("logview: ok")
