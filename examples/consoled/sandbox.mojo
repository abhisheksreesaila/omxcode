# Confinement for the automatic port (the Python daemon's port_sandbox.py, same layout and the same bwrap argv,
# D-6401): the model's config.json and model card are untrusted input, so the agent that reads them, and the code it
# writes, run in a bubblewrap sandbox with a scrubbed environment. Inside the sandbox:
#   /          read-only        (so the toolchain under /usr, /etc, pixi and claude installs just works)
#   $HOME      empty tmpfs      (no ~/.ssh, ~/.aws, ~/.config …), then only what is listed is bound back
#   MXC_HOME   empty tmpfs      (no mst.db, no API keys, no other models), then the job dirs are bound back
#   /tmp       private tmpfs;  /run/user hidden (agent sockets);  new pid/ipc/uts namespaces
#   writable   only the paths in `rw` (the workspace, the job dir, the toolchain caches)
#   network    kept: claude needs the API, the skill's pixi env needs conda and Hugging Face
# `bwrap_argv` and `scrub` are pure functions: tests/test_port_sandbox.mojo asserts their argv.

from std.os import getenv
from std.sys import CompilationTarget
from std.os.path import exists
from mojoui import libc
from mojoui.process import output

# A name that looks like a credential, and the agent sockets, are dropped from every child's environment.
comptime SECRET_WORDS = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "COOKIE"]
comptime ALWAYS_DROP = ["SSH_AUTH_SOCK", "SSH_AGENT_PID", "DBUS_SESSION_BUS_ADDRESS", "GPG_AGENT_INFO", "MXC_API_KEY",
                        "HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACE_HUB_TOKEN"]
# The daemon may itself run under `pixi run`: its activation points at a manifest the sandbox can't see, so a
# `pixi run` inside would fail to open it. (The caches stay; they are set per job.)
comptime OUTER_ACTIVATION = ["PIXI_PROJECT_", "PIXI_ENVIRONMENT_", "PIXI_IN_SHELL", "PIXI_PROMPT", "CONDA_"]
# What the claude process itself may keep to authenticate (the OAuth login is bound into its private config dir
# instead; these cover API-key and cloud-provider setups).
comptime CLAUDE_AUTH = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL",
                        "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_PROFILE", "AWS_REGION",
                        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "GOOGLE_APPLICATION_CREDENTIALS"]


def env_names() -> List[String]:
    """Every name in this process's environment."""
    var out = List[String]()
    var env = libc.environ()
    var i = 0
    while env != 0:
        var entry = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=env + i * 8)[]
        if entry == 0:
            break
        var text = _c_text(entry)
        var eq = text.find("=")
        if eq > 0:
            out.append(String(text[byte = : eq]))
        i += 1
    return out^


def _c_text(addr: Int) -> String:
    var n = 0
    while Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr + n)[] != 0:
        n += 1
    var bytes = List[UInt8]()
    for k in range(n):
        bytes.append(Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr + k)[])
    return String(unsafe_from_utf8=bytes)


def looks_secret(name: String) -> Bool:
    var up = name.upper()
    for w in materialize[SECRET_WORDS]():
        if up.find(String(w)) >= 0:
            return True
    for d in materialize[ALWAYS_DROP]():
        if name == String(d):
            return True
    for p in materialize[OUTER_ACTIVATION]():
        if name.startswith(String(p)):
            return True
    return False


def scrub(names: List[String], keep_auth: Bool) -> List[String]:
    """port_sandbox.scrub_env, as mojoui.process overrides: "NAME=" removes NAME from the child's environment.
    Every name that looks like a credential goes; with `keep_auth` (the claude process itself) the names claude
    authenticates with stay."""
    var out = List[String]()
    for n in names:
        if not looks_secret(n):
            continue
        var kept = False
        if keep_auth:
            for k in materialize[CLAUDE_AUTH]():
                if n == String(k):
                    kept = True
        if not kept:
            out.append(n + "=")
    return out^


def have_bwrap(path: String = "bwrap") -> String:
    """The bwrap on PATH, or "" (Linux only: bubblewrap is Linux-only)."""
    if not CompilationTarget.is_linux():
        return ""
    return which(path)


def which(exe: String) -> String:
    if exe.find("/") >= 0:
        return exe if exists(exe) else String("")
    var dirs = getenv("PATH", "/usr/bin:/bin")
    for d in dirs.split(":"):
        var dir = String(d)
        if dir == "":
            continue
        if exists(dir + "/" + exe):
            return dir + "/" + exe
    return ""


def real_path(path: String) -> String:
    """`path` with symlinks resolved (readlink -f), or `path` when that can't be answered."""
    var text = String(output(["readlink", "-f", path], 2000).strip())
    return text if text != "" and text.startswith("/") else path


def tool_roots(exes: List[String]) -> List[String]:
    """Install prefixes of these executables (the parent of their bin dir, resolved and not), so a toolchain
    that lives under $HOME (mise, pixi, a pixi env) can be bound back read-only."""
    var out = List[String]()
    for exe in exes:
        var found = which(exe)
        if found == "":
            continue
        for p in [found, real_path(found)]:
            var cut = String(p).rfind("/")
            if cut <= 0:
                continue
            var parent = String(String(p)[byte = : cut])
            var root = parent
            if parent.endswith("/bin"):
                var up = parent.rfind("/")
                root = String(parent[byte = : up]) if up > 0 else String("/")
            if root != "/" and root != "" and root not in out:
                out.append(root)
    return out^


@fieldwise_init
struct Confine(Copyable, Movable):
    """What one confined command needs: the writable and read-only paths, and the binds."""
    var cwd: String
    var home: String
    var mxc_home: String
    var rw: List[String]
    var ro: List[String]
    var ro_after: List[String]  # read-only files inside a writable directory (the agent's settings.json)
    var binds: List[String]  # "src>dst", read-write (the Claude login)
    var ro_binds: List[String]  # "src>dst", read-only (the model's weights in a private HF cache)
    var gpu: Bool


def bwrap_argv(argv: List[String], bwrap: String, c: Confine) -> List[String]:
    """`argv` wrapped to run confined (port_sandbox.bwrap_argv, same order: tmpfs first, then the binds on top of
    it, and `ro_after` last). Paths are bound at the same place when they exist (ro-bind-try / bind-try)."""
    var out: List[String] = [bwrap, "--die-with-parent", "--new-session", "--unshare-pid", "--unshare-ipc",
                             "--unshare-uts", "--ro-bind", "/", "/"]
    if c.gpu:
        out += ["--dev-bind", "/dev", "/dev"]
    else:
        out += ["--dev", "/dev"]
    out += ["--proc", "/proc", "--tmpfs", "/tmp", "--tmpfs", "/run/user", "--tmpfs", c.home, "--tmpfs", c.mxc_home]
    for p in c.ro:
        out += ["--ro-bind-try", p, p]
    for p in c.rw:
        out += ["--bind-try", p, p]
    for b in c.binds:
        out += ["--bind-try", _src(b), _dst(b)]
    for b in c.ro_binds:
        out += ["--ro-bind-try", _src(b), _dst(b)]
    for p in c.ro_after:
        out += ["--ro-bind-try", p, p]
    out += ["--chdir", c.cwd, "--"]
    out += argv.copy()
    return out^


def _src(bind: String) -> String:
    var at = bind.find(">")
    return String(bind[byte = : at]) if at > 0 else bind


def _dst(bind: String) -> String:
    var at = bind.find(">")
    return String(bind[byte = at + 1 :]) if at > 0 else bind
