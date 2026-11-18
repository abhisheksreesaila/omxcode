# mojoui.webcamera: the web host's camera hub (goal 77 M6, D-7765). On the web host the app runs inside the Python server and
# its Camera (mojoui.camera) looks through a browser's camera instead of one on this machine: the same Mojo calls, a different
# end. The page opens its rear camera only while an app wants it, and sends a still only when asked (a snapshot), on the
# audio socket's reserved tag 3 (docs/web-audio.md); nothing is a stream, and nothing leaves this machine.
#
#   camera_init()                          once per server process: the hub's memory (0: it was there already)
#   -- the host's side (hosts/web.py, one call each way) --
#   camera_wants()                         1 while an app wants the camera (the page opens or closes it)
#   camera_request()                       the id of the newest snapshot an app asked for (the host tells the page when it grows)
#   camera_push(addr, bytes, id, w, h)     the page's still: a JPEG, the request it answers, its pixel size
#   camera_fail(code)                      the page couldn't open a camera (101 refused, 102 none found, 103 not allowed here)
#   -- the app's side (mojoui.camera) --
#   camera_want(on) / camera_snap() / camera_got() / camera_take(dst, cap) / camera_error() / camera_hub()
#
# The frame is kept in one of two buffers and the newest one's number is published last, so a reader that copies while a new
# frame lands notices (the number changed) and copies again. A frame over CAM_CAP bytes is dropped.

from std.atomic import Atomic
from std.memory.alloc import unsafe_alloc
from mojoui.shared import get_shared, put_shared
from mojoui.clock import now_ns

comptime SLOT_WEB_CAMERA = 186  # mojoui.shared slot (89 is the audio hub's; 90 and 91 the wake pipe's, 87-99 and 197 are taken)
comptime CAM_CAP = 4_194_304  # the largest JPEG kept

comptime C_WANT = 0
comptime C_REQ = 1
comptime C_GOT = 2
comptime C_LATEST = 3
comptime C_ERR = 4
comptime C_FRAMES = 5
comptime C_NS = 6
comptime C_SLOT = 8  # per buffer: length, width, height, address
comptime C_WORDS = 16

comptime _A = Atomic[Scalar[DType.int64]]


def _word(base: Int, k: Int) -> Pointer[Scalar[DType.int64], MutUntrackedOrigin]:
    return Pointer[Scalar[DType.int64], MutUntrackedOrigin](unsafe_from_address=base + 8 * k)


def camera_hub() -> Int:
    return get_shared(SLOT_WEB_CAMERA)


def camera_init() -> Int:
    """The hub's memory, once per process (the web host calls it before any session). 0 when it was there already."""
    if camera_hub() != 0:
        return 0
    var words = unsafe_alloc[Int64](C_WORDS)
    for k in range(C_WORDS):
        _A.store(_word(Int(words), k), 0)
    for s in range(2):
        _A.store(_word(Int(words), C_SLOT + 4 * s + 3), Int64(Int(unsafe_alloc[UInt8](CAM_CAP))))  # (never freed: the process owns it)
    put_shared(SLOT_WEB_CAMERA, Int(words))
    return Int(words)


def camera_wants() -> Int:
    var h = camera_hub()
    return Int(_A.load(_word(h, C_WANT))) if h != 0 else 0


def camera_request() -> Int:
    var h = camera_hub()
    return Int(_A.load(_word(h, C_REQ))) if h != 0 else 0


def camera_fail(code: Int):
    var h = camera_hub()
    if h != 0:
        _A.store(_word(h, C_ERR), Int64(code))


def camera_push(addr: Int, nbytes: Int, id: Int, width: Int, height: Int):
    """The page's still, as it arrives: kept as the newest frame, answering request `id`."""
    var h = camera_hub()
    if h == 0 or nbytes < 4 or nbytes > CAM_CAP:
        return
    var next = 1 - Int(_A.load(_word(h, C_LATEST)))
    var slot = h + 8 * (C_SLOT + 4 * next)
    var dst = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(_A.load(_word(slot, 3))))
    var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
    for i in range(nbytes):
        dst[i] = src[i]
    _A.store(_word(slot, 0), Int64(nbytes))
    _A.store(_word(slot, 1), Int64(width))
    _A.store(_word(slot, 2), Int64(height))
    _A.store(_word(h, C_LATEST), Int64(next))
    _A.store(_word(h, C_NS), Int64(now_ns()))
    _ = _A.fetch_add(_word(h, C_FRAMES), 1)
    _A.store(_word(h, C_ERR), 0)
    _A.store(_word(h, C_GOT), Int64(id))  # (last: the number that says a frame is there)


# --- the app's side ---------------------------------------------------------------------------------------------------


def camera_want(on: Bool):
    var h = camera_hub()
    if h != 0:
        _A.store(_word(h, C_WANT), Int64(1 if on else 0))


def camera_snap() -> Int:
    """Asks the page for a still now; returns the request's id (camera_got() reaches it when the frame has landed)."""
    var h = camera_hub()
    return Int(_A.fetch_add(_word(h, C_REQ), 1)) + 1 if h != 0 else 0


def camera_got() -> Int:
    var h = camera_hub()
    return Int(_A.load(_word(h, C_GOT))) if h != 0 else 0


def camera_error() -> Int:
    var h = camera_hub()
    return Int(_A.load(_word(h, C_ERR))) if h != 0 else 0


def camera_frames() -> Int:
    var h = camera_hub()
    return Int(_A.load(_word(h, C_FRAMES))) if h != 0 else 0


def camera_arrived_ns() -> Int:
    var h = camera_hub()
    return Int(_A.load(_word(h, C_NS))) if h != 0 else 0


def camera_take(mut out: List[UInt8]) -> Tuple[Int, Int, Int]:
    """Copies the newest frame into `out` (a JPEG); (id, width, height), or (0, 0, 0) when there is none."""
    var h = camera_hub()
    if h == 0:
        return (0, 0, 0)
    while True:
        var id = Int(_A.load(_word(h, C_GOT)))
        var slot = h + 8 * (C_SLOT + 4 * Int(_A.load(_word(h, C_LATEST))))
        var n = Int(_A.load(_word(slot, 0)))
        if id == 0 or n <= 0:
            return (0, 0, 0)
        var w = Int(_A.load(_word(slot, 1)))
        var ht = Int(_A.load(_word(slot, 2)))
        out.clear()
        out.resize(n, 0)
        var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(_A.load(_word(slot, 3))))
        for i in range(n):
            out[i] = src[i]
        if Int(_A.load(_word(h, C_GOT))) == id:  # (no new frame landed during the copy)
            return (id, w, ht)
