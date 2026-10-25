# mojoui.skeleton: a bar of the asked height, its width fixed or its stack's; the role themes shape.
from std.testing import assert_equal, assert_true, assert_false
from mojoui import VSTACK
from mojoui.skeleton import Skeleton


def main() raises:
    var s = Skeleton()
    assert_equal(s.nodes[0].kind, VSTACK)
    assert_equal(s.nodes[0].name, "skeleton")
    assert_equal(s.nodes[0].h, 12)
    assert_true(s.nodes[0].fills)
    var w = Skeleton(width=180, height=20)
    assert_equal(w.nodes[0].w, 180)
    assert_equal(w.nodes[0].h, 20)
    assert_false(w.nodes[0].fills)
    print("skeleton: ok")
