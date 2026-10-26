# mojoui.results: rows of search results (goal 33 M7, D-415): where each comes from (a hairline badge in a hue), the
# name to tap over a quiet line, a status mark and a figure at the end; and a suggestion tile. Sizes and colours come
# from the theme's roles.
#
#   ResultRow("MAX", 3, "qwen2.5-0.5b", PICK + k, "Qwen/Qwen2.5-0.5B-Instruct · 1 GB", StatusMark("fits", GOOD), "~2.2 GB VRAM")

from mojoui.view import View, Text, Button, VStack, HStack, SUBTLE, CENTER, START, END, SPACE_XXS, SPACE_XS, SPACE_M


def SourceBadge(text: String, hue: Int) -> View:
    """Where a result comes from, a hairline box in the mono in data colour `hue` (roles source-badge-<hue>)."""
    return HStack(Text(text), spacing=0).justify(CENTER).align(CENTER).tag("source-badge-" + String(min(max(hue, 1), 6)))


def ResultRow(badge: String, badge_hue: Int, name: String, on_tap: Int, meta: String, mark: View, figure: String) -> View:
    """One result: its source badge, the name to tap over its quiet line, `mark` (a StatusMark) over the figure at the
    trailing edge; a rule above it (roles result-row, result-name, result-meta, result-figure)."""
    var ends: List[View] = [mark.copy()]
    if figure != "":
        ends.append(Text(figure).tag("result-figure"))
    var words: List[View] = [Button(name, on_tap, SUBTLE).tag("result-name")]
    if meta != "":
        words.append(Text(meta).tag("result-meta"))
    return HStack(SourceBadge(badge, badge_hue), VStack(words^, spacing=SPACE_XXS).align(START).grow(), VStack(ends^, spacing=SPACE_XS).align(END),
                  spacing=SPACE_M).align(CENTER).fill().tag("result-row")


def SuggestionTile(var items: List[View]) -> View:
    """A suggestion to pick, a quiet tile among others in a row (role suggestion)."""
    return VStack(items^, spacing=SPACE_XS).align(START).grow().tag("suggestion")


def SuggestionRow(var tiles: List[View]) -> View:
    """Suggestion tiles side by side, sharing the width (role suggestion-row)."""
    return HStack(tiles^, spacing=SPACE_M).align(START).fill().tag("suggestion-row")
