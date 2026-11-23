# Goal 80 M5: the CPU executor on every core. Every race scene, goal 75's scenes and the held-out ones, drawn at 1800×1280
# (two frames each) by one thread and by 2, 3, 7 and all the cores' threads: the same picture bit for bit; and how much
# faster all the cores are (median of 7 frames each way). Prints facts; docs/goals/80-check.py judges the speed-up.
#   pixi run mojo run -O3 -I . tests/test_cpu_threads.mojo
from std.testing import assert_equal
from std.time import perf_counter_ns
from std.sys.info import num_logical_cores

from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.gpu2d import GlyphAtlas, Frame2D, build_batches, execute_cpu
from bench.nanoui.scenes import build, Held, PW, PH, K


def picture(f: Frame2D, atlas: GlyphAtlas, threads: Int) -> List[UInt32]:
    var px = List[UInt32](length=f.width * f.height, fill=0)
    var s = Surface(Int(px.unsafe_ptr()), f.width, f.height, f.scale)
    execute_cpu(f, atlas, s, threads)
    return px^


def ms_of(f: Frame2D, atlas: GlyphAtlas, threads: Int) -> Float64:
    var px = List[UInt32](length=f.width * f.height, fill=0)
    var s = Surface(Int(px.unsafe_ptr()), f.width, f.height, f.scale)
    var t = List[Float64]()
    for _ in range(7):
        var t0 = perf_counter_ns()
        execute_cpu(f, atlas, s, threads)
        t.append(Float64(perf_counter_ns() - t0) / 1e6)
    _ = len(px)
    sort(t)
    return t[3]


def main() raises:
    var font = Font()
    var atlas = GlyphAtlas(font)
    var held = Held(font)
    var names: List[String] = ["boxes", "text", "scroll", "list", "dashboard", "whiteboard", "canvas", "mindmap", "document", "table"]
    var cores = num_logical_cores()
    var same = 0
    var total = 0
    var ups = List[Float64]()
    var said = String()
    for i in range(len(names)):
        var n = names[i]
        said += " " + n
        for frame in [17, 203]:
            var f = build_batches(build(n, frame, held, font), atlas, font)
            var one = picture(f, atlas, 1)
            for t in [2, 3, 7, cores]:
                var many = picture(f, atlas, t)
                var differ = 0
                for k in range(len(one)):
                    if one[k] != many[k]:
                        differ += 1
                assert_equal(differ, 0, n + " frame " + String(frame) + " with " + String(t) + " threads")
                total += 1
                same += 1
        var f = build_batches(build(n, 203, held, font), atlas, font)
        var a = ms_of(f, atlas, 1)
        var b = ms_of(f, atlas, 0)  # (the default)
        print("  ", n, ": 1 thread", round(a, 2), "ms; the default number of threads", round(b, 2), "ms; ×", round(a / b, 2))
        if i < 5:
            ups.append(a / b)
    sort(ups)
    print("SCENES" + said)
    print("IDENTICAL " + String(same) + "/" + String(total))
    print("SPEEDUP " + String(round(ups[2], 2)))
    print("cpu threads: ok")
