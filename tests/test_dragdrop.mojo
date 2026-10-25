# mojoui.dragdrop: a Draggable carries its payload (text), a DropTarget its on_drop (msg); each holds its one child; a new
# payload rebuilds rather than patches (hosts set a drag's content when they build it).
from std.testing import assert_equal, assert_true, assert_false
from mojoui import Text, VStack, DRAG, DROP
from mojoui.dragdrop import Draggable, DropTarget
from mojoui.diff import diff


def main() raises:
    var d = Draggable(Text("all-minilm-l6"), "all-minilm-l6\nllama3.2-1b").tag("row-all-minilm-l6")
    assert_equal(d.nodes[0].kind, DRAG)
    assert_equal(d.nodes[0].text, "all-minilm-l6\nllama3.2-1b")
    assert_equal(d.nodes[0].name, "row-all-minilm-l6")
    assert_equal(len(d.nodes[0].children), 1)
    assert_equal(d.nodes[d.nodes[0].children[0]].text, "all-minilm-l6")
    var t = DropTarget(Text("work"), on_drop=101).tag("label-work")
    assert_equal(t.nodes[0].kind, DROP)
    assert_equal(t.nodes[0].msg, 101)
    assert_equal(t.nodes[t.nodes[0].children[0]].text, "work")
    var a = VStack(Draggable(Text("x"), "one"), DropTarget(Text("y"), 7))
    var b = VStack(Draggable(Text("x"), "two"), DropTarget(Text("y"), 7))
    assert_true(diff(a, b).rebuild)  # (a new payload: built again)
    var c = VStack(Draggable(Text("x"), "one"), DropTarget(Text("y"), 8))
    assert_false(diff(a, c).rebuild)  # (a new on_drop: a patch)
    print("dragdrop: ok")
