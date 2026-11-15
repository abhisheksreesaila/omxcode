# Robot search by example, as a page any app can host (goal 71): a pool of robot episodes (mojoui.robotpool over omxcore's
# moments index), a sample to start from, tap a clip to get every episode like it (ranked on the GPU, the time shown), pick
# a few for More like these, export the picks as LeRobot v3 datasets. Opening the pool, decoding posters and loops and
# exporting run as background jobs: the window never waits on them.
#
#   var rs = RobotSearch(ROBOT_MSG)                 # messages ROBOT_MSG .. ROBOT_MSG + ROBOT_MSGS
#   rs.open("…/index.parquet")                      # starts reading the pool
#   update(): if rs.owns(m): rs.handle(m, event.number, width)     each frame: rs.poll(now_ns(), width)
#   view():   rs.view(width)  (+ rs.overlays() for its toast)      frames wanted while rs.busy() or rs.playing()
from std.collections import Dict
from std.os import getenv, makedirs
from std.os.path import exists
from std.sys import CompilationTarget
from std.memory import Pointer
from std.memory.alloc import alloc, Layout
from omxcore import Job, JobBody, JobCtl, JOB_RUNNING
from mojoui.uijobs import start_ui_job
from mojoui.view import (View, Text, Button, Image, VStack, HStack, Spacer, Card, Segmented, Divider, TITLE, HEADLINE, BODY, CAPTION,
                         PROMINENT, SUBTLE, START, CENTER, STRETCH, TONE_ACCENT, CARD)
from mojoui.overlays import Toast
from mojoui.chip import Badge, BADGE_OK, BADGE_PLAIN
from mojoui.clipgrid import ClipTile, ClipGrid, clip_message, clip_columns, CLIP_MSGS
from mojoui.robotpool import RobotPool, PoolEpisode, Clips, Picture, Hit, Exported, export_picks, split_key, scale_rgba
from mojoui.clock import now_ns
from mojoui.charts import grouped

comptime RS_FILTER = 0       # the robot filter (event.number: 0 every robot, i + 1 pool.robots[i])
comptime RS_MORE = 1         # More like these (the picks)
comptime RS_EXPORT = 2
comptime RS_CLEAR = 3        # clear the picks
comptime RS_BACK = 4         # back to the sample
comptime RS_TOAST_CLOSE = 5
comptime RS_HERO_PICK = 6    # pick / unpick the shown clip
comptime RS_GRID = 20        # the ClipGrid's messages (2 a tile)
comptime RS_K = 24           # results a search shows
comptime ROBOT_MSGS = RS_GRID + RS_K * CLIP_MSGS + 2 * 48   # (the sample may hold up to 48 tiles)
comptime SAMPLE = 24
comptime ROBOTS = CompilationTarget.is_linux()
"""Robot search's engine work (the index, decoding, export) is built for Linux only: on the Mac it needs Mojo's async
runtime (MAX's device context, even its CPU one) and libc calls the app's Mac link doesn't carry (goal 71 M0's Mac proof).
Everything that touches the engine sits in `_Engine`, behind `comptime if ROBOTS` (the engine's own way with its GPU,
gpu.mojo): the page itself holds only plain values, so its fields bring no runtime into a Mac build."""
comptime LOOP_FRAMES = 24
comptime LOOP_NS = 125_000_000   # 8 frames a second
comptime POSTER_SIDE = 320     # posters are decoded at this side, then fitted to the tiles (tile_side)
comptime TILE_MIN = 240       # a tile is at least this wide


# ------------------------------------------------------------------------------------------------------------- jobs


struct PoolOpened(Movable):
    var pool: Optional[RobotPool]
    var clips: Optional[Clips]
    var ms: Float64

    def __init__(out self, var pool: RobotPool, var clips: Clips, ms: Float64):
        self.pool = pool^
        self.clips = clips^
        self.ms = ms


struct OpenPoolJob(JobBody):
    comptime Out = PoolOpened
    var path: String

    def __init__(out self, var path: String):
        self.path = path^

    def run(mut self, ctl: JobCtl) raises -> PoolOpened:
        var t0 = now_ns()
        var pool = RobotPool.open(self.path)
        if len(pool.episodes) > 0:  # (the first search puts the index on the device: done here, so a tap is as quick as the rest)
            _ = pool.like([pool.episodes[0].key()], 1)
        var clips = Clips(POSTER_SIDE)
        return PoolOpened(pool^, clips^, Float64(now_ns() - t0) / 1e6)


struct ClipsJob(JobBody):
    """Posters for `keys` and, when `loop_key` is set, its loop; never raises (the Clips must come back): a failure is
    clips.problem."""
    comptime Out = Clips
    var clips: Optional[Clips]
    var keys: List[String]
    var secs: List[Float64]
    var loop_key: String
    var loop_secs: Float64
    var loop_side: Int

    def __init__(out self, var clips: Clips, var keys: List[String], var secs: List[Float64], loop_key: String, loop_secs: Float64, loop_side: Int):
        self.clips = clips^
        self.keys = keys^
        self.secs = secs^
        self.loop_key = loop_key
        self.loop_secs = loop_secs
        self.loop_side = loop_side

    def run(mut self, ctl: JobCtl) raises -> Clips:
        var c = self.clips.take()
        c.problem = ""
        try:
            if len(self.keys) > 0:
                c.posters_of(self.keys, self.secs)
            if self.loop_key.byte_length() > 0:
                _ = c.loop_of(self.loop_key, self.loop_secs, LOOP_FRAMES, self.loop_side)
        except e:
            c.problem = String(e)
        return c^


struct ExportDone(Movable):
    var made: List[Exported]
    var problem: String
    var ms: Float64

    def __init__(out self):
        self.made = List[Exported]()
        self.problem = ""
        self.ms = 0.0


struct ExportJob(JobBody):
    comptime Out = ExportDone
    var keys: List[String]
    var folder: String

    def __init__(out self, var keys: List[String], var folder: String):
        self.keys = keys^
        self.folder = folder^

    def run(mut self, ctl: JobCtl) raises -> ExportDone:
        var out = ExportDone()
        var t0 = now_ns()
        try:
            out.made = export_picks(self.keys, self.folder)
        except e:
            out.problem = String(e)
        out.ms = Float64(now_ns() - t0) / 1e6
        return out^


# ------------------------------------------------------------------------------------------------------------- words


def tenths(x: Float64) -> String:
    var t = Int(x * 10.0 + 0.5)
    return String(t // 10) + "." + String(t % 10)


def millis(ms: Float64) -> String:
    """0.10 ms, 4.2 ms, 120 ms."""
    if ms < 1.0:
        var h = Int(ms * 100.0 + 0.5)
        return "0." + ("0" if h < 10 else "") + String(h) + " ms"
    if ms < 10.0:
        return tenths(ms) + " ms"
    return String(Int(ms + 0.5)) + " ms"


def robot_name(r: String) -> String:
    """The robot as people say it ("so100" -> SO-100, "panda" -> Panda)."""
    var l = r.lower()
    if l.startswith("so"):
        var n = String(l[byte=2:]).replace("_", "").replace("-", "")
        return "SO-" + n
    if r.byte_length() == 0:
        return "robot"
    return String(r[byte=:1]).upper() + String(r[byte=1:])


def set_name(d: String) -> String:
    """lerobot/svla_so100_sorting -> svla_so100_sorting."""
    var s = d.rfind("/")
    return String(d[byte=s + 1:])


def fixed5(s: Float64) -> String:
    """A score to 5 places (a poster's tooltip: what an agent or a check reads)."""
    var t = Int(s * 100000.0 + 0.5)
    var frac = String(t % 100000)
    while frac.byte_length() < 5:
        frac = "0" + frac
    return String(t // 100000) + "." + frac


def score_text(s: Float64) -> String:
    var t = Int(s * 1000.0 + 0.5)
    var frac = String(t % 1000)
    while frac.byte_length() < 3:
        frac = "0" + frac
    return String(t // 1000) + "." + frac


# ------------------------------------------------------------------------------------------------------------- the page


struct _Engine(Movable):
    """What the page holds of the engine (heap-held by address: see ROBOTS)."""
    var pool: Optional[RobotPool]
    var clips: Optional[Clips]
    var opening: Optional[Job[PoolOpened]]
    var working: Optional[Job[Clips]]
    var exporting: Optional[Job[ExportDone]]

    def __init__(out self):
        self.pool = None
        self.clips = None
        self.opening = None
        self.working = None
        self.exporting = None


def _engine_at(addr: Int) -> Pointer[_Engine, MutUntrackedOrigin]:
    return Pointer[_Engine, MutUntrackedOrigin](unsafe_from_address=addr)


struct RobotSearch(Movable):
    var base: Int
    var path: String
    var eng: Int                    # the _Engine's address (0: none yet; never on a Mac build)
    var opened: Bool                # the pool is open: its facts below
    var opening: Bool
    var working: Bool
    var exporting: Bool
    var has_clips: Bool             # the decoder is here (not inside a running job)
    var episodes: List[PoolEpisode] # the pool's facts, copied out when it opens
    var by_key: Dict[String, Int]
    var robots: List[String]
    var n_sets: Int
    var hours: Float64
    var gpu: Bool
    var open_ms: Float64
    var posters: Dict[String, Picture]
    var fitted: Dict[String, Picture]   # the posters at tile_side (what the grid shows)
    var tile_side: Int
    var width: Int                      # the width the page was last laid out for
    var want: List[String]          # posters asked for while a job ran
    var want_loop: String           # a loop asked for while a job ran
    var loop: List[Picture]
    var loop_key: String
    var frame: Int
    var frame_ns: Int
    var hero_side: Int
    var sample: List[String]
    var shown: String               # the clip the results are like ("" when they're like the picks, or none)
    var like: List[String]          # what the results are like (one clip, or the picks)
    var hits: List[Hit]
    var ms: Float64
    var device: String
    var searched: Int
    var picked: List[String]
    var robot: Int                  # 0 every robot, i + 1: pool.robots[i]
    var toast: String
    var problem: String
    var exports_dir: String
    var exported: List[String]
    var version: Int

    def __init__(out self, base: Int):
        self.base = base
        self.path = ""
        self.eng = 0
        self.opened = False
        self.opening = False
        self.working = False
        self.exporting = False
        self.has_clips = False
        self.episodes = List[PoolEpisode]()
        self.by_key = Dict[String, Int]()
        self.robots = List[String]()
        self.n_sets = 0
        self.hours = 0.0
        self.gpu = False
        self.open_ms = 0.0
        self.posters = Dict[String, Picture]()
        self.fitted = Dict[String, Picture]()
        self.tile_side = 0
        self.width = 0
        self.want = List[String]()
        self.want_loop = ""
        self.loop = List[Picture]()
        self.loop_key = ""
        self.frame = 0
        self.frame_ns = 0
        self.hero_side = 480
        self.sample = List[String]()
        self.shown = ""
        self.like = List[String]()
        self.hits = List[Hit]()
        self.ms = 0.0
        self.device = ""
        self.searched = 0
        self.picked = List[String]()
        self.robot = 0
        self.toast = ""
        self.problem = ""
        var d = getenv("OMX_ROBOT_EXPORTS")
        self.exports_dir = d if d.byte_length() > 0 else getenv("HOME") + "/omxplorer-exports"
        self.exported = List[String]()
        self.version = 0

    def __del__(deinit self):
        comptime if ROBOTS:
            if self.eng != 0:
                var p = _engine_at(self.eng)
                p.unsafe_deinit_pointee()
                p.unsafe_free()

    # ---------- state

    def open(mut self, path: String):
        """Starts reading the pool at `path` (an omxcore moments index)."""
        if self.opening:
            return
        self.path = path
        self.problem = ""
        comptime if ROBOTS:
            if self.eng == 0:
                var a = alloc(Layout[_Engine].single())
                var ptr = a^.unsafe_leak()
                ptr.unsafe_write(_Engine())
                self.eng = Int(ptr)
            _engine_at(self.eng)[].opening = start_ui_job(OpenPoolJob(path))
            self.opening = True
        else:
            self.problem = "Robot search runs on Linux for now (its decoding needs Mojo's runtime, which this build leaves out)"
        self.version += 1

    def ready(self) -> Bool:
        return self.opened

    def busy(self) -> Bool:
        return self.opening or self.working or self.exporting

    def playing(self) -> Bool:
        return len(self.loop) > 1

    def owns(self, m: Int) -> Bool:
        return self.base <= m < self.base + ROBOT_MSGS

    def robot_filter(self) -> String:
        if self.robot <= 0 or self.robot > len(self.robots):
            return ""
        return self.robots[self.robot - 1]

    def episode_secs(self, key: String) -> Float64:
        var i = self.by_key.get(key)
        return self.episodes[i.value()].seconds if i else 0.0

    def make_sample(mut self):
        """One episode a task, the datasets taking turns (so real robots show beside the simulator), up to SAMPLE; or the
        clips OMX_ROBOT_SAMPLE names ("dataset:episode,…": a demo's chosen start), then the rest that way."""
        self.sample = List[String]()
        if not self.opened:
            return
        var chosen = getenv("OMX_ROBOT_SAMPLE")
        if chosen.byte_length() > 0 and self.robot == 0:
            for k in chosen.split(","):
                var key = String(String(k).strip())
                if key in self.by_key and key not in self.sample:
                    self.sample.append(key)
        ref p = self
        var rf = self.robot_filter()
        var groups = Dict[String, List[Int]]()
        var order = List[String]()
        for i in range(len(p.episodes)):
            ref e = p.episodes[i]
            if rf.byte_length() > 0 and e.robot != rf:
                continue
            var g = e.dataset + "|" + e.task
            if g not in groups:
                groups[g] = List[Int]()
                order.append(g)
            try:
                groups[g].append(i)
            except:
                pass
        var per = List[List[String]]()
        var sets = List[String]()
        for g in order:
            var d = String(g[byte=:g.find("|")])
            var j = -1
            for k in range(len(sets)):
                if sets[k] == d:
                    j = k
            if j < 0:
                sets.append(d)
                per.append(List[String]())
                j = len(sets) - 1
            try:
                ref ids = groups[g]
                per[j].append(p.episodes[ids[len(ids) // 2]].key())
            except:
                pass
        var taken = True
        var round = 0
        while taken and len(self.sample) < SAMPLE:
            taken = False
            for j in range(len(per)):
                if round < len(per[j]) and len(self.sample) < SAMPLE:
                    if per[j][round] not in self.sample:
                        self.sample.append(per[j][round])
                    taken = True
            round += 1

    def search(mut self, like: List[String], shown: String):
        """Ranks the pool against `like` (one clip or the picks), keeps the hits, asks for their posters and the shown
        clip's loop."""
        if not self.opened:
            return
        comptime if ROBOTS:
            try:
                var h = _engine_at(self.eng)[].pool.value().like(like, RS_K, robot=self.robot_filter())
                self.hits = h.hits.copy()
                self.ms = h.ms
                self.device = h.device
                self.searched = h.searched
                self.like = like.copy()
                self.shown = shown
                self.problem = ""
            except e:
                self.problem = String(e)
                return
        var keys = List[String]()
        for x in self.hits:
            keys.append(x.key)
        for k in like:
            keys.append(k)
        self.ask(keys, shown)
        self.version += 1

    def ask(mut self, keys: List[String], loop_key: String):
        """Posters for `keys` (those not here yet) and `loop_key`'s loop ("" none): a job now, or after the one running."""
        var need = List[String]()
        for k in keys:
            if k not in self.posters and k not in need:
                need.append(k)
        if loop_key.byte_length() > 0:
            self.loop = List[Picture]()
            self.loop_key = loop_key
        if self.working or not self.has_clips:
            for k in need:
                if k not in self.want:
                    self.want.append(k)
            if loop_key.byte_length() > 0:
                self.want_loop = loop_key
            return
        if len(need) == 0 and loop_key.byte_length() == 0:
            return
        var secs = List[Float64]()
        for k in need:
            secs.append(self.episode_secs(k))
        comptime if ROBOTS:
            ref e = _engine_at(self.eng)[]
            var c = e.clips.take()
            self.has_clips = False
            e.working = start_ui_job(ClipsJob(c^, need^, secs^, loop_key, self.episode_secs(loop_key) if loop_key.byte_length() > 0 else 0.0, self.hero_side))
            self.working = True

    def poll(mut self, now: Int, width: Int) -> Bool:
        """Lands finished jobs and moves the playing loop on; True when the page changed."""
        var changed = False
        comptime if ROBOTS:
            if self.eng != 0:
                var e = _engine_at(self.eng)
                if self.opening and e[].opening.value().poll() != JOB_RUNNING:
                    var job = e[].opening.take()
                    self.opening = False
                    try:
                        var o = job.result()
                        self.open_ms = o.ms
                        e[].pool = o.pool.take()
                        e[].clips = o.clips.take()
                        self.has_clips = True
                        ref pool = e[].pool.value()
                        self.episodes = pool.episodes.copy()
                        self.by_key = pool.by_key.copy()
                        self.robots = pool.robots.copy()
                        self.n_sets = len(pool.datasets)
                        self.hours = pool.hours()
                        self.gpu = pool.gpu
                        self.opened = True
                        self.make_sample()
                        self.ask(self.sample.copy(), "")
                    except err:
                        self.problem = "Couldn't open the pool: " + String(err)
                    changed = True
                if self.working and e[].working.value().poll() != JOB_RUNNING:
                    var job = e[].working.take()
                    self.working = False
                    try:
                        var c = job.result()
                        if c.problem.byte_length() > 0:
                            self.problem = c.problem
                        for item in c.posters.items():
                            if item.key not in self.posters:
                                self.posters[item.key] = item.value.copy()
                                if self.tile_side > 0:
                                    self.fitted[item.key] = scale_rgba(item.value, self.tile_side)
                        if self.loop_key.byte_length() > 0:
                            var cache = self.loop_key + "@" + String(self.hero_side) + "x" + String(LOOP_FRAMES)
                            if cache in c.loops:
                                self.loop = c.loops[cache].copy()
                                self.frame = 0
                                self.frame_ns = now
                        e[].clips = c^
                        self.has_clips = True
                    except err:
                        self.problem = "Couldn't decode the clips: " + String(err)
                    if self.has_clips and (len(self.want) > 0 or self.want_loop.byte_length() > 0):
                        var w = self.want.copy()
                        var l = self.want_loop
                        self.want = List[String]()
                        self.want_loop = ""
                        self.ask(w, l)
                    changed = True
                if self.exporting and e[].exporting.value().poll() != JOB_RUNNING:
                    var job = e[].exporting.take()
                    self.exporting = False
                    try:
                        var d = job.result()
                        if d.problem.byte_length() > 0:
                            self.toast = "Export failed: " + d.problem
                        else:
                            var eps = 0
                            var frames = 0
                            self.exported = List[String]()
                            for x in d.made:
                                eps += x.episodes
                                frames += x.frames
                                self.exported.append(x.folder)
                            var first = self.exported[0]
                            var name = String(first[byte=first.rfind("/") + 1:])  # (the folder's name: the whole path is in the toast's tooltip)
                            var where = name if len(self.exported) == 1 else String(len(self.exported)) + " folders (" + name + "…)"
                            self.toast = ("Exported " + String(eps) + " episodes (" + grouped(frames) + " frames) to " + where + " in " + millis(d.ms) +
                                          " · LeRobot loads it")
                    except err:
                        self.toast = "Export failed: " + String(err)
                    changed = True
        if self.playing() and now - self.frame_ns >= LOOP_NS:
            self.frame = (self.frame + 1) % len(self.loop)
            self.frame_ns = now
            changed = True
        if width != self.width and width > 0:
            self.fit(width)
            changed = True
        if changed:
            self.version += 1
        return changed

    def grid_width(self, width: Int) -> Int:
        """The grid's width: the page's, less the hero card beside it on a wide window while results show."""
        if len(self.like) > 0 and width >= 900:
            return width - (self.hero_for(width) + 40) - 24
        return width

    def fit(mut self, width: Int):
        """Lays the page out for `width`: the hero's side and the tiles' (posters fitted to their columns)."""
        self.width = width
        self.hero_side = self.hero_for(width)
        var gw = self.grid_width(width)
        var cols = clip_columns(gw, TILE_MIN)
        var side = max(120, (gw - 12 * (cols - 1)) // cols - 34)
        if side != self.tile_side:
            self.tile_side = side
            self.fitted = Dict[String, Picture]()
        for item in self.posters.items():
            if item.key not in self.fitted:
                self.fitted[item.key] = scale_rgba(item.value, self.tile_side)
        self.version += 1

    def toggle_pick(mut self, key: String):
        var kept = List[String]()
        var had = False
        for k in self.picked:
            if k == key:
                had = True
            else:
                kept.append(k)
        if not had:
            kept.append(key)
        self.picked = kept^
        self.version += 1

    def next_folder(self) -> String:
        var i = 1
        while exists(self.exports_dir + "/picks-" + String(i)) or exists(self.exports_dir + "/picks-" + String(i) + "-libero"):
            i += 1
        return self.exports_dir + "/picks-" + String(i)

    def handle(mut self, m: Int, number: Int, width: Int):
        """A message this page owns (owns(m))."""
        var o = m - self.base
        self.hero_side = self.hero_for(width)
        var had_results = len(self.like) > 0
        if o == RS_FILTER:
            self.robot = number
            self.make_sample()
            self.ask(self.sample.copy(), "")
            if len(self.like) > 0:
                var again = self.shown
                self.search(self.like.copy(), again)
        elif o == RS_MORE:
            if len(self.picked) > 0:
                self.search(self.picked.copy(), "")
        elif o == RS_EXPORT:
            if len(self.picked) > 0 and not self.exporting:
                var folder = self.next_folder()
                try:
                    makedirs(self.exports_dir, exist_ok=True)
                except:
                    pass
                comptime if ROBOTS:
                    _engine_at(self.eng)[].exporting = start_ui_job(ExportJob(self.picked.copy(), folder))
                    self.exporting = True
                self.toast = ""
        elif o == RS_CLEAR:
            self.picked = List[String]()
        elif o == RS_BACK:
            self.shown = ""
            self.like = List[String]()
            self.hits = List[Hit]()
            self.loop = List[Picture]()
            self.loop_key = ""
        elif o == RS_TOAST_CLOSE:
            self.toast = ""
        elif o == RS_HERO_PICK:
            if self.shown.byte_length() > 0:
                var key = self.shown
                self.toggle_pick(key)
        elif o >= RS_GRID:
            var c = clip_message(o - RS_GRID)
            var keys = self.grid_keys()
            if c[0] < len(keys):
                if c[1]:
                    self.toggle_pick(keys[c[0]])
                else:
                    self.search([keys[c[0]]], keys[c[0]])
        if had_results != (len(self.like) > 0) or width != self.width:
            self.fit(width)
        self.version += 1

    def grid_keys(self) -> List[String]:
        """The keys the grid shows now: the results, or the sample before any search."""
        if len(self.like) > 0:
            var out = List[String]()
            for h in self.hits:
                out.append(h.key)
            return out^
        return self.sample.copy()

    # ---------- view

    def hero_for(self, width: Int) -> Int:
        """The playing clip's longest side: 480 on a wide window, the width less the margins on a phone."""
        return 480 if width >= 900 else max(200, min(480, width - 64))

    def pool_line(self) -> String:
        if not self.opened:
            return "Reading the pool…" if self.opening else "No pool open"
        return (grouped(len(self.episodes)) + " episodes · " + tenths(self.hours) + " h · " + String(self.n_sets) + " datasets · " +
                ("on the GPU" if self.gpu else "on the CPU"))

    def picture_of(self, key: String) -> Picture:
        """The poster at the tiles' size, or a quiet blank of that size while it decodes."""
        var p = self.fitted.get(key)
        if p:
            return p.value().copy()
        var side = self.tile_side if self.tile_side > 0 else 240
        var blank = Picture(List[UInt32](length=side * side * 3 // 4, fill=UInt32(0xFFE8E4E0)), side, side * 3 // 4)
        return blank^

    def tile(self, key: String, badge: String) -> ClipTile:
        var title = key
        var detail = String("")
        try:
            ref e = self.episodes[self.by_key[key]]
            title = e.task if e.task.byte_length() > 0 else key
            detail = robot_name(e.robot) + " · " + tenths(e.seconds) + " s · #" + String(e.episode)
        except:
            pass
        var pic = self.picture_of(key)
        var tip = "Episodes like " + key.replace(":", " #")
        for h in self.hits:
            if h.key == key:
                tip += " · score " + fixed5(h.score)
        return ClipTile(key, title, detail, badge, pic.pixels, pic.w, pic.h, shown=key == self.shown, picked=key in self.picked, tip=tip)

    def view(self, width: Int) -> View:
        var phone = width < 700
        var head = List[View]()
        head.append(Text("Robot search", TITLE))
        head.append(Text(self.pool_line(), CAPTION).tone(TONE_ACCENT).tag("robot-pool-line"))
        var controls = List[View]()
        if self.opened:
            var opts: List[String] = ["Every robot"]
            for r in self.robots:
                opts.append(robot_name(r))
            controls.append(Segmented(opts^, self.robot, self.base + RS_FILTER).tag("robot-filter"))
        if not phone:
            controls.append(Spacer())
        var n = len(self.picked)
        var picks = " (" + String(n) + ")" if n > 0 else String("")
        controls.append(Button("More like these" + picks, self.base + RS_MORE if n > 0 else 0, PROMINENT if n > 0 else SUBTLE, icon="search").tag("robot-more")
                        .tooltip("Episodes like all your picks at once"))
        controls.append(Button("Export" + picks, self.base + RS_EXPORT if n > 0 and not self.exporting else 0, SUBTLE, icon="download").tag("robot-export")
                        .tooltip("The picks as a LeRobot v3 dataset (video linked, not re-encoded)"))
        if n > 0:
            controls.append(Button("Clear", self.base + RS_CLEAR, SUBTLE).tag("robot-clear"))
        var top = VStack(head^, spacing=4).align(START)
        var bar = VStack(controls^, spacing=8).align(START).fill() if phone else HStack(controls^, spacing=8).align(CENTER).fill()
        var parts = List[View]()
        parts.append(top^)
        parts.append(bar^)
        if self.problem.byte_length() > 0:
            parts.append(Text(self.problem, CAPTION).tag("robot-problem"))
        if not self.opened:
            parts.append(Text("Reading the index and every episode's facts…" if self.opening else "Open a pool to start.", BODY).tag("robot-status"))
            return VStack(parts^, spacing=16).align(STRETCH).fill()
        var tiles = List[ClipTile]()
        if len(self.like) == 0:
            for k in self.sample:
                tiles.append(self.tile(k, ""))
            parts.append(Text("Tap a clip to find every episode like it. Pick a few for More like these.", CAPTION).tag("robot-hint"))
            parts.append(ClipGrid(tiles, self.base + RS_GRID, clip_columns(self.grid_width(width), TILE_MIN), tag="robot-clip"))
            return VStack(parts^, spacing=16).align(STRETCH).fill()
        for h in self.hits:
            tiles.append(self.tile(h.key, score_text(h.score)))
        var hero = self.hero_view(phone)
        var grid = ClipGrid(tiles, self.base + RS_GRID, clip_columns(self.grid_width(width), TILE_MIN), tag="robot-clip")
        if phone:
            parts.append(hero^)
            parts.append(grid^)
        else:
            parts.append(HStack(hero^.width(self.hero_side + 40), grid^, spacing=24).align(START).fill())
        return VStack(parts^, spacing=16).align(STRETCH).fill()

    def hero_view(self, phone: Bool) -> View:
        var items = List[View]()
        var took = ("Ranked " + grouped(self.searched) + " episodes in " + millis(self.ms) + " on the " + self.device.upper() +
                    " · the " + String(len(self.hits)) + " most alike")
        if self.shown.byte_length() > 0:
            var pic = self.loop[self.frame].copy() if self.playing() else scale_rgba(self.posters.get(self.shown).or_else(self.picture_of(self.shown)), self.hero_side)
            items.append(Image(pic.pixels, pic.w, pic.h).tag("robot-hero"))
            var t = self.tile(self.shown, "")
            items.append(Text(t.title, HEADLINE).tag("robot-hero-title"))
            items.append(Text(t.detail, CAPTION))
            var mine = self.shown in self.picked
            items.append(HStack(Button("Unpick" if mine else "Pick", self.base + RS_HERO_PICK, SUBTLE, icon="check" if mine else "plus").tag("robot-hero-pick"),
                                Button("Back to the pool", self.base + RS_BACK, SUBTLE, icon="back").tag("robot-back"), spacing=8))
        else:
            items.append(Text("More like these " + String(len(self.like)), HEADLINE).tag("robot-hero-title"))
            for k in self.like:
                var t = self.tile(k, "")
                items.append(Text("· " + t.title, CAPTION))
            items.append(Button("Back to the pool", self.base + RS_BACK, SUBTLE, icon="back").tag("robot-back"))
        items.append(Divider().fill())
        items.append(Text(took, CAPTION).tone(TONE_ACCENT).tag("robot-took"))
        return Card(items^, spacing=10).tag("robot-hero-card")

    def overlays(self) -> List[View]:
        var out = List[View]()
        if self.toast.byte_length() > 0:
            var tip = self.exports_dir if len(self.exported) == 0 else self.exported[0]
            out.append(Toast(self.toast, on_close=self.base + RS_TOAST_CLOSE, seconds=12).tag("robot-toast").tooltip(tip + " · LeRobotDataset(root=…) loads it"))
        return out^
