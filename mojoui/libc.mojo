# mojoui.libc: the one place mojoui declares the libc functions other Mojo libraries also declare (goal 50 M0, D-4760).
# Mojo allows one signature per external symbol per binary: when mojoui calls `recv` with an Int address and Flare
# (vendor/flare/net/_libc.mojo) calls it with a pointer, a program using both doesn't build ("existing function with
# conflicting signature"). So each function here is declared with the argument types Flare uses (pointers as pointers,
# c_int / c_uint / c_size_t / c_ssize_t, UInt64 thread ids), and takes mojoui's usual Int addresses. Every other mojoui
# file calls these; scripts/libc_lint.py fails when one declares a listed symbol itself. The three the omxcore engine
# declares differently from Flare are looked up at run time instead (_sym), so mojoui builds beside either.

from std.ffi import external_call, c_int, c_uint, c_size_t, c_ssize_t, c_char
from std.sys import CompilationTarget

comptime _Ptr = Pointer[NoneType, MutUntrackedOrigin]


def _sym(name: String) -> Int:
    """A libc function's address, for the few that the omxcore engine and Flare declare with different types
    (pthread_create, pthread_detach, strtod): mojoui calls them through a pointer, declares neither form, and so builds
    beside both (D-4764). dlsym is declared as every other mojoui file declares it."""
    var n = name
    var anywhere = -2 if CompilationTarget.is_macos() else 0  # RTLD_DEFAULT
    return external_call["dlsym", Int](anywhere, n.as_c_string_span())


@always_inline
def _p(addr: Int) -> _Ptr:
    return _Ptr(unsafe_from_address=addr)


# sockets ------------------------------------------------------------------------------------------------------------

def socket(family: Int, kind: Int, protocol: Int) -> Int:
    return Int(external_call["socket", c_int](c_int(family), c_int(kind), c_int(protocol)))


def close(fd: Int) -> Int:
    return Int(external_call["close", c_int](c_int(fd)))


def bind(fd: Int, addr: Int, addrlen: Int) -> Int:
    return Int(external_call["bind", c_int](c_int(fd), _p(addr), c_uint(addrlen)))


def connect(fd: Int, addr: Int, addrlen: Int) -> Int:
    return Int(external_call["connect", c_int](c_int(fd), _p(addr), c_uint(addrlen)))


def listen(fd: Int, backlog: Int) -> Int:
    return Int(external_call["listen", c_int](c_int(fd), c_int(backlog)))


def accept4(fd: Int, addr: Int, addrlen: Int, flags: Int) -> Int:
    """Linux only (Flare declares it there; Apple has no accept4)."""
    return Int(external_call["accept4", c_int](c_int(fd), _p(addr), Pointer[c_uint, MutUntrackedOrigin](unsafe_from_address=addrlen), c_int(flags)))


def recv(fd: Int, buf: Int, n: Int, flags: Int) -> Int:
    return Int(external_call["recv", c_ssize_t](c_int(fd), _p(buf), c_size_t(n), c_int(flags)))


def send(fd: Int, buf: Int, n: Int, flags: Int) -> Int:
    return Int(external_call["send", c_ssize_t](c_int(fd), _p(buf), c_size_t(n), c_int(flags)))


def setsockopt(fd: Int, level: Int, name: Int, value: Int, length: Int) -> Int:
    return Int(external_call["setsockopt", c_int](c_int(fd), c_int(level), c_int(name), _p(value), c_uint(length)))


def getsockopt(fd: Int, level: Int, name: Int, value: Int, length: Int) -> Int:
    return Int(external_call["getsockopt", c_int](c_int(fd), c_int(level), c_int(name), _p(value), Pointer[c_uint, MutUntrackedOrigin](unsafe_from_address=length)))


def poll(fds: Int, nfds: Int, timeout_ms: Int) -> Int:
    return Int(external_call["poll", c_int](_p(fds), c_uint(nfds), c_int(timeout_ms)))


def inet_pton(family: Int, var src: String, dst: Int) -> Int:
    return Int(external_call["inet_pton", c_int](c_int(family), src.as_c_string_span(), _p(dst)))


def getaddrinfo(var host: String, hints: Int, res_slot: Int) -> Int:
    """No service (port) string, as Flare calls it."""
    return Int(external_call["getaddrinfo", c_int](host.as_c_string_span(), Optional[Pointer[UInt8, MutUntrackedOrigin]](None), _p(hints), _p(res_slot)))


def freeaddrinfo(head: Int):
    external_call["freeaddrinfo", NoneType](_p(head))


# files, processes, time ---------------------------------------------------------------------------------------------

def fcntl(fd: Int, cmd: Int, arg: Int = 0) -> Int:
    """Always three arguments (Flare's declaration; not the variadic one)."""
    return Int(external_call["fcntl", c_int](c_int(fd), c_int(cmd), c_int(arg)))


def pipe(fds: Int) -> Int:
    """`fds`: the address of two c_ints."""
    return Int(external_call["pipe", c_int](_p(fds)))


def unlink(var path: String) -> Int:
    return Int(external_call["unlink", c_int](path.as_c_string_span()))


def getpid() -> Int:
    return Int(external_call["getpid", Int32]())


def clock_gettime(clock: Int, ts: Int) -> Int:
    """`ts`: the address of two Ints (seconds, nanoseconds)."""
    return Int(external_call["clock_gettime", c_int](c_int(clock), Pointer[Int, MutUntrackedOrigin](unsafe_from_address=ts)))


def strtod(text: Int) -> Float64:
    """`text`: the address of a NUL-terminated number. Looked up, not declared (_sym)."""
    var f = _sym("strtod")
    return Pointer(to=f).unsafe_bitcast[def(Int, Int) thin abi("C") -> Float64]()[](text, 0)


# threads ------------------------------------------------------------------------------------------------------------

comptime ThreadArg = Pointer[UInt8, MutUntrackedOrigin]
comptime ThreadEntry = def(ThreadArg) thin -> ThreadArg
"""A thread's entry, as Flare's ThreadHandle.spawn_os types it (vendor/flare/runtime/_thread.mojo): `def entry(arg:
ThreadArg) -> ThreadArg`, raising nothing; the argument is an address (Int(arg))."""


def null_arg() -> ThreadArg:
    """A null ThreadArg (an entry's usual return; a literal 0 trips Pointer's non-null check at compile time)."""
    var zero = 0
    return ThreadArg(unsafe_from_address=zero)


def pthread_create[entry: ThreadEntry](arg: Int, tid_out: Int) -> Int:
    """Starts `entry(arg)` on a new thread with default attributes; its id is written at `tid_out` (8 bytes). Looked up,
    not declared (_sym)."""
    var f = _sym("pthread_create")
    var call = Pointer(to=f).unsafe_bitcast[def(Int, Int, ThreadEntry, Int) thin abi("C") -> c_int]()[]
    return Int(call(tid_out, 0, entry, arg))


def pthread_detach(tid: Int) -> Int:
    var f = _sym("pthread_detach")
    return Int(Pointer(to=f).unsafe_bitcast[def(Int) thin abi("C") -> c_int]()[](tid))


def pthread_mutex_init(mu: Int) -> Int:
    return Int(external_call["pthread_mutex_init", Int32](Pointer[Int8, MutUntrackedOrigin](unsafe_from_address=mu), Int(0)))


def pthread_mutex_lock(mu: Int) -> Int:
    return Int(external_call["pthread_mutex_lock", Int32](Pointer[Int8, MutUntrackedOrigin](unsafe_from_address=mu)))


def pthread_mutex_unlock(mu: Int) -> Int:
    return Int(external_call["pthread_mutex_unlock", Int32](Pointer[Int8, MutUntrackedOrigin](unsafe_from_address=mu)))


def pthread_mutex_destroy(mu: Int) -> Int:
    return Int(external_call["pthread_mutex_destroy", Int32](Pointer[Int8, MutUntrackedOrigin](unsafe_from_address=mu)))
