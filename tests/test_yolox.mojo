# mojoui.detect (goal 51 M3): YOLOX-Tiny's pack run from Mojo (letterbox, network on the GPU, decode, NMS) on the test
# pictures; writes its boxes as JSON for docs/goals/51-check.py to compare with Megvii's own (reference.json).
#   YOLOX_PACK=build/packs/yolox YOLOX_OUT=build/g51/yolox.json build/test_yolox
# Prints a line per picture, "ms/frame …" and "yolox: ok".
from std.testing import assert_true
from std.os import getenv, listdir
from std.time import perf_counter_ns
from mojoui.maxrt import MaxRuntime
from mojoui.detect import Detector, Box, coco_name


def main() raises:
    var pack = getenv("YOLOX_PACK", "build/packs/yolox")
    var out_path = getenv("YOLOX_OUT", "build/g51/yolox.json")
    var rt = MaxRuntime()
    var d = Detector(rt, pack)
    var names = List[String]()
    for f in listdir(pack):
        var n = String(f)
        if n.endswith(".size"):
            names.append(String(n[byte = 0 : n.byte_length() - 5]))
    assert_true(len(names) >= 5, "the test pictures")
    var json = String("{")
    var total = 0.0
    var runs = 0
    for k in range(len(names)):
        var size = open(pack + "/" + names[k] + ".size", "r").read().split(" ")
        var w = Int(String(size[0]))
        var h = Int(String(size[1]))
        var raw = open(pack + "/" + names[k] + ".rgb", "r").read_bytes()
        var px = List[UInt8](length=len(raw), fill=0)
        for i in range(len(raw)):
            px[i] = raw[i]
        var boxes = d.detect_rgb(px, w, h)  # (warm: the first GPU call is slow)
        for _ in range(5):
            var t0 = perf_counter_ns()
            boxes = d.detect_rgb(px, w, h)
            total += Float64(perf_counter_ns() - t0) / 1e6
            runs += 1
        json += ("," if k > 0 else "") + "\"" + names[k] + "\": ["
        var line = names[k] + ":"
        for i in range(len(boxes)):
            ref b = boxes[i]
            json += ("," if i > 0 else "") + "{\"cls\": \"" + coco_name(b.cls) + "\", \"score\": " + String(b.score) + ", \"box\": [" + String(b.x) + ", " + String(b.y) + ", " + String(b.w) + ", " + String(b.h) + "]}"
            line += " " + coco_name(b.cls) + " " + String(Int(b.score * 100)) + "%"
        json += "]"
        print(line)
    json += "}"
    with open(out_path, "w") as f:
        f.write(json)
    print("ms/frame", total / Float64(runs), "(letterbox + network + decode + NMS, mean of", runs, "runs)")
    print("yolox: ok")
