# mojoui.feedback: words that tell the person something (goal 33 M7, D-415): a quiet note across the page, a warning
# that asks before something can't be undone, an empty state with the one action that fills it. Sizes and colours come
# from the theme's roles.
#
#   Note([QuietText("Runs take about a minute.")])     Warning([Strong("Stop the daemon?"), …])
#   EmptyState("key-round", "No keys yet", "Apps need one to call /v1.", "New key", NEW)

from mojoui.view import View, Text, Button, Icon, VStack, HStack, PLAIN, NO_MSG, CENTER, START, SPACE_S, SPACE_M


def Note(var items: List[View]) -> View:
    """A quiet note across the page: a tint, its words and maybe a button (role note)."""
    return HStack(items^, spacing=SPACE_S).align(CENTER).justify(START).fill().tag("note")


def NoteAction(title: String, on_tap: Int) -> View:
    """The one action a Note offers, at the end of its sentence, in the note's own smaller voice (role note-action)."""
    return Button(title, on_tap, PLAIN).tag("note-action")


def Warning(var items: List[View]) -> View:
    """A warning that asks first: the bad colour faintly behind its words (role warning)."""
    return VStack(items^, spacing=SPACE_M).align(START).fill().tag("warning")


def EmptyState(icon: String, title: String, text: String, action: String = "", on_action: Int = NO_MSG) -> View:
    """An empty state: an icon in a ring, a title, one line, and the one action that fills it (roles empty-state,
    empty-ring, empty-title, empty-action)."""
    var items: List[View] = [VStack(Icon(icon, 20), spacing=0).align(CENTER).justify(CENTER).tag("empty-ring"), Text(title).tag("empty-title"), Text(text)]
    if action != "":
        items.append(Button(action, on_action, PLAIN).tag("empty-action"))
    return VStack(items^, spacing=SPACE_S).align(CENTER).fill().tag("empty-state")
