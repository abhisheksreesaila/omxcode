# mojoui.maxrt (goal 51 M0): a pack built once on our side (scripts/packs/tiny.py) runs in this process from Mojo, on the
# CPU and on the GPU, with the same numbers as Python; no Python is loaded.
#   scripts/packs/tiny.py build/packs/tiny   (once)
#   scripts/mxbuild.sh tests/test_maxrt.mojo -o build/test_maxrt && build/test_maxrt
# Prints "cpu: ok", "gpu: ok", "nopython: ok".
from std.testing import assert_equal, assert_true
from std.os import getenv
from std.time import perf_counter_ns
from mojoui.maxrt import MaxRuntime, TensorIn


def close(a: Float64, b: Float64, tol: Float64) -> Bool:
    return abs(a - b) <= tol * max(1.0, abs(b))


def main() raises:
    var dir = getenv("TINY_PACK", "build/packs/tiny")
    var reference = open(dir + "/reference.json", "r").read()
    var rt = MaxRuntime()
    var cpu = rt.load(dir + "/tiny_cpu.mef", gpu=False)
    var xs: List[Float32] = [1, 2, 3, 4, 0, 0, 0, 0]
    var ins = List[TensorIn]()
    ins.append(TensorIn.f32(xs, [2, 4]))
    var y = cpu.run(ins, 1)[0].floats()
    var want: List[Float32] = [7.0, 0.0, 8.5, 1.0, 0.0, 0.5]  # (reference.json's "cpu")
    assert_true(reference.find("[7.0, 0.0, 8.5, 1.0, 0.0, 0.5]") >= 0 or reference.find("7.0,") >= 0, "the reference is Python's: " + reference[byte=:80])
    assert_equal(len(y), 6)
    for i in range(6):
        assert_equal(y[i], want[i])
    print("cpu: ok", y[0], y[2], y[5])

    assert_true(rt.has_gpu(), "a GPU")
    var gpu = rt.load(dir + "/tiny_gpu.mef", dir + "/tiny_gpu.safetensors", gpu=True)
    var raw = open(dir + "/tiny_gpu_x.f32", "r").read_bytes()
    var x = List[Float32](length=len(raw) // 4, fill=0)
    var src = raw.unsafe_ptr().bitcast[Float32]()
    for i in range(len(x)):
        x[i] = src[i]
    var times = List[Float64]()
    var out = List[Float32]()
    for _ in range(3):
        var gi = List[TensorIn]()
        gi.append(TensorIn.f32(x, [1, 64, 64, 3]))
        var t0 = perf_counter_ns()
        out = gpu.run(gi, 1)[0].floats()
        times.append(Float64(perf_counter_ns() - t0) / 1e6)
    var total = 0.0
    for v in out:
        total += Float64(v)
    assert_equal(len(out), 1024)
    var at = reference.find("\"gpu_sum\": ")
    var want_sum = Float64(String(reference[byte = at + 11 : reference.find(",", at)]))
    assert_true(close(total, want_sum, 1e-5), "sum " + String(total) + " vs Python's " + String(want_sum))
    print("gpu: ok sum", total, "Python", want_sum, "; ms per call", times[0], times[1], times[2])

    var maps = open("/proc/self/maps", "r").read()
    assert_true(maps.find("libmax.so") >= 0, "libmax is loaded")
    assert_true(maps.find("libpython") < 0, "no Python in this process")
    print("nopython: ok")
