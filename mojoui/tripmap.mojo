# mojoui.tripmap: a trip as a map card (goal 77 M3). Real map tiles from the web (mojoui.tiles: OpenStreetMap's, cached on disk),
# the stops numbered in the order visited and joined by a route line, fitted to the card; each stop is a pointable part (mojoui.pointer),
# so when the voice names one the map flies there (van Wijk and Nuij's smooth zoom and pan, eased) and the pointer's ring lands on
# its marker. The stops' places are the model's guesses checked by a geocoder (mojoui.geocode: the geocoder's place when it is
# within 60 km of the guess, else the guess), and a marker glides to its checked place when the answer lands.
#
#   var map = TripMap("card3", "card3.map0", "Lisbon", stops)        # stops: List[Stop] (name, note, the model's lat/lon)
#   draw():  map.draw(surface, font, palette)                        # tiles, route, markers, labels, attribution; asks again while it moves
#   map.parts("card3") -> List[Part]                                # stop1…stopN, named by their names (names_for)
#   map.point("card3.stop2") -> Bool                                  # fly to stop 2 (a `point` event's tag)
#   map.take_log() -> List[String]                                    # what it did, for a checker ("MAP: card=card3 stop=1 …")
#
# The agent's side: mojoui.maptool.show_map_tool() (the `show_map` tool: a title, an area, the stops with a note and a guess each; its result tells
# the model to walk through the stops in order, naming each as labelled) and trip_ui(args), the card as render_ui's JSON (a Card
# holding a TripMap, mojoui.genui's component 8). Tiles and geocoding are the only web calls, and the card says "web".

from std.math import log, log2, exp, sqrt, sin, cos, tan, atan, pi, floor, cosh, sinh, tanh
from mojoui.canvas import Surface
from mojoui.clock import now_ns
from mojoui.draw import over, line, circle, rect, with_alpha
from mojoui.geocode import Geocoder, GeoAnswer, GEO_PENDING, GEO_FOUND, GEO_NONE, settle, km
from mojoui.geometry import put_spot
from mojoui.json import Json, json_string, J_ARRAY, J_OBJECT, J_NUMBER
from mojoui.pointer import Part, names_for
from mojoui.text import Font, MEDIUM, REGULAR, LEFT, CENTRE, RIGHT
from mojoui.theme import Palette
from mojoui.tiles import TileStore, TILE, ATTRIBUTION

comptime SHOW_MAP = "show_map"
comptime MAX_STOPS = 8
comptime MAX_ZOOM = 16.0
comptime MIN_ZOOM = 2.0
comptime PAD = 46.0  # points kept clear round the stops when the map is fitted (a marker and its label fit)
comptime MARKER = 12.0  # a marker's radius, points
comptime RHO = 1.42  # van Wijk's rho: how much a long flight zooms out on the way (d3 and Mapbox use about this)
comptime BACK_MS = 6500  # after the last point, the map flies back to show every stop
comptime GLIDE_MS = 700  # a marker moving to its checked place

comptime MAP_ABOUT = (
    "Show a trip, a route, a day out or a set of places as a map card with real map tiles: the stops numbered in the order visited, "
    "joined by a line. Give each stop its name exactly as it should be labelled and said (\"Belém Tower\", \"the Alfama\"), a one-line "
    "note, and your best guess of its latitude and longitude (a geocoder checks them). Call it first, then walk through the stops in "
    "order in one or two sentences, naming each exactly as labelled: the map flies to each stop as you name it."
)
comptime MAP_PARAMS = (
    '{"type":"object","properties":{"title":{"type":"string","description":"a few words, e.g. A day in Lisbon"},'
    '"area":{"type":"string","description":"the city or region the stops are in, e.g. Lisbon, Portugal"},'
    '"stops":{"type":"array","minItems":1,"maxItems":8,"description":"the places, in the order visited","items":{"type":"object","properties":{'
    '"name":{"type":"string","description":"the place as it is labelled and said"},"note":{"type":"string","description":"one short line"},'
    '"lat":{"type":"number","description":"your best guess of its latitude"},"lon":{"type":"number","description":"your best guess of its longitude"}},'
    '"required":["name","lat","lon"]}}},"required":["stops"]}'
)


# ---------------------------------------------------------------------------------------------------------------------
# the stops and the agent's tool
# ---------------------------------------------------------------------------------------------------------------------

struct Stop(Copyable, Movable):
    var name: String
    var note: String
    var guess_lat: Float64  # the model's
    var guess_lon: Float64
    var lat: Float64  # where it is drawn
    var lon: Float64
    var how: String  # "guessed" until the geocoder answers; then "checked" or "guessed"
    var settled: Bool
    var bare: Bool  # asking for the name alone ("name, area" found nothing)
    var from_lat: Float64  # a glide from here to (lat, lon)
    var from_lon: Float64
    var moved_ns: Int

    def __init__(out self, name: String, note: String, lat: Float64, lon: Float64):
        self.name = name
        self.note = note
        self.guess_lat = lat
        self.guess_lon = lon
        self.lat = lat
        self.lon = lon
        self.how = "guessed"
        self.settled = False
        self.bare = False
        self.from_lat = lat
        self.from_lon = lon
        self.moved_ns = 0


def _clip(s: String, n: Int) -> String:
    var t = String(s.strip())
    if t.byte_length() <= n:
        return t
    var out = String("")
    for c in t.codepoints():
        var ch = String(c)
        if out.byte_length() + ch.byte_length() > n:
            break
        out += ch
    return out^


def read_stops(args: String) raises -> Tuple[String, String, List[Stop]]:
    """(title, area, stops) from show_map's arguments; raises with what is wrong (the model hears it and calls again)."""
    var j = Json.parse(args)
    if j.kind(0) != J_OBJECT:
        raise Error("the arguments must be an object")
    var a = j.get(0, "stops")
    if a < 0 or j.kind(a) != J_ARRAY or j.size(a) == 0:
        raise Error("give at least one stop: {name, note, lat, lon}")
    var stops = List[Stop]()
    for i in range(min(j.size(a), MAX_STOPS)):
        var s = j.at(a, i)
        if j.kind(s) != J_OBJECT:
            raise Error("stop " + String(i + 1) + " must be an object {name, note, lat, lon}")
        var name = _clip(j.text(j.get(s, "name")), 60)
        if name == "":
            raise Error("stop " + String(i + 1) + " has no name")
        var la = j.get(s, "lat")
        var lo = j.get(s, "lon")
        if la < 0 or lo < 0 or j.kind(la) != J_NUMBER or j.kind(lo) != J_NUMBER:
            raise Error("stop " + String(i + 1) + " (" + name + ") needs lat and lon as numbers: your best guess")
        var lat = j.real(la)
        var lon = j.real(lo)
        if lat < -85 or lat > 85 or lon < -180 or lon > 180:
            raise Error("stop " + String(i + 1) + " (" + name + ") is off the map: lat -85…85, lon -180…180")
        stops.append(Stop(name, _clip(j.text(j.get(s, "note")), 160), lat, lon))
    return (_clip(j.text(j.get(0, "title")), 80), _clip(j.text(j.get(0, "area")), 80), stops^)


def trip_ui(args: String) -> String:
    """show_map's arguments as render_ui's JSON: a Card titled with the trip holding a TripMap ("" when they can't be read)."""
    try:
        var t = read_stops(args)
        var title = t[0] if t[0] != "" else (t[1] if t[1] != "" else String("Your trip"))
        var out = '{"ui":{"component":"Card","title":' + json_string(title) + ',"children":[{"component":"TripMap","area":' + json_string(t[1]) + ',"stops":['
        for i in range(len(t[2])):
            ref s = t[2][i]
            out += ("," if i > 0 else "") + '{"name":' + json_string(s.name) + ',"note":' + json_string(s.note) + ',"lat":' + String(s.guess_lat) + ',"lon":' + String(s.guess_lon) + "}"
        return out + "]}]}}"
    except:
        return ""


def show_map_answer(args: String) -> String:
    """The tool's result: shown, and what to say next (walk through the stops in order, naming each as labelled)."""
    try:
        var t = read_stops(args)
        var names = String("")
        var numbered = String("")
        for i in range(len(t[2])):
            names += (", " if i > 0 else "") + t[2][i].name
            numbered += ("," if i > 0 else "") + json_string(String(i + 1) + ". " + t[2][i].name)
        return ('{"shown":"a map card with ' + String(len(t[2])) + ' numbered stops","stops":[' + numbered + '],"next":' + json_string(
            "Now say one or two short sentences that walk through the stops in order, naming each exactly as it is labelled (" + names
            + "); the map flies to each one as you name it. Don't read the notes or coordinates out.") + "}")
    except e:
        return '{"error":' + json_string("not shown: " + String(e)) + "}"


# ---------------------------------------------------------------------------------------------------------------------
# Web Mercator: world units are pixels of the whole world at zoom 0 (256 a side)
# ---------------------------------------------------------------------------------------------------------------------

def world_x(lon: Float64) -> Float64:
    return (lon + 180.0) / 360.0 * 256.0


def world_y(lat: Float64) -> Float64:
    var s = min(max(sin(lat * pi / 180.0), -0.9999), 0.9999)
    return (0.5 - log((1.0 + s) / (1.0 - s)) / (4.0 * pi)) * 256.0


def lon_of(wx: Float64) -> Float64:
    return wx / 256.0 * 360.0 - 180.0


def lat_of(wy: Float64) -> Float64:
    var n = pi - 2.0 * pi * wy / 256.0
    return 180.0 / pi * atan(0.5 * (exp(n) - exp(-n)))


@fieldwise_init
struct View3(Copyable, Movable, ImplicitlyCopyable):
    """What the camera shows: its centre in world units and its zoom."""
    var cx: Float64
    var cy: Float64
    var zoom: Float64


def fit(xs: List[Float64], ys: List[Float64], w: Float64, h: Float64) -> View3:
    """The view that shows every point (world units) inside w x h points with PAD clear round them."""
    if len(xs) == 0:
        return View3(128.0, 128.0, MIN_ZOOM)
    var x0 = xs[0]
    var x1 = xs[0]
    var y0 = ys[0]
    var y1 = ys[0]
    for i in range(len(xs)):
        x0 = min(x0, xs[i])
        x1 = max(x1, xs[i])
        y0 = min(y0, ys[i])
        y1 = max(y1, ys[i])
    var dx = max(x1 - x0, 1e-9)
    var dy = max(y1 - y0, 1e-9)
    var z = log2(min(max(w - 2.0 * PAD, 40.0) / dx, max(h - 2.0 * PAD, 40.0) / dy))
    if len(xs) == 1 or z > 14.5:
        z = min(z, 14.5)
    return View3((x0 + x1) / 2.0, (y0 + y1) / 2.0, min(max(z, MIN_ZOOM), MAX_ZOOM))


struct Fly(Copyable, Movable):
    """A flight from one view to another: van Wijk and Nuij's optimal path (zoom out, pan, zoom in) for a viewport `width` points
    wide, eased at both ends."""
    var ux0: Float64
    var uy0: Float64
    var w0: Float64  # the viewport's width in world units
    var ux1: Float64
    var uy1: Float64
    var w1: Float64
    var d1: Float64
    var r0: Float64
    var s_total: Float64
    var straight: Bool
    var width: Float64
    var start_ns: Int
    var ms: Float64

    def __init__(out self, a: View3, b: View3, width: Float64, start_ns: Int):
        self.width = max(width, 1.0)
        self.ux0 = a.cx
        self.uy0 = a.cy
        self.w0 = self.width / (2.0 ** a.zoom)
        self.ux1 = b.cx
        self.uy1 = b.cy
        self.w1 = self.width / (2.0 ** b.zoom)
        self.start_ns = start_ns
        var dx = self.ux1 - self.ux0
        var dy = self.uy1 - self.uy0
        var d2 = dx * dx + dy * dy
        self.d1 = sqrt(d2)
        var rho2 = RHO * RHO
        if d2 < 1e-18 or self.d1 < 1e-6 * self.w0:
            self.straight = True
            self.r0 = 0
            self.s_total = abs(log(self.w1 / self.w0)) / RHO
        else:
            self.straight = False
            var b0 = (self.w1 * self.w1 - self.w0 * self.w0 + rho2 * rho2 * d2) / (2.0 * self.w0 * rho2 * self.d1)
            var b1 = (self.w1 * self.w1 - self.w0 * self.w0 - rho2 * rho2 * d2) / (2.0 * self.w1 * rho2 * self.d1)
            self.r0 = log(sqrt(b0 * b0 + 1.0) - b0)
            var r1 = log(sqrt(b1 * b1 + 1.0) - b1)
            self.s_total = (r1 - self.r0) / RHO
        self.ms = min(max(self.s_total * 520.0, 450.0), 1500.0)

    def at(self, now: Int) -> Tuple[View3, Bool]:
        """The view at `now`, and whether the flight is over."""
        var t = min(max(Float64(now - self.start_ns) / 1e6 / self.ms, 0.0), 1.0)
        var e = t * t * (3.0 - 2.0 * t)  # (smoothstep: it leaves and lands softly)
        var s = e * self.s_total
        var cx: Float64
        var cy: Float64
        var w: Float64
        if self.straight:
            cx = self.ux0 + e * (self.ux1 - self.ux0)
            cy = self.uy0 + e * (self.uy1 - self.uy0)
            w = self.w0 * exp(RHO * s * (1.0 if self.w1 > self.w0 else -1.0))
            if t >= 1.0:
                w = self.w1
        else:
            var rho2 = RHO * RHO
            var u = self.w0 / (rho2 * self.d1) * (cosh(self.r0) * tanh(RHO * s + self.r0) - sinh(self.r0))
            cx = self.ux0 + u * (self.ux1 - self.ux0)
            cy = self.uy0 + u * (self.uy1 - self.uy0)
            w = self.w0 * cosh(self.r0) / cosh(RHO * s + self.r0)
        if t >= 1.0:
            return (View3(self.ux1, self.uy1, log2(self.width / self.w1)), True)
        return (View3(cx, cy, log2(self.width / max(w, 1e-12))), False)


# ---------------------------------------------------------------------------------------------------------------------
# drawing
# ---------------------------------------------------------------------------------------------------------------------

def _sample(px: List[UInt32], x: Int, y: Int) -> SIMD[DType.float32, 4]:
    var p = px[y * TILE + x]
    return SIMD[DType.float32, 4](Float32(p & 255), Float32((p >> 8) & 255), Float32((p >> 16) & 255), Float32((p >> 24) & 255))


def blit(mut s: Surface, px: List[UInt32], sx: Float64, sy: Float64, ssize: Float64, dx: Float64, dy: Float64, dsize: Float64):
    """The square [sx, sx + ssize) x [sy, sy + ssize) of a 256 x 256 tile drawn into the square at (dx, dy), dsize pixels a side,
    clipped to the surface: bilinear when it is scaled, a straight copy when it isn't."""
    var x0 = max(Int(floor(dx)), 0)
    var y0 = max(Int(floor(dy)), 0)
    var x1 = min(Int(floor(dx + dsize)), s.width)
    var y1 = min(Int(floor(dy + dsize)), s.height)
    if x0 >= x1 or y0 >= y1:
        return
    var k = ssize / dsize
    var out = s.pixels()
    var exact = abs(k - 1.0) < 1e-3 and abs(dx - floor(dx)) < 1e-3 and abs(dy - floor(dy)) < 1e-3
    for y in range(y0, y1):
        var fy = sy + (Float64(y) + 0.5 - dy) * k - 0.5
        if exact:
            var ty = min(max(Int(floor(fy + 0.5)), 0), TILE - 1)
            for x in range(x0, x1):
                var tx = min(max(Int(floor(sx + Float64(x) - dx)), 0), TILE - 1)
                out.unsafe_offset(y * s.width + x)[] = px[ty * TILE + tx] | 0xFF000000
            continue
        var iy = Int(floor(fy))
        var wy = Float32(fy - Float64(iy))
        var ya = min(max(iy, 0), TILE - 1)
        var yb = min(max(iy + 1, 0), TILE - 1)
        for x in range(x0, x1):
            var fx = sx + (Float64(x) + 0.5 - dx) * k - 0.5
            var ix = Int(floor(fx))
            var wx = Float32(fx - Float64(ix))
            var xa = min(max(ix, 0), TILE - 1)
            var xb = min(max(ix + 1, 0), TILE - 1)
            var top = _sample(px, xa, ya) * (1 - wx) + _sample(px, xb, ya) * wx
            var bot = _sample(px, xa, yb) * (1 - wx) + _sample(px, xb, yb) * wx
            var c = top * (1 - wy) + bot * wy
            out.unsafe_offset(y * s.width + x)[] = UInt32(Int(c[0] + 0.5)) | (UInt32(Int(c[1] + 0.5)) << 8) | (UInt32(Int(c[2] + 0.5)) << 16) | 0xFF000000


def _corners(mut s: Surface, radius: Float64, color: UInt32):
    """Rounds the canvas's corners: what lies outside a quarter circle of `radius` pixels at each corner becomes `color`."""
    var r = Int(radius) + 1
    var out = s.pixels()
    for cy in range(2):
        for cx in range(2):
            for j in range(min(r, s.height)):
                for i in range(min(r, s.width)):
                    var x = i if cx == 0 else s.width - 1 - i
                    var y = j if cy == 0 else s.height - 1 - j
                    var ddx = radius - (Float64(i) + 0.5)
                    var ddy = radius - (Float64(j) + 0.5)
                    if ddx <= 0 or ddy <= 0:
                        continue
                    var d = sqrt(ddx * ddx + ddy * ddy) - radius
                    if d > -1.0:
                        out.unsafe_offset(y * s.width + x)[] = over(out.unsafe_offset(y * s.width + x)[], color, min(d + 1.0, 1.0) if d < 0 else 1.0)


def _pill(mut s: Surface, font: Font, text: String, x: Float64, y: Float64, size: Float64, ink: UInt32, back: UInt32, weight: Int, align: Int):
    """Text on a small rounded plate (legible over any tile): (x, y) is the baseline's start (LEFT) or end (RIGHT)."""
    var k = s.scale
    var w = font.measure(text, size, weight)
    var left = x if align == LEFT else (x - w if align == RIGHT else x - w / 2.0)
    rect(s, left - 5.0 * k, y - size * 0.95, w + 10.0 * k, size * 1.32, back, size * 0.42)
    font.draw(s, text, left, y, size, ink, weight, LEFT)


struct TripMap(Movable):
    var card: String
    var tag: String  # the canvas's view tag: where its stops' spots are measured from
    var area: String
    var stops: List[Stop]
    var view: View3
    var fly: Optional[Fly]
    var focus: Int  # the stop pointed at last (-1: the whole trip)
    var last_point_ns: Int
    var placed: Bool  # the view has been fitted once
    var size: Tuple[Float64, Float64]  # the canvas in points when last drawn
    var log: List[String]
    var asked: Bool  # the geocoder has been asked
    var settled_said: Bool
    var tiles_said: Bool
    var born_ns: Int
    var settled_ns: Int
    var flights: Int

    def __init__(out self, card: String, tag: String, area: String, var stops: List[Stop]):
        self.card = card
        self.tag = tag
        self.area = area
        self.stops = stops^
        self.view = View3(128.0, 128.0, MIN_ZOOM)
        self.fly = None
        self.focus = -1
        self.last_point_ns = 0
        self.placed = False
        self.size = (0.0, 0.0)
        self.log = List[String]()
        self.asked = False
        self.settled_said = False
        self.tiles_said = False
        self.born_ns = now_ns()
        self.settled_ns = 0
        self.flights = 0

    @staticmethod
    def empty() -> TripMap:
        return TripMap("", "", "", List[Stop]())

    def stop_tag(self, i: Int) -> String:
        return self.card + ".stop" + String(i + 1)

    def parts(self, card: String) -> List[Part]:
        """Every stop (card + ".stop1"…), named by its name or a word of it no other stop shares (mojoui.pointer.names_for)."""
        var labels = List[String]()
        for ref s in self.stops:
            labels.append(s.name)
        var out = List[Part]()
        for i in range(len(self.stops)):
            out.append(Part(card, "stop" + String(i + 1), names_for(self.stops[i].name, labels)))
        return out^

    def take_log(mut self) -> List[String]:
        var out = self.log.copy()
        self.log = List[String]()
        return out^

    def where(self, i: Int, now: Int) -> Tuple[Float64, Float64]:
        """Stop i's place in world units now (mid-glide to its checked place)."""
        ref s = self.stops[i]
        var t = min(max(Float64(now - s.moved_ns) / 1e6 / Float64(GLIDE_MS), 0.0), 1.0) if s.moved_ns > 0 else 1.0
        var e = 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t)
        var lat = s.from_lat + (s.lat - s.from_lat) * e
        var lon = s.from_lon + (s.lon - s.from_lon) * e
        return (world_x(lon), world_y(lat))

    def overview(self) -> View3:
        var xs = List[Float64]()
        var ys = List[Float64]()
        for ref s in self.stops:
            xs.append(world_x(s.lon))
            ys.append(world_y(s.lat))
        return fit(xs, ys, self.size[0], self.size[1])

    def close_up(self, i: Int) -> View3:
        """Stop i in the middle, close enough that its nearest neighbour sits a third of the card's width away (so two stops a
        street apart come apart), at least one step closer than the whole trip, at most MAX_ZOOM."""
        var all = self.overview()
        var x = world_x(self.stops[i].lon)
        var y = world_y(self.stops[i].lat)
        var near = 1e300
        for j in range(len(self.stops)):
            if j != i:
                var dx = world_x(self.stops[j].lon) - x
                var dy = world_y(self.stops[j].lat) - y
                near = min(near, sqrt(dx * dx + dy * dy))
        var z = all.zoom + 2.0
        if near < 1e299 and near > 0.0:
            z = log2(max(self.size[0], 200.0) / 3.0 / near)
        z = min(max(z, all.zoom + 1.0), MAX_ZOOM)
        return View3(x, y, z)

    def go(mut self, target: View3):
        self.fly = Fly(self.view, target, self.size[0], now_ns())
        self.flights += 1

    def point(mut self, tag: String) -> Bool:
        """A `point` at one of its stops: the map flies there. False when the tag isn't one of its stops."""
        for i in range(len(self.stops)):
            if self.stop_tag(i) == tag:
                self.focus = i
                self.last_point_ns = now_ns()
                if self.placed:
                    self.go(self.close_up(i))
                self.log.append("MAP: card=" + self.card + " fly=" + String(i + 1) + " zoom=" + String(Float64(Int(self.close_up(i).zoom * 10.0)) / 10.0) + " text=" + self.stops[i].name)
                return True
        return False

    def ask(mut self):
        """The geocoder's answers for the stops not settled yet; a stop moves to its checked place when one lands."""
        var geo = Geocoder.shared()
        var now = now_ns()
        var changed = False
        for i in range(len(self.stops)):
            if self.stops[i].settled:
                continue
            var q = self.stops[i].name
            if self.area != "" and not self.stops[i].bare and q.lower().find(self.area.lower()) < 0:
                q = q + ", " + self.area
            var a = geo[].lookup(q)
            if a.state == GEO_PENDING:
                continue
            if a.state == GEO_NONE and q != self.stops[i].name:  # (the model's area may be loose, "Central Italy": the name alone)
                self.stops[i].bare = True
                continue
            var p = settle(self.stops[i].guess_lat, self.stops[i].guess_lon, a)
            ref s = self.stops[i]
            var moved = km(s.lat, s.lon, p[0], p[1])
            var off = km(s.guess_lat, s.guess_lon, a.lat, a.lon) if a.state == GEO_FOUND else -1.0
            s.from_lat = s.lat
            s.from_lon = s.lon
            s.lat = p[0]
            s.lon = p[1]
            s.how = p[2]
            s.settled = True
            s.moved_ns = now if moved > 0.001 else 0
            changed = True
            self.log.append("MAP: card=" + self.card + " stop=" + String(i + 1) + " lat=" + String(s.lat) + " lon=" + String(s.lon) + " how=" + s.how
                            + " guess_lat=" + String(s.guess_lat) + " guess_lon=" + String(s.guess_lon) + " geocoder_km=" + String(Float64(Int(off * 100.0)) / 100.0)
                            + " geocode_ms=" + String(Int(a.ms)) + " cached=" + String(a.from_disk) + " text=" + s.name)
        if changed and not self.settled_said:
            var all = True
            var checked = 0
            for ref s in self.stops:
                all = all and s.settled
                if s.how == "checked":
                    checked += 1
            if all:
                self.settled_said = True
                self.settled_ns = now
                self.log.append("MAP: card=" + self.card + " settled=" + String(len(self.stops)) + " checked=" + String(checked) + " ms=" + String(Int(Float64(now - self.born_ns) / 1e6)))
        if changed and self.focus < 0 and self.placed:  # (the whole trip again, with the stops where they are)
            self.go(self.overview())

    def busy(self) -> Bool:
        for ref s in self.stops:
            if not s.settled:
                return True
        return False

    def draw(mut self, mut s: Surface, font: Font, p: Palette):
        var k = s.scale
        var w = Float64(s.width) / k
        var h = Float64(s.height) / k
        var now = now_ns()
        self.size = (w, h)
        if not self.asked:
            self.asked = True
        self.ask()
        if not self.placed and len(self.stops) > 0:
            self.view = self.overview()
            self.placed = True
            if self.focus >= 0:
                self.go(self.close_up(self.focus))
        if self.focus >= 0 and now - self.last_point_ns > BACK_MS * 1_000_000 and not self.fly:
            self.focus = -1
            self.go(self.overview())
        var moving = False
        if self.fly:
            var f = self.fly.value().at(now)
            self.view = f[0]
            if f[1] or s.still:
                if s.still:
                    self.view = self.fly.value().at(now + 10_000_000_000)[0]
                self.fly = None
            else:
                moving = True
        # the ground, then the tiles (a missing tile shows its parent's, enlarged, while it comes)
        s.fill(p.raised)
        var store = TileStore.shared()
        _ = store[].poll()
        var zi = min(max(Int(floor(self.view.zoom + 0.5)), 0), 19)
        var scale = 2.0 ** (self.view.zoom - Float64(zi))  # a tile's 256 world-at-zi pixels -> points
        var tile_pts = Float64(TILE) * scale
        var n = 1 << zi
        var left = self.view.cx * Float64(n) - w / 2.0 / scale  # in zi-tile pixels
        var top = self.view.cy * Float64(n) - h / 2.0 / scale
        var tx0 = Int(floor(left / Float64(TILE)))
        var ty0 = Int(floor(top / Float64(TILE)))
        var tx1 = Int(floor((left + w / scale) / Float64(TILE)))
        var ty1 = Int(floor((top + h / scale) / Float64(TILE)))
        var missing = 0
        var shown = 0
        for ty in range(max(ty0, 0), min(ty1, n - 1) + 1):
            for tx in range(tx0, tx1 + 1):
                var dx = (Float64(tx * TILE) - left) * scale * k
                var dy = (Float64(ty * TILE) - top) * scale * k
                var t = store[].find(zi, tx, ty)
                if t >= 0:
                    blit(s, store[].pixels[t], 0.0, 0.0, Float64(TILE), dx, dy, tile_pts * k)
                    shown += 1
                    continue
                missing += 1
                store[].want(zi, tx, ty)
                for up in range(1, 6):  # (an ancestor tile, enlarged, until this one comes)
                    if zi - up < 0:
                        break
                    var wrap = ((tx % n) + n) % n
                    var pt = store[].find(zi - up, wrap >> up, ty >> up)
                    if pt >= 0:
                        var part = Float64(TILE) / Float64(1 << up)
                        var sx = Float64(wrap - ((wrap >> up) << up)) * part
                        var sy = Float64(ty - ((ty >> up) << up)) * part
                        blit(s, store[].pixels[pt], sx, sy, part, dx, dy, tile_pts * k)
                        break
        if missing == 0 and shown > 0 and self.settled_said and not self.tiles_said and not moving:
            self.tiles_said = True
            self.log.append("MAP: card=" + self.card + " tiles=" + String(shown) + " zoom=" + String(zi) + " net=" + String(len(store[].net_ms)) + " net_ms=" + String(Int(_median(store[].net_ms)))
                            + " disk=" + String(len(store[].disk_ms)) + " disk_ms=" + String(Float64(Int(_median(store[].disk_ms) * 100.0)) / 100.0) + " full_ms=" + String(Int(Float64(now - self.born_ns) / 1e6)))
        # the route, then the stops (numbered in the order visited), the pointed-at one last and larger
        var xs = List[Float64]()
        var ys = List[Float64]()
        var zk = 2.0 ** self.view.zoom
        for i in range(len(self.stops)):
            var q = self.where(i, now)
            xs.append((w / 2.0 + (q[0] - self.view.cx) * zk) * k)
            ys.append((h / 2.0 + (q[1] - self.view.cy) * zk) * k)
            if self.stops[i].moved_ns > 0 and now - self.stops[i].moved_ns < GLIDE_MS * 1_000_000:
                moving = True
        for i in range(1, len(xs)):
            line(s, xs[i - 1], ys[i - 1], xs[i], ys[i], 7.0 * k, with_alpha(p.card, 0.9))
        for i in range(1, len(xs)):
            line(s, xs[i - 1], ys[i - 1], xs[i], ys[i], 3.5 * k, p.accent)
        var order = List[Int]()
        for i in range(len(xs)):
            if i != self.focus:
                order.append(i)
        if self.focus >= 0 and self.focus < len(xs):
            order.append(self.focus)
        var label_size = 12.5 * k
        for i in order:
            var r = MARKER * k * (1.18 if i == self.focus else 1.0)
            circle(s, xs[i] + 1.0 * k, ys[i] + 2.0 * k, r + 3.0 * k, with_alpha(p.ink, 0.18))  # (one soft shadow)
            circle(s, xs[i], ys[i], r + 2.5 * k, p.card)
            circle(s, xs[i], ys[i], r, p.accent)
            font.draw(s, String(i + 1), xs[i], ys[i] + r * 0.42, r * 1.15, p.accent_ink, MEDIUM, CENTRE)
            var right = xs[i] + r + 8.0 * k + font.measure(self.stops[i].name, label_size, MEDIUM) + 10.0 * k < Float64(s.width)
            if right:
                _pill(s, font, self.stops[i].name, xs[i] + r + 9.0 * k, ys[i] + label_size * 0.36, label_size, p.ink, with_alpha(p.card, 0.92), MEDIUM, LEFT)
            else:
                _pill(s, font, self.stops[i].name, xs[i] - r - 9.0 * k, ys[i] + label_size * 0.36, label_size, p.ink, with_alpha(p.card, 0.92), MEDIUM, RIGHT)
            put_spot(self.stop_tag(i), self.tag, xs[i] / k - r / k, ys[i] / k - r / k, 2.0 * r / k, 2.0 * r / k)
        # the attribution the tiles ask for, and the card's rounded corners
        var att = 10.0 * k
        var words = String(ATTRIBUTION).replace("© ", "")  # (the canvas font has no ©: drawn as a ring with a c in it)
        var right_x = Float64(s.width) - 10.0 * k
        var base = Float64(s.height) - 8.0 * k
        var tw = font.measure(words, att, REGULAR)
        var sym = att * 0.95
        rect(s, right_x - tw - sym - 9.0 * k, base - att * 0.95, tw + sym + 14.0 * k, att * 1.32, with_alpha(p.card, 0.85), att * 0.42)
        var cx = right_x - tw - sym / 2.0 - 3.0 * k
        var cy = base - att * 0.33
        circle(s, cx, cy, sym / 2.0, p.ink2)
        circle(s, cx, cy, sym / 2.0 - 0.9 * k, with_alpha(p.card, 1.0))
        font.draw(s, "c", cx, cy + att * 0.24, att * 0.72, p.ink2, REGULAR, CENTRE)
        font.draw(s, words, right_x - tw, base, att, p.ink2, REGULAR, LEFT)
        _corners(s, 12.0 * k, p.card)
        if moving or missing > 0 or self.busy() or store[].busy() or self.focus >= 0:
            s.again = not s.still or self.busy() or missing > 0

    def describe(self) -> String:
        var out = "Map of " + (self.area if self.area != "" else String("a trip")) + ": "
        for i in range(len(self.stops)):
            out += ("; " if i > 0 else "") + String(i + 1) + ". " + self.stops[i].name + " (" + self.stops[i].how + ")"
        return out^


def _median(v: List[Float64]) -> Float64:
    if len(v) == 0:
        return 0.0
    var s = v.copy()
    sort(s)
    return s[len(s) // 2]
