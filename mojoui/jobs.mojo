# mojoui.jobs: background jobs (MX frame's `Job`) that wake the UI the moment they end, instead of waiting for the
# app's next poll at a display frame.
#
#   self.running = start_ui_job(StepJob(...))        # in place of mxframe.start_job
#   def jobs_message(self) -> Int: return POLL        # App: update(Event(POLL)) runs on the UI thread as soon as one ends
#
# How: the job's completion callback (mxframe.start_job_then, on the job's own thread) writes one byte to a pipe the
# host made (wake_pipe); the host watches the pipe's read end on its main loop (GTK: g_unix_fd_add; the web host: a
# thread blocking on it) and sends App.jobs_message() to update() at once. On Apple there are no job threads (the
# engine's serial build runs a job inside start_ui_job, on the main thread) and no pipe: the callback asks the app's
# delegate (the AppKit host's target) for `jobsEnded:` on the next main run-loop turn, in every run-loop mode.
# Nothing else crosses threads: update() reads the job's state with poll() as it always did, so an app that also polls
# on its frames (the fallback) sees the same thing either way. With no host pipe (a test, a command-line tool) the
# callback does nothing.

from std.ffi import external_call, c_int
from std.sys import CompilationTarget
from std.memory import Pointer
from mxframe import Job, JobBody, JobDone, start_job_then
from mojoui.shared import put_shared, get_shared
from mojoui.hosts.objc import msg, cls, sel, ns_string

comptime SLOT_WAKE_WRITE = 90  # mojoui.shared slots: the pipe's ends + 1 (0: none yet)
comptime SLOT_WAKE_READ = 91


def _libc(name: String) -> Int:
    """A libc function's address (looked up: the standard library declares read() and write() its own way)."""
    var n = name
    var anywhere = -2 if CompilationTarget.is_macos() else 0  # RTLD_DEFAULT
    return external_call["dlsym", Int](anywhere, n.as_c_string_span())


def _io(name: String, fd: Int, addr: Int, n: Int) -> Int:
    var f = _libc(name)
    if f == 0:
        return -1
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=f)
    var call = Pointer(to=raw).unsafe_bitcast[def(c_int, Int, Int) thin abi("C") -> Int]()[]
    return call(c_int(fd), addr, n)


def wake_pipe() -> Int:
    """The read end of the process's job-wake pipe (made on the first call; -1 if it can't be): a host watches it and,
    when it's readable, calls drain_wakes() and sends App.jobs_message() to update()."""
    comptime if not CompilationTarget.is_linux():
        return -1  # (Apple: no pipe; see WakeUI)
    var have = get_shared(SLOT_WAKE_READ)
    if have > 0:
        return have - 1
    var fds = List[Int32](length=2, fill=-1)
    var ok = external_call["pipe", c_int](Int(fds.unsafe_ptr()))
    var r = Int(fds[0])
    var w = Int(fds[1])
    _ = len(fds)
    if Int(ok) != 0 or r < 0 or w < 0:
        return -1
    # The write end never blocks: a full pipe already means "a wake is pending", and nothing may drain it (no host
    # watching, MOJOUI_JOB_WAKE=0, an app whose jobs_message is 0), so a job's thread must not wait on write().
    # The read end stays blocking: the web host's thread waits on it. Neither end leaks into child processes.
    # (fcntl declared as mojoui.http_socket declares it, variadic: one C function, one signature per program)
    _ = external_call["fcntl", c_int, num_fixed_args=2](c_int(w), c_int(4), c_int(2048))  # F_SETFL, O_NONBLOCK (Linux: 0o4000)
    _ = external_call["fcntl", c_int, num_fixed_args=2](c_int(w), c_int(2), c_int(1))  # F_SETFD, FD_CLOEXEC
    _ = external_call["fcntl", c_int, num_fixed_args=2](c_int(r), c_int(2), c_int(1))
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
    """A completion callback that wakes the UI. The pipe is looked up when the job starts (on the UI thread), so the
    job's thread only writes a byte."""
    var fd: Int

    def __init__(out self):
        self.fd = get_shared(SLOT_WAKE_WRITE) - 1

    def done(mut self, state: Int):
        comptime if not CompilationTarget.is_linux():  # (Apple: on the main thread already; the host's turn comes next)
            var target = msg(msg(cls("NSApplication"), "sharedApplication"), "delegate")
            var ended = sel("jobsEnded:")
            if target != 0 and msg(target, "respondsToSelector:", ended) != 0:
                var modes = msg(cls("NSArray"), "arrayWithObject:", ns_string("kCFRunLoopCommonModes"))
                _ = msg(target, "performSelectorOnMainThread:withObject:waitUntilDone:modes:", ended, 0, 0, modes)
            return
        if self.fd >= 0:
            var b = List[UInt8](length=1, fill=1)
            _ = _io("write", self.fd, Int(b.unsafe_ptr()), 1)  # (-1 when the pipe is full: a wake is pending already)
            _ = len(b)


def start_ui_job[B: JobBody](var body: B) -> Job[B.Out]:
    """mxframe.start_job, plus a wake of the UI when the job ends (done, failed or cancelled)."""
    return start_job_then(body^, WakeUI())
