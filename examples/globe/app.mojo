# Globe: a 3D Earth drawn by one Mojo function per pixel on the GPU, with a day of air traffic on it.
#
# Native controls on the left (each platform's own), the globe on the right. At start-up the app rasterizes Natural
# Earth's coastlines into a texture and bins 5.5 million aircraft position reports into a 24-hour data cube (earth.mojo);
# both go to the GPU once. Every frame, `globe` runs once per pixel there: it finds the point of the Earth under the
# pixel, samples the texture and the cube, lights it by the sun and returns a colour. Drag to turn, scroll or pinch to
# zoom, tap to query a cell, press Play to watch the day go by.
#
# The same file runs as a Linux (GTK) app, a Mac (AppKit, Metal) app and on the web (the server's GPU draws, the
# browser shows). render.mojo draws it with no window at all, for batch jobs on a GPU node.

from mojoui.maths import log, floor, pi
from mojoui import (
    App, Event, View, Surface, VStack, HStack, Text, Button, Toggle, Slider, Divider, Canvas,
    TITLE, HEADLINE, CAPTION, NO_MSG, START, PAN, ZOOM, TAP,
)
from mojoui.gpu import Gpu
from mojoui.clock import now_ns
from mojoui.theme import Theme
from themes.omxqua import omxqua
from earth import (
    world, globe, pick_point, nearest_city, cell_count, Knobs8, DEG, WORDS,
    LAYER_FLIGHTS, LAYER_SUN, LAYER_GRID, LAYER_LIGHTS,
)

comptime GESTURE = 1
comptime FRAME = 2
comptime HOUR = 3
comptime PLAY = 4
comptime SPIN = 5
comptime RESET = 6
comptime LAYER = 10  # 10–13: LAYER + the layer's index in LAYERS (k < 4)

comptime HOURS_PER_SECOND = 1.0  # Play: a day in 24 seconds
comptime SPIN_PER_SECOND = 0.12  # Spin: radians a second
comptime DECLINATION = -16.5  # the sun's latitude: early November


def two(n: Int) -> String:
    return ("0" if n < 10 else "") + String(n)


def clock(hours: Float64) -> String:
    var minutes = Int(hours * 60.0 + 0.5) % (24 * 60)
    return two(minutes // 60) + ":" + two(minutes % 60)


def decimals(x: Float64, places: Int) -> String:
    var scale = 10 ** places
    var v = Int(abs(x) * Float64(scale) + 0.5)
    var frac = String(v % scale)
    while frac.byte_length() < places:
        frac = "0" + frac
    return ("-" if x < 0 and v != 0 else "") + String(v // scale) + "." + frac


def commas(n: Int) -> String:
    var s = String(n)
    var out = String("")
    var count = 0
    for i in range(s.byte_length() - 1, -1, -1):
        out = String(s[byte=i]) + out
        count += 1
        if count % 3 == 0 and i > 0:
            out = "," + out
    return out


def degrees(lon: Float64, lat: Float64) -> String:
    return decimals(abs(lat), 2) + "°" + ("N" if lat >= 0 else "S") + "  " + decimals(abs(lon), 2) + "°" + ("E" if lon >= 0 else "W")


struct Main(App):
    comptime GPU_CANVAS = True  # (the globe draws on the GPU: a desktop host may show it straight from there)
    var gpu: Gpu
    var reports: Int
    var busiest: UInt32
    var data_ms: Float64
    var lon: Float64  # the view's centre, radians
    var lat: Float64
    var zoom: Float64
    var hour: Float64  # UTC
    var layers: Int
    var playing: Bool
    var spinning: Bool
    var version: Int
    var canvas_w: Float64  # points, from the last draw
    var canvas_h: Float64
    var picked: Bool
    var pick_lon: Float64
    var pick_lat: Float64
    var pick_city: String
    var pick_km: Float64
    var pick_count: Int
    var frame_ms: Float64
    var fps: Float64

    def __init__(out self):
        var t0 = now_ns()
        var data = List[UInt32](length=WORDS, fill=0)
        var built = world(data)
        self.reports = built.reports
        self.busiest = built.busiest
        self.gpu = Gpu()
        self.gpu.set_data(data^)  # (it keeps the CPU's copy too: the queries read gpu.data_host)
        self.data_ms = Float64(now_ns() - t0) / 1e6
        self.lon = -30.0 / DEG
        self.lat = 25.0 / DEG
        self.zoom = 1
        self.hour = 14.5
        self.layers = LAYER_FLIGHTS | LAYER_SUN | LAYER_LIGHTS | LAYER_GRID
        self.playing = False
        self.spinning = False
        self.version = 0
        self.canvas_w = 0
        self.canvas_h = 0
        self.picked = False
        self.pick_lon = 0
        self.pick_lat = 0
        self.pick_city = ""
        self.pick_km = 0
        self.pick_count = 0
        self.frame_ms = 0
        self.fps = 0

    def title(self) -> String:
        return "Globe"

    def window_size(self) -> Tuple[Int, Int]:
        return (1360, 860)

    def theme(self) -> Theme:
        return omxqua(True)  # space is black: omxqua at night, whatever the desktop says

    def radius(self, w: Float64, h: Float64) -> Float64:
        """The globe's radius in the canvas's units: 42% of its short side at zoom 1."""
        return 0.42 * min(w, h) * self.zoom

    def knobs(self, w: Float64, h: Float64, scale: Float64) -> Knobs8:
        return Knobs8(
            Float32(self.lon), Float32(self.lat), Float32(self.radius(w, h)), Float32(self.hour), Float32(self.layers),
            Float32(1.0 / log(1.0 + Float64(self.busiest))), Float32(DECLINATION / DEG), Float32(scale),
        )

    def pick(mut self, x: Float64, y: Float64):
        var p = pick_point(x, y, self.canvas_w, self.canvas_h, self.knobs(self.canvas_w, self.canvas_h, 1))
        self.picked = p[2] > 0
        if not self.picked:
            return
        self.pick_lon = p[0]
        self.pick_lat = p[1]
        var near = nearest_city(p[0], p[1])
        self.pick_city = near[0]
        self.pick_km = near[1]
        self.pick_count = cell_count(self.gpu.data_host, p[0], p[1], self.hour)

    def update(mut self, event: Event):
        if event.message == GESTURE:
            var r = self.radius(self.canvas_w, self.canvas_h)
            if event.number == PAN and r > 0:
                self.lon -= event.dx / r
                self.lat = min(max(self.lat + event.dy / r, -1.45), 1.45)
            elif event.number == ZOOM:
                self.zoom = min(max(self.zoom * event.zoom, 0.6), 60.0)
            elif event.number == TAP:
                self.pick(event.x, event.y)
            if event.number == PAN or event.number == ZOOM or event.number == TAP:
                self.version += 1
        elif event.message == FRAME:
            var seconds = min(Float64(event.number) / 1e6, 0.1)
            if seconds > 0:
                self.fps = 1.0 / seconds if self.fps == 0 else 0.9 * self.fps + 0.1 / seconds
            if self.playing:
                self.hour = (self.hour + seconds * HOURS_PER_SECOND) % 24.0
            if self.spinning:
                self.lon += seconds * SPIN_PER_SECOND
                self.lon -= 2 * pi * floor((self.lon + pi) / (2 * pi))  # (one turn: float32 knobs lose precision past it)
            if self.picked:
                self.pick_count = cell_count(self.gpu.data_host, self.pick_lon, self.pick_lat, self.hour)
            self.version += 1
        elif event.message == HOUR:
            self.hour = Float64(min(event.number, 99)) * 24.0 / 100.0
            if self.picked:
                self.pick_count = cell_count(self.gpu.data_host, self.pick_lon, self.pick_lat, self.hour)
            self.version += 1
        elif event.message == PLAY:
            self.playing = event.number == 1
            self.fps = 0
        elif event.message == SPIN:
            self.spinning = event.number == 1
            self.fps = 0
        elif event.message == RESET:
            self.lon = -30.0 / DEG
            self.lat = 25.0 / DEG
            self.zoom = 1
            self.version += 1
        elif event.message >= LAYER and event.message < LAYER + 4:
            var bit = 1 << (event.message - LAYER)
            self.layers = (self.layers | bit) if event.number == 1 else (self.layers & ~bit)
            self.version += 1

    def draw(mut self, canvas: Int, mut surface: Surface):
        self.canvas_w = surface.points_width()
        self.canvas_h = surface.points_height()
        var k = self.knobs(Float64(surface.width), Float64(surface.height), surface.scale)
        self.gpu.draw_with[globe](surface, k)
        self.frame_ms = self.gpu.milliseconds

    def view(self) -> View:
        var names: List[String] = ["Flights", "Daylight", "Graticule", "City lights"]
        var bits: List[Int] = [LAYER_FLIGHTS, LAYER_SUN, LAYER_GRID, LAYER_LIGHTS]
        var rows = List[View]()
        for i in range(4):
            rows.append(Toggle(names[i], (self.layers & bits[i]) != 0, on_toggle=LAYER + log2_of(bits[i])))
        var toggles = VStack(rows^, spacing=8).align(START)
        # (always three lines, so a tap never changes the number of widgets: docs/lessons.md, fixed slots)
        # (each fills the sidebar's width: AppKit keeps a label's first size, and " " is 4 pt wide)
        var where = Text("Tap the globe to query a cell", style=HEADLINE).fill()
        var near = Text(" ").fill()
        var count = Text(" ", style=CAPTION).fill()
        if self.picked:
            var h = Int(self.hour)
            where = Text(degrees(self.pick_lon, self.pick_lat), style=HEADLINE).fill()
            near = Text("Near " + self.pick_city + " (" + commas(Int(self.pick_km + 0.5)) + " km)").fill()
            count = Text(commas(self.pick_count) + " aircraft reports within ~125 km, " + two(h) + ":00–" + two((h + 1) % 24) + ":00 UTC", style=CAPTION).fill()
        var picked = VStack(where^, near^, count^, spacing=6).align(START).fill()
        var moving = self.playing or self.spinning
        var sidebar = VStack(
            Text("Globe", style=TITLE),
            Text(commas(self.reports) + " aircraft position reports, binned into a 24 h × 0.25° cube. Coastlines: Natural Earth 1:50m.", style=CAPTION),
            Divider().fill(),
            Text("Layers", style=HEADLINE),
            toggles^,
            Text("Time: " + clock(self.hour) + " UTC", style=HEADLINE),
            Slider(Int(self.hour / 24.0 * 100.0), on_change=HOUR).fill(),
            HStack(
                Toggle("Play", self.playing, on_toggle=PLAY),
                Toggle("Spin", self.spinning, on_toggle=SPIN),
                Button("Reset view", on_tap=RESET),
                spacing=14,
            ),
            Divider().fill(),
            picked^,
            Divider().fill(),
            Text("Frame: " + decimals(self.frame_ms, 2) + " ms on " + self.gpu.name + (" · " + String(Int(self.fps + 0.5)) + " fps" if moving and self.fps > 0 else ""), style=CAPTION).fill(),
            Text("Data: built in " + decimals(self.data_ms / 1000.0, 1) + " s, " + String(WORDS * 4 // 1_000_000) + " MB on the GPU", style=CAPTION),
            Text("Drag to turn · scroll or pinch to zoom · tap to query", style=CAPTION),
            spacing=12,
        ).width(330).padding(20).align(START)
        return HStack(
            sidebar^,
            Canvas(0, self.version, on_gesture=GESTURE, on_frame=FRAME if moving else NO_MSG).grow().fill(),
            spacing=0,
        ).grow().fill()


def log2_of(bit: Int) -> Int:
    var n = 0
    while (1 << n) < bit:
        n += 1
    return n
