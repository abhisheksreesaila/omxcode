# Agent-driven live tiles (goal 77 M7c): a shown card changes without being sent again. Screens.patch applies a JSON Patch to a
# card's render_ui arguments and validates it again (a bad one leaves the card as it was); a CUSTOM `ui_patch` event does the
# same; the `tiles` tool's ops (promote, add, remove, set_face) become patches, answered with the new order or a refusal that
# says what to fix; a promoted tile becomes the first, large tile with the grid full (0 holes for 2-6 tiles) and glides there.
#   scripts/mxbuild.sh tests/test_tiles_agent.mojo -o build/test_tiles_agent && build/test_tiles_agent
from std.testing import assert_equal, assert_true, assert_false
from mojoui.agui import Agent, Tool
from mojoui.agentui import Screens, tiles_tool, stage_parts
from mojoui.stagetv import StageTV
from mojoui.pointer import Part
from mojoui.tilescard import tile_ids, is_sample, sample_plain
from mojoui.genui import sample, schema
from mojoui.json import Json, json_string
from mojoui.jsonpatch import JDoc
from mojoui.canvas import Surface
from mojoui.livetiles import TILE_S, TILE_L, TILE_XL, Tile, Face
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


def ids_of(screens: Screens, name: String) -> String:
    """The ids on card `name`'s tiles, in the card's order (passive ones too)."""
    var k = screens.card_index(name)
    var out = String("")
    var ids = tile_ids(screens.uis[k].json, screens.uis[k].tiles_node())
    for i in range(len(ids)):
        out += ("," if i > 0 else "") + ids[i]
    return out


def card_of(args: String) -> String:
    """A tiles call's "card" member as JSON text ("-" when it has none)."""
    try:
        var j = Json.parse(args)
        var c = j.get(0, "card")
        return j.dump(c) if c >= 0 else String("-")
    except:
        return String("not json")


def cards_of(parts: List[Part]) -> String:
    var out = String("")
    for p in parts:
        out += ("," if out != "" else "") + p.card + ":" + p.part
    return out


def test_stage_logic() raises:
    """omx's stage logic, lifted into the framework (review of M7f): Screens.aimed (on_stage), agent_tile_ids, keep's samples
    and refused adds, merge_tiles (tiles_to_stage) and stage_parts (known_parts)."""
    var agent = Agent("", 0, 0, "t")
    agent.offer(Tool("render_ui", "Show UI", schema()))
    agent.offer(tiles_tool())
    var s = Screens(50_000, 5000)
    var mine = List[Tile]()
    mine.append(Tile("todo", 0, "To do", "3 to do", "milk"))
    var kinds: List[String] = ["centre"]
    var samples = List[Tile]()
    samples.append(Tile("sample_weather", 0, "Weather", "9°", "sample"))
    samples.append(Tile("sample_cal", 0, "Calendar", "3:15", "sample"))
    var skinds: List[String] = ["passive", "passive"]
    assert_true(is_sample("sample_cal") and not is_sample("cal"))
    assert_equal(sample_plain("sample_weather"), "weather")
    assert_equal(sample_plain("weather"), "weather")
    assert_equal(s.keep("stage", mine, kinds, "", samples, skinds), "")
    assert_equal(ids_of(s, "stage"), "todo,sample_weather,sample_cal")
    assert_equal(len(s.agent_tile_ids("stage")), 0)
    assert_equal(len(s.agent_tile_ids("nowhere")), 0)

    # aimed: no card, an empty one, a non-string one, an agent's LiveTiles card -> the stage; any other card, the stage itself,
    # or not a JSON object -> as it is
    call(agent, "a1", "render_ui", sample("LiveTiles"))
    _ = s.take(agent)
    var agent_card = s.uis[len(s.uis) - 1].card
    _ = s.show("word", sample("WordCard"))
    assert_equal(card_of(s.aimed('{"op":"promote","id":"todo"}', "stage")), '"stage"')
    assert_equal(card_of(s.aimed('{"op":"promote","id":"todo","card":""}', "stage")), '"stage"')
    assert_equal(card_of(s.aimed('{"op":"promote","id":"todo","card":7}', "stage")), '"stage"')
    assert_equal(card_of(s.aimed('{"op":"promote","id":"todo","card":' + json_string(agent_card) + "}", "stage")), '"stage"')
    var unknown = '{"op":"promote","id":"todo","card":"card9"}'
    assert_equal(s.aimed(unknown, "stage"), unknown)
    var not_tiles = '{"op":"promote","id":"todo","card":"word"}'
    assert_equal(s.aimed(not_tiles, "stage"), not_tiles)
    var itself = '{"op":"promote","id":"todo","card":"stage"}'
    assert_equal(s.aimed(itself, "stage"), itself)
    assert_equal(s.aimed("[1,2]", "stage"), "[1,2]")
    assert_equal(s.aimed("not json", "stage"), "not json")
    assert_true(s.tiles('{"op":"promote","id":"todo"}', into="stage").find('"card":"stage"') >= 0)
    assert_true(s.tiles('{"op":"promote","id":"todo","card":"card9"}', into="stage").find("refused") >= 0)
    print("aimed: no card, empty, non-string, the agent's tiles card -> the stage; unknown, other, itself, non-object as they are")

    # keep's samples: an agent's tile "weather" sends sample_weather away; when the agent removes it, the sample comes back
    assert_true(s.tiles('{"op":"add","card":"stage","tile":{"id":"weather","head":"Weather","faces":[{"big":"11°"}]}}').find('"done":true') >= 0)
    assert_equal(s.agent_tile_ids("stage")[0], "weather")
    assert_equal(s.keep("stage", mine, kinds, "", samples, skinds), "")
    assert_equal(ids_of(s, "stage"), "todo,sample_cal,weather")
    assert_true(s.tiles('{"op":"remove","card":"stage","id":"weather"}').find('"done":true') >= 0)
    assert_equal(s.keep("stage", mine, kinds, "", samples, skinds), "")
    assert_equal(ids_of(s, "stage"), "todo,sample_cal,sample_weather")
    assert_equal(s.keep("stage", mine, kinds, "", List[Tile](), skinds), "")  # (samples off: they go)
    assert_equal(ids_of(s, "stage"), "todo")
    print("keep: a sample steps aside for the agent's tile of its name and comes back when that tile goes")

    # a refused add is remembered: not tried (nor reported) again until the tile changes
    var bad = Tile("bad", 0, "Bad", "x", "y")
    bad.faces.clear()  # (no face: the card refuses it)
    mine.append(bad.copy())
    kinds.append("centre")
    var first = s.keep("stage", mine, kinds)
    assert_true(first != "", "the first refusal is reported")
    assert_equal(len(s.kept_failed), 1)
    var before = len(s.take_log())
    assert_equal(s.keep("stage", mine, kinds), "", "not tried again")
    assert_equal(s.keep("stage", mine, kinds), "")
    assert_equal(len(s.take_log()), 0, "nothing more logged")
    _ = before
    mine[1].faces.append(Face("fixed", ""))
    assert_equal(s.keep("stage", mine, kinds), "", "changed: tried again, and taken")
    assert_equal(len(s.kept_failed), 0)
    assert_equal(ids_of(s, "stage"), "todo,bad")
    _ = mine.pop(1)
    _ = kinds.pop(1)
    assert_equal(s.keep("stage", mine, kinds), "")
    print("keep: a refused add is tried once per version of the tile")

    # merge_tiles: the agent's LiveTiles card joins the stage (todo takes the new face, the rest are added, its first leads)
    var ak = s.card_index(agent_card)
    var sent = s.merge_tiles(ak, "stage")
    assert_true(sent >= 4)
    var on = ids_of(s, "stage")
    assert_true(on.startswith("traffic,"), on)
    assert_true(on.find("todo") >= 0 and on.find("weather") >= 0 and on.find("cal") >= 0, on)
    assert_equal(s.merge_tiles(ak, "nowhere"), 0)
    assert_equal(s.merge_tiles(s.card_index("word"), "stage"), 0)
    assert_equal(s.merge_tiles(s.card_index("stage"), "stage"), 0)
    print("merge_tiles: " + on)

    # stage_parts: only this turn's card in the TV (shown or swapping in), the camera's own boxes for the TV's card, the tiles
    # only while the TV doesn't hide them
    _ = s.show("word2", sample("WordCard"))
    var since = s.card_index("word2")
    var tile_parts = List[Part]()
    tile_parts.append(Part("stage", "todo", ["to do"]))
    tile_parts[0].inside = "stage.tiles"  # (as livetiles' parts(card, inside) makes them: drawn inside the tiles' canvas)
    var cam = List[Part]()
    cam.append(Part("look3", "cup", ["cup"]))
    cam.append(Part("look2", "dog", ["dog"]))
    var tv = StageTV(1, 2)
    tv.area_w = 700
    tv.area_h = 740
    assert_equal(cards_of(stage_parts(s, tv, since, cam, tile_parts, "stage.tiles")), "stage:todo", "closed: the tiles only")
    tv.open(0, "w", "word")
    _ = tv.tick(1_000_000)
    assert_equal(len(stage_parts(s, tv, since, cam, tile_parts, "stage.tiles")), 0, "an earlier turn's card: nothing (and the tiles hidden)")
    assert_true(len(stage_parts(s, tv, s.card_index("word"), cam, tile_parts, "stage.tiles")) >= 3, "this turn's: its parts")
    tv.open(2_000_000, "w2", "word2")  # (swapping: word leaves, word2 comes)
    _ = tv.tick(2_100_000)
    var swapping = cards_of(stage_parts(s, tv, s.card_index("word"), cam, tile_parts, "stage.tiles"))
    assert_true(swapping.find("word2:") >= 0 and swapping.find("word:") < 0, swapping)
    tv.open(3_000_000, "cam", "look3")
    _ = tv.tick(3_400_000)
    assert_equal(cards_of(stage_parts(s, tv, since, cam, tile_parts, "stage.tiles")), "look3:cup", "the camera card's own boxes")
    tv.open(4_000_000, "tiles", "stage")
    _ = tv.tick(4_400_000)
    assert_equal(len(stage_parts(s, tv, 0, cam, tile_parts, "stage.tiles")), 0, "a tiles card in the TV: not its parts")
    print("stage_parts: closed -> tiles; earlier turn -> none; swap -> the incoming card; camera -> its boxes")


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
    # an app's own tiles card (goal 77 M7f): Screens.keep makes it, keeps it in step, and leaves the agent's changes standing
    var s4 = Screens(20_000, 2000)
    var mine = List[Tile]()
    mine.append(Tile("todo", 0, "To do", "3 to do", "milk · mum"))
    mine.append(Tile("cal", 0, "Calendar", "Pickup 3:15", "sample"))
    mine.append(Tile("news", 0, "News", "SpaceX", "6 headlines"))
    var kinds: List[String] = ["centre", "passive", "centre"]
    assert_equal(s4.keep("stage", mine, kinds), "")
    assert_equal(s4.uis[0].card, "stage")
    draw(s4, 0)
    assert_equal(order(s4, 0), "todo,news")  # (the passive calendar sits beside the grid)
    assert_true(s4.tiles('{"op":"promote","id":"news","card":"stage"}').find('"first":"news"') >= 0)
    assert_true(s4.tiles('{"op":"add","card":"stage","tile":{"id":"weather","head":"Weather","faces":[{"big":"9°"}]}}').find('"done":true') >= 0)
    mine[0].faces[0] = Face("2 to do", "mum")
    _ = mine.pop(2)  # (the app's news went)
    var job = Tile("job", 0, "Thinking", "Graphics cards", "0:12")
    mine.append(job^)
    kinds = ["centre", "passive", "centre"]
    assert_equal(s4.keep("stage", mine, kinds), "")
    draw(s4, 0)
    assert_equal(order(s4, 0), "todo,weather,job")  # (news gone, the agent's weather kept, the job added after it)
    var lt = s4.uis[0].tiles_at(s4.uis[0].tiles_node())
    assert_equal(lt.tiles[0].faces[0].big, "2 to do")
    assert_equal(s4.keep("stage", mine, kinds, lead="job"), "")
    draw(s4, 0)
    assert_equal(order(s4, 0), "job,todo,weather")  # (the app's lead, once)
    _ = s4.tiles('{"op":"promote","id":"weather","card":"stage"}')
    assert_equal(s4.keep("stage", mine, kinds, lead="job"), "")
    draw(s4, 0)
    assert_equal(order(s4, 0), "weather,job,todo")  # (the agent's later promote stands: the lead moves only when it changes)
    assert_true(s4.show("stage", '{"ui":{"component":"LiveTiles","tiles":[{"id":"x","head":"X","faces":[]}]}}') != "")  # (refused: no face)
    assert_equal(len(s4.uis), 1)
    print("app card: keep adds, changes, removes its own tiles; the agent's add and promote stand; lead once")
    test_stage_logic()
    print("tiles agent: ok")
