# Live tiles: mojoui.livetiles without a model (goal 77 M7b). Six sample tiles on one Canvas; the buttons change what matters
# most, so the tiles move like water: "Promote weather" makes rain the large tile, "Airport: flight XL" brings a big flight tile
# (the 3-tile layout: the others don't fit and are listed), "Reset" goes back to the morning and forgets your order and sizes.
# Press a tile (it squashes in), tap it, drag it onto another to reorder, or pull its corner grip to resize.
#
# LIVETILES_TRACE=/path: every draw appends the tiles as drawn (mojoui.livetiles.record: each tile's surface and its words'
# box, opacity, font size) with the wall clock and the frame clock, plus each button and result: the M7b proof reads it.
# LIVETILES_SHOT=/path.png@ms: the canvas's own pixels saved once, that far (frame clock) into the next scene change (a
# mid-motion picture: a host's test steps settle for up to a second after a tap, longer than the motion).

from mojoui import App, Event, View, VStack, HStack, Text, Button, Canvas, Spacer, HEADLINE, CAPTION, PROMINENT, PRESS, PAN, RELEASE, TAP
from mojoui.canvas import Surface
from mojoui.clock import now_ns
from mojoui.png import encode_png
from mojoui.livetiles import LiveTiles, Tile, Face, TileLook, TAPPED, ACTION, REORDERED, RESIZED
from mojoui.shared import environment
from mojoui.text import Font
from mojoui.theme import Theme, hx
from themes.omxqua import omxqua

comptime GESTURE = 1
comptime FRAME = 2
comptime PROMOTE = 3
comptime AIRPORT = 4
comptime RESET = 5

comptime MORNING = 0
comptime RAIN = 1
comptime FLIGHT = 2


def traffic(scene: Int) -> Tile:
    var t = Tile("traffic", hx("#15803D"), "Traffic", "Leave by 8:05", "Bridge is slow · +18 min to school", icon="car")
    if scene == MORNING:
        t.faces.append(Face("26 min to school", "via the river road · 2 incidents"))
        t.why = "you leave in 20 minutes"
        t.actions = ["Directions to the car", "Tell school"]
    else:
        t.faces = [Face("Pickup drive 22 min", "slower in rain")]
    return t^


def weather(scene: Int) -> Tile:
    if scene == RAIN:
        var t = Tile("weather", hx("#0369A1"), "Weather", "Rain from 4", "Pickup at 3:15 will be wet · take the umbrella", icon="cloud")
        t.faces.append(Face("Heavy at 5", "light again by 7"))
        t.why = "rain starts before pickup"
        t.actions = ["Remind me at 3", "Hourly"]
        return t^
    return Tile("weather", hx("#0369A1"), "Weather", "9° · clear", "rain after 4", icon="cloud")


def scene_tiles(scene: Int) -> List[Tile]:
    var todo = Tile("todo", hx("#F25500"), "To do", "3 to do", "Call mum · Pick up Maya · Water bill", icon="todo")
    todo.faces.append(Face("Next: call mum", "it's her birthday Saturday"))
    var cal = Tile("cal", hx("#E5484D"), "Calendar", "Pickup 3:15", "Maya · the side gate", icon="cal")
    cal.faces.append(Face("Then", "Dinner 6:30 · Tennis Sat 10"))
    var counter = Tile("counter", hx("#5C5C66"), "Counter", "Banana nearly ripe", "seen 7:12", icon="cam")
    counter.charm = "pin"
    var bday = Tile("bday", hx("#8B2FC9"), "Birthday", "Mum · Saturday", "turns 64", icon="gift")
    var out = List[Tile]()
    if scene == RAIN:
        out.append(weather(scene))
        out.append(traffic(scene))
        out.append(todo^)
        out.append(cal^)
        out.append(counter^)
        out.append(bday^)
    elif scene == FLIGHT:
        var flight = Tile("flight", hx("#4338CA"), "Flight", "Gate B12 · boarding 9:05", "TP1351 to Lisbon · on time · security is 12 min", icon="plane")
        flight.faces.append(Face("Seat 14A", "boarding pass ready · 1 bag to drop at desk 34"))
        flight.why = "you're 6 minutes from the airport"
        flight.actions = ["Boarding pass", "Directions to gate"]
        flight.big = True
        out.append(flight^)
        out.append(weather(scene))
        out.append(todo^)
        out.append(traffic(scene))
        out.append(cal^)
        out.append(counter^)
        out.append(bday^)
    else:
        out.append(traffic(scene))
        out.append(todo^)
        out.append(cal^)
        out.append(counter^)
        out.append(bday^)
        out.append(weather(scene))
    return out^


struct Main(App):
    var tiles: LiveTiles
    var font: Font
    var dark: Bool
    var scene: Int
    var status: String
    var trace: String
    var t0: Int
    var shot: String  # LIVETILES_SHOT's path, "" once taken
    var shot_ms: Int
    var mark_us: Int  # the frame clock at the last scene change (-1: none yet)

    def __init__(out self):
        self.tiles = LiveTiles()
        self.font = Font()
        self.dark = False
        self.scene = MORNING
        self.status = "Press, tap, drag a tile onto another, or pull its corner"
        self.trace = environment("LIVETILES_TRACE")
        self.t0 = now_ns()
        var want = environment("LIVETILES_SHOT")
        var at = want.find("@")
        self.shot = String(want[byte = 0 : at]) if at > 0 else ""
        self.shot_ms = 0
        if at > 0:
            try:
                self.shot_ms = Int(String(want[byte = at + 1 :]))
            except:
                self.shot = ""
        self.mark_us = -1
        self.tiles.set_tiles(scene_tiles(MORNING))
        self.tiles.spots("tiles", "tiles")
        self.log("START")

    def title(self) -> String:
        return "Live tiles"

    def window_size(self) -> Tuple[Int, Int]:
        return (1280, 820)

    def theme(self) -> Theme:
        return omxqua(self.dark)

    def appearance(mut self, dark: Bool):
        self.dark = dark
        self.tiles.version += 1
        self.log("SCHEME " + ("dark" if dark else "light"))

    def wall_ms(self) -> Int:
        return (now_ns() - self.t0) // 1_000_000

    def log(self, line: String):
        if self.trace == "":
            return
        try:
            with open(self.trace, "a") as f:
                f.write("EV " + String(self.wall_ms()) + " " + line + "\n")
        except:
            pass

    def go(mut self, scene: Int, what: String):
        self.scene = scene
        self.mark_us = self.tiles.clock_us
        self.tiles.set_tiles(scene_tiles(scene))
        var lay = self.tiles.layout()
        var hidden = String("")
        for i in range(len(lay.overflow)):
            hidden += (", " if i > 0 else "") + lay.overflow[i]
        self.status = what + ("" if hidden == "" else " · not on the grid: " + hidden)
        self.log(what.upper() + " overflow=" + hidden.replace(" ", ""))

    def update(mut self, event: Event):
        if event.message == FRAME:
            _ = self.tiles.frame(event.number)
        elif event.message == GESTURE:
            self.tiles.gesture(event.number, event.x, event.y)
            for r in self.tiles.take_results():
                var line: String
                if r.kind == TAPPED:
                    line = "tile " + r.id + " tapped"
                elif r.kind == ACTION:
                    line = "tile " + r.id + ": " + r.text
                elif r.kind == REORDERED:
                    line = "order: " + r.text
                else:
                    line = r.id + " resized to " + r.text
                self.status = line
                self.log("RESULT " + line)
        elif event.message == PROMOTE:
            self.go(RAIN, "Rain at pickup: weather promoted")
        elif event.message == AIRPORT:
            self.go(FLIGHT, "Near the airport: the flight is big")
        elif event.message == RESET:
            self.tiles.reset()
            self.go(MORNING, "Morning again")

    def view(self) -> View:
        return VStack(
            HStack(
                Text("Live tiles", HEADLINE),
                Spacer(),
                Button("Promote weather", on_tap=PROMOTE, style=PROMINENT),
                Button("Airport: flight XL", on_tap=AIRPORT),
                Button("Reset", on_tap=RESET),
                spacing=8,
            ).fill(),
            Text(self.status, CAPTION).tag("status"),
            Canvas(0, self.tiles.version, on_gesture=GESTURE, on_frame=FRAME).grow().fill().tag("tiles"),
            spacing=10,
        ).padding(16).fill()

    def draw(mut self, canvas: Int, mut surface: Surface):
        var look = TileLook.of(self.theme().palette)
        self.tiles.draw(surface, look, self.font)
        if self.shot != "" and self.mark_us >= 0 and self.tiles.clock_us - self.mark_us >= self.shot_ms * 1000:
            var px = List[UInt32](capacity=surface.width * surface.height)
            for i in range(surface.width * surface.height):
                px.append(surface.pixels().unsafe_offset(i)[])
            try:
                with open(self.shot, "w") as f:
                    f.write_bytes(Span(encode_png(px, surface.width, surface.height)))
                self.log("SHOT " + String((self.tiles.clock_us - self.mark_us) // 1000) + " " + self.shot)
            except:
                pass
            self.shot = ""
        if self.trace != "":
            try:
                with open(self.trace, "a") as f:
                    f.write("D " + String(self.wall_ms()) + " " + String(self.tiles.clock_us // 1000) + " " + String(Int(self.tiles.width))
                            + " " + String(Int(self.tiles.height)) + " " + String(surface.scale) + "\n" + self.tiles.record())
            except:
                pass
