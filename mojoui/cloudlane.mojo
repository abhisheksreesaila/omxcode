# mojoui.cloudlane: the cloud lane of a local assistant (goal 72 M6, D-7266; omx-local's hybrid.py and router.py).
# Everything is answered on this machine unless the person ASKS for a cloud model by name, and then the request goes to the
# logged-in `claude -p` command line, once, capped, with a record of what left.
#
#   route("Ask Claude: what is a monad?")  -> Route(CLOUD, "opus", "asked for Claude")      also "use Claude for…", "have Sonnet…"
#   route("Think it through and get back to me: …") -> Route(BACKGROUND, …)                 stays local (mojoui.llmjob)
#   route("Don't ask Claude, stay local")  -> Route(LOCAL, …)                               "stay local" / "don't use the cloud" always win
#   var lane = CloudLane(cap=3)
#   var why = lane.begin("what is a monad?", "opus")     # "" = asked; else why not (the cap, a secret in the words, no command)
#   update() on a timer:  if lane.poll() != ASK_RUNNING: lane.answer / lane.error   # never waits: the command is a child process
#   cloud_ledger()                                       # the record: one JSON line a request in $MOJOUI_LEDGER (default
#                                                        # ~/.local/share/mojoui/cloud-ledger.jsonl): when, model, bytes out and in, seconds, outcome
#
# What leaves: the person's words and a one-line instruction to answer for the ear (nothing else: no history, files, audio
# or screenshots), unless looks_secret() says the words hold a key, a password or a private key: then nothing is sent and
# the caller says so. The command runs in an empty folder with no tools, no session and no settings, so it reads nothing
# here. $OMX_CLAUDE_CMD names the command (default `claude`; a test points it at a script), $OMX_CLOUD_MODEL the default
# model (`opus`). Linux and Mac (mojoui.process).

from std.os import makedirs
from mojoui.clock import now_ns, wall_seconds
from mojoui.json import json_string
from mojoui.process import Process, file_tail
from mojoui.shared import environment
from mojoui import libc

comptime LANE_LOCAL = 0
comptime LANE_CLOUD = 1
comptime LANE_BACKGROUND = 2

comptime ASK_IDLE = 0
comptime ASK_RUNNING = 1
comptime ASK_DONE = 2
comptime ASK_FAILED = 3

comptime SPOKEN = (
    "You are answering through a voice assistant: your words will be spoken aloud. Answer in plain spoken sentences, at most five, "
    "with no markdown, no lists and no code blocks."
)


struct Route(Copyable, Movable):
    var lane: Int
    var model: String  # the cloud model's name ("opus"), "" for the local lanes
    var why: String

    def __init__(out self, lane: Int, model: String, why: String):
        self.lane = lane
        self.model = model
        self.why = why


def _tokens(text: String) -> List[String]:
    var out = List[String]()
    var cur = String("")
    for b in text.as_bytes():
        var c = Int(b)
        if c >= 65 and c <= 90:
            c += 32
        if (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 39:  # (an apostrophe stays: don't)
            cur += chr(c)
        elif cur != "":
            out.append(cur)
            cur = String("")
    if cur != "":
        out.append(cur)
    return out^


def _is(w: String, *words: String) -> Bool:
    for i in range(len(words)):
        if w == words[i]:
            return True
    return False


def _phrase(tokens: List[String], phrase: String) -> Bool:
    """The words of `phrase` appear in a row among the tokens."""
    var want = _tokens(phrase)
    if len(want) == 0:
        return False
    for i in range(len(tokens) - len(want) + 1):
        var all = True
        for k in range(len(want)):
            if tokens[i + k] != want[k]:
                all = False
                break
        if all:
            return True
    return False


def route(text: String) -> Route:
    """Which lane answers: the cloud only when named ("ask Claude", "use Opus for", "have Sonnet", "Claude, …", "go hybrid",
    "use the cloud"), unless the person said to stay local; "think it through / get back to me" is a background job; the rest local."""
    var t = _tokens(text)
    var local = False
    for p in ["stay local", "keep it local", "dont use the cloud", "don't use the cloud", "do not use the cloud", "offline"]:
        if _phrase(t, String(p)):
            local = True
    var named = False
    var model = String("")
    var low = text.lower()
    for i in range(len(t)):
        if not _is(t[i], "claude", "opus", "sonnet", "haiku"):
            continue
        if t[i] != "claude":
            model = t[i]
        var refused = False
        for k in range(max(i - 3, 0), i):
            if _is(t[k], "dont", "don't", "not", "never", "no"):
                refused = True
        var before = t[i - 1] if i > 0 else String("")
        var called = _is(before, "ask", "use", "get", "have", "let", "try") or (i == 0 and t[i] == "claude")
        if t[i] == "claude" and ("claude," in low or "claude:" in low):
            called = True
        if called and not refused:
            named = True
    if (_phrase(t, "go hybrid") or _phrase(t, "hybrid mode") or _phrase(t, "use the cloud") or _phrase(t, "frontier model")) and not local:
        named = True
    if local:
        return Route(LANE_LOCAL, "", "asked to stay local")
    if named:
        return Route(LANE_CLOUD, model if model != "" else environment("OMX_CLOUD_MODEL", "opus"), "asked for Claude")
    for p in ["think it through", "think this through", "think that through", "think it over", "think this over", "get back to me", "take your time", "in the background", "mull it over", "mull this over"]:
        if _phrase(t, String(p)):
            return Route(LANE_BACKGROUND, "", "a background job, thought through here")
    return Route(LANE_LOCAL, "", "answered here")


def looks_secret(text: String) -> Bool:
    """Words that hold a key, a token, a password or a private key: never sent to the cloud."""
    var low = text.lower()
    for marker in ["-----begin", "sk-ant-", "api_key", "api key is", "apikey", "secret key", "password is", "password:", "my password", "bearer ", "private key", "ghp_", "gho_", "github_pat_", "xoxb-", "akia"]:
        if String(marker) in low:
            return True
    # a long unbroken run of letters, digits and - _ that mixes both: a token, not a word
    var run = 0
    var digits = 0
    var letters = 0
    for b in text.as_bytes():
        var c = Int(b)
        var d = c >= 48 and c <= 57
        var l = (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
        if d or l or c == 45 or c == 95:
            run += 1
            digits += 1 if d else 0
            letters += 1 if l else 0
        else:
            if run >= 32 and digits >= 4 and letters >= 4:
                return True
            run = 0
            digits = 0
            letters = 0
    return run >= 32 and digits >= 4 and letters >= 4


# ---------------------------------------------------------------------------------------------------------------------
# the record
# ---------------------------------------------------------------------------------------------------------------------

def ledger_path() -> String:
    var own = environment("MOJOUI_LEDGER")
    if own != "":
        return own
    var data = environment("XDG_DATA_HOME")
    if data == "":
        data = environment("HOME") + "/.local/share"
    return data + "/mojoui/cloud-ledger.jsonl"


def cloud_ledger() -> String:
    """The record so far (one JSON line per request; "" when none)."""
    return file_tail(ledger_path(), 1 << 20)


def ledger_add(model: String, outcome: String, bytes_out: Int, bytes_in: Int, seconds: Float64, excerpt: String):
    """Appends a request: written whatever happened next, since the words left the machine either way."""
    var path = ledger_path()
    var slash = path.rfind("/")
    var row = (
        '{"at":' + String(Int(wall_seconds())) + ',"provider":"claude","model":' + json_string(model) + ',"outcome":' + json_string(outcome)
        + ',"bytes_out":' + String(bytes_out) + ',"bytes_in":' + String(bytes_in) + ',"seconds":' + String(Int(seconds + 0.5))
        + ',"excerpt":' + json_string(String(excerpt[byte = : min(excerpt.byte_length(), 120)])) + "}\n"
    )
    try:
        if slash > 0:
            makedirs(String(path[byte = :slash]), exist_ok=True)
        with open(path, "a") as f:
            f.write(row)
    except:
        pass


# ---------------------------------------------------------------------------------------------------------------------
# a request
# ---------------------------------------------------------------------------------------------------------------------

struct CloudLane(Movable):
    var used: Int  # requests made (a refused one doesn't count)
    var cap: Int
    var state: Int
    var proc: Optional[Process]
    var log: String
    var model: String
    var words: String  # what was asked (the ledger keeps its start)
    var bytes_out: Int
    var started_ns: Int
    var timeout_s: Int
    var answer: String
    var error: String

    def __init__(out self, cap: Int = 3, timeout_s: Int = 150):
        self.used = 0
        self.cap = cap
        self.state = ASK_IDLE
        self.proc = None
        self.log = String("")
        self.model = String("")
        self.words = String("")
        self.bytes_out = 0
        self.started_ns = 0
        self.timeout_s = timeout_s
        self.answer = String("")
        self.error = String("")

    def begin(mut self, text: String, model: String) -> String:
        """Asks the cloud model. Returns "" when the command is running, else why it wasn't asked (the person hears it)."""
        if self.state == ASK_RUNNING:
            return String("a cloud request is already running")
        if self.used >= self.cap:
            return String("I've reached the limit of " + String(self.cap) + " cloud requests for this session")
        if looks_secret(text):
            return String("that has what looks like a key or a password in it, and I don't send those to the cloud")
        var cwd = environment("TMPDIR", "/tmp") + "/mojoui-cloud-" + String(libc.getpid())
        self.log = cwd + "/out-" + String(now_ns()) + ".txt"
        try:
            makedirs(cwd, exist_ok=True)
            var argv = List[String]()
            argv.append(environment("OMX_CLAUDE_CMD", "claude"))
            argv.append("-p")
            argv.append(text)
            argv.append("--model")
            argv.append(model)
            argv.append("--output-format")
            argv.append("text")
            argv.append("--tools")
            argv.append("")
            argv.append("--no-session-persistence")
            argv.append("--strict-mcp-config")
            argv.append("--setting-sources")
            argv.append("")
            argv.append("--append-system-prompt")
            argv.append(String(SPOKEN))
            self.proc = Process.start(argv, self.log, cwd=cwd)
        except e:
            return String("I couldn't start the cloud command: " + String(e))
        self.used += 1
        self.model = model
        self.words = text
        self.bytes_out = text.byte_length() + SPOKEN.byte_length()
        self.started_ns = now_ns()
        self.answer = String("")
        self.error = String("")
        self.state = ASK_RUNNING
        return String("")

    def seconds(self) -> Float64:
        return Float64(now_ns() - self.started_ns) / 1e9

    def poll(mut self) -> Int:
        """ASK_RUNNING, then once ASK_DONE (answer) or ASK_FAILED (error); the ledger row is written at that moment."""
        if self.state != ASK_RUNNING or not self.proc:
            return self.state
        var over = self.seconds() > Float64(self.timeout_s)
        if self.proc.value().running() and not over:
            return ASK_RUNNING
        var outcome = String("ok")
        if over and self.proc.value().running():
            _ = self.proc.value().stop(1000)
            outcome = "timeout"
        var text = String(file_tail(self.log, 1 << 20).strip())
        var code = self.proc.value().exit_code()
        self.proc = None
        _ = libc.unlink(self.log)
        if outcome == "ok" and (code != 0 or text == ""):
            outcome = "exit " + String(code)
        if outcome == "ok":
            self.answer = text
            self.state = ASK_DONE
        else:
            self.error = outcome
            self.state = ASK_FAILED
        ledger_add(self.model, outcome, self.bytes_out, text.byte_length() if outcome == "ok" else 0, self.seconds(), self.words)
        return self.state

    def cancel(mut self):
        """The person interrupted: the command is stopped, the ledger says so."""
        if self.state != ASK_RUNNING or not self.proc:
            return
        _ = self.proc.value().stop(1000)
        self.proc = None
        _ = libc.unlink(self.log)
        self.error = String("interrupted")
        self.state = ASK_FAILED
        ledger_add(self.model, "interrupted", self.bytes_out, 0, self.seconds(), self.words)

    def idle(mut self):
        """Ready for the next request (after the answer or error was taken)."""
        if self.state != ASK_RUNNING:
            self.state = ASK_IDLE
