# The Metal backend of the GPU 2D renderer (goal 75 M3), on a Mac with Metal: every primitive and three scenes like the
# judged ones are drawn by Metal into an IOSurface, read back and compared with gpu2d's CPU executor (M1's bounds: mean
# ≤ 1.5 levels, ≤ 0.5 % of pixels more than 40 levels off); a 300-topic map panned through the layer cache rebuilds
# nothing after its first frame (goal 75 review, D-7578); ink drawn with frames still on the GPU (a growing page and a
# wet stroke, two frames in flight) uploads without waiting and every frame matches (D-7583). Prints `gpu2d metal: ok`; on a Mac without Metal it says
# why and fails. A Mac only (the Objective-C runtime and Metal are linked):
#   pixi run mojo build -I . tests/test_gpu2d_metal.mojo -o build/test_gpu2d_metal \
#       -Xlinker -lobjc -Xlinker -framework -Xlinker Metal -Xlinker -framework -Xlinker Foundation -Xlinker -framework -Xlinker IOSurface
#   build/test_gpu2d_metal          (from the repo's root: it reads build/g74/bench-note.json when it's there)
from std.testing import assert_true
from std.time import perf_counter_ns
from std.math import sin

from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.scene import Scene
from mojoui.gpu2d import GlyphAtlas, Frame2D, build_batches, fill_batches, execute_cpu, glyph_pages, DYN_ROWS
from mojoui.fonttext import TextStyle, GlyphImage
from mojoui.canvas import rgba
from mojoui.gpu2d_metal import Metal2D, MetalCanvas2D, read_iosurface
from mojoui.hosts.apple_canvas import io_surface, cfunc
from mojoui.objectlayer import import_fabric
from mojoui.mindmap import MapView
from mojoui.ink import Stroke
from tests.test_gpu2d import text_scene, paint_case, case_name, gradient, whiteboard, mindmap_of, diff, counts
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

    # goal 79: fonttext runs (CoreText-shaped on the Mac) and icons from the device-pixel glyph rows, colour emoji blended
    for zoom in [1.0, 4.0]:
        var big = 1 if zoom == 1.0 else 2
        gpu_vs_cpu("fonttext runs and icons (zoom " + String(zoom) + ")", mtl, text_scene(560 * big, 300 * big, 2.0, zoom), atlas, font)

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
    map_pan(font, atlas)
    glyph_holes(font, atlas)
    ink_in_flight(font, atlas)
    print("gpu2d metal: ok")


def map_pan(font: Font, atlas: GlyphAtlas) raises:
    """A 300-topic map panned at pnote's canvas size on a 1.6× screen, drawn as the host draws (MetalCanvas2D's layer
    cache, D-7538): its text layer is kept through every pan after the first frame (text depends on the zoom only,
    D-7578), and the last frame read back matches the CPU executor's picture of that Scene built whole."""
    var m = mindmap_of(300)
    var g = MetalCanvas2D()
    assert_true(g.metal.ok, "MetalCanvas2D: " + g.metal.why)
    var W = 1699
    var H = 1384
    var k = 1.6
    var io = io_surface(W, H)
    assert_true(io != 0, "map pan: no IOSurface")
    var rebuilt = 0
    var ms = List[Float64]()
    for f in range(30):
        g.scene.reset(W, H, k)
        g.scene.is_still = True
        g.scene.fill(0xFFFFFFFF)
        m.paint(g.scene, font, MapView((Float64(W) / k / 2 + Float64(f) * 7.3) * k, (Float64(H) / k / 2 - Float64(f) * 4.1) * k, k))
        assert_true(g.render_scene(1, io, W, H), "map pan frame drawn")
        if f > 0:
            rebuilt += g.rebuilt
            ms.append(g.build_ms)
        if f < 29:
            g.end_frame()
    var want = List[UInt32](length=W * H, fill=0)
    var s = Surface(Int(want.unsafe_ptr()), W, H, k)
    execute_cpu(build_batches(g.scene, atlas, font), atlas, s)
    var got = read_iosurface(io, W, H)
    g.metal.forget(io)
    cfunc[NoneType]("CFRelease", io)
    var d = diff(want, got)
    sort(ms)
    print("   mindmap pan (300 topics, 1699x1384 at 1.6x): layers rebuilt in 29 pan frames", rebuilt, "; build per frame p50",
          round(ms[len(ms) // 2], 3), "ms, max", round(ms[len(ms) - 1], 3), "ms; last frame mean", round(d.mean, 4), "levels,", round(d.far, 4), "% far")
    assert_true(rebuilt == 0, "a panned mind map rebuilt its layers on Metal")
    assert_true(d.mean <= 1.5 and d.far <= 0.5, "the panned mind map differs from the CPU executor (Metal)")


def words_into(mut sc: Scene, zoom: Float64, big: Bool):
    """test_gpu2d_gl's words_scene into a host's Scene (D-7930)."""
    sc.begin_layer("bg")
    sc.fill(rgba(255, 253, 248))
    sc.begin_layer("words")
    sc.layer_transform(0, 0, zoom)
    sc.run(TextStyle("Geist", 400, False, 14), "Kept words, zoomed: re-rasterized", 10, 24, rgba(31, 27, 22), 0)
    sc.run(TextStyle("Literata", 700, False, 18), "Three days on the coast", 10, 52, rgba(31, 27, 22), 0)
    if big:
        sc.begin_layer("more")
        sc.run(TextStyle("Bricolage Grotesque", 700, False, 64), "QWERTYUIOPASDFGHJKL", 10, 200, rgba(74, 68, 59), 0)
        sc.run(TextStyle("Source Serif 4", 600, True, 64), "zxcvbnmlkjhgfdsapoiu", 10, 300, rgba(74, 68, 59), 0)


def fill_pages_to(width: Int, rows_left: Int, mut key: Int):
    var pg = glyph_pages(width)
    var r0 = pg[].resets
    var blank = GlyphImage()
    blank.w = pg[].width - 4
    blank.h = 3
    blank.cov = List[UInt8](length=blank.w * blank.h, fill=0)
    while pg[].resets == r0 and pg[].shelf_y + 3 + 1 < DYN_ROWS - rows_left:
        _ = pg[].place(key, blank)
        key -= 1
    if rows_left == 0:
        while pg[].resets == r0:
            _ = pg[].place(key, blank)
            key -= 1


def metal_vs_cpu(mut g: MetalCanvas2D, io: Int, W: Int, H: Int, atlas: GlyphAtlas, font: Font) raises -> Float64:
    var got = read_iosurface(io, W, H)
    var want = List[UInt32](length=W * H, fill=0)
    var s = Surface(Int(want.unsafe_ptr()), W, H, 1.0)
    execute_cpu(build_batches(g.scene, atlas, font), atlas, s)
    return diff(want, got).mean


def glyph_holes(font: Font, atlas: GlyphAtlas) raises:
    """D-7930 on Metal (MetalCanvas2D's layer cache, sharing gpu2d.layer_traits with GL): a kept text layer zoomed is
    rasterized again; GlyphPages filling between frames and in the middle of one rebuilds the layers that used them."""
    var W = 900
    var H = 400
    var io = io_surface(W, H)
    assert_true(io != 0, "glyph holes: no IOSurface")
    var g = MetalCanvas2D()
    g.scene.reset(W, H, 1.0)
    words_into(g.scene, 1.0, False)
    assert_true(g.render_scene(1, io, W, H), "first frame")
    g.end_frame()
    g.scene.reset(W, H, 1.0)
    words_into(g.scene, 2.0, False)
    assert_true(g.render_scene(1, io, W, H), "zoomed frame")
    var d1 = metal_vs_cpu(g, io, W, H, atlas, font)
    print("   a kept text layer zoomed 1 → 2: rebuilt", g.rebuilt, "; vs the CPU executor mean", round(d1, 4))
    assert_true(g.rebuilt >= 1 and d1 <= 0.1, "a kept fonttext layer was scaled instead of re-rasterized (Metal)")
    g.end_frame()
    var key = -1
    fill_pages_to(atlas.width, 0, key)
    g.scene.reset(W, H, 1.0)
    words_into(g.scene, 2.0, False)
    assert_true(g.render_scene(1, io, W, H), "frame after a reset")
    var d2 = metal_vs_cpu(g, io, W, H, atlas, font)
    print("   pages reset between frames: rebuilt", g.rebuilt, "; vs the CPU executor mean", round(d2, 4))
    assert_true(g.rebuilt >= 1 and d2 <= 0.1, "a kept layer drew from glyph slots the reset gave away (Metal)")
    fill_pages_to(atlas.width, 0, key)
    fill_pages_to(atlas.width, 40, key)
    var g3 = MetalCanvas2D()
    g3.scene.reset(W, H, 1.0)
    words_into(g3.scene, 1.0, True)
    var r0 = glyph_pages(atlas.width)[].resets
    assert_true(g3.render_scene(3, io, W, H), "frame across a reset")
    var mid = glyph_pages(atlas.width)[].resets - r0
    var got = read_iosurface(io, W, H)
    var want = List[UInt32](length=W * H, fill=0)
    var s = Surface(Int(want.unsafe_ptr()), W, H, 1.0)
    execute_cpu(build_batches(g3.scene, atlas, font), atlas, s)
    var d3 = diff(want, got).mean
    print("   pages reset mid-frame (resets", mid, "): vs the CPU executor mean", round(d3, 4))
    assert_true(mid >= 1 and d3 <= 0.1, "glyphs placed before a mid-frame reset were drawn from reused slots (Metal)")
    g.metal.forget(io)
    cfunc[NoneType]("CFRelease", io)


def ink_stroke(i: Int, wet: Int) -> Stroke:
    """Stroke i of the test page (wet ≥ 0: the wet stroke, its end moving with the frame)."""
    var s = Stroke(2.0 + Float64(i % 5), UInt32(0xFF222222) if i % 3 == 0 else UInt32(0xFF2A60B0))
    var x = 40.0 + Float64((i * 97) % 700)
    var y = 30.0 + Float64((i * 61) % 400)
    var n = 30 + (wet * 3 if wet >= 0 else i % 20)
    for k in range(n):
        s.add(x + Float64(k) * 4.0, y + 25.0 * sin(Float64(k) * 0.2 + Float64(i)), 0.3 + 0.6 * abs(sin(Float64(k) * 0.15)))
    return s^


def check_oldest(mut g: MetalCanvas2D, mut fly_io: List[Int], mut fly_want: List[List[UInt32]], W: Int, H: Int) raises -> Float64:
    """The oldest frame in flight, completed and read back against its CPU picture; its mean difference."""
    assert_true(g.metal.complete_oldest(), "ink in flight: a frame didn't complete")
    var got = read_iosurface(fly_io.pop(0), W, H)
    var want = fly_want.pop(0)
    var d = diff(want, got)
    assert_true(d.mean <= 1.5 and d.far <= 0.5, "ink in flight: a frame differs from the CPU executor (mean " + String(d.mean) + ", far " + String(d.far) + ")")
    return d.mean


def ink_scene(mut sc: Scene, f: Int):
    """Frame f of the pen test: a heavy page that stays (so the GPU is still busy when the next frame uploads), the
    ink layer with 4 + f strokes, the wet stroke as it is at frame f."""
    sc.fill(0xFFFFFFFF)
    sc.begin_layer("page")
    for i in range(1500):
        var s = ink_stroke(1000 + i, -1)
        sc.polygon(s.outline(), s.color)
    sc.begin_layer("ink")
    for i in range(4 + f):
        var s = ink_stroke(i, -1)
        sc.polygon(s.outline(), s.color)
    sc.begin_layer("wet")
    var w = ink_stroke(100, f)
    sc.polygon(w.outline(), w.color)


def ink_in_flight(font: Font, atlas: GlyphAtlas) raises:
    """The pen as the host draws it (D-7555: committed, not waited for, at most two frames in flight, a ring of three
    IOSurfaces): each frame the page's ink layer grows by a stroke (a tail upload) and the wet stroke changes (its
    layer rebuilt). Neither waits for the frame on the GPU that reads the same buffers (D-7583: the tail only appends,
    the rebuilt layer goes into its spare set), and each frame read back matches the CPU executor's picture of it."""
    var g = MetalCanvas2D()
    assert_true(g.metal.ok, "MetalCanvas2D: " + g.metal.why)
    var W = 1800
    var H = 1100
    var F = 16
    var wants = List[List[UInt32]]()  # (every frame's Scene and CPU picture first: the frames then go to the GPU back
    var scenes = List[Scene]()  # to back, the CPU's share of each as short as the host's)
    for f in range(F):
        var sc = Scene(W, H, 1.0)
        ink_scene(sc, f)
        scenes.append(sc.copy())  # (the frames hand theirs over by swap)
        var want = List[UInt32](length=W * H, fill=0)
        var sf = Surface(Int(want.unsafe_ptr()), W, H, 1.0)
        execute_cpu(build_batches(sc, atlas, font), atlas, sf)
        wants.append(want^)
    var ios = List[Int]()
    for _ in range(3):
        ios.append(io_surface(W, H))
        assert_true(ios[len(ios) - 1] != 0, "ink in flight: no IOSurface")
    var fly_io = List[Int]()
    var fly_want = List[List[UInt32]]()
    var grown = 0
    var drained0 = 0
    var worst = 0.0
    var checked = 0
    var busy_rebuilds = 0  # (rebuilds of the wet layer while a frame on the GPU read its buffers: the GPU overlaps frames,
    for f in range(F):  # so how many depends on its timing; frame 1's always is)
        swap(g.scene, scenes[f])  # (O(1): the frame's own CPU work is the renderer's)
        while len(g.metal.pending) >= 2:  # (the host's rule: no more than two in flight)
            worst = max(worst, check_oldest(g, fly_io, fly_want, W, H))
            checked += 1
        if f == 1:  # (from the second frame on: the first builds everything with nothing in flight)
            drained0 = g.metal.drained
        var sp = g.spared
        var bz = g.busy_rebuilds
        assert_true(g.render_scene(1, ios[f % 3], W, H, 0, False), "ink in flight: frame not committed")
        if f >= 1:
            assert_true(g.spared - sp == g.busy_rebuilds - bz, "ink in flight: a layer rebuilt while a frame on the GPU read its buffers didn't use its spare set")
            busy_rebuilds += g.busy_rebuilds - bz
        if f >= 1:
            grown += g.grown
        fly_io.append(ios[f % 3])
        fly_want.append(wants[f].copy())
        g.end_frame()
    while len(g.metal.pending) > 0:
        worst = max(worst, check_oldest(g, fly_io, fly_want, W, H))
        checked += 1
    var drains = g.metal.drained - drained0
    for io in ios:
        g.metal.forget(io)
        cfunc[NoneType]("CFRelease", io)
    print("   ink in flight (" + String(F) + " frames, two in flight, GPU", round(g.metal.gpu_ms, 3), "ms a frame): page grown", grown,
          "; wet layer rebuilt while busy (into its spare)", busy_rebuilds, "; drains", drains, "; frames checked", checked, ", worst mean", round(worst, 4), "levels")
    assert_true(checked == F, "ink in flight: not every frame was read back")
    assert_true(grown >= F - 2, "ink in flight: the page's layer wasn't grown in place")
    assert_true(drains == 0, "ink in flight: an upload waited for the GPU")
    assert_true(busy_rebuilds >= 1, "ink in flight: no rebuild found a frame on the GPU (the case isn't exercised)")
