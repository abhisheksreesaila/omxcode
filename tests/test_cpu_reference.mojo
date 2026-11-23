# Goal 80: the CPU executor is the reference every GPU test is held to, so it must not drift. The hashes of its pictures of
# goal 75's 19 scenes, made by the base commit's own code (3686e45b, bench/nanoui/refdump.mojo run there:
# docs/goals/80/ref-base.txt), against this commit's, with one thread and with the default number. The two fonttext scenes
# use the system's fonts for other scripts, so their hashes are the owner's Linux machine's: on another they are reported,
# not judged (REF_STRICT=1 judges them).
#   pixi run mojo run -O3 -I . tests/test_cpu_reference.mojo
from std.testing import assert_equal, assert_true
from std.os import getenv

from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.scene import Scene
from mojoui.gpu2d import GlyphAtlas, build_batches, execute_cpu
from mojoui.mindmap import MapView
from tests.test_gpu2d import paint_case, gradient, whiteboard, mindmap_of, text_scene
from tests.test_objectlayer import seeded_note


def hash_of(sc: Scene, atlas: GlyphAtlas, font: Font, threads: Int) -> String:
    var f = build_batches(sc, atlas, font)
    var px = List[UInt32](length=f.width * f.height, fill=0)
    var s = Surface(Int(px.unsafe_ptr()), f.width, f.height, f.scale)
    execute_cpu(f, atlas, s, threads)
    var h = UInt64(14695981039346656037)
    for v in px:
        h = (h ^ UInt64(v)) * 1099511628211
    return String(h)


def main() raises:
    var fh = open("docs/goals/80/ref-base.txt", "r")
    var want = Dict[String, String]()
    for line in fh.read().split("\n"):
        var w = String(line).split(" ")
        if len(w) == 3 and w[0] == "REF":
            want[String(w[1])] = String(w[2])
    fh.close()
    assert_equal(len(want), 19, "the base's hashes")
    var font = Font()
    var atlas = GlyphAtlas(font)
    var img = gradient(40, 30)
    var names = List[String]()
    var scenes = List[Scene]()
    for w in range(14):
        if w == 12:
            continue
        var sc = Scene(200, 120, 1.0)
        paint_case(sc, w, font, img)
        names.append("case" + String(w))
        scenes.append(sc^)
    var wb = Scene(1000, 700, 1.0)
    whiteboard(wb)
    names.append("whiteboard")
    scenes.append(wb^)
    var ol = seeded_note()
    for k in [1.0, 0.45]:
        var c = Scene(1280, 800, 1.0)
        c.fill(0xFFFFFFFF)
        ol.paint(c, font, 20, 30, 1280.0 / k, 800.0 / k, k)
        names.append("canvas" + String(k))
        scenes.append(c^)
    var m = mindmap_of(100)
    var ms = Scene(1400, 900, 1.0)
    ms.fill(0xFFFFFFFF)
    m.paint(ms, font, MapView(700, 450, 0.8))
    names.append("mindmap")
    scenes.append(ms^)
    for z in [1.0, 4.0]:
        var big = 1 if z == 1.0 else 2
        names.append("text" + String(z))
        scenes.append(text_scene(480 * big, 240 * big, 1.6, z))
    var strict = getenv("REF_STRICT") == "1"
    var same = 0
    for i in range(len(names)):
        for threads in [1, 0]:
            var got = hash_of(scenes[i], atlas, font, threads)
            if got == want[names[i]]:
                same += 1
            elif strict or not names[i].startswith("text"):
                assert_true(False, names[i] + " (threads " + String(threads) + ") is not the base commit's picture")
            else:
                print("  ", names[i], "differs (system fonts differ from the owner's machine?)")
    print("REFERENCE", same, "of", 2 * len(names), "pictures are the base commit's")
    print("cpu reference: ok")
