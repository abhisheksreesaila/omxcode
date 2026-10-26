# mojoui.header: the top of a page (goal 33 M7, D-415): a header (an icon on a tinted square, the title with a count,
# one line under it, the page's tools), a filter bar under it, pill tabs with the actions for what the tabs show, and
# a segmented pair of buttons. Spacing, sizes and colours come from the theme's roles (none here).
#
#   PageHeader("layout-grid", "My models", "3", "3 models · 1 running", [CommandLine("mxc ls"), PrimaryButton("Add", ADD, "plus")])
#   TabHeader(PillTabs(["Overview", "Logs"], ["box", "scroll-text"], 0, TAB, hues=[2, 0]), [FlatButton("Stop", STOP, "square", filled=True)])

from mojoui.view import View, Text, Button, Icon, VStack, HStack, Spacer, SUBTLE, CENTER, START, SPACE_XXS, SPACE_S, SPACE_M
from mojoui.chip import Pill


def hued(role: String, hue: Int) -> String:
    """A role in a hue (1–6 the data colours, 7 good, 8 warning): its icon takes the colour (role-<hue>); 0: the role."""
    return role + ("-" + String(min(hue, 8)) if hue > 0 else String(""))


comptime HUE_QUIET = 7  # a page's square in the quiet ink, no colour of its own (Settings)


def IconSquare(icon: String, hue: Int = 0, tone: Int = -1) -> View:
    """An icon on a tinted rounded square: in data colour `hue` (0 the first; role icon-square, icon-square-<hue>; HUE_QUIET
    the quiet ink), or in a tone when `tone` is set (mojoui.marks QUIET, GOOD, WARN, BAD: role icon-square-tone-<tone>)."""
    var role = ("icon-square-tone-" + String(min(max(tone, 0), 3))) if tone >= 0 else ("icon-square-" + String(min(hue, HUE_QUIET)) if hue > 0 else String("icon-square"))
    return VStack(Icon(icon, 16), spacing=0).align(CENTER).justify(CENTER).tag(role)


def PageHeader(icon: String, title: String, count: String, sub: String, var tools: List[View], hue: Int = 0, var lead: List[View] = [],
               compact: Bool = False) -> View:
    """A page's header: its icon square (in data colour `hue`), the title with a count beside it, one line under it,
    then its tools at the trailing edge (roles page-header, page-title, page-sub, page-tools); `lead`: views before the
    square (a Back); `compact`: no sub line (a phone)."""
    var head: List[View] = [Text(title).tag("page-title")]
    if count != "":
        head.append(Pill(count))
    var items: List[View] = lead^
    var words: List[View] = [HStack(head^, spacing=SPACE_S).align(CENTER)]
    if not compact:
        words.append(Text(sub).tag("page-sub"))
    items += [IconSquare(icon, hue=hue), VStack(words^, spacing=SPACE_XXS).align(START).grow()]
    items.append(HStack(tools^, spacing=SPACE_S).align(CENTER).tag("page-tools"))  # (always there, empty or not: its gap is kept, as the original's .tools)
    return HStack(items^, spacing=SPACE_M).align(CENTER).fill().tag("page-header")


def FilterBar(var items: List[View], compact: Bool = False) -> View:
    """A bar of filters under a header (a search and a view switch; roles filter-bar, filter-bar-compact)."""
    return HStack(items^, spacing=SPACE_M).align(CENTER).fill().tag("filter-bar-compact" if compact else "filter-bar")


def PillTabs(titles: List[String], icons: List[String], selected: Int, on_tap: Int, hues: List[Int] = [], fill: Bool = False) -> View:
    """Tabs on a pill track; tab k sends on_tap + k (roles pill-tabs, tab, tab-on; `hues[k]` colours tab k's icon:
    tab-<hue>, tab-on-<hue>); `fill`: the tabs share the track's width (role pill-tabs-fill, tab-fill…)."""
    var tabs: List[View] = []
    var suffix = String("-fill") if fill else String("")
    for k in range(len(titles)):
        var role = (String("tab-on") if k == selected else String("tab")) + suffix
        tabs.append(Button(titles[k], on_tap + k, SUBTLE, icons[k] if k < len(icons) else String("")).tag(hued(role, hues[k] if k < len(hues) else 0)))
    var strip = HStack(tabs^, spacing=0).align(CENTER).tag("pill-tabs" + suffix)
    return strip^.fill() if fill else strip^


def SegmentButtons(titles: List[String], icons: List[String], selected: Int, on_tap: Int, icons_only: Bool = False, framed: Bool = False) -> View:
    """Two or three buttons joined in a pill, one chosen; button k sends on_tap + k (roles segment, segment-on,
    segment-off; `icons_only`: only their icons show, the titles stay for screen readers: segment-icon-on/off; `framed`:
    on the page's colour in a hairline ring, the chosen one raised (a setting's choice: segment-framed…))."""
    var items: List[View] = []
    for k in range(len(titles)):
        var role = String("segment-framed-") if framed else (String("segment-icon-") if icons_only else String("segment-"))
        items.append(Button(titles[k], on_tap + k, SUBTLE, icons[k] if k < len(icons) else String("")).tag(role + ("on" if k == selected else "off")))
    return HStack(items^, spacing=0).align(CENTER).tag("segment-framed" if framed else "segment")


def ActionGroup(var buttons: List[View], fill: Bool = False) -> View:
    """A page's actions side by side (role action-group; `fill`: they share the width, action-group-fill)."""
    var row = HStack(buttons^, spacing=SPACE_S).align(CENTER).tag("action-group-fill" if fill else "action-group")
    return row^.fill() if fill else row^


def TabHeader(tabs: View, actions: View, compact: Bool = False) -> View:
    """Tabs with the actions for what they show at the trailing edge; compact: the tabs over the actions (roles
    tab-header, tab-header-compact)."""
    if compact:
        return VStack(tabs.copy(), actions.copy(), spacing=SPACE_S).align(START).fill().tag("tab-header-compact")
    return HStack(tabs.copy(), Spacer(), actions.copy(), spacing=SPACE_M).align(CENTER).fill().tag("tab-header")


def SubHeader(text: String, var tools: List[View], compact: Bool = False, status: Bool = False) -> View:
    """A line that says what a tab shows, in the mono, its tools at the end (roles sub-header, sub-header-compact,
    sub-header-text, sub-header-tools). Short of room, the words give way first, never the line wrapping; `status`:
    the first tool is a status chip that gives way next, cut (role sub-header-status)."""
    var items: List[View] = [Text(text).grow().tag("sub-header-text")]
    if status and len(tools) > 0:
        tools[0] = HStack(tools[0].copy(), spacing=0).align(CENTER).tag("sub-header-status")
    if len(tools) > 0:
        items.append(HStack(tools^, spacing=SPACE_S).align(CENTER).tag("sub-header-tools"))
    return HStack(items^, spacing=SPACE_M).align(CENTER).fill().tag("sub-header-compact" if compact else "sub-header")


def ToolRow(var items: List[View]) -> View:
    """A row of tools over a view (a filter field, then a count at the end; role tool-row)."""
    return HStack(items^, spacing=SPACE_M).align(CENTER).fill().tag("tool-row")
