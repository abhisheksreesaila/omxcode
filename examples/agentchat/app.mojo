# agentchat: a chat panel on an AG-UI agent (goal 35 M3). The agent streams its words, and builds UI in the conversation
# by calling the frontend tool render_ui with data from the component catalog (mojoui.genui validates and renders it;
# anything outside the catalog is refused and the agent is told why). Inputs in agent-built UI edit the shared state the
# agent sees with its next run; a button (or a choice with an action) is the tool call's result. The app only composes
# mojoui.agui, mojoui.genui and catalogued components.
#
#   scripts/agentchat.sh             the scripted agent (deterministic) and the app on GTK
#   docs/agui.md                     the live agent: the OMX Console's local models, or Claude

from std.os import getenv
from mojoui.view import (
    View, Text, Button, TextField, VStack, HStack, Card, Spacer, Scroll, Divider,
    CAPTION, HEADLINE, TITLE, PROMINENT, START, END, CENTER, SPACE_XS, SPACE_S, SPACE_M, SPACE_L, CARD_WARN,
)
from mojoui.app import App, Event
from mojoui.canvas import Surface
from mojoui.theme import Theme
from mojoui.http import Http, Request
from mojoui.agui import Agent, Tool, EV_TEXT, EV_TOOL_END, EV_STATE, EV_STREAM_END
from mojoui.genui import GenUi, schema, ACT_ACTION, ACT_STATE, MAX_CONTROLS, MAX_NODES
from themes.omxqua import omxqua

# messages (no ranges below 10_000; agent-built UI k uses UI_BASE + k * MAX_CONTROLS … + 999, k < MAX_UIS)
comptime TYPED = 1
comptime SEND = 2
comptime PIECE = 3
comptime ENDED = 4
comptime URL = 5
comptime STOP = 6
comptime UI_BASE = 10_000
comptime MAX_UIS = 40
comptime CANVAS_BASE = 1000  # UI k's sparklines: CANVAS_BASE + k * MAX_NODES …


struct Shown(Copyable, Movable):
    """Agent-built UI in the conversation: which tool call it answers and the message it belongs to."""

    var call_id: String
    var message_id: String
    var problem: String  # "" shown; else why it was refused

    def __init__(out self, call_id: String, message_id: String, problem: String):
        self.call_id = call_id
        self.message_id = message_id
        self.problem = problem


struct Main(App):
    comptime HTTP = True
    var http: Http
    var agent: Agent
    var draft: String
    var url: String
    var shown: List[Shown]
    var uis: List[GenUi]  # (kept beside shown: GenUi is only Movable)
    var pieces: Int  # text deltas streamed in, all runs
    var again: Bool  # run again once this run's stream ends (the app answered a tool call meanwhile)
    var version: Int  # moves on when the state changes: sparklines redraw
    var dark: Bool
    var themed: Theme

    def __init__(out self):
        self.http = Http()
        var url = getenv("AGUI_URL")
        self.url = url if url != "" else String("http://127.0.0.1:8765/")
        self.agent = Agent(self.url, PIECE, ENDED, "agentchat")
        self.agent.offer(Tool("render_ui", "Show UI in the chat, built only from the app's catalogued components (data, never code). "
                              + "Inputs edit the shared state at their bind; the first button pressed (or choice with an action) is this tool's result.", schema()))
        self.draft = ""
        self.shown = List[Shown]()
        self.uis = List[GenUi]()
        self.pieces = 0
        self.again = False
        self.version = 0
        self.dark = False
        self.themed = omxqua(False)

    def title(self) -> String:
        return "agentchat"

    def window_size(self) -> Tuple[Int, Int]:
        return (980, 820)

    def appearance(mut self, dark: Bool):
        self.dark = dark
        self.themed = omxqua(dark)

    def theme(self) -> Theme:
        return self.themed.copy()

    def requests(mut self) -> List[Request]:
        return self.http.take()

    # ---- what happens ----

    def run(mut self):
        if not self.agent.run(self.http):
            self.again = True

    def take_ui(mut self):
        """The agent finished a tool call: render_ui is validated and shown, or refused (the agent hears why at once)."""
        for c in self.agent.pending():
            var known = False
            for s in self.shown:
                if s.call_id == c.id:
                    known = True
            if known or c.name != "render_ui":
                continue
            var k = len(self.uis)
            var ui = GenUi(c.arguments, UI_BASE + k * MAX_CONTROLS, CANVAS_BASE + k * MAX_NODES)
            if k >= MAX_UIS:
                ui.problem = "too big: the chat holds " + String(MAX_UIS) + " screens at most"
            var problem = ui.problem
            self.shown.append(Shown(c.id, self.agent.last_message, problem))
            self.uis.append(ui^)
            if problem != "":
                self.agent.answer(c.id, '{"error":"refused: ' + problem.replace("\\", "\\\\").replace('"', '\\"') + '"}')
                self.again = True

    def update(mut self, e: Event):
        if e.message == TYPED:
            self.draft = e.text
        elif e.message == URL:
            self.url = e.text
            self.agent.url = e.text
        elif e.message == SEND:
            if self.draft.byte_length() == 0 or self.agent.running:
                return
            for c in self.agent.pending():  # (UI nobody used: the agent hears it was shown, so the conversation stays whole)
                self.agent.answer(c.id, '{"shown":true}')
            self.agent.say(self.draft)
            self.draft = ""
            self.run()
        elif e.message == STOP:
            self.agent.stop(self.http)
        elif e.message == PIECE or e.message == ENDED:
            var what = self.agent.handle(e)
            if what == EV_TEXT:
                self.pieces += 1
            elif what == EV_TOOL_END:
                self.take_ui()
            elif what == EV_STATE:
                self.version += 1
            elif what == EV_STREAM_END and self.again:
                self.again = False
                self.run()
        elif e.message >= UI_BASE and e.message < UI_BASE + MAX_UIS * MAX_CONTROLS:
            var k = (e.message - UI_BASE) // MAX_CONTROLS
            if k >= len(self.uis):
                return
            var act = self.uis[k].handle(e, self.agent.state)
            self.version += 1
            if act.kind == ACT_ACTION:
                var call = self.shown[k].call_id
                if not self.agent.answered(call):
                    self.agent.answer(call, act.report())
                else:
                    self.agent.say("(used the screen) " + act.report())
                self.run()

    def draw(mut self, canvas: Int, mut surface: Surface):
        for i in range(len(self.uis)):
            if self.uis[i].draws(canvas):
                self.uis[i].draw(canvas, surface, self.themed.palette, self.agent.state)

    # ---- the screen ----

    def bubble(self, role: String, content: String) -> View:
        var who = Text("You" if role == "user" else ("Agent" if role == "assistant" else role), style=CAPTION)
        var card = Card(who, Text(content), spacing=SPACE_XS).width(560)
        if role == "user":
            return HStack(Spacer(), card^, spacing=SPACE_S).fill()
        return HStack(card^, Spacer(), spacing=SPACE_S).fill()

    def view(self) -> View:
        var items = List[View]()
        for i in range(len(self.agent.messages)):
            ref m = self.agent.messages[i]
            if m.role == "tool":
                continue  # (answers to tools: the screens below say it)
            if m.content.byte_length() > 0:
                items.append(self.bubble(m.role, m.content))
            for k in range(len(self.shown)):
                if self.shown[k].message_id != m.id:
                    continue
                if self.shown[k].problem != "":
                    items.append(HStack(Card(Text("Couldn't show the agent's UI", style=CAPTION), Text(self.shown[k].problem), spacing=SPACE_XS).tone(CARD_WARN).width(560), Spacer(), spacing=SPACE_S).fill())
                else:
                    items.append(HStack(self.uis[k].view(self.agent.state, self.version).width(560), Spacer(), spacing=SPACE_S).fill())
        if len(items) == 0:
            items.append(Text("Say hello, or ask for a chart or a form.", style=CAPTION))
        var status = ("thinking… " + self.agent.step if self.agent.running else ("ready" if self.agent.ended == "open" or self.agent.ended == "finished" else self.agent.ended))
        return VStack(
            HStack(Text("Agent chat", style=TITLE), Spacer(), TextField(self.url, placeholder="Agent URL", on_change=URL).width(300), spacing=SPACE_M).align(CENTER).fill(),
            Scroll(VStack(items^, spacing=SPACE_M).align(START).fill(), height=560, pinned=True).fill().grow(),
            HStack(TextField(self.draft, placeholder="Message", on_change=TYPED, on_submit=SEND).fill().grow(),
                   Button("Stop", on_tap=STOP) if self.agent.running else Button("Send", on_tap=SEND, style=PROMINENT), spacing=SPACE_S).align(CENTER).fill(),
            Text("streamed: " + String(self.pieces) + " pieces · " + status, style=CAPTION),
            spacing=SPACE_M,
        ).align(START).padding(28).fill().grow()
