# mojoui.agentserve: an LlmAgent (mojoui.llmagent) served over AG-UI's HTTP transport (goal 72 M3, D-7224).
#
#   var served = serve_llm_agent(LlmAgent(Llm(gguf, gpu=1)), AppRunner[Shopping](Shopping()), port=8765)
#   # any AG-UI client: POST http://127.0.0.1:8765/ with a RunAgentInput (JSON) -> text/event-stream of AG-UI events
#   # (data: {"type":"RUN_STARTED",...}\n\n ...); the protocol's own Python SDK, CopilotKit's HttpAgent, mojoui.agui.Agent.
#
# One run at a time (the model is one conversation): a second POST while one runs is a 409. The run is stepped on a thread
# of its own and streamed as the model produces it; a client that goes away (an AG-UI client aborts by closing the
# connection) cancels the run within a decode step. Loopback by default, and only a local page may start a run (the
# check scripts/agui_agent.py makes, D-722): a JSON content type, a local Host, no foreign Origin. `allow_remote=True`
# skips the Host and Origin checks for a deliberate bind elsewhere (behind a proxy that authenticates).
# GET /health -> {"ok": true}. Built like mojoui.serve: scripts/mojo_flare.sh (-D MOJOUI_FLARE).
from std.memory.alloc import unsafe_alloc
from std.ffi import external_call
from mojoui import libc
from mojoui.llmagent import LlmAgent, ToolRunner
from mojoui.serve import Server, Service, Req, Reply, Pipe, Served, spawn


def _local_host(h: String) -> Bool:
    """Whether `h` ("localhost:8765", "127.0.0.1", "[::1]:80") names this machine."""
    var cut = h.byte_length()
    if h.startswith("["):
        var e = h.find("]")
        if e >= 0:
            cut = e + 1
    else:
        var c = h.find(":")
        if c >= 0:
            cut = c
    var name = String(h[byte = :cut])
    return name == "127.0.0.1" or name == "localhost" or name == "[::1]"


def _local_origin(o: String) -> Bool:
    if o == "":
        return True
    var s = o.find("://")
    if s < 0:
        return False
    var rest = String(o[byte = s + 3 :])
    var slash = rest.find("/")
    return _local_host(String(rest[byte = :slash]) if slash >= 0 else rest)


struct _Job[R: ToolRunner](Movable):
    var agent: Int
    var runner: Int
    var pipe: Int
    var input: String

    def __init__(out self, agent: Int, runner: Int, pipe: Int, var input: String):
        self.agent = agent
        self.runner = runner
        self.pipe = pipe
        self.input = input^


def _run_job[R: ToolRunner](addr: Int):
    """The run, on its own thread: begin, then step until the model and its tools are done, writing each AG-UI event as an
    SSE event the moment it exists; the client leaving cancels it."""
    var job = Pointer[_Job[R], MutUntrackedOrigin](unsafe_from_address=addr)
    var agent = Pointer[LlmAgent, MutUntrackedOrigin](unsafe_from_address=job[].agent)
    var runner = Pointer[R, MutUntrackedOrigin](unsafe_from_address=job[].runner)
    var pipe = Pipe.at(job[].pipe)
    agent[].set_tools(runner[].tools())
    for ev in agent[].begin(job[].input):
        pipe.write("data: " + ev + "\n\n")
    var cancelled = False
    while agent[].running():
        if pipe.gone() and not cancelled:
            agent[].cancel()
            cancelled = True
        var evs = agent[].step_with(runner[])
        if len(evs) == 0:
            _ = external_call["usleep", Int32](Int32(1000))
        for ev in evs:
            pipe.write("data: " + ev + "\n\n")
    pipe.close()
    pipe.release()
    job.unsafe_deinit_pointee()
    job.unsafe_free()


struct AgentService[R: ToolRunner](Service):
    var agent: Int  # the LlmAgent's address (it outlives every request: the run's thread uses it)
    var runner: Int
    var live: Int  # the last run's Pipe (0: none); a new run waits until it closes
    var allow_remote: Bool

    def __init__(out self, var agent: LlmAgent, var runner: Self.R, allow_remote: Bool = False):
        var a = unsafe_alloc[LlmAgent](1)
        a.unsafe_write(agent^)
        var r = unsafe_alloc[Self.R](1)
        r.unsafe_write(runner^)
        self.agent = Int(a)
        self.runner = Int(r)
        self.live = 0
        self.allow_remote = allow_remote

    def tick(mut self):
        pass

    def stop(mut self):
        pass

    def answer(mut self, mut req: Req) -> Reply:
        if req.matches("GET", "/health"):
            return Reply.json('{"ok":true}')
        if not (req.matches("POST", "/") or req.matches("POST", "/agent")):
            return Reply.not_found()
        if not self.allow_remote:
            if not _local_host(req.header("host")) or not _local_origin(req.header("origin")):
                return Reply.error(403, "only a local page may start a run", "not_local")
        if req.header("content-type").find("json") < 0:
            return Reply.error(415, "POST a RunAgentInput as application/json", "bad_content_type")
        if self.live != 0:
            var last = Pipe.at(self.live)
            if not last.closed():
                return Reply.error(409, "a run is already in progress", "busy")
            last.release()
            self.live = 0
        var pipe = Pipe()
        var reply = Reply.stream(pipe)
        var job = unsafe_alloc[_Job[Self.R]](1)
        job.unsafe_write(_Job[Self.R](self.agent, self.runner, pipe.share().addr, req.body))
        if not spawn[_run_job[Self.R]](Int(job)):
            pipe.release()
            return Reply.error(503, "no thread for the run", "no_thread")
        self.live = pipe.addr  # (this handle stays, so `closed()` can be asked of it)
        return reply^


def serve_llm_agent[R: ToolRunner](var agent: LlmAgent, var runner: R, port: Int = 0, host: String = "127.0.0.1", allow_remote: Bool = False) raises -> Served:
    """Serves `agent` (its tools: `runner`'s) as an AG-UI endpoint on a thread of its own; keep the Served while you serve."""
    return Server.start(AgentService[R](agent^, runner^, allow_remote), port=port, host=host, workers=4)
