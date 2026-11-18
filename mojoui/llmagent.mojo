# mojoui.llmagent: an AG-UI agent whose brain is the in-process LLM (goal 72 M3, D-7220…).
#
#   var agent = LlmAgent(Llm("models/Qwen3.8-27B-UD-Q4_K_M.gguf", gpu=1))
#   agent.add_function(ToolFn("get_time", "The time now.", '{"type":"object","properties":{}}', clock))   # a plain Mojo function
#   var events = agent.respond(input)          # LocalAgent: a whole run, blocking (Agent.run_local, AgentChat.feed)
#
# Non-blocking, the way an app drives it (update() polls when the LLM's wake byte arrives):
#   var out = agent.begin(input)               # RunAgentInput JSON in; RUN_STARTED… out (the model is already working)
#   out += agent.poll()                        # AG-UI events JSON since the last call, as the model produces them
#   for c in agent.take_calls(): agent.answer(c.id, result)     # the app's own controls, run by the app (see AppRunner)
#   agent.cancel()                             # barge-in: the run ends at the next decode step with RUN_FINISHED (result.cancelled)
#
# What a run says (docs/agui.md): RUN_STARTED, STATE_DELTA/SNAPSHOT (/agent: step, the tools used), then per model step
# TEXT_MESSAGE_START/CONTENT/END (the words as the model produces them; tool-call markup is never text, the thinking is
# left out), TOOL_CALL_START/ARGS/END/RESULT for each call, and RUN_FINISHED or RUN_ERROR. Up to `max_steps` model steps
# per run: a call's result goes back to the model, which answers or calls again.
#
# Its tools, one list for the model:
#  (a) the frontend tools the run's input offers. render_ui (the catalog, mojoui.genui) is shown in the run: validated, its
#      result {"shown": true} or the refusal's reason goes back to the model; the model sees a compact catalog, not the
#      30 KB JSON Schema. Any other frontend tool ends the run with its call (AG-UI: the client runs it, the answer comes
#      with the next run).
#  (b) the app's own controls (AppRunner: every Button, TextField and Toggle of the view, named as the agent host names
#      them, D-162): the agent asks, the app presses.
#  (c) plain Mojo functions registered with add_function: run inside the agent.
# The conversation (sequence 0 of the Llm) and its prompt cache live as long as the agent: a run adds only what's new (the
# input's messages whose ids the agent hasn't seen). `think` is fixed per agent (the cache breaks when it changes).
from std.ffi import external_call
from mojoui.agui import LocalAgent, Tool, ToolCall, content_text
from mojoui.app import App, Event
from mojoui.clock import now_ns
from mojoui.genui import catalog, validate, Spec, Prop, P_TEXT, P_ENUM, P_NUMBER, P_TEXTS, P_NUMBERS, P_ROWS, P_POINTER, P_WORD, P_CHILDREN, P_BOOL, P_POINTS, P_ITEMS
from mojoui.json import Json, json_string, J_ARRAY, J_OBJECT, J_STRING, J_NULL
from mojoui.llm import Llm, LlmEvent, TEXT, REASONING, TOOL_CALLS, DONE, ERROR
from mojoui.view import View, BUTTON, FIELD, TOGGLE, NO_MSG

comptime DEFAULT_SYSTEM = (
    "You are a voice assistant that runs privately on the user's own computer. Your words are spoken aloud, so answer like "
    "a person talking: short natural sentences, usually one to three, no markdown, no bullet lists, no emoji, numbers "
    "written the way they are said. If a tool can answer, use it instead of guessing, and never claim to have done "
    "something a tool did not report. When an answer has several facts to compare, show them on screen with render_ui "
    "(a card) and say only the gist; cards are seen, so never read a whole card aloud. To use one of the app's buttons, "
    "call the tool of that name. If you were interrupted, stop and listen."
)

comptime T_BUTTON = 0  # an app control: pressing it (its message)
comptime T_TEXT = 1  # a text field: `text` argument
comptime T_TOGGLE = 2  # a switch: `on` argument

comptime PH_IDLE = 0
comptime PH_MODEL = 1  # the model is producing a step
comptime PH_CALLS = 2  # the step's tool calls wait for answers

comptime RENDER_UI = "render_ui"


@fieldwise_init
struct AppTool(Copyable, Movable):
    """One of the app's controls as a tool: its name (the tag, else a slug of its words), what it does (its tooltip), the
    parameters (JSON Schema text) and what the app sends when it's called (the control's message)."""

    var name: String
    var description: String
    var parameters: String
    var msg: Int
    var kind: Int


@fieldwise_init
struct ToolFn(Copyable, Movable):
    """A plain Mojo function the model may call: it gets the call's arguments (JSON text) and returns its result (text)."""

    var name: String
    var description: String
    var parameters: String
    var call: def(String) thin -> String


trait ToolRunner(Movable):
    """What runs the app's controls for an agent: the tools there are now, and one call (its result, as text). AppRunner
    does it for any App; the agent asks tools() again after every call, since a press changes the screen."""

    def tools(self) -> List[AppTool]:
        ...

    def run_tool(mut self, name: String, args: String) -> String:
        ...


# ---------------------------------------------------------------------------------------------------------------------
# the app's controls as tools (D-162: the tag names the tool, the tooltip describes it, the message is the call)
# ---------------------------------------------------------------------------------------------------------------------

def slug(text: String) -> String:
    """Lower-case words joined by "-" (at most 48 letters): "Add milk" -> "add-milk"."""
    var out = String("")
    var dash = False
    for b in text.as_bytes():
        var c = Int(b)
        if c >= 65 and c <= 90:
            c += 32
        if (c >= 97 and c <= 122) or (c >= 48 and c <= 57):
            if dash and out.byte_length() > 0:
                out += "-"
            dash = False
            out += chr(c)
        else:
            dash = True
    var n = min(out.byte_length(), 48)
    while n > 0 and out.as_bytes()[n - 1] == 45:
        n -= 1
    return String(out[byte = :n])


def _unique(name: String, tools: List[AppTool]) -> String:
    var n = name
    var k = 2
    while True:
        var taken = False
        for ref t in tools:
            if t.name == n:
                taken = True
        if not taken:
            return n^
        n = name + "-" + String(k)
        k += 1


def view_tools(view: View) -> List[AppTool]:
    """The tools of a screen: each Button with a message (its other face too, View.alternate), TextField and Toggle, in
    the order they appear. Names: the view's tag, else a slug of its words; a repeat gets -2, -3…"""
    var out = List[AppTool]()
    for ref n in view.nodes:
        if n.kind == BUTTON and n.msg != NO_MSG:
            var name = _unique(n.name if n.name != "" else slug(n.text), out)
            if name == "":
                continue
            out.append(AppTool(name, n.tip if n.tip != "" else String('Button "') + n.text + '"', '{"type":"object","properties":{}}', n.msg, T_BUTTON))
            if len(n.options) > 0 and n.size != NO_MSG and n.options[0] != "":
                var other = _unique(slug(n.options[0]), out)
                out.append(AppTool(other, String('"') + n.options[0] + '": the other face of the "' + n.text + '" button', '{"type":"object","properties":{}}', n.size, T_BUTTON))
        elif n.kind == FIELD and n.msg != NO_MSG:
            var said = n.hint if n.hint != "" else n.text
            var name = _unique(n.name if n.name != "" else (slug(said) if slug(said) != "" else String("field")), out)
            out.append(AppTool(name, n.tip if n.tip != "" else String('Text field "') + said + '"',
                '{"type":"object","properties":{"text":{"type":"string","description":"the new contents"}},"required":["text"]}', n.msg, T_TEXT))
        elif n.kind == TOGGLE and n.msg != NO_MSG:
            var name = _unique(n.name if n.name != "" else slug(n.text), out)
            out.append(AppTool(name, (n.tip if n.tip != "" else String('Switch "') + n.text + '"') + " (now " + ("on" if n.value != 0 else "off") + ")",
                '{"type":"object","properties":{"on":{"type":"boolean","description":"true to turn it on"}},"required":["on"]}', n.msg, T_TOGGLE))
    return out^


def screen_text(view: View) -> String:
    """The words on a screen, joined with "; " (what a tool's result tells the agent changed), at most 600 bytes."""
    var out = String("")
    for ref n in view.nodes:
        if n.kind == 1 and n.text != "":  # TEXT
            out += (n.text if out == "" else "; " + n.text)
            if out.byte_length() > 600:
                break
    return out^


struct AppRunner[A: App](ToolRunner):
    """Any App as an agent's tools: its buttons, text fields and toggles (view_tools). A call becomes the event a person's
    tap would send, update() runs it, and the result says what is on screen now."""

    var app: Self.A

    def __init__(out self, var app: Self.A):
        self.app = app^

    def tools(self) -> List[AppTool]:
        return view_tools(self.app.view())

    def run_tool(mut self, name: String, args: String) -> String:
        for t in view_tools(self.app.view()):
            if t.name != name:
                continue
            if t.kind == T_BUTTON:
                self.app.update(Event(t.msg, "", 0))
            else:
                try:
                    var j = Json.parse(args)
                    if t.kind == T_TEXT:
                        if j.get(0, "text") < 0:
                            return '{"error":"' + name + ' needs \\"text\\""}'
                        self.app.update(Event(t.msg, j.text(j.get(0, "text")), 0))
                    else:
                        if j.get(0, "on") < 0:
                            return '{"error":"' + name + ' needs \\"on\\""}'
                        self.app.update(Event(t.msg, "", 1 if j.flag(j.get(0, "on")) else 0))
                except:
                    return '{"error":"the arguments aren\'t JSON"}'
            return '{"ok":true,"screen":' + json_string(screen_text(self.app.view())) + "}"
        var names = String("")
        for t in view_tools(self.app.view()):
            names += (t.name if names == "" else ", " + t.name)
        return '{"error":"no such tool: ' + name + '; there are: ' + names + '"}'


# ---------------------------------------------------------------------------------------------------------------------
# render_ui as the model sees it
# ---------------------------------------------------------------------------------------------------------------------

def _prop_text(p: Prop) -> String:
    var t = String("text")
    if p.kind == P_ENUM:
        t = String("")
        for c in p.choices:
            t += (c if t == "" else "|" + c)
    elif p.kind == P_NUMBER:
        t = "number " + String(p.low) + ".." + String(p.limit)
    elif p.kind == P_TEXTS:
        t = "[text]"
    elif p.kind == P_NUMBERS:
        t = "[number]"
    elif p.kind == P_ROWS:
        t = "[[cell]]"
    elif p.kind == P_POINTER:
        t = "state path"
    elif p.kind == P_WORD:
        t = "word"
    elif p.kind == P_CHILDREN:
        t = "[component]"
    elif p.kind == P_BOOL:
        t = "bool"
    elif p.kind == P_POINTS:
        t = "[[lat,lon]]"
    elif p.kind == P_ITEMS:
        t = "[{"
        var first = True
        for ref f in p.fields:
            t += ("" if first else ",") + f.name
            first = False
        t += "}]"
    return p.name + ("*" if p.required else "") + ":" + t


def compact_catalog() -> String:
    """The catalog (mojoui.genui) in the few lines a model needs to build a card: one line per component, its props with
    their kinds (* required). The validator still decides what is shown."""
    var out = String("")
    for ref spec in catalog():
        var line = spec.name + "(" + String("")
        var first = True
        for ref p in spec.props:
            line += ("" if first else ", ") + _prop_text(p)
            first = False
        out += line + ")\n"
    return out^


def render_ui_tool() -> Tool:
    """render_ui for the model: a card from the catalog. (Clients offer the full JSON Schema, docs/genui.schema.json; the
    agent shows the model this shorter form and validates with the real one.)"""
    var about = (
        "Show a card on the screen, built only from these components (data, never code). The user sees it; do not read it "
        "aloud. Arguments: {\"ui\": a component}; a component is {\"component\": Name, ...its props}; Card, VStack, HStack, "
        "Grid and Tabs hold \"children\": [components]. Components (* = required):\n" + compact_catalog()
    )
    return Tool(RENDER_UI, about, '{"type":"object","properties":{"ui":{"type":"object","description":"one component, with its children inside"}},"required":["ui"]}')


# ---------------------------------------------------------------------------------------------------------------------
# events
# ---------------------------------------------------------------------------------------------------------------------

def _ev(type: String, rest: String) -> String:
    return '{"type":"' + type + '"' + rest + "}"


def _add_tool(mut out: String, name: String, about: String, params: String):
    out += ("," if out != "" else "") + '{"type":"function","function":{"name":' + json_string(name) + ',"description":' + json_string(about) + ',"parameters":' + params + "}}"


def _unseen(seen: List[String], key: String) -> Bool:
    for s in seen:
        if s == key:
            return False
    return True


struct LlmAgent(LocalAgent, Movable):
    var llm: Llm
    var system: String
    var think: Bool
    var max_steps: Int
    var max_tokens: Int
    var temperature: Float64
    var functions: List[ToolFn]
    var app_tools: List[AppTool]
    var history: List[String]  # the conversation as OpenAI messages (sequence 0 of the Llm: its prompt cache follows it)
    var seen: List[String]  # message ids and tool-call ids already in the history
    var phase: Int
    var req_id: Int
    var thread_id: String
    var run_id: String
    var step: Int
    var tools_json: String
    var client_tools: List[String]  # frontend tool names other than render_ui: the client runs them
    var has_ui: Bool
    var text_id: String  # the open TEXT_MESSAGE (""  none)
    var text_acc: String  # the words of this model step
    var step_calls: List[ToolCall]
    var step_results: List[String]
    var step_state: List[Int]  # per call: 0 waiting for the app, 1 answered, 2 the client's (frontend), 3 handed to the app
    var model_calls: String  # TOOL_CALLS json waiting for DONE
    var outbox: List[String]
    var cancelled: Bool
    var t_begin: Int
    var first_text_ms: Float64  # begin() to the first TEXT_MESSAGE_CONTENT (-1: none yet)
    var used: Int  # tools called this run
    var runs: Int

    def __init__(out self, var llm: Llm, system: String = DEFAULT_SYSTEM, think: Bool = False, max_steps: Int = 5, max_tokens: Int = 512, temperature: Float64 = 0.3):
        self.llm = llm^
        self.system = system
        self.think = think
        self.max_steps = max_steps
        self.max_tokens = max_tokens
        self.temperature = temperature
        self.functions = List[ToolFn]()
        self.app_tools = List[AppTool]()
        self.history = List[String]()
        self.seen = List[String]()
        self.phase = PH_IDLE
        self.req_id = 0
        self.thread_id = String("")
        self.run_id = String("")
        self.step = 0
        self.tools_json = String("")
        self.client_tools = List[String]()
        self.has_ui = False
        self.text_id = String("")
        self.text_acc = String("")
        self.step_calls = List[ToolCall]()
        self.step_results = List[String]()
        self.step_state = List[Int]()
        self.model_calls = String("")
        self.outbox = List[String]()
        self.cancelled = False
        self.t_begin = 0
        self.first_text_ms = -1.0
        self.used = 0
        self.runs = 0

    def add_function(mut self, var f: ToolFn):
        """Registers a plain Mojo function as a tool (c)."""
        self.functions.append(f^)

    def set_tools(mut self, var tools: List[AppTool]):
        """The app's controls as tools now (b); give them before begin() and again after each answer(): a press changes the screen."""
        self.app_tools = tools^

    def running(self) -> Bool:
        return self.phase != PH_IDLE

    # --- a run ---------------------------------------------------------------------------------------------------

    def begin(mut self, input: String) -> List[String]:
        """Starts a run from a RunAgentInput (JSON): takes in the messages it hasn't seen, offers the model its tools, starts
        the model. Returns the events so far (RUN_STARTED, state, or RUN_ERROR when the run can't start)."""
        var out = List[String]()
        if self.phase != PH_IDLE:
            out.append(_ev("RUN_ERROR", ',"message":"a run is already in progress","code":"busy"'))
            return out^
        self.runs += 1
        self.t_begin = now_ns()
        self.first_text_ms = -1.0
        self.step = 0
        self.used = 0
        self.cancelled = False
        self.outbox = List[String]()
        self.text_id = String("")
        self.text_acc = String("")
        self.client_tools = List[String]()
        self.has_ui = False
        var state_is_object = False
        try:
            var j = Json.parse(input)
            self.thread_id = j.text(j.get(0, "threadId"), "thread")
            self.run_id = j.text(j.get(0, "runId"), "run" + String(self.runs))
            var st = j.get(0, "state")
            state_is_object = st >= 0 and j.kind(st) == J_OBJECT
            self.take_messages(j, j.get(0, "messages"))
            self.tools_json = self.build_tools(j, j.get(0, "tools"))
        except e:
            out.append(_ev("RUN_STARTED", ',"threadId":"thread","runId":"run' + String(self.runs) + '"'))
            out.append(_ev("RUN_ERROR", ',"message":' + json_string("the run's input isn't a RunAgentInput: " + String(e)) + ',"code":"bad_input"'))
            return out^
        out.append(_ev("RUN_STARTED", ',"threadId":' + json_string(self.thread_id) + ',"runId":' + json_string(self.run_id)))
        var agent_state = '{"step":0,"tools":[]}'
        if state_is_object:
            out.append(_ev("STATE_DELTA", ',"delta":[{"op":"add","path":"/agent","value":' + agent_state + "}]"))
        else:
            out.append(_ev("STATE_SNAPSHOT", ',"snapshot":{"agent":' + agent_state + "}"))
        self.start_step(out)
        return out^

    def take_messages(mut self, j: Json, ms: Int) raises:
        if ms < 0 or j.kind(ms) != J_ARRAY:
            return
        for i in range(j.size(ms)):
            var m = j.at(ms, i)
            var role = j.text(j.get(m, "role"))
            var id = j.text(j.get(m, "id"))
            if role == "tool":
                var cid = j.text(j.get(m, "toolCallId"))
                if _unseen(self.seen, "tool:" + cid):
                    self.seen.append("tool:" + cid)
                    self.history.append('{"role":"tool","tool_call_id":' + json_string(cid) + ',"content":' + json_string(content_text(j, j.get(m, "content"))) + "}")
            elif role == "user" or role == "assistant":
                if id != "" and not _unseen(self.seen, id):
                    continue
                if id != "":
                    self.seen.append(id)
                var content = content_text(j, j.get(m, "content"))
                var calls = j.get(m, "toolCalls")
                var msg = '{"role":' + json_string(role) + ',"content":' + json_string(content)
                if role == "assistant" and calls >= 0 and j.size(calls) > 0:
                    msg += ',"tool_calls":['
                    for k in range(j.size(calls)):
                        var c = j.at(calls, k)
                        var f = j.get(c, "function")
                        var cid = j.text(j.get(c, "id"))
                        self.seen.append("call:" + cid)
                        msg += ("," if k > 0 else "") + '{"id":' + json_string(cid) + ',"type":"function","function":{"name":' + json_string(j.text(j.get(f, "name"))) + ',"arguments":' + json_string(j.text(j.get(f, "arguments"), "{}")) + "}}"
                    msg += "]"
                self.history.append(msg + "}")
            # system / developer / reasoning / activity: not ours to replay (the agent's own system prompt leads every request)

    def build_tools(mut self, j: Json, ts: Int) raises -> String:
        var out = String("")
        if ts >= 0 and j.kind(ts) == J_ARRAY:
            for i in range(j.size(ts)):
                var t = j.at(ts, i)
                var name = j.text(j.get(t, "name"))
                if name == RENDER_UI:
                    var r = render_ui_tool()
                    _add_tool(out, r.name, r.description, r.parameters)
                    self.has_ui = True
                else:
                    var p = j.get(t, "parameters")
                    _add_tool(out, name, j.text(j.get(t, "description")), j.dump(p) if p >= 0 else String('{"type":"object","properties":{}}'))
                    self.client_tools.append(name)
        for ref t in self.app_tools:
            _add_tool(out, t.name, t.description, t.parameters)
        for ref f in self.functions:
            _add_tool(out, f.name, f.description, f.parameters)
        return ("[" + out + "]") if out != "" else String("")

    def start_step(mut self, mut out: List[String]):
        self.step += 1
        self.text_id = String("")
        self.text_acc = String("")
        self.model_calls = String("")
        var msgs = '[{"role":"system","content":' + json_string(self.system) + "}"
        for ref m in self.history:
            msgs += "," + m
        msgs += "]"
        try:
            self.req_id = self.llm.chat(msgs, self.tools_json, 0, self.think, self.max_tokens, self.temperature)
            self.phase = PH_MODEL
        except e:
            self.fail(out, String(e))

    def fail(mut self, mut out: List[String], why: String):
        self.close_text(out)
        out.append(_ev("RUN_ERROR", ',"message":' + json_string(why) + ',"code":"llm"'))
        self.phase = PH_IDLE

    def close_text(mut self, mut out: List[String]):
        if self.text_id != "":
            out.append(_ev("TEXT_MESSAGE_END", ',"messageId":' + json_string(self.text_id)))
            self.text_id = String("")

    def finish(mut self, mut out: List[String], result: String = ""):
        out.append(_ev("RUN_FINISHED", ',"threadId":' + json_string(self.thread_id) + ',"runId":' + json_string(self.run_id) + ((',"result":' + result) if result != "" else "")))
        self.phase = PH_IDLE

    def cancel(mut self):
        """Barge-in: stops the model at the next decode step; the next poll() ends the run (RUN_FINISHED, result
        {"cancelled": true}). The words said so far stay in the conversation, marked as interrupted."""
        if self.phase == PH_MODEL:
            self.cancelled = True
            self.llm.cancel(self.req_id)
        elif self.phase == PH_CALLS:
            self.cancelled = True

    # --- events out ----------------------------------------------------------------------------------------------

    def poll(mut self) -> List[String]:
        """The run's events since the last call (empty when none): the model's words as they come, the tool calls and
        their results, the end of the run. Call it whenever the LLM's wake byte arrives, or every few milliseconds."""
        var out = self.outbox.copy()
        self.outbox.clear()
        if self.phase == PH_MODEL:
            var evs = List[LlmEvent]()
            try:
                evs = self.llm.poll(self.req_id)
            except e:
                self.fail(out, String(e))
                return out^
            for ref e in evs:
                if e.kind == TEXT:
                    if e.text == "":
                        continue
                    if self.text_id == "":
                        self.text_id = "m-" + self.run_id + "-" + String(self.step)
                        out.append(_ev("TEXT_MESSAGE_START", ',"messageId":' + json_string(self.text_id) + ',"role":"assistant"'))
                    if self.first_text_ms < 0:
                        self.first_text_ms = Float64(now_ns() - self.t_begin) / 1e6
                    self.text_acc += e.text
                    out.append(_ev("TEXT_MESSAGE_CONTENT", ',"messageId":' + json_string(self.text_id) + ',"delta":' + json_string(e.text)))
                elif e.kind == TOOL_CALLS:
                    self.model_calls = e.text
                elif e.kind == ERROR:
                    self.fail(out, e.text)
                    return out^
                elif e.kind == DONE:
                    self.close_text(out)
                    self.model_done(out, e.text)
                    break
        elif self.phase == PH_CALLS:
            self.settle(out)
        return out^

    def model_done(mut self, mut out: List[String], reason: String):
        if self.cancelled or reason == "cancel":
            if self.text_acc != "":
                self.history.append('{"role":"assistant","content":' + json_string(self.text_acc + " [interrupted by the user]") + "}")
            self.finish(out, '{"cancelled":true}')
            return
        var msg_id = "m-" + self.run_id + "-" + String(self.step)
        if self.model_calls == "":
            self.history.append('{"role":"assistant","content":' + json_string(self.text_acc) + "}")
            self.finish(out)
            return
        self.step_calls = List[ToolCall]()
        self.step_results = List[String]()
        self.step_state = List[Int]()
        var assistant = '{"role":"assistant","content":' + json_string(self.text_acc) + ',"tool_calls":['
        try:
            var j = Json.parse(self.model_calls)
            for i in range(j.size(0)):
                var c = j.at(0, i)
                var id = j.text(j.get(c, "id"))
                if id == "":
                    id = "call-" + self.run_id + "-" + String(self.step) + "-" + String(i)
                var name = j.text(j.get(c, "name"))
                var args = j.text(j.get(c, "arguments"), "{}")
                if args == "":
                    args = "{}"
                self.step_calls.append(ToolCall(id, name, args, True, False))
                self.step_results.append(String(""))
                self.step_state.append(0)
                self.seen.append("call:" + id)
                assistant += ("," if i > 0 else "") + '{"id":' + json_string(id) + ',"type":"function","function":{"name":' + json_string(name) + ',"arguments":' + json_string(args) + "}}"
        except e:
            self.fail(out, "the model's tool call wasn't readable: " + String(e))
            return
        self.history.append(assistant + "]}")
        for i in range(len(self.step_calls)):
            var c = self.step_calls[i].copy()
            self.used += 1
            var parent = (',"parentMessageId":' + json_string(msg_id)) if self.text_acc != "" else String("")
            out.append(_ev("TOOL_CALL_START", ',"toolCallId":' + json_string(c.id) + ',"toolCallName":' + json_string(c.name) + parent))
            out.append(_ev("TOOL_CALL_ARGS", ',"toolCallId":' + json_string(c.id) + ',"delta":' + json_string(c.arguments)))
            out.append(_ev("TOOL_CALL_END", ',"toolCallId":' + json_string(c.id)))
            out.append(_ev("STATE_DELTA", ',"delta":[{"op":"replace","path":"/agent/step","value":' + String(self.step) + '},{"op":"add","path":"/agent/tools/-","value":' + json_string(c.name) + "}]"))
            self.route(out, i)
        self.phase = PH_CALLS
        self.settle(out)

    def route(mut self, mut out: List[String], i: Int):
        """Who answers call i: this agent (render_ui, a registered function, an unknown name) or the app or the client."""
        var c = self.step_calls[i].copy()
        if c.name == RENDER_UI and self.has_ui:
            var why = validate(c.arguments)
            out.append(self.answered(i, '{"shown":true}' if why == "" else '{"error":' + json_string("refused: " + why) + "}"))
            return
        for ref f in self.functions:
            if f.name == c.name:
                out.append(self.answered(i, f.call(c.arguments)))
                return
        for ref t in self.app_tools:
            if t.name == c.name:
                return  # (waits: the app runs it; take_calls hands it over)
        for ref n in self.client_tools:
            if n == c.name:
                self.step_state[i] = 2  # (the client runs it: the run ends with the call, its answer comes with the next run)
                return
        out.append(self.answered(i, '{"error":' + json_string("no such tool: " + c.name) + "}"))

    def answered(mut self, i: Int, content: String) -> String:
        self.step_results[i] = content
        self.step_state[i] = 1
        var c = self.step_calls[i].copy()
        return (_ev("TOOL_CALL_RESULT", ',"messageId":' + json_string("r-" + c.id) + ',"toolCallId":' + json_string(c.id) + ',"content":' + json_string(content) + ',"role":"tool"'))

    def take_calls(mut self) -> List[ToolCall]:
        """The app-control calls waiting for the app (each handed over once): run each, then answer() it."""
        var out = List[ToolCall]()
        if self.phase != PH_CALLS:
            return out^
        for i in range(len(self.step_calls)):
            if self.step_state[i] == 0:
                self.step_state[i] = 3
                out.append(self.step_calls[i].copy())
        return out^

    def answer(mut self, call_id: String, content: String):
        """The app's result for a call take_calls() handed over: it goes to the model and out as TOOL_CALL_RESULT."""
        for i in range(len(self.step_calls)):
            if self.step_calls[i].id == call_id and self.step_state[i] == 3:
                self.outbox.append(self.answered(i, content))

    def settle(mut self, mut out: List[String]):
        """All the step's calls answered (or left to the client): the next model step, or the end of the run."""
        for i in range(len(self.step_calls)):
            if self.step_state[i] == 0 or self.step_state[i] == 3:
                if self.cancelled:
                    self.step_results[i] = '{"error":"cancelled"}'
                    self.step_state[i] = 1
                else:
                    return
        for i in range(len(self.step_calls)):
            if self.step_state[i] == 1:
                self.history.append('{"role":"tool","tool_call_id":' + json_string(self.step_calls[i].id) + ',"content":' + json_string(self.step_results[i]) + "}")
                self.seen.append("tool:" + self.step_calls[i].id)
        var client_runs = False
        for i in range(len(self.step_calls)):
            if self.step_state[i] == 2:
                client_runs = True
        self.step_calls = List[ToolCall]()
        self.step_state = List[Int]()
        self.step_results = List[String]()
        if self.cancelled:
            self.finish(out, '{"cancelled":true}')
        elif client_runs:
            self.finish(out)  # (the client's tool calls end the run; it answers them in the next)
        elif self.step >= self.max_steps:
            var id = "m-" + self.run_id + "-stuck"
            out.append(_ev("TEXT_MESSAGE_START", ',"messageId":' + json_string(id) + ',"role":"assistant"'))
            out.append(_ev("TEXT_MESSAGE_CONTENT", ',"messageId":' + json_string(id) + ',"delta":"Sorry, I got stuck using my tools."'))
            out.append(_ev("TEXT_MESSAGE_END", ',"messageId":' + json_string(id)))
            self.history.append('{"role":"assistant","content":"Sorry, I got stuck using my tools."}')
            self.finish(out)
        else:
            self.start_step(out)

    # --- driving it ----------------------------------------------------------------------------------------------

    def step_with[R: ToolRunner](mut self, mut runner: R) -> List[String]:
        """One round of a run driven by a runner: run the app's waiting calls with `runner`, hand its answers on, poll."""
        for c in self.take_calls():
            var result = runner.run_tool(c.name, c.arguments)
            self.answer(c.id, result)
            self.set_tools(runner.tools())
        return self.poll()

    def run_with[R: ToolRunner](mut self, input: String, mut runner: R) -> List[String]:
        """A whole run, blocking: its events in order (the tests' and tools' way; an app or a server steps instead)."""
        self.set_tools(runner.tools())
        var out = self.begin(input)
        while self.phase != PH_IDLE:
            var evs = self.step_with(runner)
            if len(evs) == 0:
                _ = external_call["usleep", Int32](Int32(1000))
            for ref e in evs:
                out.append(e)
        return out^

    def respond(mut self, input: String) -> List[String]:
        """LocalAgent: a whole run with the registered functions and render_ui (no app controls: an app that has them
        steps with its own runner instead)."""
        var out = self.begin(input)
        while self.phase != PH_IDLE:
            var evs = self.poll()
            for c in self.take_calls():
                self.answer(c.id, '{"error":"no app is connected to run this tool"}')
            if len(evs) == 0:
                _ = external_call["usleep", Int32](Int32(1000))
            for ref e in evs:
                out.append(e)
        return out^
