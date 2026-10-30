# mojoui.visionmodel: a learned vision model in the Analyzer slot (goal 39 M12 spike, D-940..D-959). A generic component:
# an app names a model and what it is looking for in words; it gets rows in a VideoTable, like any other analyzer.
#
#   var det = VisionModel("google/owlv2-base-patch16-ensemble", DETECT)        # or a model pack folder (omxconsole, later)
#   var found = det.detect(pixels, width, height, prompts, threshold=0.15)      # List[Detection]: box, score, prompt index
#   var sam = VisionModel("facebook/sam2.1-hiera-tiny", SEGMENT)
#   var m = sam.segment(pixels, width, height, found[0])                        # MaskBox: the mask's box and area
#   sam.track_start(width, height); sam.track_add(0, ids, boxes)                # then per frame: sam.track_step(pixels, ...)
#
#   var a = ModelAnalyzer(det^, prompts, kinds, threshold=0.15, stride=5, batch=8)   # an Analyzer: scan(video, a, ranges)
#
# Find more like this (M12, D-961..): the user taps ONE box on one frame, and every frame with something like it comes back
# as rows (OWLv2 image-guided detection, no words, no colours):
#
#   var ex = List[Example](); ex.append(Example(230, 652, 366, 60, 44))      # frame, box; Example(..., positive=False): "not this"
#   var found = find_like(video, det^, ex, "like")                          # LikeResult: .table (rows), .threshold, .tiles
#
# The rule, the same for every video (no per-video constants): the example's query is the model's own box on that frame
# that overlaps the tap best; the rest of that frame gives `LIKE_NEGATIVES` hard negatives (the tap says "this, not
# that"); a box matches when its logit is at least LIKE_RATIO of the example's self-match logit (its own query on its
# own frame) AND it is closer to a positive example than to every negative. The zoom (tiles) is the least at which the
# example spans two of the model's patches. Rows come from ModelAnalyzer, so keyframes, batches, tracks and the
# interpolation between keyframes are the same as for text prompts, and the rows join everything else (geo, reels).
#
# Backends. (A), here: PyTorch + Hugging Face transformers in this process through Mojo's Python interop
# (mojoui/visionmodel_torch.py). The frame is handed over as an address, never a file or a socket: Python wraps it with
# numpy without a copy, then one copy goes to the GPU through a pinned buffer (≈ 0.35 ms for 1280×720, measured). A frame
# that is already on the GPU (a MAX DeviceBuffer) goes over with no copy at all: detect_on_device() hands its CUDA pointer
# to torch (CUDA Array Interface). (B), later: a model pack compiled by MAX and run through MAX's C API
# (docs/research/inprocess-ai.md, Option 1); only this file changes, the API below stays.
#
# Masks stay on the GPU in the backend; what comes back is their box and area (rows). A mask column is a later step.

from std.python import Python, PythonObject
from std.os import getenv
from std.reflection import source_location
from mojoui.videotable import Analyzer, Cells, VideoTable, ColourRange, scan
from mojoui.video import VideoSource
from mojoui.clock import now_ns

comptime DETECT = 0  # open-vocabulary detection: boxes for text prompts (OWLv2 / OWL-ViT)
comptime SEGMENT = 1  # promptable segmentation and tracking: a box or points -> a mask that follows the object (SAM 2.x)


@fieldwise_init
struct Detection(Copyable, Movable, ImplicitlyCopyable):
    """A box in the frame's pixels (x, y: top-left), its score (0..1) and the index of the prompt it answers. slot: which
    staged frame it came from (batches; 0 otherwise)."""

    var x: Float64
    var y: Float64
    var w: Float64
    var h: Float64
    var score: Float64
    var label: Int
    var slot: Int


@fieldwise_init
struct MaskBox(Copyable, Movable, ImplicitlyCopyable):
    """A mask, as rows see it: the object id, the mask's bounding box and its area in pixels (0: lost this frame)."""

    var id: Int
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var area: Int


@fieldwise_init
struct Example(Copyable, Movable, ImplicitlyCopyable):
    """One tap: a box (x, y: top-left, w, h in pixels) on frame `frame` of the video; positive = "find more like this",
    negative = "not this"."""

    var frame: Int
    var x: Float64
    var y: Float64
    var w: Float64
    var h: Float64
    var positive: Bool

    def __init__(out self, frame: Int, x: Float64, y: Float64, w: Float64, h: Float64):
        self.frame = frame
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.positive = True


comptime LIKE_RATIO = 0.5  # a match's logit is at least half the example's self-match logit (D-963)
comptime LIKE_NEGATIVES = 64  # hard negatives from the example's own frame (a cost bound: 32..1024 give the same rows, D-962)


def _py_list(items: List[String]) raises -> PythonObject:
    var out = Python.list()
    for s in items:
        out.append(PythonObject(s))
    return out^


def _floats(lst: PythonObject) raises -> List[Float64]:
    """A Python list of floats as Mojo floats, read in one pass through an array('d') buffer (no call per number)."""
    var array = Python.import_module("array")
    var a = array.array("d", lst)
    var n = Int(py=Python.import_module("builtins").len(a))
    var out = List[Float64](capacity=n)
    if n == 0:
        return out^
    var p = UnsafePointer[Float64, MutAnyOrigin](unsafe_from_address=Int(py=a.buffer_info()[0]))
    for i in range(n):
        out.append(p.unsafe_offset(i)[])
    return out^


def _backend() raises -> PythonObject:
    """mojoui/visionmodel_torch.py, loaded from its file (never through sys.path, so a visionmodel_torch.py planted in
    the working directory or on PYTHONPATH is not picked up). Where: $MOJOUI_PY (a folder) if set, else the folder of
    this source file as the compiler saw it. A binary moved away from its source needs MOJOUI_PY."""
    var os = Python.import_module("os")
    var folder = getenv("MOJOUI_PY", "")
    if folder.byte_length() == 0:
        folder = String(py=os.path.dirname(os.path.abspath(source_location().file_name())))
    var path = os.path.join(folder, "visionmodel_torch.py")
    if not Bool(py=os.path.isfile(path)):
        raise Error("VisionModel: no backend at " + String(py=path) + " (set MOJOUI_PY to the folder of visionmodel_torch.py)")
    var sys = Python.import_module("sys")
    if Bool(py=sys.modules.__contains__("visionmodel_torch")):
        return sys.modules["visionmodel_torch"]
    var util = Python.import_module("importlib.util")
    var spec = util.spec_from_file_location("visionmodel_torch", path)
    var mod = util.module_from_spec(spec)
    sys.modules["visionmodel_torch"] = mod
    spec.loader.exec_module(mod)
    return mod


struct VisionModel(Movable):
    """One model, loaded once, called per frame. `name`: a Hugging Face id (cached under HF_HOME) or a local folder."""

    var name: String
    var task: Int
    var device: String
    var load_ms: Float64
    var _m: PythonObject

    def __init__(out self, name: String, task: Int, device: String = "cuda", half: Bool = True) raises:
        self.name = name
        self.task = task
        self.device = device
        var backend = _backend()
        if task == DETECT:
            self._m = backend.Detector(name, device, half)
        elif task == SEGMENT:
            self._m = backend.Segmenter(name, device, half)
        else:
            raise Error("VisionModel: unknown task " + String(task))
        self.load_ms = Float64(py=self._m.load_ms)

    def handoff_ms(self) raises -> Float64:
        """The last frame's hand-off: address -> GPU tensor (or wrapping a GPU pointer)."""
        return Float64(py=self._m.upload.last_ms)

    def model_ms(self) raises -> Float64:
        """The last call's model time, preprocessing and postprocessing on the GPU included."""
        return Float64(py=self._m.model_ms)

    # ---------- DETECT ----------

    def _detections(self, flat: List[Float64], stride: Int) -> List[Detection]:
        var out = List[Detection]()
        var i = 0
        while i + stride <= len(flat):
            var o = i + stride - 6
            var slot = Int(flat[i]) if stride == 7 else 0
            out.append(Detection(flat[o], flat[o + 1], flat[o + 2], flat[o + 3], flat[o + 4], Int(flat[o + 5]), slot))
            i += stride
        return out^

    def detect(mut self, pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int, prompts: List[String],
               threshold: Float64 = 0.2) raises -> List[Detection]:
        """Boxes for the prompts on one RGBA frame in host memory."""
        var flat = _floats(self._m.detect_address(Int(pixels), width, height, _py_list(prompts), threshold))
        return self._detections(flat, 6)

    def detect_on_device(mut self, device_ptr: Int, width: Int, height: Int, prompts: List[String],
                         threshold: Float64 = 0.2) raises -> List[Detection]:
        """The same, for a frame already on the GPU (a CUDA pointer to RGBA bytes): no copy at all."""
        var flat = _floats(self._m.detect_device(device_ptr, width, height, _py_list(prompts), threshold))
        return self._detections(flat, 6)

    def stage(mut self, pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int) raises -> Int:
        """Copies a frame to the GPU for the next flush() (the buffer is free again on return); frames waiting."""
        return Int(py=self._m.stage(Int(pixels), width, height))

    def flush(mut self, prompts: List[String], threshold: Float64 = 0.2) raises -> List[Detection]:
        """Every staged frame in one batch; Detection.slot says which."""
        return self._detections(_floats(self._m.flush(_py_list(prompts), threshold)), 7)

    # ---------- find more like this (image-guided DETECT) ----------

    def add_example(mut self, pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int, ex: Example,
                    tiles: Int = -1) raises -> Float64:
        """An example on its frame's pixels. The first one fixes the zoom (tiles; -1: automatic, see visionmodel_torch
        auto_tiles). Returns how well the model's own best box overlaps the tap (IoU)."""
        return Float64(py=self._m.add_example(Int(pixels), width, height, ex.x, ex.y, ex.w, ex.h, ex.positive, tiles))

    def add_background_negatives(mut self, k: Int = LIKE_NEGATIVES) raises -> Int:
        """The `k` boxes of each example's frame that look most like it without touching a tap, as negatives."""
        return Int(py=self._m.add_background_negatives(k))

    def clear_examples(mut self) raises:
        self._m.clear_examples()

    def self_match(self) raises -> Float64:
        """The lowest self-match logit over the positive examples."""
        return Float64(py=self._m.like_stats()[0])

    def tiles(self) raises -> Int:
        return Int(py=self._m.tiles)

    def like(mut self, pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int, threshold: Float64) raises -> List[Detection]:
        """Boxes like the examples on one frame; score = logit, label = the example that matched best."""
        return self._detections(_floats(self._m.like_address(Int(pixels), width, height, threshold)), 6)

    def flush_like(mut self, threshold: Float64) raises -> List[Detection]:
        """Every staged frame against the examples in one batch; Detection.slot says which."""
        return self._detections(_floats(self._m.flush_like(threshold)), 7)

    # ---------- SEGMENT ----------

    def track_start(mut self, width: Int, height: Int) raises:
        self._m.start(width, height)

    def track_add(mut self, frame: Int, ids: List[Int], boxes: List[Detection]) raises:
        """Objects to follow, seeded with boxes on `frame` (counted from track_start), all in one call."""
        var py_ids = Python.list()
        var flat = Python.list()
        for i in range(len(ids)):
            py_ids.append(PythonObject(ids[i]))
            flat.append(PythonObject(boxes[i].x))
            flat.append(PythonObject(boxes[i].y))
            flat.append(PythonObject(boxes[i].w))
            flat.append(PythonObject(boxes[i].h))
        self._m.add_boxes(frame, py_ids, flat)

    def track_step(mut self, pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int) raises -> List[MaskBox]:
        """The next frame of the session: every object's mask box and area."""
        var f = _floats(self._m.step_address(Int(pixels), width, height))
        var out = List[MaskBox]()
        var i = 0
        while i + 6 <= len(f):
            out.append(MaskBox(Int(f[i]), Int(f[i + 1]), Int(f[i + 2]), Int(f[i + 3]), Int(f[i + 4]), Int(f[i + 5])))
            i += 6
        return out^

    def segment(mut self, pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int, box: Detection) raises -> MaskBox:
        """One frame, one box -> its mask (a one-frame session)."""
        self.track_start(width, height)
        var ids = List[Int]()
        ids.append(1)
        var boxes = List[Detection]()
        boxes.append(box)
        self.track_add(0, ids, boxes)
        return self.track_step(pixels, width, height)[0]


# ---------- the Analyzer: a model over a whole video ----------


def iou(a: Detection, b: Detection) -> Float64:
    var x0 = max(a.x, b.x)
    var y0 = max(a.y, b.y)
    var x1 = min(a.x + a.w, b.x + b.w)
    var y1 = min(a.y + a.h, b.y + b.h)
    var inter = max(x1 - x0, 0.0) * max(y1 - y0, 0.0)
    var union = a.w * a.h + b.w * b.h - inter
    return inter / union if union > 0 else 0.0


def _near(a: Detection, b: Detection, link_iou: Float64, reach: Float64) -> Float64:
    """How far apart two boxes are for linking, in box sizes (centre distance / the larger side); -1: too far (neither
    overlap >= link_iou nor centres within `reach` box sizes). Overlap alone fails for small or fast things: a 60 px
    box that moves 37 px between keyframes overlaps itself by 0.24."""
    var dx = (a.x + a.w / 2) - (b.x + b.w / 2)
    var dy = (a.y + a.h / 2) - (b.y + b.h / 2)
    var size = max(max(a.w, a.h), max(b.w, b.h), 1.0)
    var d = (dx * dx + dy * dy) ** 0.5 / size
    if iou(a, b) >= link_iou or d <= reach:
        return d
    return -1


struct ModelAnalyzer(Analyzer):
    """A DETECT model as an Analyzer: every `stride`-th frame (a keyframe) is staged on the GPU, `batch` keyframes run
    together, and finish() links boxes across keyframes into tracks and fills the frames between two linked keyframes
    by linear interpolation, so a 1140-frame video costs 1140 / stride model frames. Linking: a box joins the nearest
    track of the same kind seen on one of the last `max_gap` keyframes, when they overlap (IoU >= link_iou) or their
    centres are within `reach` box sizes, as they were or moved by the scene's motion (the median move of the other
    links, see finish()); one box per track per keyframe, best scores first. A row per box per frame:
    kind = kinds[label], track = the track id, value = the score (interpolated rows: the lower of the two). A track
    takes at most one box per keyframe, so no frame gets two rows of one track. After the video's last keyframe its boxes
    are held to the last frame scanned (no keyframe follows to interpolate to).
    stride = 1: every frame, no interpolation.
    Two modes: text prompts (`ModelAnalyzer(model, prompts, kinds, threshold)`) or examples (`ModelAnalyzer.like(model,
    kind, threshold)`, after model.add_example(...)); the score is then a logit, not a probability."""

    var model: VisionModel
    var prompts: List[String]
    var kinds: List[String]
    var threshold: Float64
    var stride: Int
    var batch: Int
    var link_iou: Float64
    var reach: Float64
    var max_gap: Int
    var by_example: Bool
    var _first: Int
    var _last: Int  # the last frame step() saw
    var _staged: List[Int]  # frame number of each staged keyframe
    var _keys: List[Int]  # keyframes seen, in order
    var _found: List[List[Detection]]  # per keyframe
    var model_seconds: Float64
    var model_frames: Int

    def __init__(out self, var model: VisionModel, prompts: List[String], kinds: List[String], threshold: Float64 = 0.15,
                 stride: Int = 1, batch: Int = 8, link_iou: Float64 = 0.3, reach: Float64 = 1.0, max_gap: Int = 2):
        self.model = model^
        self.prompts = prompts.copy()
        self.kinds = kinds.copy()
        self.threshold = threshold
        self.stride = max(stride, 1)
        self.batch = max(batch, 1)
        self.link_iou = link_iou
        self.reach = reach
        self.max_gap = max(max_gap, 1)
        self.by_example = False
        self._first = -1
        self._last = -1
        self._staged = List[Int]()
        self._keys = List[Int]()
        self._found = List[List[Detection]]()
        self.model_seconds = 0
        self.model_frames = 0

    @staticmethod
    def like(var model: VisionModel, kind: String, threshold: Float64, stride: Int = 1, batch: Int = 8,
             link_iou: Float64 = 0.3, reach: Float64 = 1.0, max_gap: Int = 2) -> Self:
        """Rows of `kind` for boxes like the model's examples (VisionModel.add_example), logit >= threshold."""
        var kinds = List[String]()
        kinds.append(kind)
        var a = Self(model^, List[String](), kinds, threshold, stride, batch, link_iou, reach, max_gap)
        a.by_example = True
        return a^

    def _kind(self, d: Detection) -> String:
        return self.kinds[min(d.label, len(self.kinds) - 1)]

    def _flush(mut self) raises:
        if len(self._staged) == 0:
            return
        var t0 = Int(now_ns())
        var found = self.model.flush_like(self.threshold) if self.by_example else self.model.flush(self.prompts, self.threshold)
        self.model_seconds += Float64(Int(now_ns()) - t0) / 1e9
        self.model_frames += len(self._staged)
        for k in range(len(self._staged)):
            var mine = List[Detection]()
            for d in found:
                if d.slot == k:
                    mine.append(d)
            self._keys.append(self._staged[k])
            self._found.append(mine^)
        self._staged.clear()

    def step(mut self, frame: Int, pixels: UnsafePointer[UInt32, MutAnyOrigin], width: Int, height: Int, cells: Cells,
             mut table: VideoTable) raises:
        if self._first < 0:
            self._first = frame
        self._last = frame
        if (frame - self._first) % self.stride != 0:
            return
        var waiting = self.model.stage(pixels, width, height)
        self._staged.append(frame)
        if waiting >= self.batch:
            self._flush()

    def _best_track(self, d: Detection, k: Int, track_key: List[Int], track_box: List[Detection], track_kind: List[String],
                    taken: List[Bool], sx: Float64, sy: Float64) -> Int:
        """The nearest free track for box d on keyframe k: its last box as it was, or moved by the motion estimate
        (sx, sy per keyframe), whichever is nearer; -1: none in reach."""
        var best = -1
        var best_d = 1e18
        for t in range(len(track_key)):
            if taken[t] or track_key[t] < k - self.max_gap or track_kind[t] != self._kind(d):
                continue
            ref p = track_box[t]
            var gap = Float64(k - track_key[t])
            var moved = Detection(p.x + sx * gap, p.y + sy * gap, p.w, p.h, p.score, p.label, p.slot)
            var d0 = _near(d, p, self.link_iou, self.reach)
            var d1 = _near(d, moved, self.link_iou, self.reach)
            var dist = d0 if d1 < 0 or (d0 >= 0 and d0 < d1) else d1
            if dist >= 0 and dist < best_d:
                best_d = dist
                best = t
        return best

    def finish(mut self, mut table: VideoTable) raises:
        self._flush()
        # link: per keyframe, boxes best score first; each takes the nearest free track (same kind, last seen on one of
        # the previous max_gap keyframes). Two passes, so small fast things link too: the first links what is within
        # reach as it was (or as moved by the last motion estimate); the median move of those links per keyframe is the
        # new motion estimate (a camera or a belt moves everything alike); the second pass links the rest with it.
        var track_key = List[Int]()  # per track: keyframe index last seen
        var track_box = List[Detection]()  # per track: its box there
        var track_kind = List[String]()
        var ids = List[List[Int]]()  # per keyframe, per box: track id
        var prev = List[List[Tuple[Int, Int]]]()  # per keyframe, per box: (keyframe, box) it continues, (-1, -1): new
        var sx = 0.0
        var sy = 0.0
        for k in range(len(self._keys)):
            var n = len(self._found[k])
            var order = List[Int]()
            for i in range(n):
                order.append(i)
            for i in range(1, n):  # insertion sort by score, best first (a handful of boxes)
                var j = i
                while j > 0 and self._found[k][order[j]].score > self._found[k][order[j - 1]].score:
                    order.swap_elements(j, j - 1)
                    j -= 1
            var mine = List[Int](length=n, fill=-1)
            var from_ = List[Tuple[Int, Int]](length=n, fill=(-1, -1))
            var taken = List[Bool](length=len(track_key), fill=False)
            var moves_x = List[Float64]()
            var moves_y = List[Float64]()
            for pass_ in range(2):
                for i in order:
                    if mine[i] >= 0:
                        continue
                    ref d = self._found[k][i]
                    var best = self._best_track(d, k, track_key, track_box, track_kind, taken, sx, sy)
                    if best < 0:
                        continue
                    taken[best] = True
                    var pk = track_key[best]
                    for j in range(len(self._found[pk])):
                        if ids[pk][j] == best:
                            from_[i] = (pk, j)
                    ref p = track_box[best]
                    var gap = Float64(k - pk)
                    moves_x.append(((d.x + d.w / 2) - (p.x + p.w / 2)) / gap)
                    moves_y.append(((d.y + d.h / 2) - (p.y + p.h / 2)) / gap)
                    track_key[best] = k
                    track_box[best] = d
                    mine[i] = best
                if pass_ == 0 and len(moves_x) > 0:
                    sort(moves_x)
                    sort(moves_y)
                    sx = moves_x[len(moves_x) // 2]
                    sy = moves_y[len(moves_y) // 2]
            for i in order:
                if mine[i] < 0:
                    mine[i] = len(track_key)
                    track_key.append(k)
                    track_box.append(self._found[k][i])
                    track_kind.append(self._kind(self._found[k][i]))
                    taken.append(True)
            ids.append(mine^)
            prev.append(from_^)
        for k in range(len(self._keys)):
            var f1 = self._keys[k]
            for i in range(len(self._found[k])):
                ref e = self._found[k][i]
                table.add(f1, self._kind(e), Int(e.x), Int(e.y), Int(e.w), Int(e.h), track=ids[k][i], value=e.score)
                if k + 1 == len(self._keys):  # the video ends before the next keyframe: hold the box to the last frame
                    for f in range(f1 + 1, self._last + 1):
                        table.add(f, self._kind(e), Int(e.x), Int(e.y), Int(e.w), Int(e.h), track=ids[k][i], value=e.score)
                var pk = prev[k][i][0]
                if pk < 0:
                    continue
                ref d = self._found[pk][prev[k][i][1]]
                var f0 = self._keys[pk]
                for f in range(f0 + 1, f1):
                    var t = Float64(f - f0) / Float64(f1 - f0)
                    table.add(f, self._kind(e), Int(d.x + (e.x - d.x) * t), Int(d.y + (e.y - d.y) * t),
                              Int(d.w + (e.w - d.w) * t), Int(d.h + (e.h - d.h) * t), track=ids[k][i],
                              value=min(d.score, e.score))


# ---------- find more like this, over a whole video ----------


struct LikeResult(Movable):
    """What find_like found: the rows (a VideoTable, every frame with a match; kind = the kind asked for) and how: the
    threshold it chose (a logit), the example's self-match it came from, the zoom, the model's share of the time."""

    var table: VideoTable
    var threshold: Float64
    var self_match: Float64
    var tiles: Int
    var negatives: Int
    var model_frames: Int
    var model_seconds: Float64
    var seconds: Float64  # the whole call: examples, decode, model, rows

    def __init__(out self, var table: VideoTable, threshold: Float64, self_match: Float64, tiles: Int, negatives: Int,
                 model_frames: Int, model_seconds: Float64, seconds: Float64):
        self.table = table^
        self.threshold = threshold
        self.self_match = self_match
        self.tiles = tiles
        self.negatives = negatives
        self.model_frames = model_frames
        self.model_seconds = model_seconds
        self.seconds = seconds


def find_like(mut video: VideoSource, var model: VisionModel, examples: List[Example], kind: String, stride: Int = 5,
              batch: Int = 8, ratio: Float64 = LIKE_RATIO, negatives: Int = LIKE_NEGATIVES, tiles: Int = -1,
              start: Int = 0, limit: Int = 0) raises -> LikeResult:
    """Find more like this: every frame of `video` (from `start`; `limit` > 0: at most that many) with something like
    the positive examples and unlike the negative ones, as rows of `kind`. One example is enough. The threshold is the
    documented rule (LIKE_RATIO of the self-match logit), the zoom is automatic unless `tiles` >= 0."""
    if model.task != DETECT:
        raise Error("find_like: needs a DETECT model (OWLv2 / OWL-ViT)")
    var t0 = Int(now_ns())
    model.clear_examples()
    var px = List[UInt32]()
    var have_positive = False
    for ex in examples:
        video.seek_frame(ex.frame)
        if not video.next_into(px):
            raise Error("find_like: no frame " + String(ex.frame))
        var addr = UnsafePointer[UInt32, MutAnyOrigin](unsafe_from_address=Int(px.unsafe_ptr()))
        _ = model.add_example(addr, video.width, video.height, ex, tiles)
        have_positive = have_positive or ex.positive
    if not have_positive:
        raise Error("find_like: at least one positive example")
    var n_ex = len(examples)
    var total = model.add_background_negatives(negatives) if negatives > 0 else n_ex
    var self_match = model.self_match()
    var threshold = ratio * self_match
    var used_tiles = model.tiles()
    var a = ModelAnalyzer.like(model^, kind, threshold, stride, batch)
    video.seek_frame(start)
    var ranges = List[ColourRange]()
    ranges.append(ColourRange(0, 359, 0, 255, 0, 255))  # scan()'s cell grid wants one range; the model ignores it
    var table = scan(video, a, ranges, 8, True, limit)
    var secs = Float64(Int(now_ns()) - t0) / 1e9
    return LikeResult(table^, threshold, self_match, used_tiles, total - n_ex, a.model_frames, a.model_seconds, secs)


def frames_with(table: VideoTable, kind: String) -> List[Int]:
    """The frames (ascending, once each) on which `table` has a row of `kind`."""
    var top = 0
    for i in range(table.rows()):
        if table.kind[i] == kind:
            top = max(top, table.frame[i] + 1)
    var on = List[Bool](length=top, fill=False)
    for i in range(table.rows()):
        if table.kind[i] == kind:
            on[table.frame[i]] = True
    var out = List[Int]()
    for f in range(top):
        if on[f]:
            out.append(f)
    return out^
