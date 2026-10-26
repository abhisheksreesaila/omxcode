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


def Sentence(words: List[Word], width: Int = 48, style: Int = HEADLINE, tag: String = "sentence") -> View:
    """The words in lines of at most about `width` characters (a line breaks before a token or after a comma, never
    inside a word); tokens are buttons that send their message."""
    var lines = List[View]()
    var line = List[View]()
    var used = 0
    for w in words:
        var n = w.text.byte_length()
        if used > 0 and used + n > width and (w.msg != NO_MSG or w.text.startswith(" ")):
            lines.append(HStack(line^, spacing=0).align(CENTER).justify(START).tag(SENTENCE_LINE))
            line = List[View]()
            used = 0
            if w.msg == NO_MSG:  # (a run that would open the new line drops its leading space)
                var trimmed = String(w.text.lstrip())
                if trimmed != "":
                    line.append(Text(trimmed, style))
                    used += trimmed.byte_length()
                continue
        if w.msg != NO_MSG:
            line.append(Button(w.text, w.msg, TOKEN_LIT if w.lit else TOKEN).tag(w.tag))
        else:
            line.append(Text(w.text, style))
        used += n
    if len(line) > 0:
        lines.append(HStack(line^, spacing=0).align(CENTER).justify(START).tag(SENTENCE_LINE))
    return VStack(lines^, spacing=2).align(START).tag(tag)


def sentence_text(words: List[Word]) -> String:
    """The sentence as plain text (a title, a status message, what an agent reads)."""
    var out = String("")
    for w in words:
        out += w.text
    return out
