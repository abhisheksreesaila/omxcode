# mojoui.agentchat: a chat on an AG-UI agent that any app drops in (goal 48 M3): a panel, a sidebar or a popup.
# Streaming words as Markdown (code blocks get a Copy button), a typing indicator, Send that becomes Stop, a list that
# follows the newest words and lets go when the reader scrolls up, suggestion chips (the app's, or the agent's CUSTOM
# "suggestions" event), Copy and Regenerate on replies, an error with Retry, tool calls with their status, the agent's
# UI (render_ui: mojoui.genui, validated, native), and new messages arriving on a spring (View.arrive()).
#
#   var chat = AgentChat("http://127.0.0.1:8765/", base=20_000, canvas_base=2000, title="Assistant")
#   chat.suggest("Show me sales as a chart")
#   App: requests() → chat.requests(); update(e) → chat.update(e); view() → chat.view(); draw(c, s) → chat.draw(c, s, palette)
#
# Messages: base … base + 9_999 are the chat's own; its screens use base + 10_000 … (Screens: 1,000 each).

from mojoui.view import (
    View, Text, Button, TextField, VStack, HStack, Card, Spacer, Scroll, Divider, Icon, Overlay,
    CAPTION, HEADLINE, TITLE, BODY, PLAIN, PROMINENT, SUBTLE, ICON_ONLY, START, END, CENTER, STRETCH,
    SPACE_XS, SPACE_S, SPACE_M, SPACE_L, TONE_NONE, TONE_GOOD, TONE_WARN, TONE_ACCENT, TONE_STRONG, CARD_WARN, NO_MSG,
)
from mojoui.overlays import Clipboard
from mojoui.markdown import Markdown
from mojoui.codeblock import CodeBlock
from mojoui.chip import Chip
from mojoui.feedback import Note, Warning
from mojoui.timeline import Timeline, Stage, STAGE_RUNNING, STAGE_DONE
from mojoui.app import Event
from mojoui.canvas import Surface
from mojoui.theme import Palette
from mojoui.http import Http, Request
from mojoui.json import Json, json_string, J_ARRAY, J_STRING
from mojoui.agui import (
    Agent, Tool, ToolCall, Message, EV_TEXT, EV_TOOL_START, EV_TOOL_ARGS, EV_TOOL_END, EV_TOOL_RESULT, EV_STATE,
    EV_STREAM_END, EV_CUSTOM, EV_RUN_ERROR,
)
from mojoui.genui import schema, MAX_CONTROLS, MAX_NODES
from mojoui.agentui import Screens, MAX_RETRIES

comptime CHAT_PANEL = 0  # fills what it's given (a chat app, a page)
comptime CHAT_SIDEBAR = 1  # a column beside the app's content, with a close button
comptime CHAT_POPUP = 2  # a round button in a corner that opens a floating chat over the app

# the chat's own messages: base + …
comptime C_TYPED = 0
comptime C_SEND = 1
comptime C_PIECE = 2
comptime C_ENDED = 3
comptime C_STOP = 4
comptime C_RETRY = 5
comptime C_REGENERATE = 6
comptime C_OPEN = 7  # the popup's button / the sidebar's close
comptime C_URL = 8
comptime C_SUGGEST = 20  # + k (k < 20)
comptime C_COPY = 1000  # + message index (< 1000): copy that reply
comptime C_CODE = 3000  # + message index × 8 + block (< 8): copy that code block
comptime C_SCREENS = 10_000
comptime MAX_UIS = 40


@fieldwise_init
struct Segment(Copyable, Movable):
    var code: Bool
    var language: String
    var text: String


def segments(text: String) -> List[Segment]:
    """Markdown cut at fenced code blocks (```lang … ```): words and code in order. A fence still open (the words are
    streaming) is code to the end."""
    var out = List[Segment]()
    var words = String("")
    var code = String("")
    var lang = String("")
    var inside = False
    for line_ in text.split("\n"):
        var line = String(line_)
        var bare = String(line.strip())
        if bare.startswith("```"):
            if inside:
                out.append(Segment(True, lang, code))
                code = ""
                inside = False
            else:
                if String(words.strip()).byte_length() > 0:
                    out.append(Segment(False, "", words))
                words = ""
                lang = String(bare[byte = 3 :].strip())
                inside = True
            continue
        if inside:
            code += ("\n" if code.byte_length() > 0 else "") + line
        else:
            words += line + "\n"
    if inside:
        out.append(Segment(True, lang, code))
    elif String(words.strip()).byte_length() > 0:
        out.append(Segment(False, "", words))
    return out^


def status_of(call: ToolCall, answered: Bool) -> String:
    """A tool call's stage, as CopilotKit names them: in progress (its arguments are streaming), executing (they're
    complete; the app or the agent is working on it), complete (it has its result)."""
    if not call.done:
        return "in progress"
    return "complete" if answered else "executing"


struct AgentChat(Movable):
    var http: Http
    var agent: Agent
    var screens: Screens
    var base: Int
    var layout: Int
    var open: Bool  # the popup or the sidebar is open
    var title: String
    var welcome: String
    var draft: String
    var suggestions: List[String]  # the app's
    var agent_suggestions: List[String]  # the agent's (CUSTOM "suggestions": a list of strings)
    var again: Bool  # run again once this run's stream ends (the app answered a tool call meanwhile)
    var version: Int  # moves on when the state changes: canvases redraw
    var pieces: Int  # text deltas streamed in
    var copies: Int  # the clipboard's version
    var copy_text: String
    var copied: Int  # the message whose Copy was pressed last (-1 none)
    var stopped: Bool  # the last run was stopped by the person
    var show_url: Bool  # an Agent URL field in the header (a developer's chat)

    def __init__(out self, url: String, base: Int = 20_000, canvas_base: Int = 2000, layout: Int = CHAT_PANEL,
                 title: String = "Assistant", welcome: String = "Ask me anything.", show_url: Bool = False):
        self.http = Http()
        self.base = base
        self.agent = Agent(url, base + C_PIECE, base + C_ENDED, "agentchat")
        self.screens = Screens(base + C_SCREENS, canvas_base, MAX_UIS)
        self.layout = layout
        self.open = layout == CHAT_PANEL or layout == CHAT_SIDEBAR
        self.title = title
        self.welcome = welcome
        self.draft = ""
        self.suggestions = List[String]()
        self.agent_suggestions = List[String]()
        self.again = False
        self.version = 0
        self.pieces = 0
        self.copies = 0
        self.copy_text = ""
        self.copied = -1
        self.stopped = False
        self.show_url = show_url
        self.agent.offer(Tool("render_ui", "Show UI in the chat, built only from the app's catalogued components (data, never code). "
                              + "Inputs edit the shared state at their bind; the first button pressed (or choice with an action) is this tool's result.", schema()))

    def suggest(mut self, text: String):
        """A suggestion chip the chat offers (the first 20)."""
        if len(self.suggestions) < 20:
            self.suggestions.append(text)

    def offer(mut self, var tool: Tool):
        self.agent.offer(tool^)

    def requests(mut self) -> List[Request]:
        return self.http.take()

    # ---- what happens ----

    def owns(self, message: Int) -> Bool:
        return message >= self.base and message < self.base + C_SCREENS + MAX_UIS * MAX_CONTROLS

    def run(mut self):
        self.stopped = False
        if not self.agent.run(self.http):
            self.again = True

    def send(mut self, text: String):
        """The person says `text` and the agent runs (nothing while a run is going)."""
        if text.byte_length() == 0 or self.agent.running:
            return
        for c in self.agent.pending():  # (UI nobody used: the agent hears it was shown, so the conversation stays whole)
            self.agent.answer(c.id, '{"shown":true}')
        self.agent.say(text)
        self.screens.reset()
        self.agent_suggestions = List[String]()
        self.draft = ""
        self.run()

    def last_user(self) -> Int:
        for i in range(len(self.agent.messages) - 1, -1, -1):
            if self.agent.messages[i].role == "user":
                return i
        return -1

    def regenerate(mut self):
        """The last answer again: everything after the last question goes, and the agent runs once more."""
        if self.agent.running:
            return
        var u = self.last_user()
        if u < 0:
            return
        while len(self.agent.messages) > u + 1:
            _ = self.agent.messages.pop()
        self.screens.reset()
        self.run()

    def retry(mut self):
        """After an error: the same run again (a half-written answer is dropped first)."""
        self.regenerate()

    def update(mut self, e: Event) -> Bool:
        """The chat's own messages (False: not the chat's)."""
        if not self.owns(e.message):
            return False
        var k = e.message - self.base
        if k == C_TYPED:
            self.draft = e.text
        elif k == C_URL:
            self.agent.url = e.text
        elif k == C_SEND:
            var text = self.draft.copy()
            self.send(text)
        elif k == C_STOP:
            if self.agent.running:
                self.agent.stop(self.http)
                self.stopped = True
        elif k == C_RETRY:
            self.retry()
        elif k == C_REGENERATE:
            self.regenerate()
        elif k == C_OPEN:
            self.open = not self.open
        elif k >= C_SUGGEST and k < C_SUGGEST + 20:
            var list = self.agent_suggestions.copy() if len(self.agent_suggestions) > 0 else self.suggestions.copy()
            var at = k - C_SUGGEST
            if at < len(list):
                var text = list[at].copy()
                self.send(text)
        elif k >= C_COPY and k < C_COPY + 1000:
            var at = k - C_COPY
            if at < len(self.agent.messages):
                self.copy_text = self.agent.messages[at].content
                self.copies += 1
                self.copied = at
        elif k >= C_CODE and k < C_SCREENS:
            var at = (k - C_CODE) // 8
            var block = (k - C_CODE) % 8
            if at < len(self.agent.messages):
                var segs = segments(self.agent.messages[at].content)
                var n = 0
                for ref s in segs:
                    if s.code:
                        if n == block:
                            self.copy_text = s.text
                            self.copies += 1
                        n += 1
        elif k == C_PIECE or k == C_ENDED:
            var what = self.agent.handle(e)
            if what == EV_TEXT:
                self.pieces += 1
            elif what == EV_TOOL_START or what == EV_TOOL_ARGS:
                _ = self.screens.preview(self.agent)  # (render_ui still streaming: what's arrived, drawn now; each canvas
                # redraws only when its own data changed: genui's stamps, not the chat's version)
            elif what == EV_TOOL_END:
                if self.screens.take(self.agent):  # (a refusal: the agent hears why with another run)
                    self.again = True
            elif what == EV_STATE:
                self.version += 1
            elif what == EV_CUSTOM and self.agent.custom_name == "suggestions":
                self.agent_suggestions = List[String]()
                try:
                    var j = Json.parse(self.agent.custom_value)
                    for i in range(min(j.size(0), 6)):
                        if j.kind(j.at(0, i)) == J_STRING and j.text(j.at(0, i)).byte_length() <= 120:
                            self.agent_suggestions.append(j.text(j.at(0, i)))
                except:
                    pass
            elif what == EV_STREAM_END and self.again and not self.stopped:
                self.again = False
                self.run()
        elif self.screens.owns(e.message):
            self.version += 1
            if self.screens.handle(e, self.agent):
                self.run()
        return True

    def draw(mut self, canvas: Int, mut surface: Surface, p: Palette):
        self.screens.draw(canvas, surface, p, self.agent.state)

    # ---- the screen ----

    def errored(self) -> Bool:
        return not self.agent.running and self.agent.ended.startswith("error") and not self.stopped

    def reply_view(self, i: Int, last: Bool) -> View:
        """An assistant message: its words (Markdown, code with Copy), its tool calls, its screens, its actions."""
        ref m = self.agent.messages[i]
        var parts = List[View]()
        var block = 0
        for ref s in segments(m.content):
            if s.code:
                var head = List[View]()
                if s.language.byte_length() > 0:
                    head.append(Text(s.language, style=CAPTION))
                head.append(CodeBlock(s.text, self.base + C_CODE + i * 8 + min(block, 7), 0, False))
                parts.append(VStack(head^, spacing=SPACE_XS).align(START).fill())
                block += 1
            else:
                parts.append(Markdown(s.text, tag="markdown", tables=True))
        var tools = List[View]()
        for ref c in m.calls:
            if c.name == "render_ui" and self.screens.known(c.id):
                continue
            tools.append(self.tool_card(c))
        if len(tools) > 0:
            parts.append(VStack(tools^, spacing=SPACE_S).align(START).fill())
        for k in self.screens.of_message(m.id):
            if self.screens.streaming(k):
                parts.append(HStack(Icon("loader-circle", 14), Text("Building UI", style=CAPTION).tone(TONE_STRONG),
                                    Text("in progress", style=CAPTION), spacing=SPACE_XS).align(CENTER).tag("chat-building"))
            parts.append(self.screens.view(k, self.agent.state, self.version))
        var done = not (last and self.agent.running)
        if done and m.content.byte_length() > 0:
            var acts = List[View]()
            acts.append(Button("Copied" if self.copied == i else "Copy", self.base + C_COPY + i, style=SUBTLE, icon="copy"))
            if last:
                acts.append(Button("Regenerate", self.base + C_REGENERATE, style=SUBTLE, icon="refresh-cw"))
            parts.append(HStack(acts^, spacing=SPACE_XS).align(CENTER))
        return VStack(parts^, spacing=SPACE_S).align(START).fill().tag("chat-reply")

    def result_of(self, call_id: String) -> String:
        for ref m in self.agent.messages:
            if m.role == "tool" and m.tool_call_id == call_id:
                return m.content
        return ""

    def tool_card(self, c: ToolCall) -> View:
        """A tool call (the agent's own, or one the app answers) and its stage: in progress, executing, complete."""
        var st = status_of(c, self.agent.answered(c.id))
        var head = HStack(Icon("check" if st == "complete" else ("loader-circle" if st == "executing" else "wrench"), 14),
                          Text(c.name if c.name != "render_ui" else String("building UI"), style=CAPTION).tone(TONE_STRONG), Spacer(),
                          Chip(st, 2 if st == "complete" else (1 if st == "executing" else 0)), spacing=SPACE_XS).align(CENTER).fill()
        var rows = List[View]()
        rows.append(head^)
        var args = c.arguments if c.arguments.byte_length() <= 140 else String(c.arguments[byte = : 137]) + "…"
        if args.byte_length() > 0 and args != "{}":
            rows.append(Text(args, style=CAPTION).tag("chat-tool-args"))
        var result = self.result_of(c.id)
        if result.byte_length() > 0:
            rows.append(Text("→ " + (result if result.byte_length() <= 140 else String(result[byte = : 137]) + "…"), style=CAPTION))
        return Card(rows^, spacing=SPACE_XS).fill().tag("chat-tool")

    def steps_view(self) -> View:
        """The run's steps (STEP_STARTED / STEP_FINISHED) as a live progress list."""
        var stages = List[Stage]()
        for k in range(len(self.agent.steps)):
            stages.append(Stage(self.agent.steps[k], STAGE_DONE if self.agent.steps_done[k] else STAGE_RUNNING, -1, ""))
        return Timeline(stages)

    def user_view(self, text: String) -> View:
        return HStack(Spacer(), Card(Text(text), spacing=SPACE_XS).max_width(520).tag("chat-user"), spacing=SPACE_S).fill()

    def thinking(self) -> View:
        var words = "Thinking" + ((" · " + self.agent.step) if self.agent.step.byte_length() > 0 else String("")) + "…"
        return HStack(Icon("sparkles", 16), Text(words, style=CAPTION), spacing=SPACE_XS).align(CENTER).tag("chat-typing")

    def chips(self) -> View:
        var list = self.agent_suggestions.copy() if len(self.agent_suggestions) > 0 else self.suggestions.copy()
        var row = List[View]()
        for k in range(len(list)):
            row.append(Button(list[k], self.base + C_SUGGEST + k, style=PLAIN, icon="sparkles"))
        return HStack(row^, spacing=SPACE_S).align(CENTER).tag("chat-suggestions")

    def conversation(self) -> List[View]:
        var items = List[View]()
        var n = len(self.agent.messages)
        var last_reply = -1
        for i in range(n):
            if self.agent.messages[i].role == "assistant":
                last_reply = i
        for i in range(n):
            ref m = self.agent.messages[i]
            if m.role == "user":
                items.append(self.user_view(m.content).arrive())
                if i == self.last_user() and len(self.agent.steps) > 0:
                    items.append(self.steps_view().arrive())
            elif m.role == "assistant":
                if m.content.byte_length() == 0 and len(m.calls) == 0 and len(self.screens.of_message(m.id)) == 0:
                    continue
                items.append(self.reply_view(i, i == last_reply).arrive())
        var waiting = self.agent.running  # (until the agent has said or started something since the question)
        for i in range(self.last_user() + 1, n):
            ref m = self.agent.messages[i]
            if m.role == "assistant" and (m.content.byte_length() > 0 or len(m.calls) > 0):
                waiting = False
        if waiting:
            items.append(self.thinking().arrive())
        if self.stopped and not self.agent.running:
            items.append(Note([Text("Stopped.", style=CAPTION)]).arrive())
        if self.errored():
            items.append(Warning([Text("Something went wrong", style=HEADLINE), Text(String(self.agent.ended[byte = 7 :]) if self.agent.ended.byte_length() > 7 else self.agent.ended, style=CAPTION),
                                  HStack(Button("Retry", self.base + C_RETRY, style=PROMINENT, icon="rotate-ccw"), spacing=0)]).arrive())
        if self.screens.gave_up and not self.agent.running:
            items.append(Note([Text("The agent's UI was refused " + String(MAX_RETRIES + 1) + " times in a row: stopped (send a message to go on)", style=CAPTION)]))
        return items^

    def empty(self) -> View:
        return VStack(Spacer(), Icon("sparkles", 32), Text(self.title, style=TITLE), Text(self.welcome, style=CAPTION), self.chips(), Spacer(),
                      spacing=SPACE_M).align(CENTER).fill().grow().tag("chat-welcome")

    def composer(self) -> View:
        var button = Button("Stop", self.base + C_STOP, style=PLAIN, icon="square") if self.agent.running else Button("Send", self.base + C_SEND, style=PROMINENT, icon="arrow-up")
        return HStack(TextField(self.draft, placeholder="Message", on_change=self.base + C_TYPED, on_submit=self.base + C_SEND).fill().grow(),
                      button^, spacing=SPACE_S).align(CENTER).fill().tag("chat-composer")

    def header(self, closable: Bool) -> View:
        var row = List[View]()
        row.append(Text(self.title, style=HEADLINE))
        row.append(Spacer())
        if self.show_url:
            row.append(TextField(self.agent.url, placeholder="Agent URL", on_change=self.base + C_URL).width(280))
        if closable:
            row.append(Button("Close", self.base + C_OPEN, style=ICON_ONLY, icon="x"))
        return HStack(row^, spacing=SPACE_M).align(CENTER).fill().tag("chat-header")

    def body(self, closable: Bool) -> View:
        var parts = List[View]()
        parts.append(self.header(closable))
        if len(self.agent.messages) == 0:
            parts.append(self.empty())
        else:
            var items = self.conversation()
            if not self.agent.running and not self.errored():
                items.append(self.chips())
            parts.append(Scroll(VStack(items^, spacing=SPACE_L).align(START).fill(), height=0, pinned=True).fill().grow())
        parts.append(self.composer())
        parts.append(Clipboard(self.copy_text, self.copies))
        return VStack(parts^, spacing=SPACE_M).align(STRETCH).fill().grow().tag("chat")

    def view(self) -> View:
        """The chat as its layout says: a panel that fills, a sidebar column, or a popup over `content` (see over())."""
        if self.layout == CHAT_SIDEBAR:
            return self.body(True).width(420) if self.open else Button("Assistant", self.base + C_OPEN, style=PROMINENT, icon="sparkles")
        return self.body(False)

    def over(self, content: View) -> View:
        """CHAT_POPUP: `content` with the chat floating over it (bottom right), or its round button when closed."""
        if not self.open:
            return Overlay(content, Button("Assistant", self.base + C_OPEN, style=PROMINENT, icon="sparkles").pin(END, END))
        return Overlay(content, Card(self.body(True), spacing=0).width(420).height(600).pin(END, END).arrive())
