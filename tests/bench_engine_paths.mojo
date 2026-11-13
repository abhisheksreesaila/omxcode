# Goal 70 M1: the app's own query paths, timed, with their answers written out so two engines can be compared. Each
# path is called as omxplorer calls it: tables opened with read_table into Sheets (csvio), SQL through implied_sql (JOIN
# LINKED) and query_table (tablecard, the SQL box and the AskBook), pivots and charts through sheetpage.compute (a chart
# card's job runs the same compute on a snapshot).
#   scripts/mxbuild.sh tests/bench_engine_paths.mojo -o build/bench_engine_paths
#   build/bench_engine_paths SPEC OUT_DIR [RUNS]
# SPEC: one step a line, fields split by " | " (lines starting with # are skipped):
#   table | name | path                          open a CSV or Parquet file as table `name`
#   link | text                                  a key link (links.parse_link: "a.x = b.y")
#   sql | name | SELECT …                        (JOIN LINKED allowed)
#   pivot | name | table | value | rows | across  sums by rows × across (column names; across "-": none)
#   chart | name | table | value | group | how    how: sum, median, count or average
# Each answer goes to OUT_DIR/<name>.txt (a table: tab-separated rows; a pivot or chart: label, sum, count lines); each
# step prints "TIME <name> <ms> … median=<ms>" over RUNS runs (default 5).
from std.sys import argv
from std.time import perf_counter_ns
from std.os import makedirs
from omxcore import Catalog, Table
from mojoui.csvio import read_table, cell_text
from mojoui.sheet import Sheet
from mojoui.sheetpage import SheetObject, compute, COMBINE_SUM, COMBINE_MEDIAN, COMBINE_COUNT, COMBINE_AVERAGE
from mojoui.tablecard import query_table, add_sheet
from std.sys import is_defined
from mojoui.asksql import implied_sql
from mojoui.links import Links, parse_link


def table_text(t: Table) -> String:
    var s = String("")
    for c in range(t.columns()):
        s += ("\t" if c > 0 else "") + t.name(c)
    s += "\n"
    for r in range(t.rows()):
        for c in range(t.columns()):
            s += ("\t" if c > 0 else "") + cell_text(t, c, r)
        s += "\n"
    return s^


def object_text(o: SheetObject) -> String:
    var s = String("cols: ") + ", ".join(o.cols) + "\n"
    var per = max(len(o.cols), 1)
    for g in range(len(o.labels)):
        s += o.labels[g]
        for k in range(per):
            var i = g * per + k
            if i < len(o.sums):
                s += "\t" + String(o.sums[i]) + "\t" + String(o.counts[i] if i < len(o.counts) else -1)
        if g < len(o.values):
            s += "\tv=" + String(o.values[g])
        if g < len(o.stats) and g < len(o.has_stat) and o.has_stat[g]:
            s += "\tstat=" + String(o.stats[g])
        s += "\n"
    return s^


def median(var xs: List[Float64]) -> Float64:
    sort(xs)
    return xs[len(xs) // 2]


def times_line(name: String, xs: List[Float64]) -> String:
    var s = String("TIME ") + name
    for x in xs:
        s += " " + String(Float64(Int(x * 1000.0)) / 1000.0)
    return s + " median=" + String(median(xs.copy()))


def main() raises:
    var args = argv()
    var spec = String(args[1])
    var out = String(args[2])
    var runs = Int(String(args[3])) if len(args) > 3 else 5
    makedirs(out, exist_ok=True)
    var names = List[String]()
    var sheets = List[Sheet]()
    var catalog = Catalog()
    var links = Links()
    with open(spec, "r") as f:
        var text = f.read()
        for raw in text.split("\n"):
            var line = String(raw.strip())
            if line == "" or line.startswith("#"):
                continue
            var p = List[String]()
            for x in line.split(" | "):
                p.append(String(x.strip()))
            var kind = p[0]
            if kind == "table":
                var t0 = perf_counter_ns()
                var imp = read_table(p[2])
                sheets.append(Sheet(imp.scan.value()) if imp.streamed() else Sheet(imp.table))
                names.append(p[1])
                comptime if is_defined["BENCH_MAIN_PATH"]():
                    catalog.add_frame(p[1], sheets[len(sheets) - 1].frame)  # (main's way, for the old engine's run: docs/goals/70/bench_m1.py)
                else:
                    add_sheet(catalog, p[1], sheets[len(sheets) - 1].frame)  # (the app's way since D-7006)
                print("OPEN " + p[1] + " rows=" + String(sheets[len(sheets) - 1].rows()) + " ms=" + String(Float64(perf_counter_ns() - t0) / 1e6))
            elif kind == "link":
                _ = links.add(parse_link(p[1]))
            elif kind == "sql":
                var xs = List[Float64]()
                var answer = String("")
                try:
                    var q = implied_sql(p[2], links)
                    for _ in range(runs):
                        var t0 = perf_counter_ns()
                        var t = query_table(catalog, q)
                        xs.append(Float64(perf_counter_ns() - t0) / 1e6)
                        answer = table_text(t)
                except e:
                    answer = "ERROR: " + String(e) + "\n"  # (an engine's refusal is an answer too: compared like the rest)
                    xs = [Float64(0)]
                with open(out + "/" + p[1] + ".txt", "w") as o:
                    o.write(answer)
                print(times_line(p[1], xs))
            elif kind == "pivot" or kind == "chart":
                var k = -1
                for i in range(len(names)):
                    if names[i] == p[2]:
                        k = i
                if k < 0:
                    raise Error("no table " + p[2])
                ref sheet = sheets[k]
                var value = sheet.index(p[3])
                var group = sheet.index(p[4])
                if value < 0 or group < 0:
                    raise Error(p[1] + ": no column " + (p[3] if value < 0 else p[4]) + " in " + p[2])
                var obj: SheetObject
                if kind == "pivot":
                    obj = SheetObject.pivot(value, group, sheet.index(p[5]) if p[5] != "-" else -1, 0, 0)
                else:
                    obj = SheetObject.chart(value, group, 0, 0)
                    obj.combine = COMBINE_MEDIAN if p[5] == "median" else (COMBINE_COUNT if p[5] == "count" else (COMBINE_AVERAGE if p[5] == "average" else COMBINE_SUM))
                var xs = List[Float64]()
                for _ in range(runs):
                    var t0 = perf_counter_ns()
                    compute(obj, sheet)
                    xs.append(Float64(perf_counter_ns() - t0) / 1e6)
                with open(out + "/" + p[1] + ".txt", "w") as o:
                    o.write(object_text(obj))
                print(times_line(p[1], xs))
            else:
                raise Error("unknown step: " + line)
