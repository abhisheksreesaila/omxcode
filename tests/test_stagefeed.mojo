# mojoui.stagefeed (goal 77 M7e): the urgent tile first whatever its kind, then the centre tiles, then tiles that fill up to
# five; passive tiles in Today and live ones in Live until they are urgent; pinned tiles only in Pinned; an extra-large lead
# leaves room for three; the sides follow what the grid really shows; an occasion's charm goes on the tile it is about.
#   pixi run mojo run --disable-warnings -I . tests/test_stagefeed.mojo
# Prints one "<name>: ok" line per check, then "stagefeed: ok".
from std.testing import assert_equal, assert_true, assert_false
from mojoui.stagefeed import (
    FeedTile, StageFeed, stage_feed, stage_tiles, wear_occasion, occasion_charm, occasion_names, FEED_CENTRE, FEED_PASSIVE, FEED_LIVE,
)
from mojoui.livetiles import Tile, LiveTiles, TILE_L


def joined(ids: List[String]) -> String:
    var out = String("")
    for i in range(len(ids)):
        out += ("," if i > 0 else "") + ids[i]
    return out


def day(first: List[String]) -> List[FeedTile]:
    """The prototype's tiles and kinds, in the order given (most important first), then the rest."""
    var kinds = List[FeedTile]()
    var all: List[String] = ["traffic", "todo", "cal", "weather", "timer", "photos", "bday", "flight", "home", "cam"]
    var order = first.copy()
    for a in all:
        var seen = False
        for o in first:
            if o == a:
                seen = True
        if not seen:
            order.append(a)
    for id in order:
        var kind = String(FEED_CENTRE)
        if id == "weather" or id == "cal" or id == "bday" or id == "home" or id == "photos":
            kind = FEED_PASSIVE
        if id == "timer" or id == "traffic" or id == "flight":
            kind = FEED_LIVE
        kinds.append(FeedTile(id, kind, id == "photos" or id == "bday" or id == "cal"))
    return kinds^


def test_plain_day() raises:
    var ranked = day(["traffic", "todo", "cal", "weather", "timer", "photos", "bday", "flight", "home", "cam"])
    var f = stage_feed(ranked, "traffic", List[String]())
    assert_equal(joined(f.stage), "traffic,todo,cam,cal,photos")  # urgent (live) first, the centre ones, then fill to 5
    assert_equal(joined(f.today), "weather,bday,home")
    assert_equal(joined(f.live), "timer,flight")
    assert_equal(f.side_of("weather"), "today")
    print("a plain morning: weather in Today, traffic leads: ok")


def test_rain() raises:
    var ranked = day(["weather", "cal", "traffic", "todo", "timer", "photos", "bday", "flight", "home", "cam"])
    var f = stage_feed(ranked, "weather", List[String]())
    assert_equal(f.stage[0], "weather")  # passive, but urgent: the large tile
    assert_equal(f.side_of("weather"), "stage")
    assert_equal(f.side_of("traffic"), "live")  # live and not urgent: the right column
    var all = List[Tile]()
    for t in ranked:
        all.append(Tile(t.id, 0, t.id, "x", "y"))
    var tiles = LiveTiles()
    tiles.set_area(900, 600)
    tiles.set_tiles(stage_tiles(all, f))
    var lay = tiles.layout()
    assert_equal(lay.ids[0], "weather")
    assert_equal(lay.sizes[0], TILE_L)
    assert_equal(lay.holes, 0)
    print("rain: weather is the large tile on the stage: ok")


def test_pins_and_big() raises:
    var ranked = day(["traffic", "todo", "cal", "weather", "timer", "photos", "bday", "flight", "home", "cam"])
    var f = stage_feed(ranked, "traffic", ["todo"])
    assert_false(f.side_of("todo") == "stage")
    assert_equal(f.side_of("todo"), "pinned")
    assert_equal(joined(f.stage), "traffic,cam,cal,photos,bday")  # (todo's place filled)
    var urgent_pinned = stage_feed(ranked, "traffic", ["traffic"])
    assert_equal(urgent_pinned.stage[0], "todo")  # (a pinned tile never stands on the stage, urgent or not)
    var big = stage_feed(day(["flight", "weather", "todo"]), "flight", List[String](), most=3)
    assert_equal(len(big.stage), 3)
    assert_equal(big.stage[0], "flight")
    # the grid shows fewer than the feed asked for: the one left off goes to its side
    var g = stage_feed(ranked, "traffic", List[String]())
    g.place(ranked, ["traffic", "todo", "cam", "cal"])
    assert_equal(g.side_of("photos"), "today")
    print("pins and an extra-large lead: ok")


def test_occasions() raises:
    assert_equal(len(occasion_names()), 6)
    var want: List[String] = ["bag", "pennant", "turkey", "umbrella", "hat", "tag"]
    var names = occasion_names()
    for i in range(6):
        assert_equal(occasion_charm(names[i]), want[i])
    var tiles: List[Tile] = [Tile("weather", 0, "Weather", "Rain", ""), Tile("bday", 0, "Birthday", "Mum", ""), Tile("counter", 0, "Counter", "x", "")]
    tiles[2].charm = "pin"
    wear_occasion(tiles, "rain", "weather")
    assert_equal(tiles[0].charm, "umbrella")
    wear_occasion(tiles, "birthday", "bday")
    assert_equal(tiles[0].charm, "")  # (yesterday's charm comes off)
    assert_equal(tiles[1].charm, "hat")
    assert_equal(tiles[2].charm, "pin")  # (the person's pin stays)
    print("occasions put their charm on the tile they are about: ok")


def main() raises:
    test_plain_day()
    test_rain()
    test_pins_and_big()
    test_occasions()
    print("stagefeed: ok")
