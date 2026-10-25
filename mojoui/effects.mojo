# mojoui.effects: what an app asks for besides a new screen (goal 33): HTTP requests, sent on worker threads, and timers.
# The Runtime (mojoui.app) takes them after every update and hands their answers back to update() as Events when a host
# polls it (Runtime.poll); hosts ask Runtime.wake_in when to poll next (GTK: a GLib timeout; the web: the server's clock
# thread). Nothing here blocks the caller.
#
# The transport is chosen at build time (D-321): `Backend` below. Adding flare (TLS, HTTP/2–3) is a FlareTransport in its
# own file and one more branch here (-D MOJOUI_FLARE); no app changes (docs/http.md).

from std.atomic import Atomic
from std.ffi import external_call, c_int
from std.memory.alloc import unsafe_alloc
from mojoui.http import Request, Response, Transport
from mojoui.http_socket import SocketTransport

comptime Backend = SocketTransport  # (the only one today: plain HTTP/1.1 over libc sockets)
comptime POLL_US = 4_000  # how often a host looks for finished requests while any are out (µs)

comptime _A = Atomic[Scalar[DType.int64]]
comptime _P = Pointer[Int64, MutUntrackedOrigin]
comptime W_STATE = 0  # 0: running, 1: answered
comptime W_REFS = 1  # owners: the handle and the worker; the last one frees


struct Every(Copyable, Movable):
    """A timer an app wants (App.every): a `msg` event every `ms` milliseconds, while the app keeps listing it."""

    var ms: Int
    var msg: Int

    def __init__(out self, ms: Int, msg: Int):
        self.ms = max(ms, 1)
        self.msg = msg


struct Timer(Copyable, Movable):
    var ms: Int
    var msg: Int
    var start_us: Int  # -1 until the host's next poll starts it
    var count: Int  # ticks delivered

    def __init__(out self, ms: Int, msg: Int):
        self.ms = ms
        self.msg = msg
        self.start_us = -1
        self.count = 0

    def due_us(self) -> Int:
        """When the next tick is due: ticks keep to the start's grid (start + k × ms), so they don't drift."""
        return self.start_us + (self.count + 1) * self.ms * 1000


struct _Slot(Movable):
    var req: Request
    var resp: Response

    def __init__(out self, var req: Request):
        self.req = req^
        self.resp = Response()


def _word(words: Int, k: Int) -> _P:
    return _P(unsafe_from_address=words + 8 * k)


def _release(words: Int, slot: Int):
    if _A.fetch_add(_word(words, W_REFS), -1) == 1:
        var p = Pointer[_Slot, MutUntrackedOrigin](unsafe_from_address=slot)
        _ = p.unsafe_take_pointee()
        p.unsafe_free()
        _P(unsafe_from_address=words).unsafe_free()


def _work[T: Transport](words: Int, slot: Int):
    var p = Pointer[_Slot, MutUntrackedOrigin](unsafe_from_address=slot)
    p[].resp = T.send(p[].req)
    _A.store(_word(words, W_STATE), 1)  # (after the reply is written: the reader sees all of it)
    _release(words, slot)


def _entry[T: Transport](arg: Int) abi("C") -> Int:
    _work[T](arg, Int(_A.load(_word(arg, 2))))
    return 0


struct InFlight(Movable):
    """A request out on its worker thread. Dropping it before the answer leaves the worker to free what it holds."""

    var words: Int
    var slot: Int
    var msg: Int
    var id: Int

    def __init__(out self, words: Int, slot: Int, msg: Int, id: Int):
        self.words = words
        self.slot = slot
        self.msg = msg
        self.id = id

    def ready(self) -> Bool:
        return _A.load(_word(self.words, W_STATE)) == 1

    def response(self) -> Response:
        """The answer (only once ready())."""
        return Pointer[_Slot, MutUntrackedOrigin](unsafe_from_address=self.slot)[].resp.copy()

    def __deinit__(deinit self):
        _release(self.words, self.slot)


def start[T: Transport](var req: Request) -> InFlight:
    """Sends `req` on a thread of its own (detached; it ends with its request). With no thread to be had, it's sent here."""
    var msg = req.msg
    var id = req.id
    var words = unsafe_alloc[Int64](3)
    _A.store(_word(Int(words), W_STATE), 0)
    _A.store(_word(Int(words), W_REFS), 2)
    var slot = unsafe_alloc[_Slot](1)
    slot.unsafe_write(_Slot(req^))
    _A.store(_word(Int(words), 2), Int64(Int(slot)))  # (the worker's one argument is the words)
    var tid = List[Int](length=1, fill=0)  # (a buffer: pthread_create writes the thread's id into it)
    var rc = external_call["pthread_create", c_int](Int(tid.unsafe_ptr()), Int(0), _entry[T], Int(words))
    if rc != 0:
        _work[T](Int(words), Int(slot))
    else:
        _ = external_call["pthread_detach", c_int](tid[0])
    return InFlight(Int(words), Int(slot), msg, id)
