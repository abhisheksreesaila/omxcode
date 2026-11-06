# mojoui.companion: a helper program an app keeps running beside it (goal 55: omxconsole's consoled; any app with a
# local service of its own, LM Studio's way). Started when nothing answers at its health URL, stopped when the app
# closes, and only if the app started it: a service the person runs themselves is left alone. A helper it starts is
# told the app's pid (MOJOUI_PARENT_PID) and should end when the app is gone (parent_gone(): a crash, a kill, a SIGTERM
# that skips App.closing), so nothing keeps holding the GPU after the app. The helper is found next
# to the app's own binary (exe_dir(); build.sh puts examples/<app>/companions there).
#
#   var c = Companion()
#   var why = c.ensure("http://127.0.0.1:11435/health", [exe_dir() + "/consoled"], log_path)   # in App.init
#   c.stop()                                                                                   # in App.closing

from std.ffi import external_call, c_int
from std.sys import CompilationTarget
from mojoui.process import Process
from mojoui.http import Request
from mojoui.http_socket import SocketTransport
from mojoui import libc
from mojoui.clock import now_ns


def _sym(name: String) -> Int:
    var n = name
    var anywhere = -2 if CompilationTarget.is_macos() else 0  # RTLD_DEFAULT
    return external_call["dlsym", Int](anywhere, n.as_c_string_span())


def exe_path() -> String:
    """The running program's own path ("" if the system won't say): /proc/self/exe on Linux, _NSGetExecutablePath on
    the Mac; both looked up at run time (no new symbols to link)."""
    var buf = List[UInt8](length=4097, fill=0)
    var n = 0
    if CompilationTarget.is_macos():
        var f = _sym("_NSGetExecutablePath")
        if f == 0:
            return ""
        var size = List[UInt32](length=1, fill=4096)
        var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=f)
        if Pointer(to=raw).unsafe_bitcast[def(Int, Int) thin abi("C") -> c_int]()[](Int(buf.unsafe_ptr()), Int(size.unsafe_ptr())) != 0:
            return ""
        while n < 4096 and buf[n] != 0:
            n += 1
    else:
        var f = _sym("readlink")
        if f == 0:
            return ""
        var link = String("/proc/self/exe")
        var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=f)
        n = Pointer(to=raw).unsafe_bitcast[def(Int, Int, Int) thin abi("C") -> Int]()[](Int(link.as_c_string_span().unsafe_ptr()), Int(buf.unsafe_ptr()), 4096)
        _ = link.byte_length()
        if n <= 0:
            return ""
    buf.resize(n, 0)
    return String(unsafe_from_utf8=buf)


def exe_dir() -> String:
    """The folder the running program is in ("." if unknown)."""
    var p = exe_path()
    var cut = p.rfind("/")
    return String(p[byte=:cut]) if cut > 0 else String(".")


def answers(health_url: String, timeout_ms: Int = 500) -> Bool:
    """True when `health_url` answers 200 (plain HTTP to a local service: any build has the socket transport)."""
    var r = SocketTransport.send(Request.get(0, health_url).timeout(timeout_ms))
    return r.error == "" and r.status == 200


def parent_gone() -> Bool:
    """In a helper a Companion started: True once the app that started it has ended (it was reparented away from the
    pid in MOJOUI_PARENT_PID). False when not started by a Companion."""
    from std.os import getenv
    var want = getenv("MOJOUI_PARENT_PID")
    if want == "":
        return False
    var f = _sym("getppid")
    if f == 0:
        return False
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=f)
    var now = Int(Pointer(to=raw).unsafe_bitcast[def() thin abi("C") -> c_int]()[]())
    try:
        return now != atol(want)
    except:
        return False


struct Companion(Movable):
    var procs: List[Process]  # the helper this app started (none: it was running already, or not started yet)

    def __init__(out self):
        self.procs = List[Process]()

    def ensure(mut self, health_url: String, argv: List[String], log: String, env: List[String] = List[String](), wait_ms: Int = 20_000) -> String:
        """"" once something answers at `health_url`: already there, or `argv` started now and up within `wait_ms`;
        else why not (the helper missing, or it exited: its log's last lines)."""
        if answers(health_url):
            return ""
        if len(self.procs) > 0:
            return "already started; not answering at " + health_url
        var p: Process
        var with_parent = env.copy()
        with_parent.append("MOJOUI_PARENT_PID=" + String(libc.getpid()))
        try:
            p = Process.start(argv, log, with_parent)
        except e:
            return "couldn't start " + (argv[0] if len(argv) > 0 else String("the helper")) + ": " + String(e)
        var until = now_ns() + wait_ms * 1_000_000
        while now_ns() < until:
            if answers(health_url, 300):
                self.procs.append(p^)
                return ""
            if not p.running():
                return (argv[0] if len(argv) > 0 else String("the helper")) + " exited (" + String(p.exit_code()) + "); see " + log
            _ = libc.poll(0, 0, 100)
        self.procs.append(p^)
        return "started, but nothing answered at " + health_url + " within " + String(wait_ms // 1000) + " s; see " + log

    def started(self) -> Bool:
        return len(self.procs) > 0

    def stop(mut self, grace_ms: Int = 10_000):
        """Stops the helper if this app started it (TERM, then KILL after `grace_ms`); one it found running stays."""
        for i in range(len(self.procs)):
            _ = self.procs[i].stop(grace_ms)
        self.procs = List[Process]()
