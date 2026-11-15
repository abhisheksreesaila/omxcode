# A pool of robot episodes to search by example (goal 71): omxcore's moments index (one vector per moment, from any number
# of LeRobot datasets) and the datasets it names, opened in-process. Show one clip, get every episode like it; pick a few,
# get more like those; export the picks as LeRobot v3 datasets. No model at run time: search by example needs only the
# index's vectors.
#   var pool = RobotPool.open("build/robotics/index.parquet")
#   pool.episodes[i]                        # dataset, episode, task, robot, seconds (each episode's facts, by the engine's SQL)
#   var hits = pool.like(["lerobot/libero:7"], 24)          # ranked, best first; hits.ms: the search alone
#   var more = pool.like(["lerobot/libero:7", "lerobot/libero:9", "lerobot/libero:40"], 24, robot="panda")
#   var made = pool.export(picks, "exports/my_set")        # one LeRobot v3 folder per dataset the picks come from
from std.collections import Dict
from omxcore import Catalog, SharedTable, sql, gpu_available
from omxcore.robot import open_dataset, Dataset, MomentIndex, SearchQuery, export, frames_at, engine_context
from max.gpu.host import DeviceContext
from omxcore.robot.index import QUERY_LIKE, DEVICE_GPU, DEVICE_CPU
from mojoui.clock import now_ns
from mojoui.hfcache import hf_snapshot

comptime EPISODES_SQL = "SELECT dataset, episode, min(task) AS task, min(robot) AS robot, max(seconds) AS seconds FROM moments GROUP BY dataset, episode ORDER BY dataset, episode"


@fieldwise_init
struct PoolEpisode(Copyable, Movable):
    var dataset: String
    var episode: Int
    var task: String
    var robot: String
    var seconds: Float64

    def key(self) -> String:
        return self.dataset + ":" + String(self.episode)


@fieldwise_init
struct Hit(Copyable, Movable):
    var key: String
    var at: Int              # its row in pool.episodes
    var score: Float64


@fieldwise_init
struct Exported(Copyable, Movable):
    var folder: String
    var dataset: String
    var episodes: Int
    var frames: Int


struct Hits(Movable):
    var hits: List[Hit]
    var ms: Float64          # the search alone (the ranking, on `device`)
    var device: String       # "gpu" or "cpu"
    var searched: Int        # episodes ranked (all, or the robot filter's)

    def __init__(out self):
        self.hits = List[Hit]()
        self.ms = 0.0
        self.device = "cpu"
        self.searched = 0


def split_key(key: String) raises -> Tuple[String, Int]:
    """"lerobot/libero:7" -> ("lerobot/libero", 7)."""
    var at = key.rfind(":")
    if at < 1:
        raise Error("`" + key + "` isn't dataset:episode")
    return (String(key[byte=:at]), Int(String(key[byte=at + 1:])))


struct RobotPool(Movable):
    var index: MomentIndex
    var episodes: List[PoolEpisode]
    var by_key: Dict[String, Int]
    var datasets: List[String]          # the datasets the index names, sorted
    var seconds: Float64                # every episode's length, summed
    var robots: List[String]            # the robots in the pool, sorted
    var gpu: Bool

    def __init__(out self, var index: MomentIndex) raises:
        self.index = index^
        self.episodes = List[PoolEpisode]()
        self.by_key = Dict[String, Int]()
        self.datasets = List[String]()
        self.robots = List[String]()
        self.seconds = 0.0
        self.gpu = gpu_available()
        var catalog = Catalog()
        catalog.add_table("moments", self.index.table)
        var answer = sql(catalog, EPISODES_SQL)
        var t = answer.take_table().share()
        var cd, ce, ct, cr, cs = t.column("dataset"), t.column("episode"), t.column("task"), t.column("robot"), t.column("seconds")
        for r in range(t.rows()):
            var d = t.text_of(cd, Int(t.get(cd, r)))
            var rb = t.text_of(cr, Int(t.get(cr, r))) if not t.is_null(cr, r) else String("")
            var e = PoolEpisode(d, Int(t.get(ce, r)), t.text_of(ct, Int(t.get(ct, r))) if not t.is_null(ct, r) else String(""),
                                rb, t.get_float(cs, r))
            self.by_key[e.key()] = len(self.episodes)
            if len(self.datasets) == 0 or self.datasets[len(self.datasets) - 1] != d:
                self.datasets.append(d)
            if rb.byte_length() > 0 and rb not in self.robots:
                self.robots.append(rb)
            self.seconds += e.seconds
            self.episodes.append(e^)
        sort(self.robots)

    @staticmethod
    def open(path: String) raises -> RobotPool:
        return RobotPool(MomentIndex.open(path))

    def hours(self) -> Float64:
        return self.seconds / 3600.0

    def at(self, key: String) raises -> Int:
        var i = self.by_key.get(key)
        if not i:
            raise Error("`" + key + "` isn't in the pool")
        return i.value()

    def like(mut self, keys: List[String], k: Int = 24, robot: String = "") raises -> Hits:
        """The k episodes most like `keys` (one clip, or several: their mean), best first, the examples left out. `robot`:
        only that robot's episodes ("" every one). On the GPU when there is one."""
        var q = SearchQuery()
        q.kind = QUERY_LIKE
        for key in keys:
            _ = self.at(key)
            var p = split_key(key)
            q.like_datasets.append(p[0])
            q.like_episodes.append(p[1])
        q.k = k
        q.device = DEVICE_GPU if self.gpu else DEVICE_CPU
        if robot.byte_length() > 0:
            if robot not in self.robots:
                raise Error("no robot `" + robot + "` in the pool")
            q.where = "robot = '" + robot.replace("'", "''") + "'"  # (a name from the index itself: quoted as SQL quotes it)
            q.has_where = True
        var t0 = now_ns()
        var t = self.index.search(q)
        var out = Hits()
        out.ms = Float64(now_ns() - t0) / 1e6
        out.device = "gpu" if self.gpu else "cpu"
        var cd, ce, cs = t.column("dataset"), t.column("episode"), t.column("score")
        for r in range(t.rows()):
            var key = t.text_of(cd, Int(t.get(cd, r))) + ":" + String(Int(t.get(ce, r)))
            out.hits.append(Hit(key, self.by_key.get(key).or_else(-1), t.get_float(cs, r)))
        if robot.byte_length() == 0:
            out.searched = len(self.episodes)
        else:
            for e in self.episodes:
                if e.robot == robot:
                    out.searched += 1
        return out^

    def open_set(self, dataset: String) raises -> Dataset:
        """One of the pool's datasets, opened where the Hugging Face cache keeps it."""
        return open_dataset(hf_snapshot(dataset))

    def export(self, keys: List[String], folder: String) raises -> List[Exported]:
        for key in keys:
            _ = self.at(key)
        return export_picks(keys, folder)


def export_picks(keys: List[String], folder: String) raises -> List[Exported]:
    """The picked episodes as LeRobot v3 datasets: one folder per dataset they come from (folder + "-" + its short name
    when there are several, else folder itself), episodes in the order picked. Video is linked, never re-encoded."""
    var sets = List[String]()
    var eps = List[List[Int]]()
    for key in keys:
        var p = split_key(key)
        var j = -1
        for i in range(len(sets)):
            if sets[i] == p[0]:
                j = i
        if j < 0:
            sets.append(p[0])
            eps.append(List[Int]())
            j = len(sets) - 1
        eps[j].append(p[1])
    var out = List[Exported]()
    for i in range(len(sets)):
        var dest = folder
        if len(sets) > 1:
            var short = sets[i]
            var slash = short.rfind("/")
            dest = folder + "-" + String(short[byte=slash + 1:])
        var ds = open_dataset(hf_snapshot(sets[i]))
        var r = export(ds, eps[i], dest)
        out.append(Exported(r.out, sets[i], r.episodes, r.frames))
    return out^


# ------------------------------------------------------------------------------------------------------------ clips
# An episode's pictures for a card: its poster (one frame) and a short loop, decoded by the engine (NVDEC on an NVIDIA GPU,
# else a decoder plugin such as dav1d on MAX's CPU context), scaled down on the host, kept by key.

comptime LOOPS_KEPT = 8      # loops kept decoded (each ~16 MB at the hero's 480 px)
comptime POSTER_AT = 0.4      # the poster is the frame 40 % into the episode (the arm is mid-task; 0 s is the start pose)


struct Picture(Copyable, Movable):
    """RGBA pixels (mojoui.view.Image's format), row by row."""
    var pixels: List[UInt32]
    var w: Int
    var h: Int

    def __init__(out self):
        self.pixels = List[UInt32]()
        self.w = 0
        self.h = 0

    def __init__(out self, var pixels: List[UInt32], w: Int, h: Int):
        self.pixels = pixels^
        self.w = w
        self.h = h


def scale_planar(src: UnsafePointer[UInt8, MutAnyOrigin], w: Int, h: Int, side: Int, up: Bool = False) -> Picture:
    """A planar RGB frame (3, h, w) as RGBA scaled so its longest side is `side`, each pixel the mean of the source pixels
    it covers; never up unless `up` (then bilinear: a hero clip from a small camera)."""
    var s = Float64(side) / Float64(max(w, h))
    if s > 1.0 and not up:
        s = 1.0
    var ow = max(1, Int(Float64(w) * s + 0.5))
    var oh = max(1, Int(Float64(h) * s + 0.5))
    var out = List[UInt32](length=ow * oh, fill=0)
    var plane = w * h
    if s > 1.0:
        for y in range(oh):
            var fy = max(0.0, (Float64(y) + 0.5) / s - 0.5)
            var y0 = min(Int(fy), h - 1)
            var y1 = min(y0 + 1, h - 1)
            var ay = fy - Float64(y0)
            for x in range(ow):
                var fx = max(0.0, (Float64(x) + 0.5) / s - 0.5)
                var x0 = min(Int(fx), w - 1)
                var x1 = min(x0 + 1, w - 1)
                var ax = fx - Float64(x0)
                var px = UInt32(255) << 24
                for c in range(3):
                    var o = c * plane
                    var v = (Float64(Int(src[o + y0 * w + x0])) * (1 - ax) + Float64(Int(src[o + y0 * w + x1])) * ax) * (1 - ay) + (
                        Float64(Int(src[o + y1 * w + x0])) * (1 - ax) + Float64(Int(src[o + y1 * w + x1])) * ax) * ay
                    px |= UInt32(min(255, Int(v + 0.5))) << UInt32(8 * c)
                out[y * ow + x] = px
        return Picture(out^, ow, oh)
    for y in range(oh):
        var y0 = y * h // oh
        var y1 = max(y0 + 1, (y + 1) * h // oh)
        for x in range(ow):
            var x0 = x * w // ow
            var x1 = max(x0 + 1, (x + 1) * w // ow)
            var r = 0
            var g = 0
            var b = 0
            for yy in range(y0, y1):
                var row = yy * w
                for xx in range(x0, x1):
                    r += Int(src[row + xx])
                    g += Int(src[plane + row + xx])
                    b += Int(src[2 * plane + row + xx])
            var n = (y1 - y0) * (x1 - x0)
            out[y * ow + x] = UInt32((r + n // 2) // n) | (UInt32((g + n // 2) // n) << 8) | (UInt32((b + n // 2) // n) << 16) | (UInt32(255) << 24)
    return Picture(out^, ow, oh)


struct Clips(Movable):
    """Decodes and keeps the pool's pictures. One per app: it holds the decode context and the open datasets."""
    var ctx: DeviceContext
    var names: List[String]
    var sets: List[Dataset]
    var posters: Dict[String, Picture]
    var loops: Dict[String, List[Picture]]
    var side: Int
    var decoder: String          # what decoded the last frames ("nvdec", "dav1d", ...)
    var problem: String          # what the last background decode couldn't do ("" none)

    def __init__(out self, side: Int = 320) raises:
        self.ctx = engine_context()
        self.names = List[String]()
        self.sets = List[Dataset]()
        self.posters = Dict[String, Picture]()
        self.loops = Dict[String, List[Picture]]()
        self.side = side
        self.decoder = ""
        self.problem = ""

    def _set(mut self, dataset: String) raises -> Int:
        for i in range(len(self.names)):
            if self.names[i] == dataset:
                return i
        self.sets.append(open_dataset(hf_snapshot(dataset)))
        self.names.append(dataset)
        return len(self.sets) - 1

    def frames_rgb(mut self, dataset: String, episodes: List[Int], times: List[Float64]) raises -> Tuple[List[UInt8], Int, Int]:
        """Full-size frames of one dataset at (episode, seconds) rows, planar RGB (n, 3, h, w) on the host, the camera the
        dataset lists first: (bytes, w, h)."""
        var i = self._set(dataset)
        var cam = self.sets[i].cameras[0]
        var buf = frames_at(self.sets[i], episodes, times, cam, self.ctx)
        var hw = self.sets[i].frames_size(episodes, cam, self.ctx)
        self.decoder = self.sets[i].decoder_name(cam, episodes[0], self.ctx)
        var out = List[UInt8](length=len(episodes) * 3 * hw[0] * hw[1], fill=0)
        self.ctx.enqueue_copy(dst_ptr=out.unsafe_ptr(), src_buf=buf)
        self.ctx.synchronize()
        return (out^, hw[1], hw[0])

    def posters_for(mut self, pool: RobotPool, keys: List[String]) raises:
        """Fills `posters` for every key not there yet: one decode call per dataset."""
        var secs = List[Float64]()
        for key in keys:
            secs.append(pool.episodes[pool.at(key)].seconds)
        self.posters_of(keys, secs)

    def posters_of(mut self, keys: List[String], seconds: List[Float64]) raises:
        """posters_for with each episode's length given (a background job holds no pool)."""
        var len_of = Dict[String, Float64]()
        for i in range(len(keys)):
            len_of[keys[i]] = seconds[i]
        var by = Dict[String, List[String]]()
        for key in keys:
            if key in self.posters:
                continue
            var p = split_key(key)
            if p[0] not in by:
                by[p[0]] = List[String]()
            by[p[0]].append(key)
        for item in by.items():
            var eps = List[Int]()
            var ts = List[Float64]()
            for key in item.value:
                eps.append(split_key(key)[1])
                ts.append(len_of[key] * POSTER_AT)
            var got = self.frames_rgb(item.key, eps, ts)
            var w, h = got[1], got[2]
            var base = got[0].unsafe_ptr()
            for j in range(len(eps)):
                var src = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=Int(base) + j * 3 * w * h)
                self.posters[item.value[j]] = scale_planar(src, w, h, self.side)

    def poster(mut self, pool: RobotPool, key: String) raises -> Picture:
        if key not in self.posters:
            self.posters_for(pool, [key])
        return self.posters[key].copy()

    def loop(mut self, pool: RobotPool, key: String, n: Int = 24, side: Int = 0) raises -> List[Picture]:
        """`n` frames spread over the episode, for a card that plays (kept); `side`: its longest side (0: the posters'),
        scaled up when the camera is smaller."""
        return self.loop_of(key, pool.episodes[pool.at(key)].seconds, n, side)

    def loop_of(mut self, key: String, secs: Float64, n: Int = 24, side: Int = 0) raises -> List[Picture]:
        var size = side if side > 0 else self.side
        var cache = key + "@" + String(size) + "x" + String(n)
        if cache in self.loops:
            return self.loops[cache].copy()
        var p = split_key(key)
        var eps = List[Int](length=n, fill=p[1])
        var ts = List[Float64]()
        for i in range(n):
            ts.append(secs * (Float64(i) + 0.5) / Float64(n))
        var got = self.frames_rgb(p[0], eps, ts)
        var w, h = got[1], got[2]
        var base = got[0].unsafe_ptr()
        var out = List[Picture]()
        for j in range(n):
            out.append(scale_planar(UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=Int(base) + j * 3 * w * h), w, h, size, up=side > 0))
        if len(self.loops) >= LOOPS_KEPT:  # (a loop is ~16 MB at 480 px: keep the last few, the oldest leaves first)
            var oldest = String()
            for k in self.loops.keys():
                oldest = k
                break
            _ = self.loops.pop(oldest)
        self.loops[cache] = out.copy()
        return out^


def scale_rgba(p: Picture, side: Int) -> Picture:
    """An RGBA picture scaled (bilinear, up or down) so its longest side is `side`: a poster fitted to its tile."""
    if p.w == 0 or p.h == 0 or max(p.w, p.h) == side:
        return p.copy()
    var s = Float64(side) / Float64(max(p.w, p.h))
    var ow = max(1, Int(Float64(p.w) * s + 0.5))
    var oh = max(1, Int(Float64(p.h) * s + 0.5))
    var out = List[UInt32](length=ow * oh, fill=0)
    for y in range(oh):
        var fy = min(max(0.0, (Float64(y) + 0.5) / s - 0.5), Float64(p.h - 1))
        var y0 = Int(fy)
        var y1 = min(y0 + 1, p.h - 1)
        var ay = fy - Float64(y0)
        for x in range(ow):
            var fx = min(max(0.0, (Float64(x) + 0.5) / s - 0.5), Float64(p.w - 1))
            var x0 = Int(fx)
            var x1 = min(x0 + 1, p.w - 1)
            var ax = fx - Float64(x0)
            var a = p.pixels[y0 * p.w + x0]
            var b = p.pixels[y0 * p.w + x1]
            var c = p.pixels[y1 * p.w + x0]
            var d = p.pixels[y1 * p.w + x1]
            var px = UInt32(0)
            for ch in range(4):
                var sh = UInt32(8 * ch)
                var v = (Float64(Int((a >> sh) & 255)) * (1 - ax) + Float64(Int((b >> sh) & 255)) * ax) * (1 - ay) + (
                    Float64(Int((c >> sh) & 255)) * (1 - ax) + Float64(Int((d >> sh) & 255)) * ax) * ay
                px |= UInt32(min(255, Int(v + 0.5))) << sh
            out[y * ow + x] = px
    return Picture(out^, ow, oh)
