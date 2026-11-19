# The Metal backend of the GPU 2D renderer (goal 75 M3), on a Mac with Metal: every primitive and three scenes like the
# judged ones are drawn by Metal into an IOSurface, read back and compared with gpu2d's CPU executor (M1's bounds: mean
# ≤ 1.5 levels, ≤ 0.5 % of pixels more than 40 levels off). Prints `gpu2d metal: ok`; on a Mac without Metal it says
# why and fails. A Mac only (the Objective-C runtime and Metal are linked):
#   pixi run mojo build -I . tests/test_gpu2d_metal.mojo -o build/test_gpu2d_metal \
#       -Xlinker -lobjc -Xlinker -framework -Xlinker Metal -Xlinker -framework -Xlinker Foundation -Xlinker -framework -Xlinker IOSurface
#   build/test_gpu2d_metal          (from the repo's root: it reads build/g74/bench-note.json when it's there)
from std.testing import assert_true
from std.time import perf_counter_ns

from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.scene import Scene
from mojoui.gpu2d import GlyphAtlas, Frame2D, build_batches, fill_batches, execute_cpu
from mojoui.gpu2d_metal import Metal2D, read_iosurface
from mojoui.hosts.apple_canvas import io_surface, cfunc
from mojoui.objectlayer import import_fabric
from mojoui.mindmap import MapView
from tests.test_gpu2d import paint_case, case_name, gradient, whiteboard, mindmap_of, diff, counts
from tests.test_objectlayer import seeded_note


def gpu_vs_cpu(name: String, mut mtl: Metal2D, sc: Scene, atlas: GlyphAtlas, font: Font) raises:
    var w = sc.w
    var h = sc.h
    var frame = build_batches(sc, atlas, font)
    var want = List[UInt32](length=w * h, fill=0)
    var s = Surface(Int(want.unsafe_ptr()), w, h, sc.k)
    execute_cpu(frame, atlas, s)
    var io = io_surface(w, h)
    assert_true(io != 0, name + ": no IOSurface")
    assert_true(mtl.render(frame, io, w, h), name + ": Metal didn't draw it")
    var best = 1e30  # (the frame's GPU cost: a few more renders, the best)
    for _ in range(5):
        var t0 = perf_counter_ns()
        _ = mtl.render(frame, io, w, h)
        best = min(best, Float64(perf_counter_ns() - t0) / 1e6)
    var got = read_iosurface(io, w, h)
    mtl.forget(io)
    cfunc[NoneType]("CFRelease", io)
    var d = diff(want, got)
    var same = 0
    var inked = 0
    for i in range(len(want)):
        if want[i] == got[i]:
            same += 1
        if want[i] != want[0]:
            inked += 1
    print("  ", name, ": mean", round(d.mean, 4), "levels,", round(d.far, 4), "% far;", len(want) - same, "of", len(want),
          "pixels differ at all;", inked, "inked; render", round(best, 3), "ms (GPU", round(mtl.gpu_ms, 3), "ms)")
    assert_true(inked > 200, name + ": the reference picture is (nearly) empty")
    assert_true(d.mean <= 1.5 and d.far <= 0.5, name + ": Metal differs from the CPU executor")


def main() raises:
    var font = Font()
    var atlas = GlyphAtlas(font)
    var mtl = Metal2D(atlas)
    if not mtl.ok:
        print("gpu2d metal: no Metal (" + mtl.why + ")")
        assert_true(False, "no Metal: " + mtl.why)
    print("Metal device:", mtl.name)
    var img = gradient(40, 30)
    for which in range(14):
        if which == 12:
            continue
        var sc = Scene(200, 120, 1.0)
        paint_case(sc, which, font, img)
        gpu_vs_cpu(case_name(which), mtl, sc, atlas, font)

    var wb = Scene(1000, 700, 1.0)
    whiteboard(wb)
    gpu_vs_cpu("whiteboard", mtl, wb, atlas, font)
    print("     ", counts(wb, atlas, font))

    var text = String()
    var have = True
    try:
        var fh = open("build/g74/bench-note.json", "r")
        text = fh.read()
        fh.close()
    except:
        have = False
    var ol = import_fabric(text, font) if have else seeded_note()
    for zoom in range(2):
        var k = 1.0 if zoom == 0 else 0.45
        var c = Scene(1280, 800, 1.0)
        c.fill(0xFFFFFFFF)
        ol.paint(c, font, 20, 30, 1280.0 / k, 800.0 / k, k)
        gpu_vs_cpu("canvas (" + ("bench note" if have else "seeded note") + ", k " + String(k) + ")", mtl, c, atlas, font)
        print("     ", counts(c, atlas, font))

    var m = mindmap_of(100)
    var ms = Scene(1400, 900, 1.0)
    ms.is_still = True
    ms.fill(0xFFFFFFFF)
    m.paint(ms, font, MapView(700, 450, 0.8))
    gpu_vs_cpu("mindmap (" + String(m.nodes()) + " topics)", mtl, ms, atlas, font)
    print("     ", counts(ms, atlas, font))
    print("gpu2d metal: ok")
