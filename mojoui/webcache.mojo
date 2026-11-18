# mojoui.webcache: one GET on a thread of its own, through a file cache on disk (goal 77 M3). The map's tiles and the geocoder's
# answers are the same shape of work: look in the cache, else ask the web politely (a User-Agent that names the program and
# nothing about the person, at most one request per `gap` when a Gate is given), keep what came, and, for a picture, decode it
# there too, so nothing slow ever runs on the UI thread (docs/ui-threads.md).
#
#   var gate = Gate.make(1050)                                     # process-wide: one request a second, whoever asks
#   var job = fetch_cached(url, cache_path, USER_AGENT, gate, decode=True)
#   … each frame: if job.ready(): job.take_pixels(px) / job.take_body() …   job.status, job.problem, job.from_disk, job.ms
#
# The request goes through mojoui.effects' transport (Flare for https:// in an app whose needs file says flare). A reply that
# isn't 200 is not cached; a damaged cache file is fetched again. Nothing here knows about maps: mojoui.tiles and mojoui.geocode
# build on it.

from std.atomic import Atomic
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc, alloc, Layout
from std.os import makedirs
from std.os.path import exists, dirname
from std.time import sleep
from mojoui import libc
from mojoui.clock import now_ns
from mojoui.effects import Backend
from mojoui.http import Request
from mojoui.pngread import decode_png

comptime _A = Atomic[Scalar[DType.int64]]
comptime _P = Pointer[Int64, MutUntrackedOrigin]
comptime W_STATE = 0  # 0 running, 1 done
comptime W_REFS = 1  # the handle and the worker: the last one frees
comptime W_SLOT = 2
comptime W_WORDS = 3


def _word(words: Int, k: Int) -> _P:
    return _P(unsafe_from_address=words + 8 * k)


@fieldwise_init
struct _Gate(Movable):
    var mutex: Int  # a pthread mutex (64 bytes)
    var last_ns: Int  # when the last request went out (under the mutex)
    var gap_ns: Int


struct Gate(Copyable, Movable, ImplicitlyCopyable):
    """At most one request per `gap_ms`, across every thread that passes it (a service's rate limit). Lives for the process."""
    var addr: Int  # 0: no limit

    def __init__(out self, addr: Int = 0):
        self.addr = addr

    @staticmethod
    def make(gap_ms: Int) -> Gate:
        var mu = Int(unsafe_alloc[UInt8](64))
        _ = libc.pthread_mutex_init(mu)
        var g = alloc(Layout[_Gate].single()).unsafe_leak()
        g.unsafe_write(_Gate(mu, 0, gap_ms * 1_000_000))
        return Gate(Int(g))


struct _Fetch(Movable):
    var url: String
    var path: String  # the cache file ("" none)
    var agent: String
    var gate: Int
    var decode: Bool
    var timeout_ms: Int
    var body: List[UInt8]
    var pixels: List[UInt32]
    var width: Int
    var height: Int
    var status: Int  # 200 when it came (from the cache too); the server's otherwise; 0 no reply
    var problem: String
    var from_disk: Bool
    var ms: Float64  # the whole job: cache or wait + request + decode
    var wait_ms: Float64  # of which spent waiting at the gate

    def __init__(out self, url: String, path: String, agent: String, gate: Int, decode: Bool, timeout_ms: Int):
        self.url = url
        self.path = path
        self.agent = agent
        self.gate = gate
        self.decode = decode
        self.timeout_ms = timeout_ms
        self.body = List[UInt8]()
        self.pixels = List[UInt32]()
        self.width = 0
        self.height = 0
        self.status = 0
        self.problem = ""
        self.from_disk = False
        self.ms = 0
        self.wait_ms = 0


def _read(path: String) -> List[UInt8]:
    try:
        with open(path, "r") as f:
            return f.read_bytes()
    except:
        return List[UInt8]()


def _keep(path: String, body: List[UInt8], tag: Int):
    """Writes the cache file in one step (a temporary file renamed over it), so a reader never sees half of one."""
    try:
        makedirs(dirname(path), exist_ok=True)
        var tmp = path + ".part" + String(tag)
        with open(tmp, "w") as f:
            f.write_bytes(Span(body))
        _ = libc.rename(tmp, path)
    except:
        pass


def _get(mut job: _Fetch):
    var req = Request.get(0, job.url).header("User-Agent", job.agent).header("Accept-Language", "en").timeout(job.timeout_ms)
    var g = job.gate
    if g != 0:
        var gate = Pointer[_Gate, MutUntrackedOrigin](unsafe_from_address=g)
        _ = libc.pthread_mutex_lock(gate[].mutex)
        var t0 = now_ns()
        var wait = gate[].last_ns + gate[].gap_ns - t0
        if wait > 0:
            sleep(Float64(wait) / 1e9)
        job.wait_ms = Float64(now_ns() - t0) / 1e6
        gate[].last_ns = now_ns()
        var resp = Backend.send(req)
        _ = libc.pthread_mutex_unlock(gate[].mutex)
        job.status = resp.status
        job.problem = resp.error
        swap(job.body, resp.body)
    else:
        var resp = Backend.send(req)
        job.status = resp.status
        job.problem = resp.error
        swap(job.body, resp.body)


def _run(mut job: _Fetch, tag: Int):
    var t0 = now_ns()
    if job.path != "" and exists(job.path):
        job.body = _read(job.path)
        job.from_disk = len(job.body) > 0
        job.status = 200 if job.from_disk else 0
    for attempt in range(2):  # (a damaged cache file: fetched once more)
        if not job.from_disk or attempt == 1:
            job.from_disk = False
            _get(job)
            if job.status == 200 and job.path != "" and len(job.body) > 0 and not job.decode:
                _keep(job.path, job.body, tag)
        if job.status != 200:
            if job.problem == "":
                job.problem = "the server answered " + String(job.status)
            break
        if not job.decode:
            break
        try:
            var img = decode_png(job.body)
            job.width = img.width
            job.height = img.height
            swap(job.pixels, img.pixels)
            if not job.from_disk and job.path != "":
                _keep(job.path, job.body, tag)
            job.problem = ""
            break
        except e:
            job.problem = String(e)
            if not job.from_disk:
                break
    job.ms = Float64(now_ns() - t0) / 1e6


def _release(words: Int, slot: Int):
    if _A.fetch_add(_word(words, W_REFS), -1) == 1:
        var p = Pointer[_Fetch, MutUntrackedOrigin](unsafe_from_address=slot)
        _ = p.unsafe_take_pointee()
        p.unsafe_free()
        _P(unsafe_from_address=words).unsafe_free()


def _entry(p: libc.ThreadArg) -> libc.ThreadArg:
    var words = Int(p)
    var slot = Int(_A.load(_word(words, W_SLOT)))
    _run(Pointer[_Fetch, MutUntrackedOrigin](unsafe_from_address=slot)[], slot)
    _A.store(_word(words, W_STATE), 1)
    _release(words, slot)
    return libc.null_arg()


struct CachedFetch(Movable):
    """A fetch out on its thread. Read it once ready(); dropping it early leaves the thread to free what it holds."""
    var words: Int
    var slot: Int
    var started_ns: Int

    def __init__(out self, words: Int, slot: Int):
        self.words = words
        self.slot = slot
        self.started_ns = now_ns()

    def ready(self) -> Bool:
        return _A.load(_word(self.words, W_STATE)) == 1

    def _job(self) -> Pointer[_Fetch, MutUntrackedOrigin]:
        return Pointer[_Fetch, MutUntrackedOrigin](unsafe_from_address=self.slot)

    def status(self) -> Int:
        return self._job()[].status

    def problem(self) -> String:
        return self._job()[].problem

    def from_disk(self) -> Bool:
        return self._job()[].from_disk

    def ms(self) -> Float64:
        return self._job()[].ms

    def wait_ms(self) -> Float64:
        return self._job()[].wait_ms

    def size(self) -> Tuple[Int, Int]:
        return (self._job()[].width, self._job()[].height)

    def take_pixels(self, mut into: List[UInt32]):
        """The decoded picture (only once ready(); moves it out)."""
        swap(into, self._job()[].pixels)

    def take_body(self) -> List[UInt8]:
        var out = List[UInt8]()
        swap(out, self._job()[].body)
        return out^

    def __deinit__(deinit self):
        _release(self.words, self.slot)


def fetch_cached(url: String, path: String, agent: String, gate: Gate = Gate(), decode: Bool = False, timeout_ms: Int = 15_000) -> CachedFetch:
    """GET `url` on a thread of its own: from the file at `path` when it's there ("" for no cache), else from the web (through
    `gate`), kept at `path` when it came with 200. `decode`: the body is a PNG, decoded on the thread too."""
    var words = Int(unsafe_alloc[Int64](W_WORDS))
    _A.store(_word(words, W_STATE), 0)
    _A.store(_word(words, W_REFS), 2)
    var slot = alloc(Layout[_Fetch].single()).unsafe_leak()
    slot.unsafe_write(_Fetch(url, path, agent, gate.addr, decode, timeout_ms))
    _A.store(_word(words, W_SLOT), Int64(Int(slot)))
    var tid = List[Int](length=1, fill=0)
    var rc = libc.pthread_create[_entry](words, Int(tid.unsafe_ptr()))
    if rc != 0:  # (no thread to be had: done here, as mojoui.effects does)
        _run(slot[], Int(slot))
        _A.store(_word(words, W_STATE), 1)
        _release(words, Int(slot))
    else:
        _ = libc.pthread_detach(tid[0])
    return CachedFetch(words, Int(slot))
