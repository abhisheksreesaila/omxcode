# Job wake (a framework check, D-771): background jobs started with mojoui.jobs.start_ui_job reach update() as soon as
# they end, not at the next display frame. A canvas animates the whole time (frames keep ticking, as in a real app);
# each job busy-works 2–9 ms (so it ends at any point of a frame), records when it ended, and update() records when
# App.jobs_message reached it. After RUNS jobs it prints
#   JOBWAKE: <runs> jobs, end → update() median <ms>, p95 <ms>, worst <ms>; frame ticks <n>
# and, with JOBWAKE_EXIT=1, exits (JOBWAKE_ALL=1 lists every delay). JOBWAKE_POLL=1 turns the wake off (jobs_message 0): the frame poll alone, to compare.

from std.sys import exit, CompilationTarget
from mojoui import App, Event, View, Surface, VStack, Text, Canvas
from mojoui.jobs import start_ui_job
from mojoui.clock import now_ns
from mojoui.shared import environment
from omxcore import Job, JobBody, JobCtl, JOB_RUNNING

comptime LANDED = 1
comptime FRAME = 2
comptime RUNS = 40


struct Work(JobBody):
    comptime Out = Int
    var ns: Int

    def __init__(out self, ns: Int):
        self.ns = ns

    def run(mut self, ctl: JobCtl) raises -> Int:
        var t0 = now_ns()
        while now_ns() - t0 < self.ns:
            pass
        return now_ns()  # (when it ended)


struct Main(App):
    var job: Optional[Job[Int]]
    var delays: List[Float64]
    var ticks: Int
    var seed: Int
    var wake: Bool
    var line: String
    var started: Bool

    def __init__(out self):
        self.job = None
        self.delays = List[Float64]()
        self.ticks = 0
        self.seed = 12345
        self.wake = environment("JOBWAKE_POLL") != "1"
        self.line = "running"
        self.started = False
        self.next()

    def title(self) -> String:
        return "Job wake"

    def jobs_message(self) -> Int:
        return LANDED if self.wake else 0

    def next(mut self):
        self.seed = (self.seed * 1103515245 + 12345) % 2147483648
        self.job = start_ui_job(Work(2_000_000 + self.seed % 7_000_000))

    def landed(mut self):
        if not self.job or self.job.value().poll() == JOB_RUNNING:
            return
        var job = self.job.take()
        try:
            var ended = job.result()
            if self.started:  # (the first job starts in __init__, before the host's main loop runs: not counted)
                self.delays.append(Float64(now_ns() - ended) / 1e6)
            self.started = True
        except:
            pass
        if len(self.delays) < RUNS:
            self.next()
            return
        var d = self.delays.copy()
        sort(d)
        self.line = ("JOBWAKE: " + String(len(d)) + " jobs, end → update() median " + String(d[len(d) // 2]) + " ms, p95 "
                     + String(d[(len(d) * 95) // 100 - 1]) + " ms, worst " + String(d[len(d) - 1]) + " ms; frame ticks " + String(self.ticks)
                     + (" (wake)" if self.wake else " (frame poll only)"))
        print(self.line, flush=True)
        if environment("JOBWAKE_ALL") == "1":
            var all = String("JOBWAKE all:")
            for x in d:
                all += " " + String(Int(x * 1000)) + "us"
            print(all, flush=True)
        comptime if CompilationTarget.is_linux():  # (the Apple stubs have no exit(): close the window there)
            if environment("JOBWAKE_EXIT") == "1":
                exit(0)

    def update(mut self, event: Event):
        if event.message == FRAME:
            self.ticks += 1
            self.landed()  # (the fallback: what an app does on its frames anyway)
        elif event.message == LANDED:
            self.landed()

    def draw(mut self, canvas: Int, mut s: Surface):
        s.fill(UInt32(0xFF000000) | UInt32((self.ticks * 4) % 256))

    def view(self) -> View:
        return VStack(Text(self.line), Canvas(1, self.ticks, on_frame=FRAME).grow().fill()).grow().fill()
