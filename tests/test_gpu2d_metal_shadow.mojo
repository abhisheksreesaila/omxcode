# Goal 80 M7: Metal draws test_gpu2d_shadow's cases within the same bounds of the CPU executor (mean ≤ 1.5 levels, ≤ 0.5 %
# of pixels more than 40 off): blurs 0–32 and radii 0–24, translucent and overlapping over content, and clipped in a
# scaled, moved layer. A Mac only; built as tests/test_gpu2d_metal.mojo is.
from std.testing import assert_true

from mojoui.canvas import Surface, rgba
from mojoui.text import Font
from mojoui.scene import Scene
from mojoui.gpu2d import GlyphAtlas, build_batches, execute_cpu
from mojoui.gpu2d_metal import Metal2D, read_iosurface
from mojoui.hosts.apple_canvas import io_surface
from tests.test_gpu2d import diff


def check(name: String, sc: Scene, bare: Scene, mut mtl: Metal2D, atlas: GlyphAtlas, font: Font) raises:
    var f = build_batches(sc, atlas, font)
    var want = List[UInt32](length=sc.w * sc.h, fill=0)
    var s = Surface(Int(want.unsafe_ptr()), sc.w, sc.h, sc.k)
    execute_cpu(f, atlas, s)
    var io = io_surface(sc.w, sc.h)
    assert_true(mtl.render(f, io, sc.w, sc.h), name + ": Metal didn't draw it")
    var got = read_iosurface(io, sc.w, sc.h)
    var d = diff(want, got)
    # (not a comparison of nothing with nothing: the shadows ink pixels, and the same scene without them differs)
    assert_true(mtl.render(build_batches(bare, atlas, font), io, sc.w, sc.h), "bare")
    var off = diff(want, read_iosurface(io, sc.w, sc.h))
    var exact = 0
    for i in range(len(want)):
        if (want[i] & 0xFFFFFF) == (got[i] & 0xFFFFFF):
            exact += 1
    print("  Metal vs CPU", name, ": mean", round(d.mean, 5), "levels,", round(d.far, 4), "% far;", len(want) - exact, "of", len(want),
          "pixels differ at all; without the shadows", round(off.mean, 2), "levels off")
    assert_true(off.mean > 1.0, name + ": the picture without shadows looks the same: nothing was compared")
    assert_true(d.mean <= 1.5 and d.far <= 0.5, name + ": Metal's shadow differs from the CPU executor")


def card(b: Float64, r: Float64, shadows: Bool) -> Scene:
    var sc = Scene(240, 180, 1.0)
    sc.fill(rgba(246, 245, 243))
    sc.rect(20, 20, 60, 40, rgba(40, 120, 220), 6)
    if shadows:
        sc.shadow(60, 50, 110, 70, r, b, rgba(10, 20, 30, 140))
        sc.shadow(90, 80, 80, 60, r / 2, b / 2 + 1, rgba(200, 40, 40, 90))
    sc.rect(70, 60, 90, 50, rgba(255, 255, 255), r)
    return sc^


def cards(shadows: Bool) -> Scene:
    var sc = Scene(300, 220, 1.0)
    sc.fill(rgba(255, 255, 255))
    sc.begin_layer("cards")
    sc.layer_transform(-20, 12, 1.6)
    sc.push_clip(20, 10, 120, 80)
    if shadows:
        for i in range(6):
            sc.shadow(10 + Float64(i) * 25, 20 + Float64(i % 3) * 18, 40, 30, 6, 4 + Float64(i) * 3, rgba(0, 0, 0, 60))
    sc.pop_clip()
    return sc^


def main() raises:
    var font = Font()
    var atlas = GlyphAtlas(font)
    var mtl = Metal2D(atlas)
    assert_true(mtl.ok, "no Metal: " + mtl.why)
    for b in [0.0, 2.0, 6.0, 16.0, 32.0]:
        for r in [0.0, 6.0, 24.0]:
            check("blur " + String(b) + " radius " + String(r), card(b, r, True), card(b, r, False), mtl, atlas, font)
    check("clipped, zoom 1.6", cards(True), cards(False), mtl, atlas, font)
    print("metal shadow: ok")
