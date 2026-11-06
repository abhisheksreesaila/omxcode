# Gpu.draw (D-5310): a plain pixel function drawn into a Canvas. When the host can take a GPU picture (surface.gpu_ok),
# the picture stays on the GPU: no copy to main memory, the surface's CPU memory untouched, and the texture the host
# makes from it (mojoui.present, CUDA↔GL) equals the CPU's picture byte for byte. Without gpu_ok it's copied into the
# surface; with no GPU, the same function runs on the CPU. Same pictures every way.
# Run: pixi run mojo run -I . tests/test_gpu_draw.mojo
from std.testing import assert_equal, assert_true, assert_false
from std.memory.alloc import alloc, Layout

from mojoui import Surface
from mojoui.gpu import Gpu, Params, gpu_present
from mojoui.present import Presenter, headless_gl


def rings(x: Int, y: Int, width: Int, height: Int, p: Params) -> UInt32:
    """Integer maths only, so the GPU and the CPU agree exactly."""
    var dx = x - width // 2
    var dy = y - height // 2
    var d = (dx * dx + dy * dy) // Int(p[0])
    var r = UInt32(d * 7 % 256)
    var g = UInt32((x * 3 + y) % 256)
    var b = UInt32((x ^ y) % 256)
    return 0xFF000000 | (b << 16) | (g << 8) | r


def main() raises:
    var w = 333
    var h = 197
    var p = Params(40, 0, 0, 0)
    # the CPU picture, through a GPU-less Gpu
    var cpu = Gpu(use=False)
    var want = List[UInt32](length=w * h, fill=0)
    var sc = Surface(Int(want.unsafe_ptr()), w, h, 1.0)
    cpu.draw[rings](sc, p)
    assert_false(sc.gpu_drawn)
    assert_equal(want[0], rings(0, 0, w, h, p))
    assert_equal(want[w * h - 1], rings(w - 1, h - 1, w, h, p))
    print("  no GPU: drawn on the CPU")
    if not gpu_present():
        print("SKIP the GPU part: no GPU")
        return
    var gpu = Gpu()
    assert_true(gpu.available())
    # 1. No GPU picture on offer: copied into the surface
    var copied = List[UInt32](length=w * h, fill=0)
    var s1 = Surface(Int(copied.unsafe_ptr()), w, h, 1.0)
    gpu.draw[rings](s1, p)
    assert_true(s1.gpu_drawn and s1.gpu_address == 0)
    assert_equal(gpu.read_back, 1)
    for i in range(w * h):
        assert_equal(copied[i], want[i], "GPU = CPU picture")
    print("  copied into the surface: GPU = CPU, byte for byte")
    # 2. The host takes GPU pictures: it stays there
    var gl = headless_gl(gpu.device)
    assert_true(gl != 0, "a GL context on CUDA device " + String(gpu.device))
    var pp = alloc(Layout[Presenter].single()).unsafe_leak()
    pp.unsafe_write(Presenter())
    assert_true(pp[].start(), pp[].why)
    var none = List[UInt32](length=w * h, fill=0)
    var s2 = Surface(Int(none.unsafe_ptr()), w, h, 1.0)
    s2.gpu_ok = True
    gpu.draw[rings](s2, p)
    assert_true(s2.gpu_drawn and s2.gpu_address != 0, "the picture stayed on the GPU")
    assert_equal(s2.gpu_device, pp[].device)
    assert_equal(gpu.read_back, 1, "no copy to main memory")
    assert_equal(gpu.handed, 1)
    for i in range(w * h):
        assert_equal(none[i], UInt32(0), "the surface's CPU memory was never written")
    var slot = pp[].acquire(w, h)
    assert_true(slot >= 0)
    assert_true(pp[].copy_in(slot, s2.gpu_address, w, h), "CUDA → GL copy: " + pp[].why)
    _ = pp[].settle(slot)
    var got = List[UInt32](length=w * h, fill=0)
    assert_true(pp[].read_slot(slot, Int(got.unsafe_ptr())))
    for i in range(w * h):
        assert_equal(got[i], want[i], "GL texture = CPU picture, byte for byte")
    print("  left on the GPU, shown through a GL texture: = CPU picture, byte for byte, no copy to main memory")
    # 3. A bigger canvas next frame (the buffer grows), still right
    var w2 = 1920
    var h2 = 1080
    var none2 = List[UInt32](length=w2 * h2, fill=0)
    var s3 = Surface(Int(none2.unsafe_ptr()), w2, h2, 1.0)
    s3.gpu_ok = True
    gpu.draw[rings](s3, p)
    var slot2 = pp[].acquire(w2, h2)
    assert_true(pp[].copy_in(slot2, s3.gpu_address, w2, h2), pp[].why)
    _ = pp[].settle(slot2)
    var got2 = List[UInt32](length=w2 * h2, fill=0)
    assert_true(pp[].read_slot(slot2, Int(got2.unsafe_ptr())))
    for y in range(h2):
        for x in range(w2):
            assert_equal(got2[y * w2 + x], rings(x, y, w2, h2, p), "1920×1080: GL texture = CPU picture")
    print("  1920×1080 on the GPU: = CPU picture, byte for byte")
    # 4. Back down to a small canvas (the big buffer reused): still right
    var none3 = List[UInt32](length=w * h, fill=0)
    var s4 = Surface(Int(none3.unsafe_ptr()), w, h, 1.0)
    s4.gpu_ok = True
    gpu.draw[rings](s4, p)
    var slot3 = pp[].acquire(w, h)
    assert_true(pp[].copy_in(slot3, s4.gpu_address, w, h), pp[].why)
    _ = pp[].settle(slot3)
    var got3 = List[UInt32](length=w * h, fill=0)
    assert_true(pp[].read_slot(slot3, Int(got3.unsafe_ptr())))
    for i in range(w * h):
        assert_equal(got3[i], want[i], "smaller again: GL texture = CPU picture")
    print("  back to 333×197 in the same buffer: = CPU picture, byte for byte")
    # 5. An empty canvas (no size yet): nothing drawn, the GPU kept
    var s5 = Surface(0, 0, 0, 1.0)
    s5.gpu_ok = True
    gpu.draw[rings](s5, p)
    assert_true(gpu.available() and s5.gpu_address == 0, "a 0×0 canvas draws nothing and keeps the GPU")
    pp[].close()
    _ = len(want)
    _ = len(none)
    _ = len(none2)
    _ = len(none3)
    print("PASS")
