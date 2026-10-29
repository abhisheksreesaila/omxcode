# The 100M-row streamed file's total and group-by on the CPU, the GPU and AUTO (goal 23 M1): best of three each, the
# answers compared (they must be equal), AUTO's choice and its reason printed.
#   scripts/mxbuild.sh tests/bench_stream_device.mojo -o build/bench_stream_device && build/bench_stream_device build/g20/big.parquet
from std.sys import argv
from std.testing import assert_equal
from omxcore import Frame, Query, col, sum, count, scan_parquet, gpu_available, CPU, GPU, AUTO


def run(f: Frame, device: Int, grouped: Bool, groups: Int) raises -> Tuple[Float64, List[Int], Int, String]:
    var best = 1e18
    var sums = List[Int]()
    var dev = 0
    var why = String("")
    for _ in range(3):
        var q = Query(f)
        if grouped:
            q = q^.group_by(col("region"), groups)
        var r = q^.agg(sum(col("amount")), count()).compute(device)
        best = min(best, r.milliseconds)
        sums = r.values(0)
        dev = r.device
        why = r.fallback_reason
    return (best, sums^, dev, why^)


def main() raises:
    var args = argv()
    var f = Frame(scan_parquet(String(args[1])))
    var groups = f.word_count(f.index("region"))
    var out = String("")
    for grouped in [False, True]:
        var what = "group-by" if grouped else "total"
        var cpu = run(f, CPU, grouped, groups)
        out += what + ": CPU " + String(Int(cpu[0])) + " ms"
        if gpu_available():
            var gpu = run(f, GPU, grouped, groups)
            assert_equal(gpu[1], cpu[1], what + ": the GPU's answer is the CPU's")
            out += ", GPU " + String(Int(gpu[0])) + " ms"
        var auto = run(f, AUTO, grouped, groups)
        assert_equal(auto[1], cpu[1])
        out += ", AUTO " + String(Int(auto[0])) + " ms on the " + ("GPU" if auto[2] == GPU else "CPU") + (" (" + auto[3] + ")" if auto[3] != "" else "") + "\n"
    print(out, end="")
    print("BENCH DONE")
