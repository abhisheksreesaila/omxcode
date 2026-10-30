# mojoui.speech after a Python error (goal 43 review, D-1417): a call that fails in Python must give the interpreter's
# lock back, or the backend's own thread (which does the transcribing) never runs again and the UI thread blocks on its
# next call. The model loads first (so the main thread has given the lock up); then two calls fail in Python (a model
# that doesn't exist, an attribute that doesn't exist); then a clip goes into a stream and its FINAL must still arrive,
# with no call taking long. Prints `speech errors: raised` and `speech after error: ok`.
from std.ffi import external_call, c_int
from std.os import getenv, listdir
from std.testing import assert_true
from mojoui.audio import load_wav, RATE
from mojoui.speech import SpeechModel, SpeechStream, FINAL
from mojoui.clock import now_ns


def main() raises:
    var model = SpeechModel()
    var live = SpeechStream(model)
    var raised = 0
    try:
        var bad = SpeechModel("/nonexistent/whisper-model")
        print("unexpected: a model from", bad.name)
    except e:
        raised += 1
        print("bad model raised:", String(e))
    try:
        _ = model._attr("no_such_attribute")
    except e:
        raised += 1
        print("bad attribute raised:", String(e))
    assert_true(raised == 2, "both bad calls should raise")
    print("speech errors: raised")

    var folder = getenv("SPEECH_CLIPS", "docs/goals/43/clips")
    var names = List[String]()
    for f in listdir(folder):
        if f.endswith(".wav"):
            names.append(String(f))
    sort(names)
    var samples = load_wav(folder + "/" + names[0])
    for _ in range(RATE * 8 // 5):
        samples.append(0.0)
    var worst = 0
    var t0 = now_ns()
    var fed = 0
    var final_text = String("")
    while (now_ns() - t0) < 30_000_000_000 and final_text.byte_length() == 0:
        var piece = List[Float32]()
        for i in range(fed, min(fed + 320, len(samples))):
            piece.append(samples[i])
        var c = now_ns()
        live.feed(piece)
        for e in live.poll():
            if e.kind == FINAL:
                final_text = e.text
        worst = max(worst, now_ns() - c)
        fed += len(piece)
        _ = external_call["usleep", c_int](c_int(20000))
    live.close()
    print("final after the errors:", final_text, "| slowest feed+poll", Float64(worst) / 1e6, "ms")
    assert_true(final_text.byte_length() > 0, "no FINAL after a Python error: the lock wasn't given back")
    assert_true(worst < 100_000_000, "a call blocked the caller")
    print("speech after error: ok")
