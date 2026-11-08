# consoled's porting assistant (goal 64 M0): which frontier model writes a port. Either Claude Code on this machine
# (detected, no key needed) or an API key for a frontier model — Anthropic's, or a gateway's base URL that
# answers for one. Frontier models only: nothing in the owner's 14 real runs says a small local model can write a
# MAX architecture, so offering one would be a dead end of its own.
# The key lives in MXC_HOME/porter.json, mode 0600, never in the store and never in a URL (D-6405): only its prefix
# is ever answered or logged, and the whole file goes when the setting is removed. It reaches the agent as
# environment variables on the claude process alone (ports.mojo's `porter_env`), which is how Claude Code takes a
# key; the sandbox scrubs every other credential from that process.

from std.os.path import exists
from mojoui.http import Request, Response
from mojoui.http_flare import FlareTransport
from mojoui.json import Json, json_string
from mojoui.workbook import read_text, write_text
from mojoui import libc
from sandbox import which

comptime PORTER_KINDS = ["claude-code", "anthropic", "openai-compatible"]
comptime TEST_TIMEOUT_MS = 12_000  # a bad key must fail in seconds, not minutes into a port
comptime BETA_NOTE = "beta: of the 14 models tried on the owner's machine, 8 ported and served; everything that worked was 1 to 3 billion parameters"


@fieldwise_init
struct Porter(Copyable, Movable):
    var kind: String  # "" not set up yet
    var base_url: String
    var key: String  # "" when none is stored (Claude Code on this machine needs none)
    var model: String

    @staticmethod
    def none() -> Porter:
        return Porter("", "", "", "")

    def prefix(self) -> String:
        """What may be shown or logged: the key's first 8 characters and its length, never the key."""
        if self.key == "":
            return ""
        return String(self.key[byte = : min(8, self.key.byte_length())]) + "… (" + String(self.key.byte_length()) + " characters)"

    def configured(self) -> Bool:
        return self.kind != ""


def path_of(home: String) -> String:
    return home + "/porter.json"


def detect_claude() -> String:
    """Claude Code on this machine (MXC_CLAUDE, then PATH), or ""."""
    from std.os import getenv
    return which(getenv("MXC_CLAUDE", "claude"))


def read_porter(home: String) -> Porter:
    if not exists(path_of(home)):
        return Porter.none()
    try:
        var j = Json.parse(read_text(path_of(home)))
        return Porter(j.text(j.get(0, "kind")), j.text(j.get(0, "base_url")), j.text(j.get(0, "key")), j.text(j.get(0, "model")))
    except:
        return Porter.none()


def write_porter(home: String, p: Porter) raises:
    """The setting, readable by this user only (0600 before anything is written into it)."""
    var path = path_of(home)
    write_text(path, "{}")
    if libc.chmod(path, 0o600) != 0:
        _ = libc.unlink(path)
        raise Error("could not make " + path + " readable by you alone; the key was not stored")
    write_text(path, '{"kind": ' + json_string(p.kind) + ', "base_url": ' + json_string(p.base_url)
               + ', "key": ' + json_string(p.key) + ', "model": ' + json_string(p.model) + "}")
    _ = libc.chmod(path, 0o600)


def remove_porter(home: String) -> Bool:
    if not exists(path_of(home)):
        return False
    return libc.unlink(path_of(home)) == 0


def porter_env(p: Porter) -> List[String]:
    """How the agent authenticates. Claude Code's own login needs nothing; a key is handed to the claude process as
    the environment variables Claude Code reads, never on a command line (where `ps` would show it)."""
    var env = List[String]()
    if p.kind == "anthropic" and p.key != "":
        env.append("ANTHROPIC_API_KEY=" + p.key)
    elif p.kind == "openai-compatible" and p.key != "":
        env.append("ANTHROPIC_BASE_URL=" + p.base_url)
        env.append("ANTHROPIC_AUTH_TOKEN=" + p.key)
        env.append("ANTHROPIC_API_KEY=")  # (a stale key in the daemon's environment must not win)
        if p.model != "":
            env.append("ANTHROPIC_MODEL=" + p.model)
    return env^


@fieldwise_init
struct Tested(Copyable, Movable):
    var ok: Bool
    var message: String


def kind_problem(kind: String, base_url: String, key: String, model: String = "") -> String:
    """Why this setting can't be stored, or ""."""
    var known = False
    for k in materialize[PORTER_KINDS]():
        if kind == String(k):
            known = True
    if not known:
        return 'Send {"kind": "claude-code" | "anthropic" | "openai-compatible", …}.'
    if base_url.byte_length() > 300 or model.byte_length() > 120:
        return "That base URL or model name is too long."
    if kind == "claude-code":
        return "" if detect_claude() != "" else "Claude Code was not found on this machine. Install it, or give an API key for a frontier model instead."
    if key.byte_length() < 8 or key.byte_length() > 400:
        return "That doesn't look like an API key."
    for b in key.as_bytes():
        var c = Int(b)
        if c < 33 or c > 126:
            return "An API key is one line of printable characters."
    if kind == "openai-compatible":
        if not (base_url.startswith("https://") or base_url.startswith("http://127.0.0.1") or base_url.startswith("http://localhost")):
            return "A base URL must be https:// (or http:// on this machine)."
        if base_url.find("@") >= 0 or base_url.find("?") >= 0:
            return "Put the key in the key field, never in the URL."
    return ""


def test_porter(p: Porter) -> Tested:
    """One small call, so a bad key fails in seconds instead of minutes into a port. The key travels in a header,
    never in the URL; nothing of the answer but its status and a short reason is kept."""
    if p.kind == "claude-code":
        var found = detect_claude()
        return Tested(found != "", ("Claude Code is on this machine (" + found + ")") if found != "" else String("Claude Code was not found."))
    if p.kind == "anthropic":
        var body = '{"model": ' + json_string(p.model if p.model != "" else String("claude-haiku-5-5")) + ', "max_tokens": 1, "messages": [{"role": "user", "content": "hi"}]}'
        var req = Request(0, "POST", "https://api.anthropic.com/v1/messages", body).header("content-type", "application/json")
        req = req^.header("x-api-key", p.key).header("anthropic-version", "2023-06-01")
        return _answer(FlareTransport.send(req^.timeout(TEST_TIMEOUT_MS)), "Anthropic")
    # A gateway is tested the way Claude Code will use it: the Anthropic Messages API, one token, the key in a
    # header. An endpoint that only speaks OpenAI's API answers 404 here, which is the truth: the agent would
    # fail on it too (reviewer round 1).
    var base = p.base_url
    while base.endswith("/"):
        var shorter = String(base[byte = : base.byte_length() - 1])
        base = shorter
    var body2 = '{"model": ' + json_string(p.model if p.model != "" else String("claude-haiku-5-5")) + ', "max_tokens": 1, "messages": [{"role": "user", "content": "hi"}]}'
    var req2 = Request(0, "POST", base + "/v1/messages", body2).header("content-type", "application/json")
    req2 = req2^.header("x-api-key", p.key).header("authorization", "Bearer " + p.key).header("anthropic-version", "2023-06-01")
    return _answer(FlareTransport.send(req2^.timeout(TEST_TIMEOUT_MS)), "that endpoint")


def _answer(r: Response, who: String) -> Tested:
    if r.error != "":
        return Tested(False, "Could not reach " + who + ": " + r.error)
    if r.status == 401 or r.status == 403:
        return Tested(False, who + " refused that key (HTTP " + String(r.status) + ").")
    if r.status == 404:
        return Tested(False, who + " has no such endpoint (HTTP 404): check the base URL, and that it answers the "
                      + "Anthropic Messages API, which is what the porting agent speaks.")
    if r.status >= 400:
        return Tested(False, who + " answered HTTP " + String(r.status) + ".")
    return Tested(True, who + " accepted the key.")


def porter_json(home: String) -> String:
    """GET /admin/porter: what is set up (never the key), and what was detected on this machine."""
    var p = read_porter(home)
    var found = detect_claude()
    return ('{"configured": ' + ("true" if p.configured() else "false") + ', "kind": ' + json_string(p.kind)
            + ', "base_url": ' + json_string(p.base_url) + ', "model": ' + json_string(p.model)
            + ', "key_prefix": ' + json_string(p.prefix()) + ', "has_key": ' + ("true" if p.key != "" else "false")
            + ', "detected": {"claude_code": ' + ("true" if found != "" else "false") + ', "path": ' + json_string(found) + "}"
            + ', "beta": true, "beta_note": ' + json_string(BETA_NOTE) + "}")
