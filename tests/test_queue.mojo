# mojoui.jobs, the server queue (goal 60 round 3, R6, R10, S-L6): a claim race across threads claims each job once;
# a failed run comes back after its backoff, then dies at max attempts (a permanent error at once); a crash's running
# jobs resume; add_in() lives and dies with its transaction (the outbox); sweep() deletes old done and dead jobs.
from std.os import makedirs, remove
from std.os.path import exists
from std.memory import Pointer
from std.atomic import Atomic
from mojoui.jobs import Queue, QueuedJob, permanent, PERMANENT
from mojoui.sqlite import Database
from mojoui.serve import spawn
from mojoui.clock import wall_seconds
from mojoui import libc

comptime _A = Atomic[Scalar[DType.int64]]
comptime JOBS = 2000
comptime THREADS = 8
comptime PATH = "build/test_queue_files/host.db"


def expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def claimer(addr: Int):
    """Claims until nothing is due: word 0 counts finished threads, word 1 errors, words 2.. each job's claims."""
    var w = Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=addr)
    try:
        var q = Queue(PATH, backoff_ms=1000, max_attempts=3)
        while True:
            var j = q.claim()
            if not j:
                break
            _ = _A.fetch_add(w + 2 + j.value().id, 1)
            q.finish(j.value(), "")
    except e:
        print("claimer: " + String(e))
        _ = _A.fetch_add(w + 1, 1)
    _ = _A.fetch_add(w, 1)


def status(db: Database, id: Int) raises -> String:
    return db.one_text("SELECT status FROM jobs WHERE id = ?", [String(id)])


def main() raises:
    if not exists("build/test_queue_files"):
        makedirs("build/test_queue_files")
    for suffix in ["", "-wal", "-shm"]:
        if exists(PATH + suffix):
            remove(PATH + suffix)
    var q = Queue(PATH, backoff_ms=1000, max_attempts=3)
    var db = q.db()
    db.begin()
    for i in range(JOBS):
        _ = q.add_in(db, "k", '{"n": ' + String(i) + "}")
    db.commit()
    var w = List[Int64](length=JOBS + 3, fill=0)
    for _ in range(THREADS):
        if not spawn[claimer](Int(w.unsafe_ptr())):
            raise Error("no thread")
    var waited = 0
    while _A.load(w.unsafe_ptr()) < THREADS and waited < 600:
        _ = libc.poll(0, 0, 100)
        waited += 1
    expect(_A.load(w.unsafe_ptr()) == THREADS and w[1] == 0, "claimers: " + String(w[0]) + " finished, " + String(w[1]) + " failed")
    for id in range(1, JOBS + 1):
        expect(w[2 + id] == 1, "job " + String(id) + " claimed " + String(w[2 + id]) + " times")
    expect(db.count("SELECT count(*) FROM jobs WHERE status = 'done'") == JOBS, "every job done")
    _ = len(w)
    print("claim_race: ok (" + String(JOBS) + " jobs, " + String(THREADS) + " threads, each claimed once)")
    # a failure: back after backoff·2^(n−1), then dead at max attempts with the reason
    var id = q.add("k", "{}")
    var j = q.claim()
    expect(j and j.value().id == id and j.value().attempts == 1, "the new job claimed")
    var t0 = wall_seconds()
    q.finish(j.value(), "451 try later")
    var run_at = Float64(db.one_text("SELECT run_at FROM jobs WHERE id = ?", [String(id)]))
    expect(status(db, id) == "pending" and run_at >= t0 + 0.99 and run_at <= t0 + 1.5, "first backoff ~1 s: " + String(run_at - t0))
    expect(not q.claim(), "claimed before its backoff")
    _ = db.run("UPDATE jobs SET run_at = 0 WHERE id = ?", [String(id)])
    j = q.claim()
    t0 = wall_seconds()
    q.finish(j.value(), "451 try later")
    run_at = Float64(db.one_text("SELECT run_at FROM jobs WHERE id = ?", [String(id)]))
    expect(run_at >= t0 + 1.99 and run_at <= t0 + 2.5, "second backoff ~2 s: " + String(run_at - t0))
    _ = db.run("UPDATE jobs SET run_at = 0 WHERE id = ?", [String(id)])
    j = q.claim()
    expect(j.value().attempts == 3, "the third attempt")
    q.finish(j.value(), "451 still")
    expect(status(db, id) == "dead" and db.one_text("SELECT error FROM jobs WHERE id = ?", [String(id)]) == "451 still", "dead after 3 attempts with the reason")
    var p = q.add("k", "{}")
    var pj = q.claim()
    q.finish(pj.value(), permanent("550 no such mailbox"))
    expect(status(db, p) == "dead" and db.one_text("SELECT attempts FROM jobs WHERE id = ?", [String(p)]) == "1", "a permanent error is dead at once")
    expect(permanent(permanent("x")) == PERMANENT + "x", "permanent() twice")
    print("backoff: ok")
    # a crash mid-run: the running job goes back to pending at start, and runs again
    var c = q.add("k", "{}")
    _ = q.claim()
    expect(status(db, c) == "running", "claimed")
    var q2 = Queue(PATH, backoff_ms=1000, max_attempts=3)  # (the restarted process's queue)
    expect(q2.resume() == 1 and status(db, c) == "pending", "resumed")
    var again = q2.claim()
    expect(again and again.value().id == c and again.value().attempts == 2, "it runs again (at least once)")
    q2.finish(again.value(), "")
    print("resume: ok")
    # the outbox: a job written in a transaction that rolls back never exists
    var before = db.count("SELECT count(*) FROM jobs")
    db.begin()
    _ = db.run("CREATE TABLE IF NOT EXISTS invites(id INTEGER PRIMARY KEY, email TEXT)")
    _ = db.run("INSERT INTO invites(email) VALUES ('x@example.com')")
    _ = q.add_in(db, "invite", '{"invite": 1}')
    _ = db.rollback_quiet()  # (the crash between the row and the job, or a failed change)
    expect(db.count("SELECT count(*) FROM jobs") == before, "a rolled-back job exists")
    var raised = False
    try:
        _ = q.add_in(Database("build/test_queue_files/other.db"), "k", "{}")
    except:
        raised = True
    expect(raised, "add_in on another file")
    print("outbox: ok")
    # retention: old done and dead jobs go, new ones and pending ones stay
    var old = wall_seconds() - 40 * 86400
    _ = db.run("UPDATE jobs SET updated = ? WHERE status IN ('done', 'dead')", [String(old)])
    var fresh = q.add("k", "{}")
    var fj = q.claim()
    q.finish(fj.value(), "")
    var waiting = q.add("k", "{}", delay_s=3600)
    var gone = q.sweep()
    expect(gone == JOBS + 3, "swept " + String(gone))
    expect(status(db, fresh) == "done" and status(db, waiting) == "pending", "a new done job or a pending one swept")
    print("sweep: ok (" + String(gone) + " old jobs deleted)")
