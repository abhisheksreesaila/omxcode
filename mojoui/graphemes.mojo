# Where a caret may stand in a text (review 3, MUST 6): between graphemes (what a person sees as one character: a letter
# with its accents, an emoji family, a flag, a Hangul syllable), never inside one and never inside a UTF-8 character. Every
# field's caret, Backspace and Delete use these. Positions are bytes.


def _plain(c: Int) -> Bool:
    """A character that joins neither the one before nor the one after it: two in a row always have a boundary between them
    (letters of Latin, Greek, Cyrillic, Hebrew and Arabic, kana, ideographs, whole Hangul syllables; not marks, not emoji)."""
    if c < 0x80:
        return c >= 0x20 and c != 0x7F
    return ((0xC0 <= c <= 0x24F) or (0x391 <= c <= 0x3FF) or (0x400 <= c <= 0x482) or (0x48A <= c <= 0x52F) or (0x5D0 <= c <= 0x5EA) or (0x621 <= c <= 0x64A)
            or (0x3041 <= c <= 0x3096) or (0x30A1 <= c <= 0x30FA) or (0x3400 <= c <= 0x4DBF) or (0x4E00 <= c <= 0x9FFF) or (0xAC00 <= c <= 0xD7A3))


def _char_at(text: String, i: Int) -> Int:
    var b = text.as_bytes()
    var c = Int(b[i])
    if c < 0x80:
        return c
    if c >= 0xF0 and i + 3 < len(b):
        return ((c & 7) << 18) | ((Int(b[i + 1]) & 63) << 12) | ((Int(b[i + 2]) & 63) << 6) | (Int(b[i + 3]) & 63)
    if c >= 0xE0 and i + 2 < len(b):
        return ((c & 15) << 12) | ((Int(b[i + 1]) & 63) << 6) | (Int(b[i + 2]) & 63)
    if c >= 0xC0 and i + 1 < len(b):
        return ((c & 31) << 6) | (Int(b[i + 1]) & 63)
    return 0  # (inside a character)


def safe_start(text: String, at: Int) -> Int:
    """A boundary at or before byte `at`, found by looking back a few characters, never from the text's start unless it has
    to: between two plain characters."""
    var b = text.as_bytes()
    var i = min(at, len(b))
    var after = False  # (the character at i is plain)
    if i < len(b) and (Int(b[i]) & 0xC0) != 0x80:
        after = _plain(_char_at(text, i))
    while i > 0:
        var k = i - 1
        while k > 0 and (Int(b[k]) & 0xC0) == 0x80:
            k -= 1
        var plain = _plain(_char_at(text, k))
        if plain and after:
            return i
        after = plain
        i = k
    return 0


def prev_grapheme(text: String, at: Int) -> Int:
    """The boundary before byte `at` (0 at the start)."""
    var from_ = safe_start(text, at - 1) if at > 0 else 0
    var last = from_
    var pos = from_
    for g in text[byte=from_:].graphemes():
        var n = g.byte_length()
        if pos + n >= at:
            return pos
        pos += n
        last = pos
    return min(last, at)


def next_grapheme(text: String, at: Int) -> Int:
    """The boundary after byte `at` (the text's length at the end)."""
    var pos = safe_start(text, at)
    for g in text[byte=pos:].graphemes():
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
