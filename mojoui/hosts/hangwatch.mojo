# The hang monitor (goal 81, M5): a thread that says when the UI thread has been at one thing for too long, while it is
# still at it, and again when it ends:
#   HANG: 512 ms and counting: update msg=12
#   HANG: ended after 1204 ms: update msg=12 (1203 ms)
# On stdout and, with the time, in hangs.log in the app's state folder (~/.local/state/omxcode/<app>; on the Mac
# ~/Library/Logs/omxcode/<app>), at most 200 lines. Always on (MOJOUI_HANGS=0: off; a MOJOUI_TEST run: off unless
# MOJOUI_HANGS=1; MOJOUI_HANGS_MS: the limit, 500; MOJOUI_STATE: the folder). While the app is idle the thread sleeps in
# poll() and costs nothing; while it's busy it looks 10 times a second.
# The host calls turn_begins/turn_ends around its main loop's wait (GTK: its poll function; AppKit: a run-loop observer).
from std.ffi import external_call, c_int
from std.os import getenv, makedirs
from std.os.path import basename
from std.sys import argv, CompilationTarget
from std.memory import Pointer
from std.memory.alloc import alloc, Layout
from mojoui import libc
from mojoui.clock import now_ns, wall_seconds
from mojoui.hangmarks import (
    read, put, mark_name, turn_begins, turn_ends, M_BUSY, M_SINCE, M_TURN, M_DEPTH, M_OPEN, M_END_NS, M_END_WHAT, M_END_NUMBER, M_END_LONG, M_ASLEEP, M_PIPE, M_ARMED, M_LIMIT, M_WORDS,
)

comptime LOG_LINES = 200
comptime LOOK_US = 100_000
comptime P_READ = M_WORDS  # (after the marks: the pipe's read end, the log's path)
comptime P_PATH = M_WORDS + 1


def state_folder() -> String:
    var s = getenv("MOJOUI_STATE")
    if s != "":
        return s
    var name = String("app")
    if len(argv()) > 0:
        name = basename(String(argv()[0]))
    comptime if CompilationTarget.is_macos():
        return getenv("HOME") + "/Library/Logs/omxcode/" + name
    var base = getenv("XDG_STATE_HOME")
    return (base if base != "" else getenv("HOME") + "/.local/state") + "/omxcode/" + name


def hang_watch() -> Int:
    """Starts the watcher (once): the marks' address, or 0 when it's off."""
    var on = getenv("MOJOUI_HANGS")
    if on == "0" or (on == "" and getenv("MOJOUI_TEST") != ""):
        return 0
    var limit = 500
    try:
        limit = Int(getenv("MOJOUI_HANGS_MS"))
    except:
        pass
    var fds = List[Int32](length=2, fill=-1)
    if libc.pipe(Int(fds.unsafe_ptr())) != 0:
        return 0
    var words = alloc(Layout[Int64](count=M_WORDS + 8)).unsafe_leak()  # (lives as long as the app)
    var addr = Int(words)
    for k in range(M_WORDS + 8):
        put(addr, k, 0)
    _ = libc.fcntl(Int(fds[0]), 2, 1)  # F_SETFD, FD_CLOEXEC
    _ = libc.fcntl(Int(fds[1]), 2, 1)
    put(addr, P_READ, Int(fds[0]))
    put(addr, M_PIPE, Int(fds[1]) + 1)
    put(addr, M_LIMIT, limit * 1_000_000)
    _ = len(fds)
    var tid = List[Int](length=1, fill=0)
    if libc.pthread_create[_watch](addr, Int(tid.unsafe_ptr())) != 0:
        return 0
    _ = libc.pthread_detach(tid[0])
    return addr


def loop_wakes(addr: Int):
    """The main loop stopped waiting."""
    if addr == 0:
        return
    turn_begins(addr)
    if read(addr, M_ASLEEP) != 0:
        put(addr, M_ASLEEP, 0)
        var b = List[UInt8](length=1, fill=1)
        _ = libc.write_fd(read(addr, M_PIPE) - 1, Int(b.unsafe_ptr()), 1)
        _ = len(b)


def loop_waits(addr: Int):
    """The main loop is about to wait."""
    turn_ends(addr)


def two(v: Int) -> String:
    return ("0" if v < 10 else "") + String(v)


def stamp() -> String:
    """Now, as 2026-11-24T08:40:12Z (civil-from-days, Howard Hinnant)."""
    var t = Int(wall_seconds())
    var z = t // 86400 + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    var y = yoe + era * 400 + (1 if m <= 2 else 0)
    var s = t % 86400
    return String(y) + "-" + two(m) + "-" + two(d) + "T" + two(s // 3600) + ":" + two(s // 60 % 60) + ":" + two(s % 60) + "Z"


def say(line: String):
    print("HANG: " + line, flush=True)
    var folder = state_folder()
    var path = folder + "/hangs.log"
    try:
        makedirs(folder, exist_ok=True)
        var lines = List[String]()
        try:
            var f = open(path, "r")
            for l in f.read().split("\n"):
                if String(l) != "":
                    lines.append(String(l))
            f.close()
        except:
            pass
        var new = stamp() + " " + line + "\n"
        if len(lines) < LOG_LINES:  # (appended: another copy of the app may be writing too)
            var f = open(path, "a")
            f.write(new)
            f.close()
            return
        lines.append(stamp() + " " + line)
        var out = String("")
        for k in range(max(len(lines) - LOG_LINES, 0), len(lines)):
            out += lines[k] + "\n"
        var f = open(path, "w")
        f.write(out)
        f.close()
    except:
        pass  # (no folder to write in: stdout has it)


def now_doing(addr: Int) -> String:
    """The innermost mark open now."""
    var d = min(read(addr, M_DEPTH), 8) - 1
    if d < 0:
        return mark_name(0, 0)
    return mark_name(read(addr, M_OPEN + 3 * d), read(addr, M_OPEN + 3 * d + 1))


def look(addr: Int, mut said_turn: Int, mut said_at: Int) -> Bool:
    """Says what there is to say; True while the main loop is busy."""
    var busy = read(addr, M_BUSY) != 0
    var ended = read(addr, M_END_NS)
    if ended != 0:
        put(addr, M_END_NS, 0)
        var longest = read(addr, M_END_LONG)
        say("ended after " + String(ended // 1_000_000) + " ms: " + mark_name(read(addr, M_END_WHAT) if longest > 0 else 0, read(addr, M_END_NUMBER))
            + (" (" + String(longest // 1_000_000) + " ms)" if longest > 0 else ""))
    if busy and read(addr, M_ARMED) > 0:
        var turn = read(addr, M_TURN)
        var so_far = now_ns() - read(addr, M_SINCE)
        var due = said_at + 5_000_000_000 if turn == said_turn else read(addr, M_LIMIT)  # (again every 5 s)
        if so_far > due and read(addr, M_TURN) == turn:
            say(String(so_far // 1_000_000) + " ms and counting: " + now_doing(addr))
            said_turn = turn
            said_at = so_far
    return busy


def _watch(arg: libc.ThreadArg) -> libc.ThreadArg:
    var addr = Int(arg)
    var said_turn = -1
    var said_at = 0
    var last = -1
    var quiet = 0
    while True:
        var busy = look(addr, said_turn, said_at)
        var turn = read(addr, M_TURN)
        quiet = quiet + 1 if not busy and turn == last else 0
        last = turn
        if quiet < 20:
            _ = libc.usleep(LOOK_US)
            continue
        put(addr, M_ASLEEP, 1)  # (idle for 2 s: sleep until the main loop wakes)
        if read(addr, M_TURN) == turn and read(addr, M_BUSY) == 0:
            var fd = List[Int32](length=2, fill=0)  # struct pollfd
            fd[0] = Int32(read(addr, P_READ))
            fd[1] = 1  # POLLIN
            _ = libc.poll(Int(fd.unsafe_ptr()), 1, -1)
            _ = len(fd)
            var b = List[UInt8](length=16, fill=0)
            _ = libc.read_fd(read(addr, P_READ), Int(b.unsafe_ptr()), 16)
            _ = len(b)
        put(addr, M_ASLEEP, 0)
        quiet = 0
