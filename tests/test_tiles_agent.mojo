# Agent-driven live tiles (goal 77 M7c): a shown card changes without being sent again. Screens.patch applies a JSON Patch to a
# card's render_ui arguments and validates it again (a bad one leaves the card as it was); a CUSTOM `ui_patch` event does the
# same; the `tiles` tool's ops (promote, add, remove, set_face) become patches, answered with the new order or a refusal that
# says what to fix; a promoted tile becomes the first, large tile with the grid full (0 holes for 2-6 tiles) and glides there.
#   scripts/mxbuild.sh tests/test_tiles_agent.mojo -o build/test_tiles_agent && build/test_tiles_agent
from std.testing import assert_equal, assert_true, assert_false
from mojoui.agui import Agent, Tool
from mojoui.agentui import Screens, tiles_tool
from mojoui.genui import sample, schema
from mojoui.json import Json, json_string
from mojoui.jsonpatch import JDoc
from mojoui.canvas import Surface
from mojoui.livetiles import TILE_S, TILE_L, TILE_XL
from mojoui.tilescard import TILES
from themes.omxqua import omxqua


def call(mut agent: Agent, id: String, tool: String, args: String):
    _ = agent.on_json('{"type":"TEXT_MESSAGE_START","messageId":"m-' + id + '","role":"assistant"}')
    _ = agent.on_json('{"type":"TOOL_CALL_START","toolCallId":"' + id + '","toolCallName":"' + tool + '","parentMessageId":"m-' + id + '"}')
    _ = agent.on_json('{"type":"TOOL_CALL_ARGS","toolCallId":"' + id + '","delta":' + json_string(args) + "}")
    _ = agent.on_json('{"type":"TOOL_CALL_END","toolCallId":"' + id + '"}')


def waiting(agent: Agent) -> Int:
    """tiles calls not answered yet (the render_ui call stays open until the person acts on its card)."""
    var n = 0
    for c in agent.pending():
        if c.name == TILES:
            n += 1
    return n


def draw(mut screens: Screens, k: Int):
    """One frame of screen k's first canvas at 800 x 420 (the tiles learn their size, so later changes glide)."""
    var px = List[UInt32](length=800 * 420, fill=0)
    var s = Surface(Int(px.unsafe_ptr()), 800, 420, 1.0)
    screens.draw(screens.uis[k].canvas_base, s, omxqua(False).palette, JDoc())
    _ = len(px)


def order(screens: Screens, k: Int) -> String:
    var lay = screens.uis[k].tiles_at(screens.uis[k].tiles_node()).layout()
    var out = String("")
    for i in range(len(lay.ids)):
        out += ("," if i > 0 else "") + lay.ids[i]
    return out


def tiles_card(n: Int) -> String:
    var t = String("")
    for i in range(n):
        t += ("," if i > 0 else "") + '{"id":"t' + String(i) + '","head":"Tile ' + String(i) + '","faces":[{"big":"' + String(i) + '"}]}'
    return '{"ui":{"component":"Card","title":"Now","children":[{"component":"LiveTiles","tiles":[' + t + "]}]}}"


def main() raises:
    var agent = Agent("", 0, 0, "t")
    agent.offer(Tool("render_ui", "Show UI", schema()))
    agent.offer(tiles_tool())
    _ = Json.parse(tiles_tool().parameters)  # (the tool's schema is JSON)
    var screens = Screens(20_000, 2000)
    # the agent shows the sample (traffic, todo, cal, weather on the grid; bday passive; timer live)
    call(agent, "c1", "render_ui", sample("LiveTiles"))
    _ = screens.take(agent)
    assert_equal(len(screens.uis), 1)
    assert_equal(screens.uis[0].problem, "")
    assert_equal(order(screens, 0), "traffic,todo,cal,weather")
    draw(screens, 0)

    # the generic patch: a face changed in place; a patch that breaks the card is refused and changes nothing
    assert_equal(screens.patch(0, '[{"op":"replace","path":"/ui/tiles/1/faces/0/big","value":"2 to do"}]'), "")
    assert_true(screens.uis[0].args().find("2 to do") >= 0)
    var why = screens.patch(0, '[{"op":"add","path":"/ui/tiles/-","value":{"id":"todo","head":"Again","faces":[{"big":"x"}]}}]')
    assert_true(why.find("both have the id \"todo\"") >= 0)
    assert_true(screens.uis[0].args().find("Again") < 0)
    assert_true(screens.patch(0, '[{"op":"remove","path":"/ui/nothing"}]').find("doesn't apply") >= 0)
    # a CUSTOM ui_patch event from an AG-UI agent
    _ = agent.on_json('{"type":"CUSTOM","name":"ui_patch","value":{"card":"card1","patch":[{"op":"replace","path":"/ui/tiles/2/head","value":"Today"}]}}')
    assert_equal(screens.custom(agent), "")
    assert_true(screens.uis[0].args().find('"head":"Today"') >= 0)
    _ = agent.on_json('{"type":"CUSTOM","name":"ui_patch","value":{"card":"card9","patch":[]}}')
    assert_true(screens.custom(agent).find("no card") >= 0)

    # the tool: promote weather: it becomes the first, large tile, the grid stays full, and it glides there
    var was = screens.uis[0].tiles_at(screens.uis[0].tiles_node()).box_of("weather")
    var res = screens.tiles('{"op":"promote","id":"weather"}')
    assert_true(res.startswith('{"done":true,"card":"card1","order":["weather","traffic","todo","cal"]'))
    var tl = screens.uis[0].tiles_at(screens.uis[0].tiles_node())
    var lay = tl.layout()
    assert_equal(lay.ids[0], "weather")
    assert_equal(lay.sizes[0], TILE_L)
    assert_equal(lay.holes, 0)
    assert_true(tl.moving())  # (gliding from where it was, not jumped)
    var now = tl.box_of("weather")
    assert_true(abs(now.x - was.x) < 0.5 and abs(now.w - was.w) < 0.5)  # (its first frame is where it was)
    assert_true(tl.target_of("weather").h > was.h + 50)  # (w 2x1 -> l 2x2)
    draw(screens, 0)
    # promote with big: extra large (the 3-tile layout: the rest overflow, named under the grid)
    res = screens.tiles('{"op":"promote","id":"cal","big":true}')
    lay = screens.uis[0].tiles_at(screens.uis[0].tiles_node()).layout()
    assert_equal(lay.ids[0], "cal")
    assert_equal(lay.sizes[0], TILE_XL)
    assert_equal(lay.holes, 0)
    # promoting another clears the big one, so the promoted tile leads
    res = screens.tiles('{"op":"promote","id":"traffic"}')
    lay = screens.uis[0].tiles_at(screens.uis[0].tiles_node()).layout()
    assert_equal(lay.ids[0], "traffic")
    assert_equal(lay.sizes[0], TILE_L)
    assert_true(screens.uis[0].args().find('"big":true') < 0)
    # a passive tile promoted joins the grid, first
    res = screens.tiles('{"op":"promote","id":"bday"}')
    assert_equal(order(screens, 0), "bday,traffic,cal,weather,todo")
    # add (first), set_face, remove
    res = screens.tiles('{"op":"add","first":true,"tile":{"id":"flight","tint":"indigo","icon":"plane","head":"Flight","faces":[{"big":"Gate B12","sub":"boarding 9:05"}]}}')
    assert_true(res.find('"first":"flight"') >= 0)
    assert_equal(order(screens, 0), "flight,bday,traffic,cal,weather,todo")
    res = screens.tiles('{"op":"set_face","id":"flight","face":{"big":"Gate B14","sub":"gate changed"}}')
    assert_true(res.startswith('{"done":true'))
    assert_true(screens.uis[0].args().find("Gate B14") >= 0)
    res = screens.tiles('{"op":"remove","id":"todo"}')
    assert_equal(order(screens, 0), "flight,bday,traffic,cal,weather")
    # refusals the agent can act on
    res = screens.tiles('{"op":"promote","id":"rain"}')
    assert_true(res.find("refused: no tile \\\"rain\\\" on the card (its tiles: flight, bday, traffic, cal, weather, timer)") >= 0)
    assert_true(screens.tiles('{"op":"jump","id":"cal"}').find("unknown op") >= 0)
    assert_true(screens.tiles('{"op":"add","tile":{"id":"cal","head":"x","faces":[{"big":"y"}]}}').find("both have the id") >= 0)
    assert_true(screens.tiles('{"op":"set_face","id":"cal"}').find("set_face needs a face") >= 0)
    assert_true(screens.tiles('{"op":"promote","id":"cal","card":"card7"}').find("no live tiles on the screen called card7") >= 0)
    var log = screens.take_log()
    assert_true(len(log) >= 8)
    assert_true(log[0].startswith("PATCH: card=card1 ok"))

    # the frontend path: a tiles call the agent made is answered by take_tiles (run the agent again)
    call(agent, "c2", TILES, '{"op":"promote","id":"weather"}')
    assert_equal(waiting(agent), 1)
    assert_true(screens.take_tiles(agent))
    assert_equal(waiting(agent), 0)
    assert_true(agent.messages[len(agent.messages) - 1].content.startswith('{"done":true,"card":"card1","order":["weather"'))
    assert_false(screens.take_tiles(agent))

    # 2-6 centre tiles: promoting the last makes it the first, large tile with the grid full
    for n in range(2, 7):
        var s2 = Screens(30_000, 3000)
        var a2 = Agent("", 0, 0, "u")
        a2.offer(Tool("render_ui", "Show UI", schema()))
        a2.offer(tiles_tool())
        call(a2, "r", "render_ui", tiles_card(n))
        _ = s2.take(a2)
        assert_equal(s2.uis[0].problem, "")
        draw(s2, 0)
        var r = s2.tiles('{"op":"promote","id":"t' + String(n - 1) + '"}')
        assert_true(r.startswith('{"done":true'))
        var l2 = s2.uis[0].tiles_at(s2.uis[0].tiles_node()).layout()
        assert_equal(l2.ids[0], "t" + String(n - 1))
        assert_true(l2.sizes[0] == TILE_L or l2.sizes[0] == TILE_XL)
        assert_equal(l2.holes, 0)
        assert_equal(len(l2.ids), n)
        print("tiles", n, ": promoted t" + String(n - 1), "first,", "xl" if l2.sizes[0] == TILE_XL else "l", ", holes", l2.holes)
    # a size the person chose with the grip gives way to the agent's promote: large, the grid full (and the tool says so)
    var s3 = Screens(40_000, 4000)
    var a3 = Agent("", 0, 0, "v")
    a3.offer(Tool("render_ui", "Show UI", schema()))
    a3.offer(tiles_tool())
    call(a3, "r", "render_ui", tiles_card(4))
    _ = s3.take(a3)
    draw(s3, 0)
    var c3 = s3.uis[0].canvas_of.get(s3.uis[0].tiles_node(), 0)
    s3.uis[0].tiles[c3].set_user_size("t3", TILE_S)  # (as the corner grip records it)
    var l3 = s3.uis[0].tiles_at(s3.uis[0].tiles_node()).layout()
    assert_true(l3.holes > 0, "the shrunk tile leaves a hole")
    _ = s3.take_log()
    _ = s3.tiles('{"op":"promote","id":"t3"}')
    l3 = s3.uis[0].tiles_at(s3.uis[0].tiles_node()).layout()
    assert_equal(l3.ids[0], "t3")
    assert_equal(l3.sizes[0], TILE_L)
    assert_equal(l3.holes, 0)
    var said3 = s3.take_log()
    assert_true(said3[len(said3) - 1].find("first=t3 size=l holes=0") >= 0, said3[len(said3) - 1])
    print("resized then promoted: t3 first, l, holes 0")
    print("tiles agent: ok")
