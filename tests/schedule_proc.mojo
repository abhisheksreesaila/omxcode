# Goal 66 M3's process: mojoui.schedule on a fake clock (SCHED_T0 + (now - SCHED_REAL0) * SCHED_SPEED), "*/10 * * * *" in
# America/New_York, jobs on mojoui.jobs whose run sleeps SCHED_RUN_MS then writes done(slot UNIQUE, catchup) in
# sched.db. docs/goals/66-check.py kills it with -9 mid-run, stops it for a while and restarts it.
from std.os import getenv, makedirs
from mojoui.schedule import Cron, Zone, Scheduler, Schedule
from mojoui.jobs import Queue, QueuedJob, Runner, start_workers
from mojoui.sqlite import Pool
from mojoui.json import Json
from mojoui.clock import wall_seconds
from mojoui import libc


struct Done(Runner):
    var path: String
    var run_ms: Int

    def __init__(out self, path: String, run_ms: Int):
        self.path = path
        self.run_ms = run_ms

    def run(self, job: QueuedJob) -> String:
        try:
            var j = Json.parse(job.payload)
            _ = libc.usleep(self.run_ms * 1000)
            var db = Pool.shared().open(self.path)
            var q = db.prepare("INSERT OR IGNORE INTO done(slot, catchup) VALUES (?, ?)")  # (idempotent by the slot)
            q.bind(1, j.text(j.get(0, "slot")))
            q.bind(2, 1 if j.flag(j.get(0, "catchup")) else 0)
            q.run()
            return ""
        except e:
            return String(e)


def main() raises:
    var data = getenv("SCHED_DATA", "data")
    makedirs(data, exist_ok=True)
    var t0 = atof(getenv("SCHED_T0", "0"))
    var real0 = atof(getenv("SCHED_REAL0", "0"))
    var speed = atof(getenv("SCHED_SPEED", "1"))
    Pool.shared().open(data + "/sched.db").exec("CREATE TABLE IF NOT EXISTS done(slot TEXT PRIMARY KEY, catchup INTEGER)")
    var q = Queue(data + "/host.db", backoff_ms=100, max_attempts=10)
    var sched = Scheduler(data + "/host.db", q)
    var s = Schedule("every10", "t1", Cron("*/10 * * * *"), Zone.load("America/New_York"), "tick", "")
    start_workers(q, Done(data + "/sched.db", atol(getenv("SCHED_RUN_MS", "500"))), threads=2)
    print("SAAS: listening 0", flush=True)
    while True:
        var now = Int(t0 + (wall_seconds() - real0) * speed)
        _ = sched.due(s, now)
        _ = libc.usleep(50_000)
