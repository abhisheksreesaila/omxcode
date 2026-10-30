# MX frame (a Mojo dataframe engine) as an engine for a mojoui Table: the same group-by sums, planned and run by the
# MX frame package's own executor (`Query`, docs/mxframe-mojo-api.md section 5), with no Python (goal 20; before it,
# this went through the package's Python API and pyarrow).
#
# The Table's rows (eight int32 columns each) are copied once into the package's columns, with the derived columns
# (min(source // divisor, cap)); filters become package expressions.
#
#   var mx = MxFrame(table, ["day", "category", …], [("bin", "cents", 5000, 23)])
#   var totals = mx.group_sum("region", "cents", 5, ranges=[("day", 0, 364)], equals=[("channel", 1)])

from omxcore import Table as MxTable, SharedTable, Query, Expr, col, lit, sum, count, CPU, INT
from mojoui.gpu import Table, GroupSums
from mojoui.clock import now_ns


struct MxFrame(Movable):
    var table: SharedTable
    var ready: Bool
    var problem: String  # why it isn't ready (or stopped working)

    def __init__(out self, table: Table, names: List[String], derived: List[Tuple[String, String, Int, Int]]):
        """The package's columns over the Table's rows: `names[k]` is column k ("" skips it), then each derived
        (name, source, divisor, cap) is min(source // divisor, cap)."""
        self.table = SharedTable(MxTable.empty())
        self.ready = False
        self.problem = ""
        try:
            var t = MxTable.empty()
            var rows = table.count
            for k in range(len(names)):
                if names[k] == "":
                    continue
                var c = t.add_column(names[k], INT)
                var values = List[Int64](capacity=rows)
                for r in range(rows):
                    values.append(Int64(table.host[r * 8 + k]))
                t.cols[c].values = values^
            for d in derived:
                var source = t.column(d[1])
                var c = t.add_column(d[0], INT)
                var values = List[Int64](capacity=rows)
                for r in range(rows):
                    values.append(min(t.cols[source].values[r] // Int64(d[2]), Int64(d[3])))
                t.cols[c].values = values^
            t.check()
            self.table = t^.share()
            self.ready = True
        except e:
            self.problem = String(e)

    def group_sum(
        mut self, by: String, value: String, groups: Int,
        ranges: List[Tuple[String, Int, Int]], equals: List[Tuple[String, Int]],
    ) -> GroupSums:
        """Per-group sums of `value` and row counts, over rows inside every range and matching every value."""
        var t0 = now_ns()
        var sums = List[Int](length=groups, fill=0)
        var counts = List[Int](length=groups, fill=0)
        if not self.ready:
            return GroupSums(sums^, counts^, 0)
        try:
            var q = Query(self.table)
            for r in ranges:
                q = q^.where((col(r[0]) >= lit(r[1])) & (col(r[0]) <= lit(r[2])))
            for e in equals:
                q = q^.where(col(e[0]) == lit(e[1]))
            var out = q^.group_by(col(by), groups).agg(sum(col(value)), count()).compute(CPU)
            var s = out.values(0)
            for g in range(groups):
                sums[g] = s[g]
                counts[g] = out.counts[g]
        except e:  # say why, and stop using it (zeros would look like real results)
            self.ready = False
            self.problem = String(e)
        return GroupSums(sums^, counts^, Float64(now_ns() - t0) / 1e6)
