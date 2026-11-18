# mojoui.voiceloop's pure parts (goal 72 M4): how a streamed reply is cut into sentences for the mouth, and what is
# never said aloud. The models and devices are tests/test_omx's and docs/goals/72-check.py's.
#   pixi run mojo build -I . tests/test_voiceloop_parts.mojo -o build/test_voiceloop_parts && build/test_voiceloop_parts
from std.testing import assert_equal
from mojoui.voiceloop import take_sentences, speech_clean


def main() raises:
    # words arrive in pieces; a sentence goes to the mouth the moment its end and the space after it are seen
    var pending = String("")
    var got = List[String]()
    for piece in ["The capital of France", " is Paris.", " It sits on the", " Seine. Would you like", " more?"]:
        pending += String(piece)
        for s in take_sentences(pending):
            got.append(s)
    assert_equal(len(got), 2)
    assert_equal(got[0], "The capital of France is Paris.")
    assert_equal(got[1], "It sits on the Seine.")
    assert_equal(pending, "Would you like more?")  # (no space after it yet: it may not be over)
    var last = take_sentences(pending, True)
    assert_equal(len(last), 1)
    assert_equal(last[0], "Would you like more?")
    assert_equal(pending, "")
    # a decimal point is not an end; a short opener waits for the next sentence's company
    var p2 = String("It is 3.5 metres wide. Yes. Really, it is.")
    var s2 = take_sentences(p2)
    assert_equal(len(s2), 1)
    assert_equal(s2[0], "It is 3.5 metres wide.")
    assert_equal(p2, "Yes. Really, it is.")
    # a very long run is cut at a comma
    var p3 = String("Jupiter is the largest planet in the solar system with a diameter of about one hundred and forty thousand kilometres, and Saturn follows it. ")
    var s3 = take_sentences(p3)
    assert_equal(len(s3), 2)
    assert_equal(s3[0], "Jupiter is the largest planet in the solar system with a diameter of about one hundred and forty thousand kilometres,")
    assert_equal(s3[1], "and Saturn follows it.")
    # nothing is said of markup
    assert_equal(speech_clean("**Paris** is the `capital`.\n- _France_"), "Paris is the capital. - France")
    print("voiceloop parts: ok")
