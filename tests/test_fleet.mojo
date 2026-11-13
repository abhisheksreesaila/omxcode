# mojoui.fleet (goal 68 M4): build/bags as a fleet: a row per run, every topic joined at 10 Hz, the stops, a story the
# starter reads; then 20 stops labelled by a stated rule and Learn names the cause of the rest.
#   scripts/mxbuild.sh tests/test_fleet.mojo -o build/g68/bin/test_fleet && build/g68/bin/test_fleet [BAGS] [OUT]
from std.sys import argv
from std.time import perf_counter_ns
from omxcore import JobCtl
from mojoui.fleet import read_fleet
from mojoui.sheet import Sheet
from mojoui.starter import Starter
from mojoui.learn import with_label_column, learn_sheet, learned_name


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def cause(person: String, moved: Float64) -> String:
    """How the check labels a stop, as a person watching the cameras would: a person within 1.5 m → person ahead;
    hasn't moved yet → not started; else waiting."""
    if person != "":
        try:
            if Float64(person) < 1.5:
                return "person ahead"
        except:
            pass
    if moved < 0.2:
        return "not started"
    return "waiting"


def main() raises:
    var args = argv()
    var bags = String(args[1]) if len(args) > 1 else String("build/bags")
    var out = String(args[2]) if len(args) > 2 else String("build/g68/fleet")
    var t0 = perf_counter_ns()
    var f = read_fleet(bags, JobCtl())
    var ms = Float64(perf_counter_ns() - t0) / 1e6
    var runs = Sheet(f.runs_table, False)
    for r in range(runs.rows()):
        var line = String("RUN")
        for c in range(runs.columns()):
            line += " " + runs.name(c) + "=" + runs.plain_text(c, r)
        print(line)
    var moments = Sheet(f.moments, False)
    var stops = Sheet(f.stops, False)
    print("FLEET:", runs.rows(), "runs,", moments.rows(), "moments x", moments.columns(), "columns,", stops.rows(), "stop rows, read in", ms, "ms")
    for p in f.problems:
        print("PROBLEM:", p)
    check(runs.rows() >= 3 and moments.columns() > 20 and stops.rows() >= 30, "a fleet")
    print("fleet-read: ok")
    f.write(out)
    var s = Starter.read(out)
    check(s.sheet == "runs.csv" and len(s.tables) == 2 and len(s.questions) >= 3, "story.json")
    print("fleet-story: ok", len(s.questions), "questions")

    # (20 stops labelled by the rule, spread over the runs: every 4th stop row until 20; Learn names the rest)
    var t = with_label_column(stops, "cause")
    var sheet = Sheet(t^.share(), False)
    var lc = sheet.index("cause")
    var pc = sheet.index("person_m")
    var mc = sheet.index("moved_m")
    var n = sheet.rows()
    var truths = List[String]()
    for r in range(n):
        truths.append(cause(sheet.plain_text(pc, r), Float64(sheet.value(mc, r)) / 100.0))
    var given = 0
    var row = 0
    var step = max(n // 20, 1)
    while given < 20 and row < n:
        sheet.set_text(lc, row, truths[row])
        given += 1
        row += step
    var l = learn_sheet(sheet, "cause")
    var after = Sheet(l.take_table().share(), False)
    var gc = after.index(learned_name("cause"))
    var right = 0
    var rest = 0
    for q in range(n):
        if after.plain_text(lc, q) == "":
            rest += 1
            if after.plain_text(gc, q) == truths[q]:
                right += 1
    print("STOPS_RULE:", l.tree.rule())
    print("STOPS_LEARN:", right, "of", rest, "unlabelled stops right; held out", l.held.right, "of", l.held.tried)
    check(Float64(right) / Float64(max(rest, 1)) >= 0.85 and "person_m" in l.tree.rule(), "Learn names the cause")
    print("fleet-learn: ok")
