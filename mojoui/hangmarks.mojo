# What the UI thread is doing, written down as it does it (goal 81, M5): a few words of shared memory that a watcher
# thread reads (mojoui.hosts.hangwatch) to say what hangs while it hangs. Plain memory writes and one clock read a mark:
# no lock, no call into the system, nothing at all when the address is 0 (no watcher: web, Android, iPhone, tests).
# Only numbers are kept: what kind of work and its message or canvas number. Never an app's words.
from std.atomic import Atomic
from std.memory import Pointer
from mojoui.clock import now_ns

comptime _A = Atomic[Scalar[DType.int64]]

comptime M_BUSY = 0  # 1: the main loop runs something; 0: it waits for input
comptime M_SINCE = 1  # when this turn of it began
comptime M_TURN = 2  # turns begun
comptime M_DEPTH = 3  # marks open now
comptime M_OPEN = 4  # 8 open marks: what, number, when
comptime M_LONG_NS = 28  # the longest mark closed in this turn
comptime M_LONG_WHAT = 29
comptime M_LONG_NUMBER = 30
comptime M_END_NS = 31  # a turn that took too long has ended: how long, and its longest mark (0: none to say)
comptime M_END_WHAT = 32
comptime M_END_NUMBER = 33
comptime M_END_LONG = 34
comptime M_ASLEEP = 35  # the watcher waits on its pipe
comptime M_PIPE = 36  # its write end + 1
comptime M_ARMED = 37  # turns ended (the first, start-up, isn't watched)
comptime M_LIMIT = 38  # ns
comptime M_RING_AT = 39
comptime M_RING = 40  # the last 8 marks closed: what, number, ns
comptime M_WORDS = 64

comptime MARK_UPDATE = 1
comptime MARK_VIEW = 2
comptime MARK_DRAW = 3
comptime MARK_BUILD = 4
comptime MARK_PART = 5
comptime MARK_PATCH = 6
comptime MARK_FRAME = 7


def mark_name(what: Int, number: Int) -> String:
    if what == MARK_UPDATE:
        return "update msg=" + String(number)
    if what == MARK_VIEW:
        return "view and compare"
    if what == MARK_DRAW:
        return "draw canvas=" + String(number)
    if what == MARK_BUILD:
        return "building the window (" + String(number) + " views)"
    if what == MARK_PART:
        return "building the parts that changed (" + String(number) + " views)"
    if what == MARK_PATCH:
        return "changing widgets (" + String(number) + " patches)"
    if what == MARK_FRAME:
        return "a frame of canvas=" + String(number)
    return "the main loop (the system, or the app's own callback)"


def word(addr: Int, k: Int) -> Pointer[Scalar[DType.int64], MutUntrackedOrigin]:
    return Pointer[Scalar[DType.int64], MutUntrackedOrigin](unsafe_from_address=addr + 8 * k)


def read(addr: Int, k: Int) -> Int:
    return Int(_A.load(word(addr, k)))


def put(addr: Int, k: Int, v: Int):
    _A.store(word(addr, k), Int64(v))


@always_inline
def begin(addr: Int, what: Int, number: Int = 0):
    if addr == 0:
        return
    var d = read(addr, M_DEPTH)
    if 0 <= d < 8:
        put(addr, M_OPEN + 3 * d, what)
        put(addr, M_OPEN + 3 * d + 1, number)
        put(addr, M_OPEN + 3 * d + 2, now_ns())
    put(addr, M_DEPTH, d + 1)


@always_inline
def end(addr: Int):
    if addr == 0:
        return
    var d = read(addr, M_DEPTH) - 1
    if d < 0:
        return  # (a nested main loop ended the turn this mark began in)
    put(addr, M_DEPTH, d)
    if d >= 8:
        return
    var what = read(addr, M_OPEN + 3 * d)
    var number = read(addr, M_OPEN + 3 * d + 1)
    var took = now_ns() - read(addr, M_OPEN + 3 * d + 2)
    if took > read(addr, M_LONG_NS):
        put(addr, M_LONG_WHAT, what)
        put(addr, M_LONG_NUMBER, number)
        put(addr, M_LONG_NS, took)
    var at = read(addr, M_RING_AT)
    put(addr, M_RING + 3 * at, what)
    put(addr, M_RING + 3 * at + 1, number)
    put(addr, M_RING + 3 * at + 2, took)
    put(addr, M_RING_AT, (at + 1) % 8)


def turn_begins(addr: Int):
    """The main loop woke: something (an event, a timer, a frame) is about to run."""
    if addr == 0:
        return
    put(addr, M_SINCE, now_ns())
    put(addr, M_LONG_NS, 0)
    put(addr, M_DEPTH, 0)
    put(addr, M_TURN, read(addr, M_TURN) + 1)
    put(addr, M_BUSY, 1)


def turn_ends(addr: Int):
    """The main loop is about to wait. A turn over the limit is handed to the watcher."""
    if addr == 0 or read(addr, M_BUSY) == 0:
        return
    put(addr, M_BUSY, 0)
    put(addr, M_DEPTH, 0)
    var took = now_ns() - read(addr, M_SINCE)
    if took > read(addr, M_LIMIT) and read(addr, M_ARMED) > 0:
        put(addr, M_END_WHAT, read(addr, M_LONG_WHAT) if read(addr, M_LONG_NS) > 0 else 0)
        put(addr, M_END_NUMBER, read(addr, M_LONG_NUMBER))
        put(addr, M_END_LONG, read(addr, M_LONG_NS))
        put(addr, M_END_NS, took)
    put(addr, M_ARMED, read(addr, M_ARMED) + 1)
