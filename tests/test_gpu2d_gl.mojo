# The GL backend of the GPU 2D renderer (goal 75 M2): the same batches test_gpu2d draws on the CPU, drawn by OpenGL in
# a headless context (EGL, desktop GL 3.3 core, no window) and read back: each primitive alone and the three scenes like
# the judged ones (whiteboard, Personal Note's 645-object canvas, a mind map) must match the CPU executor within M1's
# bounds (mean ≤ 1.5 levels per channel, ≤ 0.5 % of pixels more than 40 off). Prints each case's numbers, the frame's
# GPU time (upload + draw + resolve, glFinish-timed) for the scenes, then `gpu2d gl: ok`.
#   pixi run mojo run -I . tests/test_gpu2d_gl.mojo
from std.testing import assert_true
from std.math import sin
from std.time import perf_counter_ns
from std.os import setenv

from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.scene import Scene, Painter
from mojoui.gpu2d import GlyphAtlas, Frame2D, build_batches, fill_batches, execute_cpu, PIPE_POLY
from mojoui.gpu2d_gl import GL2D, GPU2D, headless_gl33, gl_proc
from mojoui.present import fcall, dl_open, dl_sym
from std.ffi import c_uint, c_int
from mojoui.gpu2d_merge import merge_runs
from mojoui.ink import Stroke
from mojoui.objectlayer import import_fabric
from mojoui.mindmap import MapView
from tests.test_gpu2d import text_scene, paint_case, case_name, gradient, whiteboard, mindmap_of, diff, Rng
from tests.test_objectlayer import seeded_note


def cpu_of(frame: Frame2D, atlas: GlyphAtlas) -> List[UInt32]:
    var px = List[UInt32](length=frame.width * frame.height, fill=0)
    var s = Surface(Int(px.unsafe_ptr()), frame.width, frame.height, frame.scale)
    execute_cpu(frame, atlas, s)
    return px^


def gl_of(mut gl: GL2D, frame: Frame2D) raises -> List[UInt32]:
    var w = frame.width
    var h = frame.height
    var tex = gl.make_texture(w, h)
    assert_true(gl.render(frame, tex, w, h), "render: " + gl.why)
    var px = List[UInt32](length=w * h, fill=0)
    assert_true(gl.read(tex, w, h, Int(px.unsafe_ptr())), "read back")
    gl.delete(17, tex)  # F_DELETE_TEXTURES
    return px^


def compare(name: String, frame: Frame2D, mut gl: GL2D, atlas: GlyphAtlas) raises:
    var want = cpu_of(frame, atlas)
    var got = gl_of(gl, frame)
    var d = diff(want, got)
    var inked = 0
    var same = 0
    for i in range(len(want)):
        if want[i] != want[0]:
            inked += 1
        if (want[i] & 0xFFFFFF) == (got[i] & 0xFFFFFF):
            same += 1
    print("  ", name, ": mean", round(d.mean, 4), "levels,", round(d.far, 4), "% far;", len(want) - same, "of", len(want),
          "pixels differ at all;", inked, "inked;", gl.draws, "draws,", gl.poly_groups, "polygon groups")
    assert_true(inked > 200, name + ": the reference picture is (nearly) empty")
    assert_true(d.mean <= 1.5 and d.far <= 0.5, name + ": the GL picture differs from the CPU executor")


def compare_merged(name: String, scene: Scene, mut gl: GL2D, atlas: GlyphAtlas, font: Font) raises:
    """merge_runs's regrouping: the CPU executor draws the merged runs exactly as the runs as built (no pixel differs),
    and the GL picture of the merged runs is within the bounds of the CPU's picture of the runs as built."""
    var built = build_batches(scene, atlas, font)
    var scratch = build_batches(scene, atlas, font)
    var merged = Frame2D()
    merge_runs(scratch, merged)
    var want = cpu_of(built, atlas)
    var again = cpu_of(merged, atlas)
    var got = gl_of(gl, merged)
    var moved = 0
    for i in range(len(want)):
        if want[i] != again[i]:
            moved += 1
    var d = diff(want, got)
    print("  ", name, "merged:", len(built.runs), "runs ->", len(merged.runs), "; CPU pixels changed by merging:", moved,
          "; GL vs CPU mean", round(d.mean, 4), "levels,", round(d.far, 4), "% far;", gl.draws, "draws,", gl.poly_groups, "polygon groups")
    assert_true(len(merged.runs) <= len(built.runs), name + ": merging added runs")
    assert_true(moved == 0, name + ": merging changed the picture")
    assert_true(d.mean <= 1.5 and d.far <= 0.5, name + ": the GL picture of the merged runs differs from the CPU executor")


def gpu_ms(mut gl: GL2D, scene: Scene, atlas: GlyphAtlas, font: Font) raises -> String:
    """A scene's frame on the GPU, as a host does it each frame: fill_batches (reusing the Frame2D), the upload, the
    draws and the resolve, glFinish-timed; p50 and max of 30 after 3 warm-ups."""
    var f = Frame2D()
    var built = Frame2D()
    var w = scene.w
    var h = scene.h
    var tex = gl.make_texture(w, h)
    var times = List[Float64]()
    var batch = List[Float64]()
    for i in range(33):
        var t0 = perf_counter_ns()
        fill_batches(built, scene, atlas, font)
        merge_runs(built, f)
        var t1 = perf_counter_ns()
        assert_true(gl.render(f, tex, w, h), gl.why)
        gl.finish()
        var t2 = perf_counter_ns()
        if i >= 3:
            batch.append(Float64(t1 - t0) / 1e6)
            times.append(Float64(t2 - t1) / 1e6)
    gl.delete(17, tex)
    sort(times)
    sort(batch)
    return ("batches+merge p50 " + String(round(batch[len(batch) // 2], 3)) + " ms; GL upload+draw+resolve (glFinish) p50 " + String(
        round(times[len(times) // 2], 3)) + " ms, max " + String(round(times[len(times) - 1], 3)) + " ms (" + String(w) + "×" + String(h)
            + ", " + String(gl.draws) + " draws)")


def whiteboard_big[P: Painter](mut p: P, strokes: Int):
    """The judged whiteboard's size: `strokes` pressure strokes (~100 points each) over the page (timing only)."""
    p.fill(0xFFFFFFFF)
    p.begin_layer("ink")
    p.layer_transform(-40, -25, 0.9)
    var rng = Rng(76)
    var colors: List[UInt32] = [0xFF222222, 0xFFB0602A, 0xFF2A60B0, 0xE02A9040]
    for i in range(strokes):
        var s = Stroke(1.5 + rng.real(0, 5), colors[i % 4])
        var x = rng.real(0, 1600)
        var y = rng.real(0, 1000)
        var dx = rng.real(-1, 1)
        var dy = rng.real(-1, 1)
        for k in range(100):
            dx += rng.real(-0.4, 0.4)
            dy += rng.real(-0.4, 0.4)
            x += dx * 3
            y += dy * 3
            s.add(x, y, 0.3 + 0.7 * abs(sin(Float64(k) * 0.15)))
        p.polygon(s.outline(), s.color)


def grown_page(mut gl: GL2D, atlas: GlyphAtlas, font: Font) raises:
    """GPU2D as a host uses it: a page of 100 strokes drawn, then the same page with 10 more (a stroke finished): the
    ink layer must only grow (its new strokes built, planned and uploaded after the rest), and the picture must match
    the CPU executor's picture of the whole page."""
    var g = GPU2D()
    assert_true(g.start(False), "GPU2D.start: " + g.gl.why)
    var a = Scene(1000, 700, 1.0)
    whiteboard_big(a, 100)
    var b = Scene(1000, 700, 1.0)
    whiteboard_big(b, 110)
    var empty = Scene(0, 0, 1.0)
    var s1 = g.draw(a, empty, 1, 1000, 700)
    assert_true(s1 >= 0, "first draw: " + g.gl.why)
    var s2 = g.draw(b, a, 1, 1000, 700)
    assert_true(s2 >= 0, "second draw: " + g.gl.why)
    var grown = g.grown
    var uploaded = g.gl.uploaded
    var got = List[UInt32](length=1000 * 700, fill=0)
    assert_true(g.gl.read(g.gl.tex[s2], 1000, 700, Int(got.unsafe_ptr())), "read back")
    var want = cpu_of(build_batches(b, atlas, font), atlas)
    var d = diff(want, got)
    print("   grown page (100 strokes, then 10 more): layers grown", grown, "; uploaded", uploaded // 1024, "KB; mean", round(d.mean, 4),
          "levels,", round(d.far, 4), "% far;", g.gl.draws, "draws,", g.gl.poly_groups, "polygon groups")
    assert_true(g.opaque, "a page filled with an opaque colour is an opaque frame")
    var see = Scene(1000, 700, 1.0)  # (no fill: the canvas stays see-through where nothing is drawn)
    see.rect(10, 10, 100, 50, 0xFF2040A0, 0)
    _ = g.draw(see, empty, 3, 1000, 700)
    assert_true(not g.opaque, "a frame with no fill isn't opaque")
    var s3 = g.draw(b, empty, 2, 1000, 700)  # (control: the whole page drawn afresh)
    var whole = List[UInt32](length=1000 * 700, fill=0)
    assert_true(s3 >= 0 and g.gl.read(g.gl.tex[s3], 1000, 700, Int(whole.unsafe_ptr())), "control draw")
    var dc = diff(want, whole)
    var dg = diff(whole, got)
    print("   (control: drawn whole: mean", round(dc.mean, 4), "levels,", round(dc.far, 4), "% far; grown vs whole: mean", round(dg.mean, 4), ",", round(dg.far, 4), "% far)")
    g.gl.close()
    assert_true(grown == 1, "the ink layer should only have grown")
    assert_true(d.mean <= 1.5 and d.far <= 0.5, "the grown page differs from the CPU executor")


def signed32(x: Int) -> Int:
    var v = x & 0xFFFFFFFF
    return v - (1 << 32) if v >= 0x80000000 else v


def dmabuf_page(atlas: GlyphAtlas, font: Font) raises:
    """D-7570: a drawn ring texture exported as a dmabuf (what a compositor is handed under graphics offload), the
    frame's fence imported into it, then the dmabuf imported back as a new GL texture (EGL_EXT_image_dma_buf_import,
    as a compositor does) and read: the same pixels as the ring texture, and within M1's bounds of the CPU executor."""
    var g = GPU2D()
    assert_true(g.start(False), "GPU2D.start: " + g.gl.why)
    var egl = dl_open("libEGL.so.1")
    var dpy = fcall[Int](dl_sym(egl, "eglGetCurrentDisplay"))
    if not g.gl.dmabuf.start(dpy):
        print("   dmabuf: not on this EGL display (" + g.gl.dmabuf.why + "); hosts show GL textures instead")
        g.gl.close()
        return
    var page = Scene(1000, 700, 1.0)
    whiteboard_big(page, 100)
    var empty = Scene(0, 0, 1.0)
    var s = g.draw(page, empty, 1, 1000, 700)
    assert_true(s >= 0, "draw: " + g.gl.why)
    assert_true(g.gl.dmabuf.export(s, g.gl.tex[s]), "export: " + g.gl.dmabuf.why)
    var fd0 = g.gl.dmabuf.fd[s]
    assert_true(g.gl.dmabuf.export(s, g.gl.tex[s]) and g.gl.dmabuf.fd[s] == fd0, "a texture is exported once")
    assert_true(g.gl.dmabuf.fence(s), "the frame's fence into the dmabuf")
    var mod = g.gl.dmabuf.modifier[s]
    var attrs: List[Int32] = [0x3057, 1000, 0x3056, 700, 0x3271, Int32(g.gl.dmabuf.fourcc[s]), 0x3272, Int32(fd0),
                              0x3273, Int32(g.gl.dmabuf.offset[s]), 0x3274, Int32(g.gl.dmabuf.stride[s]),
                              0x3443, Int32(signed32(mod)), 0x3444, Int32(signed32(mod >> 32)), 0x3038]
    var image = fcall[Int](gl_proc("eglCreateImageKHR"), dpy, 0, c_uint(0x3270), 0, Int(attrs.unsafe_ptr()))
    _ = len(attrs)
    assert_true(image != 0, "the dmabuf imports back (EGL_EXT_image_dma_buf_import)")
    var tex2 = g.gl.gen(16)  # F_GEN_TEXTURES
    fcall[NoneType](g.gl.f(18), c_uint(0x0DE1), c_uint(tex2))  # glBindTexture
    fcall[NoneType](gl_proc("glEGLImageTargetTexture2DOES"), c_uint(0x0DE1), image)
    fcall[NoneType](g.gl.f(18), c_uint(0x0DE1), c_uint(0))
    var direct = List[UInt32](length=1000 * 700, fill=0)
    var via = List[UInt32](length=1000 * 700, fill=0)
    assert_true(g.gl.read(g.gl.tex[s], 1000, 700, Int(direct.unsafe_ptr())), "ring texture read")
    assert_true(g.gl.read(tex2, 1000, 700, Int(via.unsafe_ptr())), "dmabuf texture read: GL error " + String(g.gl.error()))
    var same = 0
    for i in range(len(direct)):
        if direct[i] == via[i]:
            same += 1
    var want = cpu_of(build_batches(page, atlas, font), atlas)
    var d = diff(want, via)
    print("   dmabuf (" + String(chr(g.gl.dmabuf.fourcc[s] & 0xFF)) + String(chr((g.gl.dmabuf.fourcc[s] >> 8) & 0xFF)) + String(chr((g.gl.dmabuf.fourcc[s] >> 16) & 0xFF))
          + String(chr((g.gl.dmabuf.fourcc[s] >> 24) & 0xFF)) + ", modifier " + hex(mod) + ", stride " + String(g.gl.dmabuf.stride[s]) + "): read back through the dmabuf,",
          len(direct) - same, "of", len(direct), "pixels differ from the ring texture; vs the CPU executor mean", round(d.mean, 4), "levels,", round(d.far, 4), "% far;",
          g.gl.dmabuf.fenced, "fenced")
    g.gl.delete(17, tex2)
    _ = fcall[c_uint](gl_proc("eglDestroyImageKHR"), dpy, image)
    g.gl.close()
    assert_true(g.gl.dmabuf.fd[s] == -1, "close() closes the dmabuf fds")
    assert_true(same == len(direct), "the dmabuf holds the ring texture's pixels")
    assert_true(d.mean <= 1.5 and d.far <= 0.5, "the dmabuf's picture differs from the CPU executor")


def two_canvases(font: Font, atlas: GlyphAtlas) raises:
    """Two .gpu() canvases on one screen (D-7561): each keeps its own layers. A page of ink (canvas 1) and a mind map
    (canvas 2) drawn in turn, twice: the second round rebuilds no layer of either, and each picture still matches the CPU
    executor. Then more canvases than GPU2D keeps: the least recently drawn is dropped, the rest stay cached."""
    var g = GPU2D()
    assert_true(g.start(False), "GPU2D.start: " + g.gl.why)
    var a = Scene(1000, 700, 1.0)
    whiteboard_big(a, 100)
    var m = mindmap_of(60)
    var b = Scene(800, 600, 1.0)
    b.is_still = True
    b.fill(0xFFFFFFFF)
    m.paint(b, font, MapView(400, 300, 0.7))
    var empty = Scene(0, 0, 1.0)
    _ = g.draw(a, empty, 1, 1000, 700)
    _ = g.draw(b, empty, 2, 800, 600)
    var sa = g.draw(a, a, 1, 1000, 700)
    var rebuilt_a = g.rebuilt
    var reused_a = g.reused
    var got_a = List[UInt32](length=1000 * 700, fill=0)
    assert_true(sa >= 0 and g.gl.read(g.gl.tex[sa], 1000, 700, Int(got_a.unsafe_ptr())), "canvas 1 again")
    var sb = g.draw(b, b, 2, 800, 600)
    var rebuilt_b = g.rebuilt
    var reused_b = g.reused
    var got_b = List[UInt32](length=800 * 600, fill=0)
    assert_true(sb >= 0 and g.gl.read(g.gl.tex[sb], 800, 600, Int(got_b.unsafe_ptr())), "canvas 2 again")
    var da = diff(cpu_of(build_batches(a, atlas, font), atlas), got_a)
    var db = diff(cpu_of(build_batches(b, atlas, font), atlas), got_b)
    print("   two canvases in turn: canvas 1 rebuilt", rebuilt_a, "reused", reused_a, "(mean", round(da.mean, 4), "levels,", round(da.far, 4),
          "% far); canvas 2 rebuilt", rebuilt_b, "reused", reused_b, "(mean", round(db.mean, 4), "levels,", round(db.far, 4), "% far); caches", g.caches())
    assert_true(rebuilt_a == 0 and reused_a == a.layers(), "canvas 1 rebuilt layers after canvas 2 drew")
    assert_true(rebuilt_b == 0 and reused_b == b.layers(), "canvas 2 rebuilt layers after canvas 1 drew")
    assert_true(da.mean <= 1.5 and da.far <= 0.5 and db.mean <= 1.5 and db.far <= 0.5, "a cached canvas's picture differs from the CPU executor")
    for owner in range(3, 11):  # (canvases 3–10: 10 canvases in all, more than GPU2D keeps)
        _ = g.draw(a, empty, owner, 1000, 700)
    assert_true(g.caches() <= 8, "GPU2D keeps at most 8 canvases' layers")
    _ = g.draw(a, a, 10, 1000, 700)
    assert_true(g.rebuilt == 0, "the canvas drawn last stays cached")
    _ = g.draw(a, a, 1, 1000, 700)
    var dropped = g.rebuilt
    var sets_before = g.next_set
    var sd = g.draw(b, empty, 11, 800, 600)  # (a new canvas: its layers go in buffer sets a dropped canvas left)
    var got_d = List[UInt32](length=800 * 600, fill=0)
    assert_true(sd >= 0 and g.gl.read(g.gl.tex[sd], 800, 600, Int(got_d.unsafe_ptr())), "canvas 11 drawn")
    var dd = diff(cpu_of(build_batches(b, atlas, font), atlas), got_d)
    print("   10 canvases: caches", g.caches(), "; the least recently drawn (canvas 1) rebuilt", dropped, "layers; a new canvas made", g.next_set - sets_before, "new buffer sets (reused a dropped canvas's): mean", round(dd.mean, 4), "levels")
    assert_true(dropped == a.layers(), "the least recently drawn canvas was dropped from the cache")
    assert_true(g.next_set == sets_before, "a new canvas reuses the buffer sets a dropped one left")
    assert_true(dd.mean <= 1.5 and dd.far <= 0.5, "a canvas drawn in reused buffer sets differs from the CPU executor")
    g.gl.close()


def map_pan(font: Font, atlas: GlyphAtlas) raises:
    """A 300-topic mind map panned at pnote's canvas size on a 1.6× screen (goal 75 review, D-7578): its layer holds
    text, whose batches depend on the zoom only (faces picked at size·k), not on where the layer sits, so a pan reuses
    the layer through its new transform instead of rebuilding every topic each frame. 30 pan frames: none rebuilds a
    layer after the first, and the last picture still matches the CPU executor's picture of that frame built whole."""
    var m = mindmap_of(300)
    var g = GPU2D()
    assert_true(g.start(False), "GPU2D.start: " + g.gl.why)
    var W = 1699
    var H = 1384
    var k = 1.6
    var prev = Scene(0, 0, 1.0)
    var rebuilt = 0
    var cpu_ns = List[Int]()
    var slot = -1
    for f in range(30):
        var s = Scene(W, H, k)
        s.is_still = True
        s.fill(0xFFFFFFFF)
        m.paint(s, font, MapView((Float64(W) / k / 2 + Float64(f) * 7.3) * k, (Float64(H) / k / 2 - Float64(f) * 4.1) * k, k))
        slot = g.draw(s, prev, 1, W, H)
        assert_true(slot >= 0, "map pan frame drawn: " + g.gl.why)
        if f > 0:
            rebuilt += g.rebuilt
            cpu_ns.append(g.batch_ns + g.render_ns)
        prev = s^
    var got = List[UInt32](length=W * H, fill=0)
    assert_true(g.gl.read(g.gl.tex[slot], W, H, Int(got.unsafe_ptr())), "map pan read back")
    var d = diff(cpu_of(build_batches(prev, atlas, font), atlas), got)
    sort(cpu_ns)
    print("   mindmap pan (300 topics, 1699x1384 at 1.6x): layers rebuilt in 29 pan frames", rebuilt, "; CPU per frame p50",
          round(Float64(cpu_ns[len(cpu_ns) // 2]) / 1e6, 3), "ms, max", round(Float64(cpu_ns[len(cpu_ns) - 1]) / 1e6, 3),
          "ms; last frame mean", round(d.mean, 4), "levels,", round(d.far, 4), "% far")
    assert_true(rebuilt == 0, "a panned mind map rebuilt its layers (text batches don't depend on where the layer sits)")
    assert_true(d.mean <= 1.5 and d.far <= 0.5, "the panned mind map differs from the CPU executor")
    g.gl.close()


def main() raises:
    var ctx = headless_gl33()
    assert_true(ctx != 0, "a headless GL 3.3 core context (EGL device platform)")
    var gl = GL2D()
    assert_true(gl.start(False), "GL2D.start: " + gl.why)
    print("gl:", gl.why)
    var font = Font()
    var atlas = GlyphAtlas(font)
    gl.upload_atlas(atlas)

    # each primitive alone (test_gpu2d's cases)
    var w = 200
    var h = 120
    var img = gradient(40, 30)
    for which in range(14):
        if which == 12:
            continue
        var sc = Scene(w, h, 1.0)
        paint_case(sc, which, font, img)
        compare(case_name(which), build_batches(sc, atlas, font), gl, atlas)

    # whiteboard
    var W = 1000
    var H = 700
    var wb = Scene(W, H, 1.0)
    whiteboard(wb)
    compare("whiteboard (200 strokes)", build_batches(wb, atlas, font), gl, atlas)
    compare_merged("whiteboard (200 strokes)", wb, gl, atlas, font)

    # canvas: Personal Note's benchmark note (or the seeded stand-in), one page and zoomed out
    var text = String()
    var have = True
    try:
        var fh = open("build/g74/bench-note.json", "r")
        text = fh.read()
        fh.close()
    except:
        have = False
    var ol = import_fabric(text, font) if have else seeded_note()
    var source = String("bench-note.json") if have else String("seeded 645-object note")
    W = 1280
    H = 800
    var canvas_scene = Scene(W, H, 1.0)
    for zoom in range(2):
        var k = 1.0 if zoom == 0 else 0.45
        var c = Scene(W, H, 1.0)
        c.fill(0xFFFFFFFF)
        ol.paint(c, font, 20, 30, Float64(W) / k, Float64(H) / k, k)
        compare("canvas (" + source + ", k " + String(k) + ")", build_batches(c, atlas, font), gl, atlas)
        compare_merged("canvas (" + source + ", k " + String(k) + ")", c, gl, atlas, font)
        if zoom == 1:
            canvas_scene = c^

    # mind map
    var m = mindmap_of(100)
    W = 1400
    H = 900
    var ms = Scene(W, H, 1.0)
    ms.is_still = True
    ms.fill(0xFFFFFFFF)
    m.paint(ms, font, MapView(Float64(W) / 2, Float64(H) / 2, 0.8))
    compare("mindmap (" + String(m.nodes()) + " topics)", build_batches(ms, atlas, font), gl, atlas)
    compare_merged("mindmap (" + String(m.nodes()) + " topics)", ms, gl, atlas, font)

    # goal 79: fonttext runs and icons on the GPU (the dynamic glyph rows, colour emoji and icons as blended images)
    for zoom in [1.0, 4.0]:
        var big = 1 if zoom == 1.0 else 2
        var ts = text_scene(480 * big, 240 * big, 1.6, zoom)
        compare("fonttext runs and icons (zoom " + String(zoom) + ")", build_batches(ts, atlas, font), gl, atlas)

    grown_page(gl, atlas, font)
    two_canvases(font, atlas)
    map_pan(font, atlas)
    dmabuf_page(atlas, font)

    # a frame's GPU time for the scenes (the judged sizes: 1440×900 windows; 1,000 strokes; 645 objects; 300 topics)
    print("frame times:")
    var big = Scene(1440, 900, 1.0)
    whiteboard_big(big, 1000)
    print("   whiteboard (1,000 strokes):", gpu_ms(gl, big, atlas, font))
    var cz = Scene(1440, 900, 1.0)
    cz.fill(0xFFFFFFFF)
    ol.paint(cz, font, 20, 30, 1440.0 / 0.45, 900.0 / 0.45, 0.45)
    print("   canvas (" + source + ", all of it at k 0.45):", gpu_ms(gl, cz, atlas, font))
    var m3 = mindmap_of(300)
    var mm = Scene(1440, 900, 1.0)
    mm.is_still = True
    mm.fill(0xFFFFFFFF)
    m3.paint(mm, font, MapView(720, 450, 0.6))
    print("   mindmap (300 topics):", gpu_ms(gl, mm, atlas, font))
    var m4 = Scene(1699, 1384, 1.6)
    m4.is_still = True
    m4.fill(0xFFFFFFFF)
    m3.paint(m4, font, MapView(850, 692, 1.0))
    print("   mindmap (300 topics) at pnote's canvas size:", gpu_ms(gl, m4, atlas, font))
    var hi = Scene(2880, 1800, 2.0)
    whiteboard_big(hi, 1000)
    print("   whiteboard (1,000 strokes) at 2×:", gpu_ms(gl, hi, atlas, font))
    gl.close()

    # the same with the fans drawn by glMultiDrawArraysIndirect (what GTK's GLES context on NVIDIA has instead of
    # glMultiDrawArrays): a mind map (polygons regrouped) and a grown page
    _ = setenv("MOJOUI_GPU2D_INDIRECT", "1", True)
    var gi = GL2D()
    assert_true(gi.start(False), "GL2D.start (indirect): " + gi.why)
    print("gl (indirect):", gi.why)
    assert_true(gi.indirect, "the indirect path (GL_ARB_multi_draw_indirect) should be on")
    gi.upload_atlas(atlas)
    compare_merged("mindmap (" + String(m.nodes()) + " topics, indirect)", ms, gi, atlas, font)
    grown_page(gi, atlas, font)
    gi.close()
    _ = setenv("MOJOUI_GPU2D_INDIRECT", "0", True)
    print("gpu2d gl: ok")
