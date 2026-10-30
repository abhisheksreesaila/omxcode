# mojoui.audio (goal 43 M0): records $MOJOUI_AUDIO_SECONDS from $MOJOUI_AUDIO_SOURCE (the checker's null-sink monitor,
# into which it plays $MOJOUI_AUDIO_REF) and compares what arrived with the file. Prints `audio capture: ok`,
# `audio match: X` and `audio ui free: ok` (start() and every read() return within 2 ms while capture runs).
from std.ffi import external_call, c_int
from std.os import getenv
from std.testing import assert_true, assert_equal
from mojoui.audio import Microphone, load_wav, best_match, RATE
from mojoui.clock import now_ns


def main() raises:
    var seconds = Int(getenv("MOJOUI_AUDIO_SECONDS", "6"))
    var mic = Microphone()
    var t0 = now_ns()
    mic.start()
    var worst = now_ns() - t0
    var want = load_wav(getenv("MOJOUI_AUDIO_REF", "docs/goals/43/tone.wav"))
    var got = List[Float32]()
    var calls = 0
    var deadline = now_ns() + seconds * 1_000_000_000
    while now_ns() < deadline:
        _ = external_call["usleep", c_int](c_int(10_000))  # the "frame": the caller does its own work meanwhile
        var t = now_ns()
        var part = mic.read(len(got))
        _ = mic.level()
        worst = max(worst, now_ns() - t)
        calls += 1
        for v in part:
            got.append(v)
        if mic.failed():
            print("audio capture failed:", mic.why())
            raise Error("capture failed")
    mic.stop()
    # the matcher itself, on a known shift
    var shifted = List[Float32](length=1234, fill=0.0)
    for v in want:
        shifted.append(v * 0.3)
    var known = best_match(shifted, want)
    assert_true(known[0] > 0.999)
    assert_equal(known[1], 1234)

    var secs = Float64(len(got)) / RATE
    print("audio source:", mic.source if mic.source else "(default)", "| captured", secs, "s in", calls, "reads; slowest call",
          Float64(worst) / 1e6, "ms")
    assert_true(secs > Float64(seconds) * 0.8)
    print("audio capture: ok")
    var m = best_match(got, want)
    print("audio match:", m[0], "(at", Float64(m[1]) / RATE, "s)")
    assert_true(worst < 2_000_000)
    print("audio ui free: ok")
