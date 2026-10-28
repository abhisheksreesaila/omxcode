# mojoui.hosts.gtk_webview's pure parts (goal 34 review, D-620): which bundle names and SRI hashes the page may name,
# how long a reply's error may be, and which command a reply may answer.
from std.testing import assert_equal, assert_true, assert_false
from mojoui.hosts.gtk_webview import plain_file, plain_sri, clip_error, WebViews


def main() raises:
    for ok in ["editor.b155452d7d904e7f.js", "counter.6955c0750185d185.css", "a-b_c.1.js"]:
        assert_true(plain_file(ok), ok)
    for bad in ["", "../etc/passwd", "a/b.js", "..", "x..js", ".hidden.js", "a b.js", 'a".js', "a<b.js", "a\\b.js"]:
        assert_false(plain_file(bad), bad)
    assert_true(plain_sri("sha384-AbC+/09=="))
    for bad in ["", "sha1-abc", "sha384-", 'sha384-a"b', "sha384-a b", "md5-x"]:
        assert_false(plain_sri(bad), bad)
    assert_equal(clip_error("short"), "short")
    var long = String("")
    for _ in range(300):
        long += "é"  # (2 bytes each: the cut never splits one)
    var c = clip_error(long)
    assert_true(c.byte_length() <= 500)
    assert_equal(c.byte_length() % 2, 0)
    # a reply answers only a command sent to the widget that replies, once
    var wv = WebViews()
    wv.sent_to(7, "mx-a", 1)
    assert_false(wv.answers(7, "mx-b", 1))
    assert_false(wv.answers(7, "mx-a", 2))
    assert_false(wv.answers(8, "mx-a", 1))
    assert_true(wv.answers(7, "mx-a", 1))
    assert_false(wv.answers(7, "mx-a", 1))
    print("gtk_webview: ok")
