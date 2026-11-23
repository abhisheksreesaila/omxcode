# Goal 79, D-7998: fonttext's Apple Color Emoji advance against the whole table measured in the Mac's own Chrome on the
# live page (docs/goals/79/emoji-chrome-mac.json, emojiprobe.mjs): every size in it, not the one M1's line uses.
# `emojiadvance: ok`.   pixi run mojo run -I . -I vendor tests/test_emojiadvance.mojo   (from the repository root)
from std.os import getenv
from std.testing import assert_true, assert_equal
from mojoui.fonttext import apple_emoji_advance


def main() raises:
    var f = open(getenv("EMOJI_TABLE", "docs/goals/79/emoji-chrome-mac.json"), "r")
    var t = f.read()
    f.close()
    var n = 0
    for part in ["sizes", "more"]:  # (whole sizes 10–40 px, and 6–96 px with fractional ones)
        var at = t.find('"' + String(part) + '"')
        assert_true(at >= 0, "the measured " + String(part))
        var body = String(t[byte=at:t.byte_length()])
        var open_ = body.find("{")
        var close = body.find("}")
        for pair in String(body[byte=open_ + 1:close]).split(","):
            var kv = String(pair).split(":")
            var size = atof(String(kv[0]).replace('"', "").strip())
            var want = atof(String(kv[1]).strip())
            assert_equal(apple_emoji_advance(size), want, "at " + String(size) + " px")
            n += 1
    assert_true(n >= 60, "every size measured")
    print("emojiadvance: ok (" + String(n) + " sizes)")
