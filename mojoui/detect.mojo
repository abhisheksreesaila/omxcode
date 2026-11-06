# mojoui.detect: an object detector in the app's own process (goal 51 M3): YOLOX-Tiny (Megvii, Apache-2.0; the pack
# scripts/packs/yolox.py builds) through mojoui.maxrt, the network on the GPU; the letterbox before it and the box
# decoding and non-maximum suppression after it in Mojo. 80 COCO classes.
#
#   var d = Detector("build/packs/yolox")          # (the pack loaded once per process: mojoui.maxrt.shared_model)
#   var boxes = d.detect_rgb(pixels, w, h)          # RGB bytes, row by row → List[Box]: cls, score, x, y, w, h (pixels)
#   var boxes = d.detect_rgba(frame, w, h)          # a video frame (mojoui.video: one UInt32 per pixel, RGBA in memory)
#   COCO_NAMES[b.cls]
#
# As Megvii's own inference does it: the picture scaled to fit 416 × 416 (bilinear, half-pixel centres: OpenCV's
# INTER_LINEAR), top-left, the rest grey 114, BGR 0–255; a box is kept when objectness × its best class ≥ `conf`
# (0.25), then NMS per class at IoU 0.45, then scaled back to the picture's pixels.

from std.math import exp
from std.memory import Pointer
from mojoui.maxrt import MaxModel, TensorIn, shared_model
from mojoui.shared import at

comptime SIZE = 416
comptime CELLS = 3549  # 52² + 26² + 13² (strides 8, 16, 32)
comptime COCO_NAMES: List[String] = [
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light", "fire hydrant",
    "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe",
    "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball", "kite", "baseball bat",
    "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl",
    "banana", "apple", "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch",
    "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave",
    "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"]


@fieldwise_init
struct Box(Copyable, Movable, ImplicitlyCopyable):
    var cls: Int
    var score: Float64
    var x: Float64
    var y: Float64
    var w: Float64
    var h: Float64


def coco_name(cls: Int) -> String:
    var names = materialize[COCO_NAMES]()
    return names[cls] if 0 <= cls < len(names) else String("?")


def _iou(a: Box, b: Box) -> Float64:
    var iw = max(0.0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x))
    var ih = max(0.0, min(a.y + a.h, b.y + b.h) - max(a.y, b.y))
    var inter = iw * ih
    var u = a.w * a.h + b.w * b.h - inter
    return inter / u if u > 0 else 0.0


def nms(var boxes: List[Box], iou: Float64) -> List[Box]:
    """Highest score first; a box that overlaps a kept box of its class by more than `iou` is dropped."""
    # (insertion sort by score: a frame has tens of candidates)
    for i in range(1, len(boxes)):
        var k = i
        while k > 0 and boxes[k - 1].score < boxes[k].score:
            var t = boxes[k - 1]
            boxes[k - 1] = boxes[k]
            boxes[k] = t
            k -= 1
    var kept = List[Box]()
    for b in boxes:
        var ok = True
        for ref k in kept:
            if k.cls == b.cls and _iou(k, b) > iou:
                ok = False
                break
        if ok:
            kept.append(b)
    return kept^


def decode(raw: List[Float32], conf: Float64, scale: Float64) -> List[Box]:
    """The head's [3549, 85] rows as boxes in the picture's pixels (÷ `scale`, the letterbox's), score ≥ conf."""
    var out = List[Box]()
    var row = 0
    for stride in [8, 16, 32]:
        var n = SIZE // stride
        for gy in range(n):
            for gx in range(n):
                var o = row * 85
                row += 1
                var obj = Float64(raw[o + 4])
                if obj < conf:
                    continue
                var best = 0
                var top = Float64(raw[o + 5])
                for c in range(1, 80):
                    var v = Float64(raw[o + 5 + c])
                    if v > top:
                        top = v
                        best = c
                var score = obj * top
                if score < conf:
                    continue
                var s = Float64(stride)
                var cx = (Float64(raw[o]) + Float64(gx)) * s
                var cy = (Float64(raw[o + 1]) + Float64(gy)) * s
                var w = exp(Float64(raw[o + 2])) * s
                var h = exp(Float64(raw[o + 3])) * s
                out.append(Box(best, score, (cx - w / 2) / scale, (cy - h / 2) / scale, w / scale, h / scale))
    return out^


struct Detector(Movable):
    var model: Int  # at[MaxModel](model)
    var conf: Float64
    var iou: Float64

    def __init__(out self, pack: String, conf: Float64 = 0.25, iou: Float64 = 0.45) raises:
        var dir = String(pack.rstrip("/"))
        self.model = shared_model(dir + "/yolox.mef", dir + "/yolox.safetensors", gpu=True)
        self.conf = conf
        self.iou = iou

    def _run(mut self, var input: List[Float32], scale: Float64) raises -> List[Box]:
        var ins = List[TensorIn]()
        ins.append(TensorIn.f32(input, [1, SIZE, SIZE, 3]))
        var raw = at[MaxModel](self.model)[].run(ins, 1)[0].floats()
        return nms(decode(raw, self.conf, scale), self.iou)

    def detect_rgb(mut self, pixels: List[UInt8], w: Int, h: Int) raises -> List[Box]:
        """RGB bytes (3 a pixel, row by row)."""
        var r = min(Float64(SIZE) / Float64(h), Float64(SIZE) / Float64(w))
        return self._run(letterbox[3, 0, 1, 2](Int(pixels.unsafe_ptr()), w, h, r), r)

    def detect_rgba(mut self, frame: List[UInt32], w: Int, h: Int) raises -> List[Box]:
        """A video frame: one UInt32 a pixel, its bytes R, G, B, A in memory (mojoui.video)."""
        var r = min(Float64(SIZE) / Float64(h), Float64(SIZE) / Float64(w))
        return self._run(letterbox[4, 0, 1, 2](Int(frame.unsafe_ptr()), w, h, r), r)


def letterbox[step: Int, R: Int, G: Int, B: Int](address: Int, w: Int, h: Int, r: Float64) -> List[Float32]:
    """416 × 416 × 3 floats, BGR 0–255: the picture scaled by r (to int(w·r) × int(h·r), OpenCV INTER_LINEAR's
    half-pixel bilinear), top-left, the rest 114. `step` bytes a pixel; R, G, B: where each channel sits in it."""
    var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=address)
    var out = List[Float32](length=SIZE * SIZE * 3, fill=114.0)
    var chans: List[Int] = [B, G, R]  # (the network reads BGR)
    var nw = Int(Float64(w) * r)
    var nh = Int(Float64(h) * r)
    var fx = Float64(w) / Float64(nw)
    var fy = Float64(h) / Float64(nh)
    for y in range(nh):
        var sy = (Float64(y) + 0.5) * fy - 0.5
        var y0 = Int(sy) if sy >= 0 else -1
        var wy = sy - Float64(y0)
        if y0 < 0:
            y0 = 0
            wy = 0.0
        var y1 = min(y0 + 1, h - 1)
        if y0 >= h - 1:
            y0 = h - 1
            wy = 0.0
        for x in range(nw):
            var sx = (Float64(x) + 0.5) * fx - 0.5
            var x0 = Int(sx) if sx >= 0 else -1
            var wx = sx - Float64(x0)
            if x0 < 0:
                x0 = 0
                wx = 0.0
            var x1 = min(x0 + 1, w - 1)
            if x0 >= w - 1:
                x0 = w - 1
                wx = 0.0
            var o = (y * SIZE + x) * 3
            for c in range(3):
                var ch = chans[c]
                var a = Float64(src[(y0 * w + x0) * step + ch])
                var b = Float64(src[(y0 * w + x1) * step + ch])
                var cc = Float64(src[(y1 * w + x0) * step + ch])
                var d = Float64(src[(y1 * w + x1) * step + ch])
                var v = (a * (1 - wx) + b * wx) * (1 - wy) + (cc * (1 - wx) + d * wx) * wy
                out[o + c] = Float32(Int(v + 0.5))  # (OpenCV rounds the resized bytes)
    return out^
