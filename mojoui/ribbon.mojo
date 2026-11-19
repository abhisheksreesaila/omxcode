# mojoui.ribbon: a tabbed ribbon, as Office has it (goal 76): one row of tab names (the app's mark leading, a status
# island trailing) and, under it, a band of the selected tab's tools in captioned groups, a divider between groups.
# It replaces a menu bar row plus a toolbar row (and a side rail of insert tools).
#
#   Ribbon([RibbonTab("Home", [RibbonGroup("Clipboard", [ribbon_tool("Save", "save", SAVE, "Save (Ctrl+S)"), …])]),
#           RibbonTab("Insert", [RibbonGroup("From a file", [ribbon_picker("Table", "table", PICK_TABLE, ".csv,.parquet")])])],
#          selected, ON_TAB, leading=[mark, file_menu], trailing=[island])
#
# Every tab's band is in the tree; the bands of the tabs that aren't selected are .hidden() (D-7601): an agent lists
# every tool of every tab and a test step taps any of them by its title or tag, without picking the tab first. A tool
# may sit on two tabs (Links on Insert and View): both send the same message. Keyboard shortcuts are the app's menus'
# (a menu can be .hidden() and still lend its items' shortcuts; on a Mac the system menu bar shows it).
# Tags a theme styles: "menubar" (the tab row: the role an app bar had), "ribbon-tabs" (the tab names: a quiet segmented
# row), "toolbar" (each band: the role a toolbar had), "ribbon-group", "ribbon-caption".

from mojoui.view import (View, Text, Button, FilePicker, HStack, VStack, Spacer, Divider, CAPTION, TOOL, TOOL_ON, ICON_ONLY,
                         ICON_ON, PLAIN, SUBTLE, CENTER, NO_MSG)

comptime RIBBON_HEAD_H = 38  # the tab row's height (an app bar's)
comptime RIBBON_BAND_H = 78  # a band's height, labelled: every tab the same, so switching tabs never moves the page
comptime RIBBON_BAND_COMPACT_H = 44  # a band's height in compact mode (icons only, no captions)


@fieldwise_init
struct RibbonTool(Copyable, Movable):
    """One tool on a ribbon band: a button (its icon over its title), a file picker (`accept` set: a picker's types, or
    "folder"), or a small icon-only toggle (`small`: Bold, Align left), shown pressed while `on`."""

    var title: String
    var icon: String
    var message: Int
    var on: Bool
    var tip: String  # the tooltip ("Save the document (Ctrl+S)"); "" for the title
    var tag: String  # the name agents and test steps use ("" for the title; a small toggle's default is its icon)
    var accept: String  # a file picker's types; "" for a button
    var small: Bool


def ribbon_tool(title: String, icon: String, message: Int, tip: String = "", on: Bool = False, tag: String = "") -> RibbonTool:
    """A button: its icon over its title (only its icon in compact mode)."""
    return RibbonTool(title, icon, message, on, tip, tag, "", False)


def ribbon_picker(title: String, icon: String, message: Int, accept: String, tip: String = "", tag: String = "") -> RibbonTool:
    """A file picker (accept: ".csv,.parquet", or "folder"): the chosen path comes with `message` in event.text."""
    return RibbonTool(title, icon, message, False, tip, tag, accept, False)


def ribbon_toggle(title: String, icon: String, message: Int, on: Bool, tip: String = "", tag: String = "") -> RibbonTool:
    """A small icon-only toggle (Bold, Italic, Align left), pressed while `on`; the title is its tooltip and its name."""
    return RibbonTool(title, icon, message, on, tip, tag if tag != "" else icon, "", True)


@fieldwise_init
struct RibbonGroup(Copyable, Movable):
    """A captioned group of tools on a band ("Clipboard", "From a file"); `views` (a dropdown with its words) sit after
    the tools."""

    var caption: String
    var tools: List[RibbonTool]
    var views: List[View]


def ribbon_group(caption: String, var tools: List[RibbonTool], var views: List[View] = []) -> RibbonGroup:
    return RibbonGroup(caption, tools^, views^)


@fieldwise_init
struct RibbonTab(Copyable, Movable):
    """One tab: its title and its band's groups. `contextual`: a tab that shows only while something is chosen (the
    Report's own tools), marked so a theme can tint it."""

    var title: String
    var groups: List[RibbonGroup]
    var contextual: Bool


def ribbon_tab(title: String, var groups: List[RibbonGroup], contextual: Bool = False) -> RibbonTab:
    return RibbonTab(title, groups^, contextual)


def slug(text: String) -> String:
    """A tab's title as a tag's end: lower case, spaces as dashes ("Insert" → "insert")."""
    return text.lower().replace(" ", "-")


def tool_view(t: RibbonTool, compact: Bool) -> View:
    """One tool as a native control: a TOOL button (icon over title), an icon-only one in compact mode or when small."""
    var icon_only = compact or t.small
    var style = (ICON_ON if t.on else ICON_ONLY) if icon_only else (TOOL_ON if t.on else TOOL)
    var v = FilePicker(t.title, t.message, style=style, icon=t.icon, accept=t.accept) if t.accept != "" else Button(t.title, t.message, style, icon=t.icon)
    if t.tip != "":
        v = v^.tooltip(t.tip)
    if t.tag != "":
        v = v^.tag(t.tag)
    return v^


def group_view(g: RibbonGroup, compact: Bool) -> View:
    """A group: its tools in a row, its caption under them (no caption in compact mode)."""
    var row = List[View]()
    for t in g.tools:
        row.append(tool_view(t, compact))
    for v in g.views:
        row.append(v.copy())
    var tools = HStack(row^, spacing=2).align(CENTER)
    if compact:
        return tools^.tag("ribbon-group")
    return VStack(tools^, Spacer(), HStack(Text(g.caption, CAPTION).tag("ribbon-caption")), spacing=0).align(CENTER).height(RIBBON_BAND_H - 8).tag("ribbon-group")


def band_view(tab: RibbonTab, shown: Bool, compact: Bool) -> View:
    """A tab's band: its groups, a divider between each two, the rest of the row free."""
    var items = List[View]()
    for k in range(len(tab.groups)):
        if k > 0:
            items.append(Divider().height(RIBBON_BAND_COMPACT_H - 8 if compact else RIBBON_BAND_H - 20))
        items.append(group_view(tab.groups[k], compact))
    items.append(Spacer())
    var h = RIBBON_BAND_COMPACT_H if compact else RIBBON_BAND_H
    return HStack(items^, spacing=6).fill().align(CENTER).height(h).padding(4, 10).tag("toolbar").hidden(not shown)


def Ribbon(tabs: List[RibbonTab], selected: Int, on_tab: Int, leading: List[View] = [], trailing: List[View] = [], compact: Bool = False) -> View:
    """The ribbon: the tab row (leading views, the tab names, then the trailing views at the far end) and the bands.
    Tab k sends `on_tab + k`; the selected one stands out (a quiet segmented row). `compact` (a narrow window): every
    tool only its icon (its title the tooltip and its name), no captions, a lower band. Every tab's tools stay in the
    tree (D-7601): only the selected tab's band shows."""
    var row = List[View]()
    for v in leading:
        row.append(v.copy())
    var names = List[View]()
    for k in range(len(tabs)):
        var b = Button(tabs[k].title, on_tab + k, PLAIN if k == selected else SUBTLE).tag("ribbon-tab-" + slug(tabs[k].title))
        names.append(b^.tooltip("The " + tabs[k].title + " tools" + (" (shown while it's open)" if tabs[k].contextual else "")))
    row.append(HStack(names^, spacing=2).align(CENTER).tag("ribbon-tabs"))
    row.append(Spacer())
    for v in trailing:
        row.append(v.copy())
    var parts = List[View]()
    parts.append(HStack(row^, spacing=10).fill().align(CENTER).height(RIBBON_HEAD_H).padding(2, 10).tag("menubar"))
    for k in range(len(tabs)):
        parts.append(band_view(tabs[k], k == selected, compact))
    return VStack(parts^, spacing=0).fill().tag("ribbon")


def tab_of(tabs: List[RibbonTab], message: Int) -> Int:
    """The first tab holding a tool that sends `message` (-1: none): an app selecting the tab of a tool a shortcut used."""
    for k in range(len(tabs)):
        for g in tabs[k].groups:
            for t in g.tools:
                if t.message == message:
                    return k
    return -1


def ribbon_messages(tabs: List[RibbonTab]) -> List[Int]:
    """Every message the ribbon's tools send, in order (a check that no tool was lost when tools moved into it)."""
    var out = List[Int]()
    for tab in tabs:
        for g in tab.groups:
            for t in g.tools:
                out.append(t.message)
    return out^
