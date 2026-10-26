# mojoui.buttons: the buttons a page uses beyond Button's own styles (goal 33 M7, D-415): flat pills (tonal, filled,
# danger; an icon in a hue), the page's one loud button, small pills in four looks (with a dimmed and an armed state),
# quiet text actions, a name to tap in a list, an underlined link, a Back. Sizes and colours come from the theme's roles.
#
#   FlatButton("Restart", RESTART, "rotate-cw", hue=8)     PrimaryButton("Add a model", ADD, "plus")
#   SmallButton("Revoke", REVOKE + k, "trash-2", DANGER, armed=True)     TextAction("Edit labels", EDIT)

from mojoui.view import View, Button, HStack, PLAIN, PROMINENT, SUBTLE, ICON_ONLY, NO_MSG, CENTER, SPACE_S

# a SmallButton's look
comptime TONAL = 0
comptime FILL = 1
comptime TEXT = 2
comptime DANGER = 3
comptime LOOK_NAMES: List[String] = ["tonal", "fill", "text", "danger"]


def FlatButton(title: String, on_tap: Int, icon: String = "", filled: Bool = False, danger: Bool = False, hue: Int = 0, square: Bool = False,
               compact: Bool = False) -> View:
    """A flat pill: a tonal tint, no shadow (role flat); `filled` the accent (flat-fill), `danger` the bad colour
    (flat-danger); `hue` colours a plain one's icon (flat-<hue>); `square`: as wide as it is high, its icon only
    (flat-icon); `compact`: a phone's (taller, sharing its row: role …-compact)."""
    var suffix = String("-compact") if compact else String("")
    var role = (String("flat-fill") + suffix) if filled else ((String("flat-danger") + suffix) if danger else String("flat") + suffix + ("-" + String(min(hue, 8)) if hue > 0 else String("")))
    if square:
        return Button(title, on_tap, ICON_ONLY, icon).tag("flat-icon" + suffix)  # (ICON_ONLY: the title stays for screen readers)
    return Button(title, on_tap, PLAIN, icon).tag(role)


def PrimaryButton(title: String, on_tap: Int, icon: String = "", compact: Bool = False) -> View:
    """A page's one loud button: the accent filled (role primary); compact, its icon only (primary-icon)."""
    if compact:
        return Button(title, on_tap, ICON_ONLY, icon).tag("primary-icon")
    return Button(title, on_tap, PROMINENT, icon).tag("primary")


def SmallButton(title: String, on_tap: Int, icon: String = "", look: Int = TONAL, armed: Bool = False, off: Bool = False) -> View:
    """A small pill in a look: TONAL, FILL, TEXT or DANGER (roles small-<look>); a DANGER one waiting for its second
    tap is `armed` (small-danger-armed); `off`: dimmed, it sends nothing (small-<look>-off)."""
    var name = materialize[LOOK_NAMES]()[min(max(look, 0), 3)]
    var role = "small-" + name + ("-off" if off else ("-armed" if armed and look == DANGER else ""))
    return Button(title, NO_MSG if off else on_tap, PLAIN, icon).tag(role)


def TextAction(title: String, on_tap: Int) -> View:
    """A small action in a head (Edit labels): the accent, no chrome (role text-action)."""
    return Button(title, on_tap, SUBTLE).tag("text-action")


def NameLink(title: String, on_tap: Int) -> View:
    """A name to tap in a list (a model's): no button chrome (role name-link)."""
    return Button(title, on_tap, SUBTLE).tag("name-link")


def LinkButton(title: String, on_tap: Int) -> View:
    """An underlined link in a line of words (role link)."""
    return Button(title, on_tap, SUBTLE).tag("link")


def BackButton(on_tap: Int, title: String = "Back") -> View:
    """A quiet Back with its chevron in a page's header (role back-button)."""
    return Button(title, on_tap, SUBTLE, "back").tag("back-button")


def ButtonRow(var buttons: List[View]) -> View:
    """Buttons side by side under what they act on (role button-row)."""
    return HStack(buttons^, spacing=SPACE_S).align(CENTER).tag("button-row")
