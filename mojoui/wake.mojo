# mojoui.wake: the job-wake pipe's low-level ends, without omxcore (mojoui.uijobs builds start_ui_job on them; a plain
# worker thread, such as mojoui.framefeed's decoder, wakes the UI with wake_write). The host makes the pipe
# (mojoui.uijobs.wake_pipe) and watches its read end on its main loop; a byte down it sends App.jobs_message() to update().

from std.ffi import external_call, c_int
from std.sys import CompilationTarget
from std.memory import Pointer
from mojoui.shared import get_shared
from mojoui.hosts.objc import msg, cls, sel, fn_address

comptime SLOT_WAKE_WRITE = 90  # mojoui.shared slots: the pipe's ends + 1 (0: none yet)
comptime SLOT_WAKE_READ = 91


def libc_fn(name: String) -> Int:
    """A libc function's address (looked up: the standard library declares read() and write() its own way)."""
    var n = name
    var anywhere = -2 if CompilationTarget.is_macos() else 0  # RTLD_DEFAULT
    return external_call["dlsym", Int](anywhere, n.as_c_string_span())


def fd_io(name: String, fd: Int, addr: Int, n: Int) -> Int:
    """libc's read or write (by name) on fd: n bytes at addr; what it returns (-1: an error, or no libc)."""
    var f = libc_fn(name)
    if f == 0:
        return -1
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=f)
    var call = Pointer(to=raw).unsafe_bitcast[def(c_int, Int, Int) thin abi("C") -> Int]()[]
    return call(c_int(fd), addr, n)


def wake_write_fd() -> Int:
    """The pipe's write end, if a host made one (-1: none). Look it up on the UI thread; write from any thread."""
    return get_shared(SLOT_WAKE_WRITE) - 1


def wake_write(fd: Int):
    """One byte down the wake pipe's write end `fd` (from wake_write_fd); nothing when fd < 0. Never waits: the write
    end doesn't block, and a full pipe already means a wake is pending."""
    if fd >= 0:
        var b = List[UInt8](length=1, fill=1)
        _ = fd_io("write", fd, Int(b.unsafe_ptr()), 1)
        _ = len(b)


def _wake_on_main(target: Int) abi("C"):
    """On the main queue (dispatch_async_f): the host's jobsEnded:, as a background job's end sends it."""
    _ = msg(target, "jobsEnded:", 0)


def _wake_main_lookup(unused: Int) abi("C"):
    """On the main queue, for a waker made before the host had its delegate (an app's __init__ runs before AppKit's
    setDelegate:): the delegate looked up here, on the main thread, then jobsEnded: as _wake_on_main sends it."""
    var target = msg(msg(cls("NSApplication"), "sharedApplication"), "delegate")
    if target != 0 and msg(target, "respondsToSelector:", sel("jobsEnded:")) != 0:
        _ = msg(target, "jobsEnded:", 0)


def _app_running() -> Bool:
    """An AppKit app exists (AppKit's NSApp global is set), so its main queue is drained: read from any thread, where
    asking NSApplication would make one. No AppKit (a test under `mojo run`, a web server, UIKit): nothing to wake."""
    var addr = libc_fn("NSApp")
    return addr != 0 and Pointer[Int, MutUntrackedOrigin](unsafe_from_address=addr)[] != 0


def _call_c(name: String, a: Int, b: Int, c: Int):
    """A C function of three pointer-sized arguments, looked up by name (dispatch_async_f: no link-time symbol)."""
    var f = libc_fn(name)
    if f == 0:
        return
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=f)
    var call = Pointer(to=raw).unsafe_bitcast[def(Int, Int, Int) thin abi("C") -> NoneType]()[]
    call(a, b, c)


struct UIWaker(Copyable, Movable):
    """Wakes the host's main loop from any thread, the way each host listens: on Linux a byte down the wake pipe, on a
    Mac `jobsEnded:` on the main dispatch queue (AppKit watches no pipe). Made on the UI thread (it looks up the pipe, and
    on a Mac the delegate), used from a worker's; plain values, nothing to release. Before it lived in mojoui.uijobs only,
    so a FrameFeed's video never reached a Mac's screen (goal 58)."""
    var fd: Int
    var target: Int  # Apple: the delegate that answers jobsEnded: (0: none)

    def __init__(out self):
        self.fd = wake_write_fd()
        self.target = 0
        comptime if not CompilationTarget.is_linux():
            var target = msg(msg(cls("NSApplication"), "sharedApplication"), "delegate")
            if target != 0 and msg(target, "respondsToSelector:", sel("jobsEnded:")) != 0:
                self.target = target  # (the host's target: it lives as long as the process, so it isn't retained)

    def __init__(out self, fd: Int, target: Int):
        """A waker from values another UIWaker found on the UI thread (a worker that keeps them in its own words)."""
        self.fd = fd
        self.target = target

    def wake(self):
        """From any thread: the host's main loop looks again (App.jobs_message to update())."""
        comptime if not CompilationTarget.is_linux():
            # the main dispatch queue (AppKit drains it in every run-loop mode): from a raw pthread,
            # performSelectorOnMainThread:… never arrived (a FrameFeed's probe on the owner's Mac, goal 58)
            if self.target != 0:
                _call_c("dispatch_async_f", libc_fn("_dispatch_main_q"), self.target, fn_address(_wake_on_main))
            elif _app_running():  # (made before the host set its delegate: the main queue looks it up, D-5808)
                _call_c("dispatch_async_f", libc_fn("_dispatch_main_q"), 0, fn_address(_wake_main_lookup))
            return
        wake_write(self.fd)

