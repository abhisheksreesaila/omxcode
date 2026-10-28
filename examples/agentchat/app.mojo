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
from mojoui.genui import schema, MAX_CONTROLS
from mojoui.agentui import Screens
from themes.omxqua import omxqua

# messages (no ranges below 10_000; agent-built UI k uses UI_BASE + k * MAX_CONTROLS … + 999, k < MAX_UIS: Screens)
comptime TYPED = 1
comptime SEND = 2
comptime PIECE = 3
comptime ENDED = 4
comptime URL = 5
comptime STOP = 6
comptime UI_BASE = 10_000
comptime MAX_UIS = 40
comptime CANVAS_BASE = 1000  # UI k's sparklines: CANVAS_BASE + k * MAX_NODES …


struct Main(App):
    comptime HTTP = True
    var http: Http
    var agent: Agent
    var draft: String
    var url: String
    var screens: Screens  # the agent's UI in the conversation (mojoui.agentui)
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
        self.screens = Screens(UI_BASE, CANVAS_BASE, MAX_UIS)
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
                if self.screens.take(self.agent):  # (a refusal: the agent hears why with another run)
                    self.again = True
            elif what == EV_STATE:
                self.version += 1
            elif what == EV_STREAM_END and self.again:
                self.again = False
                self.run()
        elif self.screens.owns(e.message):
            self.version += 1
            if self.screens.handle(e, self.agent):
                self.run()

    def draw(mut self, canvas: Int, mut surface: Surface):
        self.screens.draw(canvas, surface, self.themed.palette, self.agent.state)

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
            for k in self.screens.of_message(m.id):
                items.append(HStack(self.screens.view(k, self.agent.state, self.version).width(560), Spacer(), spacing=SPACE_S).fill())
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
