# mojoui.agui: an AG-UI client (goal 35 M1, docs/agui.md). AG-UI (docs.ag-ui.com) is an open event protocol between an
# agent backend and a UI: the app POSTs a RunAgentInput (thread, run, messages, state, tools) and reads the run as
# server-sent events: RUN_*, TEXT_MESSAGE_*, TOOL_CALL_*, STATE_SNAPSHOT / STATE_DELTA (JSON Patch), MESSAGES_SNAPSHOT,
# STEP_*, CUSTOM. The Agent keeps the conversation and the shared state; tools the app offers are "frontend tools": the
# agent calls them, the app answers (answer()), and the answer goes back in the next run.
#
#   var agent = Agent("http://127.0.0.1:8765/", PIECE, END)    # PIECE / END: the app's messages for the stream
#   agent.offer(Tool("render_ui", "Show UI", schema()))
#   agent.say("Show me sales")                                  # a user message
#   agent.run(self.http)                                        # POSTs the run (mojoui.http, streamed)
#   ...update(e): if e.message == PIECE or e.message == END: var what = agent.handle(e)   # EV_TEXT, EV_TOOL_END, …
#   for c in agent.pending(): ... agent.answer(c.id, '{"action": "submit"}'); agent.run(self.http)
#
# Everything from the agent is data: JSON read with mojoui.json, never run.

from mojoui.app import Event
from mojoui.http import Http, Request, SseReader
from mojoui.json import Json, json_string, J_STRING, J_ARRAY, J_OBJECT
from mojoui.jsonpatch import JDoc

# what handle() saw (one per AG-UI event; EV_OTHER for types this client only counts: REASONING_*, RAW, ACTIVITY_*, …)
comptime EV_NONE = 0
comptime EV_RUN_STARTED = 1
comptime EV_RUN_FINISHED = 2
comptime EV_RUN_ERROR = 3
comptime EV_TEXT_START = 4
comptime EV_TEXT = 5
comptime EV_TEXT_END = 6
comptime EV_TOOL_START = 7
comptime EV_TOOL_ARGS = 8
comptime EV_TOOL_END = 9
comptime EV_TOOL_RESULT = 10
comptime EV_STATE = 11  # a snapshot or a delta changed the state
comptime EV_STATE_REFUSED = 12  # a delta that didn't apply (the state is as it was; state_error says why)
comptime EV_MESSAGES = 13
comptime EV_STEP = 14
comptime EV_CUSTOM = 15
comptime EV_OTHER = 16
comptime EV_BAD = 17  # not an AG-UI event (not JSON, no type)
comptime EV_STREAM_END = 18  # the HTTP stream ended (ended says how the run went)

comptime MAX_MESSAGES = 2000
comptime MAX_TEXT = 1024 * 1024  # one message's words (D-718): deltas past it are refused
comptime MAX_ARGS = 32_768  # one tool call's arguments: past it the call is marked too_big and its arguments dropped
comptime MAX_TYPES = 64  # event types counted by name (the rest under "OTHER")
comptime MAX_INPUT_BYTES = 6 * 1024 * 1024  # the most a RunAgentInput may be (D-724): the state (≤ 4 MB, mojoui.jsonpatch)
# plus the newest messages that fit, oldest left out first (`trimmed` says how many). scripts/agui_agent.py accepts up to
# 8 MB (its MAX_BODY), so a run never meets a 413; tests/test_agui_agent.py checks the two numbers agree.


@fieldwise_init
struct Tool(Copyable, Movable):
    """A frontend tool the app offers: its name, what it does, its parameters as a JSON Schema (text)."""

    var name: String
    var description: String
    var parameters: String


@fieldwise_init
struct ToolCall(Copyable, Movable):
    var id: String
    var name: String
    var arguments: String  # JSON text, as streamed (whole once done)
    var done: Bool
    var too_big: Bool  # its arguments ran past MAX_ARGS: dropped (answer it with an error)


@fieldwise_init
struct Message(Copyable, Movable):
    var id: String
    var role: String  # user, assistant, tool, system, developer, …
    var content: String
    var calls: List[ToolCall]
    var tool_call_id: String  # a tool message: the call it answers


def content_text(j: Json, n: Int) -> String:
    """A message's content: a string, or the text parts of a list of content parts."""
    if j.kind(n) == J_STRING:
        return j.text(n)
    var out = String("")
    if j.kind(n) == J_ARRAY:
        for i in range(j.size(n)):
            var p = j.at(n, i)
            if j.text(j.get(p, "type")) == "text":
                out += j.text(j.get(p, "text"))
    return out


struct Agent(Movable):
    var url: String
    var piece_msg: Int
    var end_msg: Int
    var thread_id: String
    var run_id: String
    var runs: Int
    var tag: Int  # the stream's request id (Http.cancel)
    var running: Bool
    var ended: String  # "open", "finished" or "error: …" (the last run)
    var messages: List[Message]
    var state: JDoc
    var state_error: String
    var tools: List[Tool]
    var step: String  # the step running ("" none)
    var custom_name: String  # the last CUSTOM event
    var custom_value: String
    var type_names: List[String]  # every event type seen, and how often
    var type_counts: List[Int]
    var reader: SseReader
    var last_type: String
    var last_message: String  # the id of the message the last event touched
    var problem: String  # why the last event was refused (EV_BAD)
    var trimmed: Int  # the oldest messages the last RunAgentInput left out to fit MAX_INPUT_BYTES

    def __init__(out self, url: String, piece_msg: Int, end_msg: Int, thread_id: String = "thread-1", tag: Int = 3500):
        self.url = url
        self.piece_msg = piece_msg
        self.end_msg = end_msg
        self.thread_id = thread_id
        self.run_id = ""
        self.runs = 0
        self.tag = tag
        self.running = False
        self.ended = "open"
        self.messages = List[Message]()
        self.state = JDoc()
        self.state_error = ""
        self.tools = List[Tool]()
        self.step = ""
        self.custom_name = ""
        self.custom_value = ""
        self.type_names = List[String]()
        self.type_counts = List[Int]()
        self.reader = SseReader()
        self.last_type = ""
        self.last_message = ""
        self.problem = ""
        self.trimmed = 0

    # ---- the app's side ----

    def offer(mut self, var tool: Tool):
        self.tools.append(tool^)

    def say(mut self, text: String):
        """A user message (sent with the next run)."""
        self.messages.append(Message("u" + String(len(self.messages) + 1), "user", text, List[ToolCall](), ""))

    def offered(self, name: String) -> Bool:
        for t in self.tools:
            if t.name == name:
                return True
        return False

    def answered(self, call_id: String) -> Bool:
        for m in self.messages:
            if m.role == "tool" and m.tool_call_id == call_id:
                return True
        return False

    def pending(self) -> List[ToolCall]:
        """Frontend tool calls (tools the app offered) the agent finished and nobody answered yet."""
        var out = List[ToolCall]()
        for m in self.messages:
            for c in m.calls:
                if c.done and self.offered(c.name) and not self.answered(c.id):
                    out.append(c.copy())
        return out^

    def answer(mut self, call_id: String, content: String):
        """The app's result for a frontend tool call (a tool message, sent with the next run)."""
        if self.answered(call_id):
            return
        self.messages.append(Message("tool-" + call_id, "tool", content, List[ToolCall](), call_id))

    def set_state(mut self, pointer: String, value_json: String) -> Bool:
        """The app edits the shared state (the agent sees it with the next run). False: not a pointer or not JSON."""
        try:
            self.state.set(pointer, value_json)
            return True
        except:
            return False

    def message_json(self, i: Int) -> String:
        ref m = self.messages[i]
        var one = '{"id":' + json_string(m.id) + ',"role":' + json_string(m.role) + ',"content":' + json_string(m.content)
        if len(m.calls) > 0:
            one += ',"toolCalls":['
            for k in range(len(m.calls)):
                ref c = m.calls[k]
                one += ("," if k > 0 else "") + '{"id":' + json_string(c.id) + ',"type":"function","function":{"name":' + json_string(c.name) + ',"arguments":' + json_string(c.arguments) + "}}"
            one += "]"
        if m.tool_call_id.byte_length() > 0:
            one += ',"toolCallId":' + json_string(m.tool_call_id)
        return one + "}"

    def input_json(mut self) -> String:
        """The next RunAgentInput: thread, run, state, tools, and the newest messages that fit MAX_INPUT_BYTES (the oldest
        are left out first, never a tool result without the call before it; `trimmed` counts them)."""
        var tools = String("[")
        for i in range(len(self.tools)):
            tools += ("," if i > 0 else "") + '{"name":' + json_string(self.tools[i].name) + ',"description":' + json_string(self.tools[i].description) + ',"parameters":' + self.tools[i].parameters + "}"
        tools += "]"
        var head = ('{"threadId":' + json_string(self.thread_id) + ',"runId":' + json_string(self.run_id) + ',"state":' + self.state.dump()
                    + ',"tools":' + tools + ',"context":[],"forwardedProps":{},"messages":[')
        var room = MAX_INPUT_BYTES - head.byte_length() - 2
        var parts = List[String]()
        var used = 0
        var start = len(self.messages)
        while start > 0:
            var one = self.message_json(start - 1)
            if used + one.byte_length() + 1 > room:
                break
            used += one.byte_length() + 1
            parts.append(one^)
            start -= 1
        while start < len(self.messages) and self.messages[start].role == "tool":  # (its call was left out)
            _ = parts.pop()
            start += 1
        self.trimmed = start
        var msgs = String("")
        for k in range(len(parts) - 1, -1, -1):
            msgs += ("," if k < len(parts) - 1 else "") + parts[k]
        return head + msgs + "]}"

    def run(mut self, mut http: Http) -> Bool:
        """Starts a run (POST RunAgentInput, the events streamed back to update()). False while one runs."""
        if self.running:
            return False
        self.runs += 1
        self.run_id = self.thread_id + "-run" + String(self.runs)
        self.running = True
        self.ended = "open"
        http.send(Request.post_json(self.piece_msg, self.url, self.input_json()).header("Accept", "text/event-stream")
                  .stream(self.end_msg).tagged(self.tag).timeout(120_000))
        return True

    def stop(mut self, mut http: Http):
        """Cancels the run in progress (its stream ends with "cancelled")."""
        if self.running:
            http.cancel(self.tag)

    def handle(mut self, e: Event) -> Int:
        """A piece or the end of the run's stream (the app's two messages); what happened (EV_*)."""
        if e.message == self.end_msg:
            self.running = False
            if e.error != "":
                if self.ended == "open":
                    self.ended = "error: " + e.error
            elif e.number < 200 or e.number >= 300:
                self.ended = "error: the agent answered " + String(e.number) + (": " + e.text if e.text.byte_length() <= 300 else String(""))
            elif self.ended == "open":
                self.ended = "error: the stream ended without RUN_FINISHED"
            return EV_STREAM_END
        if e.message == self.piece_msg:
            return self.on_json(e.text)
        return EV_NONE

    def feed_sse(mut self, text: String) -> List[Int]:
        """A recorded stream's bytes (offline): each event's EV_* in order."""
        var out = List[Int]()
        var events = self.reader.feed(text.as_bytes())
        for ref ev in events:
            out.append(self.on_json(ev.data))
        return out^

    # ---- reading events ----

    def count(mut self, t: String):
        for i in range(len(self.type_names)):
            if self.type_names[i] == t:
                self.type_counts[i] += 1
                return
        if len(self.type_names) >= MAX_TYPES:
            self.count_other()
            return
        self.type_names.append(t)
        self.type_counts.append(1)

    def count_other(mut self):
        for i in range(len(self.type_names)):
            if self.type_names[i] == "OTHER":
                self.type_counts[i] += 1
                return
        self.type_names.append("OTHER")
        self.type_counts.append(1)

    def add_text(mut self, at: Int, delta: String) -> Int:
        if self.messages[at].content.byte_length() + delta.byte_length() > MAX_TEXT:
            self.problem = "a message longer than " + String(MAX_TEXT) + " bytes"
            return EV_BAD
        self.messages[at].content += delta
        return EV_TEXT

    def add_args(mut self, at: Int, k: Int, delta: String) -> Int:
        if self.messages[at].calls[k].too_big:
            self.problem = "tool call arguments longer than " + String(MAX_ARGS) + " bytes"
            return EV_BAD
        if self.messages[at].calls[k].arguments.byte_length() + delta.byte_length() > MAX_ARGS:
            self.messages[at].calls[k].arguments = ""
            self.messages[at].calls[k].too_big = True
            self.problem = "tool call arguments longer than " + String(MAX_ARGS) + " bytes"
            return EV_BAD
        self.messages[at].calls[k].arguments += delta
        return EV_TOOL_ARGS

    def find_message(self, id: String) -> Int:
        for i in range(len(self.messages) - 1, -1, -1):
            if self.messages[i].id == id:
                return i
        return -1

    def find_call(self, id: String) -> Tuple[Int, Int]:
        for i in range(len(self.messages) - 1, -1, -1):
            for k in range(len(self.messages[i].calls)):
                if self.messages[i].calls[k].id == id:
                    return (i, k)
        return (-1, -1)

    def add_message(mut self, var m: Message):
        self.messages.append(m^)
        while len(self.messages) > MAX_MESSAGES:
            _ = self.messages.pop(0)

    def start_call(mut self, id: String, name: String, parent: String) -> Int:
        if id.byte_length() == 0 or self.find_call(id)[0] >= 0:
            self.problem = "a tool call id that is empty or already used"
            return EV_BAD
        var at = self.find_message(parent) if parent.byte_length() > 0 else -1
        if at >= 0 and self.messages[at].role != "assistant":
            self.problem = "a tool call on a message that isn't the assistant's"
            return EV_BAD
        if at < 0 and self.find_message(id) >= 0:
            self.problem = "a tool call id that is a message's id"
            return EV_BAD
        if at < 0:
            self.add_message(Message(parent if parent.byte_length() > 0 else id, "assistant", "", List[ToolCall](), ""))
            at = len(self.messages) - 1
        self.messages[at].calls.append(ToolCall(id, name, "", False, False))
        self.last_message = self.messages[at].id
        return EV_TOOL_START

    def on_json(mut self, text: String) -> Int:
        """One AG-UI event (the JSON of an SSE event's data)."""
        var j: Json
        try:
            j = Json.parse(text)
        except:
            return EV_BAD
        if j.kind(0) != J_OBJECT or j.kind(j.get(0, "type")) != J_STRING:
            return EV_BAD
        var t = j.text(j.get(0, "type"))
        self.count(t)
        self.last_type = t
        if t == "RUN_STARTED":
            self.running = True
            self.ended = "open"
            return EV_RUN_STARTED
        if t == "RUN_FINISHED":
            self.ended = "finished"
            return EV_RUN_FINISHED
        if t == "RUN_ERROR":
            self.ended = "error: " + j.text(j.get(0, "message"), "(no message)")
            return EV_RUN_ERROR
        if t == "TEXT_MESSAGE_START" or t == "TEXT_MESSAGE_CHUNK" or t == "TEXT_MESSAGE_CONTENT":
            var id = j.text(j.get(0, "messageId"))
            var role = j.text(j.get(0, "role"), "assistant")
            if role != "assistant":  # (the agent speaks as itself: no forged "You" bubbles)
                self.problem = "a text message with the role " + json_string(role)
                return EV_BAD
            var at = self.find_message(id)
            if at >= 0 and self.messages[at].role != "assistant":
                self.problem = "a text message id that is another role's message"
                return EV_BAD
            if id.byte_length() == 0:
                self.problem = "a text message without its id"
                return EV_BAD
            if at < 0:
                self.add_message(Message(id, "assistant", "", List[ToolCall](), ""))
                at = len(self.messages) - 1
            self.last_message = id
            if t == "TEXT_MESSAGE_START":
                return EV_TEXT_START
            return self.add_text(at, j.text(j.get(0, "delta")))
        if t == "TEXT_MESSAGE_END":
            return EV_TEXT_END
        if t == "TOOL_CALL_START":
            return self.start_call(j.text(j.get(0, "toolCallId")), j.text(j.get(0, "toolCallName")), j.text(j.get(0, "parentMessageId")))
        if t == "TOOL_CALL_CHUNK":
            var id = j.text(j.get(0, "toolCallId"))
            var where = self.find_call(id)
            if where[0] < 0:
                if self.start_call(id, j.text(j.get(0, "toolCallName")), j.text(j.get(0, "parentMessageId"))) == EV_BAD:
                    return EV_BAD
                where = self.find_call(id)
            return self.add_args(where[0], where[1], j.text(j.get(0, "delta")))
        if t == "TOOL_CALL_ARGS" or t == "TOOL_CALL_END":
            var where = self.find_call(j.text(j.get(0, "toolCallId")))
            if where[0] < 0:
                return EV_OTHER
            if t == "TOOL_CALL_ARGS":
                return self.add_args(where[0], where[1], j.text(j.get(0, "delta")))
            self.messages[where[0]].calls[where[1]].done = True
            return EV_TOOL_END
        if t == "TOOL_CALL_RESULT":
            var mid = j.text(j.get(0, "messageId"))
            if mid.byte_length() == 0 or self.find_message(mid) >= 0:
                self.problem = "a tool result whose id is empty or already used"
                return EV_BAD
            var content = j.text(j.get(0, "content"))
            if content.byte_length() > MAX_TEXT:
                self.problem = "a tool result longer than " + String(MAX_TEXT) + " bytes"
                return EV_BAD
            self.add_message(Message(mid, "tool", content, List[ToolCall](), j.text(j.get(0, "toolCallId"))))
            self.last_message = mid
            return EV_TOOL_RESULT
        if t == "STATE_SNAPSHOT":
            if j.get(0, "snapshot") < 0:
                self.state_error = "a snapshot without its snapshot"
                return EV_STATE_REFUSED
            try:
                self.state = JDoc.of(j, j.get(0, "snapshot"))
            except err:
                self.state_error = String(err)
                return EV_STATE_REFUSED
            self.state_error = ""
            return EV_STATE
        if t == "STATE_DELTA":
            try:
                self.state.patch_at(j, j.get(0, "delta"))
                self.state_error = ""
                return EV_STATE
            except err:
                self.state_error = String(err)
                return EV_STATE_REFUSED
        if t == "MESSAGES_SNAPSHOT":
            var list = j.get(0, "messages")
            var fresh = List[Message]()
            for i in range(max(j.size(list) - MAX_MESSAGES, 0), j.size(list)):  # (the newest MAX_MESSAGES)
                var m = j.at(list, i)
                var calls = List[ToolCall]()
                var tc = j.get(m, "toolCalls")
                for k in range(j.size(tc)):
                    var c = j.at(tc, k)
                    var f = j.get(c, "function")
                    var args = j.text(j.get(f, "arguments"))
                    var big = args.byte_length() > MAX_ARGS
                    calls.append(ToolCall(j.text(j.get(c, "id")), j.text(j.get(f, "name")), String("") if big else args, True, big))
                var content = content_text(j, j.get(m, "content"))
                if content.byte_length() > MAX_TEXT:
                    content = "(too long to keep)"
                fresh.append(Message(j.text(j.get(m, "id")), j.text(j.get(m, "role")), content, calls^, j.text(j.get(m, "toolCallId"))))
            self.messages = fresh^
            return EV_MESSAGES
        if t == "STEP_STARTED":
            self.step = j.text(j.get(0, "stepName"))
            return EV_STEP
        if t == "STEP_FINISHED":
            self.step = ""
            return EV_STEP
        if t == "CUSTOM":
            self.custom_name = j.text(j.get(0, "name"))
            try:
                self.custom_value = JDoc.of(j, j.get(0, "value")).dump()
            except:
                self.custom_value = "null"
            return EV_CUSTOM
        return EV_OTHER

    # ---- reading what it holds ----

    def last_text(self, role: String = "assistant") -> String:
        for i in range(len(self.messages) - 1, -1, -1):
            if self.messages[i].role == role and self.messages[i].content.byte_length() > 0:
                return self.messages[i].content
        return ""

    def messages_json(self) -> String:
        """The conversation as JSON: [{id, role, content, toolCalls: [{id, name, arguments}], toolCallId}] (the last two
        only when present)."""
        var out = String("[")
        for i in range(len(self.messages)):
            ref m = self.messages[i]
            var one = '{"id":' + json_string(m.id) + ',"role":' + json_string(m.role) + ',"content":' + json_string(m.content)
            if len(m.calls) > 0:
                one += ',"toolCalls":['
                for k in range(len(m.calls)):
                    one += ("," if k > 0 else "") + '{"id":' + json_string(m.calls[k].id) + ',"name":' + json_string(m.calls[k].name) + ',"arguments":' + json_string(m.calls[k].arguments) + "}"
                one += "]"
            if m.tool_call_id.byte_length() > 0:
                one += ',"toolCallId":' + json_string(m.tool_call_id)
            out += ("," if i > 0 else "") + one + "}"
        return out + "]"

    def types_json(self) -> String:
        var out = String("{")
        for i in range(len(self.type_names)):
            out += ("," if i > 0 else "") + json_string(self.type_names[i]) + ":" + String(self.type_counts[i])
        return out + "}"
