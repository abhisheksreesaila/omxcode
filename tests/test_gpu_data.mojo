# Gpu.set_data + draw_with / render_with (the globe): a pixel function that reads the app's own data. The same function
# on the GPU and on the CPU makes the same picture, and replacing the data changes it.
# Run: pixi run mojo run -I . tests/test_gpu_data.mojo
from std.testing import assert_equal, assert_true
from mojoui.gpu import Gpu


comptime TW = 7  # a 7 × 5 "texture", then one word: an offset added to every pixel
comptime TH = 5


def sample(x: Int, y: Int, w: Int, h: Int, k: SIMD[DType.float32, 8], data: UnsafePointer[UInt32, MutAnyOrigin]) -> UInt32:
    """Nearest texel of the texture stretched over the picture, plus the data's offset word and knob 0."""
    var tx = min(x * TW // w, TW - 1)
    var ty = min(y * TH // h, TH - 1)
    return data[ty * TW + tx] + data[TW * TH] + UInt32(Int(k[0]))


def words(offset: UInt32) -> List[UInt32]:
    var out = List[UInt32]()
    for i in range(TW * TH):
        out.append(UInt32(i * 1000))
    out.append(offset)
    return out^


def main() raises:
    var gpu = Gpu()
    var cpu = Gpu(use=False)
    var empty = gpu.render_with[sample](4, 3, SIMD[DType.float32, 8](0))  # before set_data: blank, not a read of nothing
    assert_equal(len(empty.pixels), 12)
    assert_equal(empty.pixels[0], 0)
    gpu.set_data(words(7))
    cpu.set_data(words(7))
    var k = SIMD[DType.float32, 8](3, 0, 0, 0, 0, 0, 0, 0)
    var a = gpu.render_with[sample](33, 21, k)
    var b = cpu.render_with[sample](33, 21, k)
    assert_equal(len(a.pixels), 33 * 21)
    for i in range(len(a.pixels)):
        assert_equal(a.pixels[i], b.pixels[i], "pixel " + String(i))
    assert_equal(b.pixels[0], 10)  # texel 0 + offset 7 + knob 3
    assert_equal(b.pixels[33 * 21 - 1], UInt32((TW * TH - 1) * 1000 + 10))
    gpu.set_data(words(100))
    var c = gpu.render_with[sample](33, 21, k)
    assert_equal(c.pixels[0], 103, "replaced data is what's read")
    print("PASS gpu data: " + gpu.name + " and the CPU agree on 693 pixels; set_data replaces (GPU " + String(gpu.available()) + ")")
