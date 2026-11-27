# mojoui.dictation (goal 82 M5): the mic button's rule, the words at a caret, and the whole pipeline with a recorded voice
# for a microphone (no person, no microphone): each clip of $DICTATION_CLIPS (LibriSpeech, docs/goals/43/clips) is played
# into Microphone("file:…") while the mic is "held"; stop() on release; the words committed at the caret are scored
# against the clip's text. Linux: the speech model in this process on the GPU (Parakeet by default; $DICTATION_ENGINE),
# in the Python of $DICTATION_PY_ENV (default .pixi/envs/voice); macOS: Apple's on-device recogniser.
# Prints `dictation hyp: <clip> <words>`, `dictation first-words: <clip> <s>` (from where the voice starts in the clip to
# the first words on screen), `dictation wer: <errors>/<words> = <rate>` and `dictation: ok`; `dictation: BLOCKED <why>` (exit 3) when the
# host won't let it listen (macOS's permission).
from std.os import getenv
from std.testing import assert_equal, assert_true
from mojoui.dictation import (
    PressToTalk, DictationText, Dictation, Put, use_python_env, word_errors, TALK_START, TALK_STOP, TALK_NONE, PARAKEET,
)
from mojoui.speech import SpeechEvent, PARTIAL, FINAL
from mojoui.audio import load_wav, RATE
from mojoui.clock import now_ns
from mojoui import libc
from std.sys import CompilationTarget


def rules() raises:
    var t = PressToTalk()
    assert_equal(t.press(1000, False), TALK_START, "a press starts listening")
    assert_equal(t.release(1100), TALK_NONE, "a tap keeps listening")
    assert_equal(t.press(3000, True), TALK_NONE, "the next press, while listening, waits for its release")
    assert_equal(t.release(3050), TALK_STOP, "...which stops")
    assert_equal(t.press(5000, False), TALK_START, "a hold starts")
    assert_equal(t.release(5000 + 450), TALK_STOP, "and stops when let go (450 ms or more)")
    var d = DictationText()
    d.start("Hello")
    var p = d.hear(SpeechEvent(PARTIAL, "this  is", 0, 0, 0))
    assert_equal(p.preedit, " this is", "a partial is a preedit, spaced after a word")
    assert_equal(p.commit, "", "a partial commits nothing")
    p = d.hear(SpeechEvent(FINAL, " this is a test. ", 0, 0, 0))
    assert_equal(p.commit, " this is a test.", "a final is committed, spaced and normalised")
    assert_equal(p.preedit, "", "and the preedit goes")
    p = d.hear(SpeechEvent(FINAL, "Again", 0, 0, 0))
    assert_equal(p.commit, " Again", "the next final follows with a space")
    d.start("line one\n")
    p = d.hear(SpeechEvent(FINAL, "Two", 0, 0, 0))
    assert_equal(p.commit, "Two", "no space at the start of a line")
    d.start("")
    assert_equal(d.hear(SpeechEvent(FINAL, "first", 0, 0, 0)).commit, "first", "no space in an empty text")
    var e = word_errors("HE WORE BLUE SILK", "He wore blue, silk.")
    assert_equal(e[0], 0, "case and punctuation don't count")
    e = word_errors("a b c d", "a x c")
    assert_equal(e[0], 2, "one substitution, one deletion")
    print("dictation rules: ok")


def main() raises:
    rules()
    comptime if CompilationTarget.is_linux():
        var why = use_python_env(getenv("DICTATION_PY_ENV", ".pixi/envs/voice"))
        if why != "":
            print("dictation: BLOCKED", why)
            libc_exit(3)
    var folder = getenv("DICTATION_FOLDER", "docs/goals/43/clips")
    var clips = getenv("DICTATION_CLIPS", "1284-1180-0000,2094-142345-0001,2300-131720-0000,1089-134686-0000").split(",")
    var errors = 0
    var words = 0
    var engine = getenv("DICTATION_ENGINE", PARAKEET if CompilationTarget.is_linux() else "en-US")
    var ears = Dictation("", engine)  # (one for the whole run, as an app keeps one: the model loads once)
    for c in clips:
        var clip = String(c)
        var wav = folder + "/" + clip + ".wav"
        var samples = load_wav(wav)
        var seconds = Float64(len(samples)) / RATE
        var onset = 0.0  # where the voice starts: the first 20 ms louder than RMS 0.015 (the clips open with a breath of quiet)
        for k in range(0, len(samples) - 320, 320):
            var sq = Float64(0)
            for i in range(k, k + 320):
                sq += Float64(samples[i]) * Float64(samples[i])
            if sq / 320 > 0.015 * 0.015:
                onset = Float64(k) / RATE
                break
        ears.source = "file:" + wav
        var talk = PressToTalk()
        var text = DictationText()
        var caret = String("Notes:")  # the words left of the caret, as an editor would have them
        assert_equal(talk.press(0, ears.listening()), TALK_START)
        if not ears.start():
            print("dictation: BLOCKED", ears.why)
            libc_exit(3)
        text.start(caret)
        var t0 = now_ns()
        var first = -1.0
        var released = False
        while True:
            _ = libc.usleep(30_000)
            var held_s = Float64(now_ns() - t0) / 1e9
            if not released and held_s > seconds + 0.4:
                assert_equal(talk.release(Int(held_s * 1000)), TALK_STOP, "a hold longer than 450 ms stops on release")
                ears.stop()
                released = True
            for e in ears.tick():
                var put = text.hear(e)
                if put.commit != "":
                    caret += put.commit
                _ = put.preedit  # (an editor would show it underlined)
                if first < 0 and (put.commit != "" or put.preedit != ""):
                    first = held_s
            if released and not ears.busy():
                break
            if held_s > seconds + 30:
                print("dictation: FAIL no end to", clip, ears.why)
                libc_exit(1)
        if ears.why != "":
            print("dictation: BLOCKED", ears.why)
            libc_exit(3)
        _ = text.finish()
        var heard = String(caret[byte = 6 :])
        var want = String(open(folder + "/" + clip + ".txt", "r").read())
        var e = word_errors(want, heard)
        errors += e[0]
        words += e[1]
        print("dictation hyp:", clip, heard.strip())
        print("dictation first-words:", clip, first - onset, "s after the voice starts" + (" (with the model's load)" if clip == String(clips[0]) else ""))
    print("dictation wer:", errors, "/", words, "=", Float64(errors) / Float64(max(words, 1)))
    print("dictation: ok")


def libc_exit(code: Int):
    from std.ffi import external_call, c_int
    external_call["exit", NoneType](c_int(code))
