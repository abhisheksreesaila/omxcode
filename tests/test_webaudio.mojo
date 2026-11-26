# mojoui.webaudio (goal 72 M5): the web host's hub, where a browser's microphone and speaker meet an app's Microphone and
# Speaker. No browser here: the test plays the host's part (the calls web.py makes for a page's audio socket) and checks
# what the app sees, with exact values.
# Run: pixi run mojo run -I . tests/test_webaudio.mojo        (prints "webaudio: ok")
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true
from mojoui.audio import Microphone, RATE
from mojoui.speaker import Speaker, OUT_RATE
from mojoui.webaudio import audio_init, audio_push, audio_pull, audio_flushes, audio_settle, audio_wants, audio_client, audio_fail
from mojoui.clock import now_ns


def pcm_bytes(n: Int, scale: Int) -> Int:
    """n 16-bit samples, sample i = (i % 100 - 50) * scale; the buffer's address."""
    var p = unsafe_alloc[UInt8](n * 2)
    for i in range(n):
        var v = (i % 100 - 50) * scale
        if v < 0:
            v += 65536
        p[2 * i] = UInt8(v & 255)
        p[2 * i + 1] = UInt8(v >> 8)
    return Int(p)


def main() raises:
    assert_true(audio_init() != 0)
    audio_client(1)  # a page attached

    # the microphone: the app's start() asks for the browser's; a page's samples arrive through audio_push
    var mic = Microphone()
    mic.start()
    assert_equal(audio_wants(), 1)  # the page is told to open its microphone
    assert_true(not mic.running())  # ...but nothing has arrived yet
    var a = pcm_bytes(640, 100)  # 40 ms: two 20 ms frames
    audio_push(a, 640 * 2)
    assert_true(mic.running())
    assert_equal(mic.total(), 640)
    var got = mic.read(0)
    assert_equal(len(got), 640)
    assert_equal(got[0], Float32(-5000) / 32768.0)
    assert_equal(got[50], Float32(0))
    assert_equal(got[99], Float32(4900) / 32768.0)
    assert_true(mic.level() > 0.05 and mic.level() < 0.2)
    audio_push(a, 320 * 2)
    assert_equal(mic.total(), 960)
    assert_equal(len(mic.read(640)), 320)
    assert_true(mic.captured_ns(959) <= now_ns() and mic.captured_ns(959) > now_ns() - 1_000_000_000)

    # a second Microphone started later counts from its own start (like a new stream on the desktop)
    mic.stop()
    assert_equal(audio_wants(), 0)
    assert_true(not mic.running())
    var mic2 = Microphone()
    mic2.start()
    assert_equal(mic2.total(), 0)
    audio_push(a, 320 * 2)
    assert_equal(mic2.total(), 320)
    assert_equal(mic2.read(0)[0], Float32(-5000) / 32768.0)

    # a page that is refused the microphone
    audio_fail(101)
    assert_true(mic2.failed())
    assert_true("refused" in mic2.why())

    # the speaker: play() queues, the page's socket pulls 16-bit samples at 24 kHz
    var sp = Speaker()
    var tone = List[Float32]()
    for i in range(2400):  # 100 ms
        tone.append(Float32(i % 100 - 50) / 100.0)
    sp.play(tone, OUT_RATE)
    assert_true(sp.playing())
    var out = unsafe_alloc[UInt8](4800)
    var n = audio_pull(Int(out), 4800)
    assert_equal(n, 4800)  # all 2400 samples, 2 bytes each
    var v0 = Int(out[0]) | (Int(out[1]) << 8)
    assert_equal(v0, 65536 - 16384)  # -0.5 * 32768
    var v75 = Int(out[150]) | (Int(out[151]) << 8)
    assert_equal(v75, 8192)  # 0.25 * 32768
    assert_equal(audio_pull(Int(out), 4800), 0)  # nothing more
    assert_true(sp.playing())  # the page still holds ~100 ms of it
    assert_true(sp.first_ns() > 0 and sp.first_ns() >= sp.play_ns())

    # stop(): the queue and what the page holds are dropped; the host sees the flush and says so to the page
    var before = audio_flushes()
    sp.play(tone, OUT_RATE)
    sp.stop()
    assert_equal(audio_flushes(), before + 1)
    audio_settle()
    assert_equal(audio_pull(Int(out), 4800), 0)  # what was queued is gone
    assert_true(not sp.playing())
    sp.play(tone, OUT_RATE)  # and it plays again afterwards
    assert_equal(audio_pull(Int(out), 4800), 4800)

    # a rate that isn't the speaker's is resampled (12 kHz -> 24 kHz doubles the samples)
    sp.stop()
    audio_settle()
    var slow = List[Float32](length=1200, fill=0.25)
    sp.play(slow, 12000)
    assert_equal(audio_pull(Int(out), 4800), 4800)

    # lead: the host doesn't hand the page more than 600 ms ahead of what it has played (stop() stays fast)
    sp.stop()
    audio_settle()
    var long = List[Float32](length=OUT_RATE * 3, fill=0.1)  # 3 s
    sp.play(long, OUT_RATE)
    var sent = 0
    var big = unsafe_alloc[UInt8](OUT_RATE * 2)
    while True:
        var k = audio_pull(Int(big), OUT_RATE * 2)
        if k == 0:
            break
        sent += k
    assert_true(sent >= OUT_RATE * 2 * 6 // 10 and sent <= OUT_RATE * 2 * 7 // 10 + 1920)  # ≈ 600 ms in 16-bit bytes
    assert_true(sp.queued_ms() > 2000.0)
    sp.stop()
    assert_true(sp.queued_ms() < 1.0)

    audio_client(-1)
    print("webaudio: ok")
