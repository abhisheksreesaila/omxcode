# mojoui.framebudget: the slice gets the target less the last frame's other work, clamped; the slice's own time isn't
# counted as other work. `framebudget: ok`.
#   pixi run mojo run -I . -I vendor tests/test_framebudget.mojo
from std.testing import assert_equal, assert_true
from mojoui.framebudget import FrameBudget
from mojoui.docstore import clock_us


def busy(us: Int):
    var t = clock_us()
    while clock_us() - t < us:
        pass


def main() raises:
    var fb = FrameBudget(4000)
    assert_equal(fb.slice_us(250, 1500), 1500, "nothing measured: the most")
    fb.begin()
    busy(3000)  # (other work)
    var t = clock_us()
    busy(1000)  # (the slice)
    fb.spent(clock_us() - t)
    fb.end()
    assert_true(fb.other_us >= 2900 and fb.other_us < 3600, "the slice isn't other work: " + String(fb.other_us))
    var s = fb.slice_us(250, 1500)
    assert_true(s >= 400 and s <= 1100, "target − other: " + String(s))
    fb.begin()
    busy(5000)
    fb.end()
    assert_equal(fb.slice_us(250, 1500), 250, "a heavy frame: the least")
    fb.begin()
    fb.end()
    assert_equal(fb.slice_us(250, 1500), 1500, "an idle frame: the most")
    print("framebudget: ok")
