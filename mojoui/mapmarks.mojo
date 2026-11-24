# mojoui.mapmarks (goal 79, 79-gaps 68): what an idea of a mind map can carry besides its words, read from the document's own
# members (what Personal Note's web map writes: emoji, icons, due, done, vote, image, collapsed, presentation, branch curve,
# anchors and ports), and the geometry that draws it: the branch between two ideas (geometry.js), the pencil's strike
# (pencil.js), the due date's words (due.js), the twelve icons (icons.js). Pure: no drawing here.
#
#   var l = look_of('"done":true,"due":"2026-11-24"')      # an idea's other members, as stored
#   branch_between(parent, child, child_look)               # where its branch runs
#   pencil_outline(x0, x1, y, seed_of(id))                  # a strike through words
#   due_chip("2026-11-24T15:05", now)                       # ("3:05 PM", DUE_TODAY)

from std.ffi import external_call
from std.math import sqrt, tanh, sin, ceil
from mojoui.json import Json


@fieldwise_init
struct Frame(ImplicitlyCopyable, Movable):
    var x: Float64
    var y: Float64
    var hw: Float64
    var hh: Float64
    var pin: Bool  # its words lie on the branch: the branch ends at the idea's point, not at a card's edge

    def __init__(out self, x: Float64, y: Float64, hw: Float64, hh: Float64):
        self.x = x
        self.y = y
        self.hw = hw
        self.hh = hh
        self.pin = False


@fieldwise_init
struct Curve(ImplicitlyCopyable, Movable):
    var sx: Float64
    var sy: Float64
    var ax: Float64
    var ay: Float64
    var bx: Float64
    var by: Float64
    var ex: Float64
    var ey: Float64


struct TopicLook(Copyable, Movable):
    var italic: Bool
    var branch: Bool  # its words along the branch, no card
    var done: Bool
    var collapsed: Bool  # what is under it is hidden
    var image: Bool
    var emoji: String
    var due: String
    var vote: String  # "up" | "down" | ""
    var reason: String
    var icons: List[String]
    var curve: Float64
    var anchors: List[Float64]  # the branch's two own control points as t, n, t, n (empty: computed)
    var source: String  # the sides its branch was drawn from and to ("" none)
    var target: String

    def __init__(out self):
        self.italic = False
        self.branch = False
        self.done = False
        self.collapsed = False
        self.image = False
        self.emoji = ""
        self.due = ""
        self.vote = ""
        self.reason = ""
        self.icons = List[String]()
        self.curve = 78
        self.anchors = List[Float64]()
        self.source = ""
        self.target = ""

    def shown_icons(self) -> List[String]:
        """The icons before the words: a done idea's to-do box is a check, and it has one even without (displayIcons)."""
        if not self.done:
            return self.icons.copy()
        var out = List[String]()
        for n in self.icons:
            var name = String("done") if n == "todo" else n
            if name not in out:
                out.append(name)
        if "done" not in out:
            out.insert(0, "done")
        return out^


def look_of(extra: String) -> TopicLook:
    """An idea's other members (`"k":v,…`) read; anything missing or odd is left as if it weren't there."""
    var l = TopicLook()
    if extra == "":
        return l^
    try:
        var j = Json.parse("{" + extra + "}")
        l.italic = j.flag(j.get(0, "italic"))
        l.branch = j.text(j.get(0, "presentation")) == "branch"
        l.done = j.flag(j.get(0, "done"))
        l.collapsed = j.flag(j.get(0, "collapsed"))
        l.image = j.text(j.get(0, "image")) != ""
        l.emoji = j.text(j.get(0, "emoji"))
        l.due = j.text(j.get(0, "due"))
        l.vote = j.text(j.get(0, "vote"))
        if l.vote != "up" and l.vote != "down":
            l.vote = ""
        l.reason = j.text(j.get(0, "reason"))
        var ic = j.get(0, "icons")
        if ic >= 0:
            for k in range(min(j.size(ic), 3)):
                var name = j.text(j.at(ic, k))
                if icon_path(name) != "":
                    l.icons.append(name)
        l.curve = j.real(j.get(0, "curve"), 78)
        var an = j.get(0, "branchAnchors")
        if an >= 0 and j.size(an) == 2:
            for k in range(2):
                l.anchors.append(j.real(j.get(j.at(an, k), "t"), 0.5))
                l.anchors.append(j.real(j.get(j.at(an, k), "n"), 0))
        var ports = j.get(0, "branchPorts")
        if ports >= 0:
            l.source = j.text(j.get(ports, "source"))
            l.target = j.text(j.get(ports, "target"))
    except:
        pass
    return l^


# ---------------------------------------------------------------- the branch (geometry.js)

def _attach(f: Frame, tx: Float64, ty: Float64, inset: Float64) -> Tuple[Float64, Float64]:
    """Where a ray from the frame's centre toward (tx, ty) leaves its rectangle."""
    if f.pin:
        return (f.x, f.y + 5)
    var dx = tx - f.x
    var dy = ty - f.y
    var length = sqrt(dx * dx + dy * dy)
    if length == 0:
        length = 1
    var t = min(f.hw / (abs(dx) if abs(dx) > 0 else 1e-9), f.hh / (abs(dy) if abs(dy) > 0 else 1e-9))
    var reach = (t * length - min(inset, 0.6 * t * length)) / length
    return (f.x + dx * reach, f.y + dy * reach)


def _smooth(v: Float64, low: Float64, high: Float64) -> Float64:
    var x = min(1.0, max(0.0, (v - low) / (high - low)))
    return x * x * (3 - 2 * x)


def _side(name: String) -> Tuple[Float64, Float64]:
    if name == "top":
        return (0.0, -1.0)
    if name == "right":
        return (1.0, 0.0)
    if name == "bottom":
        return (0.0, 1.0)
    if name == "left":
        return (-1.0, 0.0)
    return (0.0, 0.0)


struct _Port(ImplicitlyCopyable, Movable):
    var x: Float64
    var y: Float64
    var vx: Float64
    var vy: Float64
    var weight: Float64
    var on: Bool

    def __init__(out self, x: Float64, y: Float64):
        self.x = x
        self.y = y
        self.vx = 0
        self.vy = 0
        self.weight = 0
        self.on = False


def _port(f: Frame, name: String, ray: Tuple[Float64, Float64], other: Frame, other_ray: Tuple[Float64, Float64], inset: Float64) -> _Port:
    """A saved side is only a hint: its edge's middle, blended with the computed point by how much it faces the other idea."""
    var out = _Port(ray[0], ray[1])
    var v = _side(name)
    if (v[0] == 0 and v[1] == 0) or f.pin:
        return out
    var dx = other.x - f.x
    var dy = other.y - f.y
    var px = f.x + v[0] * (f.hw - inset)
    var py = f.y + v[1] * (f.hh - inset)
    var cx = other_ray[0] - px
    var cy = other_ray[1] - py
    var chord = sqrt(cx * cx + cy * cy)
    if chord == 0:
        chord = 1
    var d = sqrt(dx * dx + dy * dy)
    if d == 0:
        d = 1
    var w = _smooth((v[0] * dx + v[1] * dy) / d, 0.3, 0.8) * _smooth((cx * v[0] + cy * v[1]) / chord, 0, 0.5)
    out.x = ray[0] + (px - ray[0]) * w
    out.y = ray[1] + (py - ray[1]) * w
    out.vx = v[0]
    out.vy = v[1]
    out.weight = w
    out.on = True
    return out


def branch_between(parent: Frame, child: Frame, curve: Float64 = 78, anchors: List[Float64] = List[Float64](), source: String = "", target: String = "") -> Curve:
    """geometry.js branchGeometry: one bend, both control points on one side of the chord, or the document's own two; saved
    sides pull its ends."""
    var s0 = _attach(parent, child.x, child.y, 30)
    var e0 = _attach(child, parent.x, parent.y, 2)
    var s = _port(parent, source, s0, child, e0, 12)
    var e = _port(child, target, e0, parent, s0, 1)
    var dx = e.x - s.x
    var dy = e.y - s.y
    var length = sqrt(dx * dx + dy * dy)
    if length == 0:
        length = 1
    var cx = dx / length
    var cy = dy / length
    var side = tanh(2.2 * cx) * (0.04 + (curve / 100) * 0.26)
    var free = side
    if s.on:
        var along = max(0.0, cx * s.vx + cy * s.vy)
        var across = -cy * s.vx + cx * s.vy
        if 0.3 * along + side * across < 0:
            side = free + ((-0.3 * along) / across - free) * s.weight
    if e.on:
        var along = min(0.0, cx * e.vx + cy * e.vy)
        var across = -cy * e.vx + cx * e.vy
        if side * across < 0.3 * along:
            side += ((0.3 * along) / across - side) * e.weight
    var t0 = 0.3
    var n0 = side
    var t1 = 0.7
    var n1 = side
    if len(anchors) == 4:
        t0 = anchors[0]
        n0 = anchors[1]
        t1 = anchors[2]
        n1 = anchors[3]
    return Curve(s.x, s.y, s.x + dx * t0 - dy * n0, s.y + dy * t0 + dx * n0, s.x + dx * t1 - dy * n1, s.y + dy * t1 + dx * n1, e.x, e.y)


def curve_mid(g: Curve) -> Tuple[Float64, Float64]:
    return ((g.sx + 3 * g.ax + 3 * g.bx + g.ex) / 8, (g.sy + 3 * g.ay + 3 * g.by + g.ey) / 8)


# ---------------------------------------------------------------- the pencil (pencil.js)

def seed_of(text: String) -> Int:
    """pencil.js seedOf: (hash · 31 + UTF-16 unit) mod 1000 over the characters, from 7."""
    var h = 7
    for cp in text.codepoints():
        var v = Int(cp)
        if v > 0xFFFF:  # (its first UTF-16 unit, as JavaScript's charCodeAt(0) of a whole character)
            v = 0xD800 + ((v - 0x10000) >> 10)
        h = (h * 31 + v) % 1000
    return h


def pencil_outline(x0: Float64, x1: Float64, y: Float64, seed: Int) -> List[Float64]:
    """The outline of a pencil's stroke from x0 to x1: it wobbles, and its width follows an uneven pressure."""
    var count = max(2, Int(ceil((x1 - x0) / 6)))
    var xs = List[Float64]()
    var ys = List[Float64]()
    var ws = List[Float64]()
    for i in range(count + 1):
        xs.append(x0 + (x1 - x0) * Float64(i) / Float64(count))
        ys.append(y + 0.9 * sin(Float64(i) * 0.7 + Float64(seed) * 2) + 0.55 * sin(Float64(i) * 1.9 + Float64(seed)))
        ws.append((1.3 + 1.7 * (0.5 + 0.5 * sin(Float64(i) * 0.31 + Float64(seed)))) * min(1.0, 0.45 + Float64(min(i, count - i)) / 3))
    var out = List[Float64]()
    var back = List[Float64]()
    for i in range(count + 1):
        var b = max(0, i - 1)
        var a = min(count, i + 1)
        var dx = xs[a] - xs[b]
        var dy = ys[a] - ys[b]
        var l = sqrt(dx * dx + dy * dy)
        if l == 0:
            l = 1
        var nx = -dy / l * ws[i] / 2
        var ny = dx / l * ws[i] / 2
        out.append(xs[i] + nx)
        out.append(ys[i] + ny)
        back.append(xs[i] - nx)
        back.append(ys[i] - ny)
    for i in range(count, -1, -1):
        out.append(back[2 * i])
        out.append(back[2 * i + 1])
    return out^


# ---------------------------------------------------------------- the due date (due.js)

comptime DUE_LATER = 0
comptime DUE_TODAY = 1
comptime DUE_OVER = 2


@fieldwise_init
struct DayTime(ImplicitlyCopyable, Movable):
    """A local date and time (a week day 0 Sunday … 6)."""
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int


def local_now() -> DayTime:
    var t = List[Int](length=1, fill=0)
    _ = external_call["time", Int](Int(t.unsafe_ptr()))
    var tm = List[Int32](length=16, fill=0)
    _ = external_call["localtime_r", Int](Int(t.unsafe_ptr()), Int(tm.unsafe_ptr()))
    var d = DayTime(Int(tm[5]) + 1900, Int(tm[4]) + 1, Int(tm[3]), Int(tm[2]), Int(tm[1]))
    _ = t
    _ = tm
    return d


def day_number(y_in: Int, m: Int, d: Int) -> Int:
    """Days since 1970-01-01."""
    var y = y_in - (1 if m <= 2 else 0)
    var era = y // 400
    var yoe = y - era * 400
    var doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _d(b: Span[UInt8, _], at: Int, n: Int) -> Int:
    var v = 0
    for k in range(at, at + n):
        if k >= len(b) or b[k] < 48 or b[k] > 57:
            return -1
        v = v * 10 + Int(b[k]) - 48
    return v


def due_chip(due: String, now: DayTime) -> Tuple[String, Int]:
    """What the pill after the words says ("" when there is none) and how it looks: DUE_LATER, DUE_TODAY, DUE_OVER."""
    var b = due.as_bytes()
    var n = len(b)
    if n != 10 and n != 16:
        return ("", DUE_LATER)
    var y = _d(b, 0, 4)
    var m = _d(b, 5, 2)
    var d = _d(b, 8, 2)
    if y < 0 or m < 1 or m > 12 or d < 1 or b[4] != 45 or b[7] != 45:
        return ("", DUE_LATER)
    var lens: List[Int] = [31, 29 if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if d > lens[m - 1]:
        return ("", DUE_LATER)
    var timed = n == 16
    var hh = 0
    var mm = 0
    if timed:
        hh = _d(b, 11, 2)
        mm = _d(b, 14, 2)
        if b[10] != 84 or b[13] != 58 or hh < 0 or hh > 23 or mm < 0 or mm > 59:
            return ("", DUE_LATER)
    var at = day_number(y, m, d)
    var days = at - day_number(now.year, now.month, now.day)
    var state = DUE_LATER
    if days < 0 or (days == 0 and timed and (hh < now.hour or (hh == now.hour and mm <= now.minute))):
        state = DUE_OVER
    elif days == 0:
        state = DUE_TODAY
    var names: List[String] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    var months: List[String] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    var day = String("")
    if days == 0:
        day = "" if timed else "Today"
    elif days > 0 and days < 7:
        day = names[((at + 4) % 7 + 7) % 7]
    else:
        day = months[m - 1] + " " + String(d)
    if timed:
        var clock = String(hh % 12 if hh % 12 != 0 else 12) + ":" + ("0" if mm < 10 else "") + String(mm) + (" AM" if hh < 12 else " PM")
        day = day + " " + clock if day != "" else clock
    return (day, state)


# ---------------------------------------------------------------- the twelve icons (Lucide paths, ISC)

def icon_path(name: String) -> String:
    """One of the twelve as a stroke icon's spec (mojoui.strokeicon), "" for another name."""
    var d = String("")
    if name == "todo":
        d = "M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z"
    elif name == "done":
        d = "M2 12a10 10 0 1 0 20 0a10 10 0 1 0-20 0M9 12l2 2 4-4"
    elif name == "flag":
        d = "M4 22V4a1 1 0 0 1 .4-.8A6 6 0 0 1 8 2c3 0 5 2 7.333 2q2 0 3.067-.8A1 1 0 0 1 20 4v10a1 1 0 0 1-.4.8A6 6 0 0 1 16 16c-3 0-5-2-8-2a6 6 0 0 0-4 1.528"
    elif name == "star":
        d = "M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166.756a.53.53 0 0 1 .294.904l-3.736 3.638a2.123 2.123 0 0 0-.611 1.878l.882 5.14a.53.53 0 0 1-.771.56l-4.618-2.428a2.122 2.122 0 0 0-1.973 0L6.396 21.01a.53.53 0 0 1-.77-.56l.881-5.139a2.122 2.122 0 0 0-.611-1.879L2.16 9.795a.53.53 0 0 1 .294-.906l5.165-.755a2.122 2.122 0 0 0 1.597-1.16z"
    elif name == "alert":
        d = "m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3M12 9v4M12 17h.01"
    elif name == "question":
        d = "M2 12a10 10 0 1 0 20 0a10 10 0 1 0-20 0M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3M12 17h.01"
    elif name == "clock":
        d = "M2 12a10 10 0 1 0 20 0a10 10 0 1 0-20 0M12 6v6l4 2"
    elif name == "idea":
        d = "M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5M9 18h6M10 22h4"
    elif name == "heart":
        d = "M2 9.5a5.5 5.5 0 0 1 9.591-3.676.56.56 0 0 0 .818 0A5.49 5.49 0 0 1 22 9.5c0 2.29-1.5 4-3 5.5l-5.492 5.313a2 2 0 0 1-3 .019L5 15c-1.5-1.5-3-3.2-3-5.5"
    elif name == "pin":
        d = "M12 17v5M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z"
    elif name == "fire":
        d = "M12 3q1 4 4 6.5t3 5.5a1 1 0 0 1-14 0 5 5 0 0 1 1-3 1 1 0 0 0 5 0c0-2-1.5-3-1.5-5q0-2 2.5-4"
    elif name == "x":
        d = "M18 6 6 18M6 6l12 12"
    return "path d=" + d if d != "" else String("")
