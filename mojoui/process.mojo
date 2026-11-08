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
        _ = libc.posix_spawn_file_actions_addopen(actions, 0, null_c, 0, 0)
        _ = libc.posix_spawn_file_actions_addopen(actions, 1, log_c, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        _ = libc.posix_spawn_file_actions_adddup2(actions, 1, 2)
        var cwd_c = _cstr(cwd) if cwd != "" else 0
        if cwd != "":
            if libc.posix_spawn_file_actions_addchdir(actions, cwd_c) != 0:
                _ = libc.posix_spawn_file_actions_destroy(actions)
                _free(actions)
                _free(attr)
                _free(log_c)
                _free(null_c)
                _free(cwd_c)
                for c in cargs:
                    _free(c)
                for c in cenv:
                    _free(c)
                raise Error("this libc cannot start a program in another directory (posix_spawn_file_actions_addchdir_np)")
        _ = libc.posix_spawnattr_init(attr)
        _ = libc.posix_spawnattr_setflags(attr, POSIX_SPAWN_SETPGROUP)
        _ = libc.posix_spawnattr_setpgroup(attr, 0)
        var pid = List[Int32](length=2, fill=0)
        var file = cargs[0]
        var argv_at = Int(cargs.unsafe_ptr())
        var envp_at = Int(cenv.unsafe_ptr())
        var rc = libc.posix_spawnp(Int(pid.unsafe_ptr()), file, actions, attr, argv_at, envp_at)
        _ = libc.posix_spawn_file_actions_destroy(actions)
        _ = libc.posix_spawnattr_destroy(attr)
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
        if rc != 0:
            raise Error("can't start " + argv[0] + " (error " + String(rc) + ")")
        var cmd = String("")
        for a in argv:
            cmd += (" " if cmd != "" else "") + a
        return Process(Int(pid[0]), cmd, log)

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
    """The last `max_bytes` of a text file ("" when it isn't there), starting at a whole line."""
    try:
        if not exists(path):
            return ""
        var size = getsize(path)
        with open(path, "r") as f:
            if size > max_bytes:
                _ = f.seek(size - max_bytes)
            var text = f.read()
            if size > max_bytes:
                var nl = text.find("\n")
                if nl >= 0:
                    return String(text[byte = nl + 1 :])
            return text
    except:
        return ""


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
