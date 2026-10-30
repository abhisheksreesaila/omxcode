# mojoui.jobs and mojoui.geometry without a host: wake_ui() before any pipe does nothing; wake_pipe() makes one pipe
# (the same read end every call); a job started with start_ui_job leaves a wake in it when it ends; 100,000 wakes
# nobody drains never block the waker (the write end is non-blocking: a full pipe means a wake is pending); and
# rect_of() answers [] when no host registered a lookup.
#   scripts/mxbuild.sh tests/test_jobs.mojo -o build/test_jobs && build/test_jobs
from std.ffi import external_call, c_int
from std.testing import assert_equal, assert_true
from mxframe import JobBody, JobCtl, JOB_RUNNING
from mojoui.jobs import wake_pipe, drain_wakes, wake_ui, start_ui_job
from mojoui.geometry import rect_of


struct Sum(JobBody):
    comptime Out = Int
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    def run(mut self, ctl: JobCtl) raises -> Int:
        var s = 0
        for k in range(self.n):
            s += k
        return s


def readable(fd: Int) -> Bool:
    """poll() with no wait: the read end holds bytes (one struct pollfd: fd, then events POLLIN in the low short)."""
    var pfd = List[Int32](length=2, fill=0)
    pfd[0] = Int32(fd)
    pfd[1] = 1
    var n = external_call["poll", c_int](Int(pfd.unsafe_ptr()), Int(1), c_int(0))
    _ = len(pfd)
    return Int(n) == 1


def main() raises:
    wake_ui()  # (no pipe yet: nothing to write to, nothing happens)
    assert_equal(len(rect_of("anything")), 0)

    var r = wake_pipe()
    assert_true(r >= 0, "wake_pipe made no pipe")
    assert_equal(wake_pipe(), r)

    var job = start_ui_job(Sum(1000))
    while job.poll() == JOB_RUNNING:
        pass
    assert_equal(job.result(), 499500)
    assert_true(drain_wakes(r) >= 1, "the job ended without a wake")  # (waits for the callback if it's still to come)
    assert_true(not readable(r), "one job, more than one wake")

    for _ in range(100_000):  # (more than a pipe holds: a blocking write end would hang here)
        wake_ui()
    var got = 0
    while readable(r):  # (the read end blocks: read only what's there)
        got += drain_wakes(r)
    assert_true(got >= 4096 and got < 100_000, "a full pipe should keep what it holds and drop the rest")

    print("test_jobs: ok (no pipe, one pipe, a job's wake, 100,000 undrained wakes never block, rect_of with no host)")
