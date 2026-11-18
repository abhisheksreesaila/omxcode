# mojoui.webaudio: the web host's audio hub (goal 72 M5). On the web host the app runs inside the Python server, and its
# Microphone and Speaker (mojoui.audio, mojoui.speaker) talk to a browser instead of a sound server: the same Mojo API, so an
# app that uses them needs no change. The browser captures the microphone and plays the speaker; this file is what sits
# between: the host's audio socket (hosts/web.py) calls the functions below, the app's Microphone and Speaker read and write
# the same words.
#
#   audio_init()               once per server process: the hub's memory (0: it was there already). Without it
#                              (the GTK host, a test) Microphone and Speaker open the sound server as before.
#   audio_client(+1 / -1)      a page's socket attached / went away; the first one drops audio nobody heard
#   audio_wants()              bit 0: an app has started its Microphone (the page opens, or closes, its microphone);
#                              bit 1: audio is queued for the speaker
#   audio_push(addr, bytes)    the page's microphone: 16-bit little-endian mono samples at 16 kHz, as they arrive
#   audio_fail(code)           the page couldn't open the microphone (101 refused, 102 none found, 103 not allowed here)
#   audio_pull(addr, max)      the app's Speaker: up to `max` bytes of 16-bit mono samples at 24 kHz for the page to play
#                              (0: nothing now); at most LEAD_MS ahead of what the page has played, so stop() stays quick
#   audio_flushes()            counts up on every Speaker.stop(): the host tells the page to drop what it holds, then calls
#   audio_settle()             to forget the time the page would have gone on playing
#   audio_latency(us)          the page's own output delay, for Speaker.latency_ms()
#
# One hub per process, because the machine has one microphone and one speaker: with two pages open, the one that opened its
# audio socket last holds them. Never built for the public copy (MOJOUI_PUBLIC=1): a visitor's microphone is nobody else's.

from std.atomic import Atomic
from std.memory.alloc import unsafe_alloc
from mojoui.audio import _word, _A, _P, W_STATE, W_TOTAL, W_LEVEL, W_ERR, W_REFS, W_RING, W_TIME, W_SEQ, W_STOP, W_WORDS, RING
from mojoui.audio import SLOT_WEB_AUDIO, HUB_SPEAKER, HUB_CTL, H_MIC_WANT, H_CLIENTS, H_WORDS
from mojoui.speaker import S_STATE, S_READ, S_WRITE, S_DROP, S_FLUSH, S_TAIL, S_FIRST, S_LAT, S_REFS, S_RING, OUT_RATE, OUT_RING
from mojoui.shared import get_shared, put_shared
from mojoui.clock import now_ns
from std.math import sqrt

comptime LEAD_MS = 600  # the page holds at most this much unplayed audio (a stop() is then a flush of at most this)


def audio_init() -> Int:
    """The hub's memory, once per process (call it before any session: the web host does). 0 when it was there already."""
    if get_shared(SLOT_WEB_AUDIO) != 0:
        return 0
    var words = unsafe_alloc[Int64](HUB_CTL + H_WORDS)
    for k in range(HUB_CTL + H_WORDS):
        _A.store(_word(Int(words), k), 0)
    var base = Int(words)
    _A.store(_word(base, W_REFS), 1 << 40)  # (never freed: the process owns it)
    _A.store(_word(base, W_RING), Int64(Int(unsafe_alloc[Float32](RING))))
    var spk = base + 8 * HUB_SPEAKER
    _A.store(_word(spk, S_REFS), 1 << 40)
    _A.store(_word(spk, S_RING), Int64(Int(unsafe_alloc[Float32](OUT_RING))))
    _A.store(_word(spk, S_STATE), 1)
    put_shared(SLOT_WEB_AUDIO, base)
    return base


def _hub() -> Int:
    return get_shared(SLOT_WEB_AUDIO)


def audio_client(delta: Int):
    var h = _hub()
    if h == 0:
        return
    var ctl = h + 8 * HUB_CTL
    var spk = h + 8 * HUB_SPEAKER
    if delta > 0:  # what nobody heard (an app played while no page was there) isn't played late
        _A.store(_word(spk, S_DROP), _A.load(_word(spk, S_WRITE)))
        _A.store(_word(spk, S_READ), _A.load(_word(spk, S_WRITE)))
        _A.store(_word(spk, S_TAIL), 0)
        _ = _A.fetch_add(_word(spk, S_FLUSH), 1)
    _ = _A.fetch_add(_word(ctl, H_CLIENTS), Int64(delta))


def audio_wants() -> Int:
    """Bit 0: an app has started its Microphone (the page opens its microphone). Bit 1: an app has audio queued for the
    speaker (a page that hasn't been tapped yet shows its "Tap to turn on sound" button)."""
    var h = _hub()
    if h == 0:
        return 0
    var spk = h + 8 * HUB_SPEAKER
    var queued = _A.load(_word(spk, S_WRITE)) > max(_A.load(_word(spk, S_READ)), _A.load(_word(spk, S_DROP)))
    return Int(_A.load(_word(h + 8 * HUB_CTL, H_MIC_WANT))) + (2 if queued else 0)


def audio_fail(code: Int):
    var h = _hub()
    if h == 0:
        return
    _A.store(_word(h, W_ERR), Int64(code))
    _A.store(_word(h, W_STATE), -1)


def audio_push(addr: Int, nbytes: Int):
    """The page's microphone: samples as they arrive (16-bit little-endian, mono, 16 kHz). Ignored while no app wants them."""
    var h = _hub()
    if h == 0 or nbytes < 2 or audio_wants() % 2 == 0:
        return
    var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
    var ring = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(_A.load(_word(h, W_RING))))
    var n = nbytes // 2
    var total = Int(_A.load(_word(h, W_TOTAL)))
    var sq = Float64(0)
    for i in range(n):
        var v = Int(src[2 * i]) | (Int(src[2 * i + 1]) << 8)
        if v >= 32768:
            v -= 65536
        var f = Float32(v) / 32768.0
        ring.unsafe_offset((total + i) % RING)[] = f
        sq += Float64(f) * Float64(f)
    _A.store(_word(h, W_LEVEL), Int64(sqrt(sq / Float64(n)) * 1e6))
    _ = _A.fetch_add(_word(h, W_SEQ), 1)  # (odd: time and total are changing, as in Microphone's capture)
    _A.store(_word(h, W_TIME), Int64(now_ns()))
    _A.store(_word(h, W_TOTAL), Int64(total + n))
    _ = _A.fetch_add(_word(h, W_SEQ), 1)
    _A.store(_word(h, W_STATE), 1)


def audio_flushes() -> Int:
    var h = _hub()
    return Int(_A.load(_word(h + 8 * HUB_SPEAKER, S_FLUSH))) if h != 0 else 0


def audio_settle():
    """After a flush: what the app dropped is gone from the queue, and the page holds nothing."""
    var h = _hub()
    if h == 0:
        return
    var spk = h + 8 * HUB_SPEAKER
    var drop = _A.load(_word(spk, S_DROP))
    if _A.load(_word(spk, S_READ)) < drop:
        _A.store(_word(spk, S_READ), drop)
    _A.store(_word(spk, S_TAIL), 0)


def audio_latency(us: Int):
    var h = _hub()
    if h != 0:
        _A.store(_word(h + 8 * HUB_SPEAKER, S_LAT), Int64(us))


def audio_pull(addr: Int, max_bytes: Int) -> Int:
    """The app's Speaker output as 16-bit mono samples at 24 kHz, at most `max_bytes` and at most LEAD_MS ahead of the page's
    playing; returns the bytes written (0: nothing to send now)."""
    var h = _hub()
    if h == 0:
        return 0
    var spk = h + 8 * HUB_SPEAKER
    var flush = _A.load(_word(spk, S_FLUSH))
    var drop = _A.load(_word(spk, S_DROP))
    var read = max(_A.load(_word(spk, S_READ)), drop)
    var avail = Int(_A.load(_word(spk, S_WRITE)) - read)
    var now = now_ns()
    var tail = Int(_A.load(_word(spk, S_TAIL)))
    var ahead = max(tail - now, 0)
    var room = ((LEAD_MS * 1_000_000 - ahead) * OUT_RATE) // 1_000_000_000
    var n = min(min(avail, max_bytes // 2), room)
    if n <= 0:
        return 0
    var dst = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
    var ring = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(_A.load(_word(spk, S_RING))))
    for i in range(n):
        var f = ring.unsafe_offset((Int(read) + i) % OUT_RING)[]
        var v = max(min(Int(f * 32768.0), 32767), -32768)
        if v < 0:
            v += 65536
        dst[2 * i] = UInt8(v & 255)
        dst[2 * i + 1] = UInt8(v >> 8)
    if _A.load(_word(spk, S_FLUSH)) != flush:  # (a stop() came while this was read: the page is told to flush, not to play it)
        return 0
    _A.store(_word(spk, S_READ), Int64(Int(read) + n))
    if tail <= now:  # a burst begins: its first sample reaches the page now
        _A.store(_word(spk, S_FIRST), Int64(now))
        tail = now
    _A.store(_word(spk, S_TAIL), Int64(tail + (n * 1_000_000_000) // OUT_RATE))
    return n * 2
