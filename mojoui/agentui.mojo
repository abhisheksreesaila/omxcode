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
# message. Calls the app didn't offer are left alone.

from mojoui.agui import Agent
from mojoui.genui import GenUi, ACT_ACTION, MAX_CONTROLS, MAX_NODES
from mojoui.jsonpatch import JDoc
from mojoui.json import json_string
from mojoui.view import View, Text, Card, CAPTION, SPACE_XS, CARD_WARN
from mojoui.canvas import Surface
from mojoui.theme import Palette
from mojoui.app import Event

comptime MAX_SCREENS = 40


struct Screens(Movable):
    var uis: List[GenUi]
    var calls: List[String]  # screen k answers tool call calls[k]
    var messages: List[String]  # … and belongs to the message messages[k]
    var base: Int
    var canvas_base: Int
    var max: Int

    def __init__(out self, base: Int, canvas_base: Int, max: Int = MAX_SCREENS):
        self.uis = List[GenUi]()
        self.calls = List[String]()
        self.messages = List[String]()
        self.base = base
        self.canvas_base = canvas_base
        self.max = max

    def known(self, call_id: String) -> Bool:
        for c in self.calls:
            if c == call_id:
                return True
        return False

    def take(mut self, mut agent: Agent, tool: String = "render_ui") -> Bool:
        """Every finished `tool` call not yet seen: shown, or refused with a message to the agent. True when one was
        refused (run the agent again so it hears why)."""
        var refused = False
        for c in agent.pending():
            if c.name != tool or self.known(c.id):
                continue
            var problem = String("")
            if c.too_big:
                problem = "too big: the arguments are larger than the client keeps"
            elif len(self.uis) >= self.max:
                problem = "too big: the chat holds " + String(self.max) + " screens at most"
            if problem != "":
                agent.answer(c.id, '{"error":' + json_string("refused: " + problem) + "}")
                refused = True
                continue
            var k = len(self.uis)
            var ui = GenUi(c.arguments, self.base + k * MAX_CONTROLS, self.canvas_base + k * MAX_NODES)
            if ui.problem != "":
                agent.answer(c.id, '{"error":' + json_string("refused: " + ui.problem) + "}")
                refused = True
            self.uis.append(ui^)
            self.calls.append(c.id)
            self.messages.append(agent.last_message)
        return refused

    def owns(self, message: Int) -> Bool:
        return message >= self.base and message < self.base + len(self.uis) * MAX_CONTROLS

    def handle(mut self, e: Event, mut agent: Agent) -> Bool:
        """One of its screens' controls was used: the state edited; True when it reported an action (run the agent)."""
        var k = (e.message - self.base) // MAX_CONTROLS
        if k < 0 or k >= len(self.uis):
            return False
        var act = self.uis[k].handle(e, agent.state)
        if act.kind != ACT_ACTION:
            return False
        if not agent.answered(self.calls[k]):
            agent.answer(self.calls[k], act.report())
        else:
            agent.say("(used the screen) " + act.report())
        return True

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

    def draw(self, canvas: Int, mut surface: Surface, p: Palette, state: JDoc):
        for k in range(len(self.uis)):
            if self.uis[k].draws(canvas):
                self.uis[k].draw(canvas, surface, p, state)
