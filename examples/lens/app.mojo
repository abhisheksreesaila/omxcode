# Data Lens: 20 million trips in a fictional city, drawn live as a density map.
#
# Native controls on the left (each platform's own), a canvas on the right that this
# file paints itself: every frame, all the trips that match the filters are counted
# into the canvas's pixels and coloured, on the GPU when there is one. Drag to pan,
# scroll or pinch to zoom, tap to centre, press Play to watch a day go by.
#
# The trips are made up (a seeded generator below); they are four float32 columns,
# x, y, hour and kind, so a real dataframe can hand its columns over instead.

from mojoui.maths import sqrt, log, cos, sin

from mojoui import (
    App, Event, View, Surface, VStack, HStack, Text, Button, Toggle, Slider, Segmented, Divider, Canvas,
    TITLE, HEADLINE, CAPTION, PROMINENT, NO_MSG, START, PAN, ZOOM, TAP,
)
from mojoui.gpu import PointCloud, Point, Knobs, OUTSIDE, FILTERED, gpu_present

comptime GESTURE = 1
comptime FRAME = 2
comptime HOUR = 3
comptime KIND = 4
comptime PLAY = 5
comptime RESET = 6

comptime BASE_UNITS_PER_POINT = Float64(1.0 / 720.0)  # the whole city is ~700 points wide at zoom 1
comptime HOUR_HALF_WIDTH = Float32(1.5)  # the hour filter shows ±1.5 h
comptime DAY_SECONDS = 12.0  # Play runs a day in 12 seconds


# ---------- the two functions that run once per trip and once per pixel (GPU or CPU) ----------

def place(p: Point, w: Int, h: Int, k: Knobs) -> Int:
    """Which pixel a trip lands on. p = (x, y, hour, kind);
    k = (centre x, centre y, units per pixel, hour or -1, hour half-width, kind or -1, …)."""
    if k[5] >= 0 and p[3] != k[5]:
        return FILTERED
    if k[3] >= 0:
        var d = abs(p[2] - k[3])
        d = min(d, 24 - d)  # hours wrap around midnight
        if d > k[4]:
            return FILTERED
    var px = (p[0] - k[0]) / k[2] + Float32(w) * 0.5
    var py = (p[1] - k[1]) / k[2] + Float32(h) * 0.5
    if px < 0 or py < 0 or px >= Float32(w) or py >= Float32(h):
        return OUTSIDE
    return Int(py) * w + Int(px)


def colour(count: UInt32, k: Knobs) -> UInt32:
    """A pixel's colour from how many trips landed on it: dark → magma → white-hot. k[6] = log of a busy count."""
    if count == 0:
        return UInt32(0xFF140A0A)  # near-black blue (R in the low byte)
    var t = min(log(Float32(1) + Float32(count)) / k[6], Float32(1))
    t = Float32(0.18) + Float32(0.82) * t  # even one trip is visible
    # Magma, as a polynomial fit (Matt Zucker's, from matplotlib's colour map)
    var r = -0.002136485 + t * (0.2516605 + t * (8.353717 + t * (-27.668733 + t * (52.17614 + t * (-50.768525 + t * 18.655705)))))
    var g = -0.000749655 + t * (0.6775232 + t * (-3.5777195 + t * (14.264731 + t * (-27.943606 + t * (29.046583 + t * -11.489774)))))
    var b = -0.005386128 + t * (2.4940266 + t * (0.3144679 + t * (-13.649213 + t * (12.944169 + t * (4.234153 + t * -5.6019615)))))
    var ri = UInt32(min(max(r, Float32(0)), Float32(1)) * 255)
    var gi = UInt32(min(max(g, Float32(0)), Float32(1)) * 255)
    var bi = UInt32(min(max(b, Float32(0)), Float32(1)) * 255)
    return ri | (gi << 8) | (bi << 16) | (UInt32(255) << 24)


# ---------- a fictional city's trips ----------

def mix(z0: UInt64) -> UInt64:
    """splitmix64: a well-spread 64-bit hash, so trip i is the same on every run and machine."""
    var z = z0 + 0x9E3779B97F4A7C15
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB
    return z ^ (z >> 31)


def uniform(i: Int, salt: Int) -> Float64:
    return Float64(Int(mix(UInt64(i) * 16 + UInt64(salt)) >> 11)) / 9007199254740992.0  # [0, 1)


def normal(i: Int, salt: Int) -> Float64:
    var u1 = max(uniform(i, salt), 1e-12)
    var u2 = uniform(i, salt + 1)
    return sqrt(-2.0 * log(u1)) * cos(6.283185307179586 * u2)


# Hubs: x, y, spread, share of hub trips, kind of place (0 business, 1 nightlife, 2 homes, 3 airport)
comptime Hub = SIMD[DType.float64, 8]
comptime HUBS: List[Hub] = [
    SIMD[DType.float64, 8](0.50, 0.45, 0.030, 0.20, 0, 0, 0, 0),  # downtown
    SIMD[DType.float64, 8](0.56, 0.40, 0.018, 0.08, 0, 0, 0, 0),  # financial district
    SIMD[DType.float64, 8](0.42, 0.52, 0.022, 0.10, 1, 0, 0, 0),  # old town (nightlife)
    SIMD[DType.float64, 8](0.62, 0.55, 0.020, 0.07, 1, 0, 0, 0),  # harbour bars
    SIMD[DType.float64, 8](0.30, 0.35, 0.060, 0.12, 2, 0, 0, 0),  # west homes
    SIMD[DType.float64, 8](0.70, 0.30, 0.055, 0.10, 2, 0, 0, 0),  # north-east homes
    SIMD[DType.float64, 8](0.35, 0.75, 0.050, 0.09, 2, 0, 0, 0),  # south homes
    SIMD[DType.float64, 8](0.72, 0.74, 0.045, 0.08, 2, 0, 0, 0),  # south-east homes
    SIMD[DType.float64, 8](0.86, 0.18, 0.012, 0.06, 3, 0, 0, 0),  # airport
    SIMD[DType.float64, 8](0.20, 0.60, 0.015, 0.05, 0, 0, 0, 0),  # university
    SIMD[DType.float64, 8](0.55, 0.62, 0.012, 0.05, 1, 0, 0, 0),  # stadium
]


def river_y(x: Float64) -> Float64:
    return 0.62 + 0.045 * sin(9.0 * x) + 0.02 * sin(23.0 * x)


def hour_for(place_kind: Int, i: Int) -> Float64:
    """When a trip from this kind of place happens: rush hours, late nights, all day."""
    var pick = uniform(i, 9)
    var h: Float64
    if place_kind == 0:  # business: morning and evening rush
        h = (8.5 if pick < 0.5 else 17.75) + 1.1 * normal(i, 10)
    elif place_kind == 1:  # nightlife: late evening
        h = 22.5 + 2.0 * normal(i, 10)
    elif place_kind == 2:  # homes: leave early, back in the evening
        h = (7.5 if pick < 0.45 else 18.75) + 1.4 * normal(i, 10)
    else:  # airport: all day, quieter at night
        h = 5.0 + 19.0 * uniform(i, 10)
    h = h - 24.0 * Float64(Int((h + 48.0) / 24.0) - 2)  # wrap into [0, 24)
    return min(max(h, 0.0), 23.999)


def hubs() -> List[Hub]:
    return materialize[HUBS]()


def trip(i: Int, hubs: List[Hub]) -> SIMD[DType.float32, 4]:
    """Trip i of the city: (x, y, hour, kind). `hubs`: from hubs()."""
    var x: Float64
    var y: Float64
    var place_kind: Int
    var r = uniform(i, 0)
    if r < 0.58:  # around a hub
        var pick = uniform(i, 1)
        var acc = 0.0
        var hub = hubs[0]
        for k in range(len(hubs)):
            acc += hubs[k][3]
            hub = hubs[k]
            if pick < acc:
                break
        x = hub[0] + hub[2] * normal(i, 2)
        y = hub[1] + hub[2] * normal(i, 4)
        place_kind = Int(hub[4])
    elif r < 0.92:  # along a street: a tilted grid, a ring road and two avenues
        var road = Int(uniform(i, 1) * 22)
        var t = uniform(i, 2)
        var off = 0.0016 * normal(i, 4)
        var tilt = 0.26
        if road < 9:  # avenues
            var u = 0.14 + 0.09 * Float64(road) + off
            var v = 0.06 + 0.88 * t
            x = 0.5 + (u - 0.5) * cos(tilt) - (v - 0.5) * sin(tilt)
            y = 0.5 + (u - 0.5) * sin(tilt) + (v - 0.5) * cos(tilt)
        elif road < 18:  # streets
            var v = 0.14 + 0.09 * Float64(road - 9) + off
            var u = 0.06 + 0.88 * t
            x = 0.5 + (u - 0.5) * cos(tilt) - (v - 0.5) * sin(tilt)
            y = 0.5 + (u - 0.5) * sin(tilt) + (v - 0.5) * cos(tilt)
        elif road < 20:  # ring road
            var a = 6.283185307179586 * t
            x = 0.5 + (0.37 + off) * cos(a)
            y = 0.5 + (0.37 + off) * sin(a)
        else:  # two long avenues from the airport
            var ex = 0.10 if road == 20 else 0.18
            var ey = 0.80 if road == 20 else 0.88
            x = 0.86 + (ex - 0.86) * t + off
            y = 0.18 + (ey - 0.18) * t + off
        place_kind = 0 if uniform(i, 6) < 0.5 else 2
    else:  # anywhere in town
        var a = 6.283185307179586 * uniform(i, 1)
        var d = 0.46 * sqrt(uniform(i, 2))
        x = 0.5 + d * cos(a)
        y = 0.5 + d * sin(a)
        place_kind = 2
    var near_river = abs(y - river_y(x)) < 0.03
    if abs(y - river_y(x)) < 0.009:  # nobody gets picked up in the river: step onto the bank
        y = river_y(x) + (0.011 if y > river_y(x) else -0.011)
    var hour = hour_for(place_kind, i)
    # Kind: 0 taxi, 1 rideshare, 2 bike. Bikes by the river by day; rideshares at night.
    var night = hour >= 21.0 or hour < 4.0
    var taxi = 0.45
    var ride = 0.40
    if near_river and not night:
        taxi = 0.22
        ride = 0.26
    elif place_kind == 1 or night:
        taxi = 0.34
        ride = 0.60
    var k = uniform(i, 7)
    var kind = 0 if k < taxi else (1 if k < taxi + ride else 2)
    return SIMD[DType.float32, 4](Float32(x), Float32(y), Float32(hour), Float32(kind))


def city(n: Int) -> PointCloud:
    var x = List[Float32](length=n, fill=0)
    var y = List[Float32](length=n, fill=0)
    var hour = List[Float32](length=n, fill=0)
    var kind = List[Float32](length=n, fill=0)
    var places = hubs()
    for i in range(n):
        var t = trip(i, places)
        x[i] = t[0]
        y[i] = t[1]
        hour[i] = t[2]
        kind[i] = t[3]
    return PointCloud(x, y, hour, kind)


# ---------- formatting ----------

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


def decimals(x: Float64, places: Int) -> String:
    var scale = 10 ** places
    var neg = x < 0
    var v = Int(abs(x) * Float64(scale) + 0.5)
    var frac = String(v % scale)
    while frac.byte_length() < places:
        frac = "0" + frac
    return ("-" if neg and v != 0 else "") + String(v // scale) + "." + frac


def clock(hours: Float64) -> String:
    var minutes = Int(hours * 60.0 + 0.5) % (24 * 60)
    var h = minutes // 60
    var m = minutes % 60
    return ("0" if h < 10 else "") + String(h) + ":" + ("0" if m < 10 else "") + String(m)


# ---------- the app ----------

struct Main(App):
    comptime GPU_CANVAS = True  # (its PointCloud draws on the GPU: a desktop host may show it straight from there, D-5310)
    var cloud: PointCloud
    var kind: Int  # 0 = all, 1–3 = taxi, rideshare, bike
    var hour: Float64  # centre of the hour filter; < 0 = all day
    var playing: Bool
    var centre_x: Float64
    var centre_y: Float64
    var zoom: Float64
    var version: Int
    var matching: Int
    var in_view: Int
    var canvas_w: Float64  # the canvas's size in points, from the last draw
    var canvas_h: Float64
    var frame_ms: Float64
    var fps: Float64

    def __init__(out self):
        self.cloud = city(20_000_000 if gpu_present() else 2_000_000)
        self.kind = 0
        self.hour = -1
        self.playing = False
        self.centre_x = 0.5
        self.centre_y = 0.5
        self.zoom = 1
        self.version = 0
        self.matching = 0
        self.in_view = 0
        self.canvas_w = 0
        self.canvas_h = 0
        self.frame_ms = 0
        self.fps = 0
        self.count()

    def title(self) -> String:
        return "Data Lens"

    def window_size(self) -> Tuple[Int, Int]:
        return (1280, 800)

    def units_per_point(self) -> Float64:
        return BASE_UNITS_PER_POINT / self.zoom

    def knobs(self, units_per_pixel: Float64) -> Knobs:
        return Knobs(
            Float32(self.centre_x), Float32(self.centre_y), Float32(units_per_pixel),
            Float32(self.hour) if self.hour >= 0 else Float32(-1), HOUR_HALF_WIDTH,
            Float32(self.kind - 1), Float32(1), Float32(0),
        )

    def count(mut self):
        """How many trips match the filters (a 1×1 picture: every match is counted, wherever it is)."""
        self.matching = self.cloud.bin[place](1, 1, self.knobs(1e9))

    def update(mut self, event: Event):
        if event.message == GESTURE:
            var upp = self.units_per_point()
            # The pointer's offset from the canvas centre (a point or less counts as the centre)
            var ox = event.x - self.canvas_w / 2 if self.canvas_w > 0 else 0.0
            var oy = event.y - self.canvas_h / 2 if self.canvas_h > 0 else 0.0
            if abs(ox) < 1 and abs(oy) < 1:
                ox = 0
                oy = 0
            if event.number == PAN:
                self.centre_x -= event.dx * upp
                self.centre_y -= event.dy * upp
            elif event.number == ZOOM:
                self.zoom = min(max(self.zoom * event.zoom, 0.5), 4000.0)
                var upp2 = self.units_per_point()
                self.centre_x += ox * (upp - upp2)  # keep the spot under the pointer in place
                self.centre_y += oy * (upp - upp2)
            elif event.number == TAP:
                self.centre_x += ox * upp
                self.centre_y += oy * upp
            if event.number == PAN or event.number == ZOOM or event.number == TAP:  # (PRESS/RELEASE change nothing: no redraw)
                self.version += 1
        elif event.message == FRAME:
            var seconds = Float64(event.number) / 1e6
            if seconds > 0:
                self.fps = 1.0 / seconds if self.fps == 0 else 0.9 * self.fps + 0.1 / seconds
            if self.playing:
                self.hour = (max(self.hour, 0.0) + min(seconds, 0.1) * 24.0 / DAY_SECONDS) % 24.0
                self.version += 1
        elif event.message == HOUR:
            self.hour = -1.0 if event.number == 0 else Float64(event.number) * 24.0 / 100.0
            self.count()
            self.version += 1
        elif event.message == KIND:
            self.kind = event.number
            self.count()
            self.version += 1
        elif event.message == PLAY:
            self.playing = event.number == 1
            self.fps = 0
        elif event.message == RESET:
            self.centre_x = 0.5
            self.centre_y = 0.5
            self.zoom = 1
            self.version += 1

    def draw(mut self, canvas: Int, mut surface: Surface):
        self.canvas_w = surface.points_width()
        self.canvas_h = surface.points_height()
        var k = self.knobs(self.units_per_point() / surface.scale)
        self.matching = self.cloud.bin[place](surface.width, surface.height, k)
        self.in_view = self.cloud.shown
        # Brightness: what a busy pixel holds, from the average over the picture
        var average = Float64(self.cloud.shown) / Float64(max(surface.width * surface.height, 1))
        k[6] = Float32(log(1.0 + max(average * 40.0, 6.0)))
        self.cloud.shade[colour](surface, k)
        self.frame_ms = self.cloud.milliseconds

    def hour_text(self) -> String:
        if self.hour < 0:
            return "Hour: all day"
        return "Hour: " + clock(self.hour) + " ± 1h30"

    def view(self) -> View:
        var kinds: List[String] = ["All", "Taxi", "Rideshare", "Bike"]
        var slider = 0 if self.hour < 0 else max(Int(self.hour / 24.0 * 100.0 + 0.5), 1)
        var device = self.cloud.device_name()
        var sidebar = VStack(
            Text("Data Lens", style=TITLE),
            Text(commas(self.cloud.count) + " trips in a made-up city, drawn live", style=CAPTION),
            Divider().fill(),
            Text("Kind", style=HEADLINE),
            Segmented(kinds, self.kind, on_select=KIND),
            Text(self.hour_text(), style=HEADLINE),
            Slider(slider, on_change=HOUR).fill(),
            HStack(
                Toggle("Play", self.playing, on_toggle=PLAY),
                Button("Reset view", on_tap=RESET),
                spacing=16,
            ),
            Divider().fill(),
            Text("Matching: " + commas(self.matching) + " of " + commas(self.cloud.count) + " trips"),
            Text("In view: " + commas(self.in_view)),
            Text("View: centre (" + decimals(self.centre_x, 4) + ", " + decimals(self.centre_y, 4) + "), zoom " + decimals(self.zoom, 2) + "×"),
            Text("Frame: " + decimals(self.frame_ms, 2) + " ms on " + device + (" · " + String(Int(self.fps + 0.5)) + " fps" if self.playing and self.fps > 0 else ""), style=CAPTION),
            Text("Drag to pan · scroll or pinch to zoom · tap to centre", style=CAPTION),
            spacing=12,
        ).width(340).padding(20).align(START)
        return HStack(
            sidebar,
            Canvas(0, self.version, on_gesture=GESTURE, on_frame=FRAME if self.playing else NO_MSG).grow().fill(),
            spacing=0,
        ).grow().fill()
