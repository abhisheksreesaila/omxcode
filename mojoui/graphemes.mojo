# Where a caret may stand in a text (review 3, MUST 6): between graphemes (what a person sees as one character: a letter
# with its accents, an emoji family, a flag, a Hangul syllable), never inside one and never inside a UTF-8 character. Every
# field's caret, Backspace and Delete use these. Positions are bytes.


def prev_grapheme(text: String, at: Int) -> Int:
    """The boundary before byte `at` (0 at the start)."""
    var last = 0
    var pos = 0
    for g in text.graphemes():
        var n = g.byte_length()
        if pos + n >= at:
            return pos
        pos += n
        last = pos
    return min(last, at)


def next_grapheme(text: String, at: Int) -> Int:
    """The boundary after byte `at` (the text's length at the end)."""
    var pos = 0
    for g in text.graphemes():
        pos += g.byte_length()
        if pos > at:
            return pos
    return text.byte_length()


def without_last(text: String) -> String:
    """The text without its last grapheme (Backspace at its end)."""
    var at = prev_grapheme(text, text.byte_length())
    return String(text[byte=0:at])


def typed_text(name: String) -> Bool:
    """Whether a key's name is the text it types (a letter, a digit, an accented or other script's character, an emoji),
    not a key such as "Enter" or "F2"."""
    if name.byte_length() == 1:
        return Int(name.as_bytes()[0]) >= 32 and Int(name.as_bytes()[0]) != 127
    for b in name.as_bytes():  # (a key's name is ASCII; "e" with a combining accent isn't)
        if Int(b) >= 0x80:
            return True
    return False
