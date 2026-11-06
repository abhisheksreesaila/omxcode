# mojoui.imagemodel and the packs that describe themselves (goal 59 M2), read by docs/goals/59-check.py.
#   OMX_PACKS=build/packs SCENE_VIDEO=<an .mp4> pixi run mojo run -I . -I vendor tests/test_imagemodel.mojo
# Prints "PACKS: <function kind>…", "FRAME_MODELS: …", "PICTURE <file>: <label index> <its logit> <score>" for each test
# picture (mojoui.video decodes it, mojoui.imagemodel crops and runs it), "HAS scene: True|False", then, with a pack
# for scene, "SCENE: <rows> rows <columns>" and its first rows from a script over SCENE_VIDEO 3–4 s, and "IMAGEMODEL: done".
from std.os import getenv, listdir
from std.time import perf_counter_ns
from omxcore import Catalog
from mojoui.models import ModelFunctions, pack_functions, frame_models, packs_dir
from mojoui.imagemodel import ImageModel, top, centre_square
from mojoui.video import VideoSource
from mojoui.videoscript import VideoFunctions
from mojoui.script import run_script
from mojoui.sheet import Sheet


def main() raises:
    var line = String("PACKS:")
    var scene = String("")
    for p in pack_functions():
        line += " " + p.function + " " + p.kind
        if p.function == "scene":
            scene = p.dir
    print(line)
    print("FRAME_MODELS: " + " ".join(frame_models()))
    # parity with from_torch.py's centre_square: one fixed 37 × 23 RGBA picture, resized to 16 × 16 (the check compares)
    var syn = List[UInt32](length=37 * 23, fill=0)
    for y in range(23):
        for x in range(37):
            var r = UInt32((x * 7 + y * 13) % 256)
            var g = UInt32((x * 29 + y * 3) % 256)
            var b = UInt32((x * x + y) % 256)
            syn[y * 37 + x] = r | (g << 8) | (b << 16) | (UInt32(255) << 24)
    var par = String("PARITY:")
    for v in centre_square(syn, 37, 23, 16):
        par += " " + String(v)
    print(par)
    if scene != "":
        var m = ImageModel(scene)
        var names = List[String]()
        for n in listdir("tests/fixtures/vision"):
            if String(n).endswith(".jpg"):
                names.append(String(n))
        sort(names)
        for n in names:
            var v = VideoSource("tests/fixtures/vision/" + n)
            var px = v.next()
            var logits = m.logits_rgba(px, v.width, v.height)
            var g = top(logits)
            var warm = perf_counter_ns()
            _ = m.logits_rgba(px, v.width, v.height)
            print("PICTURE " + n + ": " + String(g.label) + " " + String(logits[g.label]) + " " + String(g.score)
                  + " " + m.labels[g.label] + " (" + String(Float64(perf_counter_ns() - warm) / 1e6) + " ms)")
    var videos = VideoFunctions()
    var path = getenv("SCENE_VIDEO", "")
    if path != "":
        var v = VideoSource(path)
        videos.add("clip", path, v.fps, v.frames)
    var fns = ModelFunctions(videos^)
    print("HAS scene: " + String(fns.has("scene")))
    if fns.has("scene") and path != "":
        var catalog = Catalog()
        var t0 = perf_counter_ns()
        var run = run_script("labels = scene(clip, 3, 4);\nper_label = SELECT label, COUNT(*) AS frames FROM labels GROUP BY label;", catalog, fns)
        if run.problem != "":
            print("SCENE problem: " + run.problem)
        else:
            var s = Sheet(run.tables[0], False)
            var cols = String("")
            for c in range(s.columns()):
                cols += " " + s.name(c)
            print("SCENE: " + String(s.rows()) + " rows" + cols + " in " + String(Float64(perf_counter_ns() - t0) / 1e6) + " ms")
            for r in range(min(3, s.rows())):
                var row = String("ROW")
                for c in range(s.columns()):
                    row += " " + s.plain_text(c, r)
                print(row)
            var per = Sheet(run.tables[1], False)
            for r in range(per.rows()):
                print("PER_LABEL " + per.plain_text(0, r) + " " + per.plain_text(1, r))
    print("IMAGEMODEL: done")
