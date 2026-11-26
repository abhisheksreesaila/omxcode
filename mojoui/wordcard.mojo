# mojoui.wordcard: a word explained as a card (goal 77 M2): the word typed out big, how it sounds, its part of speech, its meaning,
# one example with the word emphasised, and where it comes from. An agent builds it as render_ui's `WordCard` (mojoui.genui); an
# app can place one itself.
#
#   WordCard("card1", canvas, version, word, sounds, kind, meaning, example, origin)      the card's body (put it in a Card)
#   draw_word(surface, palette, font, word, born_ns)                                      the canvas: letters typed in one by one
#   word_parts("card1", word, sounds, origin) -> List[Part]                               what speech may point at (mojoui.pointer)
#
# Its parts, each a tagged view (card + "." + part): word (the big word), sounds, meaning, example, origin. The word is named by
# itself; the others by the words people use when they say them ("means", "for example", "comes from"): those are cues, which
# count where no part was named. The meaning and the example wear a small caption of their own name, so a spoken "the meaning
# says…" refers to something on the card.

from mojoui.canvas import Surface
from mojoui.chip import Chip
from mojoui.clock import now_ns
from mojoui.draw import with_alpha, rect
from mojoui.paragraph import Paragraph, Plain, Bold, Run
from mojoui.pointer import Part
from mojoui.text import Font, MEDIUM
from mojoui.theme import Palette
from mojoui.view import View, Text, Canvas, VStack, HStack, Spacer, HEADLINE, CAPTION, START, CENTER, SPACE_XS, SPACE_S

comptime LETTER_MS = 75  # one letter typed every this many milliseconds
comptime SETTLE_MS = 240  # a letter's own rise, from clear to ink
comptime WORD_FIT = 296.0  # points: the widest the word may be (a phone's card)


def _letters(word: String) -> Int:
    var n = 0
    for _ in word.codepoints():
        n += 1
    return n


def word_size(word: String) -> Float64:
    """The big word's size in points: 58 for a short one, smaller so that a long one still fits a phone's card."""
    var n = Float64(max(_letters(word), 1))
    return min(max(WORD_FIT / (0.56 * n), 36.0), 58.0)


def word_width(word: String) -> Int:
    return Int(min(0.56 * word_size(word) * Float64(_letters(word)) + 12.0, WORD_FIT + 12.0))


def word_parts(card: String, word: String, sounds: String, origin: String) -> List[Part]:
    var out = List[Part]()
    out.append(Part(card, "word", [word], False, True))
    out.append(Part(card, "meaning", ["means", "meaning", "definition", "refers to", "describes", "is when", "is a", "is an", "is the"], True, False))
    out.append(Part(card, "example", ["for example", "example", "for instance", "such as", "as in", "like when", "you might say", "you could say"], True, False))
    if sounds != "":
        out.append(Part(card, "sounds", ["pronounced", "you say it", "sounds like", "say it"], True, False))
    if origin != "":
        out.append(Part(card, "origin", ["comes from", "from the latin", "from the greek", "from old", "from french", "originally", "origin"], True, False))
    return out^


def _lower(s: String) -> String:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b + 32 if 65 <= Int(b) <= 90 else b)
    return String(unsafe_from_utf8=out)


def emphasised(example: String, word: String) -> List[Run]:
    """The example's words with every occurrence of the word (any case) in bold."""
    var runs = List[Run]()
    var hay = _lower(example)
    var needle = _lower(word)
    var at = 0
    var n = needle.byte_length()
    var h = hay.as_bytes()
    var nd = needle.as_bytes()
    var i = 0
    while n > 0 and i + n <= len(h):
        var same = True
        for k in range(n):
            if h[i + k] != nd[k]:
                same = False
                break
        if same:
            if i > at:
                runs.append(Plain(String(example[byte = at : i])))
            runs.append(Bold(String(example[byte = i : i + n])))
            i += n
            at = i
        else:
            i += 1
    if at < example.byte_length():
        runs.append(Plain(String(example[byte = at :])))
    return runs^


def _part(label: String, body: View, tag: String) -> View:
    return VStack(Text(label, CAPTION), body.copy(), spacing=SPACE_XS).align(START).fill().tag(tag)


def WordCard(card: String, canvas: Int, version: Int, word: String, sounds: String, kind: String, meaning: String, example: String, origin: String) -> View:
    var items = List[View]()
    items.append(Canvas(canvas, version).width(word_width(word)).height(Int(word_size(word) * 1.3)).tag(card + ".word"))
    if sounds != "" or kind != "":
        var row = List[View]()
        if sounds != "":
            row.append(Text(sounds, HEADLINE).tag(card + ".sounds"))
        if kind != "":
            row.append(Chip(kind, 0))
        items.append(HStack(row^, spacing=SPACE_S).align(CENTER))
    items.append(_part("meaning", Paragraph([Plain(meaning)], style=HEADLINE), card + ".meaning"))
    if example != "":
        items.append(_part("example", Paragraph(emphasised(example, word)), card + ".example"))
    if origin != "":
        items.append(_part("origin", Paragraph([Plain(origin)]), card + ".origin"))
    return VStack(items^, spacing=SPACE_S + 4).align(START).fill()


def revealed(word: String, born_ns: Int, now: Int) -> Bool:
    """Every letter has been typed in."""
    var letters = _letters(word)
    return (now - born_ns) // 1_000_000 >= letters * LETTER_MS + SETTLE_MS


def draw_word(mut s: Surface, p: Palette, font: Font, word: String, born_ns: Int):
    """The word, one letter at a time: each rises from a little below and darkens from clear to ink, 75 ms after the one before;
    an accent line grows under it as the last letter lands. Asks for the next frame until it is done (`s.still`: all at once)."""
    s.fill(p.card)
    var k = s.scale
    var size = word_size(word) * k
    var elapsed = Float64(now_ns() - born_ns) / 1e6 if not s.still else 1e9
    var x = 2.0 * k
    var base = Float64(s.height) * 0.78
    var i = 0
    var typed = String("")
    for c in word.codepoints():
        var q = min(max((elapsed - Float64(i * LETTER_MS)) / Float64(SETTLE_MS), 0.0), 1.0)
        var ease = 1.0 - (1.0 - q) * (1.0 - q) * (1.0 - q)
        var at = x + font.measure(typed, size, MEDIUM)
        if q > 0.0:
            font.draw(s, String(c), at, base + (1.0 - ease) * 0.22 * size, size, with_alpha(p.ink, ease), MEDIUM)
        typed += String(c)
        i += 1
    var line = min(max((elapsed - Float64(i * LETTER_MS)) / Float64(SETTLE_MS * 2), 0.0), 1.0)
    var width = font.measure(word, size, MEDIUM)
    rect(s, x, base + 0.10 * size, width * line, 3.0 * k, with_alpha(p.accent, 0.85), 1.5 * k)
    if elapsed < Float64(i * LETTER_MS + SETTLE_MS * 2) + 30.0:
        s.again = True
