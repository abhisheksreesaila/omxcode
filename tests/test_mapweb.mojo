# mojoui.tiles and mojoui.geocode against the real web (goal 77 M3): OpenStreetMap tiles fetched on worker threads, decoded in
# Mojo, kept on disk and read back; Nominatim answers for real places, cached, one request a second. Built with scripts/mojo_flare.sh
# (https). Prints the cold (web) and warm (disk) tile times.
#   scripts/mojo_flare.sh build tests/test_mapweb.mojo -o build/test_mapweb && build/test_mapweb
from std.testing import assert_equal, assert_true
from std.os import setenv, getenv
from std.time import sleep
from mojoui.clock import now_ns
from mojoui.tiles import TileStore, TILE
from mojoui.geocode import Geocoder, GEO_PENDING, GEO_FOUND, GEO_NONE, km, settle
from mojoui import libc


def median(v: List[Float64]) -> Float64:
    var s = v.copy()
    sort(s)
    return s[len(s) // 2] if len(s) > 0 else -1.0


def main() raises:
    var dir = String("build/g77/tiles-test-") + String(libc.getpid())
    _ = setenv("MOJOUI_TILE_CACHE", dir, True)
    _ = setenv("MOJOUI_GEO_CACHE", dir + "/geo", True)
    var tiles = TileStore.shared()
    # a 3 x 2 block of Lisbon at zoom 13, twice the server's limit of two at once
    var want = List[Tuple[Int, Int]]()
    for dx in range(3):
        for dy in range(2):
            want.append((3913 + dx, 3095 + dy))
    var t0 = now_ns()
    while True:
        _ = tiles[].poll()
        var missing = 0
        for w in want:
            if tiles[].find(13, w[0], w[1]) < 0:
                missing += 1
                tiles[].want(13, w[0], w[1])
        if missing == 0:
            break
        assert_true(now_ns() - t0 < 60_000_000_000, "tiles didn't come in 60 s: " + tiles[].problem)
        sleep(0.005)
    var cold_all = Float64(now_ns() - t0) / 1e6
    assert_equal(len(tiles[].net_ms), 6)
    var k = tiles[].find(13, 3913, 3095)
    assert_equal(len(tiles[].pixels[k]), TILE * TILE)
    var opaque = 0
    for p in tiles[].pixels[k]:
        if (p >> 24) == 255:
            opaque += 1
    assert_true(opaque > TILE * TILE // 2)
    print("tiles web: 6 tiles in", Int(cold_all), "ms; each", Int(median(tiles[].net_ms)), "ms (median request + decode)")
    # the same tiles from disk: a fresh store (as the next run of the app would have)
    var again = TileStore()
    again.dir = dir
    var t1 = now_ns()
    while True:
        _ = again.poll()
        var missing = 0
        for w in want:
            if again.find(13, w[0], w[1]) < 0:
                missing += 1
                again.want(13, w[0], w[1])
        if missing == 0:
            break
        assert_true(now_ns() - t1 < 10_000_000_000, "disk tiles didn't come: " + again.problem)
        sleep(0.001)
    assert_equal(len(again.net_ms), 0)
    assert_equal(len(again.disk_ms), 6)
    print("tiles disk: 6 tiles in", Int(Float64(now_ns() - t1) / 1e6), "ms; each", median(again.disk_ms), "ms (median read + decode)")
    print("tiles cold_ms", median(tiles[].net_ms), "cached_ms", median(again.disk_ms))
    # the geocoder: real places, one a second, cached
    var geo = Geocoder.shared()
    var names: List[String] = ["Belém Tower, Lisbon", "LX Factory, Lisbon", "Florence, Italy"]
    var truth: List[Tuple[Float64, Float64]] = [(38.6916, -9.2160), (38.7036, -9.1784), (43.7696, 11.2558)]
    var t2 = now_ns()
    for i in range(len(names)):
        var a = geo[].lookup(names[i])
        while a.state == GEO_PENDING:
            sleep(0.01)
            a = geo[].lookup(names[i])
            assert_true(now_ns() - t2 < 30_000_000_000, "the geocoder didn't answer")
        assert_equal(a.state, GEO_FOUND, names[i] + ": " + a.why)
        var d = km(a.lat, a.lon, truth[i][0], truth[i][1])
        assert_true(d < 2.0, names[i] + " is " + String(d) + " km off")
        print("geocode", names[i], a.lat, a.lon, "off", d, "km in", Int(a.ms), "ms")
    var spent = Float64(now_ns() - t2) / 1e9
    assert_true(spent > 2.0, "three requests in under two seconds: the gate didn't hold")  # (1.05 s apart)
    # nothing found
    var none = geo[].lookup("Qqqzzx Nowhereville 99999")
    while none.state == GEO_PENDING:
        sleep(0.01)
        none = geo[].lookup("Qqqzzx Nowhereville 99999")
    assert_equal(none.state, GEO_NONE)
    # cached: a fresh geocoder reads the disk, no gate wait
    var g2 = Geocoder()
    g2.dir = dir + "/geo"
    var t3 = now_ns()
    var c = g2.lookup(names[0])
    while c.state == GEO_PENDING:
        sleep(0.001)
        c = g2.lookup(names[0])
    assert_true(c.from_disk)
    print("geocode cached in", Float64(now_ns() - t3) / 1e6, "ms")
    # the 60 km rule: Paris, Texas is not the Paris the model meant
    var paris = settle(48.8566, 2.3522, c)  # (Belém is 1450 km from Paris: the guess stands)
    assert_equal(paris[2], "guessed")
    var near = settle(38.70, -9.20, c)
    assert_equal(near[2], "checked")
    print("mapweb: ok")
