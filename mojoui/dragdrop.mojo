# mojoui.dragdrop: drag a view onto another (the console's My models: drag a model row onto a label in the groups column).
# Draggable(view, payload) can be picked up; DropTarget(view, on_drop) takes it and sends on_drop with event.text =
# the payload. The web uses the browser's own drag and drop (draggable, dragover, drop), GTK a GtkDragSource and a
# GtkDropTarget carrying text; the Mac shows the views (drag and drop there is not built yet).
# Files from outside (goal 42): DropTarget(view, on_drop, on_file=FILE) also takes files dropped from the file manager:
# GTK a second GtkDropTarget for GdkFileList, the web the browser's file drop (uploaded, then the path); not the Mac.
#
#   Draggable(row, payload="all-minilm-l6").tag("row-all-minilm-l6")     DropTarget(label_row, on_drop=DROP_ON + k)

from mojoui.view import View, Node, DRAG, DROP, _container


def Draggable(view: View, payload: String) -> View:
    """`view`, which can be dragged; a drop target it lands on gets `payload` as event.text."""
    var items: List[View] = [view.copy()]
    return _container(Node(DRAG, payload), items)


def DropTarget(view: View, on_drop: Int, on_file: Int = 0) -> View:
    """`view`, which takes drops: a Draggable let go over it sends `on_drop` with event.text = its payload. With
    `on_file`, files dropped on it from outside the app (the file manager, the desktop) send `on_file` once per file,
    with event.text = the file's path on the machine the app runs on (the web uploads it there first)."""
    var items: List[View] = [view.copy()]
    return _container(Node(DROP, msg=on_drop, msg2=on_file), items)
