# mojoui.tripmap (goal 77 M3), offline: Web Mercator both ways, fitting, van Wijk flights that end where they were sent, show_map's
# arguments read (and refused when wrong), its card as render_ui JSON (a valid genui screen with a TripMap), the tool's result, the
# stops as pointer parts, a draw from tiles in the disk cache (no network: the tile server and the geocoder point at a closed port),
# a point that flies to a stop, the 60 km rule, and the map tool registered for real (no stub).
from std.testing import assert_equal, assert_true, assert_almost_equal
from std.os import setenv, makedirs
from std.time import sleep
from mojoui.tripmap import (TripMap, Stop, View3, Fly, fit, world_x, world_y, lon_of, lat_of, read_stops, trip_ui, show_map_answer,
                            blit, SHOW_MAP)
from mojoui.tiles import TileStore, TILE
from mojoui.geocode import GeoAnswer, GEO_FOUND, GEO_NONE, settle, km, url_quote, fnv64, parse_answer
from mojoui.genui import GenUi, CV_TRIP
from mojoui.agentui import tool_card
from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.png import encode_png
from mojoui.clock import now_ns
from mojoui.pointer import match_clause
from mojoui.maptool import show_map_tool
from mojoui.jsonpatch import JDoc
from themes.omxqua import omxqua_palette
from mojoui import libc

comptime LISBON = '{"title":"A day in Lisbon","area":"Lisbon, Portugal","stops":[{"name":"Belém Tower","note":"the river fort","lat":38.6916,"lon":-9.2160},{"name":"the Alfama","note":"old streets","lat":38.7114,"lon":-9.1301},{"name":"LX Factory","note":"lunch","lat":38.7036,"lon":-9.1784}]}'


def main() raises:
    # Mercator both ways
    for lat in [-60.0, 0.0, 38.7, 51.5]:
        assert_almost_equal(lat_of(world_y(lat)), lat, atol=1e-9)
    assert_almost_equal(lon_of(world_x(-9.14)), -9.14, atol=1e-9)
    assert_almost_equal(world_x(0.0), 128.0, atol=1e-12)
    assert_almost_equal(world_y(0.0), 128.0, atol=1e-9)
    # show_map's arguments
    var t = read_stops(LISBON)
    assert_equal(t[0], "A day in Lisbon")
    assert_equal(len(t[2]), 3)
    assert_equal(t[2][1].name, "the Alfama")
    var bad = 0
    for wrong in ['{"stops":[]}', '{"stops":[{"name":"x"}]}', '{"stops":[{"name":"","lat":1,"lon":2}]}', '{"stops":[{"name":"x","lat":95,"lon":2}]}', "[1]"]:
        try:
            _ = read_stops(wrong)
        except:
            bad += 1
    assert_equal(bad, 5)
    assert_true(show_map_answer('{"stops":[]}').startswith('{"error"'))
    var said = show_map_answer(LISBON)
    assert_true(said.find("Belém Tower, the Alfama, LX Factory") >= 0 and said.find("in order") >= 0, said)
    assert_equal(show_map_tool().name, SHOW_MAP)
    # its card: render_ui JSON that genui accepts, a TripMap of three stops
    var card = trip_ui(LISBON)
    assert_equal(card, tool_card("show_map", LISBON))
    assert_equal(tool_card("render_ui", LISBON), "")
    var ui = GenUi(card, 10_000, 100)
    assert_equal(ui.problem, "")
    assert_equal(ui.summary(), "Card(TripMap)")
    assert_equal(len(ui.kinds), 1)
    assert_equal(ui.kinds[0], CV_TRIP)
    ui.card = "card3"
    var parts = ui.parts()
    assert_equal(len(parts), 3)
    assert_equal(parts[0].tag(), "card3.stop1")
    var hits = match_clause("Start at Belém Tower, then wander the Alfama and finish at LX Factory", parts)
    assert_equal(len(hits), 3)
    assert_equal(hits[0].part, "stop1")
    assert_equal(hits[1].part, "stop2")
    assert_equal(hits[2].part, "stop3")
    assert_equal(len(match_clause("Then the Factory for lunch.", parts)), 1)  # (a distinctive word of a name is enough)
    # fitting: every stop inside the canvas with room round it
    var xs = List[Float64]()
    var ys = List[Float64]()
    for ref s in t[2]:
        xs.append(world_x(s.lon))
        ys.append(world_y(s.lat))
    var v = fit(xs, ys, 760.0, 320.0)
    var zk = 2.0 ** v.zoom
    for i in range(3):
        var x = 380.0 + (xs[i] - v.cx) * zk
        var y = 160.0 + (ys[i] - v.cy) * zk
        assert_true(x >= 40.0 and x <= 720.0 and y >= 40.0 and y <= 280.0, "stop " + String(i) + " at " + String(x) + "," + String(y))
    assert_true(v.zoom > 11.0 and v.zoom < 14.0, String(v.zoom))
    # a flight ends exactly where it was sent, zooms out on the way for a long one, and starts where it was
    var a = View3(world_x(12.4964), world_y(41.9028), 9.0)  # Rome
    var b = View3(world_x(12.3155), world_y(45.4408), 9.0)  # Venice
    var f = Fly(a, b, 760.0, 1000)
    var start = f.at(1000)[0]
    assert_almost_equal(start.cx, a.cx, atol=1e-9)
    var mid = f.at(1000 + Int(f.ms * 0.5e6))[0]
    assert_true(mid.zoom < 8.5, "a long flight zooms out on the way: " + String(mid.zoom))
    var end = f.at(1000 + Int(f.ms * 1e6) + 1)
    assert_true(end[1])
    assert_almost_equal(end[0].cx, b.cx, atol=1e-12)
    assert_almost_equal(end[0].zoom, 9.0, atol=1e-9)
    assert_true(f.ms >= 450.0 and f.ms <= 1500.0)
    var z = Fly(a, View3(a.cx, a.cy, 12.0), 760.0, 0)  # (a pure zoom)
    assert_almost_equal(z.at(Int(z.ms * 1e6) + 1)[0].zoom, 12.0, atol=1e-9)
    # the 60 km rule
    var found = GeoAnswer(GEO_FOUND, 38.6916, -9.2160, 0, False, "")
    assert_equal(settle(38.70, -9.20, found)[2], "checked")
    assert_equal(settle(48.85, 2.35, found)[2], "guessed")
    assert_equal(settle(38.70, -9.20, GeoAnswer(GEO_NONE, 0, 0, 0, False, ""))[2], "guessed")
    assert_almost_equal(km(41.9028, 12.4964, 45.4408, 12.3155), 393.5, atol=2.0)
    assert_equal(url_quote("Belém Tower, Lisbon"), "Bel%C3%A9m%20Tower%2C%20Lisbon")
    assert_equal(fnv64("a"), UInt64(0xaf63dc4c8601ec8c))
    assert_equal(parse_answer('[{"lat":"38.69","lon":"-9.21"}]').state, GEO_FOUND)
    assert_equal(parse_answer("[]").state, GEO_NONE)
    # a draw, offline: tiles from a cache made here, the web unreachable (a closed port), so the stops stay where the model put them
    var dir = String("build/g77/tripmap-test-") + String(libc.getpid())
    _ = setenv("MOJOUI_TILE_CACHE", dir, True)
    _ = setenv("MOJOUI_GEO_CACHE", dir + "/geo", True)
    _ = setenv("MOJOUI_TILE_URL", "http://127.0.0.1:9/{z}/{x}/{y}.png", True)
    _ = setenv("MOJOUI_GEOCODER", "http://127.0.0.1:9/search", True)
    var zi = Int(v.zoom + 0.5)
    var n = 1 << zi
    var tile_px = List[UInt32](length=TILE * TILE, fill=UInt32(0xFF3366AA))  # (one flat colour: R 0xAA, G 0x66, B 0x33)
    var made = 0
    for ty in range(Int(v.cy * Float64(n) / 256.0) - 2, Int(v.cy * Float64(n) / 256.0) + 3):
        for tx in range(Int(v.cx * Float64(n) / 256.0) - 3, Int(v.cx * Float64(n) / 256.0) + 4):
            var p = dir + "/" + String(zi) + "/" + String(tx) + "/" + String(ty) + ".png"
            makedirs(dir + "/" + String(zi) + "/" + String(tx), exist_ok=True)
            with open(p, "w") as fh:
                fh.write_bytes(Span(encode_png(tile_px, TILE, TILE)))
            made += 1
    var pal = omxqua_palette(False)
    var font = Font()
    var buf = List[UInt32](length=760 * 320, fill=0)
    var surface = Surface(Int(buf.unsafe_ptr()), 760, 320, 1.0)
    var t0 = now_ns()
    var frames = 0
    while True:  # (until the tiles have come off the disk and the geocoder has failed: the stops are settled as guesses)
        surface.again = False
        ui.draw(100, surface, pal, ui_state(), font)
        frames += 1
        var flat = 0
        for i in range(0, 760 * 320, 97):
            if buf[i] == UInt32(0xFF3366AA):
                flat += 1
        if flat > 1500 and not ui.trips[0].busy():
            break
        assert_true(now_ns() - t0 < 20_000_000_000, "the cached tiles never showed (" + String(flat) + " flat samples) " + TileStore.shared()[].problem)
        sleep(0.01)
    var store = TileStore.shared()
    assert_true(len(store[].disk_ms) > 0, "tiles read from the disk cache")
    assert_equal(len(store[].net_ms), 0)
    for ref s in ui.trips[0].stops:
        assert_equal(s.how, "guessed")
    # the first stop's marker is drawn in the accent where the projection puts it
    var vw = ui.trips[0].view
    var mx = Int(380.0 + (world_x(-9.2160) - vw.cx) * (2.0 ** vw.zoom))
    var my = Int(160.0 + (world_y(38.6916) - vw.cy) * (2.0 ** vw.zoom))
    assert_equal(buf[my * 760 + mx + 5] & 0xFFFFFF, pal.accent & 0xFFFFFF)
    var log = ui.take_log()
    assert_true(len(log) >= 4, String(len(log)))  # (three stops settled, then "settled=3")
    var first = False
    for line in log:  # (the answers land in any order)
        if line.startswith("MAP: card=card3 stop=1 "):
            first = line.find("how=guessed") >= 0
    assert_true(first, log[0])
    # a point flies to stop 2 and the canvas asks for frames while it does
    assert_true(ui.point("card3.stop2"))
    assert_true(not ui.point("card4.stop2"))
    assert_true(not ui.point("card3.word"))
    surface.again = False
    ui.draw(100, surface, pal, ui_state(), font)
    assert_true(surface.again)
    var target = ui.trips[0].close_up(1)
    sleep(1.7)
    ui.draw(100, surface, pal, ui_state(), font)
    assert_almost_equal(ui.trips[0].view.cx, target.cx, atol=1e-9)
    assert_almost_equal(ui.trips[0].view.zoom, target.zoom, atol=1e-9)
    assert_true(target.zoom >= v.zoom + 0.99)  # (at least a step closer than the whole trip)
    var t1 = now_ns()
    for _ in range(20):
        ui.draw(100, surface, pal, ui_state(), font)
    _ = len(buf)  # (the surface draws into buf: keep it alive to here)
    print("tripmap draw 760x320:", Float64(now_ns() - t1) / 20e6, "ms a frame;", frames, "frames to settle;", made, "tiles cached")
    print("tripmap: ok")


def ui_state() raises -> JDoc:
    return JDoc.parse("{}")
