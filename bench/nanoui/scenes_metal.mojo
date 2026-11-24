# bench/nanoui/scenes.mojo's scenes on gpu2d's Metal backend (goal 80 M7): offscreen into an IOSurface, no window, the same
# rules: 900×640 points at 2x, 300 ms of frames unmeasured, 30 warm-up frames, 300 measured, 3 runs, the run with the lowest
# median frame kept. frame = Scene build + fill_batches + merge_runs; gpu = the command buffer's GPUEndTime − GPUStartTime
# (what the rival's Metal harness reads too). Prints `OMX RESULT {json}` per scene. HC_SHOT=dir: the last frame as a PNG.
#   build flags: -Xlinker -lobjc -Xlinker -framework -Xlinker Metal -Xlinker -framework -Xlinker Foundation -Xlinker -framework -Xlinker IOSurface
from std.time import perf_counter_ns
from std.os import getenv
from std.sys import argv

from mojoui.text import Font
from mojoui.gpu2d import GlyphAtlas, Frame2D, fill_batches
from mojoui.gpu2d_merge import merge_runs
from mojoui.gpu2d_metal import Metal2D, read_iosurface
from mojoui.hosts.apple_canvas import io_surface
from mojoui.hosts.objc import msg, cls
from mojoui.png import encode_png
from bench.nanoui.scenes import build, Held, PW, PH, WARMUP, FRAMES, REPEAT, median, p95, r3


def main() raises:
    var names = List[String]()
    var args = argv()
    for i in range(1, len(args)):
        names.append(String(args[i]))
    if len(names) == 0:
        names = ["boxes", "text", "scroll", "list", "dashboard"]
    var font = Font()
    var atlas = GlyphAtlas(font)
    var mtl = Metal2D(atlas)
    if not mtl.ok:
        raise Error("no Metal: " + mtl.why)
    var held = Held(font)
    # drawn into a private (GPU-only) texture, as the rival's harness does (its newTarget); a window's is an IOSurface
    var io = 1
    if getenv("HC_TARGET") != "iosurface":
        var td = msg(cls("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", 80, PW, PH, 0)
        _ = msg(td, "setUsage:", 5)
        _ = msg(td, "setStorageMode:", 2)  # Private
        mtl.targets.append(io)
        mtl.target_tex.append(msg(mtl.device, "newTextureWithDescriptor:", td))
    else:
        io = io_surface(PW, PH)
    for n in names:
        var best = List[Float64]()
        var ops = 0
        for _ in range(REPEAT):
            var built = Frame2D()
            var f = Frame2D()
            var t = List[Float64]()
            var g = List[Float64]()
            var warm0 = perf_counter_ns()
            var wi = 0
            while perf_counter_ns() - warm0 < 300_000_000:
                var sc = build(n, wi, held, font)
                fill_batches(built, sc, atlas, font)
                merge_runs(built, f)
                _ = mtl.render(f, io, PW, PH)
                wi += 1
            for i in range(WARMUP + FRAMES):
                var t0 = perf_counter_ns()
                var sc = build(n, i, held, font)
                fill_batches(built, sc, atlas, font)
                merge_runs(built, f)
                var t1 = perf_counter_ns()
                if not mtl.render(f, io, PW, PH):
                    raise Error("render")
                if i >= WARMUP:
                    t.append(Float64(t1 - t0) / 1e6)
                    g.append(mtl.gpu_ms)
            ops = 0
            for r in f.runs:
                ops += r.count
            var t2 = t.copy()
            var g2 = g.copy()
            var got: List[Float64] = [median(t), p95(t2), median(g), p95(g2)]
            if len(best) == 0 or got[0] < best[0]:
                best = got^
        print('OMX RESULT {"scene": "' + n + '", "frame_med": ' + r3(best[0]) + ', "frame_p95": ' + r3(best[1]) + ', "gpu_med": ' + r3(best[2])
              + ', "gpu_p95": ' + r3(best[3]) + ', "instances": ' + String(ops) + "}", flush=True)
        var shot = getenv("HC_SHOT")
        if shot != "":
            var see = io_surface(PW, PH)
            var b2 = Frame2D()
            var f2 = Frame2D()
            var last = build(n, WARMUP + FRAMES - 1, held, font)
            fill_batches(b2, last, atlas, font)
            merge_runs(b2, f2)
            _ = mtl.render(f2, see, PW, PH)
            var px = read_iosurface(see, PW, PH)
            with open(shot + "/omx-metal-" + n + ".png", "w") as fh:
                fh.write_bytes(encode_png(px, PW, PH))
