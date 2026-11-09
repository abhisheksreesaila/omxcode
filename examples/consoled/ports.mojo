# consoled's automatic port (goal 64; the Python daemon's port_auto.py, same stages, same rows, same log, D-6401):
# POST /admin/ports runs this on a thread of its own. A job runs Modular's `import-model` skill unattended through
# Claude Code (headless), then checks the result and registers it. Stages, in order:
#   workspace  resolve the ref, make MXC_HOME/ports/<name> with config.json and the chosen donor
#   skills     clone/update github.com/modular/skills, link them into the workspace, write PORT.md
#   generate   `claude -p` in the workspace writes the custom architecture package
#   build      the skill's check_port.py: imports the port like `max serve` does and checks every weight
#   parity     a smoke generation through `max serve --custom-architectures`, then the skill's verify gates
#   register   the pull's own path (weights pinned from Hugging Face, architecture = the package)
#   serve      start the model like any other
# When build or parity fails, generate runs again with the error output appended ("Fix this"), up to `max_attempts`
# times; each attempt is its own set of stage rows, and the same failure twice stops early (D-6404). The whole
# transcript of the agent and of every command goes to MXC_HOME/ports/<id>/port.log, and the agent's raw stream-json
# of each attempt to agent-<attempt>.jsonl beside it (it can hold anything the agent printed, a secret included:
# scrub before sharing it). Cancel stops the process group of whatever runs.
#
# Safety (config.json and the model card are untrusted, so assume prompt injection): the agent, the gate checks and
# the smoke server run under bubblewrap (sandbox.mojo) with a scrubbed environment, a job-private Claude config and
# `--permission-prompts none`; the allow list is only the skill's own scripts plus file tools. Without bwrap the
# port is refused unless the caller passes `unsandboxed`. Nothing shared is writable from a sandbox: the skill's
# pixi env is installed beforehand from the pristine clone, outside; the clone and the model's weights are bound
# read-only; every cache lives in MXC_HOME/ports/<id>/work, deleted when the job ends. The gate scripts are
# hash-checked, and restored from git if touched, before every use.
# Accepted risks, documented rather than solved: code in the agent sandbox can read the Claude login (the real
# credentials file is bound in, so a token refresh writes back to the one file) and it has network access; and the
# gates import and run the generated code, so a passing gate means "an agent that did not cheat produced matching
# output". The sandbox limits damage; it does not vouch for the port.

from std.atomic import Atomic
from std.sys import CompilationTarget
from std.memory.alloc import unsafe_alloc
from std.os import makedirs, getenv, listdir, remove
from std.os.path import exists, isdir, getsize
from mojoui.clock import wall_seconds, now_ns
from mojoui.files import remove_tree
from mojoui.hf import hub_repo, hub_download, hub_ref, HubRepo
from mojoui.http import Request
from mojoui.http_flare import FlareTransport, Transfer
from mojoui.json import Json, json_string, J_NULL, J_BOOL, J_NUMBER, J_STRING
from mojoui.process import Process, file_tail, output, healthy
from mojoui.serve import spawn
from mojoui.workbook import read_text, write_text
from mojoui import libc
from portprep import (ENTRY_SKILL, SKILLS_REPO, SKILLS_REV, SKILL_SCRIPTS, PARITY_SERVE_FLAGS, KEY_FIELDS, Donor, pick_donor,
                      catalog_names, max_arch_dir, package_slug, workspace_name, check_port_dir, apply_skill_patches,
                      stale_patches, gate_hash, max_pinned, failure_signature, infra_error, reached_text, norm)
from sandbox import bwrap_argv, Confine, scrub, env_names, have_bwrap, which, tool_roots
from store import Store
from porter import INSTALL_CLAUDE
from pulls import repo_of, model_name, folder_of, wanted, catalog, ref_problem
from supervisor import free_port

comptime _A = Atomic[Scalar[DType.int64]]
comptime _P = Pointer[Int64, MutUntrackedOrigin]
comptime W_ENDED = 0  # 1 once the worker wrote its last row: it touches nothing after

comptime STAGE_NAMES = ["workspace", "skills", "generate", "build", "parity", "register", "serve"]
comptime ATTEMPT_STAGES = ["generate", "build", "parity"]
comptime DEFAULT_ATTEMPTS = 3
comptime MAX_ATTEMPTS = 10
comptime GENERATE_TIMEOUT_MS = 3 * 3600 * 1000  # one `claude -p` run
comptime CHECK_TIMEOUT_MS = 45 * 60 * 1000      # the skill's build/verify checks
comptime INSTALL_TIMEOUT_MS = 60 * 60 * 1000    # the skill env pulls MAX and PyTorch the first time
comptime SMOKE_TIMEOUT_MS = 40 * 60 * 1000      # a cold compile of a new architecture takes 5 to 25 minutes
comptime SERVE_TIMEOUT_MS = 40 * 60 * 1000
comptime TAIL_LINES = 40
comptime KEEP_LINES = 400                       # of a command's output, for the feedback and the signature
comptime FEEDBACK_CHARS = 6000                  # how much error output is fed back to the agent
comptime KEEP_ROWS = 30
comptime INFRA_RETRIES = 2
comptime INFRA_BACKOFF_MS = 30_000
comptime SMOKE_PROMPT = "The capital of France is"
comptime POLL_MS = 150

comptime NO_SANDBOX = ("Automatic port needs bubblewrap (`bwrap`) to confine the agent that reads the model's untrusted files, "
                       + "and it was not found. Install bubblewrap (the `bubblewrap` package on most Linux distributions), or pass "
                       + "unsandboxed to run without confinement (not recommended).")
comptime NO_CLAUDE = INSTALL_CLAUDE
# What the agent may do. Files: Read/Edit/Write/Glob/Grep (acceptEdits confines edits to the workspace). Commands:
# only the skill's own scripts through its pixi env, `pixi install`, and `cd` (to reach the skill root). No general
# shell tools. The model card may be read from huggingface.co. Anything else would prompt, and prompts are denied.
comptime BASE_TOOLS = ["Read", "Write", "Edit", "Glob", "Grep", "WebFetch(domain:huggingface.co)", "Bash(cd:*)",
                       "Bash(pixi install)", "Bash(pixi install --locked)"]


def port_name_ok(name: String) -> Bool:
    """pulls.py NAME_RE / keys.py APP_NAME: 1 to 64 of letters, digits, '.', '_' and '-', starting with a letter or
    digit. It is also the only rule that keeps the workspace inside MXC_HOME/ports (no '/', no '..')."""
    var b = name.as_bytes()
    if len(b) == 0 or len(b) > 64:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        var alnum = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
        if not (alnum or ((c == 46 or c == 95 or c == 45) and i > 0)):
            return False
    return True


def allowed_tools(extra: List[String]) -> List[String]:
    var out = List[String]()
    for t in materialize[BASE_TOOLS]():
        out.append(String(t))
    for n in materialize[SKILL_SCRIPTS]():
        out.append("Bash(pixi run python scripts/" + String(n) + ":*)")
        out.append("Bash(pixi run -e cuda python scripts/" + String(n) + ":*)")
    for e in extra:
        out.append(e)
    return out^


# ---- the job's rows ---------------------------------------------------------------------------------------------

@fieldwise_init
struct Stage(Copyable, Movable):
    var name: String
    var status: String  # pending, running, done, failed, skipped, cancelled
    var started: Float64
    var ended: Float64
    var detail: String
    var attempt: Int  # 0: not an attempt stage

    @staticmethod
    def fresh(name: String, attempt: Int) -> Stage:
        return Stage(name, "pending", 0, 0, "", attempt)


def stages_json(stages: List[Stage]) -> String:
    var out = String("[")
    for i in range(len(stages)):
        ref s = stages[i]
        out += (", " if i > 0 else "") + '{"name": ' + json_string(s.name) + ', "status": ' + json_string(s.status)
        out += ', "started": ' + (String(s.started) if s.started > 0 else "null")
        out += ', "ended": ' + (String(s.ended) if s.ended > 0 else "null")
        out += ', "detail": ' + json_string(s.detail)
        out += ', "attempt": ' + (String(s.attempt) if s.attempt > 0 else "null") + "}"
    return out + "]"


@fieldwise_init
struct Fail(Copyable, Movable):
    """A stage failed. `retry` says whether another generate attempt could fix it; `output` is what is fed back to
    the agent; `reached` is how far the attempt got (1 build failed, 2 serve/smoke failed, 3 + passes/100 gates)."""
    var message: String
    var retry: Bool
    var output: String
    var reached: Float64

    @staticmethod
    def none() -> Fail:
        return Fail("", False, "", 0)

    def failed(self) -> Bool:
        return self.message != ""


# ---- what the worker carries ------------------------------------------------------------------------------------

struct PortJob(Movable):
    """What a worker needs, on the heap until it starts (it takes it)."""
    var id: Int
    var asked: String
    var name: String
    var home: String
    var max_cmd: String
    var env: List[String]
    var admin_key: String
    var daemon_port: Int
    var max_attempts: Int
    var unsandboxed: Bool
    var porter_env: List[String]  # how the agent authenticates (the porting assistant setting; never logged)
    var t: Transfer
    var words: Int

    def __init__(out self, id: Int, asked: String, name: String, home: String, max_cmd: String, var env: List[String],
                 admin_key: String, daemon_port: Int, max_attempts: Int, unsandboxed: Bool, var porter_env: List[String],
                 t: Transfer, words: Int):
        self.id = id
        self.asked = asked
        self.name = name
        self.home = home
        self.max_cmd = max_cmd
        self.env = env^
        self.admin_key = admin_key
        self.daemon_port = daemon_port
        self.max_attempts = max_attempts
        self.unsandboxed = unsandboxed
        self.porter_env = porter_env^
        self.t = t.copy()
        self.words = words


struct W(Movable):
    """The worker's own state: the job's rows, its log and the processes it has running."""
    var id: Int
    var ref_: String
    var name: String
    var repo_id: String
    var model: String
    var status: String
    var stage: String
    var message: String
    var started_at: Float64
    var max_attempts: Int
    var stages: List[Stage]
    var tail: List[String]
    var dir: String
    var log: String
    var home: String
    var unsandboxed: Bool
    var t: Transfer
    var pids: List[Int]

    def __init__(out self, job: PortJob):
        self.id = job.id
        self.ref_ = job.asked
        self.name = job.name
        self.repo_id = ""
        self.model = ""
        self.status = "running"
        self.stage = "workspace"
        self.message = ""
        self.started_at = wall_seconds()
        self.max_attempts = job.max_attempts
        self.stages = List[Stage]()
        for n in materialize[STAGE_NAMES]():
            var is_attempt = False
            for a in materialize[ATTEMPT_STAGES]():
                if String(a) == String(n):
                    is_attempt = True
            self.stages.append(Stage.fresh(String(n), 1 if is_attempt else 0))
        self.tail = List[String]()
        self.dir = job.home + "/ports/" + String(job.id)
        self.log = self.dir + "/port.log"
        self.home = job.home
        self.unsandboxed = job.unsandboxed
        self.t = job.t.copy()
        self.pids = List[Int]()

    def say(mut self, line: String):
        """One line into port.log (and the tail the screen reads)."""
        for part in line.split("\n"):
            self.tail.append(String(part))
        while len(self.tail) > TAIL_LINES:
            _ = self.tail.pop(0)
        try:
            makedirs(self.dir, exist_ok=True)
            with open(self.log, "a") as f:
                f.write(line + "\n")
        except:
            pass

    def cancelled(self) -> Bool:
        return self.t.cancelled()

    def check(self) raises:
        if self.t.cancelled():
            raise Error("cancelled")

    def row(self, name: String, attempt: Int) -> Int:
        """The index of the last row with this name (and attempt, when given), or -1."""
        for i in reversed(range(len(self.stages))):
            if self.stages[i].name == name and (attempt == 0 or self.stages[i].attempt == attempt):
                return i
        return -1

    def save(mut self, mut store: Store):
        try:
            _ = store.db.run("UPDATE ports SET name = ?, repo_id = nullif(?, ''), status = ?, stage = ?, message = ?, stages = ?, model = nullif(?, '') WHERE id = ?",
                             [self.name, self.repo_id, self.status, self.stage, self.message, stages_json(self.stages), self.model, String(self.id)])
        except:
            pass

    def begin(mut self, mut store: Store, name: String, attempt: Int, detail: String) raises -> Int:
        self.check()
        var at = self.row(name, attempt)
        self.stages[at].status = "running"
        self.stages[at].started = wall_seconds()
        if detail != "":
            self.stages[at].detail = detail
        self.stage = name
        self.save(store)
        self.say("== " + name + (" (attempt " + String(attempt) + ")" if attempt > 0 else "") + (": " + detail if detail != "" else ""))
        return at

    def end(mut self, mut store: Store, at: Int, status: String, detail: String):
        self.stages[at].status = status
        self.stages[at].ended = wall_seconds()
        if detail != "":
            self.stages[at].detail = detail
        self.save(store)
        self.say("-- " + self.stages[at].name + " " + status + (": " + self.stages[at].detail if self.stages[at].detail != "" else ""))

    def detail(mut self, at: Int, text: String):
        self.stages[at].detail = text

    def add_attempt(mut self, attempt: Int):
        """A new set of attempt rows before `register`; what the failed attempt never reached reads "skipped"."""
        for i in range(len(self.stages)):
            if self.stages[i].status == "pending" and self.stages[i].attempt > 0:
                self.stages[i].status = "skipped"
        var at = self.row("register", 0)
        var fresh = List[Stage]()
        for n in materialize[ATTEMPT_STAGES]():
            fresh.append(Stage.fresh(String(n), attempt))
        var out = List[Stage]()
        for i in range(len(self.stages)):
            if i == at:
                for s in fresh:
                    out.append(s.copy())
            out.append(self.stages[i].copy())
        self.stages = out^

    def skip_rest(mut self):
        for i in range(len(self.stages)):
            if self.stages[i].status == "pending":
                self.stages[i].status = "skipped"

    def note_pids(mut self, mut store: Store):
        var listing = String("[")
        for i in range(len(self.pids)):
            listing += (", " if i > 0 else "") + String(self.pids[i])
        listing += "]"
        try:
            _ = store.db.run("UPDATE ports SET procs = nullif(?, '[]') WHERE id = ?", [listing, String(self.id)])
        except:
            pass

    def finish(mut self, mut store: Store, status: String, message: String):
        remove_tree_quietly(self.dir + "/work")  # private caches and the Claude config dir (never the login itself)
        self.status = status
        self.message = message
        self.pids = List[Int]()
        self.note_pids(store)
        try:
            _ = store.db.run("UPDATE ports SET status = ?, message = ?, finished_at = ?, stages = ?, model = nullif(?, ''), procs = NULL WHERE id = ?",
                             [status, message, String(wall_seconds()), stages_json(self.stages), self.model, String(self.id)])
            _ = store.db.run("DELETE FROM ports WHERE id <= (SELECT MAX(id) FROM ports) - ? AND status != 'running'", [String(KEEP_ROWS)])
        except:
            pass
        self.say("== " + status + ": " + message)


def remove_tree_quietly(path: String):
    try:
        if isdir(path):
            remove_tree(path)
    except:
        pass


# ---- the context of one port ------------------------------------------------------------------------------------

struct Ctx(Movable):
    var ref_: String
    var repo_id: String
    var revision: String
    var name: String
    var workspace: String
    var port_dir: String
    var skills_root: String
    var weights: String
    var gate: String  # the gate scripts' hash right after the clone was updated
    var serving_max: String
    var extra_allowed: List[String]
    var try_command: String
    var try_config: String

    def __init__(out self):
        self.ref_ = ""
        self.repo_id = ""
        self.revision = ""
        self.name = ""
        self.workspace = ""
        self.port_dir = ""
        self.skills_root = ""
        self.weights = ""
        self.gate = ""
        self.serving_max = ""
        self.extra_allowed = List[String]()
        self.try_command = ""
        self.try_config = ""


@fieldwise_init
struct Confined(Copyable, Movable):
    var argv: List[String]
    var env: List[String]
    var note: String


def weights_root(ctx: Ctx) -> String:
    return ctx.weights


def confine(mut w: W, job: PortJob, argv: List[String], role: String, ctx: Ctx, cwd: String) raises -> Confined:
    """(argv, env, note) for running `argv` as role "agent", "check" (the skill's gates), "serve" (the smoke `max
    serve`) or "install" (trusted, pristine code, never confined). The environment is scrubbed of secrets (claude
    keeps only its own auth, plus the porting assistant's key). Every cache a sandboxed process writes to lives in
    the job's private work/ dir, so nothing shared and later used outside the sandbox is writable from inside."""
    var env = scrub(env_names(), role == "agent")
    if role == "agent":
        for e in job.porter_env:
            env.append(e)
    if role == "install":
        return Confined(argv.copy(), env^, "trusted install of the pristine skill env, not sandboxed")
    var work = w.dir + "/work"
    var cache = work + "/cache"
    for d in ["", "/pixi", "/rattler", "/uv", "/xdg", "/modular", "/modular/cache", "/modular/max"]:
        makedirs(cache + String(d), exist_ok=True)
    makedirs(work + "/hf/hub", exist_ok=True)
    env += ["PIXI_CACHE_DIR=" + cache + "/pixi", "RATTLER_CACHE_DIR=" + cache + "/rattler", "UV_CACHE_DIR=" + cache + "/uv",
            "XDG_CACHE_HOME=" + cache + "/xdg", "MODULAR_DERIVED_PATH=" + cache + "/modular",
            "MODULAR_CACHE_DIR=" + cache + "/modular/cache", "MODULAR_MAX_CACHE_DIR=" + cache + "/modular/max",
            "HF_HOME=" + work + "/hf", "HF_HUB_CACHE=" + work + "/hf/hub", "HF_HUB_OFFLINE="]
    # (not offline: the verify gate reads safetensors metadata from the Hub; the HF token is scrubbed)
    env += job.env.copy()  # (how `max` is run: its install's CONDA_PREFIX, MODULAR_HOME and PATH)
    var binds = List[String]()
    var ws = ctx.workspace if ctx.workspace != "" else w.dir
    if role == "agent":
        var cfg = work + "/claude-cfg"
        makedirs(cfg, exist_ok=True)
        env.append("CLAUDE_CONFIG_DIR=" + cfg)
        var creds = getenv("CLAUDE_CONFIG_DIR", getenv("HOME") + "/.claude") + "/.credentials.json"
        if exists(creds):  # the one real login file, not a copy: a token refresh writes back to it
            binds.append(creds + ">" + cfg + "/.credentials.json")
    var bw = have_bwrap() if not w.unsandboxed else String("")
    if bw == "":
        var why = ("bubblewrap (bwrap) not found; unsandboxed was given" if not w.unsandboxed
                   else "the caller asked for no sandbox") + " — the agent runs with this user's own permissions, "
        why += "and Claude Code's own sandbox setting is not used in its place (D-6412)"
        for b in binds:  # no mount namespace: link the login into the private config dir instead
            var at = String(b).find(">")
            _ = output(["ln", "-sfn", String(String(b)[byte = : at]), String(String(b)[byte = at + 1 :])], 2000)
        return Confined(argv.copy(), env^, "NOT sandboxed (" + why + ")")
    var ro = tool_roots([argv[0], "pixi", "git", "bash"])
    var ro_after = List[String]()
    var rw = List[String]()
    if ctx.skills_root != "":
        ro.append(ctx.skills_root)  # the pristine clone, with its pre-installed env: read-only everywhere
    if role == "agent":
        # claude reads project settings from the workspace; the agent must not be able to widen its own permissions
        # there, so those files are bound read-only on top of the writable workspace
        makedirs(ws + "/.claude", exist_ok=True)
        for name in ["settings.json", "settings.local.json"]:
            var f = ws + "/.claude/" + String(name)
            if not exists(f):
                write_text(f, "{}\n")
            ro_after.append(f)
        rw = [ws, work]
        if ctx.weights != "":
            ro.append(ctx.weights)  # so the agent's own check_port.py runs use the local weights too
        if ctx.try_config != "":
            ro.append(ctx.try_config)
            ro.append(_self_dir())
    else:
        ro.append(ws)
        if ctx.weights != "":
            ro.append(ctx.weights)
        rw = [work]
    var note = "sandboxed with bubblewrap (read-only system and skills, empty $HOME and MXC_HOME, private /tmp and caches, writable: "
    for i in range(len(rw)):
        note += ("" if i == 0 else ", ") + rw[i]
    var c = Confine(cwd if cwd != "" else ws, getenv("HOME"), w.home, rw^, ro^, ro_after^, binds^, List[String](), True)
    # (gpu: MAX picks its device by what it can see; without the GPU, bf16 weights fail on CPU)
    return Confined(bwrap_argv(argv, bw, c), env^, note + ")")


def _self_dir() -> String:
    """The folder this binary runs from (bound read-only so the agent can run `consoled port-try`)."""
    var exe = String(output(["readlink", "-f", "/proc/self/exe"], 2000).strip())
    var cut = exe.rfind("/")
    return String(exe[byte = : cut]) if cut > 0 else String("/usr/bin")


# ---- running a command ------------------------------------------------------------------------------------------

def read_from(path: String, offset: Int) -> String:
    """What was appended to `path` after `offset` bytes ("" when there is nothing new)."""
    try:
        if not exists(path):
            return ""
        var size = getsize(path)
        if size <= offset:
            return ""
        with open(path, "r") as f:
            _ = f.seek(offset)
            return f.read()
    except:
        return ""


def render_event(line: String) -> List[String]:
    """One stream-json line from claude → readable log lines (the raw line when it is not JSON)."""
    var out = List[String]()
    if not line.strip().startswith("{"):
        out.append(line)
        return out^
    try:
        var j = Json.parse(line)
        var kind = j.text(j.get(0, "type"))
        if kind == "assistant":
            var content = j.get(j.get(0, "message"), "content")
            for k in range(j.size(content)):
                var b = j.at(content, k)
                var bk = j.text(j.get(b, "type"))
                if bk == "text":
                    var text = String(j.text(j.get(b, "text")).strip())
                    if text != "":
                        out.append("claude: " + text)
                elif bk == "tool_use":
                    var inp = j.get(b, "input")
                    var what = String("")
                    for field in ["command", "file_path", "pattern", "url"]:
                        if what == "":
                            what = j.text(j.get(inp, String(field)))
                    out.append(String(("claude> " + j.text(j.get(b, "name")) + " " + String(what[byte = : min(300, what.byte_length())])).strip()))
        elif kind == "user":
            var content2 = j.get(j.get(0, "message"), "content")
            for k in range(j.size(content2)):
                var b2 = j.at(content2, k)
                if j.text(j.get(b2, "type")) == "tool_result":
                    var body = j.get(b2, "content")
                    var text2 = String("")
                    if j.size(body) > 0:
                        for x in range(j.size(body)):
                            text2 += j.text(j.get(j.at(body, x), "text"))
                    else:
                        text2 = j.text(body)
                    var lines = String(text2.strip()).split("\n")
                    if len(lines) > 0 and String(lines[0]) != "":
                        var first = String(lines[0])
                        out.append("  " + String(first[byte = : min(300, first.byte_length())])
                                   + (" (+" + String(len(lines) - 1) + " more lines)" if len(lines) > 1 else ""))
        elif kind == "result":
            out.append("claude finished: " + j.text(j.get(0, "subtype"), "done"))
    except:
        out.append(line)
    return out^


@fieldwise_init
struct Ran(Copyable, Movable):
    var code: Int
    var output: String


def exec_cmd(mut w: W, mut store: Store, job: PortJob, argv: List[String], cwd: String, timeout_ms: Int, role: String,
             ctx: Ctx, raw: String, render: Bool) raises -> Ran:
    """Run a command in its own process group (confined, with a scrubbed environment), stream every line to the log,
    and return (exit code, the last of its output). Cancel and the timeout stop the whole group."""
    w.check()
    var c = confine(w, job, argv, role, ctx, cwd)
    w.say("[" + role + "] " + c.note)
    var shown = String("")
    for a in argv:
        shown += (" " if shown != "" else "") + a
    if shown.byte_length() > 600:
        shown = String(shown[byte = : 600]) + " …"
    w.say("$ " + shown + "   (cwd " + (cwd if cwd != "" else ctx.workspace) + ")")
    var raw_path = raw if raw != "" else w.dir + "/cmd.log"
    _ = libc.unlink(raw_path)
    var p: Process
    try:
        p = Process.start(c.argv, raw_path, c.env, cwd)
    except e:
        w.say("could not run " + c.argv[0] + ": " + String(e))
        return Ran(127, "could not run " + c.argv[0] + ": " + String(e))
    w.pids.append(p.pid)
    w.note_pids(store)
    var until = now_ns() + timeout_ms * 1_000_000
    var offset = 0
    var kept = List[String]()
    var timed_out = False
    var pending = String("")
    while True:
        var fresh = read_from(raw_path, offset)
        if fresh != "":
            offset += fresh.byte_length()
            pending += fresh
            var at = pending.rfind("\n")
            if at >= 0:
                var whole = String(pending[byte = : at])
                var rest = String(pending[byte = at + 1 :])
                pending = rest
                for line in whole.split("\n"):
                    kept.append(String(line))
                    while len(kept) > KEEP_LINES:
                        _ = kept.pop(0)
                    if render:
                        for out_line in render_event(String(line)):
                            w.say(out_line)
                    else:
                        w.say(String(line))
        elif not p.running():
            break
        if w.cancelled():
            _ = p.stop(2000)
            _drop_pid(w, p.pid)
            w.note_pids(store)
            raise Error("cancelled")
        if now_ns() > until:
            timed_out = True
            _ = p.stop(2000)
            break
        if fresh == "":
            _ = libc.poll(0, 0, POLL_MS)
    if String(pending.strip()) != "":
        kept.append(pending)
        if render:
            for out_line in render_event(pending):
                w.say(out_line)
        else:
            w.say(pending)
    var code = p.exit_code()
    _drop_pid(w, p.pid)
    w.note_pids(store)
    var text = String("")
    for k in kept:
        text += ("\n" if text != "" else "") + k
    if timed_out:
        w.say("timed out after " + String(timeout_ms // 1000) + "s")
        return Ran(124, text + "\n(timed out after " + String(timeout_ms // 1000) + "s)")
    return Ran(code, text^)


def _drop_pid(mut w: W, pid: Int):
    var keep = List[Int]()
    for p in w.pids:
        if p != pid:
            keep.append(p)
    w.pids = keep^


# ---- the workspace the agent reads ------------------------------------------------------------------------------

def gate_prefix(skills_root: String) -> String:
    """How the skill's own scripts are run: through its pixi environment, or whatever MXC_GATE_CMD names. The
    Python version made the gates injectable so its tests could run stand-ins (port_auto.PortTools); this is the
    same seam, and goal 64's check drives the fake-port harness through it."""
    var override = getenv("MXC_GATE_CMD")
    if override != "":
        return override
    return "pixi run --manifest-path " + skills_root + "/" + ENTRY_SKILL + "/pixi.toml python"


def skill_script_command(skills_root: String, script: String) -> String:
    """How the agent runs one of the skill's scripts from its workspace (it can't change into the skill root)."""
    var root = skills_root + "/" + ENTRY_SKILL
    return gate_prefix(skills_root) + " " + root + "/scripts/" + script


def skill_script_allowed(skills_root: String) -> List[String]:
    var out = List[String]()
    for n in materialize[SKILL_SCRIPTS]():
        out.append("Bash(" + skill_script_command(skills_root, String(n)) + ":*)")
    return out^


def port_md(ctx: Ctx, config: String, donor: Donor, serving_max: String) raises -> String:
    """The workspace's PORT.md (port.py _port_md): the model's key config fields, which lane and donor to start
    from, the scaffold line, the loop, and that the skill itself is the source of truth."""
    var j = Json.parse(config)
    var fields = String("")
    for k in materialize[KEY_FIELDS]():
        var node = j.get(0, String(k))
        if node >= 0:
            fields += "- `" + String(k) + "`: `" + _value_text(j, node) + "`\n"
    var skill = ctx.skills_root + "/" + ENTRY_SKILL
    var v3 = ("`" + donor.v3_slug() + "` at `" + donor.v3_dir + "`") if donor.v3_dir != "" else String(
        "no `_modulev3` twin; check whether a natively-V3 architecture fits (the skill names `olmo3`)")
    var v2 = ("`" + donor.slug() + "` at `" + donor.source_dir + "`") if donor.source_dir != "" else String("none found")
    var start = donor.v3_slug() if donor.v3_dir != "" else (donor.slug() if donor.source_dir != "" else String("<slug>"))
    var lane_note = String("")
    if donor.v3_dir == "":
        lane_note = "\nNo ModuleV3 donor was found, so this scaffold line is on the **V2 lane**. Switch to a natively-V3 donor (for example `olmo3`) if you want ModuleV3.\n"
    return ("# Port " + ctx.repo_id + " to MAX\n\n"
            + "- Target architecture: `" + j.text(j.at(j.get(0, "architectures"), 0)) + "` (config `model_type`: `" + j.text(j.get(0, "model_type"), "?") + "`)\n"
            + "- Hugging Face: https://huggingface.co/" + ctx.repo_id + " at revision `" + ctx.revision + "`\n"
            + "- The full config is in `config.json` next to this file.\n"
            + "- Source of truth: the `" + ENTRY_SKILL + "` skill (`" + skill + "/SKILL.md`). Follow it over this file.\n\n"
            + "## Key config fields\n\n" + fields + "\n"
            + "## 1. Choose the lane first\n\nMAX has two model APIs, and the donor must be on the same lane as the port.\n"
            + "- **ModuleV3** (default for single-GPU ports): donor " + v3 + "\n"
            + "- **V2** (only if the model needs distributed machinery ModuleV3 lacks): donor " + v2 + "\n\n"
            + "Closest supported architecture in MAX's catalog: `" + donor.architecture + "`. Why: " + donor.reason + ".\n\n"
            + "## 2. Scaffold from the donor\n\nFrom the skill root (`pixi install` there once):\n\n```\ncd " + skill
            + "\npixi run python scripts/scaffold.py " + ctx.repo_id + " --start-from " + start + " --output-dir "
            + _parent(ctx.port_dir) + " --slug " + _leaf(ctx.port_dir) + "\n```\n" + lane_note
            + "\nThe port dir is `" + ctx.port_dir + "` (the slug folder holding `arch.py` and an `__init__.py` that\n"
            + "exposes `ARCHITECTURES`). That folder is what `--custom-architectures` takes.\n\n"
            + "## 3. The loop\n\n1. Inspect: read `config.json` and the HF modeling code; list what differs from the donor.\n"
            + "2. Adapt from donor: edit the scaffolded files one layer at a time.\n"
            + "3. Load weights: map checkpoint tensor names onto your graph; loading must be strict.\n"
            + "4. Compile: fix shape and dtype errors.\n"
            + "5. Generate: serve the package and send a prompt (a cold compile takes 5 to 25 minutes).\n"
            + "6. Compare with the HF reference: logits and layer outputs against `transformers`. If output is wrong, use the `debug-model` skill.\n"
            + "7. Repeat from 2 until greedy tokens match.\n\n"
            + "## MAX versions\n\nomxconsole serves the port with MAX " + (serving_max if serving_max != "" else String("(unknown)"))
            + ", and the skill's pixi environment is pinned to it: a port built against another MAX fails to load.\n\n"
            + "Workspace: " + ctx.workspace + "\n")


def _value_text(j: Json, node: Int) -> String:
    """One config field as the agent should read it (a string quoted, a number plain, anything else by its kind)."""
    var k = j.kind(node)
    if k == J_STRING:
        return json_string(j.text(node))
    if k == J_NUMBER:
        return String(j.number(node)) if j.is_whole(node) else String(j.real(node))
    if k == J_BOOL:
        return "true" if j.flag(node) else "false"
    if k == J_NULL:
        return "null"
    if j.size(node) > 0:
        var out = String("[")
        for i in range(j.size(node)):
            out += (", " if i > 0 else "") + _value_text(j, j.at(node, i))
        return out + "]"
    return "…"


def _parent(path: String) -> String:
    var cut = path.rfind("/")
    return String(path[byte = : cut]) if cut > 0 else path


def _leaf(path: String) -> String:
    var cut = path.rfind("/")
    return String(path[byte = cut + 1 :]) if cut >= 0 else path


def build_prompt(ctx: Ctx, attempt: Int, feedback: String, donor_note: String) -> String:
    """port_auto.build_prompt, unchanged in substance: unattended, the skill phase by phase, the package folder
    named exactly, only the skill's own commands, and the error text fed back on a retry."""
    var serving = String("")
    if ctx.serving_max != "":
        serving = ("The port will be served by MAX " + ctx.serving_max + " (omxconsole's), which may be older than the MAX in "
                   + "the skill's environment: use only APIs that exist in " + ctx.serving_max + ", nothing newer.\n")
    var try_text = String("")
    if ctx.try_command != "":
        try_text = ("Once check_port.py passes, see your package actually run: `" + ctx.try_command + "` compiles it, serves it, sends a "
                    + "prompt, runs the skill's compare_layers probe and the same verify gates omxconsole's final check uses, then stops "
                    + "the server and prints a report ending in RESULT: PASS or FAIL. Run it with the Bash timeout set to 600000 ms. A "
                    + "cold compile can take 5 to 25 minutes: if it says \"still running\", run the same command again. Fix what a report "
                    + "shows before trying again. If it passes, you are done.\n\n")
    var base = ("You are porting a Hugging Face model to MAX, unattended. Nobody is available to answer questions or confirm a plan: "
                + "where the skill says to propose a plan and wait for a veto, state your default in one paragraph and carry on.\n\n"
                + "Model: " + ctx.repo_id + "\nWorkspace (your working directory): " + ctx.workspace + "\n"
                + "Read PORT.md and config.json here first. Follow the `" + ENTRY_SKILL + "` skill (.claude/skills/" + ENTRY_SKILL
                + "/SKILL.md; the skill root is " + ctx.skills_root + "/" + ENTRY_SKILL + ", read-only, with its pixi environment "
                + "already installed) for this model, phase by phase, and write the custom architecture package for it.\n\n"
                + donor_note + "\n" + serving + "Package folder: " + ctx.port_dir + "\n"
                + "That exact folder must end up holding arch.py and an __init__.py that exposes ARCHITECTURES. Scaffold with "
                + "`--output-dir " + _parent(ctx.port_dir) + " --slug " + _leaf(ctx.port_dir) + "` (or create it by hand). Do not write "
                + "outside the workspace, except by running the skill's own commands.\n\n"
                + "Run the skill's scripts exactly in this form (allowed from here; general shell commands such as ls, cat or grep are "
                + "refused, so use Read, Glob and Grep to look at files): `" + skill_script_command(ctx.skills_root, "<script>.py") + " …`.\n\n"
                + try_text + "You are done when `" + skill_script_command(ctx.skills_root, "check_port.py") + " "
                + (ctx.weights if ctx.weights != "" else ctx.repo_id) + " --port-dir " + ctx.port_dir + "` (the weights are already "
                + "downloaded there, read-only — use that path, not the repo id, or the model is downloaded again) passes and the "
                + "implementation-complete criteria in the skill are met. Do not start `max serve` any other way and do not install "
                + "packages with pip; omxconsole serves and verifies the port again afterwards, against the Hugging Face reference. "
                + "Finish with a short summary of what you changed.")
    if attempt <= 1 and feedback == "":
        return base^
    return (base + "\n\nThis is attempt " + String(attempt) + ". The package folder already exists from the previous attempt; fix it, "
            + "do not start over.\nThe last check failed with this output. Fix this:\n\n" + feedback)


def claude_argv(claude: String, prompt: String, extra: List[String]) -> List[String]:
    """The headless Claude Code call (port_auto.claude_argv, same flags): `-p` runs once and exits; acceptEdits lets
    it edit inside the workspace; the allow list covers the skill's scripts; anything that would prompt is denied;
    only the job-private user settings load, no MCP servers, no saved session; stream-json gives one event a line."""
    var argv: List[String] = [claude, "-p", prompt, "--permission-mode", "acceptEdits", "--permission-prompts", "none",
                              "--allowedTools"]
    argv += allowed_tools(extra)
    argv += ["--setting-sources", "project", "--strict-mcp-config", "--output-format", "stream-json", "--verbose",
             "--no-session-persistence"]
    return argv^


def try_config_json(ctx: Ctx, max_cmd: String, state_dir: String) -> String:
    """try-N.json: the agent's own "see it run" harness, with the final check's server and gates (D-6403). The
    serve flags are the ones the real runs earned (D-6404)."""
    var serve = String("[")
    for part in max_cmd.split(" "):
        if String(part) != "":
            serve += (", " if serve != "[" else "") + json_string(String(part))
    for f in ["serve", "--no-device-graph-capture"]:
        serve += ", " + json_string(String(f))
    for f in materialize[PARITY_SERVE_FLAGS]():
        serve += ", " + json_string(String(f))
    serve += ", " + json_string("--served-model-name") + ", " + json_string(ctx.repo_id)
    serve += ", " + json_string("--custom-architectures") + ", " + json_string(ctx.port_dir)
    serve += ", " + json_string("--model-path") + ", " + json_string(ctx.weights if ctx.weights != "" else ctx.repo_id)
    serve += "]"
    var probe = _script_argv(ctx, "compare_layers.py", [ctx.repo_id, "--served-model-name", ctx.repo_id, "--port", "{port}", "--skip-hf-layers"])
    var gates = _script_argv(ctx, "run_oss_gates.py", [ctx.repo_id, "--port-dir", ctx.port_dir, "--phase", "verify", "--port", "{port}",
                                                       "--served-model-name", ctx.repo_id])
    return ('{"serve": ' + serve + ', "probe": ' + probe + ', "gates": ' + gates + ', "cwd": ' + json_string(ctx.skills_root + "/" + ENTRY_SKILL)
            + ', "port_dir": ' + json_string(ctx.port_dir) + ', "repo_id": ' + json_string(ctx.repo_id)
            + ', "smoke_prompt": ' + json_string(SMOKE_PROMPT) + ', "state_dir": ' + json_string(state_dir)
            + ', "max_tries": 4, "budget_s": 5400, "health_timeout": 1500, "step_timeout": 900}')


def _script_argv(ctx: Ctx, script: String, args: List[String]) -> String:
    var out = String("[")
    for part in skill_script_command(ctx.skills_root, script).split(" "):
        if String(part) != "":
            out += (", " if out != "[" else "") + json_string(String(part))
    for a in args:
        out += ", " + json_string(a)
    return out + "]"


# ---- the pipeline -----------------------------------------------------------------------------------------------

def _pristine(mut w: W, mut store: Store, job: PortJob, mut ctx: Ctx) raises -> Fail:
    """Before a gate runs: the skill's check scripts must be exactly what was cloned. If the clone was touched,
    restore it from git; if it still differs, the gate does not count and the job fails (D-6404)."""
    if gate_hash(ctx.skills_root) == ctx.gate:
        return Fail.none()
    w.say("the skill's gate scripts were modified; restoring them from git")
    var paths = List[String]()
    for g in ["scripts", "pixi.toml", "SKILL.md"]:
        paths.append(ENTRY_SKILL + "/" + String(g))
    var argv: List[String] = ["git", "-C", ctx.skills_root, "checkout", "--"]
    argv += paths.copy()
    _ = output(argv, 60_000)
    var clean: List[String] = ["git", "-C", ctx.skills_root, "clean", "-fd", "--"]
    clean += paths.copy()
    _ = output(clean, 60_000)
    _ = apply_skill_patches(ctx.skills_root, ctx.serving_max)
    if gate_hash(ctx.skills_root) != ctx.gate:
        return Fail("the skill's check scripts in " + ctx.skills_root + " were modified and could not be restored; the build and parity checks cannot be trusted", False, "", 0)
    return Fail.none()


def _smoke(mut w: W, mut store: Store, mut p: Process, port: Int, ctx: Ctx, at: Int) raises -> Fail:
    """Wait for max serve to be healthy, then ask for a few greedy tokens."""
    var base = "http://127.0.0.1:" + String(port)
    var until = now_ns() + SMOKE_TIMEOUT_MS * 1_000_000
    while True:
        w.check()
        if not p.running():
            return Fail("max serve exited with code " + String(p.exit_code()) + " while loading the port", True,
                        "max serve exited while loading the port\n" + file_tail(w.log, 8000), 0)
        if now_ns() > until:
            return Fail("max serve was not healthy after " + String(SMOKE_TIMEOUT_MS // 1000) + "s", True,
                        "max serve never became healthy\n" + file_tail(w.log, 8000), 0)
        if healthy(base + "/health", 1000):
            break
        _ = libc.poll(0, 0, 500)
    w.detail(at, "serving; sending a prompt…")
    var body = ('{"model": ' + json_string(ctx.repo_id) + ', "prompt": ' + json_string(SMOKE_PROMPT)
                + ', "max_tokens": 16, "temperature": 0.0}')
    var req = Request(0, "POST", base + "/v1/completions", body).header("Content-Type", "application/json")
    var r = FlareTransport.send(req^.timeout(300_000))
    if r.error != "" or r.status != 200:
        return Fail("smoke generation failed: " + (r.error if r.error != "" else "HTTP " + String(r.status)), True,
                    "request failed\n" + file_tail(w.log, 8000), 0)
    var text = String("")
    try:
        var j = Json.parse(_body_text(r.body, len(r.body)))  # the whole reply: a real one is longer than 500 bytes
        text = j.text(j.get(j.at(j.get(0, "choices"), 0), "text"))
    except:
        pass
    w.say("smoke: '" + SMOKE_PROMPT + "' -> '" + text + "'")
    if String(text.strip()) == "":
        return Fail("smoke generation returned no text", True, "the server answered with no text\n" + file_tail(w.log, 8000), 0)
    return Fail.none()


def _parity(mut w: W, mut store: Store, job: PortJob, mut ctx: Ctx, at: Int) raises -> Fail:
    w.check()
    var port = free_port()
    w.detail(at, "compiling and serving on :" + String(port) + " (a cold compile takes 5 to 25 minutes)…")
    var argv = List[String]()
    for part in job.max_cmd.split(" "):
        if String(part) != "":
            argv.append(String(part))
    argv += ["serve", "--no-device-graph-capture"]
    for f in materialize[PARITY_SERVE_FLAGS]():
        argv.append(String(f))
    argv += ["--port", String(port), "--served-model-name", ctx.repo_id, "--custom-architectures", ctx.port_dir,
             "--model-path", ctx.weights if ctx.weights != "" else ctx.repo_id]
    var c = confine(w, job, argv, "serve", ctx, ctx.workspace)
    w.say("[serve] " + c.note)
    var shown = String("")
    for a in argv:
        shown += (" " if shown != "" else "") + a
    w.say("$ " + shown)
    var p: Process
    try:
        p = Process.start(c.argv, w.log, c.env, ctx.workspace)
    except e:
        return Fail("could not run " + job.max_cmd + ": " + String(e), False, "", 0)
    w.pids.append(p.pid)
    w.note_pids(store)
    var out = Fail.none()
    try:
        w.check()
        out = _smoke(w, store, p, port, ctx, at)
        if not out.failed():
            w.detail(at, "smoke passed; comparing with the Hugging Face reference…")
            var vc = _script_argv_list(ctx, "run_oss_gates.py", [ctx.repo_id, "--port-dir", ctx.port_dir, "--phase", "verify",
                                                                 "--port", String(port), "--served-model-name", ctx.repo_id])
            if not exists(ctx.skills_root + "/" + ENTRY_SKILL + "/scripts/run_oss_gates.py"):
                w.detail(at, "smoke generation passed (the skill has no verify gate to run)")
            else:
                var infra = String("")
                var ran = Ran(0, "")
                for retry in range(INFRA_RETRIES + 1):
                    var bad = _pristine(w, store, job, ctx)
                    if bad.failed():
                        out = bad^
                        break
                    ran = exec_cmd(w, store, job, vc, ctx.skills_root + "/" + ENTRY_SKILL, CHECK_TIMEOUT_MS, "check", ctx, "", False)
                    infra = infra_error(ran.output, p.running()) if ran.code != 0 else String("")
                    if infra == "" or retry == INFRA_RETRIES:
                        break
                    w.say("-- infrastructure error, not the port (" + infra + "); running the check again in "
                          + String(INFRA_BACKOFF_MS // 1000) + "s")
                    _pause(w, INFRA_BACKOFF_MS)
                if not out.failed():
                    if infra != "":
                        out = Fail("the comparison with Hugging Face kept failing for a reason that is not the port ("
                                   + infra + "); try again later", False, ran.output, 0)
                    elif ran.code != 0:
                        var passes = 0
                        for line in ran.output.split("\n"):
                            if String(line).find(" PASS") >= 0:
                                passes += 1
                        out = Fail("parity check failed (exit " + String(ran.code) + "): " + last_words(ran.output),
                                   True, ran.output, 3.0 + Float64(passes) / 100.0)
                    else:
                        w.detail(at, "matches the Hugging Face reference")
    except e:
        _ = p.stop(2000)
        _drop_pid(w, p.pid)
        w.note_pids(store)
        raise e
    _ = p.stop(5000)
    _drop_pid(w, p.pid)
    w.note_pids(store)
    return out^


def last_words(output: String, keep: Int = 200) -> String:
    """The last line of a command's output that says something (what a failed gate complained about)."""
    var lines = output.split("\n")
    for i in reversed(range(len(lines))):
        var l = String(String(lines[i]).strip())
        if l != "" and not _is_noise(l):
            return String(l[byte = : min(keep, l.byte_length())])
    return ""


def _is_noise(line: String) -> Bool:
    for w in ["%|", "it/s]", "s/it]"]:
        if line.find(String(w)) >= 0:
            return True
    return False


def _script_argv_list(ctx: Ctx, script: String, args: List[String]) -> List[String]:
    var out = List[String]()
    for part in skill_script_command(ctx.skills_root, script).split(" "):
        if String(part) != "":
            out.append(String(part))
    out += args.copy()
    return out^


def _pause(mut w: W, ms: Int) raises:
    var until = now_ns() + ms * 1_000_000
    while now_ns() < until:
        w.check()
        _ = libc.poll(0, 0, 200)


def _attempt(mut w: W, mut store: Store, job: PortJob, mut ctx: Ctx, attempt: Int, feedback: String, donor_note: String) raises -> Fail:
    """generate, build, parity once. Fail.none() on success, else the failure (retryable or not)."""
    var at = w.begin(store, "generate", attempt, "running Claude Code headless…" if attempt == 1 else "fixing…")
    var claude = which(getenv("MXC_CLAUDE", "claude"))
    if claude == "":
        w.end(store, at, "failed", NO_CLAUDE)
        return Fail(NO_CLAUDE, False, "", 0)
    ctx.try_command = ""
    ctx.try_config = ""
    var extra = ctx.extra_allowed.copy()
    if not w.unsandboxed and have_bwrap() != "":
        # try-port only under bubblewrap: its PID namespace takes a detached try down with the agent
        var state_dir = w.dir + "/work/try-" + String(attempt)
        makedirs(state_dir, exist_ok=True)
        # try-N.json is written for the record and for whoever carries the port on by hand; the agent is NOT
        # told to run it, because the harness that reads it is not built yet (D-6403, revised): telling it to run
        # a command that does not exist would waste a whole attempt on a 600 s timeout.
        ctx.try_config = w.dir + "/try-" + String(attempt) + ".json"
        write_text(ctx.try_config, try_config_json(ctx, job.max_cmd, state_dir))
    var argv = claude_argv(claude, build_prompt(ctx, attempt, feedback, donor_note), extra)
    var ran = exec_cmd(w, store, job, argv, ctx.workspace, GENERATE_TIMEOUT_MS, "agent", ctx,
                       w.dir + "/agent-" + String(attempt) + ".jsonl", True)
    if ran.code != 0:
        var msg = "claude exited with code " + String(ran.code) + (" (timed out)" if ran.code == 124 else "")
        w.end(store, at, "failed", msg)
        return Fail(msg, ran.code != 127, msg + ". Its last output:\n" + ran.output, 0)
    w.end(store, at, "done", "claude finished; package at " + ctx.port_dir)

    at = w.begin(store, "build", attempt, "checking the package…")
    var why = check_port_dir(ctx.port_dir)
    if why != "":
        w.end(store, at, "failed", why)
        return Fail("build failed: " + why, True, why, 0)
    var bad = _pristine(w, store, job, ctx)
    if bad.failed():
        w.end(store, at, "failed", bad.message)
        return bad^
    if not exists(ctx.skills_root + "/" + ENTRY_SKILL + "/scripts/check_port.py"):
        w.end(store, at, "done", "package layout is valid (the skill has no check_port.py to run)")
    else:
        var cmd = _script_argv_list(ctx, "check_port.py", [ctx.weights if ctx.weights != "" else ctx.repo_id, "--port-dir", ctx.port_dir])
        var r = exec_cmd(w, store, job, cmd, ctx.skills_root + "/" + ENTRY_SKILL, CHECK_TIMEOUT_MS, "check", ctx, "", False)
        if r.code != 0:
            # the gate's own last words go in the row, so the screen hands them over without opening the log
            var msg2 = "the build check failed (exit " + String(r.code) + "): " + last_words(r.output)
            w.end(store, at, "failed", msg2)
            return Fail("build failed: " + msg2, True, r.output, 1.0)
        w.end(store, at, "done", "the package imports and every weight maps")

    at = w.begin(store, "parity", attempt, "downloading weights…")
    var failure = _parity(w, store, job, ctx, at)
    if failure.failed():
        if failure.reached == 0:
            failure.reached = 2
        w.end(store, at, "failed", String(failure.message[byte = : min(300, failure.message.byte_length())]))
        return failure^
    w.end(store, at, "done", "")
    return Fail.none()


def _snapshot(mut w: W, ctx: Ctx) raises -> Bool:
    """Copy the agent's package to <job>/best (the attempt that got furthest is kept either way)."""
    if not isdir(ctx.port_dir):
        return False
    var dst = w.dir + "/best"
    remove_tree_quietly(dst)
    makedirs(dst, exist_ok=True)
    _ = output(["cp", "-a", ctx.port_dir + "/.", dst], 60_000)
    return exists(dst + "/arch.py") or exists(dst + "/__init__.py")


def _restore_best(mut w: W, ctx: Ctx, best_attempt: Int, best_reached: Float64, attempt: Int, reached: Float64) raises -> String:
    """If an earlier attempt got further than the last one, put its package back and say so."""
    if best_attempt == 0 or best_attempt == attempt or best_reached <= reached:
        return ""
    var old = ctx.port_dir + ".last-attempt"
    var fresh = ctx.port_dir + ".restoring"
    remove_tree_quietly(fresh)
    makedirs(fresh, exist_ok=True)
    _ = output(["cp", "-a", w.dir + "/best/.", fresh], 60_000)
    remove_tree_quietly(old)
    if isdir(ctx.port_dir):
        _ = libc.rename(ctx.port_dir, old)
    if libc.rename(fresh, ctx.port_dir) != 0:
        return (" Attempt " + String(best_attempt) + " got furthest (" + reached_text(best_reached) + "), but its package could not be "
                + "restored (a copy is in " + w.dir + "/best).")
    return (" Note: attempt " + String(best_attempt) + " got furthest (" + reached_text(best_reached) + "), so its package is restored in "
            + ctx.port_dir + " (the last attempt's is in " + _leaf(old) + ").")


def _pipeline(mut w: W, mut store: Store, job: PortJob) raises -> Fail:
    var ctx = Ctx()
    ctx.ref_ = job.asked
    # workspace ---------------------------------------------------------------------------------------------------
    var at = w.begin(store, "workspace", 0, "looking up " + job.asked + "…")
    var repo = hub_repo(repo_of(job.asked))
    ctx.repo_id = repo.id
    ctx.revision = repo.sha
    w.repo_id = repo.id
    var cfg_at = -1
    for i in range(len(repo.files)):
        if repo.files[i].name == "config.json":
            cfg_at = i
    if cfg_at < 0:
        return Fail(repo.id + " has no config.json: not a transformers model MAX could serve.", False, "", 0)
    ctx.name = job.name if job.name != "" else model_name(job.asked, repo.id)
    if not port_name_ok(ctx.name):  # the name derived from the ref is not a safe path component either
        return Fail("`" + ctx.name + "` is not a name a port can be registered under: pass a name of letters, digits, "
                    + "'.', '_' and '-'.", False, "", 0)
    w.name = ctx.name
    ctx.workspace = job.home + "/ports/" + workspace_name(ctx.name)
    if ctx.workspace.find("/..") >= 0 or _parent(ctx.workspace) != job.home + "/ports":
        return Fail("the workspace for this port would be outside " + job.home + "/ports", False, "", 0)
    makedirs(ctx.workspace, exist_ok=True)
    var r = hub_download(repo, repo.files[cfg_at], ctx.workspace, w.t)
    if r.error != "" or r.status != 200:
        return Fail("could not read " + repo.id + "'s config.json: " + (r.error if r.error != "" else "HTTP " + String(r.status)), False, "", 0)
    var config = read_text(ctx.workspace + "/config.json")
    var j = Json.parse(config)
    var arch = j.text(j.at(j.get(0, "architectures"), 0))
    var cat_text = catalog(job.home, job.max_cmd, job.env)
    var names = catalog_names(cat_text)
    for n in names:
        if n == arch:
            return Fail(repo.id + " (" + arch + ") is already supported by MAX: pull it instead of porting it.", False, "", 0)
    var taken = store.db.one_text("SELECT repo_id FROM models WHERE name = ?", [ctx.name])
    if taken != "" and taken.lower() != repo.id.lower():
        return Fail("the name `" + ctx.name + "` is already registered for " + taken + "; pick another name", False, "", 0)
    var donor = pick_donor(arch, j.text(j.get(0, "model_type")), names, max_arch_dir(job.max_cmd))
    ctx.port_dir = ctx.workspace + "/port/" + package_slug(ctx.name)
    var donor_note = ("Closest supported architecture in MAX (donor): " + donor.architecture
                      + ((" (" + donor.slug() + ")") if donor.slug() != "" else "") + ". " + donor.reason + ".")
    if j.get(0, "auto_map") >= 0:
        w.say("-- warning: " + repo.id + " names Python code on the Hub for its config class (auto_map). `max serve` won't run "
              + "remote code, so this port may be refused at the build gate however good the package is.")
    w.end(store, at, "done", arch + ", donor " + donor.architecture + ", workspace " + ctx.workspace)

    # skills ------------------------------------------------------------------------------------------------------
    at = w.begin(store, "skills", 0, "installing Modular's skills…")
    ctx.skills_root = job.home + "/skills/modular"
    var paths = List[String]()
    for g in ["scripts", "pixi.toml", "SKILL.md"]:
        paths.append(ENTRY_SKILL + "/" + String(g))
    # the real repo is pinned to SKILLS_REV (D-6416); a stand-in repo (MXC_SKILLS_REPO, the goal 64 harness) follows its HEAD.
    # Either way: fetch it, then check out exactly what was fetched (a branch, a tag or a full commit id; a
    # clone left detached by an earlier run moves on too)
    var rev = getenv("MXC_SKILLS_REV", SKILLS_REV if getenv("MXC_SKILLS_REPO") == "" else "")
    if isdir(ctx.skills_root + "/.git"):
        var argv: List[String] = ["git", "-C", ctx.skills_root, "checkout", "--"]  # drop our own patches, or git refuses to move
        argv += paths.copy()
        _ = output(argv, 60_000)
    else:
        makedirs(_parent(ctx.skills_root), exist_ok=True)
        var out = output(["git", "clone", "--depth", "1", getenv("MXC_SKILLS_REPO", SKILLS_REPO), ctx.skills_root], 600_000)
        if not isdir(ctx.skills_root + "/" + ENTRY_SKILL):
            return Fail("could not install Modular's skills from " + SKILLS_REPO + ": " + String(out[byte = : min(300, out.byte_length())]), False, "", 0)
    var want = rev if rev != "" else String("HEAD")
    try:
        remove(ctx.skills_root + "/.git/FETCH_HEAD")  # a failed fetch must not leave an earlier run's tip to check out
    except:
        pass
    var fetched = output(["git", "-C", ctx.skills_root, "fetch", "-q", "origin", want], 180_000)
    var tip = String(output(["git", "-C", ctx.skills_root, "rev-parse", "--verify", "-q", "FETCH_HEAD^{commit}"], 30_000).strip())
    if tip != "":
        _ = output(["git", "-C", ctx.skills_root, "checkout", "-q", "--detach", tip], 60_000)
    var head = String(output(["git", "-C", ctx.skills_root, "rev-parse", "HEAD"], 30_000).strip())
    if tip == "" or head != tip or (rev.byte_length() == 40 and head != rev):
        return Fail("could not check Modular's skills out at " + want + (", the commit that matches the serving MAX" if rev != "" else "")
                    + " (HEAD is " + head + "): " + String(fetched[byte = : min(300, fetched.byte_length())]), False, "", 0)
    if rev != "":
        w.say("-- Modular's skills at " + head[byte = : 7] + ", the commit that matches the serving MAX")
    if not isdir(ctx.skills_root + "/" + ENTRY_SKILL):
        return Fail("Modular's skills in " + ctx.skills_root + " have no " + ENTRY_SKILL + " skill", False, "", 0)
    ctx.serving_max = max_version(job.max_cmd)
    for note in apply_skill_patches(ctx.skills_root, ctx.serving_max):
        w.say("-- patched Modular's skill: " + note)
    for note in stale_patches(ctx.skills_root):
        w.say("-- warning: " + note)
    if ctx.serving_max == "":
        w.say("-- warning: omxconsole's MAX version is unknown, so the skill's environment is not pinned to it")
    else:
        var manifest = String("")
        try:
            manifest = read_text(ctx.skills_root + "/import-model/pixi.toml")
        except:
            manifest = ""
        if manifest != "" and not max_pinned(manifest, ctx.serving_max):
            return Fail("could not pin the MAX in " + ctx.skills_root + "/import-model/pixi.toml to " + ctx.serving_max
                        + ", the version that will serve the port; a port built against another MAX fails to load", False, "", 0)
    ctx.gate = gate_hash(ctx.skills_root)
    var skills = _link_skills(ctx)
    write_text(ctx.workspace + "/PORT.md", port_md(ctx, config, donor, ctx.serving_max))
    ctx.extra_allowed = skill_script_allowed(ctx.skills_root)
    for d in [donor.source_dir, donor.v3_dir]:
        if String(d) != "":
            ctx.extra_allowed.append("Bash(cp -r " + String(d) + "/:*)")
    if exists(ctx.skills_root + "/" + ENTRY_SKILL + "/pixi.toml") and getenv("MXC_GATE_CMD") == "":
        w.detail(at, "installing the skill's environment (outside the sandbox; the first time takes a while)…")
        var ran = exec_cmd(w, store, job, ["pixi", "install"], ctx.skills_root + "/" + ENTRY_SKILL, INSTALL_TIMEOUT_MS,
                           "install", ctx, "", False)
        if ran.code != 0:
            return Fail("could not install the skill's pixi environment (exit " + String(ran.code) + "): "
                        + String(ran.output[byte = max(0, ran.output.byte_length() - 300) :]), False, "", 0)
    w.detail(at, "downloading the weights of " + repo.id + " (once, outside the sandbox)…")
    w.say("-- downloading the weights of " + repo.id + " (once, outside the sandbox)…")
    ctx.weights = _download_weights(w, repo, job)
    w.end(store, at, "done", String(skills) + " skills in " + ctx.skills_root + ", read-only for the agent and the gates; weights at " + ctx.weights)

    # the attempts ------------------------------------------------------------------------------------------------
    var feedback = String("")
    var previous = String("")
    var best_attempt = 0
    var best_reached = 0.0
    for attempt in range(1, job.max_attempts + 1):
        if attempt > 1:
            w.add_attempt(attempt)
        var err = _attempt(w, store, job, ctx, attempt, feedback, donor_note)
        if not err.failed():
            break
        if (best_attempt == 0 or err.reached > best_reached) and _snapshot(w, ctx):
            best_attempt = attempt
            best_reached = err.reached
        var signature = failure_signature(err.message, err.output, err.reached)
        var same = signature == previous
        previous = signature
        feedback = err.output if err.output != "" else err.message
        if feedback.byte_length() > FEEDBACK_CHARS:
            var cut = String(feedback[byte = feedback.byte_length() - FEEDBACK_CHARS :])
            feedback = cut
        if not err.retry or attempt == job.max_attempts or same:
            var tried = (" after " + String(attempt) + (" attempts" if attempt != 1 else " attempt")) if err.retry else String("")
            var why = " (the same failure twice in a row, so another attempt is unlikely to help)" if same and err.retry else String("")
            var kept = _restore_best(w, ctx, best_attempt, best_reached, attempt, err.reached) if err.retry else String("")
            return Fail(err.message + tried + why + "." + kept + " Full log: " + w.log, False, err.output, err.reached)
        w.say("attempt " + String(attempt) + " failed: " + err.message + ". Trying again with the error fed back.")

    # register ----------------------------------------------------------------------------------------------------
    at = w.begin(store, "register", 0, "adding " + ctx.name + " (port " + ctx.port_dir + ")…")
    _ = store.db.run("""INSERT INTO models (name, repo_id, revision, source, architecture, weights_path, custom_arch_path, kind, created_at)
        VALUES (?, ?, ?, 'port', ?, ?, ?, 'chat', ?) ON CONFLICT(name) DO UPDATE SET revision = excluded.revision,
        weights_path = excluded.weights_path, architecture = excluded.architecture, custom_arch_path = excluded.custom_arch_path, source = 'port'""",
                     [ctx.name, repo.id, repo.sha, arch, ctx.weights, ctx.port_dir, String(wall_seconds())])
    w.model = ctx.name
    w.end(store, at, "done", "registered " + ctx.name + " with custom architecture " + ctx.port_dir)

    # serve -------------------------------------------------------------------------------------------------------
    at = w.begin(store, "serve", 0, "starting " + ctx.name + "…")
    if job.daemon_port <= 0:
        w.end(store, at, "skipped", "no server attached; the model starts on its first request")
    else:
        var req = Request(0, "POST", "http://127.0.0.1:" + String(job.daemon_port) + "/admin/models/" + ctx.name + "/load", "{}")
        var reply = FlareTransport.send(req^.header("X-Mst-Admin", job.admin_key).timeout(SERVE_TIMEOUT_MS))
        if reply.error != "" or reply.status != 200:
            return Fail(ctx.name + " is registered but did not start: " + (reply.error if reply.error != "" else _body_text(reply.body)), False, "", 0)
        w.end(store, at, "done", ctx.name + " is up")
    w.finish(store, "done", "Ported " + ctx.name + " (" + repo.id + "@" + String(repo.sha[byte = : 8]) + ") and serving it.")
    return Fail.none()


def _body_text(body: List[UInt8], limit: Int = 500) -> String:
    """The reply's first `limit` bytes as text (500: enough for an error message, never enough to parse)."""
    var bytes = List[UInt8]()
    for i in range(min(limit, len(body))):
        bytes.append(body[i])
    return String(unsafe_from_utf8=bytes)


def _link_skills(ctx: Ctx) -> Int:
    """Every skill in the clone linked into the workspace's .claude/skills (read-only for the agent)."""
    var target = ctx.workspace + "/.claude/skills"
    var n = 0
    try:
        makedirs(target, exist_ok=True)
        for name in listdir(ctx.skills_root):
            var src = ctx.skills_root + "/" + String(name)
            if not exists(src + "/SKILL.md"):
                continue
            _ = output(["ln", "-sfn", src, target + "/" + String(name)], 5000)
            n += 1
    except:
        pass
    return n


def _download_weights(mut w: W, repo: HubRepo, job: PortJob) raises -> String:
    """The model's weights, once, outside any sandbox (the pull's own folder and file list)."""
    var folder = folder_of(job.home, repo.id)
    makedirs(folder, exist_ok=True)
    var shards = List[String]()
    for i in range(len(repo.files)):
        if repo.files[i].name.endswith(".safetensors.index.json"):
            var r = hub_download(repo, repo.files[i], folder, w.t)
            if r.error == "" and r.status == 200:
                var idx = Json.parse(read_text(folder + "/" + repo.files[i].name))
                var wm = idx.get(0, "weight_map")
                for k in range(idx.size(wm)):
                    var s = idx.text(idx.at(wm, k))
                    if s not in shards:
                        shards.append(s)
    for k in wanted(repo, shards):
        w.check()
        ref f = repo.files[k]
        if exists(folder + "/" + f.name) and getsize(folder + "/" + f.name) == f.size:
            continue
        var r = hub_download(repo, f, folder, w.t)
        if r.error != "":
            raise Error(r.error)
        if r.status != 200:
            raise Error("Hugging Face answered " + String(r.status) + " for " + f.name)
    return folder^


def max_version(max_cmd: String) -> String:
    """The MAX that omxconsole serves with (`max --version`), which the skill's environment is pinned to."""
    var argv = List[String]()
    for part in max_cmd.split(" "):
        if String(part) != "":
            argv.append(String(part))
    argv.append("--version")
    var text = output(argv, 60_000)
    for word in text.split():
        var w = String(word)
        if w.byte_length() > 0 and Int(w.as_bytes()[0]) >= 48 and Int(w.as_bytes()[0]) <= 57 and w.find(".") > 0:
            return w^
    return ""


# ---- the worker thread ------------------------------------------------------------------------------------------

def _work(addr: Int):
    var p = Pointer[PortJob, MutUntrackedOrigin](unsafe_from_address=addr)
    var words = p[].words
    try:
        var store = Store(p[].home + "/mst.db")
        var w = W(p[])
        try:
            var bad = _pipeline(w, store, p[])
            if bad.failed():
                _fail(w, store, bad.message)
        except e:
            if w.cancelled() or String(e) == "cancelled":
                for i in range(len(w.stages)):
                    if w.stages[i].status == "running":
                        w.stages[i].status = "cancelled"
                        w.stages[i].ended = wall_seconds()
                w.skip_rest()
                w.finish(store, "cancelled", "Cancelled. The agent and its commands were stopped; the workspace is kept.")
            else:
                _fail(w, store, String(e))
    except e:  # (the store wouldn't open, or writing the outcome failed: try once more so the row never stays running)
        try:
            var store2 = Store(p[].home + "/mst.db")
            _ = store2.db.run("UPDATE ports SET status = 'failed', message = ?, finished_at = ? WHERE id = ?",
                              ["The port stopped: " + String(e), String(wall_seconds()), String(p[].id)])
        except:
            pass
    p.unsafe_deinit_pointee()
    p.unsafe_free()
    _A.store(_P(unsafe_from_address=words), 1)  # (the last thing: the daemon frees the words and the Transfer after this)


def _fail(mut w: W, mut store: Store, message: String):
    for i in range(len(w.stages)):
        if w.stages[i].status == "running":
            w.stages[i].status = "failed"
            w.stages[i].ended = wall_seconds()
            if w.stages[i].detail == "" or message.byte_length() < 300:
                w.stages[i].detail = String(message[byte = : min(300, message.byte_length())])
    w.skip_rest()
    w.finish(store, "failed", message)


# ---- the daemon's side ------------------------------------------------------------------------------------------

@fieldwise_init
struct RunningPort(Copyable, Movable):
    var id: Int
    var t: Transfer
    var words: Int


@fieldwise_init
struct Started(Copyable, Movable):
    """What POST /admin/ports answers: an id, or a refusal with the Python daemon's own error code."""
    var id: Int
    var code: String  # "" started; invalid_request_body, no_sandbox, linux_only, port_in_progress
    var message: String
    var busy: Int


struct Ports(Movable):
    """The daemon's running ports: their cancel flags, freed once their worker ended."""
    var running: List[RunningPort]

    def __init__(out self):
        self.running = List[RunningPort]()

    def start(mut self, mut store: Store, raw_ref: String, name: String, max_attempts: Int, unsandboxed: Bool,
              home: String, max_cmd: String, env: List[String], admin_key: String, daemon_port: Int,
              porter_env: List[String]) raises -> Started:
        var why = ref_problem(raw_ref)
        if why != "":
            return Started(0, "invalid_request_body", why, 0)
        var asked = hub_ref(raw_ref)  # (a pasted huggingface.co link, as owner/name from here on)
        # `name` becomes a folder under MXC_HOME/ports that is bound read-write into the agent's sandbox, so it is
        # checked here, at the boundary, exactly as the Python did (pulls.py NAME_RE): without this, "name": ".."
        # binds MXC_HOME itself writable into the sandbox, where porter.json and mst.db live (security audit).
        if name != "" and not port_name_ok(name):
            return Started(0, "invalid_request_body", "`name` may use letters, digits, '.', '_' and '-' (64 characters at most).", 0)
        if max_attempts < 1 or max_attempts > MAX_ATTEMPTS:
            return Started(0, "invalid_request_body", "`max_attempts` must be a whole number from 1 to " + String(MAX_ATTEMPTS) + ".", 0)
        if not CompilationTarget.is_linux():
            return Started(0, "linux_only", "Automatic port runs only on Linux for now: it confines the agent with bubblewrap, "
                           + "which is Linux-only. On this machine, port " + asked + " with your own Claude Code.", 0)
        if not unsandboxed and have_bwrap() == "":
            return Started(0, "no_sandbox", NO_SANDBOX, 0)
        var want = model_name(asked, repo_of(asked)) if name == "" else name
        for r in self.running:
            var row = store.db.one_text("SELECT lower(ref) || '|' || coalesce(name, '') FROM ports WHERE id = ? AND status = 'running'", [String(r.id)])
            if row == "":
                continue
            var bar = row.find("|")
            if String(row[byte = : bar]) == repo_of(asked).lower() or String(row[byte = bar + 1 :]) == want:
                return Started(0, "port_in_progress", String(row[byte = : bar]) + " is already being ported.", r.id)
        _ = store.db.run("INSERT INTO ports (ref, name, status, stage, message, started_at, max_attempts) VALUES (?, ?, 'running', 'workspace', ?, ?, ?)",
                         [asked, want, "looking up " + asked + "…", String(wall_seconds()), String(max_attempts)])
        var id = Int(atol(store.db.one_text("SELECT last_insert_rowid()")))
        var words = unsafe_alloc[Int64](1)
        words[0] = 0
        var t = Transfer()
        var job = unsafe_alloc[PortJob](1)
        job.unsafe_write(PortJob(id, asked, want, home, max_cmd, env.copy(), admin_key, daemon_port, max_attempts,
                                 unsandboxed, porter_env.copy(), t, Int(words)))
        if not spawn[_work](Int(job)):
            _ = store.db.run("UPDATE ports SET status = 'failed', message = 'no thread for the port', finished_at = ? WHERE id = ?",
                             [String(wall_seconds()), String(id)])
            job.unsafe_deinit_pointee()
            job.unsafe_free()
            t.free()
            words.unsafe_free()
            return Started(id, "", "", 0)
        self.running.append(RunningPort(id, t.copy(), Int(words)))
        return Started(id, "", "", 0)

    def cancel(mut self, id: Int) -> Bool:
        """Sets the job's cancel flag: its worker stops the agent's process group within a poll."""
        for r in self.running:
            if r.id == id:
                r.t.cancel()
                return True
        return False

    def sweep(mut self):
        var keep = List[RunningPort]()
        for i in range(len(self.running)):
            var r = self.running[i].copy()
            if _A.load(_P(unsafe_from_address=r.words)) != 0:
                r.t.free()
                _P(unsafe_from_address=r.words).unsafe_free()
                continue
            keep.append(r^)
        self.running = keep^

    def cancel_all(mut self, grace_ms: Int = 3000):
        """A stopping daemon must not leave an agent running (port_auto.cleanup_at_exit waited too): the flag is
        set, then this waits for each worker to say it has let go — it is the worker that stops the process group,
        so leaving before it does would orphan the agent (bwrap's --die-with-parent covers only sandboxed runs)."""
        for r in self.running:
            r.t.cancel()
        var until = now_ns() + grace_ms * 1_000_000
        while now_ns() < until:
            var busy = False
            for r in self.running:
                if _A.load(_P(unsafe_from_address=r.words)) == 0:
                    busy = True
            if not busy:
                return
            _ = libc.poll(0, 0, 50)
