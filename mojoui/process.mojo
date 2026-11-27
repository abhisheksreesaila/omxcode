# mojoui.process: child programs an app supervises (goal 50 M3, D-4768): a model server, a robot's driver, a tool.
#
#   var p = Process.start(["max", "serve", "--port", "8001"], log="/tmp/max.log", env=["HF_HUB_OFFLINE=1"])
#   if not p.wait_healthy("http://127.0.0.1:8001/health", 120_000): print(p.log_tail())
#   p.touch()                       # used now (idle_ms counts from here)
#   if p.idle_ms() > 300_000: _ = p.stop()
#   p.running(); p.exit_code()      # -1 while it runs; its exit code; 128 + the signal that ended it
#
# Started with posix_spawnp (safe in a program with threads, unlike fork), in a process group of its own, stdout and
# stderr appended to the log; stop() sends SIGTERM to the whole group (a server's own workers too), then SIGKILL after
# the grace time. A Process that's dropped while its child runs stops it. Linux and macOS.

from std.os import getenv
from std.os.path import exists, getsize
from std.memory.alloc import unsafe_alloc
from std.memory import Pointer
from std.ffi import external_call, c_int
from mojoui import libc
from mojoui.http import Request
from mojoui.http_socket import SocketTransport
from mojoui.clock import now_ns
from std.sys import CompilationTarget

comptime SIGTERM = 15
comptime SIGKILL = 9
comptime WNOHANG = 1
comptime POSIX_SPAWN_SETPGROUP = 2
comptime O_WRONLY = 1
comptime O_CREAT = 0o100 if CompilationTarget.is_linux() else 0x200
comptime O_APPEND = 0o2000 if CompilationTarget.is_linux() else 0x8
comptime _BLOB = 1024  # (posix_spawn's opaque structs: 80 / 336 bytes on glibc, a pointer on macOS)


def _cstr(s: String) -> Int:
    """A NUL-terminated copy on the heap (freed by the caller)."""
    var n = s.byte_length()
    var p = unsafe_alloc[UInt8](n + 1)
    var b = s.as_bytes()
    for i in range(n):
        (p + i)[] = b[i]
    (p + n)[] = 0
    return Int(p)


def _free(addr: Int):
    if addr != 0:
        Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr).unsafe_free()


def _c_text(addr: Int) -> String:
    var out = List[UInt8]()
    var i = 0
    while True:
        var c = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr + i)[]
        if c == 0:
            break
        out.append(c)
        i += 1
    return String(unsafe_from_utf8=out)


def _environment(overrides: List[String]) -> List[String]:
    """This process's environment with `overrides` ("NAME=value"; "NAME=" alone removes NAME) applied."""
    var keys = List[String]()
    for o in overrides:
        var eq = o.find("=")
        keys.append(String(o) if eq < 0 else String(o[byte = : eq + 1]))
    var out = List[String]()
    var env = libc.environ()
    var i = 0
    while env != 0:
        var entry = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=env + i * 8)[]
        if entry == 0:
            break
        var text = _c_text(entry)
        var replaced = False
        for k in keys:
            if text.startswith(k):
                replaced = True
        if not replaced:
            out.append(text)
        i += 1
    for o in overrides:
        if not o.endswith("="):
            out.append(o)
    return out^


struct Process(Movable):
    var pid: Int
    var command: String
    var log: String
    var started_ns: Int
    var used_ns: Int
    var code: Int  # -1: running (or not looked at since it ended); else the exit code, 128 + signal

    def __init__(out self, pid: Int, command: String, log: String):
        self.pid = pid
        self.command = command
        self.log = log
        self.started_ns = now_ns()
        self.used_ns = self.started_ns
        self.code = -1

    @staticmethod
    def start(argv: List[String], log: String, env: List[String] = List[String](), cwd: String = "") raises -> Process:
        """Runs argv[0] (looked up on PATH) with argv, this environment plus `env`, stdout and stderr appended to `log`
        (stdin from /dev/null), in `cwd` when given (a libc without posix_spawn_file_actions_addchdir_np raises
        instead of silently running somewhere else)."""
        var pid = _spawn(argv, env, cwd, -1, -1, log)
        var cmd = String("")
        for a in argv:
            cmd += (" " if cmd != "" else "") + a
        return Process(pid, cmd, log)

    @staticmethod
    def start_fed(argv: List[String], input: String, log: String, env: List[String] = List[String](), cwd: String = "") raises -> Process:
        """As start(), but `input` goes to the child's stdin through a pipe (then closed): words a command line would show
        to `ps` (a key in a curl config) never leave this process any other way. Its output still goes to `log`."""
        var inp = List[Int32](length=2, fill=-1)
        if libc.pipe(Int(inp.unsafe_ptr())) != 0:
            raise Error("no pipe for " + argv[0])
        _quiet_sigpipe()
        var ends: List[Int] = [Int(inp[0]), Int(inp[1])]
        var pid: Int
        try:
            pid = _spawn(argv, env, cwd, Int(inp[0]), -1, log, ends)
        except e:
            _ = libc.close(Int(inp[0]))
            _ = libc.close(Int(inp[1]))
            raise e^
        _ = libc.close(Int(inp[0]))
        var b = input.as_bytes()
        var at = 0
        while at < len(b):  # (a child that reads its config first, as curl does, drains it; a dead one ends the write with an error)
            var n = libc.write_fd(Int(inp[1]), Int(input.unsafe_ptr()) + at, len(b) - at)
            if n <= 0:
                break
            at += n
        _ = libc.close(Int(inp[1]))
        var cmd = String("")
        for a in argv:
            cmd += (" " if cmd != "" else "") + a
        return Process(pid, cmd, log)

    def running(mut self) -> Bool:
        """Still running? (Reaps it once it has ended and keeps its exit code.)"""
        if self.code >= 0 or self.pid <= 0:
            return False
        var status = List[Int32](length=2, fill=0)
        var r = libc.waitpid(self.pid, Int(status.unsafe_ptr()), WNOHANG)
        if r == 0:
            return True
        var s = Int(status[0])
        if r < 0:
            self.code = 255
        elif s & 0x7F == 0:
            self.code = (s >> 8) & 0xFF  # exited
        else:
            self.code = 128 + (s & 0x7F)  # a signal
        return False

    def exit_code(mut self) -> Int:
        _ = self.running()
        return self.code

    def touch(mut self):
        self.used_ns = now_ns()

    def idle_ms(self) -> Int:
        return (now_ns() - self.used_ns) // 1_000_000

    def uptime_ms(self) -> Int:
        return (now_ns() - self.started_ns) // 1_000_000

    def wait_healthy(mut self, url: String, timeout_ms: Int, every_ms: Int = 250) -> Bool:
        """Until a GET of `url` answers 2xx (True), the child ends, or the time is up (False)."""
        var until = now_ns() + timeout_ms * 1_000_000
        while now_ns() < until:
            if not self.running():
                return False
            if healthy(url):
                return True
            _ = libc.poll(0, 0, every_ms)
        return False

    def stop(mut self, grace_ms: Int = 5000) -> Int:
        """SIGTERM to its process group, SIGKILL after `grace_ms`; returns the exit code."""
        if not self.running():
            return self.code
        _ = libc.kill(-self.pid, SIGTERM)
        var until = now_ns() + grace_ms * 1_000_000
        while now_ns() < until:
            if not self.running():
                return self.code
            _ = libc.poll(0, 0, 20)
        _ = libc.kill(-self.pid, SIGKILL)
        for _ in range(250):
            if not self.running():
                break
            _ = libc.poll(0, 0, 20)
        return self.code

    def begin_stop(mut self):
        """SIGTERM to its group and return at once (finish_stop later): for a caller that mustn't wait the grace out."""
        if self.running():
            _ = libc.kill(-self.pid, SIGTERM)
            self.used_ns = now_ns()  # (the grace counts from here)

    def finish_stop(mut self, grace_ms: Int = 10_000) -> Bool:
        """After begin_stop: True once it has ended; SIGKILL to the group when the grace has passed."""
        if not self.running():
            return True
        if self.idle_ms() >= grace_ms:
            _ = libc.kill(-self.pid, SIGKILL)
        return not self.running()

    def log_tail(self, max_bytes: Int = 4000) -> String:
        """The end of its log (whole lines where it can)."""
        return file_tail(self.log, max_bytes)

    def __deinit__(deinit self):
        if self.code < 0 and self.pid > 0:
            var me = Process(self.pid, self.command, self.log)
            _ = me.stop(2000)
            me.pid = 0


def healthy(url: String, timeout_ms: Int = 1000) -> Bool:
    """A GET of `url` answers 2xx within the time (http:// only)."""
    var r = SocketTransport.send(Request.get(0, url).timeout(timeout_ms))
    return r.error == "" and r.status >= 200 and r.status < 300


def file_tail(path: String, max_bytes: Int = 4000) -> String:
    """The last `max_bytes` of a text file ("" when it isn't there), starting at a whole line. Read with pread found by
    address, not FileHandle.seek: its lseek clashes with omxcore's in one program (scripts/seek_lint.py, goal 68)."""
    try:
        if not exists(path):
            return ""
        var size = getsize(path)
        var start = size - max_bytes if size > max_bytes else 0
        var n = size - start
        var p = path
        var n_open = String("open")
        var n_pread = String("pread")
        var n_close = String("close")
        var openf = external_call["dlsym", Int](0, n_open.as_c_string_span())
        var preadf = external_call["dlsym", Int](0, n_pread.as_c_string_span())
        var closef = external_call["dlsym", Int](0, n_close.as_c_string_span())
        var fd = _by_address[def(Int, c_int) thin abi("C") -> c_int](openf)(Int(p.as_c_string_span().unsafe_ptr()), c_int(0))
        if Int(fd) < 0:
            return ""
        var buf = List[UInt8](length=Int(n), fill=0)
        var got = _by_address[def(c_int, Int, Int, Int) thin abi("C") -> Int](preadf)(fd, Int(buf.unsafe_ptr()), Int(n), Int(start))
        _ = _by_address[def(c_int) thin abi("C") -> c_int](closef)(fd)
        while len(buf) > max(got, 0):
            _ = buf.pop()
        var text = String(from_utf8_lossy=Span(buf))
        if start > 0:
            var nl = text.find("\n")
            if nl >= 0:
                return String(text[byte = nl + 1 :])
        return text
    except:
        return ""


def _on_sigpipe(sig: c_int) abi("C"):
    """A write to a child that has gone is EPIPE, not the end of the app (SIGPIPE caught and ignored)."""
    pass


def _quiet_sigpipe():
    _ = libc.signal(13, _on_sigpipe)  # (SIGPIPE: 13 on Linux and macOS)


def _spawn(argv: List[String], env: List[String], cwd: String, in_fd: Int, out_fd: Int, log: String, closes: List[Int] = List[Int]()) raises -> Int:
    """posix_spawnp in a process group of its own; the child's stdin is `in_fd` (-1: /dev/null) and its stdout `out_fd`
    (-1: appended to `log`), stderr with stdout (or /dev/null when stdout is a pipe: an error message never mixes into
    what a caller reads); `closes`: descriptors the child closes once those are in place (a pipe's other ends). Returns
    the pid."""
    if len(argv) == 0:
        raise Error("no program to start")
    var envs = _environment(env)
    var cargs = List[Int]()
    for a in argv:
        cargs.append(_cstr(a))
    cargs.append(0)
    var cenv = List[Int]()
    for e in envs:
        cenv.append(_cstr(e))
    cenv.append(0)
    var log_c = _cstr(log)
    var null_c = _cstr("/dev/null")
    var actions = Int(unsafe_alloc[UInt8](_BLOB))
    var attr = Int(unsafe_alloc[UInt8](_BLOB))
    for k in range(_BLOB):
        Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=actions + k)[] = 0
        Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=attr + k)[] = 0
    _ = libc.posix_spawn_file_actions_init(actions)
    if in_fd >= 0:
        _ = libc.posix_spawn_file_actions_adddup2(actions, in_fd, 0)
    else:
        _ = libc.posix_spawn_file_actions_addopen(actions, 0, null_c, 0, 0)
    if out_fd >= 0:
        _ = libc.posix_spawn_file_actions_adddup2(actions, out_fd, 1)
        _ = libc.posix_spawn_file_actions_addopen(actions, 2, null_c, O_WRONLY, 0)
    else:
        _ = libc.posix_spawn_file_actions_addopen(actions, 1, log_c, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        _ = libc.posix_spawn_file_actions_adddup2(actions, 1, 2)
    for fd in closes:
        _ = libc.posix_spawn_file_actions_addclose(actions, fd)
    var cwd_c = _cstr(cwd) if cwd != "" else 0
    var chdir_failed = cwd != "" and libc.posix_spawn_file_actions_addchdir(actions, cwd_c) != 0
    var rc = 0
    var pid = List[Int32](length=2, fill=0)
    if not chdir_failed:
        _ = libc.posix_spawnattr_init(attr)
        _ = libc.posix_spawnattr_setflags(attr, POSIX_SPAWN_SETPGROUP)
        _ = libc.posix_spawnattr_setpgroup(attr, 0)
        var file = cargs[0]
        var argv_at = Int(cargs.unsafe_ptr())
        var envp_at = Int(cenv.unsafe_ptr())
        rc = libc.posix_spawnp(Int(pid.unsafe_ptr()), file, actions, attr, argv_at, envp_at)
        _ = libc.posix_spawnattr_destroy(attr)
    _ = libc.posix_spawn_file_actions_destroy(actions)
    _free(actions)
    _free(attr)
    _free(log_c)
    _free(null_c)
    if cwd_c != 0:
        _free(cwd_c)
    for c in cargs:
        _free(c)
    for c in cenv:
        _free(c)
    if chdir_failed:
        raise Error("this libc cannot start a program in another directory (posix_spawn_file_actions_addchdir_np)")
    if rc != 0:
        raise Error("can't start " + argv[0] + " (error " + String(rc) + ")")
    return Int(pid[0])


@fieldwise_init
struct Exchanged(Copyable, Movable):
    var code: Int  # the exit code (128 + a signal; -1: it didn't start, or was killed at the time limit)
    var out: String  # what it wrote on stdout (stderr is dropped)


def exchange(argv: List[String], input: String, timeout_ms: Int = 10_000, env: List[String] = List[String]()) -> Exchanged:
    """Runs a short program with `input` on its stdin and its stdout read back, both through pipes, so neither ever sits in
    a file (a secret given to a keyring's command line tool, a password it reads back). Killed after `timeout_ms`."""
    var inp = List[Int32](length=2, fill=-1)
    var outp = List[Int32](length=2, fill=-1)
    if libc.pipe(Int(inp.unsafe_ptr())) != 0:
        return Exchanged(-1, "")
    if libc.pipe(Int(outp.unsafe_ptr())) != 0:
        _ = libc.close(Int(inp[0]))
        _ = libc.close(Int(inp[1]))
        return Exchanged(-1, "")
    var pid: Int
    try:  # (the child keeps only the dup2'ed copies: all four ends close in it, by file action, not FD_CLOEXEC: fcntl is
        # variadic, and Apple's arm64 passes a variadic argument on the stack, where a plain call doesn't put it)
        var ends: List[Int] = [Int(inp[0]), Int(inp[1]), Int(outp[0]), Int(outp[1])]
        pid = _spawn(argv, env, "", Int(inp[0]), Int(outp[1]), "/dev/null", ends)
    except:
        for fd in [Int(inp[0]), Int(inp[1]), Int(outp[0]), Int(outp[1])]:
            _ = libc.close(fd)
        return Exchanged(-1, "")
    _ = libc.close(Int(inp[0]))
    _ = libc.close(Int(outp[1]))
    _quiet_sigpipe()
    var b = input.as_bytes()
    var at = 0
    while at < len(b):  # (inputs here are small: well under a pipe's buffer, so this never blocks on a child that doesn't read)
        var n = libc.write_fd(Int(inp[1]), Int(input.unsafe_ptr()) + at, len(b) - at)
        if n <= 0:
            break
        at += n
    _ = libc.close(Int(inp[1]))
    var got = List[UInt8]()
    var buf = List[UInt8](length=4096, fill=0)
    var until = now_ns() + timeout_ms * 1_000_000
    var pfd = List[Int32](length=2, fill=0)  # struct pollfd {int fd; short events; short revents}
    var timed_out = False
    while True:
        var left = (until - now_ns()) // 1_000_000
        if left <= 0:
            timed_out = True
            break
        pfd[0] = outp[0]
        pfd[1] = 1  # POLLIN in the low short, revents 0
        if libc.poll(Int(pfd.unsafe_ptr()), 1, min(left, 100)) <= 0:
            continue
        var n = libc.read_fd(Int(outp[0]), Int(buf.unsafe_ptr()), len(buf))
        if n <= 0:
            break
        for i in range(n):
            got.append(buf[i])
    _ = libc.close(Int(outp[0]))
    if timed_out:
        _ = libc.kill(-pid, SIGKILL)
    var status = List[Int32](length=2, fill=0)
    var code = -1
    while True:
        var r = libc.waitpid(pid, Int(status.unsafe_ptr()), WNOHANG)
        if r != 0:
            if r > 0:
                var s2 = Int(status[0])
                code = ((s2 >> 8) & 0xFF) if s2 & 0x7F == 0 else 128 + (s2 & 0x7F)
            break
        if now_ns() > until + 2_000_000_000:
            _ = libc.kill(-pid, SIGKILL)
        _ = libc.usleep(2000)
    if timed_out:
        code = -1
    var text = String(unsafe_from_utf8=Span(got))
    for i in range(len(got)):  # (the copy read back may be a secret: no second copy is left lying in this buffer)
        got[i] = 0
    return Exchanged(code, text^)


def _by_address[T: ImplicitlyCopyable](addr: Int) -> T:
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=addr)
    return Pointer(to=raw).unsafe_bitcast[T]()[]


def output(argv: List[String], timeout_ms: Int = 5000, env: List[String] = List[String]()) -> String:
    """Runs a short command and returns what it printed (stdout and stderr; "" when it can't start). Killed after
    `timeout_ms`. For quick questions to the system (nvidia-smi, uname), not for long jobs."""
    var path = getenv("TMPDIR", "/tmp") + "/mojoui-out-" + String(libc.getpid()) + "-" + String(now_ns()) + ".txt"
    try:
        var p = Process.start(argv, path, env)
        var until = now_ns() + timeout_ms * 1_000_000
        while p.running() and now_ns() < until:
            _ = libc.poll(0, 0, 5)
        _ = p.stop(200)
        var text = file_tail(path, 1 << 20)
        _ = libc.unlink(path)
        return text^
    except:
        _ = libc.unlink(path)
        return ""
