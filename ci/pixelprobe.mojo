# Which pixel kernels does MAX's Metal path compile (D-5311)? The fractal's kernel failed on the Mac runner with
# "Failed to create compute pipeline state (GPU machine code generation)". Each variant here is launched on its own and
# prints OK or FAIL with the error, from the simplest kernel to the fractal itself. Then the IOSurface-sized wrap.
#   pixi run mojo run -I . -D MOJOUI_MAC_GPU --target-accelerator metal:1 ci/mac/pixelprobe.mojo
from max.gpu import global_idx
from max.gpu.host import DeviceContext
from std.math import ceildiv
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from mojoui.gpu import Gpu, Params


def k_1d(dst: UnsafePointer[UInt32, MutAnyOrigin], n: Int32):
    var i = Int(global_idx.x)
    if i < Int(n):
        dst.unsafe_offset(i)[] = UInt32(i)


def k_2d(dst: UnsafePointer[UInt32, MutAnyOrigin], w: Int32, h: Int32):
    var x = Int(global_idx.x)
    var y = Int(global_idx.y)
    if x < Int(w) and y < Int(h):
        dst.unsafe_offset(y * Int(w) + x)[] = UInt32(x + y)


def k_simd(dst: UnsafePointer[UInt32, MutAnyOrigin], n: Int32, p: Params):
    var i = Int(global_idx.x)
    if i < Int(n):
        dst.unsafe_offset(i)[] = UInt32(Int(p[0]) + i)


def solid(x: Int, y: Int, w: Int, h: Int, p: Params) -> UInt32:
    return UInt32(0xFF0000FF)


def gradient(x: Int, y: Int, w: Int, h: Int, p: Params) -> UInt32:
    return UInt32(x % 256) | (UInt32(y % 256) << 8) | 0xFF000000


def float_to_uint(x: Int, y: Int, w: Int, h: Int, p: Params) -> UInt32:
    var t = Float32(x) / Float32(w)
    return UInt32(t * 255) | 0xFF000000


def loop_int(x: Int, y: Int, w: Int, h: Int, p: Params) -> UInt32:
    var zx = Float32(0)
    var i = 0
    while i < Int(p[3]) and zx < 4.0:
        zx = zx * zx + Float32(x) / Float32(w)
        i += 1
    return UInt32(i % 256) | 0xFF000000


def loop_int32(x: Int, y: Int, w: Int, h: Int, p: Params) -> UInt32:
    var zx = Float32(0)
    var i = Int32(0)
    var limit = Int32(p[3])
    while i < limit and zx < 4.0:
        zx = zx * zx + Float32(x) / Float32(w)
        i += 1
    return UInt32(i % 256) | 0xFF000000


def mandelbrot(x: Int, y: Int, w: Int, h: Int, p: Params) -> UInt32:
    """examples/gpu's, as it is."""
    var cx = p[1] + (Float32(x) - Float32(w) / 2) * p[0] / Float32(h)
    var cy = p[2] + (Float32(y) - Float32(h) / 2) * p[0] / Float32(h)
    var zx = Float32(0)
    var zy = Float32(0)
    var i = 0
    var limit = Int(p[3])
    while i < limit and zx * zx + zy * zy < 4.0:
        var t = zx * zx - zy * zy + cx
        zy = 2.0 * zx * zy + cy
        zx = t
        i += 1
    if i == limit:
        return UInt32(0xFF000000)
    var t = Float32(i) / Float32(limit)
    var r = UInt32(9.0 * (1 - t) * t * t * t * 255)
    var g = UInt32(15.0 * (1 - t) * (1 - t) * t * t * 255)
    var b = UInt32(8.5 * (1 - t) * (1 - t) * (1 - t) * t * 255)
    return r | (g << 8) | (b << 16) | (UInt32(255) << 24)


def try_render[f: def(Int, Int, Int, Int, Params) thin -> UInt32](name: String):
    var gpu = Gpu()
    if not gpu.available():
        print("FAIL", name, ": no GPU (" + gpu.name + ")")
        return
    try:
        var r = gpu.render[f](64, 48, Params(2.6, -0.7436439, 0.1318259, 256))
        print("OK  ", name, "first pixel", hex(Int(r.pixels[0])), "last", hex(Int(r.pixels[len(r.pixels) - 1])))
    except e:
        print("FAIL", name, ":", String(e).split("\n")[0])


def main() raises:
    var count = DeviceContext.number_of_devices()
    print("DEVICES:", count)
    if count == 0:
        return
    var ctx = DeviceContext()
    print("DEVICE:", ctx.name(), "·", ctx.api())
    var buf = ctx.enqueue_create_buffer[DType.uint32](64 * 48)
    try:
        ctx.enqueue_function[k_1d](buf.unsafe_ptr(), Int32(3072), grid_dim=12, block_dim=256)
        ctx.synchronize()
        print("OK   1d kernel")
    except e:
        print("FAIL 1d kernel:", String(e).split("\n")[0])
    try:
        ctx.enqueue_function[k_2d](buf.unsafe_ptr(), Int32(64), Int32(48), grid_dim=(4, 3), block_dim=(16, 16))
        ctx.synchronize()
        print("OK   2d grid")
    except e:
        print("FAIL 2d grid:", String(e).split("\n")[0])
    try:
        ctx.enqueue_function[k_simd](buf.unsafe_ptr(), Int32(3072), Params(5, 0, 0, 0), grid_dim=12, block_dim=256)
        ctx.synchronize()
        print("OK   SIMD[float32, 4] argument")
    except e:
        print("FAIL SIMD[float32, 4] argument:", String(e).split("\n")[0])
    try_render[solid]("render: solid")
    try_render[gradient]("render: Int maths")
    try_render[float_to_uint]("render: Float32 to UInt32")
    try_render[loop_int]("render: while loop, Int counter")
    try_render[loop_int32]("render: while loop, Int32 counter")
    try_render[mandelbrot]("render: mandelbrot")
    # the wrap: host memory of whole 16 KB pages, page-aligned (what an IOSurface rounded up gives)
    comptime PAGE = 16384
    var bytes = ceildiv(480 * 320 * 4, PAGE) * PAGE
    var raw = unsafe_alloc[UInt8](bytes + PAGE)
    var base = (Int(raw) + PAGE - 1) // PAGE * PAGE
    try:
        var wrapped = ctx.wrap_host_memory(Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=base), bytes // 4)
        ctx.enqueue_function[k_1d](wrapped.unsafe_ptr(), Int32(480 * 320), grid_dim=ceildiv(480 * 320, 256), block_dim=256)
        ctx.synchronize()
        var p = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=base)
        print("OK   wrap_host_memory of", bytes, "bytes: wrote", Int(p.unsafe_offset(1000)[]), "at 1000 (want 1000)")
    except e:
        print("FAIL wrap_host_memory:", String(e).split("\n")[0])
