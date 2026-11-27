# mojoui.filewatch (goal 82 M7): a write to a watched file is seen by the system's file events, without its writer closing it
# (a database's WAL), within 300 ms; other files in its folder aren't counted; a file put in place by a rename is; a
# second SQLite connection's commits are seen while both connections stay open. Linux (inotify) and the Mac (FSEvents).
# FACT lines: the worst latency from a write to the watcher seeing it. filewatch: ok
from std.testing import assert_true, assert_equal
from std.os import makedirs, getenv
from mojoui.filewatch import FileWatch
from mojoui.clock import now_ns
from mojoui.files import remove_tree
from mojoui.libc import open_append, write_fd, close, rename, usleep
from mojoui.sqlite import Database


def seen_within(mut w: FileWatch, before: Int, t0: Int, ms: Int) -> Int:
    """How long (µs) after t0 the count passed `before`; -1 if not within `ms`."""
    while now_ns() - t0 < ms * 1_000_000:
        if w.count() > before:
            return (w.last_ns() - t0) // 1000
        _ = usleep(1000)
    return -1


def main() raises:
    var dir = getenv("FILEWATCH_DIR", "build/test_filewatch")
    remove_tree(dir)
    makedirs(dir, exist_ok=True)
    var db = dir + "/notes.db"
    var w = FileWatch([db, db + "-wal", db + "-journal"])
    w.start()
    var t = now_ns()
    while not w.ready() and not w.failed() and now_ns() - t < 2_000_000_000:
        _ = usleep(1000)
    assert_true(w.ready(), "watching: " + w.why())
    var worst = 0
    # 1. written in place, never closed (as a WAL is)
    var fd = open_append(db + "-wal")
    _ = usleep(150_000)
    _ = w.changed()
    for k in range(5):
        var before = w.count()
        var msg = String("record ") + String(k) + "\n"
        var t0 = now_ns()
        _ = write_fd(fd, Int(msg.unsafe_ptr()), msg.byte_length())
        var us = seen_within(w, before, t0, 300)
        assert_true(us >= 0, "an open file's write seen within 300 ms")
        worst = max(worst, us)
        _ = usleep(20_000)
    assert_true(w.changed() and not w.changed(), "changed() once for what came since")
    # 2. another file in the folder isn't counted
    _ = usleep(100_000)
    var before = w.count()
    var other = open_append(dir + "/other.txt")
    var x = String("not watched")
    _ = write_fd(other, Int(x.unsafe_ptr()), x.byte_length())
    _ = close(other)
    _ = usleep(200_000)
    assert_equal(w.count(), before, "a file not asked about")
    # 3. put in place by a rename
    var tmp = open_append(dir + "/notes.db.tmp")
    _ = write_fd(tmp, Int(x.unsafe_ptr()), x.byte_length())
    _ = close(tmp)
    _ = usleep(100_000)
    before = w.count()
    var t1 = now_ns()
    _ = rename(dir + "/notes.db.tmp", db)
    var us = seen_within(w, before, t1, 300)
    assert_true(us >= 0, "a rename onto the name")
    worst = max(worst, us)
    _ = close(fd)
    # 4. two SQLite connections in WAL mode, both kept open: the other's commits are seen
    _ = usleep(100_000)
    var mine = Database(db + "2")
    var w2 = FileWatch([db + "2", db + "2-wal", db + "2-journal"])
    w2.start()
    t = now_ns()
    while not w2.ready() and now_ns() - t < 2_000_000_000:
        _ = usleep(1000)
    mine.exec("PRAGMA journal_mode=WAL")
    mine.exec("CREATE TABLE IF NOT EXISTS t (v TEXT)")
    var theirs = Database(db + "2")
    _ = usleep(200_000)
    for k in range(10):
        before = w2.count()
        var t0 = now_ns()
        _ = theirs.run("INSERT INTO t (v) VALUES (?)", [String("row ") + String(k)])
        var u = seen_within(w2, before, t0, 300)
        assert_true(u >= 0, "another connection's commit seen within 300 ms")
        worst = max(worst, u)
        _ = usleep(30_000)
    assert_equal(mine.count("SELECT COUNT(*) FROM t"), 10)
    w.stop()
    w2.stop()
    print("FACT filewatch_worst_ms " + String(Float64(worst) / 1000.0), flush=True)
    print("filewatch: ok", flush=True)
