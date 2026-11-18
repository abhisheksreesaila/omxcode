# mojoui.llmagent + mojoui.agentserve (goal 72 M3): the real Qwen3.8-27B, in this process, speaking AG-UI. Numbers go to
# build/g72/agent-bench.json (the in-process half; scripts/agui_llm_check.py adds the SSE half).
#   scripts/mojo_flare.sh build tests/test_llmagent.mojo -o build/test_llmagent
#   build/test_llmagent                    # the in-process cases
#   build/test_llmagent --serve            # ... then serve the agent (prints SERVING <port>) for scripts/agui_llm_check.py
# Environment: LLM_GGUF (default ~/Projects/omx-local/models/Qwen3.8-27B-UD-Q4_K_M.gguf), LLM_GPU (default 1: GPU 0 belongs
# to the prototype's llama-server).
from std.os import getenv, makedirs
from std.sys import argv
from std.testing import assert_equal, assert_true
from std.ffi import external_call
from mojoui.agui import Agent, EV_RUN_FINISHED, EV_TEXT, EV_TOOL_END
from mojoui.app import App, Event
from mojoui.clock import now_ns
from mojoui.genui import validate, schema
from mojoui.json import Json, json_string
from mojoui.llm import Llm
from mojoui.llmagent import LlmAgent, ToolFn, ToolRunner, AppRunner, AppTool, view_tools
from mojoui.agentserve import serve_llm_agent
from mojoui.view import View, VStack, HStack, Text, Button, TextField, CAPTION, PROMINENT, TITLE


def ms_since(t0: Int) -> Float64:
    return Float64(now_ns() - t0) / 1e6


def sleep_ms(ms: Int):
    _ = external_call["usleep", Int32](Int32(ms * 1000))


# ---- a tiny app: a shopping list with two buttons --------------------------------------------------------------------

comptime ADD_MILK = 1
comptime CLEAR = 2


struct Shopping(App):
    var items: List[String]

    def __init__(out self):
        self.items = List[String]()

    def title(self) -> String:
        return "Shopping"

    def update(mut self, event: Event):
        if event.message == ADD_MILK:
            self.items.append("milk")
        elif event.message == CLEAR:
            self.items.clear()

    def view(self) -> View:
        var list = String("Nothing on the list") if len(self.items) == 0 else String("On the list: ")
        for i in range(len(self.items)):
            list += (", " if i > 0 else "") + self.items[i]
        return VStack(
            Text("Shopping", style=TITLE),
            Text(list),
            HStack(
                Button("Add milk", on_tap=ADD_MILK, style=PROMINENT).tooltip("Put milk on the shopping list"),
                Button("Clear list", on_tap=CLEAR).tooltip("Take everything off the shopping list"),
            ),
        )


# ---- a plain Mojo function as a tool ---------------------------------------------------------------------------------

def secret_number(args: String) -> String:
    return '{"number": 4271}'


# ---- AG-UI event checks ----------------------------------------------------------------------------------------------

def run_input(thread: String, run: String, user: String, with_ui: Bool = True) -> String:
    var tools = String("[]")
    if with_ui:
        tools = '[{"name":"render_ui","description":"Show UI","parameters":' + schema() + "}]"
    return ('{"threadId":' + json_string(thread) + ',"runId":' + json_string(run) + ',"state":{},"messages":[{"id":"u-' + run
            + '","role":"user","content":' + json_string(user) + '}],"tools":' + tools + ',"context":[],"forwardedProps":{}}')


struct Events(Movable):
    """A run's events, parsed once, with the checks that make a stream valid AG-UI (order and pairing)."""

    var raw: List[String]
    var types: List[String]
    var text: String
    var ui_args: List[String]
    var tool_names: List[String]
    var tool_results: List[String]

    def __init__(out self, var raw: List[String]) raises:
        self.raw = raw^
        self.types = List[String]()
        self.text = String("")
        self.ui_args = List[String]()
        self.tool_names = List[String]()
        self.tool_results = List[String]()
        var open_text = String("")
        var open_call = String("")
        var call_state = List[String]()  # ids with their state: id=started|args|ended|result
        var args_of = List[String]()
        var ids = List[String]()
        var started = False
        var ended = False
        for ref r in self.raw:
            var j = Json.parse(r)
            var t = j.text(j.get(0, "type"))
            self.types.append(t)
            assert_true(not ended, "no event after the run ended: " + t)
            if not started:
                assert_equal(t, "RUN_STARTED")
                started = True
                continue
            if t == "TEXT_MESSAGE_START":
                assert_equal(open_text, "")
                open_text = j.text(j.get(0, "messageId"))
                assert_true(open_text != "" and j.text(j.get(0, "role")) == "assistant", "text start: " + r)
            elif t == "TEXT_MESSAGE_CONTENT":
                assert_equal(j.text(j.get(0, "messageId")), open_text)
                assert_true(j.text(j.get(0, "delta")) != "", "content has words: " + r)
                self.text += j.text(j.get(0, "delta"))
            elif t == "TEXT_MESSAGE_END":
                assert_equal(j.text(j.get(0, "messageId")), open_text)
                open_text = String("")
            elif t == "TOOL_CALL_START":
                assert_equal(open_text, "")  # (the words end before a call begins)
                var id = j.text(j.get(0, "toolCallId"))
                ids.append(id)
                args_of.append(String(""))
                call_state.append("started")
                self.tool_names.append(j.text(j.get(0, "toolCallName")))
                self.tool_results.append(String(""))
            elif t == "TOOL_CALL_ARGS":
                var k = self.index(ids, j.text(j.get(0, "toolCallId")))
                assert_equal(call_state[k], "started")
                args_of[k] += j.text(j.get(0, "delta"))
                call_state[k] = "args"
            elif t == "TOOL_CALL_END":
                var k = self.index(ids, j.text(j.get(0, "toolCallId")))
                assert_equal(call_state[k], "args")
                call_state[k] = "ended"
                if self.tool_names[k] == "render_ui":
                    self.ui_args.append(args_of[k])
            elif t == "TOOL_CALL_RESULT":
                var k = self.index(ids, j.text(j.get(0, "toolCallId")))
                assert_equal(call_state[k], "ended")
                call_state[k] = "result"
                self.tool_results[k] = j.text(j.get(0, "content"))
            elif t == "RUN_FINISHED" or t == "RUN_ERROR":
                ended = True
                assert_equal(open_text, "")
            else:
                assert_true(t == "STATE_DELTA" or t == "STATE_SNAPSHOT", "an event this agent doesn't send: " + t)
        assert_true(started and ended, "a run starts with RUN_STARTED and ends with RUN_FINISHED or RUN_ERROR")

    @staticmethod
    def index(ids: List[String], id: String) raises -> Int:
        for k in range(len(ids)):
            if ids[k] == id:
                return k
        raise Error("an event names a call that never started: " + id)

    def has(self, type: String) -> Bool:
        for ref t in self.types:
            if t == type:
                return True
        return False

    def called(self, name: String) -> Bool:
        for ref n in self.tool_names:
            if n == name:
                return True
        return False


def main() raises:
    var gguf = getenv("LLM_GGUF", getenv("HOME", "") + "/Projects/omx-local/models/Qwen3.8-27B-UD-Q4_K_M.gguf")
    var gpu = Int(getenv("LLM_GPU", "1"))
    var serve = False
    for i in range(1, len(argv())):
        if argv()[i] == "--serve":
            serve = True
    var t_load = now_ns()
    var agent = LlmAgent(Llm(gguf, gpu=gpu, n_ctx=32768, n_seq=2))
    print("agent: model loaded on GPU", gpu, "in", ms_since(t_load), "ms")
    agent.add_function(ToolFn("secret_number", "The secret number (only this tool knows it).", '{"type":"object","properties":{}}', secret_number))
    var runner = AppRunner[Shopping](Shopping())

    # 0. the app's buttons are the agent's tools, named as the agent host names them (D-162)
    var tools = view_tools(runner.app.view())
    assert_equal(len(tools), 2)
    assert_equal(tools[0].name, "add-milk")
    assert_equal(tools[0].description, "Put milk on the shopping list")
    assert_equal(tools[0].msg, ADD_MILK)
    assert_equal(tools[1].name, "clear-list")
    print("agent tools: ok", tools[0].name, "|", tools[1].name)

    # 1. a question that should produce a card: events in AG-UI order, render_ui validated against the catalog, a spoken line
    var t0 = now_ns()
    var card = Events(agent.run_with(run_input("t-card", "r1", "Compare Lisbon and Porto for a weekend trip: population, one famous food each. Show it as a card on screen, and just say the gist."), runner))
    var card_ms = ms_since(t0)
    assert_equal(card.types[len(card.types) - 1], "RUN_FINISHED")
    assert_true(card.called("render_ui"), "the model made a card; it called " + String(len(card.tool_names)) + " tools and said: " + card.text)
    assert_true(len(card.ui_args) >= 1, "render_ui's arguments were streamed")
    for ref a in card.ui_args:
        assert_equal(validate(a), "")
    var shown = False
    for ref r in card.tool_results:
        if r == '{"shown":true}':
            shown = True
    assert_true(shown, "a render_ui call was shown: " + String(len(card.tool_results)))
    assert_true(card.text.byte_length() > 0 and card.text.byte_length() <= 400, "a short spoken line: " + card.text)
    assert_true(card.text.find("*") < 0 and card.text.find("#") < 0 and card.text.find("<tool_call>") < 0 and card.text.find("<function") < 0, "no markdown or tool markup in the words: " + card.text)
    print("agent card: ok", len(card.raw), "events,", card_ms, "ms | said:", card.text)
    print("agent card ui:", card.ui_args[0])

    # 2. the app's buttons: "add milk" presses the button, the app's state changes
    var added = Events(agent.run_with(run_input("t-card", "r2", "Please add milk to my shopping list.", False), runner))
    assert_true(added.called("add-milk"), "the model pressed add-milk; it called " + String(len(added.tool_names)) + " tools and said: " + added.text)
    assert_equal(len(runner.app.items), 1)
    assert_equal(runner.app.items[0], "milk")
    var pressed = added.tool_results[0]
    assert_true(pressed.find("milk") >= 0, "the result says what is on screen now: " + pressed)
    assert_true(added.text.byte_length() > 0, "it says what it did")
    print("agent buttons: ok, state", runner.app.items[0], "| result", pressed, "| said:", added.text)
    # ... and the conversation continues in the same thread: the second button
    var cleared = Events(agent.run_with(run_input("t-card", "r3", "Now clear the list.", False), runner))
    assert_true(cleared.called("clear-list"), "the model pressed clear-list: " + cleared.text)
    assert_equal(len(runner.app.items), 0)
    print("agent buttons 2: ok, list cleared | said:", cleared.text)

    # 2b. a plain Mojo function as a tool
    var sec = Events(agent.run_with(run_input("t-card", "r4", "What is the secret number? Use your tool.", False), runner))
    assert_true(sec.called("secret_number"), "the function was called: " + sec.text)
    assert_equal(sec.tool_results[0], '{"number": 4271}')
    assert_true(sec.text.find("4271") >= 0 or sec.text.find("4,271") >= 0 or sec.text.find("four thousand") >= 0, "it reports the number: " + sec.text)
    print("agent function: ok |", sec.text)

    # 3. barge-in: cancel mid-run, RUN_FINISHED within 200 ms, and the next run works (and remembers)
    var long = agent.begin(run_input("t-card", "r5", "Count from one to three hundred in words, separated by commas, nothing else.", False))
    var heard = False
    var t_ask = now_ns()
    var got = long.copy()
    while not heard and ms_since(t_ask) < 20000:
        for ev in agent.poll():
            got.append(ev)
            if ev.find("TEXT_MESSAGE_CONTENT") >= 0:
                heard = True
        sleep_ms(1)
    assert_true(heard, "the reply started")
    sleep_ms(300)
    var t_cancel = now_ns()
    agent.cancel()
    var cancel_ms = 0.0
    while agent.running() and ms_since(t_cancel) < 5000:
        for ev in agent.poll():
            got.append(ev)
        cancel_ms = ms_since(t_cancel)
        sleep_ms(1)
    assert_true(not agent.running(), "the cancelled run ended")
    var cancelled = Events(got^)
    assert_equal(cancelled.types[len(cancelled.types) - 1], "RUN_FINISHED")
    assert_true(cancelled.raw[len(cancelled.raw) - 1].find('"cancelled":true') >= 0, "the finish says it was cancelled")
    assert_true(cancel_ms <= 200.0, "cancel took " + String(cancel_ms) + " ms")
    print("agent cancel: ok,", cancel_ms, "ms to RUN_FINISHED")
    var again = Events(agent.run_with(run_input("t-card", "r6", "What is the capital of France? One word.", False), runner))
    assert_true(again.text.find("Paris") >= 0, "the next run works: " + again.text)
    assert_equal(again.types[len(again.types) - 1], "RUN_FINISHED")
    print("agent after cancel: ok |", again.text)

    # 4. time to the first words (warm): in this process
    var ttfts = List[Float64]()
    for k in range(3):
        var e = Events(agent.run_with(run_input("t-ttft", "ttft" + String(k), "Say hello to me in one short sentence.", False), runner))
        assert_true(agent.first_text_ms > 0.0, "first text: " + e.text)
        ttfts.append(agent.first_text_ms)
    sort(ttfts)
    var inproc_ttft = ttfts[1]
    print("agent ttft: in-process median", inproc_ttft, "ms (", ttfts[0], ttfts[1], ttfts[2], ")")
    makedirs("build/g72", exist_ok=True)
    with open("build/g72/agent-bench.json", "w") as f:
        f.write('{"in_process_first_text_ms":' + String(inproc_ttft) + ',"in_process_runs_ms":[' + String(ttfts[0]) + "," + String(ttfts[1]) + "," + String(ttfts[2]) + ']}\n')
    print("agent: all in-process cases passed")

    if serve:
        var served = serve_llm_agent(agent^, AppRunner[Shopping](Shopping()), port=0)
        print("SERVING", served.port)
        with open("build/g72/agent-port", "w") as f:
            f.write(String(served.port))
        while True:
            sleep_ms(500)
