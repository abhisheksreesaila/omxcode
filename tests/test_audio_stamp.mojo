# mojoui.audio's captured_ns reads the newest chunk's time and total as one pair under a sequence word (odd while the
# capture thread writes them). It must never spin without a bound: a block whose word stays odd (a writer that died
# mid-update) returns within a few ms, with a time no later than now. An even word still reads the pair exactly.
# Prints `audio stamp: ok`.
from std.atomic import Atomic
from std.memory.alloc import unsafe_alloc
from std.testing import assert_true, assert_equal
from mojoui.audio import Microphone, RATE, RING, W_WORDS, W_REFS, W_RING, W_SEQ, W_TIME, W_TOTAL
from mojoui.clock import now_ns

comptime _A = Atomic[Scalar[DType.int64]]


def put(words: Int, k: Int, v: Int):
    _A.store(Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=words + 8 * k), Int64(v))


def block(seq: Int, t: Int, total: Int) -> Int:
    """A capture block as start() makes one, with no thread behind it (the Microphone frees it when dropped)."""
    var words = Int(unsafe_alloc[Int64](W_WORDS))
    for k in range(W_WORDS):
        put(words, k, 0)
    put(words, W_REFS, 1)
    put(words, W_RING, Int(unsafe_alloc[Float32](RING)))
    put(words, W_SEQ, seq)
    put(words, W_TIME, t)
    put(words, W_TOTAL, total)
    return words


def main() raises:
    var t = now_ns() - 1_000_000
    var calm = Microphone()
    calm.words = block(4, t, 3200)
    assert_equal(calm.captured_ns(3199), t, "an even word: the newest sample's time")
    assert_equal(calm.captured_ns(3199 - RATE), t - 1_000_000_000, "one second earlier")

    var stuck = Microphone()
    stuck.words = block(7, t, 3200)  # odd forever: the writer never finishes
    var t0 = now_ns()
    var got = stuck.captured_ns(3199)
    var took = now_ns() - t0
    print("stuck word: returned in", Float64(took) / 1e6, "ms")
    assert_true(took < 5_000_000, "captured_ns must give up on a word that stays odd (took " + String(took) + " ns)")
    assert_true(got <= now_ns(), "the fallback is never later than now")
    print("audio stamp: ok")
