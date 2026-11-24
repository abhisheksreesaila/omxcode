# Goal 81, M5: what the hang monitor costs: one event's marks (the loop's turn, an update and a view).
#   pixi run mojo run -O3 -I . tests/test_hangmarks.mojo
from std.memory.alloc import alloc, Layout
from std.testing import assert_equal, assert_true
from mojoui.clock import now_ns
from mojoui.hangmarks import begin, end, turn_begins, turn_ends, put, read, M_WORDS, M_LIMIT, M_LONG_WHAT, M_END_NS, M_DEPTH, MARK_UPDATE, MARK_VIEW


def main() raises:
    var words = alloc(Layout[Int64](count=M_WORDS)).unsafe_leak()
    var addr = Int(words)
    for k in range(M_WORDS):
        put(addr, k, 0)
    put(addr, M_LIMIT, 500_000_000)
    var n = 200_000
    var t0 = now_ns()
    for k in range(n):
        turn_begins(addr)
        begin(addr, MARK_UPDATE, k)
        end(addr)
        begin(addr, MARK_VIEW)
        end(addr)
        turn_ends(addr)
    var us = Float64(now_ns() - t0) / Float64(n) / 1000
    assert_equal(read(addr, M_DEPTH), 0)
    assert_equal(read(addr, M_END_NS), 0, "nothing took too long")
    # deeper than it keeps, and an end without its begin: no harm
    for k in range(20):
        begin(addr, MARK_UPDATE, k)
    for k in range(25):
        end(addr)
    assert_equal(read(addr, M_DEPTH), 0)
    begin(0, MARK_UPDATE)
    end(0)
    print("FACT mark_us", round(us, 4))
    print("hangmarks: ok")
