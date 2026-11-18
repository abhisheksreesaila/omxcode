# Markdown drawn and edited natively (goal 74 M3): each style drawn with its size, weight, slant, tint or block, read
# from the Scene a paint records; the marks hidden off the caret's paragraph and shown on it; a click on a task box
# ticks it (and undo unticks it); Enter continues a list.
#   pixi run mojo run -I . tests/test_mdedit.mojo
from std.testing import assert_equal, assert_true, assert_false

from mojoui.mdedit import MdEdit
from mojoui.textedit import Pos, CTRL
from mojoui.text import Font, MEDIUM, MONO
from mojoui.scene import Scene

comptime DOC = """# Groceries
Buy **fresh** bread and *ripe* fruit, see [the list](https://x.y) and `code`.
- [ ] milk
- [x] eggs
- apples
1. first
> quoted words
---
```
let x = 1
```
~~gone~~ end"""


def text_op(sc: Scene, text: String) -> Int:
    """The first text op drawing exactly `text`, -1 if none."""
    for op in range(sc.ops()):
        if sc.text_at(op) == text:
            return op
    return -1


def has_note(sc: Scene, start: String) -> Bool:
    for ref n in sc.notes:
        if n.startswith(start):
            return True
    return False


def paint(mut md: MdEdit, font: Font) -> Scene:
    var sc = Scene(800, 700, 1.0)
    md.paint(sc, font, 0, 0, True)
    return sc^


def main() raises:
    var font = Font()
    var md = MdEdit(DOC, 16)
    md.ed.resize(800, 700)
    # The caret on the last paragraph: everything else shows as Markdown.
    md.ed.caret = Pos(len(md.ed.paras) - 1, 0)
    md.ed.anchor = md.ed.caret
    var sc = paint(md, font)
    var h1 = text_op(sc, "Groceries")
    assert_true(h1 >= 0)
    assert_true(abs(sc.num(h1, 2) - 16 * 1.9) < 0.01)  # (size)
    assert_equal(Int(sc.num(h1, 4)), MEDIUM)  # (weight)
    var bold = text_op(sc, "fresh")
    assert_equal(Int(sc.num(bold, 4)), MEDIUM)
    var it = text_op(sc, "ripe")
    assert_true(sc.num(it, 3) > 0.1)  # (slant)
    var code = text_op(sc, "code")
    assert_equal(Int(sc.num(code, 4)), MONO)
    assert_true(has_note(sc, "run p link the list"))
    assert_true(has_note(sc, "marker task 2"))
    assert_true(has_note(sc, "marker done 3"))
    assert_true(has_note(sc, "marker bullet 4"))
    assert_true(has_note(sc, "marker number 5"))
    assert_true(has_note(sc, "run quote text quoted words"))
    assert_true(has_note(sc, "run code code let x = 1"))
    assert_true(has_note(sc, "run p strike gone"))
    var gone = text_op(sc, "gone")
    assert_true(gone >= 0)
    var struck = False  # (the strike line: a thin rect right after the word's text op, across its middle)
    if gone + 1 < sc.ops():
        struck = sc.text_at(gone + 1) == "" and sc.num(gone + 1, 3) < 2
    assert_true(struck)
    print("mdedit styles: ok")

    # Marks: hidden off the caret's paragraph, drawn on it.
    assert_true(has_note(sc, "hidden mark # "))
    assert_true(has_note(sc, "hidden mark **"))
    assert_true(has_note(sc, "hidden mark - [ ] "))
    assert_true(text_op(sc, "# ") < 0)
    assert_true(text_op(sc, "**") < 0)
    md.ed.caret = Pos(0, 3)
    md.ed.anchor = md.ed.caret
    var on_h1 = paint(md, font)
    assert_true(text_op(on_h1, "# ") >= 0)
    assert_true(has_note(on_h1, "run h1 mark # "))
    assert_true(text_op(on_h1, "**") < 0)  # (only the caret's paragraph shows its marks)
    md.ed.caret = Pos(1, 5)
    md.ed.anchor = md.ed.caret
    var on_p = paint(md, font)
    assert_true(text_op(on_p, "**") >= 0)
    assert_true(text_op(on_p, "# ") < 0)
    print("mdedit marks: ok")

    # Task: a click on the open box ticks it; undo unticks; Enter after a task starts the next one.
    md.ed.caret = Pos(len(md.ed.paras) - 1, 0)
    md.ed.anchor = md.ed.caret
    _ = paint(md, font)
    var y = 0.0
    for k in range(2):
        md.ed.lay(k, font, md.st)
        y += md.ed.laid[k].height
    y += md.ed.pad_y + 10
    var ticked = md.press(md.ed.pad_x + 10, y, False, font)
    assert_true(ticked)
    assert_equal(md.ed.paras[2], "- [x] milk")
    var after = paint(md, font)
    assert_true(has_note(after, "marker done 2"))
    _ = md.key("z", CTRL, 10_000, font)
    assert_equal(md.ed.paras[2], "- [ ] milk")
    md.ed.caret = Pos(2, md.ed.paras[2].byte_length())
    md.ed.anchor = md.ed.caret
    _ = md.key("Enter", 0, 20_000, font)
    assert_equal(md.ed.paras[3], "- [ ] ")
    _ = md.key("e", 0, 20_100, font)
    assert_equal(md.ed.paras[3], "- [ ] e")
    print("mdedit task: ok")
