# mojoui.sidebar: a column of groups beside a list (goal 33 M7, D-415): small-caps heads, rows to pick (a lead icon,
# dot or #, the label, a count), an action in a head. Compact (a phone): the same rows as a scrolling row of chips, the
# plain heads left out. Spacing, sizes and colours come from the theme's roles.
#
#   Sidebar([SidebarHead("Show"), SidebarItem("All models", "3", GROUP, on=True, icon="box"),
#            SidebarItem("Running", "1", GROUP + 1, dot=7), SidebarHead("Your labels", tail=[TextAction("Edit labels", EDIT)])])

from mojoui.view import View, Text, Button, Icon, VStack, HStack, Spacer, SUBTLE, CENTER, START, SPACE_XXS, SPACE_S
from mojoui.table import capitals
from mojoui.marks import HueDot

comptime SKIP = "sidebar-skip"  # (a head with nothing to show when compact: Sidebar leaves it out)


def SidebarHead(text: String, quiet: String = "", var tail: List[View] = [], compact: Bool = False) -> View:
    """A small-caps head (role sidebar-head), `quiet` after it in lower case (sidebar-quiet), `tail` at its end (an
    Edit). Compact: only its tail, as a chip in the row (sidebar-head-compact, sidebar-head-chip); none, nothing."""
    if compact:
        if len(tail) == 0:
            return VStack(spacing=0).tag(SKIP)
        return HStack(HStack(tail^, spacing=0).align(CENTER).tag("sidebar-head-chip"), spacing=0).align(CENTER).tag("sidebar-head-compact")
    var items: List[View] = [Text(capitals(text))]
    if quiet != "":
        items.append(Text(quiet).tag("sidebar-quiet"))
    if len(tail) > 0:
        items.append(Spacer())
        items += tail^
    return HStack(items^, spacing=SPACE_S).align(CENTER).justify(START).fill().tag("sidebar-head")


def SidebarItem(label: String, count: String, on_tap: Int, on: Bool = False, icon: String = "", dot: Int = -1, hash: Bool = False,
                quiet: Bool = False, compact: Bool = False) -> View:
    """A row to pick: its lead (an `icon`, a `dot` in a hue (HueDot), or a # for a label), the label, the count at the
    end (roles sidebar-item, sidebar-item-on, sidebar-item-quiet (a New … row, faint), sidebar-label, sidebar-count,
    sidebar-dot, sidebar-hash). Compact: a chip (sidebar-chip, sidebar-chip-on), its icon left out."""
    var items: List[View] = []
    if dot >= 0:
        items.append(HStack(HueDot(dot), spacing=0).align(CENTER).tag("sidebar-chip-dot" if compact else "sidebar-dot"))
    elif hash:
        items.append(Text("#").tag("sidebar-hash"))
    elif icon != "" and not compact:
        items.append(Icon(icon, 16))
    var lab = (String("sidebar-chip-label") if compact else String("sidebar-label")) + ("-quiet" if quiet else "")
    items.append(Button(label, on_tap, SUBTLE).align(START).grow().tag(lab) if not compact else Button(label, on_tap, SUBTLE).tag(lab))
    if count != "":
        items.append(Text(count).tag("sidebar-chip-count-on" if compact and on else "sidebar-count"))
    var role: String
    if compact:
        role = "sidebar-chip-on" if on else ("sidebar-chip-quiet" if quiet else "sidebar-chip")
    else:
        role = "sidebar-item-on" if on else ("sidebar-item-quiet" if quiet else "sidebar-item")
    var row = HStack(items^, spacing=SPACE_S).align(CENTER).tag(role)
    return row^.fill() if not compact else row^


def Sidebar(var items: List[View], compact: Bool = False) -> View:
    """The column (role sidebar: its width and insets); compact, a row of chips across the page (sidebar-compact)."""
    var kept: List[View] = []
    for it in items:
        if len(it.nodes) > 0 and it.nodes[0].name == SKIP:
            continue
        kept.append(it.copy())
    if compact:
        return HStack(kept^, spacing=SPACE_S).align(CENTER).justify(START).fill().tag("sidebar-compact")
    return VStack(kept^, spacing=SPACE_XXS).align(START).tag("sidebar")
