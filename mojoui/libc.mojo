# mojoui.libc: the one place mojoui declares the libc functions other Mojo libraries also declare (goal 50 M0, D-4782).
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
    beside both (D-4786). dlsym is declared as every other mojoui file declares it."""
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


def accept(fd: Int, addr: Int, addrlen: Int) -> Int:
    """macOS's (Linux: accept4); Flare's form (flare/net/_libc.mojo)."""
    return Int(external_call["accept", c_int](c_int(fd), _p(addr), Pointer[c_uint, MutUntrackedOrigin](unsafe_from_address=addrlen)))


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


def chmod(var path: String, mode: Int) -> Int:
    """A file's permissions (0o600 for a stored key: only this user may read it)."""
    return Int(external_call["chmod", c_int](path.as_c_string_span(), c_uint(mode)))


def rename(var old: String, var new: String) -> Int:
    """0 when `old` now has the name `new` (replacing it, in one step on one file system)."""
    return Int(external_call["rename", c_int](old.as_c_string_span(), new.as_c_string_span()))


def getentropy(buf: Int, n: Int) -> Int:
    """Fills `n` (≤ 256) bytes at `buf` from the OS CSPRNG; 0 on success (Flare's form: flare/crypto/random.mojo)."""
    return Int(external_call["getentropy", c_int](_p(buf), c_size_t(n)))


def usleep(us: Int) -> Int:
    """Sleeps `us` microseconds; Flare's form (flare/runtime/_libc_time.mojo)."""
    return Int(external_call["usleep", Int32, Int32](Int32(us)))


def getpid() -> Int:
    return Int(external_call["getpid", Int32]())


def clock_gettime(clock: Int, ts: Int) -> Int:
    """`ts`: the address of two Ints (seconds, nanoseconds)."""
    return Int(external_call["clock_gettime", c_int](c_int(clock), Pointer[Int, MutUntrackedOrigin](unsafe_from_address=ts)))


def strtod(text: Int) -> Float64:
    """`text`: the address of a NUL-terminated number. Looked up, not declared (_sym)."""
    var f = _sym("strtod")
    return Pointer(to=f).unsafe_bitcast[def(Int, Int) thin abi("C") -> Float64]()[](text, 0)


# processes (mojoui.process) ----------------------------------------------------------------------------------------

def kill(pid: Int, sig: Int) -> Int:
    """`pid` < 0: the whole process group -pid."""
    return Int(external_call["kill", c_int](c_int(pid), c_int(sig)))


def waitpid(pid: Int, status_addr: Int, options: Int) -> Int:
    """`status_addr`: where the C int status goes (an address, as Flare passes it)."""
    return Int(external_call["waitpid", c_int](c_int(pid), status_addr, c_int(options)))


def posix_spawnp(pid_addr: Int, file: Int, actions: Int, attr: Int, argv: Int, envp: Int) -> Int:
    """All addresses: the pid_t out, a C string (searched on PATH), the file actions, the attributes, argv, envp."""
    return Int(external_call["posix_spawnp", c_int](_p(pid_addr), _p(file), _p(actions), _p(attr), _p(argv), _p(envp)))


def posix_spawn_file_actions_init(actions: Int) -> Int:
    return Int(external_call["posix_spawn_file_actions_init", c_int](_p(actions)))


def posix_spawn_file_actions_destroy(actions: Int) -> Int:
    return Int(external_call["posix_spawn_file_actions_destroy", c_int](_p(actions)))


def posix_spawn_file_actions_addopen(actions: Int, fd: Int, path: Int, flags: Int, mode: Int) -> Int:
    return Int(external_call["posix_spawn_file_actions_addopen", c_int](_p(actions), c_int(fd), _p(path), c_int(flags), c_uint(mode)))


def posix_spawn_file_actions_addchdir(actions: Int, path: Int) -> Int:
    """posix_spawn_file_actions_addchdir_np: the child changes into `path` before it runs (glibc 2.29+, macOS 10.15+).
    0 on success; a non-zero errno, or -1 when this libc doesn't have it (the caller then runs in its own cwd)."""
    var f = _sym("posix_spawn_file_actions_addchdir_np")
    if f == 0:
        return -1
    var call = Pointer(to=f).unsafe_bitcast[def(Int, Int) thin abi("C") -> c_int]()[]
    return Int(call(actions, path))


def posix_spawn_file_actions_adddup2(actions: Int, fd: Int, to: Int) -> Int:
    return Int(external_call["posix_spawn_file_actions_adddup2", c_int](_p(actions), c_int(fd), c_int(to)))


def posix_spawnattr_init(attr: Int) -> Int:
    return Int(external_call["posix_spawnattr_init", c_int](_p(attr)))


def posix_spawnattr_destroy(attr: Int) -> Int:
    return Int(external_call["posix_spawnattr_destroy", c_int](_p(attr)))


def posix_spawnattr_setflags(attr: Int, flags: Int) -> Int:
    return Int(external_call["posix_spawnattr_setflags", c_int](_p(attr), Int16(flags)))


def posix_spawnattr_setpgroup(attr: Int, pgroup: Int) -> Int:
    return Int(external_call["posix_spawnattr_setpgroup", c_int](_p(attr), c_int(pgroup)))


def environ() -> Int:
    """The address of the first `char *` in the process's environment (NULL-terminated)."""
    var at = _sym("environ")
    return 0 if at == 0 else Pointer[Int, MutUntrackedOrigin](unsafe_from_address=at)[]


# signals (mojoui.serve's stop handler) ------------------------------------------------------------------------------

def socketpair(domain: Int, kind: Int, protocol: Int, fds: Int) -> Int:
    """`fds`: the address of two c_ints."""
    return Int(external_call["socketpair", c_int](c_int(domain), c_int(kind), c_int(protocol), _p(fds)))


def dup2(fd: Int, to: Int) -> Int:
    return Int(external_call["dup2", c_int](c_int(fd), c_int(to)))


comptime SignalHandler = def(c_int) thin abi("C") -> None


def signal(sig: Int, handler: SignalHandler) -> Int:
    return external_call["signal", Int](c_int(sig), handler)


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


# thread-local storage (mojoui.sqlite's per-thread connections) ----------------------------------------------------------

comptime TlsDestructor = def(Int) thin abi("C") -> None


def pthread_key_create(destructor: TlsDestructor) -> Int:
    """A thread-local slot whose value `destructor` gets when a thread holding one ends; the key, or -1."""
    var key = List[UInt64](length=1, fill=0)
    if external_call["pthread_key_create", c_int](Int(key.unsafe_ptr()), destructor) != 0:
        return -1
    return Int(key[0] & 0xFFFFFFFF) if CompilationTarget.is_linux() else Int(key[0])


def pthread_getspecific(key: Int) -> Int:
    return external_call["pthread_getspecific", Int](UInt64(key))


def pthread_setspecific(key: Int, value: Int) -> Int:
    return Int(external_call["pthread_setspecific", c_int](UInt64(key), value))


# files by address (mojoui.log): std's FileDescriptor and Flare declare write() their own ways, so these are looked up ---

def open_append(var path: String) -> Int:
    """The file opened for appending (O_WRONLY | O_APPEND | O_CLOEXEC), made with mode 0600 when missing: the fd, or -1.
    open() is variadic, and on Apple's arm64 a variadic mode travels on the stack, where a fixed-argument call never
    puts it (a file made with mode 0000, seen on the Mac): so open() is called without O_CREAT (two arguments) and a
    missing file is made by creat(path, 0600), which isn't variadic."""
    var flags = (0x1 | 0x8 | 0x1000000) if CompilationTarget.is_macos() else (0x1 | 0x400 | 0x80000)
    var f = _sym("open")
    var call = Pointer(to=f).unsafe_bitcast[def(Int, c_int) thin abi("C") -> c_int]()[]
    var fd = Int(call(Int(path.as_c_string_span().unsafe_ptr()), c_int(flags)))
    if fd < 0:
        var c = _sym("creat")
        var made = Int(Pointer(to=c).unsafe_bitcast[def(Int, c_uint) thin abi("C") -> c_int]()[](Int(path.as_c_string_span().unsafe_ptr()), c_uint(0o600)))
        if made >= 0:
            _ = close(made)
        fd = Int(call(Int(path.as_c_string_span().unsafe_ptr()), c_int(flags)))
    _ = path.byte_length()
    return fd


def write_fd(fd: Int, addr: Int, n: Int) -> Int:
    var f = _sym("write")
    return Int(Pointer(to=f).unsafe_bitcast[def(c_int, Int, c_size_t) thin abi("C") -> c_ssize_t]()[](c_int(fd), addr, c_size_t(n)))


def rename_path(var src: String, var dst: String) -> Int:
    var f = _sym("rename")
    var rc = Int(Pointer(to=f).unsafe_bitcast[def(Int, Int) thin abi("C") -> c_int]()[](
        Int(src.as_c_string_span().unsafe_ptr()), Int(dst.as_c_string_span().unsafe_ptr())))
    _ = src.byte_length()
    _ = dst.byte_length()
    return rc


def file_size(fd: Int) -> Int:
    """lseek(fd, 0, SEEK_END): the file's size (an O_APPEND fd writes there anyway)."""
    var f = _sym("lseek")
    return Int(Pointer(to=f).unsafe_bitcast[def(c_int, Int64, c_int) thin abi("C") -> Int64]()[](c_int(fd), 0, c_int(2)))


def cpu_count() -> Int:
    """sysconf(_SC_NPROCESSORS_ONLN), in Flare's form."""
    return external_call["sysconf", Int, c_int](c_int(84 if CompilationTarget.is_linux() else 58))


def read_fd(fd: Int, addr: Int, n: Int) -> Int:
    var f = _sym("read")
    return Int(Pointer(to=f).unsafe_bitcast[def(c_int, Int, c_size_t) thin abi("C") -> c_ssize_t]()[](c_int(fd), addr, c_size_t(n)))


def nofile_limit() -> Tuple[Int, Int]:
    """getrlimit(RLIMIT_NOFILE): (soft, hard) open-file limits ((0, 0) when it can't say). Looked up (_sym): no
    declaration to clash with, no symbol for the Mac's stub."""
    var lim = List[UInt64](length=2, fill=0)
    var f = _sym("getrlimit")
    if f == 0:
        return (0, 0)
    var rc = Pointer(to=f).unsafe_bitcast[def(c_int, Int) thin abi("C") -> c_int]()[](c_int(7 if CompilationTarget.is_linux() else 8), Int(lim.unsafe_ptr()))
    if Int(rc) != 0:
        return (0, 0)
    var soft = Int(min(lim[0], UInt64(1) << 40))  # (RLIM_INFINITY: plenty)
    var hard = Int(min(lim[1], UInt64(1) << 40))
    return (soft, hard)


def raise_nofile() -> Int:
    """The soft open-file limit raised to the hard one (Go's runtime does the same at start; macOS caps it at OPEN_MAX,
    10240): the soft limit now."""
    var have = nofile_limit()
    var want = have[1] if CompilationTarget.is_linux() else min(have[1], 10240)
    if want <= have[0]:
        return have[0]
    var lim = List[UInt64](length=2, fill=0)
    lim[0] = UInt64(want)
    lim[1] = UInt64(have[1]) if have[1] < (1 << 40) else UInt64.MAX
    var f = _sym("setrlimit")
    if f == 0:
        return have[0]
    var rc = Pointer(to=f).unsafe_bitcast[def(c_int, Int) thin abi("C") -> c_int]()[](c_int(7 if CompilationTarget.is_linux() else 8), Int(lim.unsafe_ptr()))
    _ = len(lim)
    return want if Int(rc) == 0 else have[0]
