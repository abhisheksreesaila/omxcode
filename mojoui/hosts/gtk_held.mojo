# Input that came while a rebuild waits (goal 81, M4): kept in order and sent once the new widgets are up, so a click, a
# key or typed words are never lost, and never reach the wrong view. Each names its view by the widget's node id, which
# the rebuild carries over to the new screen (GtkHost.carry_held); a view that's gone takes its input with it.
from mojoui.view import View, PAN, ZOOM, WHEEL, HOVER  # (the gesture kinds that run together: many small moves are one longer one; mojoui.view's own numbers, never copies)

comptime HELD_MESSAGE = 0  # a message with a text from outside the widgets (a file dialog's answer, a dropped file)
comptime HELD_SEND = 1  # a control's message (GtkHost.send)
comptime HELD_OPTION = 2  # a control's choice (its text read from the screen when it's sent)
comptime HELD_FIELD = 3  # a text field's or text area's new text
comptime HELD_GESTURE = 4  # a canvas gesture
comptime HELD_KEY = 5  # a key on a canvas
comptime HELD_WORDS = 6  # an input method's words, or pasted ones, for a canvas
comptime HELD_CANCEL = 7  # Escape in a field
comptime HELD_CLICK = 8  # a button (its file dialog, or its message)
comptime HELD_BOARD = 9  # a board's object moved, resized
comptime HELD_LINK = 10  # a Paragraph's link
comptime HELD_SHORTCUT = 11  # a key shortcut of the window's


struct Held(Copyable, Movable):
    var what: Int
    var id: Int  # the widget's node id (-1: none)
    var node: Int  # (while carried over: its node)
    var second: Bool
    var kind: Int  # a gesture's or words' kind; a message's number
    var text: String
    var number: Int
    var x: Float64
    var y: Float64
    var dx: Float64
    var dy: Float64
    var zoom: Float64
    var pressure: Float64

    def __init__(out self, what: Int, id: Int, text: String = "", number: Int = 0, second: Bool = False, kind: Int = 0, x: Float64 = 0, y: Float64 = 0,
                 dx: Float64 = 0, dy: Float64 = 0, zoom: Float64 = 1, pressure: Float64 = 0):
        self.what = what
        self.id = id
        self.node = -1
        self.second = second
        self.kind = kind
        self.text = text
        self.number = number
        self.x = x
        self.y = y
        self.dx = dx
        self.dy = dy
        self.zoom = zoom
        self.pressure = pressure




def hold(mut queue: List[Held], var h: Held, slides: Bool = False):
    """Adds h at the end. A change that follows one of its own kind on the same view joins it: a field's newer text, a
    slider's newer value (slides), the pointer's newer place; moves add up."""
    if len(queue) > 0:
        ref last = queue[len(queue) - 1]
        if last.what == h.what and last.id == h.id and h.id >= 0:
            if h.what == HELD_FIELD:
                last.text = h.text
                return
            if h.what == HELD_SEND and slides and not last.second and not h.second:
                last.number = h.number
                return
            if h.what == HELD_GESTURE and last.kind == h.kind and (h.kind == PAN or h.kind == WHEEL or h.kind == ZOOM or h.kind == HOVER):
                last.x = h.x
                last.y = h.y
                last.dx += h.dx
                last.dy += h.dy
                last.zoom *= h.zoom
                last.pressure = h.pressure
                return
    queue.append(h^)


def same_view(old: View, new: View, o: Int) -> Int:
    """The new screen's node that is old node o, when its widget isn't kept: the only one of its kind with its tag, or,
    untagged, the only one with its words and messages (-1: gone, or not sure which)."""
    if o < 0 or o >= len(old.nodes):
        return -1
    ref n = old.nodes[o]
    var found = -1
    for side in range(2):
        var count = 0
        ref nodes = old.nodes if side == 0 else new.nodes
        for j in range(len(nodes)):
            ref m = nodes[j]
            if m.kind == n.kind and m.name == n.name and (n.name != "" or (m.text == n.text and m.msg == n.msg and m.msg2 == n.msg2 and m.hint == n.hint)):
                count += 1
                found = j
        if count != 1:
            return -1
    return found
