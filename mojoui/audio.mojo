# mojoui.audio: the microphone (goal 43 M0). 16 kHz mono float samples from the system's sound server, captured on a
# thread of its own into a ring buffer; the caller (the UI thread) only ever reads what has arrived, so it never waits.
#
#   var mic = Microphone()                       # source: $MOJOUI_AUDIO_SOURCE if set, else the default input
#   mic.start()                                  # returns at once; capture runs on its own thread
#   var got = mic.read(since)                    # the samples since `since` (an absolute sample count) -> List[Float32]
#   mic.total(); mic.level(); mic.running(); mic.failed(); mic.stop()
#
# Linux: libpulse-simple (the PulseAudio API; PipeWire serves it through pipewire-pulse), opened with dlopen so neither
# `mojo run` nor a build needs a link flag. Mac / iPhone / web: not built yet (start() marks the microphone failed with
# a reason: AVAudioEngine is the planned path); it compiles there, so apps that use it still build.
# Also here: load_wav (16-bit PCM .wav -> floats) and best_match (normalised cross-correlation at the best lag).

from std.atomic import Atomic
from std.ffi import external_call, c_int, OwnedDLHandle
from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.sys import CompilationTarget
from std.math import sqrt
from mojoui.clock import now_ns

comptime RATE = 16000  # samples per second, mono
comptime CHUNK = 320  # samples per read from the sound server: 20 ms
comptime RING = RATE * 120  # the ring keeps the last two minutes

comptime _A = Atomic[Scalar[DType.int64]]
comptime _P = Pointer[Int64, MutUntrackedOrigin]
comptime W_STATE = 0  # 0 starting, 1 capturing, 2 stopped, -1 failed
comptime W_STOP = 1  # the reader asks the worker to stop
comptime W_TOTAL = 2  # samples written since start (absolute)
comptime W_LEVEL = 3  # the last chunk's RMS × 1e6
comptime W_ERR = 4  # the sound server's error code when it failed
comptime W_REFS = 5  # owners: the handle and the worker; the last one frees
comptime W_RING = 6  # the ring's address (Float32 × RING)
comptime W_SOURCE = 7  # a NUL-terminated copy of the source name, or 0 (default)
comptime W_TIME = 8  # now_ns() when the newest chunk landed
comptime W_SEQ = 9  # odd while the worker updates W_TIME and W_TOTAL together (a reader retries: captured_ns)
comptime W_WORDS = 10


def _word(words: Int, k: Int) -> _P:
    return _P(unsafe_from_address=words + 8 * k)


def _cstr(s: String) -> Int:
    """A NUL-terminated heap copy of s (the caller frees it)."""
    var n = s.byte_length()
    var p = unsafe_alloc[UInt8](n + 1)
    var src = s.unsafe_ptr()
    for i in range(n):
        p[i] = src[i]
    p[n] = 0
    return Int(p)


def _free_bytes(addr: Int):
    if addr != 0:
        Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr).unsafe_free()


def dl_call[T: RegisterPassable = Int, *A: AnyType](lib: Int, name: String, *args: *A) raises -> T:
    """Calls a C function found at run time in `lib` (0: anywhere in the process)."""
    var n = name
    var addr = external_call["dlsym", Int](lib, n.as_c_string_span())
    if addr == 0:
        raise Error("no symbol " + name)
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=addr)
    var f = Pointer(to=raw).unsafe_bitcast[def(*a: *A) thin abi("C") -> T]()[]
    return f(*args)


def _release(words: Int):
    if _A.fetch_add(_word(words, W_REFS), -1) == 1:
        Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(_A.load(_word(words, W_RING)))).unsafe_free()
        _free_bytes(Int(_A.load(_word(words, W_SOURCE))))
        _P(unsafe_from_address=words).unsafe_free()


def _capture(words: Int) raises:
    """The worker: open a record stream, then read 20 ms at a time into the ring until asked to stop."""
    var handle = OwnedDLHandle("libpulse-simple.so.0")  # (the standard library's dlopen: see gtk_webview, D-1413)
    var lib = 0  # (RTLD_GLOBAL: its symbols are found anywhere while `handle` holds it)
    var spec = unsafe_alloc[Int32](4)  # pa_sample_spec { int32 format; uint32 rate; uint8 channels }
    spec[0] = 5  # PA_SAMPLE_FLOAT32LE
    spec[1] = RATE
    spec[2] = 1
    spec[3] = 0
    var attr = unsafe_alloc[UInt32](5)  # pa_buffer_attr: maxlength, tlength, prebuf, minreq, fragsize
    for i in range(4):
        attr[i] = UInt32(0xFFFFFFFF)
    attr[4] = UInt32(CHUNK * 4)  # fragments of 20 ms, so samples arrive as they're spoken
    var err = unsafe_alloc[Int32](1)
    err[0] = 0
    var name = _cstr("mojoui")
    var stream = _cstr("microphone")
    var s = dl_call[Int](lib, "pa_simple_new",
        Int(0), name, c_int(2), Int(_A.load(_word(words, W_SOURCE))), stream, Int(spec), Int(0), Int(attr), Int(err))
    _free_bytes(name)
    _free_bytes(stream)
    spec.unsafe_free()
    attr.unsafe_free()
    if s == 0:
        _A.store(_word(words, W_ERR), Int64(err[0]))
        err.unsafe_free()
        raise Error("pa_simple_new failed")
    _A.store(_word(words, W_STATE), 1)
    var ring = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(_A.load(_word(words, W_RING))))
    var buf = unsafe_alloc[Float32](CHUNK)
    var lost = False
    while _A.load(_word(words, W_STOP)) == 0:
        if dl_call[c_int](lib, "pa_simple_read", s, Int(buf), CHUNK * 4, Int(err)) < 0:
            _A.store(_word(words, W_ERR), Int64(err[0]))  # (the server died, the source went away, we were killed)
            lost = True
            break
        var total = Int(_A.load(_word(words, W_TOTAL)))
        var sq = Float64(0)
        for i in range(CHUNK):
            var v = buf[i]
            ring.unsafe_offset((total + i) % RING)[] = v
            sq += Float64(v) * Float64(v)
        _A.store(_word(words, W_LEVEL), Int64(sqrt(sq / CHUNK) * 1e6))
        _ = _A.fetch_add(_word(words, W_SEQ), 1)  # (odd: time and total are changing)
        _A.store(_word(words, W_TIME), Int64(now_ns()))
        _A.store(_word(words, W_TOTAL), Int64(total + CHUNK))  # (after the samples: a reader sees all of them)
        _ = _A.fetch_add(_word(words, W_SEQ), 1)
    dl_call[NoneType](lib, "pa_simple_free", s)
    _ = handle.check_symbol("pa_simple_free")  # (keeps the library loaded until here)
    buf.unsafe_free()
    err.unsafe_free()
    if lost:
        raise Error("pa_simple_read failed")  # (_entry marks the microphone failed: failed() and why() say so)


def _entry(arg: Int) abi("C") -> Int:
    try:
        _capture(arg)
        _A.store(_word(arg, W_STATE), 2)
    except:
        _A.store(_word(arg, W_STATE), -1)
    _release(arg)
    return 0


struct Microphone(Movable):
    """One capture stream. Dropping it stops the worker (which frees what it holds when its last read returns)."""

    var words: Int
    var source: String
    var started: Bool
    var reason: String  # why it failed, in words (empty while fine)

    def __init__(out self, source: String = ""):
        self.source = source if source.byte_length() > 0 else getenv("MOJOUI_AUDIO_SOURCE", "")
        self.words = 0
        self.started = False
        self.reason = ""

    def start(mut self):
        """Starts capture on its own thread and returns at once. Safe to call once; samples arrive through read()."""
        if self.started:
            return
        self.started = True
        comptime if not CompilationTarget.is_linux():
            self.reason = "no microphone on this host yet (Mac: AVAudioEngine, planned)"
        else:
            var words = unsafe_alloc[Int64](W_WORDS)
            for k in range(W_WORDS):
                _A.store(_word(Int(words), k), 0)
            _A.store(_word(Int(words), W_REFS), 2)
            var ring = unsafe_alloc[Float32](RING)
            _A.store(_word(Int(words), W_RING), Int64(Int(ring)))
            if self.source.byte_length() > 0:
                _A.store(_word(Int(words), W_SOURCE), Int64(_cstr(self.source)))
            self.words = Int(words)
            var tid = List[Int](length=1, fill=0)
            var rc = external_call["pthread_create", c_int](Int(tid.unsafe_ptr()), Int(0), _entry, Int(words))
            if rc != 0:
                _A.store(_word(Int(words), W_STATE), -1)
                _release(Int(words))
                self.reason = "no thread for the microphone"
            else:
                _ = external_call["pthread_detach", c_int](tid[0])

    def _state(self) -> Int:
        return Int(_A.load(_word(self.words, W_STATE))) if self.words != 0 else (-1 if self.reason else 0)

    def running(self) -> Bool:
        return self._state() == 1

    def failed(self) -> Bool:
        return self._state() == -1

    def why(self) -> String:
        """Why it failed, in words."""
        if self.reason:
            return self.reason
        if self.words != 0 and self._state() == -1:
            var e = Int(_A.load(_word(self.words, W_ERR)))
            if self.total() > 0:
                return ("capture stopped: the sound server ended the stream (error " + String(e) + "; source '" + self.source
                        + "'; the server stopped, the source went away or the stream was killed)")
            return "the sound server refused the stream (error " + String(e) + "; source '" + self.source + "')"
        return ""

    def total(self) -> Int:
        """Samples captured since start()."""
        return Int(_A.load(_word(self.words, W_TOTAL))) if self.words != 0 else 0

    def captured_ns(self, index: Int) -> Int:
        """When sample `index` (absolute) was captured, on now_ns()'s clock (from when its 20 ms chunk landed)."""
        if self.words == 0:
            return 0
        var t = 0
        var total = 0
        while True:  # the newest chunk's time and the total it brought, read as one pair (W_SEQ even and unchanged)
            var seq = Int(_A.load(_word(self.words, W_SEQ)))
            if seq % 2 == 1:
                continue
            t = Int(_A.load(_word(self.words, W_TIME)))
            total = Int(_A.load(_word(self.words, W_TOTAL)))
            if Int(_A.load(_word(self.words, W_SEQ))) == seq:
                break
        return t - ((total - 1 - index) * 1_000_000_000) // RATE

    def level(self) -> Float64:
        """The last 20 ms's loudness (RMS, 0..1)."""
        return Float64(_A.load(_word(self.words, W_LEVEL))) / 1e6 if self.words != 0 else 0.0

    def read(self, since: Int) -> List[Float32]:
        """The samples from absolute index `since` to now (at most the ring's two minutes). Never waits."""
        var out = List[Float32]()
        if self.words == 0:
            return out^
        var total = self.total()
        var start = max(since, total - RING)
        if start >= total:
            return out^
        out.reserve(total - start)
        var ring = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(_A.load(_word(self.words, W_RING))))
        for i in range(start, total):
            out.append(ring.unsafe_offset(i % RING)[])
        return out^

    def stop(mut self):
        """Asks the worker to stop (it does after its current 20 ms read). Never waits."""
        if self.words != 0:
            _A.store(_word(self.words, W_STOP), 1)

    def __deinit__(deinit self):
        if self.words != 0:
            _A.store(_word(self.words, W_STOP), 1)
            _release(self.words)


def load_wav(path: String) raises -> List[Float32]:
    """A 16-bit PCM .wav's samples as floats in -1..1 (first channel; the file's own rate: callers use 16 kHz files)."""
    var b: List[UInt8]
    with open(path, "r") as f:
        b = f.read_bytes()
    if len(b) < 44 or Int(b[0]) != ord("R") or Int(b[8]) != ord("W"):
        raise Error("not a .wav: " + path)
    var channels = Int(b[22]) | (Int(b[23]) << 8)
    var k = 12
    while k + 8 <= len(b):
        var size = Int(b[k + 4]) | (Int(b[k + 5]) << 8) | (Int(b[k + 6]) << 16) | (Int(b[k + 7]) << 24)
        if Int(b[k]) == ord("d") and Int(b[k + 1]) == ord("a") and Int(b[k + 2]) == ord("t") and Int(b[k + 3]) == ord("a"):
            var out = List[Float32]()
            var step = 2 * max(channels, 1)
            var i = k + 8
            var end = min(k + 8 + size, len(b))
            while i + 1 < end:
                var v = Int(b[i]) | (Int(b[i + 1]) << 8)
                if v >= 32768:
                    v -= 65536
                out.append(Float32(v) / 32768.0)
                i += step
            return out^
        k += 8 + size + (size & 1)
    raise Error("no data chunk in " + path)


def _ncc(rec: List[Float32], want: List[Float32], lag: Int) -> Float64:
    var xy = Float64(0)
    var xx = Float64(0)
    var yy = Float64(0)
    for i in range(len(want)):
        var j = i + lag
        if j < 0 or j >= len(rec):
            continue
        var x = Float64(rec[j])
        var y = Float64(want[i])
        xy += x * y
        xx += x * x
        yy += y * y
    if xx == 0 or yy == 0:
        return 0.0
    return xy / sqrt(xx * yy)


def best_match(rec: List[Float32], want: List[Float32]) -> Tuple[Float64, Int]:
    """How well `want` appears in `rec`: the normalised cross-correlation at the best lag (1.0 = identical up to volume),
    and that lag in samples. Coarse search on 10 ms loudness envelopes, then sample by sample around the best one."""
    comptime HOP = 160
    var er = List[Float64]()
    var ef = List[Float64]()
    for i in range(len(rec) // HOP):
        var s = Float64(0)
        for j in range(HOP):
            s += abs(Float64(rec[i * HOP + j]))
        er.append(s)
    for i in range(len(want) // HOP):
        var s = Float64(0)
        for j in range(HOP):
            s += abs(Float64(want[i * HOP + j]))
        ef.append(s)
    var best_env = Float64(-1)
    var coarse = 0
    for lag in range(len(er) - len(ef) + 1):
        var s = Float64(0)
        var n = Float64(0)
        for i in range(len(ef)):
            s += er[lag + i] * ef[i]
            n += er[lag + i] * er[lag + i]
        var c = s / sqrt(n) if n > 0 else 0.0
        if c > best_env:
            best_env = c
            coarse = lag
    var best = Float64(-2)
    var at = 0
    for lag in range(coarse * HOP - 2 * HOP, coarse * HOP + 2 * HOP + 1):
        var c = _ncc(rec, want, lag)
        if c > best:
            best = c
            at = lag
    return (best, at)
