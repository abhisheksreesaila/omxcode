# The globe's data and its one GPU function, shared by the app (app.mojo) and the batch renderer (render.mojo).
#
#   earth()  rasterizes Natural Earth's land polygons (earth_data.mojo) into a 4096 × 2048 texture, on the CPU,
#            at start-up: coverage, distance to the coast on either side, city lights.
#   flights(n) makes n aircraft position reports along great circles between real cities and bins them into a
#            data cube: 24 hours × 1440 × 720 cells (0.25°), like a gridded OGC coverage.
#   globe()  is the pixel function: an orthographic globe, one GPU thread per pixel, reading both from Gpu.set_data.
#
# Knobs (eight float32): view longitude and latitude (radians), radius (pixels), UTC hour, layers (LAYER_* bits),
# 1 / log(1 + the cube's busiest cell), the sun's declination (radians), the screen's scale (pixels per point).

from mojoui.maths import sqrt, log, exp, sin, cos, atan2, floor, ceil, pi
from mojoui.text import base64_decode
from earth_data import LAND, CITIES, CITY_NAMES

comptime TW = 4096  # the earth texture: equirectangular, 4096 × 2048 (≈ 10 km a texel at the equator)
comptime TH = 2048
comptime CW = 1440  # the flight cube: 0.25° cells, one slice per UTC hour
comptime CH = 720
comptime HOURS = 24
comptime CUBE = TW * TH  # where the cube starts in the data
comptime WORDS = TW * TH + HOURS * CW * CH

comptime LAYER_FLIGHTS = 1
comptime LAYER_SUN = 2
comptime LAYER_GRID = 4
comptime LAYER_LIGHTS = 8

comptime Knobs8 = SIMD[DType.float32, 8]
comptime DEG = 57.29577951308232


# ---------- the land texture (a scanline rasterizer) ----------

def land_rings() -> List[List[Float32]]:
    """Each ring as x, y pairs in texel units of a TW × TH picture (x east from 180°W, y south from 90°N)."""
    var raw = base64_decode(LAND)
    var at = 0

    @parameter
    def word() -> Int:
        var v = Int(raw[at]) | (Int(raw[at + 1]) << 8)
        at += 2
        return v - 65536 if v >= 32768 else v

    var rings = List[List[Float32]]()
    var count = word()
    for _ in range(count):
        var hi = word()
        var n = (hi << 15) | word()
        var ring = List[Float32](capacity=2 * n)
        for _ in range(n):
            var lon = Float64(word()) / 32767.0 * 180.0
            var lat = Float64(word()) / 32767.0 * 90.0
            ring.append(Float32((lon + 180.0) / 360.0 * Float64(TW)))
            ring.append(Float32((90.0 - lat) / 180.0 * Float64(TH)))
        rings.append(ring^)
    return rings^


def rasterize(rings: List[List[Float32]], w: Int, h: Int, scale: Float32) -> List[UInt8]:
    """Even-odd fill of every ring at w × h (ring coordinates times `scale`): 1 inside, 0 outside. Each edge drops its
    crossings into the rows it spans (counted first, then placed), each row's few crossings are sorted and filled."""
    var per_row = List[Int](length=h + 1, fill=0)
    for ring in rings:
        var n = len(ring) // 2
        for i in range(n):
            var j = (i + 1) % n
            var y0 = ring[2 * i + 1] * scale
            var y1 = ring[2 * j + 1] * scale
            var lo = max(Int(ceil(min(y0, y1) - 0.5)), 0)  # rows whose centre (r + 0.5) lies in [min, max)
            var hi = min(Int(ceil(max(y0, y1) - 0.5)) - 1, h - 1)
            if min(y0, y1) == max(y0, y1):
                continue
            for r in range(lo, hi + 1):
                var c = Float32(r) + 0.5
                if c >= min(y0, y1) and c < max(y0, y1):
                    per_row[r + 1] += 1
    for r in range(h):
        per_row[r + 1] += per_row[r]
    var xs = List[Float32](length=per_row[h], fill=0)
    var fill = per_row.copy()
    for ring in rings:
        var n = len(ring) // 2
        for i in range(n):
            var j = (i + 1) % n
            var x0 = ring[2 * i] * scale
            var y0 = ring[2 * i + 1] * scale
            var x1 = ring[2 * j] * scale
            var y1 = ring[2 * j + 1] * scale
            if y0 == y1:
                continue
            var lo = max(Int(ceil(min(y0, y1) - 0.5)), 0)
            var hi = min(Int(ceil(max(y0, y1) - 0.5)) - 1, h - 1)
            for r in range(lo, hi + 1):
                var c = Float32(r) + 0.5
                if c >= min(y0, y1) and c < max(y0, y1):
                    xs[fill[r]] = x0 + (c - y0) * (x1 - x0) / (y1 - y0)
                    fill[r] += 1
    var mask = List[UInt8](length=w * h, fill=0)
    for r in range(h):
        var a = per_row[r]
        var b = per_row[r + 1]
        for i in range(a + 1, b):  # insertion sort: a row crosses a few dozen edges at most
            var v = xs[i]
            var j = i - 1
            while j >= a and xs[j] > v:
                xs[j + 1] = xs[j]
                j -= 1
            xs[j + 1] = v
        var k = a
        while k + 1 < b:
            var x_start = max(Int(floor(xs[k] - 0.5)) + 1, 0)
            var x_end = min(Int(floor(xs[k + 1] - 0.5)), w - 1)
            for x in range(x_start, x_end + 1):
                mask[r * w + x] = 1
            k += 2
    return mask^


def chamfer(inside: List[UInt8], w: Int, h: Int, want: UInt8) -> List[UInt8]:
    """Distance in texels (×4, capped at 255) from each texel to the nearest texel whose mask is `want`; wraps east-west."""
    var big = 1 << 20
    var d = List[Int](length=w * h, fill=big)
    for i in range(w * h):
        if inside[i] == want:
            d[i] = 0
    for y in range(h):  # forward: from the north-west
        for x in range(w):
            var i = y * w + x
            var best = d[i]
            var xl = (x - 1 + w) % w
            best = min(best, d[y * w + xl] + 3)
            if y > 0:
                best = min(best, d[i - w] + 3)
                best = min(best, d[(y - 1) * w + xl] + 4)
                best = min(best, d[(y - 1) * w + (x + 1) % w] + 4)
            d[i] = best
    for y in range(h - 1, -1, -1):  # backward: from the south-east
        for x in range(w - 1, -1, -1):
            var i = y * w + x
            var best = d[i]
            var xr = (x + 1) % w
            best = min(best, d[y * w + xr] + 3)
            if y < h - 1:
                best = min(best, d[i + w] + 3)
                best = min(best, d[(y + 1) * w + xr] + 4)
                best = min(best, d[(y + 1) * w + (x - 1 + w) % w] + 4)
            d[i] = best
    var out = List[UInt8](length=w * h, fill=0)
    for i in range(w * h):
        out[i] = UInt8(min(d[i] * 4 // 3, 255))  # (3 per texel: ×4/3 = 4 a texel)
    return out^


def earth(mut data: List[UInt32]):
    """Writes the TW × TH earth texture into data[0 : TW*TH]: byte 0 land coverage (rasterized at 2 × 2 a texel),
    byte 1 the ocean's distance from land, byte 2 the land's distance from the sea, byte 3 city lights."""
    var rings = land_rings()
    var fine = rasterize(rings, 2 * TW, 2 * TH, 2)
    var mask = List[UInt8](length=TW * TH, fill=0)
    var cover = List[UInt8](length=TW * TH, fill=0)
    for y in range(TH):
        for x in range(TW):
            var s = Int(fine[(2 * y) * 2 * TW + 2 * x]) + Int(fine[(2 * y) * 2 * TW + 2 * x + 1])
            s += Int(fine[(2 * y + 1) * 2 * TW + 2 * x]) + Int(fine[(2 * y + 1) * 2 * TW + 2 * x + 1])
            cover[y * TW + x] = UInt8(min(s * 64, 255))
            mask[y * TW + x] = 1 if s >= 2 else 0
    var sea = chamfer(mask, TW, TH, 1)  # ocean texels: how far to land
    var inland = chamfer(mask, TW, TH, 0)  # land texels: how far to the sea
    var lights = List[Float32](length=TW * TH, fill=0)
    var cities = materialize[CITIES]()
    for c in cities:
        var cx = (c[0] + 180.0) / 360.0 * Float64(TW)
        var cy = (90.0 - c[1]) / 180.0 * Float64(TH)
        var r = 1.5 + 2.2 * sqrt(c[2])  # texels: bigger cities glow wider
        var reach = Int(3 * r) + 1
        for dy in range(-reach, reach + 1):
            var y = Int(cy) + dy
            if y < 0 or y >= TH:
                continue
            for dx in range(-reach, reach + 1):
                var x = (Int(cx) + dx + TW) % TW
                var ex = Float64(Int(cx) + dx) + 0.5 - cx
                var ey = Float64(y) + 0.5 - cy
                lights[y * TW + x] += Float32(exp(-(ex * ex + ey * ey) / (r * r)) * (0.35 + 0.25 * sqrt(c[2])))
    for i in range(TW * TH):
        var light = UInt32(min(Int(lights[i] * 255), 255))
        data[i] = UInt32(cover[i]) | (UInt32(sea[i]) << 8) | (UInt32(inland[i]) << 16) | (light << 24)


# ---------- the flight cube ----------

def mix(z0: UInt64) -> UInt64:
    """splitmix64: the same flights on every run and machine."""
    var z = z0 + 0x9E3779B97F4A7C15
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB
    return z ^ (z >> 31)


def uniform(i: Int, salt: Int) -> Float64:
    return Float64(Int(mix(UInt64(i) * 16 + UInt64(salt)) >> 11)) / 9007199254740992.0


def unit(lon: Float64, lat: Float64) -> SIMD[DType.float64, 4]:
    """lon/lat (degrees) → a point on the unit sphere: x east at 90°E, y north, z at 0°, 0°."""
    var lo = lon / DEG
    var la = lat / DEG
    return SIMD[DType.float64, 4](cos(la) * sin(lo), sin(la), cos(la) * cos(lo), 0)


@fieldwise_init
struct Flights(Movable):
    var reports: Int  # aircraft position reports binned
    var routes: Int
    var busiest: UInt32  # the busiest cell of any hour
    var milliseconds: Float64


def flights(mut data: List[UInt32], routes: Int, per_route: Int) -> Flights:
    """`routes` city pairs (origins by population, destinations by population over distance), each flown a few times a
    day at local daytime hours, every flight reporting its position each minute. Binned into data[CUBE:]."""
    from mojoui.clock import now_ns

    var t0 = now_ns()
    var cities = materialize[CITIES]()
    var n = len(cities)
    var cum = List[Float64](length=n, fill=0)  # by population
    var total = 0.0
    for i in range(n):
        total += sqrt(cities[i][2])
        cum[i] = total

    @parameter
    def pick(u: Float64) -> Int:
        var lo = 0
        var hi = n - 1
        var target = u * total
        while lo < hi:
            var mid = (lo + hi) // 2
            if cum[mid] < target:
                lo = mid + 1
            else:
                hi = mid
        return lo

    var reports = 0
    var busiest = UInt32(0)
    for r in range(routes):
        var a = pick(uniform(r, 0))
        var b = a
        var tries = 0
        var km = 0.0
        while tries < 40:  # gravity: nearer, bigger cities are likelier
            b = pick(uniform(r, 1 + tries))
            tries += 1
            if b == a:
                continue
            var d = (unit(cities[a][0], cities[a][1]) * unit(cities[b][0], cities[b][1])).reduce_add()
            km = 6371.0 * atan2(sqrt(max(1.0 - d * d, 0.0)), d)
            if km > 250 and uniform(r, 100 + tries) < 900.0 / (km + 900.0):
                break
        if b == a or km <= 250:
            continue
        var pa = unit(cities[a][0], cities[a][1])
        var pb = unit(cities[b][0], cities[b][1])
        var omega = km / 6371.0
        var hours = km / 830.0 + 0.6
        var minutes = Int(hours * 60.0)
        var daily = 1 + Int(uniform(r, 60) * Float64(per_route) * 2.0)
        for f in range(daily):
            var local = 6.0 + 17.0 * uniform(r * 64 + f, 61)  # departs 06:00–23:00 at the origin
            var depart = local - cities[a][0] / 15.0
            for m in range(minutes):
                var t = (Float64(m) + 0.5) / Float64(minutes)
                var p = (pa * sin((1.0 - t) * omega) + pb * sin(t * omega)) / sin(omega)
                var lat = atan2(p[1], sqrt(p[0] * p[0] + p[2] * p[2])) * DEG
                var lon = atan2(p[0], p[2]) * DEG
                var utc = depart + t * hours
                utc = utc - 24.0 * floor(utc / 24.0)
                var col = min(Int((lon + 180.0) * 4.0), CW - 1)
                var row = min(Int((90.0 - lat) * 4.0), CH - 1)
                var at = CUBE + min(Int(utc), HOURS - 1) * CW * CH + row * CW + col
                data[at] += 1
                busiest = max(busiest, data[at])
                reports += 1
    return Flights(reports, routes, busiest, Float64(now_ns() - t0) / 1e6)


def world(mut data: List[UInt32]) -> Flights:
    """The globe's whole data into `data` (WORDS long): the earth texture, then the flight cube."""
    earth(data)
    return flights(data, 5000, 2)


# ---------- the pixel function ----------

def smoothstep(a: Float32, b: Float32, x: Float32) -> Float32:
    var t = min(max((x - a) / (b - a), Float32(0)), Float32(1))
    return t * t * (Float32(3) - Float32(2) * t)


def byte(w: UInt32, n: Int) -> Float32:
    return Float32(Int((w >> UInt32(8 * n)) & 0xFF)) * Float32(1.0 / 255.0)


def texel(data: UnsafePointer[UInt32, MutAnyOrigin], u: Float32, v: Float32) -> SIMD[DType.float32, 4]:
    """The earth texture at (u, v) in texels, bilinear, wrapping east-west: its four bytes as 0–1."""
    var x = u - Float32(0.5)
    var y = min(max(v - Float32(0.5), Float32(0)), Float32(TH - 1))
    var x0 = Int(floor(x))
    var y0 = Int(floor(y))
    var fx = x - Float32(x0)
    var fy = y - Float32(y0)
    var y1 = min(y0 + 1, TH - 1)
    var xa = x0 & (TW - 1)  # (TW is a power of two; no % in pixel code: Apple GPUs emulate 64-bit division)
    var xb = (xa + 1) & (TW - 1)
    var out = SIMD[DType.float32, 4](0)
    var w00 = data[y0 * TW + xa]
    var w10 = data[y0 * TW + xb]
    var w01 = data[y1 * TW + xa]
    var w11 = data[y1 * TW + xb]
    comptime for n in range(4):
        var top = byte(w00, n) * (Float32(1) - fx) + byte(w10, n) * fx
        var bottom = byte(w01, n) * (Float32(1) - fx) + byte(w11, n) * fx
        out[n] = top * (Float32(1) - fy) + bottom * fy
    return out


def cube_at(data: UnsafePointer[UInt32, MutAnyOrigin], slot: Int, u: Float32, v: Float32) -> Float32:
    """One hour's flight counts at (u, v) in cells, bilinear."""
    var x = u - Float32(0.5)
    var y = min(max(v - Float32(0.5), Float32(0)), Float32(CH - 1))
    var x0 = Int(floor(x))
    var y0 = Int(floor(y))
    var fx = x - Float32(x0)
    var fy = y - Float32(y0)
    var y1 = min(y0 + 1, CH - 1)
    var xa = x0 + CW if x0 < 0 else (x0 - CW if x0 >= CW else x0)  # (u is within one turn of [0, CW))
    var xb = xa + 1 if xa + 1 < CW else 0
    var base = CUBE + slot * CW * CH
    var top = Float32(Int(data[base + y0 * CW + xa])) * (Float32(1) - fx) + Float32(Int(data[base + y0 * CW + xb])) * fx
    var bottom = Float32(Int(data[base + y1 * CW + xa])) * (Float32(1) - fx) + Float32(Int(data[base + y1 * CW + xb])) * fx
    return top * (Float32(1) - fy) + bottom * fy


def flights_at(data: UnsafePointer[UInt32, MutAnyOrigin], hour: Float32, u: Float32, v: Float32) -> Float32:
    """Reports at (u, v) cells at a UTC hour, between the two nearest hourly slices (each slice's centre is h + 0.5)."""
    var h = hour - Float32(0.5)
    var s0 = Int(floor(h))
    var f = h - Float32(s0)
    var a = s0 + HOURS if s0 < 0 else (s0 - HOURS if s0 >= HOURS else s0)
    var b = a + 1 if a + 1 < HOURS else 0
    return cube_at(data, a, u, v) * (Float32(1) - f) + cube_at(data, b, u, v) * f


def rgb(r: Int, g: Int, b: Int) -> SIMD[DType.float32, 4]:
    return SIMD[DType.float32, 4](Float32(r), Float32(g), Float32(b), 0) * Float32(1.0 / 255.0)


def pack(c: SIMD[DType.float32, 4]) -> UInt32:
    var r = UInt32(Int(min(max(c[0], Float32(0)), Float32(1)) * 255 + 0.5))
    var g = UInt32(Int(min(max(c[1], Float32(0)), Float32(1)) * 255 + 0.5))
    var b = UInt32(Int(min(max(c[2], Float32(0)), Float32(1)) * 255 + 0.5))
    return r | (g << 8) | (b << 16) | (UInt32(255) << 24)


def sun(k: Knobs8) -> SIMD[DType.float32, 4]:
    """The direction to the sun: overhead at longitude (12 − UTC hour) × 15° and the declination k[6]."""
    var lon = (Float32(12) - k[3]) * Float32(15.0 / DEG)
    return SIMD[DType.float32, 4](cos(k[6]) * sin(lon), sin(k[6]), cos(k[6]) * cos(lon), 0)


def land_colour(lat: Float32, inland: Float32) -> SIMD[DType.float32, 4]:
    """Biomes by latitude (a sketch, not data): tropics green, subtropical desert, temperate, boreal, tundra, ice."""
    var a = abs(lat) * Float32(DEG)
    var c = rgb(48, 92, 46)
    c = c + (rgb(176, 150, 102) - c) * (smoothstep(14, 22, a) * (Float32(1) - smoothstep(30, 38, a)) * smoothstep(0.02, 0.15, inland))
    c = c + (rgb(82, 108, 60) - c) * smoothstep(34, 42, a)
    c = c + (rgb(56, 78, 56) - c) * smoothstep(48, 56, a)
    c = c + (rgb(128, 128, 116) - c) * smoothstep(62, 68, a)
    c = c + (rgb(232, 238, 244) - c) * smoothstep(70, 76, a)
    if lat < Float32(-60.0 / DEG):  # Antarctica
        c = rgb(236, 241, 247)
    return c * (Float32(0.9) + Float32(0.2) * smoothstep(0, 0.5, inland))


def hash32(v: UInt32) -> UInt32:
    """lowbias32 (Chris Wellons): a well-mixed 32-bit hash, for where the stars are."""
    var x = v
    x ^= x >> 16
    x *= 0x7FEB352D
    x ^= x >> 15
    x *= 0x846CA68B
    x ^= x >> 16
    return x


def globe(x: Int, y: Int, w: Int, h: Int, k: Knobs8, data: UnsafePointer[UInt32, MutAnyOrigin]) -> UInt32:
    var radius = k[2]
    var u = (Float32(x) + Float32(0.5) - Float32(w) * Float32(0.5)) / radius
    var v = (Float32(h) * Float32(0.5) - Float32(y) - Float32(0.5)) / radius
    var r2 = u * u + v * v
    var layers = Int(k[4])
    var px = k[7] / radius  # one point, in globe radii
    if r2 > Float32(1):  # space: the atmosphere's glow, a few stars
        var out = rgb(4, 6, 14)
        var glow = exp(-(sqrt(r2) - Float32(1)) / Float32(0.035))
        out = out + rgb(70, 140, 255) * (glow * Float32(0.55))
        var hsh = hash32(UInt32(x) * 7919 + UInt32(y) * 104729)  # (32-bit: Apple GPUs emulate 64-bit multiplies)
        if (hsh & 1023) == 0:
            out = out + SIMD[DType.float32, 4](Float32(Int((hsh >> 10) & 255)) * Float32(0.0025))
        return pack(out)
    var z = sqrt(Float32(1) - r2)
    # Back to the world: undo the tilt (latitude k[1]), then the turn (longitude k[0])
    var c1 = cos(k[1])
    var s1 = sin(k[1])
    var wy = v * c1 + z * s1
    var wz = -v * s1 + z * c1
    var lat = atan2(wy, sqrt(u * u + wz * wz))
    var lon = atan2(u, wz) + k[0]
    lon = lon - Float32(2 * pi) * floor((lon + Float32(pi)) / Float32(2 * pi))  # (into one turn: the view's longitude grows as it spins)
    var c0 = cos(k[0])
    var s0 = sin(k[0])
    var n = SIMD[DType.float32, 4](u * c0 + wz * s0, wy, -u * s0 + wz * c0, 0)  # the surface normal, world axes
    var tu = (lon * Float32(DEG) + Float32(180)) * Float32(TW / 360.0)
    var tv = (Float32(90) - lat * Float32(DEG)) * Float32(TH / 180.0)
    var t = texel(data, tu, tv)
    var land = smoothstep(0.42, 0.58, t[0])
    var shallow = Float32(1) - smoothstep(0, 0.35, t[1])
    var ocean = rgb(9, 30, 60) + (rgb(26, 88, 118) - rgb(9, 30, 60)) * (shallow * shallow)
    var c = ocean + (land_colour(lat, t[2]) - ocean) * land
    var day = Float32(1)
    if layers & LAYER_SUN:
        var ndl = (n * sun(k)).reduce_add()
        day = smoothstep(-0.1, 0.12, ndl)
        var lit = c * (Float32(0.3) + Float32(0.85) * max(ndl, Float32(0)))
        var night = c * Float32(0.1) + rgb(4, 8, 22)
        c = night + (lit - night) * day
    else:
        c = c * (Float32(0.62) + Float32(0.42) * z)
    if layers & LAYER_LIGHTS:
        var glow = t[3] * (Float32(1) - day) if layers & LAYER_SUN else t[3] * Float32(0.6)
        c = c + rgb(255, 196, 110) * (glow * Float32(1.6))
    if layers & LAYER_GRID:
        var la = lat * Float32(DEG)
        var lo = lon * Float32(DEG)
        var dla = abs(la - Float32(15) * floor(la / Float32(15) + Float32(0.5)))
        var dlo = abs(lo - Float32(15) * floor(lo / Float32(15) + Float32(0.5)))
        var per = Float32(1.0 / DEG) / px * max(z, Float32(0.08))  # points per degree here (squeezed at the rim)
        var line = max(Float32(1) - smoothstep(0.25, 0.9, dla * per), (Float32(1) - smoothstep(0.25, 0.9, dlo * per * cos(lat))) * smoothstep(0, 0.1, cos(lat)))
        c = c + (rgb(210, 225, 255) - c) * (line * Float32(0.22))
    if layers & LAYER_FLIGHTS:
        var f = flights_at(data, k[3], (lon * Float32(DEG) + Float32(180)) * Float32(4), (Float32(90) - lat * Float32(DEG)) * Float32(4))
        var heat = min(log(Float32(1) + f) * k[5], Float32(1))
        var hot = rgb(40, 190, 255) + (rgb(255, 246, 214) - rgb(40, 190, 255)) * smoothstep(0.55, 1, heat)
        c = c + hot * (smoothstep(0.06, 0.75, heat) * Float32(0.85))
    c = c + rgb(70, 140, 255) * ((Float32(1) - z) * (Float32(1) - z) * (Float32(1) - z) * Float32(0.5))  # the air at the rim
    return pack(c)


# ---------- picking (the CPU's side of the same projection) ----------

def pick_point(px: Float64, py: Float64, w: Float64, h: Float64, k: Knobs8) -> SIMD[DType.float64, 4]:
    """(lon°, lat°, 1, 0) under a point of the picture (same units as w, h, k[2]); (0, 0, 0, 0) off the globe."""
    var radius = Float64(k[2])
    var u = (px - w * 0.5) / radius
    var v = (h * 0.5 - py) / radius
    var r2 = u * u + v * v
    if r2 > 1:
        return SIMD[DType.float64, 4](0)
    var z = sqrt(1.0 - r2)
    var c1 = cos(Float64(k[1]))
    var s1 = sin(Float64(k[1]))
    var wy = v * c1 + z * s1
    var wz = -v * s1 + z * c1
    var lat = atan2(wy, sqrt(u * u + wz * wz)) * DEG
    var lon = (atan2(u, wz) + Float64(k[0])) * DEG
    lon = lon - 360.0 * floor((lon + 180.0) / 360.0)
    return SIMD[DType.float64, 4](lon, lat, 1, 0)


def nearest_city(lon: Float64, lat: Float64) -> Tuple[String, Float64]:
    """The nearest city of 150,000+ people and its distance in km."""
    var cities = materialize[CITIES]()
    var names = materialize[CITY_NAMES]()
    var p = unit(lon, lat)
    var best = -2.0
    var at = 0
    for i in range(len(cities)):
        var d = (p * unit(cities[i][0], cities[i][1])).reduce_add()
        if d > best:
            best = d
            at = i
    return (names[at], 6371.0 * atan2(sqrt(max(1.0 - best * best, 0.0)), best))


def cell_count(data: List[UInt32], lon: Float64, lat: Float64, hour: Float64) -> Int:
    """Reports during UTC hour `hour` in the 9 × 9 cells (2.25°, about 250 km) around (lon, lat)."""
    var col = Int((lon + 180.0) * 4.0)
    var row = Int((90.0 - lat) * 4.0)
    var base = CUBE + (Int(hour) % HOURS) * CW * CH
    var total = 0
    for dy in range(-4, 5):
        var r = row + dy
        if r < 0 or r >= CH:
            continue
        for dx in range(-4, 5):
            total += Int(data[base + r * CW + ((col + dx) % CW + CW) % CW])
    return total
