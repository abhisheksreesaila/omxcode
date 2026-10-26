# mojoui.fields: fields beyond TextField's own (goal 33 M7, D-415): a wide search on a tonal box (a key hint at its
# end), an outlined field with a lead icon and its help line, a row of chips that pick one filter, a field sized for a
# short entry. Sizes and colours come from the theme's roles.
#
#   SearchField(q, "Search 3 models", SEARCH, key="/")      OutlinedField(q, "Search models", SEARCH, SEARCH_NOW)
#   FilterChips(["All", "Fits"], 0, FILTER)                 ShortField(name, "App name", NAME)

from mojoui.view import View, Text, Button, Icon, TextField, VStack, HStack, PLAIN, NO_MSG, CENTER, START, SPACE_XS, SPACE_S, SPACE_M


def SearchField(value: String, placeholder: String, on_change: Int, key: String = "") -> View:
    """A wide search: a magnifier and a borderless field on a tonal box (role search-box); `key`: the key that jumps to
    it, shown at its end (role key-hint)."""
    var items: List[View] = [Icon("search", 16), TextField(value, placeholder=placeholder, on_change=on_change).grow()]
    if key != "":
        items.append(Text(key).tag("key-hint"))
    return HStack(items^, spacing=SPACE_S).align(CENTER).tag("search-box")


def OutlinedField(value: String, label: String, on_change: Int, on_submit: Int = NO_MSG, icon: String = "search") -> View:
    """An outlined field: a lead icon and a borderless field in a box with a hairline ring; `label` shows until something
    is typed (role outlined-field)."""
    return HStack(Icon(icon, 16), TextField(value, placeholder=label, on_change=on_change, on_submit=on_submit).grow(),
                  spacing=SPACE_M).align(CENTER).fill().tag("outlined-field")


def FieldHelp(text: String) -> View:
    """The quiet line under a field (role field-help)."""
    return Text(text).tag("field-help")


def FieldWithHelp(var field: View, help: String) -> View:
    """A field with its help line under it (role field-with-help)."""
    return VStack(field^, FieldHelp(help), spacing=SPACE_S).align(START).fill().tag("field-with-help")


def FilterChips(titles: List[String], selected: Int, on_tap: Int) -> View:
    """Chips to pick one filter; chip k sends on_tap + k (roles filter-chips, filter-chip, filter-chip-on)."""
    var chips: List[View] = []
    for k in range(len(titles)):
        chips.append(Button(titles[k], on_tap + k, PLAIN).tag("filter-chip-on" if k == selected else "filter-chip"))
    return HStack(chips^, spacing=SPACE_S).align(CENTER).justify(START).tag("filter-chips")


def ShortField(value: String, placeholder: String, on_change: Int, on_submit: Int = NO_MSG, compact: Bool = False, filter: Bool = False) -> View:
    """A field for a short entry (a name), as wide as the theme says (roles short-field, short-field-compact); `filter`:
    an OutlinedField with a magnifier to filter a list or a log by (filter-field, filter-field-compact)."""
    if filter:
        return HStack(OutlinedField(value, placeholder, on_change, on_submit).grow(), spacing=0).tag("filter-field-compact" if compact else "filter-field")
    return HStack(TextField(value, placeholder=placeholder, on_change=on_change, on_submit=on_submit).grow(), spacing=0).tag(
        "short-field-compact" if compact else "short-field")
