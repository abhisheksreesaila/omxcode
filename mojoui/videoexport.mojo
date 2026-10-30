# mojoui.videoexport: write a video, and cut one from another (goal 39 M5). A generic component: any app exports frames
# (a reel, a redacted copy, a time-lapse); omxplorer's "export the reel" is built on it.
#
#   var w = VideoWriter("out.mp4", 1280, 720, 30)          # H.264, yuv420p, faststart (plays in browsers and phones)
#   w.write(frame.pixels)                                   # RGBA frames, R in the low byte (VideoSource's, Frame's)
#   w.close()                                               # raises if ffmpeg failed
#
#   var segments = List[Tuple[Float64, Float64]]()          # [start, end) in seconds of the source
#   var plan = RedactPlan(table, "face", 14)                # what to do to each frame (an EditPlan: imageops Edits)
#   var n = cut(video, segments, plan, "reel.mp4", ops)     # the segments, in order, edited, as one video
#
# How: one `ffmpeg -f rawvideo -pix_fmt rgba -i - … libx264` process fed through a pipe (libc popen "w" / fwrite), the
# mirror of VideoSource's reader; an in-process encoder can replace _Pipe without changing a caller. Frames are edited by
# mojoui.imageops (GPU when there is one) between decode and encode.

from std.ffi import external_call
from mojoui.video import VideoSource, _quote
from mojoui.imageops import ImageOps, Frame, Edits
from mojoui.videotable import VideoTable, NO_CODE, Progress, NoProgress
from mojoui.canvas import rgba
from mojoui.text import MEDIUM


def _popen_w(cmd: String) -> Int:
    var c = cmd
    var mode = String("w")
    return external_call["popen", Int](c.as_c_string_span(), mode.as_c_string_span())


struct VideoWriter(Movable):
    """Frames in, an mp4 out: H.264 (libx264), yuv420p, `fps` frames per second, moov atom first (faststart)."""

    var path: String
    var width: Int
    var height: Int
    var fps: Float64
    var frames: Int
    var _fp: Int

    def __init__(out self, path: String, width: Int, height: Int, fps: Float64 = 30, crf: Int = 18, preset: String = "veryfast") raises:
        self.path = path
        self.width = width
        self.height = height
        self.fps = fps
        self.frames = 0
        var cmd = (
            "ffmpeg -y -v error -nostdin -f rawvideo -pix_fmt rgba -s " + String(width) + "x" + String(height)
            + " -r " + String(fps) + " -i - -an -c:v libx264 -preset " + preset + " -crf " + String(crf)
            + " -pix_fmt yuv420p -movflags +faststart " + _quote(path)
        )
        self._fp = _popen_w(cmd)
        if self._fp == 0:
            raise Error("VideoWriter: cannot start ffmpeg for " + path)

    def __deinit__(deinit self):
        if self._fp != 0:
            _ = external_call["pclose", Int32](self._fp)

    def write_address(mut self, addr: Int) raises:
        """One frame from memory the caller owns: width × height RGBA pixels at `addr`."""
        if self._fp == 0:
            raise Error("VideoWriter: already closed: " + self.path)
        var n = self.width * self.height * 4
        var put = external_call["fwrite", Int](addr, 1, n, self._fp)
        if put < n:
            raise Error("VideoWriter: ffmpeg stopped taking frames for " + self.path)
        self.frames += 1

    def write(mut self, pixels: List[UInt32]) raises:
        if len(pixels) != self.width * self.height:
            raise Error("VideoWriter: a frame of " + String(len(pixels)) + " pixels, want " + String(self.width * self.height))
        self.write_address(Int(pixels.unsafe_ptr()))

    def close(mut self) raises:
        """Finishes the file; raises if ffmpeg reported a failure."""
        if self._fp == 0:
            return
        var status = external_call["pclose", Int32](self._fp)
        self._fp = 0
        if status != 0:
            raise Error("VideoWriter: ffmpeg failed (status " + String(status) + ") writing " + self.path)


# ---------- cutting ----------


trait EditPlan(Movable, Deinitable):
    """What to do to each frame of a cut: add imageops edits for source frame `frame` (`reel_frame`: its index in the
    output). The plan may read the table of what was seen (mojoui.videotable) or anything else."""

    def plan(mut self, frame: Int, reel_frame: Int, mut ops: ImageOps, mut edits: Edits) raises:
        ...


struct NoEdits(EditPlan):
    """A plain cut."""

    def __init__(out self):
        pass

    def plan(mut self, frame: Int, reel_frame: Int, mut ops: ImageOps, mut edits: Edits) raises:
        pass


def frame_ranges(segments: List[Tuple[Float64, Float64]], fps: Float64, frames: Int) -> List[Tuple[Int, Int]]:
    """Seconds [start, end) → frame ranges [first, last + 1), rounded to the nearest frame and cut to the video."""
    var out = List[Tuple[Int, Int]]()
    for s in segments:
        var a = max(Int(s[0] * fps + 0.5), 0)
        var b = min(Int(s[1] * fps + 0.5), frames)
        if b > a:
            out.append((a, b))
    return out^


def cut[P: EditPlan](mut video: VideoSource, segments: List[Tuple[Float64, Float64]], mut plan: P, path: String,
                     mut ops: ImageOps, crf: Int = 18) raises -> Int:
    """The segments of `video`, in the order given, each frame edited by `plan`, written to `path` at the source's size
    and rate. Returns the frames written."""
    var quiet = NoProgress()
    return cut_with(video, segments, plan, path, ops, quiet, crf)


def cut_frames(segments: List[Tuple[Float64, Float64]], fps: Float64, frames: Int) -> Int:
    """How many frames cut() writes for these segments (a job's total)."""
    var n = 0
    for r in frame_ranges(segments, fps, frames):
        n += r[1] - r[0]
    return n


def cut_with[P: EditPlan, R: Progress](mut video: VideoSource, segments: List[Tuple[Float64, Float64]], mut plan: P, path: String,
                                       mut ops: ImageOps, mut progress: R, crf: Int = 18) raises -> Int:
    """cut(), telling `progress` after each frame written (a background job's count and cancel: mojoui.videojobs)."""
    var w = VideoWriter(path, video.width, video.height, video.fps, crf)
    var frame = Frame(video.width, video.height)
    var reel = 0
    for r in frame_ranges(segments, video.fps, video.frames):
        if video.position() != r[0]:
            video.seek_frame(r[0])
        for n in range(r[0], r[1]):
            if not video.next_into(frame.pixels):
                break
            var edits = Edits()
            plan.plan(n, reel, ops, edits)
            if len(edits.list) > 0:
                ops.apply(frame, edits)
            w.write(frame.pixels)
            reel += 1
            progress.frame_done(n)
    w.close()
    return reel


# ---------- a plan from the table: blur one kind of thing, outline another, caption the frames ----------


@fieldwise_init
struct Caption(Copyable, Movable):
    var first: Int  # source frames [first, last]
    var last: Int
    var text: String


struct RedactPlan(EditPlan):
    """Built from a VideoTable: blurs every row of kind `blur_kind` on its frame (padded by `pad`; heavy enough that a
    face can't be recognised), outlines rows of kind `mark_kind` that are damaged (`mark_colour`), and draws captions:
    a dark rounded pill with a coloured dot and white text, inside the box (cx, cy, cw, ch), vertically centred. Captions
    may end with "{t}": replaced by the frame's source time (m:ss)."""

    var table: VideoTable
    var blur_kind: String
    var pad: Int
    var mark_kind: String
    var mark_colour: UInt32
    var captions: List[Caption]
    var cx: Int
    var cy: Int
    var cw: Int
    var ch: Int
    var text_size: Float64
    var by_frame: List[List[Int]]  # rows on each frame

    def __init__(out self, var table: VideoTable, blur_kind: String, pad: Int = 14, mark_kind: String = "",
                 mark_colour: UInt32 = rgba(255, 92, 64)):
        self.table = table^
        self.blur_kind = blur_kind
        self.pad = pad
        self.mark_kind = mark_kind
        self.mark_colour = mark_colour
        self.captions = List[Caption]()
        self.cx = 40
        self.cy = 630
        self.cw = 520
        self.ch = 60
        self.text_size = 21
        self.by_frame = List[List[Int]]()
        for _ in range(self.table.frames + 1):
            self.by_frame.append(List[Int]())
        for i in range(self.table.rows()):
            var f = self.table.frame[i]
            if f >= 0 and f < len(self.by_frame):
                self.by_frame[f].append(i)

    def caption_box(mut self, x: Int, y: Int, w: Int, h: Int, size: Float64 = 21):
        self.cx = x
        self.cy = y
        self.cw = w
        self.ch = h
        self.text_size = size

    def add_caption(mut self, first: Int, last: Int, text: String):
        self.captions.append(Caption(first, last, text))

    def plan(mut self, frame: Int, reel_frame: Int, mut ops: ImageOps, mut edits: Edits) raises:
        ref t = self.table
        if frame < len(self.by_frame):
            for i in self.by_frame[frame]:
                if t.kind[i] == self.blur_kind:
                    var side = max(t.w[i], t.h[i]) + 2 * self.pad
                    edits.blur_oval(t.x[i] - self.pad, t.y[i] - self.pad, t.w[i] + 2 * self.pad, t.h[i] + 2 * self.pad, max(side // 7, 4))
                elif self.mark_kind != "" and t.kind[i] == self.mark_kind and t.damaged[i]:
                    edits.outline_rect(Float64(t.x[i] - 6), Float64(t.y[i] - 6), Float64(t.w[i] + 12), Float64(t.h[i] + 12),
                                       self.mark_colour, 3, 18)
        for ref c in self.captions:
            if frame >= c.first and frame <= c.last:
                self._caption(frame, c.text, ops, edits)
                break

    def _caption(self, frame: Int, text: String, mut ops: ImageOps, mut edits: Edits) raises:
        var s = text
        if s.endswith("{t}"):
            var secs = Int(Float64(frame) / self.table.fps)
            var ss = String(secs % 60)
            if secs % 60 < 10:
                ss = "0" + ss
            s = String(s[byte = : s.byte_length() - 3]) + String(secs // 60) + ":" + ss
        var size = self.text_size
        var tw = ops.font.measure(s, size, MEDIUM)
        var h = Float64(min(self.ch - 12, Int(size * 2.1)))
        var dot = size * 0.42
        var padx = h * 0.42
        var w = min(padx + dot + size * 0.55 + tw + padx, Float64(self.cw))
        var x = Float64(self.cx)
        var y = Float64(self.cy) + (Float64(self.ch) - h) / 2
        edits.fill_rect(x, y, w, h, rgba(17, 20, 27, 214), h / 2)
        edits.fill_rect(x + padx, y + (h - dot) / 2, dot, dot, self.mark_colour, dot / 2)
        # ops.text puts the caption's box top-left at (x, y): its own padding is size × 0.35
        var pad = Int(size * 0.35 + 0.5)
        var box_h = Int(ops.font.ascent(size) + size * 0.3 + 1) + 2 * pad
        ops.text(edits, Int(x + padx + dot + size * 0.55) - pad, Int(y + (h - Float64(box_h)) / 2 + 0.5), s, size, rgba(255, 255, 255))


def flagged_captions(table: VideoTable, kind: String, names: Dict[String, String], what: String = "damaged") -> List[Caption]:
    """Captions naming the flagged (damaged) objects of `kind` in view, one per run of frames with the same set: an
    object's code is looked up in `names` (e.g. pallet code → shipment ID; the code itself when absent), and the frame's
    source time is appended ("S-5003 · pallet 2417 · damaged · 0:05"; two or more: "S-5012 · S-5013 · 2 damaged · 0:24")."""
    # codes per frame, in code order so a set reads the same on every frame
    var per = List[List[Int]]()
    for _ in range(table.frames + 1):
        per.append(List[Int]())
    for i in range(table.rows()):
        if table.kind[i] == kind and table.damaged[i] and table.frame[i] <= table.frames:
            ref l = per[table.frame[i]]
            var j = 0
            while j < len(l) and l[j] < table.code[i]:
                j += 1
            if j == len(l) or l[j] != table.code[i]:
                l.insert(j, table.code[i])
    var out = List[Caption]()
    var start = -1
    var key = String("")
    for f in range(table.frames + 2):
        var k = String("")
        if f <= table.frames:
            for c in per[f]:
                k += String(c) + ","
        if k != key:
            if start >= 0 and key != "":
                out.append(Caption(start, f - 1, _caption_text(per[start], kind, names, what)))
            start = f
            key = k
    return out^


def _caption_text(codes: List[Int], kind: String, names: Dict[String, String], what: String) -> String:
    var s = String("")
    for i in range(len(codes)):
        var c = String(codes[i]) if codes[i] != NO_CODE else String("unread")
        var name = names.get(c, kind + " " + c)
        if i > 0:
            s += " · "
        s += name
    if len(codes) == 1:
        if codes[0] != NO_CODE and String(codes[0]) in names:
            s += " · " + kind + " " + String(codes[0])
        s += " · " + what
    else:
        s += " · " + String(len(codes)) + " " + what
    return s + " · {t}"


def read_csv_map(path: String, key: String, value: String) raises -> Dict[String, String]:
    """A two-column lookup from a plain CSV (no quoted commas): `key` column → `value` column (e.g. pallet code →
    shipment). For full tables use mojoui.csvio."""
    var out = Dict[String, String]()
    var text = open(path, "r").read()
    var lines = text.split("\n")
    if len(lines) == 0:
        return out^
    var head = lines[0].split(",")
    var ki = -1
    var vi = -1
    for i in range(len(head)):
        var name = String(head[i].strip())
        if name == key:
            ki = i
        if name == value:
            vi = i
    if ki < 0 or vi < 0:
        raise Error("read_csv_map: no column " + key + " or " + value + " in " + path)
    for li in range(1, len(lines)):
        var cells = lines[li].split(",")
        if len(cells) > max(ki, vi):
            out[String(cells[ki].strip())] = String(cells[vi].strip())
    return out^
