# mojoui.activity: a strip that shows something is going on, drawn on a Canvas: a bar one eighth of the strip wide slides
# across a track, one step per frame. It moves only while the app asks for frames (on_frame), so a still strip is a sign
# nothing is being drawn: httpcheck counts the frames that keep coming while a request is out (goal 33 M1).
#
#   ActivityStrip(CANVAS, self.phase, on_frame=FRAME if busy else NO_MSG)   # the view: fills its width, STRIP_H high
#   Strip(self.phase, self.theme().palette).draw(surface)                # in App.draw() for its canvas

from mojoui.canvas import Surface
from mojoui.theme import Palette
from mojoui.view import View, Canvas, NO_MSG

comptime STRIP_H = 36  # points
comptime STEP = 6  # pixels the bar moves each frame


def ActivityStrip(canvas: Int, version: Int, on_frame: Int = NO_MSG) -> View:
    """A canvas STRIP_H points high that fills its width; with `on_frame` it asks for every display frame."""
    return Canvas(canvas, version, on_frame=on_frame).fill().height(STRIP_H)


struct Strip(Movable):
    var phase: Int  # frames so far: where the bar is
    var track: UInt32
    var bar: UInt32

    def __init__(out self, phase: Int, palette: Palette):
        self.phase = phase
        self.track = palette.raised
        self.bar = palette.accent

    def bar_x(self, width: Int) -> Int:
        """The bar's left edge in pixels (below 0 while it slides in)."""
        var w = max(width // 8, 1)
        return (self.phase * STEP) % (width + w) - w

    def draw(self, mut surface: Surface):
        surface.fill(self.track)
        var w = max(surface.width // 8, 1)
        var x0 = self.bar_x(surface.width)
        for y in range(surface.height):
            for x in range(max(x0, 0), min(x0 + w, surface.width)):
                surface.set(x, y, self.bar)
