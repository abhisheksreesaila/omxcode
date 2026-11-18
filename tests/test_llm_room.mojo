# mojoui.llm on a context too small for both sequences (goal 72 review, D-7276): the two sequences share one context (2048 tokens
# here), so a background request that doesn't fit beside the conversation is refused with its own error and the conversation
# keeps its cache; and a conversation request that doesn't fit beside what the background holds stops the background to make room.
#   scripts/mxbuild.sh tests/test_llm_room.mojo -o build/test_llm_room && LLM_GPU=0 build/test_llm_room
from std.os import getenv
from std.testing import assert_equal, assert_true
from mojoui.json import json_string
from mojoui.llm import Llm


def msg(role: String, text: String) -> String:
    return '{"role":' + json_string(role) + ',"content":' + json_string(text) + "}"


def passage(tag: String, sentences: Int) -> String:
    """About ten tokens a sentence."""
    var out = String("")
    for i in range(sentences):
        out += "In the " + tag + " report the number " + String(i) + " is the committee's figure for the month. "
    return out^


def refused(llm: Llm, messages: String, seq: Int) -> String:
    """The error an engine request ends with ("" when it was answered)."""
    try:
        _ = llm.complete(messages, "", seq, False, 8, 0.0)
    except e:
        return String(e)
    return String("")


def main() raises:
    var gguf = getenv("LLM_GGUF", getenv("HOME", "") + "/Projects/omx-local/models/Qwen3.8-27B-UD-Q4_K_M.gguf")
    var gpu = Int(getenv("LLM_GPU", "0"))
    var llm = Llm(gguf, gpu=gpu, n_ctx=2048, n_seq=2)
    var talk = "[" + msg("user", passage("first", 55) + "Reply with one word: ready.") + "]"
    var first = llm.complete(talk, "", 0, False, 8, 0.0)
    assert_true(first.done.n_prompt > 900 and first.done.n_prompt < 1150, "the conversation's prompt: " + String(first.done.n_prompt))
    # a background request that can't fit beside it is refused, and says why
    var why = refused(llm, "[" + msg("user", passage("second", 75) + "Reply with one word: ready.") + "]", 1)
    assert_true(why.find("no room for this request") >= 0, "the background request was refused: " + why)
    assert_true(why.find("free beside the other sequences") >= 0, why)
    # the conversation was not touched: its next turn reads almost nothing again
    var again = llm.complete("[" + msg("user", passage("first", 55) + "Reply with one word: ready.") + "," + msg("assistant", first.text) + "," + msg("user", "And once more: say ready.") + "]", "", 0, False, 8, 0.0)
    assert_true(again.done.n_cached > 900, "the conversation kept its cache: " + String(again.done.n_cached) + " tokens cached")
    print("llm room: the background request was refused (", why, ") and the conversation kept", again.done.n_cached, "cached tokens")
    # and the other way round, on a fresh engine: the background holds the room, then the conversation needs it
    var other = Llm(gguf, gpu=gpu, n_ctx=2048, n_seq=2)
    var bg = other.complete("[" + msg("user", passage("third", 75) + "Reply with one word: ready.") + "]", "", 1, False, 8, 0.0)
    assert_true(bg.done.n_prompt > 1250, "the background request was answered while it had the room")
    var conv = other.complete(talk, "", 0, False, 8, 0.0)
    assert_equal(conv.done.text, "stop")
    assert_true(conv.done.n_prompt > 900, "the conversation was answered: it stopped the background's cache to make room")
    print("llm room: the conversation made room by letting the background's cache go")
    print("llm room: ok")
