# mojoui.jobs: a durable job queue for servers (goal 60 M3; fh-saas's utils_bgtsk), in a SQLite file (host.db), run by
# worker threads of their own: never under a request, never under a lock other than SQLite's writer lock for a claim.
# (The UI's background jobs are mojoui.uijobs.)
#
#   var q = Queue(data + "/host.db", backoff_ms=1000, max_attempts=5)     # jobs(id, tenant, kind, payload, status, …)
#   _ = q.add("mail", payload_json, tenant=t)                             # durable once add() returns
#   start_workers(q, MyRunner(...), threads=2)                            # MyRunner(Runner).run(job) -> "" or the error
#   q.list_json(tenant)                                                   # a tenant's jobs for an admin page
#
# A job is `pending` → `running` (claimed, attempts + 1) → `done`; a run that returns an error goes back to `pending`
# with run_at = now + backoff·2^(attempts−1), and to `dead` (the error kept) once attempts reach max_attempts. At start,
# `resume()` puts jobs a killed process left `running` back to `pending`: delivery is at least once (a job may run twice
# after a crash, never zero times). Workers sleep on a pipe that add() writes to, so a new job starts at once.

from std.memory import Pointer
from std.sys import CompilationTarget
from std.memory.alloc import alloc, Layout
from mojoui.sqlite import Database, Pool
from mojoui.json import json_string
from mojoui.clock import wall_seconds
from mojoui import libc
from mojoui.serve import spawn

comptime SCHEMA = (
    "CREATE TABLE IF NOT EXISTS jobs(id INTEGER PRIMARY KEY, tenant TEXT, kind TEXT NOT NULL, payload TEXT NOT NULL,"
    " status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0, max_attempts INTEGER NOT NULL,"
    " run_at REAL NOT NULL, error TEXT, created REAL NOT NULL, updated REAL NOT NULL);"
    "CREATE INDEX IF NOT EXISTS jobs_due ON jobs(status, run_at);"
    "CREATE INDEX IF NOT EXISTS jobs_tenant ON jobs(tenant, id)"
)


@fieldwise_init
struct QueuedJob(Copyable, Movable):
    var id: Int
    var tenant: String
    var kind: String
    var payload: String
    var attempts: Int  # this run's number (1 for the first)
    var max_attempts: Int


trait Runner(Movable, Deinitable):
    """Runs a claimed job; called from every worker thread at once (keep its state read-only or thread-safe)."""

    def run(self, job: QueuedJob) -> String:
        """"" when it worked; otherwise why not (kept on the row; the job is retried, then dead)."""
        ...


struct Queue(ImplicitlyCopyable, Movable):
    var path: String
    var pool: Pool
    var backoff_ms: Int
    var max_attempts: Int
    var wake_r: Int
    var wake_w: Int

    def __init__(out self, path: String, backoff_ms: Int = 1000, max_attempts: Int = 5) raises:
        self.path = path
        self.pool = Pool.shared()
        self.backoff_ms = max(backoff_ms, 1)
        self.max_attempts = max(max_attempts, 1)
        var fds = List[Int32](length=2, fill=-1)
        if libc.pipe(Int(fds.unsafe_ptr())) != 0:
            raise Error("jobs: no wake pipe")
        self.wake_r = Int(fds[0])
        self.wake_w = Int(fds[1])
        _ = libc.fcntl(self.wake_w, 4, 0x800 if not _mac() else 0x4)  # (F_SETFL O_NONBLOCK: add() never blocks on a full pipe)
        self.db().exec(SCHEMA)

    def db(self) raises -> Database:
        return self.pool.open(self.path)

    def add(self, kind: String, payload: String, tenant: String = "", delay_s: Float64 = 0) raises -> Int:
        """A new pending job (committed before this returns); its id."""
        var now = wall_seconds()
        var db = self.db()
        db.begin()
        var q = db.prepare("INSERT INTO jobs(tenant, kind, payload, max_attempts, run_at, created, updated) VALUES (?, ?, ?, ?, ?, ?, ?)")
        q.bind(1, tenant)
        q.bind(2, kind)
        q.bind(3, payload)
        q.bind(4, self.max_attempts)
        q.bind(5, now + delay_s)
        q.bind(6, now)
        q.bind(7, now)
        try:
            q.run()
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^
        var id = db.last_id()
        self.wake()
        return id

    def wake(self):
        var b = List[UInt8](length=1, fill=1)
        _ = libc.write_fd(self.wake_w, Int(b.unsafe_ptr()), 1)
        _ = len(b)

    def resume(self) raises -> Int:
        """Jobs left `running` by a process that ended mid-run go back to `pending` (at start, before workers)."""
        var db = self.db()
        db.begin()
        try:
            var q = db.prepare("UPDATE jobs SET status = 'pending', updated = ? WHERE status = 'running'")
            q.bind(1, wall_seconds())
            q.run()
            var n = db.changes()
            db.commit()
            return n
        except e:
            _ = db.rollback_quiet()
            raise e^

    def claim(self) raises -> Optional[QueuedJob]:
        """The next due pending job, now `running` with one more attempt (None: nothing due)."""
        var db = self.db()
        var now = wall_seconds()
        db.begin()
        try:
            var q = db.prepare(
                "UPDATE jobs SET status = 'running', attempts = attempts + 1, updated = ? WHERE id = (SELECT id FROM jobs"
                " WHERE status = 'pending' AND run_at <= ? ORDER BY run_at, id LIMIT 1)"
                " RETURNING id, COALESCE(tenant, ''), kind, payload, attempts, max_attempts"
            )
            q.bind(1, now)
            q.bind(2, now)
            var out = Optional[QueuedJob]()
            if q.step():
                out = QueuedJob(q.int(0), q.text(1), q.text(2), q.text(3), q.int(4), q.int(5))
            q.reset()
            db.commit()
            return out^
        except e:
            _ = db.rollback_quiet()
            raise e^

    def next_due(self) raises -> Float64:
        """Seconds until the next pending job is due (60 when none)."""
        var db = self.db()
        var q = db.prepare("SELECT MIN(run_at) FROM jobs WHERE status = 'pending'")
        if q.step() and not q.is_null(0):
            return max(q.float(0) - wall_seconds(), 0.0)
        return 60.0

    def finish(self, job: QueuedJob, error: String) raises:
        """Records a run: done, or back to pending after a backoff, or dead at max attempts."""
        var db = self.db()
        var now = wall_seconds()
        db.begin()
        try:
            if error == "":
                var q = db.prepare("UPDATE jobs SET status = 'done', error = NULL, updated = ? WHERE id = ?")
                q.bind(1, now)
                q.bind(2, job.id)
                q.run()
            else:
                var dead = job.attempts >= job.max_attempts
                var delay = Float64(self.backoff_ms) / 1000.0 * Float64(1 << min(job.attempts - 1, 16))
                var q = db.prepare("UPDATE jobs SET status = ?, error = ?, run_at = ?, updated = ? WHERE id = ?")
                q.bind(1, "dead" if dead else "pending")
                q.bind(2, String(error[byte = : min(error.byte_length(), 2000)]))
                q.bind(3, now + delay)
                q.bind(4, now)
                q.bind(5, job.id)
                q.run()
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^

    def list_json(self, tenant: String, limit: Int = 100) raises -> String:
        """A tenant's newest jobs (no payloads: they can hold addresses): [{id, kind, status, attempts, run_at, error}]."""
        var q = self.db().prepare("SELECT id, kind, status, attempts, run_at, COALESCE(error, '') FROM jobs WHERE tenant = ? ORDER BY id DESC LIMIT ?")
        q.bind(1, tenant)
        q.bind(2, limit)
        var out = String("[")
        var n = 0
        while q.step():
            out += ("," if n > 0 else "") + '{"id": ' + String(q.int(0)) + ', "kind": ' + json_string(q.text(1)) + ', "status": ' + json_string(q.text(2))
            out += ', "attempts": ' + String(q.int(3)) + ', "run_at": ' + String(Int(q.float(4))) + ', "error": ' + json_string(q.text(5)) + "}"
            n += 1
        return out + "]"


def _mac() -> Bool:
    return CompilationTarget.is_macos()


struct _Workers[R: Runner](Movable):
    var queue: Queue
    var runner: Self.R

    def __init__(out self, queue: Queue, var runner: Self.R):
        self.queue = queue
        self.runner = runner^


def _work[R: Runner](addr: Int):
    var w = Pointer[_Workers[R], MutUntrackedOrigin](unsafe_from_address=addr)
    var q = w[].queue
    var buf = List[UInt8](length=64, fill=0)
    var pfd = List[Int32](length=2, fill=0)
    while True:
        var job = Optional[QueuedJob]()
        try:
            job = q.claim()
        except e:
            print("jobs: claim failed: " + String(e))
        if job:
            var j = job.value().copy()
            var err = w[].runner.run(j)
            try:
                q.finish(j, err)
            except e:
                print("jobs: couldn't record job " + String(j.id) + ": " + String(e))
            continue
        var wait_ms = 1000
        try:
            wait_ms = min(Int(q.next_due() * 1000) + 1, 1000)
        except:
            pass
        pfd[0] = Int32(q.wake_r)
        pfd[1] = Int32(1)  # (POLLIN in the low half of `events`; revents zero)
        if libc.poll(Int(pfd.unsafe_ptr()), 1, wait_ms) > 0:
            _ = libc.read_fd(q.wake_r, Int(buf.unsafe_ptr()), 64)  # (another worker may have taken it: fine)
        _ = len(pfd)
        _ = len(buf)


def start_workers[R: Runner](queue: Queue, var runner: R, threads: Int = 2) raises:
    """Puts jobs left running by a dead process back, then runs `threads` workers for as long as the process lives."""
    _ = queue.resume()
    var w = alloc(Layout[_Workers[R]].single()).unsafe_leak()
    w.unsafe_write(_Workers[R](queue, runner^))
    for _ in range(max(threads, 1)):
        if not spawn[_work[R]](Int(w)):
            raise Error("jobs: no thread for a worker")
    queue.wake()
