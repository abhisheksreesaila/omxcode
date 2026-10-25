# mojoui.confirm: the first tap arms, the second acts; another action's tap moves the arming; it disarms; its timer.
from std.testing import assert_equal, assert_true, assert_false
from mojoui.confirm import TwoStep, ConfirmButton


def main() raises:
    var t = TwoStep()
    assert_false(t.is_armed(0))
    assert_equal(len(t.every(9)), 0)
    assert_false(t.tap(0))  # armed only
    assert_true(t.is_armed(0))
    assert_equal(len(t.every(9)), 1)
    assert_equal(t.every(9)[0].msg, 9)
    assert_equal(t.every(9)[0].ms, 4000)
    assert_false(t.tap(1))  # another row's tap arms that one instead
    assert_false(t.is_armed(0))
    assert_true(t.tap(1))  # the second tap acts
    assert_false(t.is_armed(1))
    assert_false(t.tap(2))
    t.disarm()
    assert_false(t.tap(2))  # after disarming, a tap arms again rather than acting
    var b = ConfirmButton("Revoke", "Click again to revoke", False, 50, icon="trash")
    assert_equal(b.nodes[0].text, "Revoke")
    assert_equal(b.nodes[0].name, "confirm")
    assert_equal(b.nodes[0].msg, 50)
    var a = ConfirmButton("Revoke", "Click again to revoke", True, 50, icon="trash")
    assert_equal(a.nodes[0].text, "Click again to revoke")
    assert_equal(a.nodes[0].name, "confirm-armed")
    print("confirm: ok")
