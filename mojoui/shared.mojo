# mojoui.shared: a process-wide registry for data built once by App.init_shared() and read by every
# session (web tabs, windows). Mojo has no global variables, so the addresses live in the process
# environment (MOJOUI_SHARED_<slot>): every host and platform has one.
#
#   @staticmethod
#   def init_shared():
#       if get_shared(0) == 0:
#           put_shared(0, share(generate_columns(20_000_000)))   # mojoui.frame.share → an address
#   def __init__(out self):
#       self.frame = Frame(get_shared(0))

from std.math import floor
from std.os import getenv, setenv, makedirs
from std.sys import argv, exit
from std.ffi import external_call, c_int
from std.sys import CompilationTarget
from std.memory.alloc import alloc, Layout
from std.atomic import Atomic
from mojoui import libc


def key(slot: Int) -> String:
    """MOJOUI_SHARED_<pid>_<slot>: a child process inherits the environment but must not follow a parent's addresses."""
    return "MOJOUI_SHARED_" + String(libc.getpid()) + "_" + String(slot)


def put_shared(slot: Int, addr: Int):
    _ = setenv(key(slot), String(addr), True)


def get_shared(slot: Int) -> Int:
    """The address (or number) put in `slot`, 0 when none. (Goal 80) Hot paths call this per frame or per op: on Linux
    the key is written into a byte buffer and glibc's secure_getenv's own string is parsed in place, no String made
    (the String path cost 500 ns a call). getenv itself is declared by std.os with another signature, so it can't be
    declared here; the Mac keeps the String path."""
    comptime if CompilationTarget.is_macos():
        var text = getenv(key(slot), "")
        if text == "":
            return 0
        try:
            return Int(text)
        except:
            return 0
    var buf = List[UInt8](capacity=64)
    for b in "MOJOUI_SHARED_".as_bytes():
        buf.append(b)
    _digits(buf, libc.getpid())
    buf.append(0x5F)  # "_"
    _digits(buf, slot)
    buf.append(0)
    var p = external_call["secure_getenv", Int](Int(buf.unsafe_ptr()))
    _ = len(buf)
    if p == 0:
        return 0
    var neg = False
    var v = 0
    var i = 0
    var c = Int(Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=p)[])
    if c == 0x2D:  # "-"
        neg = True
        i = 1
    while True:
        c = Int(Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=p + i)[])
        if c < 0x30 or c > 0x39:
            break
        v = v * 10 + (c - 0x30)
        i += 1
    if c != 0 or i == (1 if neg else 0):  # (not a whole number: Int(text) would have refused it)
        return 0
    return -v if neg else v


def _digits(mut buf: List[UInt8], n: Int):
    """n's decimal digits (n ≥ 0) appended."""
    if n == 0:
        buf.append(0x30)
        return
    var start = len(buf)
    var m = n
    while m > 0:
        buf.append(UInt8(0x30 + m % 10))
        m //= 10
    var a = start
    var b = len(buf) - 1
    while a < b:
        var t = buf[a]
        buf[a] = buf[b]
        buf[b] = t
        a += 1
        b -= 1


def floored(x: Float64) -> Float64:
    """The largest whole number not above x (apps import this rather than std.math, so they stay platform-free)."""
    return floor(x)


def environment(name: String, default: String = "") -> String:
    """An environment variable (apps import this rather than std.os, so they stay platform-free)."""
    return getenv(name, default)


def arguments() -> List[String]:
    """The command line's words, the program's own name first (apps import this rather than std.sys, D-767)."""
    var out = List[String]()
    for a in argv():
        out.append(String(a))
    return out^


def exit_with(code: Int):
    """Ends the process with `code` (a scripted run's result; apps import this rather than std.sys, D-767)."""
    exit(code)


def shared_loads() -> Int:
    """How many times init_shared() built its data in this process (hosts report it)."""
    return get_shared(99)


def count_load():
    put_shared(99, shared_loads() + 1)


def keep[T: Movable](var value: T) -> Int:
    """Moves a value to the heap for the life of the process; returns its address (see at[T])."""
    var p = alloc(Layout[T].single()).unsafe_leak()
    p.unsafe_write(value^)
    return Int(p)


def at[T: Movable](addr: Int) -> Pointer[T, MutUntrackedOrigin]:
    return Pointer[T, MutUntrackedOrigin](unsafe_from_address=addr)


def count_at(slot: Int) -> Int:
    """The address of a process-wide count at `slot` (an Int64 every thread changes atomically: count_add, count_of),
    made the first time it's asked for. The first thread's wins (setenv won't overwrite, under the C library's lock), so
    two threads asking at once share one count."""
    var addr = get_shared(slot)
    if addr != 0:
        return addr
    _ = setenv(key(slot), String(keep(Int64(0))), False)  # (a thread that lost the race leaves its 8 bytes, once)
    return get_shared(slot)


def count_add(slot: Int, n: Int) -> Int:
    """Adds n to the process-wide count at `slot` (count_at); returns the count before."""
    return Int(Atomic[Scalar[DType.int64]].fetch_add(Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=count_at(slot)), Int64(n)))


def count_of(slot: Int) -> Int:
    """The process-wide count at `slot` now (count_at)."""
    return Int(Atomic[Scalar[DType.int64]].load(Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=count_at(slot))))


def make_dir(path: String):
    """Makes a folder (and its parents) if it isn't there: apps keep their settings with it (no std imports in apps)."""
    try:
        makedirs(path, exist_ok=True)
    except:
        pass


def memory_bytes() -> Int:
    """The machine's memory (Linux: /proc/meminfo, or the cgroup's memory.max when that's lower: a container's or a
    scope's limit); 8 GB where it can't be read. OMX_MEMORY_BYTES stands in for it
    (checks use it to act as a smaller machine: what streams, what a sort may hold)."""
    var asked = environment("OMX_MEMORY_BYTES")
    if asked != "":
        try:
            return Int(asked)
        except:
            pass
    var total = 8 << 30
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f.read().split("\n"):
                if line.startswith("MemTotal:"):
                    var parts = line.split()
                    total = Int(parts[1]) * 1024
    except:
        pass
    try:  # (in a container, or a systemd scope held to a limit: the limit is the memory there is, goal 62)
        with open("/sys/fs/cgroup/memory.max", "r") as f:
            var limit = String(f.read().strip())
            if limit != "max" and limit != "":
                total = min(total, Int(limit))
    except:
        pass
    return total
