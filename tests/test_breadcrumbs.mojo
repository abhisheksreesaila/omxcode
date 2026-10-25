# mojoui.breadcrumbs: earlier parts are buttons sending on_tap + k, chevrons between, the last is text (mono if asked).
from std.testing import assert_equal
from mojoui import TEXT, BUTTON, ICON
from mojoui.breadcrumbs import Breadcrumbs


def main() raises:
    var v = Breadcrumbs(["My models", "qwen2.5-0.5b"], on_tap=40, mono_last=True)
    assert_equal(v.nodes[0].name, "breadcrumbs")
    var kinds = List[Int]()
    for c in v.nodes[0].children:
        kinds.append(v.nodes[c].kind)
    assert_equal(len(kinds), 3)
    assert_equal(kinds[0], BUTTON)
    assert_equal(kinds[1], ICON)
    assert_equal(kinds[2], TEXT)
    ref first = v.nodes[v.nodes[0].children[0]]
    assert_equal(first.text, "My models")
    assert_equal(first.msg, 40)
    assert_equal(first.name, "crumb")
    assert_equal(v.nodes[v.nodes[0].children[1]].text, "chevron-right")
    ref here = v.nodes[v.nodes[0].children[2]]
    assert_equal(here.text, "qwen2.5-0.5b")
    assert_equal(here.name, "crumb-here-mono")
    var three = Breadcrumbs(["A", "B", "C"], on_tap=10)
    assert_equal(three.nodes[three.nodes[0].children[2]].msg, 11)  # the second part sends on_tap + 1
    assert_equal(three.nodes[three.nodes[0].children[4]].name, "crumb-here")
    var one = Breadcrumbs(["API keys"], on_tap=10)
    assert_equal(len(one.nodes[0].children), 1)
    print("breadcrumbs: ok")
