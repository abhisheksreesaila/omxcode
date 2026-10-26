# mojoui.panel: what a page's content is made of (goal 33 M7, D-415): cards (a head, a body, a foot with the command
# that shows the same thing), quiet panels with a titled icon, a grid of panels, stat tiles, a list of facts (a key
# beside its value), list rows, a stack of cards with the page's insets. Spacing, sizes and colours come from the
# theme's roles.
#
#   CardStack([Card([CardHead("New key"), CardBody([…]), CardFoot("mxc keys new <app>")])])
#   PanelGrid([PanelRow(Panel([PanelTitle("gauge", "Right now", 1), StatGrid(tiles), PanelFoot("mxc status")]), …)])

from mojoui.paragraph import Paragraph, Plain, Run
from mojoui.view import View, Text, Button, VStack, HStack, Spacer, Grid, SUBTLE, CENTER, START, STRETCH, BASELINE, SPACE_XXS, SPACE_XS, SPACE_S, SPACE_M, SPACE_L, Node, VSTACK, _container
from mojoui.chip import Badge
from mojoui.marks import HueIcon
from mojoui.table import capitals


# ---- cards ----

def Card(var items: List[View]) -> View:
    """A card whose parts pad themselves (CardHead, CardBody, CardFoot): the theme's card, no padding of its own (role
    card-bare)."""
    return _container(Node(VSTACK, spacing=0), items).align(START).fill().tag("card-bare")


def CardHead(title: String, badge: String = "", sub: String = "", var lead: List[View] = [], var tail: List[View] = []) -> View:
    """A card's head: `lead` (an IconSquare), its title with `sub` under it, then a badge or `tail` at the end (roles
    card-head, card-title, card-sub; the badge is a mojoui.chip.Badge)."""
    var words: List[View] = [Text(title).tag("card-title")]
    if sub != "":
        words.append(Text(sub).tag("card-sub"))
    var items: List[View] = lead^
    items.append(VStack(words^, spacing=SPACE_XXS).align(START).grow())
    if len(tail) > 0:
        items.append(VStack(spacing=0))  # (the room .card-h's empty .sp keeps before what sits at the end: one more gap)
    if badge != "":
        items.append(Badge(badge))
    items += tail^
    return HStack(items^, spacing=SPACE_M).align(CENTER).fill().tag("card-head")


def CardBody(var items: List[View], flow: Bool = False) -> View:
    """A card's body between its head and foot (role card-body: its insets and spacing). `flow`: its items follow block
    flow, apart by their own roles' margins (a note's 10 above it, none below: role card-body-flow), as a web page's card
    body lays out its paragraphs and lists."""
    if flow:
        return VStack(items^, spacing=0).align(STRETCH).fill().tag("card-body-flow")
    return VStack(items^, spacing=SPACE_M).align(START).fill().tag("card-body")


def foot_words(text: String, note: Bool) -> View:
    """A foot's words: its mark ($, or ↳ for a note) quieter than them in a column of its own (role foot-mark), the words
    beside it the look's gap away (role foot-text): one Paragraph, so it still reads "$ text" whole."""
    var runs: List[Run] = [Plain(("↳" if note else "$") + " ", "foot-mark"), Plain(text)]
    return Paragraph(runs, role="foot-text", lead=True)


def CardFoot(text: String, note: Bool = False, tail: String = "") -> View:
    """A card's foot: the command that shows the same thing after a $ (↳ for a note) over a rule, `tail` at the end
    (role card-foot)."""
    var items: List[View] = [foot_words(text, note)]
    if tail != "":  # (at the foot's end, the room before it: role foot-tail, as .src .tail's margin-left auto, so the
        # words, the tail and the gap between them share a short foot as the original's three items do)
        items.append(Text(tail).tag("foot-tail"))
    return HStack(items^, spacing=SPACE_S).align(CENTER).justify(START).fill().tag("card-foot")


def CopyFoot(command: String, on_copy: Int, note: Bool = False) -> View:
    """A card's foot with a small copy button at its end (roles card-foot, foot-copy); the copy is the app's
    (a mojoui.overlays.Clipboard) on `on_copy`."""
    return HStack(foot_words(command, note), Spacer(), Button("copy", on_copy, SUBTLE).tag("foot-copy"),
                  spacing=SPACE_S).align(CENTER).fill().tag("card-foot")


def CardNote(text: String) -> View:
    """A quiet line inside a card, at its body's insets (Loading…, an empty list; role card-note)."""
    return Text(text).tag("card-note")


def CardStack(var cards: List[View]) -> View:
    """A page's cards top to bottom, at the page's insets (role card-stack)."""
    return VStack(cards^, spacing=SPACE_L).align(START).fill().tag("card-stack")


def CardColumn(var cards: List[View]) -> View:
    """Cards one under another with the theme's space between, no insets of their own (role card-column)."""
    return VStack(cards^, spacing=SPACE_M).align(START).fill().tag("card-column")


def TabBody(head: View, var items: List[View], compact: Bool = False, tight: Bool = False, flush: Bool = False) -> View:
    """What a tab shows: its head (a SubHeader) over its content at the tab's insets (roles tab-body, tab-content;
    tab-content-tight: closer together (a tool row over one view); tab-content-flush: no insets, its parts bring theirs;
    -compact for each)."""
    var role = String("tab-content") + ("-flush" if flush else ("-tight" if tight else "")) + ("-compact" if compact else "")
    var content = VStack(items^, spacing=SPACE_M).align(START).fill().grow().tag(role)
    return VStack(head.copy(), content^, spacing=0).align(START).fill().tag("tab-body-compact" if compact else "tab-body")


def ListRow(var items: List[View], on: Bool = False) -> View:
    """A row in a card's list: a rule above it (roles list-row, list-row-on: the chosen one, tinted)."""
    return HStack(items^, spacing=SPACE_M).align(CENTER).fill().tag("list-row-on" if on else "list-row")


# ---- panels ----

def Panel(var items: List[View]) -> View:
    """A quiet panel on a page: a tonal surface, its items top to bottom (role panel)."""
    return VStack(items^, spacing=SPACE_M).align(START).fill().tag("panel")


def PanelTitle(icon: String, title: String, hue: Int = 0) -> View:
    """A panel's title after its icon in `hue` (roles panel-head, panel-title)."""
    return HStack(HueIcon(icon, 15, hue), Text(title).tag("panel-title"), spacing=SPACE_S).align(CENTER).tag("panel-head")


def PanelFoot(command: String, note: Bool = False) -> View:
    """A panel's last line: the command that shows the same thing after a softer $ (↳ for a note; roles panel-foot,
    panel-foot-mark)."""
    return HStack(Text("↳" if note else "$").tag("panel-foot-mark"), Text(command), spacing=SPACE_S).align(CENTER).tag("panel-foot")


def PanelRow(var panels: List[View], compact: Bool = False) -> View:
    """Panels side by side, sharing the width (role panel-row); compact, one under the other."""
    var grown: List[View] = []
    for p in panels:
        grown.append(p.copy().grow() if not compact else p.copy())
    if compact:
        return VStack(grown^, spacing=SPACE_M).align(START).fill().tag("panel-column")
    return HStack(grown^, spacing=SPACE_L).align(START).fill().tag("panel-row")


def PanelGrid(var rows: List[View], compact: Bool = False) -> View:
    """A page of panels (PanelRows and panels across), at the page's insets (roles panel-grid, panel-grid-compact)."""
    return VStack(rows^, spacing=SPACE_L).align(START).fill().tag("panel-grid-compact" if compact else "panel-grid")


# ---- figures and facts ----

def StatTile(label: String, value: String, unit: String, hint: String) -> View:
    """A number with its label over it (small caps), its unit on its baseline, a hint under it (roles stat-tile,
    stat-label, stat-body, stat-number, stat-value, stat-unit, stat-hint)."""
    var number: List[View] = [Text(value).tag("stat-value")]
    if unit != "":
        number.append(Text(unit).tag("stat-unit"))
    var body = VStack(HStack(number^, spacing=SPACE_XS).align(BASELINE).tag("stat-number"), Text(hint).tag("stat-hint"), spacing=SPACE_XXS).align(START).tag("stat-body")
    return VStack(Text(capitals(label)).tag("stat-label"), body^, spacing=SPACE_XS).align(START).grow().tag("stat-tile")


def StatGrid(var tiles: List[View], columns: Int = 2) -> View:
    """Stat tiles in rows of `columns`, all the same width (roles stat-grid, stat-row)."""
    var rows: List[View] = []
    var k = 0
    while k < len(tiles):
        var row: List[View] = []
        for j in range(columns):
            if k + j < len(tiles):
                row.append(tiles[k + j].copy())
        rows.append(HStack(row^, spacing=SPACE_M).align(STRETCH).fill().tag("stat-row"))
        k += columns
    return VStack(rows^, spacing=SPACE_M).align(START).fill().tag("stat-grid")


comptime KEYS_WIDE = 0  # a Fact's key column: roles fact-key (wide), fact-key-compact, fact-key-narrow, fact-key-medium, fact-key-widest
comptime KEYS_COMPACT = 1
comptime KEYS_NARROW = 2
comptime KEYS_MEDIUM = 3
comptime KEYS_WIDEST = 4


def Fact(key: String, value: View, keys: Int = KEYS_WIDE) -> View:
    """A key beside its value, as a definition list reads (roles fact; fact-key, fact-key-compact, fact-key-narrow,
    fact-key-medium, fact-key-widest: the key column's width, `keys`)."""
    var names: List[String] = ["fact-key", "fact-key-compact", "fact-key-narrow", "fact-key-medium", "fact-key-widest"]
    return HStack(Text(key).tag(names[min(max(keys, 0), 4)]), HStack(value.copy(), spacing=0).align(CENTER).justify(START).grow(), spacing=SPACE_L).align(START).fill().tag("fact")


def LabeledRow(label: String, value: View, compact: Bool = False) -> View:
    """A strong label beside a value in its own column (roles labeled-row, labeled-row-key); compact, over it."""
    if compact:
        return VStack(Text(label).tag("strong"), value.copy(), spacing=SPACE_XXS).align(START).fill().tag("labeled-row-compact")
    return HStack(Text(label).tag("labeled-row-key"), value.copy().grow(), spacing=SPACE_M).align(START).fill().tag("labeled-row")


def FactText(value: String, plain: Bool = False) -> View:
    """A fact's value in the mono (role fact-value), or in plain words (fact-value-plain)."""
    return Text(value).tag("fact-value-plain" if plain else "fact-value")


def FactLink(title: String, on_tap: Int) -> View:
    """A fact's value to tap (Security ›): the mono in the accent (role fact-link)."""
    return Button(title, on_tap, SUBTLE).tag("fact-link")


def FactList(var facts: List[View]) -> View:
    """Facts top to bottom (role fact-list: their spacing)."""
    return VStack(facts^, spacing=SPACE_S).align(START).fill().tag("fact-list")


def ColumnRow(var cells: List[View], tail: View, on: Bool = False, compact: Bool = False) -> View:
    """A list row whose first cells line up in columns down the list (roles column-1, column-2, …: their widths), then
    `tail` at the end (a ListRow). Compact (a phone): the first cell takes the room, the tail a column of the theme's
    width, cut to one line (role column-tail-compact); the other cells are left out."""
    var items: List[View] = []
    if compact:
        if len(cells) > 0:
            items.append(HStack(cells[0].copy(), spacing=0).align(CENTER).justify(START).grow())
        items.append(HStack(tail.copy(), spacing=0).align(CENTER).justify(START).tag("column-tail-compact"))
        return ListRow(items^, on=on)
    for k in range(len(cells)):
        items.append(HStack(cells[k].copy(), spacing=0).align(CENTER).justify(START).tag("column-" + String(k + 1)))
    items.append(Spacer())
    items.append(tail.copy())
    return ListRow(items^, on=on)


def FactGrid(keys: List[String], var values: List[View], mono_keys: Bool = False, end: Bool = False, tight: Bool = False) -> View:
    """Keys beside their values, the keys' column as wide as the widest key (a fitted Grid; roles fact-grid: the space
    between rows and columns, fact-grid-key; fact-grid-key-mono for keys that are names). `end`: the values at the
    trailing edge (figures in a side panel); `tight`: the theme's tighter list (roles fact-grid-tight, fact-grid-key-tight)."""
    var cells: List[View] = []
    var suffix = String("-tight") if tight else String("")
    for k in range(len(keys)):
        cells.append(Text(keys[k]).tag(("fact-grid-key-mono" if mono_keys else "fact-grid-key") + suffix))
        cells.append(values[k].copy() if k < len(values) else Text(""))
    return Grid(cells^, columns=2, spacing=SPACE_M, fit=True, end=end).fill().tag("fact-grid" + suffix)
