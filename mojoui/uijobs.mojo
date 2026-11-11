# mojoui.uijobs (was mojoui.jobs until goal 60, D-6010): background jobs (MX frame's `Job`) that wake the UI the moment they end, instead of waiting for the
# app's next poll at a display frame.
#
#   self.running = start_ui_job(StepJob(...))        # in place of mxframe.start_job
#   def jobs_message(self) -> Int: return POLL        # App: update(Event(POLL)) runs on the UI thread as soon as one ends
#
# How: the job's completion callback (mxframe.start_job_then, on the job's own thread) writes one byte to a pipe the
# host made (wake_pipe); the host watches the pipe's read end on its main loop (GTK: g_unix_fd_add; the web host: a
# thread blocking on it) and sends App.jobs_message() to update() at once. On Apple there is no pipe: the callback asks
# the app's delegate (the AppKit host's target) for `jobsEnded:` on the main run loop's next turn, in every run-loop
# mode (performSelectorOnMainThread, which any thread may call). The Mac build gives jobs threads of their own
# (scripts/build.sh: -D MXFRAME_JOB_THREADS, D-792); the iPhone's still runs a job inside start_ui_job, on the main
# thread, and UIKit has no `jobsEnded:` (the frame poll finds it).
# Nothing else crosses threads: update() reads the job's state with poll() as it always did, so an app that also polls
# on its frames (the fallback) sees the same thing either way. With no host pipe (a test, a command-line tool) the
# callback does nothing.

from std.ffi import external_call, c_int
from std.sys import CompilationTarget
from std.memory import Pointer
from omxcore import Job, JobBody, JobDone, start_job_then
from mojoui.shared import put_shared, get_shared
from mojoui import libc
from mojoui.hosts.objc import msg, cls, sel, ns_string

from mojoui.wake import SLOT_WAKE_WRITE, SLOT_WAKE_READ, libc_fn, fd_io, UIWaker


def _io(name: String, fd: Int, addr: Int, n: Int) -> Int:
    return fd_io(name, fd, addr, n)


def wake_pipe() -> Int:
    """The read end of the process's job-wake pipe (made on the first call; -1 if it can't be): a host watches it and,
    when it's readable, calls drain_wakes() and sends App.jobs_message() to update()."""
    comptime if not CompilationTarget.is_linux():
        return -1  # (Apple: no pipe; see WakeUI)
    var have = get_shared(SLOT_WAKE_READ)
    if have > 0:
        return have - 1
    var fds = List[Int32](length=2, fill=-1)
    var ok = libc.pipe(Int(fds.unsafe_ptr()))
    var r = Int(fds[0])
    var w = Int(fds[1])
    _ = len(fds)
    if Int(ok) != 0 or r < 0 or w < 0:
        return -1
    # The write end never blocks: a full pipe already means "a wake is pending", and nothing may drain it (no host
    # watching, MOJOUI_JOB_WAKE=0, an app whose jobs_message is 0), so a job's thread must not wait on write().
    # The read end stays blocking: the web host's thread waits on it. Neither end leaks into child processes.
    # (fcntl through mojoui.libc: one C function, one signature per program)
    _ = libc.fcntl(w, 4, 2048)  # F_SETFL, O_NONBLOCK (Linux: 0o4000)
    _ = libc.fcntl(w, 2, 1)  # F_SETFD, FD_CLOEXEC
    _ = libc.fcntl(r, 2, 1)
    put_shared(SLOT_WAKE_WRITE, w + 1)
    put_shared(SLOT_WAKE_READ, r + 1)
    return r


def drain_wakes(fd: Int) -> Int:
    """Reads what the pipe holds (call once each time it's readable: one read, which doesn't wait then); the wakes."""
    var buf = List[UInt8](length=4096, fill=0)
    var n = _io("read", fd, Int(buf.unsafe_ptr()), 4096)
    _ = len(buf)
    return max(n, 0)


def wake_ui():
    """Wakes the host's main loop from any thread (one byte down the pipe; nothing when no host made one)."""
    var w = WakeUI()
    w.done(0)


struct WakeUI(JobDone):
    """A completion callback that wakes the UI (mojoui.wake.UIWaker: made when the job starts, on the UI thread, so the
    job's thread only sends one wake)."""
    var waker: UIWaker

    def __init__(out self):
        self.waker = UIWaker()

    def done(mut self, state: Int):
        self.waker.wake()


def start_ui_job[B: JobBody](var body: B) -> Job[B.Out]:
    """mxframe.start_job, plus a wake of the UI when the job ends (done, failed or cancelled)."""
    return start_job_then(body^, WakeUI())
