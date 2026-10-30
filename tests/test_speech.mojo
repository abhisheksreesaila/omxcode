# mojoui.speech (goal 43 M1): whisper-large-v3-turbo in this process, fed like a microphone. Each clip of $SPEECH_CLIPS
# (default docs/goals/43/clips) goes to a SpeechStream in 20 ms pieces at real-time pace, then 1.6 s of quiet; the clip's
# hypothesis is its FINAL text(s). Prints `speech hyp: <clip id> <text>` per clip, the model id, and
# `speech partials: ok` when every clip had words (a PARTIAL) before its last sample went in.
from std.ffi import external_call, c_int
from std.os import getenv, listdir
from std.testing import assert_true
from mojoui.audio import load_wav, RATE
from mojoui.speech import SpeechModel, SpeechStream, SpeechEvent, FINAL, PARTIAL
from mojoui.clock import now_ns


def main() raises:
    var folder = getenv("SPEECH_CLIPS", "docs/goals/43/clips")
    var names = List[String]()
    for f in listdir(folder):
        if f.endswith(".wav"):
            names.append(String(f))
    sort(names)
    var model = SpeechModel()
    print("speech model:", model.name, "on", model.gpu(), "| loaded and warmed up in", model.load_ms(), "ms")
    var live = SpeechStream(model)
    var early = 0
    var worst_call = 0
    var finals_ms = List[Float64]()
    comptime PIECE = 320
    for name in names:
        var id = String(name[byte=0 : name.byte_length() - 4])
        var samples = load_wav(folder + "/" + name)
        var quiet = List[Float32](length=RATE * 8 // 5, fill=0.0)
        var text = String("")
        var partial_at = -1.0
        var finals = 0
        var t0 = now_ns()
        var fed = 0
        var total = len(samples) + len(quiet)
        while fed < total or finals == 0:
            var piece = List[Float32]()
            for i in range(fed, min(fed + PIECE, total)):
                piece.append(samples[i] if i < len(samples) else quiet[i - len(samples)])
            var t = now_ns()
            live.feed(piece)
            var events = live.poll()
            worst_call = max(worst_call, now_ns() - t)
            fed += len(piece)
            for e in events:
                if e.kind == PARTIAL and e.text and partial_at < 0 and fed <= len(samples):
                    partial_at = Float64(fed) / RATE
                if e.kind == FINAL:
                    text += (" " if text else "") + e.text
                    finals += 1
                    finals_ms.append(e.ms)
            # real time: the next 20 ms piece goes in when its time comes
            var due = t0 + (fed * 1_000_000_000) // RATE
            var wait = (due - now_ns()) // 1000
            if wait > 0:
                _ = external_call["usleep", c_int](c_int(wait))
            if fed >= total + 10 * RATE:
                break  # (10 s past the end with no final: give up on this clip)
        if partial_at > 0:
            early += 1
        print("speech clip:", id, "| first words at", partial_at, "s of", Float64(len(samples)) / RATE, "s | finals", finals)
        print("speech hyp:", id, text)
    live.close()
    sort(finals_ms)
    print("speech model id:", model.name)
    print("speech finals:", len(finals_ms), "| text ready after the last word: median", finals_ms[len(finals_ms) // 2],
          "ms, max", finals_ms[len(finals_ms) - 1], "ms | slowest feed+poll", Float64(worst_call) / 1e6, "ms | peak GPU",
          model.peak_gpu_mb(), "MB")
    assert_true(early == len(names) and len(names) > 0)
    print("speech partials: ok")
