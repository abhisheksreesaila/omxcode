# mojoui.speaker: audio out (goal 72 M2), the mouth's end of mojoui.audio. Float samples go to the system's sound server
# from a thread of its own, through a queue the caller fills and never waits on.
#
#   var speaker = Speaker()                       # sink: $MOJOUI_AUDIO_SINK if set, else the default output; 24 kHz mono
#   speaker.play(samples, 24000)                  # queues them and returns at once (resampled if the rate differs)
#   speaker.playing()                             # something is queued or still in the device's buffer
#   speaker.stop()                                # barge-in: drops the queue and the device's buffer within a few ms
#   speaker.first_ns()                            # now_ns() when the first sample of the latest burst reached the device
#   speaker.play_ns(); speaker.latency_ms(); speaker.queued_ms(); speaker.failed(); speaker.why()
#
# Linux: libpulse-simple (PipeWire serves it through pipewire-pulse), opened with dlopen like Microphone. The device is
# kept at 40 ms of buffer, so stop() is heard within about that. The queue holds one minute: play() drops what doesn't
# fit. Mac / iPhone / web: not built yet (play() marks the speaker failed with a reason: AVAudioEngine and the browser's
# AudioContext are the planned paths; the web host's speaker is a later milestone, M5); it compiles there.

from std.atomic import Atomic
from std.ffi import c_int, OwnedDLHandle
from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.sys import CompilationTarget
from mojoui import libc
from mojoui.audio import dl_call, resample, _word, _cstr, _free_bytes, _A, _P
from mojoui.clock import now_ns

comptime OUT_RATE = 24000  # samples per second, mono (Kokoro's own rate)
comptime OUT_CHUNK = 480  # samples per write to the sound server: 20 ms
comptime OUT_RING = OUT_RATE * 60  # the queue: one minute
comptime BUFFER_MS = 40  # the device's buffer: what stop() can't take back except by flushing it
comptime S_STATE = 0  # 0 starting, 1 playing (open), 2 stopped, -1 failed
comptime S_STOP = 1  # the owner asks the worker to end
comptime S_WRITE = 2  # samples queued since start (absolute; the caller writes it after the samples)
comptime S_READ = 3  # samples handed to the device (absolute; the worker's)
comptime S_ERR = 4
comptime S_REFS = 5
comptime S_RING = 6  # the queue's address (Float32 × OUT_RING)
comptime S_SINK = 7  # a NUL-terminated copy of the sink name, or 0 (default)
comptime S_FLUSH = 8  # stop() counts this up; the worker flushes when it differs from what it has seen
comptime S_DROP = 9  # stop() sets it to S_WRITE: everything before it is dropped
comptime S_TAIL = 10  # now_ns() when the device has played everything written so far (0: nothing in the device)
comptime S_FIRST = 11  # now_ns() when the burst's first write returned
comptime S_PLAYAT = 12  # now_ns() of the play() that started the burst
comptime S_LAT = 13  # the device's latency in µs, measured at the burst's start
comptime S_WORDS = 14


def _release(words: Int):
    if _A.fetch_add(_word(words, S_REFS), -1) == 1:
        Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(_A.load(_word(words, S_RING)))).unsafe_free()
        _free_bytes(Int(_A.load(_word(words, S_SINK))))
        _P(unsafe_from_address=words).unsafe_free()


def _play(words: Int) raises:
    """The worker: open a playback stream, then write 20 ms at a time from the queue until asked to stop."""
    var handle = OwnedDLHandle("libpulse-simple.so.0")
    var lib = 0
    var spec = unsafe_alloc[Int32](4)  # pa_sample_spec { int32 format; uint32 rate; uint8 channels }
    spec[0] = 5  # PA_SAMPLE_FLOAT32LE
    spec[1] = OUT_RATE
    spec[2] = 1
    spec[3] = 0
    var attr = unsafe_alloc[UInt32](5)  # pa_buffer_attr: maxlength, tlength, prebuf, minreq, fragsize
    for i in range(5):
        attr[i] = UInt32(0xFFFFFFFF)
    attr[1] = UInt32(OUT_RATE * BUFFER_MS // 1000 * 4)
    attr[2] = 0  # start at the first sample, don't wait for the buffer to fill
    var err = unsafe_alloc[Int32](1)
    err[0] = 0
    var name = _cstr("mojoui")
    var stream = _cstr("speaker")
    var s = dl_call[Int](lib, "pa_simple_new",
        Int(0), name, c_int(1), Int(_A.load(_word(words, S_SINK))), stream, Int(spec), Int(0), Int(attr), Int(err))
    _free_bytes(name)
    _free_bytes(stream)
    spec.unsafe_free()
    attr.unsafe_free()
    if s == 0:
        _A.store(_word(words, S_ERR), Int64(err[0]))
        err.unsafe_free()
        raise Error("pa_simple_new failed")
    _A.store(_word(words, S_STATE), 1)
    var ring = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(_A.load(_word(words, S_RING))))
    var buf = unsafe_alloc[Float32](OUT_CHUNK)
    var seen = 0  # flushes handled
    var idle = True  # nothing written since the last burst ended
    var lost = False
    while _A.load(_word(words, S_STOP)) == 0:
        var flush = Int(_A.load(_word(words, S_FLUSH)))
        if flush != seen:
            seen = flush
            var drop = Int(_A.load(_word(words, S_DROP)))
            if Int(_A.load(_word(words, S_READ))) < drop:
                _A.store(_word(words, S_READ), Int64(drop))
            _ = dl_call[c_int](lib, "pa_simple_flush", s, Int(err))
            _A.store(_word(words, S_TAIL), 0)
            idle = True
        var read = Int(_A.load(_word(words, S_READ)))
        var avail = Int(_A.load(_word(words, S_WRITE))) - read
        if avail <= 0:
            if not idle and now_ns() >= Int(_A.load(_word(words, S_TAIL))):
                idle = True
            _ = libc.usleep(2000)
            continue
        var n = min(avail, OUT_CHUNK)
        for i in range(n):
            buf[i] = ring.unsafe_offset((read + i) % OUT_RING)[]
        if dl_call[c_int](lib, "pa_simple_write", s, Int(buf), n * 4, Int(err)) < 0:
            _A.store(_word(words, S_ERR), Int64(err[0]))
            lost = True
            break
        var t = now_ns()
        if idle:  # the burst's first write: when it landed, and how far behind the speaker cone the device runs
            idle = False
            _A.store(_word(words, S_FIRST), Int64(t))
            _A.store(_word(words, S_LAT), Int64(dl_call[UInt64](lib, "pa_simple_get_latency", s, Int(err))))
        if _A.load(_word(words, S_FLUSH)) == Int64(seen):  # (a stop() during the write already took this back)
            _A.store(_word(words, S_READ), Int64(read + n))
            _A.store(_word(words, S_TAIL), Int64(t) + Int64(_A.load(_word(words, S_LAT))) * 1000)
    if not lost:
        _ = dl_call[c_int](lib, "pa_simple_flush", s, Int(err))
    dl_call[NoneType](lib, "pa_simple_free", s)
    _ = handle.check_symbol("pa_simple_free")
    buf.unsafe_free()
    err.unsafe_free()
    if lost:
        raise Error("pa_simple_write failed")


def _entry(p: libc.ThreadArg) -> libc.ThreadArg:
    var arg = Int(p)
    try:
        _play(arg)
        _A.store(_word(arg, S_STATE), 2)
    except:
        _A.store(_word(arg, S_STATE), -1)
    _release(arg)
    return libc.null_arg()


struct Speaker(Movable):
    """One playback stream, opened by the first play(). Dropping it ends the worker (it frees what it holds when it's out)."""

    var words: Int
    var sink: String
    var reason: String

    def __init__(out self, sink: String = ""):
        self.sink = sink if sink.byte_length() > 0 else getenv("MOJOUI_AUDIO_SINK", "")
        self.words = 0
        self.reason = ""

    def _open(mut self):
        comptime if not CompilationTarget.is_linux():
            self.reason = "no speaker on this host yet (Mac: AVAudioEngine; web: the browser's AudioContext, M5)"
        else:
            var words = unsafe_alloc[Int64](S_WORDS)
            for k in range(S_WORDS):
                _A.store(_word(Int(words), k), 0)
            _A.store(_word(Int(words), S_REFS), 2)
            var ring = unsafe_alloc[Float32](OUT_RING)
            _A.store(_word(Int(words), S_RING), Int64(Int(ring)))
            if self.sink.byte_length() > 0:
                _A.store(_word(Int(words), S_SINK), Int64(_cstr(self.sink)))
            self.words = Int(words)
            var tid = List[Int](length=1, fill=0)
            var rc = libc.pthread_create[_entry](Int(words), Int(tid.unsafe_ptr()))
            if rc != 0:
                _A.store(_word(Int(words), S_STATE), -1)
                _release(Int(words))
                self.reason = "no thread for the speaker"
            else:
                _ = libc.pthread_detach(tid[0])

    def _state(self) -> Int:
        return Int(_A.load(_word(self.words, S_STATE))) if self.words != 0 else (-1 if self.reason else 0)

    def failed(self) -> Bool:
        return self._state() == -1

    def why(self) -> String:
        if self.reason:
            return self.reason
        if self.words != 0 and self._state() == -1:
            return "the sound server refused or ended the stream (error " + String(Int(_A.load(_word(self.words, S_ERR)))) + "; sink '" + self.sink + "')"
        return ""

    def play(mut self, samples: List[Float32], rate: Int = OUT_RATE):
        """Queues `samples` (mono floats at `rate` samples/s) and returns at once."""
        if len(samples) == 0:
            return
        if self.words == 0 and not self.reason:
            self._open()
        if self.words == 0:
            return
        var data = resample(samples, rate, OUT_RATE) if rate != OUT_RATE else samples.copy()
        var write = Int(_A.load(_word(self.words, S_WRITE)))
        var free = OUT_RING - (write - Int(_A.load(_word(self.words, S_READ))))
        var n = min(len(data), free)
        if write == Int(_A.load(_word(self.words, S_READ))):
            _A.store(_word(self.words, S_PLAYAT), Int64(now_ns()))  # (a new burst: the queue was empty)
        var ring = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(_A.load(_word(self.words, S_RING))))
        for i in range(n):
            ring.unsafe_offset((write + i) % OUT_RING)[] = data[i]
        _A.store(_word(self.words, S_WRITE), Int64(write + n))  # (after the samples: the worker sees all of them)

    def queued_ms(self) -> Float64:
        """Audio waiting in the queue (not yet handed to the device)."""
        if self.words == 0:
            return 0.0
        var q = Int(_A.load(_word(self.words, S_WRITE))) - max(Int(_A.load(_word(self.words, S_READ))), Int(_A.load(_word(self.words, S_DROP))))  # (stop() already dropped up to S_DROP)
        return Float64(max(q, 0)) * 1000.0 / OUT_RATE

    def playing(self) -> Bool:
        """Something is queued, or the device still holds what was written (until its estimated end)."""
        if self.words == 0 or self._state() != 1:
            return False
        var q = Int(_A.load(_word(self.words, S_WRITE))) - max(Int(_A.load(_word(self.words, S_READ))), Int(_A.load(_word(self.words, S_DROP))))  # (stop() already dropped up to S_DROP)
        return q > 0 or now_ns() < Int(_A.load(_word(self.words, S_TAIL)))

    def stop(mut self):
        """Barge-in: drops the queue and the device's buffer. Returns at once; the worker flushes within one 20 ms write."""
        if self.words == 0:
            return
        _A.store(_word(self.words, S_DROP), _A.load(_word(self.words, S_WRITE)))
        _A.store(_word(self.words, S_TAIL), 0)
        _ = _A.fetch_add(_word(self.words, S_FLUSH), 1)

    def first_ns(self) -> Int:
        """now_ns() when the latest burst's first write returned (the first sample was in the device's buffer)."""
        return Int(_A.load(_word(self.words, S_FIRST))) if self.words != 0 else 0

    def play_ns(self) -> Int:
        """now_ns() of the play() call that started the latest burst."""
        return Int(_A.load(_word(self.words, S_PLAYAT))) if self.words != 0 else 0

    def latency_ms(self) -> Float64:
        """The device's own delay (buffer + sink) measured when the latest burst began."""
        return Float64(_A.load(_word(self.words, S_LAT))) / 1000.0 if self.words != 0 else 0.0

    def __deinit__(deinit self):
        if self.words != 0:
            _A.store(_word(self.words, S_STOP), 1)
            _release(self.words)
