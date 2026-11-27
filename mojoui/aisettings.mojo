# mojoui.aisettings: which model an app's AI features use, chosen once (goal 82 M6; Personal Note's ai_settings.py, F-093,
# and jam_brain.py's two brains). The choices live in `ai-settings.json` in the app's folder (the web's own file and fields,
# so the two apps read each other's), never in the notes file; the API key lives in the system's secret store
# (mojoui.secrets: libsecret / the login keychain) and is never returned, logged or written anywhere else.
#
#   var s = AiSettings.load(folder)                 # the defaults when there's no file or it is damaged
#   s.provider = "openai"; s.base_url = "http://127.0.0.1:8000/v1"; s.model = "qwen"; s.save(folder)   # raises with the web's words
#   save_key(key) / has_key() / forget_key()        # the secret store's item "Personal Note AI" / "api-key" (the web's names)
#   var call = BrainCall.start(s, system, user)     # returns at once: a child process does the asking
#   while call.poll() == ASK_RUNNING: …             # from the app's timer; then call.answer or call.error
#
# Providers: "claude-code" (the person's own signed-in `claude -p`, no tools, no files, no session, in an empty folder),
# "azure" (Azure OpenAI: endpoint + deployment + api-version, the key as `api-key`), "openai" (any OpenAI-compatible
# chat-completions endpoint: base URL + model, the key as a bearer token; a local server such as max serve on
# http://127.0.0.1 counts, and needs no key). Addresses must be https, or plain http only to this computer.
# HTTPS: the system's own curl (Linux and macOS ship it), fed its config (the address, the headers with the key, the body)
# on stdin, so the key is never on a command line or in a file; redirects are refused (a key never follows one).
# $MOJOUI_BRAIN_REPLAY=<file>: the call answers that file's words without asking anyone (the checks: recorded replies).

from std.os import getenv, makedirs
from std.os.path import isdir, isfile
from mojoui.json import Json, json_string, J_STRING, J_OBJECT
from mojoui.secrets import SecretStore
from mojoui.process import Process, file_tail
from mojoui.clock import now_ns
from mojoui import libc

comptime SETTINGS_FILE = "ai-settings.json"
comptime KEYCHAIN_SERVICE = "Personal Note AI"
comptime KEYCHAIN_ACCOUNT = "api-key"
comptime DEFAULT_API_VERSION = "2024-10-21"
comptime MAX_URL = 300
comptime MAX_NAME = 100
comptime MAX_KEY = 600
comptime TIMEOUT_S = 90

comptime ASK_RUNNING = 1
comptime ASK_DONE = 2
comptime ASK_FAILED = 3


def _loopback(host: String) -> Bool:
    return host == "127.0.0.1" or host == "localhost" or host == "::1" or host == "[::1]"


def _host_of(url: String) -> String:
    """The host of an http(s) address ("" when it has none)."""
    var at = url.find("://")
    if at < 0:
        return ""
    var rest = String(url[byte = at + 3 :])
    var end = rest.byte_length()
    for stop in ["/", "?", "#"]:
        var k = rest.find(stop)
        if k >= 0 and k < end:
            end = k
    var hostport = String(rest[byte = 0:end])
    if hostport.startswith("["):
        var close = hostport.find("]")
        return String(hostport[byte = 0 : close + 1]) if close > 0 else hostport
    var colon = hostport.rfind(":")
    return String(hostport[byte = 0:colon]) if colon >= 0 else hostport


def check_url(value_in: String, label: String) raises -> String:
    var value = String(value_in.strip())
    while value.endswith("/"):
        var _cut2 = String(value[byte = 0 : value.byte_length() - 1])
        value = _cut2^
    if value.byte_length() > MAX_URL:
        raise Error("The " + label + " is too long.")
    if value != "":
        var host = _host_of(value)
        var https = value.startswith("https://")
        var http = value.startswith("http://")
        if not (https or (http and _loopback(host))) or host == "":
            raise Error("The " + label + " must start with https:// (plain http is only allowed for this computer).")
        var rest = String(value[byte = value.find("://") + 3 :])
        var hostpart = String(rest[byte = 0 : rest.find("/")]) if rest.find("/") >= 0 else rest
        if hostpart.find("@") >= 0 or value.find("?") >= 0 or value.find("#") >= 0:
            raise Error("The " + label + " must be just an address, without a login, query or #.")
    return value^


def _name_ok(value: String, slash: Bool) -> Bool:
    for b in value.as_bytes():
        var c = Int(b)
        var ok = (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 46 or c == 95 or c == 45 or (slash and (c == 58 or c == 47))
        if not ok:
            return False
    return True


def check_name(value_in: String, label: String, slash: Bool) raises -> String:
    var value = String(value_in.strip())
    if value.byte_length() > MAX_NAME or (value != "" and (not _name_ok(value, slash) or value.find("..") >= 0 or value.startswith("/"))):
        raise Error("The " + label + " has characters it cannot have, or is too long.")
    return value^


def check_key(key_in: String) raises -> String:
    var key = String(key_in.strip())
    var bad = key == "" or key.byte_length() > MAX_KEY
    for b in key.as_bytes():
        if b <= 32 or b == 127:
            bad = True
    if bad:
        raise Error("That does not look like an API key (no spaces or line breaks, up to 600 characters).")
    return key^


struct AiSettings(Copyable, Movable):
    var provider: String  # claude-code | azure | openai
    var claude_model: String  # sonnet | haiku | opus
    var endpoint: String  # azure
    var deployment: String  # azure
    var api_version: String  # azure
    var base_url: String  # openai-compatible (a local endpoint too)
    var model: String  # openai-compatible

    def __init__(out self):
        self.provider = "claude-code"
        self.claude_model = "sonnet"
        self.endpoint = ""
        self.deployment = ""
        self.api_version = DEFAULT_API_VERSION
        self.base_url = ""
        self.model = ""

    def validate(mut self) raises:
        """The web's validate(): each field checked, the provider and model one of the known ones."""
        if self.provider != "claude-code" and self.provider != "azure" and self.provider != "openai":
            raise Error("Pick Claude Code, Azure OpenAI or an OpenAI-compatible service.")
        if self.claude_model != "sonnet" and self.claude_model != "haiku" and self.claude_model != "opus":
            raise Error("The Claude model must be sonnet, haiku or opus.")
        self.endpoint = check_url(self.endpoint, "Azure endpoint")
        self.base_url = check_url(self.base_url, "base URL")
        self.deployment = check_name(self.deployment, "deployment name", False)
        self.model = check_name(self.model, "model name", True)
        self.api_version = check_name(self.api_version, "API version", False)
        if self.api_version == "":
            self.api_version = DEFAULT_API_VERSION

    def is_local(self) -> Bool:
        """An OpenAI-compatible server on this computer (no key needed, nothing leaves)."""
        return self.provider == "openai" and _loopback(_host_of(self.base_url))

    def label(self) -> String:
        """The provider in a few words, for a settings row."""
        if self.provider == "claude-code":
            return "Claude Code"
        if self.provider == "azure":
            return "Azure OpenAI"
        return "Local model" if self.is_local() else "OpenAI-compatible"

    def json(self) -> String:
        """The web's file: json.dumps(settings, indent=2), its key order."""
        return ('{\n  "provider": ' + json_string(self.provider) + ',\n  "claudeModel": ' + json_string(self.claude_model) + ',\n  "endpoint": ' + json_string(self.endpoint)
                + ',\n  "deployment": ' + json_string(self.deployment) + ',\n  "apiVersion": ' + json_string(self.api_version) + ',\n  "baseUrl": ' + json_string(self.base_url)
                + ',\n  "model": ' + json_string(self.model) + "\n}")

    @staticmethod
    def load(folder: String) -> AiSettings:
        """The saved choices, or the defaults (a missing or damaged file never stops the app)."""
        var s = AiSettings()
        try:
            var j = Json.parse(String(open(folder + "/" + SETTINGS_FILE, "r").read()))
            if j.kind(0) != J_OBJECT:
                return s^
            var names: List[String] = ["provider", "claudeModel", "endpoint", "deployment", "apiVersion", "baseUrl", "model"]
            var vals = List[String]()
            for n in names:
                var v = j.get(0, n)
                if v >= 0 and j.kind(v) != J_STRING:
                    return AiSettings()
                vals.append(j.text(v) if v >= 0 else String(""))
            if vals[0] != "":
                s.provider = vals[0]
            if vals[1] != "":
                s.claude_model = vals[1]
            s.endpoint = vals[2]
            s.deployment = vals[3]
            if vals[4] != "":
                s.api_version = vals[4]
            s.base_url = vals[5]
            s.model = vals[6]
            s.validate()
            return s^
        except:
            return AiSettings()

    def save(mut self, folder: String) raises:
        """Checked, then written whole (a temporary file renamed over the old one)."""
        self.validate()
        if not isdir(folder):
            makedirs(folder, exist_ok=True)
        var tmp = folder + "/" + SETTINGS_FILE + ".tmp"
        with open(tmp, "w") as f:
            f.write(self.json())
        if libc.rename_path(tmp, folder + "/" + SETTINGS_FILE) != 0:
            raise Error("The settings could not be saved.")

    def destination(self) -> String:
        """Where a key would be sent: the provider and its address's host (a key belongs to the service it was given for)."""
        if self.provider == "azure":
            return "azure " + _host_of(self.endpoint).lower()
        if self.provider == "openai":
            return "openai " + _host_of(self.base_url).lower()
        return self.provider


def key_store() -> SecretStore:
    """The key's item: "Personal Note AI" / "api-key", the web's names ($MOJOUI_AI_SERVICE: a test's own item, so a check
    never touches the person's key; $MOJOUI_AI_KEYCHAIN: a macOS keychain file of the test's own)."""
    return SecretStore(getenv("MOJOUI_AI_SERVICE", KEYCHAIN_SERVICE), getenv("MOJOUI_AI_KEYCHAIN", ""))


def save_key(key: String) raises:
    key_store().save(KEYCHAIN_ACCOUNT, check_key(key))


def has_key() -> Bool:
    return key_store().has(KEYCHAIN_ACCOUNT)


def forget_key() raises:
    key_store().forget(KEYCHAIN_ACCOUNT)


def save_settings(mut s: AiSettings, folder: String, key: String = "") raises -> Bool:
    """The web's AISettings.save: the choices written; a new key saved; a saved key dropped when the address it was given
    for changed (True: it was). The key is never written anywhere but the secret store."""
    var before = AiSettings.load(folder)
    s.validate()
    var dropped = False
    if key != "":
        save_key(key)
    elif s.destination() != before.destination() and has_key():
        forget_key()
        dropped = True
    s.save(folder)
    return dropped


# ---- asking the model -------------------------------------------------------------------------------------------------

def find_claude() -> String:
    """`claude` on PATH, else in the places installers use (a Mac app starts with a bare PATH)."""
    var path = getenv("PATH", "")
    for d in path.split(":"):
        var c = String(d) + "/claude"
        if String(d) != "" and isfile(c):
            return c
    var home = getenv("HOME", "")
    for place in ["/.local/bin", "/.claude/local", "/.claude/bin", "/.bun/bin", "/.volta/bin", "/.npm-global/bin", "/.local/share/mise/shims", "/.mise/shims"]:
        if isfile(home + String(place) + "/claude"):
            return home + String(place) + "/claude"
    for place in ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]:
        if isfile(String(place)):
            return String(place)
    return ""


def _curl_quoted(s: String) -> String:
    """A value for curl's config file: double-quoted, with \\ and \" escaped and line breaks as \\n."""
    var out = String('"')
    for c in s.codepoints():
        var v = Int(c)
        if v == 34:
            out += '\\"'
        elif v == 92:
            out += "\\\\"
        elif v == 10:
            out += "\\n"
        elif v == 13:
            out += "\\r"
        elif v == 9:
            out += "\\t"
        else:
            out += String(c)
    return out + '"'


def chat_body(system: String, user: String, model: String) -> String:
    var body = '{"messages": [{"role": "system", "content": ' + json_string(system) + '}, {"role": "user", "content": ' + json_string(user) + '}], "response_format": {"type": "json_object"}'
    if model != "":
        body += ', "model": ' + json_string(model)
    return body + "}"


struct BrainCall(Movable):
    var state: Int
    var answer: String
    var error: String
    var started_ns: Int
    var kind: String  # claude-code | http | replay
    var log: String
    var folder: String  # the call's own private folder (0700): its output, removed when read
    var _proc: List[Process]

    def __init__(out self):
        self.state = ASK_FAILED
        self.answer = ""
        self.error = ""
        self.started_ns = now_ns()
        self.kind = ""
        self.log = ""
        self.folder = ""
        self._proc = List[Process]()

    @staticmethod
    def start(s: AiSettings, system: String, user: String) -> BrainCall:
        """Asks the chosen brain (returns at once). A call that can't start is ASK_FAILED with the web's words in `error`."""
        var c = BrainCall()
        var replay = getenv("MOJOUI_BRAIN_REPLAY", "")
        if replay != "":
            c.kind = "replay"
            try:
                c.answer = String(open(replay, "r").read())
                c.state = ASK_DONE
            except:
                c.error = "The recorded reply couldn't be read."
            return c^
        var base = getenv("TMPDIR", "/tmp") + "/mojoui-brain-" + String(libc.getpid()) + "-" + String(now_ns())
        try:
            makedirs(base, exist_ok=True)
            _ = libc.chmod(base, 0o700)
        except:
            c.error = "No folder for the call."
            return c^
        c.folder = base
        c.log = base + "/reply.txt"
        if s.provider == "claude-code":
            var exe = find_claude()
            if exe == "":
                c.error = "Claude Code is not installed here. Install it and sign in, or pick another brain in Settings."
                return c^
            c.kind = "claude-code"
            var dir = exe[byte = 0 : exe.rfind("/")]
            try:
                c._proc.append(Process.start_fed(
                    [exe, "-p", "--output-format", "json", "--tools", "", "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config",
                     "--system-prompt", system, "--model", s.claude_model],
                    user, c.log, ["PATH=" + String(dir) + ":" + getenv("PATH", "")], base))
                c.state = ASK_RUNNING
            except e:
                c.error = "Claude Code could not start: " + String(e)
            return c^
        var key = String("")
        try:
            key = key_store().load(KEYCHAIN_ACCOUNT)
        except:
            pass
        var env_key = getenv("PERSONAL_NOTE_JAM_API_KEY", "")
        if env_key != "":
            key = env_key
        var url: String
        var auth: String
        if s.provider == "azure":
            if s.endpoint == "" or s.deployment == "":
                c.error = "Set a base URL and model, or an Azure endpoint and deployment, for this brain."
                return c^
            url = s.endpoint + "/openai/deployments/" + s.deployment + "/chat/completions?api-version=" + s.api_version
            auth = "api-key: " + key
        else:
            if s.base_url == "" or s.model == "":
                c.error = "Set a base URL and model, or an Azure endpoint and deployment, for this brain."
                return c^
            url = s.base_url + "/chat/completions"
            auth = "Authorization: Bearer " + key
        if key == "" and not s.is_local():
            c.error = "No API key: add one in Settings → AI, or set the PERSONAL_NOTE_JAM_API_KEY environment variable."
            return c^
        var config = ("url = " + _curl_quoted(url) + "\nrequest = \"POST\"\nsilent\nshow-error\nmax-redirs = 0\nmax-time = " + String(TIMEOUT_S)
                      + "\nheader = \"Content-Type: application/json\"\n" + (("header = " + _curl_quoted(auth) + "\n") if key != "" else String(""))
                      + "data-binary = " + _curl_quoted(chat_body(system, user, s.model if s.provider == "openai" else "")) + "\nwrite-out = \"\\n%{http_code}\"\n")
        c.kind = "http"
        try:
            c._proc.append(Process.start_fed(["curl", "--config", "-"], config, c.log, List[String](), base))
            c.state = ASK_RUNNING
        except e:
            c.error = "The model could not be reached: curl didn't start (" + String(e) + ")"
        return c^

    def seconds(self) -> Float64:
        return Float64(now_ns() - self.started_ns) / 1e9

    def poll(mut self) -> Int:
        if self.state != ASK_RUNNING:
            return self.state
        if self._proc[0].running():
            if self.seconds() > Float64(TIMEOUT_S + 5):
                _ = self._proc[0].stop(500)
                self.error = "The model took longer than " + String(TIMEOUT_S) + " seconds; try again."
                self.state = ASK_FAILED
                self._clean()
            return self.state
        var code = self._proc[0].exit_code()
        var out = file_tail(self.log, 8 << 20)
        self._clean()
        if self.kind == "claude-code":
            try:
                var j = Json.parse(out)
                var res = j.get(0, "result")
                var is_error = j.get(0, "is_error")
                if code == 0 and res >= 0 and j.kind(res) == J_STRING and not (is_error >= 0 and j.flag(is_error)):
                    self.answer = j.text(res)
                    self.state = ASK_DONE
                    return self.state
                self.error = "Claude Code did not answer: " + (j.text(res) if res >= 0 else String("exit code ") + String(code))
            except:
                self.error = "Claude Code did not answer: " + (String(out[byte = 0 : min(out.byte_length(), 300)]) if out != "" else String("exit code ") + String(code))
            self.state = ASK_FAILED
            return self.state
        # http: the body, then a line with the status code (write-out)
        var nl = out.rfind("\n")
        var status = String(out[byte = nl + 1 :]) if nl >= 0 else String("")
        var body = String(out[byte = 0:nl]) if nl >= 0 else out
        if code != 0 or not status.startswith("2"):
            self.error = ("The model answered with an error (HTTP " + status + ")." if status != "" and status != "000" else "The model could not be reached (curl exit " + String(code) + ").")
            self.state = ASK_FAILED
            return self.state
        try:
            var j = Json.parse(body)
            var choices = j.get(0, "choices")
            var msg = j.get(j.at(choices, 0), "message")
            self.answer = j.text(j.get(msg, "content"))
            self.state = ASK_DONE
        except:
            self.error = "The model's answer wasn't a chat completion."
            self.state = ASK_FAILED
        return self.state

    def _clean(mut self):
        if self.log != "":
            _ = libc.unlink(self.log)
        if self.folder != "":
            _ = external_rmdir(self.folder)

    def cancel(mut self):
        if self.state == ASK_RUNNING and len(self._proc) > 0:
            self._proc[0].begin_stop()
        self.state = ASK_FAILED
        self.error = "stopped"
        self._clean()


def external_rmdir(path: String) -> Int:
    from std.ffi import external_call, c_int
    var p = path
    return Int(external_call["rmdir", c_int](p.as_c_string_span().unsafe_ptr()))
