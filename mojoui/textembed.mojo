# mojoui.textembed: text to vectors in the app's own process (goal 51 M1): a sentence-embedding pack (MiniLM-L6:
# scripts/packs/minilm.py) run through mojoui.maxrt, tokenized by mojoui.wordpiece. Vectors are L2-normalised, so a
# dot product is the cosine: what classify() (mojoui.models) compares.
#
#   var rt = MaxRuntime()
#   var e = Embedder(rt, "build/packs/minilm")   # (a pack folder: <its name>.mef, .safetensors, vocab.txt, prefix.txt)
#   var v = e.embed(texts)                 # len(texts) × e.dim floats, row by row
#
# Each text starts with the pack's prefix.txt when it has one (e5's "query: ", as its model card asks).
# Batches are padded to their longest text (the mask hides the padding); texts are sorted by length first so a batch
# pads little, and the vectors come back in the order asked.

from std.math import sqrt
from mojoui.maxrt import MaxRuntime, MaxModel, TensorIn
from mojoui.wordpiece import Vocab
from mojoui.video import file_exists


struct Embedder(Movable):
    var vocab: Vocab
    var model: MaxModel
    var dim: Int
    var most: Int  # tokens per text at most
    var prefix: String

    def __init__(out self, mut rt: MaxRuntime, pack: String, dim: Int = 384, most: Int = 128) raises:
        var dir = String(pack.rstrip("/"))
        var name = String(dir[byte = dir.rfind("/") + 1 :])
        self.vocab = Vocab(dir + "/vocab.txt")
        self.model = rt.load(dir + "/" + name + ".mef", dir + "/" + name + ".safetensors", gpu=True)
        self.dim = dim
        self.most = most
        self.prefix = open(dir + "/prefix.txt", "r").read() if file_exists(dir + "/prefix.txt") else String("")

    def embed_ids(mut self, ids: List[List[Int]]) raises -> List[Float32]:
        """Vectors for texts already tokenized (one batch: padded to the longest)."""
        var rows = len(ids)
        var cols = 1
        for x in ids:
            cols = max(cols, len(x))
        var a = List[Int64](length=rows * cols, fill=0)
        var m = List[Float32](length=rows * cols, fill=0)
        for r in range(rows):
            for c in range(len(ids[r])):
                a[r * cols + c] = Int64(ids[r][c])
                m[r * cols + c] = 1.0
        var ins = List[TensorIn]()
        ins.append(TensorIn.i64(a, [rows, cols]))
        ins.append(TensorIn.f32(m, [rows, cols]))
        var v = self.model.run(ins, 1)[0].floats()
        for r in range(rows):
            var s = 0.0
            for k in range(self.dim):
                s += Float64(v[r * self.dim + k]) * Float64(v[r * self.dim + k])
            var inv = Float32(1.0 / sqrt(s)) if s > 0 else Float32(0)
            for k in range(self.dim):
                v[r * self.dim + k] *= inv
        return v^

    def embed(mut self, texts: List[String], batch: Int = 512) raises -> List[Float32]:
        """len(texts) × dim floats, in the texts' order."""
        var n = len(texts)
        var ids = List[List[Int]]()
        for t in texts:
            ids.append(self.vocab.ids(self.prefix + t, self.most))
        # by length, so each batch pads little
        var order = List[Int]()
        for i in range(n):
            order.append(i)
        _sort_by_len(order, ids)
        var out = List[Float32](length=n * self.dim, fill=0)
        var at = 0
        while at < n:
            var end = min(n, at + batch)
            var chunk = List[List[Int]]()
            for k in range(at, end):
                chunk.append(ids[order[k]].copy())
            var v = self.embed_ids(chunk)
            for k in range(at, end):
                var row = order[k]
                for d in range(self.dim):
                    out[row * self.dim + d] = v[(k - at) * self.dim + d]
            at = end
        return out^


def _sort_by_len(mut order: List[Int], ids: List[List[Int]]):
    """`order` sorted by its texts' token counts (a counting sort: counts are ≤ the cut, small)."""
    var most = 0
    for x in ids:
        most = max(most, len(x))
    var buckets = List[List[Int]]()
    for _ in range(most + 1):
        buckets.append(List[Int]())
    for i in order:
        buckets[len(ids[i])].append(i)
    var k = 0
    for b in buckets:
        for i in b:
            order[k] = i
            k += 1
