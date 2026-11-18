# mojoui.geometry: where a tagged view is on screen, asked from the app (a driver that watches the screen needs to
# know where to look, a tour needs to point at something).
#
#   var r = rect_of("kpis")      # [x, y, w, h] in window points (the window's own coordinates), or [] if unknown
#
# Hosts that can answer register a lookup at start (GTK today: gtk_widget_compute_bounds against the window). Ask on
# the UI thread, after the view has been laid out (e.g. in draw(), or once its first frame is up); the answer is the
# view as it's placed now.

from std.memory import Pointer
from mojoui.shared import put_shared, get_shared

comptime SLOT_RECT_FN = 92  # mojoui.shared: the host's lookup function, and its host
comptime SLOT_RECT_HOST = 93
comptime RectFn = def(Int, Int, Int, Int) thin abi("C") -> Int  # (host, tag address, tag bytes, 4 float64s out) → 1 if found


def register_rects(fn_addr: Int, host_addr: Int):
    """A host says it can answer rect_of (its lookup's address, and the host it answers for)."""
    put_shared(SLOT_RECT_FN, fn_addr)
    put_shared(SLOT_RECT_HOST, host_addr)


def rect_of(tag: String) -> List[Float64]:
    """The tagged view's [x, y, width, height] in window points, or [] (no such view on screen, or a host that can't say)."""
    var f = get_shared(SLOT_RECT_FN)
    if f == 0:
        return List[Float64]()
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=f)
    var call = Pointer(to=raw).unsafe_bitcast[RectFn]()[]
    var out = List[Float64](length=4, fill=0)
    var t = tag
    var ok = call(get_shared(SLOT_RECT_HOST), Int(t.unsafe_ptr()), t.byte_length(), Int(out.unsafe_ptr()))
    _ = t.byte_length()
    if ok != 1:
        return List[Float64]()
    return out^


# ---------------------------------------------------------------------------------------------------------------------
# spots: things drawn inside a canvas that move while it draws (a map's markers as it flies), found by a tag of their own
# (goal 77 M3). The canvas says where each one is now, in points from its own corner, every time it draws; spot_of turns that
# into window points through the canvas's own rect, so a pointer's ring can follow a marker the way it follows a view.
#
#   put_spot("card3.stop2", "card3.map0", x, y, w, h)     # in draw(): the canvas tagged card3.map0 shows stop 2 there now
#   var r = spot_of("card3.stop2")                         # [x, y, w, h] in window points, inside the canvas; [] unknown
# ---------------------------------------------------------------------------------------------------------------------

from std.memory.alloc import alloc, Layout

comptime SLOT_SPOTS = 182  # mojoui.shared slot: the process's spots (180, 181: mojoui.tiles and mojoui.geocode)


struct _Spots(Movable):
    var tags: List[String]
    var insides: List[String]
    var rects: List[Float64]  # four per spot

    def __init__(out self):
        self.tags = List[String]()
        self.insides = List[String]()
        self.rects = List[Float64]()


def _spots() -> Pointer[_Spots, MutUntrackedOrigin]:
    var have = get_shared(SLOT_SPOTS)
    if have == 0:
        var p = alloc(Layout[_Spots].single()).unsafe_leak()
        p.unsafe_write(_Spots())
        have = Int(p)
        put_shared(SLOT_SPOTS, have)
    return Pointer[_Spots, MutUntrackedOrigin](unsafe_from_address=have)


def put_spot(tag: String, inside: String, x: Float64, y: Float64, w: Float64, h: Float64):
    """Where the thing tagged `tag` is drawn now: (x, y, w, h) in points from the corner of the canvas tagged `inside`."""
    var s = _spots()
    for i in range(len(s[].tags)):
        if s[].tags[i] == tag:
            s[].insides[i] = inside
            s[].rects[4 * i] = x
            s[].rects[4 * i + 1] = y
            s[].rects[4 * i + 2] = w
            s[].rects[4 * i + 3] = h
            return
    s[].tags.append(tag)
    s[].insides.append(inside)
    s[].rects.append(x)
    s[].rects.append(y)
    s[].rects.append(w)
    s[].rects.append(h)


def spot_of(tag: String) -> List[Float64]:
    """The spot's [x, y, w, h] in window points, kept inside its canvas (a marker flying in from beyond the edge is shown at the
    edge); [] when there's no such spot or its canvas isn't on screen."""
    var s = _spots()
    for i in range(len(s[].tags)):
        if s[].tags[i] != tag:
            continue
        var box = rect_of(s[].insides[i])
        if len(box) < 4 or box[2] <= 0 or box[3] <= 0:
            return List[Float64]()
        var w = min(s[].rects[4 * i + 2], box[2])
        var h = min(s[].rects[4 * i + 3], box[3])
        var x = min(max(s[].rects[4 * i], 0.0), box[2] - w)
        var y = min(max(s[].rects[4 * i + 1], 0.0), box[3] - h)
        return [box[0] + x, box[1] + y, w, h]
    return List[Float64]()
