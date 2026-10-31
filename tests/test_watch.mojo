# mojoui.watch (goal 45 M0): watches $MOJOUI_WATCH_DIR (made for the run; docs/goals/45-check.py writes 1,000 changes
# into it while this runs) and prints one line per change until it's stopped (or $MOJOUI_WATCH_SECONDS pass):
#   WATCH READY                                         every folder has its watch
#   WATCH THREAD: reader=<tid> main=<tid>               inotify is read on a thread of its own
#   WATCH EVENT: <kind> <path> ms=<lag> at=<ns>         kind create/modify/rename/delete; at = when the watcher's thread
#                                                       saw it (CLOCK_MONOTONIC)
# The lag here is the test's own estimate, from the file system's timestamps (the file's ctime for a write or a
# rename, its folder's for a delete) brought onto the monotonic clock; the checker measures the real one itself.
#   pixi run mojo run -I . tests/test_watch.mojo
from std.ffi import external_call, c_int
from std.os import getenv
from mojoui.watch import FolderWatcher, DELETED, OVERFLOW, _c
from mojoui.clock import now_ns


def _clock(id: Int) -> Int:
    var ts = List[Int](length=2, fill=0)
    _ = _c[c_int]("clock_gettime", c_int(id), Int(ts.unsafe_ptr()))
    return ts[0] * 1_000_000_000 + ts[1]


def ctime_ns(path: String) -> Int:
    """The path's ctime (CLOCK_REALTIME ns), 0 if it's gone (struct stat on x86-64 Linux: st_ctim at byte 104)."""
    var st = List[Int](length=18, fill=0)
    var p = path
    var rc = _c[c_int]("stat", Int(p.as_c_string_span().unsafe_ptr()), Int(st.unsafe_ptr()))
    if Int(rc) != 0:
        return 0
    return st[13] * 1_000_000_000 + st[14]


def main() raises:
    var dir = getenv("MOJOUI_WATCH_DIR")
    if dir == "":
        raise Error("set MOJOUI_WATCH_DIR")
    var seconds = Int(getenv("MOJOUI_WATCH_SECONDS", "600"))
    var w = FolderWatcher(dir)
    w.start()
    var t0 = now_ns()
    while not w.ready():
        if w.failed():
            raise Error(w.why())
        if now_ns() - t0 > 5_000_000_000:
            raise Error("the watcher didn't get ready in 5 s")
        _ = w.wait(5)
    print("WATCH THREAD: reader=" + String(w.reader_thread()) + " main=" + String(Int(_c[c_int]("gettid"))), flush=True)
    print("WATCH READY", flush=True)
    var end = now_ns() + seconds * 1_000_000_000
    var n = 0
    while now_ns() < end:
        if not w.wait(100):
            continue
        for e in w.take():
            if e.kind == OVERFLOW:
                print("WATCH OVERFLOW", flush=True)
                continue
            if e.is_dir:
                continue
            var offset = _clock(0) - _clock(1)  # realtime − monotonic, now
            var changed = ctime_ns(String(e.path[byte=: e.path.rfind("/")]) if e.kind == DELETED else e.path)
            var lag = Float64(e.at_ns - (changed - offset)) / 1e6 if changed > 0 else 0.0
            print("WATCH EVENT: " + e.kind_name() + " " + e.path + " ms=" + String(max(lag, 0.0)) + " at=" + String(e.at_ns), flush=True)
            n += 1
    w.stop()
    var t1 = now_ns()
    while not w.stopped() and now_ns() - t1 < 1_000_000_000:
        _ = w.wait(10)
    print("WATCH DONE: " + String(n) + " events", flush=True)
