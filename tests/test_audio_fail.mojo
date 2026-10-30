# mojoui.audio when the sound server ends the stream mid-capture (goal 43 review, D-1418): failed() turns true and why()
# says so. The test makes a null sink of its own (never a real device), captures its monitor, then has the sound server
# drop this process's client (pw-cli destroy on its PipeWire object, found by pid with pactl): pa_simple_read fails as
# when the server dies. Unloading the sink instead would let the server move the stream to the default source, which is
# the owner's microphone. While capturing,
# captured_ns is read in a tight loop (its time/total pair must stay consistent: never later than now).
# Prints `audio lost: ok`.
from std.ffi import external_call, c_int
from std.testing import assert_true
from mojoui.audio import Microphone
from mojoui.clock import now_ns


def sh(cmd: String) -> Int:
    var c = cmd
    return Int(external_call["system", c_int](c.as_c_string_span()))


def main() raises:
    var pid = Int(external_call["getpid", c_int]())
    var sink = "g43_audio_fail_" + String(pid)
    var mod_file = "/tmp/" + sink + ".module"
    assert_true(sh("pactl load-module module-null-sink sink_name=" + sink + " > " + mod_file) == 0, "no null sink")
    var mic = Microphone(sink + ".monitor")
    mic.start()
    var t0 = now_ns()
    while mic.total() < 16000 and now_ns() - t0 < 5_000_000_000:
        var n = mic.total()
        if n > 0:
            assert_true(mic.captured_ns(n - 1) <= now_ns(), "captured_ns later than now")
        _ = external_call["usleep", c_int](c_int(1000))
    assert_true(mic.running() and mic.total() >= 16000, "capture didn't start: " + mic.why())
    print("capturing:", mic.total(), "samples; failed() =", mic.failed())
    var kill = String("pactl -f json list clients | python3 -c \"import json,sys; [print(c['properties']['object.id']) for c in json.load(sys.stdin) ")
    kill += "if c['properties'].get('application.process.id') == sys.argv[1]]\" " + String(pid) + " | xargs -r -n1 pw-cli destroy"
    _ = sh(kill)
    var t1 = now_ns()
    while not mic.failed() and now_ns() - t1 < 3_000_000_000:
        _ = external_call["usleep", c_int](c_int(5000))
    _ = sh("pactl unload-module $(cat " + mod_file + ") ; rm -f " + mod_file)
    print("after the server ended the stream: failed() =", mic.failed(), "| why():", mic.why())
    assert_true(mic.failed(), "a lost stream must mark the microphone failed")
    assert_true(mic.why().find("ended the stream") >= 0, "why() should say the stream ended")
    print("audio lost: ok")
