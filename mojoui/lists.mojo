# mojoui.lists: a list page's parts (goal 33 M7, D-415): a column beside the list (or over it, compact), the list's
# count line with a hint at its end, the list's body, its items as a grid of cards, the bar that acts on the ticked
# items, a line for an empty list, and the cells a table row is made of (a name over a second line, a stack, a row of
# chips). Spacing and sizes come from the theme's roles.
#
#   SplitView(Sidebar(…), VStack(ListCount("All models · 3", "tick models to label many at once"), ListBody(Table(…))))

from mojoui.view import View, Text, HStack, VStack, Spacer, Divider, Grid, Scroll, CENTER, START, STRETCH, SPACE_XXS, SPACE_XS, SPACE_S, SPACE_M
from mojoui.marks import SignalDot
from mojoui.buttons import NameLink
from mojoui.words import MonoLine


def SplitView(side: View, main: View, compact: Bool = False) -> View:
    """`side` beside `main` with a rule between, `main` taking the rest (role split-view); compact, `side` over it."""
    if compact:
        return VStack(side.copy(), Divider().fill(), main.copy().fill(), spacing=0).align(START).fill().tag("split-view-compact")
    return HStack(side.copy(), Divider().fill(), main.copy().grow(), spacing=0).align(START).grow().fill().tag("split-view")


def ListCount(text: String, hint: String = "", compact: Bool = False) -> View:
    """A list's count line in the mono, a fainter hint at its end (roles list-count, list-count-compact; mojoui.words
    MonoLine)."""
    var items: List[View] = [MonoLine(text)]
    if hint != "":
        items.append(Spacer())
        items.append(MonoLine(hint, quiet=True))
    return HStack(items^, spacing=SPACE_M).align(CENTER).justify(START).fill().tag("list-count-compact" if compact else "list-count")


def ListBody(content: View, compact: Bool = False) -> View:
    """The list itself under its count line, at the list's insets (roles list-body, list-body-compact)."""
    return HStack(content.copy().grow(), spacing=0).align(START).fill().tag("list-body-compact" if compact else "list-body")


def ListEmpty(text: String) -> View:
    """What an empty list says instead (role list-empty)."""
    return Text(text).tag("list-empty")


def CardGrid(var cards: List[View], columns: Int) -> View:
    """A list's items as cards in rows of `columns` (role card-grid)."""
    return Grid(cards^, columns=columns, spacing=SPACE_M).fill().tag("card-grid")


def SelectionBar(var items: List[View]) -> View:
    """The bar that acts on the ticked items, under the list (role selection-bar)."""
    return HStack(items^, spacing=SPACE_S).align(CENTER).fill().tag("selection-bar")


def NameCell(name: String, on_tap: Int, sub: String = "", signal: Int = 0) -> View:
    """A table cell: a name to tap after its signal dot (`signal` > 0: SignalDot(signal)), its second line under it,
    lined up with the name (roles name-cell, name-cell-head, name-cell-sub)."""
    var head: List[View] = []
    if signal > 0:
        head.append(SignalDot(signal))
    head.append(NameLink(name, on_tap))
    var items: List[View] = [HStack(head^, spacing=SPACE_S).align(CENTER).tag("name-cell-head")]
    if sub != "":
        items.append(HStack(MonoLine(sub), spacing=0).fill().tag("name-cell-sub"))
    return VStack(items^, spacing=SPACE_XXS).align(START).tag("name-cell")


def CellStack(var items: List[View]) -> View:
    """A table cell's views one under another (a state over a note; role cell-stack)."""
    return VStack(items^, spacing=SPACE_XXS).align(START).tag("cell-stack")


def PageColumn(var items: List[View], compact: Bool = False) -> View:
    """A page's content in one column no wider than the theme's reading width (roles page-column, page-column-compact)."""
    return VStack(items^, spacing=SPACE_M).align(START).fill().tag("page-column-compact" if compact else "page-column")


def MainAside(main: View, aside: View, aside_wide: Bool = False, compact: Bool = False) -> View:
    """`main` (scrolling, taking the rest) beside `aside`, which is narrow until `aside_wide` (roles main-aside,
    aside-narrow, aside-wide); compact, the aside under the main (main-aside-compact)."""
    if compact:
        return VStack(main.copy(), aside.copy().fill(), spacing=SPACE_M).align(START).fill().tag("main-aside-compact")
    return HStack(Scroll(main.copy(), height=0).grow(), HStack(aside.copy().grow(), spacing=0).align(STRETCH).tag("aside-wide" if aside_wide else "aside-narrow").grow() if aside_wide
                  else HStack(aside.copy().grow(), spacing=0).align(STRETCH).tag("aside-narrow"), spacing=SPACE_M).align(STRETCH).fill().grow().tag("main-aside")


def SideScroll(content: View) -> View:
    """`content` (a wide table) on one line that scrolls sideways when the page is narrower (role side-scroll; a table
    inside keeps its cells on one line)."""
    return HStack(content.copy(), spacing=0).align(START).justify(START).fill().tag("side-scroll")
