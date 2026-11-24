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


def erase_start(text: String, at: Int) -> Int:
    """Where Backspace at byte `at` takes away from: the grapheme before it, except in the scripts whose graphemes are
    built a sign at a time (Devanagari … Sinhala, Thai, Lao, Tibetan, Myanmar, Khmer): there its last sign only, as
    platforms and Personal Note's page do, so that a wrong vowel sign is corrected without writing the syllable again."""
    var start = prev_grapheme(text, at)
    if start >= at:
        return start
    var b = text.as_bytes()
    var k = at - 1
    while k > start and (Int(b[k]) & 0xC0) == 0x80:
        k -= 1
    if k > start and Int(b[k]) >= 0xE0 and Int(b[k]) < 0xF0 and k + 2 < at:
        var c = ((Int(b[k]) & 0x0F) << 12) | ((Int(b[k + 1]) & 0x3F) << 6) | (Int(b[k + 2]) & 0x3F)
        if (0x0900 <= c <= 0x0FFF) or (0x1000 <= c <= 0x109F) or (0x1780 <= c <= 0x17FF):
            return k
    return start


def without_last(text: String) -> String:
    """The text after Backspace at its end."""
    return String(text[byte=0:erase_start(text, text.byte_length())])


def one_line(text: String) -> String:
    """Text for a field of one line, as a browser pastes it there: its line breaks and tabs are spaces, its own spaces kept."""
    return text.replace("\r\n", " ").replace("\n", " ").replace("\r", " ").replace("\t", " ")


def typed_text(name: String) -> Bool:
    """Whether a key's name is the text it types (a letter, a digit, an accented or other script's character, an emoji),
    not a key such as "Enter" or "F2"."""
    if name.byte_length() == 1:
        return Int(name.as_bytes()[0]) >= 32 and Int(name.as_bytes()[0]) != 127
    for b in name.as_bytes():  # (a key's name is ASCII; "e" with a combining accent isn't)
        if Int(b) >= 0x80:
            return True
    return False
