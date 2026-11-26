# Goal 80 M3: no per-frame waste on the GPU. GL2D counts texture uploads (and their bytes), buffer stores (re)allocated
# and render targets allocated. Proves, in a headless GL 3.3 context:
#   (a) a scene (rects, text runs in several faces, an image, polygons) drawn twice: the second frame uploads no texture
#       and allocates nothing (no buffer store, no target);
#   (b) the same scene with one glyph never drawn before: only that glyph's rows of the atlas go up;
#   (c) instance data goes up once per frame: each buffer written exactly once, in place into the store it has (D-8019),
#       no glBufferData;
#   (d) the picture is still the CPU executor's (within goal 75's bounds), after the buffers were reused.
#   pixi run mojo run -I . tests/test_gpu2d_waste.mojo
from std.testing import assert_true, assert_equal
from std.os import setenv

from mojoui.canvas import rgba
from mojoui.text import Font
from mojoui.scene import Scene
from mojoui.fonttext import TextStyle, ALIGN_LEFT
from mojoui.gpu2d import GlyphAtlas, Frame2D, fill_batches, glyph_pages, DYN_ROWS
from mojoui.gpu2d_gl import GL2D, headless_gl33, F_BUFFER_DATA, F_BUFFER_SUB_DATA, F_MAP_BUFFER_RANGE, F_TEX_SUB_IMAGE_2D
from tests.test_gpu2d import gradient, diff
from tests.test_gpu2d_gl import cpu_of


def scene(extra: String, img: List[UInt32]) -> Scene:
    var sc = Scene(640, 400, 1.0)
    sc.begin_layer("page")
    sc.fill(rgba(250, 248, 244))
    for i in range(40):
        sc.rect(10 + Float64(i % 10) * 60, 10 + Float64(i // 10) * 50, 50, 40, rgba(40 + i * 5, 90, 200, 220), 6)
    sc.run(TextStyle("Geist", 400, False, 14), "Quick note 1,204.50", 20, 240, rgba(30, 30, 30), ALIGN_LEFT)
    sc.run(TextStyle("Source Serif 4", 700, False, 22), "Harbour trip", 20, 272, rgba(30, 30, 30), ALIGN_LEFT)
    sc.run(TextStyle("IBM Plex Mono", 400, False, 13), "x = 42; y = 7", 20, 300, rgba(30, 30, 30), ALIGN_LEFT)
    if extra != "":
        sc.run(TextStyle("Geist", 400, False, 31), extra, 300, 300, rgba(30, 30, 30), ALIGN_LEFT)
    sc.image(img, 40, 30, 500, 220, 80, 60)
    var pts: List[Float64] = [400, 330, 470, 390, 330, 390]
    sc.polygon(pts, rgba(200, 80, 40, 200))
    return sc^


struct Counts(ImplicitlyCopyable, Movable):
    var tex: Int
    var tex_bytes: Int
    var bufs: Int
    var targets: Int
    var buffer_data: Int
    var maps: Int
    var sub: Int

    def __init__(out self, gl: GL2D):
        self.tex = gl.tex_uploads
        self.tex_bytes = gl.tex_upload_bytes
        self.bufs = gl.buf_allocs
        self.targets = gl.target_allocs
        self.buffer_data = gl.counts[F_BUFFER_DATA]
        self.maps = gl.counts[F_MAP_BUFFER_RANGE]
        self.sub = gl.counts[F_BUFFER_SUB_DATA]


def draw(mut gl: GL2D, sc: Scene, atlas: GlyphAtlas, font: Font, tex: Int) raises -> Frame2D:
    var f = Frame2D()
    fill_batches(f, sc, atlas, font)
    assert_true(gl.render(f, tex, sc.w, sc.h), gl.why)
    gl.finish()
    return f^


def main() raises:
    var ctx = headless_gl33()
    assert_true(ctx != 0, "a headless GL 3.3 core context")
    var gl = GL2D()
    assert_true(gl.start(False), gl.why)
    gl.counting = True
    var font = Font()
    var atlas = GlyphAtlas(font)
    gl.upload_atlas(atlas)
    var img = gradient(40, 30)
    var tex = gl.make_texture(640, 400)
    # first: glyphs at many sizes fill a few hundred atlas rows (so "only the new glyph's rows" means something)
    var fill = Scene(640, 400, 1.0)
    fill.begin_layer("fill")
    for k in range(40):
        fill.run(TextStyle("Literata", 400, False, 10 + Float64(k)), "abcdefghijklmnopqrstuvwxyz0123456789", 5, 20 + Float64(k * 9), rgba(0, 0, 0), ALIGN_LEFT)
    _ = draw(gl, fill, atlas, font, tex)
    # first frame of the scene: everything goes up
    var a = scene("", img)
    _ = draw(gl, a, atlas, font, tex)
    var c1 = Counts(gl)
    # (a) the same scene again (its batches built again, as a host does each frame)
    var f2 = draw(gl, scene("", img), atlas, font, tex)
    var c2 = Counts(gl)
    print("  second frame: textures", c2.tex - c1.tex, "(", c2.tex_bytes - c1.tex_bytes, "bytes ); buffer stores", c2.bufs - c1.bufs,
          "; targets", c2.targets - c1.targets, "; glBufferData", c2.buffer_data - c1.buffer_data, "; mapped writes", c2.maps - c1.maps,
          "; sub-data", c2.sub - c1.sub)
    assert_equal(c2.tex - c1.tex, 0, "the second frame uploaded a texture")
    assert_equal(c2.bufs - c1.bufs, 0, "the second frame allocated a buffer store")
    assert_equal(c2.targets - c1.targets, 0, "the second frame allocated a render target")
    # (c) instance data once per frame, into the stores it has
    assert_equal(c2.buffer_data - c1.buffer_data, 0, "glBufferData on the second frame")
    var written = c2.maps - c1.maps + c2.sub - c1.sub
    var lists = (1 if len(f2.quads) > 0 else 0) + (1 if len(f2.glyphs) > 0 else 0)
    assert_equal(written, lists + 2, "buffer writes on the second frame: one per instance list, and the polygons' fan and covers")
    # an image whose pixels changed is sent again, once; unchanged again, it isn't
    var other = img.copy()
    other[7] = other[7] ^ 0x00FF00FF
    _ = draw(gl, scene("", other), atlas, font, tex)
    var ci = Counts(gl)
    assert_equal(ci.tex - c2.tex, 1, "a changed image goes up once")
    _ = draw(gl, scene("", other), atlas, font, tex)
    assert_equal(Counts(gl).tex - ci.tex, 0, "the same image again isn't sent")
    _ = draw(gl, scene("", img), atlas, font, tex)
    assert_equal(Counts(gl).tex - ci.tex, 1, "back to the first picture: sent again")
    c2 = Counts(gl)
    # (b) one new glyph
    var pg = glyph_pages(atlas.width)
    var used0 = pg[].used
    _ = draw(gl, scene("Ж", img), atlas, font, tex)
    var c3 = Counts(gl)
    var rows = (c3.tex_bytes - c2.tex_bytes) // atlas.width
    print("  one new glyph: textures", c3.tex - c2.tex, ";", c3.tex_bytes - c2.tex_bytes, "bytes =", rows, "atlas rows (rows in use", pg[].used, "of", DYN_ROWS, ")")
    assert_equal(c3.tex - c2.tex, 1, "one upload for the new glyph")
    assert_true(rows >= 1 and rows <= 31 + 2, "the new glyph sent " + String(rows) + " rows (its own ~31 px and the gaps at most)")
    assert_true(used0 >= 200, "the atlas should hold a few hundred rows before the new glyph (" + String(used0) + ")")
    assert_true(rows * 4 < pg[].used, "the new glyph sent " + String(rows) + " of " + String(pg[].used) + " rows in use")
    # (d) the picture after reuse
    var f4 = Frame2D()
    var last = scene("Ж", img)
    fill_batches(f4, last, atlas, font)
    assert_true(gl.render(f4, tex, 640, 400), gl.why)
    var got = List[UInt32](length=640 * 400, fill=0)
    assert_true(gl.read(tex, 640, 400, Int(got.unsafe_ptr())), "read back")
    var d = diff(cpu_of(f4, atlas), got)
    print("  picture after reuse: mean", round(d.mean, 4), "levels,", round(d.far, 4), "% far")
    assert_true(d.mean <= 1.5 and d.far <= 0.5, "the GL picture after buffer reuse differs from the CPU executor")
    # a second renderer on the same glyph pages gets every glyph, whatever the first one has synced
    var gl2 = GL2D()
    assert_true(gl2.start(False), gl2.why)
    gl2.upload_atlas(atlas)
    var tex2 = gl2.make_texture(640, 400)
    assert_true(gl2.render(f4, tex2, 640, 400), gl2.why)
    gl2.finish()
    var got2 = List[UInt32](length=640 * 400, fill=0)
    assert_true(gl2.read(tex2, 640, 400, Int(got2.unsafe_ptr())), "read back")
    var differ = 0
    for i in range(len(got)):
        if got[i] != got2[i]:
            differ += 1
    assert_equal(differ, 0, "a second renderer's picture differs")
    gl2.delete(17, tex2)
    gl.delete(17, tex)
    print("gpu2d waste: ok")
