# mojoui.agentui: an agent's screens in an app (goal 35, D-721): the bookkeeping between mojoui.agui (the conversation)
# and mojoui.genui (UI from data), so a chat app only composes them.
#
#   var screens = Screens(UI_BASE, CANVAS_BASE)            # messages UI_BASE … + max × 1000; canvases from CANVAS_BASE
#   update(): if agent.handle(e) == EV_TOOL_END and screens.take(agent): agent.run(http)   (a refusal: the agent retries)
#             if screens.owns(e.message) and screens.handle(e, agent): agent.run(http)     (an action: the agent hears it)
#   view():   for k in screens.of_message(m.id): screens.view(k, agent.state, version)
#   draw():   screens.draw(canvas, surface, palette, agent.state)
#
# Each render_ui call is shown (a GenUi) or refused (the agent is told why in a tool result: {"error": "refused: …"});
# past `max` screens every call is refused. The first action in a screen is its call's tool result; later ones a user
# message. Calls the app didn't offer are left alone. After MAX_RETRIES refusals in a row take() stops asking for reruns
# (gave_up); a screen shown, or reset() (the user's next message), starts the count again.
#
# A shown screen changes without being sent again (goal 77 M7c, D-7803): patch(k, json_patch) applies RFC 6902 to the card's
# render_ui arguments ({"ui": …}), validates the result with the same catalog and swaps it in, keeping what the card itself
# holds (its live tiles' motion: they glide to their new places); a refused patch leaves the card as it was. It arrives as
#   - a CUSTOM event `ui_patch` {"card": "card2", "patch": [...]} from any AG-UI agent: custom(agent) after EV_CUSTOM;
#   - the `tiles` tool (tiles_tool(): promote, add, remove, set_face), answered by the app because only it knows what is on
#     screen: take_tiles(agent) for an AG-UI client (a frontend tool, like render_ui with take()), or tiles(args) for an
#     in-process LlmAgent (add_deferred(TILES, TILES_ABOUT, TILES_PARAMS); answer its take_calls()).
# What the person does to the tiles (tapped, an action, reordered, resized) comes back like any screen action (handle()).
#
# An app's own cards (goal 77 M7f): show(name, json) shows render_ui's arguments the app built itself under a name ("stage"),
# or swaps them in for the card of that name; keep(name, tiles, kinds, lead) keeps the app's own live tiles on such a card in step
# with what it knows (adds, changes, removes its tiles) while the agent's tiles, order and promotes on the same card stay: the
# tiles tool and ui_patch work on it like on any card.

from mojoui.agui import Agent, Tool
from mojoui.tilescard import TILES, TILES_ABOUT, TILES_PARAMS, tiles_patch, tile_json, tile_ids
from mojoui.livetiles import size_name, Tile
from mojoui.json import Json, J_OBJECT
from mojoui.tripmap import SHOW_MAP, trip_ui
from mojoui.explain import EXPLAIN
from mojoui.iso import explain_ui
from mojoui.genui import GenUi, ACT_ACTION, MAX_CONTROLS, MAX_NODES, partial_ui, LOADING_UI
from mojoui.datahub import Hub, NoData
from mojoui.album import Album
from mojoui.jsonpatch import JDoc
from mojoui.pointer import Part
from mojoui.json import json_string
from mojoui.view import View, Text, Card, CAPTION, SPACE_XS, CARD_WARN
from mojoui.canvas import Surface
from mojoui.theme import Palette
from mojoui.app import Event
from mojoui.text import Font

comptime MAX_SCREENS = 40


def tool_card(name: String, args: String) -> String:
    """A card tool's call (an agent tool that shows one card from its arguments: show_map's map, explain's isometric diagram) as
    render_ui's JSON; "" when `name` isn't one or its arguments can't be read. adopt() shows these beside render_ui's own screens
    (goal 77 M3, M4; D-7735), so an app needs no code per card tool."""
    if name == SHOW_MAP:
        return trip_ui(args)
    if name == EXPLAIN:
        return explain_ui(args)
    return ""


comptime UI_PATCH = "ui_patch"  # the CUSTOM event that patches a shown card: {"card": "card2", "patch": [JSON Patch on its {"ui": …}]}


def tiles_tool() -> Tool:
    """The `tiles` agent tool (mojoui.tilescard): change the live tiles on screen without sending them all again."""
    return Tool(TILES, TILES_ABOUT, TILES_PARAMS)


def _refused(why: String) -> String:
    return '{"error":' + json_string("refused: " + why) + "}"


def _as_is(args: String) -> String:
    return args

comptime MAX_RETRIES = 3  # reruns after refused UI in a row; then take() stops asking and gave_up says so (D-725)


struct Screens[H: Hub = NoData](Movable):
    var uis: List[GenUi[Self.H]]
    var calls: List[String]  # screen k answers tool call calls[k]
    var messages: List[String]  # … and belongs to the message messages[k]
    var base: Int
    var canvas_base: Int
    var max: Int
    var streak: Int  # refusals in a row
    var gave_up: Bool  # past MAX_RETRIES: no more reruns until reset()
    var live: List[Bool]  # screen k is a preview of a call still streaming (goal 48 M1): replaced when it ends
    var sizes: List[Int]  # the argument bytes screen k was last built from (a preview rebuilds when more arrive)
    var font: Font  # one for every screen's canvases (a Font costs ~1 ms to make)
    var hub: Self.H  # the app's datasets, for screens that name one (goal 48 M5: mojoui.datahub)
    var album: Album  # the app's pictures, for screens that name one (mojoui.album)
    var refused: List[String]  # calls adopt() saw refused by an in-process agent (it told its model; nothing is shown)
    var said: List[String]  # what patches and the tiles tool did, for take_log() ("TILES: card=card1 op=promote …")
    var kept_ids: List[String]  # keep(): the app's own tiles on its card, as last sent …
    var kept: List[String]  # … and their JSON
    var kept_lead: String

    def __init__(out self, base: Int, canvas_base: Int, max: Int = MAX_SCREENS):
        self.uis = List[GenUi[Self.H]]()
        self.calls = List[String]()
        self.messages = List[String]()
        self.base = base
        self.canvas_base = canvas_base
        self.max = max
        self.streak = 0
        self.gave_up = False
        self.live = List[Bool]()
        self.sizes = List[Int]()
        self.hub = Self.H()
        self.album = Album()
        self.font = Font()
        self.refused = List[String]()
        self.said = List[String]()
        self.kept_ids = List[String]()
        self.kept = List[String]()
        self.kept_lead = String("")

    def reset(mut self):
        """The user spoke: refusals count from zero again."""
        self.streak = 0
        self.gave_up = False

    def known(self, call_id: String) -> Bool:
        """The call has a screen (shown, refused, or a preview while it streams)."""
        for c in self.calls:
            if c == call_id:
                return True
        return False

    def index_of(self, call_id: String) -> Int:
        for k in range(len(self.calls)):
            if self.calls[k] == call_id:
                return k
        return -1

    def streaming(self, k: Int) -> Bool:
        return self.live[k]

    def worth_redrawing(self, args: String, built: Int) -> Bool:
        """A preview is rebuilt when a component (or a value) finished since it was built, or 64 more bytes came: a
        model's two-byte deltas don't each pay for a parse (the screen looks the same between them)."""
        var n = args.byte_length()
        if n == built:
            return False
        if n - built >= 64:
            return True
        var b = args.as_bytes()
        for i in range(built, n):
            if b[i] == 125 or b[i] == 93:  # } ]
                return True
        return False

    def preview_of(self, args: String, k: Int) -> GenUi[Self.H]:
        """What has arrived of a screen, drawable (a dataset name still being written: the loading card)."""
        var ui = GenUi[Self.H](partial_ui(args), self.base + k * MAX_CONTROLS, self.canvas_base + k * MAX_NODES, self.hub, self.album)
        if ui.problem != "":
            return GenUi[Self.H](LOADING_UI, self.base + k * MAX_CONTROLS, self.canvas_base + k * MAX_NODES, self.hub, self.album)
        return ui^

    def preview(mut self, agent: Agent, tool: String = "render_ui") -> Bool:
        """`tool` calls still streaming get a screen of what's arrived so far (mojoui.genui.partial_ui: closed, pruned,
        a Skeleton where more is coming), rebuilt as their arguments grow. True when one changed (redraw)."""
        var changed = False
        for ref m in agent.messages:
            for ref c in m.calls:
                if c.name != tool or c.done or c.too_big:
                    continue
                var k = self.index_of(c.id)
                if k >= 0 and (not self.live[k] or not self.worth_redrawing(c.arguments, self.sizes[k])):
                    continue
                if k < 0:
                    if len(self.uis) >= self.max:
                        continue
                    k = len(self.uis)
                    var shown = self.preview_of(c.arguments, k)
                    shown.card = "card" + String(k + 1)
                    self.uis.append(shown^)
                    self.calls.append(c.id)
                    self.messages.append(m.id)
                    self.live.append(True)
                    self.sizes.append(c.arguments.byte_length())
                else:
                    var shown = self.preview_of(c.arguments, k)
                    shown.card = "card" + String(k + 1)
                    self.uis[k] = shown^
                    self.sizes[k] = c.arguments.byte_length()
                changed = True
        return changed

    def unfinished(mut self, agent: Agent):
        """The run ended (finished, stopped or failed): a preview whose call never finished says so instead of loading
        forever, and answers nothing."""
        for k in range(len(self.uis)):
            if not self.live[k]:
                continue
            var done = False
            for ref m in agent.messages:
                for ref c in m.calls:
                    if c.id == self.calls[k] and c.done:
                        done = True
            if not done:
                self.uis[k] = GenUi[Self.H]('{"ui":{"component":"Script"}}', self.base + k * MAX_CONTROLS, self.canvas_base + k * MAX_NODES, self.hub, self.album)
                self.uis[k].problem = "the agent stopped before this screen was finished"
                self.live[k] = False

    def take(mut self, mut agent: Agent, tool: String = "render_ui") -> Bool:
        """Every finished `tool` call not yet seen: shown, or refused with a message to the agent. True when one was
        refused and the agent should run again to hear why (at most MAX_RETRIES times in a row: then gave_up)."""
        var refused = False
        for c in agent.pending():
            var was = self.index_of(c.id)
            if c.name != tool or (was >= 0 and not self.live[was]):
                continue
            var problem = String("")
            if c.too_big:
                problem = "too big: the arguments are larger than the client keeps"
            elif was < 0 and len(self.uis) >= self.max:
                problem = "too big: the chat holds " + String(self.max) + " screens at most"
            if problem != "":
                agent.answer(c.id, '{"error":' + json_string("refused: " + problem) + "}")
                refused = True
                if was >= 0:  # (its preview goes: a refusal card in its place)
                    self.uis[was] = GenUi[Self.H]('{"ui":{"component":"Script"}}', self.base + was * MAX_CONTROLS, self.canvas_base + was * MAX_NODES)
                    self.uis[was].problem = problem
                    self.live[was] = False
                continue
            var k = was if was >= 0 else len(self.uis)
            var ui = GenUi[Self.H](c.arguments, self.base + k * MAX_CONTROLS, self.canvas_base + k * MAX_NODES, self.hub, self.album)
            if ui.problem != "":
                agent.answer(c.id, '{"error":' + json_string("refused: " + ui.problem) + "}")
                refused = True
            else:
                self.streak = 0
            ui.card = "card" + String(k + 1)
            if was >= 0:  # the preview becomes the screen
                self.uis[k] = ui^
                self.live[k] = False
                self.sizes[k] = c.arguments.byte_length()
            else:
                self.uis.append(ui^)
                self.calls.append(c.id)
                self.messages.append(agent.last_message)
                self.live.append(False)
                self.sizes.append(c.arguments.byte_length())
        if not refused:
            return False
        self.streak += 1
        if self.streak > MAX_RETRIES:
            self.gave_up = True
            return False
        return True

    def adopt(mut self, agent: Agent, tool: String = "render_ui") -> Int:
        """For an agent that runs `tool` itself (mojoui.llmagent.LlmAgent validates render_ui and answers it in the run):
        a screen for every finished call that was answered and not refused, once each, oldest first. Returns how many
        were added (redraw when it isn't 0). take() is for agents whose client answers the call."""
        return self.adopt_with(agent, tool, _as_is)

    def adopt_with(mut self, agent: Agent, tool: String, card: def(String) thin -> String) -> Int:
        """adopt() for an app's own card tool whose arguments aren't render_ui's: `card` turns them into render_ui's ({"ui": …}).
        The framework's card tools (show_map, explain) need neither: tool_card() turns theirs."""
        var added = 0
        for ref m in agent.messages:
            for ref c in m.calls:
                var made = tool_card(c.name, c.arguments) if c.name != tool and c.done else String("")  # (a card tool: show_map's map, explain's diagram)
                if (c.name != tool and made == "") or not c.done or self.index_of(c.id) >= 0 or self.was_refused(c.id):
                    continue
                var answer = String("")
                for ref r in agent.messages:
                    if r.role == "tool" and r.tool_call_id == c.id:
                        answer = r.content
                if answer == "":
                    continue  # (its result hasn't come yet)
                if answer.startswith('{"error"') or len(self.uis) >= self.max:
                    self.refused.append(c.id)
                    continue
                var k = len(self.uis)
                var ui = GenUi[Self.H](made if made != "" else card(c.arguments), self.base + k * MAX_CONTROLS, self.canvas_base + k * MAX_NODES, self.hub, self.album)
                if ui.problem != "":
                    self.refused.append(c.id)
                    continue
                ui.card = "card" + String(k + 1)
                self.uis.append(ui^)
                self.calls.append(c.id)
                self.messages.append(m.id)
                self.live.append(False)
                self.sizes.append(c.arguments.byte_length())
                added += 1
        return added

    def show(mut self, name: String, ui_json: String) -> String:
        """An app's own card: render_ui's arguments ({"ui": …}) built by the app, shown as screen `name` (a word that isn't
        cardN, so the agent's cards keep their names), or swapped in for the card of that name keeping what it holds (its tiles
        glide: GenUi.carry). It answers no tool call; its parts' tags start with `name`. "" when shown, else why not."""
        var k = self.card_index(name)
        if k < 0:
            if len(self.uis) >= self.max:
                return "there are already " + String(self.max) + " screens"
            k = len(self.uis)
        var made = GenUi[Self.H](ui_json, self.base + k * MAX_CONTROLS, self.canvas_base + k * MAX_NODES, self.hub, self.album)
        if made.problem != "":
            return made.problem
        if k < len(self.uis):
            made.carry(self.uis[k])
            self.uis[k] = made^
            self.sizes[k] = ui_json.byte_length()
            return ""
        made.card = name
        self.uis.append(made^)
        self.calls.append("app:" + name)
        self.messages.append("")
        self.live.append(False)
        self.sizes.append(ui_json.byte_length())
        return ""

    def keep(mut self, name: String, tiles: List[Tile], kinds: List[String], lead: String = "") -> String:
        """The app's own live tiles (`kinds[i]`: centre, passive or live) on its card `name`, made on the first call (a LiveTiles
        screen of them), then kept in step: a tile the app has and the card hasn't is added after the others, one that changed is
        replaced where it stands, one the app had and no longer has is removed. The agent's tiles on the card, its order and its
        promotes stay. `lead`: a tile the app wants first now (a job that has just finished); moved there once each time it
        changes, so a later promote by the agent still wins. "" when done, else the first refusal."""
        var made = List[String]()
        for i in range(len(tiles)):
            made.append(tile_json(tiles[i], kinds[i] if i < len(kinds) else String("centre")))
        var k = self.card_index(name)
        if k < 0:
            var body = String('{"ui":{"component":"LiveTiles","tiles":[')
            for i in range(len(made)):
                body += ("," if i > 0 else "") + made[i]
            var why = self.show(name, body + "]}}")
            if why == "":
                self.kept_ids = List[String]()
                self.kept = List[String]()
                for i in range(len(tiles)):
                    self.kept_ids.append(tiles[i].id)
                    self.kept.append(made[i])
                self.kept_lead = lead
            return why
        var first_why = String("")
        # gone: the app's tiles it no longer has
        var j = len(self.kept_ids) - 1
        while j >= 0:
            var still = False
            for t in tiles:
                if t.id == self.kept_ids[j]:
                    still = True
            if not still:
                var gone = self.kept_ids[j]
                var why = self._tile_op(k, gone, "remove", "")
                if why != "" and first_why == "":
                    first_why = why
                _ = self.kept_ids.pop(j)
                _ = self.kept.pop(j)
            j -= 1
        # new or changed
        for i in range(len(tiles)):
            var at = -1
            for q in range(len(self.kept_ids)):
                if self.kept_ids[q] == tiles[i].id:
                    at = q
            if at >= 0 and self.kept[at] == made[i]:
                continue
            var why = self._tile_op(k, tiles[i].id, "replace" if at >= 0 else "add", made[i])
            if why != "" and first_why == "":
                first_why = why
            if why == "" or at >= 0:
                if at >= 0:
                    self.kept[at] = made[i]
                else:
                    self.kept_ids.append(tiles[i].id)
                    self.kept.append(made[i])
        if lead != self.kept_lead:
            self.kept_lead = lead
            if lead != "":
                var first = lead
                var why = self._tile_op(k, first, "lead", "")
                if why != "" and first_why == "":
                    first_why = why
        return first_why

    def _tile_op(mut self, k: Int, id: String, op: String, tile: String) -> String:
        """One change to card k's tiles as a JSON Patch: "remove" (nothing to do when it isn't there), "lead" (moved first;
        nothing to do when it isn't there or is first already), and otherwise `tile` (its JSON) replaced where the id stands, or
        added last when the card has no such id (whatever `op` says: an app tile the agent removed comes back when it changes).
        "" when applied, else the patch's refusal."""
        var n = self.uis[k].tiles_node()
        if n < 0:
            return "no live tiles on " + self.uis[k].card
        var base = self.uis[k].pointer_to(n) + "/tiles/"
        var ids = tile_ids(self.uis[k].json, n)
        var i = -1
        for q in range(len(ids)):
            if ids[q] == id:
                i = q
        var ops: String
        if op == "remove" or op == "lead":
            if i < 0 or (op == "lead" and i == 0):
                return ""
            ops = ('[{"op":"remove","path":' + json_string(base + String(i)) + "}]" if op == "remove"
                   else '[{"op":"move","from":' + json_string(base + String(i)) + ',"path":' + json_string(base + "0") + "}]")
        elif i >= 0:
            ops = '[{"op":"replace","path":' + json_string(base + String(i)) + ',"value":' + tile + "}]"
        else:
            ops = '[{"op":"add","path":' + json_string(base + "-") + ',"value":' + tile + "}]"
        return self.patch(k, ops)

    def was_refused(self, call_id: String) -> Bool:
        for r in self.refused:
            if r == call_id:
                return True
        return False

    def owns(self, message: Int) -> Bool:
        return message >= self.base and message < self.base + len(self.uis) * MAX_CONTROLS

    def handle(mut self, e: Event, mut agent: Agent) -> Bool:
        """One of its screens' controls was used: the state edited; True when it reported an action (run the agent)."""
        var k = (e.message - self.base) // MAX_CONTROLS
        if k < 0 or k >= len(self.uis):
            return False
        var act = self.uis[k].handle(e, agent.state, self.font)
        if self.live[k]:  # (a screen still arriving: inputs edit the state, but nothing answers the call before it ends)
            return False
        if act.kind != ACT_ACTION:  # (an input, or the screen's own change: a tab, a copy, a scroll)
            return False
        if not agent.answered(self.calls[k]):
            agent.answer(self.calls[k], act.report())
        else:
            agent.say("(used the screen) " + act.report())
        return True

    def parts(self, from_screen: Int = 0) -> List[Part]:
        """What speech may point at on the screens from `from_screen` on (the cards of this turn): each screen's named parts
        (mojoui.pointer.Part)."""
        var out = List[Part]()
        for k in range(max(from_screen, 0), len(self.uis)):
            if not self.live[k]:
                for pt in self.uis[k].parts():
                    out.append(pt.copy())
        return out^

    def point(mut self, tag: String) -> Bool:
        """A `point` event's tag (card + "." + part): the screen it names moves for it if it can (a map flies to the stop). The
        pointer's ring is the app's (mojoui.pointer); this is what the card itself does. True when one did."""
        for k in range(len(self.uis)):
            if self.uis[k].point(tag):
                return True
        return False

    def card_index(self, card: String) -> Int:
        """The screen called `card` ("card2"), -1 none."""
        for k in range(len(self.uis)):
            if self.uis[k].card == card:
                return k
        return -1

    def patch(mut self, k: Int, patch_json: String) -> String:
        """Screen k changed by a JSON Patch (RFC 6902) on its render_ui arguments ({"ui": …}): applied atomically, validated with
        the catalog again, swapped in keeping what the card holds itself (GenUi.carry: its tiles glide). "" when it was applied,
        else why not (the card stays as it was)."""
        if k < 0 or k >= len(self.uis):
            return "no such card"
        if self.uis[k].problem != "" or self.live[k]:
            return self.uis[k].card + " isn't shown (it was refused, or it is still arriving)"
        var doc: JDoc
        try:
            doc = JDoc.parse(self.uis[k].args())
            doc.patch(patch_json)
        except e:
            return "the patch doesn't apply to " + self.uis[k].card + ": " + String(e)
        var made = GenUi[Self.H](doc.dump(), self.base + k * MAX_CONTROLS, self.canvas_base + k * MAX_NODES, self.hub, self.album)
        if made.problem != "":
            return made.problem
        made.carry(self.uis[k])
        self.uis[k] = made^
        return ""

    def custom(mut self, agent: Agent) -> String:
        """After EV_CUSTOM: a `ui_patch` event ({"card", "patch"}) applied to the card it names. "" applied, else why not (also
        logged: a CUSTOM event has no answer channel); "not a ui_patch" for other events."""
        if agent.custom_name != UI_PATCH:
            return "not a ui_patch"
        var card = String("")
        var ops = String("")
        try:
            var j = Json.parse(agent.custom_value)
            card = j.text(j.get(0, "card"))
            ops = j.dump(j.get(0, "patch"))
        except:
            pass
        var k = self.card_index(card)
        var why = String("no card ") + json_string(card) if k < 0 else self.patch(k, ops)
        self.said.append("PATCH: card=" + card + (" ok" if why == "" else " refused=" + why))
        return why

    def tiles(mut self, args: String) -> String:
        """The `tiles` tool's answer (JSON): its operation as a patch on the card it names (or the newest one with live tiles),
        validated again: {"done": true, "card", "order": [the grid's ids], "first", "say"}, or {"error": "refused: …"} with what
        to fix (an unknown id lists the ids)."""
        var card = String("")
        var op = String("")
        try:
            var a = Json.parse(args)
            if a.kind(0) == J_OBJECT:
                card = a.text(a.get(0, "card"))
                op = a.text(a.get(0, "op"))
        except:
            pass
        var k = -1
        if card != "":
            k = self.card_index(card)
        else:
            for i in range(len(self.uis)):
                if self.uis[i].problem == "" and not self.live[i] and self.uis[i].tiles_node() >= 0:
                    k = i
        if k < 0 or self.uis[k].tiles_node() < 0:
            return _refused("no live tiles on the screen" + ((" called " + card) if card != "" else String("")) + ": show them first with render_ui's LiveTiles")
        var n = self.uis[k].tiles_node()
        var ops: String
        try:
            ops = tiles_patch(self.uis[k].json, n, self.uis[k].pointer_to(n), args)
        except e:
            return _refused(String(e))
        var why = self.patch(k, ops)
        if why != "":
            self.said.append("TILES: card=" + self.uis[k].card + " op=" + op + " refused=" + why)
            return _refused(why)
        var lay = self.uis[k].tiles_at(self.uis[k].tiles_node()).layout()
        var order = String("")
        var listed = String("[")
        for i in range(len(lay.ids)):
            order += ("," if i > 0 else "") + lay.ids[i]
            listed += ("," if i > 0 else "") + json_string(lay.ids[i])
        var first = lay.ids[0] if len(lay.ids) > 0 else String("")
        var size = size_name(lay.sizes[0]) if len(lay.sizes) > 0 else String("")
        self.said.append("TILES: card=" + self.uis[k].card + " op=" + op + " order=" + order + " first=" + first + " size=" + size + " holes=" + String(lay.holes))
        return ('{"done":true,"card":' + json_string(self.uis[k].card) + ',"order":' + listed + '],"first":' + json_string(first)
                + ',"say":' + json_string("The tiles are on the screen in this order: " + order.replace(",", ", ") + ". Say what changed in a few words.") + "}")

    def take_tiles(mut self, mut agent: Agent) -> Bool:
        """Every finished `tiles` call not yet answered (an AG-UI client that offered tiles_tool()): applied and answered. True when
        one was (run the agent again: it hears the result)."""
        var did = False
        for c in agent.pending():
            if c.name != TILES:
                continue
            agent.answer(c.id, _refused("too big: the arguments are larger than the client keeps") if c.too_big else self.tiles(c.arguments))
            did = True
        return did

    def take_log(mut self) -> List[String]:
        """What the screens' components did since the last call, one line each, for a checker ("MAP: card=card3 stop=1 …")."""
        var out = self.said.copy()
        self.said.clear()
        for k in range(len(self.uis)):
            for line in self.uis[k].take_log():
                out.append(line)
        return out^

    def point_at(mut self, tag: String):
        """The pointer is on the part tagged `tag` ("" on nothing): the card it belongs to may answer (a block rises, a step is
        marked: GenUi.point_at)."""
        for k in range(len(self.uis)):
            self.uis[k].point_at(tag)

    def of_message(self, message_id: String) -> List[Int]:
        var out = List[Int]()
        for k in range(len(self.messages)):
            if self.messages[k] == message_id:
                out.append(k)
        return out^

    def view(self, k: Int, state: JDoc, version: Int) -> View:
        """Screen k, or a warning card saying why it was refused."""
        if self.uis[k].problem != "":
            return Card(Text("Couldn't show the agent's UI", style=CAPTION), Text(self.uis[k].problem), spacing=SPACE_XS).tone(CARD_WARN)
        return self.uis[k].view(state, version)

    def draw(mut self, canvas: Int, mut surface: Surface, p: Palette, state: JDoc):
        for k in range(len(self.uis)):
            if self.uis[k].draws(canvas):
                self.uis[k].draw(canvas, surface, p, state, self.font)
