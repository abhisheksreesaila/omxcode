# mojoui.geo: pictures taken from the air, put on the map (goal 39 M8). A generic component: a camera looking straight down
# from a moving platform (a drone, a plane, a mast) whose position comes from a log (mojoui.timeseries), so any pixel of
# any frame has a latitude and longitude; rows of a VideoTable get theirs; rows seen on many frames become one place each.
#
#   var cam = NadirCamera(1280, 720, 0.001, 52.01)      # image size, ground metres per pixel per metre of altitude, latitude
#   var pose = pose_at(telemetry, t)                     # lat, lon, alt_m, heading_deg at time t (interpolated, 10 Hz → any t)
#   var p = cam.to_ground(pose, px, py)                  # (lat, lon) of a point in the picture (px, py: pixel units, 0 = edge)
#   var q = cam.to_pixel(pose, lat, lon)                 # and back
#   metres(lat1, lon1, lat2, lon2)                       # distance on the ground (haversine)
#   georeference(table, telemetry, cam)                  # fills table.lat, table.lon, table.gsd from each row's (cx, cy)
#   var poles = places(table, "insulator", 6.0, 5)       # rows within 6 m of each other (≥ 5 of them) → one place each
#   name_along_route(poles, telemetry, "P", 2)           # P01, P02 … in the order the route passes them
#
# The camera model (a nadir pinhole, constant image size): ground sample distance gsd = alt_m * gsd_per_m_alt metres per
# pixel; a point (px, py) in the picture is right = (px - width/2) * gsd and fwd = (height/2 - py) * gsd metres from the
# point under the camera, turned by the heading (compass degrees, clockwise from north) into east/north metres, and those
# into degrees with a local flat-earth scale (m_per_deg_lat; m_per_deg_lon = m_per_deg_lat * cos(latitude)). Good to
# centimetres over a frame's few hundred metres; a lens model (tilt, distortion) would replace to_ground/to_pixel only.

from std.math import sin, cos, sqrt, pi, asin, atan2
from mojoui.timeseries import TimeSeries
from mojoui.videotable import VideoTable

comptime EARTH_M = 6371008.8  # mean earth radius (haversine)


@fieldwise_init
struct Pose(Copyable, Movable, ImplicitlyCopyable):
    """Where the camera is: latitude and longitude (degrees), height above the ground (m), heading (compass degrees)."""

    var lat: Float64
    var lon: Float64
    var alt_m: Float64
    var heading_deg: Float64


def _rad(d: Float64) -> Float64:
    return d * pi / 180.0


struct NadirCamera(Copyable, Movable, ImplicitlyCopyable):
    """A camera looking straight down; the picture's top is the heading."""

    var width: Int
    var height: Int
    var gsd_per_m_alt: Float64  # ground metres per pixel, per metre of altitude
    var m_per_deg_lat: Float64
    var m_per_deg_lon: Float64

    def __init__(out self, width: Int, height: Int, gsd_per_m_alt: Float64, lat0: Float64, m_per_deg_lat: Float64 = 111320.0):
        """`lat0`: a latitude in the area flown (sets the east–west scale of a degree)."""
        self.width = width
        self.height = height
        self.gsd_per_m_alt = gsd_per_m_alt
        self.m_per_deg_lat = m_per_deg_lat
        self.m_per_deg_lon = m_per_deg_lat * cos(_rad(lat0))

    def gsd(self, pose: Pose) -> Float64:
        """Ground metres per pixel at this pose."""
        return pose.alt_m * self.gsd_per_m_alt

    def to_ground(self, pose: Pose, px: Float64, py: Float64) -> Tuple[Float64, Float64]:
        """(lat, lon) of the picture point (px, py), in pixel units from the top-left edge (pixel i's centre is i + 0.5)."""
        var g = self.gsd(pose)
        var right = (px - Float64(self.width) / 2) * g
        var fwd = (Float64(self.height) / 2 - py) * g
        var h = _rad(pose.heading_deg)
        var east = right * cos(h) + fwd * sin(h)
        var north = -right * sin(h) + fwd * cos(h)
        return (pose.lat + north / self.m_per_deg_lat, pose.lon + east / self.m_per_deg_lon)

    def to_pixel(self, pose: Pose, lat: Float64, lon: Float64) -> Tuple[Float64, Float64]:
        """The picture point (px, py) showing (lat, lon); outside 0…width/height when it is out of view."""
        var g = self.gsd(pose)
        var north = (lat - pose.lat) * self.m_per_deg_lat
        var east = (lon - pose.lon) * self.m_per_deg_lon
        var h = _rad(pose.heading_deg)
        var right = east * cos(h) - north * sin(h)
        var fwd = east * sin(h) + north * cos(h)
        return (right / g + Float64(self.width) / 2, Float64(self.height) / 2 - fwd / g)


def pose_at(ts: TimeSeries, t: Float64, lat: String = "lat", lon: String = "lon", alt: String = "alt_m",
            heading: String = "heading_deg") -> Pose:
    """The pose at time t from a log with those columns, interpolated linearly (the heading the short way round)."""
    var b = ts.bracket(t)
    if b[0] < 0:
        return Pose(0, 0, 0, 0)
    var h0 = ts.value(heading, b[0])
    var dh = ts.value(heading, b[1]) - h0
    if dh > 180:
        dh -= 360
    elif dh < -180:
        dh += 360
    var h = h0 + dh * b[2]
    if h < 0:
        h += 360
    elif h >= 360:
        h -= 360
    return Pose(ts.at(lat, t), ts.at(lon, t), ts.at(alt, t), h)


def metres(lat1: Float64, lon1: Float64, lat2: Float64, lon2: Float64) -> Float64:
    """Distance on the ground between two points (haversine, mean earth radius)."""
    var p1 = _rad(lat1)
    var p2 = _rad(lat2)
    var dp = p2 - p1
    var dl = _rad(lon2 - lon1)
    var a = sin(dp / 2) ** 2 + cos(p1) * cos(p2) * sin(dl / 2) ** 2
    return 2 * EARTH_M * asin(min(sqrt(a), 1.0))


def east_north(lat0: Float64, lon0: Float64, lat: Float64, lon: Float64) -> Tuple[Float64, Float64]:
    """(east, north) metres of (lat, lon) from (lat0, lon0), flat-earth (fine over a few km)."""
    var k = EARTH_M * pi / 180.0
    return ((lon - lon0) * k * cos(_rad(lat0)), (lat - lat0) * k)


def georeference(mut table: VideoTable, ts: TimeSeries, cam: NadirCamera):
    """Every row's (cx, cy) on the ground at its frame's time: fills table.lat, table.lon and table.gsd (metres per pixel,
    to turn a row's pixel sizes into metres)."""
    table.lat = List[Float64](capacity=table.rows())
    table.lon = List[Float64](capacity=table.rows())
    table.gsd = List[Float64](capacity=table.rows())
    for i in range(table.rows()):
        var pose = pose_at(ts, table.t[i])
        var p = cam.to_ground(pose, table.cx[i], table.cy[i])
        table.lat.append(p[0])
        table.lon.append(p[1])
        table.gsd.append(cam.gsd(pose))


# ---------- places: rows seen on many frames → one thing on the ground ----------


struct Place(Copyable, Movable, ImplicitlyCopyable):
    """One thing on the ground, seen in `rows` rows: its mean position, the frames' time span, and its measured size on
    the ground (rows' value × gsd², i.e. an area in m² when the value is an area in pixels): the median over its rows
    and the largest."""

    var name: String
    var kind: String
    var lat: Float64
    var lon: Float64
    var rows: Int
    var first_t: Float64
    var last_t: Float64
    var size: Float64  # median
    var size_max: Float64

    def __init__(out self, kind: String, lat: Float64, lon: Float64):
        self.name = String("")
        self.kind = kind
        self.lat = lat
        self.lon = lon
        self.rows = 0
        self.first_t = 0
        self.last_t = 0
        self.size = 0
        self.size_max = 0


def _median(var xs: List[Float64]) -> Float64:
    if len(xs) == 0:
        return 0
    sort(xs)
    var n = len(xs)
    return xs[n // 2] if n % 2 == 1 else (xs[n // 2 - 1] + xs[n // 2]) / 2


def places(table: VideoTable, kind: String, radius_m: Float64, min_rows: Int = 1) -> List[Place]:
    """Rows of `kind` (georeferenced) joined into places: each row goes to the nearest place whose mean position is
    within radius_m, else starts one; places seen in fewer than min_rows rows are dropped (a glint, a false colour)."""
    var out = List[Place]()
    var sizes = List[List[Float64]]()
    var sum_lat = List[Float64]()
    var sum_lon = List[Float64]()
    if not table.georeferenced():
        return out^
    for i in range(table.rows()):
        if table.kind[i] != kind:
            continue
        var best = -1
        var best_d = radius_m
        for k in range(len(out)):
            var d = metres(out[k].lat, out[k].lon, table.lat[i], table.lon[i])
            if d <= best_d:
                best_d = d
                best = k
        if best < 0:
            best = len(out)
            out.append(Place(kind, table.lat[i], table.lon[i]))
            out[best].first_t = table.t[i]
            sizes.append(List[Float64]())
            sum_lat.append(0)
            sum_lon.append(0)
        ref p = out[best]
        p.rows += 1
        sum_lat[best] += table.lat[i]
        sum_lon[best] += table.lon[i]
        p.lat = sum_lat[best] / Float64(p.rows)
        p.lon = sum_lon[best] / Float64(p.rows)
        p.first_t = min(p.first_t, table.t[i])
        p.last_t = max(p.last_t, table.t[i])
        var s = table.value[i] * table.gsd[i] * table.gsd[i]
        sizes[best].append(s)
        p.size_max = max(p.size_max, s)
    var kept = List[Place]()
    for k in range(len(out)):
        if out[k].rows >= min_rows:
            out[k].size = _median(sizes[k].copy())
            kept.append(out[k])
    return kept^


def along_route(ts: TimeSeries, lat: Float64, lon: Float64, lat_col: String = "lat", lon_col: String = "lon") -> Float64:
    """How far along the logged route (metres from its first point) the point nearest (lat, lon) lies: the route is the
    polyline through the log's positions, and the point is projected onto its nearest segment."""
    var n = ts.rows()
    if n == 0:
        return 0
    var la = ts.column(lat_col)
    var lo = ts.column(lon_col)
    var lat0 = la[0]
    var lon0 = lo[0]
    var p = east_north(lat0, lon0, lat, lon)
    var best = 1e300
    var best_s = 0.0
    var walked = 0.0
    var a = east_north(lat0, lon0, la[0], lo[0])
    for i in range(1, n):
        var b = east_north(lat0, lon0, la[i], lo[i])
        var dx = b[0] - a[0]
        var dy = b[1] - a[1]
        var seg = sqrt(dx * dx + dy * dy)
        var u = 0.0
        if seg > 0:
            u = min(max(((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (seg * seg), 0.0), 1.0)
        var qx = a[0] + u * dx - p[0]
        var qy = a[1] + u * dy - p[1]
        var d = qx * qx + qy * qy
        if d < best:
            best = d
            best_s = walked + u * seg
        walked += seg
        a = b
    return best_s


def name_along_route(mut ps: List[Place], ts: TimeSeries, prefix: String, digits: Int = 2):
    """Sorts places by how far along the route they lie and names them prefix + their rank from 1, zero-padded to
    `digits` (P01, P02 …): the same things flown the same way get the same names on every flight, with no list of
    them needed."""
    var keys = List[Float64]()
    for p in ps:
        keys.append(along_route(ts, p.lat, p.lon))
    for i in range(1, len(ps)):  # insertion sort: a handful of places
        var j = i
        while j > 0 and keys[j - 1] > keys[j]:
            var k = keys[j]
            keys[j] = keys[j - 1]
            keys[j - 1] = k
            var p = ps[j]
            ps[j] = ps[j - 1]
            ps[j - 1] = p
            j -= 1
    for i in range(len(ps)):
        var s = String(i + 1)
        while s.byte_length() < digits:
            s = "0" + s
        ps[i].name = prefix + s


def nearest(ps: List[Place], lat: Float64, lon: Float64, max_m: Float64) -> Int:
    """The index of the place nearest (lat, lon) within max_m metres (-1: none)."""
    var best = -1
    var best_d = max_m
    for k in range(len(ps)):
        var d = metres(ps[k].lat, ps[k].lon, lat, lon)
        if d <= best_d:
            best_d = d
            best = k
    return best
