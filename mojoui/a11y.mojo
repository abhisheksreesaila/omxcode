# mojoui.a11y: what a screen reader calls each view, one rule for every host, and an audit of the views it can't name.
#
#   Button("", 3, ICON_ONLY, icon="trash")            # → audit: "BUTTON #4: no name" (an icon says nothing to VoiceOver)
#   Button("Delete", 3, ICON_ONLY, icon="trash")      # the title is its name (and its tooltip)
#   Canvas(1, 0, on_gesture=PAN).label("Sales by region")   # a drawn view's name; a tooltip (.tooltip) also names it
#
# The name comes from, in order: .label() (never shown), .tooltip() (shown, and a name), then what the control shows
# itself (a button's title, a toggle's words, a menu item's title), then a field's placeholder (the last resort the
# ARIA name rules allow). Hosts hand the name to the platform's accessibility API (GTK: GtkAccessible's label; the
# web: aria-label; AppKit and UIKit: accessibilityLabel). Controls whose options carry words (Segmented, Radio, Tabs)
# are named by their options; drawn views, images, dropdowns, sliders and dates need a label or a tooltip.

from mojoui.view import (
    View, Node, BUTTON, ITEM, TOGGLE, FIELD, TEXTAREA, DROPDOWN, SLIDER, PROGRESS, DATE, CANVAS, IMAGE, EMBED, WEBCOMP,
    SEGMENTED, RADIO, TABS,
)


def kind_name(kind: Int) -> String:
    if kind == BUTTON:
        return "BUTTON"
    if kind == ITEM:
        return "ITEM"
    if kind == TOGGLE:
        return "TOGGLE"
    if kind == FIELD:
        return "FIELD"
    if kind == TEXTAREA:
        return "TEXTAREA"
    if kind == DROPDOWN:
        return "DROPDOWN"
    if kind == SLIDER:
        return "SLIDER"
    if kind == PROGRESS:
        return "PROGRESS"
    if kind == DATE:
        return "DATE"
    if kind == CANVAS:
        return "CANVAS"
    if kind == IMAGE:
        return "IMAGE"
    if kind == EMBED:
        return "EMBED"
    if kind == WEBCOMP:
        return "WEBCOMP"
    if kind == SEGMENTED:
        return "SEGMENTED"
    if kind == RADIO:
        return "RADIO"
    if kind == TABS:
        return "TABS"
    return "KIND " + String(kind)


def needs_name(n: Node) -> Bool:
    """Whether a screen reader must have a name for this view (a control, or a picture that carries meaning)."""
    if n.kind == ITEM:
        return n.style == 0  # (separators and section labels aren't controls)
    return (
        n.kind == BUTTON or n.kind == TOGGLE or n.kind == FIELD or n.kind == TEXTAREA or n.kind == DROPDOWN
        or n.kind == SLIDER or n.kind == PROGRESS or n.kind == DATE or n.kind == CANVAS or n.kind == IMAGE
        or n.kind == EMBED or n.kind == WEBCOMP or n.kind == SEGMENTED or n.kind == RADIO or n.kind == TABS
    )


def accessible_name(n: Node) -> String:
    """What a screen reader says this view is ("" when nothing names it)."""
    if n.label != "":
        return n.label
    if n.tip != "":
        return n.tip
    if n.kind == BUTTON or n.kind == TOGGLE or n.kind == ITEM:
        return n.text
    if n.kind == SEGMENTED or n.kind == RADIO or n.kind == TABS:
        for o in n.options:  # (each option is a named choice; the group needs no name of its own)
            if o != "":
                return o
        return ""
    if n.kind == FIELD or n.kind == TEXTAREA:
        return n.hint
    return ""


def explicit_name(n: Node) -> String:
    """The name a host must set itself: the platform can't find it in the widget's own words (a label, a drawn view's
    or a picture's tooltip). "" when the widget's own words already name it, or the view isn't one that takes a name."""
    if not needs_name(n):
        return ""
    if n.label != "":
        return n.label
    if (n.kind == CANVAS or n.kind == IMAGE or n.kind == EMBED or n.kind == WEBCOMP) and n.tip != "":
        return n.tip
    return ""


def audit(v: View) -> List[String]:
    """One line per view a screen reader can't name: "BUTTON #4 (tag): no name". Empty: every control is named."""
    var out = List[String]()
    for i in range(len(v.nodes)):
        ref n = v.nodes[i]
        if needs_name(n) and accessible_name(n) == "":
            out.append(kind_name(n.kind) + " #" + String(i) + (" (" + n.name + ")" if n.name != "" else "") + ": no name")
    return out^
