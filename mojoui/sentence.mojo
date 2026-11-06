# mojoui.sentence: a sentence whose words can be tapped (goal 28, D-255): "Sum of amount by region, largest first", where
# "Sum", "amount", "region" and "largest first" are tokens that open their choices. Plain runs and tokens sit on one
# line, wrapping onto the next at a word's edge when the line is full. Hosts draw a token as a word in the accent's
# colour (Button style TOKEN): no fill, a quiet underline, a wash on hover.
#
#   Sentence([Word("Sum", ASK_COMBINE, "word-combine"), Word(" of "), Word("amount", ASK_VALUE, "word-value")], width=46)

from mojoui.view import View, Text, Button, HStack, VStack, HEADLINE, TOKEN, TOKEN_LIT, START, CENTER, NO_MSG
from mojoui.linebreak import SENTENCE_LINE


@fieldwise_init
struct Word(Copyable, Movable):
    var text: String  # what it reads (plain runs carry their own spaces and commas: " of ", ", ")
    var msg: Int  # a token's message (NO_MSG: plain text)
    var tag: String  # a token's tag: where its choices' popover attaches
    var lit: Bool  # just changed (an ask): hosts mark it for a moment

    def __init__(out self, text: String):
        self = Self(text, NO_MSG, "", False)

    def __init__(out self, text: String, msg: Int, tag: String):
        self = Self(text, msg, tag, False)


def _runs(words: List[Word]) -> List[Word]:
    """The words with each plain run cut after every comma that more words follow (", as " → ", " and " as "), so the
    line may break there: whole, it couldn't, and a narrow card squeezed its comma to nothing (the Mac, goal 56)."""
    var out = List[Word]()
    for w in words:
        if w.msg != NO_MSG:
            out.append(w.copy())
            continue
        var rest = w.text
        while True:
            var at = rest.find(", ")
            if at < 0 or at + 2 >= rest.byte_length():
                break
            out.append(Word(String(rest[byte = : at + 1])))
            var tail = String(rest[byte = at + 1 :])
            rest = tail^
        out.append(Word(rest))
    return out^


def _plan(words: List[Word], width: Int) -> List[List[Word]]:
    """Sentence's lines: each the words it shows (a line breaks before a token or a run with a leading space once about
    `width` characters are used, never inside a word; a run opening a line drops its leading space; no empty line)."""
    var lines = List[List[Word]]()
    var line = List[Word]()
    var used = 0
    for w in words:
        var n = w.text.byte_length()
        if used > 0 and used + n > width and (w.msg != NO_MSG or w.text.startswith(" ")):
            if len(line) > 0:
                lines.append(line^)
            line = List[Word]()
            used = 0
            if w.msg == NO_MSG:
                var trimmed = String(w.text.lstrip())
                if trimmed != "":
                    line.append(Word(trimmed))
                    used += trimmed.byte_length()
                continue
        line.append(w.copy())
        used += n
    if len(line) > 0:
        lines.append(line^)
    return lines^


def sentence_lines(words: List[Word], width: Int = 48) -> Int:
    """How many lines Sentence(words, width) takes (the same plan): a card sizes its title bar by it, so a narrow card's
    sentence never runs under what follows (a fixed two-line bar cut a four-line title on the Mac, goal 56)."""
    return len(_plan(_runs(words), width))


def Sentence(words: List[Word], width: Int = 48, style: Int = HEADLINE, tag: String = "sentence") -> View:
    """The words in lines of at most about `width` characters (a line breaks before a token or after a comma, never
    inside a word); tokens are buttons that send their message."""
    var lines = List[View]()
    for planned in _plan(_runs(words), width):
        var line = List[View]()
        for w in planned:
            if w.msg != NO_MSG:
                line.append(Button(w.text, w.msg, TOKEN_LIT if w.lit else TOKEN).tag(w.tag))
            else:
                line.append(Text(w.text, style))
        lines.append(HStack(line^, spacing=0).align(CENTER).justify(START).tag(SENTENCE_LINE))
    return VStack(lines^, spacing=2).align(START).tag(tag)


def sentence_text(words: List[Word]) -> String:
    """The sentence as plain text (a title, a status message, what an agent reads)."""
    var out = String("")
    for w in words:
        out += w.text
    return out
