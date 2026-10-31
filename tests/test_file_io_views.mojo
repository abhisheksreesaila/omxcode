# FileSaver and DropTarget(on_file) (goal 42 M3): what the views carry, and the events hosts make from them. The hosts'
# own dialogs and drops run in examples/jot's checker (GTK: `save:` and `dropfile:` steps; the web: scripts/drive.py).
#   pixi run mojo run -I . tests/test_file_io_views.mojo
from std.testing import assert_true, assert_equal, assert_false

from mojoui import VStack, Text, FilePicker, FileSaver, LazyList, BUTTON, DROP
from mojoui.view import is_file_saver
from mojoui.dragdrop import DropTarget
from mojoui.hosts.web import control_event


def main() raises:
    var v = VStack(
        FilePicker("Import", 5, accept=".md"),
        FileSaver("Export", 6, suggested="Trip plan.md", accept=".md"),
        DropTarget(LazyList(3, 1), on_drop=7, on_file=8).tag("notes"),
    )
    var picker = -1
    var saver = -1
    var drop = -1
    for i in range(len(v.nodes)):
        if v.nodes[i].kind == BUTTON and v.nodes[i].text == "Import":
            picker = i
        if v.nodes[i].kind == BUTTON and v.nodes[i].text == "Export":
            saver = i
        if v.nodes[i].kind == DROP:
            drop = i
    assert_false(is_file_saver(v.nodes[picker]))
    assert_true(is_file_saver(v.nodes[saver]))
    assert_equal(v.nodes[saver].options[2], "Trip plan.md")
    var e = control_event(v, saver, True, "/tmp/out.md", 0)  # (the host's answer: the path chosen, as on_save)
    assert_equal(e.message, 6)
    assert_equal(e.text, "/tmp/out.md")
    assert_equal(control_event(v, saver, False, "", 0).message, 0)  # (a plain tap sends nothing: the dialog answers)
    assert_equal(control_event(v, drop, False, "payload", 0).message, 7)  # a Draggable's payload: on_drop
    var f = control_event(v, drop, True, "/home/a/notes.txt", 0)  # a file from outside: on_file with its path
    assert_equal(f.message, 8)
    assert_equal(f.text, "/home/a/notes.txt")
    assert_equal(control_event(DropTarget(Text("x"), on_drop=7), 0, True, "/x", 0).message, 0)  # (no on_file: files are refused)
    print("file saver: ok")
    print("file drop: ok")
