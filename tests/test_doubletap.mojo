# mojoui.doubletap: Personal Note's double-tap.test.js cases.
#   pixi run mojo run -I . tests/test_doubletap.mojo
from std.testing import assert_true
from std.sys import CompilationTarget
from mojoui.doubletap import DoubleTap


def K() -> String:
    comptime if CompilationTarget.is_macos():
        return "Meta_L"
    else:
        return "Control_L"


def tap(mut t: DoubleTap, at: Int, hold: Int = 80) -> Bool:
    _ = t.key(K(), at)
    return t.key("KeyUp:" + K(), at + hold)


def main() raises:
    var t = DoubleTap()
    assert_true(not tap(t, 0) and tap(t, 200), "twice close together")
    assert_true(not tap(t, 400), "a third starts afresh")
    assert_true(tap(t, 600), "and a fourth ends it")
    t = DoubleTap()
    assert_true(not tap(t, 0) and not tap(t, 500), "too far apart")
    assert_true(tap(t, 700), "(the second began a pair)")
    t = DoubleTap()
    assert_true(not tap(t, 0) and not tap(t, 200, 400), "held too long")
    t = DoubleTap()
    _ = tap(t, 0)
    _ = t.key("c", 120)
    assert_true(not tap(t, 200), "a key between")
    t = DoubleTap()
    _ = tap(t, 0)
    t.interrupt()
    assert_true(not tap(t, 200), "a press between")
    t = DoubleTap()
    _ = t.key(K(), 0)
    _ = t.key("c", 20)
    assert_true(not t.key("KeyUp:" + K(), 60) and not tap(t, 150), "Ctrl+C isn't a tap")
    assert_true(not t.key("KeyUp:" + K(), 900), "a release alone")
    print("doubletap: ok")
