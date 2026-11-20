# mojoui.strokeicon (goal 79): Lucide-style stroke icons drawn natively, at device pixels, from the icon's own geometry
# (mojoui.lucide_nodes: paths, rects, circles, lines in a 24×24 box). Each icon is rasterized once per (name, device
# size, colour, stroke) into straight-alpha pixels and handed to the Painter as an image, so the same picture reaches the
# CPU painter and the GPU renderer. The coverage is the distance to the stroke's centre line (round caps and joins), the
# way a browser strokes an SVG with stroke-linecap/linejoin: round.
#
#   draw_icon(p, "panel-left", x, y, 20, k, ink)          # x, y, size in layer units; k device px per unit

from std.collections import Dict
from std.memory import Pointer
from std.memory.alloc import alloc, Layout
from std.math import sqrt, cos, sin, atan2, pi
from mojoui.lucide_nodes import lucide_node
from mojoui.shared import get_shared, put_shared
from mojoui.scene import Painter

comptime SLOT_ICONS = 231


@fieldwise_init
struct IconImage(Copyable, Movable):
    var w: Int
    var px: List[UInt32]


struct IconCache(Movable):
    var shapes: Dict[String, Int]
    var lines: List[List[Float64]]  # per icon (by shapes' index): segments x0 y0 x1 y1 …, 24-box units
    var images: Dict[String, Int]
    var store: List[IconImage]

    def __init__(out self):
        self.shapes = Dict[String, Int]()
        self.lines = List[List[Float64]]()
        self.images = Dict[String, Int]()
        self.store = List[IconImage]()


def _cache() -> Pointer[IconCache, MutUntrackedOrigin]:
    var have = get_shared(SLOT_ICONS)
    if have != 0:
        return Pointer[IconCache, MutUntrackedOrigin](unsafe_from_address=have)
    var a = alloc(Layout[IconCache].single())
    var p = a^.unsafe_leak()
    p.unsafe_write(IconCache())
    put_shared(SLOT_ICONS, Int(p))
    return Pointer[IconCache, MutUntrackedOrigin](unsafe_from_address=Int(p))


def _num(s: String, mut i: Int) -> Float64:
    """The next number in an SVG path from byte i (skipping separators); i moves past it."""
    var b = s.as_bytes()
    var n = len(b)
    while i < n and (b[i] == 32 or b[i] == 44 or b[i] == 10 or b[i] == 9):
        i += 1
    var start = i
    if i < n and (b[i] == 45 or b[i] == 43):
        i += 1
    var dot = False
    while i < n:
        var c = b[i]
        if c >= 48 and c <= 57:
            i += 1
        elif c == 46 and not dot:
            dot = True
            i += 1
        elif (c == 101 or c == 69) and i + 1 < n:
            i += 1
            if b[i] == 45 or b[i] == 43:
                i += 1
        else:
            break
    var txt = String(s[byte=start:i])
    try:
        return Float64(txt)
    except:
        return 0.0


def _flag(s: String, mut i: Int) -> Float64:
    """An arc flag: a single 0 or 1 that may touch the next number."""
    var b = s.as_bytes()
    while i < len(b) and (b[i] == 32 or b[i] == 44):
        i += 1
    if i < len(b):
        var v = Float64(Int(b[i]) - 48)
        i += 1
        return v
    return 0.0


def _has_num(s: String, i: Int) -> Bool:
    var b = s.as_bytes()
    var j = i
    while j < len(b) and (b[j] == 32 or b[j] == 44):
        j += 1
    if j >= len(b):
        return False
    var c = b[j]
    return (c >= 48 and c <= 57) or c == 45 or c == 46 or c == 43


def _seg(mut out: List[Float64], x0: Float64, y0: Float64, x1: Float64, y1: Float64):
    out.append(x0)
    out.append(y0)
    out.append(x1)
    out.append(y1)


def _cubic(mut out: List[Float64], x0: Float64, y0: Float64, x1: Float64, y1: Float64, x2: Float64, y2: Float64, x3: Float64, y3: Float64):
    var px = x0
    var py = y0
    comptime N = 16
    for k in range(1, N + 1):
        var t = Float64(k) / N
        var u = 1 - t
        var x = u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3
        var y = u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3
        _seg(out, px, py, x, y)
        px = x
        py = y


def _arc(mut out: List[Float64], x0: Float64, y0: Float64, rx_in: Float64, ry_in: Float64, phi_deg: Float64, large: Float64, sweep: Float64,
         x1: Float64, y1: Float64):
    """An SVG elliptical arc (endpoint form) as line segments (SVG 1.1 implementation notes, F.6.5)."""
    if rx_in == 0 or ry_in == 0:
        _seg(out, x0, y0, x1, y1)
        return
    var phi = phi_deg * pi / 180
    var cp = cos(phi)
    var sp = sin(phi)
    var dx = (x0 - x1) / 2
    var dy = (y0 - y1) / 2
    var x1p = cp * dx + sp * dy
    var y1p = -sp * dx + cp * dy
    var rx = abs(rx_in)
    var ry = abs(ry_in)
    var lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1:
        rx *= sqrt(lam)
        ry *= sqrt(lam)
    var num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    var den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    var co = sqrt(max(0.0, num / den)) if den != 0 else 0.0
    if large == sweep:
        co = -co
    var cxp = co * rx * y1p / ry
    var cyp = -co * ry * x1p / rx
    var cx = cp * cxp - sp * cyp + (x0 + x1) / 2
    var cy = sp * cxp + cp * cyp + (y0 + y1) / 2
    var t1 = atan2((y1p - cyp) / ry, (x1p - cxp) / rx)
    var t2 = atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx)
    var dt = t2 - t1
    if sweep == 0 and dt > 0:
        dt -= 2 * pi
    elif sweep == 1 and dt < 0:
        dt += 2 * pi
    var n = max(4, Int(abs(dt) / (pi / 16)) + 1)
    var px = x0
    var py = y0
    for k in range(1, n + 1):
        var t = t1 + dt * Float64(k) / Float64(n)
        var x = cx + rx * cos(t) * cp - ry * sin(t) * sp
        var y = cy + rx * cos(t) * sp + ry * sin(t) * cp
        if k == n:
            x = x1
            y = y1
        _seg(out, px, py, x, y)
        px = x
        py = y


def path_segments(d: String) -> List[Float64]:
    """An SVG path's outline as segments (x0 y0 x1 y1 …)."""
    var out = List[Float64]()
    var b = d.as_bytes()
    var i = 0
    var x = 0.0
    var y = 0.0
    var sx = 0.0
    var sy = 0.0
    var lcx = 0.0  # last control point (S, T)
    var lcy = 0.0
    var cmd = 0
    while i < len(b):
        var c = Int(b[i])
        if (c >= 65 and c <= 90) or (c >= 97 and c <= 122):
            cmd = c
            i += 1
        elif c == 32 or c == 44:
            i += 1
            continue
        var rel = cmd >= 97
        var up = cmd - 32 if rel else cmd
        var ox = x if rel else 0.0
        var oy = y if rel else 0.0
        if up == 90:  # Z
            _seg(out, x, y, sx, sy)
            x = sx
            y = sy
            continue
        if not _has_num(d, i):
            continue
        if up == 77:  # M (then implicit L)
            x = ox + _num(d, i)
            y = oy + _num(d, i)
            sx = x
            sy = y
            cmd = 108 if rel else 76
        elif up == 76:
            var nx = ox + _num(d, i)
            var ny = oy + _num(d, i)
            _seg(out, x, y, nx, ny)
            x = nx
            y = ny
        elif up == 72:
            var nx = ox + _num(d, i)
            _seg(out, x, y, nx, y)
            x = nx
        elif up == 86:
            var ny = oy + _num(d, i)
            _seg(out, x, y, x, ny)
            y = ny
        elif up == 67:
            var x1 = ox + _num(d, i)
            var y1 = oy + _num(d, i)
            var x2 = ox + _num(d, i)
            var y2 = oy + _num(d, i)
            var x3 = ox + _num(d, i)
            var y3 = oy + _num(d, i)
            _cubic(out, x, y, x1, y1, x2, y2, x3, y3)
            lcx = x2
            lcy = y2
            x = x3
            y = y3
        elif up == 83:
            var x1 = 2 * x - lcx
            var y1 = 2 * y - lcy
            var x2 = ox + _num(d, i)
            var y2 = oy + _num(d, i)
            var x3 = ox + _num(d, i)
            var y3 = oy + _num(d, i)
            _cubic(out, x, y, x1, y1, x2, y2, x3, y3)
            lcx = x2
            lcy = y2
            x = x3
            y = y3
        elif up == 81:
            var qx = ox + _num(d, i)
            var qy = oy + _num(d, i)
            var x3 = ox + _num(d, i)
            var y3 = oy + _num(d, i)
            _cubic(out, x, y, x + 2.0 / 3 * (qx - x), y + 2.0 / 3 * (qy - y), x3 + 2.0 / 3 * (qx - x3), y3 + 2.0 / 3 * (qy - y3), x3, y3)
            lcx = qx
            lcy = qy
            x = x3
            y = y3
        elif up == 65:
            var rx = _num(d, i)
            var ry = _num(d, i)
            var rot = _num(d, i)
            var la = _flag(d, i)
            var sw = _flag(d, i)
            var nx = ox + _num(d, i)
            var ny = oy + _num(d, i)
            _arc(out, x, y, rx, ry, rot, la, sw, nx, ny)
            x = nx
            y = ny
        else:
            i += 1
    return out^


def _attr(el: String, key: String) -> Float64:
    var k = " " + key + "="
    var at = el.find(k)
    if at < 0:
        return 0.0
    var i = at + k.byte_length()
    return _num(el, i)


def _attr_text(el: String, key: String) -> String:
    var k = " " + key + "="
    var at = el.find(k)
    if at < 0:
        return ""
    var start = at + k.byte_length()
    if key == "d" or key == "points":  # (values with spaces: up to the next " name=" or the end)
        var rest = String(el[byte=start:])
        var cut = len(rest.as_bytes())
        for other in [" x=", " y=", " fill=", " stroke="]:
            var o = rest.find(other)
            if o >= 0 and o < cut:
                cut = o
        return String(rest[byte=:cut])
    var end = el.find(" ", start)
    return String(el[byte=start:end]) if end >= 0 else String(el[byte=start:])


def icon_segments(name: String) -> List[Float64]:
    """An icon's outline as line segments: a Lucide name, or an icon's own elements in the same form (a name holding
    "=": `path d=M5 3l6 16…|rect x=4 …`, a 24 × 24 box), so an app's own icons go through the same stroker."""
    var out = List[Float64]()
    var spec = name if "=" in name else lucide_node(name)
    for el in spec.split("|"):
        var e = String(el)
        if e.startswith("path "):
            out.extend(path_segments(_attr_text(e, "d")))
        elif e.startswith("line "):
            _seg(out, _attr(e, "x1"), _attr(e, "y1"), _attr(e, "x2"), _attr(e, "y2"))
        elif e.startswith("circle ") or e.startswith("ellipse "):
            var cx = _attr(e, "cx")
            var cy = _attr(e, "cy")
            var rx = _attr(e, "r") if e.startswith("circle ") else _attr(e, "rx")
            var ry = _attr(e, "r") if e.startswith("circle ") else _attr(e, "ry")
            var n = 32
            for k in range(n):
                var a0 = 2 * pi * Float64(k) / Float64(n)
                var a1 = 2 * pi * Float64(k + 1) / Float64(n)
                _seg(out, cx + rx * cos(a0), cy + ry * sin(a0), cx + rx * cos(a1), cy + ry * sin(a1))
        elif e.startswith("rect "):
            var x = _attr(e, "x")
            var y = _attr(e, "y")
            var w = _attr(e, "width")
            var h = _attr(e, "height")
            var r = _attr(e, "rx")
            if r <= 0:
                _seg(out, x, y, x + w, y)
                _seg(out, x + w, y, x + w, y + h)
                _seg(out, x + w, y + h, x, y + h)
                _seg(out, x, y + h, x, y)
            else:
                var d = "M" + String(x + r) + " " + String(y) + "H" + String(x + w - r) + "A" + String(r) + " " + String(r) + " 0 0 1 " + String(x + w) + " " + String(y + r)
                d += "V" + String(y + h - r) + "A" + String(r) + " " + String(r) + " 0 0 1 " + String(x + w - r) + " " + String(y + h)
                d += "H" + String(x + r) + "A" + String(r) + " " + String(r) + " 0 0 1 " + String(x) + " " + String(y + h - r)
                d += "V" + String(y + r) + "A" + String(r) + " " + String(r) + " 0 0 1 " + String(x + r) + " " + String(y) + "Z"
                out.extend(path_segments(d))
        elif e.startswith("polyline ") or e.startswith("polygon "):
            var pts = path_segments("M" + _attr_text(e, "points") + ("Z" if e.startswith("polygon ") else ""))
            out.extend(pts^)
    return out^


def icon_pixels(name: String, size_dev: Int, color: UInt32, stroke: Float64) -> Int:
    """The icon at size_dev × size_dev device px (straight alpha); its index in the cache's store."""
    var c = _cache()
    var key = name + "@" + String(size_dev) + "@" + String(color) + "@" + String(Int(stroke * 100))
    if key in c[].images:
        return c[].images.get(key, 0)
    var si = c[].shapes.get(name, -1)
    if si < 0:
        c[].lines.append(icon_segments(name))
        si = len(c[].lines) - 1
        c[].shapes[name] = si
    var k = Float64(size_dev) / 24.0
    var hw = stroke * k / 2
    var px = List[UInt32](length=size_dev * size_dev, fill=0)
    ref segs = c[].lines[si]
    var n = len(segs) // 4
    var a = Float64(Int((color >> 24) & 0xFF))
    for yy in range(size_dev):
        var cy = (Float64(yy) + 0.5) / k
        for xx in range(size_dev):
            var cx = (Float64(xx) + 0.5) / k
            var best = 1e9
            for s in range(n):
                var x0 = segs[s * 4]
                var y0 = segs[s * 4 + 1]
                var dx = segs[s * 4 + 2] - x0
                var dy = segs[s * 4 + 3] - y0
                var l2 = dx * dx + dy * dy
                var t = 0.0 if l2 == 0 else max(0.0, min(1.0, ((cx - x0) * dx + (cy - y0) * dy) / l2))
                var ex = cx - x0 - t * dx
                var ey = cy - y0 - t * dy
                var d2 = ex * ex + ey * ey
                if d2 < best:
                    best = d2
            var cov = hw + 0.5 - sqrt(best) * k
            if cov > 0:
                var al = Int(min(cov, 1.0) * a + 0.5)
                px[yy * size_dev + xx] = (color & 0x00FFFFFF) | (UInt32(al) << 24)
    c[].store.append(IconImage(size_dev, px^))
    c[].images[key] = len(c[].store) - 1
    return len(c[].store) - 1


def draw_icon[P: Painter](mut p: P, name: String, x: Float64, y: Float64, size: Float64, k: Float64, color: UInt32, stroke: Float64 = 2.0):
    """The icon in a size × size box at (x, y), layer units; k device px per unit (the layer's scale)."""
    var dev = Int(size * k + 0.5)
    if dev <= 0:
        return
    var i = icon_pixels(name, dev, color, stroke)
    var c = _cache()
    # whole device pixels, as the browser places an svg box
    var xd = Float64(Int(x * k + 0.5)) / k
    var yd = Float64(Int(y * k + 0.5)) / k
    p.image(c[].store[i].px, dev, dev, xd, yd, Float64(dev) / k, Float64(dev) / k)
