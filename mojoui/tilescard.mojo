# mojoui.tilescard: live tiles as data an agent sends (goal 77 M7c, D-7800…). genui's `LiveTiles` component is a list of tiles
# in importance order, drawn by mojoui.livetiles on one Canvas; this file reads them out of the JSON, holds the rules a JSON
# Schema can't say, and turns the `tiles` agent tool's small operations into a JSON Patch on the card (mojoui.agentui applies it,
# validates the result again, and the tiles glide to their new places).
#
#   {"component":"LiveTiles","tiles":[
#      {"id":"traffic","kind":"centre","tint":"green","icon":"car","head":"Traffic","faces":[{"big":"Leave by 8:05","sub":"Bridge is slow"}],
#       "why":"you leave in 20 minutes","actions":["Directions"],"big":false,"charm":"pin"}, …]}
#
#   kind: centre (the grid: what matters now), passive (the quiet left column: weather, birthdays), live (the right column:
#   timers, scores). A card on its own draws the centre tiles on the grid and names the others in a quiet line under it; the
#   Stage (M7e/M7f) routes them to its columns. The first centre tile is the large one (or the one with big: true, extra large).
#
#   tiles_problem(j, n)              why a LiveTiles node can't be shown ("" when it can): ids unique and one lower-case word,
#                                    at least one centre tile
#   centre_tiles(j, n) / side_tiles(j, n, kind) -> List[Tile]     mojoui.livetiles tiles, in order
#   TILES, TILES_ABOUT, TILES_PARAMS the agent tool (mojoui.agentui.tiles_tool(): an AG-UI frontend tool; LlmAgent.add_deferred
#                                    takes the three)
#   tiles_patch(j, n, at, args)      its arguments as a JSON Patch on the card's render_ui arguments (`at`: the node's pointer);
#                                    raises with a message the agent can act on
#   tile_json(tile, kind)            a mojoui.livetiles Tile as one of the card's tiles (an app building its own tiles card:
#                                    Screens.keep)

from mojoui.json import Json, json_string, J_STRING, J_OBJECT, J_ARRAY, J_BOOL
from mojoui.livetiles import Tile, Face, TAPPED, ACTION, REORDERED, RESIZED, tint_names

comptime TILES = "tiles"
comptime KIND_CENTRE = "centre"
comptime KIND_PASSIVE = "passive"
comptime KIND_LIVE = "live"


def is_tile_id(s: String) -> Bool:
    """A tile's id: one lower-case word (a letter, then letters, digits or _; at most 40), so it is also the pointer part's name."""
    var n = s.byte_length()
    if n < 1 or n > 40:
        return False
    var b = s.as_bytes()
    if b[0] < 97 or b[0] > 122:
        return False
    for c in b:
        if not ((c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95):
            return False
    return True


comptime SAMPLE_PREFIX = "sample_"  # an app's stand-in tile for a source it doesn't have yet: "sample_weather" (never an agent's id)


def is_sample(id: String) -> Bool:
    """A sample tile's id (SAMPLE_PREFIX): Screens.keep lets it step aside for an agent's tile of its plain name."""
    return id.startswith(SAMPLE_PREFIX)


def sample_plain(id: String) -> String:
    """"sample_weather" → "weather" (the agent's tile that takes its place); any other id as it is."""
    return String(id[byte = SAMPLE_PREFIX.byte_length():]) if is_sample(id) else id


def kind_of(j: Json, t: Int) -> String:
    var k = j.get(t, "kind")
    return j.text(k) if k >= 0 and j.kind(k) == J_STRING else String(KIND_CENTRE)


def tiles_problem(j: Json, n: Int) -> String:
    """The rules beyond the schema (which already checks 1-12 tiles, each with an id, a head and at least one face, the kinds
    and tints): ids are unique lower-case words, and at least one tile is on the grid (kind centre)."""
    var ts = j.get(n, "tiles")
    var ids = List[String]()
    var centre = 0
    for i in range(j.size(ts)):
        var t = j.at(ts, i)
        var id = j.text(j.get(t, "id"))
        if not is_tile_id(id):
            return "LiveTiles' tiles[" + String(i) + "].id " + json_string(id) + " must be one lower-case word (letters, digits, _), e.g. \"weather\""
        for k in range(len(ids)):
            if ids[k] == id:
                return "LiveTiles' tiles[" + String(k) + "] and tiles[" + String(i) + "] both have the id " + json_string(id) + ": give each tile its own id"
        ids.append(id)
        if kind_of(j, t) == KIND_CENTRE:
            centre += 1
    if centre == 0:
        return "LiveTiles needs at least one tile of kind \"centre\" (the grid; passive and live tiles sit beside it)"
    return ""


def tile_of(j: Json, t: Int) -> Tile:
    var faces = j.get(t, "faces")
    var f0 = j.at(faces, 0)
    var tile = Tile(j.text(j.get(t, "id")), 0, j.text(j.get(t, "head")), j.text(j.get(f0, "big")), j.text(j.get(f0, "sub")),
                    icon=j.text(j.get(t, "icon")))
    var tint = j.text(j.get(t, "tint"))
    tile.tint = tint if tint != "" else String("slate")  # (the palette says what each tint looks like: mojoui.livetiles.tint_colour)
    for i in range(1, j.size(faces)):
        var f = j.at(faces, i)
        tile.faces.append(Face(j.text(j.get(f, "big")), j.text(j.get(f, "sub"))))
    tile.why = j.text(j.get(t, "why"))
    var acts = j.get(t, "actions")
    for i in range(j.size(acts)):
        tile.actions.append(j.text(j.at(acts, i)))
    tile.big = j.flag(j.get(t, "big"))
    tile.charm = j.text(j.get(t, "charm"))
    return tile^


def centre_tiles(j: Json, n: Int) -> List[Tile]:
    """The grid's tiles (kind centre), most important first."""
    return side_tiles(j, n, KIND_CENTRE)


def side_tiles(j: Json, n: Int, kind: String) -> List[Tile]:
    var out = List[Tile]()
    var ts = j.get(n, "tiles")
    for i in range(j.size(ts)):
        var t = j.at(ts, i)
        if kind_of(j, t) == kind:
            out.append(tile_of(j, t))
    return out^


def tile_ids(j: Json, n: Int) -> List[String]:
    var out = List[String]()
    var ts = j.get(n, "tiles")
    for i in range(j.size(ts)):
        out.append(j.text(j.get(j.at(ts, i), "id")))
    return out^


# ---------------------------------------------------------------------------------------------------------------------
# the agent tool
# ---------------------------------------------------------------------------------------------------------------------

comptime TILES_ABOUT = (
    "Change the live tiles already on the screen without sending them all again (show them first with render_ui's LiveTiles). "
    "op promote: move tile `id` first, so it becomes the large tile (big=true: extra large); op add: a new `tile` (first=true puts "
    "it first, else last); op remove: take tile `id` away; op set_face: tile `id` now shows `face` ({big, sub}). Use the tiles' own ids. "
    "The result says the new order; a refusal says why and lists the ids."
)
comptime TILES_PARAMS = (
    '{"type":"object","properties":{'
    '"op":{"type":"string","enum":["promote","add","remove","set_face"]},'
    '"id":{"type":"string","description":"the tile to change (promote, remove, set_face)"},'
    '"big":{"type":"boolean","description":"promote: make it the extra-large tile"},'
    '"first":{"type":"boolean","description":"add: put the new tile first"},'
    '"tile":{"type":"object","description":"add: {id, head, faces: [{big, sub}], kind, tint, icon, why, actions}"},'
    '"face":{"type":"object","properties":{"big":{"type":"string"},"sub":{"type":"string"}},"required":["big"],"description":"set_face: what the tile shows now"},'
    '"card":{"type":"string","description":"which card (card2); leave out for the newest live tiles"}},'
    '"required":["op"]}'
)


def _ids_text(ids: List[String]) -> String:
    var out = String("")
    for i in range(len(ids)):
        out += (", " if i > 0 else "") + ids[i]
    return out


def tiles_patch(j: Json, n: Int, at: String, args: String) raises -> String:
    """The `tiles` call's arguments as a JSON Patch (RFC 6902) on the card's render_ui arguments, the LiveTiles node `n` of `j`
    being at pointer `at` ("/ui/children/0"). Raises with what to fix (an unknown op or id, a missing tile or face)."""
    var a: Json
    try:
        a = Json.parse(args)
    except:
        raise Error("the arguments are not JSON: send {\"op\": \"promote\", \"id\": \"weather\"}")
    if a.kind(0) != J_OBJECT:
        raise Error("the arguments must be an object: {\"op\": \"promote\", \"id\": \"weather\"}")
    var op = a.text(a.get(0, "op"))
    var ids = tile_ids(j, n)
    var ts = j.get(n, "tiles")
    var base = at + "/tiles/"
    if op == "add":
        var t = a.get(0, "tile")
        if t < 0 or a.kind(t) != J_OBJECT:
            raise Error("add needs a tile: {\"op\": \"add\", \"tile\": {\"id\": \"timer\", \"head\": \"Timer\", \"faces\": [{\"big\": \"4:00\"}]}}")
        var first = a.get(0, "first") >= 0 and a.flag(a.get(0, "first"))
        return '[{"op":"add","path":' + json_string(base + ("0" if first else "-")) + ',"value":' + a.dump(t) + "}]"
    if op != "promote" and op != "remove" and op != "set_face":
        raise Error("unknown op " + json_string(op) + ": use promote, add, remove or set_face")
    var id = a.text(a.get(0, "id"))
    var i = -1
    for k in range(len(ids)):
        if ids[k] == id:
            i = k
    if i < 0:
        raise Error("no tile " + json_string(id) + " on the card (its tiles: " + _ids_text(ids) + ")")
    if op == "remove":
        return '[{"op":"remove","path":' + json_string(base + String(i)) + "}]"
    if op == "set_face":
        var f = a.get(0, "face")
        if f < 0 or a.kind(f) != J_OBJECT:
            raise Error("set_face needs a face: {\"op\": \"set_face\", \"id\": \"" + id + "\", \"face\": {\"big\": \"…\", \"sub\": \"…\"}}")
        return '[{"op":"replace","path":' + json_string(base + String(i) + "/faces/0") + ',"value":' + a.dump(f) + "}]"
    # promote: first, on the grid, and no other tile asking to be extra large (it would lead instead)
    var ops = List[String]()
    if i != 0:
        ops.append('{"op":"move","from":' + json_string(base + String(i)) + ',"path":' + json_string(base + "0") + "}")
    if kind_of(j, j.at(ts, i)) != KIND_CENTRE:
        ops.append('{"op":"add","path":' + json_string(base + "0/kind") + ',"value":"centre"}')
    for k in range(len(ids)):
        if k != i and j.flag(j.get(j.at(ts, k), "big")):
            var now = k + 1 if k < i else k
            ops.append('{"op":"add","path":' + json_string(base + String(now) + "/big") + ',"value":false}')
    var bg = a.get(0, "big")
    if bg >= 0 and a.kind(bg) == J_BOOL:
        ops.append('{"op":"add","path":' + json_string(base + "0/big") + ',"value":' + ("true" if a.flag(bg) else "false") + "}")
    var out = String("[")
    for k in range(len(ops)):
        out += ("," if k > 0 else "") + ops[k]
    return out + "]"


def result_word(kind: Int) -> String:
    """A mojoui.livetiles result (TileResult.kind) as the word the agent hears in {"did": …}."""
    if kind == TAPPED:
        return "tapped"
    if kind == ACTION:
        return "action"
    if kind == REORDERED:
        return "reordered"
    if kind == RESIZED:
        return "resized"
    return "other"


def tile_json(t: Tile, kind: String = KIND_CENTRE) -> String:
    """`t` as one of a LiveTiles card's tiles (JSON), `kind` centre, passive or live: what an app sends when it builds a tiles
    card of its own (mojoui.agentui.Screens.keep). Empty fields are left out; a tint must be one of tint_names()."""
    var out = '{"id":' + json_string(t.id) + ',"kind":' + json_string(kind) + ',"head":' + json_string(t.head)
    if t.tint != "":
        out += ',"tint":' + json_string(t.tint)
    if t.icon != "":
        out += ',"icon":' + json_string(t.icon)
    out += ',"faces":['
    for i in range(min(len(t.faces), 4)):
        out += ("," if i > 0 else "") + '{"big":' + json_string(t.faces[i].big) + ',"sub":' + json_string(t.faces[i].sub) + "}"
    out += "]"
    if t.why != "":
        out += ',"why":' + json_string(t.why)
    if len(t.actions) > 0:
        out += ',"actions":['
        for i in range(min(len(t.actions), 2)):
            out += ("," if i > 0 else "") + json_string(t.actions[i])
        out += "]"
    if t.big:
        out += ',"big":true'
    if t.charm != "":
        out += ',"charm":' + json_string(t.charm)
    return out + "}"
