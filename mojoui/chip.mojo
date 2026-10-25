# mojoui.chip: small labels. A Chip is a pill with a hue (a model's kind: Chat, Embeddings) or a quiet one (a #label);
# a Badge is a hairline box in the mono with a tone (access: This machine; a key's status) and an optional dot; a Pill
# is a quiet count (My models 3). Each wears a framework role its theme shapes: tag="chip", tag="chip-1" … tag="chip-6"
# (the theme's data colours), tag="badge", tag="badge-ok", tag="badge-warn", tag="badge-bad", the dot tag="dot", and
# tag="pill". They sit in a row of their own, so a table cell or a stack doesn't stretch them.
#
#   HStack(Chip("Chat", hue=1), Chip("#work"), spacing=4)   ·   Badge("active", BADGE_OK, dot=True)   ·   Pill("3")

from mojoui.view import View, Text, VStack, HStack, CENTER

comptime BADGE_PLAIN = 0
comptime BADGE_OK = 1
comptime BADGE_WARN = 2
comptime BADGE_BAD = 3


def chip_role(hue: Int) -> String:
    """The role of a chip in data colour `hue` (1–6), or the quiet one (0)."""
    if hue == 1:
        return "chip-1"
    if hue == 2:
        return "chip-2"
    if hue == 3:
        return "chip-3"
    if hue == 4:
        return "chip-4"
    if hue == 5:
        return "chip-5"
    if hue == 6:
        return "chip-6"
    return "chip"


def badge_role(tone: Int) -> String:
    if tone == BADGE_OK:
        return "badge-ok"
    if tone == BADGE_WARN:
        return "badge-warn"
    if tone == BADGE_BAD:
        return "badge-bad"
    return "badge"


def Chip(text: String, hue: Int = 0) -> View:
    """A pill: in data colour `hue` (1–6: its text in the hue on a tint of it), or quiet (0)."""
    return HStack(Text(text).tag(chip_role(hue)), spacing=0)


def Badge(text: String, tone: Int = BADGE_PLAIN, dot: Bool = False) -> View:
    """A hairline box in the mono: BADGE_PLAIN, BADGE_OK, BADGE_WARN or BADGE_BAD; `dot`: a dot in its colour first."""
    var inner: List[View] = []
    if dot:
        inner.append(VStack(spacing=0).width(6).height(6).tag("dot"))
    inner.append(Text(text))
    return HStack(HStack(inner, spacing=5).align(CENTER).tag(badge_role(tone)), spacing=0)


def Pill(text: String) -> View:
    """A quiet count in a pill (a page title's number)."""
    return HStack(Text(text).tag("pill"), spacing=0)
