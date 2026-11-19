# genui's LiveTiles (goal 77 M7c): the catalog validates the sample and refuses bad tiles with a reason an agent can act on;
# the card draws the centre tiles with mojoui.livetiles (the grid full: 0 holes), names the passive and live ones under it,
# and every tile is a pointer part; a tap on a tile is an action the agent hears.
#   pixi run mojo run -I . tests/test_genui_tiles.mojo
from std.testing import assert_equal, assert_true
from mojoui.genui import GenUi, validate, sample, schema, CV_TILES, ACT_ACTION
from mojoui.jsonpatch import JDoc
from mojoui.canvas import Surface
from mojoui.app import Event
from mojoui.text import Font
from mojoui.view import TAP
from themes.omxqua import omxqua


def wrap(tiles: String) -> String:
    return '{"ui":{"component":"LiveTiles","tiles":[' + tiles + "]}}"


comptime ONE = '{"id":"a","head":"A","faces":[{"big":"x"}]}'


def refused(args: String, has: String) raises:
    var why = validate(args)
    if why.find(has) < 0:
        print("expected a refusal with", has, "got:", why)
    assert_true(why.find(has) >= 0)


def main() raises:
    # the sample validates; the schema lists the component and its faces as objects
    assert_equal(validate(sample("LiveTiles")), "")
    assert_true(schema().find('"LiveTiles"') >= 0)
    assert_true(schema().find('"faces":{"type":"array","minItems":1,"maxItems":4,"items":{"type":"object"') >= 0)
    # refusals the agent can act on
    refused(wrap(ONE + "," + ONE), "both have the id \"a\"")
    refused(wrap('{"id":"Rain Tile","head":"A","faces":[{"big":"x"}]}'), "must be one lower-case word")
    refused(wrap('{"id":"a","head":"A","faces":[]}'), "faces must be a list of 1 to 4 objects")
    refused(wrap('{"id":"a","head":"A","faces":[{"sub":"x"}]}'), "needs \"big\"")
    refused(wrap('{"id":"a","kind":"side","head":"A","faces":[{"big":"x"}]}'), "kind must be one of centre, passive, live")
    refused(wrap('{"id":"a","kind":"passive","head":"A","faces":[{"big":"x"}]}'), "at least one tile of kind \"centre\"")
    refused('{"ui":{"component":"LiveTiles","tiles":[]}}', "tiles must be a list of 1 to 12 objects")
    refused(wrap('{"id":"a","head":"A","faces":[{"big":"x"}],"actions":["1","2","3"]}'), "actions must be a list of 0 to 2 strings")
    refused(wrap('{"id":"a","head":"A","faces":[{"big":"x"}],"big":"yes"}'), "big must be true or false")
    # the card: four centre tiles on the grid (l l w w: 0 holes), the passive and live ones beside it
    var ui = GenUi(sample("LiveTiles"), 10_000, 100)
    assert_equal(ui.problem, "")
    ui.card = "card1"
    assert_equal(ui.kinds[0], CV_TILES)
    var lay = ui.tiles[0].layout()
    assert_equal(len(lay.ids), 4)
    assert_equal(lay.ids[0], "traffic")
    assert_equal(lay.holes, 0)
    var state = JDoc()
    _ = ui.view(state, 1)
    var px = List[UInt32](length=800 * 420, fill=0)
    var surface = Surface(Int(px.unsafe_ptr()), 800, 420, 1.0)
    ui.draw(100, surface, omxqua(False).palette, state, Font())
    _ = len(px)
    var rec = ui.tiles[0].record()
    assert_true(rec.startswith("traffic "))
    # parts: the four grid tiles in the canvas and the two side tiles by their lines
    var parts = ui.parts()
    assert_equal(len(parts), 6)
    var tags = String("")
    for p in parts:
        tags += p.tag() + " "
    assert_true(tags.find("card1.weather") >= 0 and tags.find("card1.bday") >= 0 and tags.find("card1.timer") >= 0)
    assert_equal(parts[0].inside, "card1.tiles0")
    # a tap on the first tile is an action the agent hears
    var e = Event(10_000, "", TAP, 60.0, 60.0)
    var act = ui.handle(e, state)
    assert_equal(act.kind, ACT_ACTION)
    assert_equal(act.report(), '{"action":"tiles","value":{"did":"tapped","id":"traffic"}}')
    print("genui tiles: ok")
