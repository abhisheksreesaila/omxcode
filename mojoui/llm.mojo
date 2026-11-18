# mojoui.llm: a local language model in the app's own process, through llama.cpp's library (goal 72 M1).
# Qwen3.8-27B (any GGUF llama.cpp runs) on a chosen GPU: no server, no second process, no socket; a call never waits for
# the model, its words arrive as events.
#
#   var llm = Llm("models/Qwen3.8-27B-UD-Q4_K_M.gguf", gpu=1)          # loads (a few seconds when the file is cached)
#   var msgs = '[{"role":"user","content":"What is the capital of France?"}]'
#   var id = llm.chat(msgs)                                            # returns at once; sequence 0 = the conversation
#   for e in llm.poll(id):                                             # from update(), when the wake message arrives
#       if e.kind == TEXT: print(e.text)                               # also REASONING, TOOL_CALLS, DONE, ERROR
#   llm.cancel(id)                                                     # stops within one decode step (~25 ms)
#   var bg = llm.chat(msgs2, seq=1)                                    # background work: runs beside the conversation
#   var reply = llm.complete(msgs)                                     # blocking, for tests and tools: text, reasoning, calls
#
# How: bridge/llm_shim.cpp (scripts/build_llm_shim.sh -> build/llm/libmojoui_llm.so) links libllama and owns one engine
# thread per model. That thread applies the GGUF's own chat template (with the tools) through llama.cpp's jinja code, reuses
# each sequence's cached prompt (a hybrid model's recurrent state is checkpointed, so a second turn reads only what is new),
# and batches the sequences' tokens into one decode call. The reply is parsed as it streams: text and reasoning arrive as
# deltas, a tool call only when it is complete (its markup is never text). The shim is dlopen'ed the way mojoui.maxrt
# loads MAX: no link flag, and an app that never opens an Llm never loads libllama.
# Threads: chat/poll/cancel are for the UI thread and cost microseconds; the model runs on the shim's thread. One byte goes
# down the host's wake pipe (mojoui.wake) whenever events are waiting, so update() hears of them as App.jobs_message().
# Library locations: $MOJOUI_LLM_LIB (the shim; default build/llm/libmojoui_llm.so), $MOJOUI_LLAMA_DIR (llama.cpp's
# libraries when the shim finds them nowhere else; the shim's own rpath normally does), $MOJOUI_LLM_LOG=1 (llama.cpp's log).
# The temperature is passed in thousandths (0.7 -> 700); 0 samples greedily.
# Hosts: Linux with a llama.cpp build (CUDA for a GPU; gpu=-1 for the CPU). Mac/iPhone/Android/web: not built.

from std.ffi import external_call, c_char
from std.memory import Pointer
from std.os import getenv
from mojoui.json import Json
from mojoui.maxrt import _dlsym, _fn, _c_text, _exists
from mojoui.wake import wake_write_fd
from mojoui import libc

comptime TEXT = 0  # a piece of the reply
comptime REASONING = 1  # a piece of the model's thinking
comptime TOOL_CALLS = 2  # the tool calls the model made: a JSON array [{"id","name","arguments"}] in `text`
comptime DONE = 3  # the reply is over: `text` is the reason (stop, length, cancel) and the numbers are filled
comptime ERROR = 4  # it failed: `text` says why (also ends the request)

comptime _LOAD = def(Int, Int, Int, Int, Int, Int, Int) thin abi("C") -> Int
comptime _CHAT = def(Int, Int, Int, Int, Int, Int, Int, Int, Int) thin abi("C") -> Int
comptime _POLL = def(Int, Int, Int, Int) thin abi("C") -> Int
comptime _ERR = def(Int, Int) thin abi("C") -> Int
comptime _CANCEL = def(Int, Int) thin abi("C") -> NoneType
comptime _FREE = def(Int) thin abi("C") -> NoneType


@fieldwise_init
struct LlmEvent(Copyable, Movable):
    var kind: Int
    var text: String
    var n_prompt: Int  # DONE: prompt tokens
    var n_cached: Int  # DONE: of those, the ones the cache already held
    var n_gen: Int  # DONE: tokens generated
    var prefill_ms: Float64  # DONE: reading the prompt (what the cache didn't cover)
    var ttft_ms: Float64  # DONE: from chat() to the first generated token
    var tps: Float64  # DONE: decode speed, tokens per second


struct LlmReply(Movable):
    """What complete() collected: the reply text, the thinking, the tool calls (a JSON array, "" if none) and the numbers."""

    var text: String
    var reasoning: String
    var tool_calls: String
    var done: LlmEvent
    var events: List[LlmEvent]

    def __init__(out self, var done: LlmEvent):
        self.text = String("")
        self.reasoning = String("")
        self.tool_calls = String("")
        self.done = done^
        self.events = List[LlmEvent]()


def _shim_path() raises -> String:
    var path = getenv("MOJOUI_LLM_LIB", "build/llm/libmojoui_llm.so")
    if not _exists(path):
        raise Error("llm: no " + path + " (run scripts/build_llm_shim.sh, or set MOJOUI_LLM_LIB)")
    return path


def _last_error(lib: Int) -> String:
    var buf = List[UInt8](length=512, fill=0)
    var n = _fn[_ERR](_dlsym(lib, "llm_last_error"))(Int(buf.unsafe_ptr()), 512)
    return String(from_utf8_lossy=Span(buf)[0 : max(n, 0)])


def _open(path: String) raises -> Int:
    var dlopen = _dlsym(0, "dlopen")
    if dlopen == 0:
        raise Error("llm: no dlopen in this process")
    var p = path
    var h = _fn[def(Int, Int) thin abi("C") -> Int](dlopen)(Int(p.as_c_string_span().unsafe_ptr()), 2)  # RTLD_NOW
    if h == 0:
        var err = _dlsym(0, "dlerror")
        raise Error("llm: couldn't load " + path + ": " + (_c_text(_fn[def() thin abi("C") -> Int](err)()) if err != 0 else String("")))
    return h


struct Llm(Movable):
    """A loaded model. Its engine thread runs from open to the end of the value's life; make it once and keep it."""

    var handle: Int
    var lib: Int
    var n_ctx: Int
    var n_seq: Int
    var path: String

    def __init__(out self, path: String, gpu: Int = 0, n_ctx: Int = 32768, n_seq: Int = 2, kv_q8: Bool = True, flash: Bool = True) raises:
        """Loads the GGUF at `path` on GPU number `gpu` (-1: the CPU) with a context of `n_ctx` tokens shared by `n_seq`
        sequences (q8_0 KV cache and flash attention by default: about half the cache's memory). Raises why when it can't."""
        self.lib = _open(_shim_path())
        self.path = path
        self.n_ctx = 0
        self.n_seq = 0
        self.handle = 0
        var p = path
        var load = _fn[_LOAD](_dlsym(self.lib, "llm_load"))
        self.handle = load(
            Int(p.as_c_string_span().unsafe_ptr()), gpu, n_ctx, n_seq, 1 if kv_q8 else 0, 1 if flash else 0, wake_write_fd()
        )
        _ = p^
        if self.handle == 0:
            raise Error("llm: " + _last_error(self.lib))
        self.n_ctx = _fn[_ERR](_dlsym(self.lib, "llm_info"))(self.handle, 0)
        self.n_seq = _fn[_ERR](_dlsym(self.lib, "llm_info"))(self.handle, 1)

    def __del__(deinit self):
        if self.handle != 0:
            _fn[_FREE](_dlsym(self.lib, "llm_free"))(self.handle)

    def chat(
        self,
        messages_json: String,
        tools_json: String = "",
        seq: Int = 0,
        think: Bool = False,
        max_tokens: Int = 512,
        temperature: Float64 = 0.7,
    ) raises -> Int:
        """Asks for a reply to `messages_json` (an OpenAI-style array of {"role", "content", …} messages, tool results
        included) with `tools_json` (OpenAI's "tools" array; "" for none) on sequence `seq` (0: the conversation, 1:
        background work; a request waits for the sequence's earlier one). Returns at once with the request's id; the
        events come from poll(). `think` turns the model's thinking on (the cache breaks when it changes between turns)."""
        var m = messages_json
        var t = tools_json
        var id = _fn[_CHAT](_dlsym(self.lib, "llm_chat"))(
            self.handle,
            seq,
            Int(m.as_c_string_span().unsafe_ptr()),
            m.byte_length(),
            Int(t.as_c_string_span().unsafe_ptr()),
            t.byte_length(),
            1 if think else 0,
            max_tokens,
            Int(temperature * 1000.0),
        )
        _ = m^
        _ = t^
        if id == 0:
            raise Error("llm: " + _last_error(self.lib))
        return id

    def poll(self, id: Int) raises -> List[LlmEvent]:
        """The events of request `id` since the last poll, in order (empty when none yet). After its DONE or ERROR the
        request is forgotten: a poll of it returns nothing."""
        var out = List[LlmEvent]()
        var cap = 65536
        var buf = List[UInt8](length=cap, fill=0)
        var poll_fn = _fn[_POLL](_dlsym(self.lib, "llm_poll"))
        while True:
            var n = poll_fn(self.handle, id, Int(buf.unsafe_ptr()), cap)
            if n == -1:
                return out^
            if n <= -2:  # a line longer than the buffer: grow it
                cap = -n - 1 + 1024
                buf = List[UInt8](length=cap, fill=0)
                continue
            if n == 0:
                return out^
            var text = String(from_utf8_lossy=Span(buf)[0:n])
            for line in text.split("\n"):
                if line.byte_length() > 0:
                    out.append(_event(String(line)))

    def cancel(self, id: Int):
        """Stops request `id` at the next decode step; its DONE (reason "cancel") follows from poll()."""
        _fn[_CANCEL](_dlsym(self.lib, "llm_cancel"))(self.handle, id)

    def complete(
        self,
        messages_json: String,
        tools_json: String = "",
        seq: Int = 0,
        think: Bool = False,
        max_tokens: Int = 512,
        temperature: Float64 = 0.7,
    ) raises -> LlmReply:
        """chat() and wait for the whole reply (for tests and tools: an app polls from update() instead)."""
        var id = self.chat(messages_json, tools_json, seq, think, max_tokens, temperature)
        return self.wait(id)

    def wait(self, id: Int) raises -> LlmReply:
        """Polls request `id` until it ends, collecting what it said. Raises on an ERROR event."""
        var reply = LlmReply(LlmEvent(DONE, "", 0, 0, 0, 0.0, 0.0, 0.0))
        while True:
            for e in self.poll(id):
                if e.kind == TEXT:
                    reply.text += e.text
                elif e.kind == REASONING:
                    reply.reasoning += e.text
                elif e.kind == TOOL_CALLS:
                    reply.tool_calls = e.text
                elif e.kind == ERROR:
                    raise Error("llm: " + e.text)
                elif e.kind == DONE:
                    reply.done = e.copy()
                    return reply^
                reply.events.append(e.copy())
            _ = libc.usleep(2000)


def _event(line: String) raises -> LlmEvent:
    var j = Json.parse(line)
    var t = j.text(j.get(0, "t"))
    if t == "text":
        return LlmEvent(TEXT, j.text(j.get(0, "s")), 0, 0, 0, 0.0, 0.0, 0.0)
    if t == "reasoning":
        return LlmEvent(REASONING, j.text(j.get(0, "s")), 0, 0, 0, 0.0, 0.0, 0.0)
    if t == "tools":
        return LlmEvent(TOOL_CALLS, j.dump(j.get(0, "calls")), 0, 0, 0, 0.0, 0.0, 0.0)
    if t == "done":
        return LlmEvent(
            DONE,
            j.text(j.get(0, "reason")),
            j.number(j.get(0, "n_prompt")),
            j.number(j.get(0, "n_cached")),
            j.number(j.get(0, "n_gen")),
            j.real(j.get(0, "prefill_ms")),
            j.real(j.get(0, "ttft_ms")),
            j.real(j.get(0, "tps")),
        )
    return LlmEvent(ERROR, j.text(j.get(0, "s")), 0, 0, 0, 0.0, 0.0, 0.0)
