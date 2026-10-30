# mojoui.videojobs: a video's slow work as background jobs (goal 39 M7), on the same jobs as a sheet's (mojoui.sheetjobs,
# omxcore's F-175): the app starts one, polls it once a display frame for its progress (frames done of frames) and its
# result, and can cancel it; the window stays live. Two kinds:
#
#   Analyze: a registry of analyzers (ANALYZERS: their names, what each finds) run over every frame by mojoui.videotable
#            (GPU colour cells → regions → the analyzer's rows). The answer is the VideoTable and the same rows as an omxcore
#            table (detections_table: frame, t, kind, code, damaged, x, y, w, h, track), which a sheet shows like any table.
#   Reel:    the frames where a table's flag is true (flag_frames over any table with a frame column), cut from the video by
#            mojoui.videoexport with faces blurred and captions burned in (RedactPlan), written as an mp4.
#
#   var job = analyze_job(path, 0)            # 0: "Objects & codes (warehouse preset)", 1: "Regions"
#   on each frame: job.poll() == JOB_DONE → var a = job.result(); a.found (VideoTable), a.table (omxcore Table)
#   var segs = segments_of(flag_frames(sheet, damaged_col, frame_col), fps)
#   var reel = reel_job(path, out_path, a.found, segs, blur="face", mark="pallet", captions)
#
# Presets (mojoui.vision_presets) hold every footage-specific number; the analyzers are generic. Honest: classic GPU vision
# (colour, motion, a printed stripe code), not a learned model; a model is one more entry here (the Analyzer slot).

from omxcore import Job, JobCtl, JobBody, start_job, Table, INT as MX_INT, DECIMAL as MX_DECIMAL, TEXT as MX_TEXT, BOOL as MX_BOOL
from mojoui.video import VideoSource
from mojoui.videotable import VideoTable, Progress, scan_with, RegionsAnalyzer, ColourRange, NO_CODE
from mojoui.vision_presets import warehouse_analyzer, warehouse_ranges, warm_range, WAREHOUSE_CELL, WARM
from mojoui.videoexport import RedactPlan, Caption, cut_with, cut_frames
from mojoui.imageops import ImageOps
from mojoui.player import Mark
from mojoui.sheet import Sheet, BOOL, INT
from mojoui.clock import now_ns

comptime ANALYZERS: List[String] = ["Objects & codes (warehouse preset)", "Regions"]
comptime ANALYZER_NOTES: List[String] = [
    "Tracked objects with their printed codes and damage, and faces to blur (GPU colour, motion and stripe codes)",
    "Every warm-coloured region on every frame, with its box (GPU colour cells)",
]
comptime ANALYZER_ROWS: List[String] = ["detections", "regions"]  # what the answer's table is called


def analyzer_names() -> List[String]:
    return materialize[ANALYZERS]()


def analyzer_note(k: Int) -> String:
    var notes = materialize[ANALYZER_NOTES]()
    return notes[k] if 0 <= k < len(notes) else String("")


def analyzer_rows(k: Int) -> String:
    """The answer's table name for analyzer k ("detections")."""
    var rows = materialize[ANALYZER_ROWS]()
    return rows[k] if 0 <= k < len(rows) else String("rows")


struct JobFrames(Progress):
    """A scan's or a cut's frames counted into its job (progress), and the job's cancel honoured between frames."""

    var ctl: JobCtl

    def __init__(out self, ctl: JobCtl):
        self.ctl = ctl

    def frame_done(mut self, frame: Int) raises:
        self.ctl.advance(1)
        self.ctl.check()


# ---------- analyze ----------


def detections_table(vt: VideoTable) raises -> Table:
    """A VideoTable's rows as a table: frame, t (seconds, 3 places), kind, code (empty: none read), damaged, x, y, w, h,
    track (empty: none)."""
    var t = Table.empty()
    var frame = t.add_column("frame", MX_INT)
    var secs = t.add_column("t", MX_DECIMAL, 3)
    var kind = t.add_column("kind", MX_TEXT)
    var code = t.add_column("code", MX_INT)
    var damaged = t.add_column("damaged", MX_BOOL)
    var x = t.add_column("x", MX_INT)
    var y = t.add_column("y", MX_INT)
    var w = t.add_column("w", MX_INT)
    var h = t.add_column("h", MX_INT)
    var track = t.add_column("track", MX_INT)
    for i in range(vt.rows()):
        t.append(frame, Int64(vt.frame[i]))
        t.append(secs, Int64(Int(vt.t[i] * 1000 + 0.5)))
        t.append_text(kind, vt.kind[i])
        if vt.code[i] != NO_CODE:
            t.append(code, Int64(vt.code[i]))
        else:
            t.append_null(code)
        t.append(damaged, Int64(1) if vt.damaged[i] else Int64(0))
        t.append(x, Int64(vt.x[i]))
        t.append(y, Int64(vt.y[i]))
        t.append(w, Int64(vt.w[i]))
        t.append(h, Int64(vt.h[i]))
        if vt.track[i] >= 0:
            t.append(track, Int64(vt.track[i]))
        else:
            t.append_null(track)
    t.check()
    return t^


def marks_of(vt: VideoTable, skip_kind: String = "") -> List[Mark]:
    """Boxes for a Player's overlay from the rows (all but `skip_kind`'s: faces stay unmarked), damaged ones flagged."""
    var out = List[Mark]()
    for i in range(vt.rows()):
        if vt.kind[i] != skip_kind:
            out.append(Mark(vt.frame[i], vt.x[i], vt.y[i], vt.w[i], vt.h[i], vt.damaged[i]))
    return out^


struct Analyzed(Movable):
    """An analyze job's answer: the rows (VideoTable and table), which analyzer, how long, the frames a second."""

    var found: VideoTable
    var table: Table
    var analyzer: Int
    var milliseconds: Float64

    def __init__(out self, var found: VideoTable, var table: Table, analyzer: Int, milliseconds: Float64):
        self.found = found^
        self.table = table^
        self.analyzer = analyzer
        self.milliseconds = milliseconds

    def take_table(mut self) -> Table:
        var out = self.table^
        self.table = Table.empty()
        return out^

    def take_sheet(mut self) -> Sheet:
        """The rows as a sheet (a DataGrid's source, with its GPU copy), taken out of the answer."""
        return Sheet(self.take_table().share())

    def take_found(mut self) -> VideoTable:
        var out = self.found^
        self.found = VideoTable()
        return out^


def analyze(path: String, which: Int, ctl: JobCtl = JobCtl()) raises -> Analyzed:
    """Analyzer `which` over every frame of the video at `path` (the job's body; a plain call with JobCtl())."""
    var t0 = now_ns()
    var video = VideoSource(path)
    ctl.add_total(video.frames)
    var count = JobFrames(ctl)
    var found: VideoTable
    if which == 0:
        var a = warehouse_analyzer()
        found = scan_with(video, a, warehouse_ranges(), count, WAREHOUSE_CELL)
    elif which == 1:
        var a = RegionsAnalyzer("region", 0, min_w=24, min_h=24)
        var ranges = List[ColourRange]()
        ranges.append(warm_range())
        found = scan_with(video, a, ranges, count, WAREHOUSE_CELL)
    else:
        raise Error("No analyzer " + String(which) + ": there are " + String(len(analyzer_names())))
    var table = detections_table(found)
    return Analyzed(found^, table^, which, Float64(now_ns() - t0) / 1e6)


struct AnalyzeJob(JobBody):
    comptime Out = Analyzed
    var path: String
    var which: Int

    def __init__(out self, path: String, which: Int):
        self.path = path
        self.which = which

    def run(mut self, ctl: JobCtl) raises -> Analyzed:
        return analyze(self.path, self.which, ctl)


def analyze_job(path: String, which: Int) -> Job[Analyzed]:
    """Analyzer `which` (ANALYZERS) over the video at `path`, off the caller's thread; progress counts frames."""
    return start_job(AnalyzeJob(path, which))


# ---------- reels ----------


def flag_frames(sheet: Sheet, flag: Int, frame: Int) -> List[Tuple[Int, Int]]:
    """The frames where some row's `flag` column is true (a BOOL, or a number ≠ 0), as merged runs [first, last + 1) of
    the `frame` column's numbers. The rows may be in any order (a sorted sheet), with edits."""
    var on = List[Bool]()
    for r in range(sheet.rows()):
        if not sheet.alive(r) or sheet.is_null(flag, r) or sheet.is_null(frame, r):
            continue
        if sheet.value(flag, r) == 0:
            continue
        var f = Int(sheet.value(frame, r))
        if f < 0:
            continue
        while len(on) <= f:
            on.append(False)
        on[f] = True
    var out = List[Tuple[Int, Int]]()
    var start = -1
    for f in range(len(on) + 1):
        var here = f < len(on) and on[f]
        if here and start < 0:
            start = f
        elif not here and start >= 0:
            out.append((start, f))
            start = -1
    return out^


def segments_of(runs: List[Tuple[Int, Int]], fps: Float64) -> List[Tuple[Float64, Float64]]:
    """Frame runs as seconds [start, end) (what videoexport.cut takes)."""
    var out = List[Tuple[Float64, Float64]]()
    for r in runs:
        out.append((Float64(r[0]) / fps, Float64(r[1]) / fps))
    return out^


def flag_columns(sheet: Sheet) -> List[Int]:
    """The columns a reel can keep frames by: BOOL columns."""
    var out = List[Int]()
    for c in range(sheet.columns()):
        if sheet.kind(c) == BOOL:
            out.append(c)
    return out^


def matching_column(sheet: Sheet, values: List[String], other_than: Int = -1) -> Tuple[Int, Int]:
    """The column (not `other_than`) holding the most of `values` as typed, and how many it holds: how a lookup finds its
    key without being told (shipments' pallet_code for the codes a video read). (-1, 0) when none holds any."""
    var want = Dict[String, Bool]()
    for v in values:
        want[v] = True
    var best = -1
    var most = 0
    for c in range(sheet.columns()):
        if c == other_than:
            continue
        var seen = Dict[String, Bool]()
        for r in range(sheet.rows()):
            if sheet.alive(r) and not sheet.is_null(c, r):
                var v = sheet.plain_text(c, r)
                if v in want:
                    seen[v] = True
        if len(seen) > most:
            most = len(seen)
            best = c
    return (best, most)


def lookup(sheet: Sheet, key: Int, value: Int) -> Dict[String, String]:
    """`key` column → `value` column, as typed (the first row wins a repeated key)."""
    var out = Dict[String, String]()
    for r in range(sheet.rows()):
        if sheet.alive(r) and not sheet.is_null(key, r):
            var k = sheet.plain_text(key, r)
            if k not in out:
                out[k] = sheet.plain_text(value, r)
    return out^


def codes_of(vt: VideoTable) -> List[String]:
    """Every code the video's rows read, once each, as text."""
    var seen = Dict[String, Bool]()
    var out = List[String]()
    for c in vt.code:
        if c != NO_CODE:
            var s = String(c)
            if s not in seen:
                seen[s] = True
                out.append(s)
    return out^


struct Reel(Movable):
    """A reel job's answer: the file, its frames and how long it took."""

    var path: String
    var frames: Int
    var seconds: Float64
    var milliseconds: Float64

    def __init__(out self, path: String, frames: Int, seconds: Float64, milliseconds: Float64):
        self.path = path
        self.frames = frames
        self.seconds = seconds
        self.milliseconds = milliseconds


def make_reel(source: String, path: String, found: VideoTable, segments: List[Tuple[Float64, Float64]], blur: String, mark: String,
              captions: List[Caption], ctl: JobCtl = JobCtl()) raises -> Reel:
    """The segments of `source`, rows of kind `blur` blurred ("" none), damaged rows of kind `mark` outlined ("" none), the
    captions burned in a band at the bottom left, as an mp4 at `path` (the job's body; a plain call with JobCtl())."""
    if len(segments) == 0:
        raise Error("No frames to keep: nothing in the table matches")
    var t0 = now_ns()
    var video = VideoSource(source)
    ctl.add_total(cut_frames(segments, video.fps, video.frames))
    var plan = RedactPlan(found.copy(), blur, 18, mark)
    for ref c in captions:
        plan.add_caption(c.first, c.last, c.text)
    plan.caption_box(40, video.height - 90, min(520, video.width - 80), 60)
    var ops = ImageOps()
    var count = JobFrames(ctl)
    var n = cut_with(video, segments, plan, path, ops, count)
    return Reel(path, n, Float64(n) / video.fps, Float64(now_ns() - t0) / 1e6)


struct ReelJob(JobBody):
    comptime Out = Reel
    var source: String
    var path: String
    var found: VideoTable
    var segments: List[Tuple[Float64, Float64]]
    var blur: String
    var mark: String
    var captions: List[Caption]

    def __init__(out self, source: String, path: String, var found: VideoTable, var segments: List[Tuple[Float64, Float64]], blur: String,
                 mark: String, var captions: List[Caption]):
        self.source = source
        self.path = path
        self.found = found^
        self.segments = segments^
        self.blur = blur
        self.mark = mark
        self.captions = captions^

    def run(mut self, ctl: JobCtl) raises -> Reel:
        return make_reel(self.source, self.path, self.found, self.segments, self.blur, self.mark, self.captions, ctl)


def reel_job(source: String, path: String, found: VideoTable, segments: List[Tuple[Float64, Float64]], blur: String, mark: String,
             captions: List[Caption]) -> Job[Reel]:
    """make_reel off the caller's thread; progress counts the frames written."""
    return start_job(ReelJob(source, path, found.copy(), segments.copy(), blur, mark, captions.copy()))
