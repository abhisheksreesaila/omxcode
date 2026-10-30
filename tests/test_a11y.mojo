# What a screen reader calls each view (mojoui.a11y): one rule for every host, and the audit that lists what it
# can't name. The hosts are checked by scripts/check_a11y.py (GTK's accessible label, the web's accessibility tree).
#   pixi run mojo run -I . tests/test_a11y.mojo
from std.testing import assert_equal, assert_true

from mojoui import View, Text, Button, TextField, Toggle, Dropdown, Slider, Segmented, Canvas, VStack, HStack, diff
from mojoui.view import ICON_ONLY
from mojoui.a11y import accessible_name, explicit_name, audit
from mojoui.menus import Menu, Item, Separator


def main() raises:
    # The order: label, tooltip, the control's own words, a field's placeholder.
    assert_equal(accessible_name(Button("Save", 1).nodes[0]), "Save")
    assert_equal(accessible_name(Button("Delete", 2, ICON_ONLY, icon="trash").nodes[0]), "Delete")
    assert_equal(accessible_name(Button("Delete", 2, ICON_ONLY, icon="trash").tooltip("Delete the row").nodes[0]), "Delete the row")
    assert_equal(accessible_name(Button("x", 2).label("Close").tooltip("Close the panel").nodes[0]), "Close")
    assert_equal(accessible_name(TextField("", placeholder="Your name").nodes[0]), "Your name")
    assert_equal(accessible_name(Toggle("Dark mode", False, 3).nodes[0]), "Dark mode")
    assert_equal(accessible_name(Segmented(["Day", "Week"], 0, 4).nodes[0]), "Day")
    assert_equal(accessible_name(Canvas(1, 0).nodes[0]), "")
    assert_equal(accessible_name(Canvas(1, 0).tooltip("Sum of amount by region").nodes[0]), "Sum of amount by region")

    # What a host must set itself (the platform can't read it off the widget).
    assert_equal(explicit_name(Button("Save", 1).nodes[0]), "")
    assert_equal(explicit_name(Button("Save", 1).label("Save the workbook").nodes[0]), "Save the workbook")
    assert_equal(explicit_name(Canvas(1, 0).tooltip("A bar chart").nodes[0]), "A bar chart")
    assert_equal(explicit_name(Dropdown(["East", "West"], 0, 5).label("Region").nodes[0]), "Region")

    # The audit names every control a screen reader couldn't.
    var screen = VStack(
        Text("Sales"),
        HStack(Button("", 1, ICON_ONLY, icon="trash"), Button("Save", 2)),
        Dropdown(["East", "West"], 0, 3),
        Slider(40, 4).tag("zoom"),
        Canvas(1, 0),
        TextField("", placeholder="Search"),
    )
    var found = audit(screen)
    for line in found:
        print("  " + line)
    assert_equal(len(found), 4)
    assert_true(found[0].startswith("BUTTON #"))
    assert_true(found[1].startswith("DROPDOWN #"))
    assert_equal(found[2].split(": ")[0].split(" ")[2], "(zoom)")
    assert_true(found[3].startswith("CANVAS #"))

    var fixed = VStack(
        Text("Sales"),
        HStack(Button("Delete", 1, ICON_ONLY, icon="trash"), Button("Save", 2)),
        Dropdown(["East", "West"], 0, 3).label("Region"),
        Slider(40, 4).tag("zoom").label("Zoom"),
        Canvas(1, 0).tooltip("Sum of amount by region, as bars"),
        TextField("", placeholder="Search"),
    )
    assert_equal(len(audit(fixed)), 0)

    # Menus: items are named by their titles; separators need nothing.
    var menu = Menu("File", [Item("Open", 10), Separator(), Item("Save", 11)])
    assert_equal(len(audit(menu)), 0)

    # A new label is a new layout (labels rarely change); a drawn view's changing words stay a patch (SET_TIP).
    var d = diff(Button("Save", 2), Button("Save", 2).label("Save the workbook"))
    assert_true(d.rebuild)
    var d2 = diff(Canvas(1, 0).tooltip("Sum by region"), Canvas(1, 0).tooltip("Average by region"))
    assert_true(not d2.rebuild)
    assert_equal(len(d2.patches), 1)

    # A canvas's label is a patch too (its picture stays); a labelled container names nothing (not a control).
    var d3 = diff(Canvas(1, 0).label("Sales"), Canvas(1, 0).label("Sales by region"))
    assert_true(not d3.rebuild)
    assert_equal(len(d3.patches), 1)
    assert_equal(explicit_name(VStack(Text("a")).label("Group").nodes[0]), "")

    print("a11y: OK")
