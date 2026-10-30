# Sketch (goal 40): a tiny drawing app, proof that omxcode draws. Pressure ink (mojoui.ink: each stroke one filled
# outline), pen, eraser, three inks, undo, clear, pan and zoom around the pointer. The app only composes: strokes are
# mojoui.ink.Stroke, the picture is a mojoui.scene Painter, and pan/zoom is the ink layer's transform (D-1202), so a
# pan redraws nothing: the host moves the kept layer.
#
# Drawing: drag with the pen (a pen's pressure, or speed with a mouse). Eraser: drag over strokes. Pan: the Pan tool,
# or press space then drag. Zoom: pinch, or the wheel (ctrl-scroll), around the pointer. Keys: p pen, e eraser,
# h pan, ctrl+z undo, Delete clears.
#
# For checks it prints `SKETCH: tool=… strokes=… points=… zoom=… pan=…` on every change, `SKETCH PRESSURE: p` for
# each pen point, and `SKETCH CANVAS: x,y,w,h` (the canvas in the window, pixels) once it knows.
#
#   scripts/build.sh sketch linux && build/sketch/linux/sketch

from mojoui import (
    App, Event, View, Surface, VStack, HStack, Text, Button, Canvas, Spacer, Divider,
    CAPTION, CENTER, PAN, ZOOM, TAP, PRESS, RELEASE, KEY, CTRL, PLAIN, PROMINENT, SUBTLE,
)
from mojoui.canvas import rgba
from mojoui.scene import Scene, SurfacePainter, Painter
from mojoui.ink import Stroke
from mojoui.geometry import rect_of
from mojoui.theme import Theme
from themes.liquid import liquid

comptime GESTURE = 1
comptime PEN = 2
comptime ERASER = 3
comptime HAND = 4
comptime UNDO = 5
comptime CLEAR = 6
comptime INK0 = 10  # + which ink

comptime ADD = 1  # history: a stroke was drawn
comptime ERASE = 2  # strokes were erased (they and where they were)
comptime WIPE = 3  # everything was cleared

comptime PAPER: UInt32 = 0xFFFCFAF8  # (rgba: a warm white)
comptime WIDTH = 4.0  # a stroke's full width, in points of the page


def inks() -> List[UInt32]:
    return [rgba(28, 30, 38), rgba(37, 99, 235), rgba(220, 38, 38)]


def ink_names() -> List[String]:
    return ["Ink", "Blue", "Red"]


def two(x: Float64) -> String:
    """x with two decimals."""
    var v = Int(abs(x) * 100 + 0.5)
    var f = String(v % 100)
    return ("-" if x < 0 and v > 0 else "") + String(v // 100) + "." + ("0" + f if f.byte_length() < 2 else f)


struct Action(Copyable, Movable):
    var kind: Int
    var strokes: List[Stroke]  # what an erase or a clear took away
    var at: List[Int]  # where each erased stroke was

    def __init__(out self, kind: Int):
        self.kind = kind
        self.strokes = List[Stroke]()
        self.at = List[Int]()


struct Main(App):
    var strokes: List[Stroke]
    var wet: Stroke  # the stroke being drawn (no points: none)
    var drawing: Bool
    var history: List[Action]
    var erasing: Action  # what the current eraser drag has taken
    var tool: Int
    var ink: Int
    var zoom: Float64
    var pan_x: Float64  # where the page's origin is on screen (points)
    var pan_y: Float64
    var space: Bool  # space was pressed: the next drag pans
    var panning: Bool
    var version: Int  # the canvas's picture
    var ink_version: Int  # the finished strokes' picture (the host keeps that layer while it's unchanged)
    var said: String  # the last SKETCH line
    var box: String  # the last SKETCH CANVAS line

    def __init__(out self):
        self.strokes = List[Stroke]()
        self.wet = Stroke(WIDTH, 0)
        self.drawing = False
        self.history = List[Action]()
        self.erasing = Action(ERASE)
        self.tool = PEN
        self.ink = 0
        self.zoom = 1
        self.pan_x = 0
        self.pan_y = 0
        self.space = False
        self.panning = False
        self.version = 0
        self.ink_version = 0
        self.said = ""
        self.box = ""

    def title(self) -> String:
        return "Sketch"

    def theme(self) -> Theme:
        return liquid()

    def window_size(self) -> Tuple[Int, Int]:
        return (960, 680)

    def points(self) -> Int:
        var n = 0
        for ref s in self.strokes:
            n += s.points()
        return n

    def tool_name(self) -> String:
        return "pen" if self.tool == PEN else ("eraser" if self.tool == ERASER else "pan")

    def report(mut self):
        var line = ("SKETCH: tool=" + self.tool_name() + " strokes=" + String(len(self.strokes)) + " points=" + String(self.points())
                    + " zoom=" + two(self.zoom) + " pan=" + String(Int(round(self.pan_x))) + "," + String(Int(round(self.pan_y))))
        if line != self.said:
            self.said = line
            print(line, flush=True)

    def page(self, x: Float64, y: Float64) -> Tuple[Float64, Float64]:
        """A point on screen (canvas points) on the page."""
        return ((x - self.pan_x) / self.zoom, (y - self.pan_y) / self.zoom)

    def changed_ink(mut self):
        self.ink_version += 1
        self.version += 1

    def finish(mut self):
        """The wet stroke joins the page."""
        if self.drawing and self.wet.points() > 0:
            self.wet.seal()
            self.strokes.append(self.wet.copy())
            self.history.append(Action(ADD))
            self.changed_ink()
        self.drawing = False
        self.wet = Stroke(WIDTH, 0)
        self.version += 1

    def erase_at(mut self, x: Float64, y: Float64):
        var p = self.page(x, y)
        var k = len(self.strokes) - 1
        var hit = False
        while k >= 0:
            if self.strokes[k].hits(p[0], p[1], 6.0 / self.zoom):
                self.erasing.strokes.append(self.strokes.pop(k))
                self.erasing.at.append(k)
                hit = True
            k -= 1
        if hit:
            self.changed_ink()

    def end_erase(mut self):
        if len(self.erasing.strokes) > 0:
            self.history.append(self.erasing.copy())
        self.erasing = Action(ERASE)

    def undo(mut self):
        if len(self.history) == 0:
            return
        var a = self.history.pop()
        if a.kind == ADD and len(self.strokes) > 0:
            _ = self.strokes.pop()
        elif a.kind == ERASE:
            for k in range(len(a.strokes) - 1, -1, -1):  # (back in the order they were taken out, highest index last)
                self.strokes.insert(min(a.at[k], len(self.strokes)), a.strokes[k].copy())
        elif a.kind == WIPE:
            self.strokes = a.strokes.copy()
        self.changed_ink()

    def clear(mut self):
        if len(self.strokes) == 0:
            return
        var a = Action(WIPE)
        a.strokes = self.strokes.copy()
        self.history.append(a^)
        self.strokes = List[Stroke]()
        self.changed_ink()

    def zoom_at(mut self, x: Float64, y: Float64, f: Float64):
        var z = min(max(self.zoom * f, 0.1), 16.0)
        self.pan_x = x - (x - self.pan_x) * (z / self.zoom)
        self.pan_y = y - (y - self.pan_y) * (z / self.zoom)
        self.zoom = z
        self.version += 1

    def gesture(mut self, e: Event):
        var kind = e.number
        if kind == KEY:
            var mods = Int(e.dx)
            if (e.text == "z" or e.text == "Z") and (mods & CTRL) != 0:
                self.undo()
            elif e.text == "p":
                self.tool = PEN
            elif e.text == "e":
                self.tool = ERASER
            elif e.text == "h":
                self.tool = HAND
            elif e.text == " ":
                self.space = True
            elif e.text == "Delete" or e.text == "Backspace":
                self.clear()
            return
        if kind == ZOOM:
            self.zoom_at(e.x, e.y, e.zoom)
            return
        if kind == PRESS:
            self.panning = self.tool == HAND or self.space
            self.space = False
            if self.panning:
                return
            if self.tool == PEN:
                var p = self.page(e.x, e.y)
                self.wet = Stroke(WIDTH, inks()[self.ink])
                self.wet.add(p[0], p[1], e.pressure)
                self.drawing = True
                print("SKETCH PRESSURE: " + String(e.pressure), flush=True)
                self.version += 1
            else:
                self.erase_at(e.x, e.y)
            return
        if kind == PAN:
            if self.panning:
                self.pan_x += e.dx
                self.pan_y += e.dy
                self.version += 1
            elif self.tool == PEN and self.drawing:
                var p = self.page(e.x, e.y)
                self.wet.add(p[0], p[1], e.pressure)
                print("SKETCH PRESSURE: " + String(e.pressure), flush=True)
                self.version += 1
            elif self.tool == ERASER:
                self.erase_at(e.x, e.y)
            return
        if kind == RELEASE or kind == TAP:  # (a tap with the pen leaves a dot)
            if not self.panning and self.tool == PEN:
                self.finish()
            elif self.tool == ERASER:
                self.end_erase()
            self.panning = False

    def update(mut self, event: Event):
        var m = event.message
        if m == GESTURE:
            self.gesture(event)
        elif m == PEN or m == ERASER or m == HAND:
            self.tool = m
        elif m == UNDO:
            self.undo()
        elif m == CLEAR:
            self.clear()
        elif INK0 <= m < INK0 + 3:
            self.ink = m - INK0
            self.tool = PEN
        self.report()

    def view(self) -> View:
        var bar = List[View]()
        bar.append(Button("Pen", PEN, PROMINENT if self.tool == PEN else SUBTLE))
        bar.append(Button("Eraser", ERASER, PROMINENT if self.tool == ERASER else SUBTLE))
        bar.append(Button("Pan", HAND, PROMINENT if self.tool == HAND else SUBTLE))
        bar.append(Divider().height(24))
        var names = ink_names()
        for k in range(3):
            bar.append(Button(names[k], INK0 + k, PROMINENT if self.ink == k else PLAIN))
        bar.append(Spacer())
        bar.append(Text(String(len(self.strokes)) + " strokes · " + String(Int(self.zoom * 100 + 0.5)) + "%", CAPTION))
        bar.append(Button("Undo", UNDO, PLAIN))
        bar.append(Button("Clear", CLEAR, PLAIN))
        return VStack(
            HStack(bar^, spacing=6).fill().align(CENTER).padding(6, 12).tag("toolbar"),
            Canvas(0, self.version, on_gesture=GESTURE, keys=True).grow().fill().tag("sketch"),
            spacing=0,
        ).grow().fill()

    def paint[P: Painter](mut self, mut p: P):
        """The page: paper, then the finished strokes (one layer, kept by the host while its version stands), then the
        wet stroke; both ink layers shown through the view's transform."""
        var k = p.scale()
        p.begin_layer("paper")
        p.fill(PAPER)
        p.begin_layer("ink")
        p.layer_version(self.ink_version)
        p.layer_transform(self.pan_x * k, self.pan_y * k, self.zoom * k)
        for ref s in self.strokes:
            s.draw(p)
        p.begin_layer("wet")
        p.layer_transform(self.pan_x * k, self.pan_y * k, self.zoom * k)
        if self.drawing and self.wet.points() > 0:
            p.polygon(self.wet.outline(), self.wet.color)

    def where(mut self, w: Int, h: Int, k: Float64):
        var r = rect_of("sketch")
        if len(r) == 4:
            var line = ("SKETCH CANVAS: " + String(Int(round(r[0] * k))) + "," + String(Int(round(r[1] * k))) + "," + String(w) + "," + String(h))
            if line != self.box:
                self.box = line
                print(line, flush=True)

    def draw_scene(mut self, canvas: Int, mut scene: Scene) -> Bool:
        self.paint(scene)
        self.where(scene.width(), scene.height(), scene.scale())
        return True

    def draw(mut self, canvas: Int, mut surface: Surface):
        var sp = SurfacePainter(Surface(surface.address, surface.width, surface.height, surface.scale))
        self.paint(sp)
        self.where(surface.width, surface.height, surface.scale)
