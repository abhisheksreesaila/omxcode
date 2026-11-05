# mojoui.agentchat: a chat on an AG-UI agent that any app drops in (goal 48 M3): a panel, a sidebar or a popup.
# Streaming words as Markdown (code blocks get a Copy button), a typing indicator, Send that becomes Stop, a list that
# follows the newest words and lets go when the reader scrolls up, suggestion chips (the app's, or the agent's CUSTOM
# "suggestions" event), the model's thinking (live, then a folded "Thought"), Copy and Regenerate on replies, an error
# with Retry, tool calls with their status, the agent's UI (render_ui: mojoui.genui, validated, native), and new messages
# arriving on a spring (View.arrive()).
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
from mojoui.disclosure import Disclosure
from mojoui.timeline import Timeline, Stage, STAGE_RUNNING, STAGE_DONE
from mojoui.app import Event
from mojoui.canvas import Surface
from mojoui.theme import Palette
from mojoui.http import Http, Request
from mojoui.json import Json, json_string, J_ARRAY, J_STRING
from mojoui.agui import (
    Agent, Tool, LocalAgent, ToolCall, Message, EV_TEXT, EV_TOOL_START, EV_TOOL_ARGS, EV_TOOL_END, EV_TOOL_RESULT, EV_STATE,
    EV_STREAM_END, EV_CUSTOM, EV_RUN_ERROR, EV_REASONING,
)
from mojoui.genui import schema, MAX_CONTROLS, MAX_NODES
from mojoui.datahub import Hub, NoData
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
comptime C_INTERRUPT = 40  # + option (< 8): an interrupt's choice
comptime C_COPY = 1000  # + message index (< 1000): copy that reply (later ones have no Copy)
comptime C_THOUGHT = 2000  # + message index (< 1000): fold or unfold that thinking
comptime C_CODE = 3000  # + message index × 8 + block (< 8): copy that code block (messages < 500: later ones have no code Copy)
comptime C_DECIDE = 7000  # + call × 2 (+ 1: reject), call < 1500: a confirm tool's card
comptime C_SCREENS = 10_000
comptime MAX_UIS = 40
comptime RENDER_UI_ABOUT = ("Show UI in the chat, built only from the app's catalogued components (data, never code). "
                            + "Inputs edit the shared state at their bind; the first button pressed (or choice with an action) is this tool's result.")


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


def cut(text: String, most: Int) -> String:
    """`text`, at most `most` bytes, cut at a character's start (an agent's words in any language), "…" when cut."""
    if text.byte_length() <= most:
        return text
    var b = text.as_bytes()
    var end = most
    while end > 0 and b[end] >= 128 and b[end] < 192:  # (a continuation byte: inside a character)
        end -= 1
    return String(text[byte = : end]) + "…"


def tail(text: String, most: Int) -> String:
    """The end of `text`: at most `most` bytes, from a character's start, "…" before it when cut; on one line."""
    var flat = text.replace("\n", " ")
    if flat.byte_length() <= most:
        return flat^
    var b = flat.as_bytes()
    var start = flat.byte_length() - most
    while start < len(b) and b[start] >= 128 and b[start] < 192:
        start += 1
    return "…" + String(flat[byte = start :])


def status_of(call: ToolCall, answered: Bool) -> String:
    """A tool call's stage, as CopilotKit names them: in progress (its arguments are streaming), executing (they're
    complete; the app or the agent is working on it), complete (it has its result)."""
    if not call.done:
        return "in progress"
    return "complete" if answered else "executing"


struct AgentChat[H: Hub = NoData](Movable):
    var http: Http
    var agent: Agent
    var screens: Screens[Self.H]
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
    var unfolded: List[String]  # the reasoning messages shown whole (their ids)
    var show_url: Bool  # an Agent URL field in the header (a developer's chat)
    var confirm_tools: List[String]  # frontend tools that ask the person first (approve or reject)
    var decided: List[String]  # confirm calls answered (their ids)
    var asking: Bool  # an interrupt waits for the person's choice
    var question: String
    var options: List[String]
    var asked_after: Int  # the message count when it came (the card sits there)
    var chosen: String  # the last interrupt's answer ("" none)

    def __init__(out self, url: String, base: Int = 20_000, canvas_base: Int = 2000, layout: Int = CHAT_PANEL,
                 title: String = "Assistant", welcome: String = "Ask me anything.", show_url: Bool = False, offer_ui: Bool = True):
        self.http = Http()
        self.base = base
        self.agent = Agent(url, base + C_PIECE, base + C_ENDED, "agentchat")
        self.screens = Screens[Self.H](base + C_SCREENS, canvas_base, MAX_UIS)
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
        self.unfolded = List[String]()
        self.show_url = show_url
        self.confirm_tools = List[String]()
        self.decided = List[String]()
        self.asking = False
        self.question = ""
        self.options = List[String]()
        self.asked_after = 0
        self.chosen = ""
        if offer_ui:  # (an app that describes the tool its own way offers it itself: RENDER_UI_ABOUT, mojoui.genui.schema())
            self.agent.offer(Tool("render_ui", RENDER_UI_ABOUT, schema()))

    def set_hub(mut self, var hub: Self.H):
        """The datasets the agent's UI can name (DataGrid / ChartView "dataset": mojoui.datahub): their rows stay here,
        never sent. The agent hears of them in each run's context (names, rows, columns)."""
        self.screens.hub = hub^
        self.agent.context = ('[{"description":"Datasets the app holds. Show one with render_ui: a DataGrid with \\"dataset\\", or a ChartView with \\"dataset\\", \\"group_by\\" (a text column), \\"value\\" (a number column) and \\"combine\\" (sum, average, count). Never send their rows.","value":'
                              + json_string(self.screens.hub.describe()) + "}]")

    def feed(mut self, events: List[String]):
        """AG-UI events from an agent in this process (mojoui.agui's LocalAgent), through the same handler a stream's
        pieces go through, then the run's end."""
        for ref ev in events:
            _ = self.update(Event(self.base + C_PIECE, ev, 0))
        _ = self.update(Event(self.base + C_ENDED, "", 200))

    def run_local[L: LocalAgent](mut self, mut local: L):
        """A run with an agent in this process: no HTTP; its events go through update() as a stream's would."""
        var events = local.respond(self.agent.local_input())
        self.feed(events)

    def suggest(mut self, text: String):
        """A suggestion chip the chat offers (the first 20)."""
        if len(self.suggestions) < 20:
            self.suggestions.append(text)

    def offer(mut self, var tool: Tool, confirm: Bool = False):
        """A frontend tool; with `confirm` the person approves or rejects each call first: nothing runs until they do,
        and the answer is the call's result ({"decision": "approved" | "rejected", "arguments": …})."""
        if confirm:
            self.confirm_tools.append(tool.name)
        self.agent.offer(tool^)

    def asks_first(self, name: String) -> Bool:
        for t in self.confirm_tools:
            if t == name:
                return True
        return False

    def call_at(self, k: Int) -> Tuple[Int, Int]:
        """The k-th tool call in the conversation (message, call)."""
        var n = 0
        for i in range(len(self.agent.messages)):
            for j in range(len(self.agent.messages[i].calls)):
                if n == k:
                    return (i, j)
                n += 1
        return (-1, -1)

    def call_index(self, id: String) -> Int:
        var n = 0
        for ref m in self.agent.messages:
            for ref c in m.calls:
                if c.id == id:
                    return n
                n += 1
        return -1

    def decide(mut self, k: Int, approve: Bool):
        """The person's answer to the k-th call (a confirm tool's): its result, then the agent runs on."""
        var at = self.call_at(k)
        if at[0] < 0:
            return
        var c = self.agent.messages[at[0]].calls[at[1]].copy()
        if not c.done or self.agent.answered(c.id) or not self.asks_first(c.name):
            return
        self.agent.answer(c.id, '{"decision":"' + ("approved" if approve else "rejected") + '","arguments":' + (c.arguments if c.arguments.byte_length() > 0 else String("{}")) + "}")
        self.decided.append(c.id)
        self.run()

    def choose(mut self, k: Int):
        """The person picks an interrupt's option k: the run resumes with it."""
        if not self.asking or k < 0 or k >= len(self.options) or self.agent.running:
            return
        self.asking = False
        self.chosen = self.options[k]
        self.agent.resume(json_string(self.chosen))
        self.run()

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
        for c in self.agent.pending():  # (UI nobody used: the agent hears it was shown; a question nobody answered, that it was dismissed)
            self.agent.answer(c.id, '{"decision":"dismissed"}' if self.asks_first(c.name) else '{"shown":true}')
        self.asking = False
        self.agent.say(text)
        self.screens.reset()
        self.agent_suggestions = List[String]()
        self.draft = ""
        self.run()

    def ask(mut self, value_json: String):
        """An interrupt (CUSTOM "interrupt", or LangGraph's "on_interrupt"): its question and options. The value may be
        {"question" | "message": text, "options": [text…]} or a bare text (options: Approve, Reject)."""
        self.question = "The agent needs your answer"
        self.options = List[String]()
        try:
            var j = Json.parse(value_json)
            if j.kind(0) == J_STRING:
                self.question = j.text(0)
            else:
                var q = j.get(0, "question")
                if q < 0:
                    q = j.get(0, "message")
                if q >= 0 and j.kind(q) == J_STRING:
                    self.question = j.text(q)
                var o = j.get(0, "options")
                for i in range(min(j.size(o), 8)):
                    if j.kind(j.at(o, i)) == J_STRING and j.text(j.at(o, i)).byte_length() <= 60:
                        self.options.append(j.text(j.at(o, i)))
        except:
            pass
        if self.question.byte_length() > 500:
            var short = cut(self.question, 500)
            self.question = short^
        if len(self.options) == 0:
            self.options.append("Approve")
            self.options.append("Reject")
        self.asking = True
        self.chosen = ""
        self.asked_after = len(self.agent.messages)

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
        elif k >= C_INTERRUPT and k < C_INTERRUPT + 8:
            self.choose(k - C_INTERRUPT)
        elif k >= C_DECIDE and k < C_DECIDE + 3000:
            self.decide((k - C_DECIDE) // 2, (k - C_DECIDE) % 2 == 0)
        elif k >= C_SUGGEST and k < C_SUGGEST + 20:
            var list = self.agent_suggestions.copy() if len(self.agent_suggestions) > 0 else self.suggestions.copy()
            var at = k - C_SUGGEST
            if at < len(list):
                var text = list[at].copy()
                self.send(text)
        elif k >= C_THOUGHT and k < C_THOUGHT + 1000:
            var at = k - C_THOUGHT
            if at < len(self.agent.messages):
                var id = self.agent.messages[at].id.copy()
                var was = -1
                for j in range(len(self.unfolded)):
                    if self.unfolded[j] == id:
                        was = j
                if was >= 0:
                    _ = self.unfolded.pop(was)
                else:
                    self.unfolded.append(id^)
        elif k >= C_COPY and k < C_COPY + 1000:
            var at = k - C_COPY
            if at < len(self.agent.messages):
                self.copy_text = self.agent.messages[at].content
                self.copies += 1
                self.copied = at
        elif k >= C_CODE and k < C_CODE + 4000:
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
            if self.agent.closed_call and what != EV_TOOL_END and self.screens.take(self.agent):  # (a call sent as chunks ended)
                self.again = True
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
            elif what == EV_CUSTOM and (self.agent.custom_name == "interrupt" or self.agent.custom_name == "on_interrupt"):
                var value = self.agent.custom_value.copy()
                self.ask(value)
            elif what == EV_CUSTOM and self.agent.custom_name == "suggestions":
                self.agent_suggestions = List[String]()
                try:
                    var j = Json.parse(self.agent.custom_value)
                    for i in range(min(j.size(0), 6)):
                        if j.kind(j.at(0, i)) == J_STRING and j.text(j.at(0, i)).byte_length() <= 120:
                            self.agent_suggestions.append(j.text(j.at(0, i)))
                except:
                    pass
            elif what == EV_STREAM_END:
                self.screens.unfinished(self.agent)  # (a screen still streaming when the run stopped: never finished)
                if self.again and not self.stopped:
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
                head.append(CodeBlock(s.text, self.base + C_CODE + i * 8 + min(block, 7) if i < 500 else NO_MSG, 0, False))
                parts.append(VStack(head^, spacing=SPACE_XS).align(START).fill())
                block += 1
            else:
                parts.append(Markdown(s.text, tag="markdown", tables=True))
        var tools = List[View]()
        var plain = List[ToolCall]()  # (the agent's own tools: three or more fold into one card)
        for ref c in m.calls:
            if c.name == "render_ui" and self.screens.known(c.id):
                continue
            if self.asks_first(c.name):
                tools.append(self.confirm_card(c))
                continue
            plain.append(c.copy())
        if len(plain) >= 3:
            tools.append(self.tools_card(plain))
        else:
            for ref c in plain:
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
            if i < 1000:
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
        var head = HStack(Icon("wrench", 14),  # (one icon: the chip says the stage; a host may not swap an icon in place)
                          Text(c.name if c.name != "render_ui" else String("building UI"), style=CAPTION).tone(TONE_STRONG), Spacer(),
                          Chip(st, 2 if st == "complete" else (1 if st == "executing" else 0)), spacing=SPACE_XS).align(CENTER).fill()
        var rows = List[View]()
        rows.append(head^)
        var args = cut(c.arguments, 137)
        if args.byte_length() > 0 and args != "{}":
            rows.append(Text(args, style=CAPTION).tag("chat-tool-args"))
        var result = self.result_of(c.id)
        if result.byte_length() > 0:
            rows.append(Text("→ " + cut(result, 137), style=CAPTION))
        return Card(rows^, spacing=SPACE_XS).fill().tag("chat-tool")

    def tools_card(self, calls: List[ToolCall]) -> View:
        """Several tool calls in a row as one card: "Used 3 tools · web_search ×3", then a line each with its stage."""
        var names = List[String]()
        var counts = List[Int]()
        var running = 0
        for ref c in calls:
            if status_of(c, self.agent.answered(c.id)) != "complete":
                running += 1
            var found = False
            for k in range(len(names)):
                if names[k] == c.name:
                    counts[k] += 1
                    found = True
            if not found:
                names.append(c.name)
                counts.append(1)
        var what = String("")
        for k in range(len(names)):
            what += (", " if k > 0 else "") + names[k] + (" ×" + String(counts[k]) if counts[k] > 1 else String(""))
        var rows = List[View]()
        rows.append(HStack(Icon("wrench", 14), Text(("Using " if running > 0 else "Used ") + String(len(calls)) + " tools", style=CAPTION).tone(TONE_STRONG),
                           Text(what, style=CAPTION), Spacer(), Chip("complete" if running == 0 else String(running) + " running", 2 if running == 0 else 1),
                           spacing=SPACE_XS).align(CENTER).fill())
        for ref c in calls:
            var st = status_of(c, self.agent.answered(c.id))
            var args = cut(c.arguments, 87)
            rows.append(HStack(Text(c.name, style=CAPTION).tone(TONE_STRONG), Text(args, style=CAPTION).tag("chat-tool-args"), Spacer(),
                               Text(st, style=CAPTION).tone(TONE_GOOD if st == "complete" else TONE_NONE), spacing=SPACE_S).align(CENTER).fill())
        return Card(rows^, spacing=SPACE_XS).fill().tag("chat-tool")

    def confirm_card(self, c: ToolCall) -> View:
        """A confirm tool's call: what it will do (its name and arguments), Approve and Reject; once answered, which."""
        var rows = List[View]()
        var title = String("")
        for t in self.agent.tools:
            if t.name == c.name:
                title = t.description
        rows.append(HStack(Icon("circle-alert", 16), Text(title if title.byte_length() > 0 else c.name, style=HEADLINE), spacing=SPACE_S).align(CENTER))
        try:
            var j = Json.parse(c.arguments if c.arguments.byte_length() > 0 else String("{}"))
            var facts = List[View]()
            for i in range(min(len(j.keys[0]), 8)):
                var v = j.kids[0][i]
                var shown = j.text(v) if j.kind(v) == J_STRING else (String(j.number(v)) if j.is_whole(v) else String(j.real(v)))
                facts.append(HStack(Text(j.keys[0][i], style=CAPTION).width(120), Text(shown).tone(TONE_STRONG), spacing=SPACE_S).align(CENTER))
            if len(facts) > 0:
                rows.append(VStack(facts^, spacing=SPACE_XS).align(START))
        except:
            pass  # (arguments still streaming)
        var k = self.call_index(c.id)
        var answer = self.result_of(c.id)
        if answer.byte_length() > 0:
            var yes = answer.find('"approved"') >= 0
            rows.append(HStack(Spacer(), Chip("Approved" if yes else ("Rejected" if answer.find('"rejected"') >= 0 else "Dismissed"), 2 if yes else 0), spacing=0).fill())
        elif c.done:
            rows.append(HStack(Spacer(), Button("Reject", self.base + C_DECIDE + k * 2 + 1, style=PLAIN, icon="x"),
                               Button("Approve", self.base + C_DECIDE + k * 2, style=PROMINENT, icon="check"), spacing=SPACE_S).fill())
        return Card(rows^, spacing=SPACE_M).fill().tag("chat-confirm")

    def interrupt_card(self) -> View:
        var buttons = List[View]()
        buttons.append(Spacer())
        for k in range(len(self.options)):
            buttons.append(Button(self.options[k], self.base + C_INTERRUPT + k, style=PROMINENT if k == 0 else PLAIN))
        return Card(HStack(Icon("circle-alert", 16), Text(self.question, style=HEADLINE), spacing=SPACE_S).align(CENTER),
                    HStack(buttons^, spacing=SPACE_S).fill(), spacing=SPACE_M).fill().tag("chat-interrupt")

    def steps_view(self) -> View:
        """The run's steps (STEP_STARTED / STEP_FINISHED) as a live progress list."""
        var stages = List[Stage]()
        for k in range(len(self.agent.steps)):
            stages.append(Stage(self.agent.steps[k], STAGE_DONE if self.agent.steps_done[k] else STAGE_RUNNING, -1, ""))
        return Timeline(stages)

    def reasoning_view(self, i: Int) -> View:
        """The model's thinking: while it's being written, "Thinking…" over its newest words; then a folded "Thought"
        that opens to all of it."""
        ref m = self.agent.messages[i]
        if self.agent.running and self.agent.reasoning_open == m.id:
            return VStack(HStack(Icon("brain", 14), Text("Thinking…", style=CAPTION).tone(TONE_STRONG), spacing=SPACE_XS).align(CENTER),
                          Text(tail(m.content, 160), style=CAPTION).tag("chat-reasoning-live"), spacing=SPACE_XS).align(START).fill().tag("chat-reasoning")
        var open = False
        for ref id in self.unfolded:
            if id == m.id:
                open = True
        var body: List[View] = [Markdown(m.content, tag="markdown")]
        return Disclosure("Thought", open, self.base + C_THOUGHT + i if i < 1000 else NO_MSG, body^)

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
            elif m.role == "reasoning":
                if m.content.byte_length() > 0:
                    items.append(self.reasoning_view(i).arrive())
            elif m.role == "assistant":
                if m.content.byte_length() == 0 and len(m.calls) == 0 and len(self.screens.of_message(m.id)) == 0:
                    continue
                items.append(self.reply_view(i, i == last_reply).arrive())
            if i == self.asked_after - 1 and self.chosen.byte_length() > 0:  # (an interrupt answered: what was chosen, where it was asked)
                items.append(HStack(Spacer(), Chip("You chose " + self.chosen, 1), spacing=0).fill())
        var waiting = self.agent.running  # (until the agent has said or started something since the question)
        for i in range(self.last_user() + 1, n):
            ref m = self.agent.messages[i]
            if (m.role == "assistant" or m.role == "reasoning") and (m.content.byte_length() > 0 or len(m.calls) > 0):
                waiting = False
        if waiting:
            items.append(self.thinking().arrive())
        if self.asking:
            items.append(self.interrupt_card().arrive())
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
        if self.show_url:  # (a developer's chat: how the stream is going)
            var status = ("thinking… " + self.agent.step) if self.agent.running else ("ready" if self.agent.ended == "open" or self.agent.ended == "finished" else self.agent.ended)
            parts.append(Text("streamed: " + String(self.pieces) + " pieces · " + status, style=CAPTION).tag("chat-status"))
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
