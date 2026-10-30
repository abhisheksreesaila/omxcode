# Job wake (a framework check, D-771): background jobs started with mojoui.jobs.start_ui_job reach update() as soon as
# they end, not at the next display frame. A canvas animates the whole time (frames keep ticking, as in a real app);
# each job busy-works 2–9 ms (so it ends at any point of a frame), records when it ended, and update() records when
# App.jobs_message reached it. After RUNS jobs it prints
#   JOBWAKE: <runs> jobs, end → update() median <ms>, p95 <ms>, worst <ms>; frame ticks <n>
# then runs one long job (LONG_MS) and prints how long the window went without a frame while it ran (D-792):
#   JOBWAKE FREEZE: a 1500 ms job; <n> frames while it ran, longest gap between frames <ms> ms: PASS|FAIL
# (a job on the main thread: about 1500 ms; on a thread of its own: a frame or two; FAIL from FROZEN_MS). With JOBWAKE_EXIT=1 it then exits
# (and on the checks' headless display, MOJOUI_PRIVATE_DISPLAY=1 from scripts/headless.py, where no one sees the window)
# (JOBWAKE_ALL=1 lists every delay). JOBWAKE_POLL=1 turns the wake off (jobs_message 0): the frame poll alone, to compare.

from std.sys import exit, CompilationTarget
from mojoui import App, Event, View, Surface, VStack, Text, Canvas
from mojoui.jobs import start_ui_job
from mojoui.clock import now_ns
from mojoui.shared import environment
from omxcore import Job, JobBody, JobCtl, JOB_RUNNING

comptime LANDED = 1
comptime FRAME = 2
comptime RUNS = 40
comptime LONG_MS = 1500
comptime FROZEN_MS = 500  # a longer gap between frames during the long job: FAIL (a job on the UI thread reads ~1500)


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
    var long: Bool  # the long job is running (or ran)
    var last_tick: Int  # while it runs: the last frame's time, the longest gap between frames, the frames
    var gap: Int
    var long_ticks: Int

    def __init__(out self):
        self.job = None
        self.delays = List[Float64]()
        self.ticks = 0
        self.seed = 12345
        self.wake = environment("JOBWAKE_POLL") != "1"
        self.line = "running"
        self.started = False
        self.long = False
        self.last_tick = 0
        self.gap = 0
        self.long_ticks = 0
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
        if self.long:
            self.gap = max(self.gap, now_ns() - self.last_tick)
            var gap_ms = Int(Float64(self.gap) / 1e6)
            var line = ("JOBWAKE FREEZE: a " + String(LONG_MS) + " ms job; " + String(self.long_ticks) + " frames while it ran, longest gap between frames "
                        + String(gap_ms) + " ms: " + ("PASS" if gap_ms < FROZEN_MS else "FAIL (the window froze)"))
            print(line, flush=True)
            self.line += " · " + line
            comptime if CompilationTarget.is_linux():  # (the Apple stubs have no exit(): the test steps close the window there)
                if environment("JOBWAKE_EXIT") == "1" or environment("MOJOUI_PRIVATE_DISPLAY") == "1":  # (or on a check's headless display: no one sees it)
                    exit(0 if gap_ms < FROZEN_MS else 1)
            return
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
        self.long = True
        self.last_tick = now_ns()
        self.job = start_ui_job(Work(LONG_MS * 1_000_000))

    def update(mut self, event: Event):
        if event.message == FRAME:
            self.ticks += 1
            if self.long and self.job:
                self.gap = max(self.gap, now_ns() - self.last_tick)
                self.last_tick = now_ns()
                self.long_ticks += 1
            self.landed()  # (the fallback: what an app does on its frames anyway)
        elif event.message == LANDED:
            self.landed()

    def draw(mut self, canvas: Int, mut s: Surface):
        s.fill(UInt32(0xFF000000) | UInt32((self.ticks * 4) % 256))

    def view(self) -> View:
        return VStack(Text(self.line), Canvas(1, self.ticks, on_frame=FRAME).grow().fill()).grow().fill()
