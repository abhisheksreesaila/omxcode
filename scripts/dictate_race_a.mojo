# Goal 43's side A for scripts/dictate_race.py: mojoui.speech's SpeechModel in this process, each clip handed over by
# address. Prints RACE READY when the model is loaded and warmed up (two 1 s silences, as side B), warms up once more on
# the first clip (untimed, as side B), then RACE CLIP <id> <ms> <seconds> <text> per clip (ms = audio handed in -> text).
from std.os import getenv, listdir
from mojoui.audio import load_wav, RATE
from mojoui.speech import SpeechModel
from mojoui.clock import now_ns


def main() raises:
    var folder = getenv("SPEECH_CLIPS", "docs/goals/43/clips")
    var names = List[String]()
    for f in listdir(folder):
        if f.endswith(".wav"):
            names.append(String(f))
    sort(names)
    var model = SpeechModel()
    print("RACE READY", model.name, "|", model.gpu(), flush=True)
    _ = model.transcribe(load_wav(folder + "/" + names[0]))
    for name in names:
        var samples = load_wav(folder + "/" + name)
        var t = now_ns()
        var text = model.transcribe(samples)
        var ms = Float64(now_ns() - t) / 1e6
        print("RACE CLIP", String(name[byte=0 : name.byte_length() - 4]), ms, Float64(len(samples)) / RATE, text, flush=True)
    print("RACE PEAK", model.peak_gpu_mb(), flush=True)
