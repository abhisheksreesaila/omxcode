# Goal 80: hashes of the CPU executor's pictures of goal 75's scenes, for comparing two commits (the executor is every GPU
# test's reference: it must not drift).  pixi run mojo run -O3 -I . bench/nanoui/refdump.mojo
from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.scene import Scene
from mojoui.gpu2d import GlyphAtlas, build_batches, execute_cpu
from mojoui.mindmap import MapView
from tests.test_gpu2d import paint_case, gradient, whiteboard, mindmap_of, text_scene
from tests.test_objectlayer import seeded_note


def dump(name: String, sc: Scene, atlas: GlyphAtlas, font: Font) raises:
    var f = build_batches(sc, atlas, font)
    var px = List[UInt32](length=f.width * f.height, fill=0)
    var s = Surface(Int(px.unsafe_ptr()), f.width, f.height, f.scale)
    execute_cpu(f, atlas, s)
    var h = UInt64(14695981039346656037)
    for v in px:
        h = (h ^ UInt64(v)) * 1099511628211
    print("REF", name, h)


def main() raises:
    var font = Font()
    var atlas = GlyphAtlas(font)
    var img = gradient(40, 30)
    for w in range(14):
        if w == 12:
            continue
        var sc = Scene(200, 120, 1.0)
        paint_case(sc, w, font, img)
        dump("case" + String(w), sc, atlas, font)
    var wb = Scene(1000, 700, 1.0)
    whiteboard(wb)
    dump("whiteboard", wb, atlas, font)
    var ol = seeded_note()
    for k in [1.0, 0.45]:
        var c = Scene(1280, 800, 1.0)
        c.fill(0xFFFFFFFF)
        ol.paint(c, font, 20, 30, 1280.0 / k, 800.0 / k, k)
        dump("canvas" + String(k), c, atlas, font)
    var m = mindmap_of(100)
    var ms = Scene(1400, 900, 1.0)
    ms.fill(0xFFFFFFFF)
    m.paint(ms, font, MapView(700, 450, 0.8))
    dump("mindmap", ms, atlas, font)
    for z in [1.0, 4.0]:
        var big = 1 if z == 1.0 else 2
        dump("text" + String(z), text_scene(480 * big, 240 * big, 1.6, z), atlas, font)
