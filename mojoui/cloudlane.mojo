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
#
# The record is written before anything leaves (D-7303): a "sent" row first, and when it can't be written (no folder, a full
# disk) nothing is sent and the person is told; the outcome follows as a second row. The file is mode 0600 (it holds the start
# of what was asked). The prompt follows `--`, so words that begin with a dash can't be read as the command's own options. A
# stopped request is signalled at once and reaped later, so cancel() never waits on the UI thread.

from std.os import makedirs
from mojoui.utf8 import head, boundary
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


def _begins_request(t: List[String], v: Int) -> Bool:
    """The word at v starts a request: it is the first word, or follows a politeness ("please", "can you", "go ahead and")."""
    if v == 0:
        return True
    if _is(t[v - 1], "please", "now", "then", "and", "just", "so", "ok", "okay", "hey", "hi", "also", "first", "go", "but", "next", "instead"):
        return True
    return v >= 2 and _is(t[v - 2], "can", "could", "would", "will") and t[v - 1] == "you"


def _addressed(low: String) -> Bool:
    """"Claude, …" or "Claude: …": the name, then a comma or colon, at the start of the words or after "hey", "ok", "please"…
    ("Claude Monet's paintings" is a painter; "my friend Claude, a baker" is a friend)."""
    var b = low.as_bytes()
    var at = 0
    while True:
        var k = low.find("claude", at)
        if k < 0:
            return False
        at = k + 6
        if k > 0 and ((Int(b[k - 1]) >= 97 and Int(b[k - 1]) <= 122) or (Int(b[k - 1]) >= 48 and Int(b[k - 1]) <= 57)):
            continue  # (the end of a longer word)
        if at >= len(b) or (b[at] != 44 and b[at] != 58):
            continue
        var before = _tokens(String(low[byte = :k]))
        if len(before) == 0 or (len(before) == 1 and _is(before[0], "hey", "ok", "okay", "hi", "hello", "so", "please", "now", "right", "alright")):
            return True


def route(text: String) -> Route:
    """Which lane answers: the cloud only when the person asks a cloud model to answer: "ask Claude", "use Opus for", "have
    Sonnet look at", "Claude, …" (said to it), "go hybrid", "use the cloud"; a name in other words (Claude Monet, a haiku, "I use
    Claude at work") is just words. Unless the person said to stay local; "think it through / get back to me" is a background
    job; the rest local."""
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
        var asked = i > 0 and _is(t[i - 1], "ask", "use", "get", "have", "let", "try") and _begins_request(t, i - 1)
        if asked and not refused:
            named = True
    if _addressed(low):
        var k = 0
        while k < len(t) and t[k] != "claude":
            k += 1
        var refused = False
        for j in range(max(k - 3, 0), k):
            if _is(t[j], "dont", "don't", "not", "never", "no"):
                refused = True
        if not refused:
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


def ledger_add(model: String, outcome: String, bytes_out: Int, bytes_in: Int, seconds: Float64, excerpt: String) -> Bool:
    """Appends a row (mode 0600). True when it was written; False when it wasn't (no folder, no space)."""
    var path = ledger_path()
    var slash = path.rfind("/")
    var row = (
        '{"at":' + String(Int(wall_seconds())) + ',"provider":"claude","model":' + json_string(model) + ',"outcome":' + json_string(outcome)
        + ',"bytes_out":' + String(bytes_out) + ',"bytes_in":' + String(bytes_in) + ',"seconds":' + String(Int(seconds + 0.5))
        + ',"excerpt":' + json_string(head(excerpt, 120)) + "}\n"
    )
    try:
        if slash > 0:
            makedirs(String(path[byte = :slash]), exist_ok=True)
    except:
        return False
    var fd = libc.open_append(path)
    if fd < 0:
        return False
    _ = libc.chmod(path, 0o600)  # (a file an older version made may be wider)
    var n = libc.write_fd(fd, Int(row.unsafe_ptr()), row.byte_length())
    _ = libc.close(fd)
    return n == row.byte_length()


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
    var dying: List[Process]  # stopped requests, signalled and waiting to be reaped (never waited for on the UI thread)

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
        self.dying = List[Process]()

    def begin(mut self, text: String, model: String) -> String:
        """Asks the cloud model. Returns "" when the command is running, else why it wasn't asked (the person hears it)."""
        if self.state == ASK_RUNNING:
            return String("a cloud request is already running")
        if self.used >= self.cap:
            return String("I've reached the limit of " + String(self.cap) + " cloud requests for this session")
        if looks_secret(text):
            return String("that has what looks like a key or a password in it, and I don't send those to the cloud")
        self.reap()
        if not ledger_add(model, "sent", text.byte_length() + SPOKEN.byte_length(), 0, 0.0, text):  # (the record first: no row, no request)
            return String("I can't write the record of what leaves this machine, so I'm not sending anything")
        var cwd = environment("TMPDIR", "/tmp") + "/mojoui-cloud-" + String(libc.getpid())
        self.log = cwd + "/out-" + String(now_ns()) + ".txt"
        try:
            makedirs(cwd, exist_ok=True)
            if libc.chmod(cwd, 0o700) != 0:  # (only this user's: a folder someone else made first refuses the chmod)
                raise Error("the scratch folder " + cwd + " isn't this user's")
            var argv = List[String]()
            argv.append(environment("OMX_CLAUDE_CMD", "claude"))
            argv.append("-p")
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
            argv.append("--")  # (what follows is the prompt, whatever it starts with)
            argv.append(text)
            self.proc = Process.start(argv, self.log, cwd=cwd)
        except e:
            _ = ledger_add(model, "not started", 0, 0, 0.0, "")  # (the "sent" row above over-reports: say it never left; D-7316)
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
        self.reap()
        if self.state != ASK_RUNNING or not self.proc:
            return self.state
        var over = self.seconds() > Float64(self.timeout_s)
        if self.proc.value().running() and not over:
            return ASK_RUNNING
        var outcome = String("ok")
        if over and self.proc.value().running():  # (too long: signalled, reaped on a later tick)
            var gone = self.proc.take()
            self.proc = None
            gone.begin_stop()
            self.dying.append(gone^)
            _ = libc.unlink(self.log)
            self.error = String("timeout")
            self.state = ASK_FAILED
            _ = ledger_add(self.model, "timeout", self.bytes_out, 0, self.seconds(), self.words)
            return self.state
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
        _ = ledger_add(self.model, outcome, self.bytes_out, text.byte_length() if outcome == "ok" else 0, self.seconds(), self.words)
        return self.state

    def cancel(mut self):
        """The person interrupted: the command is signalled at once (no waiting here) and reaped later, the ledger says so."""
        if self.state != ASK_RUNNING or not self.proc:
            return
        var gone = self.proc.take()
        self.proc = None
        gone.begin_stop()
        self.dying.append(gone^)
        _ = libc.unlink(self.log)
        self.error = String("interrupted")
        self.state = ASK_FAILED
        _ = ledger_add(self.model, "interrupted", self.bytes_out, 0, self.seconds(), self.words)

    def reap(mut self):
        """Collects stopped commands that have ended (SIGKILL after a second's grace): a tick's work, never a wait."""
        var k = 0
        while k < len(self.dying):
            if self.dying[k].finish_stop(1000):
                _ = self.dying.pop(k)
            else:
                k += 1

    def close(mut self):
        """The app ends: a running request is stopped and everything signalled is waited for (the one place that may wait)."""
        self.cancel()
        for k in range(len(self.dying)):
            _ = self.dying[k].stop(1000)
        self.dying = List[Process]()

    def idle(mut self):
        """Ready for the next request (after the answer or error was taken)."""
        self.reap()
        if self.state != ASK_RUNNING:
            self.state = ASK_IDLE


# ---------------------------------------------------------------------------------------------------------------------
# the cloud lane as a turn of the conversation (D-7304: this was the app's own state machine; an app only composes it)
# ---------------------------------------------------------------------------------------------------------------------

comptime STEP_NONE = 0
comptime STEP_ANSWERED = 1  # the cloud's answer is in: say it, and let the local model remember both sides
comptime STEP_FAILED = 2  # the cloud didn't answer: the local model answers `question`
comptime STEP_FRAME_OFF = 3  # what the cloud said has been said: the frame and the chip go back to the local lane


struct CloudStep(Copyable, Movable):
    var kind: Int
    var question: String  # what was asked
    var text: String  # STEP_ANSWERED: the answer; STEP_FAILED: why
    var seconds: Float64
    var bytes_out: Int
    var used: Int  # requests made this session

    def __init__(out self, kind: Int, question: String = "", text: String = "", seconds: Float64 = 0.0, bytes_out: Int = 0, used: Int = 0):
        self.kind = kind
        self.question = question
        self.text = text
        self.seconds = seconds
        self.bytes_out = bytes_out
        self.used = used


struct CloudTurn(Movable):
    """A turn the cloud answers, from the person's words to the frame going away. The app says when the person spoke and when
    they were interrupted and, each tick, asks what happened:

        var words = turn.fresh(heard.text, heard.merged)          # the words not already handled (a merged turn continues one)
        var lane = route(words)
        if lane.lane == LANE_CLOUD:
            var why = turn.ask(words, lane.model)                 # "" = asked (turn.framed: draw the frame); else why not, to say
        turn.cancel()                                             # a new turn or a barge-in drops it
        var step = turn.step(voice_is_active)                     # every tick: STEP_ANSWERED, STEP_FAILED or STEP_FRAME_OFF
        turn.close()                                              # in closing(): a running request is stopped
    """

    var lane: CloudLane
    var asking: Bool  # asked, the answer awaited
    var answered: Bool  # answered: the frame stays until what it said has been said
    var framed: Bool  # the cloud lane is showing (the chip, the frame): from asked until said
    var question: String
    var said_before: String  # the words of the turn before, which a merged turn continues

    def __init__(out self, cap: Int = 3, timeout_s: Int = 150):
        self.lane = CloudLane(cap=cap, timeout_s=timeout_s)
        self.asking = False
        self.answered = False
        self.framed = False
        self.question = String("")
        self.said_before = String("")

    def fresh(mut self, heard: String, merged: Bool) -> String:
        """The words of this turn that are new: all of `heard`, or, when it continues the turn before (merged: it hadn't made a
        sound yet), what follows the words already handled."""
        var out = heard
        if merged and heard.startswith(self.said_before) and heard.byte_length() > self.said_before.byte_length():
            out = String(String(heard[byte = self.said_before.byte_length() :]).strip())
        self.said_before = heard
        return out^

    def ask(mut self, text: String, model: String) -> String:
        """Asks the cloud model. "" when it was asked (the frame is on); else why not (the cap, a secret in the words, no record
        to write, no command), which the person hears before the local model answers."""
        var why = self.lane.begin(text, model)
        if why != "":
            return why^
        self.asking = True
        self.answered = False
        self.framed = True
        self.question = text
        return String("")

    def flip(mut self):
        """The test button that flips the lane chip without asking anyone."""
        self.framed = not self.framed

    def cancel(mut self) -> Bool:
        """A new turn or an interruption: the request is dropped (signalled, never waited for) and the lane is local again.
        True when there was a cloud turn to drop."""
        var was = self.framed
        if self.asking:
            self.lane.cancel()
        self.lane.idle()
        self.asking = False
        self.answered = False
        self.framed = False
        return was

    def step(mut self, voice_active: Bool) -> CloudStep:
        """Every tick: the answer when it has come, the failure when it did, the frame's end once the answer has been said
        (`voice_active` is False)."""
        if self.asking:
            var state = self.lane.poll()
            if state == ASK_DONE:
                var out = CloudStep(STEP_ANSWERED, self.question, self.lane.answer, self.lane.seconds(), self.lane.bytes_out, self.lane.used)
                self.lane.idle()
                self.asking = False
                self.answered = True
                return out^
            if state == ASK_FAILED:
                var out = CloudStep(STEP_FAILED, self.question, self.lane.error, self.lane.seconds(), self.lane.bytes_out, self.lane.used)
                self.lane.idle()
                self.asking = False
                self.framed = False
                return out^
        elif self.answered and not voice_active:
            self.answered = False
            self.framed = False
            return CloudStep(STEP_FRAME_OFF, self.question)
        return CloudStep(STEP_NONE)

    def close(mut self):
        """The app ends: a running request is stopped."""
        self.asking = False
        self.lane.close()
