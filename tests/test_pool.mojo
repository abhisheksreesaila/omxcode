# mojoui.sqlite's Pool under many tenants (goal 60 round 3, R2): the pool's connections hold at most budget() file descriptors,
# least recently used closed first, never one with a live statement or one holding its file's writer lock. Run under a
# low open-file limit (the checker: `ulimit -n 256`): 500 tenant files from one thread, then from 8 threads at once.
# Before the cap, the 85th file or so failed with "unable to open database file" (EMFILE).
from std.os import makedirs, remove, listdir
from std.os.path import exists
from std.memory import Pointer
from std.atomic import Atomic
from mojoui.sqlite import Database, Pool
from mojoui.serve import spawn
from mojoui import libc

comptime _A = Atomic[Scalar[DType.int64]]
comptime N = 500
comptime THREADS = 8


def expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def tenant(i: Int) -> String:
    return "build/test_pool_files/t" + String(i) + ".db"


def touch(pool: Pool, i: Int, who: Int) raises:
    var db = pool.open(tenant(i), "CREATE TABLE IF NOT EXISTS rows(who INTEGER, at INTEGER)")
    db.begin()
    try:
        var q = db.prepare("INSERT INTO rows(who, at) VALUES (?, ?)")
        q.bind(1, who)
        q.bind(2, i)
        q.run()
        db.commit()
    except e:
        _ = db.rollback_quiet()
        raise e^


def worker(addr: Int):
    var w = Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=addr)  # [done, failed]
    try:
        var pool = Pool.shared()
        for i in range(N):
            touch(pool, i, 1)
            if pool.fds_now() > pool.budget() + 3 * THREADS:
                raise Error("over the budget: " + String(pool.fds_now()))
    except e:
        var why = String(e)
        try:
            var p = Pool.shared()
            why += " (" + String(p.fds_now()) + " counted, budget " + String(p.budget()) + ", " + String(len(listdir("/proc/self/fd"))) + " fds)"
        except:
            pass
        print("worker: " + why)
        _ = _A.fetch_add(w + 1, 1)
    _ = _A.fetch_add(w, 1)


def main() raises:
    if not exists("build/test_pool_files"):
        makedirs("build/test_pool_files")
    for i in range(N):
        for suffix in ["", "-wal", "-shm"]:
            if exists(tenant(i) + suffix):
                remove(tenant(i) + suffix)
    var lim = libc.nofile_limit()
    print("open-file limit: " + String(lim[0]) + " soft, " + String(lim[1]) + " hard")
    var pool = Pool.shared()
    var cap = pool.budget()
    expect(cap >= 24 and cap <= max(lim[0], 1) // 2, "a budget past half the limit: " + String(cap))
    for i in range(N):
        touch(pool, i, 0)
    expect(pool.fds_now() <= cap, String(pool.fds_now()) + " descriptors, budget " + String(cap))
    var real = len(listdir("/proc/self/fd")) if exists("/proc/self/fd") else 0
    print("tenants: ok (" + String(N) + " files from one thread, " + String(pool.open_here()) + " open, " + String(pool.fds_now()) + " descriptors counted, " + String(real) + " in the process, budget " + String(cap) + ")")
    # a live statement and the writer lock's holder are never closed
    var a = pool.open(tenant(0))
    a.begin()
    var b = pool.open(tenant(1))
    var q = b.prepare("SELECT count(*) FROM rows")
    for i in range(2, 200):
        touch(pool, i, 0)
    var ins = a.prepare("INSERT INTO rows(who, at) VALUES (9, 9)")
    ins.run()
    a.commit()
    expect(q.step() and q.int(0) >= 1, "a statement held across evictions")
    q.reset()
    var again = pool.open(tenant(0))
    expect(again.count("SELECT count(*) FROM rows WHERE who = 9") == 1, "the held transaction's row")
    again.begin()  # (its writer lock was released: this would deadlock otherwise)
    again.commit()
    print("held: ok")
    var w = List[Int64](length=2, fill=0)
    for _ in range(THREADS):
        if not spawn[worker](Int(w.unsafe_ptr())):
            raise Error("no thread")
    var waited = 0
    while _A.load(w.unsafe_ptr()) < THREADS and waited < 1200:
        _ = libc.poll(0, 0, 100)
        waited += 1
    expect(_A.load(w.unsafe_ptr()) == THREADS, "threads didn't finish")
    expect(w[1] == 0, String(w[1]) + " threads failed")
    var total = 0
    for i in range(N):
        total += pool.open(tenant(i)).count("SELECT count(*) FROM rows WHERE who = 1")
    expect(total == N * THREADS, "rows written by the threads: " + String(total))
    _ = len(w)
    expect(pool.fds_now() <= cap, "after the threads: " + String(pool.fds_now()) + " descriptors, budget " + String(cap))
    print("threads: ok (" + String(THREADS) + " threads × " + String(N) + " files)")
