# mojoui.inspector: a properties panel like Numbers' Format inspector. It's built from the native controls
# (Segmented, Dropdown, Toggle, Button, Text), so it runs on every host that has them.
#
#   Inspector(["Table", "Cell"], tab, ON_TAB, [
#       Section("Data format", [Dropdown(FORMATS, f, ON_FORMAT).fill(),
#                               Row("Decimals", Stepper("2", ON_LESS, ON_MORE)),
#                               Row("Thousands", Toggle("", on, ON_THOUSANDS))]),
#   ])

from mojoui.view import (View, Text, Button, Segmented, HStack, VStack, Spacer, Divider, Card, Scroll, Grid, CAPTION, HEADLINE, SUBTLE,
                         ICON_ONLY, CENTER, STRETCH, START)


def StatCards(stats: List[Tuple[String, String]]) -> View:
    """Small cards of a selection's figures, two across (a label over its value): Stitch's column stats."""
    var cards = List[View]()
    for st in stats:
        cards.append(VStack(Text(st[0], CAPTION), Text(st[1]).tag("stat-value"), spacing=2).align(START).fill().padding(8, 10).tag("stat-card"))
    return Grid(cards^, 2, spacing=8).fill()


def Section(title: String, items: List[View]) -> View:
    """A titled group of controls (the title in small caps on the hosts that have them)."""
    var all = List[View]()
    all.append(Text(title.upper(), CAPTION).tag("section-title"))
    for v in items:
        all.append(v.copy())
    return VStack(all^, spacing=8).fill().align(START)


def NavRow(title: String, summary: String, on_open: Int, icon: String = "") -> View:
    """A row that opens a page of its own (InspectorPage): its title, what's set now beneath it, a chevron. The whole
    title is the button; the chevron sends the same message."""
    return HStack(VStack(Button(title, on_open, SUBTLE, icon=icon).fill().align(START).tag("nav-title"),
                         Text(summary, CAPTION).padding(0, 12).tag("nav-summary"), spacing=0).fill().grow().align(START),
                  Button("Open " + title, on_open, ICON_ONLY, icon="chevron-right"), spacing=4).fill().align(CENTER).tag("nav-row")


def InspectorPage(title: String, on_back: Int, sections: List[View]) -> List[View]:
    """A page an inspector row opened: a Back button and the page's title, then its sections. Hand the result to
    Inspector as its sections; themes slide it in (it's tagged "inspector-page")."""
    var out = List[View]()
    out.append(HStack(Button("Back", on_back, SUBTLE, icon="back").tag("page-back"), Text(title, HEADLINE), Spacer(), spacing=6).fill().align(CENTER).tag("inspector-page"))
    for v in sections:
        out.append(v.copy())
    return out^


def Row(label: String, control: View) -> View:
    """A label on the left, its control on the right; the label also names the control for a screen reader when
    nothing else does (a toggle or a dropdown has no words of its own: mojoui.a11y)."""
    var c = control.copy()
    if c.nodes[0].label == "" and c.nodes[0].tip == "":
        c = c^.label(label)
    return HStack(Text(label), Spacer(), c^, spacing=8).fill().align(CENTER).tag("inspector-row")  # (a look sets its height)


def Stepper(value: String, on_less: Int, on_more: Int) -> View:
    """− value +: a number nudged one step at a time (decimal places, font size, gap)."""
    return HStack(Button("−", on_less, SUBTLE), Text(value), Button("+", on_more, SUBTLE), spacing=4).align(CENTER)


def Inspector(tabs: List[String], selected: Int, on_tab: Int, sections: List[View], width: Int = 300, height: Int = 600) -> View:
    """The panel: tabs across the top (Table · Cell · Text · Arrange), then sections divided by hairlines; the
    sections scroll when they're taller than `height` (a table with many columns)."""
    var body = List[View]()
    for k in range(len(sections)):
        if k > 0:
            body.append(Divider())
        body.append(sections[k].copy())
    var all = List[View]()
    if len(tabs) == 1:  # (one page: its name as a title, not a switch with one choice)
        all.append(Text(tabs[0], HEADLINE).tag("inspector-title"))
    else:
        all.append(Segmented(tabs, selected, on_tab).fill())
    all.append(Scroll(VStack(body^, spacing=14).fill(), height=height).fill().grow())  # (it takes the card's room, and scrolls when that's less)
    return Card(all^, spacing=14).width(width).grow().tag("inspector")
