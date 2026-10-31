# mojoui.framefeed: FrameFeed, a video (or a still) decoded on a thread of its own (goal 41 M2), so opening, seeking and
# decoding never run on the UI thread (docs/ui-threads.md, rules 1–2). A generic component: the Player, the editor's
# viewer and a picture card are built on it.
#
#   var feed = FrameFeed(path)                 # returns at once; ffprobe runs on the feed's thread (FrameFeed(info): none)
#   feed.info()                                # VideoInfo: zeros until the probe lands (feed.ready()); feed.problem() says why not
#   feed.want(frame)                           # returns at once; the latest wins (a burst of scrubs decodes only the last)
#   if feed.take(buf): …                       # swaps the newest decoded frame into buf (no copy); buf's frame: feed.frame_of_take
#   feed.pending()                             # the frame wanted hasn't landed yet (a canvas then asks for display frames)
#
# How: one thread per feed, started by pthread_create and detached. It probes (VideoSource(path)), then waits on a
# condition variable until a frame is wanted, decodes it (reading on when it's just ahead, restarting ffmpeg at the
# time otherwise, mojoui.video), and swaps the finished buffer with the shown one under a mutex: the UI thread only ever
# takes the lock to set a number or swap two lists. Between frames it checks whether a newer frame is wanted and starts
# over from there. When a frame lands it wakes the host's main loop (the job-wake pipe, mojoui.wake): App.jobs_message()
# reaches update(), or the canvas's own display frames find it. Dropping the feed tells the thread to stop; the last of
# the two (the handle, the thread) frees what they share. Nothing else crosses threads.

from std.ffi import external_call, c_int
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.time import sleep
from mojoui.video import VideoSource, VideoInfo, file_exists
from mojoui.wake import wake_write_fd, wake_write

comptime FAR_AHEAD = 12  # a frame this far ahead of the decoder is reached by reading on; further, by seeking
comptime _OPENING = 0
comptime _READY = 1
comptime _FAILED = 2
comptime _SYNC_BYTES = 128  # room for a pthread_mutex_t or pthread_cond_t on Linux and macOS (40/48 and 64/48 bytes)


struct _Shared(Movable):
    """What the feed's handle and its thread share: every field is read and written under `lock`."""

    var path: String
    var info: VideoInfo
    var known: Bool  # info came with the feed: the thread doesn't probe
    var once: Bool  # a still: the thread ends after its first frame
    var state: Int
    var error: String
    var want: Int  # the frame wanted (-1: none yet)
    var done: Int  # the want the thread last finished (landed, or failed to read)
    var front: List[UInt32]  # the newest decoded frame, for take()
    var front_frame: Int  # its frame (-1: none)
    var published: Int  # frames swapped into front so far (each decode that landed)
    var taken: Int  # `published` at the last take()
    var quit: Bool
    var refs: Int  # owners: the handle and the thread; the last frees
    var wake_fd: Int
    var lock: Int  # a pthread_mutex_t's address
    var cond: Int  # a pthread_cond_t's address

    def __init__(out self, info: VideoInfo, known: Bool, once: Bool, wake_fd: Int):
        self.path = info.path
        self.info = info
        self.known = known
        self.once = once
        self.state = _OPENING
        self.error = ""
        self.want = -1
        self.done = -1
        self.front = List[UInt32]()
        self.front_frame = -1
        self.published = 0
        self.taken = 0
        self.quit = False
        self.refs = 2
        self.wake_fd = wake_fd
        self.lock = Int(unsafe_alloc[UInt8](_SYNC_BYTES))
        self.cond = Int(unsafe_alloc[UInt8](_SYNC_BYTES))
        _ = external_call["pthread_mutex_init", c_int](self.lock, 0)
        _ = external_call["pthread_cond_init", c_int](self.cond, 0)


def _at(addr: Int) -> Pointer[_Shared, MutUntrackedOrigin]:
    return Pointer[_Shared, MutUntrackedOrigin](unsafe_from_address=addr)


def _lock(addr: Int):
    _ = external_call["pthread_mutex_lock", c_int](_at(addr)[].lock)


def _unlock(addr: Int):
    _ = external_call["pthread_mutex_unlock", c_int](_at(addr)[].lock)


def _release(addr: Int):
    """One owner lets go; the last frees the shared state (its mutex and condition too)."""
    _lock(addr)
    _at(addr)[].refs -= 1
    var last = _at(addr)[].refs == 0
    _unlock(addr)
    if not last:
        return
    var lock = _at(addr)[].lock
    var cond = _at(addr)[].cond
    _ = external_call["pthread_cond_destroy", c_int](cond)
    _ = external_call["pthread_mutex_destroy", c_int](lock)
    Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=lock).unsafe_free()
    Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=cond).unsafe_free()
    var p = _at(addr)
    _ = p.unsafe_take_pointee()
    p.unsafe_free()


def _wanted(addr: Int) -> Int:
    _lock(addr)
    var w = _at(addr)[].want
    var q = _at(addr)[].quit
    _unlock(addr)
    return -2 if q else w


def _decode(mut src: VideoSource, target: Int, mut back: List[UInt32], addr: Int) -> Int:
    """Decodes frame `target` into back: 1 landed, 0 couldn't be read, -1 a newer frame is wanted (start over)."""
    try:
        var at = src.position()
        if not (at <= target <= at + FAR_AHEAD):
            src.seek_frame(target)
        while src.position() < target:
            if _wanted(addr) != target:
                return -1
            if not src.next_into(back):
                return 0
        if _wanted(addr) != target:  # (a seek's restart took a while: a newer frame may be wanted already)
            return -1
        return 1 if src.next_into(back) else 0
    except:
        return 0


def _feed_main(addr: Int) abi("C") -> Int:
    """The feed's thread: probe, then decode whatever is wanted, newest first, until told to stop."""
    var s = _at(addr)
    var info = s[].info  # (written before the thread started)
    var known = s[].known
    var once = s[].once
    var fd = s[].wake_fd  # (the process's one wake pipe, mojoui.jobs.wake_pipe: made once, never closed, so the fd read
    # at the start stays valid for the thread's whole life: no generation check needed, D-1343)
    var src: VideoSource
    try:
        src = VideoSource(info) if known else VideoSource(info.path)
    except e:
        _lock(addr)
        s[].state = _FAILED
        s[].error = String(e)
        _unlock(addr)
        wake_write(fd)
        _release(addr)
        return 0
    _lock(addr)
    s[].info = src.info()
    s[].state = _READY
    _unlock(addr)
    wake_write(fd)
    var back = List[UInt32]()
    while True:
        _lock(addr)
        while not s[].quit and (s[].want < 0 or s[].want == s[].done):
            _ = external_call["pthread_cond_wait", c_int](s[].cond, s[].lock)
        if s[].quit:
            _unlock(addr)
            break
        var target = s[].want
        _unlock(addr)
        var got = _decode(src, target, back, addr)
        if got < 0:
            continue
        _lock(addr)
        if got == 1:
            swap(s[].front, back)
            s[].front_frame = target
            s[].published += 1
        elif once:  # (a still that can't be decoded: the feed fails, saying why, and its card shows it: problem())
            s[].state = _FAILED
            s[].error = "Couldn't decode " + info.path + (" (frame " + String(target) + ")" if target > 0 else "")
        s[].done = target
        _unlock(addr)
        wake_write(fd)  # (landed or not: the host looks again, so nothing waits on a frame that won't come)
        if once:
            break
    src.close()
    _release(addr)
    return 0


struct FrameFeed(Movable):
    """A video's frames decoded on a thread of its own; every call returns at once (see the file's header)."""

    var addr: Int  # the shared state (0: a feed that couldn't start: it reports why)
    var why: String  # why it couldn't start
    var frame_of_take: Int  # the frame the last successful take() swapped in

    def __init__(out self, path: String, once: Bool = False) raises:
        """Opens `path` off the UI thread (ffprobe on the feed's thread). Raises only when the file isn't there (one
        fopen); "not a video" arrives later, as problem(). once: a still, the thread ends after its first frame."""
        if not file_exists(path):
            raise Error("No such file: " + path)
        self.addr = 0
        self.why = ""
        self.frame_of_take = -1
        self._start(VideoInfo.unknown(path), False, once)

    def __init__(out self, info: VideoInfo, once: Bool = False):
        """A feed for a video already probed (another feed's info()): no ffprobe, ready at once."""
        self.addr = 0
        self.why = ""
        self.frame_of_take = -1
        self._start(info, info.known(), once)

    def _start(mut self, info: VideoInfo, known: Bool, once: Bool):
        var p = unsafe_alloc[_Shared](1)
        p.unsafe_write(_Shared(info, known, once, wake_write_fd()))
        if known:
            p[].state = _READY  # (the handle's view: ready at once; the thread opens its decoder without probing)
        self.addr = Int(p)
        # (declared as omxcore's jobs declare it: one C function has one signature in a program)
        var tid = Int(0)
        var attr = unsafe_alloc[UInt8](256)
        for i in range(256):
            attr[i] = 0
        _ = external_call["pthread_attr_init", c_int](attr)
        var rc = external_call["pthread_create", c_int](Pointer(to=tid), attr, _feed_main, self.addr)
        _ = external_call["pthread_attr_destroy", c_int](attr)
        attr.free()
        if rc != 0:
            self.why = "no thread to decode on"
            _release(self.addr)  # (the thread's share)
            _release(self.addr)
            self.addr = 0
        else:
            _ = external_call["pthread_detach", c_int](tid)

    def __deinit__(deinit self):
        if self.addr != 0:
            _lock(self.addr)
            _at(self.addr)[].quit = True
            _ = external_call["pthread_cond_signal", c_int](_at(self.addr)[].cond)
            _unlock(self.addr)
            _release(self.addr)

    def ready(self) -> Bool:
        """The probe has landed: info() holds the video's size, rate and length."""
        if self.addr == 0:
            return False
        _lock(self.addr)
        var r = _at(self.addr)[].state == _READY
        _unlock(self.addr)
        return r

    def problem(self) -> String:
        """Why the file can't be shown ("" while opening or once ready)."""
        if self.addr == 0:
            return self.why
        _lock(self.addr)
        var e = _at(self.addr)[].error if _at(self.addr)[].state == _FAILED else String("")
        _unlock(self.addr)
        return e

    def info(self) -> VideoInfo:
        if self.addr == 0:
            return VideoInfo.unknown("")
        _lock(self.addr)
        var i = _at(self.addr)[].info
        _unlock(self.addr)
        return i

    def want(self, frame: Int):
        """Asks for frame `frame` (0-based); returns at once. The newest want wins: frames asked for before it and not
        started yet are never decoded."""
        if self.addr == 0:
            return
        _lock(self.addr)
        if _at(self.addr)[].want != frame:
            _at(self.addr)[].want = frame
            _ = external_call["pthread_cond_signal", c_int](_at(self.addr)[].cond)
        _unlock(self.addr)

    def take(mut self, mut buf: List[UInt32]) -> Bool:
        """When a frame landed since the last take: swaps it into `buf` (the feed keeps buf's old pixels to decode into)
        and returns True; frame_of_take says which frame it is."""
        if self.addr == 0:
            return False
        var got = False
        _lock(self.addr)
        ref s = _at(self.addr)[]
        if s.published != s.taken and s.front_frame >= 0:
            swap(s.front, buf)
            self.frame_of_take = s.front_frame
            s.taken = s.published
            got = True
        _unlock(self.addr)
        return got

    def pending(self) -> Bool:
        """Still opening, or the frame wanted hasn't been decoded yet (false once it failed)."""
        if self.addr == 0:
            return False
        _lock(self.addr)
        ref s = _at(self.addr)[]
        var p = s.state == _OPENING or (s.state == _READY and s.want >= 0 and (s.want != s.done or s.published != s.taken))
        _unlock(self.addr)
        return p

    def decoding(self) -> Bool:
        """Still opening, or the thread hasn't finished the frame wanted (taken or not)."""
        if self.addr == 0:
            return False
        _lock(self.addr)
        ref s = _at(self.addr)[]
        var p = s.state == _OPENING or (s.state == _READY and s.want >= 0 and s.want != s.done)
        _unlock(self.addr)
        return p

    def decoded(self) -> Int:
        """How many frames the thread has finished decoding so far (a burst of wants collapses: fewer than asked)."""
        if self.addr == 0:
            return 0
        _lock(self.addr)
        var n = _at(self.addr)[].published
        _unlock(self.addr)
        return n

    def wait(self, seconds: Float64 = 10.0) -> Bool:
        """Blocks until nothing is pending (tests, an agent's render, an export's first frame: never the UI thread's
        update or draw); False when it timed out."""
        var waited = 0.0
        while self.decoding():
            if waited >= seconds:
                return False
            sleep(0.001)
            waited += 0.001
        return True
