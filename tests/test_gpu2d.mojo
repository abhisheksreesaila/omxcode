# The GPU 2D renderer's core (goal 75 M1): a Scene becomes per-layer runs of instanced draws (op counts and paint order
# kept, clips intersected, layer keys / versions / transforms carried), and the CPU executor of those runs draws what
# SurfacePainter draws: each primitive alone and three scenes like the judged ones (whiteboard, canvas, mind map).
#   pixi run mojo run -I . tests/test_gpu2d.mojo
from mojoui.fonttext import TextStyle
from mojoui.strokeicon import draw_icon
from std.testing import assert_equal, assert_true
from std.math import sin, cos
from std.time import perf_counter_ns

from mojoui.canvas import Surface, rgba
from mojoui.text import Font, REGULAR, MEDIUM, MONO, MONO_BOLD, LEFT, CENTRE, RIGHT
from mojoui.scene import Scene, SurfacePainter, Painter
from mojoui.gpu2d import (GlyphAtlas, Frame2D, build_batches, execute_cpu, PIPE_QUAD, PIPE_GLYPH, PIPE_IMAGE, PIPE_POLY,
                          QUAD_FLOATS, GLYPH_FLOATS, POLY_FLOATS, IMAGE_FLOATS, BLEND_OVER, BLEND_REPLACE, NO_CLIP, SHAPE_BOX,
                          SHAPE_CAPSULE)
from mojoui.ink import Stroke
from mojoui.objectlayer import ObjectLayer, import_fabric
from mojoui.mindmap import MindMap, MapView
from tests.test_objectlayer import seeded_note

comptime BG = 0xFFF7F4F1
comptime INK = 0xFF2A1F1A
comptime BLUE = 0xFFD0803A
comptime RED = 0xC03030E0  # translucent


struct Rng(Movable):
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed * 6364136223846793005 + 1442695040888963407

    def real(mut self, lo: Float64, hi: Float64) -> Float64:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return lo + (hi - lo) * Float64(Int((self.s >> 33) & 0xFFFFFF)) / 16777216.0


def near(a: Float64, b: Float64) -> Bool:
    return abs(a - b) < 1e-3


def gradient(w: Int, h: Int) -> List[UInt32]:
    var px = List[UInt32](capacity=w * h)
    for y in range(h):
        for x in range(w):
            px.append(UInt32(x * 255 // w) | (UInt32(y * 255 // h) << 8) | (UInt32(128) << 16) | 0xFF000000)
    return px^


def star(cx: Float64, cy: Float64, r: Float64) -> List[Float64]:
    """A five-pointed star drawn in one stroke (self-crossing: its middle is wound twice, filled by non-zero)."""
    var pts = List[Float64]()
    for i in range(5):
        var a = Float64(i) * 4.0 * 3.14159265 / 5.0 - 1.5707963
        pts.append(cx + r * cos(a))
        pts.append(cy + r * sin(a))
    return pts^


# ---- batches ----


def test_batches(font: Font, atlas: GlyphAtlas) raises:
    # counts per kind, glyphs = drawn characters
    var sc = Scene(400, 300, 1.0)
    sc.fill(BG)
    sc.rect(10, 10, 50, 30, BLUE, 6)
    sc.circle(100, 50, 20, INK)
    sc.line(0, 0, 100, 100, 2, INK)
    var text = String("Hi there, glyphs")
    sc.text(font, text, 20, 200, 14, INK, REGULAR, LEFT, 0)
    var img = gradient(8, 4)
    sc.image(img, 8, 4, 0, 0, 16, 8)
    sc.polygon(star(200, 150, 50), RED)
    var f = build_batches(sc, atlas, font)
    assert_equal(f.instances(PIPE_QUAD), 4, "fill, rect, circle, line")
    var drawn = 0
    for ch in text.codepoints():
        var gi = font.regular.find(Int(ch.to_u32()))
        if gi >= 0 and font.regular.glyphs[gi].w > 0 and font.regular.glyphs[gi].h > 0:
            drawn += 1
    assert_equal(drawn, 14, "16 characters, 2 spaces (no pixels)")
    assert_equal(f.instances(PIPE_GLYPH), drawn)
    assert_equal(f.instances(PIPE_IMAGE), 1)
    assert_equal(f.instances(PIPE_POLY), 1)
    assert_equal(len(f.fan) // 2, 3 * (5 - 2), "the star's fan: 3 triangles")
    assert_equal(Int(f.polys[1]), 9)
    assert_equal(len(f.points) // 2, 5)
    # fill (replace) | rect circle line (one run) | text | image (replace) | poly
    assert_equal(len(f.runs), 5)
    assert_equal(f.runs[0].pipe, PIPE_QUAD)
    assert_equal(f.runs[0].blend, BLEND_REPLACE)
    assert_equal(f.runs[1].pipe, PIPE_QUAD)
    assert_equal(f.runs[1].count, 3)
    assert_equal(f.runs[2].pipe, PIPE_GLYPH)
    assert_equal(f.runs[3].pipe, PIPE_IMAGE)
    assert_equal(f.runs[4].pipe, PIPE_POLY)
    # the circle is a capsule with both ends at its centre; the line's radius is half its width
    assert_equal(Int(f.quads[2 * QUAD_FLOATS + 5]), SHAPE_CAPSULE)
    assert_true(near(Float64(f.quads[2 * QUAD_FLOATS + 4]), 20))
    assert_true(near(Float64(f.quads[3 * QUAD_FLOATS + 4]), 1))
    assert_equal(Int(f.quads[1 * QUAD_FLOATS + 5]), SHAPE_BOX)
    assert_true(near(Float64(f.quads[1 * QUAD_FLOATS + 4]), 6))
    # colour: straight alpha floats (RED = 0xC03030E0: r 0xE0, a 0xC0)
    assert_true(near(Float64(f.polys[4]), 224.0 / 255.0) and near(Float64(f.polys[7]), 192.0 / 255.0))

    # paint order across kinds: rect, text, rect stays three runs; rects in a row are one
    var s2 = Scene(200, 100, 1.0)
    s2.rect(0, 0, 10, 10, INK, 0)
    s2.text(font, "A", 0, 50, 12, INK, REGULAR, LEFT, 0)
    s2.rect(0, 0, 10, 10, INK, 0)
    s2.rect(5, 5, 10, 10, INK, 0)
    s2.text(font, "   ", 0, 50, 12, INK, REGULAR, LEFT, 0)  # (no glyphs: no run, the rects around it stay one)
    s2.circle(5, 5, 3, INK)
    var f2 = build_batches(s2, atlas, font)
    assert_equal(len(f2.runs), 3)
    assert_equal(f2.runs[0].pipe, PIPE_QUAD)
    assert_equal(f2.runs[1].pipe, PIPE_GLYPH)
    assert_equal(f2.runs[2].pipe, PIPE_QUAD)
    assert_equal(f2.runs[2].first, 1)
    assert_equal(f2.runs[2].count, 3)

    # clips intersect, pop back, and end
    var s3 = Scene(400, 300, 1.0)
    s3.push_clip(10, 10, 100, 100)
    s3.rect(0, 0, 400, 300, INK, 0)
    s3.push_clip(50, 0, 100, 80)
    s3.rect(0, 0, 400, 300, INK, 0)
    s3.pop_clip()
    s3.rect(0, 0, 400, 300, INK, 0)
    s3.pop_clip()
    s3.rect(0, 0, 400, 300, INK, 0)
    var f3 = build_batches(s3, atlas, font)
    assert_equal(f3.instances(PIPE_QUAD), 4, "clips are not draws")
    assert_equal(len(f3.runs), 1)

    def clip_is(f: Frame2D, i: Int, x0: Float64, y0: Float64, x1: Float64, y1: Float64) -> Bool:
        var at = i * QUAD_FLOATS + 12
        return near(Float64(f.quads[at]), x0) and near(Float64(f.quads[at + 1]), y0) and near(Float64(f.quads[at + 2]), x1) and near(
            Float64(f.quads[at + 3]), y1)

    assert_true(clip_is(f3, 0, 10, 10, 110, 110))
    assert_true(clip_is(f3, 1, 50, 10, 110, 80), "nested clips intersect")
    assert_true(clip_is(f3, 2, 10, 10, 110, 110))
    var at = 3 * QUAD_FLOATS + 12
    assert_true(Float64(f3.quads[at]) <= -NO_CLIP * 0.5 and Float64(f3.quads[at + 1]) <= -NO_CLIP * 0.5 and Float64(f3.quads[at + 2]) >= NO_CLIP * 0.5
                and Float64(f3.quads[at + 3]) >= NO_CLIP * 0.5, "after the last pop: no clip")

    # layers: keys, versions, transforms carried; runs never cross layers; a clip opened in a moved layer is mapped
    var s4 = Scene(400, 300, 2.0)
    s4.begin_layer("cells")
    s4.layer_version(7)
    s4.layer_transform(5, 6, 2)
    s4.rect(0, 0, 10, 10, INK, 0)
    s4.push_clip(0, 0, 10, 10)
    s4.begin_layer("ring")
    s4.rect(0, 0, 10, 10, INK, 0)
    s4.pop_clip()
    s4.begin_layer("text")
    s4.layer_transform(-3, 4, 0.5)
    s4.text(font, "Mojo", 100, 50, 26, INK, MEDIUM, RIGHT, 0.2)
    var f4 = build_batches(s4, atlas, font)
    assert_equal(len(f4.layers), 3)
    assert_true(f4.layers[0].key == "cells" and f4.layers[1].key == "ring" and f4.layers[2].key == "text")
    assert_equal(f4.layers[0].version, 7)
    assert_equal(f4.layers[1].version, -1)
    assert_true(f4.layers[0].dx == 5 and f4.layers[0].dy == 6 and f4.layers[0].k == 2)
    assert_true(f4.layers[1].dx == 0 and f4.layers[1].dy == 0 and f4.layers[1].k == 1)
    assert_true(f4.layers[2].dx == -3 and f4.layers[2].dy == 4 and f4.layers[2].k == 0.5)
    assert_equal(f4.layers[0].runs, 1)
    assert_equal(f4.layers[1].runs, 1)
    assert_equal(f4.layers[1].first_run, 1)
    assert_equal(f4.layers[2].runs, 1)
    assert_true(clip_is(f4, 1, 5, 6, 25, 26), "the clip, in pixels, lands in the unmoved layer's units")
    # right-aligned text: the first glyph's left = x - width + its left bearing (the face picked at the size on screen)
    var g0 = font.medium.find(Int(ord("M")))
    var s = 26.0 / font.medium.size
    var want = 100 - font.measure("Mojo", 13, MEDIUM) * 2 + Float64(font.medium.glyphs[g0].left) * s
    assert_true(near(Float64(f4.glyphs[0]), want), "right alignment")
    assert_true(near(Float64(f4.glyphs[12]), 0.2) and near(Float64(f4.glyphs[13]), 50), "slant and baseline")
    assert_equal(f4.instances(PIPE_GLYPH), 4)
    # the display face is picked from the size on screen (a 40-px label shown at k = 0.5 is 20 px: the medium face)
    var s5 = Scene(400, 300, 1.0)
    s5.begin_layer("big")
    s5.text(font, "42", 0, 100, 40, INK, MEDIUM, LEFT, 0)
    s5.begin_layer("small")
    s5.layer_transform(0, 0, 0.5)
    s5.text(font, "42", 0, 100, 40, INK, MEDIUM, LEFT, 0)
    var f5 = build_batches(s5, atlas, font)
    assert_true(Int(f5.glyphs[5]) >= atlas.face_y[2] and Int(f5.glyphs[5]) < atlas.face_y[3], "big: the display face")
    assert_true(Int(f5.glyphs[2 * GLYPH_FLOATS + 5]) < atlas.face_y[2], "small: the medium face")
    # the atlas: every face's texels where its offsets say
    var probe = 0
    for i in range(len(font.mono.atlas)):
        if font.mono.atlas[i] != 0:
            var y = i // font.mono.width
            var x = i - y * font.mono.width
            assert_equal(Int(atlas.bytes[(atlas.face_y[3] + y) * atlas.width + atlas.face_x[3] + x]), Int(font.mono.atlas[i]))
            probe += 1
    assert_true(probe > 1000)
    print("atlas:", atlas.width, "x", atlas.height, "R8 (5 faces)")
    print("gpu2d batches: ok")


# ---- the CPU executor vs SurfacePainter ----


@fieldwise_init
struct Diff(Copyable, Movable):
    var mean: Float64
    var far: Float64  # % of pixels with a channel more than 40 levels off


def diff(a: List[UInt32], b: List[UInt32]) -> Diff:
    var total = 0
    var far = 0
    for i in range(len(a)):
        var x = a[i]
        var y = b[i]
        var worst = 0
        for c in range(3):
            var d = abs(Int((x >> UInt32(8 * c)) & 0xFF) - Int((y >> UInt32(8 * c)) & 0xFF))
            total += d
            worst = max(worst, d)
        if worst > 40:
            far += 1
    var d = Diff(Float64(total) / Float64(3 * len(a)), 100.0 * Float64(far) / Float64(len(a)))
    return d^


def paint_case[P: Painter](mut p: P, which: Int, font: Font, img: List[UInt32]):
    p.fill(BG)
    if which == 0:
        p.rect(20.3, 15.6, 140.2, 70.5, BLUE, 0)
        p.rect(60, 40, 90, 60, RED, 0)
    elif which == 1:
        p.rect(20.3, 15.6, 140.2, 70.5, BLUE, 14)
        p.rect(100.5, 50.25, 80, 60, RED, 40)
    elif which == 2:
        p.circle(60.5, 60.2, 40.3, BLUE)
        p.circle(120, 70, 25.7, RED)
        p.circle(180, 30, 0.8, INK)
    elif which == 3:
        p.line(10, 10, 190, 100, 1, INK)
        p.line(20.5, 100.3, 180.2, 20.7, 6.5, RED)
        p.line(30, 60, 170, 60, 3, BLUE)
    elif which >= 4 and which <= 7:
        var w = [REGULAR, MEDIUM, MONO, MONO_BOLD][which - 4]
        p.text(font, "Quick brown fox, 1,204.50", 8, 24, 20, INK, w, LEFT, 0)
        p.text(font, "small text at 9 px: jumps over", 8, 44, 9, INK, w, LEFT, 0)
        p.text(font, "Centred 13", 100, 70, 13, RED, w, CENTRE, 0)
        p.text(font, "42.7", 196, 112, 44, BLUE, w, RIGHT, 0)
    elif which == 8:
        p.text(font, "Slanted italic-ish text", 8, 30, 20, INK, REGULAR, LEFT, 0.2)
        p.text(font, "small slant 10 px", 8, 60, 10, RED, MEDIUM, LEFT, 0.25)
        p.text(font, "Mono slant", 8, 100, 24, BLUE, MONO, LEFT, 0.2)
    elif which == 9:
        p.image(img, 40, 30, 20, 10, 80, 60)
        p.image(img, 40, 30, 110, 20, 40, 30)
    elif which == 10:
        p.polygon(star(70, 60, 50), RED)
        var tri: List[Float64] = [120.3, 10.2, 195.7, 40.4, 140.1, 110.8]
        p.polygon(tri, BLUE)
    elif which == 11 or which == 12:  # clipped content (12: the same content, unclipped, for the reference)
        p.rect(10, 10, 180, 100, BLUE, 8)
        if which == 11:
            p.push_clip(30, 20, 110, 70)
        p.circle(60, 60, 45, RED)
        p.rect(80, 0, 200, 40, INK, 6)
        p.line(0, 120, 200, 0, 5, INK)
        p.text(font, "clipped words run past", 20, 80, 18, INK, MEDIUM, LEFT, 0)
        p.polygon(star(140, 70, 40), RED)
        if which == 11:
            p.pop_clip()
    elif which == 13:  # a transformed layer
        p.rect(0, 0, 10, 10, INK, 0)
        p.begin_layer("moved")
        p.layer_transform(13.5, -7.25, 1.7)
        p.rect(10, 10, 50, 30, BLUE, 6)
        p.circle(80, 40, 12, RED)
        p.line(0, 70, 100, 50, 2, INK)
        p.text(font, "zoomed 12", 5, 60, 12, INK, REGULAR, LEFT, 0)
        p.polygon(star(40, 45, 18), RED)
        p.begin_layer("shrunk")
        p.layer_transform(120, 60, 0.6)
        p.text(font, "shrunk text 14", 0, 30, 14, INK, MEDIUM, LEFT, 0)
        p.rect(0, 40, 100, 20, BLUE, 10)


def case_name(which: Int) -> String:
    return ["rect", "rounded rect", "circle", "line", "text regular", "text medium", "text mono", "text mono bold", "slanted text",
            "image", "polygon", "clipped", "", "transformed layer"][which]


def reference_case(which: Int, font: Font, img: List[UInt32], w: Int, h: Int) -> List[UInt32]:
    var a = List[UInt32](length=w * h, fill=0)
    var sp = SurfacePainter(Surface(Int(a.unsafe_ptr()), w, h, 1.0))
    paint_case(sp, which if which != 11 else 12, font, img)
    if which == 11:  # SurfacePainter doesn't clip (its callers never spill): the reference is the content cut by hand
        var bg = List[UInt32](length=w * h, fill=0)
        var sb = SurfacePainter(Surface(Int(bg.unsafe_ptr()), w, h, 1.0))
        sb.fill(BG)
        sb.rect(10, 10, 180, 100, BLUE, 8)
        for y in range(h):
            for x in range(w):
                if not (30 <= x < 140 and 20 <= y < 90):
                    a[y * w + x] = bg[y * w + x]
    return a^


def check(name: String, ref_px: List[UInt32], got: List[UInt32]) raises:
    var d = diff(ref_px, got)
    var inked = 0  # (the reference must show something: pixels not the colour of its top-left corner)
    var same = 0
    for i in range(len(ref_px)):
        if ref_px[i] != ref_px[0]:
            inked += 1
        if ref_px[i] == got[i]:
            same += 1
    print("  ", name, ": mean", round(d.mean, 4), "levels,", round(d.far, 4), "% far;", len(ref_px) - same, "of", len(ref_px),
          "pixels differ at all;", inked, "inked")
    assert_true(inked > 200, name + ": the reference picture is (nearly) empty")
    assert_true(d.mean <= 1.5 and d.far <= 0.5, name + ": the CPU executor differs from SurfacePainter")


def run_scene(sc: Scene, atlas: GlyphAtlas, font: Font, w: Int, h: Int) -> List[UInt32]:
    var f = build_batches(sc, atlas, font)
    var b = List[UInt32](length=w * h, fill=0)
    var sb = Surface(Int(b.unsafe_ptr()), w, h, sc.k)
    execute_cpu(f, atlas, sb)
    return b^


def batch_ms(sc: Scene, atlas: GlyphAtlas, font: Font) -> Float64:
    """The time of build_batches, the best of 20 (ms)."""
    var best = 1e30
    var f = Frame2D()
    for _ in range(20):
        var t0 = perf_counter_ns()
        f = build_batches(sc, atlas, font)
        best = min(best, Float64(perf_counter_ns() - t0) / 1e6)
    _ = f.instances(0)
    return best


def counts(sc: Scene, atlas: GlyphAtlas, font: Font) -> String:
    var f = build_batches(sc, atlas, font)
    return (String(sc.ops()) + " ops → " + String(len(f.runs)) + " runs: " + String(f.instances(PIPE_QUAD)) + " quads, " + String(
        f.instances(PIPE_GLYPH)) + " glyphs, " + String(f.instances(PIPE_POLY)) + " polys (" + String(len(f.fan) // 2) + " fan vertices), "
            + String(f.instances(PIPE_IMAGE)) + " images")


def whiteboard[P: Painter](mut p: P):
    """~200 pressure strokes (Stroke outlines) on a page, shown through a pan and a zoom."""
    p.fill(0xFFFFFFFF)
    p.begin_layer("ink")
    p.layer_transform(-40, -25, 0.9)
    var rng = Rng(75)
    var colors: List[UInt32] = [0xFF222222, 0xFFB0602A, 0xFF2A60B0, 0xE02A9040]
    for i in range(200):
        var s = Stroke(1.5 + rng.real(0, 5), colors[i % 4])
        var x = rng.real(0, 1000)
        var y = rng.real(0, 700)
        var dx = rng.real(-1, 1)
        var dy = rng.real(-1, 1)
        var n = 20 + Int(rng.real(0, 60))
        for k in range(n):
            dx += rng.real(-0.4, 0.4)
            dy += rng.real(-0.4, 0.4)
            x += dx * 3
            y += dy * 3
            s.add(x, y, 0.3 + 0.7 * abs(sin(Float64(k) * 0.15)))
        p.polygon(s.outline(), s.color)


def mindmap_of(n: Int) -> MindMap:
    var m = MindMap("Goal 75: silky on the GPU")
    var parents = List[Int]()
    parents.append(0)
    var rng = Rng(9)
    var names: List[String] = ["Whiteboard", "Canvas", "Mind map", "Metal", "GL", "Glyph atlas", "Stencil", "Springs", "Ribbons", "Bench"]
    for i in range(1, n):
        var par = parents[Int(rng.real(0, Float64(len(parents))))] if i > 6 else 0
        var id = m.add_child(par, names[i % len(names)] + " " + String(i))
        if len(parents) < 40:
            parents.append(id)
    return m^


def test_cpu(font: Font, atlas: GlyphAtlas) raises:
    var w = 200
    var h = 120
    var img = gradient(40, 30)
    for which in range(14):
        if which == 12:
            continue
        var sc = Scene(w, h, 1.0)
        paint_case(sc, which, font, img)
        var got = run_scene(sc, atlas, font, w, h)
        var want = reference_case(which, font, img, w, h)
        check(case_name(which), want, got)

    # the comparison sees a difference when there is one (a rect vs a rounded rect, a 1-px shift of the canvas)
    var r0 = reference_case(0, font, img, w, h)
    var d01 = diff(r0, reference_case(1, font, img, w, h))
    assert_true(d01.mean > 1.5 and d01.far > 0.5, "rect vs rounded rect must fail the bounds")
    var sh = Scene(w, h, 1.0)
    sh.begin_layer("")
    sh.layer_transform(1, 0, 1)
    paint_case(sh, 4, font, img)
    var d_shift = diff(reference_case(4, font, img, w, h), run_scene(sh, atlas, font, w, h))
    print("   (sanity: rect vs rounded rect mean", round(d01.mean, 2), "/", round(d01.far, 2), "% far; text moved 1 px mean",
          round(d_shift.mean, 2), "/", round(d_shift.far, 2), "% far)")
    assert_true(d_shift.far > 0.5, "text moved by a pixel must fail the bounds")

    # whiteboard
    var W = 1000
    var H = 700
    var sc = Scene(W, H, 1.0)
    whiteboard(sc)
    var a = List[UInt32](length=W * H, fill=0)
    var sp = SurfacePainter(Surface(Int(a.unsafe_ptr()), W, H, 1.0))
    whiteboard(sp)
    check("whiteboard", a, run_scene(sc, atlas, font, W, H))
    print("     ", counts(sc, atlas, font), "; build_batches", round(batch_ms(sc, atlas, font), 3), "ms")

    # canvas: Personal Note's benchmark note (or the seeded stand-in), the view of one page and a zoomed-out one
    var text = String()
    var source = String("build/g74/bench-note.json")
    var have = True
    try:
        var fh = open("build/g74/bench-note.json", "r")
        text = fh.read()
        fh.close()
    except:
        have = False
    var ol = import_fabric(text, font) if have else seeded_note()
    if not have:
        source = "seeded 645-object note"
    W = 1280
    H = 800
    for zoom in range(2):
        var k = 1.0 if zoom == 0 else 0.45
        var c = Scene(W, H, 1.0)
        c.fill(0xFFFFFFFF)
        ol.paint(c, font, 20, 30, Float64(W) / k, Float64(H) / k, k)
        var b = List[UInt32](length=W * H, fill=0)
        var sp2 = SurfacePainter(Surface(Int(b.unsafe_ptr()), W, H, 1.0))
        sp2.fill(0xFFFFFFFF)
        ol.paint(sp2, font, 20, 30, Float64(W) / k, Float64(H) / k, k)
        check("canvas (" + source + ", k " + String(k) + ")", b, run_scene(c, atlas, font, W, H))
        print("     ", counts(c, atlas, font), "; build_batches", round(batch_ms(c, atlas, font), 3), "ms")

    # mind map: ~100 topics
    var m = mindmap_of(100)
    W = 1400
    H = 900
    var ms = Scene(W, H, 1.0)
    ms.is_still = True
    ms.fill(0xFFFFFFFF)
    m.paint(ms, font, MapView(Float64(W) / 2, Float64(H) / 2, 0.8))
    var mp = List[UInt32](length=W * H, fill=0)
    var surf = Surface(Int(mp.unsafe_ptr()), W, H, 1.0)
    surf.still = True
    var sp3 = SurfacePainter(surf^)
    sp3.fill(0xFFFFFFFF)
    m.paint(sp3, font, MapView(Float64(W) / 2, Float64(H) / 2, 0.8))
    check("mindmap (" + String(m.nodes()) + " topics)", mp, run_scene(ms, atlas, font, W, H))
    print("     ", counts(ms, atlas, font), "; build_batches", round(batch_ms(ms, atlas, font), 3), "ms")
    print("gpu2d cpu: ok")


def text_scene(w: Int, h: Int, k: Float64, zoom: Float64) -> Scene:
    """Goal 79: fonttext runs (several faces and scripts, colour emoji) and Lucide icons (see-through images), in a layer
    scaled by k·zoom: the GPU must draw them from the device-pixel glyph atlas exactly as the CPU executor does."""
    var sc = Scene(w, h, k)
    sc.begin_layer("bg")
    sc.fill(rgba(255, 253, 248))
    sc.begin_layer("text")
    sc.layer_transform(0, 0, k * zoom)
    sc.run(TextStyle("Geist", 400, False, 14), "Quick note, Inbox and the shelves", 10, 24, rgba(31, 27, 22), 0)
    sc.run(TextStyle("Literata", 700, False, 18), "Three days on the coast", 10, 52, rgba(31, 27, 22), 0)
    sc.run(TextStyle("Bricolage Grotesque", 700, False, 26), "Lighthouse trip", 10, 86, rgba(74, 68, 59), 0)
    sc.run(TextStyle("Geist", 400, False, 16), "नमस्ते 漢字 한국어 ✈️ 📚", 10, 114, rgba(31, 27, 22), 0)
    sc.run(TextStyle("Source Serif 4", 600, True, 15), "Harbour — clipped", 10, 138, rgba(37, 99, 235, 200), 0)
    draw_icon(sc, "panel-left", 220, 10, 20, k * zoom, rgba(74, 68, 59))
    draw_icon(sc, "search", 250, 10, 20, k * zoom, rgba(74, 68, 59, 160))
    return sc^


def main() raises:
    var font = Font()
    var t0 = perf_counter_ns()
    var atlas = GlyphAtlas(font)
    print("atlas built in", round(Float64(perf_counter_ns() - t0) / 1e6, 2), "ms")
    test_batches(font, atlas)
    test_cpu(font, atlas)
