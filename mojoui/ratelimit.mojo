# mojoui.ratelimit: a thread-safe sliding-window limiter (goal 60 M7): at most `limit` hits per `window_s` per key (an
# IP, an IP and a route, "global"), exact (each allowed hit's time is kept, at most `limit` per key), so a burst at a
# window's edge can't double the rate. Keys idle for a window are dropped as the table is swept; under a flood of keys
# that are all still live, the least recently seen are evicted down to 90 % of the cap, so the table stays bounded and
# a sweep happens once per 10 % of the cap's new keys, never on every hit.
#
#   var rl = RateLimit(limit=30, window_s=60)
#   var wait = rl.hit(req.peer + " /login")          # 0: allowed; else seconds until it would be (Retry-After)
#   if wait > 0: return Reply.error(429, "slow down", "rate_limited").header("Retry-After", String(wait))

from std.memory import Pointer
from std.memory.alloc import alloc, Layout, unsafe_alloc
from mojoui import libc
from mojoui.clock import wall_seconds

comptime _MAX_KEYS = 100_000  # (a flood of new keys sweeps the table early, never grows it without bound)
comptime _KEEP_KEYS = _MAX_KEYS * 9 // 10  # what an over-full sweep evicts down to


struct _Table(Movable):
    var keys: Dict[String, Int]  # key → its slot in hits
    var hits: List[List[Float64]]  # each slot's allowed hits, oldest first
    var free: List[Int]
    var mu: Int
    var swept: Float64

    def __init__(out self, mu: Int):
        self.keys = Dict[String, Int]()
        self.hits = List[List[Float64]]()
        self.free = List[Int]()
        self.mu = mu
        self.swept = wall_seconds()


struct RateLimit(ImplicitlyCopyable, Movable):
    var addr: Int
    var limit: Int
    var window_s: Float64

    def __init__(out self, limit: Int, window_s: Float64 = 60):
        """limit <= 0: no limit."""
        self.limit = limit
        self.window_s = window_s
        var mu = Int(unsafe_alloc[UInt8](64))
        _ = libc.pthread_mutex_init(mu)
        var t = alloc(Layout[_Table].single()).unsafe_leak()
        t.unsafe_write(_Table(mu))
        self.addr = Int(t)

    def hit(self, key: String) -> Int:
        """Counts a hit for `key` when it is allowed and answers 0; else the whole seconds until one would be."""
        if self.limit <= 0:
            return 0
        var t = Pointer[_Table, MutUntrackedOrigin](unsafe_from_address=self.addr)
        var now = wall_seconds()
        _ = libc.pthread_mutex_lock(t[].mu)
        if now - t[].swept > self.window_s or len(t[].keys) > _MAX_KEYS:
            self._sweep(now)
        var slot = t[].keys.get(key, -1)
        if slot < 0:
            if len(t[].free) > 0:
                slot = t[].free.pop()
            else:
                slot = len(t[].hits)
                t[].hits.append(List[Float64]())
            t[].keys[key] = slot
        ref h = t[].hits[slot]
        var drop = 0
        while drop < len(h) and now - h[drop] >= self.window_s:
            drop += 1
        if drop > 0:
            var kept = List[Float64]()
            for i in range(drop, len(h)):
                kept.append(h[i])
            h = kept^
        var wait = 0
        if len(h) >= self.limit:
            wait = Int(h[0] + self.window_s - now) + 1
        else:
            h.append(now)
        _ = libc.pthread_mutex_unlock(t[].mu)
        return wait

    def size(self) -> Int:
        """How many keys the table tracks (tests)."""
        var t = Pointer[_Table, MutUntrackedOrigin](unsafe_from_address=self.addr)
        _ = libc.pthread_mutex_lock(t[].mu)
        var n = len(t[].keys)
        _ = libc.pthread_mutex_unlock(t[].mu)
        return n

    def _sweep(self, now: Float64):
        var t = Pointer[_Table, MutUntrackedOrigin](unsafe_from_address=self.addr)
        var gone = List[String]()
        var live = List[Float64]()  # the last hit of each key that stays
        for e in t[].keys.items():
            ref h = t[].hits[e.value]
            if len(h) == 0 or now - h[len(h) - 1] >= self.window_s:
                gone.append(e.key)
            else:
                live.append(h[len(h) - 1])
        if len(live) > _MAX_KEYS:  # every key still live: evict the least recently seen down to _KEEP_KEYS
            sort(live)
            var cut = live[len(live) - _KEEP_KEYS]  # keys last seen before this go (ties at the cut stay)
            for e in t[].keys.items():
                ref h = t[].hits[e.value]
                if len(h) > 0 and now - h[len(h) - 1] < self.window_s and h[len(h) - 1] < cut:
                    gone.append(e.key)
        for k in gone:
            try:
                var slot = t[].keys.pop(k)
                t[].hits[slot] = List[Float64]()
                t[].free.append(slot)
            except:
                pass
        t[].swept = now
