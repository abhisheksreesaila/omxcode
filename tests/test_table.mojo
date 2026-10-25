# mojoui.table: a header in capitals, cells row by row, tick boxes that say their row, selected rows.
#   scripts/mxbuild.sh tests/test_table.mojo -o build/test_table && build/test_table
from std.testing import assert_equal, assert_true
from mojoui import Text, View, TEXT, TOGGLE
from mojoui.view import TABLE
from mojoui.table import Table, capitals


def main() raises:
    assert_equal(capitals("First token · tok/s"), "FIRST TOKEN · TOK/S")
    var cells: List[View] = [Text("qwen"), Text("988 MB"), Text("llama"), Text("2.5 GB"), Text("minilm")]  # (a short last row)
    var t = Table(["Model", "Size"], cells, align="LR")
    assert_equal(t.nodes[0].kind, TABLE)
    assert_equal(t.nodes[0].value, 2)
    assert_equal(t.nodes[0].hint, "LR")
    assert_equal(len(t.nodes[0].children), 8)  # header 2 + 3 rows × 2 (the last filled with a blank)
    assert_equal(t.nodes[t.nodes[0].children[0]].text, "MODEL")
    assert_equal(t.nodes[t.nodes[0].children[3]].text, "988 MB")
    assert_equal(t.nodes[t.nodes[0].children[7]].text, "")
    assert_equal(t.nodes[0].text, "000")  # nothing selected
    # ticks: a first column of boxes, row r's sends on_tick + r, the header's ticks all; ticked rows are selected
    var ticked: List[Bool] = [True, False, True]
    var k = Table(["Model", "Size"], cells, align="LR", ticked=ticked, on_tick=100, on_tick_all=99)
    assert_equal(k.nodes[0].value, 3)
    assert_equal(k.nodes[0].hint, "LLR")
    assert_equal(k.nodes[0].text, "101")
    var all = k.nodes[k.nodes[0].children[0]].copy()
    assert_equal(all.kind, TOGGLE)
    assert_equal(all.msg, 99)
    assert_equal(all.value, 0)  # not every row ticked
    assert_equal(all.name, "tick-all")
    var row2 = k.nodes[k.nodes[0].children[3 * 3]].copy()  # row 2's first cell (header row is 0)
    assert_equal(row2.kind, TOGGLE)
    assert_equal(row2.msg, 102)
    assert_equal(row2.value, 1)
    assert_equal(row2.name, "tick-2")
    var one: List[View] = [Text("a")]
    var full = Table(["Model"], one, ticked=[True], on_tick=10, on_tick_all=9)
    assert_equal(full.nodes[full.nodes[0].children[0]].value, 1)  # every row ticked: the header's box is too
    # selected without ticks
    var two: List[View] = [Text("1"), Text("2")]
    var s = Table(["A"], two, selected=[False, True])
    assert_equal(s.nodes[0].text, "01")
    print("table: ok")
