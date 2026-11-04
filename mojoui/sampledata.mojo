# mojoui.sampledata: made-up data for demos and tests (goal 48): a million orders an agent can name as a dataset.
# The same rows every run (a xorshift generator), so tests can check what a chart says against a plain loop.

from mojoui.sheet import Sheet
from omxcore import Table, TEXT, DECIMAL, INT

comptime REGIONS: List[String] = ["North", "South", "East", "West", "Central"]
comptime PRODUCTS: List[String] = ["Trail shoe", "Rain shell", "Day pack", "Wool socks", "Fleece", "Water bottle", "Headlamp", "Trek poles"]


def sample_orders(rows: Int, mut revenue_by_region: List[Float64], use_gpu: Bool = True) raises -> Sheet:
    """`rows` orders: region (5 words), product (8), units (1–9), revenue (cents, 0–499.99). `revenue_by_region`
    gets each region's total revenue by a plain loop (REGIONS' order), to check an engine's answer against."""
    var t = Table.empty()
    var region = t.add_column("region", TEXT)
    var product = t.add_column("product", TEXT)
    var units = t.add_column("units", INT)
    var revenue = t.add_column("revenue", DECIMAL, 2)
    var rc = List[Int64]()
    var pc = List[Int64]()
    for r in materialize[REGIONS]():
        rc.append(Int64(t.add_word(region, r)))
    for p in materialize[PRODUCTS]():
        pc.append(Int64(t.add_word(product, p)))
    revenue_by_region = List[Float64](length=5, fill=0.0)
    var x: UInt64 = 88172645463325252
    for _ in range(rows):
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        var r = Int(x % 5)
        var cents = Int((x >> 8) % 50_000)
        t.append(region, rc[r])
        t.append(product, pc[Int((x >> 5) % 8)])
        t.append(units, Int64(Int((x >> 20) % 9) + 1))
        t.append(revenue, Int64(cents))
        revenue_by_region[r] += Float64(cents) / 100.0
    return Sheet(t^.share(), use_gpu)
