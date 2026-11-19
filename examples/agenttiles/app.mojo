# Agent tiles: live tiles an agent drives through AG-UI (goal 77 M7c), with no model. A scripted stand-in agent (a LocalAgent in this
# process: RunAgentInput in, AG-UI events out) goes through the real client loop (mojoui.agui.Agent.run_local, mojoui.agentui.Screens):
#   "What matters this morning?"  -> render_ui with a LiveTiles card (Screens.take shows it, validated by the catalog)
#   "It's going to rain at pickup" -> the `tiles` tool {"op":"promote","id":"weather"} (Screens.take_tiles applies it as a patch and
#                                     answers with the new order), then, hearing the result, a sentence and a CUSTOM `point` event naming
#                                     the weather tile: the pointer's ring goes to it while the tiles glide.
# Tapping a tile (or one of its actions) is an action the agent hears as a user message, and it says so.
#
# Lines on stdout for the M7c proof (scripts/g77_agenttiles_check.py): TILES SHOWN / TILES: (what a patch did) / TILES LAYOUT (the grid:
# ids, sizes, holes, each tile's rect in window points) / TILES POINT (the ring as drawn and the tile's rect, from the pointer's layer).

from mojoui import App, Event, View, VStack, HStack, Text, Button, Spacer, HEADLINE, CAPTION, PROMINENT
from mojoui.shell import Shell
from mojoui.view import SPACE_S
from mojoui.agui import Agent, Tool, LocalAgent, EV_CUSTOM
from mojoui.agentui import Screens, tiles_tool, UI_PATCH
from mojoui.genui import schema
from mojoui.canvas import Surface
from mojoui.effects import Every
from mojoui.geometry import rect_of
from mojoui.json import Json, json_string
from mojoui.livetiles import size_name
from mojoui.pointer import Pointer, PointerView, POINTER_TAG, point_event
from mojoui.theme import Theme
from mojoui.view import Overlay
from themes.omxqua import omxqua

comptime MORNING = 1
comptime RAIN = 2
comptime TICK = 3
comptime POINTER_CANVAS = 9000
comptime UI_BASE = 20_000
comptime CANVAS_BASE = 2000

comptime TILES_UI = (
    '{"ui":{"component":"Card","title":"This morning","children":[{"component":"LiveTiles","height":560,"tiles":['
    '{"id":"traffic","tint":"green","icon":"car","head":"Traffic","faces":[{"big":"Leave by 8:05","sub":"Bridge is slow · +18 min to school"},{"big":"26 min to school","sub":"via the river road · 2 incidents"}],"why":"you leave in 20 minutes","actions":["Directions","Tell school"]},'
    '{"id":"todo","tint":"orange","icon":"todo","head":"To do","faces":[{"big":"3 to do","sub":"Call mum · Pick up Maya · Water bill"},{"big":"Next: call mum","sub":"it\'s her birthday Saturday"}]},'
    '{"id":"cal","tint":"red","icon":"cal","head":"Calendar","faces":[{"big":"Pickup 3:15","sub":"Maya · the side gate"}]},'
    '{"id":"counter","tint":"slate","icon":"cam","head":"Counter","faces":[{"big":"Banana nearly ripe","sub":"seen 7:12"}],"charm":"pin"},'
    '{"id":"weather","tint":"blue","icon":"cloud","head":"Weather","faces":[{"big":"Rain from 4","sub":"Pickup at 3:15 will be wet · take the umbrella"}],"why":"rain starts before pickup","actions":["Remind me at 3","Hourly"]},'
    '{"id":"bday","kind":"passive","tint":"purple","icon":"gift","head":"Birthday","faces":[{"big":"Mum · Saturday","sub":"turns 64"}]},'
    '{"id":"timer","kind":"live","tint":"amber","icon":"timer","head":"Timer","faces":[{"big":"Pasta 6:40"}]}]}]}}'
)


def _ev(t: String, rest: String) -> String:
    return '{"type":"' + t + '"' + rest + "}"


struct Script(LocalAgent, Movable):
    """The stand-in agent: what a model would send for each turn, as AG-UI events (a run per call)."""

    var runs: Int

    def __init__(out self):
        self.runs = 0

    def respond(mut self, input: String) -> List[String]:
        self.runs += 1
        var id = String(self.runs)
        var out: List[String] = [_ev("RUN_STARTED", ',"threadId":"t","runId":"r' + id + '"')]
        var last_role = String("")
        var last = String("")
        var call_card = String("card1")
        try:
            var j = Json.parse(input)
            var ms = j.get(0, "messages")
            var m = j.at(ms, j.size(ms) - 1)
            last_role = j.text(j.get(m, "role"))
            last = j.text(j.get(m, "content"))
            if last_role == "tool":
                var r = Json.parse(last)
                if r.get(0, "card") >= 0:
                    call_card = r.text(r.get(0, "card"))
        except:
            pass
        if last_role == "user" and last.find("morning") >= 0:
            out += self.call("render_ui", TILES_UI, id)
        elif last_role == "user" and last.find("rain") >= 0:
            out += self.call("tiles", '{"op":"promote","id":"weather"}', id)
        elif last_role == "tool" and last.startswith('{"done":true'):
            out += self.say("Rain starts before pickup, so the weather is first now.", id)
            out.append(point_event(call_card, "weather", 0))
        elif last_role == "tool" or last.startswith("(used the screen)"):
            out += self.say("Got it.", id)
        out.append(_ev("RUN_FINISHED", ',"threadId":"t","runId":"r' + id + '"'))
        return out^

    def call(self, name: String, args: String, id: String) -> List[String]:
        return [_ev("TOOL_CALL_START", ',"toolCallId":"c' + id + '","toolCallName":"' + name + '","parentMessageId":"m' + id + '"'),
                _ev("TOOL_CALL_ARGS", ',"toolCallId":"c' + id + '","delta":' + json_string(args)),
                _ev("TOOL_CALL_END", ',"toolCallId":"c' + id + '"')]

    def say(self, text: String, id: String) -> List[String]:
        return [_ev("TEXT_MESSAGE_START", ',"messageId":"a' + id + '","role":"assistant"'),
                _ev("TEXT_MESSAGE_CONTENT", ',"messageId":"a' + id + '","delta":' + json_string(text)),
                _ev("TEXT_MESSAGE_END", ',"messageId":"a' + id + '"')]


struct Main(App):
    var agent: Agent
    var script: Script
    var screens: Screens[]
    var pointer: Pointer
    var dark: Bool
    var status: String
    var version: Int
    var point_stamp: Int  # the pointer's stamp when the last point was sent (-1: none to report)
    var point_ticks: Int  # ticks since the ring was first drawn there (it is reported once settled)

    def __init__(out self):
        self.agent = Agent("", 0, 0, "tiles")
        self.agent.offer(Tool("render_ui", "Show UI", schema()))
        self.agent.offer(tiles_tool())
        self.script = Script()
        self.screens = Screens(UI_BASE, CANVAS_BASE)
        self.pointer = Pointer()
        self.dark = False
        self.status = "Ask: What matters this morning?"
        self.version = 1
        self.point_stamp = -1
        self.point_ticks = 0

    def title(self) -> String:
        return "Agent tiles"

    def window_size(self) -> Tuple[Int, Int]:
        return (1280, 820)

    def theme(self) -> Theme:
        return omxqua(self.dark)

    def appearance(mut self, dark: Bool):
        self.dark = dark
        self.version += 1

    def every(self) -> List[Every]:
        return [Every(30, TICK)]

    def turn(mut self, said: String):
        """A user message and the runs it takes: the agent's frontend tools answered here (render_ui shown, tiles patched), then it
        runs again to hear them, until it stops calling."""
        self.agent.say(said)
        print("TILES SAY: " + said, flush=True)
        for _ in range(4):
            var codes = self.agent.run_local(self.script)
            for c in codes:
                if c == EV_CUSTOM:
                    self.custom()
            var had = len(self.screens.uis)
            var again = self.screens.take(self.agent)
            for k in range(had, len(self.screens.uis)):
                print("TILES SHOWN: card=" + self.screens.uis[k].card + " shape=" + self.screens.uis[k].summary() + " problem=" + self.screens.uis[k].problem, flush=True)
            again = self.screens.take_tiles(self.agent) or again
            for line in self.screens.take_log():
                print(line, flush=True)
            self.version += 1
            if not again:
                break
        self.status = self.agent.last_text()
        for k in range(len(self.screens.uis)):
            var n = self.screens.uis[k].tiles_node()
            if n < 0:
                continue
            var lay = self.screens.uis[k].tiles_at(n).layout()
            var ids = String("")
            for i in range(len(lay.ids)):
                ids += ("," if i > 0 else "") + lay.ids[i] + ":" + size_name(lay.sizes[i])
            print("TILES LAYOUT: card=" + self.screens.uis[k].card + " ids=" + ids + " holes=" + String(lay.holes), flush=True)
        print("TILES SAID: " + self.status, flush=True)

    def custom(mut self):
        """A CUSTOM event: `point` (the ring goes to the part it names; the card answers too) or `ui_patch`."""
        if self.agent.custom_name == UI_PATCH:
            _ = self.screens.custom(self.agent)
            return
        if self.agent.custom_name != "point":
            return
        try:
            var v = Json.parse(self.agent.custom_value)
            var tag = v.text(v.get(0, "card")) + "." + v.text(v.get(0, "part"))
            self.pointer.know(self.screens.parts())
            self.pointer.go(tag)
            _ = self.screens.point(tag)
            self.point_stamp = self.pointer.version()
            self.point_ticks = 0
            print("TILES POINT_SENT: tag=" + tag, flush=True)
        except:
            pass

    def update(mut self, event: Event):
        if event.message == MORNING:
            self.turn("What matters this morning?")
        elif event.message == RAIN:
            self.turn("It's going to rain at pickup.")
        elif event.message == TICK:
            self.screens.point_at(self.pointer.tag)
            self.report()
        elif self.screens.owns(event.message):
            if self.screens.handle(event, self.agent):  # (the person used the card: the agent hears it)
                var m = self.agent.messages[len(self.agent.messages) - 1].content
                print("TILES DID: " + m, flush=True)
                self.turn_after()

    def turn_after(mut self):
        var codes = self.agent.run_local(self.script)
        for c in codes:
            if c == EV_CUSTOM:
                self.custom()
        self.status = self.agent.last_text()

    def report(mut self):
        """Once the ring has been drawn on the pointed tile and had time to settle (1.2 s, and the tiles stopped), the ring and the tile, both in the
        pointer layer's points: the ring from the springs it is painted with, the tile from its canvas's rect and the layout's cell."""
        if self.point_stamp < 0 or not self.pointer.shown() or self.pointer.shown_stamp != self.point_stamp:
            return
        self.point_ticks += 1
        var tag = self.pointer.tag
        var dot = tag.find(".")
        var card = String(tag[byte = 0 : dot])
        var id = String(tag[byte = dot + 1 :])
        var k = self.screens.card_index(card)
        var still = k < 0 or self.screens.uis[k].tiles_node() < 0 or not self.screens.uis[k].tiles_at(self.screens.uis[k].tiles_node()).moving()
        if self.point_ticks < 40 or (not still and self.point_ticks < 120):  # (the tiles have stopped gliding, or 3.6 s passed)
            return
        self.point_stamp = -1
        var origin = rect_of(POINTER_TAG)
        var ox = origin[0] if len(origin) >= 4 else 0.0
        var oy = origin[1] if len(origin) >= 4 else 0.0
        var ring: List[Float64] = [self.pointer.cx.value - self.pointer.w.value / 2.0, self.pointer.cy.value - self.pointer.h.value / 2.0, self.pointer.w.value, self.pointer.h.value]
        var line = "TILES POINT: tag=" + tag + " ring=" + _rect(ring)
        if k >= 0:
            ref ui = self.screens.uis[k]
            var n = ui.tiles_node()
            var lt = ui.tiles_at(n)
            var canvas = rect_of(ui.tiles_tag(ui.canvas_of.get(n, 0)))
            var b = lt.target_of(id)
            if len(canvas) >= 4:
                var tile: List[Float64] = [canvas[0] + b.x - ox, canvas[1] + b.y - oy, b.w, b.h]
                var area: List[Float64] = [canvas[0] - ox, canvas[1] - oy, canvas[2], canvas[3]]
                line += " tile=" + _rect(tile) + " canvas=" + _rect(area)
            var lay = lt.layout()
            var ids = String("")
            for i in range(len(lay.ids)):
                ids += ("," if i > 0 else "") + lay.ids[i] + ":" + size_name(lay.sizes[i])
            line += " layout=" + ids + " holes=" + String(lay.holes)
        print(line, flush=True)

    def view(self) -> View:
        var bar = HStack(
            Text("Agent tiles", HEADLINE),
            Spacer(),
            Button("What matters this morning?", on_tap=MORNING, style=PROMINENT),
            Button("Rain at pickup", on_tap=RAIN),
            spacing=SPACE_S,
        ).fill()
        var rows = List[View]()
        rows.append(Text(self.status, CAPTION).tag("status"))
        for k in range(len(self.screens.uis) - 1, -1, -1):  # (newest first)
            rows.append(self.screens.view(k, self.agent.state, self.version))
        var page = Shell(bar^, VStack(rows^, spacing=SPACE_S).fill().grow())
        return Overlay(page^, PointerView(POINTER_CANVAS, self.pointer.version())).grow().fill()

    def draw(mut self, canvas: Int, mut surface: Surface):
        if canvas == POINTER_CANVAS:
            self.pointer.draw(surface, self.theme().palette)
        else:
            self.screens.draw(canvas, surface, self.theme().palette, self.agent.state)


def _rect(r: List[Float64]) -> String:
    var out = String("")
    for i in range(len(r)):
        out += ("," if i > 0 else "") + String(Int(r[i] + 0.5))
    return out
