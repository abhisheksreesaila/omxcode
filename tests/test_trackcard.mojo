# The drone's cards (goal 39 M8): mojoui.trackcard (a telemetry log as a card in step with a video: chart + cursor, map),
# mojoui.mapview, mojoui.inspection_tables (places as a table, two flights compared from their tables, the flight plan),
# videojobs' inspection analyzer (rows georeferenced with the log) and a table card's quiet action. Never reads truth.json.
#   scripts/mxbuild.sh tests/test_trackcard.mojo -o build/test_trackcard && G39_MEDIA=build/g39/media G39_OUT=build/g39 build/test_trackcard
# Prints "trackcard: ok", "mapview: ok", "inspection tables: ok".
from std.testing import assert_equal, assert_true
from std.os import getenv
from std.os.path import exists
from mojoui.app import Event
from mojoui.canvas import Surface
from mojoui.csvio import read_table
from mojoui.sheet import Sheet
from mojoui.text import Font
from mojoui.theme import Palette
from mojoui.view import SET_TO
from mojoui.trackcard import TrackCards, is_track, series_from_sheet, metric_label, TK_CHART, TK_METRIC, TK_CLOSE
from mojoui.mapview import MapView, MARK_PLACE, MARK_FINDING, nice_step
from mojoui.inspection_tables import places_table, is_places, read_places, compare_tables, flight_plan
from mojoui.inspection import compare
from mojoui.tablecard import TableCards, TC_ACTION
from mojoui.videojobs import analyze, INSPECTION, analyzer_needs_log
from themes.liquid import liquid_palette


def count_colour(px: List[UInt32], c: UInt32) -> Int:
    """Pixels within a few levels of colour c in every channel (edges are antialiased)."""
    var n = 0
    for p in px:
        var close = True
        for sh in range(0, 24, 8):
            var d = Int((p >> UInt32(sh)) & 255) - Int((c >> UInt32(sh)) & 255)
            if d > 6 or d < -6:
                close = False
        if close:
            n += 1
    return n


def main() raises:
    var media = getenv("G39_MEDIA", "build/g39/media")
    var out = getenv("G39_OUT", "build/g39")
    var font = Font()
    var pal = liquid_palette()

    # a telemetry CSV is a track; its series carries every number column under geo's names
    var sheet = Sheet(read_table(media + "/telemetry_a.csv").table, False)
    assert_true(is_track(sheet), "telemetry_a is a track")
    var ts = series_from_sheet(sheet)
    assert_true(ts.rows() > 100 and ts.index("lat") >= 0 and ts.index("alt_m") >= 0, "series columns")
    assert_equal(metric_label("alt_m"), "Altitude")
    var shipments = Sheet(read_table(media + "/shipments.csv").table, False)
    assert_true(not is_track(shipments), "shipments isn't a track")

    # the card: bound to a video, its chart seeks it (an agent sets a time), its cursor draws at the time given
    var tracks = TrackCards(4200, 250, 4)
    var k = tracks.add("telemetry_a", ts.copy(), "/v/drone_a.mp4", 0, 0, 720, 300)
    assert_equal(tracks.for_video("/v/drone_a.mp4"), k)
    # which video a log belongs to (goal 41 M4: moved here from omxplorer): the name that ends the same way and has no
    # log yet; else the newest video with none; else ""
    var videos: List[String] = ["/v/drone_a.mp4", "/v/drone_b.mp4", "/v/dock.mp4"]
    assert_equal(tracks.video_for_log("telemetry_b", videos), "/v/drone_b.mp4")
    assert_equal(tracks.video_for_log("telemetry_a", videos), "/v/dock.mp4")  # (drone_a has its log already: the newest free one)
    assert_equal(tracks.video_for_log("log", List[String]()), "")
    var only_a: List[String] = ["/v/drone_a.mp4"]
    assert_equal(tracks.video_for_log("telemetry_x", only_a), "")
    assert_true(tracks.cards[k].has_map(), "it has positions")
    var e = Event(tracks.msg(k) + TK_CHART, "12.5", SET_TO)
    assert_true(tracks.update(e, font, pal), "the chart's event")
    assert_equal(tracks.seek_card, k)
    assert_true(abs(tracks.seek_to - 12.5) < 1e-9, "seek to 12.5")
    var w = 480
    var h = 220
    var a = List[UInt32](length=w * h, fill=0)
    var b = List[UInt32](length=w * h, fill=0)
    var sa = Surface(Int(a.unsafe_ptr()), w, h, 1.0)
    var sb = Surface(Int(b.unsafe_ptr()), w, h, 1.0)
    tracks.draw(tracks.canvas(k), sa, font, pal, 3.0)
    tracks.draw(tracks.canvas(k), sb, font, pal, 20.0)
    var differ = 0
    for i in range(w * h):
        if a[i] != b[i]:
            differ += 1
    assert_true(differ > 50, "the cursor moves with the time")
    assert_true(tracks.describe(tracks.canvas(k), 12.5).find("Altitude") >= 0, "describe reads the row")
    var em = Event(tracks.msg(k) + TK_METRIC, "", 1)
    _ = tracks.update(em, font, pal)
    assert_equal(tracks.cards[k].metric, 1)
    print("trackcard: ok")

    # the map: the route, marks and the dot (in the accent) on the canvas's ground; a scale that reads in round metres
    var mp = MapView(ts.column("lat"), ts.column("lon"))
    mp.mark(ts.value("lat", 100), ts.value("lon", 100), "P01", MARK_PLACE)
    mp.mark(ts.value("lat", 150), ts.value("lon", 150), "", MARK_FINDING, 4)
    mp.at(ts.at("lat", 10.0), ts.at("lon", 10.0))
    var m = List[UInt32](length=w * h, fill=0)
    var sm = Surface(Int(m.unsafe_ptr()), w, h, 1.0)
    mp.draw(sm, font, pal)
    var opaque = 0
    for px in m:
        if (px >> 24) == 255:
            opaque += 1
    assert_equal(opaque, w * h)  # (every pixel opaque: a host shows the map, not the card behind it)
    assert_true(count_colour(m, pal.accent) > 20, "the route flown and the dot in the accent")
    assert_true(count_colour(m, pal.bad) > 10, "a finding in the bad tone")
    assert_equal(nice_step(43.0), 50.0)
    assert_equal(nice_step(180.0), 200.0)
    assert_true(mp.describe().find("1 places, 1 findings") >= 0, mp.describe())
    print("mapview: ok")

    # the inspection analyzer: needs the log, answers with the places table; two flights compared from their tables
    assert_true(analyzer_needs_log(INSPECTION) and not analyzer_needs_log(0), "which analyzers need a log")
    var refused = False
    try:
        _ = analyze(media + "/drone_a.mp4", INSPECTION)
    except:
        refused = True
    assert_true(refused, "no log, no inspection")
    var fa = analyze(media + "/drone_a.mp4", INSPECTION, log=ts.copy())
    var tb = series_from_sheet(Sheet(read_table(media + "/telemetry_b.csv").table, False))
    var fb = analyze(media + "/drone_b.mp4", INSPECTION, log=tb^)
    var pa = Sheet(fa.take_table().share(), False)
    var pb = Sheet(fb.take_table().share(), False)
    assert_true(is_places(pa) and is_places(pb) and not is_places(sheet), "places tables")
    var ra = read_places(pa)
    var rb = read_places(pb)
    assert_true(len(ra.assets) >= 2 and len(ra.assets) == len(rb.assets) and len(ra.found) >= 1, "assets and defects read back")
    for ref f in ra.found:
        assert_true(f.asset.byte_length() > 0 and 1 <= f.severity <= 5, "a defect on an asset, with a level")
    var worse = Sheet(compare_tables(pa, pb, 5.0).share(), False)
    var want = List[String]()
    for ref c in compare(ra.assets, ra.found, rb.assets, rb.found, 5.0):
        if c.is_worse():
            want.append(c.asset)
    assert_equal(worse.rows(), len(want))
    for r in range(worse.rows()):
        assert_equal(worse.plain_text(worse.index("asset"), r), want[r])
    var plan = out + "/test_waypoints.csv"
    assert_equal(flight_plan(plan, worse, 25.0, "inspect"), len(want))
    var lines = open(plan, "r").read().strip().split("\n")
    assert_equal(len(lines), len(want) + 1)
    assert_equal(String(lines[0]), "asset,lat,lon,alt_m,action")
    print("worse:", worse.rows(), "assets; plan:", plan)

    # a table card's one quiet action
    var cards = TableCards(4100, 230, 4)
    var t = cards.add("worse", worse^, 0, 0, 400, 300, font, pal)
    cards.cards[t].act_with("Flight plan", "route", "flight-plan", "Write the next flight")
    _ = cards.update(Event(cards.msg(t) + TC_ACTION, "", 0), font, pal, out)
    assert_equal(cards.acted, t)
    print("inspection tables: ok")
