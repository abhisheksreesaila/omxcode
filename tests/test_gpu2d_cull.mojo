# Goal 80 M1: draw only what can show. fill_batches drops ops (and the glyphs of a text run) wholly outside their clip,
# and outside the canvas for a layer that is rebuilt when it moves, before text is shaped. Proves:
#   (a) the CPU executor's picture with culling equals the picture without, bit for bit: goal 75's scenes (each test
#       primitive, whiteboard, Personal Note's 645-object canvas at two zooms, a mind map, fonttext runs) and 200 random
#       scenes of every op kind under nested clips and scaled, moved layers;
#   (b) no built instance lies wholly outside its clip ∩ the canvas (the canvas only for layers that aren't fixed);
#   (c) a 1000-row clipped column builds exactly the instances of a scene holding only the rows that meet the clip.
#   pixi run mojo run -I . tests/test_gpu2d_cull.mojo
from std.testing import assert_true, assert_equal

from mojoui.canvas import Surface, rgba
from mojoui.text import Font, LEFT, RIGHT, CENTRE
from mojoui.scene import Scene
from mojoui.fonttext import TextStyle, ALIGN_LEFT, ALIGN_RIGHT, ALIGN_CENTER
from mojoui.gpu2d import (GlyphAtlas, Frame2D, build_batches, execute_cpu, layer_traits, PIPE_QUAD, PIPE_GLYPH, PIPE_IMAGE,
                          PIPE_POLY, QUAD_FLOATS, GLYPH_FLOATS, IMAGE_FLOATS, POLY_FLOATS, NO_CLIP)
from mojoui.mindmap import MapView
from tests.test_gpu2d import Rng, paint_case, case_name, gradient, whiteboard, mindmap_of, text_scene
from tests.test_objectlayer import seeded_note


def picture(f: Frame2D, atlas: GlyphAtlas) -> List[UInt32]:
    var px = List[UInt32](length=f.width * f.height, fill=0)
    var s = Surface(Int(px.unsafe_ptr()), f.width, f.height, f.scale)
    execute_cpu(f, atlas, s)
    return px^


def instances(f: Frame2D) -> Int:
    var n = 0
    for r in f.runs:
        n += r.count
    return n


def same(name: String, scene: Scene, atlas: GlyphAtlas, font: Font) raises -> Bool:
    """(a) and (b) for one scene; prints its instance counts."""
    var off = build_batches(scene, atlas, font, False)
    var on = build_batches(scene, atlas, font, True)
    var a = picture(off, atlas)
    var b = picture(on, atlas)
    var differ = 0
    for i in range(len(a)):
        if a[i] != b[i]:
            differ += 1
    assert_equal(differ, 0, name + ": culling changed " + String(differ) + " pixels")
    inside(name, scene, on)
    print("  ", name, ": IDENTICAL; instances", instances(off), "->", instances(on))
    return True


def meets(x0: Float64, y0: Float64, x1: Float64, y1: Float64, rx0: Float64, ry0: Float64, rx1: Float64, ry1: Float64) -> Bool:
    return x1 >= rx0 and x0 <= rx1 and y1 >= ry0 and y0 <= ry1


def inside(name: String, scene: Scene, f: Frame2D) raises:
    """(b) every instance's box meets its clip ∩ (the canvas, for a layer that isn't fixed), in its layer's units."""
    var open = 0
    for li in range(len(f.layers)):
        ref L = f.layers[li]
        var tr = layer_traits(scene, li, open) if li < scene.layers() else layer_traits(scene, 0, 0)
        open = tr.open
        var ik = 1.0 / L.k
        var cx0 = -NO_CLIP
        var cy0 = -NO_CLIP
        var cx1 = NO_CLIP
        var cy1 = NO_CLIP
        if not tr.fixed:
            cx0 = -L.dx * ik
            cy0 = -L.dy * ik
            cx1 = (Float64(f.width) - L.dx) * ik
            cy1 = (Float64(f.height) - L.dy) * ik
        var pad = 2.5 * ik
        for ri in range(L.first_run, L.first_run + L.runs):
            var r = f.runs[ri]
            for j in range(r.first, r.first + r.count):
                var x0: Float64
                var y0: Float64
                var x1: Float64
                var y1: Float64
                var k0: Int
                if r.pipe == PIPE_QUAD:
                    var q = j * QUAD_FLOATS
                    var a = Float64(f.quads[q])
                    var b = Float64(f.quads[q + 1])
                    var c = Float64(f.quads[q + 2])
                    var d = Float64(f.quads[q + 3])
                    if Int(f.quads[q + 5]) == 2:  # SHAPE_SHADOW (goal 80 M4): 3 sigma past its box
                        var g = 3 * Float64(f.quads[q + 7]) + 1
                        x0 = a - g
                        y0 = b - g
                        x1 = a + c + g
                        y1 = b + d + g
                    elif Int(f.quads[q + 5]) == 0:  # SHAPE_BOX
                        x0 = a
                        y0 = b
                        x1 = a + c
                        y1 = b + d
                        if c >= NO_CLIP * 0.5 or abs(a) >= NO_CLIP * 0.5:
                            continue  # (a fill covers the canvas)
                    else:
                        var hw = Float64(f.quads[q + 4])
                        x0 = min(a, c) - hw
                        y0 = min(b, d) - hw
                        x1 = max(a, c) + hw
                        y1 = max(b, d) + hw
                    k0 = q + 12
                    if x0 <= cx0 and y0 <= cy0 and x1 >= cx1 and y1 >= cy1:
                        continue  # (a fill: the whole canvas)
                    ref cl = f.quads
                    assert_true(meets(x0 - pad, y0 - pad, x1 + pad, y1 + pad, max(Float64(cl[k0]), cx0), max(Float64(cl[k0 + 1]), cy0),
                                      min(Float64(cl[k0 + 2]), cx1), min(Float64(cl[k0 + 3]), cy1)), name + ": a quad outside what can show")
                elif r.pipe == PIPE_GLYPH:
                    var g = j * GLYPH_FLOATS
                    var gy = Float64(f.glyphs[g + 1])
                    var base = Float64(f.glyphs[g + 13])
                    var lean = abs(Float64(f.glyphs[g + 12])) * max(abs(base - gy), abs(gy + Float64(f.glyphs[g + 3]) - base))
                    x0 = Float64(f.glyphs[g]) - lean
                    y0 = gy
                    x1 = Float64(f.glyphs[g]) + Float64(f.glyphs[g + 2]) + lean
                    y1 = y0 + Float64(f.glyphs[g + 3])
                    k0 = g + 16
                    assert_true(meets(x0 - pad, y0 - pad, x1 + pad, y1 + pad, max(Float64(f.glyphs[k0]), cx0), max(Float64(f.glyphs[k0 + 1]), cy0),
                                      min(Float64(f.glyphs[k0 + 2]), cx1), min(Float64(f.glyphs[k0 + 3]), cy1)), name + ": a glyph outside what can show")
                elif r.pipe == PIPE_IMAGE:
                    var m = j * IMAGE_FLOATS
                    x0 = Float64(f.images[m])
                    y0 = Float64(f.images[m + 1])
                    x1 = x0 + Float64(f.images[m + 2])
                    y1 = y0 + Float64(f.images[m + 3])
                    k0 = m + 8
                    assert_true(meets(x0 - pad, y0 - pad, x1 + pad, y1 + pad, max(Float64(f.images[k0]), cx0), max(Float64(f.images[k0 + 1]), cy0),
                                      min(Float64(f.images[k0 + 2]), cx1), min(Float64(f.images[k0 + 3]), cy1)), name + ": an image outside what can show")
                elif r.pipe == PIPE_POLY:
                    var p = j * POLY_FLOATS
                    x0 = Float64(f.polys[p + 8])
                    y0 = Float64(f.polys[p + 9])
                    x1 = Float64(f.polys[p + 10])
                    y1 = Float64(f.polys[p + 11])
                    k0 = p + 12
                    assert_true(meets(x0 - pad, y0 - pad, x1 + pad, y1 + pad, max(Float64(f.polys[k0]), cx0), max(Float64(f.polys[k0 + 1]), cy0),
                                      min(Float64(f.polys[k0 + 2]), cx1), min(Float64(f.polys[k0 + 3]), cy1)), name + ": a polygon outside what can show")


def random_scene(seed: Int, font: Font, img: List[UInt32]) -> Scene:
    """Every op kind, scattered well past the canvas, under nested clips, in 1–3 layers with scaled, moved transforms;
    some layers fixed (no fill, clip or image), some not."""
    var rng = Rng(UInt64(1000 + seed))
    var W = 260
    var H = 180
    var sc = Scene(W, H, 1.0)
    var layers = 1 + Int(rng.real(0, 3))
    var faces: List[String] = ["Geist", "Source Serif 4", "IBM Plex Mono", "Literata"]
    var words: List[String] = ["Quick note", "Harbour 1,204.50", "नमस्ते दुनिया", "漢字かな", "한국어", "✈️📚 trip", "Wolf"]
    for li in range(layers):
        sc.begin_layer("L" + String(li))
        var k = rng.real(0.5, 2.0)
        sc.layer_transform(rng.real(-80, 80), rng.real(-60, 60), k)
        var fixed = rng.real(0, 1) < 0.4
        if not fixed and li == 0:
            sc.fill(rgba(250, 248, 244))
        var depth = 0
        for _ in range(40):
            var x = rng.real(-250, 450)
            var y = rng.real(-200, 350)
            var col = rgba(Int(rng.real(0, 255)), Int(rng.real(0, 255)), Int(rng.real(0, 255)), 120 + Int(rng.real(0, 135)))
            var which = Int(rng.real(0, 12))
            if not fixed and which == 9 and depth < 3:
                sc.push_clip(rng.real(-40, 200), rng.real(-40, 140), rng.real(10, 200), rng.real(10, 140))
                depth += 1
                continue
            if not fixed and which == 10 and depth > 0:
                sc.pop_clip()
                depth -= 1
                continue
            if which == 0:
                sc.rect(x, y, rng.real(1, 90), rng.real(1, 60), col, rng.real(0, 12))
            elif which == 11:
                sc.shadow(x, y, rng.real(4, 90), rng.real(4, 60), rng.real(0, 14), rng.real(0, 30), col)
            elif which == 1:
                sc.circle(x, y, rng.real(1, 30), col)
            elif which == 2:
                sc.line(x, y, x + rng.real(-120, 120), y + rng.real(-120, 120), rng.real(0.5, 9), col)
            elif which == 3:
                var al = [LEFT, CENTRE, RIGHT][Int(rng.real(0, 3))]
                sc.text(font, words[Int(rng.real(0, 2))], x, y, rng.real(8, 30), col, 400, al, rng.real(-0.2, 0.2))
            elif which == 4 or which == 5:
                var al = [ALIGN_LEFT, ALIGN_CENTER, ALIGN_RIGHT][Int(rng.real(0, 3))]
                var st = TextStyle(faces[Int(rng.real(0, 4))], 700 if rng.real(0, 1) < 0.3 else 400, rng.real(0, 1) < 0.25, rng.real(9, 36))
                if rng.real(0, 1) < 0.4:
                    st.letter_spacing = rng.real(-2.5, 2.5) * st.size  # (pulled so far together that it runs backwards, or wide apart)
                sc.run(st, words[Int(rng.real(0, Float64(len(words))))] + " " + String(seed), x, y, col, al)
            elif which == 6 and not fixed:
                sc.image(img, 40, 30, x, y, rng.real(5, 80), rng.real(5, 60))
            elif which == 7:
                var pts = List[Float64]()
                var n = 3 + Int(rng.real(0, 8))
                for _ in range(n):
                    pts.append(x + rng.real(-60, 60))
                    pts.append(y + rng.real(-60, 60))
                sc.polygon(pts, col)
            else:
                var pts = List[Float64]()
                var n = 2 + Int(rng.real(0, 6))
                var px = x
                var py = y
                for _ in range(n):
                    px += rng.real(-40, 40)
                    py += rng.real(-40, 40)
                    pts.append(px)
                    pts.append(py)
                sc.stroke(pts, rng.real(1, 8), col)
        while depth > 0:
            sc.pop_clip()
            depth -= 1
    return sc^


def column(rows: Int, only_visible: Bool, font: Font) -> Scene:
    """(c) A clipped column of `rows` rows (a zebra band, a label, a number on the right) moved up by 9 000 px; with
    only_visible, just the rows that meet the clip (the oracle, what an app with a virtual list would draw)."""
    var sc = Scene(900, 640, 1.0)
    sc.begin_layer("list")
    sc.fill(rgba(245, 245, 247))
    var cy0 = 40.0
    var cy1 = 600.0
    sc.push_clip(20, cy0, 860, cy1 - cy0)
    var offset = 9000.0
    var st = TextStyle("Geist", 400, False, 13)
    for i in range(rows):
        var y = Float64(i) * 28 - offset
        if only_visible and (y + 28 < cy0 or y > cy1):
            continue
        if i % 2 == 1:
            sc.rect(20, y, 860, 28, rgba(236, 236, 240), 0)
        sc.run(st, "Row " + String(i) + " — a line of a long list", 32, y + 18, rgba(29, 29, 31), ALIGN_LEFT)
        sc.run(st, String(i * 7 % 100), 868, y + 18, rgba(29, 29, 31), ALIGN_RIGHT)
    sc.pop_clip()
    return sc^


def main() raises:
    var font = Font()
    var atlas = GlyphAtlas(font)
    var img = gradient(40, 30)
    var scenes = 0
    # goal 75's scenes
    for which in range(14):
        if which == 12:
            continue
        var sc = Scene(200, 120, 1.0)
        paint_case(sc, which, font, img)
        _ = same(case_name(which), sc, atlas, font)
        scenes += 1
    var wb = Scene(1000, 700, 1.0)
    whiteboard(wb)
    _ = same("whiteboard", wb, atlas, font)
    var ol = seeded_note()
    for k in [1.0, 0.45]:
        var c = Scene(1280, 800, 1.0)
        c.fill(0xFFFFFFFF)
        ol.paint(c, font, 20, 30, 1280.0 / k, 800.0 / k, k)
        _ = same("canvas (645 objects, k " + String(k) + ")", c, atlas, font)
    var m = mindmap_of(100)
    var ms = Scene(1400, 900, 1.0)
    ms.fill(0xFFFFFFFF)
    m.paint(ms, font, MapView(700, 450, 0.8))
    _ = same("mindmap", ms, atlas, font)
    for zoom in [1.0, 4.0]:
        var big = 1 if zoom == 1.0 else 2
        _ = same("fonttext runs (zoom " + String(zoom) + ")", text_scene(480 * big, 240 * big, 1.6, zoom), atlas, font)
    scenes += 6
    # 200 random scenes
    var dropped = 0
    var total = 0
    for seed in range(200):
        var sc = random_scene(seed, font, img)
        var off = build_batches(sc, atlas, font, False)
        var on = build_batches(sc, atlas, font, True)
        var a = picture(off, atlas)
        var b = picture(on, atlas)
        var differ = 0
        for i in range(len(a)):
            if a[i] != b[i]:
                differ += 1
        assert_equal(differ, 0, "random scene " + String(seed) + ": culling changed " + String(differ) + " pixels")
        inside("random scene " + String(seed), sc, on)
        total += instances(off)
        dropped += instances(off) - instances(on)
    scenes += 200
    print("  200 random scenes: IDENTICAL; instances culled", dropped, "of", total)
    print("IDENTICAL", scenes, "/", scenes)
    # polygons with too few points, an odd coordinate or none: recorded as nothing, or as their whole points, never out of step
    var odd = Scene(200, 120, 1.0)
    odd.fill(rgba(255, 255, 255))
    odd.polygon(List[Float64](), rgba(0, 0, 0))
    odd.polygon([10.0, 10.0, 60.0, 10.0], rgba(0, 0, 0))
    odd.polygon([10.0, 10.0, 60.0, 10.0, 60.0, 60.0, 99.0], rgba(200, 0, 0))
    odd.polygon([100.0, 10.0, 160.0, 10.0, 130.0, 70.0], rgba(0, 0, 200))
    _ = same("polygons with too few or odd points", odd, atlas, font)
    # (c) the oracle
    var full = build_batches(column(1000, False, font), atlas, font)
    var oracle = build_batches(column(1000, True, font), atlas, font)
    print("  oracle: 1000-row clipped column", instances(full), "instances; the rows that meet the clip alone", instances(oracle))
    assert_equal(instances(full), instances(oracle), "the clipped column builds more than the rows that show")
    var pa = picture(full, atlas)
    var pb = picture(oracle, atlas)
    var differ = 0
    for i in range(len(pa)):
        if pa[i] != pb[i]:
            differ += 1
    assert_equal(differ, 0, "the oracle's picture differs")
    print("gpu2d cull: ok")
