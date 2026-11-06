# mojoui.imagemodel: any picture-to-labels pack in the app's own process (goal 59): a network scripts/packs/from_torch.py
# converted from PyTorch (ResNet-18, or your own), run through mojoui.maxrt on the GPU. Nothing in here knows which
# network it is: the pack's model.json says its input size and labels.txt its labels.
#
#   var m = ImageModel("build/packs/scene")        # (loaded once per process: mojoui.maxrt.shared_model)
#   var top = m.top_rgba(frame, w, h)              # a video frame (one UInt32 a pixel, RGBA in memory) → Guess
#   m.labels[top.label], top.score                 # its best label and how sure (softmax, 0–1)
#   var logits = m.logits_rgba(frame, w, h)        # every label's raw output, in labels.txt's order
#
# The picture it gets, as from_torch.py's reference does it: the centre square of the frame, resized to size × size
# (bilinear at pixel centres, edges clamped), RGB 0–255 as float32, NHWC; normalising is the graph's own first step.

from std.math import exp, floor
from mojoui.json import Json
from mojoui.maxrt import MaxModel, TensorIn, shared_model
from mojoui.shared import at


@fieldwise_init
struct Guess(Copyable, Movable, ImplicitlyCopyable):
    var label: Int
    var score: Float64  # the softmax's share for that label


struct ImageModel(Movable):
    var model: Int  # at[MaxModel](model)
    var size: Int
    var labels: List[String]
    var function: String  # what a script calls it (model.json)

    def __init__(out self, pack: String) raises:
        var dir = String(pack.rstrip("/"))
        var name = String(dir[byte = dir.rfind("/") + 1 :])
        var j = Json.parse(open(dir + "/model.json", "r").read())
        if j.text(j.get(0, "kind")) != "image-labels":
            raise Error(dir + "/model.json: kind isn't image-labels")
        self.function = j.text(j.get(0, "function"), name)
        self.size = j.number(j.get(j.get(0, "input"), "size"), 224)
        self.labels = List[String]()
        for line in open(dir + "/" + j.text(j.get(0, "labels"), "labels.txt"), "r").read().split("\n"):
            var l = String(line.strip())
            if l != "":
                self.labels.append(l)
        self.model = shared_model(dir + "/" + name + ".mef", dir + "/" + name + ".safetensors", gpu=True)

    def logits_rgba(mut self, frame: List[UInt32], w: Int, h: Int) raises -> List[Float32]:
        var ins = List[TensorIn]()
        ins.append(TensorIn.f32(centre_square(frame, w, h, self.size), [1, self.size, self.size, 3]))
        var out = at[MaxModel](self.model)[].run(ins, 1)[0].floats()
        if len(out) != len(self.labels):
            raise Error("the pack gave " + String(len(out)) + " outputs for " + String(len(self.labels)) + " labels")
        return out^

    def top_rgba(mut self, frame: List[UInt32], w: Int, h: Int) raises -> Guess:
        return top(self.logits_rgba(frame, w, h))


def top(logits: List[Float32]) -> Guess:
    """The best label and its softmax share."""
    var best = 0
    for i in range(len(logits)):
        if logits[i] > logits[best]:
            best = i
    var sum = 0.0
    for v in logits:
        sum += exp(Float64(v) - Float64(logits[best]))
    return Guess(best, 1.0 / sum)


def centre_square(frame: List[UInt32], w: Int, h: Int, size: Int) -> List[Float32]:
    """The frame's centre square at size × size, RGB floats 0–255, NHWC (from_torch.py's centre_square, in Mojo)."""
    var s = min(w, h)
    var x0 = (w - s) // 2
    var y0 = (h - s) // 2
    var i0 = List[Int](capacity=size)
    var i1 = List[Int](capacity=size)
    var f = List[Float64](capacity=size)
    for k in range(size):
        var c = (Float64(k) + 0.5) * Float64(s) / Float64(size) - 0.5
        c = min(max(c, 0.0), Float64(s - 1))
        var a = Int(floor(c))
        i0.append(a)
        i1.append(min(a + 1, s - 1))
        f.append(c - Float64(a))
    var out = List[Float32](length=size * size * 3, fill=0)
    for y in range(size):
        var ra = (y0 + i0[y]) * w + x0
        var rb = (y0 + i1[y]) * w + x0
        var fy = f[y]
        for x in range(size):
            var fx = f[x]
            var o = (y * size + x) * 3
            for ch in range(3):
                var sh = UInt32(ch * 8)
                var p00 = Float64((frame[ra + i0[x]] >> sh) & 0xFF)
                var p01 = Float64((frame[ra + i1[x]] >> sh) & 0xFF)
                var p10 = Float64((frame[rb + i0[x]] >> sh) & 0xFF)
                var p11 = Float64((frame[rb + i1[x]] >> sh) & 0xFF)
                # (down each column first, then across: the numpy reference's order, so the two round alike)
                var left = p00 * (1 - fy) + p10 * fy
                var right = p01 * (1 - fy) + p11 * fy
                out[o + ch] = Float32(left * (1 - fx) + right * fx)
    return out^
