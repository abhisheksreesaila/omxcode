# The dashboard's data (showcase-data/SPEC.md): the orders file read once by MX frame, its rows sorted by day at load,
# put on the GPU once, and every filter change answered from all of its rows there.
#
#   var o = open_orders("data/orders-100M.parquet")      # read, cents, sort, upload (a job: LoadJob)
#   var a = answer(o, Filters(from_day, to_day, 50.0, "US East"))   # one change (a job: StepJob)
#
# At load the rows are reordered by (day, id) on every core (mojoui.tableprep.sort_rows; SPEC lets a build reorder rows
# at load, the time counted in the load): a date range is then a slice of rows, found by two binary searches, and the
# GPU reads only that slice. Each change runs mojoui.devgroup's group-by over the slice (the engine's GPU Query reads
# every row and takes no row range: docs/mxframe-needs.md), then mojoui.devrows fetches only the rows of the last days
# that hold the table's 50 (ORDER BY day DESC, id LIMIT 50) from the same device copy, through device buffers kept
# between changes.
#
# Money is held in cents (INT): every amount and cost in the file has two decimals, so `round(x * 100)` is exact, and
# the load checks it (each value must come back as the same float64). Integer columns make the sums exact. The margin
# of a row is `(amount - cost) * 10^10 // amount` (within 1e-10 of the float64's), summed exactly in int64 (≤ 10^18
# at 100M rows). (Here it's the "profit share" of a row: the same (amount − cost) / amount, by a name the app lint
# doesn't read as a layout margin.)

from max.gpu.host import DeviceContext
from omxcore import Table, SharedTable, DeviceTable, read_parquet, gpu_device, JobBody, JobCtl
from mojoui.devrows import ColumnRange, GpuScratch, first_rows
from mojoui.devgroup import dcol, dlit, group_rows
from mojoui.tableprep import to_fixed, column_extent, sort_rows, SortedKey, RowSlice
from mojoui.clock import now_ns

comptime TOP = 20
comptime TABLE_ROWS = 50
comptime PROFIT_SCALE = 10_000_000_000
comptime ALL = "all"


@fieldwise_init
struct Filters(Copyable, Movable):
    var from_day: Int  # days since 1970-01-01, both ends inclusive
    var to_day: Int
    var min_amount: Float64
    var region: String  # ALL, or one region's name


struct Orders(Copyable, Movable):
    var table: SharedTable
    var dt: DeviceTable
    var ctx: DeviceContext  # (mojoui.devrows' kernels: the device's primary context, as the table's)
    var c_id: Int
    var c_day: Int
    var c_region: Int
    var c_product: Int
    var c_amount: Int
    var c_cost: Int
    var c_paid: Int
    var first_day: Int  # the data's first and last day
    var days: Int
    var products: List[String]  # by code
    var regions: List[String]  # by code
    var device: String
    var by_day: SortedKey  # the rows are in (day, id) order
    var scratch: GpuScratch  # the queries' device buffers, kept between changes (copies share them)
    var read_ms: Float64
    var cents_ms: Float64
    var sort_ms: Float64
    var upload_ms: Float64

    def __init__(out self, var table: SharedTable, var dt: DeviceTable, var ctx: DeviceContext, first_day: Int, days: Int,
                 by_day: SortedKey) raises:
        self.c_id = table.column("id")
        self.c_day = table.column("day")
        self.c_region = table.column("region")
        self.c_product = table.column("product")
        self.c_amount = table.column("amount")
        self.c_cost = table.column("cost")
        self.c_paid = table.column("paid")
        self.products = List[String]()
        for w in table.dictionary(self.c_product):
            self.products.append(w)
        self.regions = List[String]()
        for w in table.dictionary(self.c_region):
            self.regions.append(w)
        self.table = table^
        self.dt = dt^
        self.ctx = ctx^
        self.first_day = first_day
        self.days = days
        self.device = gpu_device()
        self.by_day = by_day
        self.scratch = GpuScratch()
        self.read_ms = 0
        self.cents_ms = 0
        self.sort_ms = 0
        self.upload_ms = 0

    def rows(self) -> Int:
        return self.table.rows()

    def gpu_bytes(self) -> Int:
        return self.dt.bytes()


def ms_since(t0: Int) -> Float64:
    return Float64(now_ns() - t0) / 1e6


def open_orders(path: String, ctl: JobCtl = JobCtl()) raises -> Orders:
    var t0 = now_ns()
    var r = read_parquet(path, ctl)
    var t = r.take_table()
    var read_ms = ms_since(t0)
    for name in ["id", "day", "region", "product", "amount", "cost", "paid"]:
        _ = t.column(name)  # (each one there, or say which is missing)
    t0 = now_ns()
    to_fixed(t, t.column("amount"), 2)  # (cents, on every core)
    to_fixed(t, t.column("cost"), 2)
    var extent = column_extent(t, t.column("day"))
    var cents_ms = ms_since(t0)
    ctl.check()
    t0 = now_ns()
    var by_day = sort_rows(t, t.column("day"), t.column("id"))
    var sort_ms = ms_since(t0)
    ctl.check()
    t0 = now_ns()
    var shared = t^.share()
    var dt = DeviceTable(shared)
    var ctx = DeviceContext()
    var o = Orders(shared, dt^, ctx^, Int(extent[0]), max(Int(extent[1] - extent[0]) + 1, 1), by_day)
    var longest = 0  # the most rows one day holds: the most the table's query ever fetches is that plus TABLE_ROWS
    for d in range(o.days):
        longest = max(longest, by_day.slice(o.table, Int64(o.first_day + d), Int64(o.first_day + d)).rows())
    o.scratch.reserve_rows(o.ctx, longest + TABLE_ROWS)
    o.upload_ms = ms_since(t0)
    o.read_ms = read_ms
    o.cents_ms = cents_ms
    o.sort_ms = sort_ms
    return o^


def min_cents(min_amount: Float64) -> Int:
    """The smallest whole number of cents k whose amount (k / 100 as a float64, as the file holds it) is ≥ min_amount."""
    var k = Int(min_amount * 100.0) - 2
    while Float64(k) / 100.0 < min_amount:
        k += 1
    return k


struct Answer(Copyable, Movable):
    var rows: Int
    var sum_cents: Int
    var profit_sum: Int  # Σ (amount - cost) * PROFIT_SCALE // amount
    var top_names: List[String]
    var top_cents: List[Int]
    var row_ids: List[Int]  # the table's rows (row numbers), in order
    var ids: List[Int]  # their id column
    var cells: List[String]  # the table: TABLE_ROWS × 7 texts
    var query_ms: Float64  # the GPU group-by (mojoui.devgroup, over the days' rows)
    var rows_ms: Float64  # mojoui.devrows: the table's rows on the GPU, and their cells
    var compute_ms: Float64  # the whole answer, in its job

    def __init__(out self):
        self.rows = 0
        self.sum_cents = 0
        self.profit_sum = 0
        self.top_names = List[String]()
        self.top_cents = List[Int]()
        self.row_ids = List[Int]()
        self.ids = List[Int]()
        self.cells = List[String]()
        self.query_ms = 0
        self.rows_ms = 0
        self.compute_ms = 0

    def sum_amount(self) -> Float64:
        return Float64(self.sum_cents) / 100.0

    def avg_profit(self) -> Float64:
        """The average of (amount − cost) / amount over the matching rows (SPEC's average margin)."""
        return Float64(self.profit_sum) / Float64(PROFIT_SCALE) / Float64(self.rows) if self.rows > 0 else 0.0


def money(cents: Int) -> String:
    var s = String(abs(cents) % 100)
    if cents % 100 < 10 and cents % 100 > -10:
        s = "0" + s
    var whole = String(abs(cents) // 100)
    var grouped = String("")
    var n = whole.byte_length()
    for i in range(n):
        if i > 0 and (n - i) % 3 == 0:
            grouped += ","
        grouped += whole[byte=i]
    return ("-" if cents < 0 else "") + grouped + "." + s


def answer(o: Orders, f: Filters) raises -> Answer:
    var t0 = now_ns()
    var a = Answer()
    var lo_cents = min_cents(f.min_amount)
    var region = -1
    if f.region != ALL:
        region = o.table.code_of(o.c_region, f.region)  # (-1, an unknown region: nothing matches)
    var nprod = len(o.products)
    # the days asked for that hold data, and their rows: a slice (the rows are in day order)
    var lo_day = max(f.from_day, o.first_day)
    var hi_day = min(f.to_day, o.first_day + o.days - 1)
    var span = o.by_day.slice(o.table, Int64(f.from_day), Int64(f.to_day))
    var ndays = max(hi_day - lo_day + 1, 1)
    var ranges = List[ColumnRange]()
    if f.region != ALL:
        ranges.append(ColumnRange(o.c_region, Int64(region), Int64(region)))  # (-1: nothing matches)
    ranges.append(ColumnRange(o.c_amount, Int64(lo_cents), Int64.MAX))
    var profit = (dcol(o.c_amount) - dcol(o.c_cost)) * dlit(PROFIT_SCALE) // dcol(o.c_amount)
    var by_product = List[Int](length=nprod, fill=0)
    var seen = List[Int](length=nprod, fill=0)
    var by_day = List[Int](length=ndays, fill=0)
    # one pass over the days' rows: product × day groups (sum, count, profit). It gives the bars, the KPIs and the rows
    # per day (the table's cut-off) at once; measured faster than 40 product groups plus a per-day count, in two passes
    # or as two grouping sets in one (D-768).
    var g = group_rows(o.ctx, o.dt, ranges, dcol(o.c_product) * dlit(ndays) + (dcol(o.c_day) - dlit(lo_day)), nprod * ndays,
                       [dcol(o.c_amount), profit.copy()], rows=span, scratch=o.scratch)
    a.query_ms = g.milliseconds
    for p in range(nprod):
        for d in range(ndays):
            var k = p * ndays + d
            var n = g.counts[k]
            if n == 0:
                continue
            by_product[p] += g.sums[0][k]
            seen[p] += n
            by_day[d] += n
            a.rows += n
            a.sum_cents += g.sums[0][k]
            a.profit_sum += g.sums[1][k]
    # the bars: products by sum, largest first, ties by name
    var order = List[Int]()
    for p in range(nprod):
        if seen[p] > 0:
            order.append(p)
    for i in range(1, len(order)):
        var j = i
        while j > 0 and (by_product[order[j]] > by_product[order[j - 1]] or
                         (by_product[order[j]] == by_product[order[j - 1]] and o.products[order[j]] < o.products[order[j - 1]])):
            order.swap_elements(j, j - 1)
            j -= 1
    for i in range(min(TOP, len(order))):
        a.top_names.append(o.products[order[i]])
        a.top_cents.append(by_product[order[i]])
    # the table: the first 50 matching rows by day (newest first), then id
    var t1 = now_ns()
    a.row_ids = first_rows(o.ctx, o.table, o.dt, ranges, o.c_day, lo_day, by_day, TABLE_ROWS, o.c_id, rows=span, sorted=o.by_day,
                           scratch=o.scratch)
    for row in a.row_ids:
        a.ids.append(Int(o.table.get(o.c_id, row)))
        a.cells.append(day_text(Int(o.table.get(o.c_day, row))))
        a.cells.append(String(o.table.get(o.c_id, row)))
        a.cells.append(o.table.text_of(o.c_region, Int(o.table.get(o.c_region, row))))
        a.cells.append(o.table.text_of(o.c_product, Int(o.table.get(o.c_product, row))))
        a.cells.append(money(Int(o.table.get(o.c_amount, row))))
        a.cells.append(money(Int(o.table.get(o.c_cost, row))))
        a.cells.append("yes" if o.table.get(o.c_paid, row) != 0 else "no")
    a.rows_ms = ms_since(t1)
    a.compute_ms = ms_since(t0)
    return a^


# ---------- dates ----------

def days_from_civil(y: Int, m: Int, d: Int) -> Int:
    var yy = y - (1 if m <= 2 else 0)
    var era = (yy if yy >= 0 else yy - 399) // 400
    var yoe = yy - era * 400
    var doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def day_number(iso: String) raises -> Int:
    """"2025-03-15" → days since 1970-01-01."""
    var parts = iso.strip().split("-")
    if len(parts) != 3:
        raise Error("dates look like 2025-03-15, not '" + iso + "'")
    return days_from_civil(Int(String(parts[0])), Int(String(parts[1])), Int(String(parts[2])))


def day_text(days: Int) -> String:
    var z = days + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + (3 if mp < 10 else -9)
    var y = yoe + era * 400 + (1 if m <= 2 else 0)
    return String(y) + "-" + ("0" if m < 10 else "") + String(m) + "-" + ("0" if d < 10 else "") + String(d)


# ---------- the two jobs (off the UI thread) ----------

struct LoadJob(JobBody):
    comptime Out = Orders
    var path: String

    def __init__(out self, path: String):
        self.path = path

    def run(mut self, ctl: JobCtl) raises -> Orders:
        return open_orders(self.path, ctl)


struct StepJob(JobBody):
    comptime Out = Answer
    var orders: Orders  # (handles: the shared table and its device copy are not copied)
    var filters: Filters

    def __init__(out self, orders: Orders, filters: Filters):
        self.orders = orders.copy()
        self.filters = filters.copy()

    def run(mut self, ctl: JobCtl) raises -> Answer:
        ctl.check()
        return answer(self.orders, self.filters)
