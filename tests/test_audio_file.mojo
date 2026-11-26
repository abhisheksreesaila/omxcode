# mojoui.audio's `file:` source (goal 72 M4): a recorded voice as the microphone. A tone played from 0.5 s must arrive
# bit for bit at sample 8000, silence before it, paced like a live source (2 s of audio take 2 s, not less).
#   pixi run mojo build -I . tests/test_audio_file.mojo -o build/test_audio_file && build/test_audio_file
from std.ffi import external_call, c_int
from std.testing import assert_equal, assert_true
from mojoui.audio import Microphone, load_wav, RATE
from mojoui.clock import now_ns


def main() raises:
    var want = load_wav("docs/goals/43/tone.wav")
    var mic = Microphone("file:docs/goals/43/tone.wav@0.5,docs/goals/43/tone.wav@1.5")
    var t0 = now_ns()
    mic.start()
    while mic.total() < 2 * RATE:
        _ = external_call["usleep", c_int](c_int(10_000))
    var took = Float64(now_ns() - t0) / 1e9
    var got = mic.read(0)
    assert_true(took >= 1.95 and took < 2.3, "paced in real time: " + String(took) + " s for 2 s of audio")
    for i in range(8000):
        assert_equal(got[i], Float32(0))
    for i in range(8000, 12000):
        assert_equal(got[i], want[i - 8000])
    mic.stop()
    print("audio file source: ok (", took, "s for 2 s )")
