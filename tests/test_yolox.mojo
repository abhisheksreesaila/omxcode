# mojoui.detect (goal 51 M3): YOLOX-Tiny's pack run from Mojo (letterbox, network on the GPU, decode, NMS) on the test
# pictures; writes its boxes as JSON for docs/goals/51-check.py to compare with Megvii's own (reference.json).
#   YOLOX_PACK=build/packs/yolox YOLOX_OUT=build/g51/yolox.json build/test_yolox
# Prints a line per picture, "ms/frame …" and "yolox: ok".
from std.testing import assert_true, assert_equal
from std.os import getenv, listdir
from std.time import perf_counter_ns
from mojoui.detect import Detector, Box, coco_name


def main() raises:
    var pack = getenv("YOLOX_PACK", "build/packs/yolox")
    var out_path = getenv("YOLOX_OUT", "build/g51/yolox.json")
    var d = Detector(pack)
    var names = List[String]()
    for f in listdir(pack):
        var n = String(f)
        if n.endswith(".size"):
            names.append(String(n[byte = 0 : n.byte_length() - 5]))
    assert_true(len(names) >= 5, "the test pictures")
    var json = String("{")
    var found = Dict[String, List[Box]]()
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
        # the video path (one UInt32 a pixel, RGBA in memory: what mojoui.video gives) finds the same boxes
        var rgba = List[UInt32](length=w * h, fill=0)
        for i in range(w * h):
            rgba[i] = UInt32(px[i * 3]) | (UInt32(px[i * 3 + 1]) << 8) | (UInt32(px[i * 3 + 2]) << 16) | (UInt32(255) << 24)
        var vboxes = d.detect_rgba(rgba, w, h)
        assert_equal(len(vboxes), len(boxes))
        for i in range(len(boxes)):
            assert_equal(vboxes[i].cls, boxes[i].cls)
            assert_true(abs(vboxes[i].x - boxes[i].x) < 0.01 and abs(vboxes[i].score - boxes[i].score) < 1e-6, "rgba = rgb")
        found[names[k]] = boxes.copy()
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
    # what Megvii's own code finds on these pictures (reference.json): the person, the cat in colour and in grey, the cup
    def top(boxes: List[Box]) -> String:
        return coco_name(boxes[0].cls) if len(boxes) > 0 else String("")
    assert_equal(top(found["astronaut"]), "person")
    assert_equal(top(found["cat"]), "cat")
    assert_equal(top(found["cat_gray"]), "cat")
    assert_equal(top(found["coffee"]), "cup")
    assert_equal(len(found["rocket"]), 0)
    # the pack is loaded once: a second detector is the same model
    var again = Detector(pack)
    assert_equal(again.model, d.model)
    print("yolox: ok")
