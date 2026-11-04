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

from mojoui.agui import Agent
from mojoui.genui import GenUi, ACT_ACTION, MAX_CONTROLS, MAX_NODES, partial_ui, LOADING_UI
from mojoui.datahub import Hub, NoData
from mojoui.jsonpatch import JDoc
from mojoui.json import json_string
from mojoui.view import View, Text, Card, CAPTION, SPACE_XS, CARD_WARN
from mojoui.canvas import Surface
from mojoui.theme import Palette
from mojoui.app import Event
from mojoui.text import Font

comptime MAX_SCREENS = 40
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
        self.font = Font()

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
        var ui = GenUi[Self.H](partial_ui(args), self.base + k * MAX_CONTROLS, self.canvas_base + k * MAX_NODES, self.hub)
        if ui.problem != "":
            return GenUi[Self.H](LOADING_UI, self.base + k * MAX_CONTROLS, self.canvas_base + k * MAX_NODES, self.hub)
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
                    self.uis.append(self.preview_of(c.arguments, k))
                    self.calls.append(c.id)
                    self.messages.append(m.id)
                    self.live.append(True)
                    self.sizes.append(c.arguments.byte_length())
                else:
                    self.uis[k] = self.preview_of(c.arguments, k)
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
                self.uis[k] = GenUi[Self.H]('{"ui":{"component":"Script"}}', self.base + k * MAX_CONTROLS, self.canvas_base + k * MAX_NODES, self.hub)
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
            var ui = GenUi[Self.H](c.arguments, self.base + k * MAX_CONTROLS, self.canvas_base + k * MAX_NODES, self.hub)
            if ui.problem != "":
                agent.answer(c.id, '{"error":' + json_string("refused: " + ui.problem) + "}")
                refused = True
            else:
                self.streak = 0
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
