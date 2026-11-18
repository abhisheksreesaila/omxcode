# mojoui.utf8 (goal 72 review, D-7279): a cut to a byte size never ends in the middle of a character.
#   pixi run mojo build -I . -I vendor tests/test_utf8.mojo -o build/test_utf8 && build/test_utf8
from std.testing import assert_equal
from mojoui.utf8 import head, boundary, tail


def main() raises:
    assert_equal(head("hello", 3), "hel")
    assert_equal(head("hello", 9), "hello")
    assert_equal(head("héllo", 1), "h")
    assert_equal(head("héllo", 2), "h")  # the é takes bytes 1 and 2: cut after the h
    assert_equal(head("héllo", 3), "hé")
    assert_equal(head("日本語", 4), "日")  # three bytes each
    assert_equal(head("日本語", 6), "日本")
    assert_equal(head("a😀b", 4), "a")  # the emoji takes four bytes, 1..4
    assert_equal(head("a😀b", 5), "a😀")
    assert_equal(head("é", 1), "")
    assert_equal(head("abc", 0), "")
    assert_equal(boundary("héllo", 2), 1)
    assert_equal(tail("hello", 3), "llo")
    assert_equal(tail("héllo", 4), "llo")  # the é's second byte would be the first: it stays out
    assert_equal(tail("héllo", 5), "éllo")
    assert_equal(tail("日本語", 4), "語")
    assert_equal(tail("abc", 0), "")
    print("utf8: ok")
