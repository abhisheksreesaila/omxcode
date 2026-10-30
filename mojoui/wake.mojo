# mojoui.wake: the job-wake pipe's low-level ends, without omxcore (mojoui.jobs builds start_ui_job on them; a plain
# worker thread, such as mojoui.framefeed's decoder, wakes the UI with wake_write). The host makes the pipe
# (mojoui.jobs.wake_pipe) and watches its read end on its main loop; a byte down it sends App.jobs_message() to update().

from std.ffi import external_call, c_int
from std.sys import CompilationTarget
from std.memory import Pointer
from mojoui.shared import get_shared

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
