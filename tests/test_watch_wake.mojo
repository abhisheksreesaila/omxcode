# mojoui.watch's wake (goal 58 polish, D-5808): a watcher made with wake=True wakes the host through mojoui.wake.UIWaker
# after each batch, as jobs and FrameFeed do; one made without it doesn't.
#   pixi run mojo run -I . tests/test_watch_wake.mojo
# Prints "watch wake: ok". Linux: the process's job-wake pipe (mojoui.shared slot 90, made here as a host makes it) gets a
# byte when a file lands in the watched folder, and only from the waking watcher. A Mac's wake is jobsEnded: on the main
# queue, which only a running AppKit app drains (no app here: the pipe stays quiet, so the Mac prints "skipped").
from std.testing import assert_true, assert_false
from std.ffi import c_int
from std.sys import CompilationTarget
from mojoui.watch import FolderWatcher, _c
from mojoui.shared import put_shared
from mojoui.wake import SLOT_WAKE_WRITE
from mojoui.clock import now_ns


def readable(fd: Int, ms: Int) -> Bool:
    var pfd = List[Int32](length=2, fill=0)  # struct pollfd { int fd; short events; short revents }
    pfd[0] = Int32(fd)
    pfd[1] = Int32(1)  # POLLIN
    var n = Int(_c[c_int]("poll", Int(pfd.unsafe_ptr()), Int(1), c_int(ms)))
    _ = len(pfd)
    return n > 0


def drain(fd: Int):
    var buf = List[UInt8](length=256, fill=0)
    while readable(fd, 0):
        if _c[Int]("read", c_int(fd), Int(buf.unsafe_ptr()), 256) <= 0:
            break
    _ = len(buf)


def touch(path: String):
    var p = path
    var mode = String("w")
    var f = _c[Int]("fopen", Int(p.as_c_string_span().unsafe_ptr()), Int(mode.as_c_string_span().unsafe_ptr()))
    _ = _c[c_int]("fputs", Int(mode.as_c_string_span().unsafe_ptr()), f)
    _ = _c[c_int]("fclose", f)
    _ = p.byte_length()
    _ = mode.byte_length()


def ready(mut w: FolderWatcher) raises:
    w.start()
    var t0 = now_ns()
    while not w.ready():
        if w.failed() or now_ns() - t0 > 5_000_000_000:
            raise Error("the watcher didn't get ready: " + w.why())
        _ = w.wait(5)


def main() raises:
    comptime if not CompilationTarget.is_linux():
        print("watch wake: skipped (a Mac wakes through jobsEnded:, which needs a running AppKit app)")
        return
    var dir = String("/tmp/watchwake-") + String(Int(_c[c_int]("getpid")))
    var made = _c[c_int]("mkdir", Int(dir.as_c_string_span().unsafe_ptr()), c_int(0o700))
    assert_true(Int(made) == 0, "no temp folder " + dir)
    var fds = List[Int32](length=2, fill=-1)
    assert_true(Int(_c[c_int]("pipe", Int(fds.unsafe_ptr()))) == 0)
    var r = Int(fds[0])
    put_shared(SLOT_WAKE_WRITE, Int(fds[1]) + 1)  # (as mojoui.jobs.wake_pipe does: the host's pipe)

    var quiet = FolderWatcher(dir + "/", wake=False)
    ready(quiet)
    touch(dir + "/a.txt")
    var t0 = now_ns()
    var got = 0
    while got == 0 and now_ns() - t0 < 2_000_000_000:  # (the quiet watcher still sees it)
        got = len(quiet.take())
        _ = quiet.wait(20)
    assert_true(got > 0, "the quiet watcher saw nothing")
    assert_false(readable(r, 200), "a watcher made without wake woke the host")
    quiet.stop()

    var waking = FolderWatcher(dir, wake=True)
    ready(waking)
    drain(r)
    touch(dir + "/b.txt")
    assert_true(readable(r, 2000), "no wake within 2 s of a file landing")
    var events = waking.take()
    assert_true(len(events) > 0, "woken, but nothing to take")
    waking.stop()
    var rm = String("rm -r ") + dir
    _ = _c[c_int]("system", Int(rm.as_c_string_span().unsafe_ptr()))
    _ = rm.byte_length()
    print("watch wake: ok")
