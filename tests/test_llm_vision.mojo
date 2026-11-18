# mojoui.llm's image input and mojoui.grounding with the real Qwen3.8-27B and its vision projector on one GPU (goal 77 M6).
#   pixi run python scripts/g77_scene.py                           (once: build/g77/scene.png, truth.json, otter.png)
#   scripts/build_llm_shim.sh
#   scripts/mxbuild.sh tests/test_llm_vision.mojo -o build/test_llm_vision && build/test_llm_vision
# Environment: LLM_GGUF, LLM_MMPROJ (defaults under ~/Projects/omx-local/models), LLM_GPU (default 1). Numbers go to
# build/g77/vision-bench.json; each case prints one `vision <case>: ok …` line.
from std.os import getenv
from std.testing import assert_equal, assert_true
from mojoui.clock import now_ns
from mojoui.json import Json, json_string
from mojoui.llm import Llm, DONE, ERROR
from mojoui.grounding import ground, image_size, iou, Box, parse_sight, look_messages
from mojoui.uijobs import wake_pipe


def ms_since(t0: Int) -> Float64:
    return Float64(now_ns() - t0) / 1e6


def read_all(path: String) raises -> List[UInt8]:
    var f = open(path, "r")
    var b = f.read_bytes()
    f.close()
    return b^


def main() raises:
    var home = getenv("HOME", "")
    var models = home + "/Projects/omx-local/models"
    var gguf = getenv("LLM_GGUF", models + "/Qwen3.8-27B-UD-Q4_K_M.gguf")
    var mmproj = getenv("LLM_MMPROJ", models + "/mmproj-F16.gguf")
    var gpu = Int(getenv("LLM_GPU", "1"))
    var wake_fd = wake_pipe()
    var t_load = now_ns()
    var llm = Llm(gguf, gpu=gpu, n_ctx=32768, n_seq=2, mmproj=mmproj)
    print("vision loaded in", ms_since(t_load), "ms (model + projector) on GPU", gpu)

    # 1. reading words in a picture: the PNG says PURPLE OTTER 42
    var otter = read_all("build/g77/otter.png")
    assert_equal(image_size(otter)[0], 1280)
    assert_equal(image_size(otter)[1], 720)
    var t0 = now_ns()
    var read = llm.complete("[" + llm.image_user(otter, "Read the words in the picture exactly, in capital letters, nothing else.") + "]", seq=1, max_tokens=40, temperature=0.0)
    var read_ms = ms_since(t0)
    assert_true(read.text.upper().find("PURPLE") >= 0 and read.text.upper().find("OTTER") >= 0 and read.text.find("42") >= 0, "the words: " + read.text)
    print("vision text: ok, read", json_string(read.text), "in", read_ms, "ms; image encode", llm.image_ms(), "ms,", llm.image_tokens(), "image tokens")

    # 2. grounding: every object of the scene, asked for by name, lands on its truth (IoU >= 0.4)
    var scene = read_all("build/g77/scene.png")
    var size = image_size(scene)
    assert_equal(size[0], 1280)
    assert_equal(size[1], 720)
    var truth = Json.parse(String(from_utf8_lossy=Span(read_all("build/g77/truth.json"))))
    var objs = truth.get(0, "objects")
    var worst = 1.0
    var total_ms = 0.0
    var encode_ms = 0.0
    for k in range(truth.size(objs)):
        var o = truth.at(objs, k)
        var name = truth.text(truth.get(o, "name"))
        var bx = truth.get(o, "box")
        var want = Box(name, truth.real(truth.at(bx, 0)), truth.real(truth.at(bx, 1)), truth.real(truth.at(bx, 2)), truth.real(truth.at(bx, 3)))
        var t1 = now_ns()
        var sight = ground(llm, scene, "where is the " + name + "?")
        total_ms += ms_since(t1)
        encode_ms += llm.image_ms()
        assert_equal(sight.problem, "")
        var at = sight.find(name)
        if at < 0 and name == "mug":
            at = sight.find("cup")  # (the model says cup for a mug: what a person would too)
        assert_true(at >= 0, name + " is not among the model's labels: " + sight.labels() + " | " + sight.raw)
        var score = iou(sight.boxes[at], want)
        worst = min(worst, score)
        assert_true(score >= 0.4, name + ": IoU " + String(score) + " with the truth; the model's box " + String(sight.boxes[at].x0) + "," + String(sight.boxes[at].y0) + ".." + String(sight.boxes[at].x1) + "," + String(sight.boxes[at].y1))
        assert_true(sight.answer.byte_length() > 0, "an answer is there")
        print("vision ground:", name, "ok IoU", score, "| answer:", sight.answer)
    print("vision grounding: ok, worst IoU", worst, ", mean answer time", total_ms / Float64(truth.size(objs)), "ms, mean image encode", encode_ms / Float64(truth.size(objs)), "ms")

    # 3. the cache rule: a vision request leaves no cache behind and doesn't disturb the conversation on sequence 0
    var c1 = llm.complete('[{"role":"user","content":"What is the capital of France? One word."}]', seq=0, max_tokens=20)
    assert_true(c1.text.find("Paris") >= 0, "Paris: " + c1.text)
    var v = llm.complete("[" + llm.image_user(otter, "How many words are in the picture? A digit only.") + "]", seq=1, max_tokens=10, temperature=0.0)
    assert_true(v.done.n_cached == 0, "a vision request reads all of its prompt: " + String(v.done.n_cached))
    var c2 = llm.complete('[{"role":"user","content":"What is the capital of France? One word."},{"role":"assistant","content":"Paris"},{"role":"user","content":"And of Spain? One word."}]', seq=0, max_tokens=20)
    assert_true(c2.text.find("Madrid") >= 0, "Madrid: " + c2.text)
    assert_true(c2.done.n_cached > 10, "the conversation's cache survived the vision request: " + String(c2.done.n_cached) + " cached")
    print("vision cache: ok, conversation reused", c2.done.n_cached, "of", c2.done.n_prompt, "prompt tokens after a vision request on the other sequence")

    # 4. errors say why: an image the engine doesn't hold, bytes that aren't a picture
    var failed = False
    try:
        _ = llm.chat('[{"role":"user","content":[{"type":"image_url","image_url":{"url":"mem:99999"}},{"type":"text","text":"hi"}]}]', seq=1)
    except e:
        failed = String(e).find("not there") >= 0
    assert_true(failed, "an unknown image is refused with its reason")
    var junk = List[UInt8]()
    for i in range(200):
        junk.append(UInt8(i % 251))
    var bad = llm.chat("[" + llm.image_user(junk, "what is this?") + "]", seq=1)
    var ended = String("")
    var dead = False
    while not dead:
        for e in llm.poll(bad):
            if e.kind == ERROR:
                ended = e.text
                dead = True
            elif e.kind == DONE:
                dead = True
    assert_true(ended.find("could not be decoded") >= 0, "bytes that aren't a picture: " + ended)
    var after = llm.complete('[{"role":"user","content":"Say ok."}]', seq=1, max_tokens=10)
    assert_true(after.text.byte_length() > 0, "the engine goes on after a bad image")
    print("vision errors: ok,", ended)
    _ = wake_fd
    print("vision: all ok")
