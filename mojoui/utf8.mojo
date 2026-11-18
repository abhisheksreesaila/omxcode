# mojoui.utf8: cutting text by bytes without cutting a character in two (goal 72 review, D-7279).
#
#   head("héllo", 2)  ->  "h"        (the é is two bytes: it doesn't fit in the second, so it stays out)
#   head("héllo", 3)  ->  "hé"
#
# A String slice by byte (`s[byte = :n]`) at the middle of a multi-byte character makes a broken string; every cut to a size
# (a note's chunk, a ledger excerpt, a job's answer) goes through here instead.


def boundary(text: String, most: Int) -> Int:
    """The largest n <= most that is a character boundary of `text`."""
    var size = text.byte_length()
    if most >= size:
        return size
    if most <= 0:
        return 0
    var n = most
    var b = text.as_bytes()
    while n > 0 and (Int(b[n]) & 0xC0) == 0x80:  # (a continuation byte: the character began earlier)
        n -= 1
    return n


def head(text: String, most: Int) -> String:
    """The first characters of `text` that fit in `most` bytes."""
    var n = boundary(text, most)
    if n >= text.byte_length():
        return text
    return String(text[byte = :n])


def tail(text: String, most: Int) -> String:
    """The last characters of `text` that fit in `most` bytes."""
    var size = text.byte_length()
    if most >= size:
        return text
    if most <= 0:
        return String("")
    var n = size - most
    var b = text.as_bytes()
    while n < size and (Int(b[n]) & 0xC0) == 0x80:  # (a continuation byte: the character began before the cut)
        n += 1
    return String(text[byte = n :])
