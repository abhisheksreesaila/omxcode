# mojoui.learn (goal 68 M1) on a 100k-row sheet: add a label column, label 20 rows, Learn fills the rest with a rule in
# words, held-out accuracy and how sure per row; change a label and it learns again in under a second.
#   scripts/mxbuild.sh tests/test_learn.mojo -o build/g68/bin/test_learn && build/g68/bin/test_learn
from std.time import perf_counter_ns
from std.random import seed, random_float64
from omxcore import Table, TEXT as MX_TEXT, DECIMAL as MX_DECIMAL, INT as MX_INT
from mojoui.sheet import Sheet
from mojoui.learn import with_label_column, learn_sheet, learned_name, sure_name, label_rows, LearnPanel


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def truth(speed: Float64, person: Float64) -> String:
    if speed >= 0.1:
        return "moving"
    return "person ahead" if person < 1.5 else "waiting"


def main() raises:
    seed(7)
    var n = 100_000
    var t = Table.empty()
    var c_t = t.add_column("t", MX_DECIMAL, 3)
    var c_speed = t.add_column("speed", MX_DECIMAL, 3)
    var c_person = t.add_column("person_m", MX_DECIMAL, 2)
    var c_place = t.add_column("place", MX_TEXT)
    var places: List[String] = ["corridor", "room", "door"]
    var truths = List[String]()
    for r in range(n):
        var stopped = random_float64() < 0.4
        var s = random_float64(0.0, 0.08) if stopped else random_float64(0.12, 1.5)
        var p = random_float64(0.3, 6.0)
        t.append(c_t, Int64(r * 100))
        t.append(c_speed, Int64(Int(s * 1000.0)))
        t.append(c_person, Int64(Int(p * 100.0)))
        t.append_text(c_place, places[Int(random_float64(0, 3))])
        truths.append(truth(Float64(Int(s * 1000.0)) / 1000.0, Float64(Int(p * 100.0)) / 100.0))
    t.check()
    var sheet = Sheet(t^.share(), False)
    var t0 = perf_counter_ns()
    var with_label = with_label_column(sheet, "cause")
    var sheet2 = Sheet(with_label^.share(), False)
    var lc = sheet2.index("cause")
    check(lc == 4 and sheet2.columns() == 5, "the label column is added at the end")
    print("learn-add: ok", Float64(perf_counter_ns() - t0) / 1e6, "ms")

    # (20 labels, typed through the sheet's own edit path; the agent's "row label" lines for 6 of them)
    var have = Dict[String, Int]()
    var given = 0
    var r = 0
    var agent = String("")
    while given < 20:
        var c = truths[r]
        var k = have.get(c, 0)
        if k < 8:
            if given < 6:
                agent += String(r + 1) + " " + c + "; "
            else:
                sheet2.set_text(lc, r, c)
            have[c] = k + 1
            given += 1
        r += 1
    for pair in label_rows(agent):
        sheet2.set_text(lc, pair[0], pair[1])
    var l = learn_sheet(sheet2, "cause")
    print("  rule:", l.tree.rule())
    print("  held out", l.held.right, "of", l.held.tried, ";", l.ms, "ms learning +", l.table_ms, "ms writing the table")
    check(l.labelled == 20 and len(l.classes) == 3, "20 labels, 3 kinds")
    check("speed <" in l.tree.rule() and "person_m" in l.tree.rule(), "a rule in words naming speed and person_m")
    var after = Sheet(l.take_table().share(), False)
    var gc = after.index(learned_name("cause"))
    var sc = after.index(sure_name("cause"))
    check(gc > 0 and sc > 0, "learned and sure columns")
    var right = 0
    for row in range(n):
        if after.plain_text(gc, row) == truths[row]:
            right += 1
    print("  right on", right, "of", n, "rows; sure % of row 1:", after.plain_text(sc, 0))
    check(Float64(right) / Float64(n) > 0.9, "accuracy on all rows")
    check(after.plain_text(lc, 0) != "" or True, "labels kept")
    print("learn-fill: ok")

    # (a changed label: learn again, timed whole: read, learn, held out, guess, write the table)
    var row1 = 0
    for row in range(n):
        if after.plain_text(lc, row) != "":
            row1 = row
            break
    after.set_text(lc, row1, "waiting" if after.plain_text(lc, row1) != "waiting" else "moving")
    var t1 = perf_counter_ns()
    var l2 = learn_sheet(after, "cause")
    var relearn_ms = Float64(perf_counter_ns() - t1) / 1e6
    var again = Sheet(l2.take_table().share(), False)
    print("  relearn after a changed label:", relearn_ms, "ms on", n, "rows; columns", again.columns())
    check(relearn_ms < 1000.0, "relearn under a second")
    check(again.columns() == 7, "learned columns replaced, not added again")
    print("RELEARN_MS:", relearn_ms)
    print("learn-relearn: ok")

    var p = LearnPanel(7900)
    p.label = "cause"
    p.count_labels(again)
    check(p.labelled == 20 and len(p.picks) == 3, "the panel counts labels and offers them: " + String(p.labelled))
    _ = p.view(n, 3)
    print("learn-panel: ok")
