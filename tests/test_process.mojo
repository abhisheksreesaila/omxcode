# Goal 50 M3: mojoui.process with real children: args, env and the log; a health probe (build/serve_demo, the M2
# server); a crash's exit code and log tail; stop() on a child that ignores SIGTERM (SIGKILL after the grace) and on a
# child with children of its own (the whole group goes); idle time; a dropped Process stops its child.
from mojoui.process import Process, healthy, file_tail
from mojoui.clock import now_ns
from mojoui import libc

comptime DIR = "build/g50"


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def group_alive(pgid: Int) -> Bool:
    """Is any process left in group `pgid`? (kill with signal 0 only asks.)"""
    return libc.kill(-pgid, 0) == 0


def main() raises:
    var tag = String(now_ns() % 1_000_000)
    # args, env, the log
    var log = DIR + "/proc-" + tag + ".log"
    var p = Process.start(["sh", "-c", "echo hello $G50_X; echo oops >&2; sleep 30"], log, ["G50_X=42"])
    _ = libc.poll(0, 0, 300)
    check(p.running(), "the child isn't running")
    var text = file_tail(log)
    check(text.find("hello 42") >= 0 and text.find("oops") >= 0, "the log: " + text)
    check(p.stop(2000) == 128 + 15, "SIGTERM'd: " + String(p.code))
    print("START: pid " + String(p.pid) + ", env and both streams in the log; stopped by SIGTERM")
    # health: the M2 server
    var port = 18800 + Int(now_ns() % 500)
    var srv = Process.start(["build/serve_demo", String(port)], DIR + "/proc-serve-" + tag + ".log")
    var t0 = now_ns()
    check(srv.wait_healthy("http://127.0.0.1:" + String(port) + "/items/1", 20_000), "serve_demo never got healthy: " + srv.log_tail())
    var up_ms = (now_ns() - t0) // 1_000_000
    _ = srv.stop()
    check(not healthy("http://127.0.0.1:" + String(port) + "/items/1"), "still answering after stop")
    print("HEALTH: serve_demo answered after " + String(up_ms) + " ms; gone after stop")
    # a crash
    var c = Process.start(["sh", "-c", "echo dying now; exit 3"], DIR + "/proc-crash-" + tag + ".log")
    check(not c.wait_healthy("http://127.0.0.1:9/", 3000), "a crashing child reported healthy")
    check(c.exit_code() == 3 and c.log_tail().find("dying now") >= 0, "crash: " + String(c.exit_code()) + " " + c.log_tail())
    print("CRASH: exit 3, the log's tail says why")
    # SIGTERM ignored → SIGKILL after the grace; a group with children
    var marker = "6" + tag  # (sleep's argument: seconds, unique to this run)
    var stubborn = Process.start(["sh", "-c", "trap '' TERM; sleep " + marker + " & sleep " + marker + "; wait"], DIR + "/proc-kill-" + tag + ".log")
    _ = libc.poll(0, 0, 300)
    check(group_alive(stubborn.pid), "the child's group isn't there")
    t0 = now_ns()
    var code = stubborn.stop(600)
    var took = (now_ns() - t0) // 1_000_000
    _ = libc.poll(0, 0, 200)
    check(code == 128 + 9 or code == 128 + 15, "stop's code " + String(code))
    check(not group_alive(stubborn.pid), "the group's sleeps outlived stop")
    print("STOP: the group went in " + String(took) + " ms (code " + String(code) + ")")
    # idle, and a dropped Process
    var idle = Process.start(["sleep", "7" + tag], DIR + "/proc-idle-" + tag + ".log")
    idle.touch()
    _ = libc.poll(0, 0, 300)
    check(idle.idle_ms() >= 290, "idle " + String(idle.idle_ms()))
    idle.touch()
    check(idle.idle_ms() < 50, "touch didn't reset idle")
    var idle_pid = idle.pid
    _ = idle^
    _ = libc.poll(0, 0, 300)
    check(not group_alive(idle_pid), "a dropped Process left its child running")
    print("IDLE: counted from touch(); a dropped Process stops its child")
    print("process: ok")
