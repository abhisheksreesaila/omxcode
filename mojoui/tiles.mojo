# mojoui.tiles: raster map tiles for any map in the process (goal 77 M3): OpenStreetMap-compatible {z}/{x}/{y} PNGs fetched over
# HTTPS on worker threads (mojoui.webcache), kept on disk and decoded off the UI thread, held in memory for every map that draws.
#
#   var tiles = TileStore.shared()                 # the process's store (one per process: every card, every tab)
#   _ = tiles[].poll()                             # take the tiles that landed (call at the top of a draw)
#   var k = tiles[].find(z, x, y)                  # -1: not here yet; else tiles[].pixels[k] (256 x 256 RGBA)
#   tiles[].want(z, x, y)                          # ask for it (ignored while it's on its way, failed lately, or the queue is full)
#   tiles[].busy()                                 # anything still on its way (a map draws again while it is)
#
# The source is $MOJOUI_TILE_URL (default OpenStreetMap's own tile server, {z} {x} {y} in it), the cache $MOJOUI_TILE_CACHE
# (default ~/.cache/omxcode/tiles). Politeness, as the OSM tile usage policy asks: a User-Agent naming the program (nothing about
# the person), at most two requests to the server at once, every tile kept on disk and never asked for twice, the attribution
# shown by whoever draws them (ATTRIBUTION). Memory: the newest MAX_TILES tiles (about 50 MB).

from std.collections import Dict
from std.memory import Pointer
from std.memory.alloc import alloc, Layout
from std.os import getenv
from std.os.path import exists
from mojoui.clock import now_ns
from mojoui.shared import get_shared, put_shared
from mojoui.webcache import CachedFetch, fetch_cached

comptime SLOT_TILES = 180  # mojoui.shared slot: the process's TileStore (181 is mojoui.geocode's, 182 mojoui.geometry's spots)
comptime TILE_URL = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
comptime USER_AGENT = "omxcode-map/0.1 (desktop app; low volume; disk cache)"  # (names the program, never the person)
comptime ATTRIBUTION = "© OpenStreetMap contributors"
comptime TILE = 256  # pixels a side
comptime MAX_TILES = 192
comptime MAX_NET = 2  # requests to the tile server at once
comptime MAX_DISK = 4  # tiles read from the disk cache at once
comptime RETRY_NS = 20_000_000_000  # a tile that failed is asked for again after this


def tile_key(z: Int, x: Int, y: Int) -> String:
    return String(z) + "/" + String(x) + "/" + String(y)


struct _Out(Movable):
    var key: String
    var job: CachedFetch
    var net: Bool

    def __init__(out self, key: String, var job: CachedFetch, net: Bool):
        self.key = key
        self.job = job^
        self.net = net


struct TileStore(Movable):
    var keys: List[String]
    var pixels: List[List[UInt32]]
    var used: List[Int]  # the poll count when each was last found (the oldest goes first)
    var index: Dict[String, Int]
    var out: List[_Out]
    var failed: Dict[String, Int]  # key -> when it may be asked for again
    var problem: String  # the last failure ("" none)
    var polls: Int
    var url: String
    var dir: String
    var net_ms: List[Float64]  # each tile fetched from the server: request + decode
    var disk_ms: List[Float64]  # each tile read from the disk cache: read + decode

    def __init__(out self):
        self.keys = List[String]()
        self.pixels = List[List[UInt32]]()
        self.used = List[Int]()
        self.index = Dict[String, Int]()
        self.out = List[_Out]()
        self.failed = Dict[String, Int]()
        self.problem = ""
        self.polls = 0
        self.url = getenv("MOJOUI_TILE_URL", TILE_URL)
        self.dir = getenv("MOJOUI_TILE_CACHE", getenv("HOME", "/tmp") + "/.cache/omxcode/tiles")
        self.net_ms = List[Float64]()
        self.disk_ms = List[Float64]()

    @staticmethod
    def shared() -> Pointer[TileStore, MutUntrackedOrigin]:
        """The process's store, made on the first call (on the UI thread: every draw happens there)."""
        var have = get_shared(SLOT_TILES)
        if have == 0:
            var p = alloc(Layout[TileStore].single()).unsafe_leak()
            p.unsafe_write(TileStore())
            have = Int(p)
            put_shared(SLOT_TILES, have)
        return Pointer[TileStore, MutUntrackedOrigin](unsafe_from_address=have)

    def source(self, z: Int, x: Int, y: Int) -> String:
        return self.url.replace("{z}", String(z)).replace("{x}", String(x)).replace("{y}", String(y))

    def path(self, z: Int, x: Int, y: Int) -> String:
        return self.dir + "/" + String(z) + "/" + String(x) + "/" + String(y) + ".png"

    def find(mut self, z: Int, x: Int, y: Int) -> Int:
        var n = 1 << z
        var k = self.index.get(tile_key(z, ((x % n) + n) % n, y), -1)
        if k >= 0:
            self.used[k] = self.polls
        return k

    def busy(self) -> Bool:
        return len(self.out) > 0

    def _on_way(self, key: String) -> Tuple[Bool, Int, Int]:
        """(is it out, how many go to the server, how many to the disk)."""
        var there = False
        var net = 0
        var disk = 0
        for i in range(len(self.out)):
            there = there or self.out[i].key == key
            if self.out[i].net:
                net += 1
            else:
                disk += 1
        return (there, net, disk)

    def want(mut self, z: Int, x: Int, y: Int):
        var n = 1 << z
        if z < 0 or z > 19 or y < 0 or y >= n:
            return
        var xx = ((x % n) + n) % n  # (the world wraps east to west)
        var key = tile_key(z, xx, y)
        if key in self.index:
            return
        if self.failed.get(key, 0) > now_ns():
            return
        var on = self._on_way(key)
        if on[0]:
            return
        var path = self.path(z, xx, y)
        var cached = exists(path)
        if (cached and on[2] >= MAX_DISK) or (not cached and on[1] >= MAX_NET):
            return
        self.out.append(_Out(key, fetch_cached(self.source(z, xx, y), path, USER_AGENT, decode=True), not cached))

    def poll(mut self) -> Int:
        """Takes the tiles that have landed; how many did."""
        self.polls += 1
        var landed = 0
        var i = 0
        while i < len(self.out):
            if not self.out[i].job.ready():
                i += 1
                continue
            var o = self.out.pop(i)
            var size = o.job.size()
            if o.job.problem() != "" or size[0] != TILE or size[1] != TILE:
                self.problem = o.job.problem() if o.job.problem() != "" else "a tile that isn't 256 x 256"
                self.failed[o.key] = now_ns() + RETRY_NS
                continue
            var px = List[UInt32]()
            o.job.take_pixels(px)
            if o.job.from_disk():
                self.disk_ms.append(o.job.ms())
            else:
                self.net_ms.append(o.job.ms())
            self._hold(o.key, px^)
            landed += 1
        return landed

    def _hold(mut self, key: String, var px: List[UInt32]):
        if len(self.keys) < MAX_TILES:
            self.index[key] = len(self.keys)
            self.keys.append(key)
            self.pixels.append(px^)
            self.used.append(self.polls)
            return
        var oldest = 0
        for k in range(len(self.used)):
            if self.used[k] < self.used[oldest]:
                oldest = k
        try:
            _ = self.index.pop(self.keys[oldest])
        except:
            pass
        self.keys[oldest] = key
        self.pixels[oldest] = px^
        self.used[oldest] = self.polls
        self.index[key] = oldest
