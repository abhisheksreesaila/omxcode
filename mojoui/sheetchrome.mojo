# mojoui.sheetchrome: the frame around a spreadsheet, as in Numbers and Excel: a toolbar of icon-over-label tools
# (with a group of small format toggles: Bold, Italic, Align…), the sheet's tabs (along the top, or along the bottom
# as Excel has them, renamed in place), a formula bar and a status bar. Built from native controls, so every host that
# has them draws it.

from mojoui.view import (View, Text, Button, TextField, Tabs, HStack, VStack, Spacer, Divider, Icon, HEADLINE, CAPTION, TOOL, TOOL_ON, TOOL_INLINE, TOOL_INLINE_ON, ICON_ONLY,
                         ICON_ON, SUBTLE, PLAIN, CENTER, NO_MSG)


@fieldwise_init
struct Tool(Copyable, Movable):
    """One toolbar button: its title, Lucide icon name, message, and whether it's the active tool."""

    var title: String
    var icon: String
    var message: Int
    var on: Bool
    var tip: String  # the tooltip ("Save the document (Ctrl+S)"); "" for none


def tool_views(tools: List[Tool], inline: Bool = False, compact: Bool = False) -> List[View]:
    var out = List[View]()
    for t in tools:
        var style = (ICON_ON if t.on else ICON_ONLY) if compact else ((TOOL_INLINE_ON if t.on else TOOL_INLINE) if inline else (TOOL_ON if t.on else TOOL))
        var b = Button(t.title, t.message, style, icon=t.icon)
        out.append(b^.tooltip(t.tip) if t.tip != "" else b^)
    return out^


def Toggles(tools: List[Tool]) -> List[View]:
    """Small icon-only tools (Bold, Italic, Align left…), each shown pressed while it's `on`; the title is the tooltip
    and the name an agent or a screen reader uses."""
    var out = List[View]()
    for t in tools:
        var b = Button(t.title, t.message, ICON_ON if t.on else ICON_ONLY, icon=t.icon).tag(t.icon)
        out.append(b^.tooltip(t.tip) if t.tip != "" else b^)
    return out^


def Toolbar(left: List[Tool], middle: List[Tool], right: List[Tool], extra: List[View] = [], toggles: List[List[Tool]] = [],
            before: List[View] = [], after: List[View] = [], inline: Bool = False, compact: Bool = False) -> View:
    """Three groups, as in Numbers: view controls on the left, insert tools in the middle, organise and
    format on the right. `toggles`: groups of small format toggles after the middle tools, a divider before each
    (as Excel's Home tab has them). `before` and `after` (a dropdown with its caption, say) sit either side of the
    middle tools; `extra` (a status chip) at the far right. `inline`: each tool's title beside its icon, so every
    tool and toggle sits on one line, one height (TOOL_INLINE). `compact`: only the icons (a narrow window), the titles
    in the tooltips."""
    var items = tool_views(left, inline, compact)
    items.append(Spacer())
    for v in before:
        items.append(v.copy())
    for v in tool_views(middle, inline, compact):
        items.append(v.copy())
    if len(after) > 0:
        items.append(Divider().height(28))
    for v in after:
        items.append(v.copy())
    for group in toggles:
        items.append(Divider().height(28))
        for v in Toggles(group):
            items.append(v.copy())
    items.append(Spacer())
    for v in tool_views(right, inline, compact):
        items.append(v.copy())
    for v in extra:
        items.append(v.copy())
    return HStack(items^, spacing=2).fill().align(CENTER).padding(4, 10).tag("toolbar")


def AppBar(name: String, var menubar: View, var trailing: List[View]) -> View:
    """The window's header row: the app's mark (its logo and name), its menus, and what sits at the far end (a status
    island). Tagged "menubar" (themes float it: Liquid's glass strip); on a Mac the menus live in the system menu bar
    and the row keeps the mark and the trailing views."""
    var row: List[View] = [HStack(Icon("app-logo", 18), Text(name, HEADLINE), spacing=6).align(CENTER).tag("app-mark"), menubar^, Spacer()]
    for v in trailing:
        row.append(v.copy())
    return HStack(row^, spacing=10).fill().align(CENTER).height(38).padding(2, 10).tag("menubar")


def SheetTabs(names: List[String], selected: Int, on_select: Int, on_add: Int = NO_MSG) -> View:
    """The sheets of a document, with + to add one (no + when on_add is NO_MSG)."""
    var items = List[View]()
    items.append(Tabs(names, selected, on_select))
    if on_add != NO_MSG:
        items.append(Button("Add sheet", on_add, ICON_ONLY, icon="plus"))
    items.append(Spacer())
    return HStack(items^, spacing=4).fill().align(CENTER).tag("sheet-tabs")


@fieldwise_init
struct Tab(Copyable, Movable):
    """One of a document's tabs along the bottom: its name and icon."""

    var name: String
    var icon: String


def BottomTabs(tabs: List[Tab], selected: Int, on_tap: Int, renaming: Int = -1, on_rename: Int = NO_MSG, on_cancel: Int = NO_MSG,
               right: List[View] = []) -> View:
    """A document's tabs along the bottom of the window, as Excel has them: tab k sends `on_tap + k`; the selected
    one stands out, and tapping it again is the app's cue to rename it. While tab `renaming` is being renamed its
    name is a field (Enter sends `on_rename` with the new name in event.text, Escape `on_cancel`). `right` (a
    status chip) sits at the far right."""
    var items = List[View]()
    for k in range(len(tabs)):
        if k == renaming:
            items.append(TextField(tabs[k].name, placeholder="Tab name", on_submit=on_rename, on_cancel=on_cancel).focused().width(200).tag("tab-name"))
        elif k == selected:
            items.append(Button(tabs[k].name, on_tap + k, PLAIN, icon=tabs[k].icon).tooltip("Tap again to rename it").tag("tab-" + String(k)))
        else:
            items.append(Button(tabs[k].name, on_tap + k, SUBTLE, icon=tabs[k].icon).tag("tab-" + String(k)))
    items.append(Spacer())
    for v in right:
        items.append(v.copy())
    return HStack(items^, spacing=4).fill().align(CENTER).padding(0, 14).tag("sheet-tabs")


def FormulaBar(cell: String, text: String, on_submit: Int, on_cancel: Int = NO_MSG, placeholder: String = "Value or =formula",
               on_help: Int = NO_MSG) -> View:
    """ƒx, the selected cell's name, and its value or formula (Enter writes it, Escape puts it back). With `on_help`,
    ƒx is a button (a popover listing what formulas can do)."""
    var fx = Button("ƒx", on_help, SUBTLE).tooltip("What formulas can do") if on_help != NO_MSG else Text("ƒx").tone(4)
    return HStack(fx^, Text(cell, CAPTION).width(72),
                  TextField(text, placeholder=placeholder, on_submit=on_submit, on_cancel=on_cancel).grow(),
                  spacing=10).fill().align(CENTER).padding(4, 12).tag("formula-bar")


comptime STATUS_SLOTS = 8


def StatusBar(items: List[String], right: String = "") -> View:
    """Small facts about the selection and the engine, along the bottom of the window. Always the same number of
    slots (STATUS_SLOTS, empty ones blank), so a selection that brings fewer facts patches the texts instead of
    rebuilding the screen (which would restart the grid's canvas and its gliding ring)."""
    var views = List[View]()
    for k in range(max(STATUS_SLOTS, len(items))):
        views.append(Text(items[k] if k < len(items) else String(""), CAPTION))
    views.append(Spacer())
    views.append(Text(right, CAPTION))
    return HStack(views^, spacing=18).fill().align(CENTER).padding(4, 14).tag("status-bar")
