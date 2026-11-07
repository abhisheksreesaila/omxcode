# mojoui.sheetjobs wakes the host (goal 62 M0): every background job kind it starts (open, chart, column, the GPU's warm-up)
# leaves one byte in the job-wake pipe when it ends, so a host that only listens to the pipe (the web host: a tab with no
# moving canvas has no frames to poll on) hears it. Before goal 62 they were started without the wake and only the frame
# poll found them.
#   scripts/mxbuild.sh tests/test_sheetjobs_wake.mojo -o build/test_sheetjobs_wake && build/test_sheetjobs_wake
from std.ffi import external_call, c_int
from std.testing import assert_true
from mojoui.clock import now_ns
from mojoui.csvio import read_csv
from mojoui.sheet import Sheet
from mojoui.shared import make_dir
from mojoui.sheetpage import SheetObject
from mojoui.jobs import wake_pipe, drain_wakes
from mojoui.sheetjobs import chart_job, column_job, open_job, warm_gpu, stopped, Job, JOB_RUNNING


def readable(fd: Int, wait_ms: Int) -> Bool:
    """poll() for up to wait_ms: the read end holds bytes (one struct pollfd: fd, then events POLLIN in the low short)."""
    var pfd = List[Int32](length=2, fill=0)
    pfd[0] = Int32(fd)
    pfd[1] = 1
    var n = external_call["poll", c_int](Int(pfd.unsafe_ptr()), Int(1), c_int(wait_ms))
    _ = len(pfd)
    return Int(n) == 1


def empty(fd: Int):
    while readable(fd, 0):
        _ = drain_wakes(fd)


def woke(fd: Int, what: String) raises:
    """The job ended (polled until it did): the pipe has its wake within 2 s (the callback runs as its thread ends)."""
    assert_true(readable(fd, 2000), what + " ended without waking the host")
    empty(fd)


def wait_for[T: Movable & Deinitable](mut job: Job[T]):
    var t0 = now_ns()
    while job.poll() == JOB_RUNNING and now_ns() - t0 < 60_000_000_000:
        pass
    while not stopped(job):
        pass


def main() raises:
    make_dir("build/test-sheetjobs-wake")
    var path = String("build/test-sheetjobs-wake/sales.csv")
    with open(path, "w") as f:
        f.write("amount,qty,region\n")
        for i in range(20000):
            f.write(String(i % 97) + ".5," + String(i % 7 + 1) + "," + ("north" if i % 3 == 0 else "south") + "\n")
    var fd = wake_pipe()
    assert_true(fd >= 0, "no wake pipe")
    var warming = warm_gpu()  # (started first, as an app's __init__ does)
    wait_for(warming)
    woke(fd, "warm_gpu")

    var opening = open_job(path)
    wait_for(opening)
    woke(fd, "open_job")
    var sheet = Sheet(read_csv(path).table)

    var charting = chart_job(sheet, SheetObject.chart(0, 2, 0, 0))  # (amount by region)
    wait_for(charting)
    woke(fd, "chart_job")

    var column = column_job(sheet, 0, True)
    wait_for(column)
    woke(fd, "column_job")
    print("test_sheetjobs_wake: ok (warm_gpu, open_job, chart_job, column_job each wake the host when they end)")
