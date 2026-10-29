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
