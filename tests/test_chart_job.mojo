# mojoui.sheetjobs (goal 30 M0): a chart computed through a background job equals the same chart computed in place, for
# six specs (sum, median, p90 top 3, count, average by month, a number condition), on the CPU and, when there is one, the
# GPU; a cancelled job ends cancelled, and the sheet can be edited while a job holds its snapshot.
#   scripts/mxbuild.sh tests/test_chart_job.mojo -o build/test_chart_job && build/test_chart_job
from std.testing import assert_equal, assert_true, assert_false
from omxcore import gpu_available, GPU as MX_GPU, CPU as MX_CPU, JOB_DONE, JOB_CANCELLED, JobBody, JobCtl, start_job
from std.memory import Pointer
from mojoui.clock import now_ns
from mojoui.csvio import read_csv
from mojoui.sheet import Sheet
from mojoui.shared import make_dir
from mojoui.sheetpage import (SheetObject, compute, chart_text, COMBINE_SUM, COMBINE_AVERAGE, COMBINE_COUNT, COMBINE_MEDIAN, COMBINE_P90,
                              ORDER_LARGEST, PART_MONTH, NUM_OVER)
from mojoui.sheetjobs import Charted, stopped, chart_job, take_numbers, progress_share, ChartQueue, column_job


struct Stubborn(JobBody):
    """Runs on 1 s after it's cancelled, then marks that its thread is done (a GPU block finishing after a cancel)."""
    comptime Out = Int
    var flag: Int  # an Int's address

    def __init__(out self, flag: Int):
        self.flag = flag

    def run(mut self, ctl: JobCtl) raises -> Int:
        var t0 = now_ns()
        while now_ns() - t0 < 1_000_000_000:
            pass
        Pointer[Int, MutUntrackedOrigin](unsafe_from_address=self.flag)[] = 1
        return 1


struct StubbornChart(JobBody):
    """A chart job that runs on 1 s after its cancel (a GPU block finishing), then marks its thread done."""
    comptime Out = Charted
    var flag: Int

    def __init__(out self, flag: Int):
        self.flag = flag

    def run(mut self, ctl: JobCtl) raises -> Charted:
        var t0 = now_ns()
        while now_ns() - t0 < 1_000_000_000:
            pass
        Pointer[Int, MutUntrackedOrigin](unsafe_from_address=self.flag)[] = 1
        return Charted(SheetObject.chart(0, 2, 0, 0), False)


def two(n: Int) -> String:
    return ("0" if n < 10 else "") + String(n)


def sheet() raises -> Sheet:
    make_dir("build/test-chart-job")
    var path = String("build/test-chart-job/orders.csv")
    with open(path, "w") as f:
        f.write("amount,qty,region,day\n")
        for i in range(5000):  # (enough rows that every group has a middle)
            var region = ["North", "South", "East", "West", "Central"][i % 5]
            f.write(String(i % 97) + "." + String(i % 10) + "5," + String(i % 7 + 1) + "," + region + ",2025-"
                    + two(i % 12 + 1) + "-" + two(i % 28 + 1) + "\n")
    return Sheet(read_csv(path).table)


def specs() -> List[SheetObject]:
    var out = List[SheetObject]()
    for k in range(6):
        var o = SheetObject.chart(0, 2, 0, 0)  # amount by region
        if k == 1:
            o.combine = COMBINE_MEDIAN
        elif k == 2:
            o.combine = COMBINE_P90
            o.order = ORDER_LARGEST
            o.top = 3
        elif k == 3:
            o.combine = COMBINE_COUNT
        elif k == 4:
            o.combine = COMBINE_AVERAGE
            o.group = 3
            o.part = PART_MONTH
        elif k == 5:
            o.num_col = 0
            o.num_op = NUM_OVER
            o.num_lo = 5000  # (amount over 50.00, in cents)
        out.append(o^)
    return out^


def same(mode: Int, mut s: Sheet) raises:
    s.mode = mode
    var list = specs()
    for k in range(len(list)):
        var here = list[k].copy()
        compute(here, s)
        var job = chart_job(s, list[k])
        var done = job.result()
        var shown = list[k].copy()
        take_numbers(shown, done.obj)
        assert_equal(done.on_gpu, mode == MX_GPU, "spec " + String(k) + ": where it ran is told")
        assert_equal(chart_text(shown, s), chart_text(here, s), "spec " + String(k) + " through a job")
        assert_true(len(here.labels) > 0, "spec " + String(k) + " has groups")
        assert_equal(job.poll(), JOB_DONE)
        assert_equal(progress_share(job.progress()), 1.0)


def main() raises:
    var s = sheet()
    same(MX_CPU, s)
    if gpu_available():
        same(MX_GPU, s)
    # the sheet edited while a job holds its snapshot: the job reads the sheet as it was
    s.mode = MX_CPU
    var o = SheetObject.chart(0, 2, 0, 0)
    var before = o.copy()
    compute(before, s)
    var job = chart_job(s, o)
    s.set_text(0, 0, "100000.00")
    var done = job.result()
    var shown = o.copy()
    take_numbers(shown, done.obj)
    assert_equal(chart_text(shown, s), chart_text(before, s), "a job reads its snapshot, not later edits")
    # the queue: a newer spec for the running chart cancels it; another chart waits its turn; only the newest lands
    var q = ChartQueue()
    var a = SheetObject.chart(0, 2, 0, 0)
    var b = a.copy()
    b.combine = COMBINE_MEDIAN
    q.ask(0, a, s)
    q.ask(0, b, s)
    q.ask(1, a, s)
    var landed = List[Tuple[Int, Int]]()
    while q.busy():
        var got = q.poll(s)
        if got:
            landed.append((got.value()[0], got.value()[1].combine))
    assert_equal(len(landed), 2, "two charts landed")
    assert_equal(landed[0][0], 0)
    assert_equal(landed[0][1], COMBINE_MEDIAN, "chart 0's newest spec")
    assert_equal(landed[1][0], 1)
    # an object removed: its job goes, the ones after it keep theirs under their new refs
    var r3 = ChartQueue()
    var c = a.copy()
    c.combine = COMBINE_COUNT
    r3.ask(0, a, s)
    r3.ask(1, b, s)
    r3.ask(2, c, s)
    r3.remove(1, s)
    var got3 = List[Tuple[Int, Int]]()
    while r3.busy():
        var g = r3.poll(s)
        if g:
            got3.append((g.value()[0], g.value()[1].combine))
    assert_equal(len(got3), 2, "the removed chart's job never lands")
    assert_equal(got3[0][0], 0)
    assert_equal(got3[1][0], 1, "chart 2 is chart 1 now")
    assert_equal(got3[1][1], COMBINE_COUNT, "and it still gets its own numbers")
    # removing the running chart's object: the next waiting one starts
    var r4 = ChartQueue()
    r4.ask(0, b, s)
    r4.ask(1, c, s)
    r4.remove(0, s)
    assert_true(r4.running() != (len(r4.orphans) > 0), "the next starts only once the cancelled thread has stopped")
    var first = -1
    while r4.busy():
        if r4.running() and first < 0:
            first = r4.cref
        assert_false(r4.running() and len(r4.orphans) > 0, "never two threads on the GPU")
        _ = r4.poll(s)
    assert_equal(first, 0, "chart 1 (now 0) runs")
    assert_equal(len(r4.orphans), 0, "the cancelled thread let go once stopped")
    # a re-asked chart: the cancelled job is kept until its thread stops (not detached), and the new one waits for it
    var r6 = ChartQueue()
    r6.ask(0, a, s)
    r6.ask(0, b, s)
    assert_true(len(r6.orphans) == 1 and not r6.running(), "the first job waits in orphans; the second hasn't started")
    assert_true(r6.busy(), "busy: polling goes on")
    # forget, waiting: nothing runs afterwards, cancelled threads included (the sheet's table can be given back)
    r6.forget(wait=True)
    assert_false(r6.busy(), "forgotten")
    assert_equal(len(r6.orphans), 0, "every thread stopped")
    var r5 = ChartQueue()
    r5.ask(0, b, s)
    r5.forget(wait=True)
    assert_false(r5.busy(), "forgotten")
    # stopped(): a cancelled job reads CANCELLED at once, but its thread isn't over until it says so
    var mark = List[Int](length=1, fill=0)
    var stub = start_job(Stubborn(Int(mark.unsafe_ptr())))
    stub.cancel()
    assert_equal(stub.poll(), JOB_CANCELLED, "cancelled at once")
    assert_false(stopped(stub), "its thread still runs")
    while not stopped(stub):
        pass
    assert_equal(mark[0], 1, "stopped only once the thread had finished its work")
    # the queue lets an orphan go only once its thread has ended, and starts nothing on the GPU before then
    var mark2 = List[Int](length=1, fill=0)
    var rq = ChartQueue()
    var orphan = start_job(StubbornChart(Int(mark2.unsafe_ptr())))
    orphan.cancel()
    rq.orphans.append(orphan^)
    rq.ask(0, a, s)
    _ = rq.poll(s)
    assert_equal(len(rq.orphans), 1, "polled while the cancelled thread runs: still kept")
    assert_false(rq.running(), "and the waiting chart hasn't started")
    while len(rq.orphans) > 0:
        _ = rq.poll(s)
    assert_equal(mark2[0], 1, "let go only after its thread finished")
    while rq.busy():
        _ = rq.poll(s)
    # a column's figures through a job equal them in place
    var cj = column_job(s, 0, True)
    var fig = cj.result()
    var r = s.totals(0)
    var m = s.median(0)
    assert_equal(fig.sum, r.sums[0])
    assert_equal(fig.present, r.present[0])
    assert_equal(fig.median, Int(m[0]))
    assert_equal(fig.distinct, s.distinct(0))
    print("CHART JOB TESTS PASSED")
