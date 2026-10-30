# Image operations on frames (mojoui/imageops.mojo). Run: pixi run mojo run -I . tests/test_imageops.mojo
# Prints "<name>: ok" for each group and "blur 720p ms: X". Writes build/g39/imageops-text.png to look at.
from std.testing import assert_equal, assert_true

from mojoui.canvas import rgba
from mojoui.clock import now_ns
from mojoui.imageops import Frame, Edits, ImageOps
from mojoui.png import encode_png


def noisy(w: Int, h: Int) -> Frame:
    """A sharp, busy picture: pseudo-random pixels, deterministic."""
    var f = Frame(w, h)
    for i in range(w * h):
        var v = UInt32((i * 2654435761 + (i // w) * 40503) & 0xFFFFFFFF)
        f.pixels[i] = (v & 0x00FFFFFF) | 0xFF000000
    return f^


def sharpness(f: Frame, x: Int, y: Int, w: Int, h: Int) -> Int:
    """Mean absolute difference between neighbouring pixels (all three colours), times 100."""
    var total = 0
    var n = 0
    for yy in range(y, y + h):
        for xx in range(x, x + w - 1):
            var a = f.pixels[yy * f.width + xx]
            var b = f.pixels[yy * f.width + xx + 1]
            for s in range(3):
                total += abs(Int((a >> UInt32(8 * s)) & 0xFF) - Int((b >> UInt32(8 * s)) & 0xFF))
            n += 3
    return total * 100 // n


def max_diff(a: Frame, b: Frame) -> Int:
    var m = 0
    for i in range(len(a.pixels)):
        for s in range(4):
            m = max(m, abs(Int((a.pixels[i] >> UInt32(8 * s)) & 0xFF) - Int((b.pixels[i] >> UInt32(8 * s)) & 0xFF)))
    return m


def test_blur(mut ops: ImageOps) raises:
    var f = noisy(400, 300)
    var before = f.copy()
    var s0 = sharpness(f, 100, 80, 120, 120)
    ops.blur_box(f, 100, 80, 120, 120, 10)
    var s1 = sharpness(f, 100, 80, 120, 120)
    assert_true(s1 * 5 < s0, "sharpness inside must drop below a fifth: " + String(s0) + " -> " + String(s1))
    var outside = 0
    for y in range(300):
        for x in range(400):
            var inside = 100 <= x < 220 and 80 <= y < 200
            if not inside and f.pixels[y * 400 + x] != before.pixels[y * 400 + x]:
                outside += 1
    assert_equal(outside, 0, "pixels outside the box changed")
    # a box hanging over the edge is cut to the frame
    ops.blur_box(f, 350, 250, 120, 120, 6)
    print("blur: ok (sharpness " + String(s0) + " -> " + String(s1) + ")")


def test_crop(mut ops: ImageOps) raises:
    var f = noisy(400, 300)
    var c = ops.crop(f, 50, 40, 64, 32)
    assert_equal(c.width, 64)
    assert_equal(c.height, 32)
    for y in range(32):
        for x in range(64):
            assert_equal(c.pixels[y * 64 + x], f.pixels[(40 + y) * 400 + 50 + x])
    var half = ops.crop(f, 0, 0, 400, 300, 200, 150)  # nearest: the pixel at the centre of each 2×2
    assert_equal(half.pixels[10 * 200 + 20], f.pixels[21 * 400 + 41])
    var flat = Frame(100, 100, rgba(10, 200, 90))
    var thumb = ops.crop(flat, 10, 10, 80, 80, 33, 21, bilinear=True)
    assert_equal(thumb.width, 33)
    for p in thumb.pixels:
        assert_equal(p, rgba(10, 200, 90))
    var edge = ops.crop(f, 380, 280, 100, 100)  # cut to the frame
    assert_equal(edge.width, 20)
    assert_equal(edge.height, 20)
    print("crop: ok")


def test_text(mut ops: ImageOps) raises:
    var base = Frame(420, 150, rgba(70, 90, 120))
    var f = base.copy()
    var edits = Edits()
    ops.text(edits, 20, 20, "SHP-00417", 28, rgba(255, 255, 255), rgba(0, 0, 0, 170))
    ops.text(edits, 20, 80, "Dock 4 · 12:07", 22, rgba(255, 220, 60))
    edits.outline_rect(250, 20, 140, 110, rgba(255, 60, 60), 3, 8)
    edits.fill_rect(260, 30, 40, 20, rgba(60, 255, 120, 128), 4)
    ops.apply(f, edits)
    # changed pixels: only inside the union of the four boxes, and plenty of them
    var changed = 0
    var outside = 0
    var white = 0
    for y in range(150):
        for x in range(420):
            if f.pixels[y * 420 + x] != base.pixels[y * 420 + x]:
                changed += 1
                var in_caption = 20 <= x < 20 + 250 and 20 <= y < 20 + 58
                var in_second = 20 <= x < 20 + 230 and 80 <= y < 80 + 50
                var in_rect = 250 <= x < 253 + 140 and 20 <= y < 23 + 110
                if not (in_caption or in_second or in_rect):
                    outside += 1
            if f.pixels[y * 420 + x] == rgba(255, 255, 255):
                white += 1
    assert_equal(outside, 0, "pixels changed outside the boxes")
    assert_true(changed > 2000, "too few changed pixels: " + String(changed))
    assert_true(white > 150, "too few solid white glyph pixels: " + String(white))
    # the pill darkened its background: a corner-ish pixel inside the pill but away from glyphs
    var p = f.pixels[(20 + 3) * 420 + 20 + 40]
    assert_true(Int(p & 0xFF) < 60, "pill should darken the background, red was " + String(Int(p & 0xFF)))
    # the outline is solid on its edge and leaves the middle alone
    assert_equal(f.pixels[75 * 420 + 251], rgba(255, 60, 60))
    assert_equal(f.pixels[100 * 420 + 320], rgba(70, 90, 120))
    with open("build/g39/imageops-text.png", "w") as out:
        out.write_bytes(Span(encode_png(f.pixels, 420, 150)))
    print("text: ok (" + String(changed) + " pixels changed, saved build/g39/imageops-text.png)")


def all_edits(ops: ImageOps) -> Edits:
    return Edits()


def same_edits(mut ops: ImageOps, mut e: Edits):
    e.blur(30, 30, 100, 90, 7)
    e.blur(120, 100, 90, 90, 3)  # overlaps the first: a second wave
    ops.text(e, 20, 200, "Pallet 17 OK", 24, rgba(255, 255, 255), rgba(20, 20, 20, 200))
    ops.text(e, 200, 20, "plain text", 18, rgba(250, 230, 40))
    e.outline_rect(60.5, 40.25, 130.5, 100.5, rgba(255, 0, 80, 220), 2.5, 9)
    e.fill_rect(220, 150, 50, 40, rgba(0, 120, 255, 100), 12)


def test_gpu_equals_cpu() raises:
    var gpu = ImageOps(True)
    var cpu = ImageOps(False)
    assert_true(gpu.on_gpu(), "this check needs the GPU")
    assert_true(not cpu.on_gpu(), "ImageOps(False) must be the CPU path")
    var a = noisy(320, 240)
    var b = a.copy()
    var ea = Edits()
    var eb = Edits()
    same_edits(gpu, ea)
    same_edits(cpu, eb)
    gpu.apply(a, ea)
    cpu.apply(b, eb)
    var d = max_diff(a, b)
    assert_true(d <= 1, "edits differ by " + String(d))
    var src = noisy(320, 240)
    for bil in [False, True]:
        for size in [(77, 53), (400, 300), (16, 9)]:
            var g = gpu.crop(src, 13, 7, 200, 150, size[0], size[1], bil)
            var c = cpu.crop(src, 13, 7, 200, 150, size[0], size[1], bil)
            var dd = max_diff(g, c)
            assert_true(dd <= 1, "crop differs by " + String(dd))
    print("gpu equals cpu: ok (max channel difference " + String(d) + ", on " + gpu.gpu.name + ")")


def test_speed(mut ops: ImageOps) raises:
    var f = noisy(1280, 720)
    var edits = Edits()
    edits.blur(100, 80, 120, 120, 12)
    edits.blur(400, 200, 120, 120, 12)
    edits.blur(700, 300, 130, 110, 12)
    edits.blur(1000, 500, 120, 120, 12)
    for _ in range(10):
        ops.apply(f, edits)
    var times = List[Float64]()
    for _ in range(61):
        ops.apply(f, edits)
        times.append(ops.millis)
    sort(times)
    print("blur 720p ms: " + String(times[30]))


def main() raises:
    var ops = ImageOps()
    test_blur(ops)
    test_crop(ops)
    test_text(ops)
    test_gpu_equals_cpu()
    test_speed(ops)
