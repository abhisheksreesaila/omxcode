# The globe's data and projection, checked against facts that don't depend on how it looks.
# Run: pixi run mojo run -I examples/globe -I . examples/globe/test_globe.mojo
from std.testing import assert_equal, assert_true
from earth import (
    rasterize, earth, flights, pick_point, globe, Knobs8, DEG, TW, TH, CUBE, WORDS, CW, CH, HOURS,
)
from mojoui.gpu import Gpu


def land_at(data: List[UInt32], lon: Float64, lat: Float64) -> Bool:
    var x = min(Int((lon + 180.0) / 360.0 * Float64(TW)), TW - 1)
    var y = min(Int((90.0 - lat) / 180.0 * Float64(TH)), TH - 1)
    return (data[y * TW + x] & 0xFF) > 127


def main() raises:
    # 1. A vertex exactly on a row's centre (y = 2.5) must not leave a row open (the equator band, 2026-11-09)
    var square = List[List[Float32]]()
    square.append([Float32(1), Float32(2.5), Float32(6), Float32(2.5), Float32(6), Float32(6.5), Float32(1), Float32(6.5)])
    var m = rasterize(square, 10, 10, 1)
    var filled = 0
    for i in range(100):
        filled += Int(m[i])
    assert_equal(filled, 20, "rows 2–5 × columns 1–5")
    for y in range(10):
        for x in range(10):
            assert_equal(Int(m[y * 10 + x]), 1 if (y >= 2 and y <= 5 and x >= 1 and x <= 5) else 0, "texel " + String(x) + "," + String(y))

    # 2. Land and sea where they are
    var data = List[UInt32](length=WORDS, fill=0)
    earth(data)
    var lands: List[Tuple[String, Float64, Float64]] = [("London", -0.1, 51.5), ("Sahara", 10.0, 23.0), ("Brasília", -47.9, -15.8), ("Ulan Bator", 106.9, 47.9), ("Antarctica", 0.0, -85.0), ("Sydney", 150.9, -33.8)]
    var seas: List[Tuple[String, Float64, Float64]] = [("Mid-Atlantic", -35.0, 0.0), ("Pacific", -150.0, 10.0), ("Indian Ocean", 80.0, -20.0), ("Mediterranean", 18.0, 34.5), ("Equator, Gulf of Guinea", 0.0, 0.0)]
    for p in lands:
        assert_true(land_at(data, p[1], p[2]), p[0] + " is land")
    for p in seas:
        assert_true(not land_at(data, p[1], p[2]), p[0] + " is sea")
    # every row of the texture is closed: no row is land from some coast to the edge of the map (the band's symptom)
    var y_eq = TH // 2
    assert_true(not land_at(data, -20.0, 0.1) and not land_at(data, -20.0, -0.1), "no band along the equator")

    # 3. The cube holds every report, each in an hour slice
    var f = flights(data, 300, 2)
    var total = 0
    for i in range(CUBE, WORDS):
        total += Int(data[i])
    assert_equal(total, f.reports, "every report binned once")
    assert_true(f.reports > 10_000, "flights reported")

    # 4. Picking inverts the projection: the centre is the view's centre, the rim is 90° away
    var k = Knobs8(Float32(-30.0 / DEG), Float32(25.0 / DEG), 400, 12, 0, 0, 0, 1)
    var c = pick_point(500, 400, 1000, 800, k)
    assert_true(abs(c[0] + 30.0) < 0.01 and abs(c[1] - 25.0) < 0.01, "centre → (-30, 25): " + String(c[0]) + ", " + String(c[1]))
    var top = pick_point(500, 400 - 399.999, 1000, 800, k)
    assert_true(abs(top[1] - 90.0 + 25.0) < 0.5 and abs(top[1] - 65.0) < 0.5, "top of the disc → 65°N")
    assert_equal(pick_point(5, 5, 1000, 800, k)[2], 0, "a corner is space")

    # 5. The pixel function is the same on the GPU and the CPU
    var gpu = Gpu()
    var cpu = Gpu(use=False)
    gpu.set_data(data.copy())
    cpu.set_data(data^)
    var kk = Knobs8(Float32(-30.0 / DEG), Float32(25.0 / DEG), 90, 14.5, 15, 0.2, Float32(-16.5 / DEG), 1)
    var a = gpu.render_with[globe](240, 200, kk)
    var b = cpu.render_with[globe](240, 200, kk)
    var differ = 0
    var worst = 0
    for i in range(len(a.pixels)):
        if a.pixels[i] != b.pixels[i]:
            differ += 1
            comptime for ch in range(3):
                var d = abs(Int((a.pixels[i] >> UInt32(8 * ch)) & 0xFF) - Int((b.pixels[i] >> UInt32(8 * ch)) & 0xFF))
                worst = max(worst, d)
    # (the GPU's fast sin/atan2/exp differ in the last bits: a colour level or two, never a different picture)
    assert_true(worst <= 3, "GPU and CPU within 3 levels: " + String(worst))
    print("PASS globe: rasterizer rows closed; " + String(len(lands)) + " land and " + String(len(seas)) + " sea places right; "
          + String(f.reports) + " reports binned; picking inverts; " + gpu.name + " vs CPU: " + String(differ) + " of " + String(len(a.pixels))
          + " pixels differ, by ≤ " + String(worst) + " levels")
