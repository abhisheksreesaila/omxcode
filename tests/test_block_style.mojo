# A block of cells formatted at once (goal 24 M5): Sheet.restyle_cells reaches every cell of the block and nothing
# outside it, Undo takes the whole block back in one step, a second format is its own step.
#   scripts/mxbuild.sh tests/test_block_style.mojo -o build/test_block_style && build/test_block_style
from std.testing import assert_true, assert_false
from omxcore import Table, TEXT as MX_TEXT, DECIMAL as MX_DECIMAL
from mojoui.sheet import Sheet
from mojoui.cellstyle import BOLD, ITALIC


def table() raises -> Table:
    var t = Table.empty()
    var name = t.add_column("name", MX_TEXT)
    var amount = t.add_column("amount", MX_DECIMAL, 2)
    _ = t.add_word(name, "Hello")
    for k in range(10):
        t.append(name, 0)
        t.append(amount, Int64(100 * k))
    return t^


def main() raises:
    var s = Sheet(table().share(), False)
    var block = List[Tuple[Int, Int]]()
    for row in range(2, 5):  # rows 2–4, both columns: 6 cells
        for c in range(2):
            block.append((c, row))
    s.restyle_cells(block, BOLD, BOLD)
    for row in range(10):
        for c in range(2):
            var inside = 2 <= row <= 4
            assert_true(s.style_of(c, row).bold() == inside, "bold only inside the block: column " + String(c) + " row " + String(row))
    s.restyle_cells(block, ITALIC, ITALIC)
    assert_true(s.undo())  # the italics, one step
    for row in range(2, 5):
        for c in range(2):
            assert_true(s.style_of(c, row).bold() and not s.style_of(c, row).italic(), "one Undo takes the italics off every cell")
    assert_true(s.undo())  # the bold, one step
    for row in range(10):
        for c in range(2):
            assert_false(s.style_of(c, row).bold(), "one more Undo takes the bold off every cell")
    print("BLOCK STYLE TESTS PASSED")
