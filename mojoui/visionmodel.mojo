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
from mojoui.videotable import Analyzer, Cells, VideoTable
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
        var sys = Python.import_module("sys")
        sys.path.insert(0, PythonObject(getenv("MOJOUI_PY", "mojoui")))
        var backend = Python.import_module("visionmodel_torch")
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


struct ModelAnalyzer(Analyzer):
    """A DETECT model as an Analyzer: every `stride`-th frame (a keyframe) is staged on the GPU, `batch` keyframes run
    together, and finish() links boxes across keyframes (same prompt, overlap ≥ `link_iou`) into tracks and fills the
    frames between two linked keyframes by linear interpolation, so a 1140-frame video costs 1140 / stride model frames.
    A row per box per frame: kind = kinds[prompt], track = the track id, value = the score (interpolated rows: the lower
    of the two). stride = 1: every frame, no interpolation."""

    var model: VisionModel
    var prompts: List[String]
    var kinds: List[String]
    var threshold: Float64
    var stride: Int
    var batch: Int
    var link_iou: Float64
    var _first: Int
    var _staged: List[Int]  # frame number of each staged keyframe
    var _keys: List[Int]  # keyframes seen, in order
    var _found: List[List[Detection]]  # per keyframe
    var model_seconds: Float64
    var model_frames: Int

    def __init__(out self, var model: VisionModel, prompts: List[String], kinds: List[String], threshold: Float64 = 0.15,
                 stride: Int = 1, batch: Int = 8, link_iou: Float64 = 0.3):
        self.model = model^
        self.prompts = prompts.copy()
        self.kinds = kinds.copy()
        self.threshold = threshold
        self.stride = max(stride, 1)
        self.batch = max(batch, 1)
        self.link_iou = link_iou
        self._first = -1
        self._staged = List[Int]()
        self._keys = List[Int]()
        self._found = List[List[Detection]]()
        self.model_seconds = 0
        self.model_frames = 0

    def _flush(mut self) raises:
        if len(self._staged) == 0:
            return
        var t0 = Int(now_ns())
        var found = self.model.flush(self.prompts, self.threshold)
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
        if (frame - self._first) % self.stride != 0:
            return
        if self.model.stage(pixels, width, height) >= self.batch:
            self._staged.append(frame)
            self._flush()
        else:
            self._staged.append(frame)

    def finish(mut self, mut table: VideoTable) raises:
        self._flush()
        # tracks: each box takes the id of the best-overlapping box of the same prompt on the keyframe before
        var ids = List[List[Int]]()
        var next_id = 0
        for k in range(len(self._keys)):
            var mine = List[Int]()
            for d in self._found[k]:
                var best = -1
                var best_iou = self.link_iou
                if k > 0:
                    for j in range(len(self._found[k - 1])):
                        ref p = self._found[k - 1][j]
                        var o = iou(d, p)
                        if p.label == d.label and o >= best_iou:
                            best = ids[k - 1][j]
                            best_iou = o
                if best < 0:
                    best = next_id
                    next_id += 1
                mine.append(best)
            ids.append(mine^)
        for k in range(len(self._keys)):
            var f0 = self._keys[k]
            for i in range(len(self._found[k])):
                ref d = self._found[k][i]
                table.add(f0, self.kinds[d.label], Int(d.x), Int(d.y), Int(d.w), Int(d.h), track=ids[k][i], value=d.score)
                if k + 1 >= len(self._keys):
                    continue
                var f1 = self._keys[k + 1]
                for j in range(len(self._found[k + 1])):
                    if ids[k + 1][j] != ids[k][i]:
                        continue
                    ref e = self._found[k + 1][j]
                    for f in range(f0 + 1, f1):
                        var t = Float64(f - f0) / Float64(f1 - f0)
                        table.add(f, self.kinds[d.label], Int(d.x + (e.x - d.x) * t), Int(d.y + (e.y - d.y) * t),
                                  Int(d.w + (e.w - d.w) * t), Int(d.h + (e.h - d.h) * t), track=ids[k][i],
                                  value=min(d.score, e.score))
