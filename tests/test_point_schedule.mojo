# mojoui.voiceloop pointing (goal 77 M1): a clause that names a part gives a POINT event when its audio plays, not before; a burst
# whose first sample isn't measured yet holds its points; the event is the AG-UI CUSTOM `point`.
from std.testing import assert_equal, assert_true
from mojoui.clock import now_ns
from mojoui.pointer import Part
from mojoui.voiceloop import VoiceLoop, LoopEvent, POINT, Burst


def parts() -> List[Part]:
    return [Part("card1", "word", ["ephemeral"], False, True), Part("card1", "meaning", ["means"], True, False)]


def main() raises:
    var loop = VoiceLoop()
    loop.parts = parts()
    var out = List[LoopEvent]()
    # a clause joining a burst the device already plays: "Ephemeral means short." is 2 s long; the word is at the start, "means" a third in
    var start = now_ns() + 300_000_000
    loop.schedule("Ephemeral means short.", 2000.0, start, False)
    assert_equal(len(loop.due), 2)
    assert_equal(loop.due[0].part, "word")
    assert_equal(loop.due[1].part, "meaning")
    assert_true(loop.due[1].at_ms > 400 and loop.due[1].at_ms < 1000, "means is said a third of the way in: " + String(loop.due[1].at_ms))
    loop.points(out)
    assert_equal(len(out), 0)  # (its audio is 300 ms away: nothing is shown yet)
    # time passes: the word is due, the later name is not
    loop.due[0].due_ns = now_ns() - 1_000_000
    loop.points(out)
    assert_equal(len(out), 1)
    assert_equal(out[0].kind, POINT)
    assert_true(out[0].text.startswith('{"type":"CUSTOM","name":"point","value":{"card":"card1","part":"word","at_ms":'))
    assert_equal(len(loop.due), 1)
    assert_equal(loop.due[0].part, "meaning")
    # the same part twice running is sent once
    loop.schedule("Ephemeral again.", 1000.0, now_ns() - 5_000_000, False)
    loop.due[1].due_ns = now_ns() - 1_000_000
    loop.due[0].due_ns = now_ns() - 1_000_000
    var again = List[LoopEvent]()
    loop.points(again)
    assert_equal(len(again), 2)  # meaning, then the word again (a different part from the last one sent)
    assert_true(again[1].text.find('"part":"word"') > 0)
    # a fresh burst holds its points until the device reports its first sample (the speaker here never plays: nothing is measured)
    var held = VoiceLoop()
    held.parts = parts()
    held.schedule("Ephemeral.", 800.0, now_ns() - 10_000_000, True)
    assert_equal(len(held.due), 1)
    var none = List[LoopEvent]()
    held.points(none)
    assert_equal(len(none), 0)
    assert_equal(len(held.bursts), 1)
    # no parts, no points
    var bare = VoiceLoop()
    bare.schedule("Ephemeral means short.", 2000.0, now_ns(), False)
    assert_equal(len(bare.due), 0)
    print("point schedule: ok")
