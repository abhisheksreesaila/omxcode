# mojoui.mediatimeline: MediaTimeline, an iMovie-style video editor (goal 39 M11, the owner's approved design, D-911). A
# generic component: the media demo and omxplorer's video card embed it. Top to bottom: a slim header (back, the file's
# name and facts, undo, an accent "Export reel"); the viewer (the Player's picture, rounded, with Blur faces / Caption /
# Boxes chips in its corner, which preview the reel's edits on the GPU); the transport (time, frame back, play, frame
# forward, zoom); the sentence bar, the main way to cut: "Reel of [damaged pallets], [faces blurred], [shipment ID]
# burned in" + "Cut it" (each accent word opens its choices; Cut it builds the clips from the analysis rows); a tool row
# (Split, Trim start, Trim end, Delete); the timeline: a ruler, a filmstrip of real thumbnails as rounded clip tiles, the
# playhead with its time bubble, and data lanes under the strip (objects as pills, flagged ones in the warning tone, the
# rest muted; faces as dots; a TimeSeries column as a line: a drone's altitude); a footer (the edit's length and clips).
#
#   var ed = MediaTimeline(path, msg_base=300, canvas_base=300)  # probes first (waits: tests, start-up); raises when the file isn't a video
#   var ed = MediaTimeline(info, msg_base=300, canvas_base=300)  # a video already probed (a card's player.info): nothing waits
#   var ed = MediaTimeline.open_with(info, 300, 300, at=t, log=series, room_w=w, room_h=h)  # how an app opens it (both demos)
#                                                                # owns messages 300 … 363, canvases 300 … 302
#   ed.use_rows(table, blur_kind="face", object_kind="pallet", object_label="Pallets", flag_word="damaged")   # analysis rows → lanes, sentence, preview
#   ed.use_captions(flagged_captions(table, "pallet", names), "shipment ID")                                  # captions to burn in
#   ed.add_lane(value_lane("Altitude", series, "alt_m", "m"))                                                # any lane
#   update():   if ed.update(event): feed.poll(ed)           # True when the event was the editor's (feed: mediatimeline_jobs.TimelineFeed)
#   view():     ed.view(palette)                             # the whole editor; it grows into the room it is given
#   draw():     if ed.draws(canvas): ed.draw(canvas, surface, palette, font)
#   describe(): ed.describe()                                # for an agent: the clips, the playhead, the sentence, how to seek
#
# The model is plain numbers, tested without a screen: a Project is an ordered list of Clips (source frames [first, end));
# the sequence is the clips played one after another. split(seq), trim_start / trim_end (a clip to the playhead), the
# handles' set_in / set_out, delete, replace (Cut it), undo; sequence frame ↔ (clip, source frame); segments() for
# videoexport.cut. TimelineScale maps time ↔ x at a zoom (points per second) and a scroll; tiles() says which thumbnail
# goes where. Thumbnails are decoded off the UI thread (mediatimeline_jobs); drawing only copies cached pixels.
#
# Every action is an agent tool (buttons, menu items and the settable timeline): cut-it (and the sentence's words and
# their choices), split, trim-start, trim-end, delete, undo, export, play / pause, step-back, step-forward, zoom-in,
# zoom-out, the preview chips, done, and seek (the timeline set to seconds of the edit). Keys on the timeline and viewer:
# Space plays, S splits, [ and ] trim to the playhead, ←/→ step a frame, Backspace/Delete deletes the selected clip, Z undoes.
# Tracing (MOJOUI_TRACE / MOJOUI_TEST) prints `TIMELINE: <action> …; clips n, duration m:ss.t` lines.
#
# Looks: the theme's palette (one accent, its semantic tones, opaque tonal surfaces; no yellow of its own), with every
# colour and size the canvas draws with in TimelineStyle, so a design restyles the editor without touching the drawing.

from mojoui.app import Event
from mojoui.canvas import Surface, rgba
from mojoui.clock import trace_on
from mojoui.draw import rect, line, circle, blend, with_alpha
from mojoui.imageops import ImageOps, Frame, Edits
from mojoui.menus import ContextMenu, Item
from mojoui.picture import draw_fitted
from mojoui.player import Player, PlayerState
from mojoui.sentence import Sentence, Word
from mojoui.text import Font, MEDIUM, REGULAR, LEFT, CENTRE, RIGHT
from mojoui.theme import Palette
from mojoui.timeseries import TimeSeries, metric_label, metric_unit
from mojoui.video import VideoSource, VideoInfo
from mojoui.videotable import VideoTable, NO_CODE
from mojoui.videoexport import cut, NoEdits, RedactPlan, Caption
from mojoui.view import (View, Button, Canvas, Text, HStack, VStack, Card, Spacer, Overlay, CAPTION, HEADLINE, BODY, ICON_ONLY,
                         TOOL_INLINE, TOOL_INLINE_ON, SUBTLE, PROMINENT, PLAIN, NO_MSG, CENTER, START, END, PAN, ZOOM, TAP,
                         PRESS, RELEASE, KEY, SET_TO)
from mojoui.charts import fixed

# ---------- messages, from msg_base ----------
comptime M_PLAY = 0
comptime M_PAUSE = 1
comptime M_SPLIT = 2
comptime M_TRIM_START = 3
comptime M_TRIM_END = 4
comptime M_DELETE = 5
comptime M_UNDO = 6
comptime M_EXPORT = 7
comptime M_ZOOM_IN = 8
comptime M_ZOOM_OUT = 9
comptime M_STEP_BACK = 10
comptime M_STEP_FORWARD = 11
comptime M_TIMELINE = 12  # the timeline canvas's gestures
comptime M_PICTURE = 13  # the viewer's gestures
comptime M_FRAME = 14  # display frames (playing, thumbnails arriving, an export running)
comptime M_CLOSE = 15  # back / done (the editor only reports it: closed)
comptime M_CUT = 16  # the sentence's "Cut it"
comptime M_WORD_WHAT = 17  # the sentence's words: open their choices
comptime M_WORD_BLUR = 18
comptime M_WORD_CAPTION = 19
comptime M_MENU_CLOSE = 20
comptime M_CHIP_BLUR = 21
comptime M_CHIP_CAPTION = 22
comptime M_CHIP_BOXES = 23
comptime M_BLUR_ON = 24  # the blur word's choices
comptime M_BLUR_OFF = 25
comptime M_CAPTION_ON = 26
comptime M_CAPTION_OFF = 27
comptime M_WHAT = 32  # the what word's choices: M_WHAT + i, i < MAX_WHAT
comptime MAX_WHAT = 16
comptime M_PLAYER = 56  # the inner Player's own block (unused: the editor drives it), 56 … 60
comptime MESSAGES = 64

comptime C_PICTURE = 0  # canvases from canvas_base: the viewer (the inner Player's), its unused scrubber, the timeline
comptime C_TIMELINE = 2
comptime CANVASES = 3

comptime LANE_MARKERS = 0
comptime LANE_VALUES = 1
comptime SHAPE_PILLS = 0  # markers drawn as pills spanning their time (stacked in rows when they overlap)
comptime SHAPE_DOTS = 1  # markers drawn as a run of small dots (many short sightings: faces)

comptime ZOOM_STEP = 1.6  # the zoom buttons' factor
comptime MAX_FRAME_POINTS = 14.0  # the most zoomed in: one frame this many points wide
comptime HANDLE_GRAB = 14.0  # (points) how near a selected clip's edge a press grabs its handle

comptime MENU_NONE = 0
comptime MENU_WHAT = 1
comptime MENU_BLUR = 2
comptime MENU_CAPTION = 3


# ---------- time, as people read it ----------


def clock_tenths(seconds: Float64) -> String:
    """0:12.4 (tenths of a second); 1:02:03.5 from an hour on."""
    var tenths = Int(max(seconds, 0.0) * 10 + 1e-6)
    var s = tenths // 10
    var h = s // 3600
    var m = (s // 60) % 60
    var ss = s % 60
    var tail = ("0" if ss < 10 else "") + String(ss) + "." + String(tenths % 10)
    if h > 0:
        return String(h) + ":" + ("0" if m < 10 else "") + String(m) + ":" + tail
    return String(m) + ":" + tail


def _clock_whole(t: Float64) -> String:
    var s = Int(t + 0.5)
    return String(s // 60) + ":" + ("0" if s % 60 < 10 else "") + String(s % 60)


# ---------- the project: clips in order ----------


@fieldwise_init
struct Clip(Copyable, Movable, ImplicitlyCopyable, Equatable, Writable):
    """A run of the source: frames [first, end)."""
    var first: Int
    var end: Int

    def length(self) -> Int:
        return self.end - self.first

    def __eq__(self, other: Self) -> Bool:
        return self.first == other.first and self.end == other.end

    def write_to[W: Writer](self, mut writer: W):
        writer.write("[", self.first, ",", self.end, ")")


struct Project(Copyable, Movable):
    """An edit of one source video: its clips in play order, the selected clip, and the history for undo."""
    var clips: List[Clip]
    var fps: Float64
    var source_frames: Int
    var selected: Int  # -1: none
    var history: List[List[Clip]]

    def __init__(out self, fps: Float64, source_frames: Int):
        self.fps = fps
        self.source_frames = max(source_frames, 1)
        self.clips = List[Clip]()
        self.clips.append(Clip(0, self.source_frames))
        self.selected = 0
        self.history = List[List[Clip]]()

    # ---- the sequence ----

    def length(self) -> Int:
        """Frames in the sequence."""
        var n = 0
        for c in self.clips:
            n += c.length()
        return n

    def duration(self) -> Float64:
        return Float64(self.length()) / self.fps

    def start_of(self, k: Int) -> Int:
        """The sequence frame clip k starts on."""
        var n = 0
        for i in range(min(k, len(self.clips))):
            n += self.clips[i].length()
        return n

    def clip_at(self, seq: Int) -> Int:
        """The clip showing sequence frame `seq` (clamped: the last clip at or past the end)."""
        var n = 0
        for i in range(len(self.clips)):
            n += self.clips[i].length()
            if seq < n:
                return i
        return len(self.clips) - 1

    def source_frame(self, seq: Int) -> Int:
        """The source frame on show at sequence frame `seq`."""
        var k = self.clip_at(max(seq, 0))
        var local = min(max(seq - self.start_of(k), 0), self.clips[k].length() - 1)
        return self.clips[k].first + local

    def spans(self, first: Int, end: Int) -> List[Tuple[Int, Int]]:
        """A run of source frames [first, end) as it appears in the sequence: sequence frame ranges, in order (a run cut
        by a split shows twice or not at all)."""
        var out = List[Tuple[Int, Int]]()
        var at = 0
        for c in self.clips:
            var a = max(first, c.first)
            var b = min(end, c.end)
            if b > a:
                out.append((at + a - c.first, at + b - c.first))
            at += c.length()
        return out^

    def segments(self) -> List[Tuple[Float64, Float64]]:
        """The clips as [start, end) seconds of the source, for mojoui.videoexport.cut."""
        var out = List[Tuple[Float64, Float64]]()
        for c in self.clips:
            out.append((Float64(c.first) / self.fps, Float64(c.end) / self.fps))
        return out^

    # ---- edits (each returns False and changes nothing when it can't apply) ----

    def remember(mut self):
        """Saves the clips for undo (an edit calls it; a handle drag calls it once, when it starts)."""
        self.history.append(self.clips.copy())

    def undo(mut self) -> Bool:
        if len(self.history) == 0:
            return False
        self.clips = self.history.pop()
        self.selected = min(self.selected, len(self.clips) - 1)
        return True

    def split(mut self, seq: Int) -> Bool:
        """Cuts the clip under sequence frame `seq` in two there; the right-hand part is selected. Nothing at a clip's edge."""
        var k = self.clip_at(seq)
        var local = seq - self.start_of(k)
        var c = self.clips[k]
        if local <= 0 or local >= c.length():
            return False
        self.remember()
        self.clips[k] = Clip(c.first, c.first + local)
        self.clips.insert(k + 1, Clip(c.first + local, c.end))
        self.selected = k + 1
        return True

    def trim_start(mut self, k: Int, seq: Int) -> Bool:
        """Clip k now starts at the picture on show at sequence frame `seq` (inside it, past its first frame)."""
        if not (0 <= k < len(self.clips)):
            return False
        var local = seq - self.start_of(k)
        var c = self.clips[k]
        if local <= 0 or local >= c.length():
            return False
        self.remember()
        self.clips[k] = Clip(c.first + local, c.end)
        return True

    def trim_end(mut self, k: Int, seq: Int) -> Bool:
        """Clip k now ends just before the picture on show at sequence frame `seq` (inside it, past its first frame)."""
        if not (0 <= k < len(self.clips)):
            return False
        var local = seq - self.start_of(k)
        var c = self.clips[k]
        if local <= 0 or local >= c.length():
            return False
        self.remember()
        self.clips[k] = Clip(c.first, c.first + local)
        return True

    def set_in(mut self, k: Int, source: Int) -> Bool:
        """A start handle dragged: clip k starts at source frame `source` (kept inside the source, one frame at least)."""
        if not (0 <= k < len(self.clips)):
            return False
        var c = self.clips[k]
        var f = min(max(source, 0), c.end - 1)
        if f == c.first:
            return False
        self.clips[k] = Clip(f, c.end)
        return True

    def set_out(mut self, k: Int, source: Int) -> Bool:
        """An end handle dragged: clip k ends at source frame `source` (exclusive)."""
        if not (0 <= k < len(self.clips)):
            return False
        var c = self.clips[k]
        var e = min(max(source, c.first + 1), self.source_frames)
        if e == c.end:
            return False
        self.clips[k] = Clip(c.first, e)
        return True

    def delete(mut self, k: Int) -> Bool:
        """Removes clip k (the last one left stays: a project always has a clip)."""
        if not (0 <= k < len(self.clips)) or len(self.clips) <= 1:
            return False
        self.remember()
        _ = self.clips.pop(k)
        self.selected = min(k, len(self.clips) - 1)
        return True

    def replace(mut self, var clips: List[Clip]) -> Bool:
        """The whole edit becomes `clips` (Cut it); nothing when the list is empty."""
        if len(clips) == 0:
            return False
        self.remember()
        self.clips = clips^
        self.selected = -1
        return True


# ---------- the timeline's scale: time ↔ x ----------


@fieldwise_init
struct Tile(Copyable, Movable, ImplicitlyCopyable):
    """One filmstrip tile: x (points from the canvas's left) and width (the last tile of a clip is cut short), the clip,
    and the source time whose picture it shows (the picture at the tile's left edge, as iMovie does)."""
    var x: Float64
    var w: Float64
    var clip: Int
    var source_t: Float64


struct TimelineScale(Copyable, Movable):
    var pps: Float64  # points per second of the sequence
    var scroll: Float64  # the sequence time at x = lead
    var lead: Float64  # points of room before the sequence starts (and after it ends)

    def __init__(out self, pps: Float64 = 40.0, lead: Float64 = 16.0):
        self.pps = pps
        self.scroll = 0.0
        self.lead = lead

    def x_of(self, t: Float64) -> Float64:
        return self.lead + (t - self.scroll) * self.pps

    def t_of(self, x: Float64) -> Float64:
        return self.scroll + (x - self.lead) / self.pps

    def fit_pps(self, width: Float64, duration: Float64) -> Float64:
        """The zoom that shows the whole sequence in `width` points."""
        return max(width - 2 * self.lead, 1.0) / max(duration, 1e-6)

    def fit(mut self, width: Float64, duration: Float64):
        self.pps = self.fit_pps(width, duration)
        self.scroll = 0.0

    def clamp(mut self, width: Float64, duration: Float64, fps: Float64):
        """Keeps the zoom between the whole sequence and one frame = MAX_FRAME_POINTS, and the scroll inside the sequence."""
        self.pps = min(max(self.pps, self.fit_pps(width, duration)), MAX_FRAME_POINTS * fps)
        var most = max(duration - max(width - 2 * self.lead, 1.0) / self.pps, 0.0)
        self.scroll = min(max(self.scroll, 0.0), most)

    def zoom(mut self, factor: Float64, x: Float64, width: Float64, duration: Float64, fps: Float64):
        """Zooms by `factor` keeping the time under x where it is."""
        var anchor = self.t_of(x)
        self.pps *= factor
        self.clamp(width, duration, fps)
        self.scroll = anchor - (x - self.lead) / self.pps
        self.clamp(width, duration, fps)

    def follow(mut self, t: Float64, width: Float64, duration: Float64, fps: Float64):
        """Scrolls so time t is in view (a third of the way in, when it has left the view)."""
        var x = self.x_of(t)
        if x < self.lead or x > width - self.lead:
            self.scroll = t - (width - 2 * self.lead) / (3 * self.pps)
            self.clamp(width, duration, fps)


def tiles(project: Project, scale: TimelineScale, width: Float64, tile_w: Float64) -> List[Tile]:
    """The filmstrip tiles in view (x in [0, width)), clip by clip: each clip is a run of tile_w-wide tiles from its start,
    the last one cut at its end; each shows the source picture at the tile's left edge."""
    var out = List[Tile]()
    if tile_w <= 0:
        return out^
    var seq_t = 0.0
    for k in range(len(project.clips)):
        var c = project.clips[k]
        var len_t = Float64(c.length()) / project.fps
        var x0 = scale.x_of(seq_t)
        var x1 = scale.x_of(seq_t + len_t)
        if x1 > 0 and x0 < width:
            var i = max(Int((0 - x0) / tile_w), 0)  # (the first tile that reaches into view)
            while True:
                var tx = x0 + Float64(i) * tile_w
                if tx >= x1 or tx >= width:
                    break
                out.append(Tile(tx, min(tile_w, x1 - tx), k, Float64(c.first) / project.fps + Float64(i) * tile_w / scale.pps))
                i += 1
        seq_t += len_t
    return out^


def ruler_step(pps: Float64, room: Float64 = 64.0) -> Float64:
    """Seconds between the ruler's labels: the smallest nice step at least `room` points apart."""
    var steps: List[Float64] = [0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0, 600.0, 1800.0, 3600.0]
    for s in steps:
        if s * pps >= room:
            return s
    return 3600.0


# ---------- lanes ----------


struct Lane(Copyable, Movable):
    """A row under the filmstrip. Markers: intervals of source time (an object's sightings), each with a label and a flag;
    values: a line over source time (a TimeSeries column)."""
    var label: String  # "Pallets", "Faces", "Altitude"
    var kind: Int  # LANE_MARKERS, LANE_VALUES
    var shape: Int  # SHAPE_PILLS, SHAPE_DOTS
    var flag_word: String  # what a flag means ("damaged"): the sentence offers "damaged pallets"
    var starts: List[Float64]  # markers: source seconds [start, end)
    var ends: List[Float64]
    var labels: List[String]
    var flags: List[Bool]
    var row: List[Int]  # the row each pill sits in (overlapping pills stack)
    var rows: Int
    var times: List[Float64]  # values: source seconds, rising
    var values: List[Float64]
    var unit: String

    def __init__(out self, label: String, kind: Int, shape: Int = SHAPE_PILLS, flag_word: String = "", unit: String = ""):
        self.label = label
        self.kind = kind
        self.shape = shape
        self.flag_word = flag_word
        self.starts = List[Float64]()
        self.ends = List[Float64]()
        self.labels = List[String]()
        self.flags = List[Bool]()
        self.row = List[Int]()
        self.rows = 1
        self.times = List[Float64]()
        self.values = List[Float64]()
        self.unit = unit

    def markers(self) -> Int:
        return len(self.starts)

    def flagged(self) -> Int:
        var n = 0
        for f in self.flags:
            if f:
                n += 1
        return n

    def add(mut self, start: Float64, end: Float64, label: String = "", flag: Bool = False):
        self.starts.append(start)
        self.ends.append(end)
        self.labels.append(label)
        self.flags.append(flag)

    def stack(mut self, room: Float64 = 0.1):
        """Sorts the markers by start and gives each pill the first row free at its start (`room` seconds apart)."""
        var order = List[Int]()
        for i in range(len(self.starts)):
            var j = len(order)
            while j > 0 and self.starts[order[j - 1]] > self.starts[i]:
                j -= 1
            order.insert(j, i)
        var s = List[Float64]()
        var e = List[Float64]()
        var l = List[String]()
        var f = List[Bool]()
        for i in order:
            s.append(self.starts[i])
            e.append(self.ends[i])
            l.append(self.labels[i])
            f.append(self.flags[i])
        self.starts = s^
        self.ends = e^
        self.labels = l^
        self.flags = f^
        self.row = List[Int]()
        var free = List[Float64]()  # each row's end
        for i in range(len(self.starts)):
            var r = -1
            for k in range(len(free)):
                if free[k] <= self.starts[i] and r < 0:
                    r = k
            if r < 0:
                r = len(free)
                free.append(0.0)
            free[r] = self.ends[i] + room
            self.row.append(r)
        self.rows = max(len(free), 1)

    def height(self) -> Float64:
        """Points: a pill lane grows a row per stack of overlapping pills; dots and lines are one row."""
        if self.kind == LANE_VALUES:
            return 40.0
        if self.shape == SHAPE_DOTS:
            return 22.0
        return 8.0 + 17.0 * Float64(self.rows)

    def value_at(self, t: Float64) -> Float64:
        """The line's value at source time t (linear between samples, clamped)."""
        var n = len(self.times)
        if n == 0:
            return 0.0
        if t <= self.times[0]:
            return self.values[0]
        if t >= self.times[n - 1]:
            return self.values[n - 1]
        var lo = 0
        var hi = n - 1
        while hi - lo > 1:
            var mid = (lo + hi) // 2
            if self.times[mid] <= t:
                lo = mid
            else:
                hi = mid
        var span = self.times[hi] - self.times[lo]
        var w = (t - self.times[lo]) / span if span > 0 else 0.0
        return self.values[lo] * (1 - w) + self.values[hi] * w

    def low_high(self) -> Tuple[Float64, Float64]:
        if len(self.values) == 0:
            return (0.0, 1.0)
        var lo = self.values[0]
        var hi = self.values[0]
        for v in self.values:
            lo = min(lo, v)
            hi = max(hi, v)
        if hi - lo < 1e-9:
            hi = lo + 1.0
        return (lo, hi)


def markers_from_rows(frames: List[Int], kinds: List[String], flagged: List[Bool], kind: String, fps: Float64, label: String,
                      flagged_only: Bool = False, shape: Int = SHAPE_PILLS, gap: Int = 3) -> Lane:
    """A markers lane from rows (one per thing seen on a frame: its frame, kind and flag, as mojoui.videotable writes them):
    the frames where a row of `kind` (flagged ones only, if asked) is seen, merged into intervals; a gap of up to `gap`
    frames doesn't break one (a detection that flickers). Intervals are source seconds [first frame, last frame + 1); a
    marker is flagged when any of its rows is."""
    var seen = List[Tuple[Int, Bool]]()
    for i in range(min(len(frames), len(kinds))):
        var f = i < len(flagged) and flagged[i]
        if kinds[i] == kind and (not flagged_only or f):
            seen.append((frames[i], f))
    var just = List[Int]()
    for p in seen:
        just.append(p[0])
    sort(just)
    var flag_at = Dict[Int, Bool]()
    for p in seen:
        if p[1]:
            flag_at[p[0]] = True
    var lane = Lane(label, LANE_MARKERS, shape)
    var i = 0
    while i < len(just):
        var a = just[i]
        var b = a
        var fl = a in flag_at
        while i + 1 < len(just) and just[i + 1] - b <= gap + 1:
            i += 1
            b = just[i]
            fl = fl or b in flag_at
        lane.add(Float64(a) / fps, Float64(b + 1) / fps, "", fl)
        i += 1
    lane.stack()
    return lane^


def markers_from_table(table: VideoTable, kind: String, label: String, flagged_only: Bool = False, shape: Int = SHAPE_PILLS,
                       gap: Int = 3) -> Lane:
    """markers_from_rows over a VideoTable's rows (flagged = its damaged column)."""
    return markers_from_rows(table.frame, table.kind, table.damaged, kind, table.fps, label, flagged_only, shape, gap)


def objects_from_table(table: VideoTable, kind: String, label: String, flag_word: String = "") -> Lane:
    """A pill per object of `kind` (rows grouped by their track, or by their code when untracked): from its first
    sighting to its last, labelled with its code, flagged when any of its rows is (damaged). Overlapping pills stack."""
    var keys = List[Int]()
    var first = List[Int]()
    var last = List[Int]()
    var code = List[Int]()
    var flag = List[Bool]()
    var index = Dict[Int, Int]()
    for i in range(table.rows()):
        if table.kind[i] != kind:
            continue
        var key = table.track[i] if table.track[i] >= 0 else (1_000_000_000 + table.code[i] if table.code[i] != NO_CODE else -1)
        if key < 0:
            continue
        var k = index.get(key, -1)
        if k < 0:
            k = len(keys)
            index[key] = k
            keys.append(key)
            first.append(table.frame[i])
            last.append(table.frame[i])
            code.append(table.code[i])
            flag.append(table.damaged[i])
        else:
            first[k] = min(first[k], table.frame[i])
            last[k] = max(last[k], table.frame[i])
            if code[k] == NO_CODE:
                code[k] = table.code[i]
            flag[k] = flag[k] or table.damaged[i]
    var lane = Lane(label, LANE_MARKERS, SHAPE_PILLS, flag_word)
    for k in range(len(keys)):
        lane.add(Float64(first[k]) / table.fps, Float64(last[k] + 1) / table.fps, String(code[k]) if code[k] != NO_CODE else "", flag[k])
    lane.stack()
    return lane^


def value_lane(label: String, series: TimeSeries, column: String, unit: String = "") -> Lane:
    """A values lane: a TimeSeries column over its times (source seconds), drawn as a line under the strip."""
    var lane = Lane(label, LANE_VALUES, SHAPE_PILLS, "", unit)
    lane.times = series.times.copy()
    lane.values = series.column(column)
    return lane^


def clips_from_markers(lane: Lane, flagged_only: Bool, fps: Float64, source_frames: Int, pad: Float64 = 0.0) -> List[Clip]:
    """The clips a sentence cuts: the lane's markers (flagged ones only, if asked), widened by `pad` seconds each side,
    merged where they touch or overlap, in source order, as frame ranges inside the source."""
    var spans = List[Tuple[Int, Int]]()
    for i in range(lane.markers()):
        if flagged_only and not lane.flags[i]:
            continue
        var a = max(Int((lane.starts[i] - pad) * fps + 0.5), 0)
        var b = min(Int((lane.ends[i] + pad) * fps + 0.5), source_frames)
        if b > a:
            var j = len(spans)
            while j > 0 and spans[j - 1][0] > a:
                j -= 1
            spans.insert(j, (a, b))
    var out = List[Clip]()
    for sp in spans:
        if len(out) > 0 and sp[0] <= out[len(out) - 1].end:
            out[len(out) - 1] = Clip(out[len(out) - 1].first, max(out[len(out) - 1].end, sp[1]))
        else:
            out.append(Clip(sp[0], sp[1]))
    return out^


# ---------- thumbnails ----------


def thumb_interval(duration: Float64, most: Int = 160) -> Float64:
    """Seconds between cached thumbnails: one every half second, coarser for a long video (at most `most` of them)."""
    return max(0.5, duration / Float64(most))


def thumb_count(duration: Float64, interval: Float64) -> Int:
    return max(Int(duration / interval) + 1, 1)


def decode_thumbnails(path: String, interval: Float64, first: Int, count: Int, height: Int, use_gpu: Bool = True) raises -> List[Frame]:
    """Thumbnails first … first + count - 1 (thumbnail i: the source picture at i × interval seconds), `height` pixels tall
    at the video's shape, scaled on the GPU (mojoui.imageops; the CPU without one). Reads on through near frames, seeks
    past far ones. What a background job runs (mojoui.mediatimeline_jobs) and the test calls straight."""
    var src = VideoSource(path)
    var ops = ImageOps(use_gpu)
    var tw = max(height * src.width // max(src.height, 1), 1)
    var frame = Frame(src.width, src.height)
    var out = List[Frame]()
    for i in range(first, first + count):
        var want = min(Int(Float64(i) * interval * src.fps + 0.5), src.frames - 1)
        var at = src.position()
        if not (at <= want <= at + 45):
            src.seek_frame(want)
        while src.position() < want:
            if not src.next_into(frame.pixels):
                break
        if not src.next_into(frame.pixels):
            break
        out.append(ops.crop(frame, 0, 0, src.width, src.height, tw, height, bilinear=True))
    return out^


struct Thumbnails(Movable):
    """The cache: thumbnail i is the source picture at i × interval (an empty Frame until it has arrived)."""
    var interval: Float64
    var height: Int  # pixels
    var frames: List[Frame]
    var arrived: Int  # thumbnails 0 … arrived - 1 are in

    def __init__(out self, duration: Float64, height: Int):
        self.interval = thumb_interval(duration)
        self.height = height
        self.frames = List[Frame]()
        for _ in range(thumb_count(duration, self.interval)):
            self.frames.append(Frame(0, 0))
        self.arrived = 0

    def count(self) -> Int:
        return len(self.frames)

    def complete(self) -> Bool:
        return self.arrived >= len(self.frames)

    def put(mut self, first: Int, var got: List[Frame]):
        """Thumbnails from `first` on, as a job returns them."""
        for j in range(len(got)):
            if first + j < len(self.frames):
                self.frames[first + j] = got[j].copy()
        self.arrived = max(self.arrived, first + len(got))
        if len(got) == 0:  # (the decoder ran out early: what is missing stays missing)
            self.arrived = len(self.frames)

    def index_for(self, source_t: Float64) -> Int:
        return min(max(Int(source_t / self.interval + 1e-6), 0), len(self.frames) - 1)


# ---------- the reel: what an export (and the preview) does to each frame ----------


def render_preview(mut frame: Frame, mut plan: Optional[RedactPlan], mut ops: ImageOps, source_frame: Int) raises:
    """The reel's edits for `source_frame` applied to `frame` (its pixels): what the viewer's preview shows. Runs in a
    job (mediatimeline_jobs.PreviewJob) or a test, never in a draw: ImageOps holds a GPU context."""
    if not plan:
        return
    var edits = Edits()
    plan.value().plan(source_frame, 0, ops, edits)
    if len(edits.list) > 0:
        ops.apply(frame, edits)


def copy_table(t: VideoTable) -> VideoTable:
    """A VideoTable's rows, copied (a background export owns its own)."""
    var out = VideoTable()
    out.frame = t.frame.copy()
    out.t = t.t.copy()
    out.kind = t.kind.copy()
    out.x = t.x.copy()
    out.y = t.y.copy()
    out.w = t.w.copy()
    out.h = t.h.copy()
    out.code = t.code.copy()
    out.damaged = t.damaged.copy()
    out.track = t.track.copy()
    out.cx = t.cx.copy()
    out.cy = t.cy.copy()
    out.value = t.value.copy()
    out.lat = t.lat.copy()
    out.lon = t.lon.copy()
    out.gsd = t.gsd.copy()
    out.fps = t.fps
    out.frames = t.frames
    return out^


struct ReelSpec(Movable):
    """Everything an export needs: the clips (source seconds) and, when there are analysis rows, what to blur, outline
    and caption (an empty kind: not that)."""
    var segments: List[Tuple[Float64, Float64]]
    var table: Optional[VideoTable]
    var blur_kind: String
    var mark_kind: String
    var captions: List[Caption]

    def __init__(out self, var segments: List[Tuple[Float64, Float64]]):
        self.segments = segments^
        self.table = None
        self.blur_kind = ""
        self.mark_kind = ""
        self.captions = List[Caption]()

    def plan(self) -> Optional[RedactPlan]:
        if not self.table or (self.blur_kind == "" and self.mark_kind == "" and len(self.captions) == 0):
            return None
        var p = RedactPlan(copy_table(self.table.value()), self.blur_kind, 14, self.mark_kind)
        for c in self.captions:
            p.add_caption(c.first, c.last, c.text)
        return p^


def write_reel(source: String, path: String, spec: ReelSpec, use_gpu: Bool = True) raises -> Int:
    """The edit as an mp4 at `path` (H.264, the source's size and rate), each frame edited as the spec says; the frames
    written. What the export job runs, and the test calls straight."""
    var video = VideoSource(source)
    var ops = ImageOps(use_gpu)
    var plan = spec.plan()
    if plan:
        return cut(video, spec.segments, plan.value(), path, ops)
    var none = NoEdits()
    return cut(video, spec.segments, none, path, ops)


def export_name(path: String) -> String:
    """Where an edit of `path` is exported: beside it, "<name>-reel.mp4"."""
    var dot = path.rfind(".")
    var slash = path.rfind("/")
    if dot > slash:
        return String(path[byte=:dot]) + "-reel.mp4"
    return path + "-reel.mp4"


# ---------- looks ----------


struct TimelineStyle(Copyable, Movable):
    """Every colour and size the timeline canvas draws with (points). Colours come from the theme's palette (paint);
    a design changes the sizes here."""
    var back: UInt32  # behind the timeline: the panel's tone
    var ruler_ink: UInt32
    var tick: UInt32
    var empty_tile: UInt32  # a tile whose thumbnail hasn't arrived
    var clip_edge: UInt32  # the hairline between tiles
    var select: UInt32  # the selected clip's outline and handles: the theme's one accent
    var grip: UInt32  # the dark line on a handle
    var playhead: UInt32
    var bubble_ink: UInt32
    var lane_ink: UInt32
    var flag: UInt32  # flagged pills: the theme's warning tone
    var flag_fill: UInt32
    var flag_ink: UInt32
    var quiet: UInt32  # the rest: muted
    var quiet_fill: UInt32
    var quiet_ink: UInt32
    var dot: UInt32
    var line: UInt32
    var label_back: UInt32
    var ruler_h: Float64
    var strip_h: Float64
    var lane_gap: Float64
    var gap: Float64  # between clips
    var radius: Float64
    var frame_w: Float64  # the selection outline's thickness
    var handle_w: Float64
    var text: Float64  # label size

    def __init__(out self, pal: Palette):
        self.back = 0
        self.ruler_ink = 0
        self.tick = 0
        self.empty_tile = 0
        self.clip_edge = 0
        self.select = 0
        self.grip = 0
        self.playhead = 0
        self.bubble_ink = 0
        self.lane_ink = 0
        self.flag = 0
        self.flag_fill = 0
        self.flag_ink = 0
        self.quiet = 0
        self.quiet_fill = 0
        self.quiet_ink = 0
        self.dot = 0
        self.line = 0
        self.label_back = 0
        self.ruler_h = 22
        self.strip_h = 64
        self.lane_gap = 4
        self.gap = 2
        self.radius = 9
        self.frame_w = 3
        self.handle_w = 12
        self.text = 10.5
        self.paint(pal)

    def paint(mut self, pal: Palette):
        """The colours, from the theme's palette (the sizes stay)."""
        self.back = pal.card
        self.ruler_ink = pal.ink3
        self.tick = pal.line_strong
        self.empty_tile = pal.raised
        self.clip_edge = with_alpha(rgba(0, 0, 0), 0.35)
        self.select = pal.accent
        self.grip = with_alpha(rgba(0, 0, 0), 0.6)
        self.playhead = pal.ink
        self.bubble_ink = pal.card
        self.lane_ink = pal.ink2
        self.flag = pal.bad
        self.flag_fill = blend(pal.card, pal.bad, 0.16)
        self.flag_ink = blend(pal.bad, pal.ink, 0.25)
        self.quiet = blend(pal.card, pal.ink3, 0.45)
        self.quiet_fill = blend(pal.card, pal.ink3, 0.10)
        self.quiet_ink = pal.ink2
        self.dot = blend(pal.card, pal.ink2, 0.7)
        self.line = pal.accent
        self.label_back = pal.card


# ---------- the editor ----------


struct MediaTimeline(Movable):
    var player: Player  # decodes and draws the viewer's picture (its own state is driven from the sequence)
    var project: Project
    var seq: PlayerState  # the sequence's clock: frame, playing
    var scale: TimelineScale
    var thumbs: Thumbnails
    var lanes: List[Lane]
    var style: TimelineStyle  # its colours follow the palette each draw; its sizes are the editor's (restyle: set them)
    var base: Int
    var canvas: Int
    var title: String
    var facts: String  # the header's meta line
    var width: Float64  # the timeline's width in points, from its last draw
    var room_w: Int  # the room the app gives the editor (points; 0: unknown, the viewer then grows)
    var room_h: Int
    var version: Int
    var drag: Int  # what a press grabbed: 0 nothing, 1 scrub, 2 start handle, 3 end handle
    var drag_clip: Int
    var closed: Bool  # back / Done was tapped (the app closes the editor)
    var export_path: String  # set by the export tool; mediatimeline_jobs.TimelineFeed writes it off the UI thread
    var exported_frames: Int
    var status: String  # the last thing that happened (the footer, an agent)
    # the reel: analysis rows and what the sentence and chips ask of them
    var table: Optional[VideoTable]
    var blur_kind: String  # rows of this kind are blurred ("face"); "" when there is none
    var blur_noun: String  # "faces"
    var mark_kind: String  # rows of this kind can be outlined when flagged (the Boxes chip)
    var captions: List[Caption]
    var caption_word: String  # "shipment ID"
    var blur_on: Bool
    var caption_on: Bool
    var boxes_on: Bool
    var what: Int  # the sentence's subject: an index into what_options()
    var menu: Int  # the open word menu (MENU_NONE …)
    var preview: Frame  # the viewer's frame with the reel's edits (when a chip is on)
    var preview_key: Int  # which source frame and settings it shows (-1: none)
    var ops: Optional[ImageOps]  # the preview's GPU (made on first use)
    var plan: Optional[RedactPlan]  # the preview's plan, rebuilt when the chips change
    var plan_key: Int
    var expecting: Bool  # rows are on their way (expect_rows): the chips show and can be set before they land
    var preview_busy: Bool  # a preview is being made off the UI thread (mediatimeline_jobs.TimelineFeed): ops and plan are with it

    def __init__(out self, path: String, msg_base: Int = 300, canvas_base: Int = 300) raises:
        """Probes `path` here (ffprobe: it waits), then as MediaTimeline(info): for tests and an app's start-up; an app's
        update() opens one from a video it already knows (a card's player.info), which waits for nothing."""
        self = MediaTimeline(VideoSource(path).info(), msg_base, canvas_base)

    def __init__(out self, info: VideoInfo, msg_base: Int = 300, canvas_base: Int = 300):
        self.player = Player(info, msg_base + M_PLAYER, canvas_base + C_PICTURE)
        var fps = self.player.info.fps
        self.project = Project(fps, self.player.info.frames)
        self.seq = PlayerState(fps, self.project.length(), self.project.duration())
        self.scale = TimelineScale()
        self.thumbs = Thumbnails(self.player.info.duration, 128)
        self.lanes = List[Lane]()
        self.style = TimelineStyle(Palette.plain())
        self.base = msg_base
        self.canvas = canvas_base
        var slash = info.path.rfind("/")
        self.title = String(info.path[byte=slash + 1:]) if slash >= 0 else info.path
        self.facts = (String(self.player.info.width) + "×" + String(self.player.info.height) + " · " + fixed(fps, 0) + " fps · "
                      + clock_tenths(self.player.info.duration))
        self.width = 1000.0
        self.room_w = 0
        self.room_h = 0
        self.scale.fit(self.width, self.project.duration())
        self.version = 1
        self.drag = 0
        self.drag_clip = -1
        self.closed = False
        self.export_path = ""
        self.exported_frames = -1
        self.status = ""
        self.table = None
        self.blur_kind = ""
        self.blur_noun = ""
        self.mark_kind = ""
        self.captions = List[Caption]()
        self.caption_word = ""
        self.blur_on = False
        self.caption_on = False
        self.boxes_on = False
        self.what = 0
        self.menu = MENU_NONE
        self.preview = Frame(0, 0)
        self.preview_key = -1
        self.ops = None
        self.plan = None
        self.plan_key = -1
        self.expecting = False
        self.preview_busy = False

    @staticmethod
    def open_with(info: VideoInfo, msg_base: Int, canvas_base: Int, at: Float64 = 0.0, log: Optional[TimeSeries] = None,
                  room_w: Int = 0, room_h: Int = 0) -> MediaTimeline:
        """The editor as an app opens it from a video it already shows (its player's info: nothing waits): the playhead
        at `at` seconds (0: mid-way, so a split can start at once), the log's first two measures as lines under the
        filmstrip (not its heading or position), sized to the room the app gives it. Rows come later (use_rows, or
        mojoui.videojobs.use_analysis when the analysis lands)."""
        var ed = MediaTimeline(info, msg_base, canvas_base)
        ed.seek(at if at > 0 else ed.project.duration() / 2)
        if log:
            ref ts = log.value()
            var shown = 0
            for i in range(len(ts.names)):
                var m = ts.names[i]
                if shown < 2 and m != "heading_deg" and m != "lat" and m != "lon" and m != "t":
                    ed.add_lane(value_lane(metric_label(m), ts, m, metric_unit(m)))
                    shown += 1
        if room_w > 0 and room_h > 0:
            ed.resize(room_w, room_h)
        return ed^

    def path(self) -> String:
        return self.player.info.path

    def add_lane(mut self, var lane: Lane):
        self.lanes.append(lane^)
        self.version += 1

    def use_rows(mut self, var table: VideoTable, blur_kind: String = "", blur_noun: String = "faces", object_kind: String = "",
                 object_label: String = "", flag_word: String = ""):
        """Analysis rows (mojoui.videotable) for the reel: a pill lane of the objects of `object_kind` (flagged ones are
        `flag_word`: "damaged"), a dot lane of `blur_kind` rows (faces), and the sentence's choices from them. Blur and
        the outlines of flagged objects start on, as a reel would want."""
        if object_kind != "":
            self.lanes.append(objects_from_table(table, object_kind, object_label, flag_word))
        if blur_kind != "":
            self.lanes.append(markers_from_table(table, blur_kind, blur_noun[byte=0:1].upper() + String(blur_noun[byte=1:]), shape=SHAPE_DOTS))
        self.blur_kind = blur_kind
        self.blur_noun = blur_noun
        self.mark_kind = object_kind
        self.blur_on = blur_kind != "" and (self.blur_on or not self.expecting)  # (a chip already set while the rows ran stays as set)
        self.expecting = False
        self.table = table^
        var opts = self.what_options()
        self.what = 0
        _ = opts
        self.version += 1

    def expect_rows(mut self, blur_kind: String = "", blur_noun: String = "faces", object_kind: String = ""):
        """An analysis is running for this video (its rows land with use_rows): the preview chips show now, as use_rows
        will set them, so a person can choose before the rows arrive."""
        self.blur_kind = blur_kind
        self.blur_noun = blur_noun
        self.mark_kind = object_kind
        self.blur_on = blur_kind != ""
        self.expecting = True
        self.version += 1

    def use_captions(mut self, var captions: List[Caption], word: String):
        """Captions the reel can burn in (mojoui.videoexport.flagged_captions); `word` names them in the sentence."""
        self.captions = captions^
        self.caption_word = word
        self.caption_on = len(self.captions) > 0
        self.version += 1

    def resize(mut self, width: Int, height: Int):
        """The room the editor has (the app's window, less its margins): the viewer is then sized to the video's shape,
        as tall as the timeline leaves room for, so its corner chips sit on the picture."""
        self.room_w = width
        self.room_h = height

    def owns(self, message: Int) -> Bool:
        return self.base <= message < self.base + MESSAGES

    def draws(self, canvas: Int) -> Bool:
        return canvas == self.canvas + C_PICTURE or canvas == self.canvas + C_TIMELINE

    # ---- the playhead ----

    def t(self) -> Float64:
        """The playhead: seconds of the sequence."""
        return self.seq.t()

    def seek(mut self, seconds: Float64):
        self.seq.seek(seconds)
        self.version += 1

    def seek_source(mut self, source_t: Float64) -> Bool:
        """Moves the playhead to where a source time first shows in the edit (False when it was cut out)."""
        var f = Int(source_t * self.project.fps + 1e-6)
        var s = self.project.spans(f, f + 1)
        if len(s) == 0:
            return False
        self.seq.seek(Float64(s[0][0]) / self.project.fps)
        self.version += 1
        return True

    def _rebuild(mut self, keep_frame: Int):
        """The sequence changed length: a new clock, the playhead kept (clamped), the zoom kept in range."""
        var playing = self.seq.playing
        self.seq = PlayerState(self.project.fps, self.project.length(), self.project.duration())
        self.seq.frame = min(max(keep_frame, 0), self.seq.frames - 1)
        self.seq.clock = self.seq.t()
        self.seq.playing = playing
        self.scale.clamp(self.width, self.project.duration(), self.project.fps)
        self.version += 1

    def _trace(self, action: String):
        if trace_on():
            print("TIMELINE: " + action + "; clips " + String(len(self.project.clips)) + ", duration " + clock_tenths(self.project.duration()), flush=True)

    # ---- the sentence ----

    def what_options(self) -> List[String]:
        """The subjects a reel can be of: per markers lane, its flagged ones ("damaged pallets", when any are flagged) and
        all of them ("all pallets"; for a dots lane just "faces")."""
        var out = List[String]()
        for lane in self.lanes:
            if lane.kind != LANE_MARKERS or lane.markers() == 0:
                continue
            var noun = lane.label.lower()
            if lane.flag_word != "" and lane.flagged() > 0:
                out.append(lane.flag_word + " " + noun)
                out.append("all " + noun)
            else:
                out.append(noun)
            if len(out) >= MAX_WHAT:
                break
        return out^

    def _what_choice(self, i: Int) -> Tuple[Int, Bool]:
        """Option i of what_options() as (lane index, flagged only); (-1, False) when there is none."""
        var n = 0
        for li in range(len(self.lanes)):
            ref lane = self.lanes[li]
            if lane.kind != LANE_MARKERS or lane.markers() == 0:
                continue
            if lane.flag_word != "" and lane.flagged() > 0:
                if n == i:
                    return (li, True)
                if n + 1 == i:
                    return (li, False)
                n += 2
            else:
                if n == i:
                    return (li, False)
                n += 1
        return (-1, False)

    def sentence_text(self) -> String:
        """The sentence as it reads: "Reel of damaged pallets, faces blurred, shipment ID burned in"."""
        var opts = self.what_options()
        if len(opts) == 0:
            return ""
        var s = "Reel of " + opts[min(self.what, len(opts) - 1)]
        if self.blur_kind != "":
            s += ", " + self.blur_noun + (" blurred" if self.blur_on else " kept")
        if len(self.captions) > 0:
            s += ", " + (self.caption_word if self.caption_on else "no caption") + (" burned in" if self.caption_on else "")
        return s

    def cut_by_sentence(mut self) -> Bool:
        """Cut it: the edit becomes the clips where the sentence's subject is seen (each widened by half a second)."""
        var ch = self._what_choice(self.what)
        if ch[0] < 0:
            self.status = "Nothing to cut by: no analysis rows yet"
            self._trace("cut it refused (no rows)")
            return False
        var clips = clips_from_markers(self.lanes[ch[0]], ch[1], self.project.fps, self.project.source_frames, 0.5)
        var said = self.sentence_text()
        if not self.project.replace(clips^):
            self.status = "Nothing matches “" + said + "”"
            self._trace("cut it refused (nothing matches)")
            return False
        self.status = String(len(self.project.clips)) + " clips · " + fixed(self.project.duration(), 1) + " s · from the rows"
        self._trace("cut it: " + said)
        self._rebuild(0)
        self.scale.fit(self.width, self.project.duration())
        return True

    # ---- the tools ----

    def split(mut self) -> Bool:
        var at = self.seq.frame
        if self.project.split(at):
            self.status = "Split at " + clock_tenths(self.t())
            self._trace("split at " + fixed(self.t(), 3))
            self._rebuild(at)
            return True
        self.status = "Nothing to split at a clip's edge"
        self._trace("split at " + fixed(self.t(), 3) + " refused (a clip's edge)")
        return False

    def _target(self) -> Int:
        """The clip a trim works on: the selected one when the playhead is inside it, else the one under the playhead."""
        var k = self.project.selected
        if 0 <= k < len(self.project.clips):
            var s = self.project.start_of(k)
            if s < self.seq.frame < s + self.project.clips[k].length():
                return k
        return self.project.clip_at(self.seq.frame)

    def trim_start(mut self) -> Bool:
        var k = self._target()
        if self.project.trim_start(k, self.seq.frame):
            self.project.selected = k
            self.status = "Trimmed the start to " + clock_tenths(self.t())
            self._trace("trim start of clip " + String(k + 1) + " to " + fixed(self.t(), 3))
            self._rebuild(self.project.start_of(k))
            return True
        self.status = "Move the playhead into a clip to trim it"
        self._trace("trim start at " + fixed(self.t(), 3) + " refused (the playhead is on a clip's first frame)")
        return False

    def trim_end(mut self) -> Bool:
        var k = self._target()
        var at = self.seq.frame
        if self.project.trim_end(k, at):
            self.project.selected = k
            self.status = "Trimmed the end to " + clock_tenths(self.t())
            self._trace("trim end of clip " + String(k + 1) + " to " + fixed(self.t(), 3))
            self._rebuild(at)
            return True
        self.status = "Move the playhead into a clip to trim it"
        self._trace("trim end at " + fixed(self.t(), 3) + " refused (the playhead is on a clip's first frame)")
        return False

    def delete(mut self) -> Bool:
        var k = self.project.selected
        if self.project.delete(k):
            self.status = "Clip deleted"
            self._trace("delete clip " + String(k + 1))
            self._rebuild(self.project.start_of(min(k, len(self.project.clips) - 1)))
            return True
        self.status = "Select a clip to delete (an edit keeps one at least)"
        return False

    def undo(mut self) -> Bool:
        if self.project.undo():
            self.status = "Undone"
            self._trace("undo")
            self._rebuild(self.seq.frame)
            return True
        self.status = "Nothing to undo"
        return False

    def reel_spec(self) -> ReelSpec:
        """The export's recipe: the clips, and the rows' edits the chips and sentence ask for."""
        var spec = ReelSpec(self.project.segments())
        if self.table:
            spec.table = copy_table(self.table.value())
            spec.blur_kind = self.blur_kind if self.blur_on else ""
            spec.mark_kind = self.mark_kind if self.boxes_on else ""
            if self.caption_on:
                spec.captions = self.captions.copy()
        return spec^

    def ask_export(mut self, path: String):
        """Asks for the edit to be written to `path` (an mp4): mediatimeline_jobs.TimelineFeed runs it off the UI thread."""
        self.export_path = path
        self.exported_frames = -1
        self.status = "Exporting " + fixed(self.project.duration(), 1) + " s on the GPU…"
        self._trace("export to " + path)

    def export_now(mut self, path: String) raises -> Int:
        """Writes the edit to `path` here and now; the frames written."""
        var n = write_reel(self.path(), path, self.reel_spec())
        self.exported(n)
        return n

    def exported(mut self, frames: Int):
        self.exported_frames = frames
        self.export_path = ""
        self.status = "Exported " + fixed(Float64(frames) / self.project.fps, 1) + " s"
        self._trace("exported " + String(frames) + " frames")

    # ---- events ----

    def update(mut self, event: Event) -> Bool:
        if not self.owns(event.message):
            return False
        var which = event.message - self.base
        var before = self.seq.frame
        var was = self.seq.playing
        if which == M_PLAY:
            self.seq.play()
        elif which == M_PAUSE:
            self.seq.pause()
        elif which == M_SPLIT:
            _ = self.split()
        elif which == M_TRIM_START:
            _ = self.trim_start()
        elif which == M_TRIM_END:
            _ = self.trim_end()
        elif which == M_DELETE:
            _ = self.delete()
        elif which == M_UNDO:
            _ = self.undo()
        elif which == M_EXPORT:
            self.ask_export(export_name(self.path()))
        elif which == M_ZOOM_IN or which == M_ZOOM_OUT:
            self._zoom(ZOOM_STEP if which == M_ZOOM_IN else 1.0 / ZOOM_STEP)
        elif which == M_STEP_BACK:
            self.seq.step(-1)
        elif which == M_STEP_FORWARD:
            self.seq.step(1)
        elif which == M_FRAME:
            if self.seq.tick(event.number):
                self.scale.follow(self.t(), self.width, self.project.duration(), self.project.fps)
        elif which == M_PICTURE:
            if event.number == TAP:
                self.seq.toggle()
            elif event.number == KEY:
                self._key(event.text)
        elif which == M_TIMELINE:
            self._gesture(event)
        elif which == M_CLOSE:
            self.seq.pause()
            self.closed = True
        elif which == M_CUT:
            self.menu = MENU_NONE
            _ = self.cut_by_sentence()
        elif which == M_WORD_WHAT:
            self.menu = MENU_WHAT
        elif which == M_WORD_BLUR:
            self.menu = MENU_BLUR
        elif which == M_WORD_CAPTION:
            self.menu = MENU_CAPTION
        elif which == M_MENU_CLOSE:
            self.menu = MENU_NONE
        elif which == M_CHIP_BLUR or which == M_BLUR_ON or which == M_BLUR_OFF:
            self.blur_on = (not self.blur_on) if which == M_CHIP_BLUR else which == M_BLUR_ON
            self.menu = MENU_NONE
            self._trace("blur " + self.blur_noun + (" on" if self.blur_on else " off"))
        elif which == M_CHIP_CAPTION or which == M_CAPTION_ON or which == M_CAPTION_OFF:
            self.caption_on = (not self.caption_on) if which == M_CHIP_CAPTION else which == M_CAPTION_ON
            self.menu = MENU_NONE
            self._trace("caption " + ("on" if self.caption_on else "off"))
        elif which == M_CHIP_BOXES:
            self.boxes_on = not self.boxes_on
        elif M_WHAT <= which < M_WHAT + MAX_WHAT:
            var opts = self.what_options()
            if which - M_WHAT < len(opts):
                self.what = which - M_WHAT
                self._trace("reel of " + opts[self.what])
            self.menu = MENU_NONE
        self.version += 1
        _ = before
        _ = was
        self.sync_player()
        return True

    def sync_player(mut self):
        """The viewer's player asks for the source frame under the playhead and takes what landed (returns at once)."""
        self.player.state.frame = self.project.source_frame(self.seq.frame)
        if self.player.poll():
            self.version += 1

    def _zoom(mut self, factor: Float64):
        self.scale.zoom(factor, self.scale.x_of(self.t()), self.width, self.project.duration(), self.project.fps)

    def _key(mut self, key: String):
        if key == " ":
            self.seq.toggle()
        elif key == "ArrowLeft":
            self.seq.step(-1)
        elif key == "ArrowRight":
            self.seq.step(1)
        elif key == "s" or key == "S":
            _ = self.split()
        elif key == "[" or key == "bracketleft":
            _ = self.trim_start()
        elif key == "]" or key == "bracketright":
            _ = self.trim_end()
        elif key == "BackSpace" or key == "Backspace" or key == "Delete":
            _ = self.delete()
        elif key == "z" or key == "Z":
            _ = self.undo()
        elif key == "plus" or key == "+" or key == "equal" or key == "=":
            self._zoom(ZOOM_STEP)
        elif key == "minus" or key == "-":
            self._zoom(1.0 / ZOOM_STEP)

    # ---- the timeline's layout (points) ----

    def strip_top(self) -> Float64:
        return self.style.ruler_h

    def lanes_top(self) -> Float64:
        return self.style.ruler_h + self.style.strip_h + 6

    def timeline_height(self) -> Float64:
        """The timeline canvas's height: ruler, strip, lanes."""
        var h = self.lanes_top()
        for lane in self.lanes:
            h += lane.height() + self.style.lane_gap
        return h + 6

    def _seq_frame_at(self, x: Float64) -> Int:
        return min(max(Int(self.scale.t_of(x) * self.project.fps + 1e-6), 0), self.project.length() - 1)

    def _clip_x(self, k: Int) -> Tuple[Float64, Float64]:
        """Clip k's left and right x."""
        var a = self.project.start_of(k)
        return (self.scale.x_of(Float64(a) / self.project.fps), self.scale.x_of(Float64(a + self.project.clips[k].length()) / self.project.fps))

    def _gesture(mut self, event: Event):
        var x = event.x
        var y = event.y
        var top = self.strip_top()
        var bottom = top + self.style.strip_h
        if event.number == SET_TO:
            try:
                self.seek(Float64(event.text))
            except:
                pass
        elif event.number == ZOOM:
            self.scale.zoom(event.zoom, x, self.width, self.project.duration(), self.project.fps)
        elif event.number == KEY:
            self._key(event.text)
        elif event.number == PRESS:
            self.drag = 1
            self.drag_clip = -1
            var k = self.project.selected
            if top <= y <= bottom and 0 <= k < len(self.project.clips):  # a selected clip's handle?
                var cx = self._clip_x(k)
                if abs(x - cx[0]) <= HANDLE_GRAB and x < (cx[0] + cx[1]) / 2:
                    self.drag = 2
                elif abs(x - cx[1]) <= HANDLE_GRAB:
                    self.drag = 3
                if self.drag >= 2:
                    self.drag_clip = k
                    self.project.remember()
            if self.drag == 1:
                if y > bottom:  # a lane: a marker under the pointer seeks to it
                    if self._tap_marker(x, y):
                        self.drag = 0
                        return
                elif top <= y <= bottom:  # the strip: select the clip under the pointer
                    self.project.selected = self.project.clip_at(self._seq_frame_at(x))
                self.seek(Float64(self._seq_frame_at(x)) / self.project.fps)
        elif event.number == PAN:
            if self.drag == 1:
                self.seek(Float64(self._seq_frame_at(x)) / self.project.fps)
            elif self.drag >= 2:
                self._drag_handle(x)
        elif event.number == TAP:
            self.drag = 0
        elif event.number == RELEASE:
            if self.drag >= 2 and self.drag_clip >= 0:
                var c = self.project.clips[self.drag_clip]
                var n = len(self.project.history)
                if n > 0 and self.drag_clip < len(self.project.history[n - 1]) and self.project.history[n - 1][self.drag_clip] == c:
                    _ = self.project.history.pop()  # (the handle didn't move: nothing to undo)
                else:
                    var which = "start" if self.drag == 2 else "end"
                    var src_t = Float64(c.first if self.drag == 2 else c.end) / self.project.fps
                    self.status = "Trimmed the " + which + " to " + clock_tenths(src_t) + " of the source"
                    self._trace("trim " + which + " of clip " + String(self.drag_clip + 1) + " by its handle to source " + fixed(src_t, 3))
            self.drag = 0
            self.drag_clip = -1

    def _drag_handle(mut self, x: Float64):
        """A handle follows the pointer: the clip's start (or end) becomes the source frame under it. The clip's left edge
        stays put on the timeline, so its pictures slide under a start handle and the clips after it move."""
        var k = self.drag_clip
        var c = self.project.clips[k]
        var start = self.project.start_of(k)
        var at = Int(self.scale.t_of(x) * self.project.fps + 0.5)
        if self.drag == 2:
            if self.project.set_in(k, c.first + (at - start)):
                self._rebuild(start)
        else:
            if self.project.set_out(k, c.first + (at - start)):
                self._rebuild(start + self.project.clips[k].length() - 1)

    def _tap_marker(mut self, x: Float64, y: Float64) -> Bool:
        var lane_y = self.lanes_top()
        var li = -1
        for i in range(len(self.lanes)):
            var h = self.lanes[i].height()
            if lane_y <= y < lane_y + h + self.style.lane_gap:
                li = i
            lane_y += h + self.style.lane_gap
        if li < 0 or self.lanes[li].kind != LANE_MARKERS:
            return False
        ref lane = self.lanes[li]
        var best = -1.0
        var best_d = 10.0  # points
        var name = String("")
        for m in range(lane.markers()):
            var a = Int(lane.starts[m] * self.project.fps + 0.5)
            var b = max(Int(lane.ends[m] * self.project.fps + 0.5), a + 1)
            for sp in self.project.spans(a, b):
                var x0 = self.scale.x_of(Float64(sp[0]) / self.project.fps)
                var x1 = self.scale.x_of(Float64(sp[1]) / self.project.fps)
                var d = 0.0 if x0 <= x <= x1 else min(abs(x - x0), abs(x - x1))
                if d < best_d:
                    best_d = d
                    best = Float64(sp[0]) / self.project.fps
                    name = lane.labels[m]
        if best < 0:
            return False
        var said = lane.label + (" " + name if name != "" else "") + " at " + clock_tenths(best)
        self.seek(best)
        self.status = said
        return True

    # ---- the screen ----

    def time_text(self) -> String:
        return clock_tenths(self.t()) + " / " + clock_tenths(self.project.duration())

    def needs_frames(self) -> Bool:
        """Display frames wanted: playing, thumbnails still arriving, an export running, or a frame (or its preview)
        still on its way from its thread."""
        return (self.seq.playing or not self.thumbs.complete() or self.export_path != "" or self.player.pending()
                or (self.preview_wanted() >= 0 and self.preview_key != self.preview_wanted()))

    def _menu(self) -> View:
        var b = self.base
        var items = List[View]()
        if self.menu == MENU_WHAT:
            var opts = self.what_options()
            for i in range(len(opts)):
                items.append(Item(opts[i], b + M_WHAT + i, checked=i == self.what))
            return ContextMenu("word-what", 0, 26, items^, b + M_MENU_CLOSE)
        if self.menu == MENU_BLUR:
            items.append(Item(self.blur_noun + " blurred", b + M_BLUR_ON, checked=self.blur_on))
            items.append(Item(self.blur_noun + " kept", b + M_BLUR_OFF, checked=not self.blur_on))
            return ContextMenu("word-blur", 0, 26, items^, b + M_MENU_CLOSE)
        items.append(Item(self.caption_word + " burned in", b + M_CAPTION_ON, checked=self.caption_on))
        items.append(Item("no caption", b + M_CAPTION_OFF, checked=not self.caption_on))
        return ContextMenu("word-caption", 0, 26, items^, b + M_MENU_CLOSE)

    def _sentence(self) -> View:
        """The sentence bar: "Ask  Reel of [damaged pallets], [faces blurred], [shipment ID] burned in      Cut it"."""
        var b = self.base
        var opts = self.what_options()
        var words = List[Word]()
        if len(opts) == 0:
            words.append(Word("Reel of the whole video: analyse it to cut by what it shows"))
        else:
            words.append(Word("Reel of "))
            words.append(Word(opts[min(self.what, len(opts) - 1)], b + M_WORD_WHAT, "word-what"))
            if self.blur_kind != "":
                words.append(Word(", "))
                words.append(Word(self.blur_noun + (" blurred" if self.blur_on else " kept"), b + M_WORD_BLUR, "word-blur"))
            if len(self.captions) > 0:
                words.append(Word(", "))
                words.append(Word(self.caption_word if self.caption_on else "no caption", b + M_WORD_CAPTION, "word-caption"))
                if self.caption_on:
                    words.append(Word(" burned in"))
        var cut_it = Button("Cut it", b + M_CUT, PLAIN).tag("cut-it").tooltip("Build the clips from the analysis rows, as the sentence says")
        var bar = HStack(Text("Ask", CAPTION), Sentence(words^, width=80, style=BODY), Spacer(), cut_it^, spacing=10).align(CENTER).fill()
        return Card(bar^, spacing=0).padding(8, 12).fill().tag("reel-sentence")

    def view(self, pal: Palette) -> View:
        """The editor, top to bottom: header, viewer, transport, sentence, tools, timeline, footer."""
        var b = self.base
        var playing = self.seq.playing
        # the header
        var head = HStack(
            Button("Back", b + M_CLOSE, ICON_ONLY, icon="back").tag("done").tooltip("Close the editor"),
            VStack(Text(self.title, HEADLINE).tag("editor-title"), Text(self.facts, CAPTION), spacing=0).align(START),
            Spacer(),
            Button("Undo", b + M_UNDO, ICON_ONLY, icon="undo").tag("undo").tooltip("Undo the last edit (Z)"),
            Button("Export reel", b + M_EXPORT, PROMINENT, icon="export").tag("export").tooltip("Write the edit as an mp4 (H.264), on the GPU"),
            spacing=10).align(CENTER).fill().tag("editor-header")
        # the viewer, with the reel's preview chips in its corner
        var picture = Canvas(self.canvas + C_PICTURE, self.version, on_gesture=b + M_PICTURE, keys=True).fill().grow().tag("video")
        picture = picture^.label("Video " + self.title + ", " + clock_tenths(self.t()) + " of " + clock_tenths(self.project.duration()) + (", playing" if playing else ", paused"))
        var viewer: View
        if self.table or self.expecting:
            var chips = List[View]()
            if self.blur_kind != "":
                chips.append(Button("Blur " + self.blur_noun, b + M_CHIP_BLUR, TOOL_INLINE_ON if self.blur_on else TOOL_INLINE).tag("chip-blur"))
            if len(self.captions) > 0:
                chips.append(Button("Caption", b + M_CHIP_CAPTION, TOOL_INLINE_ON if self.caption_on else TOOL_INLINE).tag("chip-caption"))
            if self.mark_kind != "":
                chips.append(Button("Boxes", b + M_CHIP_BOXES, TOOL_INLINE_ON if self.boxes_on else TOOL_INLINE).tag("chip-boxes"))
            var island = Card(HStack(chips^, spacing=4).align(CENTER), spacing=0).padding(4, 6).tag("viewer-chips")
            viewer = Overlay(picture^, island^.pin(END, START)).grow().fill()
        else:
            viewer = picture^
        if self.room_h > 0:  # the viewer at the video's shape, centred, as tall as the rest leaves room for
            var chrome = 214 + (60 if self.table or self.expecting or len(self.lanes) > 0 else 0)  # (header, transport, tools, footer, gaps: measured on GTK)
            var vh = max(self.room_h - chrome - Int(self.timeline_height()), 120)
            var aspect = Float64(self.player.info.width) / Float64(max(self.player.info.height, 1))
            var vw = min(self.room_w, Int(Float64(vh) * aspect))
            vh = Int(Float64(vw) / aspect)
            viewer = HStack(Spacer(), viewer^.width(vw).height(vh), Spacer(), spacing=0).fill()
        # the transport
        var play = (Button("Pause", b + M_PAUSE, PROMINENT, icon="pause").alternate("Play", b + M_PLAY).tag("pause") if playing
                    else Button("Play", b + M_PLAY, PROMINENT, icon="play").alternate("Pause", b + M_PAUSE).tag("play"))
        var transport = HStack(
            Text(self.time_text(), BODY).tag("timecode").min_width(130),
            Spacer(),
            Button("Back a frame", b + M_STEP_BACK, ICON_ONLY, icon="back").tag("step-back").tooltip("Back one frame (←)"),
            play^.tooltip("Play or pause (Space)"),
            Button("Forward a frame", b + M_STEP_FORWARD, ICON_ONLY, icon="chevron-right").tag("step-forward").tooltip("Forward one frame (→)"),
            Spacer(),
            Text("Zoom", CAPTION),
            Button("−", b + M_ZOOM_OUT, SUBTLE).tag("zoom-out").tooltip("Zoom out (-)"),
            Button("+", b + M_ZOOM_IN, SUBTLE).tag("zoom-in").tooltip("Zoom in (+)"),
            spacing=8).align(CENTER).fill().tag("transport")
        # the manual tools
        var tools = HStack(
            Button("Split", b + M_SPLIT, TOOL_INLINE).tag("split").tooltip("Split the clip at the playhead (S)"),
            Button("Trim start", b + M_TRIM_START, TOOL_INLINE).tag("trim-start").tooltip("Trim the clip's start to the playhead ([)"),
            Button("Trim end", b + M_TRIM_END, TOOL_INLINE).tag("trim-end").tooltip("Trim the clip's end to the playhead (])"),
            Button("Delete", b + M_DELETE, TOOL_INLINE).tag("delete").tooltip("Delete the selected clip (Backspace)"),
            Spacer(),
            Text("Drag a selected clip's edges to trim · tap a pill to jump there", CAPTION),
            spacing=6).align(CENTER).fill().padding(0, 14).tag("timeline-tools")
        var timeline = Canvas(self.canvas + C_TIMELINE, self.version, on_gesture=b + M_TIMELINE,
                              on_frame=b + M_FRAME if self.needs_frames() else NO_MSG, keys=True)
        timeline = timeline^.fill().height(Int(self.timeline_height() + 0.5)).tag("timeline").settable("seconds", 0.0, self.project.duration())
        timeline = timeline^.tooltip("The timeline: tap or drag to move the playhead; drag a selected clip's edges to trim; pinch or scroll to zoom")
        var foot = HStack(
            Text("Edit " + fixed(self.project.duration(), 1) + " s", CAPTION).tag("edit-length"),
            Text("Clips " + String(len(self.project.clips)), CAPTION).tag("edit-clips"),
            Text("Export: H.264 · " + String(self.player.info.width) + "×" + String(self.player.info.height)
                 + (" · " + self.blur_noun + " blurred on the GPU" if self.blur_kind != "" and self.blur_on else ""), CAPTION),
            Spacer(),
            Text(self.status, CAPTION).tag("timeline-status"),
            spacing=16).align(CENTER).fill().padding(0, 14)
        var panel = Card(tools^, timeline^, foot^, spacing=6).padding(8, 0).fill().tag("timeline-panel")
        var items = List[View]()
        items.append(head^)
        items.append(viewer^)
        items.append(transport^)
        if self.table or len(self.lanes) > 0:
            items.append(self._sentence())
        items.append(panel^)
        if self.menu != MENU_NONE:
            items.append(self._menu())
        return VStack(items^, spacing=10).grow().fill().tag("media-timeline")

    def describe(self) -> String:
        """For an agent: the clips, the playhead, the sentence, and how to seek."""
        var n = len(self.project.clips)
        var out = ("An edit of " + String(n) + " clip" + ("" if n == 1 else "s") + ", " + fixed(self.project.duration(), 3) + " s; playhead at "
                   + fixed(self.t(), 3) + " s" + (", playing" if self.seq.playing else ", paused") + ". Clips (source seconds):")
        for k in range(n):
            var c = self.project.clips[k]
            out += " " + String(k + 1) + (" (selected)" if k == self.project.selected else "") + " " + fixed(Float64(c.first) / self.project.fps, 2) + "–" + fixed(Float64(c.end) / self.project.fps, 2)
        for lane in self.lanes:
            out += ". Lane " + lane.label + (": " + String(lane.markers()) + " markers, " + String(lane.flagged()) + " flagged" if lane.kind == LANE_MARKERS else ": values")
        var said = self.sentence_text()
        if said != "":
            out += ". Sentence: " + said + " (cut-it builds the clips from it; its words word-what, word-blur, word-caption open their choices)"
        return out + ". Seek: set the timeline to a time in seconds of the edit."

    # ---- drawing ----

    def draw(mut self, canvas: Int, mut s: Surface, pal: Palette, font: Font):
        if canvas == self.canvas + C_PICTURE:
            self._draw_picture(s, pal)
        elif canvas == self.canvas + C_TIMELINE:
            self.style.paint(pal)
            self.draw_timeline(s, font)

    def _effects_key(self) -> Int:
        return (1 if self.blur_on else 0) + (2 if self.caption_on else 0) + (4 if self.boxes_on else 0)

    def preview_wanted(self) -> Int:
        """The preview the viewer should show (source frame × 8 + the chips), or -1 when it shows the plain frame (no
        rows yet, or every chip off)."""
        var fx = self._effects_key()
        if not self.table or fx == 0:
            return -1
        return self.project.source_frame(self.seq.frame) * 8 + fx

    def preview_spec(self) -> ReelSpec:
        """What the preview's plan is built from (the rows copied: the job that builds it owns them)."""
        var spec = ReelSpec(List[Tuple[Float64, Float64]]())
        if self.table:
            spec.table = copy_table(self.table.value())
        spec.blur_kind = self.blur_kind if self.blur_on else ""
        spec.mark_kind = self.mark_kind if self.boxes_on else ""
        if self.caption_on:
            spec.captions = self.captions.copy()
        return spec^

    def preview_now(mut self) raises:
        """Makes the wanted preview here, waiting for its frame (tests; the app's is made by a job, TimelineFeed)."""
        var key = self.preview_wanted()
        if key < 0:
            return
        self.sync_player()
        _ = self.player.settle()
        var frame = Frame(self.player.info.width, self.player.info.height, self.player.buf.copy())
        if not self.ops:
            self.ops = ImageOps()
        if not self.plan or self.plan_key != self._effects_key():
            self.plan = self.preview_spec().plan()
            self.plan_key = self._effects_key()
        render_preview(frame, self.plan, self.ops.value(), key // 8)
        self.preview = frame^
        self.preview_key = key
        self.version += 1

    def _draw_picture(mut self, mut s: Surface, pal: Palette):
        """The frame on show, or its preview with the reel's edits when a chip asks for them. Never waits: the frame comes
        from the player's thread, the preview from a job (mediatimeline_jobs.TimelineFeed); until it lands the last
        preview (or the plain frame) stays."""
        var want = self.preview_wanted()
        if want >= 0 and self.preview_key >= 0 and self.preview.width > 0:  # (the newest preview, maybe a frame behind)
            draw_fitted(s, self.preview.pixels, self.preview.width, self.preview.height, pal.page)
            return
        self.player.state.frame = self.project.source_frame(self.seq.frame)
        self.player.draw(self.canvas + C_PICTURE, s, pal.page, pal)

    def draw_timeline(mut self, mut s: Surface, font: Font):
        var was = self.width
        self.width = s.points_width()
        if abs(was - self.width) > 0.5:
            if self.scale.pps <= self.scale.fit_pps(was, self.project.duration()) * 1.0001:
                self.scale.fit(self.width, self.project.duration())  # (shown whole before: whole again)
            self.scale.clamp(self.width, self.project.duration(), self.project.fps)
        s.fill(self.style.back)
        self._draw_ruler(s, font)
        self._draw_strip(s, font)
        self._draw_lanes(s, font)
        self._draw_playhead(s, font)
        self._draw_lane_names(s, font)

    def _draw_ruler(self, mut s: Surface, font: Font):
        ref st = self.style
        var k = s.scale
        var step = ruler_step(self.scale.pps)
        var minor = step / 5
        var i = max(Int(self.scale.t_of(0) / minor) - 1, 0)
        while True:
            var t = Float64(i) * minor
            var x = self.scale.x_of(t)
            if x > self.width or t > self.project.duration() + 1e-9:
                break
            var major = i % 5 == 0
            var h = 5.0 if major else 3.0
            rect(s, x * k, (st.ruler_h - h) * k, 1 * k, h * k, st.tick)
            if major and i > 0:
                font.draw(s, clock_tenths(t) if step < 1 else _clock_whole(t), x * k, (st.ruler_h - 8) * k, st.text * k, st.ruler_ink, REGULAR, CENTRE)
            i += 1

    def _draw_strip(self, mut s: Surface, font: Font):
        ref st = self.style
        var k = s.scale
        var top = self.strip_top()
        var aspect = Float64(self.player.info.width) / Float64(max(self.player.info.height, 1))
        var tile_w = st.strip_h * aspect
        for tile in tiles(self.project, self.scale, self.width, tile_w):
            var cx = self._clip_x(tile.clip)
            var i = self.thumbs.index_for(tile.source_t)
            _blit(s, self.thumbs.frames[i], tile.x * k, top * k, tile.w * k, st.strip_h * k, (cx[0] + st.gap / 2) * k, (cx[1] - st.gap / 2) * k,
                  st.radius * k, st.empty_tile, tile_w * k)
            if tile.x > cx[0] + 1:  # the hairline between tiles of one clip
                rect(s, tile.x * k, top * k, max(1.0, 0.5 * k), st.strip_h * k, st.clip_edge)
        for c in range(len(self.project.clips)):  # each clip's length on a small dark tag, bottom left
            var cx = self._clip_x(c)
            if cx[1] < 0 or cx[0] > self.width or cx[1] - cx[0] < 56:
                continue
            var label = clock_tenths(Float64(self.project.clips[c].length()) / self.project.fps)
            var w = font.measure(label, st.text * k, MEDIUM) / k + 10
            var lx = max(cx[0], 0.0) + st.gap / 2 + (st.handle_w + 4 if c == self.project.selected else 6)
            rect(s, lx * k, (top + st.strip_h - 21) * k, w * k, 16 * k, with_alpha(rgba(0, 0, 0), 0.55), 5 * k)
            font.draw(s, label, (lx + 5) * k, (top + st.strip_h - 9) * k, st.text * k, rgba(255, 255, 255), MEDIUM)
        var sel = self.project.selected
        if 0 <= sel < len(self.project.clips):
            var cx = self._clip_x(sel)
            var x0 = cx[0] + st.gap / 2
            var x1 = cx[1] - st.gap / 2
            _selection(s, x0 * k, top * k, (x1 - x0) * k, st.strip_h * k, st.frame_w * k, st.handle_w * k, st.radius * k, st.select, st.grip)

    def _draw_lanes(self, mut s: Surface, font: Font):
        ref st = self.style
        var k = s.scale
        var y = self.lanes_top()
        var fps = self.project.fps
        for li in range(len(self.lanes)):
            ref lane = self.lanes[li]
            var lh = lane.height()
            if lane.kind == LANE_MARKERS:
                for m in range(lane.markers()):
                    var a = Int(lane.starts[m] * fps + 0.5)
                    var b = max(Int(lane.ends[m] * fps + 0.5), a + 1)
                    var flagged = lane.flags[m]
                    for sp in self.project.spans(a, b):
                        var x0 = self.scale.x_of(Float64(sp[0]) / fps)
                        var x1 = self.scale.x_of(Float64(sp[1]) / fps)
                        if x1 < 0 or x0 > self.width:
                            continue
                        if lane.shape == SHAPE_DOTS:
                            var dx = x0
                            while dx <= x1:
                                circle(s, dx * k, (y + lh / 2) * k, 3 * k, st.dot)
                                dx += 14
                            continue
                        var py = y + 4 + 17 * Float64(lane.row[m])
                        var pw = max(x1 - x0 - 2, 6.0)
                        var edge = st.flag if flagged else st.quiet
                        rect(s, x0 * k, py * k, pw * k, 14 * k, edge, 7 * k)
                        rect(s, (x0 + 1) * k, (py + 1) * k, (pw - 2) * k, 12 * k, st.flag_fill if flagged else st.quiet_fill, 6 * k)
                        var text = ("⚠ " if flagged else "") + lane.labels[m]
                        if text != "" and pw > 30:
                            var room = (pw - 12) * k
                            if font.measure(text, 9.5 * k, MEDIUM) > room:
                                text = lane.labels[m]
                            if font.measure(text, 9.5 * k, MEDIUM) <= room:
                                font.draw(s, text, (x0 + 6) * k, (py + 10.5) * k, 9.5 * k, st.flag_ink if flagged else st.quiet_ink, MEDIUM)
            else:
                var range_ = lane.low_high()
                var seq_at = 0
                for c in self.project.clips:
                    var xa = max(self.scale.x_of(Float64(seq_at) / fps), 0.0)
                    var xb = min(self.scale.x_of(Float64(seq_at + c.length()) / fps), self.width)
                    var px = xa
                    var prev_y = -1.0
                    while px <= xb:
                        var src_t = Float64(c.first) / fps + (self.scale.t_of(px) - Float64(seq_at) / fps)
                        var vy = y + lh - 4 - (lane.value_at(src_t) - range_[0]) / (range_[1] - range_[0]) * (lh - 16)
                        if prev_y >= 0:
                            line(s, (px - 2) * k, prev_y * k, px * k, vy * k, 1.6 * k, st.line)
                        prev_y = vy
                        px += 2
                    seq_at += c.length()
            y += lh + st.lane_gap

    def _draw_lane_names(self, mut s: Surface, font: Font):
        """Each lane's name on its left (a line's with its value at the playhead), on the panel's tone, over everything."""
        ref st = self.style
        var k = s.scale
        var y = self.lanes_top()
        for li in range(len(self.lanes)):
            ref lane = self.lanes[li]
            var label = lane.label
            if lane.kind == LANE_VALUES:
                label += "  " + fixed(lane.value_at(Float64(self.project.source_frame(self.seq.frame)) / self.project.fps), 1) + (" " + lane.unit if lane.unit != "" else "")
            var lw = font.measure(label, st.text * k, MEDIUM) / k
            rect(s, 0, (y + 1) * k, (lw + 14) * k, 15 * k, st.label_back, 5 * k)
            font.draw(s, label, 6 * k, (y + 12) * k, st.text * k, st.lane_ink, MEDIUM)
            y += lane.height() + st.lane_gap

    def _draw_playhead(self, mut s: Surface, font: Font):
        ref st = self.style
        var k = s.scale
        var x = self.scale.x_of(self.t())
        if x < -40 or x > self.width + 40:
            return
        rect(s, (x - 1) * k, (st.ruler_h - 4) * k, 2 * k, (Float64(s.height) / k - st.ruler_h + 4) * k, st.playhead, 1 * k)
        var label = clock_tenths(self.t())
        var w = font.measure(label, st.text * k, MEDIUM) / k + 12
        var bx = min(max(x - w / 2, 0.0), self.width - w)
        rect(s, bx * k, 1 * k, w * k, (st.ruler_h - 5) * k, st.playhead, 6 * k)
        font.draw(s, label, (bx + w / 2) * k, (st.ruler_h - 9) * k, st.text * k, st.bubble_ink, MEDIUM, CENTRE)


def _blit(mut s: Surface, thumb: Frame, x: Float64, y: Float64, w: Float64, h: Float64, clip_x0: Float64, clip_x1: Float64,
          radius: Float64, empty: UInt32, full_w: Float64):
    """A thumbnail into the tile at (x, y) w × h pixels (its left `w` of a `full_w`-wide picture), cut to the clip's
    [clip_x0, clip_x1) and rounded at the clip's corners; a tile without its thumbnail yet is `empty`."""
    var px0 = max(Int(max(x, clip_x0)), 0)
    var px1 = min(Int(min(x + w, clip_x1) + 0.999), s.width)
    var py0 = max(Int(y), 0)
    var py1 = min(Int(y + h), s.height)
    if px1 <= px0 or py1 <= py0:
        return
    var have = thumb.width > 0 and thumb.height > 0
    var out = s.pixels()
    var sx = Float64(thumb.width) / max(full_w, 1.0)
    var sy = Float64(thumb.height) / max(h, 1.0)
    for py in range(py0, py1):
        var ty = min(Int((Float64(py) - y) * sy), thumb.height - 1) if have else 0
        var dy = min(Float64(py) + 0.5 - y, y + h - Float64(py) - 0.5)
        for px in range(px0, px1):
            var c = empty
            if have:
                var tx = min(max(Int((Float64(px) - x) * sx), 0), thumb.width - 1)
                c = thumb.pixels[ty * thumb.width + tx]
            var dx = min(Float64(px) + 0.5 - clip_x0, clip_x1 - Float64(px) - 0.5)
            var p = out.unsafe_offset(py * s.width + px)
            if dx < radius and dy < radius:
                var ex = radius - dx
                var ey = radius - dy
                var cover = min(max(radius - (ex * ex + ey * ey) ** 0.5 + 0.5, 0.0), 1.0)
                p[] = blend(p[], c | 0xFF000000, cover)
            else:
                p[] = c | 0xFF000000


def _selection(mut s: Surface, x: Float64, y: Float64, w: Float64, h: Float64, thick: Float64, handle: Float64, radius: Float64,
               colour: UInt32, grip: UInt32):
    """The selected clip: an accent outline (`thick`) with an accent handle bar at each end carrying a dark grip line."""
    rect(s, x, y, w, thick, colour)
    rect(s, x, y + h - thick, w, thick, colour)
    rect(s, x, y, handle, h, colour, radius)
    rect(s, x + w - handle, y, handle, h, colour, radius)
    rect(s, x + handle / 2, y, handle / 2, h, colour)  # (square inner corners)
    rect(s, x + w - handle, y, handle / 2, h, colour)
    var gh = h * 0.25
    var gw = max(2.0, handle / 6)
    rect(s, x + handle / 2 - gw / 2, y + (h - gh) / 2, gw, gh, grip, gw / 2)
    rect(s, x + w - handle / 2 - gw / 2, y + (h - gh) / 2, gw, gh, grip, gw / 2)
