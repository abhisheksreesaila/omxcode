# mojoui.wordpiece + mojoui.textembed (goal 51 M1): BERT's tokenizer gives Hugging Face's ids, and the MiniLM pack run
# from Mojo gives the vectors the same pack gives in Python (scripts/packs/minilm.py writes both references).
#   MINILM_PACK=build/packs/minilm build/test_textembed   (after scripts/mxbuild.sh tests/test_textembed.mojo -o build/test_textembed)
# Prints "wordpiece: ok", "embed: ok", and a "rows/s" line.
from std.testing import assert_equal, assert_true
from std.os import getenv
from std.time import perf_counter_ns
from mojoui.wordpiece import Vocab
from mojoui.textembed import Embedder


def main() raises:
    var pack = getenv("MINILM_PACK", "build/packs/minilm")
    var texts = List[String]()
    for l in open(pack + "/texts.txt", "r").read().split("\n"):
        if String(l) != "":
            texts.append(String(l))
    var want = List[List[Int]]()
    for l in open(pack + "/ref_ids.txt", "r").read().split("\n"):
        if String(l) != "":
            var row = List[Int]()
            for w in String(l).split(" "):
                row.append(Int(String(w)))
            want.append(row^)
    assert_equal(len(texts), len(want))
    var vocab = Vocab(pack + "/vocab.txt")
    var differ = 0
    for i in range(len(texts)):
        var got = vocab.ids(texts[i])
        var same = len(got) == len(want[i])
        if same:
            for k in range(len(got)):
                if got[k] != want[i][k]:
                    same = False
        if not same:
            differ += 1
            if differ <= 3:
                print("differs:", texts[i])
    assert_equal(differ, 0)
    # UTF-8 anywhere: accents, an emoji, CJK: pieces or [UNK], never a cut character
    for t in ["café crème brûlée", "pick the 🍎 up", "把杯子放在桌子上", "naïve ünïcödé", "ok"]:
        var got = vocab.ids(t)
        assert_true(len(got) >= 3 and got[0] == 101 and got[len(got) - 1] == 102, "ids for " + t)
    print("wordpiece: ok", len(texts), "texts, ids = Hugging Face's; UTF-8 safe")

    var e = Embedder(pack)
    var v = e.embed(texts)
    var raw = open(pack + "/ref_vectors.f32", "r").read_bytes()
    var ref_v = raw.unsafe_ptr().bitcast[Float32]()
    assert_equal(len(v), len(texts) * e.dim)
    var worst = 1.0
    for i in range(len(texts)):
        var c = 0.0
        for d in range(e.dim):
            c += Float64(v[i * e.dim + d]) * Float64(ref_v[i * e.dim + d])
        worst = min(worst, c)
    assert_true(worst >= 0.999, "worst cosine " + String(worst))
    var again = Embedder(pack)
    assert_equal(again.model, e.model)  # (the pack is loaded once per process)
    print("embed: ok worst cosine with the Python pack", worst)

    var many = List[String]()
    for k in range(100):
        for t in texts:
            many.append(t + " " + String(k))  # (20,000 distinct texts)
    _ = e.embed(texts)  # (warm)
    var t0 = perf_counter_ns()
    var big = e.embed(many, 1024)
    var secs = Float64(perf_counter_ns() - t0) / 1e9
    print("rows/s", Int(Float64(len(many)) / secs), "(", len(many), "texts in", secs, "s, tokenizing included;", len(big) // e.dim, "vectors )")
