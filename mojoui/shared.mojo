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
from std.memory.alloc import alloc, Layout


def key(slot: Int) -> String:
    """MOJOUI_SHARED_<pid>_<slot>: a child process inherits the environment but must not follow a parent's addresses."""
    return "MOJOUI_SHARED_" + String(Int(external_call["getpid", c_int]())) + "_" + String(slot)


def put_shared(slot: Int, addr: Int):
    _ = setenv(key(slot), String(addr), True)


def get_shared(slot: Int) -> Int:
    var text = getenv(key(slot), "")
    if text == "":
        return 0
    try:
        return Int(text)
    except:
        return 0


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


def make_dir(path: String):
    """Makes a folder (and its parents) if it isn't there: apps keep their settings with it (no std imports in apps)."""
    try:
        makedirs(path, exist_ok=True)
    except:
        pass


def memory_bytes() -> Int:
    """The machine's memory (Linux: /proc/meminfo); 8 GB where it can't be read. OMX_MEMORY_BYTES stands in for it
    (checks use it to act as a smaller machine: what streams, what a sort may hold)."""
    var asked = environment("OMX_MEMORY_BYTES")
    if asked != "":
        try:
            return Int(asked)
        except:
            pass
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f.read().split("\n"):
                if line.startswith("MemTotal:"):
                    var parts = line.split()
                    return Int(parts[1]) * 1024
    except:
        pass
    return 8 << 30
