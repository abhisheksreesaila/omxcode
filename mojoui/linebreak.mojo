# Line breaks as the browser takes them (D-548). Chrome (Blink) breaks lines between two printable ASCII characters only
# where its own table allows (text_break_iterator.cc's ASCII table, measured in scripts/linebreak_table.py): after "-"
# (before a digit only when a letter or digit stands before the "-"), after "?", and before "(", "<", "[" or "{" after
# a closing or symbol character. Pango and Core Text follow UAX #14, which also breaks after "/", "!", "|" and "}" and
# before "$", "%", "+" or "\" after punctuation, and not after "-" before a digit: a path wrapped after its slashes on
# GTK and the Mac ("/tmp/mxc-console-record/mxc/" | "notebooks/...", 2 lines) and only at its hyphens on the web (3).
#
# css_breaks(text) gives a host's text path those rules: a word joiner (U+2060, no break) where UAX #14 would break and
# the browser wouldn't, a zero-width space (U+200B, a break) where the browser breaks. Both are invisible and have no
# width. Non-ASCII text keeps the toolkit's own rules (the browser's are UAX #14's there too). plain_words(text) takes
# them out again (a host reporting what a label shows).

from mojoui.view import Node

comptime WJ = "\u2060"  # word joiner
comptime ZWSP = "\u200b"  # zero-width space


def _alnum(c: Int) -> Bool:
    return (48 <= c <= 57) or (65 <= c <= 90) or (97 <= c <= 122)


def _in(c: Int, chars: StaticString) -> Bool:
    for b in chars.as_bytes():
        if Int(b) == c:
            return True
    return False


def browser_breaks(before: Int, x: Int, y: Int) -> Bool:
    """Chrome takes a line break between ASCII characters x and y (before: the character before x, 0 at the start)."""
    if x == 45:  # "-"
        if 48 <= y <= 57:  # (a minus sign before a number stays with it: "-5", " -5", ".-5")
            return _alnum(before)
        return _alnum(y) or _in(y, "\"#%&'(*+-<=>@[\\^_`{|~")
    if x == 63:  # "?"
        return _alnum(y) or _in(y, "#$%&(*+-<=>@[\\^_`{|~")
    if _in(x, "!\"#%&)*+,.:;=>\\]|}~"):
        return _in(y, "(<[{")
    return False


def toolkit_may_break(x: Int, y: Int) -> Bool:
    """UAX #14 (Pango, Core Text) may break between ASCII characters x and y where Chrome doesn't."""
    return _in(x, "!|}/") or (not _alnum(x) and _in(y, "$%+\\")) or (x == 36 and _in(y, "([{"))


def css_breaks(text: String) -> String:
    """text with the browser's line breaks between printable ASCII characters (see the top of this file)."""
    var b = text.as_bytes()
    var n = len(b)
    var needs = False
    for i in range(n - 1):
        var x, y = Int(b[i]), Int(b[i + 1])
        if 33 <= x <= 126 and 33 <= y <= 126 and not (_alnum(x) and _alnum(y)):
            needs = True
            break
    if not needs:
        return text
    var out = List[UInt8](capacity=n + 16)
    for i in range(n):
        var x = Int(b[i])
        out.append(b[i])
        if i + 1 < n:
            var y = Int(b[i + 1])
            if 33 <= x <= 126 and 33 <= y <= 126 and not (_alnum(x) and _alnum(y)):
                var before = Int(b[i - 1]) if i > 0 else 0
                if browser_breaks(before, x, y):
                    for c in ZWSP.as_bytes():
                        out.append(c)
                elif toolkit_may_break(x, y):
                    for c in WJ.as_bytes():
                        out.append(c)
    return String(unsafe_from_utf8=out)


def plain_words(text: String) -> String:
    """text without the joiners and breaks css_breaks put in."""
    if WJ not in text and ZWSP not in text:
        return text
    return text.replace(WJ, "").replace(ZWSP, "")


# A label's own box on the web is a block in white-space: normal, so the spaces at its ends are removed, never drawn
# nor measured (CSS Text 3, 4.1.2): "This machine only · " before a link stood 156 wide on GTK and the Mac for the web's
# 148 (D-549). A sentence's line keeps its words' spaces (mojoui.sentence: the web's white-space: pre there).
comptime SENTENCE_LINE = "sentence-line"


def css_ends(text: String) -> String:
    """text without the spaces, tabs and line breaks at its ends (as a block in white-space: normal shows it)."""
    var b = text.as_bytes()
    var n = len(b)
    var start = 0
    var end = n
    while start < end and (b[start] == 32 or b[start] == 9 or b[start] == 10 or b[start] == 13):
        start += 1
    while end > start and (b[end - 1] == 32 or b[end - 1] == 9 or b[end - 1] == 10 or b[end - 1] == 13):
        end -= 1
    if start == 0 and end == n:
        return text
    return String(text[byte=start:end])


def label_words(nodes: List[Node], i: Int) -> String:
    """What a host's label for TEXT node i shows: its words with the browser's line breaks, and without the spaces at
    its ends unless it stands in a sentence's line (white-space: pre there)."""
    var keeps = False
    for k in range(len(nodes)):
        if nodes[k].name == SENTENCE_LINE:
            for c in nodes[k].children:
                if c == i:
                    keeps = True
    return css_breaks(nodes[i].text if keeps else css_ends(nodes[i].text))
